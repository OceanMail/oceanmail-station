#!/usr/bin/env bash
# OceanMail Station 0.2 — Phase 4A persistent Station service/API acceptance
# Proves persistent Station identity, loopback-only API exposure, versioned
# health/station endpoints, normalized Postfix JSON-lines queue observation,
# and explicit non-production storage-security status.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_BASE="${LOG_BASE:-$HOME/oceanmail-logs}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$LOG_BASE/phase4a-station-service-$RUN_ID"
PORT="${PORT:-18080}"
BIND="127.0.0.1:$PORT"
STATE_DB="$RUN_DIR/state/station.db"
FIXTURE_POSTQUEUE="$RUN_DIR/postqueue-fixture"
SERVICE_LOG="$RUN_DIR/service.log"
SERVICE_PID=""

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
}
trap cleanup EXIT

for cmd in cargo rustc curl python3; do
    command -v "$cmd" >/dev/null 2>&1 || {
        printf 'ERROR: missing command: %s\n' "$cmd" >&2
        exit 2
    }
done

section "Phase 4A environment"
printf 'UTC run id: %s\n' "$RUN_ID"
printf 'Repository: %s\n' "$REPO_ROOT"
printf 'Bind: %s\n' "$BIND"
printf 'State DB: %s\n' "$STATE_DB"
printf 'Evidence directory: %s\n' "$RUN_DIR"
cargo --version
rustc --version

section "Format, test, and build Station service"
cd "$REPO_ROOT"
cargo fmt -- --check
cargo test --all-targets | tee "$RUN_DIR/cargo-test.log"
cargo build | tee "$RUN_DIR/cargo-build.log"
printf 'PASS: Rust Station service builds and unit tests pass\n'

section "Verify Phase 4A refuses unauthenticated LAN exposure"
set +e
OCEANMAIL_BIND="0.0.0.0:$PORT" \
    OCEANMAIL_STATE_DB="$STATE_DB" \
    "$REPO_ROOT/target/debug/oceanmail-station" \
    >"$RUN_DIR/non-loopback.stdout" 2>"$RUN_DIR/non-loopback.stderr"
NON_LOOPBACK_RC=$?
set -e
if [[ "$NON_LOOPBACK_RC" -eq 0 ]]; then
    printf 'FAIL: non-loopback bind unexpectedly succeeded\n' >&2
    exit 1
fi
if ! grep -q 'refuses non-loopback API bind' "$RUN_DIR/non-loopback.stderr"; then
    printf 'FAIL: non-loopback rejection did not report expected reason\n' >&2
    cat "$RUN_DIR/non-loopback.stderr" >&2 || true
    exit 1
fi
printf 'PASS: non-loopback API bind rejected before authentication/LAN support exists\n'

section "Create deterministic Postfix JSON-lines fixture"
cat >"$FIXTURE_POSTQUEUE" <<'EOF'
#!/bin/sh
if [ "${1:-}" != "-j" ]; then
    echo "fixture supports only -j" >&2
    exit 64
fi
cat <<'JSONL'
{"queue_name":"deferred","queue_id":"ABC123","arrival_time":1700000000,"message_size":572,"sender":"alice@stationa.test","future_field":"ignored","recipients":[{"address":"bob@stationb.test","delay_reason":"deferred transport"}]}
{"queue_name":"active","queue_id":"XYZ789","arrival_time":1700000010,"message_size":640,"sender":"carol@stationa.test","recipients":[{"address":"dave@stationb.test"}]}
JSONL
EOF
chmod 0755 "$FIXTURE_POSTQUEUE"
printf 'PASS: deterministic postqueue fixture ready\n'

start_service() {
    local station_name="$1" log_file="$2"
    stop_service
    OCEANMAIL_BIND="$BIND" \
        OCEANMAIL_STATE_DB="$STATE_DB" \
        OCEANMAIL_STATION_NAME="$station_name" \
        OCEANMAIL_POSTQUEUE="$FIXTURE_POSTQUEUE" \
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
    cat "$log_file" >&2 || true
    return 1
}

section "Start persistent Station service"
start_service "phase4a-lab-station" "$SERVICE_LOG"
printf 'PASS: Station service listening on %s\n' "$BIND"

section "Verify versioned Station API"
curl -fsS "http://$BIND/api/v1/health" | tee "$RUN_DIR/health.json"
curl -fsS "http://$BIND/api/v1/station" | tee "$RUN_DIR/station-first.json"
curl -fsS "http://$BIND/api/v1/security/storage" | tee "$RUN_DIR/storage-security.json"
curl -fsS "http://$BIND/api/v1/queues/outbound" | tee "$RUN_DIR/outbound-queue.json"

python3 - "$RUN_DIR/health.json" "$RUN_DIR/station-first.json" "$RUN_DIR/storage-security.json" "$RUN_DIR/outbound-queue.json" <<'PY'
import json, pathlib, sys
health = json.loads(pathlib.Path(sys.argv[1]).read_text())
station = json.loads(pathlib.Path(sys.argv[2]).read_text())
storage = json.loads(pathlib.Path(sys.argv[3]).read_text())
queue = json.loads(pathlib.Path(sys.argv[4]).read_text())

assert health["status"] == "ok", health
assert health["service"] == "oceanmail-station", health
assert health["api_version"] == "v1", health
assert health["station_id"] == station["station_id"], (health, station)

assert station["station_name"] == "phase4a-lab-station", station
caps = station["capabilities"]
assert caps["mail_submission"] == "smtp", caps
assert caps["mail_retrieval"] == "imap", caps
assert caps["outbound_queue_observation"] == "postfix-json-lines", caps
assert caps["constrained_transport"] == "hermes-mercury", caps
assert caps["queue_mutation"] is False, caps
assert caps["api_authentication"] is False, caps
assert caps["lan_exposure"] is False, caps

assert storage["production_storage_ready"] is False, storage
assert storage["application_storage_encryption"] is False, storage
assert storage["per_user_key_separation"] is False, storage
assert storage["host_volume_encryption_verified"] is False, storage
assert "laboratory plaintext SQLite" in storage["note"], storage

assert queue["source"] == "postfix", queue
assert len(queue["entries"]) == 2, queue
first, second = queue["entries"]
assert first["queue_id"] == "ABC123", first
assert first["delivery_state"] == "deferred", first
assert first["message_size"] == 572, first
assert first["recipients"][0]["address"] == "bob@stationb.test", first
assert first["recipients"][0]["delay_reason"] == "deferred transport", first
assert station["station_id"] in first["observation_id"], first
assert second["queue_id"] == "XYZ789", second
assert second["delivery_state"] == "selected_for_delivery", second
print("PASS: API health, Station identity/capabilities, storage-security gate, and queue normalization verified")
PY

FIRST_ID="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["station_id"])' "$RUN_DIR/station-first.json")"
FIRST_CREATED="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["created_at_unix"])' "$RUN_DIR/station-first.json")"

section "Restart service and verify durable Station identity"
stop_service
start_service "name-must-not-replace-persisted-value" "$RUN_DIR/service-restart.log"
curl -fsS "http://$BIND/api/v1/station" | tee "$RUN_DIR/station-second.json"

python3 - "$RUN_DIR/station-first.json" "$RUN_DIR/station-second.json" <<'PY'
import json, pathlib, sys
first = json.loads(pathlib.Path(sys.argv[1]).read_text())
second = json.loads(pathlib.Path(sys.argv[2]).read_text())
assert first["station_id"] == second["station_id"], (first, second)
assert first["station_name"] == second["station_name"] == "phase4a-lab-station", (first, second)
assert first["created_at_unix"] == second["created_at_unix"], (first, second)
print("PASS: Station UUID, name, and creation timestamp survived daemon restart")
PY

section "Phase 4A result"
printf 'PASS: persistent OceanMail Station service/API foundation accepted\n'
printf 'Station ID: %s\n' "$FIRST_ID"
printf 'Created at unix: %s\n' "$FIRST_CREATED"
printf 'API bind: %s (loopback only)\n' "$BIND"
printf 'Queue source contract: postqueue -j JSON lines\n'
printf 'Storage security: laboratory plaintext only; production_storage_ready=false\n'
printf 'Evidence directory: %s\n' "$RUN_DIR"
