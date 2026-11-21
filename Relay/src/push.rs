//! Turns a push intent into the APNs payload the app reads (`server`, `session_id`,
//! `window_id`, `block_id`, categories, thread and collapse ids, and for a question the wait
//! it is about: `record` and `fp`).

use crate::policy::{BlockRef, PushCategory, PushIntent};
use serde_json::{json, Value};

/// Names the relay looks up for a block, to make a push readable.
#[derive(Clone, Debug, Default)]
pub struct BlockContext {
    pub window_id: Option<String>,
    pub tab_label: Option<String>,
    pub block_label: Option<String>,
    pub session_label: Option<String>,
}

/// The wait a question's push is about, which lets the app answer it from the notification
/// (Enter, Interrupt): the status record's id and the wait's fingerprint
/// (`policy::fingerprint`). The app types only while the pane still shows this wait.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Wait {
    pub record: String,
    pub fp: String,
}

/// The category of a question that names its wait. The app gives it the two actions;
/// `AGENT_BLOCKED` has none, so a push that can't name its wait shows no button.
pub const BLOCKED_ACT: &str = "AGENT_BLOCKED_ACT";

/// The most bytes a record id may have to go into a push (the gateway takes 128 characters).
pub const MAX_RECORD_BYTES: usize = 128;

/// Apple's limit for a payload, which the gateway enforces on the text it passes on.
pub const MAX_PAYLOAD_BYTES: usize = 4096;

impl Wait {
    /// The wait of a question, when the push can name it: a fingerprint, and a record id
    /// that is not empty (the app refuses an empty one), within the gateway's length, and
    /// written as an identifier: ASCII letters, digits and `. _ : -`. The id is the reporting
    /// program's own and goes into the push as it is, so one that reads like text (a space,
    /// any other character) is not sent: a push carries no words but its title and body.
    pub fn of(i: &PushIntent) -> Option<Wait> {
        if i.category != PushCategory::Blocked {
            return None;
        }
        let (record, fp) = (i.record_id.as_deref()?, i.fp.as_deref()?);
        let identifier = record.bytes().all(|b| b.is_ascii_alphanumeric() || b".-_:".contains(&b));
        let fits = !record.is_empty() && record.len() <= MAX_RECORD_BYTES && identifier;
        fits.then(|| Wait { record: record.into(), fp: fp.into() })
    }
}

/// One push, ready for any device.
#[derive(Clone, Debug)]
pub struct PushMessage {
    pub category: PushCategory,
    pub title: String,
    pub subtitle: Option<String>,
    pub body: String,
    /// passive | active | time-sensitive
    pub interruption_level: &'static str,
    pub sound: bool,
    pub thread_id: String,
    pub collapse_id: Option<String>,
    pub server: String,
    pub session_id: String,
    pub window_id: Option<String>,
    pub block_id: String,
    /// The wait a question is about. With it the category is `BLOCKED_ACT`.
    pub wait: Option<Wait>,
    /// The desks whose presence may hold this push at the gateway (`hold_if_desk`), set per
    /// phone and only on a send that may be held (`hold::SendKind::may_hold`).
    pub hold_if_desk: Option<Vec<String>>,
}

impl PushMessage {
    /// APNs priority: 10 delivers now, 5 lets the system batch passive pushes.
    pub fn priority(&self) -> u8 {
        if self.interruption_level == "passive" {
            5
        } else {
            10
        }
    }

    /// The same push without the wait: the category without actions and no `record` or `fp`,
    /// which is the payload every gateway takes.
    pub fn without_wait(&self) -> PushMessage {
        PushMessage { wait: None, ..self.clone() }
    }

    /// The category as the phone gets it: a question that names its wait has the actions.
    pub fn category_name(&self) -> &'static str {
        match self.wait {
            Some(_) => BLOCKED_ACT,
            None => self.category.as_str(),
        }
    }

    /// The JSON body APNs gets: the gateway passes it on as it is. It is never larger than
    /// `MAX_PAYLOAD_BYTES` as long as the fields beside the body leave room: a body that
    /// would take it over is cut shorter, since every other field is needed to show the push,
    /// open its pane or answer it.
    pub fn payload(&self) -> Value {
        let whole = self.payload_with(&self.body);
        if whole.to_string().len() <= MAX_PAYLOAD_BYTES {
            return whole;
        }
        let room = MAX_PAYLOAD_BYTES.saturating_sub(self.payload_with("").to_string().len());
        self.payload_with(&fit(&self.body, room))
    }

    fn payload_with(&self, body: &str) -> Value {
        let mut alert = json!({"title": self.title, "body": body});
        if let Some(s) = &self.subtitle {
            alert["subtitle"] = json!(s);
        }
        let mut aps = json!({
            "alert": alert,
            "interruption-level": self.interruption_level,
            "thread-id": self.thread_id,
            "category": self.category_name(),
        });
        if self.sound {
            aps["sound"] = json!("default");
        }
        let mut p = json!({"aps": aps, "server": self.server});
        // A test notification is about no session and no pane.
        for (key, id) in [("session_id", &self.session_id), ("block_id", &self.block_id)] {
            if !id.is_empty() {
                p[key] = json!(id);
            }
        }
        if let Some(w) = &self.window_id {
            p["window_id"] = json!(w);
        }
        if let Some(w) = &self.wait {
            p["record"] = json!(w.record);
            p["fp"] = json!(w.fp);
        }
        p
    }

    /// The notification `send_test` sends: it says which computer it came from and opens
    /// nothing. `server` is the Rex server's address as every push carries it.
    pub fn test(server: &str) -> PushMessage {
        PushMessage {
            category: PushCategory::Notice,
            title: crate::app_name!().into(),
            subtitle: None,
            body: clip(&format!("Test notification from {}", computer_name(server)), 1000),
            interruption_level: "active",
            sound: true,
            thread_id: TEST_THREAD.into(),
            collapse_id: None,
            server: server.into(),
            session_id: String::new(),
            window_id: None,
            block_id: String::new(),
            wait: None,
            hold_if_desk: None,
        }
    }

    pub fn compose(i: &PushIntent, c: &BlockContext) -> PushMessage {
        let tab = c.tab_label.clone().or_else(|| c.session_label.clone()).unwrap_or_else(|| "Rex".into());
        // Show the session too when the tab name alone doesn't say it.
        let subtitle = c.session_label.clone().filter(|s| *s != tab);
        let agent = display_name(i.agent.as_deref().or(c.block_label.as_deref()).unwrap_or("Agent"));
        let mut m = PushMessage {
            category: i.category,
            title: String::new(),
            subtitle,
            body: String::new(),
            interruption_level: "active",
            sound: true,
            thread_id: i.block.block_id.clone(),
            collapse_id: None,
            server: i.block.server.clone(),
            session_id: i.block.session_id.clone(),
            window_id: c.window_id.clone(),
            block_id: i.block.block_id.clone(),
            wait: Wait::of(i),
            hold_if_desk: None,
        };
        match i.category {
            PushCategory::Blocked => {
                m.title = format!("{agent} · {tab}");
                m.body = i
                    .text
                    .clone()
                    .or_else(|| i.headline.clone())
                    .unwrap_or_else(|| blocked_text(i.blocked_kind.as_deref()).into());
                m.interruption_level = "time-sensitive";
                m.collapse_id = Some(collapse_id(&i.block, i.record_id.as_deref()));
            }
            PushCategory::Done => {
                m.title = format!("{agent} · {tab}");
                let error = i.state.as_deref() == Some("error");
                let fallback = if error { "Failed" } else { "Finished" };
                let text = i.text.clone().or_else(|| i.headline.clone()).unwrap_or_else(|| fallback.into());
                m.body = if error && i.text.is_some() { format!("Error: {text}") } else { text };
                m.interruption_level = "passive";
                m.sound = false;
                m.collapse_id = Some(collapse_id(&i.block, i.record_id.as_deref()));
            }
            PushCategory::Notice => {
                m.title = i.headline.clone().unwrap_or(tab);
                m.body = i.text.clone().unwrap_or_default();
            }
        }
        m.title = clip(&m.title, 120);
        m.body = clip(&m.body, 1000);
        m
    }
}

impl PushMessage {
    /// What an agent push or a notice looks like on the phone: a server's pushes form one stack
    /// (`thread-id` is the server's address, at most 256 bytes), and a pane's notices replace
    /// each other (`collapse_id` "<block>-n"). A test notification stays as it is.
    pub fn stacked(mut self) -> PushMessage {
        if self.thread_id == TEST_THREAD {
            return self;
        }
        if !self.server.is_empty() {
            let mut end = self.server.len().min(256);
            while !self.server.is_char_boundary(end) {
                end -= 1;
            }
            self.thread_id = self.server[..end].to_string();
        }
        if self.category == PushCategory::Notice && !self.block_id.is_empty() {
            self.collapse_id = Some(notice_collapse_id(&self.block_id));
        }
        self
    }
}

/// A pane's notices share this collapse id, so a second replaces the first (at most 42 bytes).
pub fn notice_collapse_id(block_id: &str) -> String {
    let short: String = block_id.replace("block:", "").chars().take(40).collect();
    format!("{short}-n")
}

/// The thread id of a test notification. The app shows a notification of this thread even
/// while it is open.
pub const TEST_THREAD: &str = "rexduo-test";

/// This computer as a test notification names it: the first part of the host in the Rex
/// server's address, which is the name people know it by ("https://studio.example.ts.net"
/// reads "studio"). An address without such a host reads "this computer".
pub fn computer_name(server: &str) -> &str {
    let Some((scheme, rest)) = server.split_once("://") else {
        return "this computer";
    };
    let name = rest.split(['/', ':', '.']).next().unwrap_or("");
    if name.is_empty() || !scheme.starts_with("http") {
        "this computer"
    } else {
        name
    }
}

pub fn blocked_text(kind: Option<&str>) -> &'static str {
    match kind {
        Some("permission") => "Needs your permission",
        Some("question") => "Has a question",
        Some("auth") => "Needs your password",
        _ => "Waiting for you",
    }
}

/// "claude" -> "Claude". Names that already have capitals are left alone.
pub fn display_name(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(f) if s == s.to_lowercase() => f.to_uppercase().chain(chars).collect(),
        _ => s.to_string(),
    }
}

/// Same block and record replace each other in Notification Center (max 64 bytes).
pub fn collapse_id(r: &BlockRef, record: Option<&str>) -> String {
    let short: String = r.block_id.replace("block:", "").chars().take(40).collect();
    match record {
        None | Some("") => short,
        Some(rec) => {
            // Fold the record id into a short stable hash (FNV-1a).
            let mut h: u32 = 2_166_136_261;
            for b in rec.bytes() {
                h = (h ^ u32::from(b)).wrapping_mul(16_777_619);
            }
            format!("{short}-{h:x}")
        }
    }
}

/// The start of `text` that takes at most `room` bytes inside a JSON string, where a quote
/// or a control character takes more bytes than it has, with the mark that says it was cut.
/// Empty when not even the mark fits.
fn fit(text: &str, room: usize) -> String {
    let mark = '…';
    let Some(mut left) = room.checked_sub(mark.len_utf8()) else { return String::new() };
    let mut out = String::new();
    for c in text.chars() {
        // As serde_json writes it, without the two quotes.
        let bytes = serde_json::to_string(c.encode_utf8(&mut [0; 4])).map_or(usize::MAX, |s| s.len() - 2);
        if bytes > left {
            break;
        }
        left -= bytes;
        out.push(c);
    }
    out.push(mark);
    out
}

pub fn clip(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        s.to_string()
    } else {
        s.chars().take(n - 1).chain(std::iter::once('…')).collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block() -> BlockRef {
        BlockRef {
            server: "https://rex.example.ts.net".into(),
            session_id: "session:s1".into(),
            block_id: "block:01a1-b1".into(),
        }
    }

    #[test]
    fn blocked_payload() {
        let mut i = PushIntent::new(PushCategory::Blocked, block());
        i.state = Some("blocked".into());
        i.record_id = Some(String::new());
        i.blocked_kind = Some("question".into());
        i.agent = Some("claude".into());
        i.text = Some("Which DB?".into());
        let c = BlockContext {
            window_id: Some("window:w1".into()),
            tab_label: Some("api".into()),
            session_label: Some("work".into()),
            ..Default::default()
        };
        let m = PushMessage::compose(&i, &c);
        assert_eq!(m.title, "Claude · api");
        assert_eq!(m.subtitle.as_deref(), Some("work"));
        assert_eq!(m.priority(), 10);
        let p = m.payload();
        assert_eq!(p["aps"]["interruption-level"], "time-sensitive");
        assert_eq!(p["aps"]["thread-id"], "block:01a1-b1");
        assert_eq!(p["aps"]["category"], "AGENT_BLOCKED");
        assert_eq!(p["aps"]["sound"], "default");
        assert_eq!(p["aps"]["alert"]["body"], "Which DB?");
        assert_eq!(p["aps"]["alert"]["subtitle"], "work");
        assert_eq!(p["server"], "https://rex.example.ts.net");
        assert_eq!(p["session_id"], "session:s1");
        assert_eq!(p["window_id"], "window:w1");
        assert_eq!(p["block_id"], "block:01a1-b1");
        assert!(m.collapse_id.unwrap().len() <= 64);
    }

    /// A question whose record has an id and a fingerprint: the whole payload, as the app
    /// and the gateway get it.
    #[test]
    fn a_question_that_names_its_wait_has_the_category_with_actions() {
        let mut i = PushIntent::new(PushCategory::Blocked, block());
        i.state = Some("blocked".into());
        i.record_id = Some("claude".into());
        i.blocked_kind = Some("question".into());
        i.agent = Some("claude".into());
        i.text = Some("Which DB?".into());
        i.fp = Some(crate::policy::fingerprint("blocked", Some("question"), Some("Which DB?")));
        let c = BlockContext { window_id: Some("window:w1".into()), tab_label: Some("api".into()), session_label: Some("work".into()), ..Default::default() };
        let m = PushMessage::compose(&i, &c);
        assert_eq!(m.category, PushCategory::Blocked);
        assert_eq!(m.category_name(), "AGENT_BLOCKED_ACT");
        let golden = |thread: &str| {
            json!({
                "aps": {
                    "alert": {"title": "Claude · api", "subtitle": "work", "body": "Which DB?"},
                    "interruption-level": "time-sensitive",
                    "thread-id": thread,
                    "category": "AGENT_BLOCKED_ACT",
                    "sound": "default",
                },
                "server": "https://rex.example.ts.net",
                "session_id": "session:s1",
                "block_id": "block:01a1-b1",
                "window_id": "window:w1",
                "record": "claude",
                "fp": "d110a7daf17e741b",
            })
        };
        assert_eq!(m.payload(), golden("block:01a1-b1"));
        // As it is sent: one stack per server, the same wait.
        let collapse = m.collapse_id.clone();
        let sent = m.stacked();
        assert_eq!(sent.payload(), golden("https://rex.example.ts.net"));
        assert_eq!(sent.collapse_id, collapse);
    }

    #[test]
    fn a_question_that_cannot_name_its_wait_has_no_actions() {
        let fp = crate::policy::fingerprint("blocked", None, None);
        let question = |record: Option<&str>, fp: Option<&str>| {
            let mut i = PushIntent::new(PushCategory::Blocked, block());
            i.state = Some("blocked".into());
            i.record_id = record.map(Into::into);
            i.fp = fp.map(Into::into);
            PushMessage::compose(&i, &BlockContext::default())
        };
        let longest = "r".repeat(MAX_RECORD_BYTES);
        for record in ["claude", "claude-code.2", "agent_1:main", "A", longest.as_str()] {
            let m = question(Some(record), Some(&fp));
            assert_eq!(m.wait, Some(Wait { record: record.into(), fp: fp.clone() }), "{record:?}");
            assert_eq!((&m.payload()["record"], &m.payload()["fp"]), (&json!(record), &json!(fp)));
        }
        // No fingerprint (a question parked by an earlier version), no record id, an empty
        // one, one the gateway would refuse: the push as it always was.
        let too_long = "r".repeat(MAX_RECORD_BYTES + 1);
        let cases = [
            (Some("claude"), None),
            (None, Some(fp.as_str())),
            (Some(""), Some(fp.as_str())),
            (Some(too_long.as_str()), Some(fp.as_str())),
            // Anything that is not written as an identifier could be text, and is not sent.
            (Some("run the tests"), Some(fp.as_str())),
            (Some("é"), Some(fp.as_str())),
            (Some("claude?"), Some(fp.as_str())),
            (Some("a/b"), Some(fp.as_str())),
            (Some("\"claude\""), Some(fp.as_str())),
            (Some("cla\nude"), Some(fp.as_str())),
            (Some("claude\u{0}"), Some(fp.as_str())),
            (Some("claude\u{7f}"), Some(fp.as_str())),
            (Some("claude\u{85}"), Some(fp.as_str())),
        ];
        for (record, fp) in cases {
            let m = question(record, fp);
            let p = m.payload();
            assert_eq!((m.wait.clone(), m.category_name()), (None, "AGENT_BLOCKED"), "{record:?}");
            assert_eq!(p["aps"]["category"], "AGENT_BLOCKED", "{record:?}");
            assert!(p.get("record").is_none() && p.get("fp").is_none(), "{record:?}");
        }
    }

    /// A "finished" and a notice never name a wait, whatever their intent holds: their whole
    /// payloads are what they were.
    #[test]
    fn a_finished_agent_and_a_notice_are_unchanged() {
        let c = BlockContext { window_id: Some("window:w1".into()), tab_label: Some("api".into()), session_label: Some("work".into()), ..Default::default() };
        let mut done = PushIntent::new(PushCategory::Done, block());
        done.state = Some("done".into());
        done.record_id = Some("claude".into());
        done.agent = Some("claude".into());
        done.fp = Some("d110a7daf17e741b".into());
        let m = PushMessage::compose(&done, &c);
        assert_eq!((m.wait.clone(), m.category_name()), (None, "AGENT_DONE"));
        assert_eq!(
            m.payload(),
            json!({
                "aps": {
                    "alert": {"title": "Claude · api", "subtitle": "work", "body": "Finished"},
                    "interruption-level": "passive",
                    "thread-id": "block:01a1-b1",
                    "category": "AGENT_DONE",
                },
                "server": "https://rex.example.ts.net",
                "session_id": "session:s1",
                "block_id": "block:01a1-b1",
                "window_id": "window:w1",
            })
        );
        let mut notice = PushIntent::new(PushCategory::Notice, block());
        notice.headline = Some("Deploy".into());
        notice.text = Some("Live".into());
        notice.record_id = Some("claude".into());
        notice.fp = Some("d110a7daf17e741b".into());
        let m = PushMessage::compose(&notice, &c);
        assert_eq!((m.wait.clone(), m.category_name()), (None, "NOTICE"));
        assert_eq!(
            m.payload(),
            json!({
                "aps": {
                    "alert": {"title": "Deploy", "subtitle": "work", "body": "Live"},
                    "interruption-level": "active",
                    "thread-id": "block:01a1-b1",
                    "category": "NOTICE",
                    "sound": "default",
                },
                "server": "https://rex.example.ts.net",
                "session_id": "session:s1",
                "block_id": "block:01a1-b1",
                "window_id": "window:w1",
            })
        );
        assert_eq!(PushMessage::test("https://rex.example.ts.net").wait, None);
    }

    /// What a push says of the wait beside its title and body: the program's record id and
    /// a hash. None of the record's words (its message, title or kind) is in either, and the
    /// hash is the same length whatever it was made from.
    #[test]
    fn the_wait_holds_an_identifier_and_a_hash_and_none_of_the_records_words() {
        let e = json!({"id": "claude", "record": {"state": "blocked", "kind": "sekritkind", "app": "claude", "title": "sekrittitle", "msg": "sekritmessage about ~/private/plans"}});
        let rep = crate::policy::StatusReport::from_event(&e).unwrap();
        let mut policy = crate::policy::PushPolicy::new(30.0);
        let crate::policy::Decision::Push(i) = policy.decide(crate::policy::RelayEvent::Status(block(), rep), 1000.0) else { panic!("a question is pushed") };
        let p = PushMessage::compose(&i, &BlockContext::default()).stacked().payload();
        assert_eq!(p["record"], "claude");
        let fp = p["fp"].as_str().unwrap();
        assert!(fp.len() == 16 && fp.bytes().all(|b| b.is_ascii_hexdigit()));
        // The words are where they always were, in the body, and nowhere else.
        assert_eq!(p["aps"]["alert"]["body"], "sekritmessage about ~/private/plans");
        let mut rest = p.clone();
        rest["aps"]["alert"]["body"] = json!("");
        assert!(!rest.to_string().contains("sekrit") && !rest.to_string().contains("private"), "{rest}");
        // Every key the payload has, so nothing else was added to carry text.
        let mut keys: Vec<&str> = p.as_object().unwrap().keys().map(String::as_str).collect();
        keys.sort();
        assert_eq!(keys, ["aps", "block_id", "fp", "record", "server", "session_id"]);
        // An id that reads like text is not sent at all.
        let mut wordy = i.clone();
        wordy.record_id = Some("sekrit words here".into());
        let p = PushMessage::compose(&wordy, &BlockContext::default()).payload();
        assert!(p.get("record").is_none() && p.get("fp").is_none() && p["aps"]["category"] == "AGENT_BLOCKED");
    }

    #[test]
    fn a_body_that_would_pass_the_limit_is_cut_and_nothing_else_is() {
        let mut i = PushIntent::new(PushCategory::Blocked, block());
        i.state = Some("blocked".into());
        i.record_id = Some("claude".into());
        i.fp = Some("d110a7daf17e741b".into());
        let c = BlockContext { tab_label: Some("api".into()), ..Default::default() };
        let size = |m: &PushMessage| m.payload().to_string().len();
        // Short enough: sent whole, with no mark.
        i.text = Some("x".repeat(1000));
        let m = PushMessage::compose(&i, &c);
        assert_eq!(m.payload()["aps"]["alert"]["body"], "x".repeat(1000));
        assert!(size(&m) <= MAX_PAYLOAD_BYTES);
        // A thousand quotes take two bytes each in JSON and still fit: whole as well.
        i.text = Some("\"".repeat(1000));
        assert_eq!(PushMessage::compose(&i, &c).payload()["aps"]["alert"]["body"], "\"".repeat(1000));
        // Characters of four bytes, of six bytes in JSON's escapes, and a mix with quotes.
        for unit in ["🦖", "\u{1}", "\"🦖🦖🦖🦖🦖🦖🦖🦖🦖"] {
            i.text = Some(unit.repeat(1000));
            let m = PushMessage::compose(&i, &c).stacked();
            let p = m.payload();
            let body = p["aps"]["alert"]["body"].as_str().unwrap();
            assert!(size(&m) <= MAX_PAYLOAD_BYTES, "{unit:?}: {}", size(&m));
            assert!(size(&m) > MAX_PAYLOAD_BYTES - 32, "{unit:?}: cut no further than needed, {}", size(&m));
            assert!(body.ends_with('…') && body.chars().count() <= 1000, "{unit:?}");
            assert!(m.body.starts_with(body.trim_end_matches('…')), "{unit:?}: the start of the text");
            assert_eq!((&p["record"], &p["fp"], &p["aps"]["category"]), (&json!("claude"), &json!("d110a7daf17e741b"), &json!("AGENT_BLOCKED_ACT")), "{unit:?}");
            assert_eq!(p["aps"]["alert"]["title"], "Agent · api");
        }
    }

    #[test]
    fn blocked_fallback_text() {
        let mut i = PushIntent::new(PushCategory::Blocked, block());
        i.blocked_kind = Some("permission".into());
        let m = PushMessage::compose(&i, &BlockContext { block_label: Some("codex".into()), ..Default::default() });
        assert_eq!(m.title, "Codex · Rex");
        assert_eq!(m.body, "Needs your permission");
        assert!(m.payload().get("window_id").is_none());
        // One wording for each reason, the same as the app shows.
        assert_eq!(blocked_text(Some("auth")), "Needs your password");
        assert_eq!(blocked_text(Some("permission")), "Needs your permission");
        assert_eq!(blocked_text(Some("question")), "Has a question");
        assert_eq!((blocked_text(None), blocked_text(Some("something new"))), ("Waiting for you", "Waiting for you"));
    }

    #[test]
    fn notice_uses_given_title_or_tab() {
        let ctx = BlockContext { tab_label: Some("ops".into()), ..Default::default() };
        let mut i = PushIntent::new(PushCategory::Notice, block());
        i.headline = Some("Deploy".into());
        i.text = Some("Live".into());
        let n = PushMessage::compose(&i, &ctx);
        assert_eq!(n.title, "Deploy");
        assert_eq!(n.body, "Live");
        assert_eq!(n.interruption_level, "active");
        assert_eq!(n.payload()["aps"]["category"], "NOTICE");
        let mut osc9 = PushIntent::new(PushCategory::Notice, block());
        osc9.text = Some("Done".into());
        assert_eq!(PushMessage::compose(&osc9, &ctx).title, "ops");
    }

    #[test]
    fn done_payload_is_passive() {
        let mut i = PushIntent::new(PushCategory::Done, block());
        i.state = Some("done".into());
        i.agent = Some("claude".into());
        let m = PushMessage::compose(&i, &BlockContext { tab_label: Some("api".into()), ..Default::default() });
        let p = m.payload();
        assert_eq!(p["aps"]["interruption-level"], "passive");
        assert_eq!(p["aps"]["category"], "AGENT_DONE");
        assert!(p["aps"].get("sound").is_none());
        assert_eq!(m.priority(), 5);
        assert_eq!(m.body, "Finished");
    }

    #[test]
    fn long_body_clipped() {
        let mut i = PushIntent::new(PushCategory::Notice, block());
        i.text = Some("x".repeat(5000));
        let m = PushMessage::compose(&i, &BlockContext::default());
        assert_eq!(m.body.chars().count(), 1000);
        assert!(serde_json::to_vec(&m.payload()).unwrap().len() < 4096);
    }

    #[test]
    fn a_test_notification_names_the_computer_and_no_session() {
        let m = PushMessage::test("https://rex.example.ts.net");
        assert_eq!(
            m.payload(),
            json!({
                "aps": {
                    "alert": {"title": crate::app_name!(), "body": "Test notification from rex"},
                    "sound": "default",
                    "category": "NOTICE",
                    "thread-id": "rexduo-test",
                    "interruption-level": "active",
                },
                "server": "https://rex.example.ts.net",
            })
        );
        assert_eq!((m.priority(), m.collapse_id), (10, None));
        assert_eq!(computer_name("https://studio.example.ts.net/"), "studio");
        assert_eq!(computer_name("https://studio:8443/x"), "studio");
        assert_eq!(computer_name("unix:/run/user/1000/rex/server.sock"), "this computer");
        assert_eq!(computer_name("studio"), "this computer");
        for none in ["", "https://", "/"] {
            assert_eq!(computer_name(none), "this computer", "{none:?}");
        }
        assert_eq!(PushMessage::test("").payload()["aps"]["alert"]["body"], "Test notification from this computer");
    }

    #[test]
    fn a_server_is_one_stack_and_a_panes_notices_replace_each_other() {
        let ctx = BlockContext { tab_label: Some("ops".into()), ..Default::default() };
        let mut n = PushIntent::new(PushCategory::Notice, block());
        n.text = Some("Built".into());
        let notice = PushMessage::compose(&n, &ctx).stacked();
        assert_eq!(notice.payload()["aps"]["thread-id"], "https://rex.example.ts.net");
        assert_eq!(notice.collapse_id.as_deref(), Some("01a1-b1-n"));
        let mut b = PushIntent::new(PushCategory::Blocked, block());
        b.record_id = Some("a".into());
        let blocked = PushMessage::compose(&b, &ctx);
        let collapse = blocked.collapse_id.clone();
        let blocked = blocked.stacked();
        assert_eq!((blocked.thread_id.as_str(), blocked.collapse_id), ("https://rex.example.ts.net", collapse));
        // Off, as before: a pane per stack, no collapse id on a notice.
        let plain = PushMessage::compose(&n, &ctx);
        assert_eq!((plain.thread_id.as_str(), plain.collapse_id), ("block:01a1-b1", None));
        // A test notification keeps its own thread; the app shows it while open.
        let test = PushMessage::test("https://rex.example.ts.net");
        assert_eq!(test.clone().stacked().payload(), test.payload());
        // Long addresses and block ids stay within what APNs takes.
        let mut long = PushIntent::new(PushCategory::Notice, BlockRef { server: format!("https://{}\u{e9}.ts.net", "a".repeat(300)), ..block() });
        long.block.block_id = format!("block:{}", "f".repeat(80));
        let m = PushMessage::compose(&long, &ctx).stacked();
        assert!(m.thread_id.len() <= 256 && m.thread_id.starts_with("https://aaa"));
        assert!(m.collapse_id.unwrap().len() <= 42);
    }

    #[test]
    fn collapse_ids() {
        assert_eq!(collapse_id(&block(), None), "01a1-b1");
        assert_eq!(collapse_id(&block(), Some("")), "01a1-b1");
        // FNV-1a of "a" is 0xe40c292c.
        assert_eq!(collapse_id(&block(), Some("a")), "01a1-b1-e40c292c");
        assert_eq!(display_name("claude"), "Claude");
        assert_eq!(display_name("OpenAI"), "OpenAI");
    }
}
