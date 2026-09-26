#!/usr/bin/env bash
# OceanMail Station 0.2 — Phase 3A standard mail-client compatibility
# Proves an ordinary SMTP client can submit to the station and an ordinary
# IMAP client can retrieve and update the resulting RFC message in the station mailbox.

set -euo pipefail

PHASE1_IMAGE="${PHASE1_IMAGE:-oceanmail-uucp-lab:phase1}"
PHASE2_IMAGE="${PHASE2_IMAGE:-oceanmail-mail-lab:phase2}"
PHASE2B_IMAGE="${PHASE2B_IMAGE:-oceanmail-mail-lab:phase2b}"
PHASE3_IMAGE="${PHASE3_IMAGE:-oceanmail-mail-client-lab:phase3}"
HERMES_NET_SHA="0fee4a53f54074ad6237b9fa1083a272cac89f60"
LIBCMIME_SHA="dd21eb096d162656e30243f60fc4bc35ad39ae6e"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_BASE="${LOG_BASE:-$HOME/oceanmail-logs}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$LOG_BASE/phase3a-standard-mail-client-$RUN_ID"
NAME="oceanmail-standard-client"
SMTP_PORT="${SMTP_PORT:-2525}"
IMAP_PORT="${IMAP_PORT:-2143}"
MESSAGE_ID="<phase3a-$RUN_ID@station.test>"
BODY_TOKEN="OceanMail-Phase3A-$RUN_ID-body-check"
SUBJECT="OceanMail Phase 3A standard client proof"
LAB_PASSWORD="oceanmail-lab"

mkdir -p "$RUN_DIR/evidence"
chmod 0777 "$RUN_DIR/evidence"

section() { printf '\n== %s ==\n' "$1"; }

cleanup() {
    docker rm -f "$NAME" >/dev/null 2>&1 || true
}
trap cleanup EXIT

for cmd in docker python3; do
    command -v "$cmd" >/dev/null 2>&1 || {
        printf 'ERROR: missing host command: %s\n' "$cmd" >&2
        exit 2
    }
done

section "Phase 3A environment"
printf 'UTC run id: %s\n' "$RUN_ID"
printf 'SMTP endpoint: 127.0.0.1:%s\n' "$SMTP_PORT"
printf 'IMAP endpoint: 127.0.0.1:%s\n' "$IMAP_PORT"
printf 'Message-ID: %s\n' "$MESSAGE_ID"
printf 'Evidence directory: %s\n' "$RUN_DIR"

section "Build station images"
if ! docker build \
    --build-arg "HERMES_NET_SHA=$HERMES_NET_SHA" \
    -f "$REPO_ROOT/lab/phase1/Dockerfile" \
    -t "$PHASE1_IMAGE" "$REPO_ROOT" >"$RUN_DIR/phase1-image-build.log" 2>&1; then
    printf 'ERROR: Phase 1 image build failed\n' >&2
    tail -n 120 "$RUN_DIR/phase1-image-build.log" >&2
    exit 2
fi

if ! docker build \
    -f "$REPO_ROOT/lab/phase2/Dockerfile" \
    -t "$PHASE2_IMAGE" "$REPO_ROOT" >"$RUN_DIR/phase2-image-build.log" 2>&1; then
    printf 'ERROR: Phase 2 image build failed\n' >&2
    tail -n 120 "$RUN_DIR/phase2-image-build.log" >&2
    exit 2
fi

if ! docker build \
    --build-arg "HERMES_NET_SHA=$HERMES_NET_SHA" \
    --build-arg "LIBCMIME_SHA=$LIBCMIME_SHA" \
    -f "$REPO_ROOT/lab/phase2b/Dockerfile" \
    -t "$PHASE2B_IMAGE" "$REPO_ROOT" >"$RUN_DIR/phase2b-image-build.log" 2>&1; then
    printf 'ERROR: Phase 2B image build failed\n' >&2
    tail -n 160 "$RUN_DIR/phase2b-image-build.log" >&2
    exit 2
fi

if ! docker build \
    -f "$REPO_ROOT/lab/phase3/Dockerfile" \
    -t "$PHASE3_IMAGE" "$REPO_ROOT" >"$RUN_DIR/phase3-image-build.log" 2>&1; then
    printf 'ERROR: Phase 3 image build failed\n' >&2
    tail -n 160 "$RUN_DIR/phase3-image-build.log" >&2
    exit 2
fi
printf 'PASS: standard-client station image ready\n'

section "Start disposable station"
docker rm -f "$NAME" >/dev/null 2>&1 || true
docker run -d --name "$NAME" --hostname station \
    -p "127.0.0.1:$SMTP_PORT:25" \
    -p "127.0.0.1:$IMAP_PORT:143" \
    -v "$RUN_DIR/evidence:/evidence" \
    "$PHASE3_IMAGE" sleep infinity >/dev/null

section "Configure Postfix SMTP submission"
docker exec "$NAME" /usr/sbin/postconf -e 'compatibility_level = 3.6'
docker exec "$NAME" /usr/sbin/postconf -e 'myhostname = station.test'
docker exec "$NAME" /usr/sbin/postconf -e 'mydomain = station.test'
docker exec "$NAME" /usr/sbin/postconf -e 'myorigin = $myhostname'
docker exec "$NAME" /usr/sbin/postconf -e 'inet_interfaces = all'
docker exec "$NAME" /usr/sbin/postconf -e 'inet_protocols = ipv4'
docker exec "$NAME" /usr/sbin/postconf -e 'mydestination = station.test, localhost'
docker exec "$NAME" /usr/sbin/postconf -e 'mynetworks = 0.0.0.0/0'
docker exec "$NAME" /usr/sbin/postconf -e 'smtpd_relay_restrictions = permit_mynetworks, reject_unauth_destination'
docker exec "$NAME" /usr/sbin/postconf -e 'maillog_file_prefixes = /var, /evidence'
docker exec "$NAME" /usr/sbin/postconf -e 'maillog_file = /evidence/postfix.log'
docker exec "$NAME" /usr/sbin/postfix check
docker exec "$NAME" /usr/sbin/postfix start
sleep 2
docker exec "$NAME" pgrep -x master >/dev/null || {
    printf 'ERROR: Postfix master is not running\n' >&2
    cat "$RUN_DIR/evidence/postfix.log" >&2 || true
    exit 2
}
printf 'PASS: Postfix SMTP service running\n'

section "Configure Dovecot IMAP"
cat >"$RUN_DIR/dovecot.conf" <<'EOF'
dovecot_config_version = 2.4.0
dovecot_storage_version = 2.4.0
protocols = imap
listen = *
ssl = no
auth_allow_cleartext = yes
auth_mechanisms = plain login
log_path = /evidence/dovecot.log
info_log_path = /evidence/dovecot-info.log
mail_driver = mbox
mail_path = ~/mail
mail_inbox_path = /var/mail/%{user}
mail_index_path = ~/mail/.imap
mbox_read_locks = fcntl
mbox_write_locks = fcntl

passdb passwd-file {
  passwd_file_path = /etc/dovecot/passwd
}

userdb passwd {
}

service imap-login {
  inet_listener imap {
    port = 143
  }
  inet_listener imaps {
    port = 0
  }
}
EOF

cat >"$RUN_DIR/dovecot-passwd" <<EOF
bob:{PLAIN}$LAB_PASSWORD
EOF
chmod 0600 "$RUN_DIR/dovecot-passwd"

docker cp "$RUN_DIR/dovecot.conf" "$NAME:/etc/dovecot/dovecot.conf" >/dev/null
docker cp "$RUN_DIR/dovecot-passwd" "$NAME:/etc/dovecot/passwd" >/dev/null
docker exec "$NAME" chown root:root /etc/dovecot/dovecot.conf
docker exec "$NAME" chmod 0600 /etc/dovecot/dovecot.conf
docker exec "$NAME" chown root:dovecot /etc/dovecot/passwd
docker exec "$NAME" chmod 0640 /etc/dovecot/passwd
docker exec "$NAME" mkdir -p /home/bob/mail
docker exec "$NAME" chown -R bob:bob /home/bob/mail

docker exec "$NAME" sh -lc "id -nG bob | tr ' ' '\n' | grep -Fx mail" >/dev/null || {
    printf 'ERROR: Bob is not a member of the mail group\n' >&2
    docker exec "$NAME" id bob >&2 || true
    exit 2
}
printf 'PASS: Bob has mail-group access required for mbox locking/writes\n'

docker exec "$NAME" /usr/bin/doveconf -c /etc/dovecot/dovecot.conf >"$RUN_DIR/evidence/doveconf.txt"
docker exec "$NAME" /usr/sbin/dovecot -c /etc/dovecot/dovecot.conf
sleep 2
docker exec "$NAME" pgrep -x dovecot >/dev/null || {
    printf 'ERROR: Dovecot is not running\n' >&2
    cat "$RUN_DIR/evidence/dovecot.log" >&2 || true
    exit 2
}
docker exec "$NAME" /usr/bin/doveadm auth test bob "$LAB_PASSWORD" | tee "$RUN_DIR/evidence/doveadm-auth.txt"
printf 'PASS: Dovecot IMAP service running and bob authentication succeeds\n'

section "Verify standard protocol ports"
python3 - "$SMTP_PORT" "$IMAP_PORT" <<'PY'
import socket, sys
for label, port in [('SMTP', int(sys.argv[1])), ('IMAP', int(sys.argv[2]))]:
    with socket.create_connection(('127.0.0.1', port), timeout=5):
        print(f'PASS: {label} TCP endpoint reachable on 127.0.0.1:{port}')
PY

section "Submit RFC message through standard SMTP"
python3 - "$SMTP_PORT" "$MESSAGE_ID" "$SUBJECT" "$BODY_TOKEN" <<'PY' | tee "$RUN_DIR/smtp-client.txt"
from email.message import EmailMessage
import smtplib, sys

port = int(sys.argv[1])
message_id, subject, body_token = sys.argv[2:]
msg = EmailMessage()
msg['From'] = 'Alice <alice@station.test>'
msg['To'] = 'Bob <bob@station.test>'
msg['Message-ID'] = message_id
msg['Subject'] = subject
msg.set_content(body_token + '\nThis message was submitted using standard SMTP client semantics.\n')
with smtplib.SMTP('127.0.0.1', port, timeout=10) as smtp:
    smtp.ehlo()
    result = smtp.send_message(msg, from_addr='alice@station.test', to_addrs=['bob@station.test'])
    if result:
        raise SystemExit(f'FAIL: SMTP refused recipients: {result!r}')
print(f'PASS: SMTP accepted {message_id}')
PY

MAILBOX_READY=0
for _ in $(seq 1 30); do
    if docker exec "$NAME" test -s /var/mail/bob 2>/dev/null; then
        MAILBOX_READY=1
        break
    fi
    sleep 1
done
if [[ "$MAILBOX_READY" -ne 1 ]]; then
    printf 'FAIL: Postfix did not create Bob mailbox after SMTP submission\n' >&2
    cat "$RUN_DIR/evidence/postfix.log" >&2 || true
    exit 1
fi
printf 'PASS: SMTP-submitted message reached Bob local mailbox\n'

docker cp "$NAME:/var/mail/bob" "$RUN_DIR/bob-mailbox-before-imap.mbox" >/dev/null

section "Retrieve and update RFC message through standard IMAP"
python3 - "$IMAP_PORT" "$LAB_PASSWORD" "$MESSAGE_ID" "$SUBJECT" "$BODY_TOKEN" <<'PY' | tee "$RUN_DIR/imap-client.txt"
from email import policy
from email.parser import BytesParser
import imaplib, sys

port = int(sys.argv[1])
password, wanted_id, wanted_subject, body_token = sys.argv[2:]
client = imaplib.IMAP4('127.0.0.1', port)
try:
    typ, _ = client.login('bob', password)
    if typ != 'OK':
        raise SystemExit('FAIL: IMAP login failed')
    typ, _ = client.select('INBOX', readonly=False)
    if typ != 'OK':
        raise SystemExit('FAIL: IMAP writable SELECT INBOX failed')
    typ, data = client.search(None, 'ALL')
    if typ != 'OK' or not data or not data[0].split():
        raise SystemExit('FAIL: IMAP inbox is empty')
    matches = []
    for seq in data[0].split():
        # BODY.PEEK[] retrieves the full RFC message without implicitly adding
        # \\Seen. That lets this acceptance prove STORE changes persisted state.
        typ, fetched = client.fetch(seq, '(BODY.PEEK[])')
        if typ != 'OK':
            continue
        raw = next((item[1] for item in fetched if isinstance(item, tuple)), None)
        if raw is None:
            continue
        msg = BytesParser(policy=policy.default).parsebytes(raw)
        if (msg.get('Message-ID') or '').strip() == wanted_id:
            matches.append((seq, msg))
    if len(matches) != 1:
        raise SystemExit(f'FAIL: expected one IMAP message {wanted_id!r}, found {len(matches)}')
    seq, msg = matches[0]
    if (msg.get('Subject') or '').strip() != wanted_subject:
        raise SystemExit(f"FAIL: subject mismatch: {msg.get('Subject')!r}")
    if 'bob@station.test' not in (msg.get('To') or ''):
        raise SystemExit(f"FAIL: recipient mismatch: {msg.get('To')!r}")
    body = msg.get_body(preferencelist=('plain',))
    text = body.get_content() if body else msg.get_content()
    if body_token not in text:
        raise SystemExit('FAIL: body token missing from IMAP-retrieved message')

    typ, fetched = client.fetch(seq, '(FLAGS)')
    if typ != 'OK' or not fetched:
        raise SystemExit('FAIL: could not read IMAP flags before STORE')
    before_flags = b' '.join(
        item if isinstance(item, bytes) else item[0]
        for item in fetched
        if isinstance(item, bytes) or isinstance(item, tuple)
    )
    if b'\\Seen' in before_flags:
        raise SystemExit('FAIL: message was already \\Seen before explicit STORE')

    typ, _ = client.store(seq, '+FLAGS', '(\\Seen)')
    if typ != 'OK':
        raise SystemExit('FAIL: IMAP STORE \\Seen failed')
    typ, fetched = client.fetch(seq, '(FLAGS)')
    if typ != 'OK' or not fetched or b'\\Seen' not in b' '.join(
        item if isinstance(item, bytes) else item[0]
        for item in fetched
        if isinstance(item, bytes) or isinstance(item, tuple)
    ):
        raise SystemExit('FAIL: IMAP \\Seen flag did not persist')
    print('PASS: IMAP login as bob')
    print(f'PASS: IMAP retrieved {wanted_id} with BODY.PEEK[] without marking it Seen')
    print(f'PASS: Subject {wanted_subject}')
    print(f'PASS: body token {body_token}')
    print('PASS: message was not \\Seen before STORE')
    print('PASS: writable IMAP STORE persisted \\Seen on mbox INBOX')
finally:
    try:
        client.logout()
    except Exception:
        pass
PY

section "Phase 3A result"
printf 'PASS: standard SMTP submission plus authenticated writable IMAP are compatible with Dovecot 2.4 on the OceanMail station mail model\n'
printf 'SMTP endpoint: 127.0.0.1:%s\n' "$SMTP_PORT"
printf 'IMAP endpoint: 127.0.0.1:%s\n' "$IMAP_PORT"
printf 'IMAP user: bob\n'
printf 'Message-ID: %s\n' "$MESSAGE_ID"
printf 'Evidence directory: %s\n' "$RUN_DIR"
