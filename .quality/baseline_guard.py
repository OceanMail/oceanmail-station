#!/usr/bin/env python3
"""Typed adaptation of the owner kit's six-field multiset baseline guard.

Usage: baseline_guard.py trusted.json proposed.json
Both documents must contain exactly {"entries": [six-field entries...]}.
"""

from collections import Counter
from dataclasses import asdict
import json
from pathlib import Path
import sys

from diagnostics import ledger, require


def main(argv: list[str]) -> int:
    require(len(argv) == 2, 'provide trusted and proposed ledger filenames')
    before = Counter(ledger(Path(argv[0]).read_text()))
    after = Counter(ledger(Path(argv[1]).read_text()))
    added = after - before
    if added:
        print(
            json.dumps(
                {
                    'new_or_expanded_exceptions': [
                        {
                            **asdict(entry.finding),
                            'issue': entry.issue,
                            'reason': entry.reason,
                            'count': count,
                        }
                        for entry, count in added.items()
                    ]
                },
                indent=2,
            )
        )
        return 1
    print(
        json.dumps(
            {
                'remaining': sum(after.values()),
                'removed': sum((before - after).values()),
            }
        )
    )
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main(sys.argv[1:]))
    except (ValueError, OSError, TypeError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(2)
