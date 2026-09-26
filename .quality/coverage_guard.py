#!/usr/bin/env python3
"""Validate complete owned Cobertura scope before changed-line threshold checks.

Adapted from the owner kit's coverage guard. No executable-line threshold is
claimed here: diff-cover remains the separate S4 80-percent check.
"""

from collections.abc import Mapping
from fnmatch import fnmatchcase
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

from diagnostics import path, require
from git_state import GitState


def validate(xml: str, sources: Mapping[str, str], prefix: str = '') -> ET.Element:
    root = ET.fromstring(xml)
    require(root.tag == 'coverage', 'expected Cobertura XML')
    normalized_prefix = path(prefix) + '/' if prefix else ''
    recorded: set[str] = set()
    for node in root.findall('.//class'):
        name = path(node.get('filename', ''))
        if normalized_prefix and not name.startswith(normalized_prefix):
            name = normalized_prefix + name
        require(name in sources, 'unmapped coverage source: ' + name)
        require(name not in recorded, 'duplicate coverage class: ' + name)
        recorded.add(name)
        node.set('filename', name)
        lines = node.findall('./lines/line')
        # Fail closed instead of treating a fake empty class as source coverage.
        require(
            bool(lines) or not sources[name].strip(),
            'nonempty source has no coverage lines: ' + name,
        )
        seen: set[int] = set()
        for line in lines:
            number, hits = int(line.get('number', '')), int(line.get('hits', ''))
            require(
                1 <= number <= len(sources[name].splitlines()) and hits >= 0,
                'invalid coverage line/hits: ' + name,
            )
            require(number not in seen, 'duplicate coverage line: ' + name)
            seen.add(number)
    require(bool(recorded), 'no coverage classes')
    require(
        recorded == set(sources),
        'missing owned coverage sources: ' + ', '.join(sorted(set(sources) - recorded)),
    )
    return root


def main(argv: list[str]) -> int:
    require(len(argv) >= 3, 'usage: coverage_guard.py BASE coverage.xml SOURCE_GLOB...')
    base, filename, *patterns = argv
    state = GitState(Path.cwd(), base)
    sources = {
        name: state.read(state.head, name)
        for name in state.tracked(state.head)
        if any(fnmatchcase(name, pattern) for pattern in patterns)
    }
    _ = validate(Path(filename).read_text(), sources)
    print(
        f'{len(sources)} owned source files retained in coverage; threshold check remains separate'
    )
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except (ValueError, OSError, ET.ParseError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(2)
