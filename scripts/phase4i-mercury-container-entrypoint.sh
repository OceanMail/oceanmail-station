#!/usr/bin/env bash
# Run the two pinned Mercury peers and their PulseAudio clean loop inside one
# disposable container. The container uses host networking so the existing
# HERMES lab can continue connecting to 127.0.0.1:8300/8400 unchanged.

set -euo pipefail

HOST_TMP="${OCEANMAIL_HOST_TMP:-/host-tmp}"
SINK_A="${OCEANMAIL_PULSE_SINK_A:-oceanmail_mercury_a}"
SINK_B="${OCEANMAIL_PULSE_SINK_B:-oceanmail_mercury_b}"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp/oceanmail-pulse-runtime}"
MODULE_IDS=()
PID_A=""
PID_B=""

cleanup() {
    if [[ -n "$PID_A" ]]; then kill "$PID_A" >/dev/null 2>&1 || true; fi
    if [[ -n "$PID_B" ]]; then kill "$PID_B" >/dev/null 2>&1 || true; fi
    for id in "${MODULE_IDS[@]:-}"; do
        [[ -n "$id" ]] && pactl unload-module "$id" >/dev/null 2>&1 || true
    done
    pulseaudio -k >/dev/null 2>&1 || true
    rm -f "$HOST_TMP/oceanmail-mercury-ready"
}
trap cleanup EXIT INT TERM

mkdir -p "$RUNTIME_DIR" "$HOST_TMP"
chmod 0700 "$RUNTIME_DIR"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"

pulseaudio --start --exit-idle-time=-1
for _ in $(seq 1 50); do
    pactl info >/dev/null 2>&1 && break
    sleep 0.1
done
pactl info >/dev/null

while read -r module_id _ rest; do
    if [[ "$rest" == *"sink_name=$SINK_A"* || "$rest" == *"sink_name=$SINK_B"* ]]; then
        pactl unload-module "$module_id" >/dev/null 2>&1 || true
    fi
done < <(pactl list short modules 2>/dev/null || true)

MODULE_IDS+=("$(pactl load-module module-null-sink sink_name="$SINK_A" rate=48000 channels=2)")
MODULE_IDS+=("$(pactl load-module module-null-sink sink_name="$SINK_B" rate=48000 channels=2)")

rm -f "$HOST_TMP/mA.log" "$HOST_TMP/mB.log" "$HOST_TMP/oceanmail-mercury-ready"

setsid /opt/mercury/mercury -x pulse -o "$SINK_A" -i "$SINK_B.monitor" \
    -p 8300 -b 8100 -v >"$HOST_TMP/mA.log" 2>&1 </dev/null &
PID_A=$!
setsid /opt/mercury/mercury -x pulse -o "$SINK_B" -i "$SINK_A.monitor" \
    -p 8400 -b 8200 -v >"$HOST_TMP/mB.log" 2>&1 </dev/null &
PID_B=$!

for _ in $(seq 1 100); do
    kill -0 "$PID_A" 2>/dev/null || {
        cat "$HOST_TMP/mA.log" >&2 || true
        exit 1
    }
    kill -0 "$PID_B" 2>/dev/null || {
        cat "$HOST_TMP/mB.log" >&2 || true
        exit 1
    }
    if grep -q 'Listening' "$HOST_TMP/mA.log" 2>/dev/null && grep -q 'Listening' "$HOST_TMP/mB.log" 2>/dev/null; then
        break
    fi
    sleep 0.1
done

kill -0 "$PID_A"
kill -0 "$PID_B"
printf '%s\n' "$PID_A" >/tmp/oceanmail-mercury-a.pid
printf '%s\n' "$PID_B" >/tmp/oceanmail-mercury-b.pid
touch "$HOST_TMP/oceanmail-mercury-ready"
printf 'Mercury container loop ready: A pid=%s B pid=%s\n' "$PID_A" "$PID_B"

wait -n "$PID_A" "$PID_B"
