#!/usr/bin/env bash
# OceanMail-owned Taylor UUCP caller-attempt evidence boundary.
#
# This wrapper records a system-level uucico attempt, snapshots the exact
# OceanMail-mapped UUCP jobs that are queued when the attempt begins, runs the
# real Taylor uucico process, and records its process exit. It does not claim
# that every queued job transmitted, nor that process exit 0 means delivery.

set -euo pipefail

if [[ $# -lt 4 ]]; then
    printf 'usage: %s STATE_DB RECORDER_PATH REMOTE_SYSTEM EVIDENCE_LOG [uucico args...]\n' "$0" >&2
    exit 64
fi

STATE_DB="$1"
RECORDER_PATH="$2"
REMOTE_SYSTEM="$3"
EVIDENCE_LOG="$4"
shift 4

UUCICO_PATH="${OCEANMAIL_UUCICO_PATH:-/usr/sbin/uucico}"
UUSTAT_PATH="${OCEANMAIL_UUSTAT_PATH:-/usr/bin/uustat}"
ATTEMPT_ID="${OCEANMAIL_ATTEMPT_ID:-$(cat /proc/sys/kernel/random/uuid)}"

mkdir -p "$(dirname "$EVIDENCE_LOG")" 2>/dev/null || true

log() {
    printf '%s attempt_id=%s remote=%s %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$ATTEMPT_ID" "$REMOTE_SYSTEM" "$*" \
        >>"$EVIDENCE_LOG" 2>/dev/null || true
}

for path in "$RECORDER_PATH" "$UUCICO_PATH" "$UUSTAT_PATH"; do
    if [[ ! -x "$path" ]]; then
        log "attempt_error=missing_executable path=$path"
        printf 'OceanMail uucico attempt wrapper: missing executable %s\n' "$path" >&2
        exit 69
    fi
done

TMP_DIR="$(mktemp -d /tmp/oceanmail-uucico-attempt.XXXXXX)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

"$RECORDER_PATH" attempt-start \
    --state-db "$STATE_DB" \
    --attempt-id "$ATTEMPT_ID" \
    --remote-system "$REMOTE_SYSTEM" \
    --adapter taylor-uucico \
    >"$TMP_DIR/start.json"

"$UUSTAT_PATH" -a >"$TMP_DIR/uustat-start.txt" 2>/dev/null || true
"$RECORDER_PATH" attempt-snapshot \
    --state-db "$STATE_DB" \
    --attempt-id "$ATTEMPT_ID" \
    --remote-system "$REMOTE_SYSTEM" \
    --uustat-file "$TMP_DIR/uustat-start.txt" \
    >"$TMP_DIR/snapshot.json"

log "attempt_started snapshot=$(tr '\n' ' ' <"$TMP_DIR/snapshot.json")"
printf 'OceanMail UUCP attempt %s started for %s\n' "$ATTEMPT_ID" "$REMOTE_SYSTEM" >&2

set +e
"$UUCICO_PATH" "$@"
UUCICO_RC=$?
set -e

set +e
FINISH_OUTPUT="$({
    "$RECORDER_PATH" attempt-finish \
        --state-db "$STATE_DB" \
        --attempt-id "$ATTEMPT_ID" \
        --exit-code "$UUCICO_RC"
} 2>&1)"
FINISH_RC=$?
set -e

if [[ "$FINISH_RC" -ne 0 ]]; then
    log "uucico_exit=$UUCICO_RC evidence_error=finish_record_failed recorder_rc=$FINISH_RC recorder_output=$(printf '%q' "$FINISH_OUTPUT")"
    printf 'OceanMail uucico attempt wrapper: uucico exited %s but finish evidence could not be recorded\n' "$UUCICO_RC" >&2
else
    log "uucico_exit=$UUCICO_RC finish=$FINISH_OUTPUT"
fi

printf 'OceanMail UUCP attempt %s finished with uucico exit %s\n' "$ATTEMPT_ID" "$UUCICO_RC" >&2
exit "$UUCICO_RC"
