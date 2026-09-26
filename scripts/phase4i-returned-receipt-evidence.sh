#!/usr/bin/env bash
# OceanMail Station 0.2 — Phase 4I returned receipt evidence
#
# Directly derives one runtime harness from the canonical Phase 2B two-station
# HERMES/Mercury mail proof. It proves the original message A->B, then creates a
# compact receipt at B and carries that receipt back B->A as its own Taylor UUCP
# job. Station A records returned receipt state only after the artifact actually
# arrives and resolves its RFC Message-ID to the original local observation/job.
#
# Trust boundary: the returned JSON artifact is deterministic laboratory data.
# It is transported over the real simulated UUCP/HERMES/Mercury path, but it is
# not cryptographically authenticated and must not be labeled production-trusted.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$REPO_ROOT/scripts/phase2b-hermes-compressed-mail.sh"
RUNTIME_COPY="$(mktemp "$REPO_ROOT/scripts/.phase4i-runtime.XXXXXX.sh")"

cleanup_runtime() { rm -f "$RUNTIME_COPY"; }
trap cleanup_runtime EXIT

python3 - "$SOURCE" "$RUNTIME_COPY" <<'PY'
from pathlib import Path
import sys
src_path=Path(sys.argv[1]); dst_path=Path(sys.argv[2]); src=src_path.read_text()
replacements={
'# OceanMail Station 0.2 — Phase 2B HERMES uuxcomp/crmail acceptance\n':'# OceanMail Station 0.2 — Phase 4I returned receipt evidence\n',
'RUN_DIR="$LOG_BASE/phase2b-hermes-mail-$RUN_ID"\n':'RUN_DIR="$LOG_BASE/phase4i-returned-receipt-$RUN_ID"\n',
'A_NAME="oceanmail-mail-a"\nB_NAME="oceanmail-mail-b"\nMESSAGE_ID="<phase2b-$RUN_ID@stationa.test>"\nBODY_TOKEN="OceanMail-Phase2B-$RUN_ID-body-check"\nSUBJECT="OceanMail Phase 2A RFC mail proof"\n':'A_NAME="oceanmail-phase4i-a"\nB_NAME="oceanmail-phase4i-b"\nMESSAGE_ID="<phase4i-$RUN_ID@stationa.test>"\nBODY_TOKEN="OceanMail-Phase4I-$RUN_ID-body-check"\nSUBJECT="OceanMail Phase 4I returned receipt proof"\nPORT="${PORT:-18088}"\nBIND="127.0.0.1:$PORT"\nSTATE_DIR="$RUN_DIR/state"\nSTATE_DB="$STATE_DIR/station.db"\nPOSTQUEUE_ADAPTER="$RUN_DIR/postqueue-real"\nSERVICE_LOG="$RUN_DIR/station-service.log"\nSERVICE_RESTART_LOG="$RUN_DIR/station-service-restart.log"\nSERVICE_PID=""\nWRAPPER_CONTAINER_PATH="/opt/oceanmail/oceanmail-uuxcomp-correlator.sh"\nATTEMPT_WRAPPER_CONTAINER_PATH="/opt/oceanmail/oceanmail-uucico-attempt.sh"\nRECORDER_CONTAINER_PATH="/opt/oceanmail/oceanmail-uucp-evidence"\nRECEIPT_INGEST_MOUNT="/opt/oceanmail/oceanmail-receipt-ingest.sh"\nRECEIPT_INGEST_COMMAND="/usr/local/bin/oceanmail-receipt-ingest"\nRETURNED_RECEIPT_DIR="/evidence/returned-receipts"\nTRUST_STATE="lab_peer_transport_unverified"\n',
'mkdir -p "$RUN_DIR"\n':'mkdir -p "$RUN_DIR" "$STATE_DIR"\nchmod 0777 "$STATE_DIR"\n',
'section "Phase 2B environment"\n':'section "Phase 4I environment"\nprintf \'Station API bind: %s\\n\' "$BIND"\nprintf \'Acceptance boundary: far-side mailbox proof -> compact receipt -> B-to-A constrained return -> origin correlation\\n\'\nprintf \'Receipt trust state: %s (laboratory only; no production signature yet)\\n\' "$TRUST_STATE"\n'}
for old,new in replacements.items():
    if old not in src: raise SystemExit(f"ERROR: expected Phase 2B source fragment not found: {old!r}")
    src=src.replace(old,new,1)
old='''cleanup() {
    docker rm -f "$A_NAME" "$B_NAME" >/dev/null 2>&1 || true
    stop_link
}
trap cleanup EXIT
'''
new='''stop_service() {
    if [[ -n "$SERVICE_PID" ]] && kill -0 "$SERVICE_PID" 2>/dev/null; then
        kill -INT "$SERVICE_PID" 2>/dev/null || true
        for _ in $(seq 1 30); do kill -0 "$SERVICE_PID" 2>/dev/null || break; sleep 0.2; done
        kill -0 "$SERVICE_PID" 2>/dev/null && kill -TERM "$SERVICE_PID" 2>/dev/null || true
        wait "$SERVICE_PID" 2>/dev/null || true
    fi
    SERVICE_PID=""
}
cleanup() { stop_service; docker rm -f "$A_NAME" "$B_NAME" >/dev/null 2>&1 || true; stop_link; }
trap cleanup EXIT
'''
if old not in src: raise SystemExit('ERROR: cleanup block not found')
src=src.replace(old,new,1)
old='''for cmd in docker git make python3 sha256sum pgrep pkill timeout; do
    command -v "$cmd" >/dev/null 2>&1 || { printf 'ERROR: missing host command: %s\\n' "$cmd" >&2; exit 2; }
done
'''
new='''for cmd in cargo rustc rustfmt docker curl git make python3 sha256sum pgrep pkill ss timeout; do command -v "$cmd" >/dev/null 2>&1 || { printf 'ERROR: missing host command: %s\\n' "$cmd" >&2; exit 2; }; done
if ss -ltn 2>/dev/null | grep -q ":$PORT[[:space:]]"; then printf 'ERROR: API port %s is already in use\\n' "$PORT" >&2; exit 2; fi
'''
if old not in src: raise SystemExit('ERROR: host command block not found')
src=src.replace(old,new,1)
marker='section "Build Phase 1 / Phase 2 / Phase 2B images"\n'
insert='''section "Verify Station source baseline"
cd "$REPO_ROOT"
cargo fmt -- --check
cargo test --all-targets | tee "$RUN_DIR/cargo-test.log"
cargo build --bins | tee "$RUN_DIR/cargo-build.log"
test -x "$REPO_ROOT/target/debug/oceanmail-station"
test -x "$REPO_ROOT/target/debug/oceanmail-uucp-evidence"
test -x "$REPO_ROOT/target/debug/oceanmail-returned-receipt-evidence"
test -r "$REPO_ROOT/scripts/oceanmail-uuxcomp-correlator.sh"
test -r "$REPO_ROOT/scripts/oceanmail-uucico-attempt.sh"
test -r "$REPO_ROOT/scripts/oceanmail-receipt-ingest.sh"
printf 'PASS: Station and Phase 4I evidence helpers build/tests pass\\n'

'''
if marker not in src: raise SystemExit('ERROR: image build marker not found')
src=src.replace(marker,insert+marker,1)
old='''docker run -d --name "$A_NAME" --hostname stationa --network host \\
    -v "$RUN_DIR/a/etc-uucp:/etc/uucp:ro" -v "$RUN_DIR/a/evidence:/evidence" \\
    "$PHASE2B_IMAGE" sleep infinity >/dev/null
'''
new='''docker run -d --name "$A_NAME" --hostname stationa --network host \\
    -v "$RUN_DIR/a/etc-uucp:/etc/uucp:ro" \\
    -v "$RUN_DIR/a/evidence:/evidence" \\
    -v "$STATE_DIR:/state" \\
    -v "$REPO_ROOT/scripts/oceanmail-uuxcomp-correlator.sh:$WRAPPER_CONTAINER_PATH:ro" \\
    -v "$REPO_ROOT/scripts/oceanmail-uucico-attempt.sh:$ATTEMPT_WRAPPER_CONTAINER_PATH:ro" \\
    -v "$REPO_ROOT/scripts/oceanmail-receipt-ingest.sh:$RECEIPT_INGEST_MOUNT:ro" \\
    -v "$REPO_ROOT/target/debug/oceanmail-uucp-evidence:$RECORDER_CONTAINER_PATH:ro" \\
    "$PHASE2B_IMAGE" sleep infinity >/dev/null
'''
if old not in src: raise SystemExit('ERROR: Station A docker block not found')
src=src.replace(old,new,1)
old='commands crmail\nEOF\ncat >"$RUN_DIR/b/etc-uucp/sys" <<\'EOF\'\n'; new='commands crmail oceanmail-receipt-ingest\nEOF\ncat >"$RUN_DIR/b/etc-uucp/sys" <<\'EOF\'\n'
if old not in src: raise SystemExit('ERROR: Station A commands policy fragment not found')
src=src.replace(old,new,1)
marker='[[ "$IPC_A" != "$IPC_B" ]] || { printf \'ERROR: IPC namespaces collided\\n\' >&2; exit 2; }\n\n'
extra=marker+'''docker exec "$A_NAME" /usr/bin/install -m 0755 "$RECEIPT_INGEST_MOUNT" "$RECEIPT_INGEST_COMMAND"
docker exec "$A_NAME" /bin/mkdir -p "$RETURNED_RECEIPT_DIR"
docker exec "$A_NAME" /bin/chmod 0777 "$RETURNED_RECEIPT_DIR"
printf 'PASS: Station A receipt-ingest command installed and writable evidence target ready\\n'

'''
if marker not in src: raise SystemExit('ERROR: IPC marker not found')
src=src.replace(marker,extra,1)
start=src.index('configure_postfix() {\n'); end_marker='configure_postfix "$A_NAME" stationa.test stationa.test\nconfigure_postfix "$B_NAME" stationb.test stationb.test\n'; end=src.index(end_marker,start)+len(end_marker)
new_config=r'''configure_postfix() {
    local container="$1" fqdn="$2" destination="$3"
    docker exec "$container" /usr/sbin/postconf -e 'compatibility_level = 3.6'
    docker exec "$container" /usr/sbin/postconf -e "myhostname = $fqdn"
    docker exec "$container" /usr/sbin/postconf -e "mydomain = $fqdn"
    docker exec "$container" /usr/sbin/postconf -e 'myorigin = $myhostname'
    docker exec "$container" /usr/sbin/postconf -e 'inet_interfaces = all'
    docker exec "$container" /usr/sbin/postconf -e 'inet_protocols = ipv4'
    docker exec "$container" /usr/sbin/postconf -e "mydestination = $destination, localhost"
    docker exec "$container" /usr/sbin/postconf -e 'relayhost ='
    docker exec "$container" /usr/sbin/postconf -e 'maillog_file_prefixes = /var, /dev/stdout, /evidence'
    docker exec "$container" /usr/sbin/postconf -e 'maillog_file = /evidence/postfix.log'
    docker exec "$container" /bin/bash -lc "sed -ri 's/^(smtp[[:space:]]+inet[[:space:]].*)/# \\1/' /etc/postfix/master.cf"
    if [[ "$container" == "$A_NAME" ]]; then
        docker exec "$container" /bin/bash -lc "cat >>/etc/postfix/master.cf <<'EOF'
uucp      unix  -       n       n       -       -       pipe
  flags=F user=uucp argv=/bin/bash $WRAPPER_CONTAINER_PATH \${queue_id} \${nexthop} /state/station.db $RECORDER_CONTAINER_PATH /evidence/uuxcomp-correlation.log -r -n -z -a\${sender} - \${nexthop}!crmail (\${recipient})
EOF"
    else
        docker exec "$container" /bin/bash -lc "cat >>/etc/postfix/master.cf <<'EOF'
uucp      unix  -       n       n       -       -       pipe
  flags=F user=uucp argv=/usr/local/bin/uuxcomp -r -n -z -a\$sender - \$nexthop!crmail (\$recipient)
EOF"
    fi
}
configure_postfix "$A_NAME" stationa.test stationa.test
configure_postfix "$B_NAME" stationb.test stationb.test
'''
src=src[:start]+new_config+src[end:]
marker='section "Start HERMES uucpd"\n'
station_setup=r'''section "Start Station observer against Station A Postfix"
DOCKER_BIN="$(command -v docker)"
cat >"$POSTQUEUE_ADAPTER" <<EOF
#!/bin/sh
if [ "\${1:-}" != "-j" ]; then echo "Phase 4I adapter supports only postqueue -j" >&2; exit 64; fi
exec "$DOCKER_BIN" exec "$A_NAME" /usr/sbin/postqueue -j
EOF
chmod 0755 "$POSTQUEUE_ADAPTER"
start_service() {
    local log_file="$1"; stop_service
    ( umask 000; export OCEANMAIL_BIND="$BIND" OCEANMAIL_STATE_DB="$STATE_DB" OCEANMAIL_STATION_NAME="phase4i-returned-receipt" OCEANMAIL_POSTQUEUE="$POSTQUEUE_ADAPTER" OCEANMAIL_QUEUE_POLL_SECONDS=1; exec "$REPO_ROOT/target/debug/oceanmail-station" ) >"$log_file" 2>&1 &
    SERVICE_PID=$!
    for _ in $(seq 1 50); do
        curl -fsS "http://$BIND/api/v1/health" >/dev/null 2>&1 && return 0
        kill -0 "$SERVICE_PID" 2>/dev/null || { cat "$log_file" >&2 || true; return 1; }
        sleep 0.2
    done
    return 1
}
start_service "$SERVICE_LOG"
OBSERVER_READY=0
for _ in $(seq 1 40); do
    curl -fsS "http://$BIND/api/v1/queues/outbound/observer" >"$RUN_DIR/observer-initial.json" || true
    if python3 - "$RUN_DIR/observer-initial.json" <<'PYOBS' 2>/dev/null
import json, pathlib, sys
s=json.loads(pathlib.Path(sys.argv[1]).read_text()); raise SystemExit(0 if s.get("last_success_at_unix") is not None and s.get("last_observed_entry_count")==0 else 1)
PYOBS
    then OBSERVER_READY=1; break; fi
    sleep 0.25
done
[[ "$OBSERVER_READY" -eq 1 ]] || { printf 'FAIL: Station observer did not establish initial empty Postfix state\\n' >&2; exit 1; }
chmod 0777 "$STATE_DIR"; chmod 0666 "$STATE_DB" "$STATE_DB-wal" "$STATE_DB-shm" 2>/dev/null || true
printf 'PASS: Station observer established initial empty Postfix state\\n'

'''
if marker not in src: raise SystemExit('ERROR: HERMES uucpd marker not found')
src=src.replace(marker,station_setup+marker,1)
old='''$BODY_TOKEN
This message is a deterministic OceanMail Phase 2A text-email acceptance payload.
It was accepted by Postfix, queued into UUCP, transferred by HERMES/Mercury,
and delivered through remote rmail into the Station B local mailbox.
EOF
'''; new='''$BODY_TOKEN
This deterministic OceanMail Phase 4I message is intentionally small. Phase 4G
and 4H already proved large interrupted/progressive transfers; this phase focuses
on returning explicit receipt evidence through the constrained path.
EOF
'''
if old not in src: raise SystemExit('ERROR: message body fragment not found')
src=src.replace(old,new,1)
marker="printf 'PASS: Postfix accepted message; compressed UUCP handoff not yet started\\n'\n"
identity=r'''printf 'PASS: Postfix accepted message; compressed UUCP handoff not yet started\n'
HELD_JSON="$RUN_DIR/postfix-held.jsonl"; docker exec "$A_NAME" /usr/sbin/postqueue -j >"$HELD_JSON"
SEEN=0
for _ in $(seq 1 40); do
    curl -fsS "http://$BIND/api/v1/queues/outbound/history" >"$RUN_DIR/history-held.json"
    if python3 - "$HELD_JSON" "$RUN_DIR/history-held.json" <<'PYSEEN' 2>/dev/null
import json, pathlib, sys
rows=[json.loads(x) for x in pathlib.Path(sys.argv[1]).read_text().splitlines() if x.strip()]; h=json.loads(pathlib.Path(sys.argv[2]).read_text())
raise SystemExit(0 if len(rows)==1 and len(h.get("jobs",[]))==1 and h["jobs"][0].get("present_in_postfix") is True else 1)
PYSEEN
    then SEEN=1; break; fi
    sleep 0.25
done
[[ "$SEEN" -eq 1 ]] || { printf 'FAIL: Station did not persist held Postfix observation\n' >&2; exit 1; }
read -r POSTFIX_QUEUE_ID OBSERVATION_ID < <(python3 - "$HELD_JSON" "$RUN_DIR/history-held.json" <<'PYIDS'
import json, pathlib, sys
rows=[json.loads(x) for x in pathlib.Path(sys.argv[1]).read_text().splitlines() if x.strip()]; h=json.loads(pathlib.Path(sys.argv[2]).read_text()); print(rows[0]["queue_id"], h["jobs"][0]["observation_id"])
PYIDS
)
printf 'Postfix queue ID: %s\nStation observation ID: %s\n' "$POSTFIX_QUEUE_ID" "$OBSERVATION_ID"
"$REPO_ROOT/target/debug/oceanmail-returned-receipt-evidence" message-record --state-db "$STATE_DB" --postfix-queue-id "$POSTFIX_QUEUE_ID" --message-id "$MESSAGE_ID" | tee "$RUN_DIR/message-identity.json"
printf 'PASS: RFC Message-ID durably correlated to original local Postfix observation\n'
'''
if marker not in src: raise SystemExit('ERROR: local Postfix acceptance marker not found')
src=src.replace(marker,identity,1)
marker='[[ ! -s "$RUN_DIR/bob-mailbox.mbox" ]] || true\n\n'
mapping=r'''[[ ! -s "$RUN_DIR/bob-mailbox.mbox" ]] || true
MAPPED=0
for _ in $(seq 1 60); do
    "$REPO_ROOT/target/debug/oceanmail-uucp-evidence" list --state-db "$STATE_DB" >"$RUN_DIR/uucp-evidence.json" 2>/dev/null || true
    if python3 - "$RUN_DIR/uucp-evidence.json" "$POSTFIX_QUEUE_ID" "$OBSERVATION_ID" <<'PYMAP' 2>/dev/null
import json, pathlib, sys
p,q,o=sys.argv[1:]; d=json.loads(pathlib.Path(p).read_text()); j=d.get("jobs",[]); raise SystemExit(0 if len(j)==1 and j[0]["postfix_queue_id"]==q and j[0]["observation_id"]==o and j[0]["remote_system"]=="stationb" else 1)
PYMAP
    then MAPPED=1; break; fi
    sleep 0.25
done
[[ "$MAPPED" -eq 1 ]] || { printf 'FAIL: exact Postfix -> UUCP mapping missing\n' >&2; exit 1; }
UUCP_JOB_ID="$(python3 - "$RUN_DIR/uucp-evidence.json" <<'PYJOB'
import json, pathlib, sys
print(json.loads(pathlib.Path(sys.argv[1]).read_text())["jobs"][0]["uucp_job_id"])
PYJOB
)"
printf 'Mapped Taylor UUCP job: stationb/%s\n' "$UUCP_JOB_ID"

'''
if marker not in src: raise SystemExit('ERROR: compressed queue tail marker not found')
src=src.replace(marker,mapping,1)
tail_marker='section "State 3: transfer compressed mail through HERMES/Mercury"\n'
if tail_marker not in src: raise SystemExit('ERROR: Phase 2B State 3 marker not found')
src=src.split(tail_marker,1)[0]
src += r'''section "State 3: deliver original mapped message A -> B"
ATTEMPT_ID="$(cat /proc/sys/kernel/random/uuid)"; printf 'Original-message UUCP attempt ID: %s\n' "$ATTEMPT_ID"
ORIGINAL_EXEC_RC_FILE="$RUN_DIR/original-attempt-docker-exec.rc"
rm -f "$ORIGINAL_EXEC_RC_FILE"
(
    set +e
    docker exec -e "OCEANMAIL_ATTEMPT_ID=$ATTEMPT_ID" "$A_NAME" /bin/bash "$ATTEMPT_WRAPPER_CONTAINER_PATH" /state/station.db "$RECORDER_CONTAINER_PATH" stationb /evidence/uucico-phase4i-original.log -D -S stationb
    ORIGINAL_EXEC_RC=$?
    printf '%s\n' "$ORIGINAL_EXEC_RC" >"$ORIGINAL_EXEC_RC_FILE.tmp"
    mv "$ORIGINAL_EXEC_RC_FILE.tmp" "$ORIGINAL_EXEC_RC_FILE"
) &
ORIGINAL_EXEC_PID=$!

original_snapshot_ready() {
    "$REPO_ROOT/target/debug/oceanmail-uucp-evidence" list --state-db "$STATE_DB" >"$RUN_DIR/original-attempt-running.json" 2>/dev/null || true
    python3 - "$RUN_DIR/original-attempt-running.json" "$ATTEMPT_ID" "$UUCP_JOB_ID" "$OBSERVATION_ID" <<'PYSNAP' 2>/dev/null
import json, pathlib, sys
p,a,j,o=sys.argv[1:]
d=json.loads(pathlib.Path(p).read_text())
attempts=[x for x in d.get("attempts",[]) if x.get("attempt_id")==a]
jobs=[x for x in d.get("attempt_jobs",[]) if x.get("attempt_id")==a]
events=[x for x in d.get("attempt_events",[]) if x.get("attempt_id")==a]
started=[x for x in events if x.get("event_type")=="uucico_attempt_started"]
snapshots=[x for x in events if x.get("event_type")=="queued_job_snapshot_recorded"]
ready=(
    len(attempts)==1
    and attempts[0].get("remote_system")=="stationb"
    and attempts[0].get("adapter")=="taylor-uucico"
    and len(jobs)==1
    and jobs[0].get("uucp_job_id")==j
    and jobs[0].get("observation_id")==o
    and jobs[0].get("remote_system")=="stationb"
    and jobs[0].get("relationship")=="queued_at_attempt_start"
    and len(started)==1
    and len(snapshots)==1
    and snapshots[0].get("evidence_source")=="taylor-uustat"
    and snapshots[0].get("metric_name")=="mapped_jobs_queued_at_attempt_start"
    and snapshots[0].get("metric_value")==1
)
raise SystemExit(0 if ready else 1)
PYSNAP
}
SNAPSHOT=0
SNAPSHOT_DEADLINE=$((SECONDS + 30))
while (( SECONDS < SNAPSHOT_DEADLINE )); do
    if original_snapshot_ready; then SNAPSHOT=1; break; fi
    if [[ -s "$ORIGINAL_EXEC_RC_FILE" ]]; then break; fi
    sleep 0.25
done
# The caller may commit and exit after the last database read. Re-read durable
# evidence after observing completion (or the deadline), before declaring failure.
if [[ "$SNAPSHOT" -ne 1 ]] && original_snapshot_ready; then SNAPSHOT=1; fi
if [[ "$SNAPSHOT" -ne 1 ]]; then
    printf 'FAIL: original-message attempt snapshot did not reach the exact durable ready state within 30 seconds\n' >&2
    [[ -s "$ORIGINAL_EXEC_RC_FILE" ]] && printf 'Original docker exec exit code: %s\n' "$(cat "$ORIGINAL_EXEC_RC_FILE")" >&2
    "$REPO_ROOT/target/debug/oceanmail-uucp-evidence" list --state-db "$STATE_DB" >"$RUN_DIR/original-attempt-timeout.json" 2>/dev/null || true
    docker exec "$A_NAME" /usr/bin/uustat -a >"$RUN_DIR/uustat-original-snapshot-timeout.txt" 2>&1 || true
    docker exec "$A_NAME" ps -ef >"$RUN_DIR/ps-a-original-snapshot-timeout.txt" 2>&1 || true
    tail -n 180 "$RUN_DIR/a/evidence/uucico-phase4i-original.log" >&2 2>/dev/null || true
    exit 1
fi
printf 'PASS: original-message attempt durable snapshot records the exact mapped Taylor job\n'
MAILBOX_READY=0
for step in $(seq 1 90); do sleep 5; if docker exec "$B_NAME" sh -lc "test -f /var/mail/bob && grep -F '$MESSAGE_ID' /var/mail/bob >/dev/null 2>&1"; then MAILBOX_READY=1; break; fi; printf '[Phase 4I original] elapsed=%ss remote-mailbox=pending\n' "$((step * 5))"; done
[[ "$MAILBOX_READY" -eq 1 ]] || { printf 'FAIL: original exact Message-ID did not reach Station B mailbox\n' >&2; exit 1; }
printf 'PASS: original exact Message-ID is present in Station B mailbox\n'
docker cp "$B_NAME:/var/mail/bob" "$RUN_DIR/bob-mailbox.mbox" >/dev/null
python3 - "$RUN_DIR/bob-mailbox.mbox" "$MESSAGE_ID" "$SUBJECT" "$BODY_TOKEN" <<'PYMAIL'
import mailbox, sys
path,wanted_id,wanted_subject,token=sys.argv[1:]; box=mailbox.mbox(path); matches=[m for m in box if (m.get('Message-ID') or '').strip()==wanted_id]; assert len(matches)==1; msg=matches[0]; assert (msg.get('Subject') or '').strip()==wanted_subject; assert 'bob@stationb.test' in (msg.get('To') or ''); payload=msg.get_payload(decode=True); payload=payload if payload is not None else str(msg.get_payload()).encode(); body=payload.decode(msg.get_content_charset() or 'utf-8',errors='replace'); assert token in body; print('PASS: far-side mailbox verified exact Message-ID/Subject/recipient/body token')
PYMAIL
section "Wait for original A -> B UUCP session retirement before reciprocal call"
ORIGINAL_ATTEMPT_DONE=0
for _ in $(seq 1 120); do
    "$REPO_ROOT/target/debug/oceanmail-uucp-evidence" list --state-db "$STATE_DB" >"$RUN_DIR/original-attempt-finished.json" 2>/dev/null || true
    if python3 - "$RUN_DIR/original-attempt-finished.json" "$ATTEMPT_ID" <<'PYDONE' 2>/dev/null
import json, pathlib, sys
p,a=sys.argv[1:]; d=json.loads(pathlib.Path(p).read_text()); x=[v for v in d.get("attempts",[]) if v["attempt_id"]==a]; raise SystemExit(0 if len(x)==1 and x[0].get("finished_at_unix") is not None and x[0].get("process_exit_code")==0 else 1)
PYDONE
    then ORIGINAL_ATTEMPT_DONE=1; break; fi
    sleep 0.5
done
[[ "$ORIGINAL_ATTEMPT_DONE" -eq 1 ]] || { printf 'FAIL: original A-to-B caller attempt did not finish successfully before reciprocal call\n' >&2; tail -n 180 "$RUN_DIR/a/evidence/uucico-phase4i-original.log" >&2 2>/dev/null || true; exit 1; }
wait "$ORIGINAL_EXEC_PID" || true
[[ -s "$ORIGINAL_EXEC_RC_FILE" ]] || { printf 'FAIL: original docker exec exit status was not captured\n' >&2; exit 1; }
[[ "$(cat "$ORIGINAL_EXEC_RC_FILE")" == "0" ]] || { printf 'FAIL: original docker exec failed with exit %s\n' "$(cat "$ORIGINAL_EXEC_RC_FILE")" >&2; exit 1; }
printf 'PASS: original A-to-B caller attempt finished successfully\n'
ORIGINAL_JOB_RETIRED=0
for _ in $(seq 1 120); do docker exec "$A_NAME" /usr/bin/uustat -a >"$RUN_DIR/uustat-original-retirement.txt" 2>&1 || true; if ! grep -F "$UUCP_JOB_ID" "$RUN_DIR/uustat-original-retirement.txt" >/dev/null; then ORIGINAL_JOB_RETIRED=1; break; fi; sleep 0.5; done
[[ "$ORIGINAL_JOB_RETIRED" -eq 1 ]] || { printf 'FAIL: original Taylor job did not retire before reciprocal call\n' >&2; cat "$RUN_DIR/uustat-original-retirement.txt" >&2 || true; exit 1; }
printf 'PASS: original Taylor job retired before reciprocal call\n'
SESSION_IDLE=0
for _ in $(seq 1 120); do A_ACTIVE=0; B_ACTIVE=0; docker exec "$A_NAME" pgrep -x uucico >/dev/null 2>&1 && A_ACTIVE=1 || true; docker exec "$B_NAME" pgrep -x uucico >/dev/null 2>&1 && B_ACTIVE=1 || true; if [[ "$A_ACTIVE" -eq 0 && "$B_ACTIVE" -eq 0 ]]; then SESSION_IDLE=1; break; fi; sleep 0.5; done
[[ "$SESSION_IDLE" -eq 1 ]] || { printf 'FAIL: prior uucico session did not become idle\n' >&2; docker exec "$A_NAME" ps -ef >&2 || true; docker exec "$B_NAME" ps -ef >&2 || true; exit 1; }
printf 'PASS: both Station containers are clear of prior uucico session state\n'
bash "$REPO_ROOT/scripts/phase4i-wait-mercury-listening.sh" /tmp/mA.log /tmp/mB.log 120 0.25 | tee "$RUN_DIR/mercury-reciprocal-idle-gate.txt"
bash "$REPO_ROOT/scripts/phase4i-wait-hermes-clean.sh" "$A_NAME" "$B_NAME" 30 0.1 | tee "$RUN_DIR/hermes-reciprocal-idle-gate.txt"
section "Prove Station A still has no returned-receipt confirmation"
"$REPO_ROOT/target/debug/oceanmail-returned-receipt-evidence" list --state-db "$STATE_DB" >"$RUN_DIR/returned-before.json"; curl -fsS "http://$BIND/api/v1/queues/outbound/history" >"$RUN_DIR/history-before-return.json"
python3 - "$RUN_DIR/returned-before.json" "$RUN_DIR/history-before-return.json" <<'PYNONE'
import json, pathlib, sys
r=json.loads(pathlib.Path(sys.argv[1]).read_text()); h=json.loads(pathlib.Path(sys.argv[2]).read_text()); assert len(r.get('message_identities',[]))==1; assert r.get('returned_receipts',[])==[]; assert 'returned_remote_receipt_observed' not in [e['event_type'] for e in h.get('events',[])]; print('PASS: far-side mailbox presence alone has not created origin returned-receipt state')
PYNONE
section "Create compact receipt artifact at Station B evidence side"
RECEIPT_ARTIFACT="$RUN_DIR/b/evidence/phase4i-returned-receipt.json"
python3 - "$RECEIPT_ARTIFACT" "$MESSAGE_ID" <<'PYART'
import json, pathlib, sys, time
path,message_id=sys.argv[1:]; artifact={"version":1,"artifact_type":"oceanmail.remote_mailbox_receipt","message_id":message_id,"remote_system":"stationb","receipt_kind":"mailbox_message_present","evidence_source":"phase4i-stationb-mailbox","observed_at_unix":int(time.time())}; pathlib.Path(path).write_text(json.dumps(artifact,separators=(",",":"))+"\n")
PYART
RECEIPT_BYTES="$(wc -c <"$RECEIPT_ARTIFACT" | tr -d ' ')"; RECEIPT_SHA="$(sha256sum "$RECEIPT_ARTIFACT" | awk '{print $1}')"; printf 'Receipt artifact bytes: %s\nReceipt artifact SHA-256: %s\n' "$RECEIPT_BYTES" "$RECEIPT_SHA"
section "Queue exact returned receipt as Taylor UUCP work B -> A"
set +e; RETURN_JOB_ID="$(docker exec -i "$B_NAME" /usr/bin/uux -j -r - stationa!oceanmail-receipt-ingest <"$RECEIPT_ARTIFACT" 2>"$RUN_DIR/b/evidence/uux-receipt.err")"; RETURN_UUX_RC=$?; set -e
[[ "$RETURN_UUX_RC" -eq 0 ]] || { cat "$RUN_DIR/b/evidence/uux-receipt.err" >&2 || true; exit 1; }
RETURN_JOB_ID="$(printf '%s\n' "$RETURN_JOB_ID" | sed '/^[[:space:]]*$/d' | tail -n 1)"; [[ -n "$RETURN_JOB_ID" ]] || { printf 'FAIL: Taylor uux did not return receipt job ID\n' >&2; exit 1; }
printf 'Returned-receipt Taylor job: stationa/%s\n' "$RETURN_JOB_ID"; docker exec "$B_NAME" /usr/bin/uustat -a >"$RUN_DIR/uustat-return-queued.txt" 2>&1 || true; grep -F "$RETURN_JOB_ID" "$RUN_DIR/uustat-return-queued.txt" >/dev/null || { printf 'FAIL: exact returned-receipt Taylor job not visible in B queue\n' >&2; exit 1; }; grep -F 'oceanmail-receipt-ingest' "$RUN_DIR/uustat-return-queued.txt" >/dev/null || { printf 'FAIL: returned Taylor job is not expected receipt-ingest command\n' >&2; exit 1; }; printf 'PASS: exact compact returned receipt is durable Taylor work before return transport\n'
section "Carry receipt B -> A over HERMES/Mercury"
set +e; timeout 600 docker exec "$B_NAME" /usr/sbin/uucico -D -S stationa >"$RUN_DIR/b/evidence/uucico-return.log" 2>&1; RETURN_UUCICO_RC=$?; set -e; printf 'Return uucico exit code: %s\n' "$RETURN_UUCICO_RC"; [[ "$RETURN_UUCICO_RC" -eq 0 ]] || { tail -n 180 "$RUN_DIR/b/evidence/uucico-return.log" >&2 || true; exit 1; }
RETURNED_FILE="$RUN_DIR/a/evidence/returned-receipts/receipt.json"; RETURNED_READY=0; for _ in $(seq 1 60); do [[ -s "$RETURNED_FILE" ]] && { RETURNED_READY=1; break; }; sleep 0.5; done; [[ "$RETURNED_READY" -eq 1 ]] || { printf 'FAIL: Station A receipt-ingest command did not produce returned artifact\n' >&2; exit 1; }; RETURNED_SHA="$(sha256sum "$RETURNED_FILE" | awk '{print $1}')"; [[ "$RETURNED_SHA" == "$RECEIPT_SHA" ]] || { printf 'FAIL: returned receipt SHA mismatch\n' >&2; exit 1; }; printf 'PASS: exact receipt artifact arrived at Station A unchanged\n'; docker exec "$B_NAME" /usr/bin/uustat -a >"$RUN_DIR/uustat-return-after.txt" 2>&1 || true; ! grep -F "$RETURN_JOB_ID" "$RUN_DIR/uustat-return-after.txt" >/dev/null || { printf 'FAIL: returned receipt Taylor job remains queued after success\n' >&2; exit 1; }; printf 'PASS: returned-receipt Taylor job retired after successful B-to-A transfer\n'
section "Validate/correlate returned receipt at Station A"
"$REPO_ROOT/target/debug/oceanmail-returned-receipt-evidence" returned-record --state-db "$STATE_DB" --artifact "$RETURNED_FILE" --trust-state "$TRUST_STATE" | tee "$RUN_DIR/returned-record.json"; "$REPO_ROOT/target/debug/oceanmail-returned-receipt-evidence" list --state-db "$STATE_DB" >"$RUN_DIR/returned-after.json"; curl -fsS "http://$BIND/api/v1/queues/outbound/history" >"$RUN_DIR/history-after-return.json"
python3 - "$RUN_DIR/returned-after.json" "$RUN_DIR/history-after-return.json" "$MESSAGE_ID" "$OBSERVATION_ID" "$POSTFIX_QUEUE_ID" "$UUCP_JOB_ID" "$TRUST_STATE" <<'PYVERIFY'
import json, pathlib, sys
rp,hp,m,o,q,j,trust=sys.argv[1:]; r=json.loads(pathlib.Path(rp).read_text()); h=json.loads(pathlib.Path(hp).read_text()); x=r['returned_receipts'][0]; assert r['source']=='station-sqlite-returned-receipt-evidence' and len(r['message_identities'])==1 and len(r['returned_receipts'])==1; assert x['message_id']==m and x['observation_id']==o and x['postfix_queue_id']==q and x['uucp_job_id']==j and x['remote_system']=='stationb' and x['receipt_kind']=='mailbox_message_present' and x['evidence_source']=='phase4i-stationb-mailbox' and x['trust_state']==trust and x['evidence_type']=='returned_remote_receipt_observed'; events=[e['event_type'] for e in h['events']]; assert events.count('message_id_correlated')==1 and events.count('returned_remote_receipt_observed')==1; print('PASS: Station A resolved returned Message-ID to original observation and exact Taylor job'); print('PASS: returned receipt state exists only after B-to-A artifact arrival and validation')
PYVERIFY
section "Restart Station A and prove returned receipt durability"
BEFORE_SHA="$(sha256sum "$RUN_DIR/returned-after.json" | awk '{print $1}')"; stop_service; start_service "$SERVICE_RESTART_LOG"; "$REPO_ROOT/target/debug/oceanmail-returned-receipt-evidence" list --state-db "$STATE_DB" >"$RUN_DIR/returned-after-restart.json"; AFTER_SHA="$(sha256sum "$RUN_DIR/returned-after-restart.json" | awk '{print $1}')"; [[ "$BEFORE_SHA" == "$AFTER_SHA" ]] || { printf 'FAIL: returned receipt evidence changed across Station restart\n' >&2; exit 1; }; printf 'PASS: returned receipt correlation survives Station restart unchanged\n'
section "Phase 4I result"
printf 'PASS: explicit returned receipt B-to-A evidence proven without physical radio\nOriginal Postfix queue ID: %s\nOriginal Station observation ID: %s\nOriginal Taylor job: stationb/%s\nOriginal Message-ID: %s\nReturned receipt Taylor job: stationa/%s\nReturned receipt bytes: %s\nReturned receipt SHA-256: %s\nTrust state: %s (not production-authenticated)\nPhysical-radio Phase 5 was not started\nEvidence directory: %s\n' "$POSTFIX_QUEUE_ID" "$OBSERVATION_ID" "$UUCP_JOB_ID" "$MESSAGE_ID" "$RETURN_JOB_ID" "$RECEIPT_BYTES" "$RECEIPT_SHA" "$TRUST_STATE" "$RUN_DIR"
'''
dst_path.write_text(src)
PY
chmod +x "$RUNTIME_COPY"
bash -n "$RUNTIME_COPY" || {
    echo "ERROR: generated Phase 4I runtime script failed bash syntax validation" >&2
    exit 2
}
set +e
bash "$RUNTIME_COPY"
RC=$?
set -e
exit "$RC"
