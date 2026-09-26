"""Tool output paths must match owned, unchanged repository files."""

from pathlib import Path
import tempfile
import unittest

import diagnostics as d


class ToolPaths(unittest.TestCase):
    def test_absolute_and_relative_paths_have_same_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / 'a.py'
            _ = source.write_text('x = 1\n')
            owned = {'a.py': 'x = 1\n'}
            self.assertEqual(d.owned_tool_path(str(source), root, owned), 'a.py')
            self.assertEqual(d.owned_tool_path('a.py', root, owned), 'a.py')

    def test_escape_alias_missing_and_changed_sources_fail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            _ = (root / 'a.py').write_text('x = 1\n')
            (root / 'alias.py').symlink_to(root / 'a.py')
            owned = {'a.py': 'x = 1\n', 'alias.py': 'x = 1\n', 'missing.py': ''}
            for name in (
                '../a.py',
                '/outside/a.py',
                './a.py',
                'alias.py',
                'missing.py',
                'other.py',
            ):
                with self.subTest(name=name), self.assertRaises(d.ReportError):
                    _ = d.owned_tool_path(name, root, owned)
            _ = (root / 'a.py').write_text('x = 2\n')
            with self.assertRaises(d.ReportError):
                _ = d.owned_tool_path('a.py', root, owned)


if __name__ == '__main__':
    _ = unittest.main()
