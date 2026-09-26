"""CLI outcome tests inject at the scanner boundary; no real scan is implied."""

from contextlib import redirect_stderr, redirect_stdout
import io
from pathlib import Path
import tempfile
import tokenize
import unittest
from unittest.mock import patch

from diagnostics import Finding, ReportError
from ratchet import main
from test_config_guard import fixture
from test_git_state import git


class RatchetCLI(unittest.TestCase):
    def test_exit_codes_clean_findings_and_setup_failure(self) -> None:
        for outcome, expected in (
            ([], 0),
            ([Finding('basedpyright', 'rule', 'a.py', 'a' * 64)], 1),
            (ReportError('partial scan'), 2),
            (tokenize.TokenError('unterminated', (1, 0)), 2),
            (TypeError('invalid scanner data'), 2),
            (RecursionError('nested input'), 2),
        ):
            with (
                self.subTest(expected=expected),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory) / 'repo'
                root.mkdir()
                base = fixture(root)
                out = Path(directory) / 'reports'
                with (
                    patch('ratchet.scan') as scanner,
                    redirect_stdout(io.StringIO()),
                    redirect_stderr(io.StringIO()),
                ):
                    if isinstance(outcome, Exception):
                        scanner.side_effect = outcome
                    else:
                        scanner.return_value = outcome
                    self.assertEqual(
                        main(['python-types', '--base', base, '--out', str(out)], root),
                        expected,
                    )
                self.assertEqual(len(list(out.glob('*/result.json'))), 1)

    def test_bad_base_and_missing_ledger_fail_with_retained_error(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'repo'
            root.mkdir()
            base = fixture(root)
            out = Path(directory) / 'reports'
            with redirect_stderr(io.StringIO()):
                self.assertEqual(
                    main(['verify-config', '--base', 'HEAD', '--out', str(out)], root),
                    2,
                )
            self.assertEqual(len(list(out.glob('*/result.json'))), 1)
            (root / '.quality/suppressions.json').unlink()
            _ = git(root, 'commit', '-qam', 'remove required ledger')
            with redirect_stderr(io.StringIO()):
                self.assertEqual(
                    main(['verify-config', '--base', base, '--out', str(out)], root), 2
                )
            self.assertEqual(len(list(out.glob('*/result.json'))), 2)
