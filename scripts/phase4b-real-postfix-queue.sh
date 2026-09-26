#!/usr/bin/env bash
# OceanMail Station 0.2 — Phase 4B real Postfix queue observation acceptance
# Proves the Station API observes a live Postfix queue through postqueue -j,
# without introducing a second OceanMail-owned mail queue or inventing delivery
# evidence beyond what Postfix actually reports.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_BASE="${LOG_BASE:-$HOME/oceanmail-logs}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$LOG_BASE/phase4b-real-postfix-$RUN_ID"
POSTFIX_IMAGE="${POSTFIX_IMAGE:-oceanmail-phase4b-postfix:lab}"
POSTFIX_NAME="${POSTFIX_NAME:-oceanmail-phase4b-postfix}"
PORT="${PORT:-18081}"
BIND="127.0.0.1:$PORT"
STATE_DB="$RUN_DIR/state/station.db"
POSTQUEUE_ADAPTER="$RUN_DIR/postqueue-real"
SERVICE_LOG="$RUN_DIR/station-service.log"
SERVICE_PID=""
MESSAGE_ID="<phase4b-$RUN_ID@stationa.test>"
BODY_TOKEN="OceanMail-Phase4B-$RUN_ID-body-check"

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

for cmd in cargo rustc rustfmt docker curl python3; do
    command -v "$cmd" >/dev/null 2>&1 || {
        printf 'ERROR: missing command: %s\n' "$cmd" >&2
        exit 2
    }
done

if ss -ltn 2>/dev/null | grep -q ":$PORT[[:space:]]"; then
    printf 'ERROR: API port %s is already in use\n' "$PORT" >&2
    exit 2
fi

section "Phase 4B environment"
printf 'UTC run id: %s\n' "$RUN_ID"
printf 'Repository: %s\n' "$REPO_ROOT"
printf 'Station API bind: %s\n' "$BIND"
printf 'Postfix container: %s\n' "$POSTFIX_NAME"
printf 'Evidence directory: %s\n' "$RUN_DIR"

section "Verify Station service baseline"
cd "$REPO_ROOT"
cargo fmt -- --check
cargo test --all-targets | tee "$RUN_DIR/cargo-test.log"
cargo build | tee "$RUN_DIR/cargo-build.log"
printf 'PASS: Station service builds and unit tests pass\n'

section "Build disposable real Postfix instance"
if ! docker build \
    -f "$REPO_ROOT/lab/phase4b/Dockerfile" \
    -t "$POSTFIX_IMAGE" \
    "$REPO_ROOT" >"$RUN_DIR/postfix-image-build.log" 2>&1; then
    printf 'ERROR: Phase 4B Postfix image build failed\n' >&2
    tail -n 160 "$RUN_DIR/postfix-image-build.log" >&2 || true
    exit 2
fi
printf 'PASS: disposable Postfix image ready\n'

docker rm -f "$POSTFIX_NAME" >/dev/null 2>&1 || true
docker run -d --name "$POSTFIX_NAME" --hostname stationa.test "$POSTFIX_IMAGE" >/dev/null

section "Configure deterministic temporary-failure transport"
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

docker exec "$POSTFIX_NAME" pgrep -x master >/dev/null || {
    printf 'ERROR: Postfix master did not start\n' >&2
    exit 2
}

docker exec "$POSTFIX_NAME" /usr/sbin/postconf mail_version default_transport relay_transport |
    tee "$RUN_DIR/postfix-config.txt"
printf 'PASS: real Postfix instance running with deterministic EX_TEMPFAIL transport\n'

section "Create Station adapter to the real Postfix postqueue interface"
DOCKER_BIN="$(command -v docker)"
cat >"$POSTQUEUE_ADAPTER" <<EOF
#!/bin/sh
if [ "\${1:-}" != "-j" ]; then
    echo "Phase 4B adapter supports only postqueue -j" >&2
    exit 64
fi
exec "$DOCKER_BIN" exec "$POSTFIX_NAME" /usr/sbin/postqueue -j
EOF
chmod 0755 "$POSTQUEUE_ADAPTER"
printf 'PASS: Station postqueue adapter targets the live Postfix instance\n'

start_service() {
    stop_service
    OCEANMAIL_BIND="$BIND" \
        OCEANMAIL_STATE_DB="$STATE_DB" \
        OCEANMAIL_STATION_NAME="phase4b-real-postfix" \
        OCEANMAIL_POSTQUEUE="$POSTQUEUE_ADAPTER" \
        "$REPO_ROOT/target/debug/oceanmail-station" >"$SERVICE_LOG" 2>&1 &
    SERVICE_PID=$!

    for _ in $(seq 1 50); do
        if curl -fsS "http://$BIND/api/v1/health" >/dev/null 2>&1; then
            return 0
        fi
        if ! kill -0 "$SERVICE_PID" 2>/dev/null; then
            printf 'ERROR: Station service exited during startup\n' >&2
            cat "$SERVICE_LOG" >&2 || true
            return 1
        fi
        sleep 0.2
    done

    printf 'ERROR: Station service did not become ready\n' >&2
    cat "$SERVICE_LOG" >&2 || true
    return 1
}

section "Start Station service against empty real Postfix queue"
start_service
curl -fsS "http://$BIND/api/v1/station" | tee "$RUN_DIR/station.json"
curl -fsS "http://$BIND/api/v1/queues/outbound" | tee "$RUN_DIR/queue-empty.json"
python3 - "$RUN_DIR/queue-empty.json" <<'PY'
import json, pathlib, sys
queue = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert queue["source"] == "postfix", queue
assert queue["entries"] == [], queue
print("PASS: Station API reports the initially empty real Postfix queue")
PY

section "Submit deterministic RFC message into real Postfix"
cat >"$RUN_DIR/source-message.txt" <<EOF
From: Alice <alice@stationa.test>
To: Bob <bob@stationb.test>
Subject: OceanMail Phase 4B real Postfix queue proof
Message-ID: $MESSAGE_ID
Date: Thu, 04 Sep 2026 08:00:00 -0800

$BODY_TOKEN
EOF

docker exec -i "$POSTFIX_NAME" /usr/sbin/sendmail -i \
    -f alice@stationa.test bob@stationb.test <"$RUN_DIR/source-message.txt"
printf 'PASS: real Postfix accepted the message locally\n'

section "Wait for real Postfix to record temporary delivery failure"
RAW_QUEUE="$RUN_DIR/postqueue-real.jsonl"
DEFERRED=0
for attempt in $(seq 1 40); do
    docker exec "$POSTFIX_NAME" /usr/sbin/postqueue -j >"$RAW_QUEUE"
    if python3 - "$RAW_QUEUE" <<'PY'; then
import json, pathlib, sys
rows = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines() if line.strip()]
raise SystemExit(0 if any(row.get("queue_name") == "deferred" for row in rows) else 1)
PY
        DEFERRED=1
        break
    fi
    sleep 0.5
done

if [[ "$DEFERRED" -ne 1 ]]; then
    printf 'FAIL: real Postfix message did not reach deferred queue\n' >&2
    cat "$RAW_QUEUE" >&2 || true
    docker exec "$POSTFIX_NAME" /usr/sbin/postqueue -p >&2 || true
    exit 1
fi

cat "$RAW_QUEUE" | tee "$RUN_DIR/postqueue-real-copy.jsonl"
docker exec "$POSTFIX_NAME" /usr/sbin/postqueue -p | tee "$RUN_DIR/postqueue-real-human.txt"
printf 'PASS: real Postfix reports the message in its deferred queue\n'

section "Compare Station API normalization with raw real Postfix JSON"
curl -fsS "http://$BIND/api/v1/queues/outbound" | tee "$RUN_DIR/queue-api-first.json"
sleep 1
curl -fsS "http://$BIND/api/v1/queues/outbound" | tee "$RUN_DIR/queue-api-second.json"
curl -fsS "http://$BIND/api/v1/security/storage" | tee "$RUN_DIR/storage-security.json"

python3 - \
    "$RUN_DIR/station.json" \
    "$RAW_QUEUE" \
    "$RUN_DIR/queue-api-first.json" \
    "$RUN_DIR/queue-api-second.json" \
    "$RUN_DIR/storage-security.json" <<'PY'
import json, pathlib, sys
station = json.loads(pathlib.Path(sys.argv[1]).read_text())
raw_rows = [json.loads(line) for line in pathlib.Path(sys.argv[2]).read_text().splitlines() if line.strip()]
first = json.loads(pathlib.Path(sys.argv[3]).read_text())
second = json.loads(pathlib.Path(sys.argv[4]).read_text())
security = json.loads(pathlib.Path(sys.argv[5]).read_text())

raw = next(row for row in raw_rows if row["queue_name"] == "deferred")
api = next(entry for entry in first["entries"] if entry["queue_id"] == raw["queue_id"])
api_second = next(entry for entry in second["entries"] if entry["queue_id"] == raw["queue_id"])

assert api["queue_name"] == raw["queue_name"] == "deferred", (raw, api)
assert api["delivery_state"] == "deferred", api
assert api["arrival_time_unix"] == raw["arrival_time"], (raw, api)
assert api["message_size"] == raw["message_size"], (raw, api)
assert api["sender"] == raw["sender"] == "alice@stationa.test", (raw, api)
assert [r["address"] for r in api["recipients"]] == [r["address"] for r in raw["recipients"]], (raw, api)

expected_id = f'{station["station_id"]}:postfix:{raw["queue_id"]}:{raw["arrival_time"]}'
assert api["observation_id"] == expected_id, (expected_id, api)
assert api_second["observation_id"] == expected_id, (expected_id, api_second)

# A queue observation is not a transmission or receipt claim.
assert api["delivery_state"] not in {"transmitted", "received", "confirmed_receipt"}, api

assert security["production_storage_ready"] is False, security
assert security["application_storage_encryption"] is False, security
assert security["per_user_key_separation"] is False, security

print("PASS: Station API matches real Postfix queue evidence and preserves stable observation identity")
PY

section "Phase 4B result"
printf 'PASS: OceanMail Station observed a real Postfix deferred queue through postqueue -j\n'
printf 'Message-ID: %s\n' "$MESSAGE_ID"
printf 'Body token: %s\n' "$BODY_TOKEN"
printf 'No parallel OceanMail mail queue was introduced\n'
printf 'No transmit/receipt state was inferred from Postfix queue membership\n'
printf 'Storage security remains laboratory-only / production_storage_ready=false\n'
printf 'Evidence directory: %s\n' "$RUN_DIR"
