"""Read immutable comparison state without trusting a PR-supplied file list."""

from collections.abc import Sequence
from pathlib import Path
import re
import subprocess

from diagnostics import ReportError, path, require


class GitState:
    def __init__(self, root: Path, base: str) -> None:
        self.root: Path = root.resolve(strict=True)
        require(
            re.fullmatch(r'[0-9a-f]{40}', base) is not None,
            'base must be a full immutable commit SHA',
        )
        self.base: str = base
        require(
            self.command(['rev-parse', '--show-toplevel']).strip() == str(self.root),
            'expected repository root',
        )
        require(
            self.command(['cat-file', '-t', base]).strip() == 'commit',
            'base is not a commit',
        )
        # Reject an unrelated repository object or a future/nonancestor base.
        _ = self.command(['merge-base', '--is-ancestor', base, 'HEAD'])
        self.head: str = self.command(['rev-parse', 'HEAD']).strip()
        require(self.base != self.head, 'base cannot be the proposed head itself')

    def command(self, args: Sequence[str]) -> str:
        try:
            result = subprocess.run(
                ['git', '--no-replace-objects', '-C', str(self.root), *args],
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired, UnicodeError) as exc:
            raise ReportError('cannot read Git comparison state') from exc
        require(
            result.returncode == 0, 'Git comparison command failed: ' + ' '.join(args)
        )
        return result.stdout

    def tracked(self, revision: str) -> dict[str, str]:
        require(revision in (self.base, self.head), 'untrusted revision selection')
        entries: dict[str, str] = {}
        for record in self.command(['ls-tree', '-rz', '--full-tree', revision]).split(
            '\0'
        ):
            if not record:
                continue
            metadata, filename = record.split('\t', 1)
            mode, kind, _ = metadata.split(' ')
            require(
                kind == 'blob' and mode in ('100644', '100755'),
                'symlink/submodule requires explicit scope policy: ' + filename,
            )
            entries[path(filename)] = mode
        return entries

    def read(self, revision: str, filename: str) -> str:
        require(revision in (self.base, self.head), 'untrusted revision selection')
        return self.command(['show', revision + ':' + path(filename)])

    def has_shebang(self, revision: str, filename: str) -> bool:
        require(revision in (self.base, self.head), 'untrusted revision selection')
        result = subprocess.run(
            [
                'git',
                '--no-replace-objects',
                '-C',
                str(self.root),
                'show',
                revision + ':' + path(filename),
            ],
            capture_output=True,
            timeout=30,
            check=False,
        )
        require(result.returncode == 0, 'cannot inspect source scope')
        return result.stdout.startswith(b'#!')

    def require_clean(self) -> None:
        require(
            not self.command(['status', '--porcelain=v1', '--untracked-files=all']),
            'comparison requires a clean tracked/untracked checkout',
        )

    def sources(self, suffixes: tuple[str, ...]) -> dict[str, str]:
        return {
            name: self.read(self.head, name)
            for name in self.tracked(self.head)
            if name.endswith(suffixes)
        }
