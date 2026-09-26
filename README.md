# OceanMail Station

OceanMail Station is the autonomous onboard/edge communications component for OceanMail 0.2.

## Authority and purpose

Organization-level OceanMail architecture, cross-repository decisions, terminology, repository inventory, and current project state are authoritative in [`OceanMail/oceanmail-project`](https://github.com/OceanMail/oceanmail-project).

This repository is authoritative for Station implementation, Station-specific architecture/status/evidence, HERMES/Mercury integration, Station APIs/state/policy, and Grid/control implementation.

Start with root [`AGENTS.md`](AGENTS.md), [`docs/CURRENT_STATUS.md`](docs/CURRENT_STATUS.md), central [`workstreams/station.md`](https://github.com/OceanMail/oceanmail-project/blob/main/workstreams/station.md), and project ADR-006 for the public Internet-mail boundary.

## Communications foundation

Station integrates OceanMail with proven HERMES/Mercury communications technology instead of recreating an HF stack.

Current proven laboratory path:

```text
standards-based mail client
    -> SMTP / Postfix
    -> HERMES uuxcomp
    -> Taylor UUCP / HERMES uucpd/uuport
    -> Mercury
    -> constrained link
    -> crmail / Postfix
    -> authenticated IMAP
    -> standards-based mail client
```

SMTP and IMAP terminate at the local Station/mailbox boundary; they are not sent across the constrained link. A correctly configured and authenticated standards-based mail client can therefore interoperate with the ordinary submission/retrieval boundary, but a generic client is not a complete OceanMail client: Available, constrained-link planning, budgets/accounting, evidence semantics, Station/Grid/link state, Emergency product behavior, and other OceanMail-specific controls remain behind OceanMail APIs and product surfaces.

Local SMTP/Postfix capability does **not** make a Station a public Internet MTA. Under the accepted architecture, OceanMail-operated Server/infrastructure is the sole public SMTP/MX boundary. An Internet-connected Full/Minimal/emergency gateway Station exchanges eligible OMail traffic toward/from OceanMail Server through the accepted authenticated service boundary; it does not deliver directly to arbitrary public SMTP systems.

Native OMail remains decentralized. A viable boat-to-boat/store-carry-forward OMail path must continue without Internet access or central Server availability. If central Server is unreachable, Internet-boundary work may be retained/retried while native OMail continues where a viable path exists.

OceanMail-owned Station code concentrates on persistent state, evidence/correlation, policy, management APIs, GRID / CONTROL behavior, and adapters around authoritative upstream STORE / TRANSPORT components rather than duplicating their payload queues or modem behavior.

Additional supported transports may later include VARA, ARDOP, PACTOR, VHF, and IP without changing OceanMail application semantics.

## Key Station documentation

- [`docs/CURRENT_STATUS.md`](docs/CURRENT_STATUS.md) — live Station implementation state and next work.
- [`docs/STATION_ARCHITECTURE.md`](docs/STATION_ARCHITECTURE.md) — STORE / TRANSPORT and GRID / CONTROL architecture.
- [`docs/PHASE4I_RETURNED_RECEIPT_EVIDENCE.md`](docs/PHASE4I_RETURNED_RECEIPT_EVIDENCE.md) — accepted no-radio returned-receipt proof and trust boundary.
- [`docs/PHASE4_STORAGE_SECURITY.md`](docs/PHASE4_STORAGE_SECURITY.md) — production storage/key-separation gates.
- [`docs/UPSTREAM_BASELINE.md`](docs/UPSTREAM_BASELINE.md) — pinned HERMES/Mercury dependencies and integration-delta policy.
- [`docs/AVAILABLE_MANIFEST_ACCOUNT_CONTRACT.md`](docs/AVAILABLE_MANIFEST_ACCOUNT_CONTRACT.md) — logical Available/account-authorization/retrieval-plan boundary.
- [`docs/testing-hardware-acquisition-plan.md`](docs/testing-hardware-acquisition-plan.md) — staged virtual/bench/RF/maritime validation and hardware-acquisition plan; planning only, not authorization to begin physical-radio Phase 5.

## Upstream policy

Prefer direct use of and contributions to Rhizomatica upstream projects. Maintain OceanMail-specific adapters/configuration here. Keep exact upstream pins and required downstream integration deltas explicit, narrow, auditable, provenance-tracked, and license-preserving. Do not silently fork or copy HERMES/Mercury implementation into OceanMail product code.

## Current milestone

No-radio STORE / TRANSPORT proof is complete through Phase 4I, including returned receipt correlation. The next foundational work is authenticated permission-scoped Station API/account identity, account-scoped Available/retrieval/accounting interfaces, production storage/key separation, scheduling/resource policy, Grid state, relay/gateway implementation, authenticated Station/Server gateway exchange, and broader API capability.

Physical-radio Phase 5 remains held until explicitly authorized with a suitable hardware/test scope. The staged hardware/test plan above defines the current candidate scope but does not itself authorize execution.

The former OceanMail 0.1 communications architecture is preserved in historical repositories and is not inherited into this active Station implementation.

## Quality baseline

[S1 report-only measurement](.quality/README.md) inventories owned source and records lint/types/tests/coverage/security evidence. No diagnostic baseline or required quality gate is established. Missing/partial measurements remain unknown, and report-only success is not clean CI. Further retrofit phases require independent review and a separate assignment.


## Source publication and licenses

See [PUBLICATION.md](PUBLICATION.md) for the fresh-history boundary and historical evidence limitations. OceanMail-owned code uses **AGPL-3.0-only**; documentation uses **CC-BY-SA-4.0**. See [LICENSING.md](LICENSING.md), [LICENSE](LICENSE), and [LICENSE-DOCS](LICENSE-DOCS). Third-party terms remain unchanged.
