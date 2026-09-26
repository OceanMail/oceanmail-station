"""Missing and fake coverage must not look like complete source instrumentation."""

import unittest

from coverage_guard import validate
from diagnostics import ReportError


def report(
    filename: str = 'src/a.rs', lines: str = '<line number="1" hits="0"/>'
) -> str:
    return f'<coverage><packages><class filename="{filename}"><lines>{lines}</lines></class></packages></coverage>'


class CoverageScope(unittest.TestCase):
    def test_zero_hit_unchanged_source_is_retained(self) -> None:
        root = validate(report(), {'src/a.rs': 'fn a() {}\n'})
        line = root.find('.//line')
        assert line is not None
        self.assertEqual(line.get('hits'), '0')

    def test_missing_never_instrumented_file_and_fake_empty_class_fail(self) -> None:
        with self.assertRaises(ReportError):
            _ = validate(
                report(),
                {'src/a.rs': 'fn a() {}\n', 'src/new.rs': 'fn never_called() {}\n'},
            )
        with self.assertRaises(ReportError):
            _ = validate(report(lines=''), {'src/a.rs': 'fn new_function() {}\n'})

    def test_duplicate_conflicting_out_of_range_and_escaping_rejected(self) -> None:
        for xml in (
            report('../src/a.rs'),
            report('/src/a.rs'),
            report('src/missing.rs'),
            report(lines='<line number="2" hits="1"/>'),
            report(lines='<line number="1" hits="0"/><line number="1" hits="1"/>'),
            report().replace('</packages>', '<class filename="src/a.rs"/></packages>'),
        ):
            with self.subTest(xml=xml), self.assertRaises(ReportError):
                _ = validate(xml, {'src/a.rs': 'fn a() {}\n'})

    def test_prefix_applied_once(self) -> None:
        for name in ('src/a.rs', 'station/src/a.rs'):
            root = validate(
                report(name), {'station/src/a.rs': 'fn a() {}\n'}, prefix='station'
            )
            node = root.find('.//class')
            assert node is not None
            self.assertEqual(node.get('filename'), 'station/src/a.rs')
