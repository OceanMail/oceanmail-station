#!/usr/bin/env bash
# OceanMail Phase 4I laboratory receipt-ingest boundary.
#
# Taylor UUCP invokes this command on the origin Station. It atomically stores
# one returned receipt artifact for later OceanMail validation/correlation. It
# deliberately does not interpret the artifact or claim receipt by itself.
#
# This helper is laboratory-only. The resulting receipt contains only Phase 4I
# correlation metadata (no message body or credentials) and must be readable by
# the host-side acceptance recorder after UUCP writes it through a bind mount.

set -euo pipefail

DEST_DIR="${OCEANMAIL_RETURNED_RECEIPT_DIR:-/evidence/returned-receipts}"
DEST_FILE="$DEST_DIR/receipt.json"

mkdir -p "$DEST_DIR"
umask 077

if [[ -e "$DEST_FILE" ]]; then
    printf 'OceanMail receipt ingest: destination already exists: %s\n' "$DEST_FILE" >&2
    exit 73
fi

TMP_FILE="$DEST_DIR/.receipt.$$.$RANDOM.tmp"
cleanup() {
    rm -f "$TMP_FILE"
}
trap cleanup EXIT

cat >"$TMP_FILE"

if [[ ! -s "$TMP_FILE" ]]; then
    printf 'OceanMail receipt ingest: refusing empty artifact\n' >&2
    exit 65
fi

mv "$TMP_FILE" "$DEST_FILE"
# Phase 4I evidence lives in a disposable lab bind mount and is consumed by the
# host-side acceptance recorder. Make this non-sensitive receipt metadata
# host-readable without weakening production storage semantics.
chmod 0644 "$DEST_FILE"
trap - EXIT
printf 'OceanMail receipt ingest: stored returned artifact at %s\n' "$DEST_FILE" >&2
