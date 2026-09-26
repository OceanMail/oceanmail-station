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
//! Cross-scope turn-taking is two-level, matching the two fairness axes
//! ADR-008 names as genuinely separate: **local-vs-relay group** share
//! first, then **account/peer** share within whichever group is due. Both
//! levels use the same rule — least decayed cumulative weighted airtime
//! first, compared by cross-multiplication so no floating point or integer
//! division is needed — applied first across the two groups' aggregate
//! usage, then (once a group is chosen) across that group's own scopes.
//! Comparing every scope flat against every other scope, weighted only by
//! its own group's weight, would let a group's *share* grow simply by
//! having more identities in it; see `group_share_is_independent_of_how_many_identities_are_in_it`.
//!
//! Usage decays linearly: one nanosecond of accrued weighted usage is
//! forgiven per nanosecond a scope goes untouched, floored at zero. Without
//! this, a scope that used substantial airtime long ago and then went idle
//! would stay behind any currently-active competitor until that
//! competitor's *own* lifetime total caught up to the idle scope's old
//! total — contradicting ADR-008's "aging protection" and turning "idle
//! time" into a permanent handicap instead of the credit it is supposed to
//! be. See `idle_time_decays_historical_usage...` below.
//!
//! Because usage decays back toward zero rather than only ever growing,
//! and is keyed by the caller-stable [`Scope`] identity, this gives every
//! property ADR-008 asks for:
//!
//! - an idle group/scope competes for nothing, so its capacity is simply
//!   available to whichever scope *is* ready — no separate reallocation
//!   step is needed;
//! - a scope that was just served has higher usage than one that has not,
//!   so the next call (the next lease/opportunity) naturally favors the
//!   less-served scope — this is what makes reconnecting or presenting
//!   repeated demand under the same identity unable to buy an extra share
//!   *when calls follow closely enough that decay has not erased the
//!   difference*;
//! - a scope that goes without service for a while has its usage decay
//!   away, so it is preferred again once enough idle time has passed —
//!   real aging, not just "never accrues more".
//!
//! The [`FairnessLedger`] is what carries usage (and each scope's
//! last-touched time, for decay) across separate calls (separate leases);
//! reusing the same ledger and the same `Scope` identity across calls is
//! the caller's responsibility. This module does no identity verification
//! and stores no personal data — only opaque identity strings and
//! accounting numbers, matching the storage gate in
//! `docs/PHASE4_STORAGE_SECURITY.md`. There is still no persistence
//! *across a process restart*: the ledger and its decay clock both live
//! only in memory for the process lifetime, matching
//! `docs/LEASE_CONTROLLER.md`'s note that restart-durable accounting
//! remains open production work.
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

#[derive(Debug, Clone, Copy)]
struct LedgerEntry {
    usage_nanos: u128,
    last_touched: Duration,
}

/// Per-scope accrued weighted airtime, carried across separate
/// `select_band2` calls (separate leases) by the caller reusing the same
/// ledger. Holds only opaque `Scope` identities and durations — no
/// personal data. See the module docs for why usage decays instead of only
/// ever growing, and for the restart-durability boundary.
#[derive(Debug, Default)]
pub struct FairnessLedger {
    entries: HashMap<Scope, LedgerEntry>,
}

impl FairnessLedger {
    pub fn new() -> Self {
        Self::default()
    }

    /// Decayed usage attributed to `scope` as of `now`: raw accrued usage
    /// minus however much real time has passed since it was last touched,
    /// floored at zero.
    fn effective_used_nanos(&self, scope: &Scope, now: Duration) -> u128 {
        match self.entries.get(scope) {
            None => 0,
            Some(entry) => {
                let idle_nanos = now.saturating_sub(entry.last_touched).as_nanos();
                entry.usage_nanos.saturating_sub(idle_nanos)
            }
        }
    }

    fn group_used_nanos(&self, group: Group, now: Duration) -> u128 {
        self.entries
            .keys()
            .filter(|scope| scope.group == group)
            .map(|scope| self.effective_used_nanos(scope, now))
            .sum()
    }

    fn credit(&mut self, scope: Scope, now: Duration, cost: Duration) {
        let decayed = self.effective_used_nanos(&scope, now);
        self.entries.insert(
            scope,
            LedgerEntry {
                usage_nanos: decayed + cost.as_nanos(),
                last_touched: now,
            },
        );
    }

    /// Decayed usage attributed to `scope` as of `now`. Exposed for
    /// tests/introspection; `select_band2` uses the private accessor above
    /// so every read goes through the same decay rule.
    pub fn used(&self, scope: &Scope, now: Duration) -> Duration {
        let nanos = self.effective_used_nanos(scope, now);
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

/// `a` is due for service strictly before `b`, as of `now`. Two-level: if
/// `a`/`b` are in different groups, compare *group-aggregate* decayed
/// usage weighted by each group's configured weight, so a group's share
/// depends only on that weight, never on how many scopes happen to be
/// active within it. Only once two candidates share a group does per-scope
/// decayed usage decide between them (equal in-group weight, per ADR-008's
/// "equal airtime shares... initial policy"). Both levels use
/// cross-multiplication to avoid floating point/division; ties break on
/// `Scope`'s/`Group`'s derived `Ord` purely for determinism, not fairness
/// meaning.
fn due_before(
    ledger: &FairnessLedger,
    policy: &SelectionPolicy,
    now: Duration,
    a: &Scope,
    b: &Scope,
) -> bool {
    if a.group != b.group {
        let used_a = ledger.group_used_nanos(a.group, now);
        let used_b = ledger.group_used_nanos(b.group, now);
        let lhs = used_a * policy.weight_for(b.group);
        let rhs = used_b * policy.weight_for(a.group);
        return if lhs != rhs {
            lhs < rhs
        } else {
            a.group < b.group
        };
    }
    let used_a = ledger.effective_used_nanos(a, now);
    let used_b = ledger.effective_used_nanos(b, now);
    if used_a != used_b {
        used_a < used_b
    } else {
        a < b
    }
}

/// Select this turn's Band 2 items as of `now` (the same injected-clock
/// discipline as `lease::LeaseController`/`route_admission`: no wall-clock
/// access happens here). `candidates` should already be exactly the
/// admitted/classified work for this decision boundary — this module
/// performs no eligibility check of its own (see module docs).
pub fn select_band2(
    ledger: &mut FairnessLedger,
    policy: &SelectionPolicy,
    now: Duration,
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
                    if due_before(ledger, policy, now, scope, current_best) {
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
        ledger.credit(scope, now, cost);
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
        let selection = select_band2(
            &mut ledger,
            &policy,
            Duration::ZERO,
            candidates,
            Duration::from_secs(10),
        );
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
        let selection = select_band2(
            &mut ledger,
            &policy,
            Duration::ZERO,
            candidates,
            Duration::from_secs(10),
        );
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

    // Codex review finding on this PR: comparing every scope flat, each
    // weighted only by its own group's weight, lets a group's aggregate
    // share grow simply by having more identities ready in it. With equal
    // 1:1 weights, two local accounts against one relay peer used to cycle
    // as three "equal" competitors, giving local roughly two-thirds of
    // airtime instead of half. `due_before` now compares group-aggregate
    // usage first; this reproduces the exact scenario and pins the fix.
    #[test]
    fn group_share_is_independent_of_how_many_identities_are_in_it() {
        let l1 = scope(Group::Local, "acct-a");
        let l2 = scope(Group::Local, "acct-b");
        let r1 = scope(Group::Relay, "peer-a");
        let mut candidates = Vec::new();
        // Deliberately far more supply per scope than `max_turns` below can
        // possibly serve: this test is only meaningful under real scarcity.
        // With enough turns to drain every scope's queue there is no
        // contention left to be fair about, and the counts below would
        // just reflect how many items each scope happened to be given.
        for i in 0..20 {
            candidates.push(body(
                &format!("l1-{i}"),
                l1.clone(),
                &format!("ml1-{i}"),
                i,
                10,
            ));
            candidates.push(body(
                &format!("l2-{i}"),
                l2.clone(),
                &format!("ml2-{i}"),
                i,
                10,
            ));
            candidates.push(body(
                &format!("r1-{i}"),
                r1.clone(),
                &format!("mr1-{i}"),
                i,
                10,
            ));
        }
        let mut ledger = FairnessLedger::new();
        let policy = equal_policy(12);
        let selection = select_band2(
            &mut ledger,
            &policy,
            Duration::ZERO,
            candidates,
            Duration::from_secs(10),
        );
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
        assert_eq!(local_count, 6, "two local identities together get half");
        assert_eq!(relay_count, 6, "one relay identity alone still gets half");
    }

    #[test]
    fn idle_group_capacity_is_reused_by_the_other_group() {
        let local = scope(Group::Local, "acct-a");
        let candidates = (0..3)
            .map(|i| body(&format!("l{i}"), local.clone(), &format!("m{i}"), i, 10))
            .collect();
        let mut ledger = FairnessLedger::new();
        let policy = equal_policy(3);
        let selection = select_band2(
            &mut ledger,
            &policy,
            Duration::ZERO,
            candidates,
            Duration::from_secs(10),
        );
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
        let selection = select_band2(
            &mut ledger,
            &policy,
            Duration::ZERO,
            candidates,
            Duration::from_secs(10),
        );
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
        let selection = select_band2(
            &mut ledger,
            &policy,
            Duration::ZERO,
            candidates,
            Duration::from_secs(10),
        );

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
            Duration::ZERO,
            vec![body("a1", a.clone(), "ma1", 0, 10)],
            Duration::from_secs(10),
        );
        assert_eq!(first.selected, vec!["a1"]);

        // A already used its ledger share in the previous lease, and no
        // idle time passed (same `now`) to decay that away; presenting A
        // again "as a new connection" (same stable Scope identity) must
        // not admit it ahead of B, which has never been served.
        let second = select_band2(
            &mut ledger,
            &policy,
            Duration::ZERO,
            vec![
                body("a2", a.clone(), "ma2", 0, 10),
                body("b1", b.clone(), "mb1", 0, 10),
            ],
            Duration::from_secs(10),
        );
        assert_eq!(second.selected, vec!["b1"]);
    }

    // Codex review finding on this PR: usage that only ever grows means a
    // scope which used substantial airtime long ago and then went idle
    // stays behind any smaller, currently-active backlog until that
    // backlog's *own* lifetime total catches up — idle time never actually
    // helps, contradicting both ADR-008's "aging protection" and this
    // module's own documentation. `FairnessLedger` now decays usage
    // linearly with real idle time; this reproduces the exact scenario
    // (a big historical user returns after a long wait, against a small
    // amount of very recent activity) and pins the fix.
    #[test]
    fn idle_time_decays_historical_usage_so_a_returning_scope_is_not_stuck_behind_smaller_recent_activity(
    ) {
        let heavy = scope(Group::Local, "acct-heavy");
        let recent = scope(Group::Local, "acct-recent");
        let mut ledger = FairnessLedger::new();
        let policy = equal_policy(1);

        for i in 0..5 {
            let item = body(&format!("h{i}"), heavy.clone(), &format!("mh{i}"), i, 100);
            let selection = select_band2(
                &mut ledger,
                &policy,
                Duration::ZERO,
                vec![item],
                Duration::from_secs(10),
            );
            assert_eq!(selection.selected.len(), 1);
        }
        assert_eq!(
            ledger.used(&heavy, Duration::ZERO),
            Duration::from_millis(500)
        );

        // `heavy` then sits idle for 2 real seconds while `recent` shows up
        // and does a little work.
        let later = Duration::from_secs(2);
        let selection = select_band2(
            &mut ledger,
            &policy,
            later,
            vec![body("r0", recent.clone(), "mr0", 0, 50)],
            Duration::from_secs(10),
        );
        assert_eq!(selection.selected, vec!["r0"]);

        // Both are ready again at the same instant `later`. heavy's 500ms
        // of debt has been idle for 2_000ms, which fully forgives it back
        // to 0 — having waited, it is now due before recent's much smaller
        // but freshly-touched 50ms, rather than staying behind it forever.
        let selection = select_band2(
            &mut ledger,
            &policy,
            later,
            vec![
                body("h-again", heavy.clone(), "mh-again", 0, 10),
                body("r-again", recent.clone(), "mr-again", 0, 10),
            ],
            Duration::from_secs(10),
        );
        assert_eq!(selection.selected, vec!["h-again"]);
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
        let selection = select_band2(
            &mut ledger,
            &policy,
            Duration::ZERO,
            candidates,
            Duration::from_secs(10),
        );
        assert_eq!(selection.selected, vec!["bod", "att"]);
    }

    #[test]
    fn orphan_attachment_without_available_body_is_never_selected() {
        let s = scope(Group::Local, "acct-a");
        let candidates = vec![attachment("att", s.clone(), "m1", 0, 10, false)];
        let mut ledger = FairnessLedger::new();
        let policy = equal_policy(10);
        let selection = select_band2(
            &mut ledger,
            &policy,
            Duration::ZERO,
            candidates,
            Duration::from_secs(10),
        );
        assert!(selection.selected.is_empty());
    }

    #[test]
    fn already_present_body_allows_standalone_attachment_selection() {
        let s = scope(Group::Local, "acct-a");
        let candidates = vec![attachment("att", s.clone(), "m1", 0, 10, true)];
        let mut ledger = FairnessLedger::new();
        let policy = equal_policy(10);
        let selection = select_band2(
            &mut ledger,
            &policy,
            Duration::ZERO,
            candidates,
            Duration::from_secs(10),
        );
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
        let selection = select_band2(
            &mut ledger,
            &policy,
            Duration::ZERO,
            candidates,
            Duration::from_secs(10),
        );
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
            Duration::ZERO,
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
            Duration::ZERO,
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
        let selection = select_band2(
            &mut ledger,
            &policy,
            Duration::ZERO,
            candidates,
            Duration::from_millis(50),
        );
        assert_eq!(selection.selected, vec!["small"]);
    }
}
