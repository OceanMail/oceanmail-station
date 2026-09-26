#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

cd "$REPO_ROOT"

command -v cargo >/dev/null 2>&1 || {
    echo "ERROR: cargo not found"
    exit 2
}

# Normalize GitHub-API-authored Rust before the strict formatter check in the
# acceptance harness. The resulting formatter diff and Cargo.lock are expected
# to be committed after a successful first acceptance run.
cargo fmt

exec bash "$REPO_ROOT/scripts/phase4a-station-service.sh"
