//! Finds the Rex server on this machine without any configuration, before every connection
//! attempt:
//!
//! 1. `REX_SERVER`, which Rex sets in its own terminals.
//! 2. The default local socket: macOS `~/Library/Application Support/rex/server.sock`,
//!    Linux `$XDG_RUNTIME_DIR/rex/server.sock` (`/run/user/<uid>/rex/server.sock`).
//! 3. `rex --autostart=false server status --json` (never starts a server): its `endpoint`,
//!    else its Tailscale HTTPS URL.

use crate::config::home;
use crate::util::Json;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Where a Rex server listens: its local Unix socket, or an HTTP(S) address such as its
/// Tailscale URL.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Endpoint {
    Unix(PathBuf),
    Url { secure: bool, host: String, port: u16, raw: String },
}

impl Endpoint {
    /// Parses `unix:///path/to/server.sock` (percent-encoded, as Rex prints it) or an
    /// `http(s)://` / `ws(s)://` address.
    pub fn parse(s: &str) -> Option<Endpoint> {
        let s = s.trim();
        let (scheme, rest) = s.split_once("://")?;
        match scheme.to_ascii_lowercase().as_str() {
            "unix" => {
                let path = percent_decode(rest);
                (path.starts_with('/') && path.len() > 1).then(|| Endpoint::Unix(PathBuf::from(path)))
            }
            sch @ ("http" | "https" | "ws" | "wss") => {
                let secure = sch == "https" || sch == "wss";
                let authority = rest.split(['/', '?', '#']).next()?;
                let authority = authority.rsplit('@').next()?;
                let (host, port) = if let Some(v6) = authority.strip_prefix('[') {
                    let (h, after) = v6.split_once(']')?;
                    (h.to_string(), after.strip_prefix(':').map(str::to_string))
                } else {
                    match authority.rsplit_once(':') {
                        Some((h, p)) => (h.to_string(), Some(p.to_string())),
                        None => (authority.to_string(), None),
                    }
                };
                if host.is_empty() {
                    return None;
                }
                let port = match port {
                    Some(p) => p.parse().ok()?,
                    None => if secure { 443 } else { 80 },
                };
                Some(Endpoint::Url { secure, host, port, raw: s.to_string() })
            }
            _ => None,
        }
    }

    /// True when both name one server: the same socket file (through any links), or the same
    /// scheme, host and port.
    pub fn same(&self, other: &Endpoint) -> bool {
        match (self, other) {
            (Endpoint::Unix(a), Endpoint::Unix(b)) => {
                let real = |p: &PathBuf| p.canonicalize().unwrap_or_else(|_| p.clone());
                real(a) == real(b)
            }
            (Endpoint::Url { secure: s1, host: h1, port: p1, .. }, Endpoint::Url { secure: s2, host: h2, port: p2, .. }) => {
                s1 == s2 && p1 == p2 && h1.eq_ignore_ascii_case(h2)
            }
            _ => false,
        }
    }

    /// Short name for log lines.
    pub fn short(&self) -> String {
        match self {
            Endpoint::Unix(_) => "local".into(),
            Endpoint::Url { host, .. } => host.clone(),
        }
    }
}

impl std::fmt::Display for Endpoint {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Endpoint::Unix(p) => write!(f, "unix:{}", p.display()),
            Endpoint::Url { raw, .. } => f.write_str(raw),
        }
    }
}

fn percent_decode(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let Some(v) = std::str::from_utf8(&b[i + 1..i + 3]).ok().and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Rex's default local socket on this OS.
pub fn default_socket() -> PathBuf {
    if cfg!(target_os = "macos") {
        home().join("Library/Application Support/rex/server.sock")
    } else {
        let runtime = std::env::var_os("XDG_RUNTIME_DIR").map(PathBuf::from).unwrap_or_else(|| {
            #[cfg(unix)]
            {
                use std::os::unix::fs::MetadataExt;
                let uid = std::fs::metadata("/proc/self").map(|m| m.uid()).unwrap_or(1000);
                PathBuf::from(format!("/run/user/{uid}"))
            }
            #[cfg(not(unix))]
            PathBuf::from("/tmp")
        });
        runtime.join("rex/server.sock")
    }
}

/// Where the rex CLI usually lives. Background jobs get no shell PATH.
pub fn cli_candidates() -> Vec<PathBuf> {
    let h = home();
    let mut paths: Vec<PathBuf> = std::env::var("PATH")
        .unwrap_or_default()
        .split(':')
        .filter(|p| !p.is_empty())
        .map(|p| Path::new(p).join("rex"))
        .collect();
    if cfg!(target_os = "macos") {
        paths.push(h.join(
            "Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex",
        ));
        paths.push("/opt/homebrew/bin/rex".into());
    }
    paths.extend([
        "/usr/local/bin/rex".into(),
        h.join(".local/bin/rex"),
        h.join("bin/rex"),
        "/usr/bin/rex".into(),
    ]);
    paths
}

fn is_executable(p: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::metadata(p).map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0).unwrap_or(false)
    }
    #[cfg(not(unix))]
    p.is_file()
}

pub async fn find() -> Option<Endpoint> {
    if let Some(ep) = std::env::var("REX_SERVER").ok().and_then(|s| Endpoint::parse(&s)) {
        return Some(ep);
    }
    let sock = default_socket();
    if sock.exists() {
        return Some(Endpoint::Unix(sock));
    }
    from_cli().await
}

async fn from_cli() -> Option<Endpoint> {
    let rex = cli_candidates().into_iter().find(|p| is_executable(p))?;
    let out = run(&rex, &["--autostart=false", "--timeout", "3s", "server", "status", "--json"]).await?;
    let status: serde_json::Value = serde_json::from_slice(&out).ok()?;
    if let Some(ep) = status.str("endpoint").and_then(Endpoint::parse) {
        match &ep {
            Endpoint::Unix(p) if !p.exists() => {} // fall through to Tailscale
            _ => return Some(ep),
        }
    }
    status.obj("tailscale")?.obj("https")?.text("url").and_then(|u| Endpoint::parse(&u))
}

/// Runs a command; its stdout, or None if it failed or took over 5 s.
pub async fn run(path: &Path, args: &[&str]) -> Option<Vec<u8>> {
    let child = crate::tools::async_command(path)?
        .args(args)
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .ok()?;
    let out = tokio::time::timeout(Duration::from_secs(5), child.wait_with_output()).await.ok()?.ok()?;
    out.status.success().then_some(out.stdout)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_endpoints() {
        assert_eq!(
            Endpoint::parse("unix:///Users/me/Library/Application%20Support/rex/server.sock"),
            Some(Endpoint::Unix("/Users/me/Library/Application Support/rex/server.sock".into()))
        );
        assert_eq!(Endpoint::parse("unix:///run/user/1000/rex/server.sock").unwrap().to_string(), "unix:/run/user/1000/rex/server.sock");
        match Endpoint::parse("https://rex-box.example.ts.net/").unwrap() {
            Endpoint::Url { secure, host, port, .. } => {
                assert!(secure);
                assert_eq!(host, "rex-box.example.ts.net");
                assert_eq!(port, 443);
            }
            e => panic!("{e:?}"),
        }
        match Endpoint::parse("http://127.0.0.1:8765").unwrap() {
            Endpoint::Url { secure, port, .. } => assert!(!secure && port == 8765),
            e => panic!("{e:?}"),
        }
        assert_eq!(Endpoint::parse("login-server:///run/x.sock"), None);
        assert_eq!(Endpoint::parse("unix://"), None);
        assert_eq!(Endpoint::parse("nonsense"), None);
    }

    #[test]
    fn two_spellings_of_one_server_are_the_same() {
        let p = |s: &str| Endpoint::parse(s).unwrap();
        assert!(p("https://Rex-Box.example.ts.net/").same(&p("https://rex-box.example.ts.net:443")));
        assert!(p("wss://rex-box.example.ts.net").same(&p("https://rex-box.example.ts.net")));
        assert!(!p("https://rex-box.example.ts.net").same(&p("http://rex-box.example.ts.net")));
        assert!(!p("https://rex-box.example.ts.net").same(&p("https://rex-box.example.ts.net:8443")));
        assert!(!p("https://rex-box.example.ts.net").same(&p("https://other.example.ts.net")));
        assert!(p("unix:///run/user/1000/rex/server.sock").same(&p("unix:///run/user/1000/rex/server%2Esock")));
        assert!(!p("unix:///run/user/1000/rex/server.sock").same(&p("unix:///run/user/1001/rex/server.sock")));
        assert!(!p("unix:///run/user/1000/rex/server.sock").same(&p("https://rex-box.example.ts.net")));
    }

    #[test]
    fn rexs_socket_is_where_this_system_has_it() {
        let socket = default_socket();
        assert!(socket.is_absolute() && socket.ends_with("rex/server.sock"), "{socket:?}");
        if cfg!(target_os = "macos") {
            assert_eq!(socket, home().join("Library/Application Support/rex/server.sock"));
        }
    }

    #[cfg(unix)]
    #[test]
    fn a_program_is_a_file_someone_may_run() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("discovery-program-{}-{}", std::process::id(), crate::util::now()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("rex");
        std::fs::write(&file, "").unwrap();
        for (mode, runs) in [(0o644, false), (0o600, false), (0o755, true), (0o700, true), (0o001, true)] {
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(mode)).unwrap();
            assert_eq!(is_executable(&file), runs, "{mode:o}");
        }
        // A folder has the bits and is no program; nor is a name with nothing behind it.
        assert!(!is_executable(&dir));
        assert!(!is_executable(&dir.join("missing")));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
