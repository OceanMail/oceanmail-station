# OceanMail Station — Current Status

Updated: 2026-09-19

This is the authoritative live implementation-status document for `OceanMail/oceanmail-station`.

Organization-level OceanMail architecture, cross-repository decisions, terminology, repository inventory, and workstream state are authoritative in [`OceanMail/oceanmail-project`](https://github.com/OceanMail/oceanmail-project). For substantial Station work, also read root `AGENTS.md`, `docs/STATION_ARCHITECTURE.md`, the applicable security/upstream/contract documents, current `main`, and open PRs/issues.

## Current architecture

OceanMail 0.2 is upstream-first around standard SMTP/IMAP above a constrained HERMES/Mercury/Taylor UUCP transport path.

Proven laboratory path:

```text
standard mail client
    -> SMTP / Postfix
    -> HERMES uuxcomp
    -> Taylor UUCP
    -> HERMES uuport/uucpd
    -> Mercury
    -> simulated constrained channel
    -> Mercury + HERMES + UUCP
    -> crmail / Postfix
    -> Dovecot / authenticated IMAP
    -> standard mail client
```

The Station is a persistent headless service that observes/correlates authoritative Postfix/UUCP stores, owns OceanMail policy/evidence metadata, and does not duplicate payload queues already authoritatively maintained by Postfix, Taylor UUCP, Dovecot/mailbox storage, or upstream transport components.

Current internal architecture distinguishes:

- **STORE / TRANSPORT Plane** — durable holding/movement of accepted traffic and measurable transport/receipt evidence.
- **GRID / CONTROL Plane** — OceanMail-specific peer/Grid observations, relay/gateway policy, topology, telemetry/reputation inputs, OChat Grid behavior, maps/network state, and future routing/selection intelligence.

Exact accepted upstream pins and integration-delta policy are authoritative in [`UPSTREAM_BASELINE.md`](UPSTREAM_BASELINE.md). Required downstream changes must remain explicit, narrow, auditable, provenance-tracked, and license-preserving.

## Proven phase state

- Phase 0 — Mercury loopsim: **COMPLETE**.
- Phase 1 — Taylor UUCP / HERMES durable store-forward: **COMPLETE**.
- Phase 2 — RFC mail + HERMES compression path: **COMPLETE**.
- Phase 3 — standard SMTP/IMAP client path: **COMPLETE**, including the merged Debian trixie/Dovecot 2.4 compatibility and writable-IMAP proof from PR #25 (`51869c31e8f80aa32d0abad1747c32ab07e0fd5d`). The accepted Phase 3A path proves authenticated writable IMAP and an explicit `\Seen` state transition after non-mutating `BODY.PEEK[]` retrieval.
- Phase 4A–4H — persistent Station, evidence correlation, transport progress, and far-side mailbox evidence: **COMPLETE**.
- Phase 4I — returned receipt evidence across the reciprocal constrained path: **COMPLETE**.

Canonical Phase 4I evidence and exact accepted CI/artifact details remain in [`PHASE4I_RETURNED_RECEIPT_EVIDENCE.md`](PHASE4I_RETURNED_RECEIPT_EVIDENCE.md).

`returned_remote_receipt_observed` means the origin Station received, structurally validated, and correlated the returned laboratory receipt to the original message/job. Accepted trust remains exactly `lab_peer_transport_unverified`; this is not production cryptographic peer authentication and is not human-read proof.

A reconciliation rerun on PR #25 exposed one nondeterministic Phase 4I laboratory readiness failure (`original-message attempt snapshot missing`) that passed on immediate rerun with the exact same source/head. Issue #42 is now closed by merged PR #47 (`65d75cb96b0b1247f598c49a60a11b8cba68e5b8`): an explicit bounded durable state/evidence gate, including a final fresh read after caller completion, replaces the readiness race. Current-base Phase 4I run `35559385475` passed on source `b001a11d085baa3b0bc3abe419f90f99034bf136`; the exact snapshot, far-side mailbox proof, session retirement, negative pre-return assertion, returned receipt correlation, and restart durability all passed. The trust state remains `lab_peer_transport_unverified`; no physical-radio evidence is claimed.

Physical-radio Phase 5 remains held until explicitly authorized with a suitable hardware/test scope.

## Available/account contract

PR #26 merged on 2026-09-11 (merge commit `7a132b6ea4967c600dc8c673718d00b09c3ad42b`). The logical Available/account-authorization/retrieval-plan foundation is now accepted Station documentation.

Current boundaries include:

- Available is private recipient pre-transfer metadata, not an IMAP folder or already-local content;
- authenticate the principal and enforce explicit principal-to-account grants before private account state is disclosed;
- account IDs, message IDs, email strings, loopback access, device trust, and Captain/Admin authority are not substitutes for account authorization;
- when no recipient Station exists, the hosted Server/service must provide equivalent client authentication, account-grant, durable-plan, and retrieval/synchronization ownership;
- holder-side private manifest metadata must be recipient/account-authorized or equivalently end-to-end confidential before disclosure;
- native boat-to-boat availability must not require central Server availability.

The contract is architecture/documentation. It does not itself implement HTTP endpoints, authentication, holder cryptography, protected persistence, accounting, scheduling, or payload retrieval.

## Current API/security boundary

Phase 4J implements the bounded first slice of issue #23: runtime-provisioned
laboratory bearer credentials, immutable principal/account/device context,
explicit account permissions and protected loopback context endpoints. See
[`PHASE4J_AUTH_FOUNDATION.md`](PHASE4J_AUTH_FOUNDATION.md) for the exact contract,
runtime provisioning, acceptance tests, and remaining gates. It is not completion
of #23 and does not implement #24's Available/retrieval/accounting APIs.

The legacy evidence API remains unauthenticated loopback laboratory diagnostics;
`api_authentication` remains false for that API as a whole. Never use these routes
as a bypass for private account data or proxy them onto a LAN.

The current Station API remains conservative and loopback-oriented while authentication/authorization work is incomplete.

Key evidence/status endpoints remain available for the laboratory implementation, but LAN exposure must not precede accepted authentication/authorization.

Current production-storage gates remain unsatisfied:

- application storage encryption is not accepted as production-ready;
- per-user key separation is not accepted as production-ready;
- host/offline volume encryption remains an independent deployment/security requirement.

API authentication must not be used to bypass those storage/key-separation gates. Captain/Station administration does not inherently grant another user's private mailbox or Available data access.

## Current mail, relay, and gateway policy

- User-originated transport classes are **Emergency** and **Ordinary** only.
- There is no ordinary sender-selectable Priority transport class.
- `Important` is conventional message metadata only; it must not alter RF/Station/relay precedence, gateway/path choice, credits/quota treatment, or automatic Available ordering.
- Recipient Available ordering is retrieval intent within ordinary local-account work; Station remains authoritative for actual scheduling, fairness, age protection, and Emergency preemption.

Relay and gateway policy are separate:

- there is no relay `Off` mode while a Station is running;
- **Eager** relays advertise/volunteer broadly subject to resource controls;
- **Reluctant** relays remain non-advertising/fallback and may intervene for Emergency or stranded/stalled ordinary traffic under accepted policy;
- **Full Gateway** normally offers ordinary third-party gateway service;
- **Minimal Gateway** normally does not, but may serve accepted fallback policy for stranded/stalled ordinary traffic;
- **Gateway Off** offers no ordinary third-party gateway service;
- Emergency remains eligible in all gateway modes when technically, legally, and operationally permitted.

Implementation of the full scheduler/Grid/gateway behavior remains future work; these are current semantics, not a claim that every behavior is already coded.

## Current upstream integration debt

Phase 4I proved a reciprocal-session defect in the pinned HERMES VARA/Mercury data bridge. OceanMail carries a narrow tracked laboratory patch because retired UUCP tail bytes could otherwise leak into a later reciprocal session and produce `OOOOOO` where Taylor expected the new `Shere` greeting.

`Rhizomatica/hermes-net/main` was rechecked on 2026-09-11 and still does not contain the OceanMail stale-tail guard/drain or explicit cleanup-complete boundary. Upstream follow-up is tracked in issue #35. Until an upstream fix is deliberately accepted and the pin is advanced/retested, preserve the explicit patch/provenance and Phase 4I lifecycle gates.

## Immediate next work

Issue #22 first slice: the library now contains a configurable, in-memory lease
controller with deterministic tests. Lease duration and normal control allowance
are independent explicit inputs, with no fixed ten-minute/four-minute or 40%
rule. See [`LEASE_CONTROLLER.md`](LEASE_CONTROLLER.md) for its caller contract and
remaining integration gates. It is not yet used by daemon transport dispatch;
full scheduler, persistent fairness/accounting and channel validation remain open.

1. issue #23 — authenticated, permission-scoped Station API and stable account/user/device context;
2. issue #24 — account-scoped Available manifest, retrieval intent, and working-ledger API after #23;
3. issue #22 — implement [ADR-008](https://github.com/OceanMail/oceanmail-project/blob/main/docs/decisions/ADR-008-four-band-scheduling-and-channel-use.md): Bands 0–3, Band 1 cap/necessary route exception, remaining-time Band 2 with local/relay fairness, unreserved shared broadcasts, and single-radio channel/check-in behavior; design accepted, runtime implementation outstanding;
4. issue #35 — upstream HERMES reciprocal-session stale-TCP-tail report/fix while retaining the accepted local laboratory delta until upstream resolution is proven;
5. production storage encryption and per-user key separation;
6. scheduler/resource accounting, Grid/control state, relay/gateway execution, and API expansion as separately bounded phases;
7. physical-radio validation only after explicit Phase 5 authorization.

## Workflow

Organization-wide agent/contributor workflow is authoritative in `OceanMail/oceanmail-project/AGENTS.md`. Root `AGENTS.md` in this repository contains only Station-specific implementation constraints.

Keep implementation evidence separated into STATIC / UNIT, INTEGRATION, and LIVE / PRODUCT. Do not claim live RF/product verification from no-radio labs or CI.

## CI retrofit S1

[Issue #53](https://github.com/OceanMail/oceanmail-station-archive/issues/53) adds [report-only measurement tooling](../.quality/README.md), coordinated by [Project G0 draft #44](https://github.com/OceanMail/oceanmail-project-archive/pull/44). Exact-head reports and established no-radio dispatch evidence accompany the draft PR. Existing application behavior, upstream pins and Phase 4I evidence semantics are unchanged. Baseline, cleanup, required CI and branch protection are not established; further retrofit work awaits review and separate owner direction.
