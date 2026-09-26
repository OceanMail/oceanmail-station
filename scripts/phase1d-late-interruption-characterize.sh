#!/usr/bin/env bash
# OceanMail Station 0.2 — Phase 1D late-interruption characterization
# Reuses the accepted Phase 1C durability harness with a larger payload and
# later interruption, then compares Mercury receive totals across attempts to
# determine whether retry behavior is consistent with partial resume or
# whole-job retransmission.

set -euo pipefail

PAYLOAD_SIZE="${PAYLOAD_SIZE:-8192}"
INTERRUPT_AFTER="${INTERRUPT_AFTER:-180}"
LOG_BASE="${LOG_BASE:-$HOME/oceanmail-logs}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
WRAPPER_LOG="$LOG_BASE/phase1d-late-interruption-$RUN_ID.log"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$LOG_BASE"

section() { printf '\n== %s ==\n' "$1"; }

max_rx_total() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        printf '0\n'
        return 0
    fi
    grep -oE 'rx_total=[0-9]+' "$file" 2>/dev/null |
        cut -d= -f2 |
        sort -n |
        tail -n 1 ||
        true
}

section "Phase 1D environment"
printf 'Payload: %s bytes\n' "$PAYLOAD_SIZE"
printf 'Late interruption: %s seconds after first uucico start\n' "$INTERRUPT_AFTER"
printf 'Purpose: characterize retry airtime behavior after substantial transfer progress\n'
printf 'Wrapper log: %s\n' "$WRAPPER_LOG"

section "Run accepted Phase 1C harness with late interruption"
set +e
PAYLOAD_SIZE="$PAYLOAD_SIZE" \
    INTERRUPT_AFTER="$INTERRUPT_AFTER" \
    bash "$REPO_ROOT/scripts/phase1c-interruption-retry.sh" 2>&1 | tee "$WRAPPER_LOG"
INNER_RC=${PIPESTATUS[0]}
set -e

printf '\nPhase 1C inner exit code: %s\n' "$INNER_RC"
if [[ "$INNER_RC" -ne 0 ]]; then
    printf 'FAIL: late-interruption durability run did not complete; characterization unavailable.\n' >&2
    exit "$INNER_RC"
fi

RUN_DIR="$(grep '^Evidence directory: ' "$WRAPPER_LOG" | tail -n 1 | sed 's/^Evidence directory: //')"
if [[ -z "$RUN_DIR" || ! -d "$RUN_DIR" ]]; then
    printf 'ERROR: could not resolve Phase 1C evidence directory from wrapper output\n' >&2
    exit 2
fi

# Phase 1C snapshots attempt 1 before destroying the link. The upstream
# loopsim rewrites /tmp/mB.log when attempt 2 starts, so copy that final log now
# before any later test can replace it.
cp -f /tmp/mA.log "$RUN_DIR/mA-attempt2-after-success.log" 2>/dev/null || true
cp -f /tmp/mB.log "$RUN_DIR/mB-attempt2-after-success.log" 2>/dev/null || true

ATTEMPT1_B_LOG="$RUN_DIR/mB-attempt1-before-loss.log"
ATTEMPT2_B_LOG="$RUN_DIR/mB-attempt2-after-success.log"
ATTEMPT1_RX="$(max_rx_total "$ATTEMPT1_B_LOG")"
ATTEMPT2_RX="$(max_rx_total "$ATTEMPT2_B_LOG")"
ATTEMPT1_RX="${ATTEMPT1_RX:-0}"
ATTEMPT2_RX="${ATTEMPT2_RX:-0}"

section "Mercury receive-layer characterization"
printf 'Attempt 1 max B rx_total before forced loss: %s bytes\n' "$ATTEMPT1_RX"
printf 'Attempt 2 max B rx_total after successful retry: %s bytes\n' "$ATTEMPT2_RX"
printf 'Application payload size: %s bytes\n' "$PAYLOAD_SIZE"

if ((ATTEMPT1_RX < PAYLOAD_SIZE / 4)); then
    printf 'INCONCLUSIVE: interruption occurred before enough receive-layer progress for a strong resume/retransmit comparison.\n'
    printf 'Evidence directory: %s\n' "$RUN_DIR"
    exit 3
fi

if ((ATTEMPT2_RX >= PAYLOAD_SIZE)); then
    printf 'OBSERVATION: retry received at least one full application-payload worth of bytes at the Mercury layer.\n'
    printf 'CLASSIFICATION: consistent with whole-file/job retransmission, not continuation near the interruption point.\n'
else
    printf 'OBSERVATION: retry received less than one full application-payload worth of bytes at the Mercury layer.\n'
    printf 'CLASSIFICATION: consistent with partial-transfer resume; inspect UUCP logs before treating this as a protocol guarantee.\n'
fi

# Emit a simple efficiency indicator. This is intentionally descriptive rather
# than a protocol guarantee because Mercury totals include UUCP framing/control.
python3 - "$PAYLOAD_SIZE" "$ATTEMPT1_RX" "$ATTEMPT2_RX" <<'PY'
import sys
payload, first, retry = map(int, sys.argv[1:])
print(f"Attempt 1 Mercury RX / payload: {first / payload:.2f}x")
print(f"Attempt 2 Mercury RX / payload: {retry / payload:.2f}x")
print(f"Combined Mercury RX / payload: {(first + retry) / payload:.2f}x")
PY

printf 'PASS: Phase 1D late-interruption characterization completed\n'
printf 'Evidence directory: %s\n' "$RUN_DIR"
