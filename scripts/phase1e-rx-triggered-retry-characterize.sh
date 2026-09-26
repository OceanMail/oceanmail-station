#!/usr/bin/env bash
# OceanMail Station 0.2 — Phase 1E receive-progress-triggered retry characterization
# Uses the accepted Phase 1C harness, but forces the first link loss only after
# Mercury B has actually received a substantial amount of data.

set -euo pipefail

PAYLOAD_SIZE="${PAYLOAD_SIZE:-16384}"
RX_THRESHOLD="${RX_THRESHOLD:-5000}"
MAX_WAIT="${MAX_WAIT:-600}"
LOG_BASE="${LOG_BASE:-$HOME/oceanmail-logs}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
WRAPPER_LOG="$LOG_BASE/phase1e-rx-triggered-$RUN_ID.log"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCHED_PHASE1C="$REPO_ROOT/scripts/.phase1c-portable-$RUN_ID.sh"

mkdir -p "$LOG_BASE"
trap 'rm -f "$PATCHED_PHASE1C"' EXIT

section() { printf '\n== %s ==\n' "$1"; }

section "Phase 1E environment"
printf 'Payload: %s bytes\n' "$PAYLOAD_SIZE"
printf 'Interrupt after Mercury B rx_total >= %s bytes\n' "$RX_THRESHOLD"
printf 'Maximum wait for receive trigger: %ss\n' "$MAX_WAIT"
printf 'Purpose: distinguish partial resume from whole-job retransmission\n'
printf 'Wrapper log: %s\n' "$WRAPPER_LOG"

# Phase 1C currently contains one GNU-awk-style capture-array expression in the
# new rx_total helper. local verification workstation's Debian awk may be mawk, so patch only that
# helper in a temporary execution copy. Keep that copy under scripts/ so
# Phase 1C's BASH_SOURCE-based repository-root calculation remains correct.
# The temporary file is removed automatically; no tracked source is modified.
python3 - "$REPO_ROOT/scripts/phase1c-interruption-retry.sh" "$PATCHED_PHASE1C" <<'PY'
from pathlib import Path
import sys
src = Path(sys.argv[1]).read_text()
old = '''max_rx_total() {
    local log="$1"
    if [[ ! -f "$log" ]]; then
        printf '0\\n'
        return
    fi
    awk '
        match($0, /rx_total=([0-9]+)/, a) {
            v=a[1]+0
            if (v>max) max=v
        }
        END { print max+0 }
    ' "$log"
}'''
new = '''max_rx_total() {
    local log="$1" max
    if [[ ! -f "$log" ]]; then
        printf '0\\n'
        return
    fi
    max="$(grep -oE 'rx_total=[0-9]+' "$log" 2>/dev/null | cut -d= -f2 | sort -n | tail -n 1 || true)"
    printf '%s\\n' "${max:-0}"
}'''
if old not in src:
    raise SystemExit("ERROR: expected max_rx_total helper not found; refusing an uncertain runtime patch")
Path(sys.argv[2]).write_text(src.replace(old, new, 1))
PY
chmod +x "$PATCHED_PHASE1C"

section "Run receive-progress-triggered interruption/retry"
set +e
PAYLOAD_SIZE="$PAYLOAD_SIZE" \
    INTERRUPT_RX_THRESHOLD="$RX_THRESHOLD" \
    INTERRUPT_MAX_WAIT="$MAX_WAIT" \
    LOG_BASE="$LOG_BASE" \
    bash "$PATCHED_PHASE1C" 2>&1 | tee "$WRAPPER_LOG"
INNER_RC=${PIPESTATUS[0]}
set -e

printf '\nPhase 1C inner exit code: %s\n' "$INNER_RC"
if [[ "$INNER_RC" -ne 0 ]]; then
    printf 'FAIL: underlying interruption/retry acceptance failed; characterization stops here.\n' >&2
    exit "$INNER_RC"
fi

RUN_DIR="$(grep '^Evidence directory:' "$WRAPPER_LOG" | tail -n 1 | sed 's/^Evidence directory: //')"
if [[ -z "$RUN_DIR" || ! -d "$RUN_DIR" ]]; then
    printf 'ERROR: could not resolve Phase 1C evidence directory from wrapper log\n' >&2
    exit 2
fi

ATTEMPT1_RX="$(grep '^Attempt 1 B rx_total:' "$WRAPPER_LOG" | tail -n 1 | awk '{print $5}')"
ATTEMPT2_RX="$(grep '^Attempt 2 B rx_total:' "$WRAPPER_LOG" | tail -n 1 | awk '{print $5}')"

ATTEMPT1_RX="${ATTEMPT1_RX:-0}"
ATTEMPT2_RX="${ATTEMPT2_RX:-0}"

section "Retry airtime characterization"
printf 'Attempt 1 B rx_total before forced loss: %s bytes\n' "$ATTEMPT1_RX"
printf 'Attempt 2 B rx_total during successful retry: %s bytes\n' "$ATTEMPT2_RX"
printf 'Application payload size: %s bytes\n' "$PAYLOAD_SIZE"

# Mercury rx_total includes UUCP/session overhead, so classify conservatively.
# If the successful retry receives nearly an application payload again despite
# several KiB already having crossed in attempt 1, it is strong evidence that
# transport recovery is whole-job retransmission rather than partial-file resume.
RETRANSMIT_FLOOR=$((PAYLOAD_SIZE * 3 / 4))
MEANINGFUL_PROGRESS=$((PAYLOAD_SIZE / 4))

if ((ATTEMPT1_RX >= MEANINGFUL_PROGRESS && ATTEMPT2_RX >= RETRANSMIT_FLOOR)); then
    printf 'CLASSIFICATION: strong evidence of whole-job retransmission on retry, not partial-file resume.\n'
    printf 'IMPLICATION: OceanMail should bound/chunk large durable jobs so a dropped HF session cannot force excessive retransmission.\n'
    exit 0
fi

if ((ATTEMPT1_RX >= MEANINGFUL_PROGRESS && ATTEMPT2_RX < RETRANSMIT_FLOOR)); then
    printf 'CLASSIFICATION: evidence consistent with partial progress being reused on retry; further confirmation recommended.\n'
    exit 0
fi

printf 'INCONCLUSIVE: actual receive progress was still too small for a reliable resume/retransmit classification.\n'
printf 'Evidence directory: %s\n' "$RUN_DIR"
exit 3
