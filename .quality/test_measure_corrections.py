"""Regression probes for #55 using the report-only runner's public boundary."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest

from suppression_inventory import inventory, unsuppress_shell
import measure


class MeasurementCorrections(unittest.TestCase):
    def test_real_bash_syntax_error_is_a_finding(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'broken.sh'
            _ = source.write_text('if then\n')
            run = subprocess.run(
                ['bash', '-n', str(source)], text=True, capture_output=True, check=False
            )
            self.assertEqual(run.returncode, 2)
            parsed = measure.parse(
                'shell-syntax', run.stdout, run.stderr, run.returncode
            )
            self.assertNotEqual(parsed['findings'], 0)

    def test_missing_shell_file_is_not_source_finding(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            run = subprocess.run(
                ['bash', '-n', str(Path(directory) / 'absent.sh')],
                text=True,
                capture_output=True,
                check=False,
            )
            with self.assertRaises(ValueError):
                _ = measure.parse(
                    'shell-syntax', run.stdout, run.stderr, run.returncode
                )

    def test_json_malformed_and_nonzero_rejected(self) -> None:
        for text, rc in (('{broken', 0), ('{}', 1)):
            with self.assertRaises(ValueError):
                _ = measure.parse('json', text, '', rc)
        self.assertEqual(
            measure.parse('json', '{"packages": []}', '', 0)['data'], {'packages': []}
        )

    def test_pyright_missing_schema_or_analysis_rejected(self) -> None:
        cases: list[dict[str, object]] = [
            {},
            {'generalDiagnostics': [], 'summary': {}},
            {
                'generalDiagnostics': [],
                'summary': {'filesAnalyzed': 0, 'errorCount': 0},
            },
        ]
        for data in cases:
            with self.assertRaises((ValueError, KeyError)):
                _ = measure.parse('pyright', json.dumps(data), '', 0)

    def test_pyright_nonzero_without_diagnostics_rejected(self) -> None:
        data: dict[str, object] = {
            'generalDiagnostics': [],
            'summary': {'filesAnalyzed': 1, 'errorCount': 0},
        }
        self.assertEqual(
            measure.parse('pyright', json.dumps(data), '', 0)['findings'], 0
        )
        for rc in (1, 2):
            with self.assertRaises(ValueError):
                _ = measure.parse('pyright', json.dumps(data), '', rc)

    def test_formatter_diff_and_setup_error_are_distinct(self) -> None:
        self.assertEqual(measure.parse('fmt', '', '', 0)['findings'], 0)
        self.assertEqual(
            measure.parse('fmt', 'Diff in src/lib.rs:1:\n', '', 1)['findings'], 1
        )
        for stdout, rc in (('', 1), ('Diff in src/lib.rs:1:\n', 2)):
            with self.assertRaises(ValueError):
                _ = measure.parse('fmt', stdout, 'tool failed', rc)

    def test_suppression_inventory_ignores_strings_and_own_regex(self) -> None:
        source = 'pattern = r"#.*noqa|shellcheck disable|#.*type: ignore"\n'
        self.assertEqual(inventory('measure.py', source), [])
        self.assertEqual(inventory('sample.py', 's = "# noqa: F401"\n'), [])
        self.assertEqual(inventory('sample.py', 's = """\n# noqa\n"""\n'), [])

    def test_real_python_directives_recorded(self) -> None:
        for directive in (
            '# noqa: F401',
            '# type: ignore[attr-defined]',
            '# pyright: ignore[reportArgumentType]',
            '# nosemgrep',
        ):
            sites = inventory('sample.py', 'x = 1  ' + directive + '\n')
            self.assertEqual(len(sites), 1)
            self.assertEqual(sites[0]['line'], 1)
            self.assertEqual(sites[0]['classification'], 'python-comment-directive')

    def test_shell_disable_after_other_options_is_inventoried_and_removed(self) -> None:
        source = '# shellcheck shell=bash disable=SC2086,SC2154\necho $x\n'
        self.assertEqual(len(inventory('a.sh', source)), 1)
        result = unsuppress_shell(source)
        self.assertNotIn('disable=', result)
        self.assertIn('shell=bash', result)
        self.assertEqual(result.splitlines()[1:], source.splitlines()[1:])
        self.assertEqual(len(result.splitlines()), len(source.splitlines()))
        self.assertEqual(unsuppress_shell(result), result)
        self.assertEqual(
            unsuppress_shell('# shellcheck disable=SC2086\necho $x\n'),
            '# measurement: native disable removed\necho $x\n',
        )

    def test_other_language_matches_explicitly_unverified(self) -> None:
        sites = inventory('a.sh', '# shellcheck disable=SC1091\n')
        self.assertEqual(len(sites), 1)
        self.assertEqual(sites[0]['classification'], 'unverified-language-candidate')
        self.assertEqual(len(inventory('a.rs', '#![allow(dead_code)]\n')), 1)


if __name__ == '__main__':
    _ = unittest.main()
