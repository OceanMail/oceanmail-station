#!/usr/bin/env bash
# OceanMail Station 0.2 — Phase 4C durable outbound queue evidence acceptance
# Proves Postfix observations persist in Station SQLite across queue disappearance
# and daemon restart without inferring transmission or delivery.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_BASE="${LOG_BASE:-$HOME/oceanmail-logs}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$LOG_BASE/phase4c-durable-queue-history-$RUN_ID"
POSTFIX_IMAGE="${POSTFIX_IMAGE:-oceanmail-phase4b-postfix:lab}"
POSTFIX_NAME="${POSTFIX_NAME:-oceanmail-phase4c-postfix}"
PORT="${PORT:-18082}"
BIND="127.0.0.1:$PORT"
STATE_DB="$RUN_DIR/state/station.db"
POSTQUEUE_ADAPTER="$RUN_DIR/postqueue-real"
SERVICE_LOG="$RUN_DIR/station-service.log"
SERVICE_PID=""
MESSAGE_ID="<phase4c-$RUN_ID@stationa.test>"
BODY_TOKEN="OceanMail-Phase4C-$RUN_ID-body-check"

mkdir -p "$RUN_DIR/state"
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

section "Phase 4C environment"
printf 'UTC run id: %s\n' "$RUN_ID"
printf 'Repository: %s\n' "$REPO_ROOT"
printf 'Station API bind: %s\n' "$BIND"
printf 'State DB: %s\n' "$STATE_DB"
printf 'Evidence directory: %s\n' "$RUN_DIR"

section "Verify Station service baseline"
cd "$REPO_ROOT"
cargo fmt -- --check
cargo test --all-targets | tee "$RUN_DIR/cargo-test.log"
cargo build | tee "$RUN_DIR/cargo-build.log"
printf 'PASS: Station service builds and unit tests pass\n'

section "Build and configure disposable real Postfix instance"
if ! docker build \
    -f "$REPO_ROOT/lab/phase4b/Dockerfile" \
    -t "$POSTFIX_IMAGE" \
    "$REPO_ROOT" >"$RUN_DIR/postfix-image-build.log" 2>&1; then
    printf 'ERROR: Postfix image build failed\n' >&2
    tail -n 160 "$RUN_DIR/postfix-image-build.log" >&2 || true
    exit 2
fi

docker rm -f "$POSTFIX_NAME" >/dev/null 2>&1 || true
docker run -d --name "$POSTFIX_NAME" --hostname stationa.test "$POSTFIX_IMAGE" >/dev/null

docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'compatibility_level = 3.6'
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'myhostname = stationa.test'
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'mydomain = stationa.test'
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'myorigin = $myhostname'
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'inet_interfaces = loopback-only'
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'inet_protocols = ipv4'
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'mydestination = stationa.test, localhost'
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'default_transport = phase4b'
docker exec "$POSTFIX_NAME" /usr/sbin/postconf -e 'relay_transport = phase4b'
docker exec "$POSTFIX_NAME" /bin/sh -lc "cat >> /etc/postfix/master.cf <<'EOF'
phase4b unix - n n - - pipe flags=Rq user=nobody argv=/usr/local/bin/phase4b-tempfail
EOF"
docker exec "$POSTFIX_NAME" /usr/sbin/postfix check
docker exec "$POSTFIX_NAME" /usr/sbin/postfix start
sleep 2
docker exec "$POSTFIX_NAME" pgrep -x master >/dev/null
printf 'PASS: disposable real Postfix instance running\n'

section "Create Station adapter to live Postfix postqueue"
DOCKER_BIN="$(command -v docker)"
cat >"$POSTQUEUE_ADAPTER" <<EOF
#!/bin/sh
if [ "\${1:-}" != "-j" ]; then
    echo "Phase 4C adapter supports only postqueue -j" >&2
    exit 64
fi
exec "$DOCKER_BIN" exec "$POSTFIX_NAME" /usr/sbin/postqueue -j
EOF
chmod 0755 "$POSTQUEUE_ADAPTER"

start_service() {
    local log_file="$1"
    stop_service
    OCEANMAIL_BIND="$BIND" \
        OCEANMAIL_STATE_DB="$STATE_DB" \
        OCEANMAIL_STATION_NAME="phase4c-durable-history" \
        OCEANMAIL_POSTQUEUE="$POSTQUEUE_ADAPTER" \
        "$REPO_ROOT/target/debug/oceanmail-station" >"$log_file" 2>&1 &
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

section "Start Station and prove empty durable history"
start_service "$SERVICE_LOG"
curl -fsS "http://$BIND/api/v1/station" | tee "$RUN_DIR/station-first.json"
curl -fsS "http://$BIND/api/v1/queues/outbound" | tee "$RUN_DIR/queue-empty.json"
curl -fsS "http://$BIND/api/v1/queues/outbound/history" | tee "$RUN_DIR/history-empty.json"
python3 - "$RUN_DIR/history-empty.json" <<'PY'
import json, pathlib, sys
h = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert h["source"] == "station-sqlite-postfix-evidence", h
assert h["jobs"] == [], h
assert h["events"] == [], h
print("PASS: fresh Station durable queue history is empty")
PY

section "Submit deterministic RFC message into real Postfix"
cat >"$RUN_DIR/source-message.txt" <<EOF
From: Alice <alice@stationa.test>
To: Bob <bob@stationb.test>
Subject: OceanMail Phase 4C durable queue history proof
Message-ID: $MESSAGE_ID
Date: Thu, 04 Sep 2026 08:00:00 -0800

$BODY_TOKEN
EOF

docker exec -i "$POSTFIX_NAME" /usr/sbin/sendmail -i \
    -f alice@stationa.test bob@stationb.test <"$RUN_DIR/source-message.txt"

RAW_QUEUE="$RUN_DIR/postqueue-before-delete.jsonl"
DEFERRED=0
for _ in $(seq 1 40); do
    docker exec "$POSTFIX_NAME" /usr/sbin/postqueue -j >"$RAW_QUEUE"
    if python3 - "$RAW_QUEUE" <<'PY'; then
import json, pathlib, sys
rows = [json.loads(x) for x in pathlib.Path(sys.argv[1]).read_text().splitlines() if x.strip()]
raise SystemExit(0 if any(row.get("queue_name") == "deferred" for row in rows) else 1)
PY
        DEFERRED=1
        break
    fi
    sleep 0.5
done
[[ "$DEFERRED" -eq 1 ]] || {
    echo 'FAIL: message did not reach deferred queue' >&2
    exit 1
}

section "Observe real Postfix job and persist first_seen evidence"
curl -fsS "http://$BIND/api/v1/queues/outbound" | tee "$RUN_DIR/queue-present.json"
curl -fsS "http://$BIND/api/v1/queues/outbound/history" | tee "$RUN_DIR/history-present.json"
python3 - "$RUN_DIR/station-first.json" "$RAW_QUEUE" "$RUN_DIR/history-present.json" <<'PY'
import json, pathlib, sys
station = json.loads(pathlib.Path(sys.argv[1]).read_text())
raw = [json.loads(x) for x in pathlib.Path(sys.argv[2]).read_text().splitlines() if x.strip()][0]
h = json.loads(pathlib.Path(sys.argv[3]).read_text())
assert len(h["jobs"]) == 1, h
job = h["jobs"][0]
expected = f'{station["station_id"]}:postfix:{raw["queue_id"]}:{raw["arrival_time"]}'
assert job["observation_id"] == expected, (expected, job)
assert job["present_in_postfix"] is True, job
assert job["evidence_state"] == "present_in_postfix", job
assert job["left_postfix_at_unix"] is None, job
assert [e["event_type"] for e in h["events"]] == ["first_seen"], h
print("PASS: first_seen queue evidence persisted in Station SQLite")
PY

section "Remove job from Postfix and record only left_postfix_queue evidence"
docker exec "$POSTFIX_NAME" /usr/sbin/postsuper -d ALL | tee "$RUN_DIR/postsuper-delete.txt"
docker exec "$POSTFIX_NAME" /usr/sbin/postqueue -j >"$RUN_DIR/postqueue-after-delete.jsonl"
if [[ -s "$RUN_DIR/postqueue-after-delete.jsonl" ]]; then
    echo 'FAIL: Postfix queue is not empty after postsuper delete' >&2
    cat "$RUN_DIR/postqueue-after-delete.jsonl" >&2
    exit 1
fi

curl -fsS "http://$BIND/api/v1/queues/outbound" | tee "$RUN_DIR/queue-after-delete.json"
curl -fsS "http://$BIND/api/v1/queues/outbound/history" | tee "$RUN_DIR/history-left.json"
python3 - "$RUN_DIR/history-left.json" <<'PY'
import json, pathlib, sys
h = json.loads(pathlib.Path(sys.argv[1]).read_text())
job = h["jobs"][0]
assert job["present_in_postfix"] is False, job
assert job["left_postfix_at_unix"] is not None, job
assert job["evidence_state"] == "left_postfix_queue", job
events = [e["event_type"] for e in h["events"]]
assert events == ["first_seen", "left_postfix_queue"], events
for forbidden in ("transmitted", "delivered", "received", "confirmed_receipt"):
    assert forbidden not in json.dumps(h).lower(), (forbidden, h)
print("PASS: disappearance persisted only as left_postfix_queue evidence")
PY

section "Restart Station and prove durable history survives"
FIRST_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["station_id"])' "$RUN_DIR/station-first.json")"
stop_service
start_service "$RUN_DIR/station-service-restart.log"
curl -fsS "http://$BIND/api/v1/station" | tee "$RUN_DIR/station-second.json"
curl -fsS "http://$BIND/api/v1/queues/outbound/history" | tee "$RUN_DIR/history-after-restart.json"
curl -fsS "http://$BIND/api/v1/security/storage" | tee "$RUN_DIR/storage-security.json"
python3 - "$RUN_DIR/station-second.json" "$RUN_DIR/history-after-restart.json" "$RUN_DIR/storage-security.json" "$FIRST_ID" <<'PY'
import json, pathlib, sys
station = json.loads(pathlib.Path(sys.argv[1]).read_text())
h = json.loads(pathlib.Path(sys.argv[2]).read_text())
security = json.loads(pathlib.Path(sys.argv[3]).read_text())
first_id = sys.argv[4]
assert station["station_id"] == first_id, (station, first_id)
assert len(h["jobs"]) == 1, h
assert h["jobs"][0]["evidence_state"] == "left_postfix_queue", h
assert [e["event_type"] for e in h["events"]] == ["first_seen", "left_postfix_queue"], h
assert security["production_storage_ready"] is False, security
assert security["application_storage_encryption"] is False, security
assert security["per_user_key_separation"] is False, security
print("PASS: durable evidence history and Station identity survived daemon restart")
PY

section "Phase 4C result"
printf 'PASS: durable Postfix queue evidence history accepted\n'
printf 'Message-ID: %s\n' "$MESSAGE_ID"
printf 'Body token: %s\n' "$BODY_TOKEN"
printf 'Evidence semantics: first_seen -> left_postfix_queue only\n'
printf 'No transmit/delivery/receipt state inferred\n'
printf 'Storage security remains laboratory-only / production_storage_ready=false\n'
printf 'Evidence directory: %s\n' "$RUN_DIR"
