"""The proposed gate cannot judge its own weakening."""

from pathlib import Path
import tempfile
import unittest

from trusted_runner import run_trusted
from test_git_state import git, initialize


class TrustedRunner(unittest.TestCase):
    def test_proposal_cannot_replace_comparator_or_gate(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'repo'
            root.mkdir()
            _ = initialize(root)
            (root / '.quality').mkdir()
            _ = (root / '.quality/ratchet.py').write_text(
                'def main(*args, **kwargs): return 0\n'
            )
            _ = (root / '.quality/diagnostics.py').write_text(
                'def compare(): return False\n'
            )
            _ = git(root, 'add', '.')
            _ = git(root, 'commit', '-qm', 'trusted gate')
            base = git(root, 'rev-parse', 'HEAD')
            _ = git(root, 'commit', '--allow-empty', '-qm', 'unchanged')
            self.assertEqual(
                run_trusted(root, base, 'verify-config', Path(directory) / 'clean'), 0
            )
            _ = (root / '.quality/diagnostics.py').write_text(
                'def compare(): return True\n'
            )
            _ = git(root, 'commit', '-qam', 'weaken comparator')
            self.assertEqual(
                run_trusted(root, base, 'verify-config', Path(directory) / 'bad'), 2
            )
