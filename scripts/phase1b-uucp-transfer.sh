#!/usr/bin/env bash
# OceanMail Station 0.2 — Phase 1B UUCP-over-Mercury transfer acceptance
# Runs two isolated Debian 13 UUCP stations through HERMES uucpd/uuport and
# the pinned Mercury v1.9.13 two-instance ALSA loopsim channel.

set -euo pipefail

IMAGE="${IMAGE:-oceanmail-uucp-lab:phase1}"
DIRECTION="${DIRECTION:-a2b}"
PAYLOAD_SIZE="${PAYLOAD_SIZE:-1024}"
HERMES_NET_SHA="5c76adff754de49c0b934c7fd7bddf7619b0c3d6"
MERCURY_REPO="https://github.com/Rhizomatica/mercury.git"
MERCURY_TAG="v1.9.13"
MERCURY_SHA="4eac25e06a0c88996621bc74af5b7b2f0d353848"
UPSTREAM_BASE="${UPSTREAM_BASE:-$HOME/Projects/upstream}"
MERCURY_DIR="$UPSTREAM_BASE/mercury"
LOG_BASE="${LOG_BASE:-$HOME/oceanmail-logs}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$LOG_BASE/phase1b-uucp-$DIRECTION-$RUN_ID"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

A_NAME="oceanmail-uucp-a"
B_NAME="oceanmail-uucp-b"

mkdir -p "$RUN_DIR" "$UPSTREAM_BASE"

section() { printf '\n== %s ==\n' "$1"; }

resolve_cmd() {
    local cmd="$1"
    local path
    path="$(command -v "$cmd" 2>/dev/null || true)"
    if [[ -n "$path" ]]; then
        printf '%s\n' "$path"
        return 0
    fi
    for path in "/usr/sbin/$cmd" "/sbin/$cmd"; do
        if [[ -x "$path" ]]; then
            printf '%s\n' "$path"
            return 0
        fi
    done
    return 1
}

cleanup() {
    docker rm -f "$A_NAME" "$B_NAME" >/dev/null 2>&1 || true
    pkill -9 -x mercury 2>/dev/null || true
    pkill -9 -f '/noisebridge' 2>/dev/null || true
    pkill -9 -f 'arecord -D plughw:' 2>/dev/null || true
}
trap cleanup EXIT

case "$DIRECTION" in
    a2b)
        SRC_NAME="$A_NAME"
        DST_NAME="$B_NAME"
        SRC_SYS="stationa"
        DST_SYS="stationb"
        SRC_CALL="TESTA"
        DST_CALL="TESTB"
        REMOTE_FILE="phase1-a2b.bin"
        ;;
    b2a)
        SRC_NAME="$B_NAME"
        DST_NAME="$A_NAME"
        SRC_SYS="stationb"
        DST_SYS="stationa"
        SRC_CALL="TESTB"
        DST_CALL="TESTA"
        REMOTE_FILE="phase1-b2a.bin"
        ;;
    *)
        printf 'ERROR: DIRECTION must be a2b or b2a, got %s\n' "$DIRECTION" >&2
        exit 2
        ;;
esac

for cmd in docker git make python3 sha256sum ss pgrep pkill; do
    command -v "$cmd" >/dev/null 2>&1 || {
        printf 'ERROR: required host command missing: %s\n' "$cmd" >&2
        exit 2
    }
done

if pgrep -x mercury >/dev/null 2>&1; then
    printf 'ERROR: Mercury is already running; refusing to interfere with another session.\n' >&2
    pgrep -af mercury >&2 || true
    exit 2
fi

section "Phase 1B environment"
printf 'UTC run id: %s\n' "$RUN_ID"
printf 'Direction: %s (%s -> %s)\n' "$DIRECTION" "$SRC_SYS" "$DST_SYS"
printf 'Payload size: %s bytes\n' "$PAYLOAD_SIZE"
printf 'Mercury: %s @ %s\n' "$MERCURY_TAG" "$MERCURY_SHA"
printf 'HERMES net: %s\n' "$HERMES_NET_SHA"
printf 'Evidence directory: %s\n' "$RUN_DIR"

section "Build/verify station image"
if ! docker build \
    --build-arg "HERMES_NET_SHA=$HERMES_NET_SHA" \
    -f "$REPO_ROOT/lab/phase1/Dockerfile" \
    -t "$IMAGE" \
    "$REPO_ROOT" >"$RUN_DIR/docker-build.log" 2>&1; then
    printf 'ERROR: station image build failed. Tail follows:\n' >&2
    tail -n 160 "$RUN_DIR/docker-build.log" >&2
    exit 2
fi
printf 'PASS: station image ready: %s\n' "$IMAGE"

section "Acquire pinned Mercury"
if [[ ! -d "$MERCURY_DIR/.git" ]]; then
    git clone "$MERCURY_REPO" "$MERCURY_DIR" >"$RUN_DIR/mercury-clone.log" 2>&1
fi
cd "$MERCURY_DIR"
git fetch --tags --prune origin >"$RUN_DIR/mercury-fetch.log" 2>&1
TAG_SHA="$(git rev-parse "refs/tags/$MERCURY_TAG^{commit}")"
if [[ "$TAG_SHA" != "$MERCURY_SHA" ]]; then
    printf 'ERROR: Mercury tag %s resolved to %s, expected %s\n' "$MERCURY_TAG" "$TAG_SHA" "$MERCURY_SHA" >&2
    exit 2
fi
git switch --detach "$MERCURY_SHA" >/dev/null
if ! make -j"$(nproc)" >"$RUN_DIR/mercury-build.log" 2>&1; then
    printf 'ERROR: Mercury build failed. Tail follows:\n' >&2
    tail -n 160 "$RUN_DIR/mercury-build.log" >&2
    exit 2
fi
if ! make -C utils/loopsim >"$RUN_DIR/loopsim-build.log" 2>&1; then
    printf 'ERROR: loopsim bridge build failed. Tail follows:\n' >&2
    tail -n 120 "$RUN_DIR/loopsim-build.log" >&2
    exit 2
fi
printf 'PASS: pinned Mercury and loopsim ready\n'

section "Start two-instance Mercury channel"
MODPROBE="$(resolve_cmd modprobe || true)"
if [[ -z "$MODPROBE" ]]; then
    printf 'ERROR: modprobe not found\n' >&2
    exit 2
fi
sudo "$MODPROBE" snd-aloop
sleep 1
CARD="$(awk '/Loopback/ {print $1; exit}' /proc/asound/cards 2>/dev/null || true)"
if [[ -z "$CARD" ]]; then
    printf 'ERROR: ALSA Loopback card not found\n' >&2
    exit 2
fi
CARD="$CARD" MERCURY="./mercury" ./utils/loopsim/run_loopsim.sh 0.0 0.0 >"$RUN_DIR/loopsim-start.log" 2>&1
cat "$RUN_DIR/loopsim-start.log"
if [[ "$(pgrep -x mercury | wc -l)" -ne 2 ]]; then
    printf 'ERROR: expected two Mercury processes\n' >&2
    exit 2
fi

section "Prepare isolated UUCP station state"
for SIDE in a b; do
    mkdir -p "$RUN_DIR/$SIDE/etc-uucp" "$RUN_DIR/$SIDE/public" "$RUN_DIR/$SIDE/evidence"
    chmod 0777 "$RUN_DIR/$SIDE/public" "$RUN_DIR/$SIDE/evidence"
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

section "Start station containers"
docker run -d --name "$A_NAME" --hostname stationa --network host \
    -v "$RUN_DIR/a/etc-uucp:/etc/uucp:ro" \
    -v "$RUN_DIR/a/public:/var/spool/uucppublic" \
    -v "$RUN_DIR/a/evidence:/evidence" \
    "$IMAGE" sleep infinity >/dev/null

docker run -d --name "$B_NAME" --hostname stationb --network host \
    -v "$RUN_DIR/b/etc-uucp:/etc/uucp:ro" \
    -v "$RUN_DIR/b/public:/var/spool/uucppublic" \
    -v "$RUN_DIR/b/evidence:/evidence" \
    "$IMAGE" sleep infinity >/dev/null

IPC_A="$(docker exec "$A_NAME" readlink /proc/1/ns/ipc)"
IPC_B="$(docker exec "$B_NAME" readlink /proc/1/ns/ipc)"
printf 'Station A IPC: %s\n' "$IPC_A"
printf 'Station B IPC: %s\n' "$IPC_B"
if [[ "$IPC_A" == "$IPC_B" ]]; then
    printf 'ERROR: station IPC namespaces collided\n' >&2
    exit 2
fi

section "Start HERMES uucpd against Mercury"
docker exec -d "$A_NAME" /bin/bash -lc \
    'exec /usr/local/bin/uucpd -a 127.0.0.1 -p 8300 -r vara -o none -c TESTA -d TESTB -f 2300 > /evidence/uucpd.log 2>&1'
docker exec -d "$B_NAME" /bin/bash -lc \
    'exec /usr/local/bin/uucpd -a 127.0.0.1 -p 8400 -r vara -o none -c TESTB -d TESTA -f 2300 > /evidence/uucpd.log 2>&1'
sleep 3

if ! docker exec "$A_NAME" pgrep -x uucpd >/dev/null; then
    printf 'ERROR: station A uucpd is not running\n' >&2
    cat "$RUN_DIR/a/evidence/uucpd.log" >&2 || true
    exit 2
fi
if ! docker exec "$B_NAME" pgrep -x uucpd >/dev/null; then
    printf 'ERROR: station B uucpd is not running\n' >&2
    cat "$RUN_DIR/b/evidence/uucpd.log" >&2 || true
    exit 2
fi
printf 'PASS: both uucpd instances running\n'

section "Create deterministic payload"
SRC_SIDE="a"
DST_SIDE="b"
if [[ "$DIRECTION" == "b2a" ]]; then
    SRC_SIDE="b"
    DST_SIDE="a"
fi
SRC_FILE="$RUN_DIR/$SRC_SIDE/evidence/source.bin"
DST_FILE="$RUN_DIR/$DST_SIDE/public/$REMOTE_FILE"
python3 - "$SRC_FILE" "$PAYLOAD_SIZE" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
size = int(sys.argv[2])
pattern = b"OCEANMAIL-PHASE1-UUCP-MERCURY-"
data = (pattern * (size // len(pattern) + 1))[:size]
path.write_bytes(data)
PY
SRC_SHA="$(sha256sum "$SRC_FILE" | awk '{print $1}')"
printf 'Source SHA-256: %s\n' "$SRC_SHA"

section "Queue payload locally without starting transport"
docker exec "$SRC_NAME" /usr/bin/uucp -r -C /evidence/source.bin "${DST_SYS}!~/$REMOTE_FILE"
docker exec "$SRC_NAME" /usr/bin/uustat -a | tee "$RUN_DIR/queue-before.txt" || true
if [[ -f "$DST_FILE" ]]; then
    printf 'ERROR: destination appeared before uucico transport started\n' >&2
    exit 2
fi
printf 'PASS: local queue accepted; remote file not yet present\n'

section "Run UUCP master session through HERMES/Mercury"
set +e
timeout 600 docker exec "$SRC_NAME" /usr/sbin/uucico -D -S "$DST_SYS" >"$RUN_DIR/$SRC_SIDE/evidence/uucico-master.log" 2>&1
UUCICO_RC=$?
set -e
printf 'uucico master exit code: %s\n' "$UUCICO_RC"

for _ in $(seq 1 60); do
    [[ -f "$DST_FILE" ]] && break
    sleep 1
done

docker exec "$SRC_NAME" /usr/bin/uustat -a >"$RUN_DIR/queue-after-source.txt" 2>&1 || true
docker exec "$DST_NAME" /usr/bin/uustat -a >"$RUN_DIR/queue-after-destination.txt" 2>&1 || true
cp -f /tmp/mA.log "$RUN_DIR/mA.log" 2>/dev/null || true
cp -f /tmp/mB.log "$RUN_DIR/mB.log" 2>/dev/null || true

if [[ ! -f "$DST_FILE" ]]; then
    printf 'FAIL: destination file did not arrive within acceptance window\n' >&2
    printf '%s\n' '--- source uucico ---' >&2
    tail -n 120 "$RUN_DIR/$SRC_SIDE/evidence/uucico-master.log" >&2 || true
    printf '%s\n' '--- station A uucpd ---' >&2
    tail -n 120 "$RUN_DIR/a/evidence/uucpd.log" >&2 || true
    printf '%s\n' '--- station B uucpd ---' >&2
    tail -n 120 "$RUN_DIR/b/evidence/uucpd.log" >&2 || true
    exit 1
fi

DST_SHA="$(sha256sum "$DST_FILE" | awk '{print $1}')"
printf 'Destination SHA-256: %s\n' "$DST_SHA"
if [[ "$SRC_SHA" != "$DST_SHA" ]]; then
    printf 'FAIL: source/destination SHA-256 mismatch\n' >&2
    exit 1
fi

section "Phase 1B result"
printf 'PASS: UUCP payload arrived through HERMES uucpd/uuport and Mercury\n'
printf 'Direction: %s\n' "$DIRECTION"
printf 'Bytes: %s\n' "$PAYLOAD_SIZE"
printf 'SHA-256: %s\n' "$SRC_SHA"
printf 'Local queue acceptance evidence: %s\n' "$RUN_DIR/queue-before.txt"
printf 'Remote arrival: %s\n' "$DST_FILE"
printf 'Evidence directory: %s\n' "$RUN_DIR"
