#!/usr/bin/env python3
"""Exercise the actual Phase 4I polling block without Docker or a live database."""

import json
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).with_name("phase4i-returned-receipt-evidence.sh").read_text()
BLOCK = SOURCE.split("original_snapshot_ready() {", 1)[1]
BLOCK = (
    "original_snapshot_ready() {"
    + BLOCK.split('if [[ "$SNAPSHOT" -ne 1 ]]; then', 1)[0]
)
READY = {
    "attempts": [
        {"attempt_id": "a", "remote_system": "stationb", "adapter": "taylor-uucico"}
    ],
    "attempt_jobs": [
        {
            "attempt_id": "a",
            "uucp_job_id": "j",
            "observation_id": "o",
            "remote_system": "stationb",
            "relationship": "queued_at_attempt_start",
        }
    ],
    "attempt_events": [
        {"attempt_id": "a", "event_type": "uucico_attempt_started"},
        {
            "attempt_id": "a",
            "event_type": "queued_job_snapshot_recorded",
            "evidence_source": "taylor-uustat",
            "metric_name": "mapped_jobs_queued_at_attempt_start",
            "metric_value": 1,
        },
    ],
}


class SnapshotReadiness(unittest.TestCase):
    def run_gate(self, final, expected, race=True):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "target/debug/oceanmail-uucp-evidence"
            binary.parent.mkdir(parents=True)
            (root / "final.json").write_text(json.dumps(final))
            # Deterministically publish completion AFTER emitting the stale read.
            binary.write_text(
                "#!/bin/bash\n"
                'if [[ ! -f "$RUN_DIR/read-once" ]]; then\n'
                '  touch "$RUN_DIR/read-once"\n'
                + ('  printf "{}\\n"\n' if race else '  cat "$RUN_DIR/final.json"\n')
                + '  printf "0\\n" > "$ORIGINAL_EXEC_RC_FILE"\n'
                'else cat "$RUN_DIR/final.json"; fi\n'
            )
            binary.chmod(0o755)
            script = (
                'set -euo pipefail\n'
                'export RUN_DIR="$1" REPO_ROOT="$1"\n'
                'export ORIGINAL_EXEC_RC_FILE="$1/exit.rc"\n'
                'STATE_DB=unused ATTEMPT_ID=a UUCP_JOB_ID=j OBSERVATION_ID=o\n'
                + BLOCK
                + '\nprintf "%s" "$SNAPSHOT"\n'
            )
            result = subprocess.run(
                ["bash", "-c", script, "test", directory],
                capture_output=True,
                text=True,
                timeout=5,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, str(expected))

    def test_snapshot_committed_between_read_and_exit_check(self):
        self.run_gate(READY, 1)

    def test_exit_without_snapshot_fails_closed(self):
        self.run_gate({}, 0)

    def test_wrong_observation_fails_closed(self):
        wrong = json.loads(json.dumps(READY))
        wrong["attempt_jobs"][0]["observation_id"] = "other"
        self.run_gate(wrong, 0)

    def test_missing_snapshot_event_fails_closed(self):
        wrong = json.loads(json.dumps(READY))
        wrong["attempt_events"].pop()
        self.run_gate(wrong, 0)

    def test_ready_on_first_read(self):
        self.run_gate(READY, 1, race=False)


if __name__ == "__main__":
    unittest.main()
