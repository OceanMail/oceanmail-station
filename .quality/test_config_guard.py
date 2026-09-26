"""Policy guards use immutable fixtures and explicit violation injection."""

from dataclasses import asdict
import json
from pathlib import Path
import tempfile
import unittest

from config_guard import candidates, verify, tests, control
from diagnostics import ReportError
from git_state import GitState
from test_git_state import git, initialize
from suppression_inventory import inventory


def fixture(root: Path) -> str:
    _ = initialize(root)
    (root / '.quality').mkdir()
    _ = (root / '.quality/suppressions.json').write_text('{"entries": []}\n')
    _ = (root / 'pyproject.toml').write_text('[tool.ruff]\n')
    _ = git(root, 'add', '.')
    _ = git(root, 'commit', '-qm', 'policy')
    base = git(root, 'rev-parse', 'HEAD')
    _ = git(root, 'commit', '--allow-empty', '-qm', 'proposal')
    return base


class Configuration(unittest.TestCase):
    def test_prefixed_noqa_comments_are_detected_but_strings_are_not(self) -> None:
        for directive in (
            '# ruff: noqa',
            '#flake8: noqa',
            '# ruff: noqa: F401',
            '# flake8:   noqa',
        ):
            with self.subTest(directive=directive):
                self.assertEqual(len(candidates('a.py', directive + '\n')), 1)
                self.assertEqual(len(inventory('a.py', directive + '\n')), 1)
                source = 'value = ' + repr(directive) + '\n'
                self.assertEqual(candidates('a.py', source), [])
                self.assertEqual(inventory('a.py', source), [])

    def test_unchanged_configuration_and_new_unsuppressed_source_pass(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = fixture(root)
            _ = (root / 'new.py').write_text('new = 1\n')
            _ = git(root, 'add', '.')
            _ = git(root, 'commit', '-qm', 'new source')
            verify(GitState(root, base))

    def test_added_suppression_changed_config_and_deleted_source_fail(self) -> None:
        for change in (
            'suppression',
            'config',
            'delete',
            'skip-alias',
            'pytest-skipif',
        ):
            with (
                self.subTest(change=change),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                base = fixture(root)
                if change == 'suppression':
                    _ = (root / 'a.py').write_text('old = 1  # type: ignore\n')
                elif change == 'config':
                    _ = (root / 'pyproject.toml').write_text(
                        '[tool.ruff]\nexclude=["a.py"]\n'
                    )
                elif change == 'delete':
                    (root / 'a.py').unlink()
                elif change == 'skip-alias':
                    _ = (root / 'a.py').write_text(
                        'from unittest import skip as omit\n'
                    )
                else:
                    _ = (root / 'a.py').write_text(
                        'import pytest\n@pytest.mark.skipif(True)\ndef test_a(): pass\n'
                    )
                _ = git(root, 'add', '-A')
                _ = git(root, 'commit', '-qm', 'injection')
                with self.assertRaises(ReportError):
                    verify(GitState(root, base))

    def test_rewriting_suppressed_statement_does_not_inherit_exception(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _ = fixture(root)
            source = 'old = 1  # noqa: F841\n'
            _ = (root / 'a.py').write_text(source)
            entries = [
                {
                    **asdict(item),
                    'issue': 'https://github.com/OceanMail/oceanmail-station/issues/58',
                    'reason': 'fixture',
                }
                for item in candidates('a.py', source)
            ]
            _ = (root / '.quality/suppressions.json').write_text(
                json.dumps({'entries': entries})
            )
            _ = git(root, 'add', '.')
            _ = git(root, 'commit', '-qm', 'accepted fixture exception')
            base = git(root, 'rev-parse', 'HEAD')
            _ = git(root, 'commit', '--allow-empty', '-qm', 'unchanged proposal')
            verify(GitState(root, base))
            _ = (root / 'a.py').write_text('old = 2  # noqa: F841\n')
            _ = git(root, 'commit', '-qam', 'change suppressed statement')
            with self.assertRaises(ReportError):
                verify(GitState(root, base))

    def test_test_deletion_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _ = fixture(root)
            _ = (root / 'a.py').write_text('def test_preserved(): pass\n')
            _ = git(root, 'commit', '-qam', 'test')
            base = git(root, 'rev-parse', 'HEAD')
            _ = (root / 'a.py').write_text('value = 1\n')
            _ = git(root, 'commit', '-qam', 'delete test')
            with self.assertRaises(ReportError):
                verify(GitState(root, base))

    def test_exception_and_import_based_skips_are_rejected(self) -> None:
        for source in (
            'import unittest\ndef test_a(): raise unittest.SkipTest("missing")\n',
            'from unittest import SkipTest\ndef test_a(): raise SkipTest("missing")\n',
            'from unittest import SkipTest as omit\ndef test_a(): raise omit("missing")\n',
            'import pytest\npytest.importorskip("missing")\n',
            'from pytest import importorskip as omit\nomit("missing")\n',
        ):
            with self.subTest(source=source), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                base = fixture(root)
                _ = (root / 'a.py').write_text(source)
                _ = git(root, 'add', '.')
                _ = git(root, 'commit', '-qm', 'skip injection')
                with self.assertRaises(ReportError):
                    verify(GitState(root, base))

    def test_python_strings_are_not_native_directives(self) -> None:
        self.assertEqual(candidates('a.py', 'x = "# noqa"\n'), [])
        self.assertTrue(
            candidates('a.rs', '#[cfg_attr(feature="x", allow(dead_code))]\nfn a() {}')
        )
        self.assertTrue(candidates('a.sh', '# shellcheck disable=SC2086\necho $x'))


class ReviewRegressions(unittest.TestCase):
    def test_unscanned_script_scope_fails(self) -> None:
        for filename, source, executable in (
            ('script', '#!/bin/sh\necho ok\n', False),
            ('script.bash', 'echo ok\n', False),
            ('binary', 'not a script\n', True),
        ):
            with (
                self.subTest(filename=filename),
                tempfile.TemporaryDirectory() as directory,
            ):
                root = Path(directory)
                base = fixture(root)
                file = root / filename
                _ = file.write_text(source)
                if executable:
                    file.chmod(0o755)
                _ = git(root, 'add', '.')
                _ = git(root, 'commit', '-qm', 'unscanned source')
                with self.assertRaises(ReportError):
                    verify(GitState(root, base))

    def test_rust_test_attributes_and_comments(self) -> None:
        for source in (
            '#[test]\n#[cfg(unix)]\nfn auth() {}',
            '#[test]\n/// explanation\nfn auth() {}',
            '#[tokio::test]\nasync fn auth() {}',
        ):
            self.assertEqual(tests('auth.rs', source), {'auth'})

    def test_multi_key_shell_directive(self) -> None:
        self.assertTrue(
            candidates('a.sh', '# shellcheck shell=bash disable=SC2086\necho $1')
        )

    def test_tool_control_files(self) -> None:
        for filename in (
            'clippy.toml',
            '.clippy.toml',
            'ruff.toml',
            '.ruff.toml',
            'deny.toml',
        ):
            self.assertTrue(control(filename))

    def test_case_and_basedpyright_directives(self) -> None:
        for text in ('# NOQA', '# RUFF: NOQA', '# basedpyright: basic'):
            self.assertTrue(candidates('a.py', text))
