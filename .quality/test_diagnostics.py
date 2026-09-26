"""Adversarial fixtures for the S3a comparison foundation."""

from collections import Counter
from datetime import date
import json
import unittest

import diagnostics as d


SOURCES = {
    'src/a.rs': 'fn main() {\n    risky();\n}\n',
    'a.py': 'x = 1\n',
    'a.sh': 'echo $x\n',
}


def cargo_record(level: str = 'warning') -> dict[str, object]:
    return {
        'reason': 'compiler-message',
        'message': {
            'level': level,
            'message': 'use other error',
            'code': {'code': 'clippy::io_other_error'},
            'spans': [
                {
                    'is_primary': True,
                    'file_name': 'src/a.rs',
                    'line_start': 2,
                    'line_end': 2,
                }
            ],
        },
    }


def cargo(*records: dict[str, object], success: bool = True) -> str:
    return '\n'.join(
        json.dumps(x)
        for x in (*records, {'reason': 'build-finished', 'success': success})
    )


def shell(code: int = 2086, filename: str = 'a.sh') -> str:
    return json.dumps(
        {
            'comments': [
                {
                    'code': code,
                    'file': filename,
                    'line': 1,
                    'endLine': 1,
                    'message': 'quote expansion',
                }
            ]
        }
    )


def types(
    rule: str = 'reportAssignmentType', filename: str = 'a.py'
) -> dict[str, object]:
    return {
        'summary': {
            'filesAnalyzed': 1,
            'errorCount': 1,
            'warningCount': 0,
            'informationCount': 0,
        },
        'generalDiagnostics': [
            {
                'file': filename,
                'rule': rule,
                'severity': 'error',
                'message': 'incompatible type',
                'range': {'start': {'line': 0}, 'end': {'line': 0}},
            }
        ],
    }


def audit() -> dict[str, object]:
    return {
        'database': {'last-commit': 'a' * 40, 'last-updated': '2026-09-25'},
        'settings': {
            'ignore': [],
            'severity': None,
            'target_arch': [],
            'target_os': [],
            'informational_warnings': ['unmaintained', 'unsound', 'notice'],
        },
        'vulnerabilities': {
            'count': 1,
            'list': [
                {
                    'advisory': {'id': 'RUSTSEC-fixture'},
                    'package': {'name': 'p', 'version': '1.0'},
                }
            ],
        },
        'warnings': {},
    }


def entry(finding: d.Finding, reason: str = 'tracked debt') -> d.ExceptionEntry:
    return d.ExceptionEntry(
        finding, 'https://github.com/OceanMail/oceanmail-station/issues/58', reason
    )


class Normalizers(unittest.TestCase):
    def test_sc1087_is_retained_but_parser_failures_are_rejected(self) -> None:
        self.assertEqual(d.shellcheck(shell(1087), 1, SOURCES)[0].rule, "SC1087")
        for code in (1009, 1072, 1091):
            with self.subTest(code=code), self.assertRaises(d.ReportError):
                _ = d.shellcheck(shell(code), 1, SOURCES)

    def test_all_audit_warning_categories(self) -> None:
        for category in ('yanked', 'unmaintained', 'unsound', 'notice'):
            with self.subTest(category=category):
                report = audit()
                report['vulnerabilities'] = {'count': 0, 'list': []}
                report['warnings'] = {
                    category: [
                        {
                            'kind': category,
                            'package': {'name': 'p', 'version': '1.0'},
                            'advisory': None
                            if category == 'yanked'
                            else {'id': 'RUSTSEC-fixture'},
                            'affected': None,
                            'versions': None,
                        }
                    ]
                }
                findings = d.cargo_audit(
                    json.dumps(report), 0, {('p', '1.0'): ['root>p']}
                )
                self.assertEqual(len(findings), 1)
                self.assertEqual(
                    findings[0].rule,
                    'yanked' if category == 'yanked' else 'RUSTSEC-fixture',
                )

    def test_audit_warning_kind_mismatch_is_rejected(self) -> None:
        report = audit()
        report['warnings'] = {
            'yanked': [
                {
                    'kind': 'notice',
                    'advisory': None,
                    'package': {'name': 'p', 'version': '1.0'},
                }
            ]
        }
        with self.assertRaises(d.ReportError):
            _ = d.cargo_audit(json.dumps(report), 0, {('p', '1.0'): ['root>p']})

    def test_malformed_warning_variants_are_rejected(self) -> None:
        variants: tuple[dict[str, object], ...] = (
            {'unknown': []},
            {'notice': {}},
            {
                'notice': [
                    {
                        'kind': 'notice',
                        'advisory': None,
                        'package': {'name': 'p', 'version': '1.0'},
                    }
                ]
            },
            {
                'yanked': [
                    {
                        'kind': 'yanked',
                        'advisory': {'id': 'RUSTSEC-fixture'},
                        'package': {'name': 'p', 'version': '1.0'},
                    }
                ]
            },
        )
        for warnings in variants:
            report = audit()
            report['warnings'] = warnings
            with self.subTest(warnings=warnings), self.assertRaises(d.ReportError):
                _ = d.cargo_audit(json.dumps(report), 0, {('p', '1.0'): ['root>p']})

    def test_cached_audit_requires_independent_database_provenance(self) -> None:
        report = audit()
        report['database'] = {'last-commit': None, 'last-updated': None}
        with self.assertRaises(d.ReportError):
            _ = d.cargo_audit(json.dumps(report), 1, {('p', '1.0'): ['root>p']})
        findings = d.cargo_audit(
            json.dumps(report),
            1,
            {('p', '1.0'): ['root>p']},
            database_provenance={'last-commit': 'a' * 40, 'last-updated': '2026-09-25'},
        )
        self.assertEqual(len(findings), 1)

    def test_audit_hidden_filters_are_rejected(self) -> None:
        for key, value in [
            ('ignore', ['RUSTSEC-fixture']),
            ('severity', 'high'),
            ('target_os', ['linux']),
            ('informational_warnings', []),
        ]:
            report = audit()
            d.obj(report['settings'])[key] = value
            with self.subTest(key=key), self.assertRaises(d.ReportError):
                _ = d.cargo_audit(json.dumps(report), 1, {('p', '1.0'): ['root>p']})

    def test_json_rejects_duplicate_keys_and_nonfinite_values(self) -> None:
        for text in ('{"x": 1, "x": 2}', 'NaN', 'Infinity', '{broken'):
            with self.subTest(text=text), self.assertRaises(d.ReportError):
                _ = d.decode(text)

    def test_path_canonical_and_no_escape(self) -> None:
        for name in ('../a', '/a', './a', 'a//b', 'C:/a', 'a\\b', '.', 'a/../b'):
            with self.subTest(name=name), self.assertRaises(d.ReportError):
                _ = d.path(name)
        self.assertEqual(d.path('dir/space name.py'), 'dir/space name.py')

    def test_clippy_keeps_repeated_target_emissions(self) -> None:
        actual = d.clippy(cargo(cargo_record(), cargo_record()), 0, SOURCES)
        self.assertEqual(len(actual), 2)
        self.assertEqual(actual[0], actual[1])

    def test_compiler_errors_always_rejected(self) -> None:
        for report, rc in (
            (cargo(cargo_record('error')), 0),
            (cargo(success=False), 101),
            (cargo(), 101),
            ('', 0),
            (json.dumps(cargo_record()), 0),
        ):
            with self.subTest(report=report), self.assertRaises(d.ReportError):
                _ = d.clippy(report, rc, SOURCES)

    def test_ambiguous_or_unmapped_clippy_span_is_not_debt(self) -> None:
        for spans in (
            [],
            [
                {
                    'is_primary': True,
                    'file_name': '../escape',
                    'line_start': 1,
                    'line_end': 1,
                }
            ],
        ):
            record = cargo_record()
            d.obj(record['message'])['spans'] = spans
            with self.assertRaises(d.ReportError):
                _ = d.clippy(cargo(record), 0, SOURCES)

    def test_source_change_invalidates_even_unchanged_diagnostic(self) -> None:
        original = d.clippy(cargo(cargo_record()), 0, SOURCES)[0]
        modified = dict(SOURCES)
        modified['src/a.rs'] += '// changed enclosing context\n'
        new = d.clippy(cargo(cargo_record()), 0, modified)[0]
        self.assertNotEqual(original, new)
        self.assertFalse(d.compare([new], [entry(original)], [entry(original)]).clean)

    def test_shellcheck_complete_findings_and_clean_report(self) -> None:
        self.assertEqual(d.shellcheck('{"comments": []}', 0, SOURCES), [])
        self.assertEqual(d.shellcheck(shell(), 1, SOURCES)[0].rule, 'SC2086')

    def test_shellcheck_parser_errors_and_exit_mismatch_rejected(self) -> None:
        for report, rc in (
            (shell(1073), 1),
            (shell(), 2),
            (shell(), 0),
            ('{"comments": []}', 1),
            ('{}', 0),
            (shell(filename='missing.sh'), 1),
        ):
            with self.subTest(report=report, rc=rc), self.assertRaises(d.ReportError):
                _ = d.shellcheck(report, rc, SOURCES)

    def test_pyright_totals_scope_and_environment(self) -> None:
        self.assertEqual(len(d.pyright(json.dumps(types()), 1, SOURCES, 1)), 1)
        wrong = types()
        d.obj(wrong['summary'])['errorCount'] = 0
        for report, rc, size in (
            (wrong, 1, 1),
            (types(), 1, 2),
            (types('reportMissingImports'), 1, 1),
            (types(), 2, 1),
        ):
            with self.subTest(report=report, rc=rc), self.assertRaises(d.ReportError):
                _ = d.pyright(json.dumps(report), rc, SOURCES, size)

    def test_invalid_source_ranges_and_boolean_counts(self) -> None:
        with self.assertRaises(d.ReportError):
            _ = d.source_finding('x', 'rule', 'a.py', 0, 1, SOURCES, 'detail')
        with self.assertRaises(d.ReportError):
            _ = d.integer(True)

    def test_audit_preserves_each_dependency_path(self) -> None:
        paths = {('p', '1.0'): ['root>p@1.0', 'root>intermediate>p@1.0']}
        findings = d.cargo_audit(json.dumps(audit()), 1, paths)
        self.assertEqual(len(findings), 2)
        self.assertNotEqual(findings[0], findings[1])

    def test_audit_malformed_or_incomplete_is_not_clean(self) -> None:
        wrong_count = audit()
        d.obj(wrong_count['vulnerabilities'])['count'] = 0
        for report, rc, paths in (
            (audit(), 1, {}),
            (wrong_count, 1, {('p', '1.0'): ['p']}),
            ({'error': 'network'}, 1, {}),
            (audit(), 2, {}),
        ):
            with self.subTest(report=report), self.assertRaises(d.ReportError):
                _ = d.cargo_audit(json.dumps(report), rc, paths)


class Ratchet(unittest.TestCase):
    first: d.Finding = d.Finding('clippy', 'rule', 'src/a.rs', 'a' * 64)
    second: d.Finding = d.Finding('clippy', 'rule', 'src/a.rs', 'b' * 64)

    def test_identical_accepted_findings_pass(self) -> None:
        self.assertTrue(
            d.compare([self.first], [entry(self.first)], [entry(self.first)]).clean
        )

    def test_new_violation_and_equal_count_swap_fail(self) -> None:
        for current in ([self.first, self.second], [self.second]):
            self.assertFalse(
                d.compare(current, [entry(self.first)], [entry(self.first)]).clean
            )

    def test_ledger_growth_and_reason_rewrite_rejected(self) -> None:
        for proposed in (
            [entry(self.first), entry(self.second)],
            [entry(self.first, 'new excuse')],
        ):
            with self.assertRaises(d.ReportError):
                _ = d.compare([self.first], [entry(self.first)], proposed)

    def test_multiplicity_not_set_membership(self) -> None:
        result = d.compare(
            [self.first, self.first], [entry(self.first)], [entry(self.first)]
        )
        self.assertEqual(result.new, Counter({self.first: 1}))

    def test_reduction_requires_removing_stale_exception(self) -> None:
        old = [entry(self.first), entry(self.second)]
        self.assertEqual(
            d.compare([self.first], old, old).stale, Counter({self.second: 1})
        )
        self.assertTrue(d.compare([self.first], old, [entry(self.first)]).clean)

    def test_deletion_cannot_pay_for_unrelated_addition(self) -> None:
        result = d.compare([self.second], [entry(self.first)], [])
        self.assertEqual(result.new, Counter({self.second: 1}))

    def test_ledger_schema_and_provenance_required(self) -> None:
        valid = {
            'tool': 'clippy',
            'rule': 'rule',
            'file': 'src/a.rs',
            'fingerprint': 'a' * 64,
            'issue': 'https://github.com/OceanMail/oceanmail-station/issues/58',
            'reason': 'reason',
        }
        self.assertEqual(len(d.ledger(json.dumps({'entries': [valid, valid]}))), 2)
        for key in valid:
            invalid = dict(valid)
            del invalid[key]
            with self.subTest(key=key), self.assertRaises(d.ReportError):
                _ = d.ledger(json.dumps({'entries': [invalid]}))

    def test_advisory_expiration_at_day_boundary(self) -> None:
        details = {'package': 'p', 'version': '1.0', 'path': 'root>p'}
        finding = d.Finding(
            'cargo-audit', 'RUSTSEC-fixture', 'Cargo.lock', d.digest(details)
        )
        companion = {
            'tool': finding.tool,
            'rule': finding.rule,
            'file': finding.file,
            'fingerprint': finding.fingerprint,
            'owner': 'owner',
            'expires': '2026-09-26',
            'created': '2026-09-25',
            'package': 'p',
            'version': '1.0',
            'dependency_path': 'root>p',
        }
        encoded = json.dumps([companion])
        d.check_expiry([entry(finding)], encoded, date(2026, 9, 25))
        with self.assertRaises(d.ReportError):
            d.check_expiry([entry(finding)], encoded, date(2026, 9, 26))
        for bad in ('[]', json.dumps([companion, companion])):
            with self.assertRaises(d.ReportError):
                d.check_expiry([entry(finding)], bad, date(2026, 9, 25))
        with self.assertRaises(d.ReportError):
            d.check_expiry([], encoded, date(2026, 9, 25))


if __name__ == '__main__':
    _ = unittest.main()


class AdvisoryDetails(unittest.TestCase):
    def test_tampered_details_and_overlong_expiry_fail(self) -> None:
        details = {'package': 'p', 'version': '1.0', 'path': 'root>p'}
        finding = d.Finding(
            'cargo-audit', 'RUSTSEC-fixture', 'Cargo.lock', d.digest(details)
        )
        valid = {
            'tool': finding.tool,
            'rule': finding.rule,
            'file': finding.file,
            'fingerprint': finding.fingerprint,
            'owner': 'owner',
            'created': '2026-09-25',
            'expires': '2026-09-26',
            'package': 'p',
            'version': '1.0',
            'dependency_path': 'root>p',
        }
        for key, value in (
            ('package', 'q'),
            ('version', '2.0'),
            ('dependency_path', 'other'),
            ('expires', '2027-01-01'),
            ('created', '2026-09-26'),
        ):
            with self.subTest(key=key), self.assertRaises(d.ReportError):
                d.check_expiry(
                    [entry(finding)],
                    json.dumps([{**valid, key: value}]),
                    date(2026, 9, 25),
                )
