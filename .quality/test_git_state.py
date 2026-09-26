"""Trusted-base probes use real temporary Git repositories."""

from pathlib import Path
import subprocess
import tempfile
import unittest

from diagnostics import ReportError
from git_state import GitState


def git(root: Path, *args: str) -> str:
    return subprocess.check_output(
        ['git', '-C', str(root), *args], text=True, stderr=subprocess.DEVNULL
    ).strip()


def initialize(root: Path) -> str:
    _ = git(root, 'init', '-q')
    _ = git(root, 'config', 'user.email', 'fixture@example.invalid')
    _ = git(root, 'config', 'user.name', 'Fixture')
    _ = (root / 'a.py').write_text('old = 1\n')
    _ = git(root, 'add', '.')
    _ = git(root, 'commit', '-qm', 'base')
    return git(root, 'rev-parse', 'HEAD')


class TrustedBase(unittest.TestCase):
    def test_reads_old_content_from_commit_not_working_tree(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = initialize(root)
            _ = (root / 'a.py').write_text('new = 2\n')
            _ = git(root, 'commit', '-qam', 'head')
            state = GitState(root, base)
            state.require_clean()
            self.assertEqual(state.read(base, 'a.py'), 'old = 1\n')
            self.assertEqual(state.sources(('.py',)), {'a.py': 'new = 2\n'})
            _ = (root / 'untracked.py').write_text('x = 1\n')
            with self.assertRaises(ReportError):
                state.require_clean()

    def test_mutable_refs_noncommits_and_path_escape_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = initialize(root)
            for value in (
                'HEAD',
                base,
                base[:8],
                '0' * 40,
                git(root, 'rev-parse', 'HEAD:a.py'),
            ):
                with self.subTest(value=value), self.assertRaises(ReportError):
                    _ = GitState(root, value)
            _ = git(root, 'commit', '--allow-empty', '-qm', 'proposal')
            state = GitState(root, base)
            with self.assertRaises(ReportError):
                _ = state.read(base, '../a.py')

    def test_nonancestor_base_and_tracked_symlinks_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = initialize(root)
            _ = (root / 'a.py').write_text('future = 2\n')
            _ = git(root, 'commit', '-qam', 'future')
            future = git(root, 'rev-parse', 'HEAD')
            _ = git(root, 'checkout', '-q', base)
            with self.assertRaises(ReportError):
                _ = GitState(root, future)
            (root / 'alias.py').symlink_to('a.py')
            _ = git(root, 'add', 'alias.py')
            _ = git(root, 'commit', '-qm', 'alias')
            state = GitState(root, base)
            with self.assertRaises(ReportError):
                _ = state.tracked(state.head)
