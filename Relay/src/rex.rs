//! A minimal Rex control-API client (`/api/control`, subprotocol `rex.control.v1`) over the
//! local Unix socket or a remote HTTPS address. Protocol reference: the server's `/llms.txt`.
//!
//! Event driven: while connected, nothing runs until the server sends something. Rex pings
//! every 120 s and tungstenite answers; a local server that goes away closes the socket.

use crate::discovery::Endpoint;
use crate::util::Json;
use futures_util::{SinkExt, StreamExt};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;
use tokio::io::{AsyncRead, AsyncWrite};
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::protocol::{frame::coding::CloseCode, CloseFrame, WebSocketConfig};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;

pub const API_REVISION: i64 = 14;

/// How the relay introduces itself. Rex DUO finds it by `name` in `client.list`.
#[derive(Clone, Debug)]
pub struct Identity {
    pub kind: String,
    pub platform: String,
    /// Don't change: the app looks for `rex-push-relay`.
    pub name: String,
    pub version: String,
    pub label: String,
}

impl Default for Identity {
    fn default() -> Self {
        Identity {
            kind: "other".into(),
            platform: if cfg!(target_os = "macos") { "macos" } else { "linux" }.into(),
            name: "rex-push-relay".into(),
            version: env!("CARGO_PKG_VERSION").into(),
            label: "rex-push-relay".into(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct RexError {
    pub code: String,
    pub message: String,
}

impl RexError {
    pub fn local(m: impl Into<String>) -> RexError {
        RexError { code: "client".into(), message: m.into() }
    }
}

impl std::fmt::Display for RexError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} ({})", self.message, self.code)
    }
}

pub trait Io: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Io for T {}
pub type Ws = WebSocketStream<Box<dyn Io>>;

pub struct Attached {
    stream: futures_util::stream::SplitStream<Ws>,
    writer: tokio::task::JoinHandle<()>,
}

/// The first message after `hello`.
pub struct Welcome {
    pub client_id: Option<String>,
    pub reconnect_token: Option<String>,
    pub resumed: bool,
}

/// Connects, upgrades, says hello and waits for the welcome.
pub async fn open(ep: &Endpoint, me: &Identity, reconnect_token: Option<&str>) -> Result<(Ws, Welcome), String> {
    let (io, url): (Box<dyn Io>, String) = match ep {
        Endpoint::Unix(path) => {
            #[cfg(unix)]
            {
                let s = tokio::net::UnixStream::connect(path).await.map_err(|e| format!("{}: {e}", path.display()))?;
                // Any host name works over the socket.
                (Box::new(s), "ws://localhost/api/control".into())
            }
            #[cfg(not(unix))]
            return Err(format!("unix sockets are not supported here: {}", path.display()));
        }
        Endpoint::Url { secure, host, port, .. } => {
            let authority = if (*secure && *port == 443) || (!*secure && *port == 80) { host.clone() } else { format!("{host}:{port}") };
            if *secure {
                let tls = crate::apns::tls_connect(host, *port, b"http/1.1").await?;
                (Box::new(tls), format!("wss://{authority}/api/control"))
            } else {
                let tcp = tokio::net::TcpStream::connect((host.as_str(), *port)).await.map_err(|e| e.to_string())?;
                (Box::new(tcp), format!("ws://{authority}/api/control"))
            }
        }
    };
    let mut req = url.into_client_request().map_err(|e| e.to_string())?;
    req.headers_mut().insert("Sec-WebSocket-Protocol", "rex.control.v1".parse().unwrap());
    req.headers_mut().insert("User-Agent", "rex-duo-helper".parse().unwrap());
    let cfg = WebSocketConfig::default().max_message_size(Some(16 << 20));
    let (mut ws, _) = tokio_tungstenite::client_async_with_config(req, io, Some(cfg))
        .await
        .map_err(|e| format!("WebSocket handshake failed: {e}"))?;

    let mut client = json!({"kind": me.kind, "platform": me.platform, "name": me.name, "version": me.version, "label": me.label});
    client.as_object_mut().unwrap().retain(|_, v| v.as_str() != Some(""));
    let mut hello = json!({"type": "hello", "api_revision": API_REVISION, "client": client});
    if let Some(t) = reconnect_token {
        hello["reconnect_token"] = json!(t);
    }
    ws.send(Message::text(hello.to_string())).await.map_err(|e| e.to_string())?;

    // The welcome is always the first message.
    loop {
        let m = ws.next().await.ok_or("closed before welcome")?.map_err(|e| e.to_string())?;
        let text = match m {
            Message::Text(t) => t.to_string(),
            Message::Binary(b) => String::from_utf8_lossy(&b).into_owned(),
            Message::Close(f) => return Err(format!("closed before welcome{}", f.map(|f| format!(": {} {}", f.code, f.reason)).unwrap_or_default())),
            _ => continue,
        };
        let v: Value = serde_json::from_str(&text).map_err(|_| "expected welcome")?;
        if v.str("type") != Some("welcome") {
            let why = v.obj("error").and_then(|e| e.str("message")).unwrap_or("expected welcome").to_string();
            let _ = ws.close(None).await;
            return Err(why);
        }
        let c = v.obj("client");
        return Ok((
            ws,
            Welcome {
                client_id: c.and_then(|c| c.str("id")).map(String::from),
                reconnect_token: c.and_then(|c| c.str("reconnect_token")).map(String::from),
                resumed: c.and_then(|c| c.bool("resumed")).unwrap_or(false),
            },
        ));
    }
}

type Reply = oneshot::Sender<Result<Value, RexError>>;

struct Live {
    out: mpsc::UnboundedSender<Message>,
    pending: HashMap<String, Reply>,
    next_id: u64,
}

/// The call side of one server connection. Survives reconnects; calls fail while it's down.
#[derive(Default)]
pub struct Conn {
    live: Mutex<Option<Live>>,
}

impl Conn {
    pub fn is_connected(&self) -> bool {
        self.live.lock().unwrap().is_some()
    }

    pub async fn call(&self, method: &str, payload: Value) -> Result<Value, RexError> {
        let (id, rx) = {
            let mut g = self.live.lock().unwrap();
            let live = g.as_mut().ok_or_else(|| RexError::local("not connected"))?;
            live.next_id += 1;
            let id = format!("r{}", live.next_id);
            let req = json!({"type": "request", "id": id, "method": method, "payload": payload});
            let (tx, rx) = oneshot::channel();
            live.pending.insert(id.clone(), tx);
            if live.out.send(Message::text(req.to_string())).is_err() {
                live.pending.remove(&id);
                return Err(RexError::local("connection lost"));
            }
            (id, rx)
        };
        match tokio::time::timeout(Duration::from_secs(20), rx).await {
            Ok(Ok(r)) => r,
            Ok(Err(_)) => Err(RexError::local("connection lost")),
            Err(_) => {
                if let Some(l) = self.live.lock().unwrap().as_mut() {
                    l.pending.remove(&id);
                }
                Err(RexError::local(format!("{method} timed out")))
            }
        }
    }

    /// Sends a close frame, so Rex drops this client at once instead of holding it as `lost`.
    pub fn close(&self, code: CloseCode) {
        if let Some(l) = self.live.lock().unwrap().as_ref() {
            let _ = l.out.send(Message::Close(Some(CloseFrame { code, reason: "".into() })));
        }
    }

    /// Takes over an open connection: calls go out on it from now on.
    pub fn attach(&self, ws: Ws) -> Attached {
        let (mut sink, stream) = ws.split();
        let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
        *self.live.lock().unwrap() = Some(Live { out: tx, pending: HashMap::new(), next_id: 0 });
        let writer = tokio::spawn(async move {
            while let Some(m) = rx.recv().await {
                let closing = matches!(m, Message::Close(_));
                if sink.send(m).await.is_err() || closing {
                    break;
                }
            }
            let _ = sink.close().await;
        });
        Attached { stream, writer }
    }

    /// Reads an attached connection until it ends: answers calls, and hands each event's
    /// inner object (`{type, payload}`) to `on_event`. Returns why it ended. `idle` drops a
    /// connection that has been silent that long (remote servers only).
    pub async fn serve(&self, a: Attached, idle: Option<Duration>, mut on_event: impl FnMut(Value)) -> String {
        let Attached { mut stream, writer } = a;
        let reason = loop {
            let next = match idle {
                Some(d) => match tokio::time::timeout(d, stream.next()).await {
                    Ok(n) => n,
                    Err(_) => break "no message from the server in a while".to_string(),
                },
                None => stream.next().await,
            };
            let m = match next {
                None => break "connection closed".to_string(),
                Some(Err(e)) => break e.to_string(),
                Some(Ok(m)) => m,
            };
            let text = match &m {
                Message::Text(t) => t.as_str(),
                Message::Close(f) => {
                    break format!("closed{}", f.as_ref().map(|f| format!(" {} {}", f.code, f.reason)).unwrap_or_default())
                }
                _ => continue, // pings are answered by tungstenite
            };
            let Ok(v) = serde_json::from_str::<Value>(text) else { continue };
            match v.str("type") {
                Some("response") => {
                    let Some(id) = v.str("id") else { continue };
                    let reply = self.live.lock().unwrap().as_mut().and_then(|l| l.pending.remove(id));
                    if let Some(reply) = reply {
                        let r = match v.obj("error") {
                            Some(e) => Err(RexError {
                                code: e.str("code").unwrap_or("internal").into(),
                                message: e.str("message").unwrap_or("error").into(),
                            }),
                            None => Ok(v.get("payload").cloned().unwrap_or(Value::Null)),
                        };
                        let _ = reply.send(r);
                    }
                }
                Some("event") => {
                    if let Some(inner) = v.obj("payload") {
                        on_event(inner.clone());
                    }
                }
                _ => {}
            }
        };
        // Dropping Live fails every pending call with "connection lost".
        *self.live.lock().unwrap() = None;
        writer.abort();
        reason
    }
}
