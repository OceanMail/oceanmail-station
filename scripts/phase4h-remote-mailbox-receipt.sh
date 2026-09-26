#!/usr/bin/env bash
# OceanMail Station 0.2 — Phase 4H remote mailbox receipt evidence
#
# Directly derives one runtime harness from the canonical Phase 2B two-station
# HERMES/Mercury mail proof. It adds the accepted Phase 4E/4F evidence boundaries
# and allows the exact mapped UUCP job to complete. Only after Station B's
# actual mailbox proves the exact Message-ID does OceanMail persist a remote
# mailbox receipt. Sender-side process/queue success alone is insufficient.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$REPO_ROOT/scripts/phase2b-hermes-compressed-mail.sh"
RUNTIME_COPY="$(mktemp "$REPO_ROOT/scripts/.phase4h-runtime.XXXXXX.sh")"

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
    '# OceanMail Station 0.2 — Phase 2B HERMES uuxcomp/crmail acceptance\n':
        '# OceanMail Station 0.2 — Phase 4H remote mailbox receipt evidence\n',
    'RUN_DIR="$LOG_BASE/phase2b-hermes-mail-$RUN_ID"\n':
        'RUN_DIR="$LOG_BASE/phase4h-remote-mailbox-receipt-$RUN_ID"\n',
    'A_NAME="oceanmail-mail-a"\nB_NAME="oceanmail-mail-b"\nMESSAGE_ID="<phase2b-$RUN_ID@stationa.test>"\nBODY_TOKEN="OceanMail-Phase2B-$RUN_ID-body-check"\nSUBJECT="OceanMail Phase 2A RFC mail proof"\n':
        'A_NAME="oceanmail-phase4h-a"\nB_NAME="oceanmail-phase4h-b"\n'
        'MESSAGE_ID="<phase4h-$RUN_ID@stationa.test>"\n'
        'BODY_TOKEN="OceanMail-Phase4H-$RUN_ID-body-check"\n'
        'SUBJECT="OceanMail Phase 4H remote mailbox receipt proof"\n'
        'PORT="${PORT:-18087}"\n'
        'BIND="127.0.0.1:$PORT"\n'
        'STATE_DIR="$RUN_DIR/state"\n'
        'STATE_DB="$STATE_DIR/station.db"\n'
        'POSTQUEUE_ADAPTER="$RUN_DIR/postqueue-real"\n'
        'SERVICE_LOG="$RUN_DIR/station-service.log"\n'
        'SERVICE_RESTART_LOG="$RUN_DIR/station-service-restart.log"\n'
        'SERVICE_PID=""\n'
        'HERMES_MAX_EMAIL_SIZE="${HERMES_MAX_EMAIL_SIZE:-20000}"\n'
        'WRAPPER_CONTAINER_PATH="/opt/oceanmail/oceanmail-uuxcomp-correlator.sh"\n'
        'ATTEMPT_WRAPPER_CONTAINER_PATH="/opt/oceanmail/oceanmail-uucico-attempt.sh"\n'
        'RECORDER_CONTAINER_PATH="/opt/oceanmail/oceanmail-uucp-evidence"\n',
    'mkdir -p "$RUN_DIR"\n':
        'mkdir -p "$RUN_DIR" "$STATE_DIR"\nchmod 0777 "$STATE_DIR"\n',
    'section "Phase 2B environment"\n':
        'section "Phase 4H environment"\n'
        'printf \'Station API bind: %s\\n\' "$BIND"\n'
        'printf \'Pinned HERMES queued-email limit: %s bytes\\n\' "$HERMES_MAX_EMAIL_SIZE"\n'
        'printf \'Receipt trigger: exact Message-ID appears in Station B mailbox\\n\'\n'
        'printf \'Acceptance boundary: exact mapped UUCP job + system attempt + actual far-side mailbox receipt\\n\'\n',
}
for old, new in replacements.items():
    if old not in src:
        raise SystemExit(f"ERROR: expected Phase 2B source fragment not found: {old!r}")
    src = src.replace(old, new, 1)

old = '''cleanup() {
    docker rm -f "$A_NAME" "$B_NAME" >/dev/null 2>&1 || true
    stop_link
}
trap cleanup EXIT
'''
new = '''stop_service() {
    if [[ -n "$SERVICE_PID" ]] && kill -0 "$SERVICE_PID" 2>/dev/null; then
        kill -INT "$SERVICE_PID" 2>/dev/null || true
        for _ in $(seq 1 30); do
            kill -0 "$SERVICE_PID" 2>/dev/null || break
            sleep 0.2
        done
        if kill -0 "$SERVICE_PID" 2>/dev/null; then
            kill -TERM "$SERVICE_PID" 2>/dev/null || true
        fi
        wait "$SERVICE_PID" 2>/dev/null || true
    fi
    SERVICE_PID=""
}

cleanup() {
    stop_service
    docker rm -f "$A_NAME" "$B_NAME" >/dev/null 2>&1 || true
    stop_link
}
trap cleanup EXIT
'''
if old not in src:
    raise SystemExit('ERROR: cleanup block not found')
src = src.replace(old, new, 1)

old = '''for cmd in docker git make python3 sha256sum pgrep pkill timeout; do
    command -v "$cmd" >/dev/null 2>&1 || { printf 'ERROR: missing host command: %s\\n' "$cmd" >&2; exit 2; }
done
'''
new = '''for cmd in cargo rustc rustfmt docker curl git make python3 sha256sum pgrep pkill ss timeout; do
    command -v "$cmd" >/dev/null 2>&1 || { printf 'ERROR: missing host command: %s\\n' "$cmd" >&2; exit 2; }
done
if ss -ltn 2>/dev/null | grep -q ":$PORT[[:space:]]"; then
    printf 'ERROR: API port %s is already in use\\n' "$PORT" >&2
    exit 2
fi
'''
if old not in src:
    raise SystemExit('ERROR: host command block not found')
src = src.replace(old, new, 1)

marker = 'section "Build Phase 1 / Phase 2 / Phase 2B images"\n'
insert = '''section "Verify Station source baseline"
cd "$REPO_ROOT"
cargo fmt -- --check
cargo test --all-targets | tee "$RUN_DIR/cargo-test.log"
cargo build --bins | tee "$RUN_DIR/cargo-build.log"
test -x "$REPO_ROOT/target/debug/oceanmail-station"
test -x "$REPO_ROOT/target/debug/oceanmail-uucp-evidence"
test -x "$REPO_ROOT/target/debug/oceanmail-remote-receipt-evidence"
test -r "$REPO_ROOT/scripts/oceanmail-uuxcomp-correlator.sh"
test -r "$REPO_ROOT/scripts/oceanmail-uucico-attempt.sh"
printf 'PASS: Station and evidence helpers build/tests pass\\n'

'''
if marker not in src:
    raise SystemExit('ERROR: image build marker not found')
src = src.replace(marker, insert + marker, 1)

old = '''docker run -d --name "$A_NAME" --hostname stationa --network host \\
    -v "$RUN_DIR/a/etc-uucp:/etc/uucp:ro" -v "$RUN_DIR/a/evidence:/evidence" \\
    "$PHASE2B_IMAGE" sleep infinity >/dev/null
'''
new = '''docker run -d --name "$A_NAME" --hostname stationa --network host \\
    -v "$RUN_DIR/a/etc-uucp:/etc/uucp:ro" \\
    -v "$RUN_DIR/a/evidence:/evidence" \\
    -v "$STATE_DIR:/state" \\
    -v "$REPO_ROOT/scripts/oceanmail-uuxcomp-correlator.sh:$WRAPPER_CONTAINER_PATH:ro" \\
    -v "$REPO_ROOT/scripts/oceanmail-uucico-attempt.sh:$ATTEMPT_WRAPPER_CONTAINER_PATH:ro" \\
    -v "$REPO_ROOT/target/debug/oceanmail-uucp-evidence:$RECORDER_CONTAINER_PATH:ro" \\
    "$PHASE2B_IMAGE" sleep infinity >/dev/null
'''
if old not in src:
    raise SystemExit('ERROR: Station A docker run block not found')
src = src.replace(old, new, 1)

start = src.index('configure_postfix() {\n')
end_marker = 'configure_postfix "$A_NAME" stationa.test stationa.test\nconfigure_postfix "$B_NAME" stationb.test stationb.test\n'
end = src.index(end_marker, start) + len(end_marker)
new_config = r'''configure_postfix() {
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
    docker exec "$container" /bin/bash -lc \
        "sed -ri 's/^(smtp[[:space:]]+inet[[:space:]].*)/# \\1/' /etc/postfix/master.cf"
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
src = src[:start] + new_config + src[end:]

marker = "printf 'PASS: Postfix running with HERMES compressed UUCP pipe\\n'\n"
log_permissions = marker + "docker exec \"$A_NAME\" chmod 0666 /evidence/postfix.log 2>/dev/null || true\ndocker exec \"$B_NAME\" chmod 0666 /evidence/postfix.log 2>/dev/null || true\n"
if marker not in src:
    raise SystemExit('ERROR: Postfix running marker not found')
src = src.replace(marker, log_permissions, 1)

marker = 'section "Start HERMES uucpd"\n'
station_setup = r'''section "Start Station observer against Station A Postfix"
DOCKER_BIN="$(command -v docker)"
cat >"$POSTQUEUE_ADAPTER" <<EOF
#!/bin/sh
if [ "\${1:-}" != "-j" ]; then
    echo "Phase 4H adapter supports only postqueue -j" >&2
    exit 64
fi
exec "$DOCKER_BIN" exec "$A_NAME" /usr/sbin/postqueue -j
EOF
chmod 0755 "$POSTQUEUE_ADAPTER"

start_service() {
    local log_file="$1"
    stop_service
    (
        umask 000
        export OCEANMAIL_BIND="$BIND"
        export OCEANMAIL_STATE_DB="$STATE_DB"
        export OCEANMAIL_STATION_NAME="phase4h-remote-mailbox-receipt"
        export OCEANMAIL_POSTQUEUE="$POSTQUEUE_ADAPTER"
        export OCEANMAIL_QUEUE_POLL_SECONDS=1
        exec "$REPO_ROOT/target/debug/oceanmail-station"
    ) >"$log_file" 2>&1 &
    SERVICE_PID=$!
    for _ in $(seq 1 50); do
        if curl -fsS "http://$BIND/api/v1/health" >/dev/null 2>&1; then return 0; fi
        if ! kill -0 "$SERVICE_PID" 2>/dev/null; then
            cat "$log_file" >&2 || true
            return 1
        fi
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
s=json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(0 if s.get("last_success_at_unix") is not None and s.get("last_observed_entry_count")==0 else 1)
PYOBS
    then OBSERVER_READY=1; break; fi
    sleep 0.25
done
[[ "$OBSERVER_READY" -eq 1 ]] || { printf 'FAIL: Station observer did not establish initial empty Postfix state\n' >&2; exit 1; }
chmod 0777 "$STATE_DIR"
chmod 0666 "$STATE_DB" "$STATE_DB-wal" "$STATE_DB-shm" 2>/dev/null || true
printf 'PASS: Station observer established initial empty Postfix state\n'

'''
if marker not in src:
    raise SystemExit('ERROR: uucpd marker not found')
src = src.replace(marker, station_setup + marker, 1)

old = '''$BODY_TOKEN
This message is a deterministic OceanMail Phase 2A text-email acceptance payload.
It was accepted by Postfix, queued into UUCP, transferred by HERMES/Mercury,
and delivered through remote rmail into the Station B local mailbox.
EOF
'''
new = '''$BODY_TOKEN
This message is a deterministic OceanMail Phase 4H remote-mailbox-receipt payload.
The following deterministic high-entropy text keeps the constrained transfer
large enough to exercise the real HERMES/Mercury path while remaining below
pinned HERMES's 20000-byte queued-email limit after XZ compression.
$(python3 - <<'PYBODY'
import hashlib
out=[]
for i in range(480):
    out.append(hashlib.sha256(f"phase4h-{i}".encode()).hexdigest())
print("\\n".join(out))
PYBODY
)
EOF
'''
if old not in src:
    raise SystemExit('ERROR: message body fragment not found')
src = src.replace(old, new, 1)

marker = "printf 'PASS: Postfix accepted message; compressed UUCP handoff not yet started\\n'\n"
addition = r'''printf 'PASS: Postfix accepted message; compressed UUCP handoff not yet started\n'
HELD_JSON="$RUN_DIR/postfix-held.jsonl"
docker exec "$A_NAME" /usr/sbin/postqueue -j >"$HELD_JSON"
SEEN=0
for _ in $(seq 1 40); do
    curl -fsS "http://$BIND/api/v1/queues/outbound/history" >"$RUN_DIR/history-held.json"
    if python3 - "$HELD_JSON" "$RUN_DIR/history-held.json" <<'PYSEEN' 2>/dev/null
import json, pathlib, sys
rows=[json.loads(x) for x in pathlib.Path(sys.argv[1]).read_text().splitlines() if x.strip()]
h=json.loads(pathlib.Path(sys.argv[2]).read_text())
raise SystemExit(0 if len(rows)==1 and len(h.get("jobs",[]))==1 and h["jobs"][0].get("present_in_postfix") is True else 1)
PYSEEN
    then SEEN=1; break; fi
    sleep 0.25
done
[[ "$SEEN" -eq 1 ]] || { printf 'FAIL: Station did not persist held Postfix observation\n' >&2; exit 1; }
read -r POSTFIX_QUEUE_ID OBSERVATION_ID < <(python3 - "$HELD_JSON" "$RUN_DIR/history-held.json" <<'PYIDS'
import json, pathlib, sys
rows=[json.loads(x) for x in pathlib.Path(sys.argv[1]).read_text().splitlines() if x.strip()]
h=json.loads(pathlib.Path(sys.argv[2]).read_text())
print(rows[0]["queue_id"], h["jobs"][0]["observation_id"])
PYIDS
)
printf 'Postfix queue ID: %s\n' "$POSTFIX_QUEUE_ID"
printf 'Station observation ID: %s\n' "$OBSERVATION_ID"
'''
if marker not in src:
    raise SystemExit('ERROR: Postfix acceptance marker not found')
src = src.replace(marker, addition, 1)

marker = "printf 'Compressed UUCP payload: %s bytes\\n' \"$COMPRESSED_BYTES\"\n"
size_guard = marker + "if (( COMPRESSED_BYTES > HERMES_MAX_EMAIL_SIZE )); then\n    printf 'FAIL: compressed UUCP payload %s exceeds pinned HERMES limit %s\\n' \"$COMPRESSED_BYTES\" \"$HERMES_MAX_EMAIL_SIZE\" >&2\n    exit 1\nfi\nprintf 'PASS: compressed UUCP payload is within pinned HERMES queue policy\\n'\n"
if marker not in src:
    raise SystemExit('ERROR: compressed payload marker not found')
src = src.replace(marker, size_guard, 1)

marker = '[[ ! -s "$RUN_DIR/bob-mailbox.mbox" ]] || true\n\n'
mapping = r'''[[ ! -s "$RUN_DIR/bob-mailbox.mbox" ]] || true
MAPPED=0
for _ in $(seq 1 60); do
    "$REPO_ROOT/target/debug/oceanmail-uucp-evidence" list --state-db "$STATE_DB" >"$RUN_DIR/uucp-evidence.json" 2>/dev/null || true
    if python3 - "$RUN_DIR/uucp-evidence.json" "$POSTFIX_QUEUE_ID" "$OBSERVATION_ID" <<'PYMAP' 2>/dev/null
import json, pathlib, sys
p,q,o=sys.argv[1:]
d=json.loads(pathlib.Path(p).read_text())
j=d.get("jobs",[])
raise SystemExit(0 if len(j)==1 and j[0]["postfix_queue_id"]==q and j[0]["observation_id"]==o and j[0]["remote_system"]=="stationb" else 1)
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
if marker not in src:
    raise SystemExit('ERROR: compressed queue tail marker not found')
src = src.replace(marker, mapping, 1)

tail_marker = 'section "State 3: transfer compressed mail through HERMES/Mercury"\n'
if tail_marker not in src:
    raise SystemExit('ERROR: State 3 marker not found')
src = src.split(tail_marker, 1)[0]
src += r'''section "State 3: deliver exact mapped job over simulated HERMES/Mercury link"
ATTEMPT_ID="$(cat /proc/sys/kernel/random/uuid)"
printf 'UUCP attempt ID: %s\n' "$ATTEMPT_ID"
docker exec -d \
    -e "OCEANMAIL_ATTEMPT_ID=$ATTEMPT_ID" \
    "$A_NAME" /bin/bash "$ATTEMPT_WRAPPER_CONTAINER_PATH" \
        /state/station.db "$RECORDER_CONTAINER_PATH" stationb \
        /evidence/uucico-phase4h.log -D -S stationb

SNAPSHOT=0
for _ in $(seq 1 80); do
    "$REPO_ROOT/target/debug/oceanmail-uucp-evidence" list --state-db "$STATE_DB" >"$RUN_DIR/attempt-running.json" 2>/dev/null || true
    if python3 - "$RUN_DIR/attempt-running.json" "$ATTEMPT_ID" "$UUCP_JOB_ID" <<'PYSNAP' 2>/dev/null
import json, pathlib, sys
p,a,j=sys.argv[1:]
d=json.loads(pathlib.Path(p).read_text())
aj=[x for x in d.get("attempt_jobs",[]) if x["attempt_id"]==a]
e=[x["event_type"] for x in d.get("attempt_events",[]) if x["attempt_id"]==a]
raise SystemExit(0 if len(aj)==1 and aj[0]["uucp_job_id"]==j and "uucico_attempt_started" in e and "queued_job_snapshot_recorded" in e else 1)
PYSNAP
    then SNAPSHOT=1; break; fi
    sleep 0.25
done
[[ "$SNAPSHOT" -eq 1 ]] || { printf 'FAIL: attempt snapshot missing\n' >&2; exit 1; }
printf 'PASS: exact mapped job was queued when successful caller attempt began\n'

section "Prove sender-side evidence has not fabricated remote receipt"
curl -fsS "http://$BIND/api/v1/queues/outbound/history" >"$RUN_DIR/history-before-receipt.json"
python3 - "$RUN_DIR/history-before-receipt.json" <<'PYNONE'
import json, pathlib, sys
h=json.loads(pathlib.Path(sys.argv[1]).read_text())
t=[e["event_type"] for e in h.get("events",[])]
assert "remote_mailbox_receipt_observed" not in t, t
print("PASS: no remote mailbox receipt event exists before far-side mailbox evidence")
PYNONE

section "Wait for actual Station B mailbox receipt"
MAILBOX_READY=0
for step in $(seq 1 90); do
    sleep 10
    RX_TOTAL="$(grep -oE 'rx_total=[0-9]+' /tmp/mB.log 2>/dev/null | cut -d= -f2 | sort -n | tail -n 1 || true)"
    RX_TOTAL="${RX_TOTAL:-0}"
    if docker exec "$B_NAME" sh -lc "test -f /var/mail/bob && grep -F '$MESSAGE_ID' /var/mail/bob >/dev/null 2>&1"; then
        MAILBOX_STATE="present"
        MAILBOX_READY=1
    else
        MAILBOX_STATE="pending"
    fi
    printf '[Phase 4H] elapsed=%ss Mercury-B-rx_total=%s remote-mailbox=%s\n' "$((step * 10))" "$RX_TOTAL" "$MAILBOX_STATE"
    [[ "$MAILBOX_READY" -eq 1 ]] && break
done
[[ "$MAILBOX_READY" -eq 1 ]] || {
    printf 'FAIL: exact Message-ID never appeared in Station B mailbox\n' >&2
    tail -n 180 "$RUN_DIR/a/evidence/uucico-phase4h.log" >&2 2>/dev/null || true
    tail -n 180 "$RUN_DIR/b/evidence/uucpd.log" >&2 2>/dev/null || true
    exit 1
}
printf 'PASS: exact Message-ID is present in Station B mailbox\n'

section "Verify far-side RFC evidence before recording OceanMail receipt"
docker cp "$B_NAME:/var/mail/bob" "$RUN_DIR/bob-mailbox.mbox" >/dev/null
python3 - "$RUN_DIR/bob-mailbox.mbox" "$MESSAGE_ID" "$SUBJECT" "$BODY_TOKEN" <<'PYMAIL' | tee "$RUN_DIR/mailbox-verification.txt"
import mailbox, sys
path, wanted_id, wanted_subject, body_token = sys.argv[1:]
box=mailbox.mbox(path)
matches=[m for m in box if (m.get('Message-ID') or '').strip()==wanted_id]
assert len(matches)==1, (wanted_id, len(matches))
msg=matches[0]
assert (msg.get('Subject') or '').strip()==wanted_subject, msg.get('Subject')
assert 'bob@stationb.test' in (msg.get('To') or ''), msg.get('To')
payload=msg.get_payload(decode=True)
if payload is None:
    payload=str(msg.get_payload()).encode()
body=payload.decode(msg.get_content_charset() or 'utf-8', errors='replace')
assert body_token in body
print(f"PASS: far-side mailbox proves Message-ID {wanted_id}")
print(f"PASS: Subject {wanted_subject}")
print("PASS: recipient and deterministic body token verified")
PYMAIL

section "Wait for caller attempt completion and sender queue retirement"
ATTEMPT_DONE=0
for _ in $(seq 1 120); do
    "$REPO_ROOT/target/debug/oceanmail-uucp-evidence" list --state-db "$STATE_DB" >"$RUN_DIR/attempt-finished.json" 2>/dev/null || true
    if python3 - "$RUN_DIR/attempt-finished.json" "$ATTEMPT_ID" <<'PYDONE' 2>/dev/null
import json, pathlib, sys
p,a=sys.argv[1:]
d=json.loads(pathlib.Path(p).read_text())
x=[v for v in d.get("attempts",[]) if v["attempt_id"]==a]
raise SystemExit(0 if len(x)==1 and x[0]["finished_at_unix"] is not None else 1)
PYDONE
    then ATTEMPT_DONE=1; break; fi
    sleep 0.5
done
[[ "$ATTEMPT_DONE" -eq 1 ]] || { printf 'FAIL: successful uucico attempt did not finish durably\n' >&2; exit 1; }

docker exec "$A_NAME" /usr/bin/uustat -a >"$RUN_DIR/uustat-after-success.txt" 2>&1 || true
if grep -F "$UUCP_JOB_ID" "$RUN_DIR/uustat-after-success.txt" >/dev/null; then
    printf 'FAIL: exact UUCP job remains queued after verified far-side mailbox receipt\n' >&2
    cat "$RUN_DIR/uustat-after-success.txt" >&2
    exit 1
fi
printf 'PASS: exact Taylor UUCP job retired after successful constrained transfer\n'

python3 - "$RUN_DIR/attempt-finished.json" "$ATTEMPT_ID" <<'PYATTEMPT'
import json, pathlib, sys
d=json.loads(pathlib.Path(sys.argv[1]).read_text())
a=[x for x in d["attempts"] if x["attempt_id"]==sys.argv[2]]
assert len(a)==1, a
print(f"Observed caller process outcome: exit={a[0]['process_exit_code']} outcome={a[0]['process_outcome']}")
print("SEMANTIC: caller process outcome is transport evidence, not the source of the remote receipt claim")
PYATTEMPT

section "Persist remote mailbox receipt only from far-side evidence"
"$REPO_ROOT/target/debug/oceanmail-remote-receipt-evidence" record \
    --state-db "$STATE_DB" \
    --remote-system stationb \
    --uucp-job-id "$UUCP_JOB_ID" \
    --message-id "$MESSAGE_ID" \
    --receipt-kind mailbox_message_present \
    --source phase4h-stationb-mailbox \
    | tee "$RUN_DIR/receipt-record.json"

"$REPO_ROOT/target/debug/oceanmail-remote-receipt-evidence" list --state-db "$STATE_DB" >"$RUN_DIR/receipt-list.json"
curl -fsS "http://$BIND/api/v1/queues/outbound/history" >"$RUN_DIR/history-after-receipt.json"
python3 - \
    "$RUN_DIR/receipt-list.json" \
    "$RUN_DIR/history-after-receipt.json" \
    "$POSTFIX_QUEUE_ID" \
    "$OBSERVATION_ID" \
    "$UUCP_JOB_ID" \
    "$MESSAGE_ID" <<'PYRECEIPT'
import json, pathlib, sys
rp,hp,q,o,j,m=sys.argv[1:]
r=json.loads(pathlib.Path(rp).read_text())
h=json.loads(pathlib.Path(hp).read_text())
assert r["source"]=="station-sqlite-remote-receipt-evidence", r
assert len(r["receipts"])==1, r
x=r["receipts"][0]
assert x["postfix_queue_id"]==q, x
assert x["observation_id"]==o, x
assert x["remote_system"]=="stationb", x
assert x["uucp_job_id"]==j, x
assert x["message_id"]==m, x
assert x["receipt_kind"]=="mailbox_message_present", x
assert x["evidence_source"]=="phase4h-stationb-mailbox", x
assert x["evidence_type"]=="remote_mailbox_receipt_observed", x
t=[e["event_type"] for e in h["events"]]
assert t.count("remote_mailbox_receipt_observed")==1, t
print("PASS: far-side mailbox evidence is durably correlated to the original Postfix observation and exact Taylor job")
print("SEMANTIC: remote_mailbox_receipt_observed proves mailbox presence of the exact Message-ID; it does not prove that a human read the message")
PYRECEIPT

section "Restart Station and prove receipt evidence durability"
BEFORE_SHA="$(sha256sum "$RUN_DIR/receipt-list.json" | awk '{print $1}')"
stop_service
start_service "$SERVICE_RESTART_LOG"
"$REPO_ROOT/target/debug/oceanmail-remote-receipt-evidence" list --state-db "$STATE_DB" >"$RUN_DIR/receipt-after-restart.json"
AFTER_SHA="$(sha256sum "$RUN_DIR/receipt-after-restart.json" | awk '{print $1}')"
[[ "$BEFORE_SHA" == "$AFTER_SHA" ]] || {
    printf 'FAIL: remote receipt evidence changed across Station restart\n' >&2
    diff -u "$RUN_DIR/receipt-list.json" "$RUN_DIR/receipt-after-restart.json" >&2 || true
    exit 1
}
printf 'PASS: remote mailbox receipt evidence survives Station restart unchanged\n'

section "Phase 4H result"
printf 'PASS: successful simulated far-side mailbox receipt evidence proven without physical radio\n'
printf 'Postfix queue ID: %s\n' "$POSTFIX_QUEUE_ID"
printf 'Station observation ID: %s\n' "$OBSERVATION_ID"
printf 'Taylor UUCP job: stationb/%s\n' "$UUCP_JOB_ID"
printf 'UUCP attempt ID: %s\n' "$ATTEMPT_ID"
printf 'Remote receipt source: Station B mailbox exact Message-ID evidence\n'
printf 'Physical-radio Phase 5 was not started\n'
printf 'Evidence directory: %s\n' "$RUN_DIR"
'''

dst_path.write_text(src)
PY

chmod +x "$RUNTIME_COPY"
bash -n "$RUNTIME_COPY" || {
    echo "ERROR: generated Phase 4H runtime script failed bash syntax validation" >&2
    exit 2
}

set +e
bash "$RUNTIME_COPY"
RC=$?
set -e
exit "$RC"
