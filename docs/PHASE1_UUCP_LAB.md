# OceanMail Station — Phase 1 UUCP Store-Forward Lab

Status: implementation plan following the accepted Mercury Phase 0 proof.

## Goal

Prove that two real UUCP stations can move a deterministic payload through HERMES `uucpd`/`uuport` and the already-proven two-instance Mercury link, without OceanMail mail semantics or GUI code.

```text
Station A UUCP spool
    -> uucico
    -> uuport
    -> uucpd A
    -> Mercury A
    -> ALSA simulated HF channel
    -> Mercury B
    -> uucpd B
    -> uucico
    -> Station B UUCP spool/public destination
```

## Why the two UUCP stations need isolation

The pinned HERMES `uucpd` implementation uses fixed System V shared-memory keys (`66664`, `66666`/`66667`, and `66668`/`66669`) for communication between `uucpd` and `uuport`.

Therefore two independent `uucpd` instances must not share the same Linux IPC namespace during the lab. Doing so would make the two station transports collide even though the Mercury TCP ports are different.

For local verification workstation, the initial test harness will use two lightweight Debian containers:

- `oceanmail-uucp-a`
- `oceanmail-uucp-b`

Each container receives its own default private IPC namespace. Both use host networking only for the laboratory so they can reach the two host Mercury TNCs at `127.0.0.1:8300/8301` and `127.0.0.1:8400/8401`.

This container choice is a **test-isolation mechanism**, not an OceanMail Station production architecture requirement.

## Pinned upstream input

HERMES networking repository:

`https://github.com/Rhizomatica/hermes-net`

Commit:

`5c76adff754de49c0b934c7fd7bddf7619b0c3d6`

Relevant programs:

- `uucpd`
- `uuport`

The lab uses the standard Debian Taylor UUCP package for `uucp`/`uucico`, while HERMES `uucpd` and `uuport` are built from the pinned source commit inside the test image.

## Station identities

UUCP system names:

- A: `stationa`
- B: `stationb`

Mercury/TNC callsigns used by the laboratory:

- A: `TESTA`
- B: `TESTB`

These are laboratory identities only and do not define OceanMail's future station/account addressing model.

## Acceptance criteria

Phase 1 passes only when all of the following are demonstrated:

1. two isolated UUCP stations are running with separate spools and IPC namespaces;
2. each station has one HERMES `uucpd` bound to the intended Mercury instance;
3. a deterministic payload is queued through UUCP on Station A rather than injected directly into Mercury;
4. `uucico` initiates a real session through `uuport`/`uucpd`;
5. Station B receives the payload through its UUCP path;
6. source and destination SHA-256 hashes match exactly;
7. UUCP queue/status and HERMES/Mercury logs are retained as evidence;
8. the test distinguishes local queue acceptance from completed remote arrival;
9. the same harness can subsequently exercise a reverse B -> A transfer;
10. cleanup removes test containers/processes without deleting retained evidence.

## Not included yet

Phase 1 deliberately does not add:

- Postfix or another MTA;
- `uuxcomp` mail compression/transcoding;
- RFC email semantics;
- OceanMail client/station API;
- account authentication;
- production container deployment;
- radio hardware.

Those belong after the generic UUCP store-forward path is proven.
