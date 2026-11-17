//! TLS, and a small HTTP/1.1 client for the two things the helper asks the internet for: a
//! `POST` to the push gateway, and `GET`s of release files. One request per connection
//! (`Connection: close`), no redirects (the caller decides which ones to follow), no
//! compression. Built on tokio, rustls and `httparse`, which the WebSocket client already uses.

use crate::rex::Io;
use std::sync::{Arc, OnceLock};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;

/// TLS settings for the gateway, release downloads and remote Rex servers, built on first use
/// (most helpers only ever talk to a local socket and push rarely).
pub fn tls_config(alpn: &[u8]) -> Arc<rustls::ClientConfig> {
    static ROOTS: OnceLock<Arc<rustls::RootCertStore>> = OnceLock::new();
    let roots = ROOTS.get_or_init(|| {
        let mut r = rustls::RootCertStore::empty();
        r.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        Arc::new(r)
    });
    let mut cfg = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .with_safe_default_protocol_versions()
        .expect("TLS versions")
        .with_root_certificates(roots.clone())
        .with_no_client_auth();
    cfg.alpn_protocols = vec![alpn.to_vec()];
    Arc::new(cfg)
}

pub async fn tls_connect(
    host: &str,
    port: u16,
    alpn: &[u8],
) -> Result<tokio_rustls::client::TlsStream<TcpStream>, String> {
    let tcp = TcpStream::connect((host, port)).await.map_err(|e| e.to_string())?;
    let _ = tcp.set_nodelay(true);
    let name = rustls::pki_types::ServerName::try_from(host.to_string()).map_err(|e| e.to_string())?;
    tokio_rustls::TlsConnector::from(tls_config(alpn)).connect(name, tcp).await.map_err(|e| e.to_string())
}

/// An `http://` or `https://` address, split up. Strict on purpose: no user name, no IPv6
/// literal, no fragment, nothing but visible ASCII.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Url {
    pub secure: bool,
    /// Lowercase.
    pub host: String,
    pub port: u16,
    /// Path and query, starting with `/`.
    pub path: String,
}

impl Url {
    pub fn parse(s: &str) -> Option<Url> {
        if s.len() > 4096 || !s.bytes().all(|b| b.is_ascii_graphic()) || s.contains('#') {
            return None;
        }
        let (scheme, rest) = s.split_once("://")?;
        let secure = match scheme {
            "https" => true,
            "http" => false,
            _ => return None,
        };
        let split = rest.find(['/', '?']).unwrap_or(rest.len());
        let (authority, path) = rest.split_at(split);
        let (host, port) = match authority.rsplit_once(':') {
            Some((h, p)) => (h, p.parse().ok()?),
            None => (authority, if secure { 443 } else { 80 }),
        };
        let host_ok = !host.is_empty()
            && !host.starts_with(['.', '-'])
            && host.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-');
        if !host_ok {
            return None;
        }
        let path = match path {
            "" => "/".to_string(),
            p if p.starts_with('?') => format!("/{p}"),
            p => p.to_string(),
        };
        Some(Url { secure, host: host.to_ascii_lowercase(), port, path })
    }

    /// The `Host` header: the port only when it isn't the scheme's own.
    pub fn authority(&self) -> String {
        if self.port == if self.secure { 443 } else { 80 } {
            self.host.clone()
        } else {
            format!("{}:{}", self.host, self.port)
        }
    }

    /// True for the two names that mean this machine, the only ones plain `http` is allowed to.
    pub fn is_loopback(&self) -> bool {
        self.host == "127.0.0.1" || self.host == "localhost"
    }
}

impl std::fmt::Display for Url {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}://{}{}", if self.secure { "https" } else { "http" }, self.authority(), self.path)
    }
}

/// The largest response head read, and the largest chunk-size line.
const HEAD_LIMIT: usize = 16 << 10;

#[derive(Debug, PartialEq)]
enum Framing {
    None,
    Length(u64),
    Chunked,
    UntilClose,
}

/// A response whose head has been read. `read_body` streams the rest.
pub struct Exchange {
    io: Box<dyn Io>,
    /// Body bytes that arrived with the head.
    rest: Vec<u8>,
    pub status: u16,
    /// Names in lowercase.
    headers: Vec<(String, String)>,
    framing: Framing,
}

impl std::fmt::Debug for Exchange {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Exchange({})", self.status)
    }
}

/// A header value may not carry a line break: that would start another header.
fn header_safe(s: &str) -> bool {
    s.bytes().all(|b| b == b'\t' || (b' '..0x7f).contains(&b))
}

fn find(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

impl Exchange {
    /// Connects, sends the request and reads the response head. Plain `http` only goes to this
    /// machine. The caller sets the time limit.
    pub async fn open(method: &str, url: &Url, headers: &[(&str, String)], body: Option<&[u8]>) -> Result<Exchange, String> {
        if !url.secure && !url.is_loopback() {
            return Err("refusing plain http".into());
        }
        let mut head = format!(
            "{method} {} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\nAccept-Encoding: identity\r\n",
            url.path,
            url.authority()
        );
        for (name, value) in headers {
            if !header_safe(name) || !header_safe(value) {
                return Err(format!("bad {name} header"));
            }
            head += &format!("{name}: {value}\r\n");
        }
        if let Some(b) = body {
            head += &format!("Content-Length: {}\r\n", b.len());
        }
        head += "\r\n";
        let mut io: Box<dyn Io> = if url.secure {
            Box::new(tls_connect(&url.host, url.port, b"http/1.1").await?)
        } else {
            Box::new(TcpStream::connect((url.host.as_str(), url.port)).await.map_err(|e| e.to_string())?)
        };
        let mut out = head.into_bytes();
        out.extend_from_slice(body.unwrap_or_default());
        io.write_all(&out).await.map_err(|e| e.to_string())?;
        io.flush().await.map_err(|e| e.to_string())?;

        let mut buf = Vec::with_capacity(2048);
        let end = loop {
            if let Some(i) = find(&buf, b"\r\n\r\n") {
                break i + 4;
            }
            if buf.len() > HEAD_LIMIT {
                return Err("response head too large".into());
            }
            let mut chunk = [0u8; 2048];
            match io.read(&mut chunk).await {
                Ok(0) => return Err("connection closed before a response".into()),
                Ok(n) => buf.extend_from_slice(&chunk[..n]),
                Err(e) => return Err(e.to_string()),
            }
        };
        let mut parsed = [httparse::EMPTY_HEADER; 64];
        let mut resp = httparse::Response::new(&mut parsed);
        match resp.parse(&buf[..end]) {
            Ok(httparse::Status::Complete(_)) => {}
            _ => return Err("not an HTTP response".into()),
        }
        let status = resp.code.ok_or("not an HTTP response")?;
        let headers: Vec<(String, String)> = resp
            .headers
            .iter()
            .map(|h| (h.name.to_ascii_lowercase(), String::from_utf8_lossy(h.value).trim().to_string()))
            .collect();
        let get = |n: &str| headers.iter().find(|(k, _)| k == n).map(|(_, v)| v.as_str());
        let framing = if method == "HEAD" || status == 204 || status == 304 || (100..200).contains(&status) {
            Framing::None
        } else if get("transfer-encoding").is_some_and(|v| v.to_ascii_lowercase().contains("chunked")) {
            Framing::Chunked
        } else if let Some(n) = get("content-length") {
            Framing::Length(n.parse().map_err(|_| "bad Content-Length")?)
        } else {
            Framing::UntilClose
        };
        Ok(Exchange { io, rest: buf[end..].to_vec(), status, headers, framing })
    }

    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
    }

    async fn fill(&mut self) -> Result<usize, String> {
        let mut chunk = [0u8; 16 << 10];
        let n = self.io.read(&mut chunk).await.map_err(|e| e.to_string())?;
        self.rest.extend_from_slice(&chunk[..n]);
        Ok(n)
    }

    /// Hands up to `want` body bytes to `sink`, reading more when none are buffered.
    async fn pass(&mut self, want: u64, sink: &mut (dyn FnMut(&[u8]) -> Result<(), String> + Send)) -> Result<u64, String> {
        if self.rest.is_empty() && self.fill().await? == 0 {
            return Err("connection closed in the middle of the response".into());
        }
        let n = self.rest.len().min(usize::try_from(want).unwrap_or(usize::MAX));
        sink(&self.rest[..n])?;
        self.rest.drain(..n);
        Ok(n as u64)
    }

    /// One CRLF-terminated line of the chunked framing, without the CRLF.
    async fn line(&mut self) -> Result<String, String> {
        loop {
            if let Some(i) = find(&self.rest, b"\r\n") {
                let line = String::from_utf8_lossy(&self.rest[..i]).into_owned();
                self.rest.drain(..i + 2);
                return Ok(line);
            }
            if self.rest.len() > HEAD_LIMIT || self.fill().await? == 0 {
                return Err("bad chunked response".into());
            }
        }
    }

    /// Streams the body to `sink`, which stops the transfer by returning an error (too large,
    /// for one).
    pub async fn read_body(mut self, sink: &mut (dyn FnMut(&[u8]) -> Result<(), String> + Send)) -> Result<(), String> {
        match self.framing {
            Framing::None => Ok(()),
            Framing::Length(mut left) => {
                while left > 0 {
                    left -= self.pass(left, sink).await?;
                }
                Ok(())
            }
            Framing::Chunked => loop {
                let line = self.line().await?;
                let size = line.split(';').next().unwrap_or("").trim();
                let mut left = u64::from_str_radix(size, 16).map_err(|_| "bad chunked response")?;
                if left == 0 {
                    return Ok(());
                }
                while left > 0 {
                    left -= self.pass(left, sink).await?;
                }
                if !self.line().await?.is_empty() {
                    return Err("bad chunked response".into());
                }
            },
            Framing::UntilClose => loop {
                if !self.rest.is_empty() {
                    sink(&self.rest)?;
                    self.rest.clear();
                }
                // A peer that hangs up without a TLS goodbye still ended the body; whoever asked
                // checks what arrived (JSON that parses, a hash that matches).
                if self.fill().await.unwrap_or(0) == 0 {
                    return Ok(());
                }
            },
        }
    }

    /// The whole body, or an error once it passes `limit` bytes.
    pub async fn body(self, limit: usize) -> Result<Vec<u8>, String> {
        let mut out = Vec::new();
        self.read_body(&mut |chunk: &[u8]| {
            if out.len() + chunk.len() > limit {
                return Err("response too large".to_string());
            }
            out.extend_from_slice(chunk);
            Ok(())
        })
        .await?;
        Ok(out)
    }
}

/// A tiny HTTP server on 127.0.0.1 for tests: answers each connection with the next canned
/// response and records what was asked.
#[cfg(test)]
pub mod testing {
    use std::sync::{Arc, Mutex};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    #[derive(Clone, Debug, Default)]
    pub struct Seen {
        pub method: String,
        pub path: String,
        /// Names in lowercase.
        pub headers: Vec<(String, String)>,
        pub body: Vec<u8>,
    }

    impl Seen {
        pub fn header(&self, name: &str) -> Option<&str> {
            self.headers.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
        }
    }

    /// One canned answer: status, extra header lines (each ending in CRLF), body.
    #[derive(Clone)]
    pub struct Canned {
        pub status: u16,
        pub headers: String,
        pub body: Vec<u8>,
        pub chunked: bool,
    }

    pub fn canned(status: u16, body: &str) -> Canned {
        Canned { status, headers: String::new(), body: body.as_bytes().to_vec(), chunked: false }
    }

    /// Starts the server. Returns its base URL (`http://127.0.0.1:<port>`) and the requests it
    /// got. The last answer repeats.
    pub async fn serve(answers: Vec<Canned>) -> (String, Arc<Mutex<Vec<Seen>>>) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let base = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
        let seen = Arc::new(Mutex::new(Vec::new()));
        let log = seen.clone();
        tokio::spawn(async move {
            let mut n = 0;
            loop {
                let Ok((mut sock, _)) = listener.accept().await else { return };
                let answer = answers[n.min(answers.len() - 1)].clone();
                n += 1;
                let mut buf = Vec::new();
                let mut chunk = [0u8; 4096];
                let (head_end, length) = loop {
                    if let Some(i) = super::find(&buf, b"\r\n\r\n") {
                        let head = String::from_utf8_lossy(&buf[..i]).to_lowercase();
                        let length = head
                            .lines()
                            .find_map(|l| l.strip_prefix("content-length:").map(|v| v.trim().parse::<usize>().unwrap()))
                            .unwrap_or(0);
                        break (i + 4, length);
                    }
                    let got = sock.read(&mut chunk).await.unwrap();
                    assert!(got > 0, "request ended early");
                    buf.extend_from_slice(&chunk[..got]);
                };
                while buf.len() < head_end + length {
                    let got = sock.read(&mut chunk).await.unwrap();
                    assert!(got > 0, "request body ended early");
                    buf.extend_from_slice(&chunk[..got]);
                }
                let head = String::from_utf8_lossy(&buf[..head_end]).into_owned();
                let mut lines = head.lines();
                let mut first = lines.next().unwrap().split(' ');
                let mut s = Seen { method: first.next().unwrap().into(), path: first.next().unwrap().into(), ..Default::default() };
                for l in lines {
                    if let Some((k, v)) = l.split_once(':') {
                        s.headers.push((k.to_lowercase(), v.trim().to_string()));
                    }
                }
                s.body = buf[head_end..].to_vec();
                log.lock().unwrap().push(s);
                let mut out = format!("HTTP/1.1 {} X\r\n{}", answer.status, answer.headers).into_bytes();
                if answer.chunked {
                    out.extend_from_slice(b"Transfer-Encoding: chunked\r\n\r\n");
                    for part in answer.body.chunks(7) {
                        out.extend_from_slice(format!("{:x}\r\n", part.len()).as_bytes());
                        out.extend_from_slice(part);
                        out.extend_from_slice(b"\r\n");
                    }
                    out.extend_from_slice(b"0\r\n\r\n");
                } else {
                    out.extend_from_slice(format!("Content-Length: {}\r\n\r\n", answer.body.len()).as_bytes());
                    out.extend_from_slice(&answer.body);
                }
                let _ = sock.write_all(&out).await;
                let _ = sock.shutdown().await;
            }
        });
        (base, seen)
    }
}

#[cfg(test)]
mod tests {
    use super::testing::{canned, serve, Canned};
    use super::*;

    #[test]
    fn parses_urls() {
        let u = Url::parse("https://Example.workers.dev/v1/push?x=1").unwrap();
        assert_eq!((u.secure, u.host.as_str(), u.port, u.path.as_str()), (true, "example.workers.dev", 443, "/v1/push?x=1"));
        assert_eq!(u.to_string(), "https://example.workers.dev/v1/push?x=1");
        let l = Url::parse("http://127.0.0.1:8787").unwrap();
        assert_eq!((l.secure, l.port, l.path.as_str(), l.authority().as_str()), (false, 8787, "/", "127.0.0.1:8787"));
        assert!(l.is_loopback());
        assert!(!Url::parse("http://127.0.0.1.evil.example/").unwrap().is_loopback());
        for bad in [
            "ftp://x/",
            "https://",
            "https://user@host/",
            "https://host/a b",
            "https://host/#frag",
            "https://[::1]/",
            "https://host:99999/",
            "https://host/\r\nX: y",
            "//host/",
        ] {
            assert!(Url::parse(bad).is_none(), "{bad}");
        }
    }

    #[tokio::test]
    async fn reads_a_sized_and_a_chunked_body() {
        let text = "hello, this is a body longer than one chunk";
        let chunked = Canned { chunked: true, ..canned(200, text) };
        let (base, seen) = serve(vec![canned(200, text), chunked]).await;
        let url = Url::parse(&format!("{base}/file")).unwrap();
        for _ in 0..2 {
            let x = Exchange::open("GET", &url, &[("User-Agent", "t".into())], None).await.unwrap();
            assert_eq!(x.status, 200);
            assert_eq!(x.body(1 << 20).await.unwrap(), text.as_bytes());
        }
        let seen = seen.lock().unwrap();
        assert_eq!(seen[0].method, "GET");
        assert_eq!(seen[0].path, "/file");
        assert_eq!(seen[0].header("connection"), Some("close"));
    }

    #[tokio::test]
    async fn a_body_past_the_limit_is_an_error() {
        let (base, _) = serve(vec![canned(200, &"x".repeat(5000))]).await;
        let url = Url::parse(&base).unwrap();
        let x = Exchange::open("GET", &url, &[], None).await.unwrap();
        assert_eq!(x.header("content-length"), Some("5000"));
        assert_eq!(x.body(4999).await.unwrap_err(), "response too large");
    }

    #[tokio::test]
    async fn refuses_plain_http_to_another_machine_and_split_headers() {
        let far = Url::parse("http://example.com/").unwrap();
        assert_eq!(Exchange::open("GET", &far, &[], None).await.unwrap_err(), "refusing plain http");
        let (base, seen) = serve(vec![canned(200, "")]).await;
        let url = Url::parse(&base).unwrap();
        let e = Exchange::open("GET", &url, &[("Authorization", "Bearer a\r\nX-Evil: 1".into())], None).await;
        assert!(e.is_err());
        assert!(seen.lock().unwrap().is_empty());
    }
}
