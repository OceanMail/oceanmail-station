#!/usr/bin/env bash
# CI-only transport adapter for Phase 4I.
#
# The canonical Phase 4I harness continues to derive from Phase 2B. On the
# minimal OceanMail self-hosted runner, this adapter changes only Mercury lab
# plumbing: host ALSA/snd-aloop is replaced with the pinned disposable
# Mercury+Pulse Docker loop. Phase 4I acceptance semantics stay in the canonical
# harness. The Phase 2B source is restored before exit.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHASE2B="$REPO_ROOT/scripts/phase2b-hermes-compressed-mail.sh"
PHASE2B_BACKUP="$(mktemp)"
cp "$PHASE2B" "$PHASE2B_BACKUP"

restore() {
    bash "$REPO_ROOT/scripts/phase4i-mercury-docker-loop.sh" stop >/dev/null 2>&1 || true
    cp "$PHASE2B_BACKUP" "$PHASE2B"
    rm -f "$PHASE2B_BACKUP"
}
trap restore EXIT

python3 - "$PHASE2B" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old = '''section "Verify pinned Mercury"
cd "$MERCURY_DIR"
git fetch --tags --prune origin >"$RUN_DIR/mercury-fetch.log" 2>&1
TAG_SHA="$(git rev-parse "refs/tags/$MERCURY_TAG^{commit}")"
[[ "$TAG_SHA" == "$MERCURY_SHA" ]] || { printf 'ERROR: Mercury pin mismatch\\n' >&2; exit 2; }
git switch --detach "$MERCURY_SHA" >/dev/null
make -j"$(nproc)" >"$RUN_DIR/mercury-build.log" 2>&1
make -C utils/loopsim >"$RUN_DIR/loopsim-build.log" 2>&1
printf 'PASS: pinned Mercury ready\\n'

section "Load ALSA loopback and start Mercury channel"
MODPROBE="$(resolve_cmd modprobe || true)"
[[ -n "$MODPROBE" ]] || { printf 'ERROR: modprobe not found\\n' >&2; exit 2; }
sudo "$MODPROBE" snd-aloop
sleep 1
CARD="$(awk '/Loopback/ {print $1; exit}' /proc/asound/cards 2>/dev/null || true)"
[[ -n "$CARD" ]] || { printf 'ERROR: ALSA Loopback card not found\\n' >&2; exit 2; }
printf 'Loopback ALSA card: %s\\n' "$CARD"
CARD="$CARD" MERCURY="./mercury" ./utils/loopsim/run_loopsim.sh 0.0 0.0 >"$RUN_DIR/loopsim-start.log" 2>&1
cat "$RUN_DIR/loopsim-start.log"
[[ "$(pgrep -x mercury | wc -l)" -eq 2 ]] || { printf 'ERROR: expected two Mercury processes\\n' >&2; exit 2; }
'''

new = '''section "Verify pinned Mercury container"
bash "$REPO_ROOT/scripts/phase4i-mercury-docker-loop.sh" verify-pin | tee "$RUN_DIR/mercury-container-pin.txt"
printf 'PASS: pinned Mercury container ready\\n'

section "Start Mercury channel in disposable PulseAudio container"
bash "$REPO_ROOT/scripts/phase4i-mercury-docker-loop.sh" start | tee "$RUN_DIR/loopsim-start.log"
bash "$REPO_ROOT/scripts/phase4i-mercury-docker-loop.sh" status
printf 'PASS: containerized Mercury peers are running on host-network TNC ports\\n'
'''

count = text.count(old)
if count != 1:
    raise SystemExit(
        f"ERROR: Phase 2B Mercury verify/start block: expected exactly one source block, found {count}"
    )

path.write_text(text.replace(old, new, 1))
print("PASS: CI adapter selected containerized pinned Mercury without changing canonical acceptance semantics")
PY

bash -n "$PHASE2B"
bash -n "$REPO_ROOT/scripts/phase4i-returned-receipt-evidence.sh"
bash "$REPO_ROOT/scripts/phase4i-returned-receipt-evidence.sh"
