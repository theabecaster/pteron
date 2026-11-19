//! Who is asking, and where pushes may go.
//!
//! Every client action arrives with a `requester` object that the Rex server fills in from the
//! requester's own connection, so it can't be faked. What a client says about itself (`info`:
//! name, label) is for showing; what the server found out (`principal`) decides what is allowed.

use crate::net::Url;
use crate::util::Json;
use serde_json::Value;

/// The gateway every copy of the phone app registers with unless its user set up another one.
pub const DEFAULT_GATEWAY: &str = "https://rexduo-push.keptday.workers.dev";

/// The client that sent a `client.perform`.
#[derive(Clone, Debug, PartialEq)]
pub struct Requester {
    pub client_id: String,
    /// What the client calls itself. The phone app ends it with ` #<device_id>`.
    pub label: String,
    /// Who the server says it is, or None when the server couldn't tell (`anonymous`, a kind
    /// this helper doesn't know, or a principal without its identifying field).
    pub identity: Option<String>,
}

/// The stable name of a principal: its kind and the one field of that kind that names an
/// account (`uid`, `sid`, `user_id`). Display names, addresses and pids change or are shared,
/// so they are not part of it.
pub fn identity_of(principal: &Value) -> Option<String> {
    let plain = |s: &&str| !s.is_empty() && s.len() <= 200 && !s.chars().any(char::is_control);
    match principal.str("kind")? {
        "peer" => principal.get("uid")?.as_u64().map(|uid| format!("peer:{uid}")),
        "windows_peer" => principal.str("sid").filter(plain).map(|sid| format!("windows_peer:{sid}")),
        "tailscale" => principal.str("user_id").filter(plain).map(|id| format!("tailscale:{id}")),
        _ => None,
    }
}

impl Requester {
    pub fn parse(requester: &Value) -> Requester {
        Requester {
            client_id: requester.str("client_id").unwrap_or("").to_string(),
            label: requester.obj("info").and_then(|i| i.str("label")).unwrap_or("").to_string(),
            identity: requester.obj("principal").and_then(identity_of),
        }
    }

    /// The name for log lines, without anything that could break a line.
    pub fn who(&self) -> String {
        let name = if self.label.is_empty() { &self.client_id } else { &self.label };
        let shown: String = name.chars().filter(|c| !c.is_control()).take(80).collect();
        if shown.is_empty() { "?".into() } else { shown }
    }

    /// The device id the requester carries in its label, if the label ends with ` #<id>` and
    /// the id is eight lowercase hex digits.
    pub fn device_id(&self) -> Option<&str> {
        let (_, id) = self.label.rsplit_once(" #")?;
        is_device_id(id).then_some(id)
    }
}

/// An install id of the phone app: eight lowercase hex digits.
pub fn is_device_id(s: &str) -> bool {
    s.len() == 8 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// `scheme://host[:port]` of an address that names a gateway and nothing more: no path, query
/// or user name.
fn origin(s: &str) -> Option<(Url, String)> {
    let s = s.trim().trim_end_matches('/');
    let u = Url::parse(s)?;
    if s.len() > 200 || u.path != "/" {
        return None;
    }
    let text = format!("{}://{}", if u.secure { "https" } else { "http" }, u.authority());
    Some((u, text))
}

/// True for a host written as numbers (`10.0.0.5`) rather than a name (`Url` already refuses
/// IPv6 literals). Only the tests ask: the list is matched exactly, so a number can only get on
/// it from config.json, and they check the built-in entry is a name.
#[cfg(test)]
fn is_ip_literal(host: &str) -> bool {
    host.split('.').all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()))
}

/// The gateways this helper pushes through. A phone names its gateway when it registers; the
/// helper only takes one that is on this list, so a client can't point it at a host of its
/// choosing and have it send requests there.
#[derive(Clone, Debug, PartialEq)]
pub struct Gateways(Vec<String>);

impl Gateways {
    /// The built-in gateway plus the `gateways` of config.json. Returns the entries of the
    /// config that were not usable, for the log.
    ///
    /// An entry from the config may be any `https://` origin, since the computer's owner wrote
    /// it. Plain `http://` is taken only for this machine (`127.0.0.1`, `localhost`), which is
    /// what tests run a gateway on.
    pub fn new(config: &[String]) -> (Gateways, Vec<String>) {
        let mut allowed = vec![DEFAULT_GATEWAY.to_string()];
        let mut refused = vec![];
        for entry in config {
            match origin(entry) {
                Some((u, text)) if u.secure || u.is_loopback() => {
                    if !allowed.contains(&text) {
                        allowed.push(text);
                    }
                }
                _ => refused.push(entry.chars().filter(|c| !c.is_control()).take(80).collect()),
            }
        }
        (Gateways(allowed), refused)
    }

    /// The normalized origin of `address` when it is on the list.
    pub fn accept(&self, address: &str) -> Option<String> {
        let (_, text) = origin(address)?;
        self.0.contains(&text).then_some(text)
    }
}

impl Default for Gateways {
    fn default() -> Gateways {
        Gateways::new(&[]).0
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn requester(principal: Value) -> Requester {
        Requester::parse(&json!({"client_id": "client:7", "info": {"label": "Alex's iPhone #a1b2c3d4"}, "principal": principal}))
    }

    #[test]
    fn identity_is_the_kind_and_its_account_field() {
        let id = |p: Value| requester(p).identity;
        assert_eq!(id(json!({"kind": "peer", "transport": "unix", "display": "uid 501", "uid": 501, "gid": 20, "pid": 4242})).as_deref(), Some("peer:501"));
        assert_eq!(id(json!({"kind": "windows_peer", "sid": "S-1-5-21-1-2-3-1001", "pid": 7})).as_deref(), Some("windows_peer:S-1-5-21-1-2-3-1001"));
        assert_eq!(
            id(json!({"kind": "tailscale", "user_id": "12345", "login_name": "alex@example.com", "node": "alexs-iphone"})).as_deref(),
            Some("tailscale:12345")
        );
        // The same account from another device, address or process is the same identity.
        assert_eq!(id(json!({"kind": "tailscale", "user_id": "12345", "node": "alexs-ipad", "remote_addr": "100.64.0.9:1"})).as_deref(), Some("tailscale:12345"));
        assert_eq!(id(json!({"kind": "peer", "uid": 501, "pid": 1})).as_deref(), Some("peer:501"));
        // Different accounts, and the same number under another kind, are different.
        assert_ne!(id(json!({"kind": "tailscale", "user_id": "501"})), id(json!({"kind": "peer", "uid": 501})));
        assert_ne!(id(json!({"kind": "peer", "uid": 502})), id(json!({"kind": "peer", "uid": 501})));
    }

    #[test]
    fn a_requester_the_server_could_not_name_has_no_identity() {
        for principal in [
            json!({"kind": "anonymous", "transport": "tcp", "display": "anonymous"}),
            json!({"kind": "anonymous", "uid": 501, "user_id": "12345"}),
            json!({"kind": "something_new", "uid": 501}),
            json!({"kind": "peer"}),
            json!({"kind": "peer", "uid": null}),
            json!({"kind": "peer", "uid": "501"}),
            json!({"kind": "peer", "uid": -1}),
            json!({"kind": "tailscale", "login_name": "alex@example.com"}),
            json!({"kind": "tailscale", "user_id": ""}),
            json!({"kind": "tailscale", "user_id": "1\n2"}),
            json!({"kind": "windows_peer", "uid": 501}),
            json!({"uid": 501}),
            json!("peer"),
        ] {
            assert_eq!(requester(principal.clone()).identity, None, "{principal}");
        }
        // What the client says about itself never stands in for the principal.
        let claimed = Requester::parse(&json!({"client_id": "client:7", "info": {"label": "x", "principal": {"kind": "peer", "uid": 501}, "uid": 501}}));
        assert_eq!(claimed.identity, None);
        assert_eq!(Requester::parse(&json!({})).identity, None);
    }

    #[test]
    fn the_device_id_is_the_end_of_the_label() {
        let with = |label: &str| Requester { client_id: "client:7".into(), label: label.into(), identity: None };
        assert_eq!(with("Alex's iPhone #a1b2c3d4").device_id(), Some("a1b2c3d4"));
        assert_eq!(with("a #b #00ff00ff").device_id(), Some("00ff00ff"));
        for bad in ["Alex's iPhone", "Alex's iPhone #A1B2C3D4", "iPhone#a1b2c3d4", "#a1b2c3d4", "iPhone #a1b2c3d4 ", "iPhone #a1b2c3d", "iPhone #a1b2c3d4e", "iPhone #a1b2c3dg", ""] {
            assert_eq!(with(bad).device_id(), None, "{bad:?}");
        }
        assert_eq!(with("line\nbreak").who(), "linebreak");
        assert_eq!(with("").who(), "client:7");
    }

    #[test]
    fn only_listed_gateways_are_taken() {
        let (g, refused) = Gateways::new(&[]);
        assert!(refused.is_empty());
        assert_eq!(g.accept(DEFAULT_GATEWAY).as_deref(), Some(DEFAULT_GATEWAY));
        // Written another way, it is stored the one way.
        assert_eq!(g.accept(" https://REXDUO-push.keptday.workers.dev:443/ ").as_deref(), Some(DEFAULT_GATEWAY));
        for bad in [
            "",
            "rexduo-push.keptday.workers.dev",
            "http://rexduo-push.keptday.workers.dev",
            "https://rexduo-push.keptday.workers.dev:8443",
            "https://rexduo-push.keptday.workers.dev/v1",
            "https://rexduo-push.keptday.workers.dev/?a=b",
            "https://rexduo-push.keptday.workers.dev/#x",
            "https://user@rexduo-push.keptday.workers.dev",
            "https://rexduo-push.keptday.workers.dev.example.com",
            "https://evil.example.com",
            "https://push.example.workers.dev",
            "https://10.0.0.5",
            "https://127.0.0.1",
            "https://localhost",
            "http://127.0.0.1:8787",
            "http://localhost:8787",
            "ftp://127.0.0.1",
            "file:///etc/passwd",
            "https://rexduo-push.keptday.workers.dev/\r\nHost: evil",
        ] {
            assert_eq!(g.accept(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn the_config_adds_gateways_and_is_the_only_way_to_plain_http() {
        let config: Vec<String> = [
            "https://push.example.com/",
            "https://10.0.0.5:8443",
            "https://localhost:8443",
            "http://127.0.0.1:8787",
            "http://localhost:8788/",
            // Not usable: plain http to another machine, a path, not an address.
            "http://push.example.com",
            "http://10.0.0.5",
            "http://127.0.0.1.example.com",
            "https://push.example.com/base",
            "push.example.com",
        ]
        .map(String::from)
        .to_vec();
        let (g, refused) = Gateways::new(&config);
        assert_eq!(refused, config[5..]);
        assert_eq!(g.accept("https://push.example.com").as_deref(), Some("https://push.example.com"));
        assert_eq!(g.accept("https://10.0.0.5:8443/").as_deref(), Some("https://10.0.0.5:8443"));
        assert_eq!(g.accept("https://localhost:8443").as_deref(), Some("https://localhost:8443"));
        assert_eq!(g.accept("http://127.0.0.1:8787").as_deref(), Some("http://127.0.0.1:8787"));
        assert_eq!(g.accept("http://localhost:8788").as_deref(), Some("http://localhost:8788"));
        // Another port of this machine is another gateway, and is not listed.
        assert_eq!(g.accept("http://127.0.0.1:8789"), None);
        assert_eq!(g.accept("http://push.example.com"), None);
        assert_eq!(g.accept("https://push.example.com/base"), None);
        // The built-in one stays.
        assert_eq!(g.accept(DEFAULT_GATEWAY).as_deref(), Some(DEFAULT_GATEWAY));
        assert!(is_ip_literal("10.0.0.5") && !is_ip_literal("rexduo-push.keptday.workers.dev") && !is_ip_literal("10.example.com"));
        // The built-in gateway is a name, not a number or this machine.
        let builtin = Url::parse(DEFAULT_GATEWAY).unwrap();
        assert!(builtin.secure && !builtin.is_loopback() && !is_ip_literal(&builtin.host));
    }
}
