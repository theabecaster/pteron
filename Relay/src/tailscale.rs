//! What the regular Tailscale client says about this computer: whether it is on a tailnet,
//! its addresses there and its name. A port share listens on one of those addresses (share.rs).
//!
//! It is read by running the client's own command line, `tailscale status --json
//! --peers=false`, as this user: no rights beyond the user's, nothing changed, no other
//! device listed. Only this computer's own entry is read (`Self`), the state of the client
//! (`BackendState`) and whether the tailnet gives names (`CurrentTailnet.MagicDNSEnabled`).
//! It runs when a phone asks for a share, never on a timer.
//!
//! Before a share is made for a phone's address, the client is also asked whose device that
//! address is (`tailscale whois --json <address>`): a share is only for a device of the same
//! tailnet user as this computer. A tagged device has no user, on either side, and gets none.
//! Both commands have 5 s and may print 256 KB; past either, there is no answer.
//!
//! The command line is looked for at fixed full paths (`platform::TAILSCALE`), in order,
//! and the first that is a program of root's or this user's is run. No `PATH` is searched.
//!
//! A computer where the command is missing, does not answer, or says anything but `Running`
//! has no tailnet as far as Beacon goes: no address is guessed from the network interfaces,
//! since an address in Tailscale's range on another network is not a tailnet.

use crate::util::Json;
use serde_json::Value;
use std::net::IpAddr;
use std::path::Path;
use std::time::Duration;

/// How long a command may take, and how much it may print.
pub const WAIT: Duration = Duration::from_secs(5);
const PRINT_LIMIT: usize = 256 * 1024;

/// True for an address Tailscale gives a device: `100.64.0.0/10` or `fd7a:115c:a1e0::/48`.
pub fn is_tailnet(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => ip.octets()[0] == 100 && ip.octets()[1] & 0xC0 == 64,
        IpAddr::V6(ip) => ip.segments()[..3] == [0xfd7a, 0x115c, 0xa1e0],
    }
}

/// This computer on its tailnet.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Tailnet {
    /// Its full name there (`desk.example.ts.net`), when the tailnet gives its devices names
    /// (MagicDNS), so that the phone can find it by name.
    pub name: Option<String>,
    /// What the computer is called, for a person to read.
    pub machine: String,
    /// Its own addresses there. Never empty.
    pub ips: Vec<IpAddr>,
    /// The tailnet user it belongs to. None for a tagged device, which belongs to no one.
    pub user: Option<u64>,
}

/// True when a device's entry lists tags.
fn tagged(device: &Value) -> bool {
    device.get("Tags").and_then(Value::as_array).is_some_and(|tags| !tags.is_empty())
}

/// A device's full name, in lowercase without the dot at its end: two or more labels of
/// letters, digits and hyphens.
fn dns_name(text: &str) -> Option<String> {
    let name = text.trim().trim_end_matches('.').to_ascii_lowercase();
    let label = |l: &str| !l.is_empty() && l.len() <= 63 && !l.starts_with('-') && !l.ends_with('-') && l.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-');
    (name.len() <= 253 && name.split('.').count() >= 2 && name.split('.').all(label)).then_some(name)
}

/// Reads what `tailscale status --json` printed. None unless the client is running with an
/// address of its own.
pub fn parse(json: &str) -> Option<Tailnet> {
    let status: Value = serde_json::from_str(json).ok()?;
    if status.str("BackendState") != Some("Running") {
        return None;
    }
    let me = status.obj("Self")?;
    let ips: Vec<IpAddr> = me.get("TailscaleIPs")?.as_array()?.iter().filter_map(|ip| ip.as_str()?.parse().ok()).filter(|ip| is_tailnet(*ip)).collect();
    if ips.is_empty() {
        return None;
    }
    let full = me.str("DNSName").and_then(dns_name);
    let named = status.obj("CurrentTailnet").and_then(|t| t.bool("MagicDNSEnabled")) == Some(true);
    let machine = me.text("HostName").or_else(|| full.as_ref().and_then(|n| n.split('.').next().map(String::from))).unwrap_or_default();
    let user = me.get("UserID").and_then(Value::as_u64).filter(|id| *id != 0 && !tagged(me));
    Some(Tailnet { name: full.filter(|_| named), machine, ips, user })
}

/// The user a device belongs to, in what `tailscale whois --json` printed about its
/// address. None when it names no device, the device is tagged, or the device's entry and
/// the user's profile do not name the same user.
pub fn whois_user(json: &str) -> Option<u64> {
    let answer: Value = serde_json::from_str(json).ok()?;
    let node = answer.obj("Node")?;
    let user = node.get("User").and_then(Value::as_u64).filter(|id| *id != 0)?;
    let profile = answer.obj("UserProfile")?.get("ID").and_then(Value::as_u64)?;
    (user == profile && !tagged(node)).then_some(user)
}

/// The first of `places` that is a full path and that `usable` takes.
pub fn find<'a>(places: &[&'a str], usable: impl Fn(&Path) -> bool) -> Option<&'a Path> {
    places.iter().map(|place| Path::new(*place)).find(|p| p.is_absolute() && usable(p))
}

/// The Tailscale client's command line: the first of `places` that `usable` takes.
fn client_at(places: &[&str], usable: impl Fn(&Path) -> bool) -> Option<tokio::process::Command> {
    crate::tools::async_command(find(places, usable)?)
}

/// The Tailscale client's command line on this computer.
fn client() -> Option<tokio::process::Command> {
    let me = crate::platform::user_id();
    client_at(&crate::platform::TAILSCALE, |p| crate::platform::is_own_program(p, me))
}

/// What `client` says of this computer when asked for at most `wait`. None without a
/// client (then nothing is started), without an answer in time, and when it is not running
/// with an address.
async fn status(client: Option<tokio::process::Command>, wait: Duration) -> Option<Tailnet> {
    let mut command = client?;
    command.args(["status", "--json", "--peers=false"]);
    parse(std::str::from_utf8(&crate::tools::printed(command, PRINT_LIMIT, wait).await?).ok()?)
}

/// Asks the Tailscale client whose device `ip` is. None when there is no client to ask or
/// it gave no answer in time: then nothing is known. `Some(None)` when it answered and the
/// address is no device with a user (it does not know the address, or the device is tagged).
#[cfg_attr(test, allow(dead_code))] // tests never ask the real client
pub async fn whois(ip: IpAddr) -> Option<Option<u64>> {
    let mut command = client()?;
    command.args(["whois", "--json", &ip.to_string()]);
    let printed = crate::tools::printed(command, PRINT_LIMIT, WAIT).await?;
    Some(std::str::from_utf8(&printed).ok().and_then(whois_user))
}

/// Asks the Tailscale client now, for at most `wait` (never more than `WAIT`). None when
/// this computer does not run it.
#[cfg_attr(test, allow(dead_code))] // tests never ask the real client
pub async fn read(wait: Duration) -> Option<Tailnet> {
    status(client(), wait.min(WAIT)).await
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    /// What the client prints, cut to what is read, with example names and addresses.
    fn status() -> Value {
        json!({
            "Version": "1.90.0", "TUN": true, "BackendState": "Running",
            "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"],
            "Self": {"HostName": "Desk", "DNSName": "desk.example.ts.net.", "OS": "macOS", "UserID": 1001, "TailscaleIPs": ["100.64.0.1", "fd7a:115c:a1e0::1"], "Online": true},
            "MagicDNSSuffix": "example.ts.net",
            "CurrentTailnet": {"Name": "example", "MagicDNSSuffix": "example.ts.net", "MagicDNSEnabled": true},
            "Peer": null
        })
    }

    fn v4() -> IpAddr {
        "100.64.0.1".parse().unwrap()
    }

    #[test]
    fn tailscales_ranges_are_told_from_every_other_address() {
        for yes in ["100.64.0.0", "100.64.0.1", "100.100.100.100", "100.127.255.255", "fd7a:115c:a1e0::1", "fd7a:115c:a1e0:1:2:3:4:5"] {
            assert!(is_tailnet(yes.parse().unwrap()), "{yes}");
        }
        for no in ["100.63.255.255", "100.128.0.0", "10.0.0.1", "192.168.1.5", "127.0.0.1", "101.64.0.1", "0.0.0.0", "::1", "fd7a:115c:a1e1::1", "fd00::1", "fe80::1", "::ffff:100.64.0.1"] {
            assert!(!is_tailnet(no.parse().unwrap()), "{no}");
        }
    }

    #[test]
    fn a_running_client_gives_the_name_and_both_addresses() {
        let t = parse(&status().to_string()).unwrap();
        assert_eq!(t, Tailnet { name: Some("desk.example.ts.net".into()), machine: "Desk".into(), ips: vec![v4(), "fd7a:115c:a1e0::1".parse().unwrap()], user: Some(1001) });
        // A tagged computer belongs to no user, whatever id stands there.
        let mut s = status();
        s["Self"]["Tags"] = json!(["tag:server"]);
        assert_eq!(parse(&s.to_string()).unwrap().user, None);
        for none in [json!(0), Value::Null, json!("1001"), json!(-4)] {
            let mut s = status();
            s["Self"]["UserID"] = none.clone();
            assert_eq!(parse(&s.to_string()).unwrap().user, None, "{none}");
        }
    }

    /// What the client prints about an address: its keys as a real client has them, with
    /// example values. The ids are whole numbers; `Tags` is there only for a tagged device.
    fn whois_answer(user: u64, profile: u64, tags: Option<Value>) -> Value {
        let mut answer = json!({
            "Node": {"ID": 5550001, "StableID": "nEXAMPLE1CNTRL", "Name": "phone.example.ts.net.", "User": user, "Key": "nodekey:0000", "KeyExpiry": "2027-01-01T00:00:00Z",
                "Machine": "mkey:0000", "DiscoKey": "discokey:0000", "Addresses": ["100.64.0.2/32", "fd7a:115c:a1e0::2/128"], "AllowedIPs": ["100.64.0.2/32", "fd7a:115c:a1e0::2/128"],
                "Hostinfo": {"OS": "iOS", "Hostname": "phone"}, "Created": "2026-01-01T00:00:00Z", "Cap": 100, "Online": true, "ComputedName": "phone", "ComputedNameWithHost": "phone"},
            "UserProfile": {"ID": profile, "LoginName": "alex@example.com", "DisplayName": "Alex", "ProfilePicURL": "https://example.com/a.png"},
            "CapMap": null
        });
        if let Some(tags) = tags {
            answer["Node"]["Tags"] = tags;
        }
        answer
    }

    #[test]
    fn an_address_belongs_to_the_user_the_client_names_for_it() {
        // The phone of the same user as this computer (1001 above).
        assert_eq!(whois_user(&whois_answer(1001, 1001, None).to_string()), Some(1001));
        // No `Tags` key, `Tags: null` and an empty list all mean untagged.
        assert_eq!(whois_user(&whois_answer(1001, 1001, Some(json!([]))).to_string()), Some(1001));
        assert_eq!(whois_user(&whois_answer(1001, 1001, Some(Value::Null)).to_string()), Some(1001));
        assert!(whois_answer(1001, 1001, None)["Node"].get("Tags").is_none());
        // Ids are whole numbers of any size, read exactly: two that a floating-point number
        // could not tell apart are two users.
        let (huge, next) = (9_007_199_254_740_993u64, 9_007_199_254_740_992u64);
        assert_eq!(whois_user(&whois_answer(huge, huge, None).to_string()), Some(huge));
        assert_eq!(whois_user(&whois_answer(u64::MAX, u64::MAX, None).to_string()), Some(u64::MAX));
        assert_eq!(whois_user(&whois_answer(huge, next, None).to_string()), None);
        assert!(!crate::share::same_user(Some(huge), Some(next)));
        let text = format!("{{\"Node\":{{\"User\":{huge}}},\"UserProfile\":{{\"ID\":{huge}}},\"CapMap\":null,\"Unknown\":[1,2]}}");
        assert_eq!(whois_user(&text), Some(huge));
        let mut s = status();
        s["Self"]["UserID"] = json!(huge);
        assert_eq!(parse(&s.to_string()).unwrap().user, Some(huge));
        // An id written as anything but a whole number is none: a string, a fraction.
        for not_whole in ["\"1001\"", "1001.0", "1.001e3", "-1001", "true", "null"] {
            let text = format!("{{\"Node\":{{\"User\":{not_whole}}},\"UserProfile\":{{\"ID\":{not_whole}}}}}");
            assert_eq!(whois_user(&text), None, "{not_whole}");
        }
        // Another user's device: a user, but not this computer's.
        assert_eq!(whois_user(&whois_answer(2002, 2002, None).to_string()), Some(2002));
        // A tagged device has no user.
        assert_eq!(whois_user(&whois_answer(1001, 1001, Some(json!(["tag:ci"]))).to_string()), None);
        // The two places that name the user disagree, or one is missing.
        assert_eq!(whois_user(&whois_answer(1001, 2002, None).to_string()), None);
        assert_eq!(whois_user(&whois_answer(0, 0, None).to_string()), None);
        // An address the client does not know: it prints an error and no JSON.
        for none in ["", "peer not found", "{}", "null", "{\"Node\":null,\"UserProfile\":null}", "{\"Node\":{\"User\":1001}}", "{\"UserProfile\":{\"ID\":1001}}", "{\"Node\":{\"User\":\"1001\"},\"UserProfile\":{\"ID\":\"1001\"}}"] {
            assert_eq!(whois_user(none), None, "{none:?}");
        }
    }

    #[test]
    fn the_same_user_is_this_computers_own_and_no_one_elses() {
        let me = parse(&status().to_string()).unwrap();
        let same = |answer: Value| crate::share::same_user(me.user, whois_user(&answer.to_string()));
        assert!(same(whois_answer(1001, 1001, None)));
        assert!(!same(whois_answer(2002, 2002, None)));
        assert!(!same(whois_answer(1001, 1001, Some(json!(["tag:ci"])))));
        // A computer that is tagged has no user for anyone to be the same as.
        assert!(!crate::share::same_user(None, Some(1001)) && !crate::share::same_user(None, None) && !crate::share::same_user(Some(1001), None));
    }

    #[test]
    fn without_names_on_the_tailnet_there_is_only_the_address() {
        for off in [json!(false), Value::Null] {
            let mut s = status();
            s["CurrentTailnet"]["MagicDNSEnabled"] = off;
            assert_eq!(parse(&s.to_string()).unwrap().name, None);
        }
        let mut s = status();
        s.as_object_mut().unwrap().remove("CurrentTailnet");
        assert_eq!(parse(&s.to_string()).unwrap().name, None);
        // A name that is none: the address is used, and the computer is still called something.
        for bad in ["", ".", "desk", "desk..ts.net", "-desk.example.ts.net", "desk.exa mple.ts.net", "desk.example.ts.net/x", "desk.example.ts.net:80", "<b>.example.ts.net"] {
            let mut s = status();
            s["Self"]["DNSName"] = json!(bad);
            let t = parse(&s.to_string()).unwrap();
            assert_eq!((t.name, t.machine.as_str()), (None, "Desk"), "{bad:?}");
        }
        // Without a host name the first part of the full name is the computer's name.
        let mut s = status();
        s["Self"].as_object_mut().unwrap().remove("HostName");
        assert_eq!(parse(&s.to_string()).unwrap().machine, "desk");
        assert_eq!(dns_name("Desk.Example.TS.net."), Some("desk.example.ts.net".into()));
    }

    #[test]
    fn a_client_that_is_not_running_or_has_no_address_is_no_tailnet() {
        for state in ["Stopped", "NeedsLogin", "NoState", "Starting", ""] {
            let mut s = status();
            s["BackendState"] = json!(state);
            assert_eq!(parse(&s.to_string()), None, "{state}");
        }
        // Addresses outside Tailscale's ranges are not taken, whatever lists them.
        for ips in [json!([]), json!(["192.168.1.5", "10.0.0.2", "::1"]), json!(["nonsense", 7]), json!("100.64.0.1"), Value::Null] {
            let mut s = status();
            s["Self"]["TailscaleIPs"] = ips.clone();
            assert_eq!(parse(&s.to_string()), None, "{ips}");
        }
        let mut s = status();
        s["Self"]["TailscaleIPs"] = json!(["192.168.1.5", "100.64.0.1"]);
        assert_eq!(parse(&s.to_string()).unwrap().ips, vec![v4()]);
        for none in ["", "{}", "[]", "not json", "{\"BackendState\":\"Running\"}", "{\"BackendState\":\"Running\",\"Self\":null}"] {
            assert_eq!(parse(none), None, "{none:?}");
        }
    }

    /// A stand-in for the client in a folder of its own: it notes each run in `runs` and
    /// prints `answer`.
    #[cfg(unix)]
    fn stand_in(dir: &Path, answer: &Value) -> String {
        use std::os::unix::fs::PermissionsExt;
        std::fs::create_dir_all(dir).unwrap();
        std::fs::write(dir.join("answer"), answer.to_string()).unwrap();
        let program = dir.join("tailscale");
        std::fs::write(&program, format!("#!/bin/sh\necho \"$*\" >> '{0}/runs'\ncat '{0}/answer'\n", dir.display())).unwrap();
        std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o700)).unwrap();
        program.to_str().unwrap().to_string()
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn the_client_is_asked_only_where_there_is_one_and_says_whether_it_runs() {
        let dir = std::env::temp_dir().join(format!("pf-client-{}", std::process::id()));
        let runs = || std::fs::read_to_string(dir.join("runs")).unwrap_or_default();
        // Found and running with an address.
        let program = stand_in(&dir, &status());
        let places = ["/nowhere/tailscale", program.as_str()];
        let found = status_of(&places).await;
        assert_eq!(found.map(|t| t.machine), Some("Desk".into()));
        assert_eq!(runs(), "status --json --peers=false\n", "asked once, for itself alone");
        // Found, and not running or without an address: nothing.
        for state in ["Stopped", "NeedsLogin", "Starting"] {
            let mut s = status();
            s["BackendState"] = json!(state);
            stand_in(&dir, &s);
            assert_eq!(status_of(&places).await, None, "{state}");
        }
        let mut s = status();
        s["Self"]["TailscaleIPs"] = json!([]);
        stand_in(&dir, &s);
        assert_eq!(status_of(&places).await, None);
        // Not found: nothing, and nothing was started.
        stand_in(&dir, &status());
        let before = runs();
        assert_eq!(super::status(client_at(&["/nowhere/tailscale", "tailscale"], |p| p.is_file()), WAIT).await, None);
        assert_eq!(super::status(client_at(&places, |_| false), WAIT).await, None);
        assert_eq!(runs(), before);
        // One that does not answer in the time given: nothing.
        std::fs::write(&program, "#!/bin/sh\nsleep 30\n").unwrap();
        assert_eq!(super::status(client_at(&places, |p| p.is_file()), Duration::from_millis(200)).await, None);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(unix)]
    async fn status_of(places: &[&str]) -> Option<Tailnet> {
        super::status(client_at(places, |p| p.is_file()), WAIT).await
    }

    #[test]
    fn the_client_is_looked_for_at_fixed_full_paths_in_order() {
        let places = crate::platform::TAILSCALE;
        for place in places {
            assert!(place.starts_with('/') && !place.contains("..") && (place.ends_with("/tailscale") || place.ends_with("/Tailscale")), "{place}");
        }
        if cfg!(target_os = "macos") {
            assert_eq!(places.to_vec(), ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale"]);
        } else {
            assert_eq!(places.to_vec(), ["/usr/bin/tailscale", "/usr/sbin/tailscale", "/run/current-system/sw/bin/tailscale", "/usr/local/bin/tailscale"]);
        }
        // The first one that is usable is taken, whichever that is; none usable is none.
        let list = ["/a/tailscale", "/b/tailscale", "/c/tailscale"];
        assert_eq!(find(&list, |_| true), Some(Path::new("/a/tailscale")));
        assert_eq!(find(&list, |p| p != Path::new("/a/tailscale")), Some(Path::new("/b/tailscale")));
        assert_eq!(find(&list, |p| p == Path::new("/c/tailscale")), Some(Path::new("/c/tailscale")));
        assert_eq!(find(&list, |_| false), None);
        // A name without a folder would be looked up somewhere: it is never tried.
        assert_eq!(find(&["tailscale", "bin/tailscale", "./tailscale"], |_| true), None);
        assert_eq!(find(&["tailscale", "/d/tailscale"], |_| true), Some(Path::new("/d/tailscale")));
    }
}
