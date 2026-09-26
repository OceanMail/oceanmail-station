#!/usr/bin/env bash
# User-facing Phase 1B wrapper: keep the acceptance runner's output visible and
# emit periodic progress while the UUCP/HF-style session is in flight.

set -euo pipefail

DIRECTION="${DIRECTION:-a2b}"
LOG_BASE="${LOG_BASE:-$HOME/oceanmail-logs}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER_ID="$(date -u +%Y%m%dT%H%M%SZ)"
WRAPPER_LOG="$LOG_BASE/phase1b-wrapper-$DIRECTION-$WRAPPER_ID.log"
mkdir -p "$LOG_BASE"

(
    set -o pipefail
    DIRECTION="$DIRECTION" bash "$REPO_ROOT/scripts/phase1b-uucp-transfer.sh" 2>&1 | tee "$WRAPPER_LOG"
) &
RUNNER_PID=$!

ELAPSED=0
LAST_EVENT=""
while kill -0 "$RUNNER_PID" 2>/dev/null; do
    sleep 10
    if ! kill -0 "$RUNNER_PID" 2>/dev/null; then
        break
    fi

    ELAPSED=$((ELAPSED + 10))
    RUN_DIR="$(ls -1dt "$LOG_BASE"/phase1b-uucp-"$DIRECTION"-* 2>/dev/null | head -n 1 || true)"
    DEST_STATE="not-created-yet"
    EVENT=""

    if [[ -n "$RUN_DIR" ]]; then
        if find "$RUN_DIR" -path '*/public/phase1-*.bin' -type f -print -quit 2>/dev/null | grep -q .; then
            DEST_STATE="arrived"
        else
            DEST_STATE="pending"
        fi

        EVENT="$(grep -hE 'CONNECTING|TNC: CONNECTED|TNC: DISCONNECTED|BUFFER:' \
            "$RUN_DIR"/a/evidence/uucpd.log "$RUN_DIR"/b/evidence/uucpd.log \
            2>/dev/null | tail -n 1 || true)"
    fi

    printf '[Phase 1B progress] elapsed=%ss destination=%s' "$ELAPSED" "$DEST_STATE"
    if [[ -n "$EVENT" && "$EVENT" != "$LAST_EVENT" ]]; then
        printf ' last-event=%s' "$EVENT"
        LAST_EVENT="$EVENT"
    fi
    printf '\n'
done

set +e
wait "$RUNNER_PID"
RC=$?
set -e

printf '\nPhase 1B wrapper exit code: %s\n' "$RC"
printf 'Wrapper log: %s\n' "$WRAPPER_LOG"
exit "$RC"
