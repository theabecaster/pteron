//! Which Rex events become pushes: debounce, flap handling and per-device rate limits.
//! Pure state machines, so they are unit-tested. Time is seconds since 1970 (`util::now`).

use crate::util::Json;
use serde_json::Value;
use std::collections::HashMap;

/// Where an event came from: one block on one server.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct BlockRef {
    pub server: String,
    pub session_id: String,
    pub block_id: String,
}

/// One OSC 7501 record, from a `program_status_changed` block event.
#[derive(Clone, Debug, Default)]
pub struct StatusReport {
    pub record_id: String,
    pub state: String,
    pub kind: Option<String>,
    pub app: Option<String>,
    pub title: Option<String>,
    pub msg: Option<String>,
}

/// The `app` of the status record `setup.sh` writes.
pub const SETUP_APP: &str = "rexduo-setup";

impl StatusReport {
    /// Parses `{id, record: {state, kind, app, effective_app, title, msg}}`.
    pub fn from_event(e: &Value) -> Option<Self> {
        let rec = e.obj("record")?;
        // The helper's own installer reports its steps as a program status, for Rex's sidebar
        // and the phone's install sheet. It is not an agent: nothing to notify about.
        if rec.str("app") == Some(SETUP_APP) || rec.str("effective_app") == Some(SETUP_APP) {
            return None;
        }
        Some(StatusReport {
            record_id: e.str("id").or_else(|| rec.str("id")).unwrap_or("").to_string(),
            state: rec.text("state")?,
            kind: rec.text("kind"),
            app: rec.text("effective_app").or_else(|| rec.text("app")),
            title: rec.text("title"),
            msg: rec.text("msg"),
        })
    }
}

/// What the relay reacts to, already reduced from Rex events.
#[derive(Clone, Debug)]
pub enum RelayEvent {
    Status(BlockRef, StatusReport),
    StatusRemoved(BlockRef, Vec<String>),
    Notification(BlockRef, Option<String>, String),
    BlockClosed(BlockRef),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PushCategory {
    Blocked,
    Done,
    Notice,
}

impl PushCategory {
    pub fn as_str(self) -> &'static str {
        match self {
            PushCategory::Blocked => "AGENT_BLOCKED",
            PushCategory::Done => "AGENT_DONE",
            PushCategory::Notice => "NOTICE",
        }
    }
}

/// A push the policy decided to send, before it's dressed with tab and session names.
#[derive(Clone, Debug, PartialEq)]
pub struct PushIntent {
    pub category: PushCategory,
    pub block: BlockRef,
    /// done / error / blocked for status pushes, None for notices.
    pub state: Option<String>,
    pub record_id: Option<String>,
    pub blocked_kind: Option<String>,
    pub agent: Option<String>,
    pub headline: Option<String>,
    pub text: Option<String>,
}

impl PushIntent {
    pub fn new(category: PushCategory, block: BlockRef) -> Self {
        PushIntent {
            category,
            block,
            state: None,
            record_id: None,
            blocked_kind: None,
            agent: None,
            headline: None,
            text: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
#[allow(clippy::large_enum_variant)] // short-lived, one per event
pub enum Decision {
    Push(PushIntent),
    /// Suppressed for now; call `due` at this time, which may release a trailing push.
    Deferred(f64),
    Drop(&'static str),
}

struct Pending {
    intent: PushIntent,
    due: f64,
    record_key: String,
}

/// - blocked: pushed when a record enters `blocked` (or reports a new message while blocked).
///   At most once per block per `debounce` window; a block that blocks again inside the window
///   gets one trailing push at the window's end if it's still blocked then.
/// - done / error: pushed on entering the state, at most once per block and state per window.
/// - desktop notifications: identical ones from the same block within the window are dropped.
pub struct PushPolicy {
    pub debounce: f64,
    last_state: HashMap<String, String>, // record key -> state
    last_msg: HashMap<String, String>,   // record key -> blocked text
    last_push: HashMap<String, f64>,     // block key + category/state -> time
    pending: HashMap<String, Pending>,   // block key -> trailing blocked push
}

fn block_key(r: &BlockRef) -> String {
    format!("{}|{}", r.server, r.block_id)
}

fn record_key(r: &BlockRef, id: &str) -> String {
    format!("{}|{id}", block_key(r))
}

impl PushPolicy {
    pub fn new(debounce: f64) -> Self {
        PushPolicy {
            debounce,
            last_state: HashMap::new(),
            last_msg: HashMap::new(),
            last_push: HashMap::new(),
            pending: HashMap::new(),
        }
    }

    pub fn next_due(&self) -> Option<f64> {
        self.pending.values().map(|p| p.due).reduce(f64::min)
    }

    pub fn decide(&mut self, event: RelayEvent, now: f64) -> Decision {
        match event {
            RelayEvent::Status(r, rep) => self.status(r, rep, now),
            RelayEvent::StatusRemoved(r, ids) => {
                for id in ids {
                    self.forget_record(&record_key(&r, &id));
                }
                Decision::Drop("status cleared")
            }
            RelayEvent::Notification(r, title, body) => {
                let key = format!("{}|notice|{}|{body}", block_key(&r), title.as_deref().unwrap_or(""));
                if let Some(t) = self.last_push.get(&key) {
                    if now - t < self.debounce {
                        return Decision::Drop("duplicate notification");
                    }
                }
                self.last_push.insert(key, now);
                let mut i = PushIntent::new(PushCategory::Notice, r);
                i.headline = title;
                i.text = Some(body);
                Decision::Push(i)
            }
            RelayEvent::BlockClosed(r) => {
                let bkey = block_key(&r);
                let prefix = format!("{bkey}|");
                self.last_state.retain(|k, _| !k.starts_with(&prefix));
                self.last_msg.retain(|k, _| !k.starts_with(&prefix));
                self.last_push.retain(|k, _| !k.starts_with(&prefix));
                self.pending.remove(&bkey);
                Decision::Drop("block closed")
            }
        }
    }

    fn status(&mut self, r: BlockRef, rep: StatusReport, now: f64) -> Decision {
        let rkey = record_key(&r, &rep.record_id);
        let bkey = block_key(&r);
        let prev = self.last_state.insert(rkey.clone(), rep.state.clone());

        match rep.state.as_str() {
            "blocked" => {
                let text = rep.msg.clone().or_else(|| rep.title.clone()).unwrap_or_default();
                let prev_text = self.last_msg.insert(rkey.clone(), text.clone());
                if prev.as_deref() == Some("blocked") && prev_text.as_deref() == Some(text.as_str()) {
                    return Decision::Drop("repeat report");
                }
                let intent = PushIntent {
                    category: PushCategory::Blocked,
                    block: r,
                    state: Some("blocked".into()),
                    record_id: Some(rep.record_id),
                    blocked_kind: rep.kind,
                    agent: rep.app,
                    headline: rep.title,
                    text: rep.msg,
                };
                let pkey = format!("{bkey}|blocked");
                if let Some(&t) = self.last_push.get(&pkey) {
                    if now - t < self.debounce {
                        let due = t + self.debounce;
                        self.pending.insert(bkey, Pending { intent, due, record_key: rkey });
                        return Decision::Deferred(due);
                    }
                }
                self.last_push.insert(pkey, now);
                self.pending.remove(&bkey);
                Decision::Push(intent)
            }
            "done" | "error" => {
                self.cancel_pending(&rkey, &bkey);
                self.last_msg.remove(&rkey);
                if prev.as_deref() == Some(rep.state.as_str()) {
                    return Decision::Drop("repeat report");
                }
                let pkey = format!("{bkey}|{}", rep.state);
                if let Some(&t) = self.last_push.get(&pkey) {
                    if now - t < self.debounce {
                        return Decision::Drop("debounced");
                    }
                }
                self.last_push.insert(pkey, now);
                Decision::Push(PushIntent {
                    category: PushCategory::Done,
                    block: r,
                    state: Some(rep.state),
                    record_id: Some(rep.record_id),
                    blocked_kind: None,
                    agent: rep.app,
                    headline: rep.title,
                    text: rep.msg,
                })
            }
            _ => {
                // idle, working, unknown
                self.cancel_pending(&rkey, &bkey);
                self.last_msg.remove(&rkey);
                Decision::Drop("not notable")
            }
        }
    }

    /// Trailing pushes whose window has ended and whose record is still blocked.
    pub fn due(&mut self, now: f64) -> Vec<PushIntent> {
        let ready: Vec<String> = self.pending.iter().filter(|(_, p)| p.due <= now).map(|(k, _)| k.clone()).collect();
        let mut out = vec![];
        for bkey in ready {
            let p = self.pending.remove(&bkey).unwrap();
            if self.last_state.get(&p.record_key).map(String::as_str) != Some("blocked") {
                continue;
            }
            self.last_push.insert(format!("{bkey}|blocked"), now);
            out.push(p.intent);
        }
        out
    }

    fn cancel_pending(&mut self, rkey: &str, bkey: &str) {
        if self.pending.get(bkey).is_some_and(|p| p.record_key == rkey) {
            self.pending.remove(bkey);
        }
    }

    fn forget_record(&mut self, rkey: &str) {
        self.last_state.remove(rkey);
        self.last_msg.remove(rkey);
        self.pending.retain(|_, p| p.record_key != rkey);
    }
}

/// Token bucket per device: `capacity` pushes at once, refilled at `per_minute`.
pub struct RateLimiter {
    pub capacity: f64,
    pub per_minute: f64,
    buckets: HashMap<String, (f64, f64)>, // key -> (tokens, at)
}

impl RateLimiter {
    pub fn new(capacity: f64, per_minute: f64) -> Self {
        RateLimiter { capacity, per_minute, buckets: HashMap::new() }
    }

    pub fn allow(&mut self, key: &str, now: f64) -> bool {
        let (mut tokens, at) = self.buckets.get(key).copied().unwrap_or((self.capacity, now));
        tokens = self.capacity.min(tokens + (now - at) * self.per_minute / 60.0);
        let ok = tokens >= 1.0;
        if ok {
            tokens -= 1.0;
        }
        self.buckets.insert(key.to_string(), (tokens, now));
        ok
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::push::{BlockContext, PushMessage};
    use serde_json::json;

    const T0: f64 = 1_000_000.0;
    fn at(s: f64) -> f64 {
        T0 + s
    }
    fn block(b: &str) -> BlockRef {
        BlockRef { server: "https://rex.example.ts.net".into(), session_id: "session:s1".into(), block_id: b.into() }
    }
    fn status_on(state: &str, msg: Option<&str>, id: &str, b: &str) -> RelayEvent {
        RelayEvent::Status(
            block(b),
            StatusReport {
                record_id: id.into(),
                state: state.into(),
                kind: Some("question".into()),
                app: Some("claude".into()),
                title: None,
                msg: msg.map(Into::into),
            },
        )
    }
    fn status(state: &str, msg: Option<&str>) -> RelayEvent {
        status_on(state, msg, "", "block:b1")
    }
    #[test]
    fn the_installers_own_status_is_not_an_agents() {
        let done = json!({"id": "rexduo-setup", "record": {"state": "done", "app": "rexduo-setup", "msg": "Installed."}});
        assert!(StatusReport::from_event(&done).is_none());
        let asking = json!({"id": "rexduo-setup", "record": {"state": "blocked", "kind": "auth", "app": "rexduo-setup"}});
        assert!(StatusReport::from_event(&asking).is_none());
        let agent = json!({"id": "r", "record": {"state": "done", "app": "claude"}});
        assert!(StatusReport::from_event(&agent).is_some());
    }

    fn intent(d: Decision) -> Option<PushIntent> {
        match d {
            Decision::Push(i) => Some(i),
            _ => None,
        }
    }

    #[test]
    fn blocked_pushes() {
        let mut p = PushPolicy::new(30.0);
        let i = intent(p.decide(status("blocked", Some("Which DB?")), T0)).unwrap();
        assert_eq!(i.category, PushCategory::Blocked);
        assert_eq!(i.agent.as_deref(), Some("claude"));
        assert_eq!(i.text.as_deref(), Some("Which DB?"));
        assert_eq!(i.blocked_kind.as_deref(), Some("question"));
    }

    #[test]
    fn repeated_blocked_report_is_dropped() {
        let mut p = PushPolicy::new(30.0);
        p.decide(status("blocked", Some("Q")), T0);
        assert_eq!(p.decide(status("blocked", Some("Q")), at(5.0)), Decision::Drop("repeat report"));
        // Same report much later is still the same blocked state.
        assert_eq!(p.decide(status("blocked", Some("Q")), at(500.0)), Decision::Drop("repeat report"));
    }

    #[test]
    fn flapping_is_deferred_to_one_trailing_push() {
        let mut p = PushPolicy::new(30.0);
        assert!(intent(p.decide(status("blocked", Some("Q1")), T0)).is_some());
        p.decide(status("working", None), at(3.0));
        assert_eq!(p.decide(status("blocked", Some("Q2")), at(5.0)), Decision::Deferred(at(30.0)));
        assert_eq!(p.next_due(), Some(at(30.0)));
        assert!(p.due(at(29.0)).is_empty());
        let trailing = p.due(at(30.0));
        assert_eq!(trailing.len(), 1);
        assert_eq!(trailing[0].text.as_deref(), Some("Q2"));
        assert_eq!(p.next_due(), None);
    }

    #[test]
    fn trailing_push_cancelled_when_unblocked() {
        let mut p = PushPolicy::new(30.0);
        p.decide(status("blocked", Some("Q1")), T0);
        p.decide(status("working", None), at(2.0));
        p.decide(status("blocked", Some("Q2")), at(4.0));
        p.decide(status("working", None), at(6.0));
        assert!(p.due(at(31.0)).is_empty());
    }

    #[test]
    fn blocked_again_after_window_pushes_immediately() {
        let mut p = PushPolicy::new(30.0);
        p.decide(status("blocked", Some("Q1")), T0);
        p.decide(status("working", None), at(10.0));
        assert!(intent(p.decide(status("blocked", Some("Q2")), at(31.0))).is_some());
    }

    #[test]
    fn debounce_is_per_block() {
        let mut p = PushPolicy::new(30.0);
        assert!(intent(p.decide(status("blocked", Some("Q")), T0)).is_some());
        assert!(intent(p.decide(status_on("blocked", Some("Q"), "", "block:b2"), at(1.0))).is_some());
    }

    #[test]
    fn done_and_error_are_passive_done_pushes() {
        let mut p = PushPolicy::new(30.0);
        p.decide(status("working", None), T0);
        let done = intent(p.decide(status("done", Some("All good")), at(1.0))).unwrap();
        assert_eq!(done.category, PushCategory::Done);
        assert_eq!(done.state.as_deref(), Some("done"));
        assert_eq!(p.decide(status("done", Some("All good")), at(2.0)), Decision::Drop("repeat report"));
        let err = intent(p.decide(status("error", Some("boom")), at(3.0))).unwrap();
        assert_eq!(err.state.as_deref(), Some("error"));
        let m = PushMessage::compose(&err, &BlockContext { tab_label: Some("api".into()), ..Default::default() });
        assert_eq!(m.interruption_level, "passive");
        assert!(!m.sound);
        assert_eq!(m.body, "Error: boom");
    }

    #[test]
    fn done_flap_within_window_is_dropped() {
        let mut p = PushPolicy::new(30.0);
        assert!(intent(p.decide(status("done", None), T0)).is_some());
        p.decide(status("working", None), at(2.0));
        assert_eq!(p.decide(status("done", None), at(4.0)), Decision::Drop("debounced"));
        p.decide(status("working", None), at(40.0));
        assert!(intent(p.decide(status("done", None), at(41.0))).is_some());
    }

    #[test]
    fn working_and_idle_never_push() {
        let mut p = PushPolicy::new(30.0);
        assert_eq!(p.decide(status("working", None), T0), Decision::Drop("not notable"));
        assert_eq!(p.decide(status("idle", None), T0), Decision::Drop("not notable"));
    }

    #[test]
    fn cleared_record_forgets_state() {
        let mut p = PushPolicy::new(30.0);
        p.decide(status_on("blocked", Some("Q"), "a", "block:b1"), T0);
        p.decide(RelayEvent::StatusRemoved(block("block:b1"), vec!["a".into()]), at(40.0));
        assert!(intent(p.decide(status_on("blocked", Some("Q"), "a", "block:b1"), at(41.0))).is_some());
    }

    #[test]
    fn closed_block_forgets_state() {
        let mut p = PushPolicy::new(30.0);
        p.decide(status("blocked", Some("Q1")), T0);
        p.decide(status("working", None), at(1.0));
        p.decide(status("blocked", Some("Q2")), at(2.0));
        p.decide(RelayEvent::BlockClosed(block("block:b1")), at(3.0));
        assert_eq!(p.next_due(), None);
        assert!(intent(p.decide(status("blocked", Some("Q1")), at(4.0))).is_some());
    }

    #[test]
    fn notifications_deduped() {
        let mut p = PushPolicy::new(30.0);
        let n = || RelayEvent::Notification(block("block:b1"), None, "Build finished".into());
        assert_eq!(intent(p.decide(n(), T0)).unwrap().category, PushCategory::Notice);
        assert_eq!(p.decide(n(), at(5.0)), Decision::Drop("duplicate notification"));
        let other = RelayEvent::Notification(block("block:b1"), None, "Other".into());
        assert!(intent(p.decide(other, at(6.0))).is_some());
        assert!(intent(p.decide(n(), at(31.0))).is_some());
    }

    #[test]
    fn rate_limiter() {
        let mut r = RateLimiter::new(3.0, 6.0);
        assert!(r.allow("d", T0));
        assert!(r.allow("d", T0));
        assert!(r.allow("d", T0));
        assert!(!r.allow("d", T0));
        assert!(r.allow("other", T0));
        assert!(!r.allow("d", at(5.0)));
        assert!(r.allow("d", at(10.0))); // 6/min refills one every 10 s
    }

    #[test]
    fn status_report_parsing() {
        let e = json!({"id": "", "reason": "report",
                       "record": {"state": "blocked", "kind": "permission", "app": "claude",
                                  "effective_app": "claude", "msg": "Allow?", "updated_at": "2026-11-16T00:00:00Z"}});
        let r = StatusReport::from_event(&e).unwrap();
        assert_eq!(r.state, "blocked");
        assert_eq!(r.kind.as_deref(), Some("permission"));
        assert_eq!(r.msg.as_deref(), Some("Allow?"));
        assert!(StatusReport::from_event(&json!({"id": ""})).is_none());
    }
}
