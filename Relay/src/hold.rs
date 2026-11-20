//! What Beacon holds back while the person is at a desk (`desk.rs`, `presence.rs`), per
//! phone, and the rules that decide it (Relay/README.md, "Desk presence"):
//!
//! - parked.json: questions (`blocked`) held at a desk. One held at this computer's desk is
//!   sent when that desk goes away; one the gateway held for a desk elsewhere (`remote`) when a
//!   look at the gateway finds nobody there (`probes`); either after `HOLD_CAP` at most, if the
//!   agent still waits.
//! - delivered.json: what each phone was last sent for each pane, so a `done` at a desk still
//!   replaces a question the phone shows.
//!
//! Pure but for the two files, which a dry run doesn't write.

use crate::auth::is_device_id;
use crate::desk::{Moment, HOLD_CAP};
use crate::devices::write_json;
use crate::info;
use crate::policy::{BlockRef, PushCategory, PushIntent};
use crate::presence::PROBE_EVERY;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

pub const PARKED_FILE: &str = "parked.json";
pub const DELIVERED_FILE: &str = "delivered.json";
/// The most panes remembered across all phones; past it the oldest goes.
pub const DELIVERED_LIMIT: usize = 512;
/// The most questions held at once. Past it a question is sent rather than held.
pub const PARKED_LIMIT: usize = 256;

/// Why a push goes out.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SendKind {
    /// A fresh event, sent at once.
    Fresh,
    /// A held question waited `HOLD_CAP`.
    Cap,
    /// The desk went away (lock, idle, another user, sleep, the desktop app left).
    Away,
    /// A `done` that replaces the question the phone shows.
    Replace,
    /// A question the gateway holds for a desk elsewhere, asked about again (`PROBE_EVERY`):
    /// sent if nobody is at that desk any more, held again if someone is.
    Probe,
}

impl SendKind {
    /// Only a fresh event, and the gateway's own question held for a desk asked about again,
    /// may be held at the gateway (`hold_if_desk`). A send that ends a hold (the cap, a desk
    /// here going away, a done replacing a question) never may, so a desk that wrongly looks
    /// present delays a question by `HOLD_CAP` at most.
    pub fn may_hold(self) -> bool {
        matches!(self, SendKind::Fresh | SendKind::Probe)
    }

    pub fn as_str(self) -> &'static str {
        match self {
            SendKind::Fresh => "fresh",
            SendKind::Cap => "held 10 min",
            SendKind::Away => "desk away",
            SendKind::Replace => "replaces the question",
            SendKind::Probe => "nobody at the desk any more",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Verdict {
    /// Send it now, under this collapse id when one is given.
    Send(SendKind, Option<String>),
    /// Hold it.
    Park,
    /// A new message for a held question: kept, and its wait goes on.
    Updated,
    Drop(&'static str),
}

/// One held question for one phone.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Parked {
    pub device_id: String,
    pub intent: PushIntent,
    /// When it was parked, on the wall clock (seconds since 1970).
    pub parked_at: f64,
    /// The same on this process's monotonic clock; not kept across a restart.
    #[serde(skip)]
    pub mono: Option<f64>,
    /// Held by the gateway for a desk elsewhere, not by this computer's desk.
    #[serde(default)]
    pub remote: bool,
}

impl Parked {
    fn since(&self) -> Moment {
        Moment { wall: self.parked_at, mono: self.mono }
    }

    pub fn record(&self) -> &str {
        record(&self.intent)
    }

    fn is(&self, device_id: &str, b: &BlockRef) -> bool {
        self.device_id == device_id && same_block(&self.intent.block, b)
    }
}

/// What a phone was last sent for a pane.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Delivered {
    pub device_id: String,
    pub server: String,
    pub block_id: String,
    pub category: PushCategory,
    pub record_id: String,
    #[serde(default)]
    pub collapse_id: Option<String>,
    pub at: f64,
}

impl Delivered {
    fn is(&self, device_id: &str, b: &BlockRef) -> bool {
        self.device_id == device_id && self.server == b.server && self.block_id == b.block_id
    }
}

fn same_block(a: &BlockRef, b: &BlockRef) -> bool {
    a.server == b.server && a.block_id == b.block_id
}

fn record(i: &PushIntent) -> &str {
    i.record_id.as_deref().unwrap_or("")
}

pub struct Holds {
    parked: Vec<Parked>,
    delivered: Vec<Delivered>,
    /// The state folder, or None to keep everything in memory (a dry run).
    dir: Option<PathBuf>,
    /// How long a question is held at most (`HOLD_CAP`; a dry run may shorten it, to try it).
    cap: f64,
    /// (phone, server) -> when the gateway was last asked about its questions held elsewhere.
    asked: HashMap<(String, String), Moment>,
}

/// The entries of a file that read as `T` and pass `ok`. A file that doesn't read, or has
/// entries that don't, is kept beside it as `<name>.bad` and logged; Beacon goes on with what
/// it could read.
fn entries<T: serde::de::DeserializeOwned>(path: &Path, ok: impl Fn(&T) -> bool) -> Vec<T> {
    let Ok(data) = std::fs::read(path) else { return vec![] };
    let bad = || {
        let keep = path.with_extension("json.bad");
        match std::fs::copy(path, &keep) {
            Ok(_) => info!("{} could not be read in full; what could not is kept as {}", path.display(), keep.display()),
            Err(e) => info!("{} could not be read in full, nor kept aside: {e}", path.display()),
        }
    };
    let Ok(values) = serde_json::from_slice::<Vec<Value>>(&data) else {
        bad();
        return vec![];
    };
    let n = values.len();
    let read: Vec<T> = values.into_iter().filter_map(|v| serde_json::from_value(v).ok()).filter(|e| ok(e)).collect();
    if read.len() != n {
        bad();
    }
    read
}

impl Holds {
    /// What the state folder holds, or nothing when `dir` is None.
    pub fn load(dir: Option<&Path>) -> Holds {
        let (parked, delivered) = match dir {
            Some(d) => (
                entries::<Parked>(&d.join(PARKED_FILE), |p| is_device_id(&p.device_id) && p.intent.category == PushCategory::Blocked),
                entries::<Delivered>(&d.join(DELIVERED_FILE), |e| is_device_id(&e.device_id)),
            ),
            None => (vec![], vec![]),
        };
        Holds { parked, delivered, dir: dir.map(Path::to_path_buf), cap: HOLD_CAP, asked: HashMap::new() }
    }

    /// A shorter cap, for a dry run that tries it out.
    pub fn set_cap(&mut self, cap: f64) {
        self.cap = cap;
    }

    pub fn parked(&self) -> &[Parked] {
        &self.parked
    }

    #[cfg(test)]
    pub fn delivered(&self) -> &[Delivered] {
        &self.delivered
    }

    fn save_parked(&self) {
        if let Some(d) = &self.dir {
            write_json(&d.join(PARKED_FILE), &self.parked);
        }
    }

    fn save_delivered(&self) {
        if let Some(d) = &self.dir {
            write_json(&d.join(DELIVERED_FILE), &self.delivered);
        }
    }

    /// The rules for one fresh event and one phone. `here`: someone is at a desk that shows
    /// the event's server. It parks, updates and unparks as it decides.
    pub fn decide(&mut self, device_id: &str, intent: &PushIntent, here: bool, now: Moment) -> Verdict {
        let b = &intent.block;
        let held = self.parked.iter().position(|p| p.is(device_id, b));
        match intent.category {
            PushCategory::Blocked => {
                if !here {
                    // Sent now, so it holds nothing any more (`sent` unparks it once it went).
                    return Verdict::Send(SendKind::Fresh, None);
                }
                if let Some(i) = held {
                    if self.parked[i].record() == record(intent) {
                        // Same question, new words: the wait goes on, now at this desk.
                        self.parked[i].intent = intent.clone();
                        self.parked[i].remote = false;
                        self.save_parked();
                        return Verdict::Updated;
                    }
                    // Another question: its wait starts now.
                    self.parked[i] = Parked { device_id: device_id.into(), intent: intent.clone(), parked_at: now.wall, mono: now.mono, remote: false };
                    self.save_parked();
                    return Verdict::Park;
                }
                // The phone shows an earlier question of this pane: replace it now.
                if self.delivered.iter().any(|e| e.is(device_id, b) && e.category == PushCategory::Blocked && e.record_id != record(intent)) {
                    return Verdict::Send(SendKind::Fresh, None);
                }
                if self.parked.len() >= PARKED_LIMIT {
                    return Verdict::Send(SendKind::Fresh, None);
                }
                self.parked.push(Parked { device_id: device_id.into(), intent: intent.clone(), parked_at: now.wall, mono: now.mono, remote: false });
                self.save_parked();
                Verdict::Park
            }
            PushCategory::Done => {
                // The agent finished: a question of the same record that was held is moot.
                if let Some(i) = held.filter(|&i| self.parked[i].record() == record(intent)) {
                    self.parked.remove(i);
                    self.save_parked();
                }
                // The phone shows this pane's question: the done replaces it, at a desk or not,
                // and is never held, so no stale question stays on the phone.
                match self.delivered.iter().find(|e| e.is(device_id, b)) {
                    Some(e) if e.category == PushCategory::Blocked => Verdict::Send(SendKind::Replace, e.collapse_id.clone()),
                    _ if here => Verdict::Drop("at the desk"),
                    _ => Verdict::Send(SendKind::Fresh, None),
                }
            }
            PushCategory::Notice => {
                if here {
                    Verdict::Drop("at the desk")
                } else {
                    Verdict::Send(SendKind::Fresh, None)
                }
            }
        }
    }

    /// The gateway accepted `intent` for this phone, under `collapse_id`: remembers an agent
    /// push as what the phone shows for the pane, and ends a hold of that pane's question.
    pub fn sent(&mut self, device_id: &str, intent: &PushIntent, collapse_id: Option<&str>, at: f64) {
        let b = &intent.block;
        let n = self.parked.len();
        if intent.category == PushCategory::Blocked {
            self.parked.retain(|p| !p.is(device_id, b));
        }
        if self.parked.len() != n {
            self.save_parked();
        }
        if intent.category == PushCategory::Notice {
            return;
        }
        self.delivered.retain(|e| !e.is(device_id, b));
        if self.delivered.len() >= DELIVERED_LIMIT {
            self.delivered.remove(0);
        }
        self.delivered.push(Delivered {
            device_id: device_id.into(),
            server: b.server.clone(),
            block_id: b.block_id.clone(),
            category: intent.category,
            record_id: record(intent).into(),
            collapse_id: collapse_id.map(String::from),
            at,
        });
        self.save_delivered();
    }

    /// An agent's record left `blocked` (it works, is idle, is done, or was removed): nothing of
    /// it waits any more. `record` None: every record of the pane. Returns how many were held.
    pub fn moved_on(&mut self, b: &BlockRef, record_id: Option<&str>) -> usize {
        let n = self.parked.len();
        self.parked.retain(|p| !(same_block(&p.intent.block, b) && record_id.is_none_or(|r| p.record() == r)));
        let gone = n - self.parked.len();
        if gone > 0 {
            self.save_parked();
        }
        gone
    }

    /// The pane closed: nothing of it is held or remembered.
    pub fn closed(&mut self, b: &BlockRef) {
        self.moved_on(b, None);
        let n = self.delivered.len();
        self.delivered.retain(|e| !(e.server == b.server && e.block_id == b.block_id));
        if self.delivered.len() != n {
            self.save_delivered();
        }
    }

    /// These records of the pane are gone (the agent quit): nothing of them is held, and no
    /// `done` of theirs will come to replace what the phone shows, so that is forgotten too.
    /// An agent that only stopped waiting (it works, idles) keeps its entry: its `done` still
    /// replaces the question. Returns how many questions were held.
    pub fn records_gone(&mut self, b: &BlockRef, record_ids: &[String]) -> usize {
        let held: usize = record_ids.iter().map(|id| self.moved_on(b, Some(id))).sum();
        let n = self.delivered.len();
        self.delivered.retain(|e| !(e.server == b.server && e.block_id == b.block_id && record_ids.contains(&e.record_id)));
        if self.delivered.len() != n {
            self.save_delivered();
        }
        held
    }

    /// Drops what is held for phones `keep` says no (unregistered, paused).
    pub fn keep_devices(&mut self, keep: impl Fn(&str) -> bool) {
        let n = self.parked.len();
        self.parked.retain(|p| keep(&p.device_id));
        if self.parked.len() != n {
            self.save_parked();
        }
    }

    /// The gateway held `intent` for this phone (`202`): a question waits for a desk elsewhere,
    /// from now, or from when it was first held when it is the same question. False when no more
    /// may be held: then it is sent rather than held.
    pub fn park_remote(&mut self, device_id: &str, intent: &PushIntent, now: Moment) -> bool {
        let b = &intent.block;
        self.asked.insert((device_id.to_string(), b.server.clone()), now);
        if let Some(i) = self.parked.iter().position(|p| p.is(device_id, b)) {
            if self.parked[i].record() == record(intent) {
                self.parked[i].intent = intent.clone();
            } else {
                self.parked[i] = Parked { device_id: device_id.into(), intent: intent.clone(), parked_at: now.wall, mono: now.mono, remote: true };
            }
            self.parked[i].remote = true;
            self.save_parked();
            return true;
        }
        if self.parked.len() >= PARKED_LIMIT {
            return false;
        }
        self.parked.push(Parked { device_id: device_id.into(), intent: intent.clone(), parked_at: now.wall, mono: now.mono, remote: true });
        self.save_parked();
        true
    }

    /// Questions to send now: those held the cap (`Cap`), then those held at this computer's
    /// desk whose server no desk here shows any more (`away(server)`, `Away`). They stay held
    /// until `sent`, so one that could not be sent is tried again.
    pub fn due(&self, now: Moment, away: impl Fn(&str) -> bool) -> Vec<(Parked, SendKind)> {
        let mut out = vec![];
        for p in &self.parked {
            if p.since().elapsed_to(&now) >= self.cap {
                out.push((p.clone(), SendKind::Cap));
            } else if !p.remote && away(&p.intent.block.server) {
                out.push((p.clone(), SendKind::Away));
            }
        }
        out
    }

    /// The questions to ask the gateway about again: of each phone and server with questions
    /// held for a desk elsewhere, the one held longest, once `PROBE_EVERY` has passed since the
    /// last time. A question that is due for its cap is left to `due`.
    pub fn probes(&self, now: Moment) -> Vec<Parked> {
        let mut first: Vec<Parked> = vec![];
        for p in self.parked.iter().filter(|p| p.remote && p.since().elapsed_to(&now) < self.cap) {
            let key = (p.device_id.clone(), p.intent.block.server.clone());
            if self.asked.get(&key).is_some_and(|at| at.elapsed_to(&now) < PROBE_EVERY) {
                continue;
            }
            match first.iter_mut().find(|q| q.device_id == p.device_id && q.intent.block.server == p.intent.block.server) {
                Some(q) if q.parked_at > p.parked_at => *q = p.clone(),
                Some(_) => {}
                None => first.push(p.clone()),
            }
        }
        first
    }

    /// The gateway was asked about this phone's questions of this server at `now`.
    pub fn asked(&mut self, device_id: &str, server: &str, now: Moment) {
        self.asked.insert((device_id.to_string(), server.to_string()), now);
    }

    /// The other questions held elsewhere for this phone and server: once one of them was sent
    /// (nobody is at that desk now), these go too.
    pub fn remote_of(&self, device_id: &str, server: &str) -> Vec<Parked> {
        self.parked.iter().filter(|p| p.remote && p.device_id == device_id && p.intent.block.server == server).cloned().collect()
    }

    /// Unparks the held questions of a server that `waits` says no longer wait. `waits` None:
    /// unknown, kept. Used after a (re)connect, for events Beacon may have missed.
    pub fn recheck(&mut self, server: &str, waits: impl Fn(&Parked) -> Option<bool>) -> usize {
        let n = self.parked.len();
        self.parked.retain(|p| p.intent.block.server != server || waits(p) != Some(false));
        let gone = n - self.parked.len();
        if gone > 0 {
            self.save_parked();
        }
        gone
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PHONE: &str = "a1b2c3d4";
    const OTHER: &str = "ffff0000";
    const SERVER: &str = "https://rex.example.ts.net";
    const T0: f64 = 1_000_000.0;

    fn at(s: f64) -> Moment {
        Moment { wall: T0 + s, mono: Some(s) }
    }

    fn block(b: &str) -> BlockRef {
        BlockRef { server: SERVER.into(), session_id: "session:s1".into(), block_id: b.into() }
    }

    fn event(category: PushCategory, record: &str, text: &str) -> PushIntent {
        let mut i = PushIntent::new(category, block("block:b1"));
        i.record_id = Some(record.into());
        i.state = Some(match category {
            PushCategory::Blocked => "blocked",
            PushCategory::Done => "done",
            PushCategory::Notice => "",
        }.into());
        i.text = Some(text.into());
        i
    }

    fn blocked(record: &str, text: &str) -> PushIntent {
        event(PushCategory::Blocked, record, text)
    }

    fn done(record: &str) -> PushIntent {
        event(PushCategory::Done, record, "Finished")
    }

    fn notice() -> PushIntent {
        PushIntent::new(PushCategory::Notice, block("block:b1"))
    }

    fn fresh() -> Verdict {
        Verdict::Send(SendKind::Fresh, None)
    }

    fn temp(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("hold-{tag}-{}-{}", std::process::id(), crate::util::now()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn nobody_at_the_desk_sends_everything_as_before() {
        let mut h = Holds::load(None);
        for i in [blocked("", "Q"), done(""), notice()] {
            assert_eq!(h.decide(PHONE, &i, false, at(0.0)), fresh(), "{i:?}");
        }
        assert!(h.parked().is_empty());
    }

    #[test]
    fn at_the_desk_a_question_is_held_and_done_and_notices_are_dropped() {
        let mut h = Holds::load(None);
        assert_eq!(h.decide(PHONE, &blocked("", "Which DB?"), true, at(0.0)), Verdict::Park);
        assert_eq!(h.parked().len(), 1);
        // The agent finished while held: the phone never saw the question, and gets nothing.
        assert_eq!(h.decide(PHONE, &done(""), true, at(5.0)), Verdict::Drop("at the desk"));
        assert!(h.parked().is_empty());
        assert_eq!(h.decide(PHONE, &notice(), true, at(6.0)), Verdict::Drop("at the desk"));
        // Another phone is its own.
        assert_eq!(h.decide(OTHER, &blocked("", "Q"), true, at(7.0)), Verdict::Park);
        assert_eq!(h.decide(PHONE, &blocked("", "Q"), false, at(8.0)), fresh());
        assert_eq!(h.parked().len(), 1);
    }

    #[test]
    fn a_new_message_keeps_the_wait_and_a_new_record_restarts_it() {
        let mut h = Holds::load(None);
        h.decide(PHONE, &blocked("r1", "First"), true, at(0.0));
        assert_eq!(h.decide(PHONE, &blocked("r1", "Second"), true, at(300.0)), Verdict::Updated);
        assert_eq!(h.parked()[0].intent.text.as_deref(), Some("Second"));
        assert_eq!(h.parked()[0].parked_at, T0);
        let due = h.due(at(HOLD_CAP), |_| false);
        assert_eq!(due.len(), 1);
        assert_eq!((due[0].1, due[0].0.intent.text.as_deref()), (SendKind::Cap, Some("Second")));
        // Another record of the same pane: a new question, a new wait.
        assert_eq!(h.decide(PHONE, &blocked("r2", "Third"), true, at(500.0)), Verdict::Park);
        assert_eq!(h.parked().len(), 1);
        assert!(h.due(at(HOLD_CAP + 10.0), |_| false).is_empty());
        assert_eq!(h.due(at(500.0 + HOLD_CAP), |_| false).len(), 1);
    }

    #[test]
    fn the_cap_and_the_desk_leaving_release_a_question_once_it_was_sent() {
        let mut h = Holds::load(None);
        let q = blocked("", "Q");
        h.decide(PHONE, &q, true, at(0.0));
        assert!(h.due(at(HOLD_CAP - 1.0), |_| false).is_empty());
        assert_eq!(h.due(at(30.0), |s| s == SERVER)[0].1, SendKind::Away);
        assert!(h.due(at(30.0), |s| s == "https://other.ts.net").is_empty());
        // The send failed (rate limit, no network): still held, and due again at the next look.
        assert_eq!(h.due(at(HOLD_CAP), |_| false)[0].1, SendKind::Cap);
        assert_eq!(h.due(at(HOLD_CAP + 30.0), |_| false)[0].1, SendKind::Cap);
        // Sent: the episode is over. The cap fires once.
        h.sent(PHONE, &q, Some("b1"), T0 + HOLD_CAP + 30.0);
        assert!(h.parked().is_empty());
        assert!(h.due(at(HOLD_CAP * 3.0), |_| true).is_empty());
        assert!(!SendKind::Cap.may_hold() && !SendKind::Away.may_hold() && !SendKind::Replace.may_hold());
        assert!(SendKind::Fresh.may_hold() && SendKind::Probe.may_hold());
    }

    #[test]
    fn a_clock_set_back_or_forward_releases_a_question_rather_than_hold_it_longer() {
        let mut h = Holds::load(None);
        h.decide(PHONE, &blocked("", "Q"), true, at(0.0));
        assert_eq!(h.due(Moment { wall: T0 - 3600.0, mono: Some(20.0) }, |_| false).len(), 1, "set back");
        assert_eq!(h.due(Moment { wall: T0 + 86_400.0, mono: Some(20.0) }, |_| false).len(), 1, "set forward");
        // Slept 20 minutes without a will-sleep (the power source missing): the wall clock counts it.
        assert_eq!(h.due(Moment { wall: T0 + 1200.0, mono: Some(1.0) }, |_| false).len(), 1, "slept");
        assert!(h.due(Moment { wall: T0 + 20.0, mono: Some(20.0) }, |_| false).is_empty());
    }

    #[test]
    fn done_at_the_desk_replaces_a_question_the_phone_shows_under_its_collapse_id() {
        let mut h = Holds::load(None);
        // Sent while away, under the record's collapse id.
        let q = blocked("r1", "Allow?");
        assert_eq!(h.decide(PHONE, &q, false, at(0.0)), fresh());
        h.sent(PHONE, &q, Some("b1-1234"), T0);
        // Back at the desk, the agent finishes (its done can carry another record id).
        assert_eq!(h.decide(PHONE, &done("r2"), true, at(60.0)), Verdict::Send(SendKind::Replace, Some("b1-1234".into())));
        h.sent(PHONE, &done("r2"), Some("b1-1234"), T0 + 60.0);
        // Now the phone shows "Finished": a later done adds nothing.
        assert_eq!(h.decide(PHONE, &done("r2"), true, at(120.0)), Verdict::Drop("at the desk"));
        // Another phone was never sent the question.
        assert_eq!(h.decide(OTHER, &done("r1"), true, at(60.0)), Verdict::Drop("at the desk"));
        // A notice never counts as what the phone shows for the pane.
        h.sent(PHONE, &q, Some("b1-1234"), T0 + 130.0);
        h.sent(PHONE, &notice(), Some("b1-n"), T0 + 131.0);
        assert_eq!(h.decide(PHONE, &done("r1"), true, at(140.0)), Verdict::Send(SendKind::Replace, Some("b1-1234".into())));
    }

    #[test]
    fn away_from_every_desk_a_done_still_replaces_the_question_the_phone_shows() {
        let mut h = Holds::load(None);
        let q = blocked("r1", "Allow?");
        h.sent(PHONE, &q, Some("b1-1"), T0);
        // Never held anywhere: `Replace` may not be held.
        assert_eq!(h.decide(PHONE, &done("r1"), false, at(60.0)), Verdict::Send(SendKind::Replace, Some("b1-1".into())));
        assert!(!SendKind::Replace.may_hold());
        // Nothing shown for the pane: a fresh done, which a desk elsewhere may hold.
        assert_eq!(h.decide(OTHER, &done("r1"), false, at(60.0)), fresh());
    }

    #[test]
    fn a_question_the_gateway_held_waits_for_its_probe_or_its_cap_and_never_for_this_desk() {
        let mut h = Holds::load(None);
        let q = blocked("r1", "Allow?");
        assert_eq!(h.decide(PHONE, &q, false, at(0.0)), fresh());
        assert!(h.park_remote(PHONE, &q, at(0.0)));
        assert!(h.parked()[0].remote);
        // This computer's desk plays no part.
        assert!(h.due(at(30.0), |_| true).is_empty());
        // Asked again one minute after it was held, then every minute.
        assert!(h.probes(at(PROBE_EVERY - 1.0)).is_empty());
        assert_eq!(h.probes(at(PROBE_EVERY)).len(), 1);
        h.asked(PHONE, SERVER, at(PROBE_EVERY));
        assert!(h.probes(at(PROBE_EVERY + 30.0)).is_empty());
        assert_eq!(h.probes(at(2.0 * PROBE_EVERY)).len(), 1);
        // Held again by a probe, or by new words of the same question: the wait goes on.
        let mut again = q.clone();
        again.text = Some("Allow, really?".into());
        assert!(h.park_remote(PHONE, &again, at(300.0)));
        assert_eq!((h.parked().len(), h.parked()[0].parked_at), (1, T0));
        // The cap releases it, and only `due` does.
        assert!(h.probes(at(HOLD_CAP)).is_empty());
        assert_eq!(h.due(at(HOLD_CAP), |_| false)[0].1, SendKind::Cap);
        // Another record restarts the wait.
        assert!(h.park_remote(PHONE, &blocked("r2", "Next?"), at(400.0)));
        assert_eq!(h.parked()[0].parked_at, T0 + 400.0);
    }

    #[test]
    fn one_probe_per_phone_and_server_and_the_others_go_once_one_was_sent() {
        let mut h = Holds::load(None);
        for (n, b) in ["block:b1", "block:b2"].into_iter().enumerate() {
            let mut q = blocked("r", "Q");
            q.block = block(b);
            h.park_remote(PHONE, &q, at(n as f64));
        }
        let mut theirs = blocked("r", "Q");
        theirs.block = block("block:b3");
        h.park_remote(OTHER, &theirs, at(0.0));
        let probes = h.probes(at(PROBE_EVERY + 1.0));
        assert_eq!(probes.len(), 2, "one for each phone");
        assert_eq!(probes.iter().find(|p| p.device_id == PHONE).unwrap().intent.block.block_id, "block:b1", "the oldest");
        assert_eq!(h.remote_of(PHONE, SERVER).len(), 2);
        assert!(h.remote_of(PHONE, "https://other.ts.net").is_empty());
        // Restarted: held questions are asked about at the first look.
        let dir = temp("remote");
        let mut kept = Holds::load(Some(&dir));
        kept.park_remote(PHONE, &blocked("r", "Q"), at(0.0));
        let back = Holds::load(Some(&dir));
        assert!(back.parked()[0].remote);
        assert_eq!(back.probes(at(1.0)).len(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_question_held_elsewhere_becomes_this_desks_when_the_person_sits_here() {
        let mut h = Holds::load(None);
        h.park_remote(PHONE, &blocked("r1", "Q"), at(0.0));
        assert_eq!(h.decide(PHONE, &blocked("r1", "Q, again"), true, at(10.0)), Verdict::Updated);
        assert!(!h.parked()[0].remote);
        assert_eq!(h.due(at(20.0), |_| true)[0].1, SendKind::Away);
        // Past the limit the gateway's hold can't be kept: the caller sends instead.
        let mut full = Holds::load(None);
        for n in 0..PARKED_LIMIT {
            let mut i = blocked("", "Q");
            i.block = block(&format!("block:{n}"));
            assert!(full.park_remote(PHONE, &i, at(0.0)));
        }
        assert!(!full.park_remote(PHONE, &blocked("", "one more"), at(0.0)));
    }

    #[test]
    fn a_shorter_cap_releases_sooner() {
        let mut h = Holds::load(None);
        h.set_cap(60.0);
        h.decide(PHONE, &blocked("", "Q"), true, at(0.0));
        assert_eq!(h.due(at(60.0), |_| false)[0].1, SendKind::Cap);
    }

    #[test]
    fn a_new_question_while_the_phone_shows_an_older_one_goes_now() {
        let mut h = Holds::load(None);
        let q1 = blocked("r1", "First");
        h.sent(PHONE, &q1, Some("b1-1"), T0);
        assert_eq!(h.decide(PHONE, &blocked("r2", "Second"), true, at(10.0)), fresh());
        // The same question again (new words) at the desk is held: the phone shows it already.
        assert_eq!(h.decide(PHONE, &blocked("r1", "First, again"), true, at(20.0)), Verdict::Park);
    }

    #[test]
    fn what_the_phone_shows_is_kept_until_replaced_or_its_record_is_gone() {
        let mut h = Holds::load(None);
        h.sent(PHONE, &blocked("r1", "Q"), Some("b1-1"), T0);
        h.sent(OTHER, &blocked("r2", "Q"), Some("b1-2"), T0);
        // Answered at the desk: the agent works again, then finishes. Its done replaces.
        assert_eq!(h.moved_on(&block("block:b1"), Some("r1")), 0);
        assert_eq!(h.decide(PHONE, &done("r1"), true, at(60.0)), Verdict::Send(SendKind::Replace, Some("b1-1".into())));
        // The agent of r2 quit: its record is gone, and no done will come.
        assert_eq!(h.records_gone(&block("block:b1"), &["r2".into()]), 0);
        assert_eq!(h.decide(OTHER, &done("r3"), true, at(60.0)), Verdict::Drop("at the desk"));
        assert_eq!(h.delivered().len(), 1);
        // A held question whose record went is released from the hold too.
        h.decide(OTHER, &blocked("r4", "Q"), true, at(70.0));
        assert_eq!(h.records_gone(&block("block:b1"), &["r4".into()]), 1);
    }

    #[test]
    fn a_closed_pane_and_an_agent_that_moved_on_hold_nothing() {
        let mut h = Holds::load(None);
        h.decide(PHONE, &blocked("r1", "Q"), true, at(0.0));
        h.decide(OTHER, &blocked("r1", "Q"), true, at(0.0));
        assert_eq!(h.moved_on(&block("block:b1"), Some("r2")), 0);
        assert_eq!(h.moved_on(&block("block:b1"), Some("r1")), 2);
        h.decide(PHONE, &blocked("r1", "Q"), true, at(1.0));
        h.sent(OTHER, &blocked("r1", "Q"), None, T0);
        h.closed(&block("block:b1"));
        assert!(h.parked().is_empty() && h.delivered().is_empty());
    }

    #[test]
    fn the_delivered_list_is_bounded_oldest_out() {
        let mut h = Holds::load(None);
        for n in 0..DELIVERED_LIMIT + 3 {
            let mut i = blocked("", "Q");
            i.block = block(&format!("block:{n}"));
            h.sent(PHONE, &i, None, T0 + n as f64);
        }
        assert_eq!(h.delivered().len(), DELIVERED_LIMIT);
        assert_eq!(h.delivered()[0].block_id, "block:3");
    }

    #[test]
    fn past_the_limit_a_question_is_sent_rather_than_held() {
        let mut h = Holds::load(None);
        for n in 0..PARKED_LIMIT {
            let mut i = blocked("", "Q");
            i.block = block(&format!("block:{n}"));
            assert_eq!(h.decide(PHONE, &i, true, at(0.0)), Verdict::Park);
        }
        let mut one_more = blocked("", "Q");
        one_more.block = block("block:last");
        assert_eq!(h.decide(PHONE, &one_more, true, at(0.0)), fresh());
    }

    #[test]
    fn a_held_question_keeps_the_wait_it_is_about_and_one_parked_before_reads_without_it() {
        let dir = temp("wait-kept");
        let mut h = Holds::load(Some(&dir));
        let mut q = blocked("r1", "Q1");
        q.fp = Some("d110a7daf17e741b".into());
        h.decide(PHONE, &q, true, at(0.0));
        // New words for the same record: the wait is the new one's.
        let mut q2 = blocked("r1", "Q2");
        q2.fp = Some("07d16acb842d33f1".into());
        assert_eq!(h.decide(PHONE, &q2, true, at(1.0)), Verdict::Updated);
        let back = Holds::load(Some(&dir));
        assert_eq!(back.parked().len(), 1);
        assert_eq!((back.parked()[0].record(), back.parked()[0].intent.fp.as_deref()), ("r1", Some("07d16acb842d33f1")));
        assert_eq!(back.parked()[0].intent, q2);

        // parked.json as 0.5.0 wrote it, with no `fp`: it reads, and has no wait to name.
        let old = r#"[{"device_id":"a1b2c3d4","intent":{"category":"Blocked","block":{"server":"https://rex.example.ts.net","session_id":"session:s1","block_id":"block:b1"},"state":"blocked","record_id":"r1","blocked_kind":null,"agent":null,"headline":null,"text":"Q1"},"parked_at":1000000.0,"remote":false}]"#;
        std::fs::write(dir.join(PARKED_FILE), old).unwrap();
        let before = Holds::load(Some(&dir));
        assert_eq!(before.parked().len(), 1);
        assert_eq!(before.parked()[0].intent, blocked("r1", "Q1"));
        assert_eq!(before.parked()[0].intent.fp, None);
        assert!(!dir.join("parked.json.bad").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn both_files_survive_a_restart_and_a_recheck_drops_what_no_longer_waits() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temp("restart");
        let mut h = Holds::load(Some(&dir));
        h.decide(PHONE, &blocked("r1", "Q1"), true, at(0.0));
        let mut q2 = blocked("r2", "Q2");
        q2.block = block("block:b2");
        h.decide(PHONE, &q2, true, at(100.0));
        h.sent(OTHER, &blocked("r1", "Q1"), Some("b1-x"), T0);
        for f in [PARKED_FILE, DELIVERED_FILE] {
            assert_eq!(std::fs::metadata(dir.join(f)).unwrap().permissions().mode() & 0o777, 0o600, "{f}");
        }

        // Restarted: the wall clock carries the waits on.
        let mut back = Holds::load(Some(&dir));
        assert_eq!(back.parked().len(), 2);
        assert!(back.parked().iter().all(|p| p.mono.is_none()));
        let after = Moment { wall: T0 + HOLD_CAP + 1.0, mono: Some(0.5) };
        assert_eq!(back.due(after, |_| false).len(), 1, "only the first has waited 10 minutes");
        assert_eq!(back.decide(OTHER, &done("r1"), true, at(700.0)), Verdict::Send(SendKind::Replace, Some("b1-x".into())));
        // Asked again after the reconnect: r2 no longer waits, r1 couldn't be asked.
        assert_eq!(back.recheck(SERVER, |p| if p.record() == "r2" { Some(false) } else { None }), 1);
        assert_eq!(back.recheck("https://other.ts.net", |_| Some(false)), 0);
        assert_eq!(Holds::load(Some(&dir)).parked().len(), 1);

        // Files written by hand or damaged: what doesn't read is dropped, the rest kept, the
        // file as it was kept aside as `.bad`, and the helper carries on.
        let good = std::fs::read_to_string(dir.join(PARKED_FILE)).unwrap();
        let mut entries: Vec<Value> = serde_json::from_str(&good).unwrap();
        entries.push(serde_json::json!({"device_id": "nope"}));
        entries.push(serde_json::json!(7));
        let mixed = serde_json::to_string(&entries).unwrap();
        std::fs::write(dir.join(PARKED_FILE), &mixed).unwrap();
        std::fs::write(dir.join(DELIVERED_FILE), "{").unwrap();
        let damaged = Holds::load(Some(&dir));
        assert_eq!(damaged.parked().len(), 1);
        assert!(damaged.delivered().is_empty());
        assert_eq!(std::fs::read_to_string(dir.join("parked.json.bad")).unwrap(), mixed);
        assert_eq!(std::fs::read_to_string(dir.join("delivered.json.bad")).unwrap(), "{");
        // A whole file that reads is not set aside.
        std::fs::remove_file(dir.join("parked.json.bad")).unwrap();
        std::fs::write(dir.join(PARKED_FILE), &good).unwrap();
        Holds::load(Some(&dir));
        assert!(!dir.join("parked.json.bad").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_dry_run_writes_nothing() {
        let dir = temp("dry");
        let mut h = Holds::load(None);
        h.decide(PHONE, &blocked("", "Q"), true, at(0.0));
        h.sent(PHONE, &blocked("", "Q"), None, T0);
        assert!(!dir.join(PARKED_FILE).exists() && !dir.join(DELIVERED_FILE).exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_phone_that_left_or_paused_holds_nothing() {
        let mut h = Holds::load(None);
        h.decide(PHONE, &blocked("", "Q"), true, at(0.0));
        h.decide(OTHER, &blocked("", "Q"), true, at(0.0));
        h.keep_devices(|d| d == OTHER);
        assert_eq!(h.parked().len(), 1);
        assert_eq!(h.parked()[0].device_id, OTHER);
    }
}
