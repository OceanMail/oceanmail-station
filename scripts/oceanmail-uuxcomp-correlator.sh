#!/usr/bin/env bash
# OceanMail-owned deterministic Postfix -> HERMES/Taylor-UUCP correlation boundary.
#
# Postfix passes its authoritative queue ID to this wrapper. The pinned HERMES
# uuxcomp launches `uux` by name through popen(), so this wrapper prepends a
# per-invocation OceanMail shim to PATH. The shim calls the real Taylor `uux -j`,
# captures the authoritative job ID, and leaves all mail compression/UUCP behavior
# in the upstream programs.
#
# A correlation-recording failure MUST NOT turn a successfully queued upstream UUCP
# job into a Postfix retry, because that could duplicate mail. Such failures are
# logged and left as missing evidence for later diagnosis.

set -euo pipefail

if [[ $# -lt 5 ]]; then
    printf 'usage: %s POSTFIX_QUEUE_ID REMOTE_SYSTEM STATE_DB RECORDER_PATH CORRELATION_LOG [uuxcomp args...]\n' "$0" >&2
    exit 64
fi

POSTFIX_QUEUE_ID="$1"
REMOTE_SYSTEM="$2"
STATE_DB="$3"
RECORDER_PATH="$4"
CORRELATION_LOG="$5"
shift 5

UUXCOMP_PATH="${OCEANMAIL_UUXCOMP_PATH:-/usr/local/bin/uuxcomp}"
UUX_PATH="${OCEANMAIL_UUX_PATH:-/usr/bin/uux}"
UUSTAT_PATH="${OCEANMAIL_UUSTAT_PATH:-/usr/bin/uustat}"
CORRELATION_TIMEOUT_SECONDS="${OCEANMAIL_UUCP_CORRELATION_TIMEOUT_SECONDS:-45}"

mkdir -p "$(dirname "$CORRELATION_LOG")" 2>/dev/null || true

log() {
    printf '%s queue_id=%s remote=%s %s\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$POSTFIX_QUEUE_ID" "$REMOTE_SYSTEM" "$*" \
        >>"$CORRELATION_LOG" 2>/dev/null || true
}

for path in "$UUXCOMP_PATH" "$UUX_PATH" "$UUSTAT_PATH" "$RECORDER_PATH"; do
    if [[ ! -x "$path" ]]; then
        log "correlation_error=missing_executable path=$path"
        printf 'OceanMail correlation wrapper: missing executable %s\n' "$path" >&2
        exit 69
    fi
done

TMP_DIR="$(mktemp -d /tmp/oceanmail-uuxcomp-correlation.XXXXXX)"
JOB_FILE="$TMP_DIR/jobids.txt"
UUSTAT_FILE="$TMP_DIR/uustat.txt"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

cat >"$TMP_DIR/uux" <<'SHIM'
#!/usr/bin/env bash
set -euo pipefail
: "${OCEANMAIL_REAL_UUX:?missing OCEANMAIL_REAL_UUX}"
: "${OCEANMAIL_UUX_JOBFILE:?missing OCEANMAIL_UUX_JOBFILE}"
TMP_JOBFILE="${OCEANMAIL_UUX_JOBFILE}.tmp.$$"
cleanup_uux_shim() {
    rm -f "$TMP_JOBFILE"
}
trap cleanup_uux_shim EXIT
set +e
"$OCEANMAIL_REAL_UUX" -j "$@" >"$TMP_JOBFILE"
RC=$?
set -e
if [[ "$RC" -eq 0 ]]; then
    mv "$TMP_JOBFILE" "$OCEANMAIL_UUX_JOBFILE"
    trap - EXIT
fi
exit "$RC"
SHIM
chmod 0755 "$TMP_DIR/uux"

log 'handoff_start correlation_boundary=postfix_queue_id+uux_jobid'
set +e
PATH="$TMP_DIR:$PATH" \
    OCEANMAIL_REAL_UUX="$UUX_PATH" \
    OCEANMAIL_UUX_JOBFILE="$JOB_FILE" \
    "$UUXCOMP_PATH" "$@"
UPSTREAM_RC=$?
set -e

if [[ "$UPSTREAM_RC" -ne 0 ]]; then
    log "uuxcomp_exit=$UPSTREAM_RC correlation_skipped=true"
    exit "$UPSTREAM_RC"
fi

JOB_FILE_READY=0
for _ in $(seq 1 "$CORRELATION_TIMEOUT_SECONDS"); do
    if [[ -s "$JOB_FILE" ]]; then
        JOB_FILE_READY=1
        break
    fi
    sleep 1
done

if [[ "$JOB_FILE_READY" -ne 1 ]]; then
    log "uuxcomp_exit=0 correlation_error=no_uux_jobid timeout_seconds=$CORRELATION_TIMEOUT_SECONDS"
    printf 'OceanMail correlation wrapper: uuxcomp returned success but Taylor uux did not expose a job ID for Postfix queue %s\n' \
        "$POSTFIX_QUEUE_ID" >&2
    exit 0
fi

mapfile -t JOB_IDS < <(sed '/^[[:space:]]*$/d' "$JOB_FILE")
if [[ "${#JOB_IDS[@]}" -ne 1 ]]; then
    log "uuxcomp_exit=0 correlation_error=unexpected_jobid_count count=${#JOB_IDS[@]} jobids=$(tr '\n' ',' <"$JOB_FILE")"
    printf 'OceanMail correlation wrapper: expected one Taylor UUCP job ID for Postfix queue %s, found %s\n' \
        "$POSTFIX_QUEUE_ID" "${#JOB_IDS[@]}" >&2
    exit 0
fi
UUCP_JOB_ID="${JOB_IDS[0]}"

UUSTAT_MATCHED=0
NEW_LINE=""
for _ in $(seq 1 "$CORRELATION_TIMEOUT_SECONDS"); do
    "$UUSTAT_PATH" -a >"$UUSTAT_FILE" 2>/dev/null || true
    NEW_LINE="$(awk -v job="$UUCP_JOB_ID" '$1 == job { print; exit }' "$UUSTAT_FILE")"
    if [[ -n "$NEW_LINE" ]]; then
        UUSTAT_MATCHED=1
        break
    fi
    sleep 1
done

if [[ "$UUSTAT_MATCHED" -ne 1 ]]; then
    log "uuxcomp_exit=0 uucp_job_id=$UUCP_JOB_ID correlation_error=jobid_missing_from_uustat timeout_seconds=$CORRELATION_TIMEOUT_SECONDS"
    printf 'OceanMail correlation wrapper: Taylor uux reported job %s but uustat did not confirm it for Postfix queue %s\n' \
        "$UUCP_JOB_ID" "$POSTFIX_QUEUE_ID" >&2
    exit 0
fi

OBSERVED_SYSTEM="$(printf '%s\n' "$NEW_LINE" | awk '{print $2}')"
QUEUED_BYTES="$(printf '%s\n' "$NEW_LINE" | sed -nE 's/.*\(sending ([0-9]+) bytes\).*/\1/p')"

if [[ "$OBSERVED_SYSTEM" != "$REMOTE_SYSTEM" || "$NEW_LINE" != *"Executing crmail"* || -z "$QUEUED_BYTES" ]]; then
    log "uuxcomp_exit=0 uucp_job_id=$UUCP_JOB_ID correlation_error=uustat_semantic_mismatch line=$(printf '%q' "$NEW_LINE")"
    printf 'OceanMail correlation wrapper: Taylor job %s does not match expected %s/crmail evidence for Postfix queue %s\n' \
        "$UUCP_JOB_ID" "$REMOTE_SYSTEM" "$POSTFIX_QUEUE_ID" >&2
    exit 0
fi

set +e
RECORDER_OUTPUT="$({
    "$RECORDER_PATH" record \
        --state-db "$STATE_DB" \
        --postfix-queue-id "$POSTFIX_QUEUE_ID" \
        --remote-system "$REMOTE_SYSTEM" \
        --uucp-job-id "$UUCP_JOB_ID" \
        --command crmail \
        --queued-bytes "$QUEUED_BYTES"
} 2>&1)"
RECORDER_RC=$?
set -e

if [[ "$RECORDER_RC" -ne 0 ]]; then
    log "uuxcomp_exit=0 uucp_job_id=$UUCP_JOB_ID queued_bytes=$QUEUED_BYTES correlation_error=recorder_failed recorder_rc=$RECORDER_RC recorder_output=$(printf '%q' "$RECORDER_OUTPUT")"
    printf 'OceanMail correlation wrapper: UUCP job %s exists, but Station evidence recording failed for Postfix queue %s\n' \
        "$UUCP_JOB_ID" "$POSTFIX_QUEUE_ID" >&2
    exit 0
fi

log "uuxcomp_exit=0 correlation=recorded uucp_job_id=$UUCP_JOB_ID command=crmail queued_bytes=$QUEUED_BYTES recorder_output=$(printf '%q' "$RECORDER_OUTPUT")"
printf 'OceanMail correlation: Postfix %s -> UUCP %s/%s (%s bytes, crmail)\n' \
    "$POSTFIX_QUEUE_ID" "$REMOTE_SYSTEM" "$UUCP_JOB_ID" "$QUEUED_BYTES" >&2
exit 0
