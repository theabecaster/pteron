//! The relay: watches the Rex server (found automatically, or the ones in the config), turns
//! agent and notification events into pushes, and serves the client actions the iOS app calls:
//! `helper_identity`, `register_push`, `unregister_push`, `push_presence`, `set_push_paused`,
//! `helper_status`, `update_helper`, `send_test`, `port_share`, `port_owner`.
//!
//! Any client of the Rex server can call these actions, so each one first asks who the server
//! says the caller is (`auth::Requester`) and what that identity may do.

use crate::auth::{is_device_id, Gateways, Requester};
use crate::brand::{APP, BEACON};
use crate::desk::{is_local_desktop_app, Desk, Edge, Moment, NOTICE_MEMORY, NOTICE_WAIT, POLL, SLEEP_GRACE};
use crate::devices::{is_app_claimed, secret_hash, ClientSnapshot, Device, DeviceStore, Strikes};
use crate::discovery::{self, Endpoint};
use crate::gateway::{describe, SendResult, Sender};
use crate::hold::{Holds, Parked, SendKind, Verdict};
use crate::identity::HelperKey;
use crate::idle::{Power, Sense};
use crate::notice;
use crate::policy::{BlockRef, Decision, PushCategory, PushIntent, PushPolicy, RateLimiter, RelayEvent, StatusReport};
use crate::presence::{hold_tags, shows_desk, LeaseAnswer, Leases, PresenceKey};
use crate::push::{BlockContext, PushMessage};
use crate::rex::{self, Conn, Identity};
use crate::share::{self, Refusal, Shares};
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
pub const NEEDS_NEWER_APP: &str = concat!("This ", crate::beacon_name!(), " needs a newer ", crate::app_name!(), " app.");

/// The least time between two updates asked for through `update_helper`, whoever asks. Each
/// one makes the helper download from GitHub, so a client must not be able to make it do that
/// in a loop. The helper's own timer does not count.
pub const UPDATE_COOLDOWN: Duration = Duration::from_secs(600);

/// The least time between two test notifications to one phone (`send_test`).
pub const TEST_INTERVAL: Duration = Duration::from_secs(10);

/// The seconds until `update_helper` may be used again, or None when it may be used now.
fn cooldown_left(last: Option<Instant>, now: Instant) -> Option<u64> {
    let since = now.saturating_duration_since(last?);
    (since < UPDATE_COOLDOWN).then(|| (UPDATE_COOLDOWN - since).as_secs().max(1))
}

/// The actions the helper answers. Only one of these names is repeated in a log line.
const KNOWN_ACTIONS: [&str; 10] =
    ["register_push", "unregister_push", "push_presence", "set_push_paused", "helper_identity", "helper_status", "update_helper", "send_test", "port_share", "port_owner"];

fn error(code: &str, message: &str) -> Value {
    json!({"code": code, "message": message})
}

/// The answer to a request whose change could not be written to devices.json. Nothing changed.
fn not_saved() -> Value {
    error("not_saved", concat!(crate::beacon_name!(), " couldn't save that. Try again."))
}

/// Actions the relay offers to other Rex clients (declared with `client.keymap`).
/// The server checks `client.perform` args against these schemas. Nothing is `required` in
/// them and the old `token` stays listed, so a call from an app that predates the push gateway
/// still reaches the helper, which answers it in words that app can show.
pub fn actions() -> Value {
    json!([
        {
            "name": "register_push", "kind": "client", "category": BEACON,
            "title": concat!("Register for ", crate::app_name!(), " Pushes"),
            "description": "Send push notifications for this server's agents to an iPhone.",
            "args": {
                "type": "object",
                "properties": {
                    "gateway": {"type": "string", "description": "Base URL of the push gateway the phone registered with."},
                    "push_secret": {"type": "string", "description": "The secret the gateway gave the phone for pushes to it."},
                    "environment": {"type": "string", "enum": ["sandbox", "production"]},
                    "device_name": {"type": "string"},
                    "device_id": {"type": "string", "description": "Short id the app also puts in its client label as \"#<id>\"."},
                    "paused": {"type": "boolean", "description": "Pause (true) or resume (false) notifications to this phone with this registration. Left out, a registration with the secret the helper already holds keeps its value and any other starts resumed."},
                    "setup_seal": {"type": "string", "description": concat!("From the ", crate::app_name!(), " setup that installed this helper: base64 of 32 bytes, made from its setup code for this registration.")},
                    "token": {"type": "string", "description": "No longer used."}
                }
            }
        },
        {
            "name": "helper_identity", "kind": "client", "category": BEACON,
            "title": concat!(crate::beacon_name!(), " Identity"),
            "description": "Prove which helper this is: its public key, and a signature over the caller's challenge.",
            "args": {"type": "object", "properties": {
                "challenge": {"type": "string", "description": "32 random bytes, base64url."},
                "device_id": {"type": "string"},
                "setup_challenge": {"type": "string", "description": concat!("32 random bytes, base64url, from the ", crate::app_name!(), " setup that installed this helper.")}
            }}
        },
        {
            "name": "unregister_push", "kind": "client", "category": BEACON,
            "title": concat!("Unregister from ", crate::app_name!(), " Pushes"),
            "description": "Stop sending pushes to an iPhone.",
            "args": {"type": "object", "properties": {
                "device_id": {"type": "string"},
                "token": {"type": "string", "description": "No longer used."}
            }}
        },
        {
            "name": "push_presence", "kind": "client", "category": BEACON,
            "title": concat!(crate::app_name!(), " Presence"),
            "description": concat!("Tell the relay whether the calling ", crate::app_name!(), " app is in the foreground."),
            "args": {"type": "object", "properties": {"active": {"type": "boolean"}}, "required": ["active"]}
        },
        {
            "name": "set_push_paused", "kind": "client", "category": BEACON,
            "title": "Pause or Resume Notifications",
            "description": "Pause or resume notifications from this computer to the calling iPhone. Its registration stays as it is.",
            "args": {"type": "object", "properties": {"paused": {"type": "boolean"}}, "required": ["paused"]}
        },
        {
            "name": "helper_status", "kind": "client", "category": BEACON,
            "title": concat!(crate::beacon_name!(), " Status"),
            "description": "The helper's version, whether a newer one is available, and what this computer still asks of its user.",
            "args": {"type": "object", "properties": {}}
        },
        {
            "name": "update_helper", "kind": "client", "category": BEACON,
            "title": concat!("Update ", crate::beacon_name!()),
            "description": "Look for a newer helper now and install it.",
            "args": {"type": "object", "properties": {}}
        },
        {
            "name": "send_test", "kind": "client", "category": BEACON,
            "title": "Send a Test Notification",
            "description": "Send one notification to the calling iPhone, to show that notifications from this computer arrive.",
            "args": {"type": "object", "properties": {}}
        },
        {
            "name": "port_share", "kind": "client", "category": BEACON,
            "title": "Open a Port in the Phone's Browser",
            "description": "Let the calling iPhone's browsers reach a web server that listens on this computer, over Tailscale, for as long as it is used.",
            "args": {"type": "object", "properties": {
                "block": {"type": "string", "description": "The pane the server runs in."},
                "port": {"type": "integer", "description": "The port the server listens on, on this computer."},
                "phone_ip": {"type": "string", "description": "The calling iPhone's own Tailscale address: the only one that may connect."}
            }}
        },
        {
            "name": "port_owner", "kind": "client", "category": BEACON,
            "title": "Who Holds a Port",
            "description": "The process that listens on a port of this computer: its process group, the group in the foreground of its terminal, and the processes that started it.",
            "args": {"type": "object", "properties": {
                "pid": {"type": "integer", "description": "The process that listens, as Rex names it for the port."},
                "port": {"type": "integer", "description": "The port, when the process is not known."}
            }}
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
    /// App clients that said they are in front (`push_presence {active: true}`), and when.
    /// The phone app counts as open only while its claim is live (`devices::is_app_claimed`).
    claims: HashMap<String, Moment>,
    /// "<session>|<block>" -> when the pane last lost an OSC 7501 record (`desk::mono`), kept
    /// `desk::NOTICE_MEMORY`: its desktop notifications still count as a status pane's.
    status_removed_at: HashMap<String, f64>,
}

pub struct Server {
    conn: Conn,
    /// From the config or `--server`; None means discover the local server each attempt.
    fixed: Option<Endpoint>,
    st: Mutex<ServerState>,
}

impl Server {
    /// Names this connection among the relay's, for what belongs to one server (port shares).
    fn key(&self) -> String {
        format!("{:p}", self as *const Server)
    }

    fn host(&self) -> String {
        let h = self.st.lock().unwrap().host.clone();
        if h.is_empty() { "rex".into() } else { h }
    }
}

pub struct Options {
    pub dry_run: bool,
    pub label: Option<String>,
    /// The client name to connect under instead of `rex-push-relay` (a dry run only).
    pub name: Option<String>,
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
    /// This computer's system as `helper_status` names it (`host::os`), read once at start.
    pub os: String,
    /// Idle time, lock, display and processes, for desk presence (`idle::System`).
    pub sense: Arc<dyn Sense>,
    /// Away after this long without input (`desk::AWAY_AFTER`; shorter in a dry run, to try it).
    pub away_after: f64,
    /// `--session` (a dry run only): attach to these sessions alone, so a test run sees no
    /// other session's events. Empty: every session, as the helper always does.
    pub sessions: Vec<String>,
    /// `--hold-cap` (a dry run only): hold a question this long at most instead of
    /// `desk::HOLD_CAP`.
    pub hold_cap: Option<f64>,
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
    /// Per device id: who owned the registration, and the unix time, when the gateway last
    /// accepted a notification for that phone. Since this helper started; not stored.
    last_push: Mutex<HashMap<String, (String, i64)>>,
    /// Per device id, when `send_test` last sent to that phone, kept for `TEST_INTERVAL`.
    tests: Mutex<HashMap<String, Instant>>,
    os: String,
    state_dir: PathBuf,
    dry_run: bool,
    identity: Identity,
    due_task: Mutex<Option<JoinHandle<()>>>,
    status_path: PathBuf,
    stopping: AtomicBool,
    /// The ports a phone's browsers reach over the tailnet (share.rs).
    shares: Arc<Shares>,
    /// Desk presence (desk.rs, hold.rs, presence.rs).
    desk: Mutex<Desk>,
    holds: Mutex<Holds>,
    /// This computer's desk leases at each phone's gateway.
    leases: Mutex<Leases>,
    /// The look for leases runs (`lease_watch`).
    lease_running: AtomicBool,
    sessions: Vec<String>,
    sense: Arc<dyn Sense>,
    away_after: f64,
    /// The look at the desk every `hold_poll` (`POLL`) runs, while a question is held.
    hold_running: Mutex<bool>,
    hold_poll: Mutex<Duration>,
    /// Sleep and wake are watched, from the start.
    power_watched: AtomicBool,
    /// Whether a desk shows a server, as a test has it (no Rex to ask).
    #[cfg(test)]
    shown_in_test: Mutex<Option<bool>>,
    /// The labels of the desktop apps that run here, as a test has them (no Rex to ask).
    #[cfg(test)]
    labels_in_test: Mutex<Option<Vec<String>>>,
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
        if let Some(n) = o.name.filter(|n| !n.is_empty()) {
            identity.name = n;
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
            last_push: Mutex::new(HashMap::new()),
            tests: Mutex::new(HashMap::new()),
            os: o.os,
            state_dir: o.state_dir.clone(),
            dry_run: o.dry_run,
            identity,
            due_task: Mutex::new(None),
            status_path: o.status_path,
            stopping: AtomicBool::new(false),
            #[cfg(not(test))]
            shares: Shares::new(share::Net::tailnet()),
            // No test asks the real Tailscale client: loopback stands in for the tailnet.
            #[cfg(test)]
            shares: Shares::new(share::Net::testing()),
            desk: Mutex::new(Desk::default()),
            // A dry run holds in memory only, so it never touches what the real helper holds.
            holds: Mutex::new({
                let mut h = Holds::load((!o.dry_run).then_some(o.state_dir.as_path()));
                if let Some(cap) = o.hold_cap {
                    h.set_cap(cap);
                }
                h
            }),
            leases: Mutex::new(Leases::default()),
            lease_running: AtomicBool::new(false),
            sessions: o.sessions,
            sense: o.sense,
            away_after: o.away_after,
            hold_running: Mutex::new(false),
            hold_poll: Mutex::new(POLL),
            power_watched: AtomicBool::new(false),
            #[cfg(test)]
            shown_in_test: Mutex::new(None),
            #[cfg(test)]
            labels_in_test: Mutex::new(None),
        })
    }

    /// The registrations, as devices.json has them now (`rex-duo-helper forget` may have
    /// changed the file).
    fn store(&self) -> MutexGuard<'_, DeviceStore> {
        let mut store = self.store.lock().unwrap();
        // A phone that left the file since has no share any more.
        if store.sync() {
            self.shares.keep_devices(|id| store.get(id).is_some());
        }
        store
    }

    /// From now on a share asks, before it takes a connection, whether its phone is still
    /// registered, so one that `forget` removed is not served even when nothing else has
    /// made Beacon read the file again. Weak, so the two don't keep each other alive.
    fn watch_shares(self: &Arc<Self>) {
        let relay = Arc::downgrade(self);
        self.shares.watch_registrations(move |id| relay.upgrade().is_none_or(|r| r.store().get(id).is_some()));
    }

    pub fn start(self: &Arc<Self>) {
        let n = self.store().devices.len();
        let mode = if self.dry_run { "dry run, no pushes are sent" } else { "pushes go through the gateway" };
        info!("{BEACON} {VERSION} starting; {n} registered device(s); {mode}");
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
        self.watch_shares();
        self.watch_power();
        self.watch_restored();
        self.lease_watch();
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
        // A Beacon that stops shares nothing.
        self.shares.close_all();
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
        // `updating`, `can_update`, `last_error`, `failing_since`), then the relay's own.
        let mut v = self.updater.status();
        v["pid"] = json!(std::process::id());
        v["helper_version"] = json!(VERSION);
        v["connected"] = json!(!ready.is_empty());
        v["servers"] = json!(ready);
        v["dry_run"] = json!(self.dry_run);
        let exe = std::env::current_exe().ok();
        v["exe"] = json!(exe.as_ref().map(|p| p.to_string_lossy()));
        v["exe_mtime"] = json!(exe.map(|p| crate::service::mtime(&p)).unwrap_or(0));
        // The launchd job this helper runs as (src/label.rs).
        #[cfg(target_os = "macos")]
        {
            v["label"] = json!(crate::service::own_label());
        }
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
                                        relay.recheck_held(&srv).await;
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
        let boot = if self.sessions.is_empty() {
            s.conn.call("session.bootstrap", json!({"event_scope": "all", "attach_session_ids": []})).await?
        } else {
            // `--session` (a dry run only): these sessions alone. No `attach_all`, so no other
            // session's events reach this run.
            for id in &self.sessions {
                s.conn.call("session.attach", json!({"session_id": id})).await?;
            }
            let status = s.conn.call("server.status", json!({})).await.unwrap_or(Value::Null);
            let sessions: Vec<Value> = self.sessions.iter().map(|id| json!({"session_id": id})).collect();
            json!({"server_status": status, "attach_all": {"sessions": sessions}})
        };
        // Payloads name the server by its Tailscale URL, which is how the phone app knows it.
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
        st.claims.retain(|c, _| live.contains(c));
        info!("[{}] watching {} session(s) as {}; offering its actions to {APP}", st.host, st.sessions.len(), st.name);
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
                    let prefix = format!("{id}|");
                    st.status_removed_at.retain(|k, _| !k.starts_with(&prefix));
                }
            }
            Some("client_left") => {
                if let Some(id) = p.str("client_id") {
                    let mut st = s.st.lock().unwrap();
                    st.backgrounded.remove(id);
                    st.claims.remove(id);
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
                    s.st.lock().unwrap().status_removed_at.remove(&format!("{sid}|{b}"));
                    self.shares.block_closed(&s.key(), b);
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
                        {
                            // Any record, the installer's too: an agent's pane stays one for a while.
                            let mut st = s.st.lock().unwrap();
                            let now = crate::desk::mono();
                            st.status_removed_at.retain(|_, at| now - *at < NOTICE_MEMORY);
                            st.status_removed_at.insert(format!("{sid}|{b}"), now);
                        }
                        self.decide(RelayEvent::StatusRemoved(r, ids));
                    }
                    "desktop_notification" => {
                        let body = e.str("body").unwrap_or("").to_string();
                        let title = e.text("title");
                        info!("[{}] notification {}: {} {body}", s.host(), short(b), title.as_deref().unwrap_or(""));
                        self.decide(RelayEvent::Notification(r, title, body));
                    }
                    // The pane's whole list of ports: a shared one that left it waits, and
                    // one that is back is piped again.
                    "ports_changed" => self.shares.ports_changed(&s.key(), b, &e),
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
        self.unhold(&e);
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
        // With every registered phone paused there is nobody to compose a notification for.
        if self.all_paused() {
            debug!("no push: notifications are paused on every registered phone");
            return;
        }
        if intent.category == PushCategory::Notice && !self.notice_worth_a_push(&s, &intent).await {
            return;
        }
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
        let clients = self.presence_snapshot().await;
        // The app clients of the agent's own server: whether someone is at this computer's desk
        // that shows it, and which desks elsewhere do (`hold_if_desk`).
        let on_server = app_clients(&s).await.unwrap_or_default();
        let here = self.desk_here(&on_server);
        self.deliver(&intent, &msg, devices, &clients, &on_server, here, Moment::now()).await;
    }

    /// True when phones are registered and each of them is paused.
    fn all_paused(&self) -> bool {
        let store = self.store();
        !store.devices.is_empty() && store.devices.iter().all(|d| d.paused)
    }

    /// What the gateway's answer to one notification, at time `t`, means for the phone it
    /// was for: an accepted one is remembered for `last_push_at`, and a phone the gateway
    /// has dropped (`410`), or whose secret it refused twice a minute apart (`401`), is
    /// unregistered and its secret remembered as refused. The phone learns of it from
    /// `registered: false` in its next `push_presence` or `helper_status`, and registers again.
    /// A push the gateway held is neither: nothing reached the phone (`send_one`).
    fn settle(&self, d: &Device, result: &SendResult, t: f64) {
        let who = d.who();
        let hash = secret_hash(&d.push_secret);
        match result {
            SendResult::Sent(id) => {
                self.strikes.lock().unwrap().clear(&hash);
                // A dry run's sender asks no gateway, so there is nothing to remember.
                if self.sender.asks() {
                    self.last_push.lock().unwrap().insert(d.device_id.clone(), (d.owner.clone(), t as i64));
                }
                if !self.dry_run {
                    info!("sent to {who}{}", id.as_ref().map(|i| format!(" (apns-id {i})")).unwrap_or_default());
                }
            }
            SendResult::Gone(why) => {
                info!("the gateway no longer has {who} ({why}); unregistering it until the phone registers again");
                self.strikes.lock().unwrap().clear(&hash);
                self.store().drop_secret(&d.device_id, &d.push_secret);
                self.shares.device_gone(&d.device_id);
            }
            SendResult::Unauthorized => {
                if self.strikes.lock().unwrap().refused(&hash, t) {
                    info!("the gateway refused {who}'s secret again; unregistering it until the phone registers again");
                    self.store().drop_secret(&d.device_id, &d.push_secret);
                    self.shares.device_gone(&d.device_id);
                } else {
                    info!("the gateway refused {who}'s secret; this push is dropped, the registration stays unless it happens again in a minute or more");
                }
            }
            SendResult::Held(_) => {}
            SendResult::Limited(why) | SendResult::Failed(why) => info!("push to {who} dropped: {why}"),
        }
    }

    /// Asks every connected server who's connected right now. Pushes are rare, so this stays exact.
    async fn presence_snapshot(&self) -> Vec<ClientSnapshot> {
        let mut clients = vec![];
        for s in &self.servers {
            if !s.conn.is_connected() {
                continue;
            }
            if let Ok(c) = app_clients(s).await {
                clients.extend(c);
            }
        }
        clients
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
            let known = KNOWN_ACTIONS.contains(&action);
            info!("refused {} from {who}: the Rex server did not identify it", if known { action } else { "an unknown action" });
            return (Err(error("refused", concat!(crate::beacon_name!(), " only answers clients the Rex server has identified."))), None);
        };
        let mut after = None;
        let outcome = match action {
            "register_push" => self.register(args, requester, identity).inspect(|_| {
                // A registration that carries the setup's seal is the one the setup was for:
                // its code has done its work. Any other registration is only a registration.
                let (secret, device_id) = (args.str("push_secret").unwrap_or(""), args.str("device_id").unwrap_or(""));
                if crate::setup::registered(&self.state_dir, identity, secret, device_id, args.str("setup_seal"), now() as i64) {
                    info!("the {APP} setup that installed this helper is complete, for {who}");
                }
            }),
            "unregister_push" => self.unregister(args, requester, identity),
            "push_presence" => {
                let background = args.bool("active") == Some(false);
                if !requester.client_id.is_empty() {
                    let mut st = s.st.lock().unwrap();
                    let id = requester.client_id.clone();
                    // The app renews its claim every minute: no news, so only a change is logged.
                    let renewal = !background && !st.backgrounded.contains(&id) && st.claims.contains_key(&id);
                    if background {
                        st.backgrounded.insert(id.clone());
                        st.claims.remove(&id);
                    } else {
                        st.backgrounded.remove(&id);
                        st.claims.insert(id, Moment::now());
                    }
                    let line = format!("presence from {who}: {}", if background { "background" } else { "foreground" });
                    if renewal {
                        debug!("{line}");
                    } else {
                        info!("{line}");
                    }
                }
                Ok(json!({"registered": self.registered(requester, identity)}))
            }
            "set_push_paused" => self.set_paused(args, requester, identity),
            "helper_identity" => self.identify(s, args, requester, identity),
            "helper_status" => {
                // A check the command line ran since the last look is part of the answer.
                self.updater.take_command_result();
                let mut status = self.updater.status();
                let own = self.own_device(requester, identity);
                status["registered"] = json!(own.is_some());
                status["paused"] = json!(own.is_some_and(|d| d.paused));
                let facts = self.host_facts().await;
                status["notices"] = json!(facts.notices);
                status["linger"] = json!(facts.linger);
                status["os"] = json!(self.os);
                let (all, others) = {
                    let store = self.store();
                    (store.devices.len(), store.devices.iter().filter(|d| d.owner != identity).count())
                };
                status["devices"] = json!(all);
                status["other_phones"] = json!(others);
                status["last_push_at"] = json!(self.last_push_at(requester, identity));
                Ok(status)
            }
            "send_test" => self.send_test(s, requester, identity).await,
            "port_share" => self.share_port(s, args, requester, identity).await,
            "port_owner" => self.port_owner(args, requester, identity).await,
            "update_helper" => self.begin_update(&who, identity).await.map(|(result, start)| {
                after = start;
                result
            }),
            _ => Err(error("not_supported", concat!(crate::beacon_name!(), " has no such action."))),
        };
        (outcome, after)
    }

    /// True when the requester's phone (the device id at the end of its label) has a
    /// registration here that the requester's identity made. False tells the app to register
    /// again: this helper never had its secret, or the gateway refused it.
    fn registered(&self, requester: &Requester, identity: &str) -> bool {
        self.own_device(requester, identity).is_some()
    }

    /// The requester's phone, when the requester's identity registered it here.
    fn own_device(&self, requester: &Requester, identity: &str) -> Option<Device> {
        let id = requester.device_id()?;
        self.store().get(id).filter(|d| d.owner == identity).cloned()
    }

    /// `set_push_paused`: pauses or resumes the requester's own phone, for the identity that
    /// registered it, as `push_presence` tells them apart. The registration and its secret
    /// stay; while it is paused the helper sends that phone nothing.
    fn set_paused(&self, args: &Value, requester: &Requester, identity: &str) -> Result<Value, Value> {
        let who = requester.who();
        let Some(paused) = args.bool("paused") else { return Err(error("bad_request", "paused must be true or false")) };
        let known = requester.device_id().map_or(Ok(false), |id| {
            let mut store = self.store();
            if store.get(id).is_some_and(|d| d.owner == identity) { store.set_paused(id, paused) } else { Ok(false) }
        });
        let Ok(known) = known else {
            info!("no pause or resume for {who}: it could not be saved");
            return Err(not_saved());
        };
        if !known {
            info!("no pause or resume for {who}: no phone of theirs is registered here under that id");
            return Err(error("not_registered", "This phone is not set up for notifications from this computer."));
        }
        info!("notifications {} by {who}", if paused { "paused" } else { "resumed" });
        Ok(json!({"paused": paused, "registered": true}))
    }

    /// When the gateway last accepted a notification from this helper for the requester's
    /// phone, in unix seconds. None before the first one since the helper started, and for
    /// a phone that was someone else's then.
    fn last_push_at(&self, requester: &Requester, identity: &str) -> Option<i64> {
        let last = self.last_push.lock().unwrap();
        last.get(requester.device_id()?).filter(|(owner, _)| owner == identity).map(|(_, at)| *at)
    }

    /// Takes the phone's one test of these ten seconds, or says to wait.
    fn take_test_slot(&self, device_id: &str, now: Instant) -> Result<(), Value> {
        let mut tests = self.tests.lock().unwrap();
        tests.retain(|_, at| now.saturating_duration_since(*at) < TEST_INTERVAL);
        if tests.contains_key(device_id) {
            return Err(error("test_too_soon", "A test notification was sent a moment ago. Try again in a few seconds."));
        }
        tests.insert(device_id.to_string(), now);
        Ok(())
    }

    /// `send_test`: one notification to the requester's own phone, through the gateway, now.
    /// Only for the identity that registered that phone, as `push_presence` tells them
    /// apart. Whether the phone app is open on the phone plays no part, and neither does the
    /// allowance of agent pushes: a test has its own, one per phone every `TEST_INTERVAL`,
    /// which an attempt uses up whatever comes of it. A paused phone gets no test: the
    /// answer is `paused`, and neither the gateway nor the phone's test allowance is touched.
    async fn send_test(&self, s: &Server, requester: &Requester, identity: &str) -> Result<Value, Value> {
        let who = requester.who();
        let Some(d) = self.own_device(requester, identity) else {
            info!("no test notification for {who}: no phone of theirs is registered here under that id");
            return Err(error("not_registered", "This phone is not set up for notifications from this computer."));
        };
        if d.paused {
            info!("no test notification for {who}: notifications are paused on that phone");
            return Err(error("paused", "Notifications from this computer are paused on this phone."));
        }
        self.take_test_slot(&d.device_id, Instant::now())?;
        let server = s.st.lock().unwrap().name.clone();
        let msg = PushMessage::test(&server);
        info!("test notification asked for by {who}");
        let result = self.sender.send(&msg, &d).await;
        self.settle(&d, &result, now());
        match result {
            SendResult::Sent(_) => Ok(json!({"sent": true})),
            // The gateway does not know this phone, or not by what this helper holds for it.
            // Either way the phone has to set notifications up again.
            SendResult::Gone(_) | SendResult::Unauthorized => {
                Err(error("phone_gone", "This phone's notification address is no longer valid. Set up notifications on it again."))
            }
            SendResult::Limited(_) => Err(error("limit_reached", "The notification service has sent as many notifications as it allows for now. Try again later.")),
            // A test carries no `hold_if_desk`, so no gateway holds it; one that did reached no phone.
            SendResult::Failed(_) | SendResult::Held(_) => Err(error("no_connection", "The notification service could not be reached.")),
        }
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
        let Some(key) = &self.key else { return Err(error("internal", concat!("This ", crate::beacon_name!(), " has no identity key."))) };
        let Some(own) = s.st.lock().unwrap().client_id.clone() else {
            return Err(error("internal", concat!("This ", crate::beacon_name!(), " does not know its own client id on this server.")));
        };
        let setup_challenge = match args.get("setup_challenge") {
            None | Some(Value::Null) => None,
            Some(c) => Some(c.as_str().filter(|c| crate::identity::is_challenge(c)).ok_or_else(|| error("bad_request", "setup_challenge must be the base64url of 32 bytes"))?),
        };
        let mut answer =
            key.answer(args.str("challenge").unwrap_or(""), &own, &requester.client_id, args.str("device_id").unwrap_or("")).map_err(|m| error("bad_request", m))?;
        if let Some(challenge) = setup_challenge {
            if let Some(proof) = crate::setup::take_proof(&self.state_dir, challenge, &own, &requester.client_id, identity, now() as i64) {
                info!("answered the {APP} setup that installed this helper, for {}", requester.who());
                answer["setup_proof"] = json!(proof);
            }
        }
        Ok(answer)
    }

    /// `register_push`: stores the phone's gateway and secret under its device id, for the
    /// identity that asked. A phone registering the secret the helper already holds for it
    /// stays paused or not as it was; a new secret starts it resumed; `paused` among the args
    /// sets the value either way. A `setup_seal` among the args plays no part here: `act` reads it
    /// once the registration is made.
    fn register(&self, args: &Value, requester: &Requester, identity: &str) -> Result<Value, Value> {
        let who = requester.who();
        let bad = |m: &str| Err(error("bad_request", m));
        let secret = args.str("push_secret").unwrap_or("");
        if secret.is_empty() && args.get("token").is_some() {
            info!("{who} registered the old way (an APNs token); it needs a newer {APP}");
            return Err(error("not_supported", NEEDS_NEWER_APP));
        }
        let env = args.str("environment").unwrap_or("");
        let dev_id = args.str("device_id").unwrap_or("");
        // The helper sends the secret wherever this says, so it must be a gateway the helper
        // already knows, not one the caller picked.
        let Some(gateway) = args.str("gateway").and_then(|g| self.gateways.accept(g)) else {
            info!("refused a registration from {who}: its gateway is not one this helper pushes through");
            return bad(concat!("gateway is not one this ", crate::beacon_name!(), " pushes through (the built-in one, or one listed in its config.json)"));
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
        let paused = match args.get("paused") {
            None | Some(Value::Null) => None,
            Some(Value::Bool(p)) => Some(*p),
            Some(_) => return bad("paused must be true or false"),
        };
        let mut d = Device::new(dev_id, &gateway, secret, env, identity);
        d.device_name = args.text("device_name");
        // Only a phone that confirmed this computer as its owner's own sends one; without it
        // the phone is pushed to as before. One that isn't a key is left out, never logged.
        d.presence_key = match args.str("presence_key") {
            Some(k) if PresenceKey::parse(k).is_some() => Some(k.to_string()),
            Some(_) => {
                info!("the presence key from {who} is not 32 bytes as base64url; that phone gets no desk presence across computers");
                None
            }
            None => None,
        };
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
            d.paused = paused.unwrap_or_else(|| store.get(dev_id).is_some_and(|old| old.paused && old.push_secret == secret));
            let new = store.first_sight(dev_id);
            let Ok(d) = store.register(d) else {
                info!("no registration for {who}: it could not be saved");
                return Err(not_saved());
            };
            (d, store.devices.len(), new)
        };
        self.leases.lock().unwrap().registered(dev_id);
        info!(
            "registered {} [{env}] #{} from {who}{}{}",
            d.device_name.as_deref().unwrap_or("device"),
            d.device_id,
            if d.presence_key.is_some() { ", with desk presence" } else { "" },
            if d.paused { ", paused" } else { "" }
        );
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
    fn unregister(&self, args: &Value, requester: &Requester, identity: &str) -> Result<Value, Value> {
        let removed = args.str("device_id").map_or(Ok(false), |id| {
            let mut store = self.store();
            let Some(secret) = store.get(id).filter(|d| d.owner == identity).map(|d| d.push_secret.clone()) else { return Ok(false) };
            let removed = store.remove(id);
            if removed.is_ok() {
                self.strikes.lock().unwrap().clear(&secret_hash(&secret));
                self.leases.lock().unwrap().forget(id);
                self.shares.device_gone(id);
            }
            removed
        });
        let Ok(removed) = removed else {
            info!("unregister from {}: it could not be saved, so the phone is still registered", requester.who());
            return Err(not_saved());
        };
        info!("unregister from {}: {}", requester.who(), if removed { "removed" } else { "nothing of theirs to remove" });
        Ok(json!({"removed": removed}))
    }

    /// `port_share`: lets the requester's own registered phone reach one port of this
    /// computer's loopback from its browsers, over the tailnet (share.rs). The answer is the
    /// address to open. Asking again for a port that is shared gives the same address.
    async fn share_port(&self, s: &Server, args: &Value, requester: &Requester, identity: &str) -> Result<Value, Value> {
        let who = requester.who();
        let Some(device) = self.own_device(requester, identity) else {
            info!("port_share from {who}: refused, no phone of theirs is registered here under that id");
            return Err(error("not_registered", concat!("Only a phone registered with this ", crate::beacon_name!(), " can open a page this way.")));
        };
        let bad = |m: &str| Err(error("bad_request", m));
        let Some(port) = args.int("port").and_then(|p| u16::try_from(p).ok()).filter(|p| *p > 0) else { return bad("port must be a port number") };
        let Some(phone) = args.str("phone_ip").and_then(|a| a.parse::<std::net::IpAddr>().ok()).map(|ip| ip.to_canonical()) else { return bad("phone_ip must be the phone's Tailscale address") };
        // A pane's name is only held to tell its events from another's.
        let block = args.str("block").unwrap_or("");
        if block.len() > 200 {
            return bad("block must be a pane's id");
        }
        if share::is_refused_port(port) {
            info!("port_share from {who}: refused, port {port} never opens in a browser");
            return Err(error("refused", "That port doesn't open in a browser."));
        }
        let ask = share::Ask { server: s.key(), block: block.into(), port, device: device.device_id.clone(), phone };
        match self.shares.open(ask).await {
            Ok(opened) => Ok(json!({
                "url": opened.url,
                "ip_url": opened.ip_url,
                "port": opened.port,
                "same_port": opened.same_port,
                "idle_seconds": share::IDLE.as_secs(),
                "waiting_seconds": share::WAITING.as_secs(),
            })),
            Err(refusal) => {
                let (code, message) = match refusal {
                    Refusal::NotAvailable => ("not_available", "This computer doesn't run Tailscale, so its pages can't open in the phone's browser."),
                    Refusal::BadPhone => ("bad_request", "phone_ip must be the phone's Tailscale address"),
                    Refusal::NotListening => ("not_listening", "Nothing listens on that port right now."),
                    Refusal::Full => ("busy", "Too many pages are open this way. Close one and try again."),
                    Refusal::NoPort => ("failed", "This computer couldn't listen for the phone."),
                    Refusal::NotYourPhone => ("not_your_phone", "Tailscale doesn't say that this phone is a device of this computer's own user."),
                    Refusal::NotYourPort => ("refused", "That port doesn't open in a browser."),
                };
                info!("port_share from {who}: no share of port {port} ({code})");
                Err(error(code, message))
            }
        }
    }

    /// `port_owner`: the process behind a listening port and what started it (owner.rs), for
    /// someone with a phone registered here. With `pid` it is that process; with `port`
    /// alone, the one the system says listens there. Nothing is ever signalled.
    async fn port_owner(&self, args: &Value, requester: &Requester, identity: &str) -> Result<Value, Value> {
        if self.own_device(requester, identity).is_none() {
            info!("port_owner from {}: refused, no phone of theirs is registered here under that id", requester.who());
            return Err(error("not_registered", concat!("Only a phone registered with this ", crate::beacon_name!(), " can ask that.")));
        }
        // The same answer for a process that is not there and one of another user. Nothing
        // read about a process (its arguments least of all) goes into an error or the log.
        let missing = || error("not_available", "That process can't be read: it has ended, or it is not this user's.");
        let pid = match (args.int("pid"), args.int("port")) {
            (Some(pid), _) => u32::try_from(pid).ok().filter(|p| *p > 1).ok_or_else(|| error("bad_request", "pid must be a process id"))?,
            (None, Some(port)) => {
                let port = u16::try_from(port).ok().filter(|p| *p > 0).ok_or_else(|| error("bad_request", "port must be a port number"))?;
                crate::owner::listener(port).await.ok_or_else(missing)?
            }
            (None, None) => return Err(error("bad_request", "pid or port is needed")),
        };
        crate::owner::owner(pid, crate::platform::user_id(), &|pid| self.sense.process(pid), &|pid| self.sense.invocation(pid)).map(|o| o.json()).ok_or_else(missing)
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
            return Err(error("refused", concat!("Only someone with a phone registered on this ", crate::beacon_name!(), " can update it.")));
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

// MARK: Desk presence (desk.rs, hold.rs, idle.rs, presence.rs)

impl Relay {
    /// Someone is at this computer, as the readings say now. Logs when that changes, without
    /// naming anything.
    fn desk_present(&self) -> bool {
        let reading = self.sense.read();
        let mut desk = self.desk.lock().unwrap();
        match desk.observe(&reading, self.away_after) {
            Some(Edge::Arrived) => info!("desk present"),
            Some(Edge::Left(why)) => info!("desk away ({why})"),
            None => {}
        }
        debug!("desk: {reading:?}");
        desk.present()
    }

    /// Someone is at this computer, at a Rex desktop app among `clients` (the app clients of
    /// one server) that runs here for this user.
    fn desk_here(&self, clients: &[ClientSnapshot]) -> bool {
        let present = self.desk_present();
        let uid = crate::platform::user_id();
        let app_here = clients.iter().any(|c| is_local_desktop_app(c, uid, &|pid| self.sense.process(pid)));
        debug!("desk: a desktop app here shows this server: {app_here}");
        present && app_here
    }

    /// Whether a desk shows server `s` now. A server that can't be asked shows none.
    async fn here(&self, s: &Server) -> bool {
        #[cfg(test)]
        if let Some(shown) = *self.shown_in_test.lock().unwrap() {
            return shown;
        }
        match app_clients(s).await {
            Ok(clients) => self.desk_here(&clients),
            Err(_) => false,
        }
    }

    /// The live in-front claims of every server at dispatch time. A claim of a client the list
    /// shows as lost is removed.
    fn claims(&self, clients: &[ClientSnapshot]) -> HashMap<String, Moment> {
        let lost: HashSet<&str> = clients.iter().filter(|c| c.connection_state.as_deref() == Some("lost")).map(|c| c.client_id.as_str()).collect();
        let mut all = HashMap::new();
        for s in &self.servers {
            let mut st = s.st.lock().unwrap();
            st.claims.retain(|id, _| !lost.contains(id.as_str()));
            all.extend(st.claims.iter().map(|(k, v)| (k.clone(), *v)));
        }
        all
    }

    /// One push to every phone that should get it. A paused phone gets none, and neither does
    /// one whose app is in front (a live claim among `clients`). Each phone's push goes
    /// through the rules of hold.rs (`here`: someone is at this computer's desk, which shows
    /// the event's server); one that is sent and may be held names the desks among
    /// `on_server` (the event server's clients) for the gateway to hold it for.
    #[allow(clippy::too_many_arguments)]
    async fn deliver(self: &Arc<Self>, intent: &PushIntent, msg: &PushMessage, devices: Vec<Device>, clients: &[ClientSnapshot], on_server: &[ClientSnapshot], here: bool, at: Moment) {
        let msg = msg.clone().stacked();
        let claims = self.claims(clients);
        for d in devices {
            let who = d.who();
            if d.paused {
                debug!("skip {who}: paused");
                continue;
            }
            if is_app_claimed(&d, clients, &claims, at) {
                info!("skip {who}: {APP} is open");
                continue;
            }
            let verdict = self.holds.lock().unwrap().decide(&d.device_id, intent, here, at);
            match verdict {
                Verdict::Send(kind, collapse) => {
                    let mut m = msg.clone();
                    if collapse.is_some() {
                        m.collapse_id = collapse;
                    }
                    self.send_one(&d, intent, &m, kind, on_server, at).await;
                }
                Verdict::Park => {
                    info!("holding {} for {who}: at the desk", msg.category.as_str());
                    self.hold_watch();
                }
                Verdict::Updated => info!("holding {} for {who}: new words, the same wait", msg.category.as_str()),
                Verdict::Drop(why) => info!("no {} to {who}: {why}", msg.category.as_str()),
            }
        }
    }

    /// `hold_if_desk` for one phone and a send of `kind`: the desks among `on_server` under the
    /// phone's presence key. None for a send that may not be held, a phone without a key, or a
    /// server no desk shows.
    fn hold_for(d: &Device, kind: SendKind, on_server: &[ClientSnapshot]) -> Option<Vec<String>> {
        if !kind.may_hold() {
            return None;
        }
        let key = PresenceKey::parse(d.presence_key.as_deref()?)?;
        let tags = hold_tags(&key, on_server);
        (!tags.is_empty()).then_some(tags)
    }

    /// One push to one phone at `at`, through the rate limiter. When the gateway takes it, the
    /// phone shows it and a question of that pane is no longer held. When the gateway holds it
    /// for a desk elsewhere (`202`), a question waits (`Holds::park_remote`) and anything else
    /// is dropped, as at a desk here; the rate limit's token is given back, since nothing
    /// reached the phone.
    async fn send_one(self: &Arc<Self>, d: &Device, intent: &PushIntent, m: &PushMessage, kind: SendKind, on_server: &[ClientSnapshot], at: Moment) -> SendResult {
        let who = d.who();
        let t = at.wall;
        if !self.limiter.lock().unwrap().allow(&d.device_id, t) {
            info!("skip {who}: rate limited");
            return SendResult::Limited("rate limited here".into());
        }
        if !kind.may_hold() {
            info!("push {} to {who}: {}", m.category.as_str(), kind.as_str());
        }
        let mut m = m.clone();
        m.hold_if_desk = Self::hold_for(d, kind, on_server);
        let mut result = self.sender.send(&m, d).await;
        self.settle(d, &result, t);
        if let SendResult::Held(_) = result {
            self.limiter.lock().unwrap().refund(&d.device_id);
            if intent.category != PushCategory::Blocked {
                info!("no {} to {who}: at a desk elsewhere", m.category.as_str());
                return result;
            }
            if self.holds.lock().unwrap().park_remote(&d.device_id, intent, at) {
                if kind == SendKind::Probe {
                    debug!("still holding blocked for {who}: at a desk elsewhere");
                } else {
                    info!("holding blocked for {who}: at a desk elsewhere");
                }
                self.hold_watch();
                return result;
            }
            // No more may be held: it goes now, and nowhere may hold it.
            info!("push blocked to {who}: too many questions held");
            m.hold_if_desk = None;
            result = self.sender.send(&m, d).await;
            self.settle(d, &result, t);
        }
        if matches!(result, SendResult::Sent(_)) {
            if kind == SendKind::Probe {
                info!("push blocked to {who}: {}", kind.as_str());
            }
            self.holds.lock().unwrap().sent(&d.device_id, intent, m.collapse_id.as_deref(), t);
        }
        result
    }

    /// Starts the look at the desk every `POLL`, unless it runs. It ends when nothing is held.
    /// Whether it runs is decided under one lock, here and where it ends (`hold_watch_ends`),
    /// so a question held just as the last look found nothing either keeps it going or starts
    /// a new one.
    fn hold_watch(self: &Arc<Self>) {
        {
            let mut running = self.hold_running.lock().unwrap();
            if *running {
                return;
            }
            *running = true;
        }
        let relay = self.clone();
        tokio::spawn(async move {
            loop {
                let poll = *relay.hold_poll.lock().unwrap();
                tokio::time::sleep(poll).await;
                if relay.stopping.load(Ordering::SeqCst) {
                    *relay.hold_running.lock().unwrap() = false;
                    break;
                }
                if !relay.release(None).await && relay.hold_watch_ends() {
                    break;
                }
            }
        });
    }

    /// At start: questions held before a restart (parked.json) are watched from now, whether
    /// or not Rex is back, since the cap needs no server.
    fn watch_restored(self: &Arc<Self>) {
        if !self.holds.lock().unwrap().parked().is_empty() {
            self.hold_watch();
        }
    }

    /// The last look found nothing held: the watch ends, unless a question was held since.
    fn hold_watch_ends(&self) -> bool {
        let mut running = self.hold_running.lock().unwrap();
        if !self.holds.lock().unwrap().parked().is_empty() {
            return false;
        }
        *running = false;
        true
    }

    /// Sends the held questions that are due: with `force`, all of them, for that reason
    /// (sleep); else those held the cap and those whose desk here went away, and then asks the
    /// gateway again about those it holds for a desk elsewhere (`probe_held`). One that could
    /// not be sent stays held and is tried at the next look. Returns whether anything is still
    /// held.
    async fn release(self: &Arc<Self>, force: Option<SendKind>) -> bool {
        {
            // A phone that was unregistered or paused meanwhile is sent nothing.
            let store = self.store();
            self.holds.lock().unwrap().keep_devices(|id| store.get(id).is_some_and(|d| !d.paused));
        }
        let held: Vec<Parked> = self.holds.lock().unwrap().parked().to_vec();
        if held.is_empty() {
            return false;
        }
        let due = match force {
            Some(kind) => held.into_iter().map(|p| (p, kind)).collect(),
            None => {
                let mut away: HashSet<String> = HashSet::new();
                let names: HashSet<String> = held.iter().filter(|p| !p.remote).map(|p| p.intent.block.server.clone()).collect();
                for name in names {
                    let shown = match self.server_named(&name) {
                        Some(s) => self.here(&s).await,
                        None => false,
                    };
                    if !shown {
                        away.insert(name);
                    }
                }
                self.holds.lock().unwrap().due(Moment::now(), |server| away.contains(server))
            }
        };
        let clients = self.presence_snapshot().await;
        self.send_held(due, &clients).await;
        if force.is_none() {
            self.probe_held(&clients).await;
        }
        !self.holds.lock().unwrap().parked().is_empty()
    }

    /// Sends held questions, each composed afresh with its pane's names, so that nowhere may
    /// hold them. A phone whose app is in front now (a live claim among `clients`) shows the
    /// question itself: it stays held, and goes out once the app has left the front, if it
    /// still waits then.
    async fn send_held(self: &Arc<Self>, due: Vec<(Parked, SendKind)>, clients: &[ClientSnapshot]) {
        let claims = self.claims(clients);
        let at = Moment::now();
        for (p, kind) in due {
            let Some(d) = self.store().get(&p.device_id).cloned() else { continue };
            if is_app_claimed(&d, clients, &claims, at) {
                debug!("still holding for {}: {APP} is open", d.who());
                continue;
            }
            let ctx = match self.server_named(&p.intent.block.server) {
                Some(s) => context(&s, &p.intent.block).await,
                None => BlockContext::default(),
            };
            let m = PushMessage::compose(&p.intent, &ctx).stacked();
            self.send_one(&d, &p.intent, &m, kind, &[], at).await;
        }
    }

    /// Asks the gateway again about the questions it holds for a desk elsewhere: per phone and
    /// server, one each `presence::PROBE_EVERY`, the push itself with `hold_if_desk` once more.
    /// Held again, it waits on (its cap still counts from when it was first held); sent, nobody
    /// is at that desk now, and the phone's other questions of that server go too. A server
    /// that can't be asked names no desk, so its question is sent.
    async fn probe_held(self: &Arc<Self>, clients: &[ClientSnapshot]) {
        let probes = self.holds.lock().unwrap().probes(Moment::now());
        if probes.is_empty() {
            return;
        }
        let claims = self.claims(clients);
        for p in probes {
            let at = Moment::now();
            let server = p.intent.block.server.clone();
            self.holds.lock().unwrap().asked(&p.device_id, &server, at);
            let Some(d) = self.store().get(&p.device_id).cloned() else { continue };
            if is_app_claimed(&d, clients, &claims, at) {
                debug!("still holding for {}: {APP} is open", d.who());
                continue;
            }
            let (ctx, on_server) = match self.server_named(&server) {
                Some(s) => (context(&s, &p.intent.block).await, app_clients(&s).await.unwrap_or_default()),
                None => (BlockContext::default(), vec![]),
            };
            let m = PushMessage::compose(&p.intent, &ctx).stacked();
            if let SendResult::Sent(_) = self.send_one(&d, &p.intent, &m, SendKind::Probe, &on_server, at).await {
                let rest = self.holds.lock().unwrap().remote_of(&p.device_id, &server);
                self.send_held(rest.into_iter().map(|q| (q, SendKind::Away)).collect(), clients).await;
            }
        }
    }

    /// A desktop notification (OSC 9 / 777) is pushed unless it is an OSC 9;4 progress report
    /// an older Rex passed on, or its pane has an OSC 7501 record now or lost one
    /// `desk::NOTICE_MEMORY` ago at most: that agent alerts through its status already. Rex is
    /// asked after `desk::NOTICE_WAIT`, so a status that follows the notice counts. A pane that
    /// runs an agent but reports no status, and a pane Rex can't tell about, push as before.
    async fn notice_worth_a_push(&self, s: &Server, intent: &PushIntent) -> bool {
        if intent.text.as_deref().is_some_and(|t| t.starts_with("4;")) {
            debug!("no push: a progress report, not a notification");
            return false;
        }
        tokio::time::sleep(NOTICE_WAIT).await;
        let b = &intent.block;
        let key = format!("{}|{}", b.session_id, b.block_id);
        let recent = s.st.lock().unwrap().status_removed_at.get(&key).is_some_and(|at| crate::desk::mono() - at < NOTICE_MEMORY);
        let has_status = recent || {
            let args = json!({"session_id": b.session_id, "block_id": b.block_id, "args": {}});
            s.conn.call("com.superlogical.terminal.program_status", args).await.is_ok_and(|r| !r.arr("records").is_empty())
        };
        if has_status {
            info!("no push: a notification from a pane that alerts through its status");
        }
        !has_status
    }

    fn server_named(&self, name: &str) -> Option<Arc<Server>> {
        self.servers.iter().find(|s| s.st.lock().unwrap().name == name).cloned()
    }

    /// What an event says about held questions: an agent that left `blocked` (working, idle,
    /// done, error), records removed, a pane closed. None of it waits any more.
    fn unhold(&self, e: &RelayEvent) {
        let mut holds = self.holds.lock().unwrap();
        let gone = match e {
            RelayEvent::Status(b, rep) if rep.state != "blocked" => holds.moved_on(b, Some(&rep.record_id)),
            RelayEvent::StatusRemoved(b, ids) => holds.records_gone(b, ids),
            RelayEvent::BlockClosed(b) => {
                holds.closed(b);
                0
            }
            _ => 0,
        };
        if gone > 0 {
            info!("no longer holding {gone} question(s): the agent moved on");
        }
    }

    /// After a (re)connect, or a restart that read parked.json: a held question of this server
    /// whose agent no longer waits is dropped (its events may have been missed), asking Rex for
    /// each pane's status; one Rex can't answer for stays, and the desk is watched.
    async fn recheck_held(self: &Arc<Self>, s: &Server) {
        let name = s.st.lock().unwrap().name.clone();
        let held: Vec<Parked> = self.holds.lock().unwrap().parked().iter().filter(|p| p.intent.block.server == name).cloned().collect();
        if held.is_empty() {
            return;
        }
        // (session, block) -> the records that are blocked, or None when Rex didn't say.
        let mut blocked: HashMap<(String, String), Option<HashSet<String>>> = HashMap::new();
        for p in &held {
            let key = (p.intent.block.session_id.clone(), p.intent.block.block_id.clone());
            if blocked.contains_key(&key) {
                continue;
            }
            let args = json!({"session_id": key.0, "block_id": key.1, "args": {}});
            let records = s.conn.call("com.superlogical.terminal.program_status", args).await.ok().map(|r| {
                r.arr("records").into_iter().filter(|rec| rec.str("state") == Some("blocked")).map(|rec| rec.str("id").unwrap_or("").to_string()).collect()
            });
            blocked.insert(key, records);
        }
        let gone = self.holds.lock().unwrap().recheck(&name, |p| {
            let key = (p.intent.block.session_id.clone(), p.intent.block.block_id.clone());
            blocked.get(&key).cloned().flatten().map(|ids| ids.contains(p.record()))
        });
        if gone > 0 {
            info!("no longer holding {gone} question(s): the agent no longer waits");
        }
        if !self.holds.lock().unwrap().parked().is_empty() {
            self.hold_watch();
        }
    }

    /// Watches the computer's sleep and wake, once. On "will sleep" the desk is away: what is
    /// held goes out, and this computer's leases are removed, before sleep is allowed,
    /// `SLEEP_GRACE` at most. On wake the desk is looked at again.
    fn watch_power(self: &Arc<Self>) {
        if self.power_watched.swap(true, Ordering::SeqCst) {
            return;
        }
        let Some(mut events) = self.sense.watch_power() else { return };
        let relay = Arc::downgrade(self);
        tokio::spawn(async move {
            while let Some(event) = events.recv().await {
                let Some(r) = relay.upgrade() else { break };
                match event {
                    Power::WillSleep(done) => {
                        if let Some(Edge::Left(why)) = r.desk.lock().unwrap().will_sleep() {
                            info!("desk away ({why})");
                        }
                        // A release cut off here, after the gateway took a push but before
                        // `sent` unparked it, sends that question again after wake. The copy has
                        // the same collapse id, so it replaces the first on the phone: a
                        // duplicate request, not a duplicate notification. A removal cut off
                        // is sent again at the next look after wake, and the lease ends within
                        // `presence::LEASE_TTL` anyway.
                        let _ = tokio::time::timeout(SLEEP_GRACE, async { tokio::join!(r.release(Some(SendKind::Away)), r.lease_tick(true)) }).await;
                        let _ = done.try_send(());
                    }
                    Power::PoweredOn => {
                        r.desk.lock().unwrap().powered_on();
                        if !r.holds.lock().unwrap().parked().is_empty() {
                            r.hold_watch();
                        }
                    }
                }
            }
        });
    }

    /// Starts the look for leases every `POLL`, once. It costs nothing while no phone has a
    /// presence key, and reads the computer only while a Rex desktop app runs here.
    fn lease_watch(self: &Arc<Self>) {
        if self.lease_running.swap(true, Ordering::SeqCst) {
            return;
        }
        let relay = Arc::downgrade(self);
        tokio::spawn(async move {
            loop {
                tokio::time::sleep(POLL).await;
                let Some(r) = relay.upgrade() else { break };
                if r.stopping.load(Ordering::SeqCst) {
                    break;
                }
                r.lease_tick(false).await;
            }
        });
    }

    /// The desks of this computer: the labels of the Rex desktop apps that run here for this
    /// user, on any server watched, while someone is at the computer. None while nobody is, it
    /// sleeps, or no such app runs (then the computer is not even read).
    async fn desk_labels(&self) -> Vec<String> {
        let uid = crate::platform::user_id();
        let mut labels: Vec<String> = vec![];
        #[cfg(test)]
        if let Some(l) = self.labels_in_test.lock().unwrap().clone() {
            labels = l;
        }
        for s in &self.servers {
            if !s.conn.is_connected() {
                continue;
            }
            let Ok(clients) = app_clients(s).await else { continue };
            for c in clients {
                if shows_desk(&c) && is_local_desktop_app(&c, uid, &|pid| self.sense.process(pid)) {
                    labels.extend(c.label.clone());
                }
            }
        }
        labels.sort();
        labels.dedup();
        if labels.is_empty() || !self.desk_present() {
            return vec![];
        }
        labels
    }

    /// Writes this computer's desk leases at each phone's gateway, renews them, and removes
    /// those of a desk nobody is at any more (`presence::Leases`). `away`: nobody is here, whatever
    /// the readings say (the computer goes to sleep). The requests go out together, so the 3 s
    /// before sleep cover every phone.
    async fn lease_tick(&self, away: bool) {
        let devices: Vec<Device> = self.store().devices.clone();
        let tracked = self.leases.lock().unwrap().phones();
        let keyed = devices.iter().any(|d| d.presence_key.is_some());
        if !keyed && tracked.is_empty() {
            return;
        }
        let labels = if away || !keyed { vec![] } else { self.desk_labels().await };
        let t = now();
        let mut puts = vec![];
        {
            let mut leases = self.leases.lock().unwrap();
            for id in tracked.iter().filter(|id| !devices.iter().any(|d| &d.device_id == *id)) {
                leases.forget(id);
            }
            for d in &devices {
                let want: Vec<String> = match d.presence_key.as_deref().and_then(PresenceKey::parse) {
                    Some(key) => labels.iter().map(|l| key.tag(l)).collect(),
                    None => vec![],
                };
                if want.is_empty() && !tracked.contains(&d.device_id) {
                    continue;
                }
                for p in leases.plan(&d.device_id, &want, t) {
                    let held = leases.holds(&d.device_id, &p.tag);
                    puts.push((p, d.clone(), held));
                }
            }
        }
        let sends = puts.into_iter().map(|(p, d, held)| async move {
            let answer = self.sender.lease(&d, &p.tag, p.ttl).await;
            (p, d, held, answer)
        });
        for (p, d, held, answer) in futures_util::future::join_all(sends).await {
            let who = d.who();
            match &answer {
                LeaseAnswer::Stored if p.ttl == 0 => info!("desk lease for {who}: removed"),
                LeaseAnswer::Stored if !held => info!("desk lease for {who}: present"),
                LeaseAnswer::Stored => debug!("desk lease for {who}: renewed"),
                LeaseAnswer::NotStored => {
                    info!("the gateway takes no desk lease for {who}: it doesn't count this computer as the phone owner's; none until the phone registers again")
                }
                LeaseAnswer::Absent => info!("the gateway of {who} has no desk presence; asking again in a day"),
                LeaseAnswer::Limited(wait) => info!("desk lease for {who}: rate limited, waiting {wait:.0} s"),
                LeaseAnswer::Unauthorized => self.settle(&d, &SendResult::Unauthorized, t),
                LeaseAnswer::Gone(why) => self.settle(&d, &SendResult::Gone(why.clone()), t),
                LeaseAnswer::Retry(why) => debug!("desk lease for {who} not written, tried again at the next look: {why}"),
            }
            self.leases.lock().unwrap().answer(&p, &answer, now());
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
        assert_eq!(names, ["register_push", "helper_identity", "unregister_push", "push_presence", "set_push_paused", "helper_status", "update_helper", "send_test", "port_share", "port_owner"]);
        let args = |i: usize| a[i]["args"]["properties"].as_object().unwrap().keys().map(String::as_str).collect::<Vec<_>>();
        assert_eq!((args(8), args(9)), (vec!["block", "phone_ip", "port"], vec!["pid", "port"]));
        assert!(a[8]["args"].get("required").is_none() && a[9]["args"].get("required").is_none());
        assert_eq!(a[4], json!({"name": "set_push_paused", "kind": "client", "category": BEACON, "title": "Pause or Resume Notifications",
            "description": "Pause or resume notifications from this computer to the calling iPhone. Its registration stays as it is.",
            "args": {"type": "object", "properties": {"paused": {"type": "boolean"}}, "required": ["paused"]}}));
        assert_eq!(a[7], json!({"name": "send_test", "kind": "client", "category": BEACON, "title": "Send a Test Notification",
            "description": "Send one notification to the calling iPhone, to show that notifications from this computer arrive.",
            "args": {"type": "object", "properties": {}}}));
        // Every declared action is one the helper answers, and the other way round.
        let mut known = KNOWN_ACTIONS.to_vec();
        known.sort_unstable();
        let mut declared = names.clone();
        declared.sort_unstable();
        assert_eq!(known, declared);
        let args: Vec<&str> = a[0]["args"]["properties"].as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(args, ["device_id", "device_name", "environment", "gateway", "paused", "push_secret", "setup_seal", "token"]);
        assert_eq!(a[0]["args"]["properties"]["paused"]["type"], "boolean");
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
    /// The system the tests' helper says it runs on.
    const OS: &str = "macOS 15.5";

    fn temp(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("relay-{tag}-{}-{}", std::process::id(), now()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// A relay with no server. Only a relay with `dry_run` may be asked to `register`: it
    /// logs the desktop notice instead of posting it. `sender` says whether pushes go out
    /// (to a server in the test) or are logged.
    fn relay_with(dir: &std::path::Path, dry_run: bool, sender: Sender, gateways: &[&str]) -> Arc<Relay> {
        relay_watching(vec![], dir, dry_run, sender, gateways)
    }

    /// The computer as a test has it: what a reading gives, and the processes there are.
    #[derive(Default)]
    struct TestSense {
        reading: Mutex<crate::desk::Reading>,
        processes: Mutex<HashMap<u32, crate::desk::Process>>,
        /// How those processes were started.
        invocations: Mutex<HashMap<u32, crate::platform::Invocation>>,
        /// The sleep and wake events the test sends, taken by the first watcher.
        power: Mutex<Option<tokio::sync::mpsc::UnboundedReceiver<Power>>>,
    }

    impl Sense for TestSense {
        fn read(&self) -> crate::desk::Reading {
            *self.reading.lock().unwrap()
        }

        fn process(&self, pid: u32) -> Option<crate::desk::Process> {
            self.processes.lock().unwrap().get(&pid).cloned()
        }

        fn invocation(&self, pid: u32) -> Option<crate::platform::Invocation> {
            self.invocations.lock().unwrap().get(&pid).cloned()
        }

        fn watch_power(&self) -> Option<tokio::sync::mpsc::UnboundedReceiver<Power>> {
            self.power.lock().unwrap().take()
        }
    }

    /// `relay_with`, and one connection (never opened) per entry of `watch`.
    fn relay_watching(watch: Vec<Option<Endpoint>>, dir: &std::path::Path, dry_run: bool, sender: Sender, gateways: &[&str]) -> Arc<Relay> {
        relay_sensing(watch, dir, dry_run, sender, gateways, Arc::new(TestSense::default()))
    }

    /// `relay_watching` on a computer the test controls.
    fn relay_sensing(watch: Vec<Option<Endpoint>>, dir: &std::path::Path, dry_run: bool, sender: Sender, gateways: &[&str], sense: Arc<dyn Sense>) -> Arc<Relay> {
        let env = Env { dry_run, debug_build: true, keys: Ok(vec![[7u8; 32]]), place: Err("test".into()), service: false, writable: false };
        let config: Vec<String> = gateways.iter().map(|g| g.to_string()).collect();
        Relay::new(
            watch,
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
                os: OS.into(),
                name: None,
                sense,
                away_after: crate::desk::AWAY_AFTER,
                sessions: vec![],
                hold_cap: None,
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

    /// The phone app on a phone with this device id, as the server reports the caller.
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
        assert_eq!(e["message"], concat!("This ", crate::beacon_name!(), " needs a newer ", crate::app_name!(), " app."));
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
            ("set_push_paused", json!({"paused": true})),
            ("helper_identity", json!({"challenge": challenge, "device_id": "a1b2c3d4"})),
            ("helper_status", json!({})),
            ("update_helper", json!({})),
            ("send_test", json!({})),
            ("anything_else", json!({})),
        ] {
            let (outcome, after) = r.act(&s, action, &args, &nobody).await;
            assert_eq!(outcome.unwrap_err()["code"], "refused", "{action}");
            assert!(after.is_none());
        }
        // Nothing changed: the phone is still registered, not paused, and was not marked as in
        // the background.
        assert_eq!(devices(&r).len(), 1);
        assert!(!devices(&r)[0].paused);
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
            assert_eq!(r.unregister(&args, &alex, ALEX), Ok(json!({"removed": false})), "{args}");
        }
        let other_client = Requester { client_id: "client:mac".into(), label: "rex".into(), identity: Some(ALEX.into()) };
        assert_eq!(r.unregister(&json!({"device_id": "a1b2c3d4", "token": "ab".repeat(32)}), &other_client, ALEX), Ok(json!({"removed": true})));
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
            ["can_update", "checked_at", "devices", "failing_since", "last_error", "last_push_at", "latest_version", "linger", "manifest_expires_at", "min_version", "notices", "os",
                "other_phones", "paused", "registered", "update_available", "update_required", "updating", "version"]
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
        assert_eq!(outcome.unwrap_err(), json!({"code": "update_failed", "message": concat!("This copy of ", crate::beacon_name!(), " can't update itself.")}));
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
            ["can_update", "checked_at", "failing_since", "last_error", "latest_version", "manifest_expires_at", "min_version", "update_available", "update_required", "updating", "version"]
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
        assert!(log.contains(concat!("answered the ", crate::app_name!(), " setup")));
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
            Options {
                dry_run: true,
                label: None,
                name: None,
                debounce: 30.0,
                burst: 10.0,
                per_minute: 10.0,
                status_path: dir.join("status.json"),
                gateways: Gateways::default(),
                key: None,
                state_dir: dir.clone(),
                os: OS.into(),
                sense: Arc::new(TestSense::default()),
                away_after: crate::desk::AWAY_AFTER,
                sessions: vec![],
                hold_cap: None,
            },
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

    /// One push of `m` to `devices` at time `t`, nobody at a desk, as `dispatch` sends it.
    async fn push_at(r: &Arc<Relay>, m: &PushMessage, devices: Vec<Device>, clients: &[ClientSnapshot], t: f64) {
        let intent = PushIntent::new(m.category, BlockRef { server: m.server.clone(), session_id: m.session_id.clone(), block_id: m.block_id.clone() });
        r.deliver(&intent, m, devices, clients, &[], false, Moment { wall: t, mono: None }).await;
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
            r.store.lock().unwrap().register(phone(id, &base)).unwrap();
        }
        push_at(&r, &message("A very private message"), devices(&r), &[], 1000.0).await;

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
        r.store.lock().unwrap().register(phone("a1b2c3d4", &base)).unwrap();
        let secret = format!("{SECRET}a1b2c3d4");
        let push = |t: f64| {
            let r = r.clone();
            async move { push_at(&r, &message("Hello"), devices(&r), &[], t).await }
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
        push_at(&r, &message("Hello"), devices(&r), &[], 1000.0).await;
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
    async fn a_dry_run_sends_nothing() {
        // (An open app gets no request: `only_a_live_claim_counts_as_open`.)
        let dir = temp("skip");
        let (base, seen) = serve(vec![canned(200, "{}")]).await;
        let r = relay_with(&dir, false, Sender::Gateway, &[&base]);
        r.store.lock().unwrap().register(phone("a1b2c3d4", &base)).unwrap();
        let dry_dir = temp("skipdry");
        push_at(&relay(&dry_dir, true), &message("Hello"), devices(&r), &[], 1000.0).await;
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
        r.store.lock().unwrap().register(Device::new("a1b2c3d4", &base, NEW_SECRET, "sandbox", ALEX)).unwrap();
        push_at(&r, &message("Hello"), vec![old.clone()], &[], 1000.0).await;
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
            ask(r.act(&s, "set_push_paused", &json!({"paused": true}), who).await.0);
            ask(r.act(&s, "set_push_paused", &json!({"paused": false}), who).await.0);
            ask(r.act(&s, "update_helper", &json!({}), who).await.0);
            ask(r.act(&s, first, &json!({}), who).await.0);
        }
        ask(r.act(&s, "unregister_push", &json!({"device_id": first}), &alex).await.0);
        ask(r.act(&s, "unregister_push", &json!({"device_id": "a1b2c3d4"}), &sam).await.0);

        // Pushes: sent, failed, refused once, refused for good.
        for t in [1000.0, 1010.0, 1020.0, 1100.0] {
            push_at(&r, &message("Hello"), devices(&r), &[], t).await;
        }
        assert!(devices(&r).is_empty(), "the second 401 dropped it");
        ask(r.act(&s, "register_push", &registration(first), &alex).await.0);
        ask(r.act(&s, "push_presence", &json!({"active": true}), &alex).await.0);
        // A new secret, which Apple's answer then kills.
        ask(r.act(&s, "register_push", &registration(second), &alex).await.0);
        push_at(&r, &message("Hello"), devices(&r), &[], 1200.0).await;
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

    /// A server the helper watches under this name, which is what a push carries as `server`.
    fn named_server(name: &str) -> Server {
        let s = server();
        s.st.lock().unwrap().name = name.into();
        s
    }

    async fn status(r: &Relay, who: &Requester) -> Value {
        r.act(&server(), "helper_status", &json!({}), who).await.0.unwrap()
    }

    async fn send_test(r: &Relay, s: &Server, who: &Requester) -> Result<Value, Value> {
        let (outcome, after) = r.act(s, "send_test", &json!({}), who).await;
        assert!(after.is_none());
        outcome
    }

    #[tokio::test]
    async fn helper_status_names_the_system_and_counts_the_phones() {
        let dir = temp("status-fields");
        let r = relay(&dir, true);
        let alex = app("a1b2c3d4", Some(ALEX));
        let first = status(&r, &alex).await;
        assert_eq!((&first["os"], &first["devices"], &first["last_push_at"]), (&json!(OS), &json!(0), &Value::Null));
        register(&r, &register_args(), ALEX).unwrap();
        assert_eq!(status(&r, &alex).await["devices"], 1);
        // Every phone on this helper counts, whoever registered it and whoever asks.
        let mut sams = register_args();
        sams["device_id"] = json!("ffff0000");
        sams["push_secret"] = json!(NEW_SECRET);
        register(&r, &sams, SAM).unwrap();
        for who in [&alex, &app("ffff0000", Some(SAM)), &app("00000000", Some("tailscale:1"))] {
            let answer = status(&r, who).await;
            assert_eq!((&answer["os"], &answer["devices"]), (&json!(OS), &json!(2)), "{who:?}");
        }
        // The same phone again is still one, and a phone that left is gone from the count.
        register(&r, &register_args(), ALEX).unwrap();
        assert_eq!(status(&r, &alex).await["devices"], 2);
        assert_eq!(r.unregister(&json!({"device_id": "ffff0000"}), &app("ffff0000", Some(SAM)), SAM), Ok(json!({"removed": true})));
        assert_eq!(status(&r, &alex).await["devices"], 1);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn last_push_at_is_the_callers_phones_last_accepted_notification() {
        let dir = temp("last-push");
        let (base, seen) = serve(vec![canned(200, "{}"), canned(500, "boom"), canned(200, "{}")]).await;
        let r = relay_with(&dir, false, Sender::Gateway, &[&base]);
        for id in ["a1b2c3d4", "ffff0000"] {
            r.store.lock().unwrap().register(phone(id, &base)).unwrap();
        }
        let (alex, other, sam) = (app("a1b2c3d4", Some(ALEX)), app("ffff0000", Some(ALEX)), app("a1b2c3d4", Some(SAM)));
        let no_phone = Requester { client_id: "client:mac".into(), label: "rex".into(), identity: Some(ALEX.into()) };
        for who in [&alex, &other, &sam, &no_phone] {
            assert_eq!(status(&r, who).await["last_push_at"], Value::Null, "{who:?}");
        }
        let one = |id: &str| vec![r.store.lock().unwrap().get(id).unwrap().clone()];
        push_at(&r, &message("Hello"), one("a1b2c3d4"), &[], 1234.9).await;
        assert_eq!(status(&r, &alex).await["last_push_at"], 1234);
        // Only for that phone, and only for the identity it is registered to.
        for who in [&other, &sam, &no_phone] {
            assert_eq!(status(&r, who).await["last_push_at"], Value::Null, "{who:?}");
        }
        // A notification the gateway did not accept changes nothing; the next accepted one does.
        push_at(&r, &message("Hello"), one("a1b2c3d4"), &[], 2000.0).await;
        assert_eq!(status(&r, &alex).await["last_push_at"], 1234);
        push_at(&r, &message("Hello"), one("a1b2c3d4"), &[], 3000.0).await;
        assert_eq!(status(&r, &alex).await["last_push_at"], 3000);
        assert_eq!(seen.lock().unwrap().len(), 3);
        // It is kept in memory only: a helper that starts again knows of none.
        r.write_status();
        assert!(!std::fs::read_to_string(dir.join("status.json")).unwrap().contains("last_push_at"));
        drop(r);
        let r = relay_with(&dir, false, Sender::Gateway, &[&base]);
        assert_eq!(status(&r, &alex).await["last_push_at"], Value::Null);
        // A dry run asks no gateway, so it has nothing to report either.
        let dry_dir = temp("last-push-dry");
        let dry = relay(&dry_dir, true);
        register(&dry, &register_args(), ALEX).unwrap();
        push_at(&dry, &message("Hello"), devices(&dry), &[], 1000.0).await;
        assert_eq!(send_test(&dry, &server(), &alex).await, Ok(json!({"sent": true})));
        assert_eq!(status(&dry, &alex).await["last_push_at"], Value::Null);
        std::fs::remove_dir_all(dir).unwrap();
        std::fs::remove_dir_all(dry_dir).unwrap();
    }

    /// What a payload field may hold by the gateway's rules (`Gateway/src/validate.ts`): a
    /// string of at most this many characters, one of these words, or a string of this form.
    enum Rule {
        Max(usize),
        OneOf(&'static [&'static str]),
        Form(fn(&str) -> bool),
    }

    /// `record`: 1 to 128 characters, none a control character (`\p{Cc}`).
    fn record_form(text: &str) -> bool {
        (1..=128).contains(&text.chars().count()) && !text.chars().any(char::is_control)
    }

    /// `fp`: 16 lowercase hex characters.
    fn fp_form(text: &str) -> bool {
        text.len() == 16 && text.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
    }

    const PAYLOAD_FIELDS: [(&str, Rule); 6] = [
        ("server", Rule::Max(512)),
        ("session_id", Rule::Max(256)),
        ("window_id", Rule::Max(256)),
        ("block_id", Rule::Max(256)),
        ("record", Rule::Form(record_form)),
        ("fp", Rule::Form(fp_form)),
    ];
    const APS_FIELDS: [(&str, Rule); 4] = [
        ("sound", Rule::OneOf(&["default"])),
        ("thread-id", Rule::Max(256)),
        ("category", Rule::OneOf(&["AGENT_BLOCKED", "AGENT_BLOCKED_ACT", "AGENT_DONE", "NOTICE"])),
        ("interruption-level", Rule::OneOf(&["passive", "active", "time-sensitive"])),
    ];
    const ALERT_FIELDS: [(&str, Rule); 3] = [("title", Rule::Max(120)), ("subtitle", Rule::Max(256)), ("body", Rule::Max(1000))];

    /// `fieldsProblem` of validate.ts: every key but `nested` is a listed one and holds a
    /// string its rule allows.
    fn fields_problem(object: &Value, rules: &[(&str, Rule)], nested: Option<&str>) -> Option<String> {
        for (key, value) in object.as_object()? {
            if Some(key.as_str()) == nested {
                continue;
            }
            let Some((_, rule)) = rules.iter().find(|(name, _)| name == key) else { return Some(format!("{key} is not a field the gateway passes on")) };
            let Some(text) = value.as_str() else { return Some(format!("{key} is not a string")) };
            let allowed = match rule {
                Rule::Max(most) => text.chars().count() <= *most,
                Rule::OneOf(words) => words.contains(&text),
                Rule::Form(holds) => holds(text),
            };
            if !allowed {
                return Some(format!("{key} holds a value the gateway refuses"));
            }
        }
        None
    }

    /// `parsePush` of validate.ts for the body of one `POST /v1/push`, at the gateway's time
    /// `now`: what the gateway would refuse it for, or None.
    fn gateway_problem(body: &Value, now: i64) -> Option<String> {
        let payload = body.get("payload").filter(|p| p.is_object())?;
        if payload.to_string().len() > 4096 {
            return Some("payload is larger than 4096 bytes".into());
        }
        let (aps, alert) = (&payload["aps"], &payload["aps"]["alert"]);
        if !aps.is_object() || !alert.is_object() || !alert["title"].is_string() || !alert["body"].is_string() {
            return Some("payload.aps.alert needs a title and a body".into());
        }
        let fields = fields_problem(payload, &PAYLOAD_FIELDS, Some("aps")).or_else(|| fields_problem(aps, &APS_FIELDS, Some("alert"))).or_else(|| fields_problem(alert, &ALERT_FIELDS, None));
        if fields.is_some() {
            return fields;
        }
        if body.get("push_type").is_some_and(|t| t != "alert") {
            return Some("push_type must be alert".into());
        }
        if body.get("priority").is_some_and(|p| p != 5 && p != 10) {
            return Some("priority must be 5 or 10".into());
        }
        if let Some(id) = body.get("collapse_id") {
            if !id.as_str().is_some_and(|id| (1..=64).contains(&id.len()) && id.bytes().all(|b| (0x21..=0x7e).contains(&b))) {
                return Some("collapse_id must be 1 to 64 visible ASCII characters".into());
            }
        }
        if let Some(at) = body.get("expiration") {
            if !at.as_i64().is_some_and(|at| (now - 60..=now + 3600 + 60).contains(&at)) {
                return Some("expiration is not within the hour".into());
            }
        }
        None
    }

    #[test]
    fn the_gateways_rules_as_the_tests_mirror_them() {
        let body = |payload: Value| json!({"payload": payload, "push_type": "alert", "priority": 10});
        let good = json!({"aps": {"alert": {"title": "t", "body": "b"}, "category": "NOTICE"}, "server": "s"});
        assert_eq!(gateway_problem(&body(good.clone()), 0), None);
        let with = |path: &[&str], value: Value| {
            let mut p = good.clone();
            let mut at = &mut p;
            for key in path {
                at = &mut at[*key];
            }
            *at = value;
            gateway_problem(&body(p), 0)
        };
        assert!(with(&["badge"], json!("1")).is_some());
        assert!(with(&["server"], json!(7)).is_some());
        assert!(with(&["aps", "badge"], json!("1")).is_some());
        assert!(with(&["aps", "category"], json!("OTHER")).is_some());
        assert!(with(&["aps", "sound"], json!("loud")).is_some());
        assert!(with(&["aps", "interruption-level"], json!("critical")).is_some());
        assert!(with(&["aps", "alert", "title"], json!("x".repeat(121))).is_some());
        assert!(with(&["aps", "alert", "title"], Value::Null).is_some());
        assert!(with(&["aps", "alert", "action"], json!("x")).is_some());
        assert_eq!(with(&["aps", "category"], json!("AGENT_BLOCKED_ACT")), None);
        assert_eq!(with(&["record"], json!("claude")), None);
        assert_eq!(with(&["fp"], json!("d110a7daf17e741b")), None);
        for record in [json!(""), json!("r".repeat(129)), json!("cla\nude"), json!(7)] {
            assert!(with(&["record"], record.clone()).is_some(), "{record}");
        }
        for fp in [json!(""), json!("a5beb1b22ff48d5"), json!("d110a7daf17e741b0"), json!("A5BEB1B22FF48D5D"), json!("g5beb1b22ff48d5d")] {
            assert!(with(&["fp"], fp.clone()).is_some(), "{fp}");
        }
        let mut late = body(good.clone());
        late["expiration"] = json!(3661);
        assert!(gateway_problem(&late, 0).is_some());
        late["expiration"] = json!(3660);
        assert_eq!(gateway_problem(&late, 0), None);
    }

    #[tokio::test]
    async fn send_test_sends_one_notification_the_gateway_accepts() {
        let dir = temp("test-payload");
        let (base, seen) = serve(vec![canned(200, r#"{"apns_id":"11111111-2222"}"#)]).await;
        let r = relay_with(&dir, false, Sender::Gateway, &[&base]);
        r.store.lock().unwrap().register(phone("a1b2c3d4", &base)).unwrap();
        let alex = app("a1b2c3d4", Some(ALEX));
        let s = named_server("https://rex.example.ts.net");
        let before = now() as i64;
        assert_eq!(send_test(&r, &s, &alex).await, Ok(json!({"sent": true})));
        let after = now() as i64;

        let seen = seen.lock().unwrap().clone();
        assert_eq!(seen.len(), 1);
        let q = &seen[0];
        assert_eq!((q.method.as_str(), q.path.as_str()), ("POST", "/v1/push"));
        assert_eq!(q.header("authorization"), Some(format!("Bearer {SECRET}a1b2c3d4").as_str()));
        let mut body: Value = serde_json::from_slice(&q.body).unwrap();
        assert_eq!(gateway_problem(&body, after), None);
        // The time it is kept for is the one field that differs from run to run.
        let expiration = body.as_object_mut().unwrap().remove("expiration").unwrap().as_i64().unwrap();
        assert!((before + 3600..=after + 3600).contains(&expiration), "{expiration}");
        assert_eq!(
            body,
            json!({
                "payload": {
                    "aps": {
                        "alert": {"title": crate::app_name!(), "body": "Test notification from rex"},
                        "sound": "default",
                        "category": "NOTICE",
                        "thread-id": "rexduo-test",
                        "interruption-level": "active",
                    },
                    "server": "https://rex.example.ts.net",
                },
                "push_type": "alert",
                "priority": 10,
            })
        );
        // The gateway accepted it, so it is this phone's last notification.
        let at = status(&r, &alex).await["last_push_at"].as_i64().unwrap();
        assert!((before..=after).contains(&at), "{at}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn send_test_is_only_for_the_identity_that_registered_the_phone() {
        let dir = temp("test-owner");
        let (base, seen) = serve(vec![canned(200, "{}")]).await;
        let r = relay_with(&dir, false, Sender::Gateway, &[&base]);
        let s = named_server("https://rex.example.ts.net");
        let alex = app("a1b2c3d4", Some(ALEX));
        let not_registered = json!({"code": "not_registered", "message": "This phone is not set up for notifications from this computer."});
        // Nobody is registered.
        assert_eq!(send_test(&r, &s, &alex).await, Err(not_registered.clone()));
        r.store.lock().unwrap().register(phone("a1b2c3d4", &base)).unwrap();
        // Someone else's client with this phone's id in its label, another phone of the
        // owner, and a client with no device id: the ones `push_presence` answers
        // `registered: false`.
        let others = [app("a1b2c3d4", Some(SAM)), app("a1b2c3d4", Some("peer:12345")), app("ffff0000", Some(ALEX)), Requester { client_id: "client:mac".into(), label: "rex".into(), identity: Some(ALEX.into()) }];
        for other in &others {
            assert_eq!(r.act(&s, "push_presence", &json!({"active": false}), other).await.0.unwrap(), json!({"registered": false}), "{other:?}");
            assert_eq!(send_test(&r, &s, other).await, Err(not_registered.clone()), "{other:?}");
        }
        // A client the server did not identify is refused before that.
        assert_eq!(send_test(&r, &s, &app("a1b2c3d4", None)).await.unwrap_err()["code"], "refused");
        // None of them sent anything or used up the owner's test.
        assert!(seen.lock().unwrap().is_empty());
        assert!(r.tests.lock().unwrap().is_empty());
        assert_eq!(send_test(&r, &s, &alex).await, Ok(json!({"sent": true})));
        assert_eq!(seen.lock().unwrap().len(), 1);
        for other in &others {
            assert_eq!(status(&r, other).await["last_push_at"], Value::Null, "{other:?}");
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_phone_gets_one_test_every_ten_seconds() {
        let dir = temp("test-soon");
        let (base, seen) = serve(vec![canned(200, "{}"), canned(200, "{}")]).await;
        let r = relay_with(&dir, false, Sender::Gateway, &[&base]);
        let s = named_server("https://rex.example.ts.net");
        for id in ["a1b2c3d4", "ffff0000"] {
            r.store.lock().unwrap().register(phone(id, &base)).unwrap();
        }
        let (alex, other) = (app("a1b2c3d4", Some(ALEX)), app("ffff0000", Some(ALEX)));
        let too_soon = json!({"code": "test_too_soon", "message": "A test notification was sent a moment ago. Try again in a few seconds."});
        assert_eq!(send_test(&r, &s, &alex).await, Ok(json!({"sent": true})));
        assert_eq!(send_test(&r, &s, &alex).await, Err(too_soon.clone()));
        assert_eq!(seen.lock().unwrap().len(), 1, "the second one asked the gateway nothing");
        // Each phone has its own.
        assert_eq!(send_test(&r, &s, &other).await, Ok(json!({"sent": true})));
        assert_eq!(send_test(&r, &s, &other).await, Err(too_soon.clone()));
        assert_eq!(seen.lock().unwrap().len(), 2);

        assert_eq!(TEST_INTERVAL, Duration::from_secs(10));
        let t = Instant::now() + Duration::from_secs(60);
        assert_eq!(r.take_test_slot("00000001", t), Ok(()));
        assert_eq!(r.take_test_slot("00000001", t + Duration::from_millis(9_999)), Err(too_soon.clone()));
        assert_eq!(r.take_test_slot("00000002", t + Duration::from_secs(5)), Ok(()));
        // A refused one does not move the next one further out.
        assert_eq!(r.take_test_slot("00000001", t + Duration::from_secs(10)), Ok(()));
        assert_eq!(r.take_test_slot("00000002", t + Duration::from_secs(14)), Err(too_soon.clone()));
        assert_eq!(r.take_test_slot("00000002", t + Duration::from_secs(15)), Ok(()));
        // A clock that reads earlier than the last test never frees the slot early.
        assert_eq!(r.take_test_slot("00000002", t), Err(too_soon));
        // Nothing older than ten seconds is kept.
        assert_eq!(r.take_test_slot("00000003", t + Duration::from_secs(600)), Ok(()));
        assert_eq!(r.tests.lock().unwrap().len(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn each_answer_of_the_gateway_to_a_test_has_its_error() {
        let dir = temp("test-outcomes");
        capture_log();
        let (base, seen) = serve(vec![
            canned(200, r#"{"apns_id":"11111111-2222"}"#),
            canned(410, r#"{"error":"unregistered","reason":"Unregistered"}"#),
            canned(429, r#"{"error":"rate_limited","message":"slow down"}"#),
            canned(500, "boom"),
            canned(502, r#"{"error":"apns_unreachable"}"#),
            canned(503, ""),
            canned(401, UNAUTHORIZED),
            canned(400, r#"{"error":"bad_request"}"#),
        ])
        .await;
        let r = relay_with(&dir, false, Sender::Gateway, &[&base]);
        let s = named_server("https://rex.example.ts.net");
        // One phone per answer, in the order the gateway gives them.
        let cases = [
            ("00000200", None),
            ("00000410", Some("phone_gone")),
            ("00000429", Some("limit_reached")),
            ("00000500", Some("no_connection")),
            ("00000502", Some("no_connection")),
            ("00000503", Some("no_connection")),
            ("00000401", Some("phone_gone")),
            ("00000400", Some("no_connection")),
        ];
        for (id, _) in cases {
            r.store.lock().unwrap().register(phone(id, &base)).unwrap();
        }
        let mut replies = vec![];
        for (id, code) in cases {
            let outcome = send_test(&r, &s, &app(id, Some(ALEX))).await;
            match code {
                None => assert_eq!(outcome, Ok(json!({"sent": true})), "{id}"),
                Some(code) => assert_eq!(outcome.as_ref().unwrap_err()["code"], code, "{id}"),
            }
            replies.push(outcome.map_or_else(|e| e.to_string(), |v| v.to_string()));
        }
        assert_eq!(seen.lock().unwrap().len(), 8, "one request per test, no retry");
        // The sentences an app may show.
        let message = |code: &str| replies.iter().filter_map(|r| serde_json::from_str::<Value>(r).ok()).find(|v| v["code"] == code).unwrap()["message"].as_str().unwrap().to_string();
        assert_eq!(message("phone_gone"), "This phone's notification address is no longer valid. Set up notifications on it again.");
        assert_eq!(message("limit_reached"), "The notification service has sent as many notifications as it allows for now. Try again later.");
        assert_eq!(message("no_connection"), "The notification service could not be reached.");
        // The registrations fare as after any push: the phone the gateway dropped is gone,
        // and one refusal of a secret is not yet the end of it.
        let left: Vec<String> = devices(&r).iter().map(|d| d.device_id.clone()).collect();
        assert_eq!(left, ["00000200", "00000429", "00000500", "00000502", "00000503", "00000401", "00000400"]);
        // Only the accepted one counts as a notification that was sent.
        for (id, code) in cases {
            assert_eq!(status(&r, &app(id, Some(ALEX))).await["last_push_at"].is_null(), code.is_some(), "{id}");
        }
        // Neither a reply nor the log holds a secret or free text from the other end.
        let log = captured_log();
        assert!(log.contains("test notification asked for by Alex's iPhone #00000200"));
        for text in replies.iter().chain([&log]) {
            assert!(!text.contains(SECRET) && !text.contains("slow down") && !text.contains("boom"), "{text}");
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_gateway_that_is_not_there_is_no_connection() {
        let dir = temp("test-unreachable");
        // Bind, note the port, close: nothing listens there now.
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://127.0.0.1:{}", l.local_addr().unwrap().port());
        drop(l);
        let r = relay_with(&dir, false, Sender::Gateway, &[&base]);
        r.store.lock().unwrap().register(phone("a1b2c3d4", &base)).unwrap();
        let alex = app("a1b2c3d4", Some(ALEX));
        let e = send_test(&r, &named_server("https://rex.example.ts.net"), &alex).await.unwrap_err();
        assert_eq!(e, json!({"code": "no_connection", "message": "The notification service could not be reached."}));
        assert_eq!(devices(&r).len(), 1);
        assert_eq!(status(&r, &alex).await["last_push_at"], Value::Null);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_test_is_sent_while_rex_duo_is_open_on_the_phone() {
        let dir = temp("test-foreground");
        let (base, seen) = serve(vec![canned(200, "{}")]).await;
        let r = relay_with(&dir, false, Sender::Gateway, &[&base]);
        r.store.lock().unwrap().register(phone("a1b2c3d4", &base)).unwrap();
        let s = named_server("https://rex.example.ts.net");
        let alex = app("a1b2c3d4", Some(ALEX));
        // The app says it is in the foreground.
        assert_eq!(r.act(&s, "push_presence", &json!({"active": true}), &alex).await.0.unwrap(), json!({"registered": true}));
        assert!(s.st.lock().unwrap().backgrounded.is_empty());
        // An agent's push that used up its allowance is held back.
        while r.limiter.lock().unwrap().allow("a1b2c3d4", 1000.0) {}
        push_at(&r, &message("Hello"), devices(&r), &[], 1000.0).await;
        assert!(seen.lock().unwrap().is_empty());
        // The test goes out all the same.
        assert_eq!(send_test(&r, &s, &alex).await, Ok(json!({"sent": true})));
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 1);
        let body: Value = serde_json::from_slice(&seen[0].body).unwrap();
        assert_eq!(body["payload"]["aps"]["thread-id"], "rexduo-test");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_test_to_a_phone_the_gateway_dropped_ends_its_registration() {
        let dir = temp("test-gone");
        let (base, seen) = serve(vec![canned(410, r#"{"error":"unregistered","reason":"BadDeviceToken"}"#)]).await;
        // A dry-run relay, so `register` posts no desktop notice, with a sender that does send.
        let r = relay_with(&dir, true, Sender::Gateway, &[&base]);
        let s = named_server("https://rex.example.ts.net");
        let alex = app("a1b2c3d4", Some(ALEX));
        let mut args = register_args();
        args["gateway"] = json!(base);
        register(&r, &args, ALEX).unwrap();
        assert_eq!(send_test(&r, &s, &alex).await.unwrap_err()["code"], "phone_gone");
        // As after any push the gateway answers that way: the phone is unregistered, here
        // and in devices.json, it is told so the next time it asks, and that secret is not
        // taken again.
        assert!(devices(&r).is_empty());
        assert!(DeviceStore::open(dir.join("devices.json")).devices.is_empty());
        let answer = status(&r, &alex).await;
        assert_eq!((&answer["registered"], &answer["devices"], &answer["last_push_at"]), (&json!(false), &json!(0), &Value::Null));
        assert_eq!(register(&r, &args, ALEX).unwrap_err()["code"], "secret_dropped");
        // The next test finds no registration; the gateway is not asked.
        r.tests.lock().unwrap().clear();
        assert_eq!(send_test(&r, &s, &alex).await.unwrap_err()["code"], "not_registered");
        assert_eq!(seen.lock().unwrap().len(), 1);
        // With a new secret the phone is back.
        args["push_secret"] = json!(NEW_SECRET);
        assert_eq!(register(&r, &args, ALEX).unwrap()["registered"], true);
        std::fs::remove_dir_all(dir).unwrap();
    }

    async fn set_paused(r: &Relay, who: &Requester, paused: bool) -> Result<Value, Value> {
        let (outcome, after) = r.act(&server(), "set_push_paused", &json!({"paused": paused}), who).await;
        assert!(after.is_none());
        outcome
    }

    fn paused(r: &Relay, id: &str) -> bool {
        r.store.lock().unwrap().get(id).unwrap().paused
    }

    /// An agent's notification about a pane of the server named `server`.
    fn agent_event(server: &str) -> PushIntent {
        let mut i = PushIntent::new(PushCategory::Notice, BlockRef { server: server.into(), session_id: "session:1".into(), block_id: "block:1".into() });
        i.headline = Some("Deploy".into());
        i.text = Some("Hello".into());
        i
    }

    #[tokio::test]
    async fn a_paused_phone_gets_nothing_and_resumes_with_the_secret_the_helper_holds() {
        const NAME: &str = "https://rex.example.ts.net";
        let dir = temp("pause");
        capture_log();
        let (base, seen) = serve(vec![canned(200, "{}")]).await;
        // One watched server, which is where the agent's event comes from.
        let r = relay_watching(vec![None], &dir, false, Sender::Gateway, &[&base]);
        r.servers[0].st.lock().unwrap().name = NAME.into();
        r.store.lock().unwrap().register(phone("a1b2c3d4", &base)).unwrap();
        let alex = app("a1b2c3d4", Some(ALEX));
        let before = devices(&r)[0].clone();

        assert_eq!(set_paused(&r, &alex, true).await, Ok(json!({"paused": true, "registered": true})));
        // The registration is as it was but for the pause: same secret, gateway and owner.
        let now_paused = devices(&r)[0].clone();
        assert!(now_paused.paused);
        assert_eq!((&now_paused.push_secret, &now_paused.gateway, &now_paused.owner, &now_paused.registered_at), (&before.push_secret, &before.gateway, &before.owner, &before.registered_at));
        // An agent's event, from the event to the gateway and at the last step alone: no
        // notification is composed and the gateway gets no request.
        r.clone().dispatch(agent_event(NAME)).await;
        push_at(&r, &message("Hello"), devices(&r), &[], 1000.0).await;
        assert!(seen.lock().unwrap().is_empty());
        assert!(!captured_log().contains("push NOTICE"));
        assert_eq!(status(&r, &alex).await["last_push_at"], Value::Null);
        // Presence is still taken, and says the phone is registered.
        let s = server();
        assert_eq!(r.act(&s, "push_presence", &json!({"active": false}), &alex).await.0.unwrap(), json!({"registered": true}));
        assert!(s.st.lock().unwrap().backgrounded.contains("client:a1b2c3d4"));
        // Pausing a paused phone is the same answer.
        assert_eq!(set_paused(&r, &alex, true).await, Ok(json!({"paused": true, "registered": true})));

        // Resumed: the next event goes out, with the secret the helper held all along.
        assert_eq!(set_paused(&r, &alex, false).await, Ok(json!({"paused": false, "registered": true})));
        r.clone().dispatch(agent_event(NAME)).await;
        let seen = seen.lock().unwrap().clone();
        assert_eq!(seen.len(), 1);
        assert_eq!(seen[0].path, "/v1/push");
        assert_eq!(seen[0].header("authorization"), Some(format!("Bearer {SECRET}a1b2c3d4").as_str()));
        let log = captured_log();
        assert!(log.contains("push NOTICE") && log.contains("notifications paused by") && log.contains("notifications resumed by"), "{log}");
        assert!(!log.contains(SECRET));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_pause_survives_a_restart_of_the_helper() {
        let dir = temp("pause-restart");
        let (base, seen) = serve(vec![canned(200, "{}")]).await;
        let r = relay_with(&dir, false, Sender::Gateway, &[&base]);
        r.store.lock().unwrap().register(phone("a1b2c3d4", &base)).unwrap();
        let alex = app("a1b2c3d4", Some(ALEX));
        set_paused(&r, &alex, true).await.unwrap();
        drop(r);
        let r = relay_with(&dir, false, Sender::Gateway, &[&base]);
        assert!(paused(&r, "a1b2c3d4"));
        assert_eq!(status(&r, &alex).await["paused"], true);
        push_at(&r, &message("Hello"), devices(&r), &[], 1000.0).await;
        assert!(seen.lock().unwrap().is_empty());
        set_paused(&r, &alex, false).await.unwrap();
        drop(r);
        let r = relay_with(&dir, false, Sender::Gateway, &[&base]);
        assert!(!paused(&r, "a1b2c3d4"));
        push_at(&r, &message("Hello"), devices(&r), &[], 1000.0).await;
        assert_eq!(seen.lock().unwrap().len(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn pausing_is_only_for_the_identity_that_registered_the_phone() {
        let dir = temp("pause-owner");
        let r = relay(&dir, true);
        let s = server();
        let alex = app("a1b2c3d4", Some(ALEX));
        let not_registered = json!({"code": "not_registered", "message": "This phone is not set up for notifications from this computer."});
        // Nobody is registered.
        assert_eq!(set_paused(&r, &alex, true).await, Err(not_registered.clone()));
        register(&r, &register_args(), ALEX).unwrap();
        // Someone else's client with this phone's id in its label, another phone of the
        // owner, and a client with no device id: the ones `push_presence` answers
        // `registered: false`. None of them pauses the phone.
        let others = [app("a1b2c3d4", Some(SAM)), app("a1b2c3d4", Some("peer:12345")), app("ffff0000", Some(ALEX)), Requester { client_id: "client:mac".into(), label: "rex".into(), identity: Some(ALEX.into()) }];
        for other in &others {
            assert_eq!(r.act(&s, "push_presence", &json!({"active": false}), other).await.0.unwrap(), json!({"registered": false}), "{other:?}");
            assert_eq!(set_paused(&r, other, true).await, Err(not_registered.clone()), "{other:?}");
            assert!(!paused(&r, "a1b2c3d4"), "{other:?}");
        }
        // A client the server did not identify is refused before that.
        assert_eq!(set_paused(&r, &app("a1b2c3d4", None), true).await.unwrap_err()["code"], "refused");
        // Nor do they resume a phone its owner paused.
        assert_eq!(set_paused(&r, &alex, true).await, Ok(json!({"paused": true, "registered": true})));
        for other in &others {
            assert_eq!(set_paused(&r, other, false).await, Err(not_registered.clone()), "{other:?}");
        }
        assert!(paused(&r, "a1b2c3d4"));
        // The argument is a boolean and it is required.
        for args in [json!({}), json!({"paused": "true"}), json!({"paused": 1}), json!({"paused": null})] {
            assert_eq!(r.act(&s, "set_push_paused", &args, &alex).await.0.unwrap_err()["code"], "bad_request", "{args}");
        }
        assert!(paused(&r, "a1b2c3d4"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_paused_phone_gets_no_test_notification() {
        let dir = temp("pause-test");
        let (base, seen) = serve(vec![canned(200, "{}")]).await;
        let r = relay_with(&dir, false, Sender::Gateway, &[&base]);
        r.store.lock().unwrap().register(phone("a1b2c3d4", &base)).unwrap();
        let s = named_server("https://rex.example.ts.net");
        let alex = app("a1b2c3d4", Some(ALEX));
        set_paused(&r, &alex, true).await.unwrap();
        let e = send_test(&r, &s, &alex).await.unwrap_err();
        assert_eq!(e, json!({"code": "paused", "message": "Notifications from this computer are paused on this phone."}));
        // The gateway was not asked, and the phone's one test of these ten seconds is unused.
        assert!(seen.lock().unwrap().is_empty());
        assert!(r.tests.lock().unwrap().is_empty());
        set_paused(&r, &alex, false).await.unwrap();
        assert_eq!(send_test(&r, &s, &alex).await, Ok(json!({"sent": true})));
        assert_eq!(seen.lock().unwrap().len(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn registering_again_keeps_a_pause_for_the_same_secret_and_ends_it_for_a_new_one() {
        let dir = temp("pause-register");
        let r = relay(&dir, true);
        let alex = app("a1b2c3d4", Some(ALEX));
        let with = |secret: &str, paused: Option<bool>| {
            let mut args = register_args();
            args["push_secret"] = json!(secret);
            if let Some(p) = paused {
                args["paused"] = json!(p);
            }
            args
        };
        let usual = json!({"registered": true, "devices": 1, "push_enabled": false, "helper_version": VERSION});
        // A first registration is not paused.
        assert_eq!(register(&r, &with(SECRET, None), ALEX).unwrap(), usual);
        assert!(!paused(&r, "a1b2c3d4"));
        // The same secret again, as the app sends it after every connect: the pause stays.
        set_paused(&r, &alex, true).await.unwrap();
        assert_eq!(register(&r, &with(SECRET, None), ALEX).unwrap(), usual);
        assert!(paused(&r, "a1b2c3d4"));
        assert_eq!(devices(&r)[0].push_secret, SECRET);
        // A new secret is stored and the phone is resumed.
        assert_eq!(register(&r, &with(NEW_SECRET, None), ALEX).unwrap(), usual);
        assert!(!paused(&r, "a1b2c3d4"));
        assert_eq!(devices(&r)[0].push_secret, NEW_SECRET);
        // `paused` in the call sets the value at once: with the same secret, with a new
        // one, and for a phone that was not registered.
        assert_eq!(register(&r, &with(NEW_SECRET, Some(true)), ALEX).unwrap(), usual);
        assert!(paused(&r, "a1b2c3d4"));
        assert_eq!(register(&r, &with(NEW_SECRET, Some(false)), ALEX).unwrap(), usual);
        assert!(!paused(&r, "a1b2c3d4"));
        assert_eq!(register(&r, &with(SECRET, Some(true)), ALEX).unwrap(), usual);
        assert!(paused(&r, "a1b2c3d4"));
        assert_eq!(devices(&r)[0].push_secret, SECRET);
        assert_eq!(r.unregister(&json!({"device_id": "a1b2c3d4"}), &alex, ALEX), Ok(json!({"removed": true})));
        assert_eq!(register(&r, &with(SECRET, Some(true)), ALEX).unwrap(), usual);
        assert!(paused(&r, "a1b2c3d4"));
        // A registration after an unregister starts resumed, like a first one.
        assert_eq!(r.unregister(&json!({"device_id": "a1b2c3d4"}), &alex, ALEX), Ok(json!({"removed": true})));
        assert_eq!(register(&r, &with(SECRET, None), ALEX).unwrap(), usual);
        assert!(!paused(&r, "a1b2c3d4"));
        // The value is on disk each time, and anything but a boolean is refused whole.
        set_paused(&r, &alex, true).await.unwrap();
        assert!(DeviceStore::open(dir.join("devices.json")).devices[0].paused);
        let mut bad = with(NEW_SECRET, None);
        bad["paused"] = json!("yes");
        assert_eq!(register(&r, &bad, ALEX).unwrap_err()["code"], "bad_request");
        assert_eq!((devices(&r)[0].push_secret.as_str(), paused(&r, "a1b2c3d4")), (SECRET, true));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn helper_status_says_whether_the_callers_phone_is_paused() {
        let dir = temp("pause-status");
        let r = relay(&dir, true);
        let (alex, other, sam) = (app("a1b2c3d4", Some(ALEX)), app("ffff0000", Some(ALEX)), app("a1b2c3d4", Some(SAM)));
        let no_phone = Requester { client_id: "client:mac".into(), label: "rex".into(), identity: Some(ALEX.into()) };
        // No registration: not paused.
        assert_eq!(status(&r, &alex).await["paused"], false);
        register(&r, &register_args(), ALEX).unwrap();
        assert_eq!(status(&r, &alex).await["paused"], false);
        set_paused(&r, &alex, true).await.unwrap();
        let answer = status(&r, &alex).await;
        assert_eq!((&answer["paused"], &answer["registered"], &answer["devices"]), (&json!(true), &json!(true), &json!(1)));
        // Only for that phone, and only for the identity it is registered to.
        for who in [&other, &sam, &no_phone] {
            let answer = status(&r, who).await;
            assert_eq!((&answer["paused"], &answer["registered"]), (&json!(false), &json!(false)), "{who:?}");
        }
        set_paused(&r, &alex, false).await.unwrap();
        assert_eq!(status(&r, &alex).await["paused"], false);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn pausing_one_phone_leaves_the_others_on_the_helper_receiving() {
        const NAME: &str = "https://rex.example.ts.net";
        let dir = temp("pause-other");
        let (base, seen) = serve(vec![canned(200, "{}")]).await;
        let r = relay_watching(vec![None], &dir, false, Sender::Gateway, &[&base]);
        r.servers[0].st.lock().unwrap().name = NAME.into();
        for id in ["a1b2c3d4", "ffff0000"] {
            r.store.lock().unwrap().register(phone(id, &base)).unwrap();
        }
        let (alex, other) = (app("a1b2c3d4", Some(ALEX)), app("ffff0000", Some(ALEX)));
        set_paused(&r, &alex, true).await.unwrap();
        assert_eq!((paused(&r, "a1b2c3d4"), paused(&r, "ffff0000")), (true, false));
        r.clone().dispatch(agent_event(NAME)).await;
        // One request, with the other phone's secret.
        {
            let seen = seen.lock().unwrap();
            assert_eq!(seen.len(), 1);
            assert_eq!(seen[0].header("authorization"), Some(format!("Bearer {SECRET}ffff0000").as_str()));
        }
        assert_eq!(status(&r, &alex).await["last_push_at"], Value::Null);
        assert!(status(&r, &other).await["last_push_at"].is_i64());
        assert_eq!(status(&r, &other).await["paused"], false);
        // The other phone's test goes out as well; the paused one's does not.
        let s = named_server(NAME);
        assert_eq!(send_test(&r, &s, &other).await, Ok(json!({"sent": true})));
        assert_eq!(send_test(&r, &s, &alex).await.unwrap_err()["code"], "paused");
        assert_eq!(seen.lock().unwrap().len(), 2);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn each_phone_is_notified_with_its_own_secret_only() {
        const NAME: &str = "https://rex.example.ts.net";
        let dir = temp("own-secret");
        let (base, seen) = serve(vec![canned(200, "{}")]).await;
        let r = relay_watching(vec![None], &dir, false, Sender::Gateway, &[&base]);
        r.servers[0].st.lock().unwrap().name = NAME.into();
        let (first, second) = (Device::new("a1b2c3d4", &base, SECRET, "sandbox", ALEX), Device::new("ffff0000", &base, NEW_SECRET, "sandbox", SAM));
        for d in [&first, &second] {
            r.store.lock().unwrap().register(d.clone()).unwrap();
        }
        let bearers = || -> Vec<String> { seen.lock().unwrap().iter().map(|q| q.header("authorization").unwrap().to_string()).collect() };

        // One agent event: one request per phone, each with the secret that phone registered.
        r.clone().dispatch(agent_event(NAME)).await;
        assert_eq!(bearers(), [format!("Bearer {}", first.push_secret), format!("Bearer {}", second.push_secret)]);
        for (q, (own, other)) in seen.lock().unwrap().iter().zip([(&first, &second), (&second, &first)]) {
            let sent = format!("{:?}{}", q.headers, String::from_utf8_lossy(&q.body));
            assert!(sent.contains(&own.push_secret) && !sent.contains(&other.push_secret), "the request for #{}", own.device_id);
        }

        // With the first phone paused, the next event is one request, with the second's secret.
        set_paused(&r, &app("a1b2c3d4", Some(ALEX)), true).await.unwrap();
        r.clone().dispatch(agent_event(NAME)).await;
        let all = bearers();
        assert_eq!(all.len(), 3);
        assert_eq!(all[2], format!("Bearer {}", second.push_secret));
        let last = seen.lock().unwrap()[2].clone();
        assert!(!format!("{:?}{}", last.headers, String::from_utf8_lossy(&last.body)).contains(&first.push_secret));
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// devices.json in a state folder that can't be written: no change is answered as made,
    /// and the helper keeps the registrations the file has.
    #[cfg(unix)]
    #[tokio::test]
    async fn a_change_that_could_not_be_saved_is_refused_and_nothing_changes() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temp("not-saved");
        let r = relay(&dir, true);
        let alex = app("a1b2c3d4", Some(ALEX));
        register(&r, &register_args(), ALEX).unwrap();
        let file = dir.join("devices.json");
        let on_disk = || std::fs::read(&file).unwrap();
        let before = on_disk();
        let lock = |mode: u32| std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(mode)).unwrap();
        let not_saved = json!({"code": "not_saved", "message": concat!(crate::beacon_name!(), " couldn't save that. Try again.")});

        lock(0o500);
        // A pause.
        assert_eq!(set_paused(&r, &alex, true).await, Err(not_saved.clone()));
        assert!(!paused(&r, "a1b2c3d4"));
        assert_eq!(status(&r, &alex).await["paused"], false);
        // A registration that sets the pause, and one of a second phone.
        let mut pausing = register_args();
        pausing["paused"] = json!(true);
        assert_eq!(register(&r, &pausing, ALEX), Err(not_saved.clone()));
        assert!(!paused(&r, "a1b2c3d4"));
        let mut second = register_args();
        second["device_id"] = json!("ffff0000");
        second["push_secret"] = json!(NEW_SECRET);
        assert_eq!(r.register(&second, &app("ffff0000", Some(ALEX)), ALEX), Err(not_saved.clone()));
        assert_eq!(devices(&r).len(), 1);
        // Taking the phone out.
        assert_eq!(r.unregister(&json!({"device_id": "a1b2c3d4"}), &alex, ALEX), Err(not_saved.clone()));
        assert_eq!(devices(&r).len(), 1);
        assert_eq!(on_disk(), before);

        // Writable again: the same requests go through.
        lock(0o700);
        assert_eq!(set_paused(&r, &alex, true).await, Ok(json!({"paused": true, "registered": true})));
        assert!(paused(&r, "a1b2c3d4"));
        assert_ne!(on_disk(), before);
        assert_eq!(r.unregister(&json!({"device_id": "a1b2c3d4"}), &alex, ALEX), Ok(json!({"removed": true})));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn helper_status_counts_the_phones_someone_else_registered() {
        let dir = temp("other-phones");
        let r = relay(&dir, true);
        let (alex, sam) = (app("a1b2c3d4", Some(ALEX)), app("ffff0000", Some(SAM)));
        assert_eq!(status(&r, &alex).await["other_phones"], 0);
        // Alex registers two phones, Sam one.
        let phone = |id: &str, secret: &str| {
            let mut args = register_args();
            args["device_id"] = json!(id);
            args["push_secret"] = json!(secret);
            args
        };
        register(&r, &register_args(), ALEX).unwrap();
        assert_eq!(r.register(&phone("0000aaaa", &"B".repeat(43)), &app("0000aaaa", Some(ALEX)), ALEX).map(|v| v["devices"].clone()), Ok(json!(2)));
        assert_eq!(r.register(&phone("ffff0000", NEW_SECRET), &sam, SAM).map(|v| v["devices"].clone()), Ok(json!(3)));
        // Each sees the phones that are not theirs; someone with none sees all of them.
        for (who, others) in [(&alex, 1), (&sam, 2), (&app("00000000", Some("tailscale:1")), 3)] {
            let answer = status(&r, who).await;
            assert_eq!((&answer["devices"], &answer["other_phones"]), (&json!(3), &json!(others)), "{who:?}");
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    // MARK: Desk presence

    const DESK_SERVER: &str = "https://rex.example.ts.net";
    const T0: f64 = 1_800_000_000.0;
    /// Thirty-two bytes 0..32, as base64url: Alex's phone's presence key.
    const PRESENCE_KEY: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
    type SeenLog = Arc<Mutex<Vec<crate::net::testing::Seen>>>;

    fn moment(s: f64) -> Moment {
        Moment { wall: T0 + s, mono: Some(s) }
    }

    /// A relay that watches one server, `DESK_SERVER`, with Alex's phone registered at a test
    /// gateway that answers `answers`, and a computer the test controls.
    async fn desk_relay(tag: &str, answers: Vec<crate::net::testing::Canned>) -> (Arc<Relay>, Arc<TestSense>, SeenLog, PathBuf) {
        let dir = temp(tag);
        let (base, seen) = serve(answers).await;
        let sense = Arc::new(TestSense::default());
        let r = relay_sensing(vec![None], &dir, false, Sender::Gateway, &[&base], sense.clone());
        r.servers[0].st.lock().unwrap().name = DESK_SERVER.into();
        r.store.lock().unwrap().register(phone("a1b2c3d4", &base)).unwrap();
        (r, sense, seen, dir)
    }

    /// `desk_relay`, with Alex's phone holding its presence key.
    async fn keyed_relay(tag: &str, answers: Vec<crate::net::testing::Canned>) -> (Arc<Relay>, Arc<TestSense>, SeenLog, PathBuf) {
        let (r, sense, seen, dir) = desk_relay(tag, answers).await;
        let mut d = devices(&r)[0].clone();
        d.presence_key = Some(PRESENCE_KEY.into());
        r.store.lock().unwrap().register(d).unwrap();
        (r, sense, seen, dir)
    }

    /// The same helper started again on the same folder, as after a restart.
    fn restarted(dir: &std::path::Path, base: &str) -> Arc<Relay> {
        let r = relay_sensing(vec![None], dir, false, Sender::Gateway, &[base], Arc::new(TestSense::default()));
        r.servers[0].st.lock().unwrap().name = DESK_SERVER.into();
        r
    }

    fn desk_event(category: PushCategory, record: &str) -> PushIntent {
        let mut i = PushIntent::new(category, BlockRef { server: DESK_SERVER.into(), session_id: "session:1".into(), block_id: "block:b1".into() });
        i.agent = Some("claude".into());
        i.text = Some("Which database?".into());
        if category != PushCategory::Notice {
            i.record_id = Some(record.into());
            i.state = Some(if category == PushCategory::Blocked { "blocked" } else { "done" }.into());
        }
        i
    }

    /// The agent's server as it lists its app clients: the MacBook's Rex app (bridged here
    /// through SSH, so not this computer's desk) and Alex's phone.
    fn desk_clients() -> Vec<ClientSnapshot> {
        vec![
            ClientSnapshot {
                client_id: "client:mac".into(),
                kind: Some("app".into()),
                platform: Some("macos".into()),
                label: Some("MBP_M4MAX".into()),
                connection_state: Some("connected".into()),
                pid: Some(4242),
                ..Default::default()
            },
            ClientSnapshot {
                client_id: "client:a1b2c3d4".into(),
                kind: Some("app".into()),
                platform: Some("ios".into()),
                label: Some("Alex's iPhone #a1b2c3d4".into()),
                connection_state: Some("connected".into()),
                ..Default::default()
            },
        ]
    }

    fn mac_tag() -> String {
        PresenceKey::parse(PRESENCE_KEY).unwrap().tag("MBP_M4MAX")
    }

    async fn desk_push(r: &Arc<Relay>, i: &PushIntent, here: bool, clients: &[ClientSnapshot], at: Moment) {
        desk_push_on(r, i, here, clients, &[], at).await;
    }

    /// `desk_push`, for an event whose server lists `on_server`.
    async fn desk_push_on(r: &Arc<Relay>, i: &PushIntent, here: bool, clients: &[ClientSnapshot], on_server: &[ClientSnapshot], at: Moment) {
        let msg = PushMessage::compose(i, &BlockContext::default());
        r.deliver(i, &msg, devices(r), clients, on_server, here, at).await;
    }

    fn bodies(seen: &SeenLog) -> Vec<Value> {
        seen.lock().unwrap().iter().map(|q| serde_json::from_slice(&q.body).unwrap()).collect()
    }

    fn held(r: &Relay) -> usize {
        r.holds.lock().unwrap().parked().len()
    }

    /// Waits for `n` requests, a second at most.
    async fn requests(seen: &SeenLog, n: usize) -> usize {
        for _ in 0..100 {
            if seen.lock().unwrap().len() >= n {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        seen.lock().unwrap().len()
    }

    const HELD: &str = r#"{"held":true,"retry_after":60}"#;

    #[tokio::test]
    async fn without_a_presence_key_a_push_names_no_desk_and_is_stacked_per_server() {
        let (r, _, seen, dir) = desk_relay("desk-no-key", vec![canned(200, "{}")]).await;
        // What a phone app that sends no presence key gets, whatever desks show the server.
        desk_push_on(&r, &desk_event(PushCategory::Blocked, ""), false, &[], &desk_clients(), moment(0.0)).await;
        desk_push_on(&r, &desk_event(PushCategory::Notice, ""), false, &[], &desk_clients(), moment(1.0)).await;
        let sent = bodies(&seen);
        assert_eq!(sent.len(), 2);
        assert_eq!(sent[0]["payload"]["aps"]["thread-id"], DESK_SERVER);
        assert_eq!(sent[1]["collapse_id"], "b1-n");
        for b in &sent {
            assert!(b.get("hold_if_desk").is_none());
            let mut keys: Vec<&str> = b.as_object().unwrap().keys().map(String::as_str).collect();
            keys.sort();
            assert_eq!(keys, ["collapse_id", "expiration", "payload", "priority", "push_type"]);
        }
        // No lease is written for it either, and nothing of the desk switch is left.
        r.lease_tick(false).await;
        assert_eq!(seen.lock().unwrap().len(), 2);
        assert!(!dir.join("desk.json").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_fresh_push_names_the_desks_that_show_its_server_under_the_phones_key() {
        let (r, _, seen, dir) = keyed_relay("desk-tags", vec![canned(200, "{}")]).await;
        desk_push_on(&r, &desk_event(PushCategory::Blocked, "r1"), false, &[], &desk_clients(), moment(0.0)).await;
        let sent = bodies(&seen);
        assert_eq!(sent[0]["hold_if_desk"], json!([mac_tag()]));
        // A server no desk shows: no field.
        desk_push_on(&r, &desk_event(PushCategory::Notice, ""), false, &[], &desk_clients()[1..], moment(1.0)).await;
        assert!(bodies(&seen)[1].get("hold_if_desk").is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_question_the_gateway_holds_waits_takes_no_rate_limit_and_goes_when_a_probe_is_sent() {
        let mut answers: Vec<_> = (0..12).map(|_| canned(202, HELD)).collect();
        answers.extend([canned(200, "{}"), canned(200, "{}")]);
        let (r, _, seen, dir) = keyed_relay("desk-remote", answers).await;
        // Twelve questions, more than the burst of ten: holding uses up no allowance.
        for n in 0..12 {
            let mut q = desk_event(PushCategory::Blocked, "r1");
            q.block.block_id = format!("block:{n}");
            desk_push_on(&r, &q, false, &[], &desk_clients(), Moment::now()).await;
        }
        assert_eq!((seen.lock().unwrap().len(), held(&r)), (12, 12));
        assert!(r.holds.lock().unwrap().parked().iter().all(|p| p.remote));
        assert!(r.limiter.lock().unwrap().allow("a1b2c3d4", now()), "the tokens were given back");
        // This computer's desk plays no part, and nothing is due before its cap.
        assert!(r.holds.lock().unwrap().due(Moment::now(), |_| true).is_empty());
        // A minute on, the oldest is asked about again. Its server can't be asked here, so it
        // names no desk and goes; then the phone's other questions of that server go too.
        let minute_ago = Moment { wall: now() - 61.0, mono: Some(crate::desk::mono() - 61.0) };
        r.holds.lock().unwrap().asked("a1b2c3d4", DESK_SERVER, minute_ago);
        r.probe_held(&[]).await;
        let sent = bodies(&seen);
        // The probe, then the others as far as the allowance goes (the test took one token
        // above): the three left wait for the next look.
        assert_eq!(sent.len(), 12 + 9);
        assert!(sent[12..].iter().all(|b| b.get("hold_if_desk").is_none()));
        assert_eq!(held(&r), 3);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_probe_held_again_keeps_the_question_and_its_wait() {
        let (r, _, seen, dir) = keyed_relay("desk-probe", vec![canned(202, HELD), canned(202, HELD), canned(200, "{}")]).await;
        let q = desk_event(PushCategory::Blocked, "r1");
        let first = Moment::now();
        desk_push_on(&r, &q, false, &[], &desk_clients(), first).await;
        assert_eq!(held(&r), 1);
        let d = devices(&r)[0].clone();
        let m = PushMessage::compose(&q, &BlockContext::default()).stacked();
        let again = r.send_one(&d, &q, &m, SendKind::Probe, &desk_clients(), Moment::now()).await;
        assert_eq!(again, SendResult::Held(60));
        assert_eq!(bodies(&seen)[1]["hold_if_desk"], json!([mac_tag()]), "a probe names the desk again");
        assert_eq!((held(&r), r.holds.lock().unwrap().parked()[0].parked_at), (1, first.wall));
        // Sent: nobody is at that desk now.
        assert!(matches!(r.send_one(&d, &q, &m, SendKind::Probe, &desk_clients(), Moment::now()).await, SendResult::Sent(_)));
        assert_eq!(held(&r), 0);
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A question as the policy makes it from a report: it names its wait.
    fn desk_question(record: &str, text: &str) -> PushIntent {
        let mut q = desk_event(PushCategory::Blocked, record);
        q.text = Some(text.into());
        q.fp = Some(crate::policy::fingerprint("blocked", None, Some(text)));
        q
    }

    #[tokio::test]
    async fn a_question_held_at_the_desk_goes_later_with_the_wait_it_is_about() {
        let (r, _, seen, dir) = keyed_relay("desk-wait-kept", vec![canned(200, "{}")]).await;
        let q = desk_question("claude", "Which database?");
        desk_push_on(&r, &q, true, &[], &desk_clients(), moment(0.0)).await;
        assert_eq!((seen.lock().unwrap().len(), held(&r)), (0, 1));
        // The helper restarts meanwhile: the question is read back from parked.json.
        *r.holds.lock().unwrap() = crate::hold::Holds::load(Some(&dir));
        let due = r.holds.lock().unwrap().due(moment(HOLD_CAP_TEST), |_| false);
        assert_eq!(due.len(), 1);
        r.send_held(due, &[]).await;
        let sent = bodies(&seen);
        assert_eq!(sent.len(), 1);
        assert_eq!(gateway_problem(&sent[0], now() as i64), None);
        let p = &sent[0]["payload"];
        assert_eq!((&p["aps"]["category"], &p["record"], &p["fp"]), (&json!("AGENT_BLOCKED_ACT"), &json!("claude"), &json!(q.fp)));
        assert_eq!(p["aps"]["alert"]["body"], "Which database?");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_question_the_gateway_held_goes_on_a_probe_with_the_wait_it_is_about() {
        let (r, _, seen, dir) = keyed_relay("desk-wait-probe", vec![canned(202, HELD), canned(200, "{}"), canned(200, "{}")]).await;
        let first = desk_question("claude", "Which database?");
        let mut second = desk_question("codex", "Run it?");
        second.block.block_id = "block:b2".into();
        desk_push_on(&r, &first, false, &[], &desk_clients(), Moment::now()).await;
        // The second is parked beside it without a request of its own.
        assert!(r.holds.lock().unwrap().park_remote("a1b2c3d4", &second, Moment::now()));
        assert_eq!((seen.lock().unwrap().len(), held(&r)), (1, 2));
        let minute_ago = Moment { wall: now() - 61.0, mono: Some(crate::desk::mono() - 61.0) };
        r.holds.lock().unwrap().asked("a1b2c3d4", DESK_SERVER, minute_ago);
        // The probe goes (this server can't be asked, so it names no desk), then the other.
        r.probe_held(&[]).await;
        let sent = bodies(&seen);
        assert_eq!((sent.len(), held(&r)), (3, 0));
        let mut waits: Vec<(String, String)> = sent.iter().map(|b| (b["payload"]["record"].as_str().unwrap_or("").to_string(), b["payload"]["fp"].as_str().unwrap_or("").to_string())).collect();
        assert_eq!(waits[0], ("claude".to_string(), first.fp.clone().unwrap()), "the first send named it too");
        waits.remove(0);
        waits.sort();
        assert_eq!(waits, [("claude".to_string(), first.fp.clone().unwrap()), ("codex".to_string(), second.fp.clone().unwrap())]);
        for b in &sent {
            assert_eq!(b["payload"]["aps"]["category"], "AGENT_BLOCKED_ACT");
            assert_eq!(gateway_problem(b, now() as i64), None);
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// Every field at the most the gateway takes, in characters of four bytes where a field
    /// holds text: the payload stays within Apple's limit, and only the body gives way.
    #[test]
    fn the_largest_question_fits_the_limit_and_the_gateway_takes_it() {
        let mut q = PushIntent::new(PushCategory::Blocked, BlockRef { server: format!("https://{}", "h".repeat(504)), session_id: format!("session:{}", "s".repeat(248)), block_id: format!("block:{}", "b".repeat(250)) });
        q.state = Some("blocked".into());
        q.record_id = Some("r".repeat(128));
        q.agent = Some("🦖".repeat(200));
        q.text = Some("🦖".repeat(5000));
        q.fp = Some(crate::policy::fingerprint("blocked", None, q.text.as_deref()));
        let ctx = BlockContext { window_id: Some(format!("window:{}", "w".repeat(249))), tab_label: Some("🦖".repeat(200)), block_label: None, session_label: Some("🦖".repeat(256)) };
        let size = |m: &PushMessage| m.payload().to_string().len();
        let mut largest = 0;
        for body in ["🦖".repeat(5000), "\u{1}".repeat(5000), "\"".repeat(5000), "x".repeat(5000), "é".repeat(999)] {
            q.text = Some(body);
            for m in [PushMessage::compose(&q, &ctx), PushMessage::compose(&q, &ctx).stacked()] {
                let p = m.payload();
                assert!(size(&m) <= crate::push::MAX_PAYLOAD_BYTES, "{}", size(&m));
                largest = largest.max(size(&m));
                assert_eq!(gateway_problem(&crate::gateway::push_body(&m, 1000.0), 1000), None);
                assert_eq!((p["server"].as_str().unwrap().len(), p["session_id"].as_str().unwrap().len(), p["window_id"].as_str().unwrap().len(), p["block_id"].as_str().unwrap().len()), (512, 256, 256, 256));
                assert_eq!((p["aps"]["alert"]["title"].as_str().unwrap().chars().count(), p["aps"]["alert"]["subtitle"].as_str().unwrap().chars().count()), (120, 256));
                assert_eq!((p["record"].as_str().unwrap().len(), p["fp"].as_str().unwrap().len(), &p["aps"]["category"]), (128, 16, &json!("AGENT_BLOCKED_ACT")));
                assert!(!p["aps"]["alert"]["body"].as_str().unwrap().is_empty());
            }
        }
        // The fields beside the body leave it room, and the cut uses the room there is.
        assert!(largest > crate::push::MAX_PAYLOAD_BYTES - 8, "{largest}");
        println!("largest payload: {largest} bytes");
    }

    #[tokio::test]
    async fn the_cap_send_of_a_question_held_elsewhere_names_no_desk() {
        let (r, _, seen, dir) = keyed_relay("desk-remote-cap", vec![canned(202, HELD), canned(200, "{}")]).await;
        desk_push_on(&r, &desk_event(PushCategory::Blocked, "r1"), false, &[], &desk_clients(), short_of_cap(0.0)).await;
        let due = r.holds.lock().unwrap().due(Moment::now(), |_| false);
        assert_eq!(due.iter().map(|(_, k)| *k).collect::<Vec<_>>(), [SendKind::Cap]);
        r.send_held(due, &[]).await;
        let sent = bodies(&seen);
        assert_eq!(sent.len(), 2);
        assert!(sent[1].get("hold_if_desk").is_none());
        assert_eq!(held(&r), 0);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_done_or_notice_held_elsewhere_is_dropped_and_a_done_replacing_a_question_is_never_held() {
        let (r, _, seen, dir) = keyed_relay("desk-remote-drop", vec![canned(202, HELD), canned(202, HELD), canned(200, "{}"), canned(200, "{}")]).await;
        capture_log();
        desk_push_on(&r, &desk_event(PushCategory::Done, "r0"), false, &[], &desk_clients(), moment(0.0)).await;
        desk_push_on(&r, &desk_event(PushCategory::Notice, ""), false, &[], &desk_clients(), moment(1.0)).await;
        assert_eq!((seen.lock().unwrap().len(), held(&r)), (2, 0));
        assert!(captured_log().contains("no AGENT_DONE to #a1b2c3d4: at a desk elsewhere"), "{}", captured_log());
        // The question goes (nobody at a desk then); the done that follows at a desk elsewhere
        // replaces it under its collapse id and names no desk.
        desk_push_on(&r, &desk_event(PushCategory::Blocked, "r1"), false, &[], &desk_clients(), moment(2.0)).await;
        let question = bodies(&seen)[2]["collapse_id"].clone();
        assert!(bodies(&seen)[2].get("hold_if_desk").is_some());
        desk_push_on(&r, &desk_event(PushCategory::Done, "r1"), false, &[], &desk_clients(), moment(3.0)).await;
        let sent = bodies(&seen);
        assert_eq!(sent.len(), 4);
        assert_eq!((&sent[3]["collapse_id"], &sent[3]["payload"]["aps"]["category"]), (&question, &json!("AGENT_DONE")));
        assert!(sent[3].get("hold_if_desk").is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn an_old_gateway_ignores_the_field_and_every_push_goes_as_before() {
        // A gateway from before presence answers 200 whatever the body holds.
        let (r, _, seen, dir) = keyed_relay("desk-old-gateway", vec![canned(200, r#"{"apns_id":"x"}"#)]).await;
        desk_push_on(&r, &desk_event(PushCategory::Blocked, "r1"), false, &[], &desk_clients(), moment(0.0)).await;
        assert_eq!((seen.lock().unwrap().len(), held(&r)), (1, 0));
        std::fs::remove_dir_all(dir).unwrap();
    }

    fn at_the_desk() -> crate::desk::Reading {
        crate::desk::Reading { idle: Some(3.0), session: Some(crate::desk::Session { locked: false, on_console: true }), display_asleep: Some(false) }
    }

    fn lease_bodies(seen: &SeenLog) -> Vec<(String, Value)> {
        seen.lock().unwrap().iter().filter(|q| q.path == "/v1/presence").map(|q| (q.method.clone(), serde_json::from_slice(&q.body).unwrap())).collect()
    }

    #[tokio::test]
    async fn a_desk_here_is_leased_while_someone_is_at_it_and_removed_on_leaving_or_sleep() {
        let stored = || canned(200, r#"{"stored":true}"#);
        let (r, sense, seen, dir) = keyed_relay("desk-leases", vec![stored(), stored(), stored(), stored()]).await;
        capture_log();
        // Nobody here yet, or no desktop app here: nothing is read or written.
        *r.labels_in_test.lock().unwrap() = Some(vec!["MBP_M4MAX".into()]);
        r.lease_tick(false).await;
        assert!(seen.lock().unwrap().is_empty());
        // At the desk: one lease, of this desk, for ten minutes.
        *sense.reading.lock().unwrap() = at_the_desk();
        r.lease_tick(false).await;
        assert_eq!(lease_bodies(&seen), [("PUT".to_string(), json!({"desk": mac_tag(), "ttl": 600}))]);
        // The next looks, within five minutes: nothing new.
        r.lease_tick(false).await;
        assert_eq!(seen.lock().unwrap().len(), 1);
        // Locked: removed at once.
        *sense.reading.lock().unwrap() = crate::desk::Reading { session: Some(crate::desk::Session { locked: true, on_console: true }), ..at_the_desk() };
        r.lease_tick(false).await;
        assert_eq!(lease_bodies(&seen)[1].1, json!({"desk": mac_tag(), "ttl": 0}));
        // Back, then the computer goes to sleep: removed before sleep is allowed.
        *sense.reading.lock().unwrap() = at_the_desk();
        r.lease_tick(false).await;
        r.lease_tick(true).await;
        let all = lease_bodies(&seen);
        assert_eq!((all.len(), all[3].1["ttl"].clone()), (4, json!(0)));
        let log = captured_log();
        assert!(log.contains("desk lease for #a1b2c3d4: present") && log.contains("desk lease for #a1b2c3d4: removed"), "{log}");
        assert!(!log.contains(PRESENCE_KEY) && !log.contains(&mac_tag()) && !log.contains("MBP_M4MAX"), "{log}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_gateway_that_takes_no_lease_or_has_no_presence_is_left_alone() {
        let (r, sense, seen, dir) = keyed_relay("desk-lease-refused", vec![canned(200, r#"{"stored":false}"#), canned(404, r#"{"error":"not_found"}"#)]).await;
        *r.labels_in_test.lock().unwrap() = Some(vec!["MBP_M4MAX".into()]);
        *sense.reading.lock().unwrap() = at_the_desk();
        r.lease_tick(false).await;
        r.lease_tick(false).await;
        assert_eq!(seen.lock().unwrap().len(), 1, "not stored: no more until the phone registers again");
        // It registers again (the app calls register_push), and is asked once more: a 404.
        r.leases.lock().unwrap().registered("a1b2c3d4");
        r.lease_tick(false).await;
        r.lease_tick(false).await;
        assert_eq!(seen.lock().unwrap().len(), 2, "no presence at that gateway: asked again in a day");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_registration_keeps_a_presence_key_only_when_it_is_one_and_never_logs_it() {
        let dir = temp("presence-key");
        capture_log();
        let r = relay(&dir, false);
        let mut args = register_args();
        args["presence_key"] = json!(PRESENCE_KEY);
        register(&r, &args, ALEX).unwrap();
        assert_eq!(devices(&r)[0].presence_key.as_deref(), Some(PRESENCE_KEY));
        assert!(std::fs::read_to_string(dir.join("devices.json")).unwrap().contains(PRESENCE_KEY));
        // An app that sends none (an old one, or a computer it doesn't count as its owner's).
        register(&r, &register_args(), ALEX).unwrap();
        assert_eq!(devices(&r)[0].presence_key, None);
        for bad in [json!("short"), json!(42), json!(format!("{PRESENCE_KEY}A"))] {
            let mut args = register_args();
            args["presence_key"] = bad.clone();
            assert_eq!(register(&r, &args, ALEX).unwrap()["registered"], true, "{bad}");
            assert_eq!(devices(&r)[0].presence_key, None, "{bad}");
        }
        let log = captured_log();
        assert!(log.contains("with desk presence"), "{log}");
        assert!(!log.contains(PRESENCE_KEY) && !format!("{:?}", devices(&r)).contains("presence_key"), "{log}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn at_the_desk_a_question_waits_for_the_cap_and_the_cap_send_is_never_holdable() {
        let (r, _, seen, dir) = keyed_relay("desk-cap", vec![canned(200, "{}")]).await;
        let q = desk_event(PushCategory::Blocked, "");
        desk_push_on(&r, &q, true, &[], &desk_clients(), moment(0.0)).await;
        assert_eq!((seen.lock().unwrap().len(), held(&r)), (0, 1));
        // Still there at the desk: nothing yet.
        assert!(r.holds.lock().unwrap().due(moment(HOLD_CAP_TEST - 1.0), |_| false).is_empty());
        let due = r.holds.lock().unwrap().due(moment(HOLD_CAP_TEST), |_| false);
        assert_eq!(due.iter().map(|(_, k)| *k).collect::<Vec<_>>(), [SendKind::Cap]);
        r.send_held(due, &[]).await;
        let sent = bodies(&seen);
        assert_eq!(sent.len(), 1);
        // The request carries what any push carries, and nothing that could hold it again.
        let mut keys: Vec<&str> = sent[0].as_object().unwrap().keys().map(String::as_str).collect();
        keys.sort();
        assert_eq!(keys, ["collapse_id", "expiration", "payload", "priority", "push_type"]);
        assert_eq!(sent[0]["payload"]["aps"]["category"], "AGENT_BLOCKED");
        assert_eq!(sent[0]["payload"]["aps"]["thread-id"], DESK_SERVER);
        // Once per episode.
        assert_eq!(held(&r), 0);
        assert!(r.holds.lock().unwrap().due(moment(HOLD_CAP_TEST * 4.0), |_| true).is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }

    const HOLD_CAP_TEST: f64 = crate::desk::HOLD_CAP;

    #[tokio::test]
    async fn when_the_desk_goes_a_held_question_goes_and_one_that_failed_is_tried_again() {
        let (r, _, seen, dir) = desk_relay("desk-away", vec![canned(500, "boom"), canned(200, "{}")]).await;
        desk_push(&r, &desk_event(PushCategory::Blocked, ""), true, &[], moment(0.0)).await;
        // The release looks the server's desk up; this one can't be asked, so it is away.
        assert!(r.release(None).await, "the send failed, so it is still held");
        assert_eq!((seen.lock().unwrap().len(), held(&r)), (1, 1));
        assert!(!r.release(None).await);
        assert_eq!((seen.lock().unwrap().len(), held(&r)), (2, 0));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn holding_takes_no_rate_limit_and_a_limited_release_stays_held() {
        let (r, _, seen, dir) = desk_relay("desk-limit", vec![canned(200, "{}")]).await;
        for n in 0..12 {
            let mut q = desk_event(PushCategory::Blocked, "");
            q.block.block_id = format!("block:{n}");
            desk_push(&r, &q, true, &[], moment(0.0)).await;
        }
        assert_eq!((seen.lock().unwrap().len(), held(&r)), (0, 12));
        let due = r.holds.lock().unwrap().due(moment(HOLD_CAP_TEST), |_| false);
        r.send_held(due, &[]).await;
        // Ten go now (the burst); the other two wait for the next look rather than being lost.
        assert_eq!((seen.lock().unwrap().len(), held(&r)), (10, 2));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn done_at_the_desk_replaces_the_question_the_phone_shows_even_after_a_restart() {
        let (r, _, seen, dir) = desk_relay("desk-replace", vec![canned(200, "{}")]).await;
        let base = r.store.lock().unwrap().devices[0].gateway.clone();
        // Away: the question goes, under its record's collapse id.
        desk_push(&r, &desk_event(PushCategory::Blocked, "r1"), false, &[], moment(0.0)).await;
        let question = bodies(&seen)[0]["collapse_id"].clone();
        assert!(question.is_string());
        // Beacon updates itself and starts again; the person answers at the desk.
        let r = restarted(&dir, &base);
        desk_push(&r, &desk_event(PushCategory::Done, "r2"), true, &[], moment(60.0)).await;
        let sent = bodies(&seen);
        assert_eq!(sent.len(), 2);
        assert_eq!(sent[1]["collapse_id"], question);
        assert_eq!(sent[1]["payload"]["aps"]["interruption-level"], "passive");
        assert_eq!(sent[1]["payload"]["aps"]["category"], "AGENT_DONE");
        // The phone shows "Finished" now: the next done at the desk adds nothing.
        desk_push(&r, &desk_event(PushCategory::Done, "r2"), true, &[], moment(120.0)).await;
        assert_eq!(seen.lock().unwrap().len(), 2);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn at_the_desk_notices_and_a_done_are_dropped_and_away_they_go_in_one_stack() {
        let (r, _, seen, dir) = desk_relay("desk-drop", vec![canned(200, "{}")]).await;
        desk_push(&r, &desk_event(PushCategory::Notice, ""), true, &[], moment(0.0)).await;
        desk_push(&r, &desk_event(PushCategory::Done, ""), true, &[], moment(1.0)).await;
        assert_eq!(seen.lock().unwrap().len(), 0);
        desk_push(&r, &desk_event(PushCategory::Notice, ""), false, &[], moment(2.0)).await;
        let sent = bodies(&seen);
        assert_eq!(sent[0]["payload"]["aps"]["thread-id"], DESK_SERVER);
        assert_eq!(sent[0]["collapse_id"], "b1-n");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn only_a_live_claim_counts_as_open() {
        let (r, _, seen, dir) = desk_relay("desk-claims", vec![canned(200, "{}")]).await;
        let ios = |state: &str| ClientSnapshot {
            client_id: "client:a1b2c3d4".into(),
            kind: Some("app".into()),
            platform: Some("ios".into()),
            label: Some("Alex's iPhone #a1b2c3d4".into()),
            connection_state: Some(state.into()),
            ..Default::default()
        };
        let alex = app("a1b2c3d4", Some(ALEX));
        let notice = desk_event(PushCategory::Notice, "");
        // Connected but never claimed (a phone in a pocket, a Beacon that restarted): pushed.
        desk_push(&r, &notice, false, &[ios("connected")], Moment::now()).await;
        assert_eq!(seen.lock().unwrap().len(), 1);
        let presence = |active: bool| {
            let (r, alex) = (r.clone(), alex.clone());
            async move { r.act(&r.servers[0], "push_presence", &json!({"active": active}), &alex).await }
        };
        assert_eq!(presence(true).await.0.unwrap(), json!({"registered": true}));
        desk_push(&r, &notice, false, &[ios("connected")], Moment::now()).await;
        assert_eq!(seen.lock().unwrap().len(), 1, "claimed: open");
        // (A claim's three minutes: devices.rs tests it, with the clock in hand.)
        // `active: false` ends it.
        presence(false).await.0.unwrap();
        desk_push(&r, &notice, false, &[ios("connected")], Moment::now()).await;
        assert_eq!(seen.lock().unwrap().len(), 2);
        // Seen lost at dispatch: removed, not only skipped.
        presence(true).await.0.unwrap();
        desk_push(&r, &notice, false, &[ios("lost")], Moment::now()).await;
        assert!(r.servers[0].st.lock().unwrap().claims.is_empty());
        desk_push(&r, &notice, false, &[ios("connected")], Moment::now()).await;
        assert_eq!(seen.lock().unwrap().len(), 4);
        // The client left.
        presence(true).await.0.unwrap();
        r.handle(&r.servers[0], json!({"type": "client_left", "payload": {"client_id": "client:a1b2c3d4"}}));
        assert!(r.servers[0].st.lock().unwrap().claims.is_empty());
        // A restart starts with no claim.
        presence(true).await.0.unwrap();
        let base = r.store.lock().unwrap().devices[0].gateway.clone();
        assert!(restarted(&dir, &base).servers[0].st.lock().unwrap().claims.is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn claims_and_their_renewals_leave_what_the_phone_shows_so_a_done_still_replaces_it() {
        let (r, _, seen, dir) = desk_relay("desk-renewed", vec![canned(200, "{}")]).await;
        capture_log();
        desk_push(&r, &desk_event(PushCategory::Blocked, ""), false, &[], moment(0.0)).await;
        let question = bodies(&seen)[0]["collapse_id"].clone();
        let alex = app("a1b2c3d4", Some(ALEX));
        for _ in 0..3 {
            r.act(&r.servers[0], "push_presence", &json!({"active": true}), &alex).await.0.unwrap();
        }
        r.act(&r.servers[0], "push_presence", &json!({"active": false}), &alex).await.0.unwrap();
        desk_push(&r, &desk_event(PushCategory::Done, ""), true, &[], moment(60.0)).await;
        let sent = bodies(&seen);
        assert_eq!(sent.len(), 2);
        assert_eq!((&sent[1]["collapse_id"], &sent[1]["payload"]["aps"]["category"]), (&question, &json!("AGENT_DONE")));
        // A renewal is no news: one line for the claim, one for the background.
        assert_eq!(captured_log().matches("presence from").count(), 2, "{}", captured_log());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn helper_status_says_nothing_of_a_desk_switch() {
        let (r, _, _, dir) = desk_relay("desk-status", vec![canned(200, "{}")]).await;
        for who in [app("a1b2c3d4", Some(ALEX)), app("ffff0000", Some(ALEX)), app("a1b2c3d4", Some(SAM))] {
            assert!(status(&r, &who).await.get("desk").is_none(), "{who:?}");
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_restart_keeps_what_is_held_and_rex_that_cant_be_asked_keeps_it_held() {
        let (r, _, seen, dir) = desk_relay("desk-restart", vec![canned(200, "{}")]).await;
        let base = r.store.lock().unwrap().devices[0].gateway.clone();
        desk_push(&r, &desk_event(PushCategory::Blocked, ""), true, &[], moment(0.0)).await;
        drop(r);
        let r = restarted(&dir, &base);
        assert_eq!(held(&r), 1);
        r.recheck_held(&r.servers[0]).await;
        assert_eq!((held(&r), seen.lock().unwrap().len()), (1, 0));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn an_agent_that_moves_on_holds_nothing_and_a_paused_phone_is_never_held_for() {
        let (r, _, seen, dir) = desk_relay("desk-moved-on", vec![canned(200, "{}")]).await;
        desk_push(&r, &desk_event(PushCategory::Blocked, "r1"), true, &[], moment(0.0)).await;
        let b = desk_event(PushCategory::Blocked, "r1").block;
        r.decide(RelayEvent::Status(b.clone(), StatusReport { record_id: "r1".into(), state: "working".into(), ..Default::default() }));
        assert_eq!(held(&r), 0);
        desk_push(&r, &desk_event(PushCategory::Blocked, "r1"), true, &[], moment(1.0)).await;
        r.decide(RelayEvent::StatusRemoved(b.clone(), vec!["r1".into()]));
        assert_eq!(held(&r), 0);
        desk_push(&r, &desk_event(PushCategory::Blocked, "r1"), true, &[], moment(2.0)).await;
        r.decide(RelayEvent::BlockClosed(b));
        assert_eq!(held(&r), 0);
        // Paused, at the desk or not: nothing composed, nothing held.
        let alex = app("a1b2c3d4", Some(ALEX));
        set_paused(&r, &alex, true).await.unwrap();
        desk_push(&r, &desk_event(PushCategory::Blocked, "r1"), true, &[], moment(3.0)).await;
        desk_push(&r, &desk_event(PushCategory::Blocked, "r2"), false, &[], moment(3.0)).await;
        assert_eq!((held(&r), seen.lock().unwrap().len()), (0, 0));
        // Held, then paused: the release drops it rather than send it.
        set_paused(&r, &alex, false).await.unwrap();
        desk_push(&r, &desk_event(PushCategory::Blocked, "r1"), true, &[], moment(4.0)).await;
        set_paused(&r, &alex, true).await.unwrap();
        assert!(!r.release(Some(SendKind::Away)).await);
        assert_eq!((held(&r), seen.lock().unwrap().len()), (0, 0));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn the_desk_counts_only_with_a_person_there_and_a_desktop_app_of_theirs_running_here() {
        let (r, sense, _, dir) = desk_relay("desk-here", vec![canned(200, "{}")]).await;
        capture_log();
        let me = crate::platform::user_id();
        sense.processes.lock().unwrap().extend([
            (100, crate::desk::Process { path: "/Applications/Rex.app/Contents/MacOS/Rex".into(), uid: me, ppid: 1, ..Default::default() }),
            (200, crate::desk::Process { path: "/Applications/Rex.app/Contents/MacOS/Rex".into(), uid: me, ppid: 4242, ..Default::default() }),
        ]);
        let mac = |pid: u32| ClientSnapshot {
            client_id: format!("client:{pid}"),
            kind: Some("app".into()),
            platform: Some("macos".into()),
            connection_state: Some("connected".into()),
            pid: Some(pid),
            ..Default::default()
        };
        // Nothing read yet: every reading unknown, away.
        assert!(!r.desk_here(&[mac(100)]));
        *sense.reading.lock().unwrap() = at_the_desk();
        assert!(r.desk_here(&[mac(100)]));
        assert!(!r.desk_here(&[mac(200)]), "a Mac app reaching this server over SSH");
        assert!(!r.desk_here(&[]), "no desktop app shows this server");
        *sense.reading.lock().unwrap() = crate::desk::Reading { session: Some(crate::desk::Session { locked: true, on_console: true }), ..at_the_desk() };
        assert!(!r.desk_here(&[mac(100)]));
        let log = captured_log();
        assert!(log.contains("desk present") && log.contains("desk away (screen locked)"), "{log}");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn before_sleep_what_is_held_goes_out_the_leases_are_removed_and_sleep_is_then_allowed() {
        let stored = || canned(200, r#"{"stored":true}"#);
        let (r, sense, seen, dir) = keyed_relay("desk-sleep", vec![stored(), canned(200, "{}"), stored()]).await;
        *r.labels_in_test.lock().unwrap() = Some(vec!["MBP_M4MAX".into()]);
        *sense.reading.lock().unwrap() = at_the_desk();
        r.lease_tick(false).await;
        let (power, events) = tokio::sync::mpsc::unbounded_channel();
        *sense.power.lock().unwrap() = Some(events);
        r.watch_power();
        desk_push(&r, &desk_event(PushCategory::Blocked, ""), true, &[], moment(0.0)).await;
        let (done, allowed) = std::sync::mpsc::sync_channel(1);
        power.send(Power::WillSleep(done)).unwrap();
        let allowed = tokio::task::spawn_blocking(move || allowed.recv_timeout(Duration::from_secs(5))).await.unwrap();
        assert!(allowed.is_ok(), "sleep is allowed");
        assert_eq!(held(&r), 0);
        let leases = lease_bodies(&seen);
        assert_eq!(leases.iter().map(|(_, b)| b["ttl"].as_u64().unwrap()).collect::<Vec<_>>(), [600, 0]);
        assert_eq!(seen.lock().unwrap().len(), 3);
        // Woken: nobody is at the desk until a reading says so.
        power.send(Power::PoweredOn).unwrap();
        tokio::time::sleep(Duration::from_millis(20)).await;
        assert!(!r.desk.lock().unwrap().present());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_status_panes_notification_and_a_progress_report_are_not_pushed() {
        let (r, _, seen, dir) = desk_relay("desk-notices", vec![canned(200, "{}")]).await;
        let notice = |text: &str| {
            let mut i = desk_event(PushCategory::Notice, "");
            i.text = Some(text.into());
            i
        };
        // The pane lost its OSC 7501 record a moment ago (Claude's reminder after its turn).
        r.handle_session_event(&r.servers[0], "session:1", &json!({"type": "block_event", "payload": {"block_id": "block:b1", "name": "program_status_removed", "payload": {"ids": [""]}}}));
        r.clone().dispatch(notice("Claude is waiting for your input")).await;
        // An OSC 9;4 progress report an older Rex passed on as a notification.
        r.clone().dispatch(notice("4;1;42")).await;
        assert_eq!(seen.lock().unwrap().len(), 0);
        // Another pane with no status record (an agent that reports none, or a pane Rex can't
        // tell about here): pushed, after the wait.
        let mut other = notice("Build finished");
        other.block.block_id = "block:b2".into();
        let began = Instant::now();
        r.clone().dispatch(other).await;
        assert!(began.elapsed() >= NOTICE_WAIT);
        assert_eq!(seen.lock().unwrap().len(), 1);
        // The pane closed: what it was is forgotten.
        r.handle_session_event(&r.servers[0], "session:1", &json!({"type": "block_closed", "payload": {"block_id": "block:b1"}}));
        assert!(r.servers[0].st.lock().unwrap().status_removed_at.is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_held_question_waits_while_the_app_is_in_front() {
        let (r, _, seen, dir) = desk_relay("desk-in-front", vec![canned(200, "{}")]).await;
        let ios = ClientSnapshot {
            client_id: "client:a1b2c3d4".into(),
            kind: Some("app".into()),
            platform: Some("ios".into()),
            label: Some("Alex's iPhone #a1b2c3d4".into()),
            connection_state: Some("connected".into()),
            ..Default::default()
        };
        desk_push(&r, &desk_event(PushCategory::Blocked, ""), true, &[], Moment::now()).await;
        r.act(&r.servers[0], "push_presence", &json!({"active": true}), &app("a1b2c3d4", Some(ALEX))).await.0.unwrap();
        let due = r.holds.lock().unwrap().due(Moment::now(), |_| true);
        r.send_held(due, std::slice::from_ref(&ios)).await;
        assert_eq!((seen.lock().unwrap().len(), held(&r)), (0, 1), "the app shows it");
        // Once the app has left the front, it goes.
        r.act(&r.servers[0], "push_presence", &json!({"active": false}), &app("a1b2c3d4", Some(ALEX))).await.0.unwrap();
        let due = r.holds.lock().unwrap().due(Moment::now(), |_| true);
        r.send_held(due, std::slice::from_ref(&ios)).await;
        assert_eq!((seen.lock().unwrap().len(), held(&r)), (1, 0));
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A moment `left` seconds short of a question's cap, for one held now.
    fn short_of_cap(left: f64) -> Moment {
        Moment { wall: now() - crate::desk::HOLD_CAP + left, mono: Some(crate::desk::mono() - crate::desk::HOLD_CAP + left) }
    }

    async fn until(what: impl Fn() -> bool) -> bool {
        for _ in 0..200 {
            if what() {
                return true;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        what()
    }

    #[tokio::test]
    async fn the_watch_ends_when_nothing_is_held_and_a_question_held_at_its_end_still_gets_its_cap() {
        let (r, _, seen, dir) = desk_relay("desk-watch", vec![canned(200, "{}")]).await;
        *r.hold_poll.lock().unwrap() = Duration::from_millis(20);
        // At the desk all along: only the cap releases a question.
        *r.shown_in_test.lock().unwrap() = Some(true);
        let running = |r: &Relay| *r.hold_running.lock().unwrap();
        let mut second = desk_event(PushCategory::Blocked, "");
        second.block.block_id = "block:b2".into();

        desk_push(&r, &desk_event(PushCategory::Blocked, ""), true, &[], short_of_cap(0.2)).await;
        assert!(running(&r));
        assert_eq!(requests(&seen, 1).await, 1, "the cap");
        assert!(until(|| !running(&r)).await, "nothing held: the watch ends");

        // The gap: a watch that found nothing and has not ended yet when a question is held.
        // Holding sees it running and starts none; ending sees the question and goes on.
        *r.hold_running.lock().unwrap() = true;
        desk_push(&r, &second, true, &[], short_of_cap(0.2)).await;
        assert!(!r.hold_watch_ends(), "a question was held meanwhile: the watch goes on");
        assert!(running(&r));
        // (That watch was only pretended; let a real one take over from here.)
        *r.hold_running.lock().unwrap() = false;
        r.hold_watch();
        assert_eq!(requests(&seen, 2).await, 2, "the second question's cap still fires");
        assert!(until(|| !running(&r)).await);
        assert_eq!(held(&r), 0);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn questions_held_before_a_restart_are_watched_from_the_start_without_rex() {
        let (r, _, seen, dir) = desk_relay("desk-restored", vec![canned(200, "{}")]).await;
        let base = r.store.lock().unwrap().devices[0].gateway.clone();
        desk_push(&r, &desk_event(PushCategory::Blocked, ""), true, &[], short_of_cap(0.2)).await;
        drop(r);
        let r = restarted(&dir, &base);
        *r.hold_poll.lock().unwrap() = Duration::from_millis(20);
        *r.shown_in_test.lock().unwrap() = Some(true);
        // No server is connected or set up: the cap fires all the same.
        r.watch_restored();
        assert_eq!(requests(&seen, 1).await, 1);
        assert!(until(|| held(&r) == 0).await);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_dry_run_holds_in_memory_only() {
        let dir = temp("desk-dry");
        let r = relay_watching(vec![None], &dir, true, Sender::DryRun, &[GATEWAY]);
        r.store.lock().unwrap().register(phone("a1b2c3d4", GATEWAY)).unwrap();
        desk_push(&r, &desk_event(PushCategory::Blocked, ""), true, &[], moment(0.0)).await;
        assert_eq!(held(&r), 1);
        desk_push(&r, &desk_event(PushCategory::Blocked, "other"), false, &[], moment(1.0)).await;
        assert!(!dir.join(crate::hold::PARKED_FILE).exists() && !dir.join(crate::hold::DELIVERED_FILE).exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    // MARK: Port shares and port owners (share.rs, owner.rs)
    //
    // Loopback stands in for the tailnet: the computer is desk.example.ts.net at 127.0.0.1,
    // and a phone may have any loopback address.

    use crate::share::testing::{exchange, get, soon, Dev};

    async fn code(r: &Relay, s: &Server, action: &str, who: &Requester, args: &Value) -> String {
        r.act(s, action, args, who).await.0.unwrap_err()["code"].as_str().unwrap().to_string()
    }

    /// Lets the tasks of shares that were closed end.
    async fn closed(to: std::net::SocketAddr) -> bool {
        for _ in 0..50 {
            tokio::task::yield_now().await;
        }
        soon(tokio::net::TcpStream::connect(to)).await.is_err()
    }

    #[tokio::test]
    async fn port_share_is_only_for_a_registered_phone_and_a_port_that_listens() {
        let dir = temp("share-owner");
        let r = relay(&dir, false);
        let s = named_server("https://rex.example.ts.net");
        let dev = Dev::start().await;
        let alex = app("a1b2c3d4", Some(ALEX));
        let ask = json!({"block": "block:1", "port": dev.port(), "phone_ip": "127.0.0.1"});
        // Nobody is registered; a client the server did not identify is refused before that.
        assert_eq!(code(&r, &s, "port_share", &alex, &ask).await, "not_registered");
        assert_eq!(code(&r, &s, "port_share", &app("a1b2c3d4", None), &ask).await, "refused");
        r.store.lock().unwrap().register(phone("a1b2c3d4", GATEWAY)).unwrap();
        // Someone else's client with this phone's id, and another phone of the owner.
        for other in [app("a1b2c3d4", Some(SAM)), app("ffff0000", Some(ALEX))] {
            assert_eq!(code(&r, &s, "port_share", &other, &ask).await, "not_registered", "{other:?}");
        }
        // The owner: a request that names no port or no address of a phone is no request.
        for bad in [
            json!({"block": "block:1", "phone_ip": "127.0.0.1"}),
            json!({"block": "block:1", "port": 0, "phone_ip": "127.0.0.1"}),
            json!({"block": "block:1", "port": 70000, "phone_ip": "127.0.0.1"}),
            json!({"block": "block:1", "port": "3000", "phone_ip": "127.0.0.1"}),
            json!({"block": "block:1", "port": dev.port()}),
            json!({"block": "block:1", "port": dev.port(), "phone_ip": "phone.example"}),
            json!({"block": "block:1", "port": dev.port(), "phone_ip": "192.168.1.20"}),
            json!({"block": "b".repeat(201), "port": dev.port(), "phone_ip": "127.0.0.1"}),
        ] {
            assert_eq!(code(&r, &s, "port_share", &alex, &bad).await, "bad_request", "{bad}");
        }
        // The system's ports and the usual ports of debuggers and databases are refused,
        // listening or not.
        for port in [9229, 9225, 5432, 11434, 22, 443] {
            assert_eq!(code(&r, &s, "port_share", &alex, &json!({"port": port, "phone_ip": "127.0.0.1"})).await, "refused", "{port}");
        }
        assert_eq!(r.shares.count(), 0);
        // The port listens: the answer is where to open it.
        let opened = r.act(&s, "port_share", &ask, &alex).await.0.unwrap();
        let port = opened["port"].as_u64().unwrap();
        assert_eq!(
            opened,
            json!({"url": format!("http://desk.example.ts.net:{port}"), "ip_url": format!("http://127.0.0.1:{port}"), "port": port, "same_port": false, "idle_seconds": 1800, "waiting_seconds": 600})
        );
        let to: std::net::SocketAddr = format!("127.0.0.1:{port}").parse().unwrap();
        let (head, _) = exchange(to, &get("/", &format!("desk.example.ts.net:{port}"))).await;
        assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
        // Asked again, it is the same share.
        assert_eq!(r.act(&s, "port_share", &ask, &alex).await.0.unwrap(), opened);
        assert_eq!(r.shares.count(), 1);
        // A port nothing listens on is not shared.
        let gone = Dev::start().await;
        let silent = json!({"block": "block:1", "port": gone.port(), "phone_ip": "127.0.0.1"});
        gone.stop().await;
        assert_eq!(code(&r, &s, "port_share", &alex, &silent).await, "not_listening");
        assert_eq!(r.shares.count(), 1);
        r.stop();
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_phone_that_unregisters_loses_its_shares_and_a_stop_ends_them_all() {
        let dir = temp("share-ends");
        let r = relay(&dir, false);
        let s = named_server("https://rex.example.ts.net");
        let (one, two) = (Dev::start().await, Dev::start().await);
        r.store.lock().unwrap().register(phone("a1b2c3d4", GATEWAY)).unwrap();
        r.store.lock().unwrap().register(phone("ffff0000", GATEWAY)).unwrap();
        let (alex, other) = (app("a1b2c3d4", Some(ALEX)), app("ffff0000", Some(ALEX)));
        let mut at = vec![];
        for (who, dev) in [(&alex, &one), (&other, &one), (&other, &two)] {
            let opened = r.act(&s, "port_share", &json!({"block": "block:1", "port": dev.port(), "phone_ip": "127.0.0.1"}), who).await.0.unwrap();
            at.push(format!("127.0.0.1:{}", opened["port"]).parse::<std::net::SocketAddr>().unwrap());
        }
        assert_eq!(r.shares.count(), 3);
        // Someone else's unregister of that id removes nothing, and ends no share.
        assert_eq!(r.act(&s, "unregister_push", &json!({"device_id": "a1b2c3d4"}), &app("a1b2c3d4", Some(SAM))).await.0.unwrap(), json!({"removed": false}));
        assert_eq!(r.shares.count(), 3);
        assert_eq!(r.act(&s, "unregister_push", &json!({"device_id": "a1b2c3d4"}), &alex).await.0.unwrap(), json!({"removed": true}));
        assert_eq!(r.shares.count(), 2, "the phone's own share went with its registration");
        assert!(closed(at[0]).await);
        // A phone the gateway no longer knows is unregistered, and its shares go as well.
        let dropped = r.store.lock().unwrap().get("ffff0000").cloned().unwrap();
        r.settle(&dropped, &SendResult::Gone("unregistered".into()), 0.0);
        assert_eq!(r.shares.count(), 0);
        assert!(closed(at[1]).await && closed(at[2]).await);
        // A Beacon that stops shares nothing.
        r.store.lock().unwrap().register(phone("a1b2c3d4", GATEWAY)).unwrap();
        let opened = r.act(&s, "port_share", &json!({"port": two.port(), "phone_ip": "127.0.0.1"}), &alex).await.0.unwrap();
        assert_eq!(r.shares.count(), 1);
        r.stop();
        assert_eq!(r.shares.count(), 0);
        assert!(closed(format!("127.0.0.1:{}", opened["port"]).parse().unwrap()).await);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_phone_removed_with_forget_loses_its_shares() {
        let dir = temp("share-forget");
        let r = relay(&dir, false);
        let s = named_server("https://rex.example.ts.net");
        let dev = Dev::start().await;
        r.store.lock().unwrap().register(phone("a1b2c3d4", GATEWAY)).unwrap();
        r.store.lock().unwrap().register(phone("ffff0000", GATEWAY)).unwrap();
        let (alex, other) = (app("a1b2c3d4", Some(ALEX)), app("ffff0000", Some(ALEX)));
        let ask = json!({"block": "block:1", "port": dev.port(), "phone_ip": "127.0.0.1"});
        let mine = r.act(&s, "port_share", &ask, &alex).await.0.unwrap();
        let theirs = r.act(&s, "port_share", &ask, &other).await.0.unwrap();
        assert_eq!(r.shares.count(), 2);
        let forget = |id: &str| {
            // What `rex-duo-helper forget <id>` does: another process writes the file.
            let mut file = DeviceStore::open(dir.join("devices.json"));
            assert!(file.remove(id).unwrap());
        };
        // The next time Beacon reads its registrations, for whatever reason, the share goes.
        forget("a1b2c3d4");
        assert_eq!(r.shares.count(), 2, "nothing has made Beacon look yet");
        status(&r, &other).await;
        assert_eq!(r.shares.count(), 1);
        let at = |opened: &Value| format!("127.0.0.1:{}", opened["port"]).parse::<std::net::SocketAddr>().unwrap();
        assert!(closed(at(&mine)).await);
        // And when nothing makes it look, the share itself asks before it serves anyone.
        r.watch_shares();
        let (head, _) = exchange(at(&theirs), &get("/", &format!("desk.example.ts.net:{}", theirs["port"]))).await;
        assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
        forget("ffff0000");
        assert_eq!(r.shares.count(), 1);
        assert!(crate::share::testing::nothing(at(&theirs), &get("/", &format!("desk.example.ts.net:{}", theirs["port"]))).await);
        assert_eq!(r.shares.count(), 0);
        assert!(closed(at(&theirs)).await);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn rex_events_about_a_pane_reach_the_shares_of_its_ports() {
        let dir = temp("share-events");
        let r = relay(&dir, false);
        let s = Arc::new(named_server("https://rex.example.ts.net"));
        let dev = Dev::start().await;
        r.store.lock().unwrap().register(phone("a1b2c3d4", GATEWAY)).unwrap();
        let alex = app("a1b2c3d4", Some(ALEX));
        r.act(&s, "port_share", &json!({"block": "block:1", "port": dev.port(), "phone_ip": "127.0.0.1"}), &alex).await.0.unwrap();
        let ports = |block: &str, ports: Value| {
            json!({"type": "session_event", "payload": {"session_id": "session:1", "event": {"type": "block_event",
                "payload": {"block_id": block, "name": "ports_changed", "payload": {"status": "ok", "ports": ports}}}}})
        };
        let listed = json!([{"port": dev.port(), "protocol": "tcp", "address": "127.0.0.1"}]);
        // The pane still lists the port, or it is another pane's list, or another server's.
        r.handle(&s, ports("block:1", listed.clone()));
        r.handle(&s, ports("block:2", json!([])));
        r.handle(&Arc::new(named_server("https://other.example.ts.net")), ports("block:1", json!([])));
        assert_eq!(r.shares.waiting(), 0);
        // The pane's list without it: the share waits. With it again: it doesn't.
        r.handle(&s, ports("block:1", json!([])));
        assert_eq!((r.shares.waiting(), r.shares.count()), (1, 1));
        r.handle(&s, ports("block:1", listed));
        assert_eq!(r.shares.waiting(), 0);
        // The pane closes.
        r.handle(&s, json!({"type": "session_event", "payload": {"session_id": "session:1", "event": {"type": "block_closed", "payload": {"block_id": "block:1"}}}}));
        assert_eq!((r.shares.waiting(), r.shares.count()), (1, 1));
        r.stop();
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// What a test's processes carry among their arguments, and no log line or error may.
    const ARGV_SECRET: &str = "s3cr3t-from-a-flag";

    /// A relay on a computer with these processes, all of this user unless said otherwise.
    fn relay_with_processes(dir: &std::path::Path, processes: &[(u32, &str, u32, u32, Option<u32>)]) -> Arc<Relay> {
        let sense = Arc::new(TestSense::default());
        for (pid, name, ppid, pgid, tty_pgid) in processes {
            let p = crate::desk::Process { path: format!("/usr/bin/{name}"), name: name.to_string(), uid: crate::platform::user_id(), ppid: *ppid, pgid: *pgid, sid: 900, tty_pgid: *tty_pgid };
            sense.processes.lock().unwrap().insert(*pid, p);
            // Every process was started with a token among its arguments.
            let argv = vec![name.as_bytes().to_vec(), b"run".to_vec(), format!("--token={ARGV_SECRET}").into_bytes()];
            sense.invocations.lock().unwrap().insert(*pid, crate::platform::Invocation { argv, truncated: false, cwd: Some("/app".into()) });
        }
        let r = relay_sensing(vec![], dir, false, Sender::Gateway, &[GATEWAY], sense);
        r.store.lock().unwrap().register(phone("a1b2c3d4", GATEWAY)).unwrap();
        r
    }

    #[tokio::test]
    async fn port_owner_names_the_group_and_the_ancestry_of_a_wrapped_server() {
        let dir = temp("owner");
        // `npm run dev` in a pane: zsh 900 started npm 4200, npm a shell 4201, that node 4242.
        let r = relay_with_processes(&dir, &[(4242, "node", 4201, 4200, Some(4200)), (4201, "sh", 4200, 4200, Some(4200)), (4200, "npm", 900, 4200, Some(4200)), (900, "zsh", 1, 900, Some(4200))]);
        let s = server();
        let alex = app("a1b2c3d4", Some(ALEX));
        capture_log();
        let owner = r.act(&s, "port_owner", &json!({"pid": 4242}), &alex).await.0.unwrap();
        let entry = |pid: u32, ppid: u32, pgid: u32, name: &str| {
            json!({"pid": pid, "ppid": ppid, "pgid": pgid, "sid": 900, "group_leader": pid == pgid, "session_leader": pid == 900, "name": name, "path": format!("/usr/bin/{name}"),
                "argv": [name, "run", format!("--token={ARGV_SECRET}")], "argv_lossy": false, "truncated": false, "cwd": "/app"})
        };
        assert_eq!(
            owner,
            json!({"pid": 4242, "pgid": 4200, "tty_foreground_pgid": 4200, "foreground": true, "ancestry": [
                entry(4242, 4201, 4200, "node"), entry(4201, 4200, 4200, "sh"), entry(4200, 900, 4200, "npm"), entry(900, 1, 900, "zsh")
            ]})
        );
        // `pid` wins over `port`: no tool is run to look the port up.
        assert_eq!(r.act(&s, "port_owner", &json!({"pid": 4242, "port": 3000}), &alex).await.0.unwrap(), owner);
        // A process that is not there, or another user's.
        assert_eq!(code(&r, &s, "port_owner", &alex, &json!({"pid": 5555})).await, "not_available");
        let elsewhere = temp("owner-none");
        let other = relay_with_processes(&elsewhere, &[]);
        assert_eq!(code(&other, &s, "port_owner", &alex, &json!({"pid": 4242})).await, "not_available");
        for bad in [json!({}), json!({"pid": 0}), json!({"pid": 1}), json!({"pid": -5}), json!({"pid": "4242"}), json!({"port": 0}), json!({"port": 70000})] {
            assert_eq!(code(&r, &s, "port_owner", &alex, &bad).await, "bad_request", "{bad}");
        }
        // Only for someone with a phone registered here, as the server names them.
        for stranger in [app("a1b2c3d4", Some(SAM)), app("ffff0000", Some(ALEX))] {
            assert_eq!(code(&r, &s, "port_owner", &stranger, &json!({"pid": 4242})).await, "not_registered");
        }
        // What nobody but the caller gets: an error says nothing of a process, and neither
        // does the log, whoever asked and whatever came of it.
        for (who, args) in [(&alex, json!({"pid": 5555})), (&alex, json!({"pid": "4242"})), (&app("a1b2c3d4", Some(SAM)), json!({"pid": 4242})), (&app("a1b2c3d4", None), json!({"pid": 4242}))] {
            let refusal = r.act(&s, "port_owner", &args, who).await.0.unwrap_err().to_string();
            assert!(!refusal.contains(ARGV_SECRET) && !refusal.contains("--token") && !refusal.contains("/app"), "{refusal}");
        }
        assert_eq!(code(&r, &s, "port_owner", &app("a1b2c3d4", None), &json!({"pid": 4242})).await, "refused");
        let log = captured_log();
        assert!(!log.contains(ARGV_SECRET) && !log.contains("--token") && !log.contains("npm"), "{log}");
        // Nor is it in any file Beacon keeps.
        r.write_status();
        for file in std::fs::read_dir(&dir).unwrap() {
            let path = file.unwrap().path();
            if path.is_file() {
                assert!(!String::from_utf8_lossy(&std::fs::read(&path).unwrap()).contains(ARGV_SECRET), "{}", path.display());
            }
        }
        std::fs::remove_dir_all(dir).unwrap();
        std::fs::remove_dir_all(elsewhere).unwrap();
    }

    #[tokio::test]
    async fn a_beacon_from_before_these_actions_says_it_has_none() {
        // What an app gets from a Beacon that does not know an action, which is how it
        // tells that "Open in Browser" is not there: `not_supported`, as for any other name.
        let dir = temp("unknown-action");
        let r = relay(&dir, false);
        r.store.lock().unwrap().register(phone("a1b2c3d4", GATEWAY)).unwrap();
        assert_eq!(code(&r, &server(), "port_share_v2", &app("a1b2c3d4", Some(ALEX)), &json!({})).await, "not_supported");
        assert!(KNOWN_ACTIONS.contains(&"port_share") && KNOWN_ACTIONS.contains(&"port_owner"));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
