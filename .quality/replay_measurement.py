"""Replay retained S1 raw reports to detect measurement-schema regressions.

Usage: python3 .quality/replay_measurement.py /path/to/S1-source-report
No scanner executes and this is not current-source acceptance evidence.
"""

import hashlib
from pathlib import Path
import sys

from diagnostics import array, decode, integer, obj, require, string
from measure import parse


KINDS = {
    'cargo-metadata': 'json',
    'cargo-fmt': 'fmt',
    'cargo-clippy': 'cargo',
    'cargo-check': 'cargo',
    'cargo-test': 'rust-tests',
    'auth-build': 'cargo',
    'measurement-self-tests': 'python-tests',
    'readiness-tests': 'python-tests',
    'auth-http-tests': 'python-tests',
    'python-ruff': 'ruff',
    'python-types': 'pyright',
    'shellcheck': 'shellcheck',
    'shellcheck-unsuppressed': 'shellcheck',
    'docker-hadolint': 'hadolint',
    'workflow-actionlint': 'actionlint',
    'semgrep': 'semgrep',
    'cargo-audit': 'audit',
    'audit-tools-python': 'pip-audit',
    'audit-tools-semgrep': 'pip-audit',
    'audit-tool-cargo-audit': 'audit',
    'audit-tool-cargo-llvm-cov': 'audit',
}


def replay(root: Path) -> int:
    hashes = obj(decode((root / 'SHA256SUMS.json').read_text()))
    for name, expected in hashes.items():
        filename = root / name
        require(
            filename.resolve().is_relative_to(root.resolve()), 'escaping archive path'
        )
        require(
            hashlib.sha256(filename.read_bytes()).hexdigest() == expected,
            'retained report hash mismatch: ' + name,
        )
    checks = {
        string(obj(item)['name']): obj(item)
        for item in array(decode((root / 'checks.json').read_text()))
    }
    count = 0
    for name, kind in KINDS.items():
        old = checks[name]
        actual = parse(
            kind,
            (root / (name + '.stdout')).read_text(),
            (root / (name + '.stderr')).read_text(),
            integer(old['exit_code']),
        )
        expected = dict(obj(old['metrics']))
        # measure.main computes scan coverage after parsing; it is not a parser field.
        if kind == 'semgrep':
            _ = expected.pop('missing_targets', None)
        require(actual == expected, 'retained parser metrics changed: ' + name)
        count += 1
    return count


if __name__ == '__main__':
    require(len(sys.argv) == 2, 'provide extracted S1 report directory')
    print(
        f'{replay(Path(sys.argv[1]))} retained scanner reports reproduce exact parser metrics'
    )
