//! In-memory GRID/CONTROL lease policy; no transport, authorization, or queues.
//!
//! All demand is already admitted by the caller (including permission, capacity,
//! recipient selection and route eligibility). Decisions are scheduling advice,
//! never RF permission or evidence of transmission. Call at safe transport
//! boundaries and on eligibility changes; essential ACK/teardown belongs to the
//! active exchange. The adapter must bound batches and reserve teardown time.

use std::time::Duration;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LeaseError {
    ZeroDuration,
    ControlCapExceedsLease,
    ClockWentBackwards,
}

/// Independent tuning inputs. No default duration or percentage is imposed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct LeasePolicy {
    duration: Duration,
    control_cap: Duration,
}

impl LeasePolicy {
    pub fn new(duration: Duration, control_cap: Duration) -> Result<Self, LeaseError> {
        if duration.is_zero() {
            return Err(LeaseError::ZeroDuration);
        }
        if control_cap > duration {
            return Err(LeaseError::ControlCapExceedsLease);
        }
        Ok(Self {
            duration,
            control_cap,
        })
    }
}

/// Trusted internal inputs, not deserialized client flags. False is fail-closed.
#[derive(Clone, Copy, Debug, Default)]
pub struct EligibleWork {
    pub emergency: bool,
    /// Only necessary setup admitted by a separate bounded-attempt/backoff policy.
    /// Must become false as soon as a usable route exists. Routine control and
    /// promoted shared updates must never set this flag.
    pub necessary_route_setup: bool,
    pub control: bool,
    pub payload: bool,
    pub background: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Work {
    RouteSetup,
    Control,
    Payload,
    Background,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Decision {
    /// Yield the ordinary lease to the separately authorized Emergency coordinator.
    /// This is not an unbounded transmit grant or cross-channel discovery proof.
    Emergency,
    Run {
        work: Work,
        max_duration: Duration,
    },
    Release,
    Expired,
}

/// One finite opportunity. Supply monotonic elapsed time since its agreed start,
/// including negotiation, switching, waits, retries and ACKs. Never reconstruct
/// this object on reconnect to renew the same opportunity. Restart reconciliation
/// and persistent service ledgers are outside this first policy slice.
#[derive(Debug)]
pub struct LeaseController {
    policy: LeasePolicy,
    last_elapsed: Duration,
    control_used: Duration,
    active: Option<Work>,
    released: bool,
}

impl LeaseController {
    pub fn new(policy: LeasePolicy) -> Self {
        Self {
            policy,
            last_elapsed: Duration::ZERO,
            control_used: Duration::ZERO,
            active: None,
            released: false,
        }
    }

    /// Actual elapsed Band 1 occupancy reported at decision boundaries, including
    /// setup and its overhead. An overrun is counted, not hidden by cap clipping.
    pub fn control_used(&self) -> Duration {
        self.control_used
    }

    pub fn decide(
        &mut self,
        elapsed: Duration,
        eligible: EligibleWork,
    ) -> Result<Decision, LeaseError> {
        let delta = elapsed
            .checked_sub(self.last_elapsed)
            .ok_or(LeaseError::ClockWentBackwards)?;
        if matches!(self.active, Some(Work::Control | Work::RouteSetup)) {
            self.control_used = self.control_used.saturating_add(delta);
        }
        self.last_elapsed = elapsed;
        self.active = None;

        // Emergency is a handoff outside ordinary lease budgeting, including
        // after expiry/release. It never renews the ordinary lease deadline.
        if eligible.emergency {
            return Ok(Decision::Emergency);
        }
        if elapsed >= self.policy.duration {
            return Ok(Decision::Expired);
        }
        if self.released {
            return Ok(Decision::Release);
        }
        let remaining = self.policy.duration - elapsed;
        let control_remaining = self.policy.control_cap.saturating_sub(self.control_used);
        let (work, max_duration) = if eligible.necessary_route_setup {
            (Work::RouteSetup, remaining)
        } else if eligible.control && !control_remaining.is_zero() {
            (Work::Control, remaining.min(control_remaining))
        } else if eligible.payload {
            (Work::Payload, remaining)
        } else if eligible.background {
            (Work::Background, remaining)
        } else {
            self.released = true;
            return Ok(Decision::Release);
        };
        self.active = Some(work);
        Ok(Decision::Run { work, max_duration })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(ms: u64) -> Duration {
        Duration::from_millis(ms)
    }
    fn lease(length: u64, cap: u64) -> LeaseController {
        LeaseController::new(LeasePolicy::new(d(length), d(cap)).unwrap())
    }
    fn run(work: Work, ms: u64) -> Decision {
        Decision::Run {
            work,
            max_duration: d(ms),
        }
    }
    fn ordinary() -> EligibleWork {
        EligibleWork {
            control: true,
            payload: true,
            background: true,
            ..Default::default()
        }
    }

    #[test]
    fn independent_caps_and_lengths() {
        for (length, cap) in [(600_000, 240_000), (90_000, 7_000), (1_000, 900), (7, 2)] {
            let mut c = lease(length, cap);
            assert_eq!(c.decide(d(0), ordinary()), Ok(run(Work::Control, cap)));
            assert_eq!(
                c.decide(d(cap), ordinary()),
                Ok(run(Work::Payload, length - cap))
            );
            assert_eq!(c.decide(d(length), ordinary()), Ok(Decision::Expired));
        }
    }

    #[test]
    fn unused_control_and_no_background_reservation() {
        let mut c = lease(100, 40);
        c.decide(d(0), ordinary()).unwrap();
        let payload = EligibleWork {
            payload: true,
            background: true,
            ..Default::default()
        };
        assert_eq!(c.decide(d(9), payload), Ok(run(Work::Payload, 91)));
        assert_eq!(c.control_used(), d(9));
        let mut c = lease(100, 40);
        assert_eq!(c.decide(d(0), payload), Ok(run(Work::Payload, 100)));
    }

    #[test]
    fn setup_counts_toward_cap_and_yields_at_expiry() {
        for setup_time in [10, 70] {
            let mut c = lease(100, 40);
            let setup = EligibleWork {
                necessary_route_setup: true,
                ..ordinary()
            };
            assert_eq!(c.decide(d(0), setup), Ok(run(Work::RouteSetup, 100)));
            let expected = if setup_time < 40 {
                run(Work::Control, 40 - setup_time)
            } else {
                run(Work::Payload, 100 - setup_time)
            };
            assert_eq!(c.decide(d(setup_time), ordinary()), Ok(expected));
            assert_eq!(c.control_used(), d(setup_time));
            assert_eq!(c.decide(d(100), setup), Ok(Decision::Expired));
        }
    }

    #[test]
    fn emergency_preempts_every_kind_without_renewal() {
        for input in [
            EligibleWork {
                necessary_route_setup: true,
                ..Default::default()
            },
            EligibleWork {
                control: true,
                ..Default::default()
            },
            EligibleWork {
                payload: true,
                ..Default::default()
            },
            EligibleWork {
                background: true,
                ..Default::default()
            },
        ] {
            let mut c = lease(100, 40);
            c.decide(d(0), input).unwrap();
            let emergency = EligibleWork {
                emergency: true,
                ..ordinary()
            };
            assert_eq!(c.decide(d(10), emergency), Ok(Decision::Emergency));
            assert_eq!(c.decide(d(100), emergency), Ok(Decision::Emergency));
            assert_eq!(c.decide(d(101), ordinary()), Ok(Decision::Expired));
        }
    }

    #[test]
    fn emergency_does_not_consume_control_cap() {
        let mut c = lease(100, 40);
        c.decide(d(0), ordinary()).unwrap();
        c.decide(
            d(10),
            EligibleWork {
                emergency: true,
                ..Default::default()
            },
        )
        .unwrap();
        assert_eq!(c.decide(d(30), ordinary()), Ok(run(Work::Control, 30)));
        assert_eq!(c.control_used(), d(10));
    }

    #[test]
    fn release_is_terminal_but_emergency_handoff_remains_possible() {
        let mut c = lease(100, 40);
        assert_eq!(
            c.decide(d(0), EligibleWork::default()),
            Ok(Decision::Release)
        );
        assert_eq!(c.decide(d(1), ordinary()), Ok(Decision::Release));
        assert_eq!(
            c.decide(
                d(2),
                EligibleWork {
                    emergency: true,
                    ..Default::default()
                }
            ),
            Ok(Decision::Emergency)
        );
        assert_eq!(c.decide(d(3), ordinary()), Ok(Decision::Release));
    }

    #[test]
    fn background_only_uses_eligible_idle_time_and_yields_to_payload() {
        let mut c = lease(100, 40);
        assert_eq!(
            c.decide(
                d(5),
                EligibleWork {
                    background: true,
                    ..Default::default()
                }
            ),
            Ok(run(Work::Background, 95))
        );
        assert_eq!(
            c.decide(
                d(20),
                EligibleWork {
                    payload: true,
                    background: true,
                    ..Default::default()
                }
            ),
            Ok(run(Work::Payload, 80))
        );
    }

    #[test]
    fn clock_rejection_is_atomic_and_overhead_and_overrun_are_counted() {
        let mut c = lease(100, 40);
        assert_eq!(c.decide(d(10), ordinary()), Ok(run(Work::Control, 40)));
        assert_eq!(
            c.decide(d(9), ordinary()),
            Err(LeaseError::ClockWentBackwards)
        );
        assert_eq!(c.decide(d(60), ordinary()), Ok(run(Work::Payload, 40)));
        assert_eq!(c.control_used(), d(50));
        assert_eq!(c.decide(d(60), ordinary()), Ok(run(Work::Payload, 40)));
        assert_eq!(c.control_used(), d(50));
    }

    #[test]
    fn validates_policy_and_supports_zero_and_full_caps() {
        assert_eq!(LeasePolicy::new(d(0), d(0)), Err(LeaseError::ZeroDuration));
        assert_eq!(
            LeasePolicy::new(d(10), d(11)),
            Err(LeaseError::ControlCapExceedsLease)
        );
        assert_eq!(
            lease(10, 0).decide(d(0), ordinary()),
            Ok(run(Work::Payload, 10))
        );
        assert_eq!(
            lease(10, 10).decide(d(0), ordinary()),
            Ok(run(Work::Control, 10))
        );
    }
}
