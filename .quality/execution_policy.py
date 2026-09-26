"""Isolated scanner environment and pinned cargo-audit completion checks."""

from datetime import datetime, timezone
from pathlib import Path
import os
import re

from diagnostics import require, obj, array, integer


UNSAFE_ENVIRONMENT = (
    'RUSTFLAGS',
    'CARGO_ENCODED_RUSTFLAGS',
    'RUSTC_WRAPPER',
    'RUSTC_WORKSPACE_WRAPPER',
    'CLIPPY_CONF_DIR',
    'SHELLCHECK_OPTS',
)


def environment(out: Path) -> dict[str, str]:
    require(
        not any(os.environ.get(name) for name in UNSAFE_ENVIRONMENT),
        'scanner environment overrides require explicit policy',
    )
    runtime = out.resolve() / 'runtime'
    for name in ('home', 'cargo', 'config', 'cache', 'tmp'):
        (runtime / name).mkdir(parents=True, exist_ok=False)
    # PATH and rustup select tools; the resolved launcher/proxy bytes are recorded.
    # This does not hash every underlying compiler, driver or interpreter.
    # No compiler options, Python imports, user config or Cargo config are inherited.
    result = {
        'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
        'HOME': str(runtime / 'home'),
        'CARGO_HOME': str(runtime / 'cargo'),
        'RUSTUP_HOME': os.environ.get('RUSTUP_HOME', str(Path.home() / '.rustup')),
        'RUSTUP_AUTO_INSTALL': '0',
        'XDG_CONFIG_HOME': str(runtime / 'config'),
        'XDG_CACHE_HOME': str(runtime / 'cache'),
        'TMPDIR': str(runtime / 'tmp'),
        'LANG': 'C.UTF-8',
        'LC_ALL': 'C.UTF-8',
        'TZ': 'UTC',
        'NO_COLOR': '1',
        'CARGO_TERM_COLOR': 'never',
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': '/dev/null',
        'GIT_TERMINAL_PROMPT': '0',
    }
    # Transport settings preserve the runner network boundary; not tool options.
    for name in (
        'HTTPS_PROXY',
        'HTTP_PROXY',
        'ALL_PROXY',
        'NO_PROXY',
        'https_proxy',
        'http_proxy',
        'all_proxy',
        'no_proxy',
        'SSL_CERT_FILE',
    ):
        if name in os.environ:
            result[name] = os.environ[name]
    if 'SSL_CERT_FILE' in result:
        result['CARGO_HTTP_CAINFO'] = result['SSL_CERT_FILE']
    return result


def reject_external_cargo_config(root: Path) -> None:
    for directory in (root.resolve(), *root.resolve().parents):
        for name in ('config', 'config.toml'):
            require(
                not (directory / '.cargo' / name).exists(),
                'Cargo config requires an explicit reviewed execution policy',
            )


def audit_completed(
    stderr: str, started: datetime, finished: datetime, report: object
) -> None:
    """Pinned audit JSON omits index failures: check its mandatory stderr too.

    The command runs in a fresh directory/home with no config and no quiet flag.
    Default cargo-audit fetches the DB and index, but only prints some index
    failures. Unknown stderr fails closed. The captured database commit date
    is provenance only; this adapter does not enforce a maximum database age.
    """
    require(
        started.tzinfo is not None and finished.tzinfo is not None,
        'audit timestamps must be timezone-aware',
    )
    require(
        0 <= (finished - started).total_seconds() <= 1800,
        'audit freshness window exceeded',
    )
    text = re.sub(r'\x1b\[[0-9;]*m', '', stderr)
    patterns = (
        r'Fetching advisory database from `https://github.com/RustSec/advisory-db(?:\.git)?`',
        r'Loaded \d+ security advisories \(from .+\)',
        r'Updating crates\.io index',
        r'Scanning .+ for vulnerabilities \(\d+ crate dependencies\)',
    )
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    data = obj(report)
    count = integer(obj(data.get('vulnerabilities')).get('count'))
    warnings = sum(len(array(value)) for value in obj(data.get('warnings')).values())
    summaries: list[str] = []
    if count:
        word = 'vulnerability' if count == 1 else 'vulnerabilities'
        summaries.append(f'error: {count} {word} found!')
    if warnings:
        word = 'warning' if warnings == 1 else 'warnings'
        summaries.append(f'warning: {warnings} allowed {word} found')
    require(lines[4:] == summaries, 'audit unexpected stderr or incomplete stages')
    require(
        len(lines) >= 4
        and all(
            re.fullmatch(pattern, line) for pattern, line in zip(patterns, lines[:4])
        ),
        'audit feed/index completion requires triage',
    )


def utc_now() -> datetime:
    return datetime.now(timezone.utc)
