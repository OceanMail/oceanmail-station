#!/usr/bin/env bash
# Adapted from owner kit: preserve push-before scope; reject divergent history.
set -euo pipefail
event="${GITHUB_EVENT_NAME:?}"
if [[ "$event" == pull_request ]]; then
  base="${PR_BASE_SHA:?}"
elif [[ "$event" == push && "${PUSH_BEFORE:-}" != 0000000000000000000000000000000000000000 ]]; then
  [[ "${PUSH_BEFORE:-}" =~ ^[0-9a-f]{40}$ ]] || { echo 'Invalid push-before SHA' >&2; exit 2; }
  base="$PUSH_BEFORE"
  git merge-base --is-ancestor "$base" HEAD || { echo 'Divergent push history requires explicit comparison policy' >&2; exit 2; }
elif [[ "$event" == workflow_dispatch || "$event" == push ]]; then
  # Initial branch push/manual run must compare with an ancestor of main.
  base="$(git merge-base HEAD refs/remotes/origin/main)"
  if [[ "$base" == "$(git rev-parse HEAD)" ]]; then
    # Never silently compare main to itself and claim coverage verification.
    base="$(git rev-parse HEAD^)"
  fi
else
  echo 'Unsupported event comparison policy' >&2
  exit 2
fi
[[ "$base" =~ ^[0-9a-f]{40}$ ]]
git cat-file -e "$base^{commit}"
base="$(git merge-base "$base" HEAD)"
[[ "$base" != "$(git rev-parse HEAD)" ]] || { echo 'Empty comparison scope' >&2; exit 2; }
printf 'QUALITY_BASE=%s\n' "$base" >> "${GITHUB_ENV:?}"
