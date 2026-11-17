//! What `install` takes when Rex DUO's setup runs it on this computer:
//!
//! - `--server <addr>`: the Rex server the setup ran in, added to config.json's `servers` so
//!   the background helper watches it too.
//! - `--setup-nonce-file <path>`: a file holding the setup code, a value only that setup run
//!   and the phone that started it know. The code travels in a file and never as an argument.
//!   `install` reads the file, removes it, and keeps the code in the state folder for 30
//!   minutes. The running helper reads it there each time a phone sends a `setup_challenge`
//!   in `helper_identity`, and answers with a proof made from it. The phone then knows the
//!   helper it reached is the one its setup installed. A code makes up to three proofs for
//!   each requester and ten in all. It is removed when a requester that got one registers
//!   its phone with a `setup_seal`, which only the holder of the code can make.
//!
//! The code is never logged, never part of an error and never in status.json.

use crate::config::DISCOVER;
use crate::discovery::Endpoint;
use crate::identity::is_challenge;
use crate::util::base64;
use serde_json::{json, Value};
use std::path::Path;

/// The first line of what a setup proof covers.
const PROOF_DOMAIN: &str = "rexduo-setup-v1";
/// The first line of what a setup seal covers.
const SEAL_DOMAIN: &str = "rexduo-setup-register-v1";
const NONCE_FILE: &str = "setup_nonce.json";
const LOCK_FILE: &str = "setup_nonce.lock";
/// How long a stored code can still make a proof, in seconds.
pub const NONCE_LIFETIME: i64 = 30 * 60;
/// How many proofs one code makes for one requester identity: a setup asks once, and again
/// after a lost connection.
pub const MAX_PROOFS: usize = 3;
/// How many proofs one code makes for all requesters together.
pub const MAX_PROOFS_TOTAL: usize = 10;
/// The most a file given to `--setup-nonce-file` may hold: the code and a newline fit twice.
const MAX_NONCE_FILE: u64 = 128;
const USAGE: &str = "usage: rex-duo-helper install [--server unix:///path/server.sock | https://host] [--setup-nonce-file <path>]";

#[derive(Debug, Default, PartialEq)]
pub struct InstallOptions {
    pub server: Option<String>,
    /// The path given to `--setup-nonce-file`.
    pub nonce_file: Option<String>,
}

/// Reads `install`'s arguments. The error is the message to print; it never repeats a value.
pub fn parse_install(args: &[String]) -> Result<InstallOptions, String> {
    let mut o = InstallOptions::default();
    let mut it = args.iter();
    while let Some(a) = it.next() {
        let slot = match a.as_str() {
            "--server" => &mut o.server,
            "--setup-nonce-file" => &mut o.nonce_file,
            _ => return Err(format!("install takes no such option.\n{USAGE}")),
        };
        let Some(value) = it.next() else { return Err(format!("{a} needs a value.\n{USAGE}")) };
        if slot.replace(value.clone()).is_some() {
            return Err(format!("{a} was given twice.\n{USAGE}"));
        }
    }
    Ok(o)
}

/// 64 lowercase hex digits: 32 bytes.
pub fn is_nonce(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

// MARK: --server

/// The address to store for `--server`, when it is one `install` takes: the `unix://` address
/// of a socket that is there and belongs to the user `uid`, or an `https://` address.
pub fn check_server(addr: &str, uid: u32) -> Result<String, String> {
    use std::os::unix::fs::{FileTypeExt, MetadataExt};
    let addr = addr.trim();
    let refuse = |why: &str| Err(format!("--server: {why}. Nothing was changed."));
    if addr.is_empty() || addr.len() > 1024 || addr.chars().any(|c| c.is_control() || c.is_whitespace()) {
        return refuse("that is not an address");
    }
    let scheme = addr.split_once("://").map(|(s, _)| s.to_ascii_lowercase());
    match (scheme.as_deref(), Endpoint::parse(addr)) {
        (Some("unix"), Some(Endpoint::Unix(path))) => match std::fs::metadata(&path) {
            Err(_) => refuse("there is no socket at that path"),
            Ok(m) if !m.file_type().is_socket() => refuse("that path is not a socket"),
            Ok(m) if m.uid() != uid => refuse("that socket belongs to another user"),
            Ok(_) => Ok(addr.to_string()),
        },
        (Some("https"), Some(Endpoint::Url { .. })) if !addr.contains('@') => Ok(addr.to_string()),
        _ => refuse("it takes unix:///path/to/server.sock or https://host"),
    }
}

/// config.json with `addr` among its `servers`, or None when it needs no change: the address
/// is already listed, or discovery is on and finds that server anyway (`discovered`).
///
/// Everything else in the file stays. A list that was empty or missing meant "discover", so
/// the new list starts with that word and discovery stays on; a list that named servers keeps
/// them, and keeps discovery only if it had the word.
pub fn merge_server(config: Option<&str>, addr: &str, discovered: bool) -> Result<Option<String>, String> {
    let unusable = |what: &str| format!("config.json {what}, so it was left as it is.");
    let mut root: Value = match config.map(str::trim).filter(|c| !c.is_empty()) {
        None => json!({}),
        Some(text) => serde_json::from_str(text).map_err(|_| unusable("is not JSON"))?,
    };
    let Some(object) = root.as_object_mut() else { return Err(unusable("is not a JSON object")) };
    let mut servers: Vec<String> = match object.get("servers") {
        None | Some(Value::Null) => vec![],
        Some(Value::Array(list)) => {
            list.iter().map(|s| s.as_str().map(String::from)).collect::<Option<_>>().ok_or_else(|| unusable("has a server that is not text"))?
        }
        Some(_) => return Err(unusable("has servers that are not a list")),
    };
    let new = Endpoint::parse(addr);
    let listed = servers.iter().any(|s| s == addr || (new.is_some() && Endpoint::parse(s).is_some_and(|e| new.as_ref().is_some_and(|n| n.same(&e)))));
    let discovers = servers.is_empty() || servers.iter().any(|s| s == DISCOVER);
    if listed || (discovers && discovered) {
        return Ok(None);
    }
    if servers.is_empty() {
        servers.push(DISCOVER.to_string());
    }
    servers.push(addr.to_string());
    object.insert("servers".into(), json!(servers));
    let mut text = serde_json::to_string_pretty(&root).map_err(|e| e.to_string())?;
    text.push('\n');
    Ok(Some(text))
}

/// Adds `addr` to the config file. True when the file changed, which is when a running helper
/// has to start again to see it.
pub fn add_server(config: &Path, addr: &str) -> Result<bool, String> {
    let current = match std::fs::read_to_string(config) {
        Ok(text) => Some(text),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        Err(e) => return Err(format!("could not read config.json: {e}")),
    };
    // Discovery finds Rex's default socket without being told.
    let default = Endpoint::Unix(crate::discovery::default_socket());
    let discovered = Endpoint::parse(addr).is_some_and(|e| e.same(&default));
    match merge_server(current.as_deref(), addr, discovered)? {
        None => Ok(false),
        Some(text) => write_private(config, text.as_bytes()).map(|()| true).map_err(|e| format!("could not write config.json: {e}")),
    }
}

/// Writes through a temporary file that only this user can read from the moment it exists,
/// then renames it into place: a reader sees the old file or the whole new one.
fn write_private(path: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("json.tmp");
    let _ = std::fs::remove_file(&tmp);
    let mut f = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)?;
    f.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    f.write_all(data)?;
    f.sync_all()?;
    std::fs::rename(&tmp, path)
}

// MARK: --setup-nonce-file

/// The setup code in the file at `path`, which is removed whatever it held: after this the
/// code has one copy, the helper's own. The file has to be a regular file (not a link to
/// one) that belongs to the user `uid` and that no one else can open, of at most 128 bytes:
/// 64 lowercase hex digits, with or without one newline after them.
pub fn read_nonce_file(path: &Path, uid: u32) -> Result<String, String> {
    let code = nonce_in_file(path, uid);
    let _ = std::fs::remove_file(path);
    code.ok_or_else(|| {
        "--setup-nonce-file takes a file of yours that no one else can read, holding 64 lowercase hex digits. Nothing was installed.".to_string()
    })
}

fn nonce_in_file(path: &Path, uid: u32) -> Option<String> {
    use std::io::Read;
    use std::os::unix::fs::MetadataExt;
    let named = std::fs::symlink_metadata(path).ok().filter(|m| m.file_type().is_file())?;
    let file = std::fs::File::open(path).ok()?;
    // What was opened is the file that was looked at by name.
    let m = file.metadata().ok().filter(|m| m.dev() == named.dev() && m.ino() == named.ino())?;
    if !m.is_file() || m.uid() != uid || m.mode() & 0o077 != 0 || m.len() > MAX_NONCE_FILE {
        return None;
    }
    let mut data = Vec::new();
    file.take(MAX_NONCE_FILE + 1).read_to_end(&mut data).ok()?;
    if data.len() as u64 > MAX_NONCE_FILE {
        return None;
    }
    let text = String::from_utf8(data).ok()?;
    let code = text.strip_suffix('\n').unwrap_or(&text);
    is_nonce(code).then(|| code.to_string())
}

// MARK: The stored code

/// The code as the state folder holds it.
struct Record {
    nonce: String,
    expires_at: i64,
    /// The identity of each requester that was given a proof, in order.
    proofs: Vec<String>,
}

impl Record {
    fn parse(data: &[u8]) -> Option<Record> {
        let v: Value = serde_json::from_slice(data).ok()?;
        let proofs = match v.get("proofs") {
            None => vec![],
            Some(list) => list.as_array()?.iter().map(|p| p.as_str().map(String::from)).collect::<Option<_>>()?,
        };
        let nonce = v["nonce"].as_str().filter(|n| is_nonce(n))?.to_string();
        Some(Record { nonce, expires_at: v["expires_at"].as_i64()?, proofs })
    }

    fn write(&self, state_dir: &Path) -> std::io::Result<()> {
        let record = json!({"nonce": self.nonce, "expires_at": self.expires_at, "proofs": self.proofs});
        write_private(&state_dir.join(NONCE_FILE), record.to_string().as_bytes())
    }
}

/// Held while the code's file is read and written, by `install` and by the running helper:
/// each sees what the other wrote, whole, and neither writes over it.
fn lock(state_dir: &Path) -> std::io::Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    let file = std::fs::OpenOptions::new().create(true).truncate(false).write(true).mode(0o600).open(state_dir.join(LOCK_FILE))?;
    file.lock()?;
    Ok(file)
}

/// Keeps `nonce` in the state folder until `now + NONCE_LIFETIME` (seconds since 1970). A
/// code stored before is replaced, and the new one starts with no proofs made.
pub fn store_nonce(state_dir: &Path, nonce: &str, now: i64) -> Result<(), String> {
    if !is_nonce(nonce) {
        return Err("the setup code is not 64 lowercase hex digits".into());
    }
    let record = Record { nonce: nonce.to_string(), expires_at: now + NONCE_LIFETIME, proofs: vec![] };
    std::fs::create_dir_all(state_dir)
        .and_then(|()| lock(state_dir))
        .and_then(|_lock| record.write(state_dir))
        .map_err(|e| format!("could not keep the setup code: {e}"))
}

/// The code the state folder holds at `now`, read from its file on every call, so a code
/// that `install` stored a moment ago is there for a helper that was already running. It
/// comes with the lock, to hold until the caller is done with the file. A code past its 30
/// minutes, or a file that can't be read as one, is removed.
fn held(state_dir: &Path, now: i64) -> Option<(std::fs::File, Record)> {
    let path = state_dir.join(NONCE_FILE);
    // Most calls find no code, and they leave the folder as it is.
    std::fs::symlink_metadata(&path).ok()?;
    let lock = lock(state_dir).ok()?;
    let record = std::fs::read(&path).ok().and_then(|data| Record::parse(&data)).filter(|r| now < r.expires_at);
    if record.is_none() {
        let _ = std::fs::remove_file(&path);
    }
    record.map(|r| (lock, r))
}

fn unhex(s: &str) -> Option<Vec<u8>> {
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok()).collect()
}

/// The proof for one challenge: HMAC-SHA256, keyed by the 32 bytes of the nonce, over four
/// lines joined by `\n` with no newline at the end. Both client ids are in it, so a proof
/// answers only the client that asked, about the helper it asked.
pub fn proof(nonce: &str, setup_challenge: &str, helper_client: &str, requester_client: &str) -> Option<String> {
    if !is_nonce(nonce) || !is_challenge(setup_challenge) {
        return None;
    }
    let one_line = |s: &str| !s.is_empty() && !s.chars().any(char::is_control);
    if !one_line(helper_client) || !one_line(requester_client) {
        return None;
    }
    let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, &unhex(nonce)?);
    let message = [PROOF_DOMAIN, setup_challenge, helper_client, requester_client].join("\n");
    Some(base64(ring::hmac::sign(&key, message.as_bytes()).as_ref()))
}

/// Makes a proof from the stored code, at `now`, for the requester the Rex server identified
/// as `identity`. A code makes `MAX_PROOFS` of them for one identity and `MAX_PROOFS_TOTAL`
/// for all. The requester's identity is written beside the code before the proof is handed
/// out, so the counts hold across a restart and `registered` knows whose registration can
/// end the setup. None when there is no code to use.
pub fn take_proof(state_dir: &Path, setup_challenge: &str, helper_client: &str, requester_client: &str, identity: &str, now: i64) -> Option<String> {
    if !is_challenge(setup_challenge) || identity.is_empty() {
        return None;
    }
    let (_lock, mut record) = held(state_dir, now)?;
    if record.proofs.len() >= MAX_PROOFS_TOTAL || record.proofs.iter().filter(|p| *p == identity).count() >= MAX_PROOFS {
        return None;
    }
    let made = proof(&record.nonce, setup_challenge, helper_client, requester_client)?;
    record.proofs.push(identity.to_string());
    record.write(state_dir).ok()?;
    Some(made)
}

/// What a setup seal covers: three lines joined by `\n` with no newline at the end.
fn seal_message(push_secret: &str, device_id: &str) -> String {
    [SEAL_DOMAIN, push_secret, device_id].join("\n")
}

/// The seal a phone sends with the registration that completes its setup: HMAC-SHA256, keyed
/// by the 32 bytes of the nonce, over the secret and the device id it registers.
#[cfg(test)]
pub fn seal(nonce: &str, push_secret: &str, device_id: &str) -> Option<String> {
    let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, &unhex(nonce).filter(|_| is_nonce(nonce))?);
    Some(base64(ring::hmac::sign(&key, seal_message(push_secret, device_id).as_bytes()).as_ref()))
}

/// Called when `identity` has registered the phone `device_id` with `push_secret`, and sent
/// `seal` with it. The setup the code was for is complete, and the code is removed, when
/// that requester was given a proof and the seal is the one the code makes for this
/// registration. Any other registration leaves the code as it is. True when it was removed.
pub fn registered(state_dir: &Path, identity: &str, push_secret: &str, device_id: &str, seal: Option<&str>, now: i64) -> bool {
    let Some(tag) = seal.and_then(crate::util::base64_decode) else { return false };
    let Some((_lock, record)) = held(state_dir, now) else { return false };
    let Some(key) = unhex(&record.nonce).map(|k| ring::hmac::Key::new(ring::hmac::HMAC_SHA256, &k)) else { return false };
    record.proofs.iter().any(|p| p == identity)
        && ring::hmac::verify(&key, seal_message(push_secret, device_id).as_bytes(), &tag).is_ok()
        && std::fs::remove_file(state_dir.join(NONCE_FILE)).is_ok()
}

/// Removes a stored code that is past its 30 minutes. The running helper calls this every
/// minute, so the code is gone on time whether or not anyone asks for a proof.
pub fn sweep(state_dir: &Path, now: i64) {
    let _ = held(state_dir, now);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    const NONCE: &str = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";
    const CHALLENGE: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
    const PROOF: &str = "4Cn9RKo/LEB9ftm6bCl+5ddooucq97kzOtl8tIHNkvo=";

    /// A short path: a Unix socket's path has to fit in about 100 bytes.
    fn temp(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("su-{tag}-{}-{}", std::process::id(), crate::util::now() as u64 % 100_000));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn args(words: &[&str]) -> Vec<String> {
        words.iter().map(|w| w.to_string()).collect()
    }

    #[test]
    fn install_takes_a_server_and_the_path_of_a_code_file() {
        assert_eq!(parse_install(&[]).unwrap(), InstallOptions::default());
        let o = parse_install(&args(&["--setup-nonce-file", "/run/user/1000/stage/code", "--server", "https://rex.example.ts.net"])).unwrap();
        assert_eq!((o.server.as_deref(), o.nonce_file.as_deref()), (Some("https://rex.example.ts.net"), Some("/run/user/1000/stage/code")));
        for bad in [
            &["--server"][..],
            &["--setup-nonce-file"],
            &["--force"],
            &["extra"],
            &["--server", "https://a.example", "--server", "https://b.example"],
            &["--setup-nonce-file", "/a", "--setup-nonce-file", "/b"],
            // The code itself is not an option's value.
            &["--setup-nonce", NONCE],
            &[NONCE],
        ] {
            let e = parse_install(&args(bad)).unwrap_err();
            // The message says what is wrong without repeating what was typed.
            assert!(!e.contains(&NONCE[..16]), "{e}");
        }
    }

    /// A file with these bytes and this mode, as the setup script leaves one.
    fn code_file(path: &Path, content: &[u8], mode: u32) {
        use std::os::unix::fs::PermissionsExt;
        std::fs::write(path, content).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
    }

    #[test]
    fn the_code_is_read_from_a_private_file_which_is_then_removed() {
        let dir = temp("file");
        let uid = crate::tools::uid();
        let file = dir.join("code");
        // With one newline after it, or none.
        for content in [format!("{NONCE}\n"), NONCE.to_string()] {
            code_file(&file, content.as_bytes(), 0o600);
            assert_eq!(read_nonce_file(&file, uid).as_deref(), Ok(NONCE));
            assert!(!file.exists());
        }
        code_file(&file, NONCE.as_bytes(), 0o400);
        assert_eq!(read_nonce_file(&file, uid).as_deref(), Ok(NONCE));

        let refused = |file: &Path, uid: u32, why: &str| {
            let e = read_nonce_file(file, uid).unwrap_err();
            assert!(e.starts_with("--setup-nonce-file takes ") && e.ends_with("Nothing was installed."), "{why}: {e}");
            assert!(!e.contains(&NONCE[..16]), "{why}: {e}");
            assert!(std::fs::symlink_metadata(file).is_err(), "{why}: the file is still there");
        };
        // A file that the group or anyone else can open.
        for mode in [0o640, 0o604, 0o660, 0o644, 0o610, 0o601] {
            code_file(&file, NONCE.as_bytes(), mode);
            refused(&file, uid, &format!("mode {mode:o}"));
        }
        // A file of another user.
        code_file(&file, NONCE.as_bytes(), 0o600);
        refused(&file, uid + 1, "owner");
        // More than 128 bytes, even when it starts with a code.
        code_file(&file, format!("{NONCE}\n{}", " ".repeat(64)).as_bytes(), 0o600);
        refused(&file, uid, "size");
        let upper = NONCE.to_uppercase();
        for content in [
            "".to_string(),
            "\n".to_string(),
            "abc\n".to_string(),
            NONCE[..63].to_string(),
            format!("{NONCE}0"),
            upper,
            format!("g{}", &NONCE[1..]),
            format!("{NONCE}\n\n"),
            format!("{NONCE}\r\n"),
            format!(" {NONCE}"),
            format!("{NONCE} "),
            format!("{NONCE}\n{NONCE}"),
        ] {
            code_file(&file, content.as_bytes(), 0o600);
            refused(&file, uid, &format!("{} bytes", content.len()));
        }
        code_file(&file, &[0xff; 64], 0o600);
        refused(&file, uid, "not text");

        // A link is refused and removed; the file it points to stays.
        let target = dir.join("target");
        code_file(&target, NONCE.as_bytes(), 0o600);
        std::os::unix::fs::symlink(&target, &file).unwrap();
        refused(&file, uid, "link");
        assert_eq!(std::fs::read_to_string(&target).unwrap(), NONCE);
        // No file, and a folder.
        assert!(read_nonce_file(&dir.join("missing"), uid).is_err());
        assert!(read_nonce_file(&dir, uid).is_err());
        assert!(dir.is_dir());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_server_is_a_socket_of_this_user_or_an_https_address() {
        use std::os::unix::fs::MetadataExt;
        let dir = temp("srv");
        let sock = dir.join("server.sock");
        let _listener = std::os::unix::net::UnixListener::bind(&sock).unwrap();
        let uid = std::fs::metadata(&sock).unwrap().uid();
        assert_eq!(uid, crate::tools::uid());
        let addr = format!("unix://{}", sock.display());
        assert_eq!(check_server(&addr, uid).as_deref(), Ok(addr.as_str()));
        assert_eq!(check_server(&format!(" {addr}\n"), uid).as_deref(), Ok(addr.as_str()));
        assert_eq!(check_server("https://rex-box.example.ts.net", uid).as_deref(), Ok("https://rex-box.example.ts.net"));
        assert_eq!(check_server("HTTPS://rex-box.example.ts.net:8443/", uid).as_deref(), Ok("HTTPS://rex-box.example.ts.net:8443/"));

        let file = dir.join("plain");
        std::fs::write(&file, "").unwrap();
        for bad in [
            // The socket of someone else is checked below; these are not sockets or not there.
            format!("unix://{}", file.display()),
            format!("unix://{}", dir.display()),
            format!("unix://{}", dir.join("missing.sock").display()),
            "unix://".into(),
            "unix://relative/server.sock".into(),
            sock.display().to_string(),
            "http://rex-box.example.ts.net".into(),
            "ws://rex-box.example.ts.net".into(),
            "wss://rex-box.example.ts.net".into(),
            "https://".into(),
            "https://user@rex-box.example.ts.net".into(),
            "https://rex box.example.ts.net".into(),
            "https://rex-box.example.ts.net\r\nx".into(),
            "file:///etc/hosts".into(),
            "rex-box.example.ts.net".into(),
            String::new(),
            format!("https://{}", "a".repeat(1100)),
        ] {
            let e = check_server(&bad, uid).unwrap_err();
            assert!(e.starts_with("--server: ") && e.ends_with("Nothing was changed."), "{bad:?}: {e}");
        }
        assert_eq!(check_server(&addr, uid + 1).unwrap_err(), "--server: that socket belongs to another user. Nothing was changed.");
        std::fs::remove_dir_all(dir).unwrap();
    }

    fn servers(text: &str) -> Vec<String> {
        let v: Value = serde_json::from_str(text).unwrap();
        v["servers"].as_array().unwrap().iter().map(|s| s.as_str().unwrap().to_string()).collect()
    }

    #[test]
    fn a_server_is_added_once_and_discovery_stays() {
        let addr = "unix:///run/user/1000/rex-b/server.sock";
        // No config, or one without servers: discovery was on, and stays on.
        for none in [None, Some(""), Some("{}"), Some(r#"{"servers": []}"#), Some(r#"{"servers": null}"#)] {
            assert_eq!(servers(&merge_server(none, addr, false).unwrap().unwrap()), ["discover", addr], "{none:?}");
            // The server discovery finds anyway needs no entry.
            assert_eq!(merge_server(none, addr, true).unwrap(), None, "{none:?}");
        }
        // Everything else in the file is kept.
        let full = r#"{"label": "relay", "auto_update": false, "gateways": ["https://push.example.com"], "apns": {"key_id": "OLD"}}"#;
        let merged: Value = serde_json::from_str(&merge_server(Some(full), addr, false).unwrap().unwrap()).unwrap();
        let mut expected: Value = serde_json::from_str(full).unwrap();
        expected["servers"] = json!(["discover", addr]);
        assert_eq!(merged, expected);

        // A list that names servers keeps them, in order, and gets the new one at the end.
        let fixed = r#"{"servers": ["https://rex-a.example.ts.net"]}"#;
        let once = merge_server(Some(fixed), addr, false).unwrap().unwrap();
        assert_eq!(servers(&once), ["https://rex-a.example.ts.net", addr]);
        // Discovery was off there, so even the default socket is written down.
        assert_eq!(servers(&merge_server(Some(fixed), addr, true).unwrap().unwrap()), ["https://rex-a.example.ts.net", addr]);
        // A second time changes nothing, however the address is spelled.
        assert_eq!(merge_server(Some(&once), addr, false).unwrap(), None);
        assert_eq!(merge_server(Some(fixed), "https://REX-A.example.ts.net:443/", false).unwrap(), None);
        assert_eq!(merge_server(Some(&once), "unix:///run/user/1000/rex%2Db/server.sock", false).unwrap(), None);
        let with_word = r#"{"servers": ["discover", "https://rex-a.example.ts.net"]}"#;
        assert_eq!(servers(&merge_server(Some(with_word), addr, false).unwrap().unwrap()), ["discover", "https://rex-a.example.ts.net", addr]);
        assert_eq!(merge_server(Some(with_word), addr, true).unwrap(), None);

        // A file that can't be understood is not written over.
        for broken in ["[]", "\"x\"", "{", r#"{"servers": "unix:///x"}"#, r#"{"servers": [1]}"#] {
            assert!(merge_server(Some(broken), addr, false).unwrap_err().contains("left as it is"), "{broken}");
        }
    }

    #[test]
    fn the_config_file_is_changed_only_when_it_has_to_be() {
        let dir = temp("cfg");
        let config = dir.join("state/config.json");
        let addr = "https://rex-box.example.ts.net";
        assert_eq!(add_server(&config, addr), Ok(true));
        assert_eq!(servers(&std::fs::read_to_string(&config).unwrap()), ["discover", addr]);
        let watch = crate::config::Config::load(&config).unwrap().watch();
        assert_eq!(watch, [None, Endpoint::parse(addr)]);
        let before = std::fs::metadata(&config).unwrap().modified().unwrap();
        assert_eq!(add_server(&config, addr), Ok(false));
        assert_eq!(std::fs::metadata(&config).unwrap().modified().unwrap(), before);
        assert!(!config.with_extension("json.tmp").exists());

        std::fs::write(&config, "not json").unwrap();
        assert!(add_server(&config, addr).is_err());
        assert_eq!(std::fs::read_to_string(&config).unwrap(), "not json");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_proof_matches_the_shared_vector() {
        assert_eq!(proof(NONCE, CHALLENGE, "client:helper", "client:phone").as_deref(), Some(PROOF));
        // Another challenge, helper or requester is another proof.
        let other = crate::util::base64url(&[9; 32]);
        for (c, h, r) in [(other.as_str(), "client:helper", "client:phone"), (CHALLENGE, "client:other", "client:phone"), (CHALLENGE, "client:helper", "client:other")] {
            let p = proof(NONCE, c, h, r).unwrap();
            assert_ne!(p, PROOF);
            assert_eq!(crate::util::base64_decode(&p).unwrap().len(), 32);
        }
        assert_eq!(proof(NONCE, "AAAA", "client:helper", "client:phone"), None);
        assert_eq!(proof(&NONCE[..62], CHALLENGE, "client:helper", "client:phone"), None);
        assert_eq!(proof(NONCE, CHALLENGE, "client:helper\nx", "client:phone"), None);
        assert_eq!(proof(NONCE, CHALLENGE, "client:helper", ""), None);
    }

    const ALEX: &str = "tailscale:12345";
    const SAM: &str = "tailscale:777";

    const SECRET: &str = "S3cr3tS3cr3tS3cr3tS3cr3tS3cr3tS3cr3tS3cr3t0";
    const DEVICE: &str = "a1b2c3d4";
    const SEAL: &str = "uFBNieeZhse8TXl8fRQiixoD7UCeYMg3k+hrGw9CICM=";

    #[test]
    fn a_code_is_kept_private_and_makes_three_proofs_for_each_requester() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temp("nonce");
        let state = dir.join("state");
        let file = state.join(NONCE_FILE);
        let take = |now: i64| take_proof(&state, CHALLENGE, "client:helper", "client:phone", ALEX, now);
        // No code: no proof, and nothing appears.
        assert_eq!(take(1000), None);
        sweep(&state, 1000);
        assert!(!registered(&state, ALEX, SECRET, DEVICE, Some(SEAL), 1000));
        assert!(!state.exists());

        store_nonce(&state, NONCE, 1000).unwrap();
        assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(std::fs::metadata(state.join(LOCK_FILE)).unwrap().permissions().mode() & 0o777, 0o600);
        assert!(!file.with_extension("json.tmp").exists());
        let record = || serde_json::from_slice::<Value>(&std::fs::read(&file).unwrap()).unwrap();
        assert_eq!(record(), json!({"nonce": NONCE, "expires_at": 1000 + 30 * 60, "proofs": []}));
        // A challenge that is not one, or a requester without an identity, uses nothing up.
        assert_eq!(take_proof(&state, "AAAA", "client:helper", "client:phone", ALEX, 1001), None);
        assert_eq!(take_proof(&state, CHALLENGE, "client:helper", "client:phone", "", 1001), None);
        assert_eq!(record()["proofs"], json!([]));

        // Three proofs for one identity, the last in the code's last second.
        assert_eq!(take(1001).as_deref(), Some(PROOF));
        assert_eq!(take(1002).as_deref(), Some(PROOF));
        assert_eq!(take(1000 + NONCE_LIFETIME - 1).as_deref(), Some(PROOF));
        assert_eq!(record(), json!({"nonce": NONCE, "expires_at": 1000 + 30 * 60, "proofs": [ALEX, ALEX, ALEX]}));
        assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
        // There is no fourth for that identity, from any of its clients.
        assert_eq!(take(1003), None);
        assert_eq!(take_proof(&state, CHALLENGE, "client:helper", "client:tablet", ALEX, 1003), None);
        // Another identity still gets its own three, each made for the client that asked.
        let sams = |now: i64| take_proof(&state, CHALLENGE, "client:helper", "client:tablet", SAM, now);
        let other = sams(1004).unwrap();
        assert_ne!(other, PROOF);
        assert_eq!(sams(1005), Some(other.clone()));
        assert_eq!(sams(1006), Some(other));
        assert_eq!(sams(1007), None);
        assert_eq!(record()["proofs"], json!([ALEX, ALEX, ALEX, SAM, SAM, SAM]));

        // A newer install replaces the code and starts the counts and the 30 minutes again.
        store_nonce(&state, &"ab".repeat(32), 1000).unwrap();
        store_nonce(&state, NONCE, 5000).unwrap();
        assert_eq!(take(5000 + NONCE_LIFETIME - 1).as_deref(), Some(PROOF));
        // A file that can't be read as a code is removed.
        for junk in ["", "{}", r#"{"nonce": "zz", "expires_at": 9999999999}"#, r#"{"nonce": 1}"#] {
            std::fs::write(&file, junk).unwrap();
            assert_eq!(take(1000), None, "{junk}");
            assert!(!file.exists(), "{junk}");
        }
        std::fs::write(&file, json!({"nonce": NONCE, "expires_at": 9_999_999_999i64, "proofs": "x"}).to_string()).unwrap();
        assert_eq!(take(1000), None);
        assert!(!file.exists());
        assert!(store_nonce(&state, "abc", 1000).unwrap_err().contains("64"));
        assert!(!file.exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_code_makes_ten_proofs_in_all() {
        let dir = temp("total");
        store_nonce(&dir, NONCE, 1000).unwrap();
        let take = |identity: &str| take_proof(&dir, CHALLENGE, "client:helper", "client:phone", identity, 1001);
        // Three identities use their three each, and a fourth gets the tenth.
        for identity in ["tailscale:1", "tailscale:2", "tailscale:3"] {
            for _ in 0..MAX_PROOFS {
                assert!(take(identity).is_some(), "{identity}");
            }
            assert_eq!(take(identity), None, "{identity}");
        }
        assert!(take("tailscale:4").is_some());
        // The eleventh is not made, for an identity with proofs left or a new one.
        assert_eq!(take("tailscale:4"), None);
        assert_eq!(take("tailscale:5"), None);
        let record: Value = serde_json::from_slice(&std::fs::read(dir.join(NONCE_FILE)).unwrap()).unwrap();
        assert_eq!(record["proofs"].as_array().unwrap().len(), MAX_PROOFS_TOTAL);
        assert_eq!((MAX_PROOFS, MAX_PROOFS_TOTAL), (3, 10));
        // The count is in the file, so a helper that starts again continues it.
        assert_eq!(take_proof(&dir, CHALLENGE, "client:helper", "client:phone", "tailscale:5", 1002), None);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_seal_matches_the_shared_vector() {
        assert_eq!(seal(NONCE, SECRET, DEVICE).as_deref(), Some(SEAL));
        // Another code, secret or device id is another seal.
        for (n, s, d) in [("ab".repeat(32).as_str(), SECRET, DEVICE), (NONCE, "N3wS3cr3tN3wS3cr3tN3wS3cr3tN3wS3cr3tN3wS3c0", DEVICE), (NONCE, SECRET, "ffff0000")] {
            let other = seal(n, s, d).unwrap();
            assert_ne!(other, SEAL);
            assert_eq!(crate::util::base64_decode(&other).unwrap().len(), 32);
        }
        assert_eq!(seal(&NONCE[..62], SECRET, DEVICE), None);
    }

    #[test]
    fn a_code_is_removed_by_the_sealed_registration_of_a_requester_it_answered() {
        let dir = temp("used");
        let file = dir.join(NONCE_FILE);
        let sealed = |identity: &str, seal: Option<&str>, now: i64| registered(&dir, identity, SECRET, DEVICE, seal, now);
        store_nonce(&dir, NONCE, 1000).unwrap();
        // Nobody has a proof yet: a registration is not part of this setup, sealed or not.
        assert!(!sealed(ALEX, Some(SEAL), 1001));
        assert_eq!(take_proof(&dir, CHALLENGE, "client:helper", "client:phone", ALEX, 1002).as_deref(), Some(PROOF));
        // A sealed registration by an identity that got no proof leaves the code.
        assert!(!sealed(SAM, Some(SEAL), 1003));
        assert!(!sealed("", Some(SEAL), 1003));
        // So does one by the identity that got a proof, with no seal or another seal.
        let other_code = seal(&"ab".repeat(32), SECRET, DEVICE).unwrap();
        let short = &SEAL[..40];
        for wrong in [None, Some(""), Some("AAAA"), Some("not base64!"), Some(short), Some(other_code.as_str()), Some(PROOF)] {
            assert!(!sealed(ALEX, wrong, 1003), "{wrong:?}");
        }
        // The seal is for one secret and one device id.
        assert!(!registered(&dir, ALEX, "N3wS3cr3tN3wS3cr3tN3wS3cr3tN3wS3cr3tN3wS3c0", DEVICE, Some(SEAL), 1003));
        assert!(!registered(&dir, ALEX, SECRET, "ffff0000", Some(SEAL), 1003));
        assert!(file.exists());
        // The code still makes proofs until the sealed registration.
        assert!(take_proof(&dir, CHALLENGE, "client:helper", "client:phone", ALEX, 1003).is_some());
        assert!(sealed(ALEX, Some(SEAL), 1004));
        assert!(!file.exists());
        // With the code gone there are no more proofs, and nothing left to complete.
        assert_eq!(take_proof(&dir, CHALLENGE, "client:helper", "client:phone", ALEX, 1005), None);
        assert_eq!(take_proof(&dir, CHALLENGE, "client:helper", "client:tablet", SAM, 1005), None);
        assert!(!sealed(ALEX, Some(SEAL), 1005));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_code_is_removed_after_thirty_minutes() {
        let dir = temp("expiry");
        let file = dir.join(NONCE_FILE);
        let end = 1000 + NONCE_LIFETIME;
        // By the next request for a proof.
        store_nonce(&dir, NONCE, 1000).unwrap();
        assert_eq!(take_proof(&dir, CHALLENGE, "client:helper", "client:phone", ALEX, end), None);
        assert!(!file.exists());
        // By the next sealed registration, which does not count as the end of that setup.
        store_nonce(&dir, NONCE, 1000).unwrap();
        assert!(take_proof(&dir, CHALLENGE, "client:helper", "client:phone", ALEX, 1001).is_some());
        assert!(!registered(&dir, ALEX, SECRET, DEVICE, Some(SEAL), end));
        assert!(!file.exists());
        // And by the helper's own look every minute, with or without proofs made.
        store_nonce(&dir, NONCE, 1000).unwrap();
        sweep(&dir, end - 1);
        assert!(file.exists());
        sweep(&dir, end);
        assert!(!file.exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
