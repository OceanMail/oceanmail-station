#!/usr/bin/env python3
"""Station S1 report-only measurement; never a required CI gate.

Derived from owner CI kit scripts/measure.py's subprocess/report design.
All raw outputs survive findings, scanner errors, missing tools and timeouts.
"""

import argparse
from collections import Counter
from collections.abc import Callable, Mapping, Sequence
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from typing import NotRequired, TypedDict

from suppression_inventory import inventory, unsuppress_shell
from diagnostics import array, decode, integer, obj, string

ROOT = Path(__file__).resolve().parents[1]
RUST = '1.98.1'


class Result(TypedDict):
    name: str
    argv: NotRequired[list[str]]
    cwd: NotRequired[str]
    started_at: NotRequired[str]
    finished_at: NotRequired[str]
    exit_code: NotRequired[int | None]
    execution: NotRequired[str]
    error: NotRequired[str]
    seconds: NotRequired[float]
    assessment: NotRequired[str]
    metrics: NotRequired[dict[str, object] | None]
    parse_error: NotRequired[str]
    coverage: NotRequired['Coverage']
    coverage_error: NotRequired[str]


class FileCoverage(TypedDict):
    executable_lines: int
    hit_lines: int
    percent: float | None


class Coverage(TypedDict):
    per_file: dict[str, FileCoverage]
    missing_owned_files: list[str]
    zero_hit_files: list[str]


class Options(argparse.Namespace):
    out: Path = ROOT / '.quality/reports'
    timeout: float = 1800


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def write(path: Path, data: object) -> None:
    _ = path.write_text(json.dumps(data, indent=2, sort_keys=True) + '\n')


def capture(argv: Sequence[str], cwd: Path = ROOT) -> str:
    return subprocess.check_output(argv, cwd=cwd, text=True, timeout=120).strip()


def run(
    argv: Sequence[str],
    cwd: Path,
    out: Path,
    name: str,
    timeout: float = 1800,
    env: Mapping[str, str] | None = None,
) -> Result:
    """A process outcome is not a diagnostic interpretation."""
    command = list(argv)
    result = Result(name=name, argv=command, cwd=str(cwd), started_at=now())
    start = time.monotonic()
    with (
        (out / f'{name}.stdout').open('w') as stdout,
        (out / f'{name}.stderr').open('w') as stderr,
    ):
        try:
            proc = subprocess.Popen(
                command,
                cwd=cwd,
                env=env,
                stdout=stdout,
                stderr=stderr,
                start_new_session=True,
            )
            try:
                result['exit_code'] = proc.wait(timeout=timeout)
                result['execution'] = 'COMPLETED'
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                _ = proc.wait()
                result.update(execution='TIMEOUT', exit_code=124)
        except OSError as exc:
            result.update(
                execution='MISSING_OR_SETUP_ERROR', exit_code=None, error=str(exc)
            )
    result.update(seconds=round(time.monotonic() - start, 3), finished_at=now())
    return result


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def parse(kind: str, stdout: str, stderr: str, rc: int | None) -> dict[str, object]:
    """Reject unknown/malformed schemas; preserve partial counts only as partial."""
    if kind == 'json':
        require(rc == 0, 'command failed')
        return {'data': decode(stdout)}
    if kind in ('ruff', 'shellcheck', 'hadolint', 'actionlint'):
        raw = decode(stdout)
        if kind == 'shellcheck':
            raw = obj(raw)['comments']
        data = [obj(item) for item in array(raw)]
        require(rc in (0, 1), 'scanner execution failed')
        key = {
            'ruff': 'code',
            'shellcheck': 'code',
            'hadolint': 'code',
            'actionlint': 'kind',
        }[kind]
        counts = Counter(str(item[key]) for item in data)
        require(rc == 0 or bool(data), 'nonzero exit with no diagnostics')
        return {
            'findings': len(data),
            'by_rule': dict(counts),
            'diagnostics': data,
            'partial': any(str(x.get('code')) == 'DL1000' for x in data)
            if kind == 'hadolint'
            else False,
        }
    if kind == 'pyright':
        report = obj(decode(stdout))
        type_diagnostics = [obj(item) for item in array(report['generalDiagnostics'])]
        require(rc in (0, 1), 'type checker setup failed')
        summary = obj(report['summary'])
        require(
            'filesAnalyzed' in summary and 'errorCount' in summary,
            'missing analysis totals',
        )
        require(integer(summary['filesAnalyzed']) > 0, 'no files analyzed')
        require(rc == 0 or bool(type_diagnostics), 'nonzero without diagnostics')
        return {
            'findings': len(type_diagnostics),
            'summary': summary,
            'by_rule': dict(
                Counter(string(d.get('rule', d['severity'])) for d in type_diagnostics)
            ),
        }
    if kind == 'cargo':
        records = [obj(decode(line)) for line in stdout.splitlines() if line.strip()]
        require(
            any(x.get('reason') == 'build-finished' for x in records),
            'missing cargo completion',
        )
        diagnostics = [
            obj(x['message']) for x in records if x.get('reason') == 'compiler-message'
        ]
        errors = sum(x['level'] == 'error' for x in diagnostics)
        warnings = [x for x in diagnostics if x['level'] == 'warning']
        success = (
            records[-1].get('reason') == 'build-finished'
            and records[-1].get('success') is True
        )
        return {
            'findings': len(warnings),
            'compiler_errors': errors,
            'build_success': success and rc == 0,
            'by_rule': dict(
                Counter(
                    string(obj(x.get('code') or {}).get('code', 'warning'))
                    for x in warnings
                )
            ),
            'diagnostics': diagnostics,
            'partial': not success or rc != 0,
        }
    if kind == 'rust-tests':
        tests = [
            {'id': m[0], 'outcome': m[1]}
            for m in re.findall(
                r'^test (.+) \.\.\. (ok|FAILED|ignored)(?: .*)?$', stdout, re.M
            )
        ]
        totals = re.findall(
            r'test result: (ok|FAILED)\. (\d+) passed; (\d+) failed; (\d+) ignored;',
            stdout,
        )
        require(bool(totals), 'missing test completion; setup/collection failure')
        require(
            len(tests) == sum(int(x[1]) + int(x[2]) + int(x[3]) for x in totals),
            'test identity/count mismatch',
        )
        require(rc in (0, 101), 'unexpected test process exit')
        require(
            rc == 0 or any(x['outcome'] == 'FAILED' for x in tests),
            'nonzero without failing test',
        )
        return {
            'tests': tests,
            'outcomes': dict(Counter(x['outcome'] for x in tests)),
            'test_count': len(tests),
            'zero_tests': not tests,
            'xfail': 0,
            'findings': sum(x['outcome'] == 'FAILED' for x in tests),
        }
    if kind == 'python-tests':
        tests = [
            {'id': m[0], 'outcome': m[1]}
            for m in re.findall(
                r'^(test\S+ \(.+\)) \.\.\. (ok|FAIL|ERROR|skipped[^\n]*|expected failure|unexpected success)$',
                stderr,
                re.M,
            )
        ]
        count = re.search(r'^Ran (\d+) tests? in ', stderr, re.M)
        require(
            count is not None and int(count[1]) == len(tests),
            'missing/incomplete unittest identities',
        )
        require(
            re.search(r'^(OK(?: \(.*\))?|FAILED \(.*\))$', stderr, re.M) is not None,
            'missing unittest completion',
        )
        require(rc in (0, 1), 'unexpected unittest exit')
        require(
            rc == 0
            or any(
                x['outcome'] in ('FAIL', 'ERROR', 'unexpected success') for x in tests
            ),
            'nonzero without failing test',
        )
        return {
            'tests': tests,
            'test_count': len(tests),
            'zero_tests': not tests,
            'outcomes': dict(Counter(x['outcome'] for x in tests)),
            'findings': sum(
                x['outcome'] in ('FAIL', 'ERROR', 'unexpected success') for x in tests
            ),
        }
    if kind == 'semgrep':
        report = obj(decode(stdout))
        scan_results = [obj(item) for item in array(report['results'])]
        scan_errors = array(report['errors'])
        scanned = [string(item) for item in array(obj(report['paths'])['scanned'])]
        require(rc in (0, 1), 'scanner setup/engine failed')
        require(
            rc == 0 or bool(scan_results) or bool(scan_errors),
            'nonzero without scan findings/errors',
        )
        return {
            'findings': len(scan_results),
            'partial': bool(scan_errors) or not scanned,
            'errors': scan_errors,
            'scanned': scanned,
            'by_severity': dict(
                Counter(string(obj(x['extra'])['severity']) for x in scan_results)
            ),
        }
    if kind == 'audit':
        report = obj(decode(stdout))
        require(rc in (0, 1), 'audit execution failed')
        vulnerabilities = obj(report['vulnerabilities'])
        vulns = array(vulnerabilities['list'])
        require(integer(vulnerabilities['count']) == len(vulns), 'audit count mismatch')
        require('database' in report, 'missing advisory database metadata')
        audit_warnings = {
            key: array(value) for key, value in obj(report.get('warnings', {})).items()
        }
        require(
            rc == 0 or bool(vulns) or any(audit_warnings.values()),
            'nonzero without advisories',
        )
        return {
            'findings': len(vulns),
            'advisories': vulns,
            'warnings': audit_warnings,
            'warning_count': sum(len(v) for v in audit_warnings.values()),
            'database': report['database'],
        }
    if kind == 'pip-audit':
        report = obj(decode(stdout))
        require(rc in (0, 1), 'audit execution failed')
        deps = [obj(item) for item in array(report['dependencies'])]
        require(bool(deps), 'missing audited dependencies')
        skipped = [d for d in deps if 'skip_reason' in d]
        findings = [
            dict(package=d['name'], version=d['version'], advisory=v)
            for d in deps
            if 'skip_reason' not in d
            for v in array(d['vulns'])
        ]
        require(
            rc == 0 or bool(findings) or bool(skipped), 'nonzero without advisories'
        )
        return {
            'findings': len(findings),
            'advisories': findings,
            'partial': bool(skipped),
            'skipped': skipped,
        }
    if kind == 'fmt':
        require(rc in (0, 1), 'formatter setup error')
        require(rc == 0 or 'Diff in ' in stdout, 'nonzero without formatting diff')
        return {
            'findings': len(re.findall(r'^Diff in ', stdout, re.M)),
            'metric': 'diff hunks (not lint identities)',
        }
    if kind == 'shell-syntax':
        # bash -n returns 2 for syntax errors AND some invocation failures.
        # Require Bash's file/line diagnostic; permission/missing-file failures
        # are execution errors, not source findings.
        require(rc in (0, 2), 'unexpected Bash exit')
        diagnostics = re.findall(
            r'^.+: line \d+: (?:syntax error[^\n]*|unexpected EOF[^\n]*)$',
            stderr,
            re.M,
        )
        require(rc == 0 or bool(diagnostics), 'Bash setup/read failure')
        require(rc != 0 or not diagnostics, 'Bash exit/diagnostic mismatch')
        return {'findings': len(diagnostics), 'diagnostics': diagnostics}
    require(rc == 0, 'command failed; inspect raw evidence')
    return {'findings': 0}


def interpret(result: Result, out: Path, kind: str) -> Result:
    execution = result.get('execution', 'MISSING_OR_SETUP_ERROR')
    if execution != 'COMPLETED':
        result['assessment'] = execution
        return result
    try:
        parsed = parse(
            kind,
            (out / (result['name'] + '.stdout')).read_text(),
            (out / (result['name'] + '.stderr')).read_text(),
            result.get('exit_code'),
        )
        result['metrics'] = parsed
        result['assessment'] = (
            'PARTIAL_OR_COMPILER_ERROR'
            if parsed.get('partial')
            else 'ZERO_TESTS'
            if parsed.get('zero_tests')
            else 'FINDINGS'
            if parsed.get('findings', 0) or parsed.get('warning_count', 0)
            else 'COMPLETE'
        )
    except (ValueError, KeyError, TypeError) as exc:
        result.update(
            assessment='PARSER_OR_EXECUTION_ERROR', parse_error=str(exc), metrics=None
        )
    return result


def coverage(path: Path, sources: Sequence[str]) -> Coverage:
    tree = ET.parse(path)
    files: dict[str, dict[int, int]] = {}
    for cls in tree.findall('.//class'):
        name = cls.attrib['filename']
        p = Path(name)
        if p.is_absolute():
            p = p.relative_to(ROOT)
        require('..' not in p.parts, 'escaping coverage path')
        name = p.as_posix()
        if name not in sources:
            raise ValueError('unmapped coverage path: ' + name)
        lines = files.setdefault(name, {})
        for line in cls.findall('./lines/line'):
            number, hits = int(line.attrib['number']), int(line.attrib['hits'])
            require(number > 0 and hits >= 0, 'invalid coverage line')
            lines[number] = max(hits, lines.get(number, 0))
    require(bool(files), 'empty coverage')
    result: dict[str, FileCoverage] = {
        p: FileCoverage(
            executable_lines=len(ls),
            hit_lines=sum(v > 0 for v in ls.values()),
            percent=round(100 * sum(v > 0 for v in ls.values()) / len(ls), 2)
            if ls
            else None,
        )
        for p, ls in files.items()
    }
    return Coverage(
        per_file=result,
        missing_owned_files=sorted(set(sources) - set(files)),
        zero_hit_files=[p for p, x in result.items() if x['hit_lines'] == 0],
    )


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    _ = ap.add_argument('--out', type=Path, default=ROOT / '.quality/reports')
    _ = ap.add_argument('--timeout', type=float, default=1800)
    args = Options()
    _ = ap.parse_args(namespace=args)
    require(args.timeout > 0, 'timeout must be positive')
    out = args.out.resolve() / datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S.%fZ')
    out.mkdir(parents=True)
    files = capture(['git', 'ls-files', '-z']).split('\0')
    files = [p for p in files if p]
    predicates: dict[str, Callable[[str], bool]] = {
        'rust': lambda p: p.endswith('.rs'),
        'shell': lambda p: p.endswith('.sh'),
        'python': lambda p: p.endswith('.py'),
        'docker': lambda p: Path(p).name == 'Dockerfile',
        'workflow': lambda p: p.startswith('.github/workflows/'),
        'patch': lambda p: p.endswith('.patch'),
    }
    groups = {
        kind: [p for p in files if predicate(p)]
        for kind, predicate in predicates.items()
    }
    provenance_files = files
    manifest: dict[str, object] = dict(
        source_sha=capture(['git', 'rev-parse', 'HEAD']),
        started_at=now(),
        dirty_state=capture(
            ['git', 'status', '--porcelain=v1', '--untracked-files=all']
        ),
        platform=platform.platform(),
        python=sys.version,
        os_release=Path('/etc/os-release').read_text(),
        groups=groups,
        files_sha256={
            p: hashlib.sha256((ROOT / p).read_bytes()).hexdigest()
            for p in provenance_files
        },
        environment={
            k: os.environ.get(k)
            for k in (
                'RUSTUP_HOME',
                'CARGO_HOME',
                'CARGO_TARGET_DIR',
                'RUSTFLAGS',
                'RUSTDOCFLAGS',
            )
        },
        gaps=[
            'Embedded Python/shell and generated variants are not extracted for standalone analysis.',
            'No RF, GUI, Windows, macOS or ARM runtime evidence.',
            'LLVM coverage measures Rust tests, not no-radio Docker workflows or Python-driven HTTP execution.',
            'Semgrep rules are limited syntactic review leads, not a complete security audit.',
            'Upstream HERMES patch is inventoried/hashed, excluded from owned-source lint and coverage.',
            'Docker base-image/apt/upstream dependency advisories are not covered by Cargo/pip audits.',
            'Direct tool pins and captured resolutions are not complete transitive reproducibility.',
        ],
    )
    write(out / 'manifest.json', manifest)
    write(
        out / 'native-suppressions.json',
        [
            site
            for p in groups['rust'] + groups['shell'] + groups['python']
            for site in inventory(p, (ROOT / p).read_text())
        ],
    )
    bootstrap = ROOT / '.quality/tools/provenance'
    if bootstrap.exists():
        _ = shutil.copytree(
            bootstrap,
            out / 'bootstrap',
            ignore=shutil.ignore_patterns(
                '*.tar.gz', 'hadolint-Linux-x86_64', 'hadolint-linux-x86_64'
            ),
        )
    results: list[Result] = []

    def check(
        name: str,
        argv: Sequence[str],
        kind: str = 'command',
        env: Mapping[str, str] | None = None,
    ) -> Result:
        print(name, flush=True)
        r = interpret(run(argv, ROOT, out, name, args.timeout, env), out, kind)
        results.append(r)
        write(out / 'checks.json', results)
        return r

    check(
        'measurement-self-tests',
        [
            'python3',
            '-m',
            'unittest',
            'discover',
            '-s',
            '.quality',
            '-p',
            'test_*.py',
            '-v',
        ],
        'python-tests',
    )
    for name, argv in {
        'rustc': ['rustc', '+' + RUST, '-vV'],
        'cargo': ['cargo', '+' + RUST, '--version'],
        'clippy': ['cargo', '+' + RUST, 'clippy', '--version'],
        'rustfmt': ['cargo', '+' + RUST, 'fmt', '--version'],
        'llvm-cov': ['cargo', '+' + RUST, 'llvm-cov', '--version'],
        'cargo-audit': ['cargo', 'audit', '--version'],
        'ruff': ['ruff', '--version'],
        'basedpyright': ['basedpyright', '--version'],
        'semgrep': ['semgrep', '--version'],
        'shellcheck': ['shellcheck', '--version'],
        'hadolint': ['hadolint', '--version'],
        'actionlint': ['actionlint', '--version'],
        'pip-audit': ['pip-audit', '--version'],
        'bash': ['bash', '--version'],
    }.items():
        check('version-' + name, argv)
    cargo = ['cargo', '+' + RUST]
    meta = check(
        'cargo-metadata',
        cargo + ['metadata', '--locked', '--format-version', '1'],
        'json',
    )
    check('cargo-features', cargo + ['tree', '--locked', '-e', 'features'])
    check('cargo-fmt', cargo + ['fmt', '--all', '--', '--check'], 'fmt')
    check(
        'cargo-clippy',
        cargo + ['clippy', '--locked', '--all-targets', '--message-format=json'],
        'cargo',
    )
    check(
        'cargo-check',
        cargo + ['check', '--locked', '--all-targets', '--message-format=json'],
        'cargo',
    )
    check(
        'cargo-test',
        cargo + ['test', '--locked', '--', '--format', 'pretty'],
        'rust-tests',
    )
    # Per-target identities disambiguate same-named tests in different binaries.
    metadata_metrics = meta.get('metrics')
    if metadata_metrics:
        data = obj(metadata_metrics['data'])
        members = array(data['workspace_members'])
        owned = [obj(p) for p in array(data['packages']) if obj(p)['id'] in members]
        write(out / 'target-matrix.json', owned)
        for package in owned:
            for raw_target in array(package['targets']):
                target = obj(raw_target)
                if not target['test']:
                    continue
                kind = string(array(target['kind'])[0])
                target_name = string(target['name'])
                selector = (
                    ['--lib']
                    if kind == 'lib'
                    else ['--bin', target_name]
                    if kind == 'bin'
                    else []
                )
                if selector:
                    check(
                        'tests-' + target_name,
                        cargo
                        + ['test', '--locked', *selector, '--', '--format', 'pretty'],
                        'rust-tests',
                    )
    check(
        'readiness-tests',
        ['python3', 'scripts/test-phase4i-snapshot-readiness.py', '-v'],
        'python-tests',
    )
    built = check(
        'auth-build', cargo + ['build', '--locked', '--message-format=json'], 'cargo'
    )
    if (built.get('metrics') or {}).get('build_success'):
        check(
            'auth-http-tests',
            ['python3', 'scripts/test-phase4j-auth.py', '-v'],
            'python-tests',
        )
    else:
        results.append(
            Result(name='auth-http-tests', assessment='BLOCKED_BY_BUILD', metrics=None)
        )
    cov = check(
        'rust-coverage',
        cargo
        + [
            'llvm-cov',
            '--locked',
            '--all-targets',
            '--cobertura',
            '--output-path',
            str(out / 'coverage.xml'),
        ],
    )
    try:
        require(cov.get('exit_code') == 0, 'coverage execution failed')
        cov['coverage'] = coverage(out / 'coverage.xml', groups['rust'])
        if cov['coverage']['missing_owned_files']:
            cov['assessment'] = 'PARTIAL_COVERAGE'
    except (OSError, ValueError, KeyError, ET.ParseError) as exc:
        cov.update(assessment='MISSING_OR_INVALID_COVERAGE', coverage_error=str(exc))
    for i, p in enumerate(groups['shell']):
        check(f'shell-syntax-{i:02}', ['bash', '-n', p], 'shell-syntax')
    check(
        'shellcheck', ['shellcheck', '--format=json1', *groups['shell']], 'shellcheck'
    )
    # A second scan removes only native ShellCheck disable comments in temporary
    # copies; source files and line numbers remain unchanged in the checkout.
    shell_inputs: list[str] = []
    mapping: dict[str, str] = {}
    for p in groups['shell']:
        content = (ROOT / p).read_text()
        unsuppressed = unsuppress_shell(content)
        if unsuppressed != content:
            dest = out / 'unsuppressed-shell' / p
            dest.parent.mkdir(parents=True, exist_ok=True)
            _ = dest.write_text(unsuppressed)
            shell_inputs.append(str(dest))
            mapping[str(dest)] = p
        else:
            shell_inputs.append(p)
    write(out / 'shellcheck-source-map.json', mapping)
    check(
        'shellcheck-unsuppressed',
        ['shellcheck', '--format=json1', *shell_inputs],
        'shellcheck',
    )
    check(
        'python-ruff',
        [
            'ruff',
            'check',
            '--isolated',
            '--ignore-noqa',
            '--output-format=json',
            *groups['python'],
        ],
        'ruff',
    )
    check(
        'python-types',
        ['basedpyright', '--project', '.quality/pyrightconfig.json', '--outputjson'],
        'pyright',
    )
    check(
        'docker-hadolint',
        ['hadolint', '--format', 'json', *groups['docker']],
        'hadolint',
    )
    # pyflakes is not provisioned. ShellCheck remains enabled; embedded Python gap is explicit.
    check(
        'workflow-actionlint',
        [
            'actionlint',
            '-color',
            '-pyflakes=',
            '-format',
            '{{json .}}',
            *groups['workflow'],
        ],
        'actionlint',
    )
    env = os.environ.copy()
    _ = env.pop('SEMGREP_APP_TOKEN', None)
    env.update(SEMGREP_SEND_METRICS='off')
    scan = check(
        'semgrep',
        [
            'semgrep',
            'scan',
            '--config',
            '.quality/semgrep.yml',
            '--metrics=off',
            '--disable-version-check',
            '--no-git-ignore',
            '--disable-nosem',
            '--json',
            '--error',
            *groups['rust'],
            *groups['python'],
        ],
        'semgrep',
        env,
    )
    scan_metrics = scan.get('metrics')
    if scan_metrics:
        missing = sorted(
            set(groups['rust'] + groups['python'])
            - {string(p) for p in array(scan_metrics['scanned'])}
        )
        scan_metrics['missing_targets'] = missing
        if missing:
            scan['assessment'] = 'PARTIAL_SCAN'
    check('cargo-audit', ['cargo', 'audit', '--json'], 'audit')
    # Audit installed tools' locked Rust graphs separately from product dependencies.
    cargo_home = Path(os.environ.get('CARGO_HOME', Path.home() / '.cargo'))
    for tool, version in [('cargo-audit', '0.22.2'), ('cargo-llvm-cov', '0.6.19')]:
        locks = list(
            (cargo_home / 'registry/src').glob(f'*/{tool}-{version}/Cargo.lock')
        )
        if len(locks) == 1:
            _ = shutil.copy(locks[0], out / (tool + '-Cargo.lock'))
            check(
                'audit-tool-' + tool,
                ['cargo', 'audit', '--json', '--file', str(locks[0])],
                'audit',
            )
        else:
            results.append(
                Result(
                    name='audit-tool-' + tool,
                    assessment='MISSING_TOOL_LOCK',
                    metrics=None,
                )
            )
    for venv in ('python', 'semgrep'):
        sites = list(
            (ROOT / '.quality/tools' / venv / 'lib').glob('python*/site-packages')
        )
        if len(sites) == 1:
            check(
                'audit-tools-' + venv,
                [
                    'pip-audit',
                    '--path',
                    str(sites[0]),
                    '--format=json',
                    '--progress-spinner=off',
                ],
                'pip-audit',
            )
        else:
            results.append(
                Result(
                    name='audit-tools-' + venv,
                    assessment='MISSING_TOOL_ENV',
                    metrics=None,
                )
            )
    db = cargo_home / 'advisory-db'
    if db.exists():
        check('advisory-revision', ['git', '-C', str(db), 'rev-parse', 'HEAD'])
        check(
            'advisory-date',
            ['git', '-C', str(db), 'show', '-s', '--format=%cI', 'HEAD'],
        )
    manifest.update(
        finished_at=now(),
        final_dirty_state=capture(
            ['git', 'status', '--porcelain=v1', '--untracked-files=all']
        ),
    )
    write(out / 'manifest.json', manifest)
    write(out / 'checks.json', results)
    summary = [
        '# Station S1 measurement',
        '',
        'Report-only; exit zero is not clean CI.',
        '',
        f"Source: `{manifest['source_sha']}`",
        f"Started: {manifest['started_at']}",
        '',
        '| Check | Assessment | Exit | Findings |',
        '| --- | --- | --- | --- |',
    ]
    for r in results:
        summary.append(
            f"| {r['name']} | {r.get('assessment', 'UNASSESSED')} | {r.get('exit_code', 'N/A')} | {(r.get('metrics') or {}).get('findings', 'unknown/N/A')} |"
        )
    summary += ['', '## Known scope gaps', ''] + [
        '- ' + string(g) for g in array(manifest['gaps'])
    ]
    _ = (out / 'summary.md').write_text('\n'.join(summary) + '\n')
    hashes = {
        str(p.relative_to(out)): hashlib.sha256(p.read_bytes()).hexdigest()
        for p in out.rglob('*')
        if p.is_file()
    }
    write(out / 'SHA256SUMS.json', hashes)
    print(out)
    return 0


if __name__ == '__main__':
    sys.exit(main())
