#!/usr/bin/env bash
# OceanMail Station 0.2 — Phase 0 Mercury loopsim acceptance runner
# Builds pinned Mercury development revision and runs its upstream two-instance ALSA loop test.
# Does not install packages or install Mercury system-wide.

set -euo pipefail

MERCURY_REPO="https://github.com/Rhizomatica/mercury.git"
MERCURY_TAG=""
MERCURY_SHA="638193b9a9cc5ab15f272805af116e94b2fdf4c6"
UPSTREAM_BASE="${UPSTREAM_BASE:-$HOME/Projects/upstream}"
MERCURY_DIR="$UPSTREAM_BASE/mercury"
LOG_BASE="${LOG_BASE:-$HOME/oceanmail-logs}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$LOG_BASE/phase0-mercury-$RUN_ID"

mkdir -p "$UPSTREAM_BASE" "$LOG_BASE" "$RUN_DIR"

cleanup() {
    pkill -9 -x mercury 2>/dev/null || true
    pkill -9 -f '/noisebridge' 2>/dev/null || true
    pkill -9 -f 'arecord -D plughw:' 2>/dev/null || true
}
trap cleanup EXIT

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

section "Phase 0 environment"
printf 'UTC run id: %s\n' "$RUN_ID"
printf 'Host: %s\n' "$(hostname)"
printf 'Kernel: %s\n' "$(uname -srmo)"
printf 'Mercury tag: %s\n' "$MERCURY_TAG"
printf 'Mercury expected SHA: %s\n' "$MERCURY_SHA"
printf 'Evidence directory: %s\n' "$RUN_DIR"

required=(git gcc make pkg-config python3 aplay arecord pkill setsid ss)
for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null 2>&1 || {
        printf 'ERROR: required command missing: %s\n' "$cmd" >&2
        exit 2
    }
done

MODPROBE="$(resolve_cmd modprobe || true)"
if [[ -z "$MODPROBE" ]]; then
    printf 'ERROR: required command missing: modprobe (checked PATH, /usr/sbin, /sbin)\n' >&2
    exit 2
fi
printf 'modprobe: %s\n' "$MODPROBE"

if pgrep -x mercury >/dev/null 2>&1; then
    printf 'ERROR: Mercury was already running before the test. Stop it deliberately and rerun.\n' >&2
    exit 2
fi

section "Acquire pinned Mercury source"
if [[ ! -d "$MERCURY_DIR/.git" ]]; then
    git clone "$MERCURY_REPO" "$MERCURY_DIR"
fi
cd "$MERCURY_DIR"

if [[ -n "$(git status --porcelain)" ]]; then
    printf 'ERROR: Mercury checkout is dirty; refusing to overwrite upstream work.\n' >&2
    git status --short >&2
    exit 2
fi

git fetch --tags --prune origin
TAG_SHA="$(git rev-parse "${MERCURY_TAG:+refs/tags/}${MERCURY_TAG:-$MERCURY_SHA}^{commit}")"
if [[ "$TAG_SHA" != "$MERCURY_SHA" ]]; then
    printf 'ERROR: %s resolved to %s, expected %s.\n' "$MERCURY_TAG" "$TAG_SHA" "$MERCURY_SHA" >&2
    exit 2
fi

git switch --detach "$MERCURY_SHA"
printf 'Mercury HEAD: %s\n' "$(git rev-parse HEAD)"
printf 'Mercury description: %s\n' "$(git describe --tags --always --dirty)"

section "Build pinned Mercury"
make clean >/dev/null 2>&1 || true
if ! make -j"$(nproc)" >"$RUN_DIR/build.log" 2>&1; then
    printf 'ERROR: Mercury build failed. Tail of build log:\n' >&2
    tail -n 120 "$RUN_DIR/build.log" >&2
    exit 2
fi
test -x ./mercury
printf 'PASS: Mercury build completed (%s)\n' "$RUN_DIR/build.log"

section "Build upstream loopsim bridge"
make -C utils/loopsim clean >/dev/null 2>&1 || true
if ! make -C utils/loopsim >"$RUN_DIR/loopsim-build.log" 2>&1; then
    printf 'ERROR: loopsim bridge build failed. Tail of build log:\n' >&2
    tail -n 120 "$RUN_DIR/loopsim-build.log" >&2
    exit 2
fi
test -x utils/loopsim/noisebridge
printf 'PASS: loopsim bridge build completed (%s)\n' "$RUN_DIR/loopsim-build.log"

section "Load ALSA loopback"
sudo "$MODPROBE" snd-aloop
sleep 1
CARD="$(awk '/Loopback/ {print $1; exit}' /proc/asound/cards 2>/dev/null || true)"
if [[ -z "$CARD" ]]; then
    printf 'ERROR: no Loopback ALSA card detected after modprobe.\n' >&2
    cat /proc/asound/cards >&2 || true
    exit 2
fi
printf 'Loopback ALSA card: %s\n' "$CARD"
cat /proc/asound/cards | tee "$RUN_DIR/asound-cards.txt"

section "Start clean two-instance Mercury link"
# Do not pipe the upstream launcher through tee: its long-lived background ALSA
# bridge processes inherit stdout and would keep the pipe open after the launcher
# itself exits. Redirect directly to a file, then print that finite file.
if ! CARD="$CARD" MERCURY="./mercury" ./utils/loopsim/run_loopsim.sh 0.0 0.0 >"$RUN_DIR/loopsim-start.log" 2>&1; then
    printf 'ERROR: loopsim launcher failed.\n' >&2
    cat "$RUN_DIR/loopsim-start.log" >&2
    exit 2
fi
cat "$RUN_DIR/loopsim-start.log"

MERCURY_COUNT="$(pgrep -x mercury | wc -l)"
if [[ "$MERCURY_COUNT" -ne 2 ]]; then
    printf 'ERROR: expected 2 Mercury processes after launcher, found %s.\n' "$MERCURY_COUNT" >&2
    exit 2
fi

section "Transfer deterministic payload"
set +e
# -u keeps progress visible when stdout is piped through tee.
PAYLOAD=5120 TIMEOUT=240 python3 -u ./utils/loopsim/drive.py 2>&1 | tee "$RUN_DIR/drive.log"
DRIVER_RC=${PIPESTATUS[0]}
set -e

cp -f /tmp/mA.log "$RUN_DIR/mA.log" 2>/dev/null || true
cp -f /tmp/mB.log "$RUN_DIR/mB.log" 2>/dev/null || true
ss -ltnp >"$RUN_DIR/ss-after.txt" 2>&1 || true

if [[ $DRIVER_RC -ne 0 ]]; then
    printf 'FAIL: drive.py exit code %s\n' "$DRIVER_RC" | tee "$RUN_DIR/result.txt"
    exit "$DRIVER_RC"
fi

if ! grep -q 'match=True' "$RUN_DIR/drive.log"; then
    printf 'FAIL: exact payload match was not reported.\n' | tee "$RUN_DIR/result.txt"
    exit 1
fi

grep '=== RESULT:' "$RUN_DIR/drive.log" | tail -n 1 | tee "$RUN_DIR/result.txt"
printf 'PASS: Mercury Phase 0 clean-channel transfer\n' | tee -a "$RUN_DIR/result.txt"
printf 'Evidence directory: %s\n' "$RUN_DIR"
