# Configurable lease controller and ADR-008 follow-on slices

`src/lease.rs` implements a deterministic, in-memory GRID/CONTROL policy module.
`src/classify.rs`, `src/route_admission.rs`, `src/band2_fairness.rs`, and
`src/scheduling_harness.rs` are the follow-on slices described below. All five
are exported by the Station library but none is wired into the daemon or an RF
adapter.

The initial lease controller and subsequent classification/admission/fairness
modules are present in public source. Track remaining production integration work
in public issues; the implementation and test boundaries below remain explicit.

Authority: [ADR-008](https://github.com/OceanMail/oceanmail-project/blob/main/docs/decisions/ADR-008-four-band-scheduling-and-channel-use.md).
Ten/four minutes are arithmetic examples, not selected defaults.
`LeasePolicy::new(duration, control_cap)` requires independent explicit values.
There is no default duration, fixed 40% relationship, or wire constant.
Zero control allowance and a full-lease control allowance are supported;
zero-length leases and caps exceeding their lease are rejected.

## Behavior and caller contract

- Supply monotonic elapsed time from the agreed opportunity start. Delays and
  negotiation/switching/ACK/retry overhead consume the opportunity too.
- Each decision accounts elapsed time since the preceding decision against its
  selected work. Band 1 setup counts toward the normal cap; establishing a route
  does not reset the allowance. Late adapter calls count actual overruns.
- Route setup can use the remaining lease only while separately admitted as
  necessary. Routine Grid/topology manifests and Server-promoted updates use
  normal control (Band 1). Ordinary per-account mail manifests/receipts are a
  different "manifest" in ADR-008/ADR-009 prose and never use this control
  budget — see `classify.rs` below, which makes the two kinds of "manifest"
  distinct closed-set variants instead of one ambiguous label.
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

## Traffic classification (`classify.rs`)

Maps typed traffic — public Grid coordination, ordinary account mail
control/payload, background broadcasts, and already-authorized Emergency —
onto `lease::EligibleWork`. This is the only place Station should construct a
real `EligibleWork`. `WorkKind::Unclassified` and a `ServerPromotedUpdate`
missing its `ServerPromotion` evidence both fail closed to ineligible rather
than defaulting into some band. `AuthorizedEmergency` and `ServerPromotion`
are opaque, non-deserializable marker types: a client-suppliable flag alone
can never confer Band 1 Server promotion or Band 0 Emergency eligibility, and
neither type implements the production authentication/authorization check
itself (there is none yet).

## Bounded route-attempt admission and backoff (`route_admission.rs`)

Tracks, per caller-stable `RouteId`, whether a `NecessaryRouteSetup` attempt
should be admitted at all — separate from `lease.rs`'s per-opportunity time
grant. Consecutive no-progress/false-progress outcomes back off (doubling,
capped, explicit required tuning); real strictly-advancing progress resets
the count; losing a previously-established route grants no amnesty. State is
keyed by `RouteId`, not connection identity, so reconnecting does not reset
allowance, and the tracker has no memory across a process restart — that is
stated as an honest limitation, not silently assumed safe.

## Band 2 fair selection (`band2_fairness.rs`)

Given an already-admitted/classified candidate list and a `Work::Payload`
turn, selects which items run and in what order, two-level: local-vs-relay
**group** share first (compared by each group's own aggregate decayed
usage, so the number of identities active in a group cannot change its
share), then per-account/per-peer share within whichever group is due
(equal in-group weight, ADR-008's "initial policy"). An idle scope/group
simply never competes, so its capacity is used by whichever scope is
ready, with no separate reallocation step. Usage decays linearly with real
idle time (one nanosecond of accrued weighted usage forgiven per
nanosecond untouched, floored at zero), so a scope that used substantial
airtime long ago and then went idle is not stuck behind smaller,
currently-active competitors forever — real aging, not just "never accrues
more". Within a scope: recipient Available order, with body-before-
attachment enforced even against a misordered `recipient_order`; an
explicit `Measured`/`Estimated` distinction on every item's airtime cost so
a turn's reported `used` total is never reported as fully measured when it
is not. The `FairnessLedger` persists decayed usage across calls (separate
leases), which is what keeps a large backlog or an immediate reconnect from
buying a scope more than its fair share — see the module's own tests for
worked examples, including the exact scenarios an automated PR review
([chatgpt-codex-connector] on
[oceanmail-station#1](https://github.com/OceanMail/oceanmail-station/pull/1))
found broken in an earlier version of this module (flat per-scope
comparison instead of group-then-scope, and usage that never decayed).

## No-radio scheduling harness (`scheduling_harness.rs`)

Explicitly experimental integration/test scaffolding — not referenced from
`main.rs` or the Axum router, and dispatches nothing to a real daemon or
transport. Runs a fixed, fully caller-scripted sequence of ticks against an
injected clock through the real `classify`/`lease`/`route_admission`/
`band2_fairness` APIs (not hand-built shortcuts around them) and produces a
serializable `Trace` (`Trace::to_json`). A scenario may carry a
`capacity_tier_label` string as evidence metadata only; this harness does
not implement ADR-007's capacity-tier eligibility/cost gating, so the label
records a scenario author's assumption, not an enforced rule.

Route-setup admission is enforced by the harness itself, not left to a
scenario author to remember: `Tick::route_setup_candidate` names a route,
and `Harness::run` checks `RouteAttemptTracker::admit` for it before
classification; a bare `WorkKind::NecessaryRouteSetup` placed directly in
`Tick::work_kinds` is dropped rather than honored. An earlier version left
this unchecked, so a scenario could show a backed-off route still winning
lease turns — also found by the automated review on
[oceanmail-station#1](https://github.com/OceanMail/oceanmail-station/pull/1),
fixed the same way as the fairness findings above: reproduced first
(`a_backed_off_route_cannot_win_a_lease_turn_either_path`), then corrected.

## Validation and remaining work

`cargo test --locked` exercises independent durations/caps, setup-to-normal
transition, expiry, unused capacity, zero/full caps, background yielding,
Emergency handoff, early release, monotonic time and overrun accounting
(`lease::tests`); classification fail-closed/evidence-required behavior
(`classify::tests`); repeated failure/expiry/success/false-progress/route-loss/
reconnect backoff (`route_admission::tests`); local-vs-relay and
account/peer fairness, aging, idle-share reuse, body-before-attachment, and
measured-vs-estimated accounting (`band2_fairness::tests`); and end-to-end
composed scenarios covering full-lease route setup with backoff on expiry,
the control cap falling through to a Band 2 selection, early release,
Emergency handoff/return without resetting control accounting, Band 3
yielding, teardown-reserve enforcement, and Server-promotion evidence
(`scheduling_harness::tests`). Tests use a supplied clock; no sleeps or
hardware are required.

STATIC / UNIT is the acceptance class for all five modules. Transport
integration and LIVE / PRODUCT / RF behavior are not established by these
tests; a `scheduling_harness` trace is simulation bookkeeping, not RF
airtime evidence.

Local validation on Rust 1.94.1 (CI pins 1.98.1): `cargo test --locked`
passed all 70 tests. `rustfmt --edition 2021 --check` passed for all five
files; `cargo clippy --all-targets --locked` reported no new warnings from
them. The existing Phase 4J workflow runs the full suite and checks each new
file's format alongside `auth.rs`/`lease.rs`.

Remaining follow-on work: persistent (restart-durable) fairness/backoff
storage — everything above is explicitly in-memory-only and says so;
capacity-tier (ADR-007) integration into classification/cost, which does not
exist yet; authenticated Server-promotion and Emergency-authorization
implementations, which `classify.rs` deliberately stops short of (it only
keeps a client flag from forging them); real channel coordination and
bounded single-radio Emergency discovery across channels; and actual
transport-safe dispatch/resume wiring a real adapter would need beyond this
harness's synthetic ticks. Do not recreate any of these trackers'/ledgers'
state on reconnect to mint a fresh allowance — none of the four new modules
do, and their tests assert it.
