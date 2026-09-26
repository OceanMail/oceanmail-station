# Station Grid Accounting and Metering Boundary

Status: **accepted implementation boundary; accounting/metering implementation remains future work unless current source/evidence says otherwise.**

Organization-level accounting semantics are authoritative in [`OceanMail/oceanmail-project/docs/specifications/grid-accounting-metering-and-service-policy.md`](https://github.com/OceanMail/oceanmail-project/blob/main/docs/specifications/grid-accounting-metering-and-service-policy.md). This document defines how Station architecture must consume that contract; it does not redefine plan prices, quota sizes, credit formulas, or other service-policy values.

## Station responsibility

Station needs a generalized local resource-accounting/budget engine, not merely a customer-quota counter.

That engine must support autonomous disconnected operation while preserving the STORE / TRANSPORT versus GRID / CONTROL boundary:

- **GRID / CONTROL** applies current account/service/resource policy and decides whether work is eligible;
- **STORE / TRANSPORT** performs or coordinates accepted work through authoritative stores/transports and reports measurable evidence;
- Station-owned state persists accounting/resource metadata, approvals, correlation, and evidence without creating a duplicate payload queue.

Current mail policy still applies: Emergency and Ordinary are the only user-originated OMail transport classes. `Important` metadata does not alter accounting, credits, RF precedence, relay precedence, or gateway/path selection.

## Account bytes, Station airtime, and lease policy

[Project ADR-008](https://github.com/OceanMail/oceanmail-project/blob/main/docs/decisions/ADR-008-four-band-scheduling-and-channel-use.md) defines Bands 0–3. User/ship budgets use bytes; Station shared-radio budgets use time with separate local-account, relay, and system domains.

Lease duration and the normal Band 1 cap are independently configured. Ten/four minutes are arithmetic examples, not defaults or a fixed 40% ratio. Necessary Band 1 route establishment may use the whole lease; after a route exists the configured normal cap applies. Band 2 uses remaining time with account/relay-peer fairness and bounded new custody against forwarding backlog. Band 3 has no reserved share; shared broadcasts use idle or announced opportunities. Band 0 Emergency overrides ordinary budgets under existing authorization gates. Server-promoted urgent updates use Band 1's normal cap, not its route exception.

Include attributable negotiation, ACKs, retries, switching, and transfer directions within lease accounting where observable; do not double-count an occupied interval. Passive listening occupies radio availability but is not transmitting channel occupation. Internet-only work consumes no HF airtime. Values/weights remain tunable; implementation is outstanding.

## Required local domains

Station should keep conceptually distinct durable state/evidence for:

1. **User Grid accounting** — send/receive eligibility and usage for authenticated accounts served by the Station.
2. **Relay/gateway resource accounting** — third-party bytes, airtime, storage, retries/chatter, expensive Internet, peer behavior, and other local resource consumption.
3. **Station/system operational accounting** — control, receipt, manifest, policy, synchronization, diagnostics, retries, and other non-user-payload work where measurable.
4. **Contribution evidence** — candidate evidence for Server-side validation of eligible Eager relay/gateway contribution.

These may share storage/schema infrastructure, but they must not be collapsed into one ambiguous byte counter or one user quota ledger.

## User-budget behavior while disconnected

For authenticated users, Station must eventually be able to:

- cache the latest valid applicable policy/account allowance state received from Server;
- expose only authorized account budget state through Station APIs;
- persist the user's approval for a specific ordinary constrained-link send/retrieval operation;
- reject or hold work that is not currently authorized by cached policy/budget state;
- continue already authorized work after the client disconnects;
- record successful usage based on actual evidence rather than UI intent alone; and
- reconcile local working ledgers with Server authority later.

For ordinary constrained-link retrieval, private Available metadata may be learned before payload transfer, but payload content requires recipient selection/approval regardless of size. The Available/account authorization contract remains authoritative for who may see or approve that state.

Fail closed when required accounting permission/account authorization is unknown. Do not interpret loopback, device pairing, Captain/Admin role, or possession of a message/account identifier as budget authorization.

## Third-party relay/gateway behavior

Third-party forwarding incurs **no local user send/receive Grid-quota debit** merely because the Station relayed/gatewayed the traffic.

This is an accounting rule, not a resource exemption. Station still measures and may restrict third-party work according to current operator/service policy, including where supported:

- RF airtime/on-air-equivalent time;
- third-party bytes;
- relay storage and hold time;
- retries, duplicates, repair, and control chatter;
- peer/source rate or failure patterns;
- battery/power and CPU/storage pressure;
- metered/satellite Internet use; and
- success/failure/receipt outcomes.

GRID / CONTROL may rate-limit, defer, deprioritize, or temporarily refuse excessive/defective/abusive third-party work according to accepted policy. That action must not be represented as charging the volunteer vessel/captain user quota.

## Contribution credit evidence

Eager participation may produce candidate contribution evidence, but Station cannot mint globally spendable credit.

Station should eventually retain enough evidence for Server-side verification/deduplication, such as the accepted object/job/peer identity, useful work completed, resource measurements that are actually available, timestamps, duplicate/failure evidence, and relevant gateway completion evidence.

At Station registration the owner chooses the credit destination defined by program policy:

- associated vessel account; or
- captain's personal OceanMail account.

Station may cache/display that authenticated registration setting and report contribution against it; Server remains authoritative for the setting's accepted global state, qualification, balance, corrections, anti-gaming, and reconciliation.

## Policy distribution and tuning

Quota amounts, credit formulas/rates, caps/expiry/rollover, refund/reconciliation thresholds, abuse thresholds, relay resource ceilings, prices, retention durations, and similar numeric/economic/operational values are mutable service policy.

Station implementation should therefore consume authenticated/versioned policy rather than compile those values into protocol semantics. A policy-value change supported by the existing schema should not require redesigning Station architecture.

Exact signing, rollback, expiry/staleness, and fail-open/fail-closed behavior for policy distribution must be reconciled with the accepted security architecture before production use.

## API/dashboard direction

Future authenticated Station APIs/web management should be able to expose role/account-appropriate views of:

- user send/receive usage and remaining eligibility;
- pending approved operations and local working-ledger state;
- third-party relay/gateway resource utilization and configured limits;
- contribution evidence and Server-confirmed credit/reconciliation state;
- unusually expensive/chatty peer patterns where operator permissions allow; and
- policy freshness/reconciliation health.

Do not expose another user's private budget/Available/account state merely because the caller is a Station administrator.

## Evidence rule

Meter to the precision the underlying system actually provides. Distinguish application payload, Station/protocol overhead, transport progress, retransmission/repair, airtime, Internet bytes, storage/time held, and outcome only where those distinctions are supported by evidence.

A local successful process exit, attempted transfer, or estimated byte count must not be promoted into successful user accounting or eligible contribution evidence unless the relevant acceptance criteria are actually satisfied.
