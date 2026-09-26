"""Inventory only: Python comments are tokenized; other languages are candidates.

This is not verify-config. Shell heredocs and Rust strings need language-aware
policy validation before any candidate can be accepted as a real exception.
"""

import io
from pathlib import Path
import re
import tokenize
from typing import TypedDict


class Site(TypedDict):
    file: str
    line: int
    text: str
    classification: str


PYTHON_DIRECTIVE = re.compile(
    r'#\s*(?:(?:(?:ruff|flake8):\s*)?noqa\b|nosemgrep\b|type:\s*ignore\b|(?:based)?pyright:|mypy:)',
    re.IGNORECASE,
)
OTHER_CANDIDATE = re.compile(
    r'#\s*!?\[\s*(?:allow|expect)\b|#\s*shellcheck\b[^\n]*\bdisable\s*=|#\s*nosemgrep\b'
)


def inventory(filename: str, source: str) -> list[Site]:
    if Path(filename).suffix == '.py':
        return [
            Site(
                file=filename,
                line=token.start[0],
                text=token.string,
                classification='python-comment-directive',
            )
            for token in tokenize.generate_tokens(io.StringIO(source).readline)
            if token.type == tokenize.COMMENT and PYTHON_DIRECTIVE.search(token.string)
        ]
    return [
        Site(
            file=filename,
            line=number,
            text=line.strip(),
            classification='unverified-language-candidate',
        )
        for number, line in enumerate(source.splitlines(), 1)
        if OTHER_CANDIDATE.search(line)
    ]


def unsuppress_shell(source: str) -> str:
    """Remove disable options, retaining other ShellCheck settings and line count.

    As with the inventory, shell comments are conservative textual candidates;
    this helper is only used on temporary measurement copies.
    """
    def remove(match: re.Match[str]) -> str:
        result = re.sub(r'\bdisable=[^\s]+', '', match.group())
        # Only options before a trailing reason comment affect ShellCheck.
        options = result.removeprefix('#').split('#', 1)[0]
        if not re.search(r'\b[\w-]+=\S', options):
            return '# measurement: native disable removed'
        return result

    return re.sub(r'#\s*shellcheck\b[^\n]*', remove, source)
