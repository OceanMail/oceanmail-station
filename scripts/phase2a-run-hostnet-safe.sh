#!/usr/bin/env bash
# Runtime compatibility wrapper for Phase 2A on Docker host networking.
# Phase 2A does not need SMTP sockets; local sendmail and remote rmail are used.
# Patch a temporary in-repo copy so its REPO_ROOT resolution remains correct.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$REPO_ROOT/scripts/phase2a-rfc-mail.sh"
RUNTIME_COPY="$(mktemp "$REPO_ROOT/scripts/.phase2a-runtime.XXXXXX.sh")"

cleanup() {
    rm -f "$RUNTIME_COPY"
}
trap cleanup EXIT

python3 - "$SOURCE" "$RUNTIME_COPY" <<'PY'
from pathlib import Path
import sys

src_path = Path(sys.argv[1])
dst_path = Path(sys.argv[2])
src = src_path.read_text()

replacements = {
    '    local container="$1" fqdn="$2" destination="$3" listen_ip="$4"\n':
        '    local container="$1" fqdn="$2" destination="$3"\n',
    '    docker exec "$container" /usr/sbin/postconf -e "inet_interfaces = $listen_ip"\n':
        "    docker exec \"$container\" /usr/sbin/postconf -e 'inet_interfaces = all'\n"
        "    # Host-networked lab containers share one network namespace. Disable the\n"
        "    # SMTP inet listener entirely; Phase 2A uses local sendmail and rmail.\n"
        "    docker exec \"$container\" /bin/bash -lc \"sed -ri 's/^(smtp[[:space:]]+inet[[:space:]].*)/# \\\\1/' /etc/postfix/master.cf\"\n",
    "    docker exec \"$container\" /usr/sbin/postconf -e 'maillog_file = /evidence/postfix.log'\n":
        "    docker exec \"$container\" /usr/sbin/postconf -e 'maillog_file_prefixes = /var, /dev/stdout, /evidence'\n"
        "    docker exec \"$container\" /usr/sbin/postconf -e 'maillog_file = /evidence/postfix.log'\n",
    'configure_postfix "$A_NAME" stationa.test stationa.test 127.0.0.2\n':
        'configure_postfix "$A_NAME" stationa.test stationa.test\n',
    'configure_postfix "$B_NAME" stationb.test stationb.test 127.0.0.3\n':
        'configure_postfix "$B_NAME" stationb.test stationb.test\n',
}

for old, new in replacements.items():
    if old not in src:
        raise SystemExit(f"ERROR: expected Phase 2A source fragment not found: {old!r}")
    src = src.replace(old, new, 1)

dst_path.write_text(src)
PY

chmod +x "$RUNTIME_COPY"

set +e
bash "$RUNTIME_COPY"
RC=$?
set -e

exit "$RC"
