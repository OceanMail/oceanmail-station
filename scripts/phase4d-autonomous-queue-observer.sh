#!/usr/bin/env bash
# OceanMail Station 0.2 — Phase 4D autonomous queue observer acceptance
# Proves the headless Station advances durable Postfix evidence without any
# client request triggering observation. Observer failures must not be treated
# as empty queues or fabricate left_postfix_queue evidence.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_BASE="${LOG_BASE:-$HOME/oceanmail-logs}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$LOG_BASE/phase4d-autonomous-queue-observer-$RUN_ID"
POSTFIX_IMAGE="${POSTFIX_IMAGE:-oceanmail-phase4b-postfix:lab}"
POSTFIX_NAME="${POSTFIX_NAME:-oceanmail-phase4d-postfix}"
PORT="${PORT:-18083}"
BIND="127.0.0.1:$PORT"
STATE_DB="$RUN_DIR/state/station.db"
POSTQUEUE_ADAPTER="$RUN_DIR/postqueue-real"
SERVICE_LOG="$RUN_DIR/station-service.log"
SERVICE_PID=""
MESSAGE_ID="<phase4d-$RUN_ID@stationa.test>"
BODY_TOKEN="OceanMail-Phase4D-$RUN_ID-body-check"

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
    chmod 0755 "$POSTQUEUE_ADAPTER" 2>/dev/null || true
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

section "Phase 4D environment"
printf 'UTC run id: %s\n' "$RUN_ID"
printf 'Repository: %s\n' "$REPO_ROOT"
printf 'Station API bind: %s\n' "$BIND"
printf 'State DB: %s\n' "$STATE_DB"
printf 'Observer interval: 1 second (lab override)\n'
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
    echo "Phase 4D adapter supports only postqueue -j" >&2
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
        OCEANMAIL_STATION_NAME="phase4d-autonomous-observer" \
        OCEANMAIL_POSTQUEUE="$POSTQUEUE_ADAPTER" \
        OCEANMAIL_QUEUE_POLL_SECONDS=1 \
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

section "Start Station and wait for autonomous empty-queue observation"
start_service "$SERVICE_LOG"
curl -fsS "http://$BIND/api/v1/station" | tee "$RUN_DIR/station-first.json"

READY=0
for _ in $(seq 1 30); do
    curl -fsS "http://$BIND/api/v1/queues/outbound/observer" >"$RUN_DIR/observer-initial.json"
    if python3 - "$RUN_DIR/observer-initial.json" <<'PY'; then
import json, pathlib, sys
s = json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(0 if s.get("last_success_at_unix") is not None and s.get("last_observed_entry_count") == 0 else 1)
PY
        READY=1
        break
    fi
    sleep 0.25
done
[[ "$READY" -eq 1 ]] || {
    echo 'FAIL: autonomous observer never completed initial poll' >&2
    exit 1
}

curl -fsS "http://$BIND/api/v1/queues/outbound/history" | tee "$RUN_DIR/history-empty.json"
python3 - "$RUN_DIR/observer-initial.json" "$RUN_DIR/history-empty.json" <<'PY'
import json, pathlib, sys
status = json.loads(pathlib.Path(sys.argv[1]).read_text())
h = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert status["mode"] == "autonomous_postfix_polling", status
assert status["poll_interval_seconds"] == 1, status
assert status["consecutive_failures"] == 0, status
assert status["last_error"] is None, status
assert h["jobs"] == [] and h["events"] == [], h
print("PASS: headless observer independently established empty Postfix state")
PY

section "Submit real message and prove background observer notices it without queue GET"
cat >"$RUN_DIR/source-message.txt" <<EOF
From: Alice <alice@stationa.test>
To: Bob <bob@stationb.test>
Subject: OceanMail Phase 4D autonomous observer proof
Message-ID: $MESSAGE_ID
Date: Thu, 04 Sep 2026 08:00:00 -0800

$BODY_TOKEN
EOF

docker exec -i "$POSTFIX_NAME" /usr/sbin/sendmail -i \
    -f alice@stationa.test bob@stationb.test <"$RUN_DIR/source-message.txt"

RAW_QUEUE="$RUN_DIR/postqueue-present.jsonl"
DEFERRED=0
for _ in $(seq 1 40); do
    docker exec "$POSTFIX_NAME" /usr/sbin/postqueue -j >"$RAW_QUEUE"
    if python3 - "$RAW_QUEUE" <<'PY'; then
import json, pathlib, sys
rows=[json.loads(x) for x in pathlib.Path(sys.argv[1]).read_text().splitlines() if x.strip()]
raise SystemExit(0 if any(r.get("queue_name") == "deferred" for r in rows) else 1)
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

SEEN=0
for _ in $(seq 1 30); do
    curl -fsS "http://$BIND/api/v1/queues/outbound/history" >"$RUN_DIR/history-present.json"
    if python3 - "$RUN_DIR/history-present.json" <<'PY'; then
import json, pathlib, sys
h=json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(0 if len(h.get("jobs", [])) == 1 and h["jobs"][0].get("present_in_postfix") is True else 1)
PY
        SEEN=1
        break
    fi
    sleep 0.25
done
[[ "$SEEN" -eq 1 ]] || {
    echo 'FAIL: background observer did not persist real queue arrival' >&2
    exit 1
}

python3 - "$RUN_DIR/history-present.json" <<'PY'
import json, pathlib, sys
h=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert [e["event_type"] for e in h["events"]] == ["first_seen"], h
print("PASS: real Postfix arrival persisted without any client queue-observation request")
PY

section "Break observer adapter and prove failure is not interpreted as empty queue"
chmod 000 "$POSTQUEUE_ADAPTER"
FAILED=0
for _ in $(seq 1 30); do
    curl -fsS "http://$BIND/api/v1/queues/outbound/observer" >"$RUN_DIR/observer-failed.json"
    if python3 - "$RUN_DIR/observer-failed.json" <<'PY'; then
import json, pathlib, sys
s=json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(0 if s.get("consecutive_failures", 0) >= 1 and s.get("last_error") else 1)
PY
        FAILED=1
        break
    fi
    sleep 0.25
done
[[ "$FAILED" -eq 1 ]] || {
    echo 'FAIL: observer failure was not surfaced' >&2
    exit 1
}

curl -fsS "http://$BIND/api/v1/health" >"$RUN_DIR/health-during-failure.json"
curl -fsS "http://$BIND/api/v1/queues/outbound/history" >"$RUN_DIR/history-during-failure.json"
python3 - "$RUN_DIR/health-during-failure.json" "$RUN_DIR/history-during-failure.json" <<'PY'
import json, pathlib, sys
health=json.loads(pathlib.Path(sys.argv[1]).read_text())
h=json.loads(pathlib.Path(sys.argv[2]).read_text())
assert health["status"] == "ok", health
assert h["jobs"][0]["present_in_postfix"] is True, h
assert [e["event_type"] for e in h["events"]] == ["first_seen"], h
print("PASS: observer failure left daemon healthy and did not fabricate queue disappearance")
PY

section "Restore observer adapter and prove autonomous recovery"
chmod 0755 "$POSTQUEUE_ADAPTER"
RECOVERED=0
for _ in $(seq 1 30); do
    curl -fsS "http://$BIND/api/v1/queues/outbound/observer" >"$RUN_DIR/observer-recovered.json"
    if python3 - "$RUN_DIR/observer-recovered.json" <<'PY'; then
import json, pathlib, sys
s=json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(0 if s.get("consecutive_failures") == 0 and s.get("last_error") is None and s.get("last_observed_entry_count") == 1 else 1)
PY
        RECOVERED=1
        break
    fi
    sleep 0.25
done
[[ "$RECOVERED" -eq 1 ]] || {
    echo 'FAIL: autonomous observer did not recover' >&2
    exit 1
}
printf 'PASS: autonomous observer recovered after adapter restoration\n'

section "Delete Postfix job and prove background observer records only left_postfix_queue"
docker exec "$POSTFIX_NAME" /usr/sbin/postsuper -d ALL | tee "$RUN_DIR/postsuper-delete.txt"
LEFT=0
for _ in $(seq 1 30); do
    curl -fsS "http://$BIND/api/v1/queues/outbound/history" >"$RUN_DIR/history-left.json"
    if python3 - "$RUN_DIR/history-left.json" <<'PY'; then
import json, pathlib, sys
h=json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(0 if h.get("jobs") and h["jobs"][0].get("evidence_state") == "left_postfix_queue" else 1)
PY
        LEFT=1
        break
    fi
    sleep 0.25
done
[[ "$LEFT" -eq 1 ]] || {
    echo 'FAIL: autonomous observer did not record queue disappearance' >&2
    exit 1
}

python3 - "$RUN_DIR/history-left.json" <<'PY'
import json, pathlib, sys
h=json.loads(pathlib.Path(sys.argv[1]).read_text())
assert h["jobs"][0]["present_in_postfix"] is False, h
assert [e["event_type"] for e in h["events"]] == ["first_seen", "left_postfix_queue"], h
text=json.dumps(h).lower()
for forbidden in ("transmitted", "delivered", "received", "confirmed_receipt"):
    assert forbidden not in text, (forbidden, h)
print("PASS: background disappearance evidence remained conservative")
PY

section "Restart Station and prove autonomous observer plus durable history recover"
FIRST_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["station_id"])' "$RUN_DIR/station-first.json")"
stop_service
start_service "$RUN_DIR/station-service-restart.log"

RESTART_READY=0
for _ in $(seq 1 30); do
    curl -fsS "http://$BIND/api/v1/queues/outbound/observer" >"$RUN_DIR/observer-after-restart.json"
    if python3 - "$RUN_DIR/observer-after-restart.json" <<'PY'; then
import json, pathlib, sys
s=json.loads(pathlib.Path(sys.argv[1]).read_text())
raise SystemExit(0 if s.get("last_success_at_unix") is not None and s.get("consecutive_failures") == 0 else 1)
PY
        RESTART_READY=1
        break
    fi
    sleep 0.25
done
[[ "$RESTART_READY" -eq 1 ]] || {
    echo 'FAIL: observer did not restart successfully' >&2
    exit 1
}

curl -fsS "http://$BIND/api/v1/station" >"$RUN_DIR/station-second.json"
curl -fsS "http://$BIND/api/v1/queues/outbound/history" >"$RUN_DIR/history-after-restart.json"
curl -fsS "http://$BIND/api/v1/security/storage" >"$RUN_DIR/storage-security.json"
python3 - "$RUN_DIR/station-second.json" "$RUN_DIR/history-after-restart.json" "$RUN_DIR/storage-security.json" "$FIRST_ID" <<'PY'
import json, pathlib, sys
station=json.loads(pathlib.Path(sys.argv[1]).read_text())
h=json.loads(pathlib.Path(sys.argv[2]).read_text())
security=json.loads(pathlib.Path(sys.argv[3]).read_text())
assert station["station_id"] == sys.argv[4], station
assert h["jobs"][0]["evidence_state"] == "left_postfix_queue", h
assert [e["event_type"] for e in h["events"]] == ["first_seen", "left_postfix_queue"], h
assert security["production_storage_ready"] is False, security
assert security["application_storage_encryption"] is False, security
assert security["per_user_key_separation"] is False, security
print("PASS: headless observer restarted and durable evidence remained intact")
PY

section "Phase 4D result"
printf 'PASS: autonomous headless Postfix queue observation accepted\n'
printf 'Message-ID: %s\n' "$MESSAGE_ID"
printf 'Body token: %s\n' "$BODY_TOKEN"
printf 'No client request was required to create first_seen or left_postfix_queue evidence\n'
printf 'Observer failure did not masquerade as an empty queue\n'
printf 'No transmit/delivery/receipt state inferred\n'
printf 'Storage security remains laboratory-only / production_storage_ready=false\n'
printf 'Evidence directory: %s\n' "$RUN_DIR"
