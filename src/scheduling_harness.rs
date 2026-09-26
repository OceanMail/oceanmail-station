//! No-radio scheduling harness (ADR-008 follow-on): a deterministic,
//! fake-clock adapter that ties `classify`, `route_admission`,
//! `band2_fairness` and `lease::LeaseController` together for
//! scenario-driven exercise and machine-readable evidence.
//!
//! **Explicitly experimental.** This module is never referenced from
//! `main.rs` or the Axum router, and nothing here dispatches to a real
//! daemon, transport, or RF adapter. A scenario is a fixed sequence of
//! synthetic ticks against an injected `Duration` clock; every tick's
//! demand is scripted by the caller, never observed from real queues or
//! real time. Selected/measured durations in a produced `Trace` are
//! simulation bookkeeping, not RF airtime evidence — do not describe a
//! run of this harness as transport, throughput, or scheduler field
//! evidence (see AGENTS.md's evidence-truthfulness rules).
//!
//! A scenario may carry a `capacity_tier_label`
//! (`docs/decisions/ADR-007-hf-link-capacity-tiers-and-survival-mode.md`)
//! purely as evidence metadata echoed into the trace. This harness does
//! **not** implement ADR-007's tier-based eligibility/cost gating; a
//! "survival" label documents a scenario author's assumption, not an
//! enforced rule. Capacity-tier eligibility remains separate, outstanding
//! work.
//!
//! Each tick's `WorkKind`s are run through the real `classify::classify`,
//! not hand-built `TrafficClass` values, so this harness actually
//! exercises the classification boundary rather than assuming its
//! correctness. Likewise `Work::Payload` turns are handed to the real
//! `band2_fairness::select_band2`, and any tick scripted as concluding a
//! route-setup attempt reports its outcome to the real
//! `route_admission::RouteAttemptTracker`, exactly as
//! `route_admission`'s own module docs require of an adapter.
//!
//! An adapter is also responsible for safe bounded batches and reserving
//! essential ACK/teardown time out of a granted `Work::Payload` turn
//! (`docs/LEASE_CONTROLLER.md`); this harness does that via
//! `teardown_reserve`, and never hands `band2_fairness` more than
//! `max_duration - teardown_reserve` as spendable budget.

use crate::band2_fairness::{self, FairnessLedger, Item as Band2Item, Selection, SelectionPolicy};
use crate::classify::{self, AuthorizedEmergency, Candidate, ServerPromotion, WorkKind};
use crate::lease::{Decision, LeaseController, LeasePolicy, Work};
use crate::route_admission::{
    Admission, AttemptOutcome, AttemptPolicy, RouteAttemptTracker, RouteId,
};
use serde::Serialize;
use std::time::Duration;

/// One synthetic tick's demand. Entirely caller-scripted.
#[derive(Default)]
pub struct Tick {
    pub elapsed: Duration,
    pub work_kinds: Vec<(WorkKind, Option<ServerPromotion>)>,
    pub emergency: Option<AuthorizedEmergency>,
    pub band2_items: Vec<Band2Item>,
    /// If this tick concludes an admitted route-setup attempt (by success,
    /// failure, or the lease expiring while it was active), the scenario
    /// must say what happened so `route_admission` accounting reflects
    /// reality instead of silently assuming success. Keyed by the same
    /// `RouteId` the scenario used when checking `Harness::admit_route`.
    pub route_outcome: Option<(RouteId, AttemptOutcome)>,
}

#[derive(Debug, Serialize)]
pub struct TraceEvent {
    pub tick: usize,
    pub elapsed_ms: u64,
    pub decision: String,
    pub max_duration_ms: Option<u64>,
    pub teardown_reserved_ms: u64,
    pub band2_selected: Vec<String>,
    pub band2_used_ms: u64,
    pub band2_any_estimated: bool,
    pub control_used_ms: u64,
    pub route_outcome_note: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Trace {
    pub capacity_tier_label: &'static str,
    pub events: Vec<TraceEvent>,
}

impl Trace {
    /// Machine-readable rendering (ADR-008 acceptance: "Produce
    /// machine-readable traces"). Never fails on well-formed `Trace` data;
    /// falls back to an empty array only if serialization itself errors,
    /// which does not happen for this plain-data shape.
    pub fn to_json(&self) -> String {
        serde_json::to_string_pretty(self).unwrap_or_else(|_| "[]".to_string())
    }
}

fn ms(duration: Duration) -> u64 {
    duration.as_millis().min(u64::MAX as u128) as u64
}

/// Experimental no-radio scheduling adapter. See module docs: not wired to
/// any daemon or transport, and produces no production dispatch.
pub struct Harness {
    lease: LeaseController,
    band2_ledger: FairnessLedger,
    band2_policy: SelectionPolicy,
    routes: RouteAttemptTracker,
    teardown_reserve: Duration,
}

impl Harness {
    pub fn new(
        lease_policy: LeasePolicy,
        band2_policy: SelectionPolicy,
        route_policy: AttemptPolicy,
        teardown_reserve: Duration,
    ) -> Self {
        Self {
            lease: LeaseController::new(lease_policy),
            band2_ledger: FairnessLedger::new(),
            band2_policy,
            routes: RouteAttemptTracker::new(route_policy),
            teardown_reserve,
        }
    }

    /// Whether a necessary-route-setup attempt for `route` may be presented
    /// as eligible this tick. A scenario should gate its own
    /// `WorkKind::NecessaryRouteSetup` entries on this, exactly as a real
    /// caller must (see `route_admission` module docs).
    pub fn admit_route(&self, route: &str, now: Duration) -> Admission {
        self.routes.admit(route, now)
    }

    pub fn control_used(&self) -> Duration {
        self.lease.control_used()
    }

    /// Run a fixed, caller-scripted scenario to completion and return its
    /// machine-readable trace. Nothing here reads real time or real state.
    pub fn run(&mut self, capacity_tier_label: &'static str, ticks: Vec<Tick>) -> Trace {
        let mut events = Vec::with_capacity(ticks.len());

        for (index, tick) in ticks.into_iter().enumerate() {
            let elapsed = tick.elapsed;

            let mut candidates: Vec<Candidate> = tick
                .work_kinds
                .iter()
                .filter_map(|(kind, promotion)| classify::classify(kind, promotion.as_ref()).ok())
                .map(Candidate::Classified)
                .collect();
            if let Some(evidence) = tick.emergency {
                candidates.push(Candidate::Emergency(evidence));
            }
            let eligible = classify::eligible_work(&candidates);

            let decision = self.lease.decide(elapsed, eligible);

            let mut event = TraceEvent {
                tick: index,
                elapsed_ms: ms(elapsed),
                decision: String::new(),
                max_duration_ms: None,
                teardown_reserved_ms: 0,
                band2_selected: Vec::new(),
                band2_used_ms: 0,
                band2_any_estimated: false,
                control_used_ms: ms(self.lease.control_used()),
                route_outcome_note: None,
            };

            match decision {
                Ok(Decision::Run { work, max_duration }) => {
                    event.decision = format!("{work:?}");
                    event.max_duration_ms = Some(ms(max_duration));

                    if work == Work::Payload && !tick.band2_items.is_empty() {
                        let reserve = self.teardown_reserve.min(max_duration);
                        let usable = max_duration - reserve;
                        event.teardown_reserved_ms = ms(reserve);

                        let Selection {
                            selected,
                            used,
                            any_estimated,
                        } = band2_fairness::select_band2(
                            &mut self.band2_ledger,
                            &self.band2_policy,
                            tick.band2_items,
                            usable,
                        );
                        event.band2_selected = selected;
                        event.band2_used_ms = ms(used);
                        event.band2_any_estimated = any_estimated;
                    }
                }
                Ok(Decision::Emergency) => event.decision = "Emergency".to_string(),
                Ok(Decision::Release) => event.decision = "Release".to_string(),
                Ok(Decision::Expired) => event.decision = "Expired".to_string(),
                Err(err) => event.decision = format!("Error({err:?})"),
            }

            if let Some((route, outcome)) = tick.route_outcome {
                event.route_outcome_note = Some(format!("{route}:{outcome:?}"));
                // A tick that scripts a route outcome without the lease
                // actually having run RouteSetup this tick is a scenario
                // authoring bug; recording is unconditional so the trace
                // still shows exactly what was asserted, and the result is
                // still checked here so a broken scenario fails loudly.
                self.routes
                    .record_outcome(route, elapsed, outcome)
                    .expect("scenario route outcome must be chronologically valid");
            }

            events.push(event);
        }

        Trace {
            capacity_tier_label,
            events,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::band2_fairness::{AirtimeCost, Group, Item, ItemKind, Scope};

    fn harness(lease_ms: u64, cap_ms: u64, teardown_ms: u64) -> Harness {
        Harness::new(
            LeasePolicy::new(
                Duration::from_millis(lease_ms),
                Duration::from_millis(cap_ms),
            )
            .unwrap(),
            SelectionPolicy::new(1, 1, 10).unwrap(),
            AttemptPolicy::new(Duration::from_millis(50), Duration::from_millis(500)).unwrap(),
            Duration::from_millis(teardown_ms),
        )
    }

    fn tick(elapsed_ms: u64) -> Tick {
        Tick {
            elapsed: Duration::from_millis(elapsed_ms),
            ..Default::default()
        }
    }

    fn body_item(id: &str, cost_ms: u64) -> Item {
        Item {
            id: id.to_string(),
            scope: Scope {
                group: Group::Local,
                identity: "acct-a".to_string(),
            },
            message_id: id.to_string(),
            kind: ItemKind::Body,
            cost: AirtimeCost::Measured(Duration::from_millis(cost_ms)),
            recipient_order: 0,
            important: false,
            body_already_present: false,
        }
    }

    #[test]
    fn full_lease_necessary_route_setup_then_backoff_on_expiry() {
        let mut h = harness(1_000, 400, 50);
        let route: RouteId = "dest-a".to_string();
        assert_eq!(h.admit_route(&route, Duration::ZERO), Admission::Admit);

        let mut t0 = tick(0);
        t0.work_kinds.push((WorkKind::NecessaryRouteSetup, None));
        let mut t1 = tick(1_000);
        t1.work_kinds.push((WorkKind::NecessaryRouteSetup, None));
        t1.route_outcome = Some((route.clone(), AttemptOutcome::NoProgress));

        let trace = h.run("normal-tier3", vec![t0, t1]);
        assert_eq!(trace.events[0].decision, "RouteSetup");
        assert_eq!(trace.events[0].max_duration_ms, Some(1_000));
        assert_eq!(trace.events[1].decision, "Expired");

        assert!(matches!(
            h.admit_route(&route, Duration::from_millis(1_000)),
            Admission::Deny { .. }
        ));
    }

    #[test]
    fn control_cap_then_falls_through_to_payload_with_band2_selection() {
        let mut h = harness(100, 40, 5);
        let mut t0 = tick(0);
        t0.work_kinds.push((WorkKind::GridDiscovery, None));
        t0.work_kinds.push((WorkKind::AccountMailControl, None));
        t0.band2_items = vec![body_item("m1", 10)];

        let mut t1 = tick(40);
        t1.work_kinds.push((WorkKind::GridDiscovery, None));
        t1.work_kinds.push((WorkKind::AccountMailControl, None));
        t1.band2_items = vec![body_item("m2", 10)];

        let trace = h.run("normal-tier3", vec![t0, t1]);
        assert_eq!(trace.events[0].decision, "Control");
        assert_eq!(trace.events[0].max_duration_ms, Some(40));
        assert!(trace.events[0].band2_selected.is_empty());

        assert_eq!(trace.events[1].decision, "Payload");
        assert_eq!(trace.events[1].max_duration_ms, Some(60));
        assert_eq!(trace.events[1].teardown_reserved_ms, 5);
        assert_eq!(trace.events[1].band2_selected, vec!["m2"]);
    }

    #[test]
    fn nothing_eligible_releases_before_lease_duration() {
        let mut h = harness(1_000, 400, 0);
        let trace = h.run("normal-tier3", vec![tick(0)]);
        assert_eq!(trace.events[0].decision, "Release");
        assert!(trace.events[0].elapsed_ms < 1_000);
    }

    #[test]
    fn emergency_handoff_and_return_preserves_control_accounting() {
        let mut h = harness(1_000, 400, 0);

        let mut t0 = tick(0);
        t0.work_kinds.push((WorkKind::GridDiscovery, None));
        let mut t1 = tick(30);
        t1.emergency = Some(AuthorizedEmergency::already_authorized_elsewhere());
        let mut t2 = tick(200);
        t2.emergency = Some(AuthorizedEmergency::already_authorized_elsewhere());
        let mut t3 = tick(250);
        t3.work_kinds.push((WorkKind::GridDiscovery, None));

        let trace = h.run("normal-tier3", vec![t0, t1, t2, t3]);
        assert_eq!(trace.events[0].decision, "Control");
        assert_eq!(trace.events[1].decision, "Emergency");
        assert_eq!(trace.events[2].decision, "Emergency");
        assert_eq!(trace.events[3].decision, "Control");

        // Only the real Band 1 occupancy (0..30ms) counts; the Emergency
        // detour (30..250ms) neither resets nor inflates control_used, and
        // the ordinary lease deadline (1000ms) is unaffected by it either:
        // remaining lease (1000-250=750ms) is still capped by what's left
        // of the 400ms control cap after the genuine 30ms already spent
        // (400-30=370ms), not reset to a fresh 400ms by the detour.
        assert_eq!(h.control_used(), Duration::from_millis(30));
        assert_eq!(trace.events[3].max_duration_ms, Some(370));
    }

    #[test]
    fn band3_yields_the_instant_higher_bands_become_eligible() {
        let mut h = harness(1_000, 400, 0);
        let mut t0 = tick(0);
        t0.work_kinds.push((WorkKind::BackgroundBroadcast, None));
        let mut t1 = tick(10);
        t1.work_kinds.push((WorkKind::BackgroundBroadcast, None));
        t1.work_kinds.push((WorkKind::AccountMailPayload, None));

        let trace = h.run("normal-tier3", vec![t0, t1]);
        assert_eq!(trace.events[0].decision, "Background");
        assert_eq!(trace.events[1].decision, "Payload");
    }

    #[test]
    fn teardown_reserve_is_never_handed_to_band2_selection() {
        let mut h = harness(1_000, 0, 20);
        let mut t0 = tick(0);
        t0.work_kinds.push((WorkKind::AccountMailPayload, None));
        t0.band2_items = vec![body_item("big", 995)];

        let trace = h.run("normal-tier3", vec![t0]);
        assert_eq!(trace.events[0].decision, "Payload");
        assert_eq!(trace.events[0].teardown_reserved_ms, 20);
        // The 995ms item cannot fit in the 980ms usable budget, so nothing
        // is selected — proving the reserve was actually withheld rather
        // than merely reported.
        assert!(trace.events[0].band2_selected.is_empty());
    }

    #[test]
    fn server_promotion_without_evidence_is_ineligible_end_to_end() {
        let mut h = harness(100, 40, 0);
        let mut t0 = tick(0);
        t0.work_kinds.push((WorkKind::ServerPromotedUpdate, None));
        let trace = h.run("normal-tier3", vec![t0]);
        assert_eq!(trace.events[0].decision, "Release");
    }

    #[test]
    fn server_promotion_with_evidence_reaches_band1() {
        let mut h = harness(100, 40, 0);
        let promotion = ServerPromotion::already_authenticated_elsewhere();
        let mut t0 = tick(0);
        t0.work_kinds
            .push((WorkKind::ServerPromotedUpdate, Some(promotion)));
        let trace = h.run("normal-tier3", vec![t0]);
        assert_eq!(trace.events[0].decision, "Control");
    }

    #[test]
    fn trace_serializes_to_machine_readable_json() {
        let mut h = harness(100, 40, 0);
        let mut t0 = tick(0);
        t0.work_kinds.push((WorkKind::AccountMailControl, None));
        t0.band2_items = vec![body_item("m1", 5)];
        let trace = h.run("survival-tier0-label-only", vec![t0]);

        let json = trace.to_json();
        let value: serde_json::Value = serde_json::from_str(&json).expect("valid JSON");
        assert_eq!(value["capacity_tier_label"], "survival-tier0-label-only");
        assert_eq!(value["events"][0]["decision"], "Payload");
        assert_eq!(value["events"][0]["band2_selected"][0], "m1");
    }
}
