"""Real subprocess failures and partial execution cannot become clean scans."""

from pathlib import Path
import sys
import re
from unittest.mock import patch
import tempfile
import unittest

from adapter_runner import Scanner, VERSION_PATTERNS
from execution_policy import UNSAFE_ENVIRONMENT
from diagnostics import ReportError


class ScannerExecution(unittest.TestCase):
    def test_missing_tool_and_timeout_retain_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scanner = Scanner(root, root, timeout=0.05)
            for name, argv in (
                ('missing', ['/no/such/oceanmail-tool']),
                ('timeout', [sys.executable, '-c', 'import time; time.sleep(10)']),
            ):
                with self.subTest(name=name), self.assertRaises(ReportError):
                    _ = scanner.execute(name, argv)
                for suffix in ('.stdout', '.stderr', '.execution.json'):
                    self.assertTrue((root / (name + suffix)).is_file())

    def test_scanner_nonzero_is_preserved_for_parser(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scanner = Scanner(root, root)
            text, code = scanner.execute(
                'findings', [sys.executable, '-c', 'print("finding"); exit(1)']
            )
            self.assertEqual((text.strip(), code), ('finding', 1))
            with self.assertRaises(ReportError):
                scanner.version(
                    'wrong', [sys.executable, '-c', 'print("tool 9.0")'], r'^tool 1\.0$'
                )

    def test_version_and_report_path_validation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            scanner = Scanner(root, root)
            scanner.version(
                'fixture',
                [sys.executable, '-c', 'print("tool 1.0")'],
                r'^tool 1\.0\s*$',
            )
            with self.assertRaises(ReportError):
                _ = scanner.execute('../escape', [sys.executable, '--version'])


class RetainedVersionOutput(unittest.TestCase):
    def test_all_gates_match_retained_pinned_tool_output(self) -> None:
        for name, pattern in VERSION_PATTERNS.items():
            with self.subTest(tool=name):
                text = (
                    Path(__file__).parent / 'fixtures' / ('version-' + name + '.stdout')
                ).read_text()
                self.assertIsNotNone(re.search(pattern, text))
                self.assertIsNone(re.search(pattern, 'unrecognized-tool 9.9\n'))


class EnvironmentPolicy(unittest.TestCase):
    def test_scanner_rejects_output_altering_environment(self) -> None:
        for name in UNSAFE_ENVIRONMENT:
            with self.subTest(name=name), patch.dict('os.environ', {name: 'override'}):
                with self.assertRaises(ReportError):
                    _ = Scanner(Path('.'), Path('.'))
