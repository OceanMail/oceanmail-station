//! Bounded route-attempt admission, progress tracking, and backoff across
//! separate lease opportunities (ADR-008 follow-on; see
//! `docs/LEASE_CONTROLLER.md`: "Necessary route attempts require a separate
//! bounded admission, progress and backoff policy").
//!
//! `lease::LeaseController` already grants `Work::RouteSetup` the remaining
//! time of a single lease once a caller decides to attempt it. This module
//! decides, *across* many separate lease opportunities, whether that
//! attempt should be admitted at all: ADR-008 requires that "repeated
//! unsuccessful setup needs bounded attempts, progress evidence, and
//! backoff so an unreachable destination cannot consume successive leases
//! indefinitely."
//!
//! State is keyed by a caller-supplied [`RouteId`], not by connection or
//! session object identity, so reconnecting or constructing a new transport
//! connection to the same destination cannot itself reset accumulated
//! backoff. A caller that mints a fresh `RouteId` per connection attempt
//! defeats this by construction; that is a caller bug this module cannot
//! detect, which is why `RouteId` is documented as a stable logical
//! destination identity rather than a session/connection handle.
//!
//! This module holds no durable storage and has no memory across a process
//! restart. A freshly constructed [`RouteAttemptTracker`] starts every
//! route with a clean history; that is this module honestly reporting it
//! has no memory before its own construction, not amnesty for a route it
//! previously backed off. `docs/LEASE_CONTROLLER.md` already records
//! restart/reconnect accounting as open production work; a caller that
//! needs backoff to survive a restart must persist and restore this
//! tracker's state itself. Until it does, every attempt after a restart
//! passes through the same admission/backoff rules as any other, starting
//! from nothing — this module never assumes a route is safe merely because
//! its own history is empty.

use std::collections::HashMap;
use std::time::Duration;

/// Caller-defined stable identity for a logical destination/route. Must
/// stay the same across reconnects/new connection objects for the same
/// destination.
pub type RouteId = String;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AttemptPolicyError {
    ZeroBackoffBase,
    BackoffCapBelowBase,
}

/// Explicit, required tuning inputs. No default backoff schedule is
/// selected; operating values await measured transport behavior, matching
/// `lease::LeasePolicy`'s "no default duration" discipline.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct AttemptPolicy {
    backoff_base: Duration,
    backoff_cap: Duration,
}

impl AttemptPolicy {
    pub fn new(backoff_base: Duration, backoff_cap: Duration) -> Result<Self, AttemptPolicyError> {
        if backoff_base.is_zero() {
            return Err(AttemptPolicyError::ZeroBackoffBase);
        }
        if backoff_cap < backoff_base {
            return Err(AttemptPolicyError::BackoffCapBelowBase);
        }
        Ok(Self {
            backoff_base,
            backoff_cap,
        })
    }

    /// Doubling backoff bounded by `backoff_cap`. Bounded growth, never
    /// unbounded, never immediate re-admission after a real failure. Exits
    /// early once the cap is reached so an arbitrarily large failure count
    /// cannot turn this into an unbounded loop.
    fn backoff_for(&self, consecutive_failures: u32) -> Duration {
        let mut backoff = self.backoff_base;
        for _ in 1..consecutive_failures {
            if backoff >= self.backoff_cap {
                break;
            }
            backoff = backoff.saturating_mul(2);
        }
        backoff.min(self.backoff_cap)
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Admission {
    Admit,
    Deny { retry_not_before: Duration },
}

/// What happened after an admitted attempt. Reported once the attempt ends,
/// whether by success, explicit failure, lost route, or the enclosing lease
/// expiring with `Work::RouteSetup` still active.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AttemptOutcome {
    /// The attempt ended (failure or lease expiry) with no accepted
    /// evidence of forward progress.
    NoProgress,
    /// Forward progress with an opaque, caller-defined, strictly increasing
    /// marker (e.g. negotiation steps completed, bytes exchanged). A marker
    /// that does not strictly exceed the last accepted marker for this
    /// route is rejected as false/duplicate progress and treated exactly
    /// like `NoProgress` — this is the guard against a stalled attempt
    /// re-claiming the same partial progress forever to dodge backoff.
    Progress { marker: u64 },
    /// A usable route now exists. Clears all backoff state for this route.
    RouteEstablished,
    /// A previously established route is no longer usable. Setup may be
    /// attempted again, but this grants no amnesty: it does not reset
    /// `consecutive_failures` to anything other than what it already was
    /// (zero, since establishment last cleared it).
    RouteLost,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AttemptError {
    ClockWentBackwards,
}

#[derive(Clone, Debug, Default)]
struct RouteRecord {
    consecutive_failures: u32,
    blocked_until: Option<Duration>,
    last_progress_marker: Option<u64>,
    last_event_at: Option<Duration>,
}

/// Tracks admission/backoff state per [`RouteId`] under one [`AttemptPolicy`].
/// Supply injected monotonic time, exactly like `lease::LeaseController`; no
/// wall-clock or hardware access happens here.
#[derive(Debug)]
pub struct RouteAttemptTracker {
    policy: AttemptPolicy,
    routes: HashMap<RouteId, RouteRecord>,
}

impl RouteAttemptTracker {
    pub fn new(policy: AttemptPolicy) -> Self {
        Self {
            policy,
            routes: HashMap::new(),
        }
    }

    /// Whether a necessary-route-setup attempt for `route` may begin at
    /// `now`. A route with no recorded history is always admitted: absence
    /// of history is not evidence of unreachability.
    pub fn admit(&self, route: &str, now: Duration) -> Admission {
        match self
            .routes
            .get(route)
            .and_then(|record| record.blocked_until)
        {
            Some(until) if now < until => Admission::Deny {
                retry_not_before: until,
            },
            _ => Admission::Admit,
        }
    }

    /// Record what happened after an admitted attempt. Rejects a `now`
    /// earlier than this route's last recorded event instead of silently
    /// accepting it, matching `lease::LeaseController`'s monotonic-time
    /// discipline; the record is left unchanged on rejection.
    pub fn record_outcome(
        &mut self,
        route: RouteId,
        now: Duration,
        outcome: AttemptOutcome,
    ) -> Result<(), AttemptError> {
        let existing = self.routes.get(&route);
        if let Some(last) = existing.and_then(|record| record.last_event_at) {
            if now < last {
                return Err(AttemptError::ClockWentBackwards);
            }
        }

        let record = self.routes.entry(route).or_default();
        record.last_event_at = Some(now);

        match outcome {
            AttemptOutcome::RouteEstablished => {
                record.consecutive_failures = 0;
                record.blocked_until = None;
                record.last_progress_marker = None;
            }
            AttemptOutcome::RouteLost => {
                // No special-casing: consecutive_failures/blocked_until are
                // already whatever they were (zero, from the establishment
                // that preceded this loss). Losing a working route neither
                // punishes nor exempts the next setup attempt.
            }
            AttemptOutcome::Progress { marker } => {
                let is_real_progress = match record.last_progress_marker {
                    Some(last) => marker > last,
                    None => true,
                };
                if is_real_progress {
                    record.last_progress_marker = Some(marker);
                    record.consecutive_failures = 0;
                    record.blocked_until = None;
                } else {
                    record.consecutive_failures = record.consecutive_failures.saturating_add(1);
                    record.blocked_until =
                        Some(now + self.policy.backoff_for(record.consecutive_failures));
                }
            }
            AttemptOutcome::NoProgress => {
                record.consecutive_failures = record.consecutive_failures.saturating_add(1);
                record.blocked_until =
                    Some(now + self.policy.backoff_for(record.consecutive_failures));
            }
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn policy(base_ms: u64, cap_ms: u64) -> AttemptPolicy {
        AttemptPolicy::new(
            Duration::from_millis(base_ms),
            Duration::from_millis(cap_ms),
        )
        .unwrap()
    }

    fn d(ms: u64) -> Duration {
        Duration::from_millis(ms)
    }

    #[test]
    fn policy_rejects_zero_base_and_cap_below_base() {
        assert_eq!(
            AttemptPolicy::new(Duration::ZERO, d(10)),
            Err(AttemptPolicyError::ZeroBackoffBase)
        );
        assert_eq!(
            AttemptPolicy::new(d(10), d(9)),
            Err(AttemptPolicyError::BackoffCapBelowBase)
        );
        assert!(AttemptPolicy::new(d(10), d(10)).is_ok());
    }

    #[test]
    fn unknown_route_starts_admitted() {
        let tracker = RouteAttemptTracker::new(policy(100, 1_000));
        assert_eq!(tracker.admit("dest-a", d(0)), Admission::Admit);
    }

    #[test]
    fn repeated_failure_denies_during_backoff_and_grows_bounded_by_cap() {
        let mut tracker = RouteAttemptTracker::new(policy(100, 1_000));
        let route = "dest-a".to_string();

        tracker
            .record_outcome(route.clone(), d(0), AttemptOutcome::NoProgress)
            .unwrap();
        assert_eq!(
            tracker.admit(&route, d(50)),
            Admission::Deny {
                retry_not_before: d(100)
            }
        );
        assert_eq!(tracker.admit(&route, d(100)), Admission::Admit);

        tracker
            .record_outcome(route.clone(), d(100), AttemptOutcome::NoProgress)
            .unwrap();
        assert_eq!(
            tracker.admit(&route, d(100)),
            Admission::Deny {
                retry_not_before: d(300)
            }
        );

        tracker
            .record_outcome(route.clone(), d(300), AttemptOutcome::NoProgress)
            .unwrap();
        assert_eq!(
            tracker.admit(&route, d(300)),
            Admission::Deny {
                retry_not_before: d(700)
            }
        );

        // Many further consecutive failures must never exceed the cap.
        let mut now = d(700);
        for _ in 0..20 {
            tracker
                .record_outcome(route.clone(), now, AttemptOutcome::NoProgress)
                .unwrap();
            match tracker.admit(&route, now) {
                Admission::Deny { retry_not_before } => {
                    assert!(retry_not_before - now <= d(1_000));
                    now = retry_not_before;
                }
                Admission::Admit => panic!("route must remain backed off"),
            }
        }
    }

    #[test]
    fn expiry_with_no_progress_is_reported_as_failure() {
        // An adapter that let `Work::RouteSetup` run to `Decision::Expired`
        // without ever observing progress must report exactly this.
        let mut tracker = RouteAttemptTracker::new(policy(100, 1_000));
        let route = "dest-a".to_string();
        tracker
            .record_outcome(route.clone(), d(0), AttemptOutcome::NoProgress)
            .unwrap();
        assert_eq!(
            tracker.admit(&route, d(0)),
            Admission::Deny {
                retry_not_before: d(100)
            }
        );
    }

    #[test]
    fn success_clears_backoff_immediately() {
        let mut tracker = RouteAttemptTracker::new(policy(100, 1_000));
        let route = "dest-a".to_string();
        tracker
            .record_outcome(route.clone(), d(0), AttemptOutcome::NoProgress)
            .unwrap();
        tracker
            .record_outcome(route.clone(), d(0), AttemptOutcome::NoProgress)
            .unwrap();
        assert!(matches!(
            tracker.admit(&route, d(0)),
            Admission::Deny { .. }
        ));

        tracker
            .record_outcome(route.clone(), d(0), AttemptOutcome::RouteEstablished)
            .unwrap();
        assert_eq!(tracker.admit(&route, d(0)), Admission::Admit);
    }

    #[test]
    fn duplicate_and_non_advancing_progress_markers_are_false_progress() {
        let mut tracker = RouteAttemptTracker::new(policy(100, 1_000));
        let route = "dest-a".to_string();

        tracker
            .record_outcome(route.clone(), d(0), AttemptOutcome::Progress { marker: 5 })
            .unwrap();
        // First-ever marker is accepted as real progress: no backoff yet.
        assert_eq!(tracker.admit(&route, d(0)), Admission::Admit);

        // Repeating the same marker is a duplicate claim, not new progress.
        tracker
            .record_outcome(route.clone(), d(0), AttemptOutcome::Progress { marker: 5 })
            .unwrap();
        assert_eq!(
            tracker.admit(&route, d(0)),
            Admission::Deny {
                retry_not_before: d(100)
            }
        );

        // A marker that goes backward is also false progress, and stacks
        // onto the existing backoff rather than resetting it.
        tracker
            .record_outcome(
                route.clone(),
                d(100),
                AttemptOutcome::Progress { marker: 3 },
            )
            .unwrap();
        assert_eq!(
            tracker.admit(&route, d(100)),
            Admission::Deny {
                retry_not_before: d(300)
            }
        );
    }

    #[test]
    fn real_advancing_progress_resets_failure_count() {
        let mut tracker = RouteAttemptTracker::new(policy(100, 1_000));
        let route = "dest-a".to_string();

        tracker
            .record_outcome(route.clone(), d(0), AttemptOutcome::NoProgress)
            .unwrap();
        assert!(matches!(
            tracker.admit(&route, d(0)),
            Admission::Deny { .. }
        ));

        tracker
            .record_outcome(route.clone(), d(0), AttemptOutcome::Progress { marker: 1 })
            .unwrap();
        assert_eq!(tracker.admit(&route, d(0)), Admission::Admit);

        // A later strictly-greater marker is again real progress.
        tracker
            .record_outcome(route.clone(), d(0), AttemptOutcome::Progress { marker: 2 })
            .unwrap();
        assert_eq!(tracker.admit(&route, d(0)), Admission::Admit);
    }

    #[test]
    fn route_loss_grants_no_amnesty_beyond_prior_state() {
        let mut tracker = RouteAttemptTracker::new(policy(100, 1_000));
        let route = "dest-a".to_string();

        tracker
            .record_outcome(route.clone(), d(0), AttemptOutcome::RouteEstablished)
            .unwrap();
        tracker
            .record_outcome(route.clone(), d(0), AttemptOutcome::RouteLost)
            .unwrap();
        // Losing a working route does not itself deny the next attempt...
        assert_eq!(tracker.admit(&route, d(0)), Admission::Admit);

        // ...but subsequent failures back off exactly as if the route had
        // never been established, with no special exemption.
        tracker
            .record_outcome(route.clone(), d(0), AttemptOutcome::NoProgress)
            .unwrap();
        assert_eq!(
            tracker.admit(&route, d(0)),
            Admission::Deny {
                retry_not_before: d(100)
            }
        );
    }

    #[test]
    fn reconnecting_does_not_reset_allowance_for_the_same_route() {
        let mut tracker = RouteAttemptTracker::new(policy(100, 1_000));
        let route = "dest-a".to_string();
        let mut now = d(0);

        for expected_backoff_ms in [100, 200, 400, 800, 1_000, 1_000] {
            // Each iteration stands in for tearing down and constructing a
            // brand-new connection object before retrying; only `route`
            // (the logical destination identity) is reused.
            tracker
                .record_outcome(route.clone(), now, AttemptOutcome::NoProgress)
                .unwrap();
            assert_eq!(
                tracker.admit(&route, now),
                Admission::Deny {
                    retry_not_before: now + d(expected_backoff_ms)
                }
            );
            now += d(expected_backoff_ms);
        }
    }

    #[test]
    fn routes_are_independent() {
        let mut tracker = RouteAttemptTracker::new(policy(100, 1_000));
        tracker
            .record_outcome("dest-a".to_string(), d(0), AttemptOutcome::NoProgress)
            .unwrap();
        assert!(matches!(
            tracker.admit("dest-a", d(0)),
            Admission::Deny { .. }
        ));
        assert_eq!(tracker.admit("dest-b", d(0)), Admission::Admit);
    }

    #[test]
    fn clock_going_backwards_is_rejected_and_state_is_unchanged() {
        let mut tracker = RouteAttemptTracker::new(policy(100, 1_000));
        let route = "dest-a".to_string();
        tracker
            .record_outcome(route.clone(), d(100), AttemptOutcome::NoProgress)
            .unwrap();
        assert_eq!(
            tracker.record_outcome(route.clone(), d(50), AttemptOutcome::RouteEstablished),
            Err(AttemptError::ClockWentBackwards)
        );
        // The rejected call must not have applied RouteEstablished's reset.
        assert_eq!(
            tracker.admit(&route, d(100)),
            Admission::Deny {
                retry_not_before: d(200)
            }
        );
    }

    #[test]
    fn a_fresh_tracker_has_no_memory_of_a_prior_process() {
        // Documents the restart contract: nothing here claims durable
        // cross-restart backoff. A caller needing that must persist and
        // restore state itself; this module never invents leniency.
        let mut before_restart = RouteAttemptTracker::new(policy(100, 1_000));
        before_restart
            .record_outcome("dest-a".to_string(), d(0), AttemptOutcome::NoProgress)
            .unwrap();
        assert!(matches!(
            before_restart.admit("dest-a", d(0)),
            Admission::Deny { .. }
        ));

        let after_restart = RouteAttemptTracker::new(policy(100, 1_000));
        assert_eq!(after_restart.admit("dest-a", d(0)), Admission::Admit);
    }
}
