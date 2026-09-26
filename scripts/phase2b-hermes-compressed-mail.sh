#!/usr/bin/env bash
# OceanMail Station 0.2 — Phase 2B HERMES uuxcomp/crmail acceptance
# Sends the Phase 2A-style RFC text message through HERMES's compressed UUCP
# mail boundary and compares queued radio payload bytes against the accepted
# Phase 2A standard-uux baseline (720 bytes).

set -euo pipefail

PHASE1_IMAGE="${PHASE1_IMAGE:-oceanmail-uucp-lab:phase1}"
PHASE2_IMAGE="${PHASE2_IMAGE:-oceanmail-mail-lab:phase2}"
PHASE2B_IMAGE="${PHASE2B_IMAGE:-oceanmail-mail-lab:phase2b}"
BASELINE_UUCP_BYTES="${BASELINE_UUCP_BYTES:-720}"
HERMES_NET_SHA="5c76adff754de49c0b934c7fd7bddf7619b0c3d6"
LIBCMIME_SHA="dd21eb096d162656e30243f60fc4bc35ad39ae6e"
MERCURY_TAG="v1.9.13"
MERCURY_SHA="4eac25e06a0c88996621bc74af5b7b2f0d353848"
MERCURY_DIR="${UPSTREAM_BASE:-$HOME/Projects/upstream}/mercury"
LOG_BASE="${LOG_BASE:-$HOME/oceanmail-logs}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RUN_DIR="$LOG_BASE/phase2b-hermes-mail-$RUN_ID"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
A_NAME="oceanmail-mail-a"
B_NAME="oceanmail-mail-b"
MESSAGE_ID="<phase2b-$RUN_ID@stationa.test>"
BODY_TOKEN="OceanMail-Phase2B-$RUN_ID-body-check"
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
    command -v "$cmd" >/dev/null 2>&1 || { printf 'ERROR: missing host command: %s\n' "$cmd" >&2; exit 2; }
done

if pgrep -x mercury >/dev/null 2>&1; then
    printf 'ERROR: Mercury already running; refusing to interfere\n' >&2
    exit 2
fi

section "Phase 2B environment"
printf 'UTC run id: %s\n' "$RUN_ID"
printf 'Message-ID: %s\n' "$MESSAGE_ID"
printf 'Envelope: alice@stationa.test -> bob@stationb.test\n'
printf 'Accepted Phase 2A UUCP baseline: %s bytes\n' "$BASELINE_UUCP_BYTES"
printf 'HERMES net: %s\n' "$HERMES_NET_SHA"
printf 'libcmime: %s\n' "$LIBCMIME_SHA"
printf 'Mercury: %s @ %s\n' "$MERCURY_TAG" "$MERCURY_SHA"
printf 'Evidence directory: %s\n' "$RUN_DIR"

section "Build Phase 1 / Phase 2 / Phase 2B images"
docker build --build-arg "HERMES_NET_SHA=$HERMES_NET_SHA" \
    -f "$REPO_ROOT/lab/phase1/Dockerfile" -t "$PHASE1_IMAGE" "$REPO_ROOT" \
    >"$RUN_DIR/phase1-image-build.log" 2>&1 || {
        tail -n 160 "$RUN_DIR/phase1-image-build.log" >&2; exit 2;
    }

docker build -f "$REPO_ROOT/lab/phase2/Dockerfile" -t "$PHASE2_IMAGE" "$REPO_ROOT" \
    >"$RUN_DIR/phase2-image-build.log" 2>&1 || {
        tail -n 160 "$RUN_DIR/phase2-image-build.log" >&2; exit 2;
    }
docker build \
    --build-arg "HERMES_NET_SHA=$HERMES_NET_SHA" \
    --build-arg "LIBCMIME_SHA=$LIBCMIME_SHA" \
    -f "$REPO_ROOT/lab/phase2b/Dockerfile" -t "$PHASE2B_IMAGE" "$REPO_ROOT" \
    >"$RUN_DIR/phase2b-image-build.log" 2>&1 || {
        printf 'ERROR: Phase 2B uuxcomp/crmail image build failed\n' >&2
        tail -n 220 "$RUN_DIR/phase2b-image-build.log" >&2
        exit 2
    }
printf 'PASS: HERMES uuxcomp/crmail image ready\n'

docker run --rm "$PHASE2B_IMAGE" /bin/bash -lc \
    'uuxcomp 2>&1 | head -n 3; crmail </dev/null >/dev/null 2>&1 || true; ldd /usr/local/bin/uuxcomp' \
    >"$RUN_DIR/uuxcomp-smoke.txt" 2>&1 || true
cat "$RUN_DIR/uuxcomp-smoke.txt"

section "Verify pinned Mercury"
cd "$MERCURY_DIR"
git fetch --tags --prune origin >"$RUN_DIR/mercury-fetch.log" 2>&1
TAG_SHA="$(git rev-parse "refs/tags/$MERCURY_TAG^{commit}")"
[[ "$TAG_SHA" == "$MERCURY_SHA" ]] || { printf 'ERROR: Mercury pin mismatch\n' >&2; exit 2; }
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
command-path /usr/local/bin /usr/sbin /usr/bin
commands crmail
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
command-path /usr/local/bin /usr/sbin /usr/bin
commands crmail
EOF

section "Start Phase 2B station containers"
docker run -d --name "$A_NAME" --hostname stationa --network host \
    -v "$RUN_DIR/a/etc-uucp:/etc/uucp:ro" -v "$RUN_DIR/a/evidence:/evidence" \
    "$PHASE2B_IMAGE" sleep infinity >/dev/null
docker run -d --name "$B_NAME" --hostname stationb --network host \
    -v "$RUN_DIR/b/etc-uucp:/etc/uucp:ro" -v "$RUN_DIR/b/evidence:/evidence" \
    "$PHASE2B_IMAGE" sleep infinity >/dev/null
IPC_A="$(docker exec "$A_NAME" readlink /proc/1/ns/ipc)"
IPC_B="$(docker exec "$B_NAME" readlink /proc/1/ns/ipc)"
printf 'Station A IPC: %s\nStation B IPC: %s\n' "$IPC_A" "$IPC_B"
[[ "$IPC_A" != "$IPC_B" ]] || { printf 'ERROR: IPC namespaces collided\n' >&2; exit 2; }

section "Configure Postfix with HERMES uuxcomp"
configure_postfix() {
    local container="$1" fqdn="$2" destination="$3"
    docker exec "$container" /usr/sbin/postconf -e 'compatibility_level = 3.6'
    docker exec "$container" /usr/sbin/postconf -e "myhostname = $fqdn"
    docker exec "$container" /usr/sbin/postconf -e "mydomain = $fqdn"
    docker exec "$container" /usr/sbin/postconf -e 'myorigin = $myhostname'
    docker exec "$container" /usr/sbin/postconf -e 'inet_interfaces = all'
    docker exec "$container" /usr/sbin/postconf -e 'inet_protocols = ipv4'
    docker exec "$container" /usr/sbin/postconf -e "mydestination = $destination, localhost"
    docker exec "$container" /usr/sbin/postconf -e 'relayhost ='
    docker exec "$container" /usr/sbin/postconf -e 'maillog_file_prefixes = /var, /dev/stdout, /evidence'
    docker exec "$container" /usr/sbin/postconf -e 'maillog_file = /evidence/postfix.log'
    docker exec "$container" /bin/bash -lc \
        "sed -ri 's/^(smtp[[:space:]]+inet[[:space:]].*)/# \\1/' /etc/postfix/master.cf"
    docker exec "$container" /bin/bash -lc "cat >>/etc/postfix/master.cf <<'EOF'
uucp      unix  -       n       n       -       -       pipe
  flags=F user=uucp argv=/usr/local/bin/uuxcomp -r -n -z -a\$sender - \$nexthop!crmail (\$recipient)
EOF"
}
configure_postfix "$A_NAME" stationa.test stationa.test
configure_postfix "$B_NAME" stationb.test stationb.test

docker exec "$A_NAME" /usr/sbin/postconf -e 'default_transport = uucp:stationb'
docker exec "$A_NAME" /usr/sbin/postconf -e 'defer_transports = uucp'
docker exec "$A_NAME" /usr/sbin/postfix check
docker exec "$B_NAME" /usr/sbin/postfix check
docker exec "$A_NAME" /usr/sbin/postfix start
docker exec "$B_NAME" /usr/sbin/postfix start
sleep 3
docker exec "$A_NAME" pgrep -x master >/dev/null || { printf 'ERROR: Postfix A not running\n' >&2; exit 2; }
docker exec "$B_NAME" pgrep -x master >/dev/null || { printf 'ERROR: Postfix B not running\n' >&2; exit 2; }
printf 'PASS: Postfix running with HERMES compressed UUCP pipe\n'

section "Start HERMES uucpd"
docker exec -d "$A_NAME" /bin/bash -lc \
    'exec /usr/local/bin/uucpd -a 127.0.0.1 -p 8300 -r vara -o none -c TESTA -d TESTB -f 2300 > /evidence/uucpd.log 2>&1'
docker exec -d "$B_NAME" /bin/bash -lc \
    'exec /usr/local/bin/uucpd -a 127.0.0.1 -p 8400 -r vara -o none -c TESTB -d TESTA -f 2300 > /evidence/uucpd.log 2>&1'
sleep 3
docker exec "$A_NAME" pgrep -x uucpd >/dev/null || { cat "$RUN_DIR/a/evidence/uucpd.log" >&2; exit 2; }
docker exec "$B_NAME" pgrep -x uucpd >/dev/null || { cat "$RUN_DIR/b/evidence/uucpd.log" >&2; exit 2; }
printf 'PASS: HERMES uucpd running\n'

section "Create Phase 2A-equivalent RFC text message"
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
SOURCE_BYTES="$(wc -c <"$MESSAGE_FILE" | tr -d ' ')"
SOURCE_SHA="$(sha256sum "$MESSAGE_FILE" | awk '{print $1}')"
printf 'Source RFC bytes: %s\n' "$SOURCE_BYTES"
printf 'Source RFC SHA-256: %s\n' "$SOURCE_SHA"
cp "$MESSAGE_FILE" "$RUN_DIR/a/evidence/source-message.eml"

section "State 1: local Postfix acceptance"
docker exec -i "$A_NAME" /usr/sbin/sendmail -i -f alice@stationa.test bob@stationb.test <"$MESSAGE_FILE"
sleep 3
docker exec "$A_NAME" /usr/sbin/postqueue -p | tee "$RUN_DIR/postfix-queue-held.txt"
grep -q 'bob@stationb.test' "$RUN_DIR/postfix-queue-held.txt" || { printf 'FAIL: Postfix acceptance missing\n' >&2; exit 1; }
if docker exec "$A_NAME" /usr/bin/uustat -a 2>/dev/null | grep -q stationb; then
    printf 'FAIL: UUCP job exists before Postfix release\n' >&2; exit 1
fi
printf 'PASS: Postfix accepted message; compressed UUCP handoff not yet started\n'

section "State 2: release into HERMES uuxcomp and measure compressed queue"
docker exec "$A_NAME" /usr/sbin/postconf -e 'defer_transports ='
docker exec "$A_NAME" /usr/sbin/postfix reload
docker exec "$A_NAME" /usr/sbin/postqueue -f

HANDOFF=0
for _ in $(seq 1 45); do
    docker exec "$A_NAME" /usr/bin/uustat -a >"$RUN_DIR/uucp-compressed-queue.txt" 2>&1 || true
    if grep -q 'crmail' "$RUN_DIR/uucp-compressed-queue.txt"; then HANDOFF=1; break; fi
    sleep 1
done
cat "$RUN_DIR/uucp-compressed-queue.txt"
[[ "$HANDOFF" -eq 1 ]] || {
    printf 'FAIL: uuxcomp did not create crmail UUCP job\n' >&2
    cat "$RUN_DIR/a/evidence/postfix.log" >&2 || true
    exit 1
}
COMPRESSED_BYTES="$(grep 'crmail' "$RUN_DIR/uucp-compressed-queue.txt" | grep -oE '\(sending [0-9]+ bytes\)' | grep -oE '[0-9]+' | tail -n 1)"
[[ -n "$COMPRESSED_BYTES" ]] || { printf 'FAIL: could not parse compressed UUCP bytes\n' >&2; exit 1; }
printf 'Compressed UUCP payload: %s bytes\n' "$COMPRESSED_BYTES"
printf 'Accepted Phase 2A standard-uux payload: %s bytes\n' "$BASELINE_UUCP_BYTES"
if (( COMPRESSED_BYTES < BASELINE_UUCP_BYTES )); then
    SAVED=$((BASELINE_UUCP_BYTES - COMPRESSED_BYTES))
    PCT="$(python3 - "$BASELINE_UUCP_BYTES" "$COMPRESSED_BYTES" <<'PY'
import sys
base, comp = map(int, sys.argv[1:])
print(f"{(base-comp)*100/base:.1f}")
PY
)"
    printf 'Queue payload reduction: %s bytes (%s%%)\n' "$SAVED" "$PCT"
else
    printf 'NOTE: compressed queue is not smaller for this small RFC message; semantic integration will still be tested.\n'
fi
[[ ! -s "$RUN_DIR/bob-mailbox.mbox" ]] || true

section "State 3: transfer compressed mail through HERMES/Mercury"
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
    printf '[Phase 2B] elapsed=%ss remote-mail=%s%s\n' "$elapsed" "$MAIL_STATE" "${LAST_EVENT:+ last-event=$LAST_EVENT}"
done
set +e
wait "$MASTER_PID"
UUCICO_RC=$?
set -e
printf 'uucico master exit code: %s\n' "$UUCICO_RC"
[[ "$UUCICO_RC" -eq 0 ]] || { tail -n 180 "$RUN_DIR/a/evidence/uucico-mail.log" >&2 || true; exit 1; }

section "State 4: verify crmail decompression and remote mailbox"
MAILBOX_READY=0
for _ in $(seq 1 45); do
    if docker exec "$B_NAME" test -s /var/mail/bob 2>/dev/null; then MAILBOX_READY=1; break; fi
    sleep 1
done
[[ "$MAILBOX_READY" -eq 1 ]] || {
    printf 'FAIL: Bob mailbox missing after compressed UUCP session\n' >&2
    tail -n 180 "$RUN_DIR/b/evidence/uucpd.log" >&2 || true
    cat "$RUN_DIR/b/evidence/postfix.log" >&2 || true
    exit 1
}
docker cp "$B_NAME:/var/mail/bob" "$RUN_DIR/bob-mailbox.mbox" >/dev/null
cp -f /tmp/mA.log "$RUN_DIR/mA.log" 2>/dev/null || true
cp -f /tmp/mB.log "$RUN_DIR/mB.log" 2>/dev/null || true

python3 - "$RUN_DIR/bob-mailbox.mbox" "$MESSAGE_ID" "$SUBJECT" "$BODY_TOKEN" <<'PY' | tee "$RUN_DIR/mailbox-verification.txt"
import mailbox, sys
path, wanted_id, wanted_subject, body_token = sys.argv[1:]
box = mailbox.mbox(path)
matches = [m for m in box if (m.get('Message-ID') or '').strip() == wanted_id]
if len(matches) != 1:
    raise SystemExit(f"FAIL: expected one Message-ID {wanted_id!r}, found {len(matches)}")
msg = matches[0]
subject = (msg.get('Subject') or '').strip()
recipient = (msg.get('To') or '').strip()
chat_version = (msg.get('Chat-Version') or '').strip()
payload = msg.get_payload(decode=True)
if payload is None:
    payload = str(msg.get_payload()).encode()
body = payload.decode(msg.get_content_charset() or 'utf-8', errors='replace')
if subject != wanted_subject: raise SystemExit(f"FAIL: subject mismatch {subject!r}")
if 'bob@stationb.test' not in recipient: raise SystemExit(f"FAIL: recipient mismatch {recipient!r}")
if body_token not in body: raise SystemExit('FAIL: body token missing after uuxcomp/crmail')
print(f"PASS: Message-ID {wanted_id}")
print(f"PASS: Subject {subject}")
print(f"PASS: To {recipient}")
print(f"PASS: body token {body_token}")
print(f"Observed Chat-Version header: {chat_version or '<absent>'}")
print(f"Mailbox message count: {len(box)}")
PY

section "Phase 2B result"
printf 'PASS: RFC text email delivered through HERMES uuxcomp/crmail compression boundary\n'
printf 'Source RFC bytes: %s\n' "$SOURCE_BYTES"
printf 'Standard Phase 2A UUCP payload: %s bytes\n' "$BASELINE_UUCP_BYTES"
printf 'HERMES compressed UUCP payload: %s bytes\n' "$COMPRESSED_BYTES"
if (( COMPRESSED_BYTES < BASELINE_UUCP_BYTES )); then
    printf 'Reduction: %s bytes (%s%%)\n' "$SAVED" "$PCT"
fi
printf 'Message-ID: %s\n' "$MESSAGE_ID"
printf 'Evidence directory: %s\n' "$RUN_DIR"
