#!/usr/bin/env bash
# OceanMail Station 0.2 — Phase 2A RFC text email acceptance
# Proves a real Postfix -> UUCP/uux -> HERMES uucpd/uuport -> Mercury ->
# remote rmail -> Postfix local mailbox delivery path.

set -euo pipefail

PHASE1_IMAGE="${PHASE1_IMAGE:-oceanmail-uucp-lab:phase1}"
PHASE2_IMAGE="${PHASE2_IMAGE:-oceanmail-mail-lab:phase2}"
HERMES_NET_SHA="0fee4a53f54074ad6237b9fa1083a272cac89f60"
MERCURY_TAG=""
MERCURY_SHA="638193b9a9cc5ab15f272805af116e94b2fdf4c6"
MERCURY_DIR="${UPSTREAM_BASE:-$HOME/Projects/upstream}/mercury"
LOG_BASE="${LOG_BASE:-$HOME/oceanmail-logs}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$LOG_BASE/phase2a-rfc-mail-$RUN_ID"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A_NAME="oceanmail-mail-a"
B_NAME="oceanmail-mail-b"
MESSAGE_ID="<phase2a-$RUN_ID@stationa.test>"
BODY_TOKEN="OceanMail-Phase2A-$RUN_ID-body-check"
SUBJECT="OceanMail Phase 2A RFC mail proof"

mkdir -p "$RUN_DIR"

section() { printf '\n== %s ==\n' "$1"; }

resolve_cmd() {
    local cmd="$1" path
    path="$(command -v "$cmd" 2>/dev/null || true)"
    if [[ -n "$path" ]]; then printf '%s\n' "$path"; return 0; fi
    for path in "/usr/sbin/$cmd" "/sbin/$cmd"; do
        if [[ -x "$path" ]]; then printf '%s\n' "$path"; return 0; fi
    done
    return 1
}

stop_link() {
    pkill -9 -x mercury 2>/dev/null || true
    pkill -9 -f '/noisebridge' 2>/dev/null || true
    pkill -9 -f 'arecord -D plughw:' 2>/dev/null || true
    sleep 2
}

cleanup() {
    docker rm -f "$A_NAME" "$B_NAME" >/dev/null 2>&1 || true
    stop_link
}
trap cleanup EXIT

for cmd in docker git make python3 sha256sum pgrep pkill timeout; do
    command -v "$cmd" >/dev/null 2>&1 || {
        printf 'ERROR: missing host command: %s\n' "$cmd" >&2
        exit 2
    }
done

if pgrep -x mercury >/dev/null 2>&1; then
    printf 'ERROR: Mercury already running; refusing to interfere with another session\n' >&2
    pgrep -af mercury >&2 || true
    exit 2
fi

section "Phase 2A environment"
printf 'UTC run id: %s\n' "$RUN_ID"
printf 'Message-ID: %s\n' "$MESSAGE_ID"
printf 'Envelope: alice@stationa.test -> bob@stationb.test\n'
printf 'Mercury: %s @ %s\n' "$MERCURY_TAG" "$MERCURY_SHA"
printf 'HERMES net: %s\n' "$HERMES_NET_SHA"
printf 'Evidence directory: %s\n' "$RUN_DIR"

section "Build Phase 1 and Phase 2 station images"
if ! docker build \
    --build-arg "HERMES_NET_SHA=$HERMES_NET_SHA" \
    -f "$REPO_ROOT/lab/phase1/Dockerfile" \
    -t "$PHASE1_IMAGE" "$REPO_ROOT" >"$RUN_DIR/phase1-image-build.log" 2>&1; then
    printf 'ERROR: Phase 1 base image build failed\n' >&2
    tail -n 160 "$RUN_DIR/phase1-image-build.log" >&2
    exit 2
fi

if ! docker build \
    -f "$REPO_ROOT/lab/phase2/Dockerfile" \
    -t "$PHASE2_IMAGE" "$REPO_ROOT" >"$RUN_DIR/phase2-image-build.log" 2>&1; then
    printf 'ERROR: Phase 2 mail image build failed\n' >&2
    tail -n 160 "$RUN_DIR/phase2-image-build.log" >&2
    exit 2
fi
printf 'PASS: Phase 2 Postfix/UUCP station image ready\n'

section "Verify pinned Mercury"
cd "$MERCURY_DIR"
git fetch --tags --prune origin >"$RUN_DIR/mercury-fetch.log" 2>&1
TAG_SHA="$(git rev-parse "${MERCURY_TAG:+refs/tags/}${MERCURY_TAG:-$MERCURY_SHA}^{commit}")"
[[ "$TAG_SHA" == "$MERCURY_SHA" ]] || {
    printf 'ERROR: Mercury tag resolved to %s, expected %s\n' "$TAG_SHA" "$MERCURY_SHA" >&2
    exit 2
}
git switch --detach "$MERCURY_SHA" >/dev/null
make -j"$(nproc)" >"$RUN_DIR/mercury-build.log" 2>&1
make -C utils/loopsim >"$RUN_DIR/loopsim-build.log" 2>&1
printf 'PASS: pinned Mercury ready\n'

section "Load ALSA loopback and start Mercury channel"
MODPROBE="$(resolve_cmd modprobe || true)"
[[ -n "$MODPROBE" ]] || { printf 'ERROR: modprobe not found\n' >&2; exit 2; }
sudo "$MODPROBE" snd-aloop
sleep 1
CARD="$(awk '/Loopback/ {print $1; exit}' /proc/asound/cards 2>/dev/null || true)"
[[ -n "$CARD" ]] || { printf 'ERROR: ALSA Loopback card not found\n' >&2; exit 2; }
printf 'Loopback ALSA card: %s\n' "$CARD"
CARD="$CARD" MERCURY="./mercury" ./utils/loopsim/run_loopsim.sh 0.0 0.0 >"$RUN_DIR/loopsim-start.log" 2>&1
cat "$RUN_DIR/loopsim-start.log"
[[ "$(pgrep -x mercury | wc -l)" -eq 2 ]] || { printf 'ERROR: expected two Mercury processes\n' >&2; exit 2; }

section "Prepare isolated UUCP station configuration"
for side in a b; do
    mkdir -p "$RUN_DIR/$side/etc-uucp" "$RUN_DIR/$side/evidence"
    chmod 0777 "$RUN_DIR/$side/evidence"
done

cat >"$RUN_DIR/a/etc-uucp/config" <<'EOF'
nodename stationa
pubdir /var/spool/uucppublic
EOF
cat >"$RUN_DIR/b/etc-uucp/config" <<'EOF'
nodename stationb
pubdir /var/spool/uucppublic
EOF

cat >"$RUN_DIR/a/etc-uucp/port" <<'EOF'
port HFP
type pipe
command /usr/local/bin/uuport -e /evidence/uuport.log
EOF
cp "$RUN_DIR/a/etc-uucp/port" "$RUN_DIR/b/etc-uucp/port"

cat >"$RUN_DIR/a/etc-uucp/sys" <<'EOF'
protocol y
protocol-parameter y packet-size 512
protocol-parameter y timeout 540
chat-timeout 200
system stationb
call-login *
call-password *
time any
port HFP
chat "" \r
local-send /
remote-send ~
local-receive ~
remote-receive ~
command-path /usr/sbin /usr/bin
commands rmail
EOF

cat >"$RUN_DIR/b/etc-uucp/sys" <<'EOF'
protocol y
protocol-parameter y packet-size 512
protocol-parameter y timeout 540
chat-timeout 200
system stationa
call-login *
call-password *
time any
port HFP
chat "" \r
local-send /
remote-send ~
local-receive ~
remote-receive ~
command-path /usr/sbin /usr/bin
commands rmail
EOF

section "Start station containers"
docker run -d --name "$A_NAME" --hostname stationa --network host \
    -v "$RUN_DIR/a/etc-uucp:/etc/uucp:ro" \
    -v "$RUN_DIR/a/evidence:/evidence" \
    "$PHASE2_IMAGE" sleep infinity >/dev/null

docker run -d --name "$B_NAME" --hostname stationb --network host \
    -v "$RUN_DIR/b/etc-uucp:/etc/uucp:ro" \
    -v "$RUN_DIR/b/evidence:/evidence" \
    "$PHASE2_IMAGE" sleep infinity >/dev/null

IPC_A="$(docker exec "$A_NAME" readlink /proc/1/ns/ipc)"
IPC_B="$(docker exec "$B_NAME" readlink /proc/1/ns/ipc)"
printf 'Station A IPC: %s\nStation B IPC: %s\n' "$IPC_A" "$IPC_B"
[[ "$IPC_A" != "$IPC_B" ]] || { printf 'ERROR: station IPC namespaces collided\n' >&2; exit 2; }

section "Configure Postfix mail semantics"
configure_postfix() {
    local container="$1" fqdn="$2" destination="$3" listen_ip="$4"
    docker exec "$container" /usr/sbin/postconf -e "compatibility_level = 3.6"
    docker exec "$container" /usr/sbin/postconf -e "myhostname = $fqdn"
    docker exec "$container" /usr/sbin/postconf -e "mydomain = $fqdn"
    docker exec "$container" /usr/sbin/postconf -e 'myorigin = $myhostname'
    docker exec "$container" /usr/sbin/postconf -e "inet_interfaces = $listen_ip"
    docker exec "$container" /usr/sbin/postconf -e 'inet_protocols = ipv4'
    docker exec "$container" /usr/sbin/postconf -e "mydestination = $destination, localhost"
    docker exec "$container" /usr/sbin/postconf -e 'relayhost ='
    docker exec "$container" /usr/sbin/postconf -e 'maillog_file = /evidence/postfix.log'
    docker exec "$container" /bin/bash -lc "grep -q '^uucp[[:space:]]' /etc/postfix/master.cf || cat >>/etc/postfix/master.cf <<'EOF'
uucp      unix  -       n       n       -       -       pipe
  flags=F user=uucp argv=/usr/bin/uux -r -n -z -a\$sender - \$nexthop!rmail (\$recipient)
EOF"
}

configure_postfix "$A_NAME" stationa.test stationa.test 127.0.0.2
configure_postfix "$B_NAME" stationb.test stationb.test 127.0.0.3

docker exec "$A_NAME" /usr/sbin/postconf -e 'default_transport = uucp:stationb'
docker exec "$A_NAME" /usr/sbin/postconf -e 'defer_transports = uucp'

docker exec "$A_NAME" /usr/sbin/postfix check
docker exec "$B_NAME" /usr/sbin/postfix check
docker exec "$A_NAME" /usr/sbin/postfix start
docker exec "$B_NAME" /usr/sbin/postfix start
sleep 3

docker exec "$A_NAME" pgrep -x master >/dev/null || { printf 'ERROR: Postfix master not running on station A\n' >&2; exit 2; }
docker exec "$B_NAME" pgrep -x master >/dev/null || { printf 'ERROR: Postfix master not running on station B\n' >&2; exit 2; }
printf 'PASS: Postfix running on both stations\n'

section "Start HERMES uucpd against Mercury"
docker exec -d "$A_NAME" /bin/bash -lc \
    'exec /usr/local/bin/uucpd -a 127.0.0.1 -p 8300 -r vara -o none -c TESTA -d TESTB -f 2300 > /evidence/uucpd.log 2>&1'
docker exec -d "$B_NAME" /bin/bash -lc \
    'exec /usr/local/bin/uucpd -a 127.0.0.1 -p 8400 -r vara -o none -c TESTB -d TESTA -f 2300 > /evidence/uucpd.log 2>&1'
sleep 3

docker exec "$A_NAME" pgrep -x uucpd >/dev/null || { printf 'ERROR: station A uucpd not running\n' >&2; cat "$RUN_DIR/a/evidence/uucpd.log" >&2 || true; exit 2; }
docker exec "$B_NAME" pgrep -x uucpd >/dev/null || { printf 'ERROR: station B uucpd not running\n' >&2; cat "$RUN_DIR/b/evidence/uucpd.log" >&2 || true; exit 2; }
printf 'PASS: HERMES uucpd running on both stations\n'

section "Create deterministic RFC text message"
MESSAGE_FILE="$RUN_DIR/source-message.eml"
cat >"$MESSAGE_FILE" <<EOF
From: Alice <alice@stationa.test>
To: Bob <bob@stationb.test>
Date: $(date -Ru)
Message-ID: $MESSAGE_ID
Subject: $SUBJECT
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8
Content-Transfer-Encoding: 7bit

$BODY_TOKEN
This message is a deterministic OceanMail Phase 2A text-email acceptance payload.
It was accepted by Postfix, queued into UUCP, transferred by HERMES/Mercury,
and delivered through remote rmail into the Station B local mailbox.
EOF
SOURCE_SHA="$(sha256sum "$MESSAGE_FILE" | awk '{print $1}')"
printf 'Source RFC message SHA-256: %s\n' "$SOURCE_SHA"
cp "$MESSAGE_FILE" "$RUN_DIR/a/evidence/source-message.eml"

section "State 1: local Postfix acceptance"
docker exec -i "$A_NAME" /usr/sbin/sendmail -i -f alice@stationa.test bob@stationb.test <"$MESSAGE_FILE"
sleep 3
docker exec "$A_NAME" /usr/sbin/postqueue -p | tee "$RUN_DIR/postfix-queue-held.txt"
if ! grep -q 'bob@stationb.test' "$RUN_DIR/postfix-queue-held.txt"; then
    printf 'FAIL: message was not visible in held Postfix queue\n' >&2
    cat "$RUN_DIR/a/evidence/postfix.log" >&2 || true
    exit 1
fi
if docker exec "$A_NAME" /usr/bin/uustat -a 2>/dev/null | grep -q stationb; then
    printf 'FAIL: UUCP job exists before Postfix transport release\n' >&2
    exit 1
fi
printf 'PASS: Postfix accepted message locally; UUCP handoff has not occurred\n'

section "State 2: release Postfix message into UUCP"
docker exec "$A_NAME" /usr/sbin/postconf -e 'defer_transports ='
docker exec "$A_NAME" /usr/sbin/postfix reload
docker exec "$A_NAME" /usr/sbin/postqueue -f

HANDOFF=0
for _ in $(seq 1 30); do
    docker exec "$A_NAME" /usr/bin/uustat -a >"$RUN_DIR/uucp-queue-before-radio.txt" 2>&1 || true
    if grep -q stationb "$RUN_DIR/uucp-queue-before-radio.txt"; then
        HANDOFF=1
        break
    fi
    sleep 1
done
cat "$RUN_DIR/uucp-queue-before-radio.txt"
if [[ "$HANDOFF" -ne 1 ]]; then
    printf 'FAIL: Postfix did not hand the message to UUCP\n' >&2
    docker exec "$A_NAME" /usr/sbin/postqueue -p >&2 || true
    cat "$RUN_DIR/a/evidence/postfix.log" >&2 || true
    exit 1
fi
if docker exec "$B_NAME" test -s /var/mail/bob; then
    printf 'FAIL: remote mailbox exists before UUCP radio session\n' >&2
    exit 1
fi
printf 'PASS: message moved from Postfix responsibility into durable UUCP queue\n'

section "State 3: run UUCP mail session through HERMES/Mercury"
set +e
timeout 900 docker exec "$A_NAME" /usr/sbin/uucico -D -S stationb >"$RUN_DIR/a/evidence/uucico-mail.log" 2>&1 &
MASTER_PID=$!
set -e
elapsed=0
while kill -0 "$MASTER_PID" 2>/dev/null; do
    sleep 15
    elapsed=$((elapsed + 15))
    MAIL_STATE="pending"
    if docker exec "$B_NAME" test -s /var/mail/bob 2>/dev/null; then MAIL_STATE="mailbox-present"; fi
    LAST_EVENT="$(tail -n 80 "$RUN_DIR/a/evidence/uucpd.log" 2>/dev/null | grep -E 'CONNECTING|CONNECTED|BUFFER:|TNC:' | tail -n 1 || true)"
    printf '[Phase 2A] elapsed=%ss remote-mail=%s%s\n' "$elapsed" "$MAIL_STATE" "${LAST_EVENT:+ last-event=$LAST_EVENT}"
done
set +e
wait "$MASTER_PID"
UUCICO_RC=$?
set -e
printf 'uucico master exit code: %s\n' "$UUCICO_RC"
[[ "$UUCICO_RC" -eq 0 ]] || {
    printf 'FAIL: UUCP mail session did not complete\n' >&2
    tail -n 160 "$RUN_DIR/a/evidence/uucico-mail.log" >&2 || true
    exit 1
}

section "State 4: verify remote rmail/Postfix mailbox delivery"
MAILBOX_READY=0
for _ in $(seq 1 45); do
    if docker exec "$B_NAME" test -s /var/mail/bob 2>/dev/null; then
        MAILBOX_READY=1
        break
    fi
    sleep 1
done
if [[ "$MAILBOX_READY" -ne 1 ]]; then
    printf 'FAIL: Bob mailbox did not appear after completed UUCP session\n' >&2
    printf '%s\n' '--- Station B uucpd ---' >&2
    tail -n 160 "$RUN_DIR/b/evidence/uucpd.log" >&2 || true
    printf '%s\n' '--- Station B Postfix ---' >&2
    cat "$RUN_DIR/b/evidence/postfix.log" >&2 || true
    docker exec "$B_NAME" /usr/bin/uustat -a >&2 || true
    exit 1
fi

docker cp "$B_NAME:/var/mail/bob" "$RUN_DIR/bob-mailbox.mbox" >/dev/null

docker exec "$A_NAME" /usr/sbin/postqueue -p >"$RUN_DIR/postfix-queue-final-a.txt" 2>&1 || true
docker exec "$A_NAME" /usr/bin/uustat -a >"$RUN_DIR/uucp-queue-final-a.txt" 2>&1 || true
docker exec "$B_NAME" /usr/bin/uustat -a >"$RUN_DIR/uucp-queue-final-b.txt" 2>&1 || true
cp -f /tmp/mA.log "$RUN_DIR/mA.log" 2>/dev/null || true
cp -f /tmp/mB.log "$RUN_DIR/mB.log" 2>/dev/null || true

python3 - "$RUN_DIR/bob-mailbox.mbox" "$MESSAGE_ID" "$SUBJECT" "$BODY_TOKEN" <<'PY' | tee "$RUN_DIR/mailbox-verification.txt"
import mailbox
import sys

path, wanted_id, wanted_subject, body_token = sys.argv[1:]
box = mailbox.mbox(path)
matches = [m for m in box if (m.get('Message-ID') or '').strip() == wanted_id]
if len(matches) != 1:
    raise SystemExit(f"FAIL: expected exactly one Message-ID {wanted_id!r}, found {len(matches)}")
msg = matches[0]
subject = (msg.get('Subject') or '').strip()
recipient = (msg.get('To') or '').strip()
payload = msg.get_payload(decode=True)
if payload is None:
    payload = str(msg.get_payload()).encode()
body = payload.decode(msg.get_content_charset() or 'utf-8', errors='replace')
if subject != wanted_subject:
    raise SystemExit(f"FAIL: subject mismatch: {subject!r}")
if 'bob@stationb.test' not in recipient:
    raise SystemExit(f"FAIL: recipient mismatch: {recipient!r}")
if body_token not in body:
    raise SystemExit('FAIL: deterministic body token missing')
print(f"PASS: Message-ID {wanted_id}")
print(f"PASS: Subject {subject}")
print(f"PASS: To {recipient}")
print(f"PASS: body token {body_token}")
print(f"Mailbox message count: {len(box)}")
PY

section "Phase 2A result"
printf 'PASS: RFC text email delivered Postfix -> UUCP -> HERMES/Mercury -> rmail -> Postfix mailbox\n'
printf 'Message-ID: %s\n' "$MESSAGE_ID"
printf 'Subject: %s\n' "$SUBJECT"
printf 'Source message SHA-256 (pre-MTA): %s\n' "$SOURCE_SHA"
printf 'Local acceptance evidence: %s\n' "$RUN_DIR/postfix-queue-held.txt"
printf 'UUCP handoff evidence: %s\n' "$RUN_DIR/uucp-queue-before-radio.txt"
printf 'Remote mailbox evidence: %s\n' "$RUN_DIR/bob-mailbox.mbox"
printf 'Evidence directory: %s\n' "$RUN_DIR"
