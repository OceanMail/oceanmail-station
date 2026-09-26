#!/usr/bin/env bash
# OceanMail Station 0.2 — Phase 1C interruption/retry acceptance
# Queues a UUCP payload A->B, deliberately kills the Mercury link mid-session,
# proves there is no completed remote delivery and the UUCP job remains queued,
# then restores the link and proves an exact retry delivery.
#
# Interruption trigger:
# - default: INTERRUPT_AFTER seconds after the first uucico start
# - optional: set INTERRUPT_RX_THRESHOLD > 0 to interrupt only after Mercury B
#   reports at least that many cumulative received bytes (rx_total). This is
#   useful for late-interruption/retransmission characterization.

set -euo pipefail

IMAGE="${IMAGE:-oceanmail-uucp-lab:phase1}"
PAYLOAD_SIZE="${PAYLOAD_SIZE:-4096}"
INTERRUPT_AFTER="${INTERRUPT_AFTER:-90}"
INTERRUPT_RX_THRESHOLD="${INTERRUPT_RX_THRESHOLD:-0}"
INTERRUPT_MAX_WAIT="${INTERRUPT_MAX_WAIT:-600}"
HERMES_NET_SHA="0fee4a53f54074ad6237b9fa1083a272cac89f60"
MERCURY_TAG="${OCEANMAIL_MERCURY_TAG-}"
MERCURY_SHA="${OCEANMAIL_MERCURY_SHA:-638193b9a9cc5ab15f272805af116e94b2fdf4c6}"
MERCURY_DIR="${UPSTREAM_BASE:-$HOME/Projects/upstream}/mercury"
LOG_BASE="${LOG_BASE:-$HOME/oceanmail-logs}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$LOG_BASE/phase1c-interruption-$RUN_ID"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A_NAME="oceanmail-uucp-a"
B_NAME="oceanmail-uucp-b"
REMOTE_FILE="phase1c-retry.bin"
DST_FILE="$RUN_DIR/b/public/$REMOTE_FILE"

mkdir -p "$RUN_DIR"

section() { printf '\n== %s ==\n' "$1"; }

resolve_cmd() {
    local cmd="$1" path
    path="$(command -v "$cmd" 2>/dev/null || true)"
    if [[ -n "$path" ]]; then printf '%s\n' "$path"; return 0; fi
    for path in "/usr/sbin/$cmd" "/sbin/$cmd"; do
        if [[ -x "$path" ]]; then printf '%s\n' "$path"; return 0; fi
    done
    return 1
}

max_rx_total() {
    local log="$1" max
    if [[ ! -f "$log" ]]; then
        printf '0\n'
        return
    fi
    max="$(grep -oE 'rx_total=[0-9]+' "$log" 2>/dev/null | cut -d= -f2 | sort -n | tail -n 1 || true)"
    printf '%s\n' "${max:-0}"
}

stop_link() {
    if [[ -n "${OCEANMAIL_MERCURY_DOCKER_IMAGE:-}" ]]; then
        bash "$REPO_ROOT/scripts/phase4i-mercury-docker-loop.sh" stop
        return
    fi
    pkill -9 -x mercury 2>/dev/null || true
    pkill -9 -f '/noisebridge' 2>/dev/null || true
    pkill -9 -f 'arecord -D plughw:' 2>/dev/null || true
    sleep 2
}

cleanup() {
    docker rm -f "$A_NAME" "$B_NAME" >/dev/null 2>&1 || true
    stop_link
}
trap cleanup EXIT

start_mercury() {
    local label="$1"
    stop_link
    if [[ -n "${OCEANMAIL_MERCURY_DOCKER_IMAGE:-}" ]]; then
        bash "$REPO_ROOT/scripts/phase4i-mercury-docker-loop.sh" start >"$RUN_DIR/loopsim-$label.log" 2>&1
        cat "$RUN_DIR/loopsim-$label.log"
        return
    fi
    cd "$MERCURY_DIR"
    CARD="$CARD" MERCURY="./mercury" ./utils/loopsim/run_loopsim.sh 0.0 0.0 >"$RUN_DIR/loopsim-$label.log" 2>&1
    cat "$RUN_DIR/loopsim-$label.log"
    if [[ "$(pgrep -x mercury | wc -l)" -ne 2 ]]; then
        printf 'ERROR: expected two Mercury processes after %s start\n' "$label" >&2
        exit 2
    fi
}

start_uucpd() {
    local label="$1"
    for c in "$A_NAME" "$B_NAME"; do
        docker exec "$c" pkill -TERM -x uucico >/dev/null 2>&1 || true
        docker exec "$c" pkill -TERM -x uuport >/dev/null 2>&1 || true
        docker exec "$c" pkill -TERM -x uucpd >/dev/null 2>&1 || true
    done
    sleep 2
    docker exec -d "$A_NAME" /bin/bash -lc \
        "exec /usr/local/bin/uucpd -a 127.0.0.1 -p 8300 -r vara -o none -c TESTA -d TESTB -f 2300 > /evidence/uucpd-$label.log 2>&1"
    docker exec -d "$B_NAME" /bin/bash -lc \
        "exec /usr/local/bin/uucpd -a 127.0.0.1 -p 8400 -r vara -o none -c TESTB -d TESTA -f 2300 > /evidence/uucpd-$label.log 2>&1"
    sleep 3
    for c in "$A_NAME" "$B_NAME"; do
        if ! docker exec "$c" pgrep -x uucpd >/dev/null; then
            printf 'ERROR: %s uucpd failed during %s start\n' "$c" "$label" >&2
            exit 2
        fi
    done
}

for cmd in docker git make python3 sha256sum pgrep pkill timeout; do
    command -v "$cmd" >/dev/null 2>&1 || { printf 'ERROR: missing %s\n' "$cmd" >&2; exit 2; }
done

if pgrep -x mercury >/dev/null 2>&1; then
    printf 'ERROR: Mercury already running; refusing to interfere\n' >&2
    exit 2
fi

section "Phase 1C environment"
printf 'UTC run id: %s\n' "$RUN_ID"
printf 'Payload: %s bytes\n' "$PAYLOAD_SIZE"
if (( INTERRUPT_RX_THRESHOLD > 0 )); then
    printf 'Forced interruption: after Mercury B rx_total >= %s bytes (max wait %ss)\n' "$INTERRUPT_RX_THRESHOLD" "$INTERRUPT_MAX_WAIT"
else
    printf 'Forced interruption: %s seconds after first uucico start\n' "$INTERRUPT_AFTER"
fi
printf 'Mercury: %s @ %s\n' "$MERCURY_TAG" "$MERCURY_SHA"
printf 'HERMES net: %s\n' "$HERMES_NET_SHA"
printf 'Evidence directory: %s\n' "$RUN_DIR"

section "Build/verify station image"
if ! docker build --build-arg "HERMES_NET_SHA=$HERMES_NET_SHA" \
    -f "$REPO_ROOT/lab/phase1/Dockerfile" -t "$IMAGE" "$REPO_ROOT" >"$RUN_DIR/docker-build.log" 2>&1; then
    tail -n 160 "$RUN_DIR/docker-build.log" >&2
    exit 2
fi
printf 'PASS: station image ready\n'

if [[ -n "${OCEANMAIL_MERCURY_DOCKER_IMAGE:-}" ]]; then
    bash "$REPO_ROOT/scripts/phase4i-mercury-docker-loop.sh" verify-pin | tee "$RUN_DIR/mercury-container-pin.txt"
else
section "Verify pinned Mercury"
cd "$MERCURY_DIR"
git fetch --tags --prune origin >"$RUN_DIR/mercury-fetch.log" 2>&1
TAG_SHA="$(git rev-parse "${MERCURY_TAG:+refs/tags/}${MERCURY_TAG:-$MERCURY_SHA}^{commit}")"
[[ "$TAG_SHA" == "$MERCURY_SHA" ]] || { printf 'ERROR: Mercury pin mismatch\n' >&2; exit 2; }
git switch --detach "$MERCURY_SHA" >/dev/null
make -j"$(nproc)" >"$RUN_DIR/mercury-build.log" 2>&1
make -C utils/loopsim >"$RUN_DIR/loopsim-build.log" 2>&1
printf 'PASS: pinned Mercury ready\n'

section "Load ALSA loopback"
MODPROBE="$(resolve_cmd modprobe || true)"
[[ -n "$MODPROBE" ]] || { printf 'ERROR: modprobe not found\n' >&2; exit 2; }
sudo "$MODPROBE" snd-aloop
sleep 1
CARD="$(awk '/Loopback/ {print $1; exit}' /proc/asound/cards 2>/dev/null || true)"
[[ -n "$CARD" ]] || { printf 'ERROR: Loopback ALSA card not found\n' >&2; exit 2; }
printf 'Loopback ALSA card: %s\n' "$CARD"

fi

section "Prepare two isolated UUCP stations"
for side in a b; do
    mkdir -p "$RUN_DIR/$side/etc-uucp" "$RUN_DIR/$side/public" "$RUN_DIR/$side/evidence"
    chmod 0777 "$RUN_DIR/$side/public" "$RUN_DIR/$side/evidence"
done

cat >"$RUN_DIR/a/etc-uucp/config" <<'EOF'
nodename stationa
pubdir /var/spool/uucppublic
EOF
cat >"$RUN_DIR/b/etc-uucp/config" <<'EOF'
nodename stationb
pubdir /var/spool/uucppublic
EOF

cat >"$RUN_DIR/a/etc-uucp/port" <<'EOF'
port HFP
type pipe
command /usr/local/bin/uuport -e /evidence/uuport.log
EOF
cp "$RUN_DIR/a/etc-uucp/port" "$RUN_DIR/b/etc-uucp/port"

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
EOF
cat >"$RUN_DIR/b/etc-uucp/sys" <<'EOF'
protocol y
protocol-parameter y packet-size 512
protocol-parameter y timeout 540
chat-timeout 200
system stationa
call-login *
call-password *
time any
port HFP
chat "" \r
local-send /
remote-send ~
local-receive ~
remote-receive ~
EOF

docker run -d --name "$A_NAME" --hostname stationa --network host \
    -v "$RUN_DIR/a/etc-uucp:/etc/uucp:ro" \
    -v "$RUN_DIR/a/public:/var/spool/uucppublic" \
    -v "$RUN_DIR/a/evidence:/evidence" "$IMAGE" sleep infinity >/dev/null

docker run -d --name "$B_NAME" --hostname stationb --network host \
    -v "$RUN_DIR/b/etc-uucp:/etc/uucp:ro" \
    -v "$RUN_DIR/b/public:/var/spool/uucppublic" \
    -v "$RUN_DIR/b/evidence:/evidence" "$IMAGE" sleep infinity >/dev/null

IPC_A="$(docker exec "$A_NAME" readlink /proc/1/ns/ipc)"
IPC_B="$(docker exec "$B_NAME" readlink /proc/1/ns/ipc)"
printf 'Station A IPC: %s\nStation B IPC: %s\n' "$IPC_A" "$IPC_B"
[[ "$IPC_A" != "$IPC_B" ]] || { printf 'ERROR: IPC namespaces collided\n' >&2; exit 2; }

section "Start initial Mercury/HERMES link"
start_mercury attempt1
start_uucpd attempt1
printf 'PASS: initial link ready\n'

section "Queue deterministic payload"
SRC_FILE="$RUN_DIR/a/evidence/source.bin"
python3 - "$SRC_FILE" "$PAYLOAD_SIZE" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
size = int(sys.argv[2])
pattern = b"OCEANMAIL-INTERRUPT-RETRY-"
path.write_bytes((pattern * (size // len(pattern) + 1))[:size])
PY
SRC_SHA="$(sha256sum "$SRC_FILE" | awk '{print $1}')"
printf 'Source SHA-256: %s\n' "$SRC_SHA"
docker exec "$A_NAME" /usr/bin/uucp -r -C /evidence/source.bin "stationb!~/$REMOTE_FILE"
docker exec "$A_NAME" /usr/bin/uustat -a | tee "$RUN_DIR/queue-initial.txt"
[[ ! -f "$DST_FILE" ]] || { printf 'ERROR: destination exists before transport\n' >&2; exit 2; }
printf 'PASS: job queued; no remote delivery yet\n'

section "Attempt 1: begin transfer, then destroy link"
set +e
timeout "$((INTERRUPT_MAX_WAIT + 180))" docker exec "$A_NAME" /usr/sbin/uucico -D -S stationb >"$RUN_DIR/a/evidence/uucico-attempt1.log" 2>&1 &
MASTER1_PID=$!
set -e

elapsed=0
TRIGGERED=0
while (( TRIGGERED == 0 )); do
    sleep 15
    elapsed=$((elapsed + 15))
    if ! kill -0 "$MASTER1_PID" 2>/dev/null; then
        printf 'FAIL: first uucico attempt ended before interruption trigger at %ss\n' "$elapsed" >&2
        tail -n 120 "$RUN_DIR/a/evidence/uucico-attempt1.log" >&2 || true
        exit 1
    fi
    if [[ -f "$DST_FILE" ]]; then
        printf 'FAIL: destination completed before planned interruption trigger\n' >&2
        exit 1
    fi
    RX_TOTAL="$(max_rx_total /tmp/mB.log)"
    LAST_EVENT="$(tail -n 80 "$RUN_DIR/a/evidence/uucpd-attempt1.log" 2>/dev/null | grep -E 'CONNECTING|CONNECTED|BUFFER:|TNC:' | tail -n 1 || true)"
    printf '[Attempt 1] elapsed=%ss destination=pending B-rx_total=%s%s\n' "$elapsed" "$RX_TOTAL" "${LAST_EVENT:+ last-event=$LAST_EVENT}"

    if (( INTERRUPT_RX_THRESHOLD > 0 )); then
        if (( RX_TOTAL >= INTERRUPT_RX_THRESHOLD )); then
            TRIGGERED=1
            printf 'Receive-progress trigger reached: B rx_total=%s >= %s\n' "$RX_TOTAL" "$INTERRUPT_RX_THRESHOLD"
        elif (( elapsed >= INTERRUPT_MAX_WAIT )); then
            printf 'FAIL: receive-progress trigger not reached within %ss (max B rx_total=%s)\n' "$INTERRUPT_MAX_WAIT" "$RX_TOTAL" >&2
            exit 1
        fi
    else
        if (( elapsed >= INTERRUPT_AFTER )); then
            TRIGGERED=1
        fi
    fi
done

printf 'FORCING LINK LOSS now: killing both Mercury instances and audio bridges\n'
cp -f /tmp/mA.log "$RUN_DIR/mA-attempt1-before-loss.log" 2>/dev/null || true
cp -f /tmp/mB.log "$RUN_DIR/mB-attempt1-before-loss.log" 2>/dev/null || true
ATTEMPT1_RX_TOTAL="$(max_rx_total "$RUN_DIR/mB-attempt1-before-loss.log")"
printf 'Attempt 1 Mercury B rx_total at interruption: %s bytes\n' "$ATTEMPT1_RX_TOTAL"
stop_link

sleep 5
for c in "$A_NAME" "$B_NAME"; do
    docker exec "$c" pkill -TERM -x uucico >/dev/null 2>&1 || true
    docker exec "$c" pkill -TERM -x uuport >/dev/null 2>&1 || true
    docker exec "$c" pkill -TERM -x uucpd >/dev/null 2>&1 || true
done
set +e
wait "$MASTER1_PID"
ATTEMPT1_RC=$?
set -e
printf 'Attempt 1 uucico/timeout exit code after forced loss: %s\n' "$ATTEMPT1_RC"

section "Verify interrupted state"
[[ ! -f "$DST_FILE" ]] || { printf 'FAIL: final destination file exists after interrupted attempt\n' >&2; exit 1; }
docker exec "$A_NAME" /usr/bin/uustat -a | tee "$RUN_DIR/queue-after-interrupt.txt" || true
if ! grep -q 'stationb' "$RUN_DIR/queue-after-interrupt.txt"; then
    printf 'FAIL: UUCP job is not visibly queued after interrupted transfer\n' >&2
    exit 1
fi
printf '%s\n' 'Remote public directory after interruption:'
find "$RUN_DIR/b/public" -maxdepth 1 -type f -printf '  %f (%s bytes)\n' | tee "$RUN_DIR/remote-public-after-interrupt.txt" || true
printf 'PASS: no completed remote file and job remains queued\n'

section "Restore link"
start_mercury attempt2
start_uucpd attempt2
printf 'PASS: Mercury/HERMES link restored\n'

section "Attempt 2: retry existing queued job"
set +e
timeout 1200 docker exec "$A_NAME" /usr/sbin/uucico -D -S stationb >"$RUN_DIR/a/evidence/uucico-attempt2.log" 2>&1 &
MASTER2_PID=$!
set -e
elapsed=0
ARRIVAL_REPORTED=0
while kill -0 "$MASTER2_PID" 2>/dev/null; do
    sleep 15
    elapsed=$((elapsed + 15))
    RX_TOTAL="$(max_rx_total /tmp/mB.log)"
    if [[ -f "$DST_FILE" && "$ARRIVAL_REPORTED" -eq 0 ]]; then
        printf '[Attempt 2] elapsed=%ss destination=arrived B-rx_total=%s; waiting for session completion\n' "$elapsed" "$RX_TOTAL"
        ARRIVAL_REPORTED=1
    else
        LAST_EVENT="$(tail -n 80 "$RUN_DIR/a/evidence/uucpd-attempt2.log" 2>/dev/null | grep -E 'CONNECTING|CONNECTED|BUFFER:|TNC:' | tail -n 1 || true)"
        printf '[Attempt 2] elapsed=%ss destination=%s B-rx_total=%s%s\n' "$elapsed" "$([[ -f "$DST_FILE" ]] && echo arrived || echo pending)" "$RX_TOTAL" "${LAST_EVENT:+ last-event=$LAST_EVENT}"
    fi
done
set +e
wait "$MASTER2_PID"
ATTEMPT2_RC=$?
set -e
printf 'Attempt 2 uucico exit code: %s\n' "$ATTEMPT2_RC"

cp -f /tmp/mA.log "$RUN_DIR/mA-attempt2.log" 2>/dev/null || true
cp -f /tmp/mB.log "$RUN_DIR/mB-attempt2.log" 2>/dev/null || true
ATTEMPT2_RX_TOTAL="$(max_rx_total "$RUN_DIR/mB-attempt2.log")"
printf 'Attempt 2 Mercury B max rx_total: %s bytes\n' "$ATTEMPT2_RX_TOTAL"

if [[ "$ATTEMPT2_RC" -ne 0 ]]; then
    printf 'FAIL: retry uucico did not complete successfully\n' >&2
    tail -n 160 "$RUN_DIR/a/evidence/uucico-attempt2.log" >&2 || true
    exit 1
fi
[[ -f "$DST_FILE" ]] || { printf 'FAIL: retry ended without remote destination file\n' >&2; exit 1; }
DST_SHA="$(sha256sum "$DST_FILE" | awk '{print $1}')"
printf 'Destination SHA-256: %s\n' "$DST_SHA"
[[ "$SRC_SHA" == "$DST_SHA" ]] || { printf 'FAIL: retry destination hash mismatch\n' >&2; exit 1; }
docker exec "$A_NAME" /usr/bin/uustat -a | tee "$RUN_DIR/queue-after-success.txt" || true

section "Phase 1C result"
printf 'PASS: interrupted UUCP/Mercury transfer survived and retried successfully\n'
if (( INTERRUPT_RX_THRESHOLD > 0 )); then
    printf 'First attempt: forced loss after Mercury B rx_total reached %s bytes\n' "$ATTEMPT1_RX_TOTAL"
else
    printf 'First attempt: forced link loss at %ss; no completed remote file\n' "$INTERRUPT_AFTER"
fi
printf 'Durability: UUCP job remained queued after interruption\n'
printf 'Retry: uucico exit 0 after restored link\n'
printf 'Bytes: %s\n' "$PAYLOAD_SIZE"
printf 'SHA-256: %s\n' "$SRC_SHA"
printf 'Attempt 1 B rx_total: %s\n' "$ATTEMPT1_RX_TOTAL"
printf 'Attempt 2 B rx_total: %s\n' "$ATTEMPT2_RX_TOTAL"
printf 'Evidence directory: %s\n' "$RUN_DIR"
