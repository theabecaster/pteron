//! The relay: watches the Rex server (found automatically, or the ones in the config), turns
//! agent and notification events into pushes, and serves the `register_push` /
//! `unregister_push` / `push_presence` client actions the iOS app calls.

use crate::apns::{describe, SendResult, Sender};
use crate::devices::{is_app_open, ClientSnapshot, Device, DeviceStore};
use crate::discovery::{self, Endpoint};
use crate::policy::{BlockRef, Decision, PushIntent, PushPolicy, RateLimiter, RelayEvent, StatusReport};
use crate::push::{BlockContext, PushMessage};
use crate::rex::{self, Conn, Identity};
use crate::util::{now, now_iso, Json};
use crate::{debug, info};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Actions the relay offers to other Rex clients (declared with `client.keymap`).
/// The server checks `client.perform` args against these schemas.
pub fn actions() -> Value {
    json!([
        {
            "name": "register_push", "kind": "client", "category": "Rex DUO",
            "title": "Register for Rex DUO Pushes",
            "description": "Send push notifications for this server's agents to an iPhone.",
            "args": {
                "type": "object",
                "properties": {
                    "token": {"type": "string", "description": "APNs device token, hex."},
                    "environment": {"type": "string", "enum": ["sandbox", "production"]},
                    "device_name": {"type": "string"},
                    "device_id": {"type": "string", "description": "Short id the app also puts in its client label as \"#<id>\"."}
                },
                "required": ["token", "environment"]
            }
        },
        {
            "name": "unregister_push", "kind": "client", "category": "Rex DUO",
            "title": "Unregister from Rex DUO Pushes",
            "description": "Stop sending pushes to an iPhone.",
            "args": {"type": "object", "properties": {"token": {"type": "string"}}, "required": ["token"]}
        },
        {
            "name": "push_presence", "kind": "client", "category": "Rex DUO",
            "title": "Rex DUO Presence",
            "description": "Tell the relay whether the calling Rex DUO app is in the foreground.",
            "args": {"type": "object", "properties": {"active": {"type": "boolean"}}, "required": ["active"]}
        }
    ])
}

#[derive(Default)]
struct SessionView {
    revision: i64,
    blocks: HashMap<String, BlockContext>,
}

#[derive(Default)]
struct ServerState {
    /// The server's address as the app knows it (its Tailscale HTTPS URL), sent in payloads.
    name: String,
    /// Short name for log lines.
    host: String,
    endpoint: Option<Endpoint>,
    /// Set up and watching events.
    ready: bool,
    sessions: HashMap<String, String>,
    views: HashMap<String, SessionView>,
    latest_revision: HashMap<String, i64>,
    /// App clients that said they went to the background (`push_presence {active: false}`).
    backgrounded: HashSet<String>,
}

pub struct Server {
    conn: Conn,
    /// From the config or `--server`; None means discover the local server each attempt.
    fixed: Option<Endpoint>,
    st: Mutex<ServerState>,
}

impl Server {
    fn host(&self) -> String {
        let h = self.st.lock().unwrap().host.clone();
        if h.is_empty() { "rex".into() } else { h }
    }
}

pub struct Options {
    pub dry_run: bool,
    pub label: Option<String>,
    pub debounce: f64,
    pub burst: f64,
    pub per_minute: f64,
    pub status_path: PathBuf,
}

pub struct Relay {
    servers: Vec<Arc<Server>>,
    policy: Mutex<PushPolicy>,
    limiter: Mutex<RateLimiter>,
    store: Mutex<DeviceStore>,
    sender: Option<Sender>,
    dry_run: bool,
    identity: Identity,
    due_task: Mutex<Option<JoinHandle<()>>>,
    status_path: PathBuf,
    stopping: AtomicBool,
}

impl Relay {
    /// `endpoints` None discovers the local server.
    pub fn new(endpoints: Option<Vec<Endpoint>>, store: DeviceStore, sender: Option<Sender>, o: Options) -> Arc<Relay> {
        let mut identity = Identity::default();
        if let Some(l) = o.label.filter(|l| !l.is_empty()) {
            identity.label = l;
        }
        let fixed: Vec<Option<Endpoint>> = match endpoints {
            Some(eps) => eps.into_iter().map(Some).collect(),
            None => vec![None],
        };
        Arc::new(Relay {
            servers: fixed
                .into_iter()
                .map(|f| Arc::new(Server { conn: Conn::default(), fixed: f, st: Mutex::new(ServerState::default()) }))
                .collect(),
            policy: Mutex::new(PushPolicy::new(o.debounce)),
            limiter: Mutex::new(RateLimiter::new(o.burst, o.per_minute)),
            store: Mutex::new(store),
            sender,
            dry_run: o.dry_run,
            identity,
            due_task: Mutex::new(None),
            status_path: o.status_path,
            stopping: AtomicBool::new(false),
        })
    }

    fn push_enabled(&self) -> bool {
        self.sender.is_some() && !self.dry_run
    }

    pub fn start(self: &Arc<Self>) {
        let n = self.store.lock().unwrap().devices.len();
        let mode = if self.dry_run {
            "dry run, no pushes are sent"
        } else if self.sender.is_none() {
            "pushes disabled (no APNs key)"
        } else {
            "APNs on"
        };
        info!("Rex DUO Helper {VERSION} starting; {n} registered device(s); {mode}");
        self.write_status();
        for s in &self.servers {
            tokio::spawn(self.clone().run_server(s.clone()));
        }
    }

    /// Closes every connection with a close frame, so Rex drops this client at once
    /// instead of listing it as `lost` for a minute.
    pub fn stop(&self) {
        self.stopping.store(true, Ordering::SeqCst);
        for s in &self.servers {
            s.conn.close(CloseCode::Normal);
        }
        let _ = std::fs::remove_file(&self.status_path);
    }

    /// status.json, read by `rex-duo-helper status` and the Mac app's dialog.
    fn write_status(&self) {
        let ready: Vec<String> =
            self.servers.iter().filter_map(|s| { let st = s.st.lock().unwrap(); st.ready.then(|| st.name.clone()) }).collect();
        let v = json!({
            "pid": std::process::id(),
            "version": VERSION,
            "connected": !ready.is_empty(),
            "servers": ready,
            "dry_run": self.dry_run,
            "push_enabled": self.push_enabled(),
            "exe_mtime": std::env::current_exe().map(|p| crate::service::mtime(&p)).unwrap_or(0),
            "updated_at": now_iso(),
        });
        let tmp = self.status_path.with_extension("json.tmp");
        if std::fs::write(&tmp, v.to_string()).is_ok() {
            let _ = std::fs::rename(&tmp, &self.status_path);
        }
    }

    // MARK: Connection loop

    async fn run_server(self: Arc<Self>, s: Arc<Server>) {
        let mut delay: f64 = 1.0;
        let mut last_reason = String::new();
        let mut token: Option<String> = None;
        while !self.stopping.load(Ordering::SeqCst) {
            let began = Instant::now();
            let ep = match &s.fixed {
                Some(e) => Some(e.clone()),
                None => discovery::find().await,
            };
            let mut was_connected = false;
            let reason = match ep {
                None => "no Rex server found".to_string(),
                Some(ep) => {
                    {
                        let mut st = s.st.lock().unwrap();
                        st.host = ep.short();
                        st.endpoint = Some(ep.clone());
                    }
                    // Connect, upgrade, hello and welcome must all finish within 8 s.
                    match tokio::time::timeout(Duration::from_secs(8), rex::open(&ep, &self.identity, token.as_deref())).await {
                        Err(_) => "timed out connecting".to_string(),
                        Ok(Err(e)) => e,
                        Ok(Ok((ws, welcome))) => {
                            if welcome.reconnect_token.is_some() {
                                token = welcome.reconnect_token.clone();
                            }
                            info!(
                                "[{}] connected to {ep} as {}{}",
                                s.host(),
                                welcome.client_id.as_deref().unwrap_or("?"),
                                if welcome.resumed { " (resumed)" } else { "" }
                            );
                            was_connected = true;
                            let attached = s.conn.attach(ws);
                            let (relay, srv) = (self.clone(), s.clone());
                            tokio::spawn(async move {
                                match relay.set_up(&srv).await {
                                    Ok(()) => {
                                        srv.st.lock().unwrap().ready = true;
                                        relay.write_status();
                                    }
                                    Err(e) => {
                                        info!("[{}] setup failed: {e}", srv.host());
                                        srv.conn.close(CloseCode::Away);
                                    }
                                }
                            });
                            // Rex pings every 120 s; a remote server that vanished goes quiet.
                            let idle = matches!(ep, Endpoint::Url { .. }).then(|| Duration::from_secs(330));
                            let relay = self.clone();
                            let srv = s.clone();
                            s.conn.serve(attached, idle, move |ev| relay.handle(&srv, ev)).await
                        }
                    }
                }
            };
            if was_connected {
                s.st.lock().unwrap().ready = false;
                if !self.stopping.load(Ordering::SeqCst) {
                    self.write_status();
                }
            }
            if self.stopping.load(Ordering::SeqCst) {
                break;
            }
            // A connection that stayed up a while starts the backoff over.
            if began.elapsed() > Duration::from_secs(60) {
                delay = 1.0;
            }
            // While Rex is down this repeats every minute; say it once.
            if reason != last_reason || was_connected {
                info!("[{}] disconnected ({reason}); retrying with backoff up to 60s", s.host());
            }
            last_reason = reason;
            tokio::time::sleep(Duration::from_secs_f64(delay * jitter())).await;
            delay = (delay * 2.0).min(60.0);
        }
    }

    async fn set_up(&self, s: &Server) -> Result<(), rex::RexError> {
        let boot = s.conn.call("session.bootstrap", json!({"event_scope": "all", "attach_session_ids": []})).await?;
        // Payloads name the server by its Tailscale URL, which is how Rex DUO knows it.
        let url = boot
            .obj("server_status")
            .and_then(|v| v.obj("tailscale"))
            .and_then(|v| v.obj("https"))
            .and_then(|v| v.text("url"))
            .unwrap_or_else(|| s.st.lock().unwrap().endpoint.as_ref().map(|e| e.to_string()).unwrap_or_default());
        {
            let mut st = s.st.lock().unwrap();
            st.name = url.trim_matches('/').to_string();
            st.sessions.clear();
            if let Some(all) = boot.obj("attach_all") {
                for sess in all.arr("sessions") {
                    if let Some(id) = sess.str("session_id") {
                        st.sessions.insert(id.into(), sess.str("label").unwrap_or("").into());
                    }
                }
            }
            st.views.clear();
            st.latest_revision.clear();
        }
        s.conn.call("client.keymap", json!({"actions": actions(), "server_actions": "none"})).await?;
        let live: HashSet<String> = app_clients(s).await?.into_iter().map(|c| c.client_id).collect();
        let st = &mut *s.st.lock().unwrap();
        st.backgrounded.retain(|c| live.contains(c));
        info!("[{}] watching {} session(s) as {}; offering register_push", st.host, st.sessions.len(), st.name);
        Ok(())
    }

    // MARK: Events

    fn handle(self: &Arc<Self>, s: &Arc<Server>, ev: Value) {
        let p = ev.obj("payload").cloned().unwrap_or(Value::Null);
        match ev.str("type") {
            Some("session_created") => {
                if let Some(sess) = p.obj("session") {
                    if let Some(id) = sess.str("session_id") {
                        let label = sess.str("label").unwrap_or("").to_string();
                        debug!("[{}] session created: {}", s.host(), if label.is_empty() { id } else { &label });
                        s.st.lock().unwrap().sessions.insert(id.into(), label);
                    }
                }
            }
            Some("session_destroyed") => {
                if let Some(id) = p.str("session_id") {
                    let mut st = s.st.lock().unwrap();
                    st.sessions.remove(id);
                    st.views.remove(id);
                    st.latest_revision.remove(id);
                }
            }
            Some("client_left") => {
                if let Some(id) = p.str("client_id") {
                    s.st.lock().unwrap().backgrounded.remove(id);
                }
            }
            Some("client_perform_requested") => {
                let (relay, srv) = (self.clone(), s.clone());
                tokio::spawn(async move { relay.perform(&srv, p).await });
            }
            Some("session_event") => {
                if let (Some(sid), Some(inner)) = (p.str("session_id"), p.obj("event")) {
                    self.handle_session_event(s, sid, inner);
                }
            }
            _ => {}
        }
    }

    fn handle_session_event(self: &Arc<Self>, s: &Arc<Server>, sid: &str, ev: &Value) {
        let p = ev.obj("payload").cloned().unwrap_or(Value::Null);
        match ev.str("type") {
            Some("session_view_changed") => {
                if let Some(r) = p.int("revision") {
                    let mut st = s.st.lock().unwrap();
                    let e = st.latest_revision.entry(sid.into()).or_insert(0);
                    *e = (*e).max(r);
                }
            }
            Some("session_label_changed") => {
                if let Some(l) = p.str("label") {
                    s.st.lock().unwrap().sessions.insert(sid.into(), l.into());
                }
            }
            Some("block_closed") => {
                if let Some(b) = p.str("block_id") {
                    let r = self.block_ref(s, sid, b);
                    self.decide(RelayEvent::BlockClosed(r));
                }
            }
            Some("block_event") => {
                let (Some(b), Some(name)) = (p.str("block_id"), p.str("name")) else { return };
                let r = self.block_ref(s, sid, b);
                let e = p.obj("payload").cloned().unwrap_or(Value::Null);
                match name {
                    "program_status_changed" => {
                        let Some(rep) = StatusReport::from_event(&e) else { return };
                        let line = format!(
                            "[{}] status {} {}-> {}{}{}",
                            s.host(),
                            short(b),
                            if rep.record_id.is_empty() { String::new() } else { format!("{} ", rep.record_id) },
                            rep.state,
                            rep.app.as_ref().map(|a| format!(" ({a})")).unwrap_or_default(),
                            rep.msg.as_ref().map(|m| format!(": {m}")).unwrap_or_default()
                        );
                        if ["blocked", "done", "error"].contains(&rep.state.as_str()) {
                            info!("{line}");
                        } else {
                            debug!("{line}");
                        }
                        self.decide(RelayEvent::Status(r, rep));
                    }
                    "program_status_removed" => {
                        let ids = e
                            .get("ids")
                            .and_then(|v| v.as_array())
                            .map(|a| a.iter().filter_map(|i| i.as_str().map(String::from)).collect())
                            .unwrap_or_default();
                        self.decide(RelayEvent::StatusRemoved(r, ids));
                    }
                    "desktop_notification" => {
                        let body = e.str("body").unwrap_or("").to_string();
                        let title = e.text("title");
                        info!("[{}] notification {}: {} {body}", s.host(), short(b), title.as_deref().unwrap_or(""));
                        self.decide(RelayEvent::Notification(r, title, body));
                    }
                    _ => {}
                }
            }
            _ => {}
        }
    }

    fn block_ref(&self, s: &Server, sid: &str, b: &str) -> BlockRef {
        BlockRef { server: s.st.lock().unwrap().name.clone(), session_id: sid.into(), block_id: b.into() }
    }

    fn decide(self: &Arc<Self>, e: RelayEvent) {
        let d = self.policy.lock().unwrap().decide(e, now());
        match d {
            Decision::Push(i) => {
                tokio::spawn(self.clone().dispatch(i));
            }
            Decision::Deferred(until) => {
                info!("blocked again within the debounce window; holding for {:.0}s", (until - now()).max(0.0));
                self.schedule_due();
            }
            Decision::Drop(why) => debug!("no push: {why}"),
        }
    }

    fn schedule_due(self: &Arc<Self>) {
        let mut task = self.due_task.lock().unwrap();
        if let Some(t) = task.take() {
            t.abort();
        }
        let Some(next) = self.policy.lock().unwrap().next_due() else { return };
        let relay = self.clone();
        *task = Some(tokio::spawn(async move {
            let wait = (next - now()).max(0.0) + 0.05;
            tokio::time::sleep(Duration::from_secs_f64(wait)).await;
            let due = relay.policy.lock().unwrap().due(now());
            // Their own tasks, so a later reschedule (which aborts this one) can't cut them off.
            for i in due {
                tokio::spawn(relay.clone().dispatch(i));
            }
            relay.due_task.lock().unwrap().take();
            relay.schedule_due();
        }));
    }

    // MARK: Sending

    async fn dispatch(self: Arc<Self>, intent: PushIntent) {
        let Some(s) = self.servers.iter().find(|s| s.st.lock().unwrap().name == intent.block.server).cloned() else { return };
        let ctx = context(&s, &intent.block).await;
        let msg = PushMessage::compose(&intent, &ctx);
        info!("push {} [{}] \"{}\": {}", msg.category.as_str(), msg.interruption_level, msg.title, msg.body);
        let Some(sender) = &self.sender else { return };
        let devices = self.store.lock().unwrap().devices.clone();
        if devices.is_empty() {
            if self.dry_run {
                info!("DRY-RUN push -> (no registered devices) {}", describe(&msg, sender.topic()));
            }
            return;
        }
        let (clients, background) = self.presence_snapshot().await;
        let t = now();
        for d in devices {
            let who = d.who();
            if is_app_open(&d, &clients, &background) {
                info!("skip {who}: Rex DUO is open");
                continue;
            }
            if !self.limiter.lock().unwrap().allow(&d.token, t) {
                info!("skip {who}: rate limited");
                continue;
            }
            match sender.send(&msg, &d).await {
                SendResult::Sent(id) => {
                    if !self.dry_run {
                        info!("sent to {who}{}", id.map(|i| format!(" (apns-id {i})")).unwrap_or_default());
                    }
                }
                SendResult::DropDevice(why) => {
                    info!("APNs rejected {who} ({why}); unregistering it");
                    self.store.lock().unwrap().remove(&d.token);
                }
                SendResult::Failed(why) => info!("send to {who} failed: {why}"),
            }
        }
    }

    /// Asks every connected server who's connected right now. Pushes are rare, so this stays exact.
    async fn presence_snapshot(&self) -> (Vec<ClientSnapshot>, HashSet<String>) {
        let mut clients = vec![];
        let mut background = HashSet::new();
        for s in &self.servers {
            if !s.conn.is_connected() {
                continue;
            }
            if let Ok(c) = app_clients(s).await {
                clients.extend(c);
            }
            background.extend(s.st.lock().unwrap().backgrounded.iter().cloned());
        }
        (clients, background)
    }

    // MARK: Client actions

    async fn perform(&self, s: &Server, p: Value) {
        let Some(call_id) = p.str("call_id") else { return };
        let empty = json!({});
        let args = p.obj("args").unwrap_or(&empty);
        let requester = p.obj("requester").unwrap_or(&empty);
        let who = requester
            .obj("info")
            .and_then(|i| i.str("label"))
            .or_else(|| requester.str("client_id"))
            .unwrap_or("?")
            .to_string();
        let mut reply = json!({"call_id": call_id});
        let bad = |m: &str| json!({"code": "bad_request", "message": m});
        match p.str("action") {
            Some("register_push") => {
                let token = args.str("token").unwrap_or("").to_lowercase();
                let env = args.str("environment").unwrap_or("");
                let dev_id = args.text("device_id").map(|d| d.to_lowercase());
                if !Device::is_valid_token(&token) {
                    reply["error"] = bad("token must be the APNs device token in hex");
                } else if env != "sandbox" && env != "production" {
                    reply["error"] = bad("environment must be sandbox or production");
                } else if dev_id.as_deref().is_some_and(|d| !Device::is_valid_device_id(d)) {
                    reply["error"] = bad("device_id must be 4-16 letters or digits");
                } else {
                    let pr = requester.obj("principal").unwrap_or(&empty);
                    let mut d = Device::new(&token, env);
                    d.device_name = args.text("device_name");
                    d.device_id = dev_id;
                    d.tailscale_node = if pr.str("kind") == Some("tailscale") { pr.text("node") } else { None };
                    let (d, count) = {
                        let mut store = self.store.lock().unwrap();
                        let d = store.register(d);
                        (d, store.devices.len())
                    };
                    info!(
                        "registered {} [{env}] token {}... from {who}",
                        d.device_name.as_deref().unwrap_or("device"),
                        &token[..8]
                    );
                    reply["result"] = json!({
                        "registered": true, "devices": count,
                        "push_enabled": self.push_enabled(), "relay_version": VERSION,
                    });
                }
            }
            Some("unregister_push") => {
                let removed = self.store.lock().unwrap().remove(args.str("token").unwrap_or(""));
                info!("unregister from {who}: {}", if removed { "removed" } else { "not found" });
                reply["result"] = json!({"removed": removed});
            }
            Some("push_presence") => {
                if let Some(cid) = requester.str("client_id") {
                    let background = args.bool("active") == Some(false);
                    let mut st = s.st.lock().unwrap();
                    if background {
                        st.backgrounded.insert(cid.into());
                    } else {
                        st.backgrounded.remove(cid);
                    }
                    info!("presence from {who}: {}", if background { "background" } else { "foreground" });
                }
                reply["result"] = json!({});
            }
            other => {
                reply["error"] = json!({"code": "not_supported", "message": format!("unknown action {}", other.unwrap_or(""))});
            }
        }
        if let Err(e) = s.conn.call("client.reply", reply).await {
            info!("client.reply failed: {e}");
        }
    }
}

async fn app_clients(s: &Server) -> Result<Vec<ClientSnapshot>, rex::RexError> {
    let r = s.conn.call("client.list", json!({"kinds": ["app"]})).await?;
    Ok(r.arr("clients").into_iter().filter_map(ClientSnapshot::parse).collect())
}

async fn context(s: &Server, r: &BlockRef) -> BlockContext {
    let sid = &r.session_id;
    let stale = {
        let st = s.st.lock().unwrap();
        match st.views.get(sid) {
            None => true,
            Some(v) => v.revision < st.latest_revision.get(sid).copied().unwrap_or(0),
        }
    };
    if stale {
        if let Ok(v) = s.conn.call("session.view", json!({"session_id": sid})).await {
            let mut st = s.st.lock().unwrap();
            st.views.insert(sid.clone(), parse_view(&v));
            if let Some(l) = v.str("label") {
                st.sessions.insert(sid.clone(), l.into());
            }
        }
    }
    let st = s.st.lock().unwrap();
    let mut c = st.views.get(sid).and_then(|v| v.blocks.get(&r.block_id)).cloned().unwrap_or_default();
    c.session_label = st.sessions.get(sid).filter(|l| !l.is_empty()).cloned();
    c
}

fn parse_view(v: &Value) -> SessionView {
    let mut blocks = HashMap::new();
    for w in v.arr("windows") {
        for layer in w.arr("layers") {
            for b in layer.arr("blocks") {
                let Some(id) = b.str("block_id") else { continue };
                blocks.insert(
                    id.to_string(),
                    BlockContext {
                        window_id: w.str("window_id").map(String::from),
                        tab_label: w.text("label"),
                        block_label: b.text("label"),
                        session_label: None,
                    },
                );
            }
        }
    }
    SessionView { revision: v.int("revision").unwrap_or(0), blocks }
}

fn short(id: &str) -> &str {
    let n = id.len();
    id.get(n.saturating_sub(6)..).unwrap_or(id)
}

/// 0.8 to 1.2, so helpers on many machines don't retry in lockstep.
fn jitter() -> f64 {
    let n = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(0);
    0.8 + f64::from(n % 1000) / 2500.0
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_session_view() {
        let v = json!({"revision": 7, "label": "work", "windows": [
            {"window_id": "window:w1", "label": " api ", "layers": [
                {"blocks": [{"block_id": "block:b1", "label": "claude"}, {"block_id": "block:b2"}]}]}]});
        let view = parse_view(&v);
        assert_eq!(view.revision, 7);
        let b1 = &view.blocks["block:b1"];
        assert_eq!(b1.window_id.as_deref(), Some("window:w1"));
        assert_eq!(b1.tab_label.as_deref(), Some("api"));
        assert_eq!(b1.block_label.as_deref(), Some("claude"));
        assert_eq!(view.blocks["block:b2"].block_label, None);
    }

    #[test]
    fn actions_declare_the_contract() {
        let a = actions();
        let names: Vec<&str> = a.as_array().unwrap().iter().map(|x| x["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["register_push", "unregister_push", "push_presence"]);
        assert_eq!(a[0]["args"]["required"], json!(["token", "environment"]));
    }
}
