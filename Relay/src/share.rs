//! Port shares: a dev server on this computer, opened in any browser on the phone.
//!
//! The phone app shows such a page inside itself through Rex. Another browser on the phone
//! can't use that path, so for "Open in Browser" Beacon listens on this computer's own
//! Tailscale address and passes each connection on to the dev server on this computer's
//! loopback (proxy.rs). That works for servers that listen on `127.0.0.1` only, and the
//! server sees a local visitor.
//!
//! What a share is held to:
//! - it exists only on a computer that runs the regular Tailscale client (tailscale.rs), and
//!   listens on that computer's Tailscale address alone, never on a LAN or public one;
//! - it takes connections from one address: the tailnet address of the phone that asked,
//!   which must be a registered phone of the caller, and which the Tailscale client must say
//!   is a device of the same tailnet user as this computer. Anyone else is dropped before a
//!   byte is read;
//! - it reaches one port of the loopback, and only as HTTP: a port from 1024 up (or 80), not
//!   one of the usual ports of debuggers, databases and the like, and one that a process of
//!   the user Beacon runs as listens on;
//! - at most `MAX_SHARES` exist at once, each with at most `MAX_CONNECTIONS` connections,
//!   and all of them together with at most `MAX_ALL_CONNECTIONS`;
//! - it ends `IDLE` after its last connection closed, `WAITING` after its port stopped
//!   listening, when the phone is no longer registered (it unregistered, the gateway dropped
//!   it, or `forget` removed it), and when Beacon stops.
//!
//! Its address has the dev server's own port number when that is free on the Tailscale
//! address and the system lets a share take it (`platform::SAME_PORT`: macOS), and a port
//! the system picks otherwise.
//!
//! Nothing here polls. A share waits on its listener and on at most one timer, for the
//! earlier of its two ends. It learns that its port stopped listening from Rex
//! (`ports_changed`, the pane closing) and from a connection that finds nothing there, and
//! that it listens again the same two ways.

use crate::proxy::{self, Target, Watch};
use crate::tailscale::{self, Tailnet};
use crate::util::Json;
use crate::{debug, info};
use serde_json::Value;
use std::net::{IpAddr, SocketAddr};
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;
use tokio::net::TcpListener;
use tokio::sync::Notify;
use tokio::task::{JoinHandle, JoinSet};
use tokio::time::Instant;

/// The most shares at once, whoever asked for them.
pub const MAX_SHARES: usize = 8;
/// The most connections of one share at once. A browser opens six to a host, and a page
/// keeps one or two more for live reload.
pub const MAX_CONNECTIONS: usize = 32;
/// The most connections of all shares together. Each takes two sockets, so with the eight
/// listeners the shares hold at most 136.
pub const MAX_ALL_CONNECTIONS: usize = 64;
/// A share ends this long after its last connection closed.
pub const IDLE: Duration = Duration::from_secs(30 * 60);
/// A share whose port stopped listening answers with the waiting page this long, then ends.
pub const WAITING: Duration = Duration::from_secs(10 * 60);

/// The usual ports of programs that are not web pages to open on a phone: debuggers (whoever
/// reaches one runs code in the program), databases, queues, caches, the Docker and Kubernetes
/// APIs, a local model server, a file-sync admin page. A share is refused for them.
const REFUSED_PORTS: [u16; 14] = [2181, 2375, 3306, 5432, 5672, 6379, 8001, 8384, 9092, 9222, 9229, 9230, 11211, 11434];
const REFUSED_MORE: [u16; 1] = [27017];
/// The other ports debuggers take when the first is in use.
const REFUSED_RANGES: [std::ops::RangeInclusive<u16>; 2] = [9223..=9228, 9231..=9239];

/// True for a port no share is made for: every port below 1024 but 80 (the system's own
/// services, which a user's program can't listen on anyway), and the usual ports above.
pub fn is_refused_port(port: u16) -> bool {
    (port < 1024 && port != 80) || REFUSED_PORTS.contains(&port) || REFUSED_MORE.contains(&port) || REFUSED_RANGES.iter().any(|r| r.contains(&port))
}

/// True when a phone's address belongs to the tailnet user this computer belongs to. A
/// device without a user (a tagged one), on either side, is nobody's.
pub fn same_user(mine: Option<u64>, phones: Option<u64>) -> bool {
    mine.is_some() && mine == phones
}

/// Something asked of this computer, or the answer a test gives in its place.
#[derive(Clone, Copy)]
enum Asked<T> {
    System,
    #[cfg_attr(not(test), allow(dead_code))]
    Fixed(T),
}

/// True when a `ports_changed` payload lists `port` over TCP.
fn lists(payload: &Value, port: u16) -> bool {
    payload.arr("ports").iter().any(|p| p.int("port") == Some(i64::from(port)) && p.str("protocol").is_none_or(|proto| proto == "tcp"))
}

/// Where shares listen and who may connect: the tailnet in a real run. Tests put loopback
/// addresses in its place.
#[derive(Clone)]
pub struct Net {
    /// This computer on the tailnet as a test has it; None asks the Tailscale client.
    fixed: Option<Tailnet>,
    /// Whether a phone may have this address.
    phone: fn(IpAddr) -> bool,
    /// The tailnet user a phone's address belongs to.
    who: Asked<Option<u64>>,
    /// Whether the port's listener is a process of this user.
    holder: Asked<bool>,
    pub idle: Duration,
    pub waiting: Duration,
}

impl Net {
    #[cfg_attr(test, allow(dead_code))] // the tests put `loopback` in its place
    pub fn tailnet() -> Net {
        Net { fixed: None, phone: tailscale::is_tailnet, who: Asked::System, holder: Asked::System, idle: IDLE, waiting: WAITING }
    }

    /// Loopback in the tailnet's place, for tests: the computer is `tailnet` and a phone
    /// may have any loopback address.
    #[cfg(test)]
    pub fn loopback(tailnet: Option<Tailnet>) -> Net {
        let who = Asked::Fixed(tailnet.as_ref().and_then(|t| t.user));
        Net { fixed: tailnet, phone: |ip| ip.is_loopback(), who, holder: Asked::Fixed(true), idle: IDLE, waiting: WAITING }
    }

    /// The tailnet user `phone` belongs to, as the Tailscale client says.
    async fn whois(&self, phone: IpAddr) -> Option<u64> {
        match self.who {
            Asked::Fixed(user) => user,
            // A test never asks the real client.
            #[cfg(test)]
            Asked::System => {
                let _ = phone;
                None
            }
            #[cfg(not(test))]
            Asked::System => tailscale::whois(phone).await,
        }
    }

    /// Whether a process of this user listens on `port`.
    async fn listens_as_me(&self, port: u16) -> bool {
        match self.holder {
            Asked::Fixed(mine) => mine,
            Asked::System => crate::owner::listens_as_me(port).await,
        }
    }

    /// `loopback` for a computer called `desk.example.ts.net` that has both loopback
    /// addresses as its tailnet ones.
    #[cfg(test)]
    pub fn testing() -> Net {
        let ips = vec![IpAddr::V4(std::net::Ipv4Addr::LOCALHOST), IpAddr::V6(std::net::Ipv6Addr::LOCALHOST)];
        Net::loopback(Some(Tailnet { name: Some("desk.example.ts.net".into()), machine: "desk".into(), ips, user: Some(1001) }))
    }

    async fn read(&self) -> Option<Tailnet> {
        // A test never asks the real client.
        #[cfg(not(test))]
        if self.fixed.is_none() {
            return tailscale::read().await;
        }
        self.fixed.clone()
    }
}

/// What a phone asks to have shared.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Ask {
    /// The Rex server the pane is on, as the relay names its connection.
    pub server: String,
    /// The pane the dev server runs in. Rex's events about it tell when the port goes.
    pub block: String,
    pub port: u16,
    /// The registered phone the share is for, by its device id.
    pub device: String,
    /// That phone's tailnet address: the only one that may connect.
    pub phone: IpAddr,
}

/// Where a share is reached.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Opened {
    /// The address to open: by the computer's tailnet name when it has one, else by its
    /// tailnet address.
    pub url: String,
    /// The same by tailnet address, always.
    pub ip_url: String,
    /// The port the share listens on.
    pub port: u16,
    /// True when that is the dev server's own port number.
    pub same_port: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Refusal {
    /// This computer does not run the regular Tailscale client, or has no address of the
    /// phone's kind there.
    NotAvailable,
    /// The phone's address is not one a phone on the tailnet has.
    BadPhone,
    /// Nothing listens on the port.
    NotListening,
    /// `MAX_SHARES` are open.
    Full,
    /// The system gave no port.
    NoPort,
    /// The Tailscale client does not say that the phone's address is a device of this
    /// computer's own tailnet user.
    NotYourPhone,
    /// The port is one no share is made for, or its listener is not a process of this user.
    NotYourPort,
}

/// What a share's connections and its timer both look at.
struct Live {
    state: Mutex<LiveState>,
    /// Wakes the share's task when its end moved.
    changed: Notify,
    /// The connections of all shares together.
    all: Arc<AtomicUsize>,
}

struct LiveState {
    /// Connections open now.
    open: usize,
    /// When the last one closed (or the share began, or was asked for again).
    quiet_since: Instant,
    /// Since when nothing listens on the port, as far as the share knows.
    waiting_since: Option<Instant>,
}

impl Live {
    fn new(all: Arc<AtomicUsize>) -> Live {
        Live { state: Mutex::new(LiveState { open: 0, quiet_since: Instant::now(), waiting_since: None }), changed: Notify::new(), all }
    }

    /// When the share ends if nothing changes, and why. None while a connection is open and
    /// the port listens: then no timer runs at all.
    fn end(&self, idle: Duration, waiting: Duration) -> Option<(Instant, &'static str)> {
        let st = self.state.lock().unwrap();
        let quiet = (st.open == 0).then(|| (st.quiet_since + idle, "nothing used it for a while"));
        let gone = st.waiting_since.map(|since| (since + waiting, "nothing listens on its port any more"));
        match (quiet, gone) {
            (Some(q), Some(g)) => Some(if g.0 <= q.0 { g } else { q }),
            (q, g) => q.or(g),
        }
    }

    fn open(&self) -> usize {
        self.state.lock().unwrap().open
    }

    #[cfg(test)]
    fn waiting(&self) -> bool {
        self.state.lock().unwrap().waiting_since.is_some()
    }

    /// The phone asked for the share again: its idle time starts over.
    fn touch(&self) {
        self.state.lock().unwrap().quiet_since = Instant::now();
        self.changed.notify_one();
    }

    fn enter(self: &Arc<Self>) -> Entered {
        self.state.lock().unwrap().open += 1;
        self.all.fetch_add(1, Ordering::SeqCst);
        self.changed.notify_one();
        Entered(self.clone())
    }
}

impl Watch for Live {
    fn source_gone(&self) {
        let mut st = self.state.lock().unwrap();
        if st.waiting_since.is_none() {
            st.waiting_since = Some(Instant::now());
            drop(st);
            self.changed.notify_one();
        }
    }

    fn source_back(&self) {
        let mut st = self.state.lock().unwrap();
        if st.waiting_since.take().is_some() {
            drop(st);
            self.changed.notify_one();
        }
    }
}

/// One open connection of a share. It counts until it is dropped, however its task ends.
struct Entered(Arc<Live>);

impl Drop for Entered {
    fn drop(&mut self) {
        self.0.all.fetch_sub(1, Ordering::SeqCst);
        let mut st = self.0.state.lock().unwrap();
        st.open -= 1;
        if st.open == 0 {
            st.quiet_since = Instant::now();
        }
        drop(st);
        self.0.changed.notify_one();
    }
}

struct Share {
    id: u64,
    ask: Ask,
    addr: SocketAddr,
    live: Arc<Live>,
    task: JoinHandle<()>,
}

/// Says whether a phone is still registered, by its device id.
type Registered = Box<dyn Fn(&str) -> bool + Send + Sync>;

pub struct Shares {
    net: Net,
    list: Mutex<Vec<Share>>,
    next: AtomicU64,
    /// One request for a share is looked at at a time, so two for the same thing make one.
    opening: tokio::sync::Mutex<()>,
    /// The connections of all shares together.
    all: Arc<AtomicUsize>,
    /// Asked before a connection is taken. Not set: every phone counts as registered.
    registered: Mutex<Option<Arc<Registered>>>,
}

/// A listener on `ip`: on `port` when the system lets a share take the dev server's own
/// number and nothing else has it there, else on a port the system picks.
async fn listen(ip: IpAddr, port: u16, same_port: bool) -> Option<TcpListener> {
    if same_port {
        if let Ok(listener) = crate::platform::bind_tcp(SocketAddr::new(ip, port)).await {
            return Some(listener);
        }
    }
    crate::platform::bind_tcp(SocketAddr::new(ip, 0)).await.ok()
}

/// The addresses a share at `addr` is given out with.
fn opened(tailnet: &Tailnet, addr: SocketAddr, port: u16) -> Opened {
    let ip_url = format!("http://{}", proxy::authority(&addr.ip().to_string(), addr.port()));
    let url = tailnet.name.as_ref().map_or_else(|| ip_url.clone(), |name| format!("http://{}", proxy::authority(name, addr.port())));
    Opened { url, ip_url, port: addr.port(), same_port: addr.port() == port }
}

impl Shares {
    pub fn new(net: Net) -> Arc<Shares> {
        Arc::new(Shares {
            net,
            list: Mutex::new(vec![]),
            next: AtomicU64::new(1),
            opening: tokio::sync::Mutex::new(()),
            all: Arc::new(AtomicUsize::new(0)),
            registered: Mutex::new(None),
        })
    }

    /// From now on `registered` is asked before a share takes a connection: a share whose
    /// phone it no longer knows ends instead.
    pub fn watch_registrations(&self, registered: impl Fn(&str) -> bool + Send + Sync + 'static) {
        *self.registered.lock().unwrap() = Some(Arc::new(Box::new(registered)));
    }

    /// True unless the registrations are watched and no longer hold `device`.
    fn is_registered(&self, device: &str) -> bool {
        // Not asked under the lock: the answer may close shares, which takes it.
        let ask = self.registered.lock().unwrap().clone();
        ask.is_none_or(|ask| ask(device))
    }

    /// Ends the shares of every phone `registered` does not hold.
    pub fn keep_devices(&self, registered: impl Fn(&str) -> bool) -> usize {
        self.close("the phone is no longer registered", |s| !registered(&s.ask.device))
    }

    pub fn count(&self) -> usize {
        self.list.lock().unwrap().len()
    }

    /// Opens a share for `ask`, reachable from its phone only, and says where. The same
    /// phone asking again for the same port gets the share it has, with its idle time
    /// starting over.
    pub async fn open(self: &Arc<Self>, ask: Ask) -> Result<Opened, Refusal> {
        // An IPv4 address written as an IPv6 one is the IPv4 address.
        let ask = Ask { phone: ask.phone.to_canonical(), ..ask };
        if is_refused_port(ask.port) {
            return Err(Refusal::NotYourPort);
        }
        if !(self.net.phone)(ask.phone) {
            return Err(Refusal::BadPhone);
        }
        // Until this request is settled the next one waits: it then finds the share made here.
        let _one_at_a_time = self.opening.lock().await;
        let tailnet = self.net.read().await.ok_or(Refusal::NotAvailable)?;
        // The phone connects from an address of one kind, so the share listens on this
        // computer's address of that kind.
        let local = tailnet.ips.iter().copied().find(|ip| ip.is_ipv4() == ask.phone.is_ipv4()).ok_or(Refusal::NotAvailable)?;
        {
            let mut list = self.list.lock().unwrap();
            if let Some(s) = list.iter_mut().find(|s| s.ask.device == ask.device && s.ask.port == ask.port && s.ask.phone == ask.phone && s.addr.ip() == local) {
                s.ask = ask;
                s.live.touch();
                return Ok(opened(&tailnet, s.addr, s.ask.port));
            }
        }
        // The same port for the same phone at another address: the old share goes.
        self.close("the phone asked again from another address", |s| s.ask.device == ask.device && s.ask.port == ask.port);
        if self.count() >= MAX_SHARES {
            return Err(Refusal::Full);
        }
        // The address has to be a device of this computer's own user, as Tailscale has it,
        // and the port's listener a process of the user Beacon runs as.
        if !same_user(tailnet.user, self.net.whois(ask.phone).await) {
            return Err(Refusal::NotYourPhone);
        }
        if !self.net.listens_as_me(ask.port).await {
            // Nothing there at all is said as that.
            return Err(if Target::new(ask.port, SocketAddr::new(local, 0), None, "").dial().await.is_none() { Refusal::NotListening } else { Refusal::NotYourPort });
        }
        let listener = listen(local, ask.port, crate::platform::SAME_PORT).await.ok_or(Refusal::NoPort)?;
        let addr = listener.local_addr().map_err(|_| Refusal::NoPort)?;
        let target = Arc::new(Target::new(ask.port, addr, tailnet.name.as_deref(), &tailnet.machine));
        // A share is for a server that runs: what is not there now is not waited for.
        if target.dial().await.is_none() {
            return Err(Refusal::NotListening);
        }
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let mut list = self.list.lock().unwrap();
        // Checked again under the lock that adds it: two requests at once can't pass the cap.
        if list.len() >= MAX_SHARES {
            return Err(Refusal::Full);
        }
        let live = Arc::new(Live::new(self.all.clone()));
        let task = tokio::spawn(serve(Arc::downgrade(self), id, listener, target, live.clone(), ask.phone, ask.device.clone(), self.net.idle, self.net.waiting));
        info!("sharing port {} with one phone, on port {}", ask.port, addr.port());
        let found = opened(&tailnet, addr, ask.port);
        list.push(Share { id, ask, addr, live, task });
        Ok(found)
    }

    /// Ends every share `gone` picks: its listener closes, and its connections with it.
    fn close(&self, why: &str, gone: impl Fn(&Share) -> bool) -> usize {
        let mut list = self.list.lock().unwrap();
        let before = list.len();
        list.retain(|s| {
            if !gone(s) {
                return true;
            }
            s.task.abort();
            info!("stopped sharing port {}: {why}", s.ask.port);
            false
        });
        before - list.len()
    }

    /// A share's own task is over: it leaves the list.
    fn ended(&self, id: u64, why: &str) {
        let mut list = self.list.lock().unwrap();
        if let Some(i) = list.iter().position(|s| s.id == id) {
            info!("stopped sharing port {}: {why}", list[i].ask.port);
            list.remove(i);
        }
    }

    /// Rex said which ports a pane listens on now (`ports_changed`): a shared port that
    /// left the list starts waiting, and one that is back stops.
    pub fn ports_changed(&self, server: &str, block: &str, payload: &Value) {
        // Only a whole list says that a port is gone.
        let whole = payload.str("status") == Some("ok");
        for s in self.list.lock().unwrap().iter().filter(|s| s.ask.server == server && s.ask.block == block) {
            if lists(payload, s.ask.port) {
                s.live.source_back();
            } else if whole {
                s.live.source_gone();
            }
        }
    }

    /// A pane closed: what ran in it no longer listens.
    pub fn block_closed(&self, server: &str, block: &str) {
        for s in self.list.lock().unwrap().iter().filter(|s| s.ask.server == server && s.ask.block == block) {
            s.live.source_gone();
        }
    }

    /// A phone's registration ended.
    pub fn device_gone(&self, device: &str) -> usize {
        self.close("the phone is no longer registered", |s| s.ask.device == device)
    }

    pub fn close_all(&self) -> usize {
        self.close(concat!(crate::beacon_name!(), " is stopping"), |_| true)
    }

    /// How many shares answer with the waiting page now.
    #[cfg(test)]
    pub fn waiting(&self) -> usize {
        self.list.lock().unwrap().iter().filter(|s| s.live.waiting()).count()
    }

    /// How many connections the shares have open now.
    #[cfg(test)]
    pub fn connections(&self) -> usize {
        self.list.lock().unwrap().iter().map(|s| s.live.open()).sum()
    }
}

/// True when a connection from `peer` is one from `phone`: the same address, where an IPv4
/// address written as an IPv6 one is the IPv4 address.
fn is_phone(peer: IpAddr, phone: IpAddr) -> bool {
    peer.to_canonical() == phone.to_canonical()
}

/// One share: takes the phone's connections and pipes each, until it ends.
#[allow(clippy::too_many_arguments)]
async fn serve(shares: Weak<Shares>, id: u64, listener: TcpListener, target: Arc<Target>, live: Arc<Live>, phone: IpAddr, device: String, idle: Duration, waiting: Duration) {
    let mut connections = JoinSet::new();
    let why = loop {
        let end = live.end(idle, waiting);
        tokio::select! {
            accepted = listener.accept() => {
                let (stream, peer) = match accepted {
                    Ok(pair) => pair,
                    // A connection that ended before it was taken says nothing about the listener.
                    Err(e) if matches!(e.kind(), std::io::ErrorKind::ConnectionAborted | std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::Interrupted) => continue,
                    Err(_) => break "its listener failed",
                };
                // Anyone but the phone it is for is dropped before a byte is read.
                if !is_phone(peer.ip(), phone) {
                    debug!("a connection to a shared port from another address was dropped");
                    continue;
                }
                if live.open() >= MAX_CONNECTIONS || live.all.load(Ordering::SeqCst) >= MAX_ALL_CONNECTIONS {
                    debug!("a connection to a shared port was dropped: too many are open");
                    continue;
                }
                // `forget` may have removed the phone since: then this share is over, and
                // the connection with it.
                if shares.upgrade().is_some_and(|all| !all.is_registered(&device)) {
                    break "the phone is no longer registered";
                }
                // A phone that vanished is noticed by the system's probes.
                let _ = crate::platform::keep_alive(&stream);
                let (entered, target, live) = (live.enter(), target.clone(), live.clone());
                connections.spawn(async move {
                    let _entered = entered;
                    proxy::serve(stream, &target, &*live).await;
                });
            }
            _ = tokio::time::sleep_until(end.map_or_else(Instant::now, |e| e.0)), if end.is_some() => {
                // What moved the end meanwhile is looked at first.
                if let Some((at, why)) = live.end(idle, waiting) {
                    if Instant::now() >= at {
                        break why;
                    }
                }
            }
            _ = live.changed.notified() => {}
            Some(_) = connections.join_next(), if !connections.is_empty() => {}
        }
    };
    // Dropping the set ends every connection of the share.
    drop(connections);
    drop(listener);
    if let Some(shares) = shares.upgrade() {
        shares.ended(id, why);
    }
}

/// A dev server for tests, and a browser's side of a connection.
#[cfg(test)]
pub mod testing {
    use crate::proxy::{Chunked, Framing};
    use crate::waiting;
    use std::net::SocketAddr;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};
    use tokio::sync::Notify;
    use tokio::task::JoinHandle;

    /// How long any one step of a test may take.
    pub const STEP: Duration = Duration::from_secs(20);

    /// `what`, or a failed test when it takes longer than `STEP`.
    pub async fn soon<T>(what: impl std::future::Future<Output = T>) -> T {
        tokio::time::timeout(STEP, what).await.expect("a step of the test took too long")
    }

    /// `n` bytes that repeat in no short pattern.
    pub fn pattern(n: usize) -> Vec<u8> {
        static ROUND: std::sync::OnceLock<Vec<u8>> = std::sync::OnceLock::new();
        let round = ROUND.get_or_init(|| (0..65_521u32).map(|i| (i % 251) as u8).collect());
        let mut out = Vec::with_capacity(n);
        while out.len() < n {
            out.extend_from_slice(&round[..round.len().min(n - out.len())]);
        }
        out
    }

    #[derive(Default)]
    pub struct Seen {
        /// Connections taken so far.
        pub connections: AtomicUsize,
        /// Requests answered so far, the refused ones too.
        pub requests: AtomicUsize,
        /// Bytes of upload bodies read so far.
        pub uploaded: AtomicUsize,
        /// Lets `/slow` send its second half.
        pub go: Notify,
    }

    /// A dev server on the loopback that answers only as `localhost:<port>`, the way Vite
    /// (`server.allowedHosts`) and Next.js turn a foreign `Host` away.
    pub struct Dev {
        pub addr: SocketAddr,
        pub seen: Arc<Seen>,
        task: JoinHandle<()>,
    }

    impl Dev {
        pub async fn start() -> Dev {
            Dev::on(TcpListener::bind("127.0.0.1:0").await.unwrap())
        }

        pub fn on(listener: TcpListener) -> Dev {
            let addr = listener.local_addr().unwrap();
            let seen = Arc::new(Seen::default());
            let state = seen.clone();
            let task = tokio::spawn(async move {
                let mut connections = tokio::task::JoinSet::new();
                loop {
                    let Ok((stream, _)) = listener.accept().await else { return };
                    state.connections.fetch_add(1, Ordering::SeqCst);
                    connections.spawn(connection(stream, addr.port(), state.clone()));
                }
            });
            Dev { addr, seen, task }
        }

        pub fn port(&self) -> u16 {
            self.addr.port()
        }

        /// Stops the server: its listener and every connection close.
        pub async fn stop(self) {
            self.task.abort();
            let _ = self.task.await;
        }
    }

    fn header<'a>(head: &'a str, name: &str) -> Option<&'a str> {
        head.split("\r\n").skip(1).find_map(|l| l.split_once(':').filter(|(n, _)| n.eq_ignore_ascii_case(name)).map(|(_, v)| v.trim()))
    }

    async fn head_of(s: &mut TcpStream, buf: &mut Vec<u8>) -> Option<String> {
        loop {
            if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                let head = String::from_utf8_lossy(&buf[..i + 4]).into_owned();
                buf.drain(..i + 4);
                return Some(head);
            }
            if s.read_buf(buf).await.ok()? == 0 {
                return None;
            }
        }
    }

    async fn connection(mut s: TcpStream, port: u16, seen: Arc<Seen>) {
        let mut buf = vec![];
        while let Some(head) = head_of(&mut s, &mut buf).await {
            seen.requests.fetch_add(1, Ordering::SeqCst);
            let mut first = head.split("\r\n").next().unwrap().split(' ');
            let (method, path) = (first.next().unwrap_or(""), first.next().unwrap_or(""));
            let host = header(&head, "host").unwrap_or("");
            // The allowlist: only its own local name.
            if host != format!("localhost:{port}") {
                let body = format!("Blocked request. This host (\"{host}\") is not allowed.");
                let _ = s.write_all(format!("HTTP/1.1 403 Forbidden\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await;
                return;
            }
            let fixed = |status: &str, extra: &str, body: &str| format!("HTTP/1.1 {status}\r\n{extra}Content-Length: {}\r\n\r\n{body}", body.len()).into_bytes();
            let sent = match (method, path) {
                // What the server was asked as, so a test can read the rewrite.
                ("GET", "/") => {
                    let body = format!("host={host}\norigin={}\nreferer={}\n", header(&head, "origin").unwrap_or("-"), header(&head, "referer").unwrap_or("-"));
                    s.write_all(&fixed("200 OK", "Content-Type: text/plain\r\n", &body)).await
                }
                ("GET", "/login") => {
                    let extra = format!(
                        "Location: http://localhost:{port}/home\r\nSet-Cookie: sid=1; Domain=localhost; Path=/; HttpOnly\r\nAccess-Control-Allow-Origin: http://localhost:{port}\r\n{}: 1\r\n",
                        waiting::HEADER
                    );
                    s.write_all(&fixed("302 Found", &extra, "")).await
                }
                ("HEAD", _) => s.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 4096\r\n\r\n").await,
                ("GET", "/hints") => {
                    let mut all = b"HTTP/1.1 103 Early Hints\r\nLink: </a.css>; rel=preload\r\n\r\n".to_vec();
                    all.extend(fixed("200 OK", "", "after the hints"));
                    s.write_all(&all).await
                }
                // A body in one piece, by its length, of as many megabytes as the path says.
                ("GET", p) if p.starts_with("/big/") => {
                    let n: usize = p[5..].parse::<usize>().unwrap() << 20;
                    let _ = s.write_all(format!("HTTP/1.1 200 OK\r\nContent-Length: {n}\r\n\r\n").as_bytes()).await;
                    s.write_all(&super::testing::pattern(n)).await
                }
                // A chunked body in two halves: the second only once the test says so.
                ("GET", "/slow") => {
                    let _ = s.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nfirst \r\n").await;
                    seen.go.notified().await;
                    s.write_all(b"6;note=1\r\nsecond\r\n0\r\nX-Trailer: done\r\n\r\n").await
                }
                // An event stream: no length, it ends when the server closes.
                ("GET", "/events") => {
                    let _ = s.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: one\n\n").await;
                    seen.go.notified().await;
                    let _ = s.write_all(b"data: two\n\n").await;
                    return;
                }
                // Reads the whole body, by length or in chunks, and says how much came.
                ("POST", "/upload") => {
                    let mut body = match header(&head, "content-length") {
                        Some(n) => Framing::Length(n.parse().unwrap()),
                        None => Framing::Chunked(Chunked::new()),
                    };
                    let (mut total, mut sum) = (0usize, 0u64);
                    loop {
                        let (n, done) = body.take(&buf).unwrap();
                        total += n;
                        sum += buf[..n].iter().map(|b| u64::from(*b)).sum::<u64>();
                        seen.uploaded.fetch_add(n, Ordering::SeqCst);
                        buf.drain(..n);
                        if done {
                            break;
                        }
                        if s.read_buf(&mut buf).await.unwrap_or(0) == 0 {
                            return;
                        }
                    }
                    s.write_all(&fixed("200 OK", "", &format!("{total} {sum}"))).await
                }
                // A WebSocket's handshake, then every byte back as it came. The first bytes
                // of the new protocol leave in one piece with the head.
                ("GET", "/socket") if header(&head, "upgrade").is_some() => {
                    let _ = s.write_all(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n\x81\x05hello").await;
                    let _ = s.write_all(&std::mem::take(&mut buf)).await;
                    let (mut from, mut to) = s.split();
                    let _ = tokio::io::copy(&mut from, &mut to).await;
                    return;
                }
                // A server that changes protocols without being asked to.
                ("GET", "/rogue") => {
                    let _ = s.write_all(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: other\r\nConnection: Upgrade\r\n\r\nnot http any more").await;
                    return;
                }
                _ => s.write_all(&fixed("404 Not Found", "", "no such page")).await,
            };
            if sent.is_err() || header(&head, "connection").is_some_and(|c| c.eq_ignore_ascii_case("close")) {
                return;
            }
        }
    }

    /// One answer read off a connection that stays open: its head, and its body by its
    /// length.
    pub async fn answer(s: &mut TcpStream, buf: &mut Vec<u8>) -> (String, Vec<u8>) {
        let head = soon(head_of(s, buf)).await.expect("an answer");
        let n: usize = header(&head, "content-length").map_or(0, |n| n.parse().unwrap());
        while buf.len() < n {
            assert!(soon(s.read_buf(buf)).await.unwrap() > 0, "the body ended early");
        }
        let body = buf.drain(..n).collect();
        (head, body)
    }

    /// Sends `request` on a new connection to `to` and reads until the other side closes:
    /// the head and everything after it.
    pub async fn exchange(to: SocketAddr, request: &[u8]) -> (String, Vec<u8>) {
        let mut s = soon(TcpStream::connect(to)).await.unwrap();
        s.write_all(request).await.unwrap();
        let mut all = vec![];
        soon(s.read_to_end(&mut all)).await.unwrap();
        let end = all.windows(4).position(|w| w == b"\r\n\r\n").map_or(all.len(), |i| i + 4);
        (String::from_utf8_lossy(&all[..end]).into_owned(), all[end..].to_vec())
    }

    /// True when `request` sent to `to` gets nothing back: the connection is refused, or
    /// ends without a byte.
    pub async fn nothing(to: SocketAddr, request: &[u8]) -> bool {
        let Ok(mut s) = soon(TcpStream::connect(to)).await else { return true };
        let _ = s.write_all(request).await;
        let mut all = vec![];
        let _ = soon(s.read_to_end(&mut all)).await;
        all.is_empty()
    }

    /// A `GET` that asks the server to close after its answer.
    pub fn get(path: &str, host: &str) -> Vec<u8> {
        format!("GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n").into_bytes()
    }

    pub fn line<'a>(head: &'a str, name: &str) -> Option<&'a str> {
        header(head, name)
    }
}

#[cfg(test)]
mod tests {
    use super::testing::*;
    use super::*;
    use crate::waiting;
    use serde_json::json;
    use std::net::{Ipv4Addr, Ipv6Addr};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpStream;

    // Loopback stands in for the tailnet: the computer's tailnet addresses are 127.0.0.1
    // and ::1, its name there is desk.example.ts.net, and a phone may have any loopback
    // address. A test connects from 127.0.0.1, so a share for 127.0.0.1 lets it in and a
    // share for another phone drops it.
    const HERE: IpAddr = IpAddr::V4(Ipv4Addr::LOCALHOST);
    const OTHER_PHONE: IpAddr = IpAddr::V4(Ipv4Addr::new(127, 0, 0, 9));

    /// The length of the fixture's answer to a WebSocket handshake, with its first frame.
    const HANDSHAKE: usize = 84;

    fn shares() -> Arc<Shares> {
        Shares::new(Net::testing())
    }

    /// Opens a share of `dev`'s port, and waits until the dev server has counted the look
    /// that opening takes at whether it listens.
    async fn share(all: &Arc<Shares>, dev: &Dev, ask: Ask) -> Opened {
        let before = dev.seen.connections.load(Ordering::SeqCst);
        let opened = all.open(ask).await.unwrap();
        until(|| dev.seen.connections.load(Ordering::SeqCst) > before).await;
        opened
    }

    fn ask(port: u16) -> Ask {
        Ask { server: "rex".into(), block: "block:1".into(), port, device: "a1b2c3d4".into(), phone: HERE }
    }

    /// Where a test connects to reach a share.
    fn at(opened: &Opened) -> SocketAddr {
        SocketAddr::new(HERE, opened.port)
    }

    /// What a browser that opened the share's address sends as `Host`.
    fn host(opened: &Opened) -> String {
        opened.url.strip_prefix("http://").unwrap().to_string()
    }

    /// Lets every task that can run do so, without the clock moving.
    async fn settle() {
        for _ in 0..50 {
            tokio::task::yield_now().await;
        }
    }

    /// Waits, in real time, until `what` holds.
    async fn until(what: impl Fn() -> bool) {
        soon(async {
            while !what() {
                tokio::time::sleep(Duration::from_millis(2)).await;
            }
        })
        .await;
    }

    async fn read_n(s: &mut TcpStream, n: usize) -> Vec<u8> {
        let mut got = vec![0u8; n];
        soon(s.read_exact(&mut got)).await.expect("more bytes");
        got
    }

    /// True when a connection to `to` is refused, or closed without a byte.
    async fn shut(to: SocketAddr) -> bool {
        match soon(TcpStream::connect(to)).await {
            Err(_) => true,
            Ok(mut s) => {
                let _ = s.write_all(&get("/", &format!("desk.example.ts.net:{}", to.port()))).await;
                let mut got = vec![];
                let _ = soon(s.read_to_end(&mut got)).await;
                got.is_empty()
            }
        }
    }

    async fn has_v6() -> bool {
        tokio::net::TcpListener::bind((Ipv6Addr::LOCALHOST, 0)).await.is_ok()
    }

    #[tokio::test]
    async fn the_address_is_the_computers_name_when_the_tailnet_gives_names_and_its_address_otherwise() {
        let dev = Dev::start().await;
        let named = shares();
        let opened = named.open(ask(dev.port())).await.unwrap();
        assert_eq!(opened.url, format!("http://desk.example.ts.net:{}", opened.port));
        assert_eq!(opened.ip_url, format!("http://127.0.0.1:{}", opened.port));
        // A tailnet without names (MagicDNS off): the address is all there is.
        let mut net = Net::testing();
        net.fixed.as_mut().unwrap().name = None;
        let unnamed = Shares::new(net);
        let opened = unnamed.open(ask(dev.port())).await.unwrap();
        assert_eq!((opened.url.as_str(), opened.ip_url.as_str()), (format!("http://127.0.0.1:{}", opened.port).as_str(), opened.url.as_str()));
        // A phone that comes over IPv6 gets the computer's IPv6 address, in brackets.
        if has_v6().await {
            let opened = unnamed.open(Ask { phone: IpAddr::V6(Ipv6Addr::LOCALHOST), device: "ffff0000".into(), ..ask(dev.port()) }).await.unwrap();
            assert_eq!(opened.url, format!("http://[::1]:{}", opened.port));
        }
    }

    #[tokio::test]
    async fn a_computer_without_the_tailscale_client_shares_nothing() {
        let dev = Dev::start().await;
        // The client is not there, not running, or has no address.
        let none = Shares::new(Net::loopback(None));
        assert_eq!(none.open(ask(dev.port())).await, Err(Refusal::NotAvailable));
        // It has no address of the kind the phone comes from.
        let mut net = Net::testing();
        net.fixed.as_mut().unwrap().ips.truncate(1);
        let v4_only = Shares::new(net);
        assert_eq!(v4_only.open(Ask { phone: IpAddr::V6(Ipv6Addr::LOCALHOST), ..ask(dev.port()) }).await, Err(Refusal::NotAvailable));
        // An address no phone on the tailnet has (here: not loopback) is refused before
        // anything is looked up.
        for phone in ["192.168.1.20", "8.8.8.8", "0.0.0.0", "fe80::1"] {
            assert_eq!(none.open(Ask { phone: phone.parse().unwrap(), ..ask(dev.port()) }).await, Err(Refusal::BadPhone), "{phone}");
        }
        // And in a real run only Tailscale's ranges count as a phone's.
        let real = Net::tailnet();
        assert!((real.phone)("100.64.0.2".parse().unwrap()) && (real.phone)("fd7a:115c:a1e0::2".parse().unwrap()));
        assert!(!(real.phone)(HERE) && !(real.phone)("192.168.1.20".parse().unwrap()));
        assert_eq!((real.idle, real.waiting), (Duration::from_secs(1800), Duration::from_secs(600)));
        assert_eq!((none.count(), v4_only.count()), (0, 0));
    }

    #[tokio::test]
    async fn the_port_number_is_the_dev_servers_own_when_it_is_free_there() {
        // Taken: here the dev server itself holds the port on the address the share
        // listens on, as a server that listens on every address does on a real tailnet one.
        let dev = Dev::start().await;
        let all = shares();
        let opened = all.open(ask(dev.port())).await.unwrap();
        assert!(opened.port != dev.port() && !opened.same_port, "{opened:?}");
        let (head, _) = exchange(at(&opened), &get("/", &host(&opened))).await;
        assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
        // Free: the dev server listens on ::1 alone, so 127.0.0.1 has the same number free.
        // Where the system lets a share take it (macOS), it does; elsewhere (Linux) the
        // share's port is always one the system picks.
        if has_v6().await {
            let dev = Dev::on(tokio::net::TcpListener::bind((Ipv6Addr::LOCALHOST, 0)).await.unwrap());
            let opened = all.open(ask(dev.port())).await.unwrap();
            assert_eq!(opened.same_port, crate::platform::SAME_PORT);
            assert_eq!(opened.port == dev.port(), crate::platform::SAME_PORT);
            assert_eq!(opened.url, format!("http://desk.example.ts.net:{}", opened.port));
            // The share never connects to itself: the request arrives at the dev server.
            let (head, body) = exchange(at(&opened), &get("/", &host(&opened))).await;
            assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
            assert!(String::from_utf8_lossy(&body).starts_with(&format!("host=localhost:{}\n", dev.port())));
        }
        // A dev server that listens on every address of the computer, IPv4 or both kinds,
        // holds its number on the share's address too: the share gets another.
        for everywhere in ["0.0.0.0:0", "[::]:0"] {
            let Ok(listener) = tokio::net::TcpListener::bind(everywhere).await else { continue };
            let dev = Dev::on(listener);
            let opened = all.open(Ask { device: format!("0000000{}", everywhere.len()), ..ask(dev.port()) }).await.unwrap();
            assert!(opened.port != dev.port() && !opened.same_port, "{everywhere}: {opened:?}");
            let (head, _) = exchange(at(&opened), &get("/", &host(&opened))).await;
            assert!(head.starts_with("HTTP/1.1 200 OK"), "{everywhere}: {head}");
            dev.stop().await;
        }
        // Nothing listens: there is nothing to share, and no listener is left behind.
        let gone = Dev::start().await;
        let port = gone.port();
        gone.stop().await;
        let before = all.count();
        assert_eq!(all.open(ask(port)).await, Err(Refusal::NotListening));
        assert_eq!(all.count(), before);
    }

    #[tokio::test]
    async fn a_dev_server_that_checks_its_host_answers_through_the_share() {
        let dev = Dev::start().await;
        let all = shares();
        let opened = all.open(ask(dev.port())).await.unwrap();
        let name = host(&opened);
        // Asked as anything but localhost, the dev server turns the request away.
        let (head, body) = exchange(dev.addr, &get("/", &name)).await;
        assert!(head.starts_with("HTTP/1.1 403 Forbidden"), "{head}");
        assert_eq!(String::from_utf8_lossy(&body), format!("Blocked request. This host (\"{name}\") is not allowed."));
        // Through the share the same request is a local one, with its origin and referer.
        let request = format!("GET / HTTP/1.1\r\nHost: {name}\r\nOrigin: http://{name}\r\nReferer: http://{name}/page?x=1\r\nConnection: close\r\n\r\n");
        let (head, body) = exchange(at(&opened), request.as_bytes()).await;
        assert!(head.starts_with("HTTP/1.1 200 OK\r\n"), "{head}");
        let local = format!("localhost:{}", dev.port());
        assert_eq!(String::from_utf8_lossy(&body), format!("host={local}\norigin=http://{local}\nreferer=http://{local}/page?x=1\n"));
        // And what the answer names is the address the browser is on.
        let (head, _) = exchange(at(&opened), &get("/login", &name)).await;
        assert!(head.starts_with("HTTP/1.1 302 Found\r\n"), "{head}");
        assert_eq!(line(&head, "location"), Some(format!("http://{name}/home").as_str()));
        assert_eq!(line(&head, "set-cookie"), Some("sid=1; Path=/; HttpOnly"));
        assert_eq!(line(&head, "access-control-allow-origin"), Some(format!("http://{name}").as_str()));
        assert_eq!(line(&head, waiting::HEADER), None, "the dev server's own header of that name is taken out");
        // The browser came by address: it is sent on by address.
        let by_ip = opened.ip_url.strip_prefix("http://").unwrap();
        let (head, _) = exchange(at(&opened), &get("/login", by_ip)).await;
        assert_eq!(line(&head, "location"), Some(format!("http://{by_ip}/home").as_str()));
    }

    #[tokio::test]
    async fn one_connection_carries_request_after_request() {
        let dev = Dev::start().await;
        let all = shares();
        let opened = share(&all, &dev, ask(dev.port())).await;
        let name = host(&opened);
        let taken = dev.seen.connections.load(Ordering::SeqCst);
        let mut s = TcpStream::connect(at(&opened)).await.unwrap();
        let mut buf = vec![];
        let send = |path: &str, method: &str| format!("{method} {path} HTTP/1.1\r\nHost: {name}\r\n\r\n").into_bytes();
        s.write_all(&send("/", "GET")).await.unwrap();
        let (head, body) = answer(&mut s, &mut buf).await;
        assert!(head.starts_with("HTTP/1.1 200 OK") && body.starts_with(b"host=localhost:"), "{head}");
        // An answer to HEAD names a length and has no body: the next answer follows at once.
        s.write_all(&send("/anything", "HEAD")).await.unwrap();
        let head = soon(async {
            loop {
                if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
                    break String::from_utf8(buf.drain(..i + 4).collect()).unwrap();
                }
                s.read_buf(&mut buf).await.unwrap();
            }
        })
        .await;
        assert!(head.contains("Content-Length: 4096"), "{head}");
        // An interim answer comes first, then the real one, for the one request.
        s.write_all(&send("/hints", "GET")).await.unwrap();
        let (hints, nothing) = answer(&mut s, &mut buf).await;
        assert!(hints.starts_with("HTTP/1.1 103 Early Hints\r\nLink: </a.css>; rel=preload\r\n") && nothing.is_empty(), "{hints}");
        let (head, body) = answer(&mut s, &mut buf).await;
        assert!(head.starts_with("HTTP/1.1 200 OK") && body == b"after the hints", "{head}");
        // Two requests sent in one piece are answered in order.
        s.write_all(&[send("/nowhere", "GET"), send("/", "GET")].concat()).await.unwrap();
        let (first, _) = answer(&mut s, &mut buf).await;
        let (second, _) = answer(&mut s, &mut buf).await;
        assert!(first.starts_with("HTTP/1.1 404") && second.starts_with("HTTP/1.1 200"), "{first}{second}");
        assert_eq!(dev.seen.connections.load(Ordering::SeqCst), taken + 1, "all of it over one connection to the dev server");
        // The browser closes: the dev server's side closes with it.
        drop(s);
        until(|| all.connections() == 0).await;
    }

    #[tokio::test]
    async fn bodies_larger_than_any_buffer_pass_both_ways() {
        let dev = Dev::start().await;
        let all = shares();
        let opened = all.open(ask(dev.port())).await.unwrap();
        let name = host(&opened);
        const MB: usize = 1 << 20;
        // Down, by its length: 8 MB through buffers of some tens of kilobytes.
        let (head, body) = exchange(at(&opened), &get("/big/8", &name)).await;
        assert_eq!(line(&head, "content-length"), Some((8 * MB).to_string().as_str()));
        assert!(body == pattern(8 * MB), "8 MB came through as they were sent");
        // Up, by its length.
        let data = pattern(6 * MB + 123);
        let sum: u64 = data.iter().map(|b| u64::from(*b)).sum();
        let mut request = format!("POST /upload HTTP/1.1\r\nHost: {name}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", data.len()).into_bytes();
        request.extend_from_slice(&data);
        let (head, body) = exchange(at(&opened), &request).await;
        assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
        assert_eq!(String::from_utf8_lossy(&body), format!("{} {sum}", data.len()));
        // Up, in chunks of odd sizes with an extension and a trailer: the dev server gets
        // the body exactly as the browser cut it.
        let mut chunked = vec![];
        for (i, piece) in pattern(2 * MB).chunks(40_009).enumerate() {
            chunked.extend_from_slice(format!("{:x}{}\r\n", piece.len(), if i % 2 == 0 { ";n=1" } else { "" }).as_bytes());
            chunked.extend_from_slice(piece);
            chunked.extend_from_slice(b"\r\n");
        }
        chunked.extend_from_slice(b"0\r\nX-Sum: abc\r\n\r\n");
        let sum: u64 = chunked.iter().map(|b| u64::from(*b)).sum();
        let mut request = format!("POST /upload HTTP/1.1\r\nHost: {name}\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n").into_bytes();
        request.extend_from_slice(&chunked);
        let (_, body) = exchange(at(&opened), &request).await;
        assert_eq!(String::from_utf8_lossy(&body), format!("{} {sum}", chunked.len()));
    }

    #[tokio::test]
    async fn a_body_arrives_as_it_is_sent_not_when_it_is_whole() {
        let dev = Dev::start().await;
        let all = shares();
        let opened = all.open(ask(dev.port())).await.unwrap();
        let name = host(&opened);
        // A chunked answer whose second half the dev server has not sent yet: the first
        // half is already at the browser.
        let mut s = TcpStream::connect(at(&opened)).await.unwrap();
        s.write_all(&get("/slow", &name)).await.unwrap();
        let first = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nfirst \r\n";
        assert_eq!(read_n(&mut s, first.len()).await, first);
        dev.seen.go.notify_one();
        let mut rest = vec![];
        soon(s.read_to_end(&mut rest)).await.unwrap();
        assert_eq!(rest, b"6;note=1\r\nsecond\r\n0\r\nX-Trailer: done\r\n\r\n", "chunk sizes, the extension and the trailer as the dev server sent them");
        // An event stream has no length at all.
        let mut s = TcpStream::connect(at(&opened)).await.unwrap();
        s.write_all(&get("/events", &name)).await.unwrap();
        let first = b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: one\n\n";
        assert_eq!(read_n(&mut s, first.len()).await, first);
        dev.seen.go.notify_one();
        let mut rest = vec![];
        soon(s.read_to_end(&mut rest)).await.unwrap();
        assert_eq!(rest, b"data: two\n\n");
        // An upload whose second half the browser has not sent yet: the dev server already
        // has the first.
        let half = pattern(1 << 20);
        let mut s = TcpStream::connect(at(&opened)).await.unwrap();
        s.write_all(format!("POST /upload HTTP/1.1\r\nHost: {name}\r\nContent-Length: {}\r\n\r\n", 2 * half.len()).as_bytes()).await.unwrap();
        s.write_all(&half).await.unwrap();
        until(|| dev.seen.uploaded.load(Ordering::SeqCst) == half.len()).await;
        s.write_all(&half).await.unwrap();
        let (head, body) = answer(&mut s, &mut vec![]).await;
        assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
        assert!(String::from_utf8_lossy(&body).starts_with(&format!("{} ", 2 * half.len())));
    }

    #[tokio::test]
    async fn a_websocket_passes_through_untouched() {
        let dev = Dev::start().await;
        let all = shares();
        let opened = all.open(ask(dev.port())).await.unwrap();
        let name = host(&opened);
        let mut s = TcpStream::connect(at(&opened)).await.unwrap();
        let handshake = format!("GET /socket HTTP/1.1\r\nHost: {name}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nOrigin: http://{name}\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n");
        s.write_all(handshake.as_bytes()).await.unwrap();
        // The answer's head, and the first frame the dev server sent right behind it.
        let expected = b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n\x81\x05hello";
        assert_eq!(read_n(&mut s, expected.len()).await, expected);
        // From here every byte is the other protocol's: all 256 values, and text that looks
        // like HTTP, come back exactly as sent, whatever the pieces.
        let mut frames: Vec<u8> = (0..300_000u32).map(|i| (i.wrapping_mul(2_654_435_761) >> 13) as u8).collect();
        frames.extend_from_slice(b"GET / HTTP/1.1\r\nHost: evil.example\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n0\r\n\r\n");
        assert!((0..=255u8).all(|b| frames.contains(&b)));
        let (mut from, mut to) = s.split();
        let (sent, echoed) = tokio::join!(
            async {
                for piece in frames.chunks(7919) {
                    to.write_all(piece).await.unwrap();
                }
            },
            async {
                let mut got = vec![0u8; frames.len()];
                soon(from.read_exact(&mut got)).await.unwrap();
                got
            }
        );
        let _ = sent;
        assert!(echoed == frames, "the frames came back byte for byte");
        // Closing the browser's side closes the dev server's, and the connection is gone.
        to.shutdown().await.unwrap();
        let mut rest = vec![];
        soon(from.read_to_end(&mut rest)).await.unwrap();
        assert!(rest.is_empty());
        until(|| all.connections() == 0).await;
    }

    #[tokio::test]
    async fn only_the_phone_it_is_for_gets_in() {
        let dev = Dev::start().await;
        let all = shares();
        // A share for a phone at another address: this test's connection is not that phone.
        let other = share(&all, &dev, Ask { phone: OTHER_PHONE, device: "ffff0000".into(), ..ask(dev.port()) }).await;
        let (connections, requests) = (dev.seen.connections.load(Ordering::SeqCst), dev.seen.requests.load(Ordering::SeqCst));
        for _ in 0..3 {
            assert!(shut(at(&other)).await, "dropped without a byte");
        }
        assert_eq!(all.connections(), 0);
        assert_eq!((dev.seen.connections.load(Ordering::SeqCst), dev.seen.requests.load(Ordering::SeqCst)), (connections, requests), "nothing reached the dev server");
        // The share for this address answers.
        let mine = all.open(ask(dev.port())).await.unwrap();
        assert_ne!(mine.port, other.port);
        let (head, _) = exchange(at(&mine), &get("/", &host(&mine))).await;
        assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
        assert_eq!(all.count(), 2);
    }

    #[tokio::test]
    async fn at_most_eight_shares_and_one_per_phone_and_port() {
        let mut devs = vec![];
        for _ in 0..=MAX_SHARES {
            devs.push(Dev::start().await);
        }
        let all = shares();
        let mut opened = vec![];
        for (i, dev) in devs.iter().take(MAX_SHARES).enumerate() {
            let device = if i == 0 { "ffff0000" } else { "a1b2c3d4" };
            opened.push(all.open(Ask { device: device.into(), ..ask(dev.port()) }).await.unwrap());
        }
        assert_eq!((all.count(), MAX_SHARES), (8, 8));
        // The ninth is refused, whoever asks, and nothing was opened for it.
        let ninth = devs[MAX_SHARES].port();
        assert_eq!(all.open(ask(ninth)).await, Err(Refusal::Full));
        assert_eq!(all.open(Ask { device: "0000aaaa".into(), ..ask(ninth) }).await, Err(Refusal::Full));
        // Asking again for a port that is shared gives the share there is, also at the cap.
        assert_eq!(all.open(ask(devs[3].port())).await.unwrap(), opened[3]);
        assert_eq!(all.count(), 8);
        // A phone that asks again from another address gets a new share in the old one's place.
        let moved = all.open(Ask { phone: OTHER_PHONE, ..ask(devs[3].port()) }).await.unwrap();
        assert_eq!(all.count(), 8);
        settle().await;
        assert!(moved.port != opened[3].port || shut(at(&opened[3])).await);
        // One ends: there is room for the ninth.
        assert_eq!(all.device_gone("ffff0000"), 1);
        assert!(all.open(ask(ninth)).await.is_ok());
        assert_eq!(all.count(), 8);
    }

    #[tokio::test]
    async fn more_connections_than_a_share_allows_are_dropped() {
        let dev = Dev::start().await;
        let all = shares();
        let opened = share(&all, &dev, ask(dev.port())).await;
        let mut held = vec![];
        for _ in 0..MAX_CONNECTIONS {
            held.push(TcpStream::connect(at(&opened)).await.unwrap());
        }
        until(|| all.connections() == MAX_CONNECTIONS).await;
        // A connection that has asked for nothing has not reached the dev server either.
        let taken = dev.seen.connections.load(Ordering::SeqCst);
        assert!(shut(at(&opened)).await, "one more than the share allows is dropped");
        assert_eq!((all.connections(), dev.seen.connections.load(Ordering::SeqCst)), (MAX_CONNECTIONS, taken));
        // One closes: the next one is served.
        held.pop();
        until(|| all.connections() == MAX_CONNECTIONS - 1).await;
        let (head, _) = exchange(at(&opened), &get("/", &host(&opened))).await;
        assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
    }

    #[tokio::test]
    async fn a_request_the_share_cannot_pass_on_is_answered_by_the_share() {
        let dev = Dev::start().await;
        let all = shares();
        let opened = share(&all, &dev, ask(dev.port())).await;
        let name = host(&opened);
        let connections = dev.seen.connections.load(Ordering::SeqCst);
        // A head longer than the share holds.
        let long = format!("GET / HTTP/1.1\r\nHost: {name}\r\nCookie: {}\r\n\r\n", "c".repeat(proxy::HEAD_MAX));
        let (head, _) = exchange(at(&opened), long.as_bytes()).await;
        assert!(head.starts_with("HTTP/1.1 431 "), "{head}");
        // A body with two ends, two hosts, and what is not HTTP at all.
        for bad in [
            format!("POST /upload HTTP/1.1\r\nHost: {name}\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"),
            format!("GET / HTTP/1.1\r\nHost: {name}\r\nHost: localhost\r\n\r\n"),
            "SSH-2.0-OpenSSH_9.9\r\n\r\n".to_string(),
            "*1\r\n$4\r\nPING\r\n\r\n".to_string(),
            format!("GET http://{name}/ HTTP/1.1\r\nHost: {name}\r\n\r\n"),
            format!("POST /upload HTTP/1.0\r\nHost: {name}\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"),
        ] {
            let (head, _) = exchange(at(&opened), bad.as_bytes()).await;
            assert!(head.starts_with("HTTP/1.1 400 Bad Request\r\n") && head.contains("Connection: close"), "{bad:?}: {head}");
        }
        // A body whose chunks are not written as HTTP writes them: the browser is told.
        let before = dev.seen.connections.load(Ordering::SeqCst);
        for body in ["5 \r\nhello\r\n0\r\n\r\n", "zz\r\n", "5\r\nhelloXX0\r\n\r\n"] {
            let request = format!("POST /upload HTTP/1.1\r\nHost: {name}\r\nTransfer-Encoding: chunked\r\n\r\n{body}");
            let (head, _) = exchange(at(&opened), request.as_bytes()).await;
            assert!(head.starts_with("HTTP/1.1 400 Bad Request\r\n"), "{body:?}: {head}");
        }
        // An answer that changes protocols when the request did not ask to: nothing of it
        // reaches the browser.
        assert!(nothing(at(&opened), &get("/rogue", &name)).await);
        let (connections, requests) = (connections + dev.seen.connections.load(Ordering::SeqCst) - before, dev.seen.requests.load(Ordering::SeqCst));
        // A request for another host that was pointed at this address: the dev server's
        // own check would have refused it, so the share does.
        for foreign in ["evil.example", &format!("evil.example:{}", opened.port), &format!("localhost:{}", dev.port()), &format!("localhost:{}", opened.port)] {
            let (head, _) = exchange(at(&opened), &get("/", foreign)).await;
            assert!(head.starts_with("HTTP/1.1 421 Misdirected Request\r\n"), "{foreign}: {head}");
        }
        // The name's first part is the share's too.
        let (head, _) = exchange(at(&opened), &get("/", &format!("desk:{}", opened.port))).await;
        assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
        let (connections, requests) = (connections + 1, requests + 1);
        assert_eq!((dev.seen.connections.load(Ordering::SeqCst), dev.seen.requests.load(Ordering::SeqCst)), (connections, requests), "none of it reached the dev server");
        until(|| all.connections() == 0).await;
    }

    #[tokio::test]
    async fn a_share_ends_half_an_hour_after_its_last_connection() {
        let dev = Dev::start().await;
        let all = shares();
        let opened = all.open(ask(dev.port())).await.unwrap();
        // A live-reload socket is open, with nothing on it: the share stays, for hours.
        let mut idle = TcpStream::connect(at(&opened)).await.unwrap();
        idle.write_all(format!("GET /socket HTTP/1.1\r\nHost: {}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n", host(&opened)).as_bytes()).await.unwrap();
        assert!(read_n(&mut idle, HANDSHAKE).await.starts_with(b"HTTP/1.1 101 "));
        assert_eq!(all.connections(), 1);
        tokio::time::pause();
        tokio::time::advance(IDLE * 6).await;
        settle().await;
        assert_eq!(all.count(), 1, "an open connection keeps its share");
        tokio::time::resume();
        drop(idle);
        until(|| all.connections() == 0).await;
        // From the moment it closed: a second short of half an hour the share is there.
        tokio::time::pause();
        tokio::time::advance(IDLE - Duration::from_secs(1)).await;
        settle().await;
        assert_eq!(all.count(), 1);
        // The phone asks for it again: the half hour starts over.
        assert_eq!(all.open(ask(dev.port())).await.unwrap(), opened);
        tokio::time::advance(IDLE - Duration::from_secs(1)).await;
        settle().await;
        assert_eq!(all.count(), 1);
        tokio::time::advance(Duration::from_secs(2)).await;
        settle().await;
        assert_eq!(all.count(), 0, "half an hour without a connection ends it");
        tokio::time::resume();
        assert!(shut(at(&opened)).await, "its listener is closed");
        // A share nobody ever connected to ends the same way.
        let opened = all.open(ask(dev.port())).await.unwrap();
        tokio::time::pause();
        tokio::time::advance(IDLE + Duration::from_secs(1)).await;
        settle().await;
        assert_eq!(all.count(), 0);
        tokio::time::resume();
        assert!(shut(at(&opened)).await);
    }

    #[tokio::test]
    async fn when_the_dev_server_stops_the_share_answers_with_the_waiting_page() {
        let dev = Dev::start().await;
        let (addr, port) = (dev.addr, dev.port());
        let all = shares();
        let opened = all.open(ask(port)).await.unwrap();
        let name = host(&opened);
        let (head, _) = exchange(at(&opened), &get("/", &name)).await;
        assert!(head.starts_with("HTTP/1.1 200 OK") && line(&head, waiting::HEADER).is_none(), "{head}");
        assert_eq!(all.waiting(), 0);
        dev.stop().await;
        // A page load gets the page.
        let (head, body) = exchange(at(&opened), &get("/some/page?x=1", &name)).await;
        assert!(head.starts_with("HTTP/1.1 503 Service Unavailable\r\n"), "{head}");
        assert_eq!((line(&head, "retry-after"), line(&head, "cache-control"), line(&head, waiting::HEADER)), (Some("5"), Some("no-store"), Some("1")));
        assert_eq!(line(&head, "content-type"), Some("text/html; charset=utf-8"));
        let page = String::from_utf8(body).unwrap();
        assert_eq!(page, waiting::page(port, "desk"));
        assert!(page.contains(&format!("<p>Nothing is running on localhost:{port} on desk right now.</p>")) && page.len() < 8 * 1024, "{} bytes", page.len());
        assert_eq!((all.waiting(), all.count()), (1, 1));
        // Anything else gets the status alone: a form sent, a script's request for data
        // by another method, a live-reload socket.
        let post = format!("POST /api HTTP/1.1\r\nHost: {name}\r\nContent-Length: 5\r\n\r\nhello");
        let socket = format!("GET /socket HTTP/1.1\r\nHost: {name}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n");
        let head_only = format!("HEAD / HTTP/1.1\r\nHost: {name}\r\n\r\n");
        for request in [post, socket, head_only] {
            let (head, body) = exchange(at(&opened), request.as_bytes()).await;
            assert!(head.starts_with("HTTP/1.1 503 ") && body.is_empty(), "{request:?}: {head}");
            assert_eq!((line(&head, waiting::HEADER), line(&head, "retry-after"), line(&head, "content-length")), (Some("1"), Some("5"), Some("0")));
        }
        // The dev server is started again on its port: the very next request is piped, and
        // the answer no longer carries the header, which is what the page's script looks for.
        let dev = Dev::on(tokio::net::TcpListener::bind(addr).await.unwrap());
        let (head, body) = exchange(at(&opened), &get("/", &name)).await;
        assert!(head.starts_with("HTTP/1.1 200 OK") && line(&head, waiting::HEADER).is_none(), "{head}");
        assert!(body.starts_with(b"host=localhost:"));
        assert_eq!((all.waiting(), all.count()), (0, 1));
        dev.stop().await;
    }

    #[tokio::test]
    async fn the_waiting_page_shows_a_hostile_computer_name_as_text() {
        let dev = Dev::start().await;
        let mut net = Net::testing();
        net.fixed.as_mut().unwrap().machine = "<img src=x onerror=alert(1)>\"'&".into();
        let all = Shares::new(net);
        let opened = all.open(ask(dev.port())).await.unwrap();
        dev.stop().await;
        let (_, body) = exchange(at(&opened), &get("/", &host(&opened))).await;
        let page = String::from_utf8(body).unwrap();
        assert!(page.contains(" on &lt;img src=x onerror=alert(1)&gt;&quot;&#39;&amp; right now."), "{page}");
        assert!(!page.contains("<img") && page.matches("<script").count() == 1 && page.len() < 8 * 1024);
    }

    #[tokio::test]
    async fn a_share_whose_port_stays_silent_ends_after_ten_minutes() {
        let dev = Dev::start().await;
        let addr = dev.addr;
        let all = shares();
        let opened = all.open(ask(dev.port())).await.unwrap();
        let name = host(&opened);
        dev.stop().await;
        let (head, _) = exchange(at(&opened), &get("/", &name)).await;
        assert!(head.starts_with("HTTP/1.1 503 "), "{head}");
        until(|| all.connections() == 0).await;
        // It listens again within the ten minutes: the wait is over, and only the half
        // hour without a connection counts.
        tokio::time::pause();
        tokio::time::advance(WAITING - Duration::from_secs(1)).await;
        settle().await;
        assert_eq!((all.count(), all.waiting()), (1, 1));
        tokio::time::resume();
        let dev = Dev::on(tokio::net::TcpListener::bind(addr).await.unwrap());
        let (head, _) = exchange(at(&opened), &get("/", &name)).await;
        assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
        until(|| all.connections() == 0).await;
        tokio::time::pause();
        tokio::time::advance(WAITING * 2).await;
        settle().await;
        assert_eq!((all.count(), all.waiting()), (1, 0));
        tokio::time::resume();
        // It stops for good. A page that stays open keeps asking, and each answer is the
        // waiting page; the ten minutes run from the first of them all the same.
        dev.stop().await;
        let (head, _) = exchange(at(&opened), &get("/", &name)).await;
        assert!(head.starts_with("HTTP/1.1 503 "), "{head}");
        until(|| all.connections() == 0).await;
        tokio::time::pause();
        tokio::time::advance(WAITING / 2).await;
        tokio::time::resume();
        let (head, _) = exchange(at(&opened), &get("/", &name)).await;
        assert!(head.starts_with("HTTP/1.1 503 "), "{head}");
        until(|| all.connections() == 0).await;
        tokio::time::pause();
        tokio::time::advance(WAITING / 2 - Duration::from_secs(2)).await;
        settle().await;
        assert_eq!(all.count(), 1);
        tokio::time::advance(Duration::from_secs(4)).await;
        settle().await;
        assert_eq!(all.count(), 0, "ten minutes of nothing on the port end the share");
        tokio::time::resume();
        assert!(shut(at(&opened)).await);
    }

    #[tokio::test]
    async fn rex_saying_the_port_left_its_pane_starts_the_wait_without_a_connection() {
        let dev = Dev::start().await;
        let port = dev.port();
        let all = shares();
        let opened = all.open(ask(port)).await.unwrap();
        let listing = |ports: &[u16], status: &str| json!({"status": status, "ports": ports.iter().map(|p| json!({"port": p, "protocol": "tcp", "address": "127.0.0.1"})).collect::<Vec<_>>()});
        // Another pane's list, another server's, a list that still has the port, and a
        // list that is not whole say nothing against the share.
        all.ports_changed("rex", "block:2", &listing(&[], "ok"));
        all.ports_changed("other", "block:1", &listing(&[], "ok"));
        all.ports_changed("rex", "block:1", &listing(&[port, 9], "ok"));
        all.ports_changed("rex", "block:1", &listing(&[9], "partial"));
        assert_eq!(all.waiting(), 0);
        // The pane's whole list without the port: the share waits.
        all.ports_changed("rex", "block:1", &listing(&[9], "ok"));
        assert_eq!(all.waiting(), 1);
        // The port is back in the list: it waits no more.
        all.ports_changed("rex", "block:1", &listing(&[port], "ok"));
        assert_eq!(all.waiting(), 0);
        // A UDP port of the same number is not the dev server.
        all.ports_changed("rex", "block:1", &json!({"status": "ok", "ports": [{"port": port, "protocol": "udp"}]}));
        assert_eq!(all.waiting(), 1);
        // A connection that finds the dev server there ends the wait as well.
        let (head, _) = exchange(at(&opened), &get("/", &host(&opened))).await;
        assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
        assert_eq!(all.waiting(), 0);
        // The pane closes, and nobody connects: ten minutes later the share is gone.
        all.block_closed("rex", "block:2");
        assert_eq!(all.waiting(), 0);
        all.block_closed("rex", "block:1");
        assert_eq!(all.waiting(), 1);
        until(|| all.connections() == 0).await;
        tokio::time::pause();
        tokio::time::advance(WAITING - Duration::from_secs(1)).await;
        settle().await;
        assert_eq!(all.count(), 1);
        tokio::time::advance(Duration::from_secs(2)).await;
        settle().await;
        assert_eq!(all.count(), 0);
    }

    #[tokio::test]
    async fn a_phone_that_is_gone_and_a_stop_close_every_share_and_its_connections() {
        let dev = Dev::start().await;
        let other = Dev::start().await;
        let all = shares();
        let mine = all.open(ask(dev.port())).await.unwrap();
        let second = all.open(ask(other.port())).await.unwrap();
        let theirs = all.open(Ask { device: "ffff0000".into(), ..ask(dev.port()) }).await;
        // The same phone address and port for another device is the same listener's port
        // taken: it gets a port of its own.
        let theirs = theirs.unwrap();
        assert_eq!(all.count(), 3);
        // A live-reload socket on each.
        let mut sockets = vec![];
        for opened in [&mine, &second, &theirs] {
            let mut s = TcpStream::connect(at(opened)).await.unwrap();
            s.write_all(format!("GET /socket HTTP/1.1\r\nHost: {}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n", host(opened)).as_bytes()).await.unwrap();
            let head = read_n(&mut s, HANDSHAKE).await;
            assert!(head.starts_with(b"HTTP/1.1 101 "), "{}", String::from_utf8_lossy(&head));
            sockets.push(s);
        }
        assert_eq!(all.connections(), 3);
        // The phone unregisters: both of its shares go, with their open sockets, and the
        // other phone's stays.
        assert_eq!(all.device_gone("a1b2c3d4"), 2);
        assert_eq!(all.count(), 1);
        for s in sockets.iter_mut().take(2) {
            let mut rest = vec![];
            let _ = soon(s.read_to_end(&mut rest)).await;
            assert!(rest.is_empty(), "the socket ended");
        }
        assert!(shut(at(&mine)).await && shut(at(&second)).await, "nothing listens there any more");
        sockets[2].write_all(b"still here").await.unwrap();
        assert_eq!(read_n(&mut sockets[2], 10).await, b"still here");
        // Beacon stops: nothing is left.
        assert_eq!(all.close_all(), 1);
        assert_eq!(all.count(), 0);
        let mut rest = vec![];
        let _ = soon(sockets[2].read_to_end(&mut rest)).await;
        assert!(rest.is_empty() && shut(at(&theirs)).await);
    }

    #[tokio::test]
    async fn a_connection_that_asks_for_nothing_is_not_kept() {
        let dev = Dev::start().await;
        let all = shares();
        let opened = share(&all, &dev, ask(dev.port())).await;
        let name = host(&opened);
        let taken = dev.seen.connections.load(Ordering::SeqCst);
        // Silent from the start, and silent after half a request.
        let mut silent = TcpStream::connect(at(&opened)).await.unwrap();
        let mut half = TcpStream::connect(at(&opened)).await.unwrap();
        half.write_all(b"GET / HTTP/1.1\r\nHost: de").await.unwrap();
        // One that got its answer and then asks for nothing more.
        let mut done = TcpStream::connect(at(&opened)).await.unwrap();
        done.write_all(format!("GET / HTTP/1.1\r\nHost: {name}\r\n\r\n").as_bytes()).await.unwrap();
        answer(&mut done, &mut vec![]).await;
        // One whose answer is still coming, however quiet it is (an event stream), and a
        // live-reload socket: these are in use.
        let mut events = TcpStream::connect(at(&opened)).await.unwrap();
        events.write_all(format!("GET /events HTTP/1.1\r\nHost: {name}\r\n\r\n").as_bytes()).await.unwrap();
        read_n(&mut events, b"HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\ndata: one\n\n".len()).await;
        let mut socket = TcpStream::connect(at(&opened)).await.unwrap();
        socket.write_all(format!("GET /socket HTTP/1.1\r\nHost: {name}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n").as_bytes()).await.unwrap();
        read_n(&mut socket, HANDSHAKE).await;
        until(|| all.connections() == 5).await;
        tokio::time::pause();
        tokio::time::advance(proxy::HEAD_WAIT - Duration::from_secs(1)).await;
        settle().await;
        assert_eq!(all.connections(), 5, "a second short of the wait they are all there");
        tokio::time::advance(Duration::from_secs(2)).await;
        settle().await;
        assert_eq!(all.connections(), 2, "the three that ask for nothing are closed");
        tokio::time::advance(proxy::HEAD_WAIT * 20).await;
        settle().await;
        assert_eq!(all.connections(), 2);
        tokio::time::resume();
        for closed in [&mut silent, &mut half, &mut done] {
            let mut rest = vec![];
            let _ = soon(closed.read_to_end(&mut rest)).await;
            assert!(rest.is_empty());
        }
        // The silent ones never reached the dev server.
        assert_eq!(dev.seen.connections.load(Ordering::SeqCst), taken + 3);
        // The two in use still work.
        dev.seen.go.notify_one();
        assert_eq!(read_n(&mut events, 11).await, b"data: two\n\n");
        socket.write_all(b"ping").await.unwrap();
        assert_eq!(read_n(&mut socket, 4).await, b"ping");
        // With the socket closed and the stream over, the share's half hour runs.
        drop((socket, events));
        until(|| all.connections() == 0).await;
        tokio::time::pause();
        tokio::time::advance(IDLE + Duration::from_secs(1)).await;
        settle().await;
        assert_eq!(all.count(), 0);
    }

    #[tokio::test]
    async fn all_shares_together_hold_at_most_sixty_four_connections() {
        let dev = Dev::start().await;
        let all = shares();
        let mut opened = vec![];
        for device in ["a1b2c3d4", "ffff0000", "0000aaaa"] {
            opened.push(share(&all, &dev, Ask { device: device.into(), ..ask(dev.port()) }).await);
        }
        assert_eq!((MAX_ALL_CONNECTIONS, 2 * MAX_CONNECTIONS), (64, 64));
        let mut held = vec![];
        for _ in 0..MAX_CONNECTIONS {
            held.push(TcpStream::connect(at(&opened[0])).await.unwrap());
            held.push(TcpStream::connect(at(&opened[1])).await.unwrap());
        }
        until(|| all.connections() == MAX_ALL_CONNECTIONS).await;
        // The third share has none of its own, and still gets none.
        assert!(shut(at(&opened[2])).await);
        assert_eq!(all.connections(), MAX_ALL_CONNECTIONS);
        held.truncate(MAX_ALL_CONNECTIONS - 2);
        until(|| all.connections() == MAX_ALL_CONNECTIONS - 2).await;
        let (head, _) = exchange(at(&opened[2]), &get("/", &host(&opened[2]))).await;
        assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
        // Every share closed: nothing is counted any more.
        drop(held);
        all.close_all();
        until(|| all.all.load(Ordering::SeqCst) == 0).await;
    }

    #[tokio::test]
    async fn two_requests_for_the_same_share_at_once_make_one() {
        let dev = Dev::start().await;
        let all = shares();
        let (a, b, c) = tokio::join!(all.open(ask(dev.port())), all.open(ask(dev.port())), all.open(ask(dev.port())));
        let (a, b, c) = (a.unwrap(), b.unwrap(), c.unwrap());
        assert_eq!((&a, &b), (&b, &c));
        assert_eq!(all.count(), 1);
        // Also at the cap: eight requests at once for eight ports, and a ninth.
        let mut devs = vec![];
        for _ in 0..MAX_SHARES {
            devs.push(Dev::start().await);
        }
        let mut asks = tokio::task::JoinSet::new();
        for dev in &devs {
            let (all, port) = (all.clone(), dev.port());
            asks.spawn(async move { all.open(ask(port)).await });
        }
        let results = asks.join_all().await;
        assert_eq!(results.iter().filter(|r| r.is_ok()).count(), MAX_SHARES - 1);
        assert_eq!(results.iter().filter(|r| **r == Err(Refusal::Full)).count(), 1);
        assert_eq!(all.count(), MAX_SHARES);
    }

    #[tokio::test]
    async fn a_phone_is_known_by_its_address_however_that_is_written() {
        assert!(is_phone("127.0.0.1".parse().unwrap(), "127.0.0.1".parse().unwrap()));
        // A connection that arrives on a socket of both kinds shows an IPv4 peer as an
        // IPv6 one; it is the same phone. Any other address is not.
        assert!(is_phone("::ffff:127.0.0.1".parse().unwrap(), "127.0.0.1".parse().unwrap()));
        assert!(is_phone("100.64.0.2".parse().unwrap(), "::ffff:100.64.0.2".parse().unwrap()));
        assert!(is_phone("fd7a:115c:a1e0::2".parse().unwrap(), "fd7a:115c:a1e0:0::2".parse().unwrap()));
        for (peer, phone) in [("127.0.0.2", "127.0.0.1"), ("::1", "127.0.0.1"), ("::ffff:127.0.0.2", "127.0.0.1"), ("fd7a:115c:a1e0::3", "fd7a:115c:a1e0::2"), ("::ffff:100.64.0.3", "100.64.0.2")] {
            assert!(!is_phone(peer.parse().unwrap(), phone.parse().unwrap()), "{peer} {phone}");
        }
        // A phone that gives its IPv4 address written as an IPv6 one gets a share on the
        // computer's IPv4 address, which is where it will come from.
        let dev = Dev::start().await;
        let all = shares();
        let opened = all.open(Ask { phone: "::ffff:127.0.0.1".parse().unwrap(), ..ask(dev.port()) }).await.unwrap();
        assert_eq!(opened.ip_url, format!("http://127.0.0.1:{}", opened.port));
        let (head, _) = exchange(at(&opened), &get("/", &host(&opened))).await;
        assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
        // A phone on IPv6: the share listens on the computer's IPv6 address, takes the
        // phone from there, and is not there at all on IPv4.
        if has_v6().await {
            let opened = all.open(Ask { phone: IpAddr::V6(Ipv6Addr::LOCALHOST), device: "ffff0000".into(), ..ask(dev.port()) }).await.unwrap();
            let v6 = SocketAddr::new(IpAddr::V6(Ipv6Addr::LOCALHOST), opened.port);
            let (head, body) = exchange(v6, &get("/", &format!("[::1]:{}", opened.port))).await;
            assert!(head.starts_with("HTTP/1.1 200 OK") && body.starts_with(b"host=localhost:"), "{head}");
            // (On IPv4 that number is nobody's, or the dev server's own.)
            assert!(opened.port == dev.port() || soon(TcpStream::connect(at(&opened))).await.is_err());
        }
    }

    #[tokio::test]
    async fn a_share_is_only_for_a_device_of_this_computers_own_user() {
        let dev = Dev::start().await;
        // Tailscale says the address is another user's device, a tagged one, or it knows
        // no such address (or could not be asked): no share.
        for theirs in [Some(2002), None] {
            let all = Shares::new(Net { who: Asked::Fixed(theirs), ..Net::testing() });
            assert_eq!(all.open(ask(dev.port())).await, Err(Refusal::NotYourPhone), "{theirs:?}");
            assert_eq!(all.count(), 0);
        }
        // This computer is a tagged one: it has no user for a phone to share.
        let mut net = Net::testing();
        net.fixed.as_mut().unwrap().user = None;
        for phone in [Some(1001), None] {
            let all = Shares::new(Net { who: Asked::Fixed(phone), ..net.clone() });
            assert_eq!(all.open(ask(dev.port())).await, Err(Refusal::NotYourPhone));
        }
        // A test never asks the real client: unasked, nobody is known.
        let all = Shares::new(Net { who: Asked::System, ..Net::testing() });
        assert_eq!(all.open(ask(dev.port())).await, Err(Refusal::NotYourPhone));
        assert!(same_user(Some(1001), Some(1001)) && !same_user(Some(1001), Some(2002)));
    }

    #[tokio::test]
    async fn only_a_port_this_user_listens_on_is_shared() {
        // The system's ports, and the usual ports of what is no page for a phone.
        for refused in [1, 22, 25, 53, 443, 631, 1023, 2181, 2375, 3306, 5432, 5672, 6379, 8001, 8384, 9092, 9222, 9223, 9225, 9228, 9229, 9230, 9231, 9239, 11211, 11434, 27017] {
            assert!(is_refused_port(refused), "{refused}");
        }
        for fine in [80, 1024, 3000, 4321, 5173, 8000, 8080, 8443, 9000, 9221, 9240, 65535] {
            assert!(!is_refused_port(fine), "{fine}");
        }
        let dev = Dev::start().await;
        let all = shares();
        assert_eq!(all.open(ask(443)).await, Err(Refusal::NotYourPort));
        assert_eq!(all.open(ask(9229)).await, Err(Refusal::NotYourPort));
        // Something listens there, but it is not a process of this user.
        let others = Shares::new(Net { holder: Asked::Fixed(false), ..Net::testing() });
        assert_eq!(others.open(ask(dev.port())).await, Err(Refusal::NotYourPort));
        // Nothing listens there at all.
        let gone = Dev::start().await;
        let silent = gone.port();
        gone.stop().await;
        assert_eq!(others.open(ask(silent)).await, Err(Refusal::NotListening));
        assert_eq!((all.count(), others.count()), (0, 0));
        // Asked of the system itself: this test's own dev server is this user's.
        let real = Shares::new(Net { holder: Asked::System, ..Net::testing() });
        let (tool, _) = crate::platform::listener_query(dev.port());
        if crate::tools::program(std::path::Path::new(tool)).is_some() {
            let opened = real.open(ask(dev.port())).await.expect("the system names this process as the listener");
            let (head, _) = exchange(at(&opened), &get("/", &host(&opened))).await;
            assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
            assert_eq!(real.open(ask(silent)).await, Err(Refusal::NotListening));
        }
    }

    #[tokio::test]
    async fn a_phone_that_is_no_longer_registered_is_not_served() {
        let dev = Dev::start().await;
        let all = shares();
        let mine = all.open(ask(dev.port())).await.unwrap();
        let theirs = all.open(Ask { device: "ffff0000".into(), ..ask(dev.port()) }).await.unwrap();
        let gone = Arc::new(Mutex::new(Vec::<String>::new()));
        let list = gone.clone();
        all.watch_registrations(move |id| !list.lock().unwrap().iter().any(|g| g == id));
        let (head, _) = exchange(at(&mine), &get("/", &host(&mine))).await;
        assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
        // The phone was removed behind Beacon's back, and nothing has told the share: its
        // next connection gets nothing, and the share is over.
        let taken = dev.seen.connections.load(Ordering::SeqCst);
        gone.lock().unwrap().push("a1b2c3d4".into());
        assert!(shut(at(&mine)).await);
        until(|| all.count() == 1).await;
        assert!(shut(at(&mine)).await, "its listener is closed");
        assert_eq!(dev.seen.connections.load(Ordering::SeqCst), taken);
        let (head, _) = exchange(at(&theirs), &get("/", &host(&theirs))).await;
        assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
        // Told outright which phones are left.
        assert_eq!(all.keep_devices(|id| id == "a1b2c3d4"), 1);
        assert_eq!(all.count(), 0);
    }

    /// The middle and the 95th of a hundred, in microseconds.
    fn spread(mut times: Vec<Duration>) -> (u128, u128) {
        times.sort();
        (times[times.len() / 2].as_micros(), times[times.len() * 95 / 100].as_micros())
    }

    #[tokio::test]
    async fn the_share_adds_little_time_to_a_request() {
        let dev = Dev::start().await;
        let all = shares();
        let opened = all.open(ask(dev.port())).await.unwrap();
        let (direct, shared) = (get("/", &format!("localhost:{}", dev.port())), get("/", &host(&opened)));
        const ROUNDS: usize = 100;
        // Each request on a connection of its own: the share connects on to the dev server
        // every time, which is its most expensive case.
        let (mut plain, mut through) = (vec![], vec![]);
        for round in 0..ROUNDS + 10 {
            let began = std::time::Instant::now();
            let (head, _) = exchange(dev.addr, &direct).await;
            let middle = std::time::Instant::now();
            let (shared_head, _) = exchange(at(&opened), &shared).await;
            let ended = std::time::Instant::now();
            assert!(head.starts_with("HTTP/1.1 200") && shared_head.starts_with("HTTP/1.1 200"));
            // The first ten warm things up.
            if round >= 10 {
                plain.push(middle - began);
                through.push(ended - middle);
            }
        }
        let (plain_new, through_new) = (spread(plain), spread(through));
        // And on one connection that stays open, as a browser loads a page's files.
        let keep = |host: String| format!("GET / HTTP/1.1\r\nHost: {host}\r\n\r\n").into_bytes();
        let (direct, shared) = (keep(format!("localhost:{}", dev.port())), keep(host(&opened)));
        let mut a = TcpStream::connect(dev.addr).await.unwrap();
        let mut b = TcpStream::connect(at(&opened)).await.unwrap();
        a.set_nodelay(true).unwrap();
        b.set_nodelay(true).unwrap();
        let (mut plain, mut through, mut buf) = (vec![], vec![], vec![]);
        for round in 0..ROUNDS + 10 {
            let began = std::time::Instant::now();
            a.write_all(&direct).await.unwrap();
            answer(&mut a, &mut buf).await;
            let middle = std::time::Instant::now();
            b.write_all(&shared).await.unwrap();
            answer(&mut b, &mut buf).await;
            let ended = std::time::Instant::now();
            if round >= 10 {
                plain.push(middle - began);
                through.push(ended - middle);
            }
        }
        let (plain_kept, through_kept) = (spread(plain), spread(through));
        println!(
            "latency over {ROUNDS} requests, microseconds (median, p95): new connection direct {plain_new:?}, shared {through_new:?}; kept connection direct {plain_kept:?}, shared {through_kept:?}"
        );
        // The bar: under 2 ms added to the usual request, which is one on a connection the
        // browser already has. (A new connection costs one more connect on the loopback;
        // its numbers are printed, and how long that takes is the system's to say.)
        let added = through_kept.0.saturating_sub(plain_kept.0);
        assert!(added < 2000, "the share added {added} us to the median request");
        let _ = (plain_new, through_new);
    }

    #[tokio::test]
    async fn a_hundred_requests_pass_beside_an_open_websocket() {
        let dev = Dev::start().await;
        let all = shares();
        let opened = all.open(ask(dev.port())).await.unwrap();
        let name = host(&opened);
        let mut socket = TcpStream::connect(at(&opened)).await.unwrap();
        socket.write_all(format!("GET /socket HTTP/1.1\r\nHost: {name}\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n").as_bytes()).await.unwrap();
        assert!(read_n(&mut socket, HANDSHAKE).await.starts_with(b"HTTP/1.1 101 "));
        let before = dev.seen.requests.load(Ordering::SeqCst);
        // Six connections at once, as a browser opens them, with a hundred requests
        // between them, some large; the socket is used all the while.
        let mut browsers = tokio::task::JoinSet::new();
        for worker in 0..6usize {
            let (to, name) = (at(&opened), name.clone());
            browsers.spawn(async move {
                let mut s = TcpStream::connect(to).await.unwrap();
                let (mut buf, mut done) = (vec![], 0);
                for i in (worker..100).step_by(6) {
                    let path = if i % 10 == 0 { "/big/1" } else { "/" };
                    s.write_all(format!("GET {path} HTTP/1.1\r\nHost: {name}\r\n\r\n").as_bytes()).await.unwrap();
                    let (head, body) = answer(&mut s, &mut buf).await;
                    assert!(head.starts_with("HTTP/1.1 200 OK"), "{head}");
                    if path == "/" {
                        assert!(body.starts_with(b"host=localhost:"));
                    } else {
                        assert!(body == pattern(1 << 20));
                    }
                    done += 1;
                }
                done
            });
        }
        let mut pings = 0;
        let mut done = 0;
        while done < 100 {
            tokio::select! {
                Some(finished) = browsers.join_next() => done += finished.unwrap(),
                _ = tokio::time::sleep(Duration::from_millis(1)) => {
                    let frame = format!("ping {pings:06}");
                    socket.write_all(frame.as_bytes()).await.unwrap();
                    assert_eq!(read_n(&mut socket, frame.len()).await, frame.as_bytes());
                    pings += 1;
                }
            }
        }
        assert_eq!(dev.seen.requests.load(Ordering::SeqCst) - before, 100);
        assert!(pings > 0);
        // The socket still works when the page has loaded.
        socket.write_all(b"after").await.unwrap();
        assert_eq!(read_n(&mut socket, 5).await, b"after");
        until(|| all.connections() == 1).await;
        assert_eq!(all.count(), 1);
    }
}
