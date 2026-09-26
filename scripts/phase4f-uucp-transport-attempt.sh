#!/usr/bin/env bash
# OceanMail Station 0.2 — Phase 4F Taylor UUCP caller-attempt evidence
#
# Reuses the accepted Phase 4E deterministic Postfix -> exact UUCP-job setup,
# then starts one real Taylor uucico caller attempt while no HERMES/Mercury link
# service exists. The exact mapped UUCP job must remain queued. No physical
# radio or simulated RF link is used.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$REPO_ROOT/scripts/phase4e-postfix-uucp-correlation.sh"
RUNTIME_COPY="$(mktemp "$REPO_ROOT/scripts/.phase4f-runtime.XXXXXX.sh")"

cleanup_runtime() {
    rm -f "$RUNTIME_COPY"
}
trap cleanup_runtime EXIT

python3 - "$SOURCE" "$RUNTIME_COPY" <<'PY'
from pathlib import Path
import sys

src_path = Path(sys.argv[1])
dst_path = Path(sys.argv[2])
src = src_path.read_text()

replacements = {
    '# OceanMail Station 0.2 — Phase 4E deterministic Postfix -> Taylor UUCP correlation\n':
        '# OceanMail Station 0.2 — Phase 4F Taylor UUCP transport-attempt evidence\n',
    '# Acceptance stops once one known Postfix message is durably mapped to the exact\n# Taylor UUCP crmail job created by HERMES uuxcomp. It deliberately does NOT run\n# uucico, Mercury, a simulated constrained link, or physical radio hardware.\n':
        '# Acceptance first establishes the proven Phase 4E Postfix -> UUCP mapping,\n# then starts one Taylor uucico caller attempt. No uucpd, Mercury, simulated RF,\n# or physical radio link is started in this Phase 4F harness.\n',
    'RUN_DIR="$LOG_BASE/phase4e-postfix-uucp-correlation-$RUN_ID"\n':
        'RUN_DIR="$LOG_BASE/phase4f-uucp-transport-attempt-$RUN_ID"\n',
    'POSTFIX_NAME="${POSTFIX_NAME:-oceanmail-phase4e-postfix}"\n':
        'POSTFIX_NAME="${POSTFIX_NAME:-oceanmail-phase4f-postfix}"\n',
    'PORT="${PORT:-18084}"\n':
        'PORT="${PORT:-18085}"\n',
    'MESSAGE_ID="<phase4e-$RUN_ID@stationa.test>"\n':
        'MESSAGE_ID="<phase4f-$RUN_ID@stationa.test>"\n',
    'BODY_TOKEN="OceanMail-Phase4E-$RUN_ID-body-check"\n':
        'BODY_TOKEN="OceanMail-Phase4F-$RUN_ID-body-check"\n',
    'WRAPPER_CONTAINER_PATH="/opt/oceanmail/oceanmail-uuxcomp-correlator.sh"\n':
        'WRAPPER_CONTAINER_PATH="/opt/oceanmail/oceanmail-uuxcomp-correlator.sh"\n'
        'ATTEMPT_WRAPPER_CONTAINER_PATH="/opt/oceanmail/oceanmail-uucico-attempt.sh"\n',
    "printf 'Not started by this test: uucico, Mercury, constrained-link transfer, physical radio\\n'\n":
        "printf 'Phase 4F later starts Taylor uucico only; no uucpd, Mercury, simulated RF, or physical radio\\n'\n",
    '    -v "$REPO_ROOT/scripts/oceanmail-uuxcomp-correlator.sh:$WRAPPER_CONTAINER_PATH:ro" \\\n':
        '    -v "$REPO_ROOT/scripts/oceanmail-uuxcomp-correlator.sh:$WRAPPER_CONTAINER_PATH:ro" \\\n'
        '    -v "$REPO_ROOT/scripts/oceanmail-uucico-attempt.sh:$ATTEMPT_WRAPPER_CONTAINER_PATH:ro" \\\n',
    "    'test -x /usr/local/bin/uuxcomp && test -x /usr/bin/uux && test -x /usr/bin/uustat && test -x /opt/oceanmail/oceanmail-uucp-evidence && test -r /opt/oceanmail/oceanmail-uuxcomp-correlator.sh'\n":
        "    'test -x /usr/local/bin/uuxcomp && test -x /usr/bin/uux && test -x /usr/bin/uustat && test -x /usr/sbin/uucico && test -x /opt/oceanmail/oceanmail-uucp-evidence && test -r /opt/oceanmail/oceanmail-uuxcomp-correlator.sh && test -r /opt/oceanmail/oceanmail-uucico-attempt.sh'\n",
    '        export OCEANMAIL_STATION_NAME="phase4e-postfix-uucp-correlation"\n':
        '        export OCEANMAIL_STATION_NAME="phase4f-uucp-transport-attempt"\n',
}

for old, new in replacements.items():
    if old not in src:
        raise SystemExit(f"ERROR: expected Phase 4E source fragment not found: {old!r}")
    src = src.replace(old, new, 1)

marker = 'section "Phase 4E result"\n'
if marker not in src:
    raise SystemExit('ERROR: Phase 4E result marker not found')
src = src.split(marker, 1)[0]

src += r'''section "Phase 4F: start one real Taylor uucico caller attempt"
UUCP_JOB_ID="$(python3 - "$RUN_DIR/uucp-evidence-after-restart.json" <<'PYJOB'
import json, pathlib, sys
j=json.loads(pathlib.Path(sys.argv[1]).read_text())["jobs"]
assert len(j) == 1, j
print(j[0]["uucp_job_id"])
PYJOB
)"
ATTEMPT_ID="$(cat /proc/sys/kernel/random/uuid)"
printf 'Mapped UUCP job before attempt: %s\n' "$UUCP_JOB_ID"
printf 'Attempt ID: %s\n' "$ATTEMPT_ID"

docker exec -d \
    -e "OCEANMAIL_ATTEMPT_ID=$ATTEMPT_ID" \
    "$POSTFIX_NAME" \
    /bin/bash "$ATTEMPT_WRAPPER_CONTAINER_PATH" \
        /state/station.db \
        "$RECORDER_CONTAINER_PATH" \
        stationb \
        /evidence/uucico-attempt.log \
        -D -S stationb

SNAPSHOT_READY=0
for _ in $(seq 1 60); do
    "$REPO_ROOT/target/debug/oceanmail-uucp-evidence" list --state-db "$STATE_DB" \
        >"$RUN_DIR/uucp-attempt-running.json" 2>/dev/null || true
    if python3 - "$RUN_DIR/uucp-attempt-running.json" "$ATTEMPT_ID" "$UUCP_JOB_ID" <<'PYATT' 2>/dev/null
import json, pathlib, sys
p, attempt_id, job_id = sys.argv[1:]
d=json.loads(pathlib.Path(p).read_text())
a=[x for x in d.get("attempts",[]) if x["attempt_id"] == attempt_id]
aj=[x for x in d.get("attempt_jobs",[]) if x["attempt_id"] == attempt_id]
e=[x["event_type"] for x in d.get("attempt_events",[]) if x["attempt_id"] == attempt_id]
ok=(len(a)==1 and len(aj)==1 and aj[0]["uucp_job_id"]==job_id and
    aj[0]["relationship"]=="queued_at_attempt_start" and
    "uucico_attempt_started" in e and "queued_job_snapshot_recorded" in e)
raise SystemExit(0 if ok else 1)
PYATT
    then
        SNAPSHOT_READY=1
        break
    fi
    sleep 0.25
done
[[ "$SNAPSHOT_READY" -eq 1 ]] || {
    echo 'FAIL: system-level uucico attempt and queued-job snapshot were not persisted' >&2
    cat "$RUN_DIR/a/evidence/uucico-attempt.log" >&2 2>/dev/null || true
    exit 1
}
printf 'PASS: exact mapped job recorded as queued when the system-level attempt began\n'
printf 'SEMANTIC: queued_at_attempt_start does not claim this job transmitted bytes\n'

section "Ensure the no-link caller attempt finishes"
# No uucpd or Mercury process is running in this Phase 4F harness. uucico may
# fail immediately. If it is still waiting after the snapshot is persisted,
# terminate only the caller child; the OceanMail wrapper remains to record exit.
docker exec "$POSTFIX_NAME" pkill -TERM -x uucico >/dev/null 2>&1 || true

FINISHED=0
for _ in $(seq 1 80); do
    "$REPO_ROOT/target/debug/oceanmail-uucp-evidence" list --state-db "$STATE_DB" \
        >"$RUN_DIR/uucp-attempt-finished.json" 2>/dev/null || true
    if python3 - "$RUN_DIR/uucp-attempt-finished.json" "$ATTEMPT_ID" <<'PYFIN' 2>/dev/null
import json, pathlib, sys
p, attempt_id = sys.argv[1:]
d=json.loads(pathlib.Path(p).read_text())
a=[x for x in d.get("attempts",[]) if x["attempt_id"] == attempt_id]
e=[x["event_type"] for x in d.get("attempt_events",[]) if x["attempt_id"] == attempt_id]
raise SystemExit(0 if len(a)==1 and a[0]["finished_at_unix"] is not None and "uucico_attempt_finished" in e else 1)
PYFIN
    then
        FINISHED=1
        break
    fi
    sleep 0.25
done
[[ "$FINISHED" -eq 1 ]] || {
    echo 'FAIL: uucico attempt did not persist a finished process state' >&2
    cat "$RUN_DIR/a/evidence/uucico-attempt.log" >&2 2>/dev/null || true
    exit 1
}

# The exact Taylor job must remain queued after the no-link attempt.
docker exec "$POSTFIX_NAME" /usr/bin/uustat -a >"$RUN_DIR/uustat-after-failed-attempt.txt" 2>&1 || true
grep -F "$UUCP_JOB_ID" "$RUN_DIR/uustat-after-failed-attempt.txt" >/dev/null || {
    echo 'FAIL: exact UUCP job disappeared after no-link attempt' >&2
    cat "$RUN_DIR/uustat-after-failed-attempt.txt" >&2
    exit 1
}

curl -fsS "http://$BIND/api/v1/queues/outbound/history" >"$RUN_DIR/history-after-failed-attempt.json"
python3 - \
    "$RUN_DIR/uucp-attempt-finished.json" \
    "$RUN_DIR/history-after-failed-attempt.json" \
    "$ATTEMPT_ID" \
    "$UUCP_JOB_ID" <<'PYVERIFY'
import json, pathlib, sys
attempt_path, history_path, attempt_id, job_id = sys.argv[1:]
d=json.loads(pathlib.Path(attempt_path).read_text())
h=json.loads(pathlib.Path(history_path).read_text())
a=[x for x in d["attempts"] if x["attempt_id"] == attempt_id]
assert len(a)==1, a
assert a[0]["remote_system"] == "stationb", a[0]
assert a[0]["adapter"] == "taylor-uucico", a[0]
assert a[0]["finished_at_unix"] is not None, a[0]
assert a[0]["process_exit_code"] is not None, a[0]
aj=[x for x in d["attempt_jobs"] if x["attempt_id"] == attempt_id]
assert len(aj)==1 and aj[0]["uucp_job_id"] == job_id, aj
assert aj[0]["relationship"] == "queued_at_attempt_start", aj
et=[x["event_type"] for x in d["attempt_events"] if x["attempt_id"] == attempt_id]
assert et.count("uucico_attempt_started") == 1, et
assert et.count("queued_job_snapshot_recorded") == 1, et
assert et.count("uucico_attempt_finished") == 1, et
assert "transport_progress_observed" not in et, et
outbound=[x["event_type"] for x in h["events"]]
assert not any(any(word in t for word in ("transmitted","delivered","received","acknowledged")) for t in outbound), outbound
print(f"PASS: caller attempt finished with process exit {a[0]['process_exit_code']} / {a[0]['process_outcome']}")
print("PASS: exact UUCP job remains queued after the no-link caller attempt")
print("PASS: no transport-progress or delivery claim was fabricated")
PYVERIFY

section "Restart Station and prove Phase 4F attempt evidence durability"
BEFORE_SHA="$(sha256sum "$RUN_DIR/uucp-attempt-finished.json" | awk '{print $1}')"
stop_service
start_service "$RUN_DIR/station-service-after-attempt-restart.log"
"$REPO_ROOT/target/debug/oceanmail-uucp-evidence" list --state-db "$STATE_DB" \
    >"$RUN_DIR/uucp-attempt-after-restart.json"
AFTER_SHA="$(sha256sum "$RUN_DIR/uucp-attempt-after-restart.json" | awk '{print $1}')"
[[ "$BEFORE_SHA" == "$AFTER_SHA" ]] || {
    echo 'FAIL: Phase 4F UUCP attempt evidence changed across Station restart' >&2
    diff -u "$RUN_DIR/uucp-attempt-finished.json" "$RUN_DIR/uucp-attempt-after-restart.json" >&2 || true
    exit 1
}
printf 'PASS: attempt lifecycle and queued-job snapshot survive Station restart unchanged\n'

section "Phase 4F result"
printf 'PASS: durable Taylor UUCP caller-attempt evidence proven without radio hardware\n'
printf 'Postfix queue ID: %s\n' "$POSTFIX_QUEUE_ID"
printf 'Station observation ID: %s\n' "$OBSERVATION_ID"
printf 'Taylor UUCP job: stationb/%s\n' "$UUCP_JOB_ID"
printf 'UUCP attempt ID: %s\n' "$ATTEMPT_ID"
printf 'Exact UUCP job remains queued after no-link attempt\n'
printf 'No HERMES uucpd, Mercury, simulated RF, or physical radio transport was started\n'
printf 'Next evidence boundary: simulated HERMES/Mercury link-session/progress evidence\n'
printf 'Evidence directory: %s\n' "$RUN_DIR"
'''

dst_path.write_text(src)
PY

chmod +x "$RUNTIME_COPY"
bash -n "$RUNTIME_COPY" || {
    echo "ERROR: generated Phase 4F runtime script failed bash syntax validation" >&2
    exit 2
}

set +e
bash "$RUNTIME_COPY"
RC=$?
set -e
exit "$RC"
