# Configurable lease controller — issue #22, first slice

`src/lease.rs` implements a deterministic, in-memory GRID/CONTROL policy module.
It is exported by the Station library but is not wired into the daemon or an RF
adapter. Issue #22 remains open; this is not a complete scheduler.

Authority: [ADR-008](https://github.com/OceanMail/oceanmail-project/blob/main/docs/decisions/ADR-008-four-band-scheduling-and-channel-use.md).
The owner clarified on 2026-09-21 that ten/four minutes were convenient arithmetic
examples. `LeasePolicy::new(duration, control_cap)` requires independent explicit
values. There is no default duration, fixed 40% relationship, or wire constant.
Zero control allowance and a full-lease control allowance are supported;
zero-length leases and caps exceeding their lease are rejected.

## Behavior and caller contract

- Supply monotonic elapsed time from the agreed opportunity start. Delays and
  negotiation/switching/ACK/retry overhead consume the opportunity too.
- Each decision accounts elapsed time since the preceding decision against its
  selected work. Band 1 setup counts toward the normal cap; establishing a route
  does not reset the allowance. Late adapter calls count actual overruns.
- Route setup can use the remaining lease only while separately admitted as
  necessary. Routine manifests and Server-promoted updates use normal control.
- Payload receives all remaining time when no eligible control can run.
  Background has no reservation and runs only when no higher eligible work runs.
- No eligible work releases the ordinary opportunity permanently. Later work
  needs a newly negotiated opportunity, not resurrection of a released lease.
- Emergency returns a handoff to a separate Emergency coordinator, even after
  ordinary expiry. It does not renew the ordinary lease or supply an unlimited
  transmit grant. Its elapsed time does not debit the normal Band 1 cap.
- Backward time is rejected without mutation; repeated timestamps charge nothing.

`EligibleWork` is trusted internal input, not a client/API priority interface.
All flags default false. Before setting them, the caller must validate permission,
capacity-tier eligibility, recipient intent, route usability and Server promotion
where applicable. Necessary route attempts require a separate bounded admission,
progress and backoff policy. Unknown or unvalidated work must remain ineligible.

`Run.max_duration` is an upper bound for the policy turn. An adapter must enforce
safe bounded batches, reserve essential ACK/teardown time, and call again when
work completes or eligibility changes. This module does not interrupt HERMES,
implement ARQ, inspect payloads, create queues, grant custody, or prove receipt.
It cannot discover an Emergency on another channel. Clock ticks and decisions
are not RF metering evidence.

## Validation and remaining work

`cargo test --locked lease::tests` exercises independent durations/caps,
setup-to-normal transition, expiry, unused capacity, zero/full caps, background
yielding, Emergency handoff, early release, monotonic time and overrun accounting.
Tests use a supplied clock; no sleeps or hardware are required.

STATIC / UNIT is the acceptance class for this slice. Transport integration and
LIVE / PRODUCT / RF behavior are not established by these tests.

Local validation on Rust 1.98.1: `cargo test --locked` passed all 22 tests,
including nine lease tests. `rustfmt --edition 2021 --check src/lease.rs` passed.
The existing Phase 4J workflow runs the full suite and checks this module's format.

Remaining #22 work includes route-attempt backoff/progress admission, classification
and authenticated promotion, persistent account/peer fairness and custody limits,
restart/reconnect accounting, capacity policy integration, transport-safe dispatch
and resume, channel coordination and bounded single-radio Emergency discovery.
Do not recreate a controller on reconnect to mint a fresh allowance. Production
restart recovery requires the durable lease/service ledger, which is not present
in this slice. Initial operating defaults await measured transport behavior.
