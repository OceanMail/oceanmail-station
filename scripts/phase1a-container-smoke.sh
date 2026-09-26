#!/usr/bin/env bash
# OceanMail Station 0.2 — Phase 1A container/image smoke test
# Builds the disposable Debian 13 UUCP station lab image and verifies that the
# pinned HERMES uucpd/uuport plus Debian Taylor UUCP are present and isolated.

set -euo pipefail

IMAGE="${IMAGE:-oceanmail-uucp-lab:phase1}"
HERMES_NET_SHA="5c76adff754de49c0b934c7fd7bddf7619b0c3d6"
LOG_BASE="${LOG_BASE:-$HOME/oceanmail-logs}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$LOG_BASE/phase1a-container-$RUN_ID"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

mkdir -p "$RUN_DIR"

cleanup() {
    docker rm -f oceanmail-phase1a-a oceanmail-phase1a-b >/dev/null 2>&1 || true
}
trap cleanup EXIT

section() { printf '\n== %s ==\n' "$1"; }

section "Phase 1A environment"
printf 'UTC run id: %s\n' "$RUN_ID"
printf 'Image: %s\n' "$IMAGE"
printf 'HERMES net SHA: %s\n' "$HERMES_NET_SHA"
printf 'Evidence directory: %s\n' "$RUN_DIR"
docker --version

section "Build disposable UUCP station image"
if ! docker build \
    --pull \
    --build-arg "HERMES_NET_SHA=$HERMES_NET_SHA" \
    -f "$REPO_ROOT/lab/phase1/Dockerfile" \
    -t "$IMAGE" \
    "$REPO_ROOT" >"$RUN_DIR/docker-build.log" 2>&1; then
    printf 'ERROR: image build failed. Tail of build log:\n' >&2
    tail -n 160 "$RUN_DIR/docker-build.log" >&2
    exit 2
fi
printf 'PASS: image build completed (%s)\n' "$RUN_DIR/docker-build.log"

section "Verify station toolchain"
docker run --rm "$IMAGE" /bin/bash -lc '
set -euo pipefail
printf "Debian: "
. /etc/os-release
printf "%s %s (%s)\n" "$ID" "$VERSION_ID" "$VERSION_CODENAME"
printf "UUCP package: "
dpkg-query -W -f="\${Version}\n" uucp
printf "uucico: "
/usr/sbin/uucico --version | head -n 1
printf "HERMES net pin: "
cat /usr/local/share/oceanmail/hermes-net.sha
test "$(cat /usr/local/share/oceanmail/hermes-net.sha)" = "5c76adff754de49c0b934c7fd7bddf7619b0c3d6"
test -x /usr/local/bin/uucpd
test -x /usr/local/bin/uuport
printf "uucpd: present at /usr/local/bin/uucpd\n"
printf "uuport: present at /usr/local/bin/uuport\n"
' | tee "$RUN_DIR/toolchain.txt"

section "Verify separate IPC namespaces"
docker run -d --rm --name oceanmail-phase1a-a "$IMAGE" sleep 300 >/dev/null
docker run -d --rm --name oceanmail-phase1a-b "$IMAGE" sleep 300 >/dev/null

IPC_A="$(docker exec oceanmail-phase1a-a readlink /proc/1/ns/ipc)"
IPC_B="$(docker exec oceanmail-phase1a-b readlink /proc/1/ns/ipc)"
printf 'Station A IPC: %s\n' "$IPC_A" | tee "$RUN_DIR/ipc.txt"
printf 'Station B IPC: %s\n' "$IPC_B" | tee -a "$RUN_DIR/ipc.txt"

if [[ "$IPC_A" == "$IPC_B" ]]; then
    printf 'FAIL: containers share an IPC namespace; unsafe for two uucpd instances.\n' >&2
    exit 1
fi
printf 'PASS: station containers have distinct IPC namespaces\n' | tee -a "$RUN_DIR/ipc.txt"

section "Inspect clean baseline"
docker ps --filter name=oceanmail-phase1a- --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}'
docker image inspect "$IMAGE" --format 'Image ID: {{.Id}}' | tee "$RUN_DIR/image-id.txt"

printf '\nPASS: Phase 1A UUCP station container smoke test\n'
printf 'Evidence directory: %s\n' "$RUN_DIR"
