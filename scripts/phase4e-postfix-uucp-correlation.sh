#!/usr/bin/env bash
# OceanMail Station 0.2 — Phase 4E deterministic Postfix -> Taylor UUCP correlation
#
# Acceptance stops once one known Postfix message is durably mapped to the exact
# Taylor UUCP crmail job created by HERMES uuxcomp. It deliberately does NOT run
# uucico, Mercury, a simulated constrained link, or physical radio hardware.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_BASE="${LOG_BASE:-$HOME/oceanmail-logs}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$LOG_BASE/phase4e-postfix-uucp-correlation-$RUN_ID"
PHASE1_IMAGE="${PHASE1_IMAGE:-oceanmail-uucp-lab:phase1}"
PHASE2_IMAGE="${PHASE2_IMAGE:-oceanmail-mail-lab:phase2}"
PHASE2B_IMAGE="${PHASE2B_IMAGE:-oceanmail-mail-lab:phase2b}"
HERMES_NET_SHA="0fee4a53f54074ad6237b9fa1083a272cac89f60"
POSTFIX_NAME="${POSTFIX_NAME:-oceanmail-phase4e-postfix}"
PORT="${PORT:-18084}"
BIND="127.0.0.1:$PORT"
STATE_DIR="$RUN_DIR/state"
STATE_DB="$STATE_DIR/station.db"
POSTQUEUE_ADAPTER="$RUN_DIR/postqueue-real"
SERVICE_LOG="$RUN_DIR/station-service.log"
SERVICE_RESTART_LOG="$RUN_DIR/station-service-restart.log"
SERVICE_PID=""
MESSAGE_ID="<phase4e-$RUN_ID@stationa.test>"
BODY_TOKEN="OceanMail-Phase4E-$RUN_ID-body-check"
WRAPPER_CONTAINER_PATH="/opt/oceanmail/oceanmail-uuxcomp-correlator.sh"
RECORDER_CONTAINER_PATH="/opt/oceanmail/oceanmail-uucp-evidence"

mkdir -p "$STATE_DIR" "$RUN_DIR/a/evidence" "$RUN_DIR/a/etc-uucp"
chmod 0777 "$STATE_DIR" "$RUN_DIR/a/evidence"

section() { printf '\n== %s ==\n' "$1"; }

stop_service() {
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
    docker rm -f "$POSTFIX_NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for cmd in cargo rustc rustfmt docker curl python3 ss; do
    command -v "$cmd" >/dev/null 2>&1 || {
        printf 'ERROR: missing command: %s\n' "$cmd" >&2
        exit 2
    }
done

if ss -ltn 2>/dev/null | grep -q ":$PORT[[:space:]]"; then
    printf 'ERROR: API port %s is already in use\n' "$PORT" >&2
    exit 2
fi

section "Phase 4E environment"
printf 'UTC run id: %s\n' "$RUN_ID"
printf 'Repository: %s\n' "$REPO_ROOT"
printf 'Station API bind: %s\n' "$BIND"
printf 'State DB: %s\n' "$STATE_DB"
printf 'HERMES net: %s\n' "$HERMES_NET_SHA"
printf 'Evidence directory: %s\n' "$RUN_DIR"
printf 'Acceptance boundary: Postfix -> HERMES uuxcomp -> exact queued Taylor UUCP crmail job\n'
printf 'Not started by this test: uucico, Mercury, constrained-link transfer, physical radio\n'

section "Verify Station source baseline"
cd "$REPO_ROOT"
cargo fmt -- --check
cargo test --all-targets | tee "$RUN_DIR/cargo-test.log"
cargo build --bins | tee "$RUN_DIR/cargo-build.log"
test -x "$REPO_ROOT/target/debug/oceanmail-station"
test -x "$REPO_ROOT/target/debug/oceanmail-uucp-evidence"
test -r "$REPO_ROOT/scripts/oceanmail-uuxcomp-correlator.sh"
printf 'PASS: Station daemon and UUCP evidence helper build and tests pass\n'

section "Build disposable HERMES uuxcomp/Taylor UUCP/Postfix image"
docker build --build-arg "HERMES_NET_SHA=$HERMES_NET_SHA" \
    -f "$REPO_ROOT/lab/phase1/Dockerfile" -t "$PHASE1_IMAGE" "$REPO_ROOT" \
    >"$RUN_DIR/phase1-image-build.log" 2>&1 || {
        tail -n 180 "$RUN_DIR/phase1-image-build.log" >&2 || true
        exit 2
    }
docker build -f "$REPO_ROOT/lab/phase2/Dockerfile" -t "$PHASE2_IMAGE" "$REPO_ROOT" \
    >"$RUN_DIR/phase2-image-build.log" 2>&1 || {
        tail -n 180 "$RUN_DIR/phase2-image-build.log" >&2 || true
        exit 2
    }
docker build \
    --build-arg "HERMES_NET_SHA=$HERMES_NET_SHA" \
    -f "$REPO_ROOT/lab/phase2b/Dockerfile" -t "$PHASE2B_IMAGE" "$REPO_ROOT" \
    >"$RUN_DIR/phase2b-image-build.log" 2>&1 || {
        tail -n 220 "$RUN_DIR/phase2b-image-build.log" >&2 || true
        exit 2
    }
printf 'PASS: pinned HERMES uuxcomp/Taylor UUCP/Postfix lab image ready\n'

section "Prepare one isolated Taylor UUCP station"
cat >"$RUN_DIR/a/etc-uucp/config" <<'EOF'
nodename stationa
pubdir /var/spool/uucppublic
EOF
cat >"$RUN_DIR/a/etc-uucp/port" <<'EOF'
port HFP
type pipe
command /usr/local/bin/uuport -e /evidence/uuport.log
EOF
cat >"$RUN_DIR/a/etc-uucp/sys" <<'EOF'
protocol y
protocol-parameter y packet-size 512
protocol-parameter y timeout 540
chat-timeout 200
system stationb
call-login *
call-password *
time any
port HFP
chat "" \r
local-send /
remote-send ~
local-receive ~
remote-receive ~
command-path /usr/local/bin /usr/sbin /usr/bin
commands crmail
EOF

docker rm -f "$POSTFIX_NAME" >/dev/null 2>&1 || true
docker run -d --name "$POSTFIX_NAME" --hostname stationa --network none \
    -v "$RUN_DIR/a/etc-uucp:/etc/uucp:ro" \
    -v "$RUN_DIR/a/evidence:/evidence" \
    -v "$STATE_DIR:/state" \
    -v "$REPO_ROOT/scripts/oceanmail-uuxcomp-correlator.sh:$WRAPPER_CONTAINER_PATH:ro" \
    -v "$REPO_ROOT/target/debug/oceanmail-uucp-evidence:$RECORDER_CONTAINER_PATH:ro" \
    "$PHASE2B_IMAGE" sleep infinity >/dev/null

docker exec "$POSTFIX_NAME" /bin/bash -lc \
    'test -x /usr/local/bin/uuxcomp && test -x /usr/bin/uux && test -x /usr/bin/uustat && test -x /opt/oceanmail/oceanmail-uucp-evidence && test -r /opt/oceanmail/oceanmail-uuxcomp-correlator.sh'
printf 'PASS: isolated station has pinned upstream uuxcomp/Taylor uux and OceanMail correlation boundary\n'

section "Configure held Postfix uucp pipe with authoritative queue-id handoff"
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'compatibility_level = 3.6'
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'myhostname = stationa.test'
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'mydomain = stationa.test'
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'myorigin = $myhostname'
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'inet_interfaces = loopback-only'
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'inet_protocols = ipv4'
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'mydestination = stationa.test, localhost'
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'relayhost ='
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'default_transport = uucp:stationb'
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'defer_transports = uucp'
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'maillog_file_prefixes = /var, /dev/stdout, /evidence'
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'maillog_file = /evidence/postfix.log'

docker exec "$POSTFIX_NAME" /bin/bash -lc "cat >>/etc/postfix/master.cf <<'EOF'
uucp      unix  -       n       n       -       -       pipe
  flags=F user=uucp argv=/bin/bash $WRAPPER_CONTAINER_PATH \${queue_id} \${nexthop} /state/station.db $RECORDER_CONTAINER_PATH /evidence/uuxcomp-correlation.log -r -n -z -a\${sender} - \${nexthop}!crmail (\${recipient})
EOF"

docker exec "$POSTFIX_NAME" /usr/sbin/postfix check
docker exec "$POSTFIX_NAME" /usr/sbin/postfix start
sleep 2
docker exec "$POSTFIX_NAME" pgrep -x master >/dev/null
printf 'PASS: Postfix is running with uucp transport held before uuxcomp\n'

section "Create Station adapter to the real container Postfix queue"
DOCKER_BIN="$(command -v docker)"
cat >"$POSTQUEUE_ADAPTER" <<EOF
#!/bin/sh
if [ "\${1:-}" != "-j" ]; then
    echo "Phase 4E adapter supports only postqueue -j" >&2
    exit 64
fi
exec "$DOCKER_BIN" exec "$POSTFIX_NAME" /usr/sbin/postqueue -j
EOF
chmod 0755 "$POSTQUEUE_ADAPTER"

start_service() {
    local log_file="$1"
    stop_service
    (
        umask 000
        export OCEANMAIL_BIND="$BIND"
        export OCEANMAIL_STATE_DB="$STATE_DB"
        export OCEANMAIL_STATION_NAME="phase4e-postfix-uucp-correlation"
        export OCEANMAIL_POSTQUEUE="$POSTQUEUE_ADAPTER"
        export OCEANMAIL_QUEUE_POLL_SECONDS=1
        exec "$REPO_ROOT/target/debug/oceanmail-station"
    ) >"$log_file" 2>&1 &
    SERVICE_PID=$!

    for _ in $(seq 1 50); do
        if curl -fsS "http://$BIND/api/v1/health" >/dev/null 2>&1; then
            return 0
        fi
        if ! kill -0 "$SERVICE_PID" 2>/dev/null; then
            printf 'ERROR: Station service exited during startup\n' >&2
            cat "$log_file" >&2 || true
            return 1
        fi
        sleep 0.2
    done
    printf 'ERROR: Station service did not become ready\n' >&2
    return 1
}

section "Start Station and verify conservative security boundary"
start_service "$SERVICE_LOG"
OBSERVER_READY=0
for _ in $(seq 1 30); do
    if curl -fsS "http://$BIND/api/v1/queues/outbound/observer" >"$RUN_DIR/observer-initial.json" \
        && python3 - "$RUN_DIR/observer-initial.json" <<'PY'
import json, pathlib, sys
s=json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(0 if s.get("last_success_at_unix") is not None and s.get("last_observed_entry_count") == 0 else 1)
PY
    then
        OBSERVER_READY=1
        break
    fi
    sleep 0.25
done
[[ "$OBSERVER_READY" -eq 1 ]] || { printf 'FAIL: Station observer did not establish the initial empty Postfix state\n' >&2; exit 1; }
curl -fsS "http://$BIND/api/v1/security/storage" | tee "$RUN_DIR/storage-security.json"
python3 - "$RUN_DIR/storage-security.json" <<'PY'
import json, pathlib, sys
s=json.loads(pathlib.Path(sys.argv[1]).read_text())
for key in (
    "production_storage_ready",
    "application_storage_encryption",
    "per_user_key_separation",
    "host_volume_encryption_verified",
):
    assert s[key] is False, (key, s)
print("PASS: Phase 4E did not weaken production storage-security gates")
PY
chmod 0777 "$STATE_DIR"
chmod 0666 "$STATE_DB" "$STATE_DB-wal" "$STATE_DB-shm" 2>/dev/null || true

section "Submit exactly one deterministic RFC message while uucp is held"
cat >"$RUN_DIR/source-message.eml" <<EOF
From: Alice <alice@stationa.test>
To: Bob <bob@stationb.test>
Date: Fri, 04 Sep 2026 12:00:00 -0800
Message-ID: $MESSAGE_ID
Subject: OceanMail Phase 4E Postfix to UUCP correlation
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: 7bit

$BODY_TOKEN
This message must become exactly one HERMES-compressed Taylor UUCP crmail job.
Phase 4E proves queue identity correlation only; it does not claim transmission or delivery.
EOF

docker exec -i "$POSTFIX_NAME" /usr/sbin/sendmail -i \
    -f alice@stationa.test bob@stationb.test <"$RUN_DIR/source-message.eml"

RAW_QUEUE="$RUN_DIR/postfix-held.jsonl"
DEFERRED=0
for _ in $(seq 1 40); do
    docker exec "$POSTFIX_NAME" /usr/sbin/postqueue -j >"$RAW_QUEUE"
    if python3 - "$RAW_QUEUE" <<'PY'
import json, pathlib, sys
rows=[json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
raise SystemExit(0 if len(rows) == 1 and rows[0].get("queue_name") == "deferred" else 1)
PY
    then
        DEFERRED=1
        break
    fi
    sleep 0.5
done
[[ "$DEFERRED" -eq 1 ]] || { printf 'FAIL: exactly one message did not reach held deferred Postfix state\n' >&2; exit 1; }

SEEN=0
for _ in $(seq 1 40); do
    curl -fsS "http://$BIND/api/v1/queues/outbound/history" >"$RUN_DIR/history-held.json"
    if python3 - "$RUN_DIR/history-held.json" <<'PY'
import json, pathlib, sys
h=json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(0 if len(h.get("jobs", [])) == 1 and h["jobs"][0].get("present_in_postfix") is True else 1)
PY
    then
        SEEN=1
        break
    fi
    sleep 0.25
done
[[ "$SEEN" -eq 1 ]] || { printf 'FAIL: Station observer did not persist held Postfix observation\n' >&2; exit 1; }

read -r POSTFIX_QUEUE_ID OBSERVATION_ID < <(python3 - "$RAW_QUEUE" "$RUN_DIR/history-held.json" <<'PY'
import json, pathlib, sys
rows=[json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
h=json.loads(pathlib.Path(sys.argv[2]).read_text())
assert len(rows) == 1 and len(h["jobs"]) == 1
raw=rows[0]; job=h["jobs"][0]
assert job["queue_id"] == raw["queue_id"], (job,raw)
assert job["present_in_postfix"] is True
assert [e["event_type"] for e in h["events"]] == ["first_seen"], h
print(raw["queue_id"], job["observation_id"])
PY
)
printf 'Postfix queue ID: %s\n' "$POSTFIX_QUEUE_ID"
printf 'Station observation ID: %s\n' "$OBSERVATION_ID"

docker exec "$POSTFIX_NAME" /usr/bin/uustat -a >"$RUN_DIR/uustat-before.txt" 2>&1 || true
if grep -q 'Executing[[:space:]]\+crmail' "$RUN_DIR/uustat-before.txt"; then
    printf 'FAIL: a crmail UUCP job exists before held Postfix release\n' >&2
    cat "$RUN_DIR/uustat-before.txt" >&2
    exit 1
fi
printf 'PASS: exact Postfix observation exists and no UUCP crmail job exists before release\n'

section "Release the one Postfix message into HERMES uuxcomp"
chmod 0777 "$STATE_DIR"
chmod 0666 "$STATE_DB" "$STATE_DB-wal" "$STATE_DB-shm" 2>/dev/null || true
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'defer_transports ='
docker exec "$POSTFIX_NAME" /usr/sbin/postfix reload
docker exec "$POSTFIX_NAME" /usr/sbin/postqueue -f

MAPPED=0
for _ in $(seq 1 60); do
    "$REPO_ROOT/target/debug/oceanmail-uucp-evidence" list --state-db "$STATE_DB" \
        >"$RUN_DIR/uucp-evidence.json" 2>"$RUN_DIR/uucp-evidence.err" || true
    if python3 - "$RUN_DIR/uucp-evidence.json" 2>/dev/null <<'PY'
import json, pathlib, sys
try:
    data=json.loads(pathlib.Path(sys.argv[1]).read_text())
except Exception:
    raise SystemExit(1)
raise SystemExit(0 if len(data.get("jobs", [])) == 1 else 1)
PY
    then
        MAPPED=1
        break
    fi
    sleep 0.5
done
[[ "$MAPPED" -eq 1 ]] || {
    printf 'FAIL: no durable Postfix -> UUCP mapping appeared\n' >&2
    cat "$RUN_DIR/a/evidence/uuxcomp-correlation.log" >&2 2>/dev/null || true
    cat "$RUN_DIR/a/evidence/postfix.log" >&2 2>/dev/null || true
    cat "$RUN_DIR/uucp-evidence.err" >&2 2>/dev/null || true
    exit 1
}

docker exec "$POSTFIX_NAME" /usr/bin/uustat -a >"$RUN_DIR/uustat-after.txt" 2>&1 || true
cat "$RUN_DIR/uustat-after.txt"
python3 - \
    "$RUN_DIR/uucp-evidence.json" \
    "$RUN_DIR/uustat-after.txt" \
    "$POSTFIX_QUEUE_ID" \
    "$OBSERVATION_ID" <<'PY'
import json, pathlib, re, sys
mapping_path, uustat_path, queue_id, observation_id = sys.argv[1:]
data=json.loads(pathlib.Path(mapping_path).read_text())
assert data["source"] == "station-sqlite-uucp-evidence", data
assert len(data["jobs"]) == 1, data
job=data["jobs"][0]
assert job["postfix_queue_id"] == queue_id, job
assert job["observation_id"] == observation_id, job
assert job["remote_system"] == "stationb", job
assert job["uucp_command"] == "crmail", job
assert job["evidence_type"] == "uucp_job_created", job
assert job["queued_bytes"] > 0, job
lines=[line for line in pathlib.Path(uustat_path).read_text().splitlines() if line.strip()]
matches=[line for line in lines if line.split()[0] == job["uucp_job_id"]]
assert len(matches) == 1, (job, lines)
line=matches[0]
fields=line.split()
assert len(fields) >= 2 and fields[1] == "stationb", line
assert "Executing crmail" in line, line
m=re.search(r"\(sending ([0-9]+) bytes\)", line)
assert m and int(m.group(1)) == job["queued_bytes"], (job,line)
print(f"PASS: {observation_id} -> stationb/{job['uucp_job_id']} ({job['queued_bytes']} bytes, crmail)")
PY

section "Prove evidence event and conservative Postfix disappearance semantics"
LEFT=0
for _ in $(seq 1 40); do
    docker exec "$POSTFIX_NAME" /usr/sbin/postqueue -j >"$RUN_DIR/postfix-after-release.jsonl"
    curl -fsS "http://$BIND/api/v1/queues/outbound/history" >"$RUN_DIR/history-after-release.json"
    if [[ ! -s "$RUN_DIR/postfix-after-release.jsonl" ]] \
        && python3 - "$RUN_DIR/history-after-release.json" <<'PY'
import json, pathlib, sys
h=json.loads(pathlib.Path(sys.argv[1]).read_text())
types=[e["event_type"] for e in h.get("events", [])]
raise SystemExit(0 if "uucp_job_created" in types and "left_postfix_queue" in types else 1)
PY
    then
        LEFT=1
        break
    fi
    sleep 0.5
done
[[ "$LEFT" -eq 1 ]] || { printf 'FAIL: expected durable uucp_job_created plus later Postfix disappearance evidence\n' >&2; exit 1; }

python3 - "$RUN_DIR/history-after-release.json" "$OBSERVATION_ID" <<'PY'
import json, pathlib, sys
h=json.loads(pathlib.Path(sys.argv[1]).read_text())
observation_id=sys.argv[2]
assert len(h["jobs"]) == 1, h
job=h["jobs"][0]
assert job["observation_id"] == observation_id, job
assert job["present_in_postfix"] is False, job
assert job["evidence_state"] == "left_postfix_queue", job
types=[e["event_type"] for e in h["events"]]
assert types.count("uucp_job_created") == 1, types
assert types.count("left_postfix_queue") == 1, types
assert types.index("uucp_job_created") < types.index("left_postfix_queue"), types
assert not any("transmitted" in t or "delivered" in t or "received" in t or "acknowledged" in t for t in types), types
print("PASS: UUCP job creation is recorded before conservative left_postfix_queue evidence")
print("PASS: no transmitted/delivered/received/acknowledged event was fabricated")
PY

section "Restart Station and prove mapping/event durability"
stop_service
start_service "$SERVICE_RESTART_LOG"
for _ in $(seq 1 30); do
    if curl -fsS "http://$BIND/api/v1/queues/outbound/history" >"$RUN_DIR/history-after-restart.json"; then
        break
    fi
    sleep 0.25
done
"$REPO_ROOT/target/debug/oceanmail-uucp-evidence" list --state-db "$STATE_DB" \
    >"$RUN_DIR/uucp-evidence-after-restart.json"
docker exec "$POSTFIX_NAME" /usr/bin/uustat -a >"$RUN_DIR/uustat-after-restart.txt" 2>&1 || true

python3 - \
    "$RUN_DIR/uucp-evidence.json" \
    "$RUN_DIR/uucp-evidence-after-restart.json" \
    "$RUN_DIR/history-after-restart.json" \
    "$RUN_DIR/uustat-after-restart.txt" <<'PY'
import json, pathlib, sys
before=json.loads(pathlib.Path(sys.argv[1]).read_text())
after=json.loads(pathlib.Path(sys.argv[2]).read_text())
h=json.loads(pathlib.Path(sys.argv[3]).read_text())
uustat=pathlib.Path(sys.argv[4]).read_text()
assert before == after, (before,after)
assert len(after["jobs"]) == 1, after
job=after["jobs"][0]
assert job["uucp_job_id"] in uustat, (job,uustat)
types=[e["event_type"] for e in h["events"]]
assert types.count("uucp_job_created") == 1, types
assert types.count("left_postfix_queue") == 1, types
print("PASS: Postfix -> UUCP mapping survives Station restart unchanged")
print("PASS: exact UUCP job is still queued because no transport attempt was started")
PY

section "Phase 4E result"
printf 'PASS: deterministic Postfix observation -> exact Taylor UUCP job correlation proven\n'
printf 'Postfix queue ID: %s\n' "$POSTFIX_QUEUE_ID"
printf 'Station observation ID: %s\n' "$OBSERVATION_ID"
python3 - "$RUN_DIR/uucp-evidence-after-restart.json" <<'PY'
import json, pathlib, sys
job=json.loads(pathlib.Path(sys.argv[1]).read_text())["jobs"][0]
print(f"Taylor UUCP job: {job['remote_system']}/{job['uucp_job_id']}")
print(f"Queued crmail bytes: {job['queued_bytes']}")
PY
printf 'Semantic boundary: uucp_job_created = queued Taylor UUCP work, not transmitted or delivered\n'
printf 'No uucico/Mercury/physical-radio transmission was started\n'
printf 'Evidence directory: %s\n' "$RUN_DIR"
