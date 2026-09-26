"""Typed, fail-closed S3a normalization primitives; not an installed CI gate.

Callers must establish tool versions, complete scan scope and report provenance.
Source fingerprints deliberately include the entire file until reviewed context
remapping exists: a changed file never inherits an exception silently.
"""

from collections import Counter
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from datetime import date, timedelta
import hashlib
import json
from pathlib import Path, PurePosixPath
import re
from typing import cast


class ReportError(ValueError):
    """Incomplete, malformed or unsuccessful tool execution (future exit 2)."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ReportError(message)


def obj(value: object) -> dict[str, object]:
    require(isinstance(value, dict), 'expected object')
    result = cast(dict[object, object], value)
    require(all(isinstance(key, str) for key in result), 'non-string key')
    return cast(dict[str, object], result)


def array(value: object) -> list[object]:
    require(isinstance(value, list), 'expected array')
    return cast(list[object], value)


def string(value: object) -> str:
    require(isinstance(value, str) and bool(value.strip()), 'expected nonempty string')
    return cast(str, value)


def integer(value: object) -> int:
    require(type(value) is int, 'expected integer, not boolean')
    return cast(int, value)


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        require(key not in result, 'duplicate JSON key: ' + key)
        result[key] = value
    return result


def _invalid_constant(value: str) -> object:
    raise ReportError('non-finite JSON constant: ' + value)


def decode(text: str) -> object:
    try:
        value: object = json.loads(
            text, object_pairs_hook=_unique_object, parse_constant=_invalid_constant
        )
        return value
    except json.JSONDecodeError as exc:
        raise ReportError('malformed JSON') from exc


def path(value: object) -> str:
    name = string(value)
    parts = PurePosixPath(name)
    require(
        not parts.is_absolute()
        and '..' not in parts.parts
        and '\\' not in name
        and ':' not in name
        and '\x00' not in name
        and parts.as_posix() == name
        and name != '.',
        'expected canonical repository-relative path',
    )
    return name


def digest(value: object) -> str:
    return hashlib.sha256(
        json.dumps(
            value, sort_keys=True, separators=(',', ':'), ensure_ascii=False
        ).encode()
    ).hexdigest()


def owned_tool_path(value: object, root: Path, sources: Mapping[str, str]) -> str:
    """Map tool paths to owned files; reject traversal and symlink aliases."""
    name = string(value)
    candidate = Path(name)
    require('..' not in candidate.parts, 'tool path contains traversal')
    repository = root.resolve(strict=True)
    if candidate.is_absolute():
        try:
            relative = candidate.relative_to(repository).as_posix()
        except ValueError as exc:
            raise ReportError('tool path outside repository') from exc
    else:
        relative = name
    relative = path(relative)
    require(relative in sources, 'tool path outside owned source')
    target = repository / relative
    try:
        require(target.resolve(strict=True) == target, 'symlink tool path rejected')
        require(target.is_file(), 'tool path is not a file')
        require(target.read_text() == sources[relative], 'source changed since scan')
    except (OSError, UnicodeError, RuntimeError) as exc:
        raise ReportError('cannot validate tool source') from exc
    return relative


@dataclass(frozen=True, order=True)
class Finding:
    tool: str
    rule: str
    file: str
    fingerprint: str


def source_finding(
    tool: str,
    rule: str,
    filename: object,
    start: int,
    end: int,
    sources: Mapping[str, str],
    detail: str,
) -> Finding:
    name = path(filename)
    require(name in sources, 'diagnostic outside declared owned source: ' + name)
    lines = sources[name].splitlines()
    require(1 <= start <= end <= len(lines), 'diagnostic range outside source')
    # No line number in identity; identical occurrences are counted separately.
    fingerprint = digest(
        {
            'source': sources[name],
            'span': lines[start - 1 : end],
            'detail': detail,
        }
    )
    return Finding(tool, string(rule), name, fingerprint)


def clippy(text: str, rc: int, sources: Mapping[str, str]) -> list[Finding]:
    require(rc == 0, 'Clippy/build failed')
    records = [obj(decode(line)) for line in text.splitlines() if line.strip()]
    finished = [
        record for record in records if record.get('reason') == 'build-finished'
    ]
    require(
        len(finished) == 1
        and records[-1] == finished[0]
        and finished[0].get('success') is True,
        'missing/failed Cargo completion',
    )
    findings: list[Finding] = []
    for record in records:
        require(
            record.get('reason')
            in {
                'compiler-message',
                'compiler-artifact',
                'build-script-executed',
                'build-finished',
            },
            'unknown Cargo JSON record',
        )
        if record.get('reason') != 'compiler-message':
            continue
        message = obj(record.get('message'))
        level = string(message.get('level'))
        require(level != 'error', 'compiler errors cannot be legacy debt')
        if level in ('note', 'help', 'failure-note'):
            continue
        require(level == 'warning', 'unknown compiler diagnostic level')
        code = obj(message.get('code'))
        primary = [
            obj(span)
            for span in array(message.get('spans'))
            if obj(span).get('is_primary') is True
        ]
        require(len(primary) == 1, 'ambiguous or missing primary span')
        span = primary[0]
        findings.append(
            source_finding(
                'clippy',
                string(code.get('code')),
                span.get('file_name'),
                integer(span.get('line_start')),
                integer(span.get('line_end')),
                sources,
                string(message.get('message')),
            )
        )
    return findings


def shellcheck(text: str, rc: int, sources: Mapping[str, str]) -> list[Finding]:
    require(rc in (0, 1), 'ShellCheck execution failed')
    comments = array(obj(decode(text)).get('comments'))
    require((rc == 0) == (not comments), 'ShellCheck exit/diagnostic mismatch')
    findings: list[Finding] = []
    for item in comments:
        entry = obj(item)
        code = integer(entry.get('code'))
        require(code > 0, 'invalid ShellCheck rule')
        # SC1087 is an array-expansion diagnostic with a completed parse.
        # All other SC1xxx remain parser/source triage, never baseline debt.
        require(
            code == 1087 or not 1000 <= code < 2000,
            'ShellCheck parser/source scope requires triage',
        )
        findings.append(
            source_finding(
                'shellcheck',
                'SC' + str(code),
                entry.get('file'),
                integer(entry.get('line')),
                integer(entry.get('endLine')),
                sources,
                string(entry.get('message')),
            )
        )
    return findings


def pyright(
    text: str,
    rc: int,
    sources: Mapping[str, str],
    expected_files: int,
    root: Path | None = None,
) -> list[Finding]:
    require(rc in (0, 1), 'type checker execution failed')
    report = obj(decode(text))
    summary = obj(report.get('summary'))
    require(
        expected_files > 0 and integer(summary.get('filesAnalyzed')) == expected_files,
        'type scan scope incomplete',
    )
    entries = [obj(item) for item in array(report.get('generalDiagnostics'))]
    levels = Counter(string(entry.get('severity')) for entry in entries)
    require(set(levels) <= {'error', 'warning', 'information'}, 'unknown severity')
    for level, key in [
        ('error', 'errorCount'),
        ('warning', 'warningCount'),
        ('information', 'informationCount'),
    ]:
        require(
            integer(summary.get(key)) == levels[level], 'type diagnostic total mismatch'
        )
    require(rc == 0 or bool(entries), 'type checker failure without diagnostics')
    findings: list[Finding] = []
    for entry in entries:
        rule = string(entry.get('rule'))
        require(
            rule
            not in {
                'reportMissingImports',
                'reportMissingModuleSource',
                'reportMissingTypeStubs',
            },
            'type environment requires repair',
        )
        position = obj(entry.get('range'))
        start = integer(obj(position.get('start')).get('line')) + 1
        end = integer(obj(position.get('end')).get('line')) + 1
        findings.append(
            source_finding(
                'basedpyright',
                rule,
                owned_tool_path(entry.get('file'), root, sources)
                if root is not None
                else entry.get('file'),
                start,
                end,
                sources,
                string(entry.get('message')),
            )
        )
    return findings


def cargo_audit(
    text: str,
    rc: int,
    dependency_paths: Mapping[tuple[str, str], Sequence[str]],
    lockfile: str = 'Cargo.lock',
    database_provenance: Mapping[str, str] | None = None,
) -> list[Finding]:
    """Normalize using independently resolved locked-graph paths, never ignores.

    Caller supplies all root-to-package paths from locked metadata. These are
    identities, not display-only text; missing paths make the report unusable.
    """
    require(rc in (0, 1), 'audit execution failed')
    report = obj(decode(text))
    database = obj(report.get('database'))
    for field in ('last-commit', 'last-updated'):
        value = database.get(field)
        if value is None:
            require(database_provenance is not None, 'missing database provenance')
            assert database_provenance is not None
            value = database_provenance.get(field)
        _ = string(value)
        if database_provenance is not None:
            require(
                value == database_provenance.get(field), 'database provenance mismatch'
            )
    commit = database.get('last-commit') or (database_provenance or {}).get(
        'last-commit'
    )
    require(
        re.fullmatch(r'[0-9a-f]{40}', string(commit)) is not None,
        'invalid database commit',
    )
    settings = obj(report.get('settings'))
    require(
        array(settings.get('ignore')) == [] and settings.get('severity') is None,
        'audit filters cannot substitute for exception ledger',
    )
    require(
        array(settings.get('target_arch')) == []
        and array(settings.get('target_os')) == [],
        'audit target filtering requires explicit scope policy',
    )
    vulnerabilities = obj(report.get('vulnerabilities'))
    entries = [obj(item) for item in array(vulnerabilities.get('list'))]
    require(
        integer(vulnerabilities.get('count')) == len(entries), 'audit count mismatch'
    )
    classified: list[tuple[dict[str, object], str | None]] = [
        (entry, None) for entry in entries
    ]
    require(
        sorted(string(item) for item in array(settings.get('informational_warnings')))
        == ['notice', 'unmaintained', 'unsound'],
        'audit informational warning filtering requires explicit scope policy',
    )
    warnings = obj(report.get('warnings'))
    for category, values in warnings.items():
        require(
            category in {'unmaintained', 'unsound', 'yanked', 'notice'},
            'unknown audit warning category',
        )
        for item in array(values):
            warning = obj(item)
            require(warning.get('kind') == category, 'audit warning kind mismatch')
            classified.append((warning, category))
    require(rc == 0 or bool(classified), 'audit failure without advisories')
    findings: list[Finding] = []
    for entry, category in classified:
        if category == 'yanked':
            require(
                'advisory' in entry and entry['advisory'] is None,
                'unexpected yanked advisory',
            )
            rule = 'yanked'
        else:
            rule = string(obj(entry.get('advisory')).get('id'))
        package = obj(entry.get('package'))
        name, version = string(package.get('name')), string(package.get('version'))
        routes = dependency_paths.get((name, version))
        require(routes is not None and bool(routes), 'missing locked dependency path')
        assert routes is not None
        require(len(set(routes)) == len(routes), 'duplicate dependency path')
        for route in routes:
            findings.append(
                Finding(
                    'cargo-audit',
                    rule,
                    path(lockfile),
                    digest(
                        {'package': name, 'version': version, 'path': string(route)}
                    ),
                )
            )
    return findings


@dataclass(frozen=True)
class ExceptionEntry:
    finding: Finding
    issue: str
    reason: str


def ledger(text: str) -> list[ExceptionEntry]:
    entries: list[ExceptionEntry] = []
    document = obj(decode(text))
    require(
        set(document) == {'entries'}, 'ledger must contain exactly an entries array'
    )
    for item in array(document['entries']):
        entry = obj(item)
        require(
            set(entry) == {'tool', 'rule', 'file', 'fingerprint', 'issue', 'reason'},
            'exception must use six-field schema',
        )
        fingerprint = string(entry.get('fingerprint'))
        require(
            re.fullmatch(r'[0-9a-f]{64}', fingerprint) is not None,
            'invalid fingerprint',
        )
        issue = string(entry.get('issue'))
        require(
            re.fullmatch(
                r'https://github\.com/OceanMail/[A-Za-z0-9_.-]+/issues/[1-9][0-9]*',
                issue,
            )
            is not None,
            'exception requires an OceanMail GitHub issue URL',
        )
        entries.append(
            ExceptionEntry(
                Finding(
                    string(entry.get('tool')),
                    string(entry.get('rule')),
                    path(entry.get('file')),
                    fingerprint,
                ),
                issue,
                string(entry.get('reason')),
            )
        )
    return entries


@dataclass(frozen=True)
class Comparison:
    new: Counter[Finding]
    stale: Counter[Finding]

    @property
    def clean(self) -> bool:
        return not self.new and not self.stale


def compare(
    current: Sequence[Finding],
    trusted: Sequence[ExceptionEntry],
    proposed: Sequence[ExceptionEntry],
) -> Comparison:
    """Caller loads trusted ledger from immutable base, not working tree.

    Deleting obsolete entries is required; deleting debt cannot offset additions.
    Repeated identical entries are deliberate multiplicity, not set membership.
    """
    require(
        not (Counter(proposed) - Counter(trusted)),
        'baseline additions or metadata edits',
    )
    actual = Counter(current)
    accepted = Counter(entry.finding for entry in proposed)
    return Comparison(actual - accepted, accepted - actual)


def check_expiry(
    entries: Sequence[ExceptionEntry],
    companion: str,
    today: date,
) -> None:
    """Cross-check audit exceptions by full identity; reject absent/extra entries."""
    expected = {
        entry.finding for entry in entries if entry.finding.tool == 'cargo-audit'
    }
    seen: set[Finding] = set()
    for item in array(decode(companion)):
        entry = obj(item)
        require(
            set(entry)
            == {
                'tool',
                'rule',
                'file',
                'fingerprint',
                'owner',
                'created',
                'expires',
                'package',
                'version',
                'dependency_path',
            },
            'invalid advisory companion schema',
        )
        identity = Finding(
            string(entry.get('tool')),
            string(entry.get('rule')),
            path(entry.get('file')),
            string(entry.get('fingerprint')),
        )
        require(
            identity in expected and identity not in seen,
            'unmatched/duplicate advisory exception',
        )
        require(
            re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]*', string(entry.get('owner')))
            is not None,
            'invalid advisory owner',
        )
        details = {
            'package': string(entry.get('package')),
            'version': string(entry.get('version')),
            'path': string(entry.get('dependency_path')),
        }
        require(
            digest(details) == identity.fingerprint,
            'advisory details do not match identity',
        )
        expiry_text = string(entry.get('expires'))
        require(
            re.fullmatch(r'\d{4}-\d{2}-\d{2}', expiry_text) is not None,
            'invalid expiry',
        )
        try:
            expires = date.fromisoformat(expiry_text)
            created_text = string(entry.get('created'))
            require(
                re.fullmatch(r'\d{4}-\d{2}-\d{2}', created_text) is not None,
                'invalid creation date',
            )
            created = date.fromisoformat(created_text)
        except ValueError as exc:
            raise ReportError('invalid expiry') from exc
        require(
            created <= today < expires, 'advisory exception expired or not yet valid'
        )
        require(
            created < expires <= created + timedelta(days=30),
            'advisory exception exceeds 30 days',
        )
        seen.add(identity)
    require(seen == expected, 'missing advisory exception owner/expiry')
