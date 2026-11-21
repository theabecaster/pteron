//! The pipe of a port share: HTTP/1.1 between the phone's browser and a dev server on this
//! computer's loopback, read just far enough to make the server see a local visitor.
//!
//! A dev server checks who it is asked as (Vite's `server.allowedHosts`, Next.js's
//! `allowedDevOrigins`, webpack-dev-server): a request for the computer's tailnet name is
//! turned away. That check is the server's guard against a page of another site reading it
//! through a name that site controls, so the share keeps it in the server's place: a request
//! whose `Host` is not one of the share's own names is answered `421` and goes nowhere. Of
//! every other request the head is rewritten, and only the head:
//! - `Host` becomes `localhost:<port>`;
//! - `Origin` and `Referer` that name the shared address name `http://localhost:<port>`.
//!
//! And of each answer:
//! - a `Location` and an `Access-Control-Allow-Origin` that name the local address name the
//!   shared one, as the browser asked for it;
//! - a `Set-Cookie` loses a `Domain` of the local address, so the cookie belongs to the host
//!   the browser is on;
//! - the header that marks the share's own waiting page (waiting.rs) is taken out.
//!
//! Bodies pass as they come, a piece at a time: a body is never held whole, whatever its
//! length, chunked or not. After a `101` (a WebSocket, as live reload uses) both directions
//! pass every byte untouched.
//!
//! One connection from the phone has one connection to the dev server, opened when its first
//! request has come. When nothing listens there, the request is answered with the waiting
//! page and the connection ends. Each direction holds one buffer: at most `HEAD_MAX` plus one
//! read (`READ`), so a connection costs at most about 128 KB however much passes through it.

use crate::waiting;
use std::collections::VecDeque;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::mpsc;

/// The longest request or response head. A longer one ends the connection.
pub const HEAD_MAX: usize = 32 * 1024;
/// How much is read at once.
pub const READ: usize = 16 * 1024;
/// The most header lines of one head.
const MAX_HEADERS: usize = 100;
/// The most requests of one connection that wait for their answer.
const MAX_ASKED: usize = 64;
/// How long a connection may take to send its first request, and how long one may stay
/// open between two requests with nothing asked and nothing being answered.
pub const HEAD_WAIT: Duration = Duration::from_secs(30);
/// How long a connection to the loopback may take.
const DIAL: Duration = Duration::from_secs(5);
/// How long a connection the share has answered itself is read on, so the answer arrives
/// before the connection is closed under what the browser still sends.
const LINGER: Duration = Duration::from_secs(2);

/// What one share pipes: where it listens and which port it reaches.
pub struct Target {
    /// The dev server's port on the loopback.
    pub port: u16,
    /// Where the share listens. The pipe never connects there.
    pub listen: SocketAddr,
    /// `host:port` of every way the share is reached, in lowercase; the first is the one
    /// its address is given out with.
    pub shared: Vec<String>,
    /// This computer's name, for the waiting page.
    pub machine: String,
    /// The dev server answered on `::1` last, so that is tried first.
    v6_first: AtomicBool,
}

/// `host:port` as an address writes it: an IPv6 address in brackets.
pub fn authority(host: &str, port: u16) -> String {
    if host.contains(':') {
        format!("[{host}]:{port}")
    } else {
        format!("{host}:{port}")
    }
}

impl Target {
    /// A share of `port` that listens on `listen` and is also reached by `name`, when the
    /// computer has one: by the whole name, and by its first part, which a device on the
    /// same tailnet may use for it.
    pub fn new(port: u16, listen: SocketAddr, name: Option<&str>, machine: &str) -> Target {
        let name = name.map(str::to_ascii_lowercase);
        let short = name.as_ref().and_then(|n| n.split('.').next().map(String::from));
        let hosts = name.into_iter().chain(short).chain([listen.ip().to_string()]);
        let mut shared = vec![];
        for host in hosts {
            shared.push(authority(&host, listen.port()));
            // A browser leaves the port out of `Host` when it is the scheme's own.
            if listen.port() == 80 {
                shared.push(if host.contains(':') { format!("[{host}]") } else { host });
            }
        }
        Target { port, listen, shared, machine: machine.to_string(), v6_first: AtomicBool::new(false) }
    }

    /// True for `host:port` as the dev server names itself.
    fn is_local(&self, authority: &str) -> bool {
        ["localhost", "127.0.0.1", "[::1]"].iter().any(|h| {
            authority.strip_prefix(h).is_some_and(|rest| rest.strip_prefix(':').is_some_and(|p| p.parse() == Ok(self.port)) || (rest.is_empty() && self.port == 80))
        })
    }

    fn is_shared(&self, authority: &str) -> bool {
        self.shared.iter().any(|s| s == authority)
    }

    /// The dev server, on the loopback: `127.0.0.1` and `::1`, the one that answered last
    /// first. None when nothing listens on the port.
    pub async fn dial(&self) -> Option<TcpStream> {
        let (v4, v6) = (IpAddr::V4(Ipv4Addr::LOCALHOST), IpAddr::V6(Ipv6Addr::LOCALHOST));
        let v6_first = self.v6_first.load(Ordering::Relaxed);
        for ip in if v6_first { [v6, v4] } else { [v4, v6] } {
            let addr = SocketAddr::new(ip, self.port);
            if addr == self.listen {
                continue;
            }
            if let Ok(Ok(stream)) = tokio::time::timeout(DIAL, TcpStream::connect(addr)).await {
                self.v6_first.store(ip.is_ipv6(), Ordering::Relaxed);
                let _ = stream.set_nodelay(true);
                return Some(stream);
            }
        }
        None
    }
}

/// Told when the dev server was found gone or back, so the share can count its waiting time.
pub trait Watch: Send + Sync {
    fn source_gone(&self);
    fn source_back(&self);
}

// MARK: Bodies

/// How the end of a body is found.
#[derive(Debug, PartialEq)]
pub enum Framing {
    None,
    Length(u64),
    Chunked(Chunked),
    /// Until the connection ends.
    Close,
}

#[derive(Debug, PartialEq)]
pub struct Malformed;

impl Framing {
    /// How many bytes at the start of `data` belong to the body, and whether it ends there.
    pub fn take(&mut self, data: &[u8]) -> Result<(usize, bool), Malformed> {
        match self {
            Framing::None => Ok((0, true)),
            Framing::Length(left) => {
                let n = (*left).min(data.len() as u64);
                *left -= n;
                Ok((n as usize, *left == 0))
            }
            Framing::Chunked(c) => c.take(data),
            Framing::Close => Ok((data.len(), false)),
        }
    }
}

/// Where a chunked body is, between two pieces of it. It is passed on as it is: this only
/// counts along to find its end.
#[derive(Debug, PartialEq)]
pub enum Chunked {
    /// In a chunk's size line: the size so far, whether a digit came, and whether the rest
    /// of the line is an extension.
    Size(u64, bool, bool),
    /// In a chunk's data, this many bytes to go.
    Data(u64),
    /// After a chunk's data: its CR, then its LF.
    DataCr,
    DataLf,
    /// In the lines after the last chunk; true while the current line is empty so far.
    Trailer(bool),
}

impl Chunked {
    pub fn new() -> Chunked {
        Chunked::Size(0, false, false)
    }

    fn take(&mut self, data: &[u8]) -> Result<(usize, bool), Malformed> {
        let mut i = 0;
        while i < data.len() {
            let b = data[i];
            match self {
                Chunked::Size(size, digit, ext) => {
                    i += 1;
                    match b {
                        b'\n' if *digit => *self = if *size == 0 { Chunked::Trailer(true) } else { Chunked::Data(*size) },
                        b'\r' if *digit => {}
                        b';' if *digit => *ext = true,
                        _ if *ext && b != b'\n' => {}
                        _ => {
                            let d = (b as char).to_digit(16).ok_or(Malformed)?;
                            *size = size.checked_mul(16).and_then(|s| s.checked_add(u64::from(d))).ok_or(Malformed)?;
                            *digit = true;
                        }
                    }
                }
                Chunked::Data(left) => {
                    let n = (*left).min((data.len() - i) as u64);
                    i += n as usize;
                    *left -= n;
                    if *left == 0 {
                        *self = Chunked::DataCr;
                    }
                }
                Chunked::DataCr | Chunked::DataLf => {
                    i += 1;
                    *self = match (&*self, b) {
                        (Chunked::DataCr, b'\r') => Chunked::DataLf,
                        (_, b'\n') => Chunked::new(),
                        _ => return Err(Malformed),
                    };
                }
                Chunked::Trailer(empty) => {
                    i += 1;
                    match b {
                        b'\n' if *empty => return Ok((i, true)),
                        b'\n' => *empty = true,
                        b'\r' => {}
                        _ => *empty = false,
                    }
                }
            }
        }
        Ok((i, false))
    }
}

// MARK: Heads

/// Why a head is not passed on.
#[derive(Debug, PartialEq)]
pub enum Reject {
    Bad,
    TooLarge,
    /// The request is for a host that is not the share.
    Foreign,
}

/// What the answer to a request needs to know of it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct Asked {
    /// `HEAD`: the answer has no body, whatever its headers say.
    pub head_only: bool,
    /// It asks to change protocols (`Connection: upgrade`).
    pub upgrade: bool,
    /// A plain page load: `GET` and no upgrade.
    pub page: bool,
    /// The shared `host:port` the browser asked as, for what the answer names.
    pub host: String,
}

fn eq(name: &str, other: &str) -> bool {
    name.eq_ignore_ascii_case(other)
}

fn line(out: &mut Vec<u8>, name: &str, value: &[u8]) {
    out.extend_from_slice(name.as_bytes());
    out.extend_from_slice(b": ");
    out.extend_from_slice(value);
    out.extend_from_slice(b"\r\n");
}

fn has_token(value: &[u8], token: &str) -> bool {
    value.split(|b| *b == b',').any(|t| t.trim_ascii().eq_ignore_ascii_case(token.as_bytes()))
}

/// A `Content-Length`: digits alone.
fn length(value: &[u8]) -> Option<u64> {
    let text = std::str::from_utf8(value).ok()?;
    (!text.is_empty() && text.bytes().all(|b| b.is_ascii_digit())).then(|| text.parse().ok()).flatten()
}

/// `http://host:port` and what follows it, of an address in a header. `host:port` comes in
/// lowercase. With `bare`, an address that starts at `//` counts too; the second value says
/// whether the scheme was there.
fn split_address(value: &[u8], bare: bool) -> Option<(String, bool, &[u8])> {
    let (schemed, rest) = match value {
        v if v.len() >= 7 && v[..7].eq_ignore_ascii_case(b"http://") => (true, &v[7..]),
        v if bare && v.starts_with(b"//") => (false, &v[2..]),
        _ => return None,
    };
    let end = rest.iter().position(|b| matches!(b, b'/' | b'?' | b'#')).unwrap_or(rest.len());
    let authority = std::str::from_utf8(&rest[..end]).ok()?.to_ascii_lowercase();
    Some((authority, schemed, &rest[end..]))
}

/// A `Set-Cookie` without a `Domain` of the local address, or None when it has none.
fn host_only_cookie(value: &[u8]) -> Option<Vec<u8>> {
    let local = |part: &[u8]| {
        let part = part.trim_ascii();
        part.len() > 7 && part[..7].eq_ignore_ascii_case(b"domain=") && {
            let domain = part[7..].trim_ascii();
            let domain = domain.strip_prefix(b".").unwrap_or(domain);
            [&b"localhost"[..], b"127.0.0.1", b"::1", b"[::1]"].iter().any(|l| domain.eq_ignore_ascii_case(l))
        }
    };
    let mut out = vec![];
    let mut changed = false;
    for (i, part) in value.split(|b| *b == b';').enumerate() {
        // The first part is the cookie itself, whatever it is called.
        if i > 0 && local(part) {
            changed = true;
            continue;
        }
        if i > 0 {
            out.push(b';');
        }
        out.extend_from_slice(part);
    }
    changed.then_some(out)
}

/// A request head as the dev server gets it, what its answer needs to know, and how its
/// body ends. `head` is one whole head, through its empty line.
pub fn request(head: &[u8], t: &Target) -> Result<(Vec<u8>, Asked, Framing), Reject> {
    let mut headers = [httparse::EMPTY_HEADER; MAX_HEADERS];
    let mut req = httparse::Request::new(&mut headers);
    match req.parse(head) {
        Ok(httparse::Status::Complete(n)) if n == head.len() => {}
        Err(httparse::Error::TooManyHeaders) => return Err(Reject::TooLarge),
        _ => return Err(Reject::Bad),
    }
    let (Some(method), Some(path), Some(version)) = (req.method, req.path, req.version) else { return Err(Reject::Bad) };
    // A tunnel through the share to anywhere is not what it is for, and neither is a
    // request that names another place in its first line: only a path of the dev server's.
    if eq(method, "CONNECT") || !path.starts_with('/') {
        return Err(Reject::Bad);
    }
    let local = format!("localhost:{}", t.port);
    let mut out = Vec::with_capacity(head.len() + 32);
    out.extend_from_slice(format!("{method} {path} HTTP/1.{version}\r\n").as_bytes());
    let (mut host, mut content_length, mut chunked, mut wants_upgrade, mut names_upgrade) = (None, None, None, false, false);
    for h in req.headers.iter() {
        if eq(h.name, "host") {
            if host.is_some() {
                return Err(Reject::Bad);
            }
            host = Some(String::from_utf8_lossy(h.value).to_ascii_lowercase());
            line(&mut out, h.name, local.as_bytes());
            continue;
        }
        if eq(h.name, "origin") || eq(h.name, "referer") {
            if let Some((_, _, rest)) = split_address(h.value, false).filter(|(a, _, _)| t.is_shared(a)) {
                line(&mut out, h.name, &[b"http://", local.as_bytes(), rest].concat());
                continue;
            }
        }
        if eq(h.name, "content-length") {
            let n = length(h.value).ok_or(Reject::Bad)?;
            if content_length.is_some_and(|other| other != n) {
                return Err(Reject::Bad);
            }
            content_length = Some(n);
        } else if eq(h.name, "transfer-encoding") {
            // The last coding named is the one the body is cut by.
            chunked = Some(h.value.rsplit(|b| *b == b',').next().is_some_and(|last| last.trim_ascii().eq_ignore_ascii_case(b"chunked")));
        } else if eq(h.name, "connection") {
            wants_upgrade |= has_token(h.value, "upgrade");
        } else if eq(h.name, "upgrade") {
            names_upgrade = true;
        }
        line(&mut out, h.name, h.value);
    }
    // Asked as anything but the share itself, nothing is passed on: the dev server would
    // take the rewritten request for a local one, whoever sent the browser here.
    let Some(host) = host.filter(|h| t.is_shared(h)) else { return Err(Reject::Foreign) };
    out.extend_from_slice(b"\r\n");
    // A body whose end two headers put in two places is no request to pass on, and neither
    // is a chunked one in HTTP/1.0, which has no chunks.
    if version == 0 && chunked.is_some() {
        return Err(Reject::Bad);
    }
    let body = match (chunked, content_length) {
        (Some(_), Some(_)) | (Some(false), _) => return Err(Reject::Bad),
        (Some(true), None) => Framing::Chunked(Chunked::new()),
        (None, Some(n)) if n > 0 => Framing::Length(n),
        (None, _) => Framing::None,
    };
    let upgrade = wants_upgrade && names_upgrade;
    let asked = Asked {
        head_only: eq(method, "HEAD"),
        upgrade,
        page: eq(method, "GET") && !upgrade,
        host,
    };
    Ok((out, asked, body))
}

/// What a response head says about what follows it.
#[derive(Debug, PartialEq)]
pub struct Answer {
    pub code: u16,
    pub body: Framing,
}

impl Answer {
    /// A `1xx` that is not the last word on its request (`100 Continue`, `103 Early Hints`).
    pub fn interim(&self) -> bool {
        (100..200).contains(&self.code) && self.code != 101
    }
}

/// A response head as the browser gets it, and how its body ends. `asked` is the request it
/// answers.
pub fn response(head: &[u8], t: &Target, asked: &Asked) -> Result<(Vec<u8>, Answer), Reject> {
    let mut headers = [httparse::EMPTY_HEADER; MAX_HEADERS];
    let mut res = httparse::Response::new(&mut headers);
    match res.parse(head) {
        Ok(httparse::Status::Complete(n)) if n == head.len() => {}
        _ => return Err(Reject::Bad),
    }
    let (Some(code), Some(version)) = (res.code, res.version) else { return Err(Reject::Bad) };
    let mut out = Vec::with_capacity(head.len() + 64);
    out.extend_from_slice(format!("HTTP/1.{version} {code} {}\r\n", res.reason.unwrap_or("")).as_bytes());
    let (mut content_length, mut chunked) = (None, None);
    let shared = [b"http://", asked.host.as_bytes()].concat();
    for h in res.headers.iter() {
        if eq(h.name, waiting::HEADER) {
            continue;
        }
        if eq(h.name, "location") || eq(h.name, "access-control-allow-origin") {
            if let Some((_, schemed, rest)) = split_address(h.value, eq(h.name, "location")).filter(|(a, _, _)| t.is_local(a)) {
                line(&mut out, h.name, &[if schemed { &shared[..] } else { &shared[5..] }, rest].concat());
                continue;
            }
        }
        if eq(h.name, "set-cookie") {
            if let Some(cookie) = host_only_cookie(h.value) {
                line(&mut out, h.name, &cookie);
                continue;
            }
        }
        if eq(h.name, "content-length") {
            content_length = Some(length(h.value).ok_or(Reject::Bad)?);
        } else if eq(h.name, "transfer-encoding") {
            chunked = Some(h.value.rsplit(|b| *b == b',').next().is_some_and(|last| last.trim_ascii().eq_ignore_ascii_case(b"chunked")));
        }
        line(&mut out, h.name, h.value);
    }
    out.extend_from_slice(b"\r\n");
    let bodiless = asked.head_only || (100..200).contains(&code) || code == 204 || code == 304;
    let body = match (bodiless, chunked, content_length) {
        (true, _, _) => Framing::None,
        (_, Some(true), _) => Framing::Chunked(Chunked::new()),
        (_, Some(false), _) => Framing::Close,
        (_, None, Some(0)) => Framing::None,
        (_, None, Some(n)) => Framing::Length(n),
        (_, None, None) => Framing::Close,
    };
    Ok((out, Answer { code, body }))
}

// MARK: The pipe

/// How a read for a head ended without one.
#[derive(Debug, PartialEq)]
enum NoHead {
    /// The other side closed between two messages.
    Closed,
    Broken,
    TooLarge,
}

/// One side of a connection and what was read from it and not yet passed on.
struct Reader<R> {
    io: R,
    buf: Vec<u8>,
}

impl<R: AsyncRead + Unpin> Reader<R> {
    fn new(io: R) -> Reader<R> {
        Reader { io, buf: vec![] }
    }

    /// Reads once more. 0 at the end of the stream.
    async fn fill(&mut self) -> std::io::Result<usize> {
        if self.buf.capacity() - self.buf.len() < READ / 4 {
            self.buf.reserve(READ);
        }
        self.io.read_buf(&mut self.buf).await
    }

    /// Reads until a whole head is there, and says how long it is.
    async fn head(&mut self) -> Result<usize, NoHead> {
        let mut seen = 0usize;
        loop {
            let from = seen.saturating_sub(3);
            if let Some(i) = self.buf[from..].windows(4).position(|w| w == b"\r\n\r\n") {
                let len = from + i + 4;
                return if len <= HEAD_MAX { Ok(len) } else { Err(NoHead::TooLarge) };
            }
            seen = self.buf.len();
            if seen >= HEAD_MAX {
                return Err(NoHead::TooLarge);
            }
            match self.fill().await {
                Ok(0) if self.buf.is_empty() => return Err(NoHead::Closed),
                Ok(0) | Err(_) => return Err(NoHead::Broken),
                Ok(_) => {}
            }
        }
    }

    /// Passes a body on to `to`, as it comes. `first` is written ahead of it, in one piece
    /// with as much of the body as is already here. False when the stream ended first.
    async fn pass<W: AsyncWrite + Unpin>(&mut self, mut first: Vec<u8>, mut body: Framing, to: &mut W) -> std::io::Result<bool> {
        let bad = |_| std::io::Error::new(std::io::ErrorKind::InvalidData, "a body that is not what its head said");
        loop {
            let (n, done) = body.take(&self.buf).map_err(bad)?;
            if first.is_empty() {
                to.write_all(&self.buf[..n]).await?;
            } else {
                first.extend_from_slice(&self.buf[..n]);
                to.write_all(&first).await?;
                first = vec![];
            }
            self.buf.drain(..n);
            if done {
                return Ok(true);
            }
            if self.fill().await? == 0 {
                return Ok(false);
            }
        }
    }

    /// Passes everything on, untouched, until the stream ends.
    async fn pass_all<W: AsyncWrite + Unpin>(&mut self, to: &mut W) -> std::io::Result<()> {
        to.write_all(&self.buf).await?;
        self.buf = vec![];
        tokio::io::copy(&mut self.io, to).await.map(|_| ())
    }
}

/// What the two directions of one connection tell each other.
struct Between {
    /// The requests that went to the dev server and have no answer yet, oldest first.
    asked: Mutex<VecDeque<Asked>>,
    /// An answer's body is on its way to the browser.
    answering: AtomicBool,
    /// Something of an answer has gone to the browser on this connection.
    answered: AtomicBool,
}

/// How the browser's side of a connection ended.
#[derive(Debug, PartialEq)]
enum Up {
    /// The browser closed after a whole request.
    Closed,
    /// The connection is of no more use.
    Broken,
    /// A request's body was not what its head said.
    Malformed,
}

/// An answer the share gives itself, with nothing after it.
fn plain(status: &str) -> Vec<u8> {
    format!("HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").into_bytes()
}

/// Writes the share's own answer and ends the connection, reading on for a moment so the
/// answer is not lost under what the browser was still sending.
async fn answer<R: AsyncRead + Unpin, W: AsyncWrite + Unpin>(mut from: R, mut to: W, bytes: &[u8]) {
    if to.write_all(bytes).await.is_err() {
        return;
    }
    let _ = to.shutdown().await;
    let _ = tokio::time::timeout(LINGER, async {
        let (mut sink, mut total) = ([0u8; 4096], 0usize);
        while let Ok(n) = from.read(&mut sink).await {
            total += n;
            if n == 0 || total > 1 << 20 {
                break;
            }
        }
    })
    .await;
}

/// One connection from the phone, from its first byte to its end.
pub async fn serve(stream: TcpStream, t: &Target, watch: &dyn Watch) {
    let _ = stream.set_nodelay(true);
    let (from_phone, mut to_phone) = stream.into_split();
    let mut phone = Reader::new(from_phone);
    // Nothing is asked of the dev server before the browser has asked for something, and
    // a connection that asks for nothing is not kept.
    let len = match tokio::time::timeout(HEAD_WAIT, phone.head()).await {
        Ok(Ok(len)) => len,
        Ok(Err(NoHead::TooLarge)) => return answer(phone.io, to_phone, &plain("431 Request Header Fields Too Large")).await,
        Ok(Err(_)) | Err(_) => return,
    };
    let asked = match request(&phone.buf[..len], t) {
        Ok((_, asked, _)) => asked,
        Err(Reject::TooLarge) => return answer(phone.io, to_phone, &plain("431 Request Header Fields Too Large")).await,
        Err(Reject::Bad) => return answer(phone.io, to_phone, &plain("400 Bad Request")).await,
        Err(Reject::Foreign) => return answer(phone.io, to_phone, &plain("421 Misdirected Request")).await,
    };
    let Some(server) = t.dial().await else {
        watch.source_gone();
        return answer(phone.io, to_phone, &waiting::response(t.port, &t.machine, asked.page)).await;
    };
    watch.source_back();
    let (from_server, mut to_server) = server.into_split();
    let between = Between { asked: Mutex::new(VecDeque::new()), answering: AtomicBool::new(false), answered: AtomicBool::new(false) };
    let (verdict, mut verdicts) = mpsc::unbounded_channel::<bool>();
    let malformed = {
        let up = up(&mut phone, &mut to_server, t, &between, &mut verdicts);
        let down = down(Reader::new(from_server), &mut to_phone, t, &between, verdict);
        tokio::pin!(up, down);
        tokio::select! {
            _ = &mut down => false,
            ended = &mut up => match ended {
                // The browser is done sending: what the dev server still answers goes out.
                Up::Closed => {
                    down.await;
                    false
                }
                Up::Broken => false,
                Up::Malformed => true,
            }
        }
    };
    // The first request's body was not what its head said, and nothing has been answered:
    // the browser is told. Later in a connection it just ends.
    if malformed && !between.answered.load(Ordering::SeqCst) {
        answer(phone.io, to_phone, &plain("400 Bad Request")).await;
    }
}

/// The browser's side: each request, its head rewritten, to the dev server.
async fn up<R: AsyncRead + Unpin, W: AsyncWrite + Unpin>(phone: &mut Reader<R>, server: &mut W, t: &Target, between: &Between, verdicts: &mut mpsc::UnboundedReceiver<bool>) -> Up {
    loop {
        let len = loop {
            match tokio::time::timeout(HEAD_WAIT, phone.head()).await {
                Ok(Ok(len)) => break len,
                Ok(Err(NoHead::Closed)) => {
                    let _ = server.shutdown().await;
                    return Up::Closed;
                }
                Ok(Err(_)) => return Up::Broken,
                // Quiet for a while. A request that waits for its answer, or an answer
                // that is still coming (an event stream), keeps the connection; one with
                // nothing going on is closed, as a server closes an idle connection.
                Err(_) => {
                    if between.asked.lock().unwrap().is_empty() && !between.answering.load(Ordering::SeqCst) {
                        return Up::Broken;
                    }
                }
            }
        };
        let Ok((head, asked, body)) = request(&phone.buf[..len], t) else { return Up::Broken };
        phone.buf.drain(..len);
        let upgrade = asked.upgrade;
        {
            let mut waiting = between.asked.lock().unwrap();
            if waiting.len() >= MAX_ASKED {
                return Up::Broken;
            }
            waiting.push_back(asked);
        }
        match phone.pass(head, body, server).await {
            Ok(true) => {}
            Err(e) if e.kind() == std::io::ErrorKind::InvalidData => return Up::Malformed,
            _ => return Up::Broken,
        }
        if upgrade {
            // The browser sends nothing more until it knows which protocol the rest is.
            match verdicts.recv().await {
                Some(true) => {
                    let done = phone.pass_all(server).await.is_ok();
                    let _ = server.shutdown().await;
                    return if done { Up::Closed } else { Up::Broken };
                }
                Some(false) => {}
                None => return Up::Broken,
            }
        }
    }
}

/// The dev server's side: each answer, its head rewritten, to the browser. Returns when the
/// dev server closed or the connection is of no more use.
async fn down<R: AsyncRead + Unpin, W: AsyncWrite + Unpin>(mut server: Reader<R>, phone: &mut W, t: &Target, between: &Between, verdict: mpsc::UnboundedSender<bool>) {
    loop {
        let Ok(len) = server.head().await else { return };
        let asked = between.asked.lock().unwrap().front().cloned().unwrap_or_default();
        let asked = if asked.host.is_empty() { Asked { host: t.shared[0].clone(), ..asked } } else { asked };
        let Ok((head, answer)) = response(&server.buf[..len], t, &asked) else { return };
        server.buf.drain(..len);
        // A change of protocols nobody asked for is not passed on: the browser would read
        // what follows as HTTP.
        if answer.code == 101 && !asked.upgrade {
            return;
        }
        between.answered.store(true, Ordering::SeqCst);
        if answer.interim() {
            if phone.write_all(&head).await.is_err() {
                return;
            }
            continue;
        }
        between.asked.lock().unwrap().pop_front();
        if answer.code == 101 {
            let _ = verdict.send(true);
            if phone.write_all(&head).await.is_ok() {
                let _ = server.pass_all(phone).await;
            }
            let _ = phone.shutdown().await;
            return;
        }
        if asked.upgrade {
            let _ = verdict.send(false);
        }
        between.answering.store(true, Ordering::SeqCst);
        let whole = matches!(server.pass(head, answer.body, phone).await, Ok(true));
        between.answering.store(false, Ordering::SeqCst);
        if !whole {
            let _ = phone.shutdown().await;
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A share of port 3000 that listens on port 3000 of the computer's address, where the
    /// computer is `desk.example.ts.net` (example names and addresses, as everywhere here).
    fn target() -> Target {
        Target::new(3000, "100.64.0.1:3000".parse().unwrap(), Some("Desk.Example.ts.net"), "desk")
    }

    fn text(bytes: &[u8]) -> String {
        String::from_utf8(bytes.to_vec()).unwrap()
    }

    fn asked(host: &str) -> Asked {
        Asked { host: host.into(), page: true, ..Asked::default() }
    }

    #[test]
    fn a_share_knows_every_way_it_is_reached() {
        let t = target();
        assert_eq!(t.shared, ["desk.example.ts.net:3000", "desk:3000", "100.64.0.1:3000"]);
        let v6 = Target::new(5173, "[fd7a:115c:a1e0::1]:41000".parse().unwrap(), None, "desk");
        assert_eq!(v6.shared, ["[fd7a:115c:a1e0::1]:41000"]);
        // On port 80 a browser leaves the port out.
        let plain = Target::new(80, "100.64.0.1:80".parse().unwrap(), Some("desk.example.ts.net"), "desk");
        assert_eq!(plain.shared, ["desk.example.ts.net:80", "desk.example.ts.net", "desk:80", "desk", "100.64.0.1:80", "100.64.0.1"]);
        for local in ["localhost:3000", "127.0.0.1:3000", "[::1]:3000"] {
            assert!(t.is_local(local), "{local}");
        }
        for other in ["localhost", "localhost:3001", "localhost:30000", "localhost.example.com:3000", "127.0.0.10:3000", "desk.example.ts.net:3000", ""] {
            assert!(!t.is_local(other), "{other}");
        }
        assert!(plain.is_local("localhost") && plain.is_local("localhost:80") && plain.is_local("[::1]"));
    }

    #[test]
    fn a_request_reaches_the_dev_server_as_a_local_one() {
        let t = target();
        let head = b"GET /src/main.ts?v=1 HTTP/1.1\r\nHost: desk.example.ts.net:3000\r\nUser-Agent: Mobile Safari\r\nOrigin: http://desk.example.ts.net:3000\r\nReferer: http://Desk.Example.ts.net:3000/app/page?x=1#top\r\nAccept: */*\r\nCookie: sid=1\r\n\r\n";
        let (out, asked, body) = request(head, &t).unwrap();
        // Every other line is as it came, in its place.
        assert_eq!(
            text(&out),
            "GET /src/main.ts?v=1 HTTP/1.1\r\nHost: localhost:3000\r\nUser-Agent: Mobile Safari\r\nOrigin: http://localhost:3000\r\nReferer: http://localhost:3000/app/page?x=1#top\r\nAccept: */*\r\nCookie: sid=1\r\n\r\n"
        );
        assert_eq!(asked, Asked { head_only: false, upgrade: false, page: true, host: "desk.example.ts.net:3000".into() });
        assert_eq!(body, Framing::None);
        // By address instead of by name: the answer will name the address.
        let (out, asked, _) = request(b"HEAD / HTTP/1.1\r\nhost: 100.64.0.1:3000\r\nORIGIN: http://100.64.0.1:3000\r\n\r\n", &t).unwrap();
        assert_eq!(text(&out), "HEAD / HTTP/1.1\r\nhost: localhost:3000\r\nORIGIN: http://localhost:3000\r\n\r\n");
        assert_eq!((asked.head_only, asked.page, asked.host.as_str()), (true, false, "100.64.0.1:3000"));
    }

    #[test]
    fn an_origin_or_referer_from_elsewhere_stays_as_it_is() {
        let t = target();
        for value in ["https://desk.example.ts.net:3000", "http://desk.example.ts.net:3001", "http://desk.example.ts.net", "http://other.example.com:3000", "http://desk.example.ts.net:3000.evil.example", "null", "http://user@desk.example.ts.net:3000"] {
            let head = format!("POST /api HTTP/1.1\r\nHost: desk.example.ts.net:3000\r\nOrigin: {value}\r\nReferer: {value}/x\r\nContent-Length: 2\r\n\r\n");
            let (out, _, body) = request(head.as_bytes(), &t).unwrap();
            assert!(text(&out).contains(&format!("\r\nOrigin: {value}\r\nReferer: {value}/x\r\n")), "{value}: {}", text(&out));
            assert_eq!(body, Framing::Length(2));
        }
    }

    #[test]
    fn a_request_for_any_host_but_the_share_is_not_passed_on() {
        let t = target();
        // By its whole name, the name's first part, and its address, in any letter case.
        for own in ["desk.example.ts.net:3000", "DESK.Example.TS.net:3000", "desk:3000", "100.64.0.1:3000"] {
            let (out, asked, _) = request(format!("GET / HTTP/1.1\r\nHost: {own}\r\n\r\n").as_bytes(), &t).unwrap();
            assert_eq!(text(&out), "GET / HTTP/1.1\r\nHost: localhost:3000\r\n\r\n");
            assert_eq!(asked.host, own.to_ascii_lowercase());
        }
        // A name someone else gave this address, the local name itself, another port, and
        // no `Host` at all: the dev server would take each for a local visitor.
        for foreign in ["evil.example:3000", "localhost:3000", "127.0.0.1:3000", "desk.example.ts.net", "desk.example.ts.net:3001", "desk.example.ts.net.evil.example:3000", "100.64.0.2:3000", ""] {
            assert_eq!(request(format!("GET / HTTP/1.1\r\nHost: {foreign}\r\n\r\n").as_bytes(), &t).err(), Some(Reject::Foreign), "{foreign:?}");
        }
        assert_eq!(request(b"GET / HTTP/1.0\r\nAccept: */*\r\n\r\n", &t).err(), Some(Reject::Foreign));
    }

    #[test]
    fn a_requests_body_and_upgrade_are_read_from_its_head() {
        let t = target();
        let framing = |lines: &str| request(format!("POST /u HTTP/1.1\r\nHost: desk:3000\r\n{lines}\r\n").as_bytes(), &t).map(|(_, asked, body)| (asked.upgrade, body));
        assert_eq!(framing(""), Ok((false, Framing::None)));
        assert_eq!(framing("Content-Length: 0\r\n"), Ok((false, Framing::None)));
        assert_eq!(framing("Content-Length: 5000000000\r\n"), Ok((false, Framing::Length(5_000_000_000))));
        assert_eq!(framing("content-length: 7\r\nContent-Length: 7\r\n"), Ok((false, Framing::Length(7))));
        assert_eq!(framing("Transfer-Encoding: chunked\r\n"), Ok((false, Framing::Chunked(Chunked::new()))));
        assert_eq!(framing("Transfer-Encoding: gzip, Chunked\r\n"), Ok((false, Framing::Chunked(Chunked::new()))));
        // A body whose end is not certain is no request to pass on.
        for unsure in ["Content-Length: 7\r\nContent-Length: 8\r\n", "Content-Length: 7\r\nTransfer-Encoding: chunked\r\n", "Transfer-Encoding: gzip\r\n", "Content-Length: -1\r\n", "Content-Length: 1e3\r\n", "Content-Length: 7, 7\r\n", "Content-Length: 99999999999999999999999\r\n", "Host: desk:3000\r\n"] {
            assert_eq!(framing(unsure), Err(Reject::Bad), "{unsure:?}");
        }
        // An upgrade needs both headers, as a WebSocket handshake has them.
        let (_, ws, _) = request(b"GET /hmr HTTP/1.1\r\nHost: desk:3000\r\nConnection: keep-alive, Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Key: x\r\n\r\n", &t).unwrap();
        assert_eq!((ws.upgrade, ws.page), (true, false));
        assert_eq!(framing("Connection: upgrade\r\n").unwrap().0, false);
        assert_eq!(framing("Upgrade: websocket\r\n").unwrap().0, false);
    }

    #[test]
    fn what_is_not_one_whole_http_request_is_turned_away() {
        let t = target();
        for bad in [
            &b"SSH-2.0-OpenSSH_9.9\r\n\r\n"[..],
            b"\x16\x03\x01\x02\x00\x01\x00\r\n\r\n",
            b"GET /\r\n\r\n",
            b"GET / HTTP/2.0\r\nHost: a\r\n\r\n",
            b"CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n",
            // A first line that names a place instead of a path of the dev server's.
            b"GET http://desk.example.ts.net:3000/ HTTP/1.1\r\nHost: desk.example.ts.net:3000\r\n\r\n",
            b"GET http://other.example/ HTTP/1.1\r\nHost: desk.example.ts.net:3000\r\n\r\n",
            b"GET //other.example/ HTTP/1.1\r\nHost: desk:3000\r\nX: a\x00b\r\n\r\n",
            b"OPTIONS * HTTP/1.1\r\nHost: desk:3000\r\n\r\n",
            b"GET example HTTP/1.1\r\nHost: desk:3000\r\n\r\n",
            // HTTP/1.0 has no chunks.
            b"POST /u HTTP/1.0\r\nHost: desk:3000\r\nTransfer-Encoding: chunked\r\n\r\n",
            b"GET / HTTP/1.1\r\nHost: a\r\nBad Header: x\r\n\r\n",
            b"GET / HTTP/1.1\r\nHost: a\r\n",
            // Two heads in what was taken for one.
            b"GET / HTTP/1.1\nHost: a\n\nGET /second HTTP/1.1\r\nHost: b\r\n\r\n",
        ] {
            assert_eq!(request(bad, &t).err(), Some(Reject::Bad), "{:?}", String::from_utf8_lossy(bad));
        }
        let many: String = (0..=MAX_HEADERS).map(|i| format!("X-{i}: v\r\n")).collect();
        assert_eq!(request(format!("GET / HTTP/1.1\r\n{many}\r\n").as_bytes(), &t).err(), Some(Reject::TooLarge));
    }

    #[test]
    fn an_answer_names_the_shared_address_where_it_named_the_local_one() {
        let t = target();
        let head = concat!(
            "HTTP/1.1 302 Found\r\n",
            "Location: http://localhost:3000/login?next=%2F\r\n",
            "Set-Cookie: sid=abc; Domain=localhost; Path=/; HttpOnly\r\n",
            "set-cookie: theme=dark; Path=/\r\n",
            "Access-Control-Allow-Origin: http://localhost:3000\r\n",
            "Vary: Origin\r\n",
            "Content-Length: 0\r\n\r\n"
        );
        let (out, answer) = response(head.as_bytes(), &t, &asked("desk.example.ts.net:3000")).unwrap();
        assert_eq!(
            text(&out),
            concat!(
                "HTTP/1.1 302 Found\r\n",
                "Location: http://desk.example.ts.net:3000/login?next=%2F\r\n",
                "Set-Cookie: sid=abc; Path=/; HttpOnly\r\n",
                "set-cookie: theme=dark; Path=/\r\n",
                "Access-Control-Allow-Origin: http://desk.example.ts.net:3000\r\n",
                "Vary: Origin\r\n",
                "Content-Length: 0\r\n\r\n"
            )
        );
        assert_eq!(answer, Answer { code: 302, body: Framing::None });
        // The browser came by address: that is what it is sent back to.
        let (out, _) = response(b"HTTP/1.1 301 Moved Permanently\r\nLocation: //127.0.0.1:3000/x\r\n\r\n", &t, &asked("100.64.0.1:3000")).unwrap();
        assert_eq!(text(&out), "HTTP/1.1 301 Moved Permanently\r\nLocation: //100.64.0.1:3000/x\r\n\r\n");
        let (out, _) = response(b"HTTP/1.1 307 \r\nLocation: HTTP://[::1]:3000\r\n\r\n", &t, &asked("100.64.0.1:3000")).unwrap();
        assert_eq!(text(&out), "HTTP/1.1 307 \r\nLocation: http://100.64.0.1:3000\r\n\r\n");
    }

    #[test]
    fn an_answer_that_names_another_place_stays_as_it_is() {
        let t = target();
        for location in ["/login", "login", "?x=1", "http://localhost:3001/", "http://localhost/", "https://localhost:3000/", "http://example.com/?next=http://localhost:3000/", "http://localhost:3000.example.com/", "//cdn.example.com/a.js"] {
            let head = format!("HTTP/1.1 302 Found\r\nLocation: {location}\r\nAccess-Control-Allow-Origin: *\r\nContent-Length: 0\r\n\r\n");
            let (out, _) = response(head.as_bytes(), &t, &asked("desk.example.ts.net:3000")).unwrap();
            assert_eq!(text(&out), head, "{location}");
        }
        // Only a `Domain` of the local address is taken out of a cookie.
        let cookie = |value: &str| {
            let (out, _) = response(format!("HTTP/1.1 200 OK\r\nSet-Cookie: {value}\r\nContent-Length: 0\r\n\r\n").as_bytes(), &t, &asked("desk.example.ts.net:3000")).unwrap();
            text(&out).lines().nth(1).unwrap().strip_prefix("Set-Cookie: ").unwrap().to_string()
        };
        assert_eq!(cookie("a=1; domain=.LOCALHOST"), "a=1");
        assert_eq!(cookie("a=1;Domain=127.0.0.1;Secure; SameSite=Lax"), "a=1;Secure; SameSite=Lax");
        assert_eq!(cookie("a=1; Path=/; Domain=localhost"), "a=1; Path=/");
        for kept in ["a=1; Domain=example.com; Path=/", "domain=localhost; Path=/", "a=Domain=localhost", "a=1; Domain=localhost.example.com", "a=1; Domain=notlocalhost", "a=1"] {
            assert_eq!(cookie(kept), kept);
        }
    }

    #[test]
    fn a_dev_server_cannot_mark_its_own_answer_as_the_waiting_page() {
        let t = target();
        for name in [waiting::HEADER.to_string(), waiting::HEADER.to_lowercase(), waiting::HEADER.to_uppercase()] {
            let head = format!("HTTP/1.1 200 OK\r\n{name}: 1\r\nContent-Type: text/html\r\n{name}: yes\r\nContent-Length: 2\r\n\r\n");
            let (out, answer) = response(head.as_bytes(), &t, &asked("desk.example.ts.net:3000")).unwrap();
            assert_eq!(text(&out), "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 2\r\n\r\n");
            assert_eq!(answer.body, Framing::Length(2));
        }
    }

    #[test]
    fn an_answers_body_is_read_from_its_head_and_its_request() {
        let t = target();
        let page = asked("desk.example.ts.net:3000");
        let framing = |head: &str, asked: &Asked| response(head.as_bytes(), &t, asked).map(|(_, a)| (a.code, a.interim(), a.body));
        assert_eq!(framing("HTTP/1.1 200 OK\r\nContent-Length: 12\r\n\r\n", &page), Ok((200, false, Framing::Length(12))));
        assert_eq!(framing("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n", &page), Ok((200, false, Framing::Chunked(Chunked::new()))));
        // Chunked wins over a length, as HTTP says.
        assert_eq!(framing("HTTP/1.1 200 OK\r\nContent-Length: 12\r\nTransfer-Encoding: chunked\r\n\r\n", &page), Ok((200, false, Framing::Chunked(Chunked::new()))));
        // Neither: the body runs until the dev server closes (an event stream).
        assert_eq!(framing("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n", &page), Ok((200, false, Framing::Close)));
        assert_eq!(framing("HTTP/1.0 200 OK\r\nTransfer-Encoding: gzip\r\n\r\n", &page), Ok((200, false, Framing::Close)));
        // No body, whatever the headers say.
        for (head, code) in [("HTTP/1.1 204 No Content\r\nContent-Length: 5\r\n\r\n", 204), ("HTTP/1.1 304 Not Modified\r\nContent-Length: 5\r\nETag: \"x\"\r\n\r\n", 304)] {
            assert_eq!(framing(head, &page), Ok((code, false, Framing::None)));
        }
        let head_only = Asked { head_only: true, ..page.clone() };
        assert_eq!(framing("HTTP/1.1 200 OK\r\nContent-Length: 5000\r\n\r\n", &head_only), Ok((200, false, Framing::None)));
        // An interim answer is followed by the real one; `101` is the last HTTP on the connection.
        assert_eq!(framing("HTTP/1.1 100 Continue\r\n\r\n", &page), Ok((100, true, Framing::None)));
        assert_eq!(framing("HTTP/1.1 103 Early Hints\r\nLink: </a.css>; rel=preload\r\n\r\n", &page), Ok((103, true, Framing::None)));
        assert_eq!(framing("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n", &page), Ok((101, false, Framing::None)));
        for bad in ["HTTP/1.1 200 OK\r\nContent-Length: x\r\n\r\n", "HTP/1.1 200 OK\r\n\r\n", "HTTP/1.1 200 OK\r\n", "garbage\r\n\r\n"] {
            assert_eq!(framing(bad, &page), Err(Reject::Bad), "{bad:?}");
        }
    }

    /// Feeds `body` in pieces of `step` bytes and says how many bytes belonged to it.
    fn chunked_end(body: &[u8], step: usize) -> Result<Option<usize>, Malformed> {
        let mut c = Framing::Chunked(Chunked::new());
        let mut taken = 0;
        for piece in body.chunks(step) {
            let (n, done) = c.take(piece)?;
            taken += n;
            if done {
                return Ok(Some(taken));
            }
            assert_eq!(n, piece.len(), "a body that is not over takes everything");
        }
        Ok(None)
    }

    #[test]
    fn a_chunked_body_ends_where_it_says_however_it_is_cut() {
        let plain = b"5\r\nhello\r\n1;ext=\"a;b\"\r\n!\r\nA\r\n0123456789\r\n0\r\n\r\n".to_vec();
        let trailers = b"3\r\nabc\r\n0\r\nX-Sum: 1\r\nX-More: 2\r\n\r\n".to_vec();
        // Data that looks like the end of a body is still data.
        let tricky = b"7\r\n0\r\n\r\n\r\n\r\n0\r\n\r\n".to_vec();
        for body in [plain, trailers, tricky] {
            let mut followed = body.clone();
            followed.extend_from_slice(b"GET /next HTTP/1.1\r\n\r\n");
            for step in 1..=followed.len() {
                assert_eq!(chunked_end(&followed, step), Ok(Some(body.len())), "{:?} in pieces of {step}", String::from_utf8_lossy(&body));
            }
            // Cut short, it has not ended.
            assert_eq!(chunked_end(&body[..body.len() - 1], 3), Ok(None));
        }
        for bad in [&b"x\r\n"[..], b"\r\n", b"5\r\nhelloXX", b"5\r\nhello\rX", b"FFFFFFFFFFFFFFFFF\r\n", b"-1\r\n", b"5 \r\nhello\r\n", b" 5\r\nhello\r\n", b"5\t\r\nhello\r\n", b"1 0\r\n", b"0x5\r\nhello\r\n", b"+5\r\nhello\r\n"] {
            assert_eq!(chunked_end(bad, 1), Err(Malformed), "{:?}", String::from_utf8_lossy(bad));
        }
        // A length is counted down across pieces.
        let mut len = Framing::Length(10);
        assert_eq!((len.take(b"1234"), len.take(b"5678"), len.take(b"90NEXT")), (Ok((4, false)), Ok((4, false)), Ok((2, true))));
    }

    #[tokio::test]
    async fn a_head_is_read_whole_and_one_that_is_too_long_is_not() {
        let (mut far, near) = tokio::io::duplex(1 << 20);
        let mut r = Reader::new(near);
        far.write_all(b"GET / HTTP/1.1\r\nHo").await.unwrap();
        far.write_all(b"st: a\r\n\r").await.unwrap();
        far.write_all(b"\nBODY").await.unwrap();
        let len = r.head().await.unwrap();
        assert_eq!(&r.buf[..len], b"GET / HTTP/1.1\r\nHost: a\r\n\r\n");
        r.buf.drain(..len);
        assert_eq!(r.buf, b"BODY");
        r.buf.clear();
        // The other side closes between two messages, or in the middle of one.
        far.write_all(b"GET / HT").await.unwrap();
        drop(far);
        assert_eq!(r.head().await, Err(NoHead::Broken));
        let (far, near) = tokio::io::duplex(64);
        drop(far);
        assert_eq!(Reader::new(near).head().await, Err(NoHead::Closed));
        // A head that never ends is given up on at `HEAD_MAX`, not held.
        let (mut far, near) = tokio::io::duplex(1 << 20);
        let mut r = Reader::new(near);
        let feed = tokio::spawn(async move {
            let _ = far.write_all(b"GET / HTTP/1.1\r\n").await;
            let line = format!("X-Fill: {}\r\n", "x".repeat(1000));
            while far.write_all(line.as_bytes()).await.is_ok() {}
        });
        assert_eq!(r.head().await, Err(NoHead::TooLarge));
        assert!(r.buf.capacity() <= HEAD_MAX + 2 * READ, "{}", r.buf.capacity());
        feed.abort();
    }

    #[tokio::test]
    async fn a_body_of_any_length_passes_through_one_small_buffer() {
        const LENGTH: usize = 8 << 20;
        let (mut far, near) = tokio::io::duplex(256 * 1024);
        let (mut out, mut sink) = tokio::io::duplex(256 * 1024);
        let feed = tokio::spawn(async move {
            let piece: Vec<u8> = (0..65_521u32).map(|i| (i % 251) as u8).collect();
            let mut left = LENGTH;
            while left > 0 {
                let n = left.min(piece.len());
                far.write_all(&piece[..n]).await.unwrap();
                left -= n;
            }
            far
        });
        let drain = tokio::spawn(async move {
            let (mut total, mut sum, mut buf) = (0usize, 0u64, vec![0u8; 64 * 1024]);
            loop {
                let n = sink.read(&mut buf).await.unwrap();
                if n == 0 {
                    return (total, sum);
                }
                total += n;
                sum += buf[..n].iter().map(|b| u64::from(*b)).sum::<u64>();
            }
        });
        let mut r = Reader::new(near);
        let mut most = 0;
        let mut body = Framing::Length(LENGTH as u64);
        // `pass`, a piece at a time, so the buffer can be looked at on the way.
        loop {
            let (n, done) = body.take(&r.buf).unwrap();
            out.write_all(&r.buf[..n]).await.unwrap();
            r.buf.drain(..n);
            most = most.max(r.buf.capacity());
            if done {
                break;
            }
            assert!(r.fill().await.unwrap() > 0);
            most = most.max(r.buf.capacity());
        }
        drop(out);
        let _far = feed.await.unwrap();
        let (total, sum) = drain.await.unwrap();
        let round: u64 = (0..65_521u64).map(|i| i % 251).sum();
        let expected = (LENGTH / 65_521) as u64 * round + (0..(LENGTH % 65_521) as u64).map(|i| i % 251).sum::<u64>();
        assert_eq!((total, sum), (LENGTH, expected));
        assert!(most <= HEAD_MAX + 2 * READ, "8 MB passed through a buffer that grew to {most} bytes");
        // The same through `pass` itself: the head goes out with the start of the body.
        let (mut far, near) = tokio::io::duplex(1 << 16);
        let (mut out, mut sink) = tokio::io::duplex(1 << 16);
        far.write_all(b"hello world, and the next message").await.unwrap();
        let mut r = Reader::new(near);
        r.fill().await.unwrap();
        assert_eq!(r.pass(b"HEAD|".to_vec(), Framing::Length(11), &mut out).await.unwrap(), true);
        let mut got = [0u8; 16];
        sink.read_exact(&mut got).await.unwrap();
        assert_eq!((&got[..], &r.buf[..]), (&b"HEAD|hello world"[..], &b", and the next message"[..]));
        // A body cut short by the end of the stream says so.
        drop(far);
        assert_eq!(r.pass(vec![], Framing::Length(1000), &mut out).await.unwrap(), false);
    }
}
