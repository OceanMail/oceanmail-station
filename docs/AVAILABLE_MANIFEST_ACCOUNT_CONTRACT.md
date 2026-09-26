# Available manifest and account authorization boundary

Status: accepted logical architecture/contract foundation, 2026-09-10. This specifies required behavior, not implemented API capabilities. No HTTP endpoints, wire schema, authentication scheme, cryptographic encoding or identifier format is selected here.

Authority: project-lead Available foundation decisions and [Desktop Decision 0009](https://github.com/OceanMail/oceanmail-desktop/blob/main/docs/decisions/0009-ordinary-mail-scheduling-and-importance.md). See [Station product decisions](OCEANMAIL_0_2_PRODUCT_STATION_DECISIONS.md) and [storage security gate](PHASE4_STORAGE_SECURITY.md).

OMail transport classes are Emergency and Ordinary only; there is no ordinary sender-selectable Priority class. Important is conventional metadata, not a class or spend authorization.

## Meaning and ownership

Available is recipient-authorized metadata describing content that exists at another authoritative holder **before constrained-link payload transfer**. It is not an IMAP folder, already-downloaded mailbox content, Postfix outbound queue history, or a client-side filtering trick. A manifest is not permission to transfer an ordinary body or attachment.

| Owner | Responsibility |
| --- | --- |
| Client | Present Available; express selection/order/hold/representation intent; obtain explicit user approval. |
| Recipient Station, when present | Authenticate the client principal; enforce principal → account grants; persist recipient-visible availability and retrieval intent; validate ownership, eligibility and representations; schedule/execute approved retrieval; own local progress/evidence after client disconnect. |
| Hosted Server/service when no recipient Station exists | In accepted direct-Internet/Lite operation, authenticate the client principal, enforce account grants, own the hosted recipient-visible Available state/retrieval plan, and execute or coordinate permitted hosted retrieval/synchronization without pretending a Station exists. |
| Source/holder | Be authoritative that the identified payload/components exist; generate or supply trustworthy availability metadata and provenance; bind disclosure to the intended recipient/account and require holder-side authorization or equivalent end-to-end confidentiality before private metadata leaves the holder. |
| Server | Be authoritative for hosted OceanMail mailbox/account availability, service/account policy and balances/credits. Internet ingress can originate availability metadata for hosted mail. |
| Sender Station/native OMail holder | Originate availability metadata for decentralized native OMail without requiring central OceanMail infrastructure, while enforcing recipient/account binding before disclosure. |

The **active recipient-side plan owner** is the recipient Station when one is present. In accepted Station-less hosted/Lite direct-Internet operation, the hosted Server/service assumes the corresponding authentication, account-grant, durable-plan, and execution-coordination responsibilities. The two modes must expose equivalent privacy/authorization semantics even though their implementation locations differ.

Native boat-to-boat Available must work without the central Server. This does not permit a Station to invent hosted service balances or grant account access. Native account enrollment/trust and applicable local resource authorization remain prerequisites to implementation; central availability is not their mandatory source.

Payloads remain in authoritative stores. Recipient-side metadata, mappings and plans coordinate those stores; this contract does not create a second payload queue. Normal local delivery/retrieval remains SMTP/IMAP around the established constrained transport.

## Identities

These are logical terms, not concrete serialized fields or identifier formats:

| Term | Meaning and constraints |
| --- | --- |
| OceanMail logical message ID | Durable identity of the logical message across holder advertisements and transfer/correlation records. Must support disambiguation across independent native holders and survive local queue-ID changes; collision, origin binding and trust rules need later design. |
| Component ID | Identifies a body or attachment component within a logical message. A message can have multiple attachment components, each with its own selection and availability. |
| Representation ID | Identifies one permitted representation of a component. References must resolve within that component/message, never by a globally assumed label such as `preview`. |
| RFC Message-ID | Interoperability/correlation evidence only. It may be absent, duplicated or untrusted and is not an ownership grant or sufficient logical/authorization identity alone. |
| Account ID | Durable recipient account authorization scope, independent of a Thunderbird profile key, display name or email string. The authenticated principal needs an explicit grant to act within it. |

Subject, recipient address, timing, Postfix queue ID and RFC Message-ID alone must never authorize access. Possession of an ID is not a grant. Each holder advertisement and component reference must be bound to the intended account and verified source context before being accepted as trustworthy availability; the binding/crypto mechanism is separate design work.

## Private metadata and authorization

Manifest/Available metadata is private recipient mailbox metadata. Privacy must be enforced on **both sides of disclosure**:

1. the source/holder must not release private manifest metadata to an unauthenticated, unauthorized, or wrong recipient/account endpoint; and
2. the recipient-side plan owner must authenticate the requesting client principal and enforce its account grant before returning that metadata locally.

A concrete holder-to-recipient cryptographic/authentication mechanism is deliberately not selected here. Implementation may use authenticated peer/account binding, end-to-end encryption to the recipient/account, or another reviewed mechanism, but the required property is fixed: sender/subject/component/representation metadata must not travel in cleartext to an unauthorized peer merely because the final recipient Station/API would later enforce a local grant.

When a recipient Station is present, recheck grants on every operation and before new execution; already-authorized background work follows the applicable revocation/expiry policy, which must be specified before implementation. In Station-less hosted/Lite mode, the hosted Server/service performs the corresponding client/account authorization and durable-plan checks.

Read and update permissions must be explicit; read access does not imply permission to retrieve or spend. Device pairing alone is not user authorization. Captain/Station Admin authority does not inherently grant personal mailbox Available access. A shared Desktop profile does not merge account grants or balances.

Every referenced message, component, representation, plan and budget must belong to an authorized scope. Reject mixed-account or unauthorized references before disclosing protected details; errors must not reveal another account's object existence. Apply the boundary to lists, counts, events, caches, diagnostics and other API paths too. Existing vessel-wide observation routes cannot serve as a bypass for private metadata. Desktop filtering and loopback binding provide no authorization.

Production persistence must satisfy the storage/key separation gate: headers and relationship metadata are sensitive, not merely bodies. Current plaintext lab SQLite is not approved production storage for this contract. This document neither enables LAN exposure nor selects authentication/key management.

## Recipient-visible availability state

The logical catalog needs account and holder/source binding, message/component/representation identities, observed availability and freshness/provenance, permitted descriptive metadata, component sizes where known, and local-possession/deduplication evidence. Estimates must be distinguished from measured sizes and actual transfer/receipt evidence.

Holder existence is not the same as current reachability, recipient permission, local possession or scheduling eligibility. Preserve these distinctions. Stale/untrusted metadata cannot silently become current availability. A repeated advertisement must not trigger a duplicate payload retrieval merely because its Postfix ID or arrival time changed.

Known already-local components must not remain eligible as remote work requiring another constrained-link download. Reconcile their evidence/state without pretending a manifest supplied their content. Eligibility and a meaningful block reason are recipient-side policy state, not client assertions.

## Durable retrieval plan

The active recipient-side plan owner—recipient Station when present, otherwise hosted Server/service for Station-less hosted/Lite operation—owns an account-scoped plan with a revision and durable accepted intent. It must represent:

- logical message/component references and body selected/not selected;
- each attachment component's selected permitted representation or deferred/not selected state;
- the user's preferred order for selected retrieval work, with unambiguous membership including attachment-only work;
- hold/defer/resume intent and its scope, distinct from selection and current eligibility;
- plan-owner-derived eligibility/block reasons, relevant availability/policy revisions and execution evidence;
- operation/batch-specific user approval and any authorized reservation references; and
- accepted revision/result sufficient to recover after retries, client disconnect and plan-owner restart/failover according to the deployment model.

A message-level hold prevents new execution of its body and selected components. A component defer prevents that component's new execution. Retained choices may remain visible while held, but must not be mistaken for executable work. Resume removes the hold and revalidates eligibility, grants and spending authorization; it does not bypass them. Reservation release/retention and safe treatment of already-in-flight work require explicit execution/accounting rules before implementation. No hold promises reversal of bytes already transferred.

Selection and order are intent, not proof of retrieval, reservation or billing. Ordinary constrained-link content requires recipient approval regardless of size. Internet synchronization may be automatic for permitted content but must respect applicable explicit hold/defer/privacy intent.

Preferred payload order is within Band 2's local-account share under [Project ADR-008](https://github.com/OceanMail/oceanmail-project/blob/main/docs/decisions/ADR-008-four-band-scheduling-and-channel-use.md), never guaranteed RF priority. Authorized manifests are Band 1 and do not authorize body/attachment retrieval. These numbers belong to the four-band model, superseding the intermediate six-band draft. Station retains fairness, aging, budget eligibility, and Band 0 Emergency preemption. Addressed private manifests remain account/holder-authorized even when public shared records can be overheard. Important remains metadata only and does not change transport or accounting precedence.

## Minimum logical operations

No endpoint URLs or transport verbs are prescribed. The operation semantics apply to whichever component is the active recipient-side plan owner for the deployment mode.

| Operation | Required semantics |
| --- | --- |
| List available manifest | Authenticate and authorize account read access; return only that account's holder-authorized permitted metadata, evidence/freshness and catalog revision. Distinguish an authoritative empty result from failure or unknown availability. |
| Read current retrieval plan | Authorize account plan access; return durable intent, plan revision, eligibility/block reasons and approval/reservation availability without claiming execution from selection. |
| Update retrieval plan | Authorize account update/required spend rights; require expected plan revision; validate all referenced objects, representations, ordering, holds, eligibility and approvals against current authoritative state; durably accept a coherent change or reject without partial mutation. Return accepted revision/result or a conflict/denial that requires resolution. |
| Read budget/accounting availability state | Authorize account access; distinguish known values and authoritative provenance/policy freshness from unknown or unavailable allowance, credit, reservation and usage state. A missing ledger is not zero or unlimited credit. |

An update is not itself evidence of execution. Actual accepted-work progress and outcomes remain authoritative execution evidence and must be readable/reconciled without inventing completion. The four operations are a minimum logical boundary, not a complete execution/event API specification.

## Revision, concurrency and retry requirements

- Use an opaque plan-owner-issued plan revision for compare-and-update. A stale expected revision must not overwrite another client's accepted changes.
- Validate against current account grants, catalog/component versions, eligibility and budget/policy state at acceptance; checking only the plan revision is insufficient.
- Validate ordering as the intended unique set/permutation of selected work; reject duplicates, omissions and foreign references rather than silently filtering them.
- Persist intent, revision, approval and any reservation effects consistently before acknowledging acceptance. Rejected updates leave prior state intact.
- Retries after a lost response must resolve to the prior accepted result or a safe conflict, not duplicate retrieval or spending. Concrete idempotency/replay mechanisms are deferred.
- Availability, execution and policy changes can invalidate an intent without erasing it. Expose revised effective state/block reasons and prevent execution beyond current authorization. Define revision interactions before implementation.

## Budgets and unavailable state

Server remains authoritative for hosted service/account balances, credits and policy. Station may eventually cache authoritative policy and maintain local reservations and actual usage for disconnected operation. No balance, credit award or cost can be manufactured from fixture values, queue sizes or a client's approval boolean.

Until authoritative accounting exists, report it explicitly as unavailable/unknown and fail closed for spending beyond known authorization. Unknown is not zero, unlimited, approved or denied-by-policy; unavailable means the capability/source cannot currently supply a fact. Known zero is a real value. Stale evidence must retain its provenance and cannot silently authorize spending. The eventual representation of these states is not specified here.

Native holder availability does not require a Server balance lookup merely to exist. It also does not imply free/unlimited transfer: execution still requires known applicable authorization/resource policy. The native/offline policy and trust mechanism must be designed without adding a central Server dependency to boat-to-boat availability.

Estimates are not actual debits. Approval is operation/batch-scoped, not a reusable blanket grant; increasing work beyond approved scope requires renewed authorization. Successful recipient-approved constrained-link receipt, incomplete attempts, reservations, actual usage and Server reconciliation remain distinct. Missing accounting must not prevent permitted protective intent such as holding/deferring work, while it must prevent unauthorized new spend.

## Non-goals and prerequisites

This tranche does not implement HTTP APIs, enrollment/authentication, account grants, encrypted stores, ledgers, payload retrieval, representation generation, or a new scheduler. It does not choose UUID/crypto formats, wire schemas, codec/progressive-byte reuse or source authentication mechanisms. Multiple native holders, account binding, revocation, source trust, stale-state policy and execution/accounting transitions need implementation designs and acceptance tests.

A compact OceanMail control/synchronization mechanism must carry recipient-scoped availability metadata ahead of payload where the constrained path permits it. Its wire encoding, cryptography, synchronization protocol and transport mapping are separate design work. Whatever mechanism is selected must enforce the holder-side authorization/confidentiality boundary above. This contract does **not** decide to carry manifests as RFC email bodies and does not redesign HERMES/Mercury/UUCP.

Current observation-only API and fixture-backed Desktop Available remain explicitly incomplete. Phase 4I returned-receipt evidence is accepted on main; the Dovecot compatibility proof is a separate post-transfer mailbox result. Future correlation/mailbox integration must coordinate with those accepted/current outcomes, without mistaking a receipt mapping for account authorization or IMAP retrieval for pre-transfer availability.
