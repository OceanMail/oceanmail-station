#!/usr/bin/env bash
# Control the disposable containerized two-peer Mercury/Pulse loop used by
# self-hosted Phase 4I CI. Host networking preserves the canonical HERMES
# endpoints while keeping PulseAudio and Mercury build/runtime dependencies out
# of the runner host.

set -euo pipefail

ACTION="${1:-}"
IMAGE="${OCEANMAIL_MERCURY_DOCKER_IMAGE:-oceanmail-phase4i-mercury:ci}"
CONTAINER="${OCEANMAIL_MERCURY_DOCKER_CONTAINER:-oceanmail-phase4i-mercury}"
HOST_TMP="${OCEANMAIL_MERCURY_HOST_TMP:-/tmp}"
READY_FILE="$HOST_TMP/oceanmail-mercury-ready"

status() {
    docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -qx true || return 1
    docker exec "$CONTAINER" sh -lc '
        a=$(cat /tmp/oceanmail-mercury-a.pid 2>/dev/null || true)
        b=$(cat /tmp/oceanmail-mercury-b.pid 2>/dev/null || true)
        [ -n "$a" ] && [ -n "$b" ] && kill -0 "$a" 2>/dev/null && kill -0 "$b" 2>/dev/null
    '
}

case "$ACTION" in
    start)
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
        # The Mercury container owns the bind-mounted readiness/log files under
        # /tmp. Let the new container remove its prior files as the same UID;
        # the host runner must not try to unlink another user's files from the
        # sticky /tmp directory.
        docker run -d --name "$CONTAINER" --network host \
            -v "$HOST_TMP:/host-tmp" \
            "$IMAGE" >/dev/null
        for _ in $(seq 1 150); do
            if [[ -f "$READY_FILE" ]] && status; then
                printf 'PASS: containerized Mercury/Pulse loop is ready\n'
                exit 0
            fi
            if ! docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -qx true; then
                docker logs "$CONTAINER" >&2 2>/dev/null || true
                cat "$HOST_TMP/mA.log" >&2 2>/dev/null || true
                cat "$HOST_TMP/mB.log" >&2 2>/dev/null || true
                exit 1
            fi
            sleep 0.1
        done
        printf 'FAIL: Mercury container did not become ready\n' >&2
        docker logs "$CONTAINER" >&2 2>/dev/null || true
        cat "$HOST_TMP/mA.log" >&2 2>/dev/null || true
        cat "$HOST_TMP/mB.log" >&2 2>/dev/null || true
        exit 1
        ;;
    stop)
        # docker rm is sufficient. The next container instance, running as the
        # same image UID, owns cleanup of bind-mounted ready/log files.
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
        ;;
    status)
        status
        ;;
    drive)
        PAYLOAD_BYTES="${2:-1024}"
        TRANSFER_TIMEOUT="${3:-180}"
        status || {
            printf 'FAIL: Mercury container is not ready\n' >&2
            exit 1
        }
        docker exec \
            -e "PAYLOAD=$PAYLOAD_BYTES" \
            -e "TIMEOUT=$TRANSFER_TIMEOUT" \
            "$CONTAINER" \
            python3 /opt/mercury/utils/loopsim/drive.py
        ;;
    verify-pin)
        docker run --rm --entrypoint /bin/sh "$IMAGE" -lc '
            test "$(cat /opt/mercury/.oceanmail-tag)" = "v1.9.13"
            test "$(cat /opt/mercury/.oceanmail-sha)" = "4eac25e06a0c88996621bc74af5b7b2f0d353848"
        '
        printf 'PASS: Mercury container has exact OceanMail pin\n'
        ;;
    *)
        printf 'usage: %s {start|stop|status|drive [bytes timeout]|verify-pin}\n' "$0" >&2
        exit 2
        ;;
esac
