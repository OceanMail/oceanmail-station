"""Actual pinned basedpyright/ShellCheck probes in disposable Git repositories.

Run explicitly with both tools on PATH and an external evidence directory:
python3 .quality/smoke_adapters.py /absolute/output
This does not execute Station's application or no-radio acceptance workflows.
"""

import json
from pathlib import Path
import tempfile
import sys

from diagnostics import require
from ratchet import main
from test_git_state import git, initialize
from measure import write


def smoke(out: Path) -> None:
    cases = [
        ('python-clean', 'python-types', 'value: int = 1\n', 0),
        ('python-finding', 'python-types', 'value: int = "wrong"\n', 1),
        (
            'python-environment',
            'python-types',
            'import oceanmail_missing_fixture_module\n',
            2,
        ),
        ('shell-clean', 'shellcheck', '#!/bin/sh\nprintf "%s\\n" "$1"\n', 0),
        ('shell-finding', 'shellcheck', '#!/bin/sh\necho $1\n', 1),
        (
            'shell-directive',
            'shellcheck',
            '#!/bin/sh\n# shellcheck shell=bash disable=SC2086\necho $1\n',
            2,
        ),
        (
            'python-directive',
            'python-types',
            'value: int = "wrong"  # basedpyright: ignore[reportAssignmentType]\n',
            2,
        ),
        ('shell-array-lint', 'shellcheck', '#!/bin/sh\necho "$var[1]"\necho $x\n', 1),
        ('shell-parser', 'shellcheck', '#!/bin/sh\nif then\n', 2),
    ]
    outcomes: list[dict[str, object]] = []
    out.mkdir(parents=True, exist_ok=True)
    for name, command, source, expected in cases:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _ = initialize(root)
            (root / '.quality').mkdir()
            _ = (root / '.quality/suppressions.json').write_text('{"entries": []}\n')
            _ = (root / '.quality/pyrightconfig.json').write_text(
                json.dumps(
                    {
                        'include': ['../a.py'],
                        'typeCheckingMode': 'strict',
                    }
                )
            )
            if command == 'python-types':
                _ = (root / 'a.py').write_text(source)
            else:
                _ = (root / 'a.sh').write_text(source)
            _ = git(root, 'add', '.')
            _ = git(root, 'commit', '-qm', 'scanner fixture')
            base = git(root, 'rev-parse', 'HEAD')
            _ = git(root, 'commit', '--allow-empty', '-qm', 'proposed head')
            actual = main([command, '--base', base, '--out', str(out / name)], root)
            outcomes.append({'case': name, 'expected': expected, 'actual': actual})
            write(out / 'summary.json', outcomes)
            require(actual == expected, 'pinned-tool smoke failed: ' + name)
    print(str(len(cases)) + ' actual pinned-tool smoke cases passed')


if __name__ == '__main__':
    require(len(sys.argv) == 2, 'provide external evidence directory')
    smoke(Path(sys.argv[1]).resolve())
