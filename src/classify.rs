//! Traffic classification at the scheduler boundary (ADR-008/ADR-009
//! follow-on; see `docs/LEASE_CONTROLLER.md`).
//!
//! Station issue #22 (archived) was closed once the first `lease::` slice
//! merged, even though that PR explicitly stated its slice did not close
//! #22 and the project workstream record asks for a follow-up tracker
//! before further implementation is assigned. This module, and the sibling
//! modules it is designed to compose with, are that follow-on: typed
//! classification (this file), bounded route-attempt admission, and Band 2
//! fair selection over what this module has already classified.
//!
//! This module is the only place Station should decide which
//! `lease::EligibleWork` flags a piece of traffic sets. Centralizing that
//! decision means a caller cannot accidentally route Band 2 ordinary mail
//! (manifests, receipts, bodies, attachments) into the Band 1 control cap —
//! older component prose ("routine manifests... use normal control") predates
//! ADR-009 moving ordinary mail manifests/receipts/control into Band 2, and
//! is superseded for that traffic; it still correctly describes Band 1's own
//! Grid/topology advertisements, which is why `WorkKind` spells the two
//! kinds of "manifest" out as distinct variants instead of one ambiguous
//! label.
//!
//! This module performs no cryptographic authentication and no legal/
//! operational Emergency-permission check; those remain unimplemented,
//! production gates. `AuthorizedEmergency` and `ServerPromotion` are typed
//! markers that must be constructed by code that has already done that
//! validation elsewhere. Neither implements `Deserialize`, so neither can be
//! asserted by a client/API request body; an untrusted flag alone can never
//! confer Band 1 Server promotion or Band 0 Emergency eligibility.

use crate::lease::EligibleWork;

/// Evidence that Emergency eligibility for a piece of work has already been
/// authorized elsewhere (technical capability, legal/operational
/// permission). Intentionally opaque and non-deserializable: constructing
/// one is an assertion trusted internal code makes, not a client claim.
#[derive(Clone, Copy, Debug)]
pub struct AuthorizedEmergency(());

impl AuthorizedEmergency {
    /// The caller attests this work already passed Emergency authorization
    /// outside this module. Production authorization is not implemented
    /// here or anywhere yet in Station.
    pub fn already_authorized_elsewhere() -> Self {
        Self(())
    }
}

/// Evidence that a shared broadcast has already passed authenticated Server
/// promotion (ADR-008: "Honor only authenticated, authorized Server
/// designations with validated scope/freshness"). Non-deserializable for the
/// same reason as `AuthorizedEmergency`.
#[derive(Clone, Copy, Debug)]
pub struct ServerPromotion(());

impl ServerPromotion {
    /// The caller attests this update was authenticated/authorized by the
    /// Server elsewhere. Production Server authentication is not
    /// implemented here or anywhere yet in Station.
    pub fn already_authenticated_elsewhere() -> Self {
        Self(())
    }
}

/// A closed set of concrete internal work kinds the scheduler boundary may
/// see, plus an explicit `Unclassified` escape hatch for anything this
/// module does not recognize. This is caller-trusted internal input (a kind
/// Station's own code assigns to a queue/observation), not a raw client/API
/// priority field — see `docs/LEASE_CONTROLLER.md`'s `EligibleWork` contract.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WorkKind {
    /// Band 1: peer/Station discovery, presence, rendezvous announcements.
    GridDiscovery,
    /// Band 1: repairing/maintaining a route, outside the necessary-setup
    /// full-lease exception (i.e. some usable route already exists).
    RouteRepair,
    /// Band 1 full-lease exception: establishing a currently-absent usable
    /// route for queued work. Kept distinct from `RouteRepair` because
    /// admission (bounded attempts/backoff across opportunities) gates this
    /// case separately from ordinary Band 1 control.
    NecessaryRouteSetup,
    /// Band 1, only with `ServerPromotion` evidence: a Server-designated
    /// urgent public update (ADR-008/ADR-009). Without evidence this is
    /// ineligible — never a silent Band 3 downgrade and never Band 1
    /// admission on the strength of the label alone.
    ServerPromotedUpdate,
    /// Band 2 ordinary mail control: account manifests/Available metadata,
    /// retrieval requests, receipts, stop-flow/tombstones, custody
    /// evidence, mailbox/usage-accounting reconciliation. Never Band 1,
    /// regardless of the word "manifest" also describing Band 1 Grid state
    /// in older prose docs.
    AccountMailControl,
    /// Band 2 ordinary mail payload: bodies and attachments.
    AccountMailPayload,
    /// Band 3: shared background broadcast data (no Server promotion).
    BackgroundBroadcast,
    /// Anything this module does not recognize. Always ineligible; the
    /// label is diagnostic only and must never be pattern-matched to infer
    /// a band.
    Unclassified(&'static str),
}

/// The band-scheduling outcome of classifying one `WorkKind` plus whatever
/// evidence it required. Deliberately smaller than `WorkKind`: several kinds
/// collapse onto the same class because `lease::EligibleWork` only needs to
/// know which bucket to fill, not the original queue-level distinction.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TrafficClass {
    NecessaryRouteSetup,
    PublicCoordination,
    OrdinaryMail,
    Background,
}

/// Why a work item was refused classification. Diagnostic only — callers
/// must treat every variant identically (ineligible now; the caller may
/// re-present the same work later with the required evidence) rather than
/// branching to recover eligibility from the reason.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Ineligible {
    Unclassified,
    ServerPromotionRequired,
}

/// Classify one internal work kind. Returns `Err(Ineligible)` rather than
/// guessing a band for anything unrecognized or missing required evidence;
/// unknown work must remain ineligible rather than defaulting into Band 2 or
/// Band 3.
pub fn classify(
    kind: &WorkKind,
    promotion: Option<&ServerPromotion>,
) -> Result<TrafficClass, Ineligible> {
    match kind {
        WorkKind::GridDiscovery | WorkKind::RouteRepair => Ok(TrafficClass::PublicCoordination),
        WorkKind::NecessaryRouteSetup => Ok(TrafficClass::NecessaryRouteSetup),
        WorkKind::ServerPromotedUpdate => match promotion {
            Some(_) => Ok(TrafficClass::PublicCoordination),
            None => Err(Ineligible::ServerPromotionRequired),
        },
        WorkKind::AccountMailControl | WorkKind::AccountMailPayload => {
            Ok(TrafficClass::OrdinaryMail)
        }
        WorkKind::BackgroundBroadcast => Ok(TrafficClass::Background),
        WorkKind::Unclassified(_) => Err(Ineligible::Unclassified),
    }
}

/// One classified candidate contributing to the current decision boundary's
/// `EligibleWork`. `Emergency` bypasses `classify`/`WorkKind` entirely: it
/// can only be constructed here, directly, from `AuthorizedEmergency`
/// evidence, so no `WorkKind` variant and therefore no client-suppliable
/// input can ever produce it.
#[derive(Clone, Copy, Debug)]
pub enum Candidate {
    Emergency(AuthorizedEmergency),
    Classified(TrafficClass),
}

/// Fold classified candidates into `lease::EligibleWork`. This is the only
/// function Station should use to construct a real `EligibleWork` outside
/// tests, so the Band 1/Band 2 separation and the Emergency/Server-promotion
/// evidence requirements live in one auditable place instead of being
/// re-derived ad hoc at each call site.
pub fn eligible_work(candidates: &[Candidate]) -> EligibleWork {
    let mut work = EligibleWork::default();
    for candidate in candidates {
        match candidate {
            Candidate::Emergency(_evidence) => work.emergency = true,
            Candidate::Classified(TrafficClass::NecessaryRouteSetup) => {
                work.necessary_route_setup = true;
            }
            Candidate::Classified(TrafficClass::PublicCoordination) => work.control = true,
            Candidate::Classified(TrafficClass::OrdinaryMail) => work.payload = true,
            Candidate::Classified(TrafficClass::Background) => work.background = true,
        }
    }
    work
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::lease::{LeaseController, LeasePolicy, Work};
    use std::time::Duration;

    fn promoted() -> ServerPromotion {
        ServerPromotion::already_authenticated_elsewhere()
    }

    #[test]
    fn band1_kinds_classify_as_public_coordination() {
        for kind in [WorkKind::GridDiscovery, WorkKind::RouteRepair] {
            assert_eq!(classify(&kind, None), Ok(TrafficClass::PublicCoordination));
        }
    }

    #[test]
    fn necessary_route_setup_is_distinct_from_public_coordination() {
        assert_eq!(
            classify(&WorkKind::NecessaryRouteSetup, None),
            Ok(TrafficClass::NecessaryRouteSetup)
        );
    }

    #[test]
    fn server_promotion_is_required_and_not_inferred() {
        assert_eq!(
            classify(&WorkKind::ServerPromotedUpdate, None),
            Err(Ineligible::ServerPromotionRequired)
        );
        let evidence = promoted();
        assert_eq!(
            classify(&WorkKind::ServerPromotedUpdate, Some(&evidence)),
            Ok(TrafficClass::PublicCoordination)
        );
    }

    #[test]
    fn ordinary_mail_kinds_never_classify_into_band1() {
        for kind in [WorkKind::AccountMailControl, WorkKind::AccountMailPayload] {
            assert_eq!(classify(&kind, None), Ok(TrafficClass::OrdinaryMail));
        }
    }

    #[test]
    fn background_broadcast_classifies_as_background() {
        assert_eq!(
            classify(&WorkKind::BackgroundBroadcast, None),
            Ok(TrafficClass::Background)
        );
    }

    #[test]
    fn unclassified_work_always_fails_closed() {
        for label in ["", "future-kind", "client-supplied-priority"] {
            assert_eq!(
                classify(&WorkKind::Unclassified(label), None),
                Err(Ineligible::Unclassified)
            );
        }
        // Presenting promotion evidence must not rescue an unrecognized kind.
        let evidence = promoted();
        assert_eq!(
            classify(&WorkKind::Unclassified("x"), Some(&evidence)),
            Err(Ineligible::Unclassified)
        );
    }

    #[test]
    fn ordinary_mail_never_sets_band1_or_emergency_flags() {
        let candidates = [
            Candidate::Classified(TrafficClass::OrdinaryMail),
            Candidate::Classified(TrafficClass::OrdinaryMail),
        ];
        let work = eligible_work(&candidates);
        assert!(work.payload);
        assert!(!work.control);
        assert!(!work.necessary_route_setup);
        assert!(!work.emergency);
        assert!(!work.background);
    }

    #[test]
    fn emergency_flag_requires_explicit_evidence_variant() {
        // No `WorkKind`/`classify` path can produce `Candidate::Emergency`;
        // it is only reachable by holding `AuthorizedEmergency` directly.
        let evidence = AuthorizedEmergency::already_authorized_elsewhere();
        let work = eligible_work(&[Candidate::Emergency(evidence)]);
        assert!(work.emergency);
        assert!(!work.control);
        assert!(!work.payload);
        assert!(!work.necessary_route_setup);
        assert!(!work.background);
    }

    #[test]
    fn mixed_batch_fills_exactly_the_expected_buckets() {
        let promotion = promoted();
        let kinds = [
            (WorkKind::GridDiscovery, None),
            (WorkKind::AccountMailControl, None),
            (WorkKind::AccountMailPayload, None),
            (WorkKind::BackgroundBroadcast, None),
            (WorkKind::ServerPromotedUpdate, Some(&promotion)),
            (WorkKind::Unclassified("unrecognized"), None),
        ];
        let candidates: Vec<Candidate> = kinds
            .iter()
            .filter_map(|(kind, promo)| classify(kind, *promo).ok())
            .map(Candidate::Classified)
            .collect();
        // The unclassified item must have been dropped, not defaulted.
        assert_eq!(candidates.len(), kinds.len() - 1);

        let work = eligible_work(&candidates);
        assert!(work.control, "grid discovery + promoted update -> Band 1");
        assert!(work.payload, "account control + payload -> Band 2 bucket");
        assert!(work.background);
        assert!(!work.necessary_route_setup);
        assert!(!work.emergency);
    }

    #[test]
    fn classification_composes_with_lease_controller() {
        // End-to-end sanity: classifying ordinary mail and feeding the
        // result into the existing, separately-tested LeaseController must
        // land in the Payload bucket, never Control, for the whole lease.
        let mut controller = LeaseController::new(
            LeasePolicy::new(Duration::from_millis(100), Duration::from_millis(40)).unwrap(),
        );
        let candidates = [Candidate::Classified(TrafficClass::OrdinaryMail)];
        let work = eligible_work(&candidates);
        let decision = controller.decide(Duration::from_millis(0), work).unwrap();
        assert_eq!(
            decision,
            crate::lease::Decision::Run {
                work: Work::Payload,
                max_duration: Duration::from_millis(100),
            }
        );
        assert_eq!(controller.control_used(), Duration::ZERO);
    }
}
