//! Turns a push intent into the APNs payload the app reads (`server`, `session_id`,
//! `window_id`, `block_id`, categories, thread and collapse ids).

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

    /// The JSON body APNs gets: the gateway passes it on as it is.
    pub fn payload(&self) -> Value {
        let mut alert = json!({"title": self.title, "body": self.body});
        if let Some(s) = &self.subtitle {
            alert["subtitle"] = json!(s);
        }
        let mut aps = json!({
            "alert": alert,
            "interruption-level": self.interruption_level,
            "thread-id": self.thread_id,
            "category": self.category.as_str(),
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
        p
    }

    /// The notification `send_test` sends: it says which computer it came from and opens
    /// nothing. `server` is the Rex server's address as every push carries it.
    pub fn test(server: &str) -> PushMessage {
        PushMessage {
            category: PushCategory::Notice,
            title: "Rex DUO".into(),
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
        Some("question") => "Has a question for you",
        Some("auth") => "Needs you to sign in",
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

    #[test]
    fn blocked_fallback_text() {
        let mut i = PushIntent::new(PushCategory::Blocked, block());
        i.blocked_kind = Some("permission".into());
        let m = PushMessage::compose(&i, &BlockContext { block_label: Some("codex".into()), ..Default::default() });
        assert_eq!(m.title, "Codex · Rex");
        assert_eq!(m.body, "Needs your permission");
        assert!(m.payload().get("window_id").is_none());
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
                    "alert": {"title": "Rex DUO", "body": "Test notification from rex"},
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
    fn collapse_ids() {
        assert_eq!(collapse_id(&block(), None), "01a1-b1");
        assert_eq!(collapse_id(&block(), Some("")), "01a1-b1");
        // FNV-1a of "a" is 0xe40c292c.
        assert_eq!(collapse_id(&block(), Some("a")), "01a1-b1-e40c292c");
        assert_eq!(display_name("claude"), "Claude");
        assert_eq!(display_name("OpenAI"), "OpenAI");
    }
}
