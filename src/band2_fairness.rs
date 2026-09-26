//! Band 2 fair selection over already-admitted, already-classified work
//! (ADR-008 follow-on; see `docs/LEASE_CONTROLLER.md`).
//!
//! This module does not decide *whether* work is eligible for Band 2 — that
//! is `classify`'s job — only, given a `Work::Payload` turn from
//! `lease::LeaseController`, *which* already-eligible items get served and
//! in what order: "Maintain internal fairness between local and relay
//! work, account fairness within local work, and per-requesting-Station
//! fairness within relay work. An idle group's unused capacity can serve
//! the other group... Use bounded turns and persistent age/service
//! accounting across leases... equal airtime shares... is an initial
//! policy, not an entitlement... extra sessions/reconnects must not create
//! additional shares" (ADR-008).
//!
//! Cross-scope turn-taking always serves whichever ready, affordable scope
//! has the least cumulative weighted airtime *ever* attributed to it in
//! this [`FairnessLedger`] (a weighted least-service-first schedule): given
//! usage `u` and configured weight `w`, scope `a` goes before scope `b`
//! when `u_a / w_a < u_b / w_b`, compared by cross-multiplication so no
//! floating point or integer division is needed. Because usage only ever
//! grows and is keyed by the caller-stable [`Scope`] identity, this single
//! rule already gives every property ADR-008 asks for:
//!
//! - an idle group/scope competes for nothing, so its capacity is simply
//!   available to whichever scope *is* ready — no separate reallocation
//!   step is needed;
//! - a scope that was just served has higher usage than one that has not,
//!   so the next call (the next lease/opportunity) naturally favors the
//!   less-served scope — this is what makes reconnecting or presenting
//!   repeated demand under the same identity unable to buy an extra share;
//! - a scope that goes without service for a while never accrues usage, so
//!   it is preferred as soon as it has ready work again (aging).
//!
//! The [`FairnessLedger`] is what carries usage across separate calls
//! (separate leases); reusing the same ledger and the same `Scope` identity
//! across calls is the caller's responsibility. This module does no
//! identity verification and stores no personal data — only opaque
//! identity strings and accounting numbers, matching the storage gate in
//! `docs/PHASE4_STORAGE_SECURITY.md`.
//!
//! Within one scope, item order follows recipient-selected Available
//! order, except that an attachment whose body has not already been
//! delivered is reordered after (never before) that body, and is dropped
//! from selectability entirely if no such body is among this round's
//! candidates. `Item::important` exists only so callers can assert it is
//! *not* used as a sort key — Important is interoperable metadata, not
//! transport precedence (ADR-008/ADR-009).

use crate::lease::EligibleWork;
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::time::Duration;

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Group {
    Local,
    Relay,
}

/// A stable local-account or relay-peer identity. Must stay the same across
/// reconnects/repeated requests for the same account/peer; a fresh identity
/// per connection would defeat both the anti-reconnect-advantage and the
/// aging guarantees this module provides.
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub struct Scope {
    pub group: Group,
    pub identity: String,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ItemKind {
    Body,
    Attachment,
}

/// Explicit cost units that never let a merely-estimated cost pass as a
/// measured one (AGENTS.md evidence-truthfulness baseline, applied to
/// scheduler accounting rather than transport evidence).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AirtimeCost {
    Measured(Duration),
    Estimated(Duration),
}

impl AirtimeCost {
    pub fn duration(&self) -> Duration {
        match self {
            AirtimeCost::Measured(d) | AirtimeCost::Estimated(d) => *d,
        }
    }

    pub fn is_estimated(&self) -> bool {
        matches!(self, AirtimeCost::Estimated(_))
    }
}

/// One synthetic, already-admitted candidate. Carries no message content or
/// address data — only what this module needs to order and cost it.
#[derive(Clone, Debug)]
pub struct Item {
    pub id: String,
    pub scope: Scope,
    /// Links a Body to its Attachments. Only consulted for `Attachment`
    /// items; ignored for `Body` items beyond identifying them to each
    /// other.
    pub message_id: String,
    pub kind: ItemKind,
    pub cost: AirtimeCost,
    /// Recipient-selected Available ordering; lower sorts first. Body and
    /// attachment items belonging to the same message should normally
    /// share one value — see `order_scope_queue`'s body-before-attachment
    /// handling for what happens when they do not.
    pub recipient_order: u32,
    /// Exists only to be asserted irrelevant by tests. Must never affect
    /// selection order or eligibility.
    pub important: bool,
    /// Only meaningful for `ItemKind::Attachment`. ADR-008: "selecting an
    /// attachment also requests its body unless already present."
    pub body_already_present: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SelectionPolicyError {
    ZeroWeight,
}

/// Explicit, required tuning inputs — no guessed production defaults,
/// matching `lease::LeasePolicy` and `route_admission::AttemptPolicy`.
/// ADR-008 records equal shares as an initial policy, not a fixed rule, so
/// weights are required inputs rather than an assumed 1:1 default.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct SelectionPolicy {
    local_weight: u32,
    relay_weight: u32,
    /// Hard cap on items selected in one call, independent of remaining
    /// budget — forces the caller to reconsider between bounded batches
    /// rather than draining every queue in one turn.
    pub max_turns: u32,
}

impl SelectionPolicy {
    pub fn new(
        local_weight: u32,
        relay_weight: u32,
        max_turns: u32,
    ) -> Result<Self, SelectionPolicyError> {
        if local_weight == 0 || relay_weight == 0 {
            return Err(SelectionPolicyError::ZeroWeight);
        }
        Ok(Self {
            local_weight,
            relay_weight,
            max_turns,
        })
    }

    fn weight_for(&self, group: Group) -> u128 {
        match group {
            Group::Local => self.local_weight as u128,
            Group::Relay => self.relay_weight as u128,
        }
    }
}

/// Per-scope cumulative weighted airtime ever attributed, carried across
/// separate `select_band2` calls (separate leases) by the caller reusing
/// the same ledger. Holds only opaque `Scope` identities and durations —
/// no personal data. Usage only ever grows; there is no decay/expiry in
/// this slice, matching `docs/LEASE_CONTROLLER.md`'s note that persistent
/// restart/reconnect accounting remains open production work — a caller
/// needing that must persist and restore this ledger itself.
#[derive(Debug, Default)]
pub struct FairnessLedger {
    used_nanos: HashMap<Scope, u128>,
}

impl FairnessLedger {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn used(&self, scope: &Scope) -> Duration {
        let nanos = self.used_nanos.get(scope).copied().unwrap_or(0);
        Duration::from_nanos(nanos.min(u64::MAX as u128) as u64)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Selection {
    /// Item ids in the order they would be served.
    pub selected: Vec<String>,
    pub used: Duration,
    /// True if any selected item's cost was `AirtimeCost::Estimated`; a
    /// caller must not then report `used` as fully measured evidence.
    pub any_estimated: bool,
}

/// Order one scope's own candidates: recipient-selected order first, with
/// body-before-attachment enforced even when an attachment's own
/// `recipient_order` would otherwise place it earlier than its body. An
/// attachment that still needs its body, with no such body among this
/// round's candidates, is dropped — never selected on its own.
fn order_scope_queue(items: Vec<Item>) -> Vec<Item> {
    let mut ordered = items;

    let body_order: HashMap<String, u32> = ordered
        .iter()
        .filter(|item| item.kind == ItemKind::Body)
        .map(|item| (item.message_id.clone(), item.recipient_order))
        .collect();

    ordered.retain(|item| {
        item.kind == ItemKind::Body
            || item.body_already_present
            || body_order.contains_key(&item.message_id)
    });

    ordered.sort_by_key(|item| {
        let kind_rank: u8 = match item.kind {
            ItemKind::Body => 0,
            ItemKind::Attachment => 1,
        };
        let effective_order = if item.kind == ItemKind::Attachment && !item.body_already_present {
            body_order
                .get(&item.message_id)
                .copied()
                .unwrap_or(item.recipient_order)
        } else {
            item.recipient_order
        };
        (effective_order, kind_rank, item.id.clone())
    });

    ordered
}

/// `a` is due for service strictly before `b`: `used_a/weight_a <
/// used_b/weight_b`, decided by cross-multiplication to avoid floating
/// point and avoid dividing by a weight at all. Ties break on `Scope`'s
/// derived `Ord` purely for determinism, not fairness meaning.
fn due_before(ledger: &FairnessLedger, policy: &SelectionPolicy, a: &Scope, b: &Scope) -> bool {
    let used_a = ledger.used_nanos.get(a).copied().unwrap_or(0);
    let used_b = ledger.used_nanos.get(b).copied().unwrap_or(0);
    let lhs = used_a * policy.weight_for(b.group);
    let rhs = used_b * policy.weight_for(a.group);
    if lhs != rhs {
        lhs < rhs
    } else {
        a < b
    }
}

/// Select this turn's Band 2 items. `candidates` should already be exactly
/// the admitted/classified work for this decision boundary — this module
/// performs no eligibility check of its own (see module docs).
pub fn select_band2(
    ledger: &mut FairnessLedger,
    policy: &SelectionPolicy,
    candidates: Vec<Item>,
    mut remaining_budget: Duration,
) -> Selection {
    let mut queues: BTreeMap<Scope, VecDeque<Item>> = BTreeMap::new();
    for item in candidates {
        queues
            .entry(item.scope.clone())
            .or_default()
            .push_back(item);
    }
    for queue in queues.values_mut() {
        let ordered = order_scope_queue(queue.drain(..).collect());
        *queue = ordered.into_iter().collect();
    }

    let mut selected = Vec::new();
    let mut used = Duration::ZERO;
    let mut any_estimated = false;
    let mut turns_left = policy.max_turns;

    while turns_left > 0 && !remaining_budget.is_zero() {
        let mut best: Option<&Scope> = None;
        for (scope, queue) in &queues {
            let Some(front) = queue.front() else {
                continue;
            };
            if front.cost.duration() > remaining_budget {
                continue;
            }
            best = Some(match best {
                None => scope,
                Some(current_best) => {
                    if due_before(ledger, policy, scope, current_best) {
                        scope
                    } else {
                        current_best
                    }
                }
            });
        }
        let Some(scope) = best.cloned() else {
            break;
        };

        let item = queues.get_mut(&scope).unwrap().pop_front().unwrap();
        let cost = item.cost.duration();
        selected.push(item.id.clone());
        used += cost;
        any_estimated |= item.cost.is_estimated();
        remaining_budget -= cost;
        turns_left -= 1;
        *ledger.used_nanos.entry(scope).or_insert(0) += cost.as_nanos();
    }

    Selection {
        selected,
        used,
        any_estimated,
    }
}

/// Convenience: whether this turn had any Band 2 work at all, in the shape
/// `classify::eligible_work` / `lease::LeaseController` expect. Provided so
/// an adapter can decide whether to even ask for a `Work::Payload` turn.
pub fn any_ready(candidates: &[Item]) -> bool {
    !candidates.is_empty()
}

/// Documents the composition point with `classify`/`lease` without adding a
/// hard dependency: a caller typically only invokes `select_band2` once
/// `classify::eligible_work` and `lease::LeaseController::decide` have
/// already produced a `Work::Payload` run for this opportunity.
pub fn expects_payload_turn(work: &EligibleWork) -> bool {
    work.payload
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scope(group: Group, identity: &str) -> Scope {
        Scope {
            group,
            identity: identity.to_string(),
        }
    }

    fn body(id: &str, scope: Scope, message_id: &str, order: u32, cost_ms: u64) -> Item {
        Item {
            id: id.to_string(),
            scope,
            message_id: message_id.to_string(),
            kind: ItemKind::Body,
            cost: AirtimeCost::Measured(Duration::from_millis(cost_ms)),
            recipient_order: order,
            important: false,
            body_already_present: false,
        }
    }

    fn attachment(
        id: &str,
        scope: Scope,
        message_id: &str,
        order: u32,
        cost_ms: u64,
        body_present: bool,
    ) -> Item {
        Item {
            id: id.to_string(),
            scope,
            message_id: message_id.to_string(),
            kind: ItemKind::Attachment,
            cost: AirtimeCost::Measured(Duration::from_millis(cost_ms)),
            recipient_order: order,
            important: false,
            body_already_present: body_present,
        }
    }

    fn equal_policy(max_turns: u32) -> SelectionPolicy {
        SelectionPolicy::new(1, 1, max_turns).unwrap()
    }

    #[test]
    fn policy_rejects_zero_weight() {
        assert_eq!(
            SelectionPolicy::new(0, 1, 10),
            Err(SelectionPolicyError::ZeroWeight)
        );
        assert_eq!(
            SelectionPolicy::new(1, 0, 10),
            Err(SelectionPolicyError::ZeroWeight)
        );
    }

    #[test]
    fn equal_weight_scopes_alternate_turns() {
        let a = scope(Group::Local, "acct-a");
        let b = scope(Group::Local, "acct-b");
        let candidates = vec![
            body("a1", a.clone(), "m-a1", 0, 10),
            body("a2", a.clone(), "m-a2", 1, 10),
            body("b1", b.clone(), "m-b1", 0, 10),
            body("b2", b.clone(), "m-b2", 1, 10),
        ];
        let mut ledger = FairnessLedger::new();
        let policy = equal_policy(4);
        let selection = select_band2(&mut ledger, &policy, candidates, Duration::from_secs(10));
        assert_eq!(selection.selected, vec!["a1", "b1", "a2", "b2"]);
    }

    #[test]
    fn local_vs_relay_weight_controls_the_split() {
        let local = scope(Group::Local, "acct-a");
        let relay = scope(Group::Relay, "peer-a");
        let mut candidates = Vec::new();
        for i in 0..6 {
            candidates.push(body(
                &format!("l{i}"),
                local.clone(),
                &format!("m-l{i}"),
                i,
                10,
            ));
            candidates.push(body(
                &format!("r{i}"),
                relay.clone(),
                &format!("m-r{i}"),
                i,
                10,
            ));
        }
        let mut ledger = FairnessLedger::new();
        let policy = SelectionPolicy::new(2, 1, 9).unwrap();
        let selection = select_band2(&mut ledger, &policy, candidates, Duration::from_secs(10));
        let local_count = selection
            .selected
            .iter()
            .filter(|id| id.starts_with('l'))
            .count();
        let relay_count = selection
            .selected
            .iter()
            .filter(|id| id.starts_with('r'))
            .count();
        assert_eq!(local_count, 6);
        assert_eq!(relay_count, 3);
    }

    #[test]
    fn idle_group_capacity_is_reused_by_the_other_group() {
        let local = scope(Group::Local, "acct-a");
        let candidates = (0..3)
            .map(|i| body(&format!("l{i}"), local.clone(), &format!("m{i}"), i, 10))
            .collect();
        let mut ledger = FairnessLedger::new();
        let policy = equal_policy(3);
        let selection = select_band2(&mut ledger, &policy, candidates, Duration::from_secs(10));
        assert_eq!(selection.selected.len(), 3);
    }

    #[test]
    fn bounded_turns_caps_selection_regardless_of_budget() {
        let a = scope(Group::Local, "acct-a");
        let candidates = (0..10)
            .map(|i| body(&format!("a{i}"), a.clone(), &format!("m{i}"), i, 1))
            .collect();
        let mut ledger = FairnessLedger::new();
        let policy = equal_policy(3);
        let selection = select_band2(&mut ledger, &policy, candidates, Duration::from_secs(10));
        assert_eq!(selection.selected.len(), 3);
    }

    #[test]
    fn a_large_backlog_does_not_starve_a_low_demand_scope() {
        let a = scope(Group::Local, "acct-a");
        let b = scope(Group::Local, "acct-b");
        let mut candidates: Vec<Item> = (0..10)
            .map(|i| body(&format!("a{i}"), a.clone(), &format!("ma{i}"), i, 10))
            .collect();
        candidates.push(body("b1", b.clone(), "mb1", 0, 10));

        let mut ledger = FairnessLedger::new();
        let policy = equal_policy(4);
        let selection = select_band2(&mut ledger, &policy, candidates, Duration::from_secs(10));

        // B's single item is not crowded out by A's much larger backlog,
        // and once B is exhausted the remaining turns still go to A rather
        // than being wasted.
        assert_eq!(selection.selected, vec!["a0", "b1", "a1", "a2"]);
    }

    #[test]
    fn ledger_persists_across_calls_so_reconnects_gain_no_extra_share() {
        let a = scope(Group::Local, "acct-a");
        let b = scope(Group::Local, "acct-b");
        let mut ledger = FairnessLedger::new();
        let policy = equal_policy(1);

        let first = select_band2(
            &mut ledger,
            &policy,
            vec![body("a1", a.clone(), "ma1", 0, 10)],
            Duration::from_secs(10),
        );
        assert_eq!(first.selected, vec!["a1"]);

        // A already used its ledger share in the previous lease; presenting
        // A again "as a new connection" (same stable Scope identity) must
        // not admit it ahead of B, which has never been served.
        let second = select_band2(
            &mut ledger,
            &policy,
            vec![
                body("a2", a.clone(), "ma2", 0, 10),
                body("b1", b.clone(), "mb1", 0, 10),
            ],
            Duration::from_secs(10),
        );
        assert_eq!(second.selected, vec!["b1"]);
    }

    #[test]
    fn body_before_attachment_overrides_recipient_order() {
        let s = scope(Group::Local, "acct-a");
        let candidates = vec![
            attachment("att", s.clone(), "m1", 0, 10, false),
            body("bod", s.clone(), "m1", 5, 10),
        ];
        let mut ledger = FairnessLedger::new();
        let policy = equal_policy(10);
        let selection = select_band2(&mut ledger, &policy, candidates, Duration::from_secs(10));
        assert_eq!(selection.selected, vec!["bod", "att"]);
    }

    #[test]
    fn orphan_attachment_without_available_body_is_never_selected() {
        let s = scope(Group::Local, "acct-a");
        let candidates = vec![attachment("att", s.clone(), "m1", 0, 10, false)];
        let mut ledger = FairnessLedger::new();
        let policy = equal_policy(10);
        let selection = select_band2(&mut ledger, &policy, candidates, Duration::from_secs(10));
        assert!(selection.selected.is_empty());
    }

    #[test]
    fn already_present_body_allows_standalone_attachment_selection() {
        let s = scope(Group::Local, "acct-a");
        let candidates = vec![attachment("att", s.clone(), "m1", 0, 10, true)];
        let mut ledger = FairnessLedger::new();
        let policy = equal_policy(10);
        let selection = select_band2(&mut ledger, &policy, candidates, Duration::from_secs(10));
        assert_eq!(selection.selected, vec!["att"]);
    }

    #[test]
    fn important_flag_never_affects_order() {
        let s = scope(Group::Local, "acct-a");
        let mut important_first = body("urgent-looking", s.clone(), "m1", 5, 10);
        important_first.important = true;
        let mundane = body("plain", s.clone(), "m2", 0, 10);
        let candidates = vec![important_first, mundane];
        let mut ledger = FairnessLedger::new();
        let policy = equal_policy(10);
        let selection = select_band2(&mut ledger, &policy, candidates, Duration::from_secs(10));
        assert_eq!(selection.selected, vec!["plain", "urgent-looking"]);
    }

    #[test]
    fn measured_vs_estimated_airtime_is_never_conflated() {
        let s = scope(Group::Local, "acct-a");
        let all_measured = body("m1", s.clone(), "msg1", 0, 10);
        let mut ledger = FairnessLedger::new();
        let policy = equal_policy(10);
        let measured_only = select_band2(
            &mut ledger,
            &policy,
            vec![all_measured],
            Duration::from_secs(10),
        );
        assert!(!measured_only.any_estimated);

        let mut estimated = body("e1", s.clone(), "msg2", 0, 10);
        estimated.cost = AirtimeCost::Estimated(Duration::from_millis(10));
        let mut ledger2 = FairnessLedger::new();
        let with_estimate = select_band2(
            &mut ledger2,
            &policy,
            vec![estimated],
            Duration::from_secs(10),
        );
        assert!(with_estimate.any_estimated);
    }

    #[test]
    fn an_unaffordable_head_item_does_not_block_a_cheaper_item_elsewhere() {
        let expensive = scope(Group::Local, "acct-a");
        let cheap = scope(Group::Local, "acct-b");
        let candidates = vec![
            body("big", expensive.clone(), "m1", 0, 1_000),
            body("small", cheap.clone(), "m2", 0, 10),
        ];
        let mut ledger = FairnessLedger::new();
        let policy = equal_policy(10);
        let selection = select_band2(&mut ledger, &policy, candidates, Duration::from_millis(50));
        assert_eq!(selection.selected, vec!["small"]);
    }
}
