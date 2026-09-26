#!/usr/bin/env bash
# OceanMail Station 0.2 — Phase 3B standard client over HERMES/Mercury
# Reuses the accepted Phase 2B transport harness and changes only the client
# boundaries: SMTP submission into Station A and authenticated IMAP retrieval
# from Station B after the compressed UUCP/Mercury transfer.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$REPO_ROOT/scripts/phase2b-hermes-compressed-mail.sh"
RUNTIME_COPY="$(mktemp "$REPO_ROOT/scripts/.phase3b-runtime.XXXXXX.sh")"

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
    'PHASE2B_IMAGE="${PHASE2B_IMAGE:-oceanmail-mail-lab:phase2b}"\n':
        'PHASE2B_IMAGE="${PHASE2B_IMAGE:-oceanmail-mail-lab:phase2b}"\n'
        'PHASE3_IMAGE="${PHASE3_IMAGE:-oceanmail-mail-client-lab:phase3}"\n'
        'SMTP_PORT="${SMTP_PORT:-2525}"\n'
        'IMAP_PORT="${IMAP_PORT:-2143}"\n'
        'LAB_PASSWORD="${LAB_PASSWORD:-oceanmail-lab}"\n',
    'RUN_DIR="$LOG_BASE/phase2b-hermes-mail-$RUN_ID"\n':
        'RUN_DIR="$LOG_BASE/phase3b-standard-client-hf-$RUN_ID"\n',
    'A_NAME="oceanmail-mail-a"\nB_NAME="oceanmail-mail-b"\nMESSAGE_ID="<phase2b-$RUN_ID@stationa.test>"\nBODY_TOKEN="OceanMail-Phase2B-$RUN_ID-body-check"\nSUBJECT="OceanMail Phase 2A RFC mail proof"\n':
        'A_NAME="oceanmail-client-a"\nB_NAME="oceanmail-client-b"\nMESSAGE_ID="<phase3b-$RUN_ID@stationa.test>"\nBODY_TOKEN="OceanMail-Phase3B-$RUN_ID-body-check"\nSUBJECT="OceanMail Phase 3B RFC mail proof"\n',
    'section "Phase 2B environment"\n':
        'section "Phase 3B environment"\n'
        'printf \'SMTP submission endpoint: 127.0.0.1:%s\\n\' "$SMTP_PORT"\n'
        'printf \'IMAP retrieval endpoint: 127.0.0.1:%s\\n\' "$IMAP_PORT"\n',
    "printf 'PASS: HERMES uuxcomp/crmail image ready\\n'\n":
        "printf 'PASS: HERMES uuxcomp/crmail image ready\\n'\n"
        'docker build -f "$REPO_ROOT/lab/phase3/Dockerfile" -t "$PHASE3_IMAGE" "$REPO_ROOT" \\\n'
        '    >"$RUN_DIR/phase3-image-build.log" 2>&1 || { \\\n'
        "        printf 'ERROR: Phase 3 standard-client image build failed\\n' >&2; \\\n"
        '        tail -n 180 "$RUN_DIR/phase3-image-build.log" >&2; exit 2; \\\n'
        '    }\n'
        "printf 'PASS: Phase 3 standard-client image ready\\n'\n",
    '    "$PHASE2B_IMAGE" sleep infinity >/dev/null\n':
        '    "$PHASE3_IMAGE" sleep infinity >/dev/null\n',
    'configure_postfix "$A_NAME" stationa.test stationa.test\nconfigure_postfix "$B_NAME" stationb.test stationb.test\n\n':
        'configure_postfix "$A_NAME" stationa.test stationa.test\n'
        'configure_postfix "$B_NAME" stationb.test stationb.test\n\n'
        '# Re-enable SMTP only on Station A, on an isolated lab port.\n'
        'docker exec "$A_NAME" /bin/bash -lc "printf \'%s\\n\' \'127.0.0.1:${SMTP_PORT} inet n - n - - smtpd\' >> /etc/postfix/master.cf"\n'
        'docker exec "$A_NAME" /usr/sbin/postconf -e \'mynetworks = 127.0.0.0/8\'\n'
        'docker exec "$A_NAME" /usr/sbin/postconf -e \'smtpd_relay_restrictions = permit_mynetworks, reject_unauth_destination\'\n\n',
    'section "Create Phase 2A-equivalent RFC text message"\n':
        'section "Create Phase 3B RFC text message"\n',
    'This message is a deterministic OceanMail Phase 2A text-email acceptance payload.\nIt was accepted by Postfix, queued into UUCP, transferred by HERMES/Mercury,\nand delivered through remote rmail into the Station B local mailbox.\n':
        'This message is a deterministic OceanMail Phase 3B standard-client payload.\nIt was submitted by standard SMTP, compressed into UUCP, transferred by HERMES/Mercury,\nand retrieved from Station B through standard authenticated IMAP.\n',
    'section "State 1: local Postfix acceptance"\ndocker exec -i "$A_NAME" /usr/sbin/sendmail -i -f alice@stationa.test bob@stationb.test <"$MESSAGE_FILE"\n':
        'section "State 1: standard SMTP submission into Station A"\n'
        'python3 - "$SMTP_PORT" "$MESSAGE_FILE" <<\'PYSMTP\' | tee "$RUN_DIR/smtp-client.txt"\n'
        'from email import policy\n'
        'from email.parser import BytesParser\n'
        'import smtplib, socket, sys\n'
        'port = int(sys.argv[1])\n'
        'path = sys.argv[2]\n'
        'with socket.create_connection(("127.0.0.1", port), timeout=5):\n'
        '    pass\n'
        'with open(path, "rb") as fp:\n'
        '    msg = BytesParser(policy=policy.default).parse(fp)\n'
        'with smtplib.SMTP("127.0.0.1", port, timeout=10) as smtp:\n'
        '    smtp.ehlo()\n'
        '    refused = smtp.send_message(msg, from_addr="alice@stationa.test", to_addrs=["bob@stationb.test"])\n'
        '    if refused:\n'
        '        raise SystemExit(f"FAIL: SMTP refused recipients: {refused!r}")\n'
        'print(f"PASS: standard SMTP accepted {msg[\'Message-ID\']}")\n'
        'PYSMTP\n',
    "printf 'PASS: Postfix accepted message; compressed UUCP handoff not yet started\\n'\n":
        "printf 'PASS: standard SMTP submission accepted; compressed UUCP handoff not yet started\\n'\n",
    'section "Phase 2B result"\n':
        'section "State 5: expose Station B mailbox over authenticated IMAP"\n'
        'cat >"$RUN_DIR/dovecot-b.conf" <<EOF\n'
        'dovecot_config_version = 2.4.0\n'
        'dovecot_storage_version = 2.4.0\n'
        'protocols = imap\n'
        'listen = 127.0.0.1\n'
        'ssl = no\n'
        'auth_allow_cleartext = yes\n'
        'auth_mechanisms = plain login\n'
        'log_path = /evidence/dovecot.log\n'
        'info_log_path = /evidence/dovecot-info.log\n'
        'mail_driver = mbox\n'
        'mail_path = ~/mail\n'
        'mail_inbox_path = /var/mail/%{user}\n'
        'mail_index_path = ~/mail/.imap\n'
        'mbox_read_locks = fcntl\n'
        'mbox_write_locks = fcntl\n'
        '\n'
        'passdb passwd-file {\n'
        '  passwd_file_path = /etc/dovecot/passwd\n'
        '}\n'
        '\n'
        'userdb passwd {\n'
        '}\n'
        '\n'
        'service imap-login {\n'
        '  inet_listener imap {\n'
        '    port = $IMAP_PORT\n'
        '  }\n'
        '  inet_listener imaps {\n'
        '    port = 0\n'
        '  }\n'
        '}\n'
        'EOF\n'
        'cat >"$RUN_DIR/dovecot-passwd" <<EOF\n'
        'bob:{PLAIN}$LAB_PASSWORD\n'
        'EOF\n'
        'docker cp "$RUN_DIR/dovecot-b.conf" "$B_NAME:/etc/dovecot/dovecot.conf" >/dev/null\n'
        'docker cp "$RUN_DIR/dovecot-passwd" "$B_NAME:/etc/dovecot/passwd" >/dev/null\n'
        'docker exec "$B_NAME" chown root:dovecot /etc/dovecot/passwd\n'
        'docker exec "$B_NAME" chmod 0640 /etc/dovecot/passwd\n'
        'docker exec "$B_NAME" mkdir -p /home/bob/mail\n'
        'docker exec "$B_NAME" chown -R bob:bob /home/bob/mail\n'
        'docker exec "$B_NAME" /usr/bin/doveconf -c /etc/dovecot/dovecot.conf >"$RUN_DIR/b/evidence/doveconf.txt"\n'
        'docker exec "$B_NAME" /usr/sbin/dovecot -c /etc/dovecot/dovecot.conf\n'
        'sleep 2\n'
        'docker exec "$B_NAME" /usr/bin/doveadm auth test bob "$LAB_PASSWORD" | tee "$RUN_DIR/b/evidence/doveadm-auth.txt"\n'
        '\n'
        'python3 - "$IMAP_PORT" "$LAB_PASSWORD" "$MESSAGE_ID" "$SUBJECT" "$BODY_TOKEN" <<\'PYIMAP\' | tee "$RUN_DIR/imap-client.txt"\n'
        'from email import policy\n'
        'from email.parser import BytesParser\n'
        'import imaplib, sys\n'
        'port = int(sys.argv[1])\n'
        'password, wanted_id, wanted_subject, body_token = sys.argv[2:]\n'
        'client = imaplib.IMAP4("127.0.0.1", port)\n'
        'try:\n'
        '    typ, _ = client.login("bob", password)\n'
        '    if typ != "OK":\n'
        '        raise SystemExit("FAIL: IMAP login failed")\n'
        '    typ, _ = client.select("INBOX", readonly=True)\n'
        '    if typ != "OK":\n'
        '        raise SystemExit("FAIL: IMAP SELECT failed")\n'
        '    typ, data = client.search(None, "ALL")\n'
        '    if typ != "OK":\n'
        '        raise SystemExit("FAIL: IMAP SEARCH failed")\n'
        '    matches = []\n'
        '    for seq in data[0].split():\n'
        '        typ, fetched = client.fetch(seq, "(RFC822)")\n'
        '        if typ != "OK":\n'
        '            continue\n'
        '        raw = next((item[1] for item in fetched if isinstance(item, tuple)), None)\n'
        '        if raw is None:\n'
        '            continue\n'
        '        msg = BytesParser(policy=policy.default).parsebytes(raw)\n'
        '        if (msg.get("Message-ID") or "").strip() == wanted_id:\n'
        '            matches.append(msg)\n'
        '    if len(matches) != 1:\n'
        '        raise SystemExit(f"FAIL: expected one IMAP message {wanted_id!r}, found {len(matches)}")\n'
        '    msg = matches[0]\n'
        '    if (msg.get("Subject") or "").strip() != wanted_subject:\n'
        '        raise SystemExit(f"FAIL: subject mismatch: {msg.get(\'Subject\')!r}")\n'
        '    if "bob@stationb.test" not in (msg.get("To") or ""):\n'
        '        raise SystemExit(f"FAIL: recipient mismatch: {msg.get(\'To\')!r}")\n'
        '    body = msg.get_body(preferencelist=("plain",))\n'
        '    text = body.get_content() if body else msg.get_content()\n'
        '    if body_token not in text:\n'
        '        raise SystemExit("FAIL: body token missing from IMAP-retrieved message")\n'
        '    print(f"PASS: IMAP login as bob")\n'
        '    print(f"PASS: IMAP retrieved {wanted_id}")\n'
        '    print(f"PASS: Subject {wanted_subject}")\n'
        '    print(f"PASS: body token {body_token}")\n'
        'finally:\n'
        '    try:\n'
        '        client.logout()\n'
        '    except Exception:\n'
        '        pass\n'
        'PYIMAP\n'
        '\n'
        'section "Phase 3B result"\n',
    "printf 'PASS: RFC text email delivered through HERMES uuxcomp/crmail compression boundary\\n'\n":
        "printf 'PASS: standard SMTP -> HERMES/Mercury -> authenticated IMAP end-to-end path succeeded\\n'\n",
}

for old, new in replacements.items():
    if old == '    "$PHASE2B_IMAGE" sleep infinity >/dev/null\n':
        count = src.count(old)
        if count != 2:
            raise SystemExit(f"ERROR: expected 2 Phase 2B container image fragments, found {count}")
        src = src.replace(old, new, 2)
        continue
    if old not in src:
        raise SystemExit(f"ERROR: expected Phase 2B source fragment not found: {old!r}")
    src = src.replace(old, new, 1)

src = src.replace('[Phase 2B]', '[Phase 3B]')
src = src.replace('Phase 2A text-email acceptance payload', 'Phase 3B standard-client payload')

dst_path.write_text(src)
PY

chmod +x "$RUNTIME_COPY"
bash -n "$RUNTIME_COPY" || {
    echo "ERROR: generated Phase 3B runtime script failed bash syntax validation" >&2
    exit 2
}

set +e
bash "$RUNTIME_COPY"
RC=$?
set -e
exit "$RC"
