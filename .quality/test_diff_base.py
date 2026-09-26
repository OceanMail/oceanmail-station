"""Exercise the actual Bash event-base helper against temporary Git history."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from test_git_state import git, initialize


HELPER = Path(__file__).with_name('diff-base.sh').resolve()


class DiffBase(unittest.TestCase):
    def test_pr_push_and_manual_compare_nonempty_history(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = initialize(root)
            _ = (root / 'a.py').write_text('changed = 2\n')
            _ = git(root, 'commit', '-qam', 'head')
            _ = git(root, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
            for event, before in [
                ('pull_request', base),
                ('push', base),
                ('push', '0' * 40),
                ('workflow_dispatch', ''),
            ]:
                output = root / 'env'
                output.unlink(missing_ok=True)
                env = {
                    **os.environ,
                    'GITHUB_EVENT_NAME': event,
                    'PR_BASE_SHA': base,
                    'PUSH_BEFORE': before,
                    'GITHUB_ENV': str(output),
                }
                result = subprocess.run(
                    ['bash', str(HELPER)],
                    cwd=root,
                    env=env,
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(output.read_text(), 'QUALITY_BASE=' + base + '\n')

    def test_empty_invalid_and_unsupported_scope_fail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = initialize(root)
            _ = git(root, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
            for event, before in [
                ('push', 'HEAD'),
                ('pull_request', base),
                ('workflow_dispatch', ''),
                ('merge_group', ''),
            ]:
                env = {
                    **os.environ,
                    'GITHUB_EVENT_NAME': event,
                    'PR_BASE_SHA': base,
                    'PUSH_BEFORE': before,
                    'GITHUB_ENV': str(root / 'env'),
                }
                result = subprocess.run(
                    ['bash', str(HELPER)],
                    cwd=root,
                    env=env,
                    capture_output=True,
                    text=True,
                )
                self.assertNotEqual(result.returncode, 0)
