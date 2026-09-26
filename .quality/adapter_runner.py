"""Execute scanners with retained evidence; never reinterpret setup failure as debt."""

from collections.abc import Mapping, Sequence
from pathlib import Path
import re
import hashlib
import shutil

from diagnostics import (
    Comparison,
    Finding,
    ReportError,
    cargo_audit,
    check_expiry,
    clippy,
    compare,
    decode,
    ledger,
    owned_tool_path,
    obj,
    array,
    integer,
    require,
    shellcheck,
    pyright,
)
from cargo_graph import dependency_paths
from git_state import GitState
from measure import run, write
from execution_policy import (
    environment,
    reject_external_cargo_config,
    audit_completed,
    utc_now,
)


VERSION_PATTERNS = {
    'rustc': '^rustc 1\\.98\\.1 ',
    'basedpyright': '(?m)^basedpyright 1\\.31\\.4(?:\\s|$)',
    'shellcheck': '(?m)^version: 0\\.10\\.0\\s*$',
    'cargo-audit': '^cargo-audit-audit 0\\.22\\.2(?:\\s|$)',
}


class Scanner:
    def __init__(self, root: Path, out: Path, timeout: float = 1800) -> None:
        require(timeout > 0, 'timeout must be positive')
        self.environment: dict[str, str] = environment(out)
        write(
            out / 'environment.json',
            {
                name: '<transport setting present>'
                if 'PROXY' in name.upper()
                else value
                for name, value in self.environment.items()
            },
        )
        self.root: Path = root
        self.out: Path = out
        self.timeout: float = timeout

    def execute(
        self, name: str, argv: Sequence[str], cwd: Path | None = None
    ) -> tuple[str, int]:
        require(re.fullmatch(r'[a-z0-9-]+', name) is not None, 'invalid report name')
        executable = shutil.which(argv[0], path=self.environment['PATH'])
        if executable is not None:
            write(
                self.out / (name + '.executable.json'),
                {
                    'path': executable,
                    'sha256': hashlib.sha256(Path(executable).read_bytes()).hexdigest(),
                },
            )
        command = [executable or argv[0], *argv[1:]]
        result = run(
            command,
            cwd or self.root,
            self.out,
            name,
            self.timeout,
            env=self.environment,
        )
        write(self.out / (name + '.execution.json'), result)
        require(
            result.get('execution') == 'COMPLETED',
            'scanner execution incomplete: ' + name,
        )
        code = result.get('exit_code')
        require(code is not None, 'missing scanner exit code')
        assert code is not None
        return (self.out / (name + '.stdout')).read_text(), code

    def version(self, name: str, argv: Sequence[str], pattern: str) -> None:
        text, code = self.execute('version-' + name, argv)
        require(
            code == 0 and re.search(pattern, text) is not None,
            'unvalidated tool version: ' + name,
        )


def report_paths(text: str, key: str, root: Path, sources: Mapping[str, str]) -> str:
    """Map ShellCheck paths before identity normalization, retaining raw separately."""
    import json

    report = obj(decode(text))
    for raw in array(report.get(key)):
        entry = obj(raw)
        entry['file'] = owned_tool_path(entry.get('file'), root, sources)
    return json.dumps(report)


def scan(kind: str, state: GitState, scanner: Scanner) -> list[Finding]:
    if kind == 'python-types':
        sources = state.sources(('.py',))
        scanner.version(
            'basedpyright',
            ['basedpyright', '--version'],
            VERSION_PATTERNS['basedpyright'],
        )
        text, code = scanner.execute(
            'python-types',
            [
                'basedpyright',
                '--project',
                '.quality/pyrightconfig.json',
                '--outputjson',
            ],
        )
        return pyright(text, code, sources, len(sources), root=state.root)
    if kind == 'shellcheck':
        sources = state.sources(('.sh',))
        require(bool(sources), 'no owned shell source')
        scanner.version(
            'shellcheck', ['shellcheck', '--version'], VERSION_PATTERNS['shellcheck']
        )
        text, code = scanner.execute(
            'shellcheck', ['shellcheck', '--format=json1', *sorted(sources)]
        )
        return shellcheck(
            report_paths(text, 'comments', state.root, sources), code, sources
        )
    if kind == 'clippy':
        reject_external_cargo_config(state.root)
        sources = state.sources(('.rs',))
        require(bool(sources), 'no owned Rust source')
        scanner.version(
            'rustc', ['rustc', '+1.98.1', '--version'], VERSION_PATTERNS['rustc']
        )
        text, code = scanner.execute(
            'clippy',
            [
                'cargo',
                '+1.98.1',
                'clippy',
                '--locked',
                '--workspace',
                '--all-targets',
                '--message-format=json',
            ],
        )
        return clippy(text, code, sources)
    if kind == 'audit':
        reject_external_cargo_config(state.root)
        scanner.version(
            'cargo-audit',
            ['cargo', 'audit', '--version'],
            VERSION_PATTERNS['cargo-audit'],
        )
        metadata, metadata_code = scanner.execute(
            'cargo-metadata',
            ['cargo', '+1.98.1', 'metadata', '--locked', '--format-version', '1'],
        )
        require(metadata_code == 0, 'locked metadata resolution failed')
        routes = dependency_paths(decode(metadata))
        audit_root = scanner.out / 'audit-work'
        audit_root.mkdir()
        started = utc_now()
        argv = [
            'cargo',
            '+1.98.1',
            'audit',
            '--color',
            'never',
            '--file',
            str(state.root / 'Cargo.lock'),
        ]
        _, preflight_code = scanner.execute('audit-preflight', argv, cwd=audit_root)
        require(preflight_code in (0, 1), 'audit preflight execution failed')
        database = Path(scanner.environment['CARGO_HOME']) / 'advisory-db'
        commit, commit_code = scanner.execute(
            'audit-db-commit', ['git', '-C', str(database), 'rev-parse', 'HEAD']
        )
        updated, updated_code = scanner.execute(
            'audit-db-date',
            ['git', '-C', str(database), 'show', '-s', '--format=%cI', 'HEAD'],
        )
        require(
            commit_code == updated_code == 0, 'audit database provenance unavailable'
        )
        text, code = scanner.execute(
            'audit', [*argv, '--json', '--no-fetch'], cwd=audit_root
        )
        finished = utc_now()
        require(code == preflight_code, 'audit preflight/report exit mismatch')
        require(
            not (scanner.out / 'audit.stderr').read_text().strip(),
            'audit JSON stderr requires triage',
        )
        audit_completed(
            (scanner.out / 'audit-preflight.stderr').read_text(),
            started,
            finished,
            decode(text),
        )
        write(
            scanner.out / 'audit-freshness.json',
            {
                'started_utc': started.isoformat(),
                'finished_utc': finished.isoformat(),
                'database_fetch': 'fresh invocation; no inherited audit config',
                'index_check': 'enabled; failure stderr rejected',
                'database_stale_policy': 'pinned RustSec default 90 days; no --stale',
            },
        )
        require(
            integer(obj(obj(decode(text)).get('lockfile')).get('dependency-count'))
            == len(array(obj(decode(metadata)).get('packages'))),
            'audit lockfile/metadata package count mismatch',
        )
        return cargo_audit(
            text,
            code,
            routes,
            database_provenance={
                'last-commit': commit.strip(),
                'last-updated': updated.strip(),
            },
        )
    raise ReportError('unknown adapter: ' + kind)


def assess(kind: str, findings: Sequence[Finding], state: GitState) -> Comparison:
    tool = {
        'python-types': 'basedpyright',
        'shellcheck': 'shellcheck',
        'clippy': 'clippy',
        'audit': 'cargo-audit',
    }[kind]
    filename = '.quality/suppressions.json'
    trusted = ledger(state.read(state.base, filename))
    proposed = ledger(state.read(state.head, filename))
    # Validate the entire ledger against the base before filtering per tool.
    _ = compare([], trusted, proposed)
    selected = [entry for entry in proposed if entry.finding.tool == tool]
    if kind == 'audit':
        companion = '.quality/advisory-exceptions.json'
        require(
            state.read(state.base, companion) == state.read(state.head, companion),
            'advisory policy changed; separate reviewed update required',
        )
        check_expiry(selected, state.read(state.head, companion), utc_now().date())
    return compare(
        findings, [entry for entry in trusted if entry.finding.tool == tool], selected
    )
