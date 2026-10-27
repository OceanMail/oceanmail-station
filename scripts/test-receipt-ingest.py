#!/usr/bin/env python3
"""Exercise the Phase 4I receipt-ingest boundary without UUCP or Docker."""

import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).with_name("oceanmail-receipt-ingest.sh")
REAL_CAT = shutil.which("cat")


class ReceiptIngest(unittest.TestCase):
    def setUp(self):
        self._directory = tempfile.TemporaryDirectory()
        self.root = Path(self._directory.name)
        self.dest_dir = self.root / "returned-receipts"
        self.dest = self.dest_dir / "receipt.json"

    def tearDown(self):
        self._directory.cleanup()

    def ingest(self, data, path=None):
        env = dict(os.environ, OCEANMAIL_RETURNED_RECEIPT_DIR=str(self.dest_dir))
        if path is not None:
            env["PATH"] = f"{path}:{env['PATH']}"
        return subprocess.run(
            ["bash", str(SCRIPT)],
            input=data,
            capture_output=True,
            env=env,
            timeout=5,
        )

    def leftover_temporaries(self):
        return sorted(p.name for p in self.dest_dir.glob(".receipt.*"))

    def test_stores_artifact_host_readable(self):
        result = self.ingest(b'{"receipt": 1}\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.dest.read_bytes(), b'{"receipt": 1}\n')
        self.assertEqual(stat.S_IMODE(self.dest.stat().st_mode), 0o644)
        self.assertEqual(self.leftover_temporaries(), [])

    def test_existing_destination_is_refused_unchanged(self):
        self.dest_dir.mkdir()
        self.dest.write_bytes(b"first\n")
        result = self.ingest(b"second\n")
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual(self.dest.read_bytes(), b"first\n")

    def test_empty_artifact_is_refused(self):
        result = self.ingest(b"")
        self.assertEqual(result.returncode, 65, result.stderr)
        self.assertFalse(self.dest.exists())
        self.assertEqual(self.leftover_temporaries(), [])

    def test_concurrent_winner_is_not_overwritten(self):
        # Deterministically publish a concurrent ingest's receipt AFTER the
        # existence check passes and while this invocation reads its input.
        shim = self.root / "bin"
        shim.mkdir()
        (shim / "cat").write_text(
            "#!/bin/bash\n"
            f'printf "winner\\n" > "{self.dest}"\n'
            f'exec "{REAL_CAT}" "$@"\n'
        )
        (shim / "cat").chmod(0o755)
        result = self.ingest(b"loser\n", path=shim)
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual(self.dest.read_bytes(), b"winner\n")
        self.assertEqual(self.leftover_temporaries(), [])

    def test_destination_directory_is_not_written_into(self):
        # A directory at the destination path must be refused, not receive
        # the artifact inside it.
        self.dest.mkdir(parents=True)
        result = self.ingest(b"artifact\n")
        self.assertEqual(result.returncode, 73, result.stderr)
        self.assertEqual(list(self.dest.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
