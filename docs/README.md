# OceanMail Station Documentation

This directory is authoritative for **Station-specific implementation, evidence, plans, and research** in OceanMail 0.2.

Organization-level OceanMail definition, architecture, terminology, cross-repository decisions, repository inventory, current project state, and contributor/agent workflow are authoritative in [`OceanMail/oceanmail-project`](https://github.com/OceanMail/oceanmail-project). Component-local documents here must not override that spine.

## Required read order

For substantial Station work, read:

1. `OceanMail/oceanmail-project/PROJECT.md`;
2. `OceanMail/oceanmail-project/CURRENT_STATE.md`;
3. `OceanMail/oceanmail-project/DECISIONS.md`;
4. `OceanMail/oceanmail-project/REPOSITORIES.md`;
5. the relevant project workstreams/ADRs/interfaces/specifications;
6. this repository's [`CURRENT_STATUS.md`](CURRENT_STATUS.md);
7. the applicable Station architecture/security/upstream/contract documents below;
8. current source, tests, open PRs, and issues.

Older handoffs and predecessor-repository references are context only and cannot override current project-spine or Station `main` truth.

## Live status authority

Start component work with [`CURRENT_STATUS.md`](CURRENT_STATUS.md).

It is the authoritative live Station implementation snapshot and supersedes older thread handoffs when they disagree with current Git state. Always verify `main` and open PRs/issues before acting.

Historical handoff files remain useful for evidence lineage and design history, but are not live continuation authority after being superseded.

## Current Station documents

- [`AVAILABLE_MANIFEST_ACCOUNT_CONTRACT.md`](AVAILABLE_MANIFEST_ACCOUNT_CONTRACT.md) — logical availability/identity/account authorization and durable retrieval-intent boundary; includes decentralized native OMail, with no endpoint or wire design.
- [`GRID_ACCOUNTING_METERING.md`](GRID_ACCOUNTING_METERING.md) — Station implementation boundary for disconnected user working ledgers, third-party resource metering, contribution evidence, and Server-authoritative service accounting.
- [`CURRENT_STATUS.md`](CURRENT_STATUS.md) — live phase status, accepted evidence boundary, current next work, maintenance findings, and workflow conventions.
- [`STATION_ARCHITECTURE.md`](STATION_ARCHITECTURE.md) — current STORE / TRANSPORT and GRID / CONTROL architecture and proof boundaries.
- [`PHASE4_STORAGE_SECURITY.md`](PHASE4_STORAGE_SECURITY.md) — accepted Phase 4 encryption-at-rest, user-key-separation, and production storage security gate.
- [`UPSTREAM_BASELINE.md`](UPSTREAM_BASELINE.md) — HERMES/Mercury upstream baseline and exact dependencies/research basis.
- [`PHASE1_UUCP_LAB.md`](PHASE1_UUCP_LAB.md) — Phase 1 UUCP/HERMES/Mercury laboratory design and acceptance scope.
- [`testing-hardware-acquisition-plan.md`](testing-hardware-acquisition-plan.md) — current staged validation/hardware-acquisition planning from virtual testing through RF and maritime field trials. It is a plan, **not authorization to start physical-radio Phase 5**, and its RF/unattended language is qualified by the U.S. HF regulatory constraints below.
- [`PUBLICATION_READINESS.md`](PUBLICATION_READINESS.md) — Station-specific privacy/history/licensing/provenance gates that must be reviewed before any repository publication decision.
- [`OCEANMAIL_0_2_PRODUCT_STATION_DECISIONS.md`](OCEANMAIL_0_2_PRODUCT_STATION_DECISIONS.md) — Station-specific Client/Station/Server and management decisions, subject to the project-spine decision ledger where program-level semantics have since been centralized.
- [`research/RADIO_RENDEZVOUS_AND_LINK_REQUIREMENTS.md`](research/RADIO_RENDEZVOUS_AND_LINK_REQUIREMENTS.md) — deferred RF/rendezvous/link research, not current proof requirements.
- [`research/SINGLE_RADIO_OPERATIONAL_BASELINE.md`](research/SINGLE_RADIO_OPERATIONAL_BASELINE.md) — retained one-HF-transceiver functional baseline for future scheduler/rendezvous work; multi-radio remains an optimization, not a baseline dependency.
- [`research/US_HF_REGULATORY_CONSTRAINTS.md`](research/US_HF_REGULATORY_CONSTRAINTS.md) — Station-specific engineering constraints derived from the project-spine FCC/Part 80 workstream; explicitly qualifies older OTA/unattended test-plan language and does not itself constitute legal authorization.
- [`CURRENT_HANDOFF_2026-09-04.md`](CURRENT_HANDOFF_2026-09-04.md) — historical handoff retained as a pointer to the live status document and Git history.

## Program decisions Station must consume

Current program-level semantics come from `OceanMail/oceanmail-project`, especially `PROJECT.md`, `DECISIONS.md`, and the relevant workstream/ADR/interface/specification documents.

Desktop Decision 0009 remains useful provenance for the removal of ordinary sender-selectable Priority, but the current authoritative rule is recorded in the project decision ledger: user-originated transport classes are Emergency and Ordinary; `Important` is metadata only.

[Project ADR-008](https://github.com/OceanMail/oceanmail-project/blob/main/docs/decisions/ADR-008-four-band-scheduling-and-channel-use.md) defines Bands 0–3, capped control with a necessary route-establishment exception, ordinary local/relay payload using the remainder, and unreserved shared broadcasts. It also defines negotiated same-channel control/payload and bounded single-radio check-in requirements. This supersedes the five-/six-band and reserved-slot drafts; experimental implementation and remaining gates are described in [LEASE_CONTROLLER.md](LEASE_CONTROLLER.md).

The Server remains authoritative for global service accounting and earned-credit validation. Station may maintain disconnected working ledgers and resource limits but does not redefine service accounting locally.

## Authority boundary

This repository may define:

- Station service architecture and APIs;
- HERMES/Mercury/UUCP integration;
- radio/link adapters and control;
- Station-local persistence/queue observation/evidence state;
- management API/web implementation;
- measurements/diagnostics;
- installation/update/recovery behavior for the Station component;
- Station-specific test plans and implementation evidence; and
- RF/link research.

It must not independently redefine organization-level semantics such as:

- what OceanMail Full/Lite mean;
- OMail delivery/receipt meaning where a cross-component contract exists;
- user/vessel/Station identity relationships;
- Captain/Owner/Admin product authority;
- OChat behavior;
- service pricing/quota policy;
- Emergency/Ordinary transport-class semantics; or
- the program roadmap.

Those require owner/project-lead decisions recorded in the project spine and then consumed here.

## Precedence for Station work

1. owner decisions and `OceanMail/oceanmail-project` current authority;
2. [`CURRENT_STATUS.md`](CURRENT_STATUS.md) for live Station implementation status;
3. current Station architecture/API/security/upstream/contract documents;
4. Station implementation/test plans;
5. Station research/work reports/history.

If Station implementation evidence shows a program assumption is wrong, record the evidence and reconcile the project-spine decision rather than silently changing semantics locally.

## Research and planning rule

Research documents preserve requirements, experiments, and candidate techniques. Plans describe intended future work. Neither enters the current critical path merely because it exists.

In particular, physical-radio Phase 5 remains held until explicit owner/project-lead authorization even though a component-local hardware/test plan exists. U.S. OTA/transmitter-control work must also satisfy the active regulatory constraints referenced above; technical capability or successful lab operation is not regulatory clearance.
