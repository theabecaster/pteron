//! The relay: watches the Rex server (found automatically, or the ones in the config), turns
//! agent and notification events into pushes, and serves the client actions the iOS app calls:
//! `helper_identity`, `register_push`, `unregister_push`, `push_presence`, `helper_status`,
//! `update_helper`.
//!
//! Any client of the Rex server can call these actions, so each one first asks who the server
//! says the caller is (`auth::Requester`) and what that identity may do.

use crate::auth::{is_device_id, Gateways, Requester};
use crate::devices::{is_app_open, secret_hash, ClientSnapshot, Device, DeviceStore, Strikes};
use crate::discovery::{self, Endpoint};
use crate::gateway::{describe, SendResult, Sender};
use crate::identity::HelperKey;
use crate::notice;
use crate::policy::{BlockRef, Decision, PushIntent, PushPolicy, RateLimiter, RelayEvent, StatusReport};
use crate::push::{BlockContext, PushMessage};
use crate::rex::{self, Conn, Identity};
use crate::update::{Asset, Plan, Restart, Updater};
use crate::util::{now, now_iso, Json};
use crate::{debug, info};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};
use tokio::task::JoinHandle;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// What a phone that still registers with an APNs token is told.
pub const NEEDS_NEWER_APP: &str = "This Rex DUO Helper needs a newer Rex DUO app.";

/// The least time between two updates asked for through `update_helper`, whoever asks. Each
/// one makes the helper download from GitHub, so a client must not be able to make it do that
/// in a loop. The helper's own timer does not count.
pub const UPDATE_COOLDOWN: Duration = Duration::from_secs(600);

/// The seconds until `update_helper` may be used again, or None when it may be used now.
fn cooldown_left(last: Option<Instant>, now: Instant) -> Option<u64> {
    let since = now.saturating_duration_since(last?);
    (since < UPDATE_COOLDOWN).then(|| (UPDATE_COOLDOWN - since).as_secs().max(1))
}

fn error(code: &str, message: &str) -> Value {
    json!({"code": code, "message": message})
}

/// Actions the relay offers to other Rex clients (declared with `client.keymap`).
/// The server checks `client.perform` args against these schemas. Nothing is `required` in
/// them and the old `token` stays listed, so a call from an app that predates the push gateway
/// still reaches the helper, which answers it in words that app can show.
pub fn actions() -> Value {
    json!([
        {
            "name": "register_push", "kind": "client", "category": "Rex DUO",
            "title": "Register for Rex DUO Pushes",
            "description": "Send push notifications for this server's agents to an iPhone.",
            "args": {
                "type": "object",
                "properties": {
                    "gateway": {"type": "string", "description": "Base URL of the push gateway the phone registered with."},
                    "push_secret": {"type": "string", "description": "The secret the gateway gave the phone for pushes to it."},
                    "environment": {"type": "string", "enum": ["sandbox", "production"]},
                    "device_name": {"type": "string"},
                    "device_id": {"type": "string", "description": "Short id the app also puts in its client label as \"#<id>\"."},
                    "setup_seal": {"type": "string", "description": "From the Rex DUO setup that installed this helper: base64 of 32 bytes, made from its setup code for this registration."},
                    "token": {"type": "string", "description": "No longer used."}
                }
            }
        },
        {
            "name": "helper_identity", "kind": "client", "category": "Rex DUO",
            "title": "Rex DUO Helper Identity",
            "description": "Prove which helper this is: its public key, and a signature over the caller's challenge.",
            "args": {"type": "object", "properties": {
                "challenge": {"type": "string", "description": "32 random bytes, base64url."},
                "device_id": {"type": "string"},
                "setup_challenge": {"type": "string", "description": "32 random bytes, base64url, from the Rex DUO setup that installed this helper."}
            }}
        },
        {
            "name": "unregister_push", "kind": "client", "category": "Rex DUO",
            "title": "Unregister from Rex DUO Pushes",
            "description": "Stop sending pushes to an iPhone.",
            "args": {"type": "object", "properties": {
                "device_id": {"type": "string"},
                "token": {"type": "string", "description": "No longer used."}
            }}
        },
        {
            "name": "push_presence", "kind": "client", "category": "Rex DUO",
            "title": "Rex DUO Presence",
            "description": "Tell the relay whether the calling Rex DUO app is in the foreground.",
            "args": {"type": "object", "properties": {"active": {"type": "boolean"}}, "required": ["active"]}
        },
        {
            "name": "helper_status", "kind": "client", "category": "Rex DUO",
            "title": "Rex DUO Helper Status",
            "description": "The helper's version, whether a newer one is available, and what this computer still asks of its user.",
            "args": {"type": "object", "properties": {}}
        },
        {
            "name": "update_helper", "kind": "client", "category": "Rex DUO",
            "title": "Update Rex DUO Helper",
            "description": "Look for a newer helper now and install it.",
            "args": {"type": "object", "properties": {}}
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
    /// The helper's own client id on this server, from the welcome. It goes into what
    /// `helper_identity` signs.
    client_id: Option<String>,
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
    /// The gateways pushes may go through.
    pub gateways: Gateways,
    /// The helper's identity key, or None when it could not be read or made.
    pub key: Option<HelperKey>,
    /// The state folder, where `install` leaves a setup code.
    pub state_dir: PathBuf,
}

/// How long an answer about this computer (notification permission, lingering) is reused.
/// Each one costs starting a program, and a phone asks `helper_status` every few seconds
/// while its user decides.
const FACTS_TTL: Duration = Duration::from_secs(5);

/// What `helper_status` says about this computer besides the helper itself.
#[derive(Clone, Debug, Default, PartialEq)]
struct HostFacts {
    /// macOS: `allowed`, `denied` or `undetermined`.
    notices: Option<&'static str>,
    /// Linux: whether the helper keeps running after logout.
    linger: Option<bool>,
}

/// The facts read last and when, reused for `FACTS_TTL`.
#[derive(Default)]
struct FactsCache(Option<(Instant, HostFacts)>);

impl FactsCache {
    fn fresh(&self, now: Instant) -> Option<HostFacts> {
        let (read, facts) = self.0.as_ref()?;
        (now.saturating_duration_since(*read) < FACTS_TTL).then(|| facts.clone())
    }

    fn keep(&mut self, now: Instant, facts: HostFacts) {
        self.0 = Some((now, facts));
    }
}

pub struct Relay {
    servers: Vec<Arc<Server>>,
    policy: Mutex<PushPolicy>,
    limiter: Mutex<RateLimiter>,
    store: Mutex<DeviceStore>,
    notices: Mutex<notice::NoticeLimiter>,
    sender: Sender,
    updater: Arc<Updater>,
    gateways: Gateways,
    key: Option<HelperKey>,
    /// The gateway's `401` answers so far, per secret.
    strikes: Mutex<Strikes>,
    /// When `update_helper` last made the helper look for an update.
    asked_update: Mutex<Option<Instant>>,
    facts: Mutex<FactsCache>,
    state_dir: PathBuf,
    dry_run: bool,
    identity: Identity,
    due_task: Mutex<Option<JoinHandle<()>>>,
    status_path: PathBuf,
    stopping: AtomicBool,
}

impl Relay {
    /// One connection per entry of `watch`; None is the server discovery finds.
    pub fn new(watch: Vec<Option<Endpoint>>, mut store: DeviceStore, sender: Sender, updater: Arc<Updater>, o: Options) -> Arc<Relay> {
        // A gateway that was taken out of config.json gets no more pushes.
        let gone = store.keep_gateways(|g| o.gateways.accept(g).is_some());
        if gone > 0 {
            info!("dropped {gone} registration(s) whose gateway is no longer allowed");
        }
        let mut identity = Identity::default();
        if let Some(l) = o.label.filter(|l| !l.is_empty()) {
            identity.label = l;
        }
        Arc::new(Relay {
            servers: watch
                .into_iter()
                .map(|f| Arc::new(Server { conn: Conn::default(), fixed: f, st: Mutex::new(ServerState::default()) }))
                .collect(),
            policy: Mutex::new(PushPolicy::new(o.debounce)),
            limiter: Mutex::new(RateLimiter::new(o.burst, o.per_minute)),
            store: Mutex::new(store),
            notices: Mutex::new(notice::NoticeLimiter::default()),
            sender,
            updater,
            gateways: o.gateways,
            key: o.key,
            strikes: Mutex::new(Strikes::default()),
            asked_update: Mutex::new(None),
            facts: Mutex::new(FactsCache::default()),
            state_dir: o.state_dir,
            dry_run: o.dry_run,
            identity,
            due_task: Mutex::new(None),
            status_path: o.status_path,
            stopping: AtomicBool::new(false),
        })
    }

    /// The registrations, as devices.json has them now (`rex-duo-helper forget` may have
    /// changed the file).
    fn store(&self) -> MutexGuard<'_, DeviceStore> {
        let mut store = self.store.lock().unwrap();
        store.sync();
        store
    }

    pub fn start(self: &Arc<Self>) {
        let n = self.store().devices.len();
        let mode = if self.dry_run { "dry run, no pushes are sent" } else { "pushes go through the gateway" };
        info!("Rex DUO Helper {VERSION} starting; {n} registered device(s); {mode}");
        // status.json follows what the updater learns. Weak, so the two don't keep each other alive.
        let relay = Arc::downgrade(self);
        self.updater.set_on_change(move || {
            if let Some(r) = relay.upgrade() {
                if !r.stopping.load(Ordering::SeqCst) {
                    r.write_status();
                }
            }
        });
        self.write_status();
        tokio::spawn(self.updater.clone().run_timer());
        // A setup code is gone 30 minutes after `install` stored it, asked for or not.
        let state_dir = self.state_dir.clone();
        tokio::spawn(async move {
            loop {
                crate::setup::sweep(&state_dir, now() as i64);
                tokio::time::sleep(Duration::from_secs(60)).await;
            }
        });
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
        // The updater's fields (`version`, `latest_version`, `update_available`, `checked_at`,
        // `updating`, `can_update`, `last_error`), then the relay's own.
        let mut v = self.updater.status();
        v["pid"] = json!(std::process::id());
        v["helper_version"] = json!(VERSION);
        v["connected"] = json!(!ready.is_empty());
        v["servers"] = json!(ready);
        v["dry_run"] = json!(self.dry_run);
        v["exe_mtime"] = json!(std::env::current_exe().map(|p| crate::service::mtime(&p)).unwrap_or(0));
        v["updated_at"] = json!(now_iso());
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
                // A server the config also names has its own connection; a second one would
                // show up in Rex as a second helper.
                None => discovery::find().await.filter(|found| !self.watched_by_name(found)),
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
                            s.st.lock().unwrap().client_id = welcome.client_id.clone();
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

    /// True when `found` is one of the servers the config names.
    fn watched_by_name(&self, found: &Endpoint) -> bool {
        self.servers.iter().any(|s| s.fixed.as_ref().is_some_and(|fixed| fixed.same(found)))
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
        info!("[{}] watching {} session(s) as {}; offering its actions to Rex DUO", st.host, st.sessions.len(), st.name);
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
        // The words of a push stay out of the log; a dry run shows them, that is what it is for.
        if self.dry_run {
            info!("push {} [{}] \"{}\": {}", msg.category.as_str(), msg.interruption_level, msg.title, msg.body);
        } else {
            info!("push {} [{}]", msg.category.as_str(), msg.interruption_level);
        }
        let devices = self.store().devices.clone();
        if devices.is_empty() {
            if self.dry_run {
                info!("DRY-RUN push -> (no registered devices) {}", describe(&msg));
            }
            return;
        }
        let (clients, background) = self.presence_snapshot().await;
        self.deliver(&msg, devices, &clients, &background, now()).await;
    }

    /// One request per phone that should get this push, at time `t`. Any failure loses this
    /// push for that phone; it is not retried. A phone the gateway has dropped (`410`), or
    /// whose secret the gateway refused twice a minute apart (`401`), is unregistered and its
    /// secret remembered as refused. The phone learns of it from `registered: false` in its
    /// next `push_presence` or `helper_status`, and registers again.
    async fn deliver(&self, msg: &PushMessage, devices: Vec<Device>, clients: &[ClientSnapshot], background: &HashSet<String>, t: f64) {
        for d in devices {
            let who = d.who();
            if is_app_open(&d, clients, background) {
                info!("skip {who}: Rex DUO is open");
                continue;
            }
            if !self.limiter.lock().unwrap().allow(&d.device_id, t) {
                info!("skip {who}: rate limited");
                continue;
            }
            let hash = secret_hash(&d.push_secret);
            match self.sender.send(msg, &d).await {
                SendResult::Sent(id) => {
                    self.strikes.lock().unwrap().clear(&hash);
                    if !self.dry_run {
                        info!("sent to {who}{}", id.map(|i| format!(" (apns-id {i})")).unwrap_or_default());
                    }
                }
                SendResult::Gone(why) => {
                    info!("the gateway no longer has {who} ({why}); unregistering it until the phone registers again");
                    self.strikes.lock().unwrap().clear(&hash);
                    self.store().drop_secret(&d.device_id, &d.push_secret);
                }
                SendResult::Unauthorized => {
                    if self.strikes.lock().unwrap().refused(&hash, t) {
                        info!("the gateway refused {who}'s secret again; unregistering it until the phone registers again");
                        self.store().drop_secret(&d.device_id, &d.push_secret);
                    } else {
                        info!("the gateway refused {who}'s secret; this push is dropped, the registration stays unless it happens again in a minute or more");
                    }
                }
                SendResult::Failed(why) => info!("push to {who} dropped: {why}"),
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
        let requester = Requester::parse(p.obj("requester").unwrap_or(&empty));
        let (outcome, after) = self.act(s, p.str("action").unwrap_or(""), args, &requester).await;
        let mut reply = json!({"call_id": call_id});
        match outcome {
            Ok(result) => reply["result"] = result,
            Err(error) => reply["error"] = error,
        }
        if let Err(e) = s.conn.call("client.reply", reply).await {
            info!("client.reply failed: {e}");
        }
        // Rex has answered `client.reply`, so the app has its result before anything restarts.
        if let Some((version, asset)) = after {
            let _ = self.updater.install(&version, &asset, Restart::Detached).await;
        }
    }

    /// Decides one client action: its result or error, and what to start once the reply is on
    /// its way (an update restarts this process).
    async fn act(&self, s: &Server, action: &str, args: &Value, requester: &Requester) -> (Result<Value, Value>, Option<(String, Asset)>) {
        let who = requester.who();
        // A client the server could not name can't own a registration, and nothing here is
        // for someone who may be anyone.
        let Some(identity) = requester.identity.as_deref() else {
            // The action's name is the caller's text: only a name the helper knows is repeated.
            let known = ["register_push", "unregister_push", "push_presence", "helper_identity", "helper_status", "update_helper"].contains(&action);
            info!("refused {} from {who}: the Rex server did not identify it", if known { action } else { "an unknown action" });
            return (Err(error("refused", "Rex DUO Helper only answers clients the Rex server has identified.")), None);
        };
        let mut after = None;
        let outcome = match action {
            "register_push" => self.register(args, requester, identity).inspect(|_| {
                // A registration that carries the setup's seal is the one the setup was for:
                // its code has done its work. Any other registration is only a registration.
                let (secret, device_id) = (args.str("push_secret").unwrap_or(""), args.str("device_id").unwrap_or(""));
                if crate::setup::registered(&self.state_dir, identity, secret, device_id, args.str("setup_seal"), now() as i64) {
                    info!("the Rex DUO setup that installed this helper is complete, for {who}");
                }
            }),
            "unregister_push" => Ok(self.unregister(args, requester, identity)),
            "push_presence" => {
                let background = args.bool("active") == Some(false);
                if !requester.client_id.is_empty() {
                    let mut st = s.st.lock().unwrap();
                    if background {
                        st.backgrounded.insert(requester.client_id.clone());
                    } else {
                        st.backgrounded.remove(&requester.client_id);
                    }
                    info!("presence from {who}: {}", if background { "background" } else { "foreground" });
                }
                Ok(json!({"registered": self.registered(requester, identity)}))
            }
            "helper_identity" => self.identify(s, args, requester, identity),
            "helper_status" => {
                let mut status = self.updater.status();
                status["registered"] = json!(self.registered(requester, identity));
                let facts = self.host_facts().await;
                status["notices"] = json!(facts.notices);
                status["linger"] = json!(facts.linger);
                Ok(status)
            }
            "update_helper" => self.begin_update(&who, identity).await.map(|(result, start)| {
                after = start;
                result
            }),
            _ => Err(error("not_supported", "Rex DUO Helper has no such action.")),
        };
        (outcome, after)
    }

    /// True when the requester's phone (the device id at the end of its label) has a
    /// registration here that the requester's identity made. False tells the app to register
    /// again: this helper never had its secret, or the gateway refused it.
    fn registered(&self, requester: &Requester, identity: &str) -> bool {
        requester.device_id().is_some_and(|id| self.store().get(id).is_some_and(|d| d.owner == identity))
    }

    /// The notification permission and lingering, read now or within the last `FACTS_TTL`.
    async fn host_facts(&self) -> HostFacts {
        let now = Instant::now();
        if let Some(facts) = self.facts.lock().unwrap().fresh(now) {
            return facts;
        }
        let facts = HostFacts { notices: notice::status().await, linger: crate::service::linger_state().await };
        self.facts.lock().unwrap().keep(now, facts.clone());
        facts
    }

    /// `helper_identity`: signs the caller's challenge with the helper's key, bound to both
    /// client ids (identity.rs says why). With a `setup_challenge`, and while the helper holds
    /// the code of the setup that installed it, the answer also carries a `setup_proof` made
    /// from that code (setup.rs), up to three for one identity and ten in all. The code is
    /// read from the state folder on each call, so a helper that was running before `install`
    /// stored it answers too.
    fn identify(&self, s: &Server, args: &Value, requester: &Requester, identity: &str) -> Result<Value, Value> {
        let Some(key) = &self.key else { return Err(error("internal", "This Rex DUO Helper has no identity key.")) };
        let Some(own) = s.st.lock().unwrap().client_id.clone() else {
            return Err(error("internal", "This Rex DUO Helper does not know its own client id on this server."));
        };
        let setup_challenge = match args.get("setup_challenge") {
            None | Some(Value::Null) => None,
            Some(c) => Some(c.as_str().filter(|c| crate::identity::is_challenge(c)).ok_or_else(|| error("bad_request", "setup_challenge must be the base64url of 32 bytes"))?),
        };
        let mut answer =
            key.answer(args.str("challenge").unwrap_or(""), &own, &requester.client_id, args.str("device_id").unwrap_or("")).map_err(|m| error("bad_request", m))?;
        if let Some(challenge) = setup_challenge {
            if let Some(proof) = crate::setup::take_proof(&self.state_dir, challenge, &own, &requester.client_id, identity, now() as i64) {
                info!("answered the Rex DUO setup that installed this helper, for {}", requester.who());
                answer["setup_proof"] = json!(proof);
            }
        }
        Ok(answer)
    }

    /// `register_push`: stores the phone's gateway and secret under its device id, for the
    /// identity that asked. A `setup_seal` among the args plays no part here: `act` reads it
    /// once the registration is made.
    fn register(&self, args: &Value, requester: &Requester, identity: &str) -> Result<Value, Value> {
        let who = requester.who();
        let bad = |m: &str| Err(error("bad_request", m));
        let secret = args.str("push_secret").unwrap_or("");
        if secret.is_empty() && args.get("token").is_some() {
            info!("{who} registered the old way (an APNs token); it needs a newer Rex DUO");
            return Err(error("not_supported", NEEDS_NEWER_APP));
        }
        let env = args.str("environment").unwrap_or("");
        let dev_id = args.str("device_id").unwrap_or("");
        // The helper sends the secret wherever this says, so it must be a gateway the helper
        // already knows, not one the caller picked.
        let Some(gateway) = args.str("gateway").and_then(|g| self.gateways.accept(g)) else {
            info!("refused a registration from {who}: its gateway is not one this helper pushes through");
            return bad("gateway is not one this helper pushes through (the built-in one, or one listed in its config.json)");
        };
        if !Device::is_valid_secret(secret) {
            return bad("push_secret must be the secret the gateway gave this phone");
        }
        if env != "sandbox" && env != "production" {
            return bad("environment must be sandbox or production");
        }
        if !is_device_id(dev_id) {
            return bad("device_id must be 8 lowercase hex digits");
        }
        // The label is the caller's own word, so this proves nothing about who it is. It
        // keeps an honest client from registering under an id that pushes would then be
        // skipped or sent for by mistake: the helper finds a phone's app by this suffix.
        if requester.device_id() != Some(dev_id) {
            return bad("device_id must be the id at the end of this client's label");
        }
        let mut d = Device::new(dev_id, &gateway, secret, env, identity);
        d.device_name = args.text("device_name");
        let (d, count, new) = {
            let mut store = self.store();
            if store.is_dropped(secret) {
                info!("refused a registration from {who}: the gateway has already refused that secret");
                return Err(error("secret_dropped", "The push gateway no longer accepts that secret. The phone needs a new one."));
            }
            // A phone belongs to whoever registered it first. Anyone else would be taking
            // over where its pushes go, or cutting them off.
            if store.get(dev_id).is_some_and(|old| old.owner != identity) {
                info!("refused a registration from {who}: #{dev_id} is registered to someone else");
                return Err(error(
                    "not_your_device",
                    "That phone is registered to someone else on this computer. To clear it, run there: rex-duo-helper forget <device id>",
                ));
            }
            let new = store.first_sight(dev_id);
            let d = store.register(d);
            (d, store.devices.len(), new)
        };
        info!("registered {} [{env}] #{} from {who}", d.device_name.as_deref().unwrap_or("device"), d.device_id);
        if new && self.notices.lock().unwrap().allow(Instant::now()) {
            notice::post(&notice::body(d.device_name.as_deref()), self.dry_run);
        } else if new {
            info!(
                "holding back the desktop notice: more than {} new devices in {} s",
                notice::NOTICE_LIMIT,
                notice::NOTICE_WINDOW.as_secs()
            );
        }
        Ok(json!({"registered": true, "devices": count, "push_enabled": !self.dry_run, "helper_version": VERSION}))
    }

    /// `unregister_push`: by device id, and only for the identity that registered it. An old
    /// app's `token` alone removes nothing.
    fn unregister(&self, args: &Value, requester: &Requester, identity: &str) -> Value {
        let removed = args.str("device_id").is_some_and(|id| {
            let mut store = self.store();
            let secret = store.get(id).filter(|d| d.owner == identity).map(|d| d.push_secret.clone());
            secret.is_some_and(|secret| {
                self.strikes.lock().unwrap().clear(&secret_hash(&secret));
                store.remove(id)
            })
        });
        info!("unregister from {}: {}", requester.who(), if removed { "removed" } else { "nothing of theirs to remove" });
        json!({"removed": removed})
    }

    /// Takes the one `update_helper` slot of this ten minutes, or says how long is left.
    fn take_update_slot(&self, now: Instant) -> Result<(), Value> {
        let mut asked = self.asked_update.lock().unwrap();
        if let Some(left) = cooldown_left(*asked, now) {
            return Err(error("update_cooldown", &format!("An update was asked for a moment ago. Try again in {left} s.")));
        }
        *asked = Some(now);
        Ok(())
    }

    /// `update_helper`: looks for a newer version now. Returns the action's result, and what to
    /// install once that result has been sent. Only for someone who has a phone registered
    /// here: replacing the program is not for every client that can reach Rex.
    async fn begin_update(&self, who: &str, identity: &str) -> Result<(Value, Option<(String, Asset)>), Value> {
        if !self.store().owns_any(identity) {
            info!("refused an update asked for by {who}: no phone of theirs is registered here");
            return Err(error("refused", "Only someone with a phone registered on this helper can update it."));
        }
        info!("update asked for by {who}");
        if let Some(version) = self.updater.updating() {
            return Ok((json!({"started": true, "version": version}), None));
        }
        // The app gets one of a few fixed sentences. What exactly went wrong is in the log.
        let failed = |f: crate::update::Fault| error("update_failed", f.problem.sentence());
        if let Some(why) = self.updater.blocker() {
            return Err(failed(why));
        }
        self.take_update_slot(Instant::now())?;
        match self.updater.check().await.map_err(failed)? {
            Plan::UpToDate => Ok((json!({"started": false, "version": VERSION}), None)),
            Plan::Update { version, asset } => Ok((json!({"started": true, "version": version.clone()}), Some((version, asset)))),
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
        assert_eq!(names, ["register_push", "helper_identity", "unregister_push", "push_presence", "helper_status", "update_helper"]);
        let args: Vec<&str> = a[0]["args"]["properties"].as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(args, ["device_id", "device_name", "environment", "gateway", "push_secret", "setup_seal", "token"]);
        let args: Vec<&str> = a[1]["args"]["properties"].as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(args, ["challenge", "device_id", "setup_challenge"]);
        // Nothing required: a call from an old app must reach the helper to get its answer.
        assert!(a[0]["args"].get("required").is_none());
        assert!(a[2]["args"].get("required").is_none());
    }

    use crate::net::testing::{canned, serve};
    use crate::policy::PushCategory;
    use crate::update::Env;
    use crate::util::testing::{capture_log, captured_log};

    const SECRET: &str = "S3cr3tS3cr3tS3cr3tS3cr3tS3cr3tS3cr3tS3cr3t0";
    const NEW_SECRET: &str = "N3wS3cr3tN3wS3cr3tN3wS3cr3tN3wS3cr3tN3wS3c0";
    /// A gateway the tests' config.json lists. Nothing is ever sent to it.
    const GATEWAY: &str = "https://push.example.com";
    /// Two people on the tailnet, and what the server says about them.
    const ALEX: &str = "tailscale:12345";
    const SAM: &str = "tailscale:777";

    fn temp(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("relay-{tag}-{}-{}", std::process::id(), now()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A relay with no server. Only a relay with `dry_run` may be asked to `register`: it
    /// logs the desktop notice instead of posting it. `sender` says whether pushes go out
    /// (to a server in the test) or are logged.
    fn relay_with(dir: &std::path::Path, dry_run: bool, sender: Sender, gateways: &[&str]) -> Arc<Relay> {
        let env = Env { dry_run, debug_build: true, keys: Ok(vec![[7u8; 32]]), place: Err("test".into()), service: false, writable: false };
        let config: Vec<String> = gateways.iter().map(|g| g.to_string()).collect();
        Relay::new(
            vec![],
            DeviceStore::open(dir.join("devices.json")),
            sender,
            Updater::with_env(env, false, dir),
            Options {
                dry_run,
                label: None,
                debounce: 30.0,
                burst: 10.0,
                per_minute: 10.0,
                status_path: dir.join("status.json"),
                gateways: Gateways::new(&config).0,
                key: Some(HelperKey::load_or_create(&dir.join("identity.key")).unwrap()),
                state_dir: dir.to_path_buf(),
            },
        )
    }

    fn relay(dir: &std::path::Path, dry_run: bool) -> Arc<Relay> {
        relay_with(dir, dry_run, if dry_run { Sender::DryRun } else { Sender::Gateway }, &[GATEWAY])
    }

    /// The server the helper is connected to, where it is `client:helper`.
    fn server() -> Server {
        Server { conn: Conn::default(), fixed: None, st: Mutex::new(ServerState { client_id: Some("client:helper".into()), ..Default::default() }) }
    }

    /// Rex DUO on a phone with this device id, as the server reports the caller.
    fn app(device_id: &str, identity: Option<&str>) -> Requester {
        Requester { client_id: format!("client:{device_id}"), label: format!("Alex's iPhone #{device_id}"), identity: identity.map(String::from) }
    }

    fn register_args() -> Value {
        json!({"gateway": "https://push.example.com/", "push_secret": SECRET, "environment": "production",
            "device_name": "Alex's iPhone", "device_id": "a1b2c3d4"})
    }

    fn register(r: &Relay, args: &Value, identity: &str) -> Result<Value, Value> {
        r.register(args, &app(args["device_id"].as_str().unwrap_or(""), Some(identity)), identity)
    }

    fn devices(r: &Relay) -> Vec<Device> {
        r.store.lock().unwrap().devices.clone()
    }

    #[test]
    fn register_stores_gateway_and_secret_by_device_id() {
        let dir = temp("register");
        let r = relay(&dir, true);
        let result = register(&r, &register_args(), ALEX).unwrap();
        assert_eq!(result, json!({"registered": true, "devices": 1, "push_enabled": false, "helper_version": VERSION}));
        let d = devices(&r)[0].clone();
        assert_eq!((d.device_id.as_str(), d.gateway.as_str(), d.push_secret.as_str()), ("a1b2c3d4", GATEWAY, SECRET));
        assert_eq!((d.environment.as_str(), d.device_name.as_deref(), d.owner.as_str()), ("production", Some("Alex's iPhone"), ALEX));
        // The same phone with a new secret replaces its entry.
        let mut again = register_args();
        again["push_secret"] = json!(NEW_SECRET);
        assert_eq!(register(&r, &again, ALEX).unwrap()["devices"], 1);
        assert_eq!(devices(&r)[0].push_secret, NEW_SECRET);
        // The built-in gateway needs no config.
        let mut builtin = register_args();
        builtin["gateway"] = json!(crate::auth::DEFAULT_GATEWAY);
        builtin["device_id"] = json!("ffff0000");
        assert_eq!(register(&r, &builtin, ALEX).unwrap()["devices"], 2);
        assert_eq!(devices(&r)[1].gateway, "https://rexduo-push.keptday.workers.dev");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn register_refuses_what_it_cannot_use() {
        let dir = temp("refuse");
        let r = relay(&dir, true);
        let with = |k: &str, v: Value| {
            let mut a = register_args();
            a[k] = v;
            r.register(&a, &app("a1b2c3d4", Some(ALEX)), ALEX).unwrap_err()
        };
        for (key, value) in [
            // Not on the allowlist, however well formed.
            ("gateway", json!("https://evil.example.com")),
            ("gateway", json!("https://push.example.com.evil.example.com")),
            ("gateway", json!("https://push.example.com:8443")),
            ("gateway", json!("https://push.example.com/base")),
            ("gateway", json!("http://push.example.com")),
            ("gateway", json!("http://127.0.0.1:8787")),
            ("gateway", json!("http://localhost:8787")),
            ("gateway", json!("https://10.0.0.5")),
            ("gateway", json!("push.example.com")),
            ("gateway", json!("https://user@push.example.com")),
            ("gateway", Value::Null),
            ("push_secret", json!("short")),
            ("push_secret", json!(format!("{SECRET}\r\nX-Evil: 1"))),
            ("environment", json!("staging")),
            ("device_id", json!("not-an-id")),
            ("device_id", json!("A1B2C3D4")),
            ("device_id", Value::Null),
            // A real id, but not the one this client carries in its label.
            ("device_id", json!("ffff0000")),
        ] {
            assert_eq!(with(key, value.clone())["code"], "bad_request", "{key} = {value}");
        }
        // A client whose label names no device can't register one.
        for label in ["Alex's iPhone", "rex", "Alex's iPhone #A1B2C3D4", "a1b2c3d4"] {
            let bare = Requester { client_id: "client:9".into(), label: label.into(), identity: Some(ALEX.into()) };
            assert_eq!(r.register(&register_args(), &bare, ALEX).unwrap_err()["code"], "bad_request", "{label}");
        }
        assert!(devices(&r).is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn plain_http_is_only_for_a_gateway_on_this_machine_that_the_config_lists() {
        let dir = temp("http");
        let r = relay_with(&dir, true, Sender::DryRun, &["http://127.0.0.1:8787", "http://push.example.com"]);
        let with = |gateway: &str| {
            let mut a = register_args();
            a["gateway"] = json!(gateway);
            register(&r, &a, ALEX)
        };
        assert!(with("http://127.0.0.1:8787").is_ok());
        assert_eq!(devices(&r)[0].gateway, "http://127.0.0.1:8787");
        assert!(with("http://127.0.0.1:8788").is_err(), "another port is another gateway");
        assert!(with("http://localhost:8787").is_err());
        assert!(with("http://push.example.com").is_err(), "the config can't allow plain http to another machine");
        assert!(with(GATEWAY).is_err(), "not in this config");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_gateway_taken_out_of_the_config_gets_no_more_pushes() {
        let dir = temp("delisted");
        let r = relay(&dir, true);
        register(&r, &register_args(), ALEX).unwrap();
        let mut builtin = register_args();
        builtin["gateway"] = json!(crate::auth::DEFAULT_GATEWAY);
        builtin["device_id"] = json!("ffff0000");
        register(&r, &builtin, ALEX).unwrap();
        drop(r);
        // The next start has no `gateways` in its config.
        let r = relay_with(&dir, false, Sender::Gateway, &[]);
        let left: Vec<String> = devices(&r).into_iter().map(|d| d.device_id).collect();
        assert_eq!(left, ["ffff0000"]);
        assert_eq!(DeviceStore::open(dir.join("devices.json")).devices.len(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_legacy_registration_is_told_to_update_the_app() {
        let dir = temp("legacy");
        let r = relay(&dir, true);
        let old = json!({"token": "ab".repeat(32), "environment": "sandbox", "device_name": "iPhone", "device_id": "a1b2c3d4"});
        let e = register(&r, &old, ALEX).unwrap_err();
        assert_eq!(e["message"], "This Rex DUO Helper needs a newer Rex DUO app.");
        assert!(devices(&r).is_empty());
        // A token beside a secret is ignored: that is a new app.
        let mut both = register_args();
        both["token"] = json!("ab".repeat(32));
        assert!(register(&r, &both, ALEX).is_ok());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_client_the_server_did_not_identify_gets_nothing() {
        let dir = temp("anonymous");
        let r = relay(&dir, true);
        let s = server();
        register(&r, &register_args(), ALEX).unwrap();
        let nobody = app("a1b2c3d4", None);
        let challenge = crate::util::base64url(&[9u8; 32]);
        for (action, args) in [
            ("register_push", register_args()),
            ("unregister_push", json!({"device_id": "a1b2c3d4"})),
            ("push_presence", json!({"active": false})),
            ("helper_identity", json!({"challenge": challenge, "device_id": "a1b2c3d4"})),
            ("helper_status", json!({})),
            ("update_helper", json!({})),
            ("anything_else", json!({})),
        ] {
            let (outcome, after) = r.act(&s, action, &args, &nobody).await;
            assert_eq!(outcome.unwrap_err()["code"], "refused", "{action}");
            assert!(after.is_none());
        }
        // Nothing changed: the phone is still registered and was not marked as in the background.
        assert_eq!(devices(&r).len(), 1);
        assert!(s.st.lock().unwrap().backgrounded.is_empty());
        // The same refusal for a requester parsed from what an unidentified connection looks like.
        let parsed = Requester::parse(&json!({"client_id": "client:5", "info": {"label": "Alex's iPhone #a1b2c3d4"},
            "principal": {"kind": "anonymous", "transport": "tcp", "display": "anonymous"}}));
        assert_eq!(r.act(&s, "helper_status", &json!({}), &parsed).await.0.unwrap_err()["code"], "refused");
        // An identified client asking for something the helper doesn't offer is told so.
        assert_eq!(r.act(&s, "anything_else", &json!({}), &app("a1b2c3d4", Some(ALEX))).await.0.unwrap_err()["code"], "not_supported");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_registration_belongs_to_the_identity_that_made_it() {
        let dir = temp("owner");
        let r = relay(&dir, true);
        let s = server();
        register(&r, &register_args(), ALEX).unwrap();
        // Someone else, with a client that carries the same device id in its label, can't
        // replace it, with the same secret or another.
        let mut theirs = register_args();
        theirs["push_secret"] = json!(NEW_SECRET);
        for args in [&register_args(), &theirs] {
            let e = register(&r, args, SAM).unwrap_err();
            assert_eq!(e["code"], "not_your_device");
            assert!(e["message"].as_str().unwrap().contains("rex-duo-helper forget"));
        }
        // A local user of the same number is not the tailnet user.
        assert_eq!(register(&r, &theirs, "peer:12345").unwrap_err()["code"], "not_your_device");
        assert_eq!((devices(&r).len(), devices(&r)[0].push_secret.as_str(), devices(&r)[0].owner.as_str()), (1, SECRET, ALEX));

        // Nor remove it. The owner can, from any of their clients.
        let sam = app("a1b2c3d4", Some(SAM));
        assert_eq!(r.act(&s, "unregister_push", &json!({"device_id": "a1b2c3d4"}), &sam).await.0.unwrap(), json!({"removed": false}));
        assert_eq!(devices(&r).len(), 1);
        // An old app's token alone removes nothing, and neither does an id nobody registered.
        let alex = app("a1b2c3d4", Some(ALEX));
        for args in [json!({"token": "ab".repeat(32)}), json!({}), json!({"device_id": "ffff0000"}), json!({"device_id": "A1B2C3D4"})] {
            assert_eq!(r.unregister(&args, &alex, ALEX), json!({"removed": false}), "{args}");
        }
        let other_client = Requester { client_id: "client:mac".into(), label: "rex".into(), identity: Some(ALEX.into()) };
        assert_eq!(r.unregister(&json!({"device_id": "a1b2c3d4", "token": "ab".repeat(32)}), &other_client, ALEX), json!({"removed": true}));
        assert!(devices(&r).is_empty());

        // Once it is gone the id is free again, for whoever registers first.
        register(&r, &theirs, SAM).unwrap();
        assert_eq!(register(&r, &register_args(), ALEX).unwrap_err()["code"], "not_your_device");
        // The way out on the computer itself: forget it there, and the running helper sees it.
        assert_eq!(crate::devices::forget(&dir.join("devices.json"), "a1b2c3d4"), Ok(true));
        register(&r, &register_args(), ALEX).unwrap();
        assert_eq!(devices(&r)[0].owner, ALEX);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn presence_and_status_say_whether_the_callers_phone_is_registered() {
        let dir = temp("registered");
        let r = relay(&dir, true);
        let s = server();
        let alex = app("a1b2c3d4", Some(ALEX));
        let presence = |who: &Requester, active: bool| {
            let (r, s, who) = (r.clone(), &s, who.clone());
            async move { r.act(s, "push_presence", &json!({"active": active}), &who).await.0.unwrap() }
        };
        assert_eq!(presence(&alex, true).await, json!({"registered": false}));
        register(&r, &register_args(), ALEX).unwrap();
        assert_eq!(presence(&alex, false).await, json!({"registered": true}));
        assert!(s.st.lock().unwrap().backgrounded.contains("client:a1b2c3d4"));
        assert_eq!(presence(&alex, true).await, json!({"registered": true}));
        assert!(s.st.lock().unwrap().backgrounded.is_empty());

        let status = r.act(&s, "helper_status", &json!({}), &alex).await.0.unwrap();
        let keys: Vec<&str> = status.as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(
            keys,
            ["can_update", "checked_at", "last_error", "latest_version", "linger", "manifest_expires_at", "min_version", "notices", "registered", "update_available",
                "update_required", "updating", "version"]
        );
        assert_eq!((status["registered"].as_bool(), status["version"].as_str()), (Some(true), Some(VERSION)));

        // Another phone of the same person, someone else's client with this phone's id in its
        // label, and a client with no device id: not registered.
        for other in [app("ffff0000", Some(ALEX)), app("a1b2c3d4", Some(SAM)), Requester { client_id: "client:mac".into(), label: "rex".into(), identity: Some(ALEX.into()) }] {
            assert_eq!(presence(&other, true).await, json!({"registered": false}), "{other:?}");
            assert_eq!(r.act(&s, "helper_status", &json!({}), &other).await.0.unwrap()["registered"], false);
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn helper_identity_signs_for_this_requester_on_this_server() {
        let dir = temp("identity");
        let r = relay(&dir, true);
        let s = server();
        let alex = app("a1b2c3d4", Some(ALEX));
        let challenge = crate::util::base64url(&[9u8; 32]);
        let args = json!({"challenge": challenge, "device_id": "a1b2c3d4"});
        let answer = r.act(&s, "helper_identity", &args, &alex).await.0.unwrap();
        assert_eq!(answer["client_id"], "client:helper");
        let public = crate::util::base64_decode(answer["public_key"].as_str().unwrap()).unwrap();
        let signature = crate::util::base64_decode(answer["signature"].as_str().unwrap()).unwrap();
        assert_eq!(public, r.key.as_ref().unwrap().public_key());
        let verifies = |message: String| ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, &public).verify(message.as_bytes(), &signature).is_ok();
        // The helper's client id from the welcome, then the caller's as the server gave it.
        assert!(verifies(format!("rexduo-helper-identity-v1\n{challenge}\nclient:helper\nclient:a1b2c3d4\na1b2c3d4")));
        // A client in the middle that passes the phone's challenge on gets a signature that
        // names itself, which the phone refuses.
        let relayed = r.act(&s, "helper_identity", &args, &app("ffff0000", Some(SAM))).await.0.unwrap();
        assert_ne!(relayed["signature"], answer["signature"]);
        assert!(!verifies(format!("rexduo-helper-identity-v1\n{challenge}\nclient:helper\nclient:ffff0000\na1b2c3d4")));
        // The key is the same after a restart.
        assert_eq!(relay(&dir, true).key.as_ref().unwrap().public_key(), public[..]);

        for bad in [json!({"challenge": "AAAA", "device_id": "a1b2c3d4"}), json!({"device_id": "a1b2c3d4"}), json!({"challenge": challenge}), json!({"challenge": challenge, "device_id": "A1B2C3D4"})] {
            assert_eq!(r.act(&s, "helper_identity", &bad, &alex).await.0.unwrap_err()["code"], "bad_request", "{bad}");
        }
        // Before the welcome told the helper who it is on this server, it signs nothing.
        let early = Server { conn: Conn::default(), fixed: None, st: Mutex::new(ServerState::default()) };
        assert_eq!(r.act(&early, "helper_identity", &args, &alex).await.0.unwrap_err()["code"], "internal");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn only_someone_with_a_phone_here_may_update_and_not_in_a_loop() {
        let dir = temp("update");
        let r = relay(&dir, true);
        let s = server();
        let (alex, sam) = (app("a1b2c3d4", Some(ALEX)), app("ffff0000", Some(SAM)));
        // Nobody is registered: nobody may.
        assert_eq!(r.act(&s, "update_helper", &json!({}), &alex).await.0.unwrap_err()["code"], "refused");
        register(&r, &register_args(), ALEX).unwrap();
        assert_eq!(r.act(&s, "update_helper", &json!({}), &sam).await.0.unwrap_err()["code"], "refused");
        // The owner may. This helper can't update (a dry run), and says so in a fixed
        // sentence: the reason with its paths is for the log.
        let (outcome, after) = r.act(&s, "update_helper", &json!({}), &alex).await;
        assert_eq!(outcome.unwrap_err(), json!({"code": "update_failed", "message": "This copy of Rex DUO Helper can't update itself."}));
        assert!(after.is_none());
        // Refusals use up no slot.
        assert!(r.asked_update.lock().unwrap().is_none());

        // One attempt per ten minutes, whoever asks.
        let t = Instant::now();
        assert_eq!(r.take_update_slot(t), Ok(()));
        let e = r.take_update_slot(t + Duration::from_secs(1)).unwrap_err();
        assert_eq!(e, json!({"code": "update_cooldown", "message": "An update was asked for a moment ago. Try again in 599 s."}));
        assert_eq!(r.take_update_slot(t + Duration::from_secs(599)).unwrap_err()["code"], "update_cooldown");
        assert_eq!(r.take_update_slot(t + Duration::from_secs(600)), Ok(()));
        // A refused attempt does not push the next one further out.
        assert_eq!(r.take_update_slot(t + Duration::from_secs(1199)).unwrap_err()["message"], "An update was asked for a moment ago. Try again in 1 s.");
        assert_eq!(r.take_update_slot(t + Duration::from_secs(1200)), Ok(()));

        assert_eq!(cooldown_left(None, t), None);
        assert_eq!(cooldown_left(Some(t), t), Some(600));
        assert_eq!(cooldown_left(Some(t), t + Duration::from_millis(599_500)), Some(1));
        assert_eq!(cooldown_left(Some(t), t + UPDATE_COOLDOWN), None);
        // A clock that reads earlier than the last attempt never frees the slot early.
        assert_eq!(cooldown_left(Some(t + Duration::from_secs(5)), t), Some(600));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn helper_status_and_status_file() {
        let dir = temp("status");
        let r = relay(&dir, true);
        let s = r.updater.status();
        let keys: Vec<&str> = s.as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(
            keys,
            ["can_update", "checked_at", "last_error", "latest_version", "manifest_expires_at", "min_version", "update_available", "update_required", "updating", "version"]
        );
        assert_eq!((s["version"].as_str(), s["can_update"].as_bool(), s["updating"].as_bool()), (Some(VERSION), Some(false), Some(false)));
        // status.json carries the same fields and the relay's own.
        r.write_status();
        let file: Value = serde_json::from_slice(&std::fs::read(dir.join("status.json")).unwrap()).unwrap();
        assert_eq!(file["helper_version"], VERSION);
        assert_eq!(file["version"], VERSION);
        assert_eq!(file["pid"], std::process::id());
        for key in ["latest_version", "min_version", "update_required", "checked_at", "last_error", "connected", "servers", "dry_run", "can_update"] {
            assert!(file.get(key).is_some(), "{key}");
        }
        assert!(file.get("push_enabled").is_none());
        // The action adds who is asking and what this computer says. Neither probe has
        // anything to ask here: the tests don't run from the Mac app, and a Mac has no lingering.
        let answer = r.act(&server(), "helper_status", &json!({}), &app("a1b2c3d4", Some(ALEX))).await.0.unwrap();
        assert!(answer.get("notices").is_some() && answer.get("linger").is_some());
        assert_eq!(answer["notices"], Value::Null);
        assert_eq!(answer["manifest_expires_at"], Value::Null);
        if cfg!(target_os = "macos") {
            assert_eq!(answer["linger"], Value::Null);
        }
        // status.json has neither: they are read when a phone asks.
        assert!(file.get("notices").is_none() && file.get("linger").is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn facts_about_this_computer_are_reused_for_a_few_seconds() {
        let start = Instant::now();
        let mut cache = FactsCache::default();
        assert_eq!(cache.fresh(start), None);
        let facts = HostFacts { notices: Some("undetermined"), linger: None };
        cache.keep(start, facts.clone());
        assert_eq!(cache.fresh(start + Duration::from_secs(4)), Some(facts));
        assert_eq!(cache.fresh(start + FACTS_TTL), None);
        // An answer of "can't say" is kept as well, so asking again starts nothing either.
        cache.keep(start, HostFacts::default());
        assert_eq!(cache.fresh(start + Duration::from_secs(1)), Some(HostFacts::default()));
        assert_eq!(FACTS_TTL, Duration::from_secs(5));
    }

    #[tokio::test]
    async fn a_setup_code_makes_proofs_and_ends_with_the_sealed_registration() {
        const NONCE: &str = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
        const SETUP_CHALLENGE: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
        const PROOF: &str = "4Cn9RKo/LEB9ftm6bCl+5ddooucq97kzOtl8tIHNkvo=";
        // The seal the code makes for `register_args()`.
        const SEAL: &str = "uFBNieeZhse8TXl8fRQiixoD7UCeYMg3k+hrGw9CICM=";
        let dir = temp("setup-proof");
        let code = dir.join("setup_nonce.json");
        // The helper is running before any setup stores a code.
        let r = relay(&dir, true);
        let s = server();
        let phone = Requester { client_id: "client:phone".into(), label: "Alex's iPhone #a1b2c3d4".into(), identity: Some(ALEX.into()) };
        let sam = app("b2c3d4e5", Some(SAM));
        let plain = json!({"challenge": crate::util::base64url(&[5; 32]), "device_id": "a1b2c3d4"});
        let mut with_setup = plain.clone();
        with_setup["setup_challenge"] = json!(SETUP_CHALLENGE);
        let sams = json!({"challenge": crate::util::base64url(&[5; 32]), "device_id": "b2c3d4e5", "setup_challenge": SETUP_CHALLENGE});
        let keys = |v: &Value| v.as_object().unwrap().keys().cloned().collect::<Vec<_>>();

        // No code: the usual answer, without the field.
        let answer = r.act(&s, "helper_identity", &with_setup, &phone).await.0.unwrap();
        assert_eq!(keys(&answer), ["client_id", "public_key", "signature"]);

        capture_log();
        // `install` stores a code while the helper runs; the helper is not restarted.
        crate::setup::store_nonce(&dir, NONCE, now() as i64).unwrap();
        // A call without a setup challenge, a bad one, or one whose own challenge is refused
        // leaves the code as it is.
        assert_eq!(keys(&r.act(&s, "helper_identity", &plain, &phone).await.0.unwrap()), ["client_id", "public_key", "signature"]);
        for bad in [json!("AAAA"), json!(7), json!(format!("{SETUP_CHALLENGE}\nx"))] {
            let mut args = with_setup.clone();
            args["setup_challenge"] = bad;
            assert_eq!(r.act(&s, "helper_identity", &args, &phone).await.0.unwrap_err()["code"], "bad_request");
        }
        let mut refused = with_setup.clone();
        refused["challenge"] = json!("AAAA");
        assert_eq!(r.act(&s, "helper_identity", &refused, &phone).await.0.unwrap_err()["code"], "bad_request");
        // So does a sealed registration by someone no proof went to.
        let sams_phone = json!({"gateway": GATEWAY, "push_secret": NEW_SECRET, "environment": "production", "device_id": "b2c3d4e5",
            "setup_seal": crate::setup::seal(NONCE, NEW_SECRET, "b2c3d4e5").unwrap()});
        r.act(&s, "register_push", &sams_phone, &sam).await.0.unwrap();
        assert!(code.exists());

        // The proof is the contract's vector; the signature is there as always.
        let answer = r.act(&s, "helper_identity", &with_setup, &phone).await.0.unwrap();
        assert_eq!(keys(&answer), ["client_id", "public_key", "setup_proof", "signature"]);
        assert_eq!(answer["setup_proof"], PROOF);
        // The same code answers that identity twice more, then no more.
        assert_eq!(r.act(&s, "helper_identity", &with_setup, &phone).await.0.unwrap()["setup_proof"], PROOF);
        assert_eq!(r.act(&s, "helper_identity", &with_setup, &phone).await.0.unwrap()["setup_proof"], PROOF);
        let fourth = r.act(&s, "helper_identity", &with_setup, &phone).await.0.unwrap();
        assert_eq!(keys(&fourth), ["client_id", "public_key", "signature"]);

        // A registration that is refused ends nothing, with the seal or without.
        let mut sealed = register_args();
        sealed["setup_seal"] = json!(SEAL);
        let mut bad_registration = sealed.clone();
        bad_registration["environment"] = json!("staging");
        assert!(r.act(&s, "register_push", &bad_registration, &phone).await.0.is_err());
        assert!(code.exists());
        // A registration with no seal, or with one the code does not make for it, is a
        // registration like any other: it succeeds with the usual result and the code stays.
        let usual = json!({"registered": true, "devices": 2, "push_enabled": false, "helper_version": VERSION});
        let sams_seal = sams_phone["setup_seal"].clone();
        for seal in [None, Some(json!("")), Some(json!("AAAA")), Some(json!("not base64!")), Some(json!(PROOF)), Some(sams_seal), Some(json!(7))] {
            let mut args = register_args();
            if let Some(seal) = &seal {
                args["setup_seal"] = seal.clone();
            }
            assert_eq!(r.act(&s, "register_push", &args, &phone).await.0.unwrap(), usual, "{seal:?}");
            assert!(code.exists(), "{seal:?}");
        }
        // The code still answers other identities, each up to three times.
        let sams_proof = r.act(&s, "helper_identity", &sams, &sam).await.0.unwrap()["setup_proof"].clone();
        assert!(sams_proof.is_string() && sams_proof != PROOF);
        // The phone that was answered registers with the seal: the setup is complete, the
        // answer is the usual one, and the code is gone.
        assert_eq!(r.act(&s, "register_push", &sealed, &phone).await.0.unwrap(), usual);
        assert!(!code.exists());
        // No more proofs after that, for anyone, and a seal sent again changes nothing.
        for (args, requester) in [(&with_setup, &phone), (&sams, &sam)] {
            let after = r.act(&s, "helper_identity", args, requester).await.0.unwrap();
            assert_eq!(keys(&after), ["client_id", "public_key", "signature"]);
        }
        assert_eq!(r.act(&s, "register_push", &sealed, &phone).await.0.unwrap(), usual);
        assert_eq!(devices(&r).len(), 2);

        // A second setup's code is picked up the same way, by the same running helper.
        crate::setup::store_nonce(&dir, NONCE, now() as i64).unwrap();
        assert_eq!(r.act(&s, "helper_identity", &with_setup, &phone).await.0.unwrap()["setup_proof"], PROOF);

        // A code past its 30 minutes makes no proof and is removed.
        crate::setup::store_nonce(&dir, NONCE, now() as i64 - crate::setup::NONCE_LIFETIME - 1).unwrap();
        let late = r.act(&s, "helper_identity", &with_setup, &phone).await.0.unwrap();
        assert_eq!(keys(&late), ["client_id", "public_key", "signature"]);
        assert!(!code.exists());

        // Neither the code nor a proof is logged or written to status.json.
        r.write_status();
        let status = std::fs::read_to_string(dir.join("status.json")).unwrap();
        let log = captured_log();
        assert!(log.contains("answered the Rex DUO setup"));
        assert!(log.contains("setup that installed this helper is complete"));
        assert_eq!(log.matches("setup that installed this helper is complete").count(), 1);
        let sams_proof = sams_proof.as_str().unwrap();
        for secret in [NONCE, "4Cn9RKo", &sams_proof[..8], SETUP_CHALLENGE, "uFBNiee", "setup_seal"] {
            assert!(!log.contains(secret) && !status.contains(secret), "{secret}");
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_server_the_config_names_is_not_watched_twice() {
        let dir = temp("watch");
        let env = Env { dry_run: true, debug_build: true, keys: Ok(vec![[7u8; 32]]), place: Err("test".into()), service: false, writable: false };
        let named = Endpoint::parse("unix:///run/user/1000/rex-b/server.sock").unwrap();
        let r = Relay::new(
            vec![None, Some(named.clone())],
            DeviceStore::open_dry_run(dir.join("devices.json")),
            Sender::DryRun,
            Updater::with_env(env, false, &dir),
            Options { dry_run: true, label: None, debounce: 30.0, burst: 10.0, per_minute: 10.0, status_path: dir.join("status.json"), gateways: Gateways::default(), key: None, state_dir: dir.clone() },
        );
        assert_eq!(r.servers.len(), 2);
        assert!(r.servers[0].fixed.is_none() && r.servers[1].fixed.as_ref() == Some(&named));
        assert!(r.watched_by_name(&named));
        assert!(r.watched_by_name(&Endpoint::parse("unix:///run/user/1000/rex%2Db/server.sock").unwrap()));
        assert!(!r.watched_by_name(&Endpoint::parse("unix:///run/user/1000/rex/server.sock").unwrap()));
        std::fs::remove_dir_all(dir).unwrap();
    }

    fn message(text: &str) -> PushMessage {
        let mut i = PushIntent::new(PushCategory::Notice, BlockRef { server: "s".into(), session_id: "session:1".into(), block_id: "block:1".into() });
        i.headline = Some("Deploy".into());
        i.text = Some(text.into());
        PushMessage::compose(&i, &BlockContext::default())
    }

    fn phone(id: &str, gateway: &str) -> Device {
        Device::new(id, gateway, &format!("{SECRET}{id}"), "sandbox", ALEX)
    }

    const UNAUTHORIZED: &str = r#"{"error":"unauthorized","message":"unknown secret"}"#;

    #[tokio::test]
    async fn the_gateways_answer_decides_what_happens_to_the_registration() {
        let dir = temp("deliver");
        // What the helper logs while it delivers, to check that no secret or message is in it.
        capture_log();
        let (base, seen) = serve(vec![
            canned(200, r#"{"apns_id":"11111111-2222-3333-4444-555555555555"}"#),
            canned(401, UNAUTHORIZED),
            canned(410, r#"{"error":"unregistered","message":"gone","reason":"Unregistered"}"#),
            canned(429, r#"{"error":"rate_limited","message":"slow down"}"#),
            canned(500, "boom"),
        ])
        .await;
        let r = relay_with(&dir, false, Sender::Gateway, &[&base]);
        let ids = ["00000200", "00000401", "00000410", "00000429", "00000500"];
        for id in ids {
            r.store.lock().unwrap().register(phone(id, &base));
        }
        r.deliver(&message("A very private message"), devices(&r), &[], &HashSet::new(), 1000.0).await;

        // One request per phone, each with that phone's secret: nothing was sent twice.
        let seen = seen.lock().unwrap().clone();
        assert_eq!(seen.len(), 5);
        for (q, id) in seen.iter().zip(ids) {
            assert_eq!(q.path, "/v1/push");
            assert_eq!(q.header("authorization"), Some(format!("Bearer {SECRET}{id}").as_str()));
        }
        // Only 410 unregisters the phone at once. One 401 is a warning; 200, 429 and 500
        // leave it alone.
        let left: Vec<String> = devices(&r).iter().map(|d| d.device_id.clone()).collect();
        assert_eq!(left, ["00000200", "00000401", "00000429", "00000500"]);
        let reopened = DeviceStore::open(dir.join("devices.json"));
        assert_eq!(reopened.devices.len(), 4);
        // The secret Apple's answer killed is remembered; the one refused once is not yet.
        assert!(reopened.is_dropped(&format!("{SECRET}00000410")));
        assert!(!reopened.is_dropped(&format!("{SECRET}00000401")));

        let text = captured_log();
        for line in ["sent to #00000200 (apns-id 11111111-2222-3333-4444-555555555555)", "refused #00000401's secret; this push is dropped", "no longer has #00000410 (Unregistered)", "push to #00000429 dropped", "push to #00000500 dropped"] {
            assert!(text.contains(line), "missing {line:?} in {text}");
        }
        assert!(!text.contains(SECRET), "a secret was logged");
        assert!(!text.contains("A very private message"), "the message was logged");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_secret_is_given_up_on_the_second_401_a_minute_after_the_first() {
        let dir = temp("strikes");
        let (base, seen) = serve(vec![
            canned(401, UNAUTHORIZED),
            canned(401, UNAUTHORIZED),
            // The gateway takes it again: a fault that passed.
            canned(200, "{}"),
            canned(401, UNAUTHORIZED),
            // Not the gateway's words: a proxy or a sign-in page in between.
            canned(401, "<html>Sign in</html>"),
            canned(401, r#"{"error":"Unauthorized"}"#),
            canned(401, UNAUTHORIZED),
        ])
        .await;
        let r = relay_with(&dir, false, Sender::Gateway, &[&base]);
        r.store.lock().unwrap().register(phone("a1b2c3d4", &base));
        let secret = format!("{SECRET}a1b2c3d4");
        let push = |t: f64| {
            let r = r.clone();
            async move { r.deliver(&message("Hello"), devices(&r), &[], &HashSet::new(), t).await }
        };
        let registered = || devices(&r).len() == 1;

        push(1000.0).await;
        assert!(registered(), "the first 401 keeps the registration");
        push(1030.0).await;
        assert!(registered(), "a second within the minute too");
        push(1070.0).await;
        assert!(registered());
        // The 200 in between cleared the count, so this 401 is a first one again.
        push(1100.0).await;
        assert!(registered());
        // 401s that are not the gateway's own never count, however far apart.
        push(1200.0).await;
        push(1300.0).await;
        assert!(registered());
        assert!(!r.store.lock().unwrap().is_dropped(&secret));
        // The gateway's own 401 again, well over a minute after the one at 1100: gone.
        push(1400.0).await;
        assert!(!registered());
        assert!(r.store.lock().unwrap().is_dropped(&secret));
        assert_eq!(seen.lock().unwrap().len(), 7, "one request per push, no retry");
        // The phone is told the next time it speaks, and its old secret is not taken back.
        let s = server();
        let alex = app("a1b2c3d4", Some(ALEX));
        assert_eq!(r.act(&s, "push_presence", &json!({"active": true}), &alex).await.0.unwrap(), json!({"registered": false}));
        assert_eq!(r.act(&s, "helper_status", &json!({}), &alex).await.0.unwrap()["registered"], false);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_dropped_secret_cannot_be_registered_again_but_a_new_one_can() {
        let dir = temp("dropped");
        let (base, _) = serve(vec![canned(410, r#"{"error":"unregistered","reason":"BadDeviceToken"}"#)]).await;
        // A dry-run relay, so `register` posts no desktop notice, with a sender that does send.
        let r = relay_with(&dir, true, Sender::Gateway, &[&base]);
        let mut args = register_args();
        args["gateway"] = json!(base);
        register(&r, &args, ALEX).unwrap();
        r.deliver(&message("Hello"), devices(&r), &[], &HashSet::new(), 1000.0).await;
        assert!(devices(&r).is_empty());

        let e = register(&r, &args, ALEX).unwrap_err();
        assert_eq!(e["code"], "secret_dropped");
        assert!(devices(&r).is_empty());
        // Also after a restart, and whoever asks.
        drop(r);
        let r = relay_with(&dir, true, Sender::Gateway, &[&base]);
        assert_eq!(register(&r, &args, ALEX).unwrap_err()["code"], "secret_dropped");
        assert_eq!(register(&r, &args, SAM).unwrap_err()["code"], "secret_dropped");
        // The phone mints a new secret and is back.
        args["push_secret"] = json!(NEW_SECRET);
        assert_eq!(register(&r, &args, ALEX).unwrap()["registered"], true);
        assert_eq!(devices(&r).len(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn an_open_app_gets_no_request_and_a_dry_run_sends_nothing() {
        let dir = temp("skip");
        let (base, seen) = serve(vec![canned(200, "{}")]).await;
        let r = relay_with(&dir, false, Sender::Gateway, &[&base]);
        r.store.lock().unwrap().register(phone("a1b2c3d4", &base));
        let open = ClientSnapshot {
            client_id: "client:1".into(),
            kind: Some("app".into()),
            platform: Some("ios".into()),
            label: Some("iPhone #a1b2c3d4".into()),
            connection_state: Some("connected".into()),
            ..Default::default()
        };
        r.deliver(&message("Hello"), devices(&r), &[open], &HashSet::new(), 1000.0).await;
        let dry_dir = temp("skipdry");
        relay(&dry_dir, true).deliver(&message("Hello"), devices(&r), &[], &HashSet::new(), 1000.0).await;
        assert!(seen.lock().unwrap().is_empty());
        std::fs::remove_dir_all(dir).unwrap();
        std::fs::remove_dir_all(dry_dir).unwrap();
    }

    #[tokio::test]
    async fn a_phone_that_registered_again_meanwhile_is_kept() {
        let dir = temp("rereg");
        let (base, _) = serve(vec![canned(410, r#"{"error":"unregistered"}"#)]).await;
        let r = relay_with(&dir, false, Sender::Gateway, &[&base]);
        let old = phone("a1b2c3d4", &base);
        // The store already holds the phone's new secret when the old one is refused.
        r.store.lock().unwrap().register(Device::new("a1b2c3d4", &base, NEW_SECRET, "sandbox", ALEX));
        r.deliver(&message("Hello"), vec![old.clone()], &[], &HashSet::new(), 1000.0).await;
        assert_eq!(devices(&r).len(), 1);
        assert_eq!(devices(&r)[0].push_secret, NEW_SECRET);
        assert!(r.store.lock().unwrap().is_dropped(&old.push_secret));
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// Every run of `n` characters of `secret`.
    fn pieces(secret: &str, n: usize) -> Vec<&str> {
        (0..=secret.len() - n).map(|i| &secret[i..i + n]).collect()
    }

    /// No reply and no log line may carry a push secret, or enough of one to help guess it.
    /// The check does not know how long a secret is: it looks for every 12 characters of it.
    #[tokio::test]
    async fn no_reply_and_no_log_line_carries_any_part_of_a_secret() {
        // No character repeats within 12, so every piece is its own string.
        let first = "Zx9Qm2Lk7Vb4Nc1Jh8Gf5Ds3Ap6Yt0WeRuIoPlMnBvC";
        let second = "q7W-e2R_t5Y8u1I4o0P3a6S9d2F5g8H1j4K7l0ZxCvB";
        let dir = temp("leak");
        capture_log();
        // A gateway that echoes the secret in every field it can, as a hostile or broken one might.
        let echo = |status: u16, error: &str, secret: &str| canned(status, &format!(r#"{{"error":"{error}","message":"{secret}","reason":"{secret}","apns_id":"{secret}"}}"#));
        let (base, seen) = serve(vec![
            echo(200, "ok", first),
            echo(500, first, first),
            echo(401, "unauthorized", first),
            echo(401, "unauthorized", first),
            echo(410, "unregistered", second),
        ])
        .await;
        let r = relay_with(&dir, true, Sender::Gateway, &[&base]);
        let s = server();
        let (alex, sam) = (app("a1b2c3d4", Some(ALEX)), app("a1b2c3d4", Some(SAM)));
        let mut replies: Vec<String> = vec![];
        let mut ask = |outcome: Result<Value, Value>| replies.push(match outcome {
            Ok(v) => v.to_string(),
            Err(v) => v.to_string(),
        });
        let registration = |secret: &str| json!({"gateway": base, "push_secret": secret, "environment": "sandbox", "device_name": "Alex's iPhone", "device_id": "a1b2c3d4"});
        let challenge = json!({"challenge": crate::util::base64url(&[9u8; 32]), "device_id": "a1b2c3d4"});

        // Everything a client can ask, by the owner, by someone else and by nobody, with the
        // secret in play, and with it where it doesn't belong.
        ask(r.act(&s, "register_push", &registration(first), &alex).await.0);
        ask(r.act(&s, "register_push", &registration(first), &sam).await.0);
        ask(r.act(&s, "register_push", &registration(first), &app("a1b2c3d4", None)).await.0);
        ask(r.act(&s, "register_push", &registration(&format!("{first} oops")), &alex).await.0);
        ask(r.act(&s, "register_push", &json!({"gateway": format!("https://{first}.example.com"), "push_secret": first, "environment": "sandbox", "device_id": "a1b2c3d4"}), &alex).await.0);
        ask(r.act(&s, "register_push", &json!({"gateway": base, "push_secret": first, "environment": first, "device_id": first}), &alex).await.0);
        for who in [&alex, &sam] {
            ask(r.act(&s, "helper_identity", &challenge, who).await.0);
            ask(r.act(&s, "helper_identity", &json!({"challenge": first, "device_id": first}), who).await.0);
            ask(r.act(&s, "helper_status", &json!({}), who).await.0);
            ask(r.act(&s, "push_presence", &json!({"active": false}), who).await.0);
            ask(r.act(&s, "update_helper", &json!({}), who).await.0);
            ask(r.act(&s, first, &json!({}), who).await.0);
        }
        ask(r.act(&s, "unregister_push", &json!({"device_id": first}), &alex).await.0);
        ask(r.act(&s, "unregister_push", &json!({"device_id": "a1b2c3d4"}), &sam).await.0);

        // Pushes: sent, failed, refused once, refused for good.
        for t in [1000.0, 1010.0, 1020.0, 1100.0] {
            r.deliver(&message("Hello"), devices(&r), &[], &HashSet::new(), t).await;
        }
        assert!(devices(&r).is_empty(), "the second 401 dropped it");
        ask(r.act(&s, "register_push", &registration(first), &alex).await.0);
        ask(r.act(&s, "push_presence", &json!({"active": true}), &alex).await.0);
        // A new secret, which Apple's answer then kills.
        ask(r.act(&s, "register_push", &registration(second), &alex).await.0);
        r.deliver(&message("Hello"), devices(&r), &[], &HashSet::new(), 1200.0).await;
        ask(r.act(&s, "register_push", &registration(second), &alex).await.0);
        ask(r.act(&s, "helper_status", &json!({}), &alex).await.0);
        ask(r.act(&s, "unregister_push", &json!({"device_id": "a1b2c3d4"}), &alex).await.0);
        r.write_status();

        // The test did what it meant to: the secrets went to the gateway and nowhere else.
        assert_eq!(seen.lock().unwrap().len(), 5);
        assert_eq!(seen.lock().unwrap()[0].header("authorization"), Some(format!("Bearer {first}").as_str()));
        let codes: Vec<String> = replies.iter().filter_map(|r| serde_json::from_str::<Value>(r).ok()?.str("code").map(String::from)).collect();
        for code in ["not_your_device", "refused", "bad_request", "secret_dropped", "update_failed", "not_supported"] {
            assert!(codes.iter().any(|c| c == code), "no reply with {code}: {codes:?}");
        }
        let log = captured_log();
        for line in ["registered Alex's iPhone", "push to Alex's iPhone dropped", "secret; this push is dropped", "secret again; unregistering", "no longer has Alex's iPhone"] {
            assert!(log.contains(line), "missing {line:?} in the log");
        }

        // Everything the helper said, and every file it wrote except the one that is the
        // secrets' home.
        let mut said = replies;
        said.push(log);
        said.push(format!("{:?}", Device::new("a1b2c3d4", &base, first, "sandbox", ALEX)));
        for name in ["status.json", "dropped_secrets.json", "seen_devices.json"] {
            said.push(std::fs::read_to_string(dir.join(name)).unwrap_or_else(|e| panic!("{name}: {e}")));
        }
        for secret in [first, second] {
            for piece in pieces(secret, 12) {
                for text in &said {
                    assert!(!text.contains(piece), "{piece:?} of a secret is in: {text}");
                }
            }
        }
        std::fs::remove_dir_all(dir).unwrap();
    }
}
