#!/usr/bin/env bash
# Wait until both Mercury peers' latest connection-state transition is LISTENING.
# This is a deterministic lab lifecycle gate for reciprocal constrained-link work;
# Taylor/uucico process retirement alone does not prove Mercury ARQ session retirement.

set -euo pipefail

LOG_A="${1:-/tmp/mA.log}"
LOG_B="${2:-/tmp/mB.log}"
TIMEOUT_SECONDS="${3:-120}"
POLL_SECONDS="${4:-0.25}"

if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT_SECONDS" -le 0 ]]; then
    printf 'ERROR: timeout must be a positive integer, got %s\n' "$TIMEOUT_SECONDS" >&2
    exit 2
fi

latest_conn_line() {
    local log_file="$1"
    [[ -r "$log_file" ]] || return 1
    grep 'conn:' "$log_file" 2>/dev/null | tail -n 1
}

conn_state_from_line() {
    sed -nE 's/.*conn:[[:space:]]+[^[:space:]]+[[:space:]]+->[[:space:]]+([A-Z_]+).*/\1/p'
}

START_SECONDS=$SECONDS
LAST_A=""
LAST_B=""
LINE_A=""
LINE_B=""

while ((SECONDS - START_SECONDS < TIMEOUT_SECONDS)); do
    LINE_A="$(latest_conn_line "$LOG_A" || true)"
    LINE_B="$(latest_conn_line "$LOG_B" || true)"
    STATE_A="$(printf '%s\n' "$LINE_A" | conn_state_from_line)"
    STATE_B="$(printf '%s\n' "$LINE_B" | conn_state_from_line)"

    if [[ "$STATE_A" != "$LAST_A" || "$STATE_B" != "$LAST_B" ]]; then
        printf 'Mercury lifecycle: A=%s B=%s elapsed=%ss\n' \
            "${STATE_A:-unknown}" "${STATE_B:-unknown}" "$((SECONDS - START_SECONDS))"
        LAST_A="$STATE_A"
        LAST_B="$STATE_B"
    fi

    if [[ "$STATE_A" == "LISTENING" && "$STATE_B" == "LISTENING" ]]; then
        printf 'Mercury A final transition: %s\n' "$LINE_A"
        printf 'Mercury B final transition: %s\n' "$LINE_B"
        printf 'PASS: both Mercury peers latest conn transition is LISTENING\n'
        exit 0
    fi

    sleep "$POLL_SECONDS"
done

printf 'FAIL: Mercury peers did not both return to LISTENING within %ss (A=%s B=%s)\n' \
    "$TIMEOUT_SECONDS" "${LAST_A:-unknown}" "${LAST_B:-unknown}" >&2
printf '%s\n' '--- /tmp/mA.log tail ---' >&2
tail -n 80 "$LOG_A" >&2 2>/dev/null || true
printf '%s\n' '--- /tmp/mB.log tail ---' >&2
tail -n 80 "$LOG_B" >&2 2>/dev/null || true
exit 1
