# OceanMail Station — 0.2 Architecture

> Dependency reconciliation proposed on 2026-09-26: current HERMES
> `0fee4a53f54074ad6237b9fa1083a272cac89f60` with an isolated temporary retirement
> patch, and unmodified Mercury `638193b9a9cc5ab15f272805af116e94b2fdf4c6`.
> [Current inputs, regression and acceptance gates](UPSTREAM_RECONCILIATION.md)
> supersede dependency selection below; older phase evidence remains historical.


Status: **no-radio proofs complete through Phase 4I; physical-radio Phase 5 is held pending hardware and explicit authorization.**

For live implementation status and continuation instructions, see [`CURRENT_STATUS.md`](CURRENT_STATUS.md).

For accepted product/deployment boundaries, relay/gateway semantics, and Client/Station/Server decisions, see [`OCEANMAIL_0_2_PRODUCT_STATION_DECISIONS.md`](OCEANMAIL_0_2_PRODUCT_STATION_DECISIONS.md).

## Architectural boundary

OceanMail Station is not an HF modem and is not a replacement for HERMES networking.

The proven mail path is:

```text
standards-based mail client
      |
SMTP submission
      |
Postfix
      |
HERMES uuxcomp
      |
Taylor UUCP
(uucico -> uuport -> uucpd)
      |
VARA-compatible TNC interface
      |
Mercury
      |
simulated constrained channel / later physical HF
      |
Mercury + HERMES + UUCP
      |
crmail / Postfix
      |
authenticated IMAP / Dovecot
      |
standards-based mail client
```

SMTP and IMAP do not traverse the constrained link. They are ordinary client/local-service boundaries around a compressed/store-forward middle.

OceanMail-owned code should concentrate on:

- persistent Station identity/configuration/service state;
- local API/authentication/authorization;
- observation/correlation of authoritative queue/store state;
- Emergency/Ordinary scheduling, budget, relay, and gateway policy;
- user-facing evidence/delivery state;
- translation between OceanMail semantics and proven mail/HERMES boundaries;
- diagnostics/resource accounting;
- GRID / CONTROL state and network intelligence;
- web/client management integration.

It should not duplicate:

- ARQ;
- modem adaptation;
- retransmission framing;
- radio keying;
- generic UUCP behavior;
- authoritative payload queues/stores already provided by Postfix, Taylor UUCP, Dovecot/mailbox storage, or future store/transport components;
- ordinary desktop mail composition/storage merely for its own sake.

## Internal functional split: STORE / TRANSPORT Plane and GRID / CONTROL Plane

OceanMail Station has two major functional responsibilities that remain logically distinct even when they share one daemon or computer.

```text
                       OceanMail Station
                              |
                    +---------+---------+
                    |   Station Core    |
                    | identity/config   |
                    | API/events/state  |
                    +---------+---------+
                              |
              +---------------+---------------+
              |                               |
              v                               v
    STORE / TRANSPORT Plane          GRID / CONTROL Plane
    -----------------------          --------------------
    SMTP/Postfix                     station/peer discovery
    Dovecot/mailbox storage          topology/observations
    HERMES uuxcomp/crmail            relay policy
    Taylor UUCP                      gateway policy
    Mercury                          OChat Grid behavior
    durable store coordination       reputation/telemetry
    HF/IP/future VHF                 maps/network statistics
    transfer/receipt evidence        future routing/selection
```

The **STORE / TRANSPORT Plane** answers: “How do I durably hold and move accepted traffic from here to there, and what evidence proves what happened?”

It coordinates authoritative stores, transport execution, retries, queue interaction, measurable progress, and transport/receipt evidence. Payloads remain authoritative in the underlying store/transport component. OceanMail-owned state persists mappings, evidence, policy decisions, budgets, and metadata without creating a second payload queue merely for convenience.

The **GRID / CONTROL Plane** answers: “What does the network look like, and how should this Station behave within it?”

It owns OceanMail-specific peer observations, relay/gateway policy, OChat Grid behavior, topology, reputation inputs, telemetry, maps/network state, and future selection/routing intelligence.

The Station Core provides shared identity, configuration, authorization, API/event boundaries, and cross-plane state.

GRID / CONTROL policy should not be embedded into upstream STORE / TRANSPORT implementations. GRID / CONTROL may select or authorize work; STORE / TRANSPORT then performs/coordinates it and reports measurable evidence back.

## Relay/gateway boundary

A running Station has no relay-Off mode.

- **Eager** relays advertise availability and volunteer broadly, subject to resource controls.
- **Reluctant** relays do not advertise; they listen and may intervene as fallback when another station cannot find a suitable relay, evaluating Emergency, age/stall/failure and route/resource conditions, never an ordinary Priority class.
- relay and gateway policies are separate.
- emergency assistance remains constrained by technical capability and legal/operational permission.

OceanMail-operated managed gateways run the same Station software as vessel stations.

## Current mail policy and Available boundary

[Desktop Decision 0009](https://github.com/OceanMail/oceanmail-desktop/blob/main/docs/decisions/0009-ordinary-mail-scheduling-and-importance.md) supersedes conflicting older normal/Priority rules. Emergency and Ordinary are the only OMail transport classes. Important is interoperable metadata only: it must not affect RF, Station queue or relay precedence, gateway/path selection, credits/quota treatment, or automatic Available retrieval order.

Full Gateway normally offers ordinary third-party service. Minimal retains its name and normally does not; it may offer fallback for stranded/stalled ordinary traffic when Grid policy finds no suitable Full Gateway/route or excessive accumulated delay. Off offers no ordinary third-party service. Emergency remains eligible in all modes when technically, legally and operationally permitted. Relay willingness remains separate from gateway policy.

Station scheduling follows [Project ADR-008](https://github.com/OceanMail/oceanmail-project/blob/main/docs/decisions/ADR-008-four-band-scheduling-and-channel-use.md): (0) Emergency and its own propagation/control; (1) control/manifests/Grid updates/coordination plus authenticated Server-promoted urgent updates; (2) ordinary local-account and relay payload; (3) shared background broadcasts. This supersedes Decision 0009's five-band hierarchy and the later six-band/reserved-slot drafts.

Lease duration and the normal Band 1 cap are independent tuning inputs; ten/four minutes are examples, not fixed values or a 40% rule. Band 1 may use the full opportunity for necessary route establishment, then returns to its normal cap after a route exists. Band 2 uses the remainder with local/relay and account/peer fairness. Band 3 has no reserved share; it uses idle opportunities or announced broadcasts. Emergency preempts under existing authorization gates. The first in-memory policy controller is documented in [LEASE_CONTROLLER.md](LEASE_CONTROLLER.md); transport dispatch, fairness and channel behavior remain unimplemented. Use rendezvous announcements, negotiated same-channel addressed Band 1/Band 2 exchanges, and time/channel-announced shared updates. Single-radio check-in and Emergency discovery/preemption require bounded validation; capacity eligibility and privacy remain mandatory.

The [Available contract](AVAILABLE_MANIFEST_ACCOUNT_CONTRACT.md) defines private recipient metadata supplied by an authoritative remote holder before constrained-link content. When a recipient Station exists, it authenticates the client, enforces account grants, persists availability and retrieval intent, and owns local execution/progress. In accepted Station-less hosted/Lite direct-Internet operation, the hosted Server/service assumes the equivalent client-authentication, account-grant, durable-plan and retrieval/synchronization coordination responsibilities. The Server remains authoritative for hosted availability and service/account balances/policy; native sender Stations/holders can supply boat-to-boat availability without central infrastructure. Wire encoding, source trust, synchronization and transport mapping remain separate design work. No manifest transport through RFC email bodies is selected.

This is not yet implemented by the observation API or the proven whole-message mail path. Do not relabel local IMAP mail or outbound history as Available, or use Desktop filtering as authorization.

## Deployment boundary

Production must not assume the client and Station are the same process or computer.

The Station is intended to:

- run persistently/headlessly on Linux;
- remain autonomous when clients disconnect;
- serve multiple authorized users/clients over a vessel LAN once authentication/authorization is implemented;
- continue accepted background work independent of the user interface;
- expose one secured API used by OceanMail-aware clients and local web management.

Administrative Station authority and mailbox decryption authority are separate concerns. Captain/Owner/Admin authority does not inherently grant access to another user's private mailbox contents.

## Storage/security boundary

Current lab SQLite state is plaintext and explicitly not production-ready.

Current security status remains equivalent to:

- `production_storage_ready=false`
- `application_storage_encryption=false`
- `per_user_key_separation=false`
- `host_volume_encryption_verified=false`

Production requires:

1. host/offline storage protection for a stolen/removed disk (LUKS2/dm-crypt remains a candidate);
2. application/mailbox key separation so administrative Station authority does not automatically decrypt other users' private mail.

The Station API remains loopback-only until authentication/authorization is implemented and accepted.

## Evidence semantics

Every state must correspond to evidence available at that layer.

Current conservative rules:

- Postfix `active` = selected for delivery, not transmitted;
- `left_postfix_queue` = disappeared from Postfix, not delivered;
- `uucp_job_created` = exact queued Taylor UUCP work exists, not transmitted;
- `queued_at_attempt_start` = exact mapped job was queued when a system-level `uucico` attempt began, not proof that it sent bytes;
- `transport_progress_observed` with Mercury `rx_total_bytes` = measured system/link progress during that attempt, not per-message byte attribution and not receipt;
- `uucico_attempt_finished` = caller process completion only; exit 0 is not automatically remote receipt;
- `remote_mailbox_receipt_observed` = the exact RFC `Message-ID` was proven present in the specified far-side mailbox after receive-side processing; it is stronger than sender-side transport success but is not proof that a human read the message;
- `returned_remote_receipt_observed` = the origin Station received and structurally validated the returned Phase 4I laboratory receipt, correlated it to the original local observation/message/Taylor job, and persisted that evidence. Accepted trust is exactly `lab_peer_transport_unverified`; this is not production cryptographic peer authentication and not human-read proof.

A successful local transmit/process exit is never automatically equivalent to confirmed remote receipt.

## Proof phases

### Phase 0 — Mercury link proof — COMPLETE

Pinned Mercury `v1.9.13` / `4eac25e06a0c88996621bc74af5b7b2f0d353848` builds and exchanges deterministic data through loopsim/ALSA without radio hardware.

### Phase 1 — two-station store-forward proof — COMPLETE

Proved Taylor UUCP/HERMES durable job retention, interruption, exact retry, and partial-progress reuse. The canonical Phase 1C `rx_total` parser is now Debian/mawk portable.

### Phase 2 — RFC mail semantics + HERMES compression — COMPLETE

Proved Postfix -> HERMES `uuxcomp` -> Taylor UUCP -> HERMES/Mercury -> `crmail` -> Postfix/mailbox.

Pinned HERMES queue policy currently defaults to a 20,000-byte maximum queued email and 80,000-byte per-host UUCP email queue. Acceptance fixtures must remain aware of those upstream limits.

### Phase 3 — standard mail-client compatibility — COMPLETE

Proved standard SMTP submission and authenticated IMAP retrieval across the complete constrained path.

### Phase 4A — persistent Station foundation — COMPLETE

Rust + SQLite + Axum service, persistent identity, loopback API, Postfix parsing, security gates.

### Phase 4B — real Postfix observation — COMPLETE

Stable Station observation identity over real `postqueue -j` state.

### Phase 4C — durable queue evidence — COMPLETE

Persistent `first_seen`, `queue_state_changed`, `left_postfix_queue`, and `reappeared` events.

### Phase 4D — autonomous Postfix observer — COMPLETE

Background polling with explicit observer health/failure state; observer failure cannot fabricate an empty queue.

### Phase 4E — deterministic Postfix -> Taylor job correlation — COMPLETE

Postfix authoritative queue ID is carried into an OceanMail-owned HERMES `uuxcomp` boundary; Taylor's own `uux -j` job ID is captured/verified and durably correlated.

### Phase 4F — Taylor caller-attempt evidence — COMPLETE

Merged PR #14, main merge `6c624ca65c085aa1c4e52246769986135d2179fd`.

Proved a real system-level `uucico` caller attempt, exact queued-job snapshot, no-link failure with job retention, conservative process semantics, and restart durability.

### Phase 4G — simulated Mercury progress evidence — COMPLETE

Merged PR #15, main merge `1e307ec3983bb66c18dae1989cbd30876c756bd5`.

Proved exact mapping -> caller attempt -> measured remote-side Mercury progress, followed by forced link loss with the exact Taylor job retained and no remote mailbox delivery.

### Phase 4H — far-side mailbox receipt evidence — COMPLETE

Merged PR #18, main merge `581f2981e503d63ea0210f5ab6ed3960607afe59`.

Accepted verification workstation run proved:

- exact Postfix observation -> exact Taylor job mapping;
- successful system-level `uucico` attempt association;
- 17,076-byte compressed `crmail` payload within pinned HERMES policy;
- actual Station B mailbox presence of the exact RFC `Message-ID` after approximately 350 seconds of simulated transfer;
- Subject, recipient, and deterministic body token verification at Station B;
- Taylor job retirement after successful constrained transfer;
- caller exit 0 recorded separately from receipt evidence;
- `remote_mailbox_receipt_observed` persisted only after far-side mailbox verification;
- durable receipt mapping across Station restart;
- no physical radio usage.

### Phase 4I — returned receipt evidence — COMPLETE

Merged PR #20, main merge `188d0ffea77367814a4b3efa26f3832cc7ddeed9`.

Phase 4I removes the origin's dependence on omniscient direct access to the far-side mailbox for sender-visible returned evidence. The accepted no-radio chain proves:

1. Station B creates a compact versioned receipt only after exact far-side mailbox proof;
2. that receipt identifies/correlates the original message/observation identity;
3. the receipt is queued as its own exact Taylor B -> A job;
4. reciprocal work waits for both Mercury to return to `LISTENING` and HERMES to reach explicit cleanup-complete boundaries;
5. the receipt traverses the same constrained HERMES/Mercury path and arrives byte-identical at Station A;
6. Station A validates/correlates the returned artifact to the original message/job;
7. only then is `returned_remote_receipt_observed` persisted;
8. the evidence survives Station restart.

Accepted source head is `563bf08ea2d06f478db5f559c499d88c70c15eca`; accepted self-hosted run is `34517583360`. The returned receipt is 264 bytes with SHA-256 `81516f76ed78ec0872f74333e2c5a7539a8061c878f9093a6262bffae6be6755`. Trust remains `lab_peer_transport_unverified`.

This completes the current no-radio STORE / TRANSPORT evidence chain through returned sender-visible laboratory receipt without claiming production cryptographic trust.

## Next security/account/Available boundary

The next high-value implementation boundary is not another receipt proof. It is the security/account foundation required before private Available metadata or LAN API access can become real:

1. authenticated client principal and durable user/account/device context;
2. explicit principal -> account grants and revocation semantics;
3. account-scoped API authorization while keeping LAN exposure disabled until accepted;
4. protected persistence/key-separation design consistent with the existing production security gate;
5. then account-scoped Available catalog/retrieval-plan operations from the logical contract;
6. only after those boundaries are accepted should Desktop fixtures be replaced with real recipient-private state.

Manifest synchronization/wire encoding, holder trust/cryptography, accounting, scheduling implementation and decentralized transport mapping remain separately bounded work. They must not be smuggled into API authentication merely to accelerate UI integration.

## Physical-radio Phase 5 — HELD PENDING HARDWARE

No suitable physical HF radios are currently available for the test program, so Phase 5 is deliberately not started.

When hardware is acquired and work is explicitly authorized, evaluate:

- actual HF radio/audio profiles;
- Mercury direct Hamlib/serial PTT;
- HERMES radio daemon where useful;
- real RF measurements/failure modes.

No-radio acceptance remains mandatory even after hardware exists.

## Future transport abstraction

The Station architecture must remain capable of adding:

- IP / Starlink / normal Internet;
- VHF;
- HF;
- later VARA/ARDOP/PACTOR or other appropriate adapters.

VHF is explicitly deferred until a functional OceanMail system exists.

## Maintenance/refactoring guidance

Historical lab scripts include temporary exact-string generated variants. This fails loudly when assumptions drift, but accumulated layering is difficult to audit.

Policy:

- preserve accepted historical evidence/scripts;
- avoid adding generator-on-generator depth;
- prefer direct canonical scripts or shared lab helpers for new phases;
- refactor existing wrappers only when doing so does not obscure accepted evidence lineage.

SQLite connection reuse and a named intermediate type for `load_outbound_history` remain valid future cleanup items but are not current correctness blockers.

## Key design rule

Every claimed delivery state must correspond to evidence available at that layer. OceanMail must tolerate long one-way transfers, missing acknowledgements, interruption, and delayed return evidence without converting transport success into fictional receipt state.
