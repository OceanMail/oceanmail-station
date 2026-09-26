"""Unknown audit output and inherited scanner controls cannot produce clean scans."""

from datetime import datetime, timedelta, timezone
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

from diagnostics import ReportError
from execution_policy import environment, audit_completed, reject_external_cargo_config


class ExecutionPolicy(unittest.TestCase):
    def test_environment_drops_arbitrary_tool_options(self) -> None:
        with (
            tempfile.TemporaryDirectory() as tmp,
            patch.dict(
                'os.environ',
                {
                    'PYTHONPATH': '/untrusted',
                    'CARGO_BUILD_RUSTFLAGS': '-A warnings',
                    'RUSTC': '/untrusted/compiler',
                    'SHELLCHECK_SHELL': 'bash',
                },
            ),
        ):
            result = environment(Path(tmp))
            for key in (
                'PYTHONPATH',
                'CARGO_BUILD_RUSTFLAGS',
                'RUSTC',
                'SHELLCHECK_SHELL',
            ):
                self.assertNotIn(key, result)
            self.assertTrue(Path(result['HOME']).is_dir())

    def test_audit_index_failure_and_partial_stages_rejected(self) -> None:
        now = datetime.now(timezone.utc)
        report = {'vulnerabilities': {'count': 0}, 'warnings': {}}
        clean = (
            'Fetching advisory database from `https://github.com/RustSec/advisory-db.git`\n'
            'Loaded 1271 security advisories (from /private/db)\n'
            'Updating crates.io index\nScanning Cargo.lock for vulnerabilities (81 crate dependencies)\n'
        )
        audit_completed(clean, now, now, report)
        for stderr in (
            '',
            clean.replace('Updating crates.io index\n', ''),
            clean + "warning: couldn't update crates.io index\n",
            clean + "error: couldn't check if the package is yanked\n",
        ):
            with self.subTest(stderr=stderr), self.assertRaises(ReportError):
                audit_completed(stderr, now, now, report)
        with self.assertRaises(ReportError):
            audit_completed(clean, now, now + timedelta(hours=1), report)

    def test_parent_cargo_config_is_rejected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / 'repo').mkdir()
            (root / '.cargo').mkdir()
            _ = (root / '.cargo/config.toml').write_text(
                '[build]\nrustflags=["-A", "warnings"]\n'
            )
            with self.assertRaises(ReportError):
                reject_external_cargo_config(root / 'repo')
