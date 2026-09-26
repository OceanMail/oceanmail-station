"""Failure-path probes for report-only measurement, not product tests."""

import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location(
    'measure', Path(__file__).with_name('measure.py')
)
measure = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(measure)


class MeasurementFailures(unittest.TestCase):
    def execute(self, argv, kind='command', timeout=2):
        with tempfile.TemporaryDirectory() as directory:
            out = Path(directory)
            result = measure.run(argv, out, out, 'probe', timeout)
            result = measure.interpret(result, out, kind)
            self.assertTrue((out / 'probe.stdout').exists())
            self.assertTrue((out / 'probe.stderr').exists())
            self.assertEqual(result['argv'], argv)
            return result

    def report(self, data, kind, rc=0):
        return self.execute(
            [
                sys.executable,
                '-c',
                'import sys; print(sys.argv[1]); sys.exit(int(sys.argv[2]))',
                json.dumps(data),
                str(rc),
            ],
            kind,
        )

    def test_missing_tool_is_not_zero_findings(self):
        r = self.execute(['/no/such/oceanmail-measurement-tool'])
        self.assertEqual(r['assessment'], 'MISSING_OR_SETUP_ERROR')
        self.assertNotIn('metrics', r)

    def test_timeout_retains_output_and_does_not_pass(self):
        r = self.execute(
            [
                sys.executable,
                '-c',
                'import time; print("started", flush=True); time.sleep(20)',
            ],
            timeout=0.1,
        )
        self.assertEqual(r['assessment'], 'TIMEOUT')
        self.assertEqual(r['exit_code'], 124)

    def test_malformed_json_does_not_become_zero(self):
        r = self.execute([sys.executable, '-c', 'print("{broken")'], 'ruff')
        self.assertEqual(r['assessment'], 'PARSER_OR_EXECUTION_ERROR')
        self.assertIsNone(r['metrics'])

    def test_wrong_schema_does_not_become_zero(self):
        self.assertEqual(
            self.report({}, 'shellcheck')['assessment'], 'PARSER_OR_EXECUTION_ERROR'
        )

    def test_nonzero_findings_are_distinct_from_tool_failure(self):
        finding = [{'code': 'F401'}]
        self.assertEqual(self.report(finding, 'ruff', 1)['assessment'], 'FINDINGS')
        self.assertEqual(
            self.report(finding, 'ruff', 2)['assessment'], 'PARSER_OR_EXECUTION_ERROR'
        )
        self.assertEqual(
            self.report([], 'ruff', 1)['assessment'], 'PARSER_OR_EXECUTION_ERROR'
        )
        self.assertEqual(self.report([], 'ruff')['assessment'], 'COMPLETE')

    def test_docker_parse_failure_is_partial_even_with_findings(self):
        r = self.report([{'code': 'DL1000'}, {'code': 'DL3008'}], 'hadolint', 1)
        self.assertEqual(r['assessment'], 'PARTIAL_OR_COMPILER_ERROR')
        self.assertEqual(r['metrics']['findings'], 2)

    def test_partial_semgrep_keeps_findings_without_claiming_completion(self):
        data = {
            'results': [{'extra': {'severity': 'WARNING'}}],
            'errors': [{'type': 'ParseError'}],
            'paths': {'scanned': ['src/lib.rs']},
        }
        r = self.report(data, 'semgrep', 1)
        self.assertEqual(r['assessment'], 'PARTIAL_OR_COMPILER_ERROR')
        self.assertEqual(r['metrics']['findings'], 1)

    def test_nonzero_empty_security_reports_are_not_clean(self):
        scan = {'results': [], 'errors': [], 'paths': {'scanned': ['src/lib.rs']}}
        self.assertEqual(
            self.report(scan, 'semgrep', 1)['assessment'], 'PARSER_OR_EXECUTION_ERROR'
        )
        audit = {'database': {}, 'vulnerabilities': {'list': [], 'count': 0}}
        self.assertEqual(
            self.report(audit, 'audit', 1)['assessment'], 'PARSER_OR_EXECUTION_ERROR'
        )

    def test_empty_semgrep_scan_is_partial(self):
        r = self.report(
            {'results': [], 'errors': [], 'paths': {'scanned': []}}, 'semgrep'
        )
        self.assertEqual(r['assessment'], 'PARTIAL_OR_COMPILER_ERROR')

    def test_cargo_compiler_failure_cannot_be_lint_debt(self):
        text = '\n'.join(
            json.dumps(x)
            for x in [
                {
                    'reason': 'compiler-message',
                    'message': {'level': 'error', 'code': {'code': 'E0308'}},
                },
                {'reason': 'build-finished', 'success': False},
            ]
        )
        parsed = measure.parse('cargo', text, '', 101)
        self.assertTrue(parsed['partial'])
        self.assertEqual(parsed['compiler_errors'], 1)
        with self.assertRaises(ValueError):
            measure.parse('cargo', text.splitlines()[0], '', 0)

    def test_rust_test_identity_mismatch_is_error(self):
        with self.assertRaises(ValueError):
            measure.parse(
                'rust-tests', 'test result: ok. 2 passed; 0 failed; 0 ignored;', '', 0
            )

    def test_zero_tests_are_explicit(self):
        self.assertTrue(
            measure.parse(
                'rust-tests', 'test result: ok. 0 passed; 0 failed; 0 ignored;', '', 0
            )['zero_tests']
        )

    def test_failed_test_is_not_setup_failure(self):
        text = 'test auth::denied ... FAILED\ntest result: FAILED. 0 passed; 1 failed; 0 ignored;'
        self.assertEqual(measure.parse('rust-tests', text, '', 101)['findings'], 1)
        with self.assertRaises(ValueError):
            measure.parse('rust-tests', '', 'could not compile', 101)

    def test_audit_network_error_is_unknown(self):
        self.assertEqual(
            self.report({'error': 'network'}, 'audit', 1)['assessment'],
            'PARSER_OR_EXECUTION_ERROR',
        )

    def test_skipped_dependency_is_partial(self):
        data = {'dependencies': [{'name': 'unknown', 'skip_reason': 'not found'}]}
        self.assertEqual(
            self.report(data, 'pip-audit')['assessment'], 'PARTIAL_OR_COMPILER_ERROR'
        )

    def test_coverage_missing_owned_file_is_retained(self):
        with tempfile.TemporaryDirectory() as directory:
            xml = Path(directory) / 'coverage.xml'
            xml.write_text(
                '<coverage><class filename="src/lib.rs"><lines><line number="1" hits="0"/></lines></class></coverage>'
            )
            data = measure.coverage(xml, ['src/lib.rs', 'src/main.rs'])
            self.assertEqual(data['missing_owned_files'], ['src/main.rs'])
            self.assertEqual(data['zero_hit_files'], ['src/lib.rs'])
            self.assertEqual(data['per_file']['src/lib.rs']['percent'], 0)

    def test_coverage_empty_or_escaping_cannot_pass(self):
        with tempfile.TemporaryDirectory() as directory:
            xml = Path(directory) / 'coverage.xml'
            for content in [
                '<coverage/>',
                '<coverage><class filename="../outside.rs"/></coverage>',
            ]:
                xml.write_text(content)
                with self.assertRaises(ValueError):
                    measure.coverage(xml, ['src/lib.rs'])


if __name__ == '__main__':
    unittest.main()
