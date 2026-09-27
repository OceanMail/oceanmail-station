# Phase 4I — Returned Receipt Evidence

Status: **Accepted no-radio laboratory evidence**

Accepted branch head: `563bf08ea2d06f478db5f559c499d88c70c15eca`

Accepted self-hosted workflow run: `34517583360`

Environment: Linux container acceptance; private host inventory omitted.

Evidence artifact:

- artifact ID: `10168742993`
- artifact name: `phase4i-linux-evidence-34517583360`
- archive size: 51,917 bytes
- archive SHA-256: `5a6a4032a90c2b1a77872b8fcd7038c46c116eefe0174238e4560217a61f0147`
- retention at acceptance: through 2026-09-24

## What Phase 4I proves

Phase 4I removes the sender-side laboratory shortcut used in Phase 4H. The origin Station does not create returned-receipt state merely because the test harness can inspect Station B's mailbox. Instead:

1. Station A accepts an RFC message into Postfix and records its exact Message-ID to local Postfix observation.
2. The existing Phase 4E boundary maps that observation to one exact Taylor UUCP job.
3. The message traverses the simulated constrained UUCP/HERMES/Mercury path A -> B.
4. Station B's actual mailbox is checked for the exact Message-ID, Subject, recipient, and deterministic body token.
5. Only after that far-side proof does Station B create a compact receipt artifact.
6. That artifact is queued as its own exact Taylor UUCP job B -> A.
7. The receipt traverses the same constrained path back to Station A.
8. Station A requires the returned bytes to match the original receipt SHA-256 before validation/correlation.
9. Only returned-artifact arrival and validation creates `returned_remote_receipt_observed`.
10. The resulting correlation survives Station restart unchanged.

This is stronger than local queue departure, `uucico` success, or local Mercury progress. It is still laboratory transport evidence, not production peer authentication.

## Accepted evidence

- original Postfix queue ID: `56380820A24`
- original Station observation: `3f789e0a-77d5-4c92-8e7d-78f415ddc69e:postfix:56380820A24:1789066855`
- original Taylor job: `stationb/stationb.NRyMmZBAAAI0`
- original attempt ID: `322336a8-b453-48aa-954e-bc4725f16e29`
- original Message-ID: `<phase4i-20260910T190005Z@stationa.test>`
- compressed original UUCP payload: 528 bytes versus accepted Phase 2A baseline 720 bytes (192-byte / 26.7% queue-payload reduction)
- returned receipt Taylor job: `stationa/stationa.NR2qTGhAAAQg`
- returned receipt bytes: 264
- returned receipt SHA-256: `81516f76ed78ec0872f74333e2c5a7539a8061c878f9093a6262bffae6be6755`
- reciprocal B -> A `uucico` exit code: 0
- trust state: `lab_peer_transport_unverified`

The returned evidence record resolved back to original Taylor job `stationb.NRyMmZBAAAI0`, not the later receipt-return job.

## Reciprocal-session lifecycle findings

Phase 4I exposed two upstream integration boundaries that were not visible in one-way tests.

### Mercury lifecycle

Taylor process/job retirement is not the same as Mercury ARQ-session retirement. A reciprocal call attempted while the prior Mercury session remained connected failed even though the original `uucico` process and Taylor job had retired.

The canonical acceptance now requires both Mercury peers' latest `conn:` transition to be `LISTENING` before reciprocal work begins.

Accepted final transitions were followed by both peers reaching LISTENING before the HERMES gate was evaluated.

### HERMES lifecycle and retired TCP data

Pinned HERMES can receive more than one `TNC: DISCONNECTED` boundary around teardown and performs asynchronous post-session work including terminating old `uucico`/`uuport` processes and resetting its shared buffers. An earlier reciprocal call was killed by a later cleanup cycle.

After that race was gated, Taylor exposed a second problem: its new master received `OOOOOO`, the previous UUCP conversation's end sequence, where the new slave greeting `Shere` should have appeared. The old data had survived in the persistent VARA/Mercury TCP data stream across sessions.

OceanMail therefore carries a narrow, tracked laboratory patch against exact HERMES commit `5c76adff754de49c0b934c7fd7bddf7619b0c3d6`. The patch:

- discards a blocking data read if the control path has already transitioned to disconnected;
- drains retired VARA/Mercury TCP tail data at the old-session cleanup boundary;
- emits `Connection cleanup complete.` only after the final buffer reset and `clean_buffers=false`.

The Phase 4I HERMES gate requires every observed disconnect to be matched by this explicit completion marker on both peers and requires no live non-zombie `uucico` or `uuport` process before the reciprocal call proceeds.

Accepted run `34517583360` recorded:

- Station A: 2 disconnects / 2 cleanup-complete markers;
- Station B: 2 disconnects / 2 cleanup-complete markers;
- final boundary on both peers: `Connection cleanup complete.`;
- no live `uucico`/`uuport` bridge process at release.

The exact HERMES pin plus tracked patch was independently compiled as an early workflow preflight before Mercury/UUCP acceptance.

### Rejected lifecycle shortcuts and regression guards

The final Phase 4I boundary was reached by disproving several tempting but incorrect shortcuts. Preserve these rejections when changing the harness or attempting to upstream the HERMES fix:

- **arbitrary sleeps are not lifecycle evidence.** The former `sleep 2` was removed after a reciprocal call demonstrated that cleanup can outlive it;
- **Taylor job retirement or absence of a `uucico` process is insufficient.** The modem/bridge can still be retiring the previous session after Taylor considers the job complete;
- **Mercury `LISTENING` alone is insufficient.** A later HERMES cleanup cycle can still terminate a newly started reciprocal `uucico`/`uuport` session;
- **the existence of any historical HERMES cleanup marker is insufficient.** Every observed disconnect must be matched by a later completion boundary for that retired session;
- **`Connection closed. Cleaning internal buffers.` is not the final cleanup boundary.** In the pinned upstream code it is emitted before the last buffer reset/cleanup-state clear. OceanMail's explicit `Connection cleanup complete.` marker is intentionally later;
- **continuous data-socket draining while disconnected was rejected.** It can race with a legitimate first byte belonging to the next session;
- **draining at the next new-session `CONNECTED` boundary was rejected.** The remote peer may already be able to send new-session UUCP data before the local control thread processes that notification, so this can consume valid new data;
- the accepted stale-tail drain point is the **retired old-session cleanup boundary**, after Mercury has provided the old session an opportunity to flush receive data to the old TCP stream and before a later reciprocal session is released.

The HERMES upstream/integration follow-up is tracked in upstream lifecycle work. As of 2026-09-11, current `Rhizomatica/hermes-net/main` still lacks the OceanMail stale-tail handling and explicit cleanup-complete boundary, so the local tracked patch must not be silently removed until an upstream replacement is accepted and the full reciprocal acceptance is rerun.

## Portable no-radio execution

The Linux acceptance no longer depends on a workstation-specific ALSA `snd-aloop` setup. The acceptance harness uses a disposable Debian container containing exact pinned Mercury `v1.9.13` / `4eac25e06a0c88996621bc74af5b7b2f0d353848` and a user-space PulseAudio null-sink loop.

Before the mail acceptance, the workflow independently transfers 1,024 deterministic bytes between the two Mercury peers and requires an exact match. The Station/HERMES test then uses the same host-network TNC ports expected by the canonical Phase 2B path.

The CI adapter changes this lab audio plumbing only; Phase 4I acceptance semantics live in the canonical Phase 4I harness.

## Trust boundary

`returned_remote_receipt_observed` means the origin Station received a structurally valid laboratory receipt artifact over the constrained return path and correlated it to the original local message/job.

It does **not** mean:

- the remote peer was cryptographically authenticated;
- the receipt was digitally signed;
- a human read the message;
- production storage security is ready.

The Phase 4I recorder fails closed on trust state and accepts only `lab_peer_transport_unverified`.

Production receipt signing/authentication remains future work.

## Storage and API boundary

No production storage-security flag changes in Phase 4I. Laboratory SQLite and evidence files remain non-production state.

The Station API remains loopback-only. Authentication/authorization and account-scoped access are separate follow-on work.

## Physical-radio boundary

Phase 5 physical-radio work was not started by this acceptance. The no-radio STORE / TRANSPORT evidence chain is now complete through returned receipt correlation, but physical-radio acceptance remains a separate hardware-dependent phase.
