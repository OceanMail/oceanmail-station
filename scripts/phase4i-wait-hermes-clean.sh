#!/usr/bin/env bash
# Wait until both persistent HERMES uucpd instances have completed their
# post-session cleanup. Mercury LISTENING alone is not sufficient: HERMES
# performs buffer cleanup and killall uucico/uuport after TNC disconnect.
#
# A historical cleanup marker is not enough. Mercury/HERMES can emit another
# TNC: DISCONNECTED after an earlier cleanup completed, which re-arms the
# clean_buffers path. The OceanMail lab patch emits an explicit completion
# marker only after stale VARA tail bytes are drained, buffers are reset, and
# clean_buffers is cleared. Reciprocal work is allowed only after that marker
# has caught up with every disconnect and no live bridge process remains.

set -euo pipefail

A_NAME="${1:?missing Station A container name}"
B_NAME="${2:?missing Station B container name}"
TIMEOUT_SECONDS="${3:-30}"
POLL_SECONDS="${4:-0.1}"
DISCONNECT_MARKER='TNC: DISCONNECTED'
CLEAN_MARKER='Connection cleanup complete.'

[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || {
    printf 'ERROR: timeout must be a positive integer\n' >&2
    exit 2
}

boundary_state() {
    local name="$1"
    docker exec "$name" awk \
        -v disconnected="$DISCONNECT_MARKER" \
        -v clean="$CLEAN_MARKER" '
            index($0, disconnected) {
                disconnects++
                latest="disconnect"
            }
            index($0, clean) {
                cleans++
                latest="clean"
            }
            END {
                if (latest == "") latest="none"
                printf "%s %d %d\n", latest, disconnects + 0, cleans + 0
            }
        ' /evidence/uucpd.log 2>/dev/null
}

bridge_busy() {
    local name="$1"
    # The disposable lab containers run `sleep infinity` as PID 1, so orphaned
    # zombies are not guaranteed to be reaped promptly. A Z-state process is
    # inert and cannot race a reciprocal call; only live uucico/uuport entries
    # count as busy for this lifecycle gate.
    docker exec "$name" ps -eo stat=,comm= 2>/dev/null | awk '
        ($2 == "uucico" || $2 == "uuport") && $1 !~ /^Z/ { live=1 }
        END { exit live ? 0 : 1 }
    '
}

start="$(date +%s)"
last_state=''

while :; do
    read -r a_latest a_disconnects a_cleans < <(boundary_state "$A_NAME")
    read -r b_latest b_disconnects b_cleans < <(boundary_state "$B_NAME")

    a_busy=0
    b_busy=0
    bridge_busy "$A_NAME" && a_busy=1 || true
    bridge_busy "$B_NAME" && b_busy=1 || true

    a_clean=0
    b_clean=0
    if [[ "$a_latest" == "clean" && "$a_cleans" -ge "$a_disconnects" && "$a_busy" -eq 0 ]]; then
        a_clean=1
    fi
    if [[ "$b_latest" == "clean" && "$b_cleans" -ge "$b_disconnects" && "$b_busy" -eq 0 ]]; then
        b_clean=1
    fi

    now="$(date +%s)"
    elapsed="$((now - start))"
    state="A_latest=$a_latest A_disc=$a_disconnects A_clean_count=$a_cleans A_busy=$a_busy B_latest=$b_latest B_disc=$b_disconnects B_clean_count=$b_cleans B_busy=$b_busy"

    if [[ "$state" != "$last_state" ]]; then
        printf 'HERMES lifecycle: %s elapsed=%ss\n' "$state" "$elapsed"
        last_state="$state"
    fi

    if [[ "$a_clean" -eq 1 && "$b_clean" -eq 1 ]]; then
        printf 'HERMES A final boundary: '
        docker exec "$A_NAME" awk \
            -v disconnected="$DISCONNECT_MARKER" \
            -v clean="$CLEAN_MARKER" \
            'index($0, disconnected) || index($0, clean) { line=$0 } END { print line }' \
            /evidence/uucpd.log 2>/dev/null || true
        printf 'HERMES B final boundary: '
        docker exec "$B_NAME" awk \
            -v disconnected="$DISCONNECT_MARKER" \
            -v clean="$CLEAN_MARKER" \
            'index($0, disconnected) || index($0, clean) { line=$0 } END { print line }' \
            /evidence/uucpd.log 2>/dev/null || true
        printf 'PASS: both HERMES peers reached explicit cleanup-complete boundary with no live uucico/uuport active\n'
        exit 0
    fi

    if ((elapsed >= TIMEOUT_SECONDS)); then
        printf 'FAIL: HERMES prior-session cleanup did not complete within %ss (%s)\n' "$TIMEOUT_SECONDS" "$state" >&2
        printf '%s\n' '--- Station A uucpd tail ---' >&2
        docker exec "$A_NAME" tail -n 160 /evidence/uucpd.log >&2 2>/dev/null || true
        printf '%s\n' '--- Station B uucpd tail ---' >&2
        docker exec "$B_NAME" tail -n 160 /evidence/uucpd.log >&2 2>/dev/null || true
        exit 1
    fi

    sleep "$POLL_SECONDS"
done
