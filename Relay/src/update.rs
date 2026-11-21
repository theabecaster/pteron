//! The helper updates itself from the releases of its own repository.
//!
//! What to do is decided by pure functions, tested below: check the manifest's signature
//! against the trusted keys, read it, refuse one that expired or is older than one already
//! seen, compare versions, pick this platform's file, check every address, size, hash and
//! signature. What is done sits in small functions after them: download, the platform's own
//! check (macOS: code signature, team, notarization; Linux: an ed25519 signature that names
//! the version, the platform and the file's hash), swap, restart, confirm, roll back.
//!
//! Nothing downloaded runs before it has passed every check. The restart and the wait for the
//! new version are done by the *old* program (`finish-update`), started outside the service so
//! that restarting the service doesn't stop it.

use crate::config::default_state_dir;
use crate::devices::{read_json, write_json};
use crate::net::{Exchange, Url};
use crate::util::{base64, base64_decode, iso8601, now, now_iso, parse_iso8601, sha256_hex, Json};
use crate::brand::BEACON;
use crate::{gateway, info, service};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant, SystemTime};

pub const VERSION: &str = env!("CARGO_PKG_VERSION");

/// Every file of a release, and the manifest, lives under this address. Nothing else is fetched.
/// The repository is now `theabecaster/pteron`; this keeps its earlier name on purpose. GitHub
/// redirects it, every shipped Beacon and app asks for it, and every manifest lists its files
/// under it. Never create a repository named `rexduo` again: that would end the redirect.
pub const RELEASE_PREFIX: &str = "https://github.com/theabecaster/rexduo/releases/download/";
pub const MANIFEST_URL: &str = "https://github.com/theabecaster/rexduo/releases/download/helper-latest/manifest.json";
/// GitHub answers a release download with a redirect to its file servers. A redirect to any
/// other host is refused.
const DOWNLOAD_HOSTS: [&str; 3] = ["github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com"];
const MAX_REDIRECTS: usize = 5;
/// No release file is larger than this, whatever a manifest says.
pub const MAX_ASSET: u64 = 64 << 20;
const MAX_MANIFEST: usize = 64 << 10;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(20);
const DOWNLOAD_TIMEOUT: Duration = Duration::from_secs(15 * 60);
/// How long the new version has to show up in status.json before the old one is put back.
/// It counts from the moment the old helper is gone, not from the request to restart.
const CONFIRM_TIMEOUT: Duration = Duration::from_secs(20);
/// How long the old helper gets to stop after the service manager was asked to restart it.
const EXIT_TIMEOUT: Duration = Duration::from_secs(15);
/// A lock this old belongs to an update that died, whatever its pid says now.
const LOCK_MAX_AGE: Duration = Duration::from_secs(30 * 60);

/// The public halves of the keys that sign the manifest and the Linux binaries, one
/// `<label> <base64 of 32 bytes>` line each. The private halves never enter the repository.
const UPDATE_KEY_FILE: &str = include_str!("../update-key.pub");

/// The Mac app's folder, and the name an installed app waits under while its replacement starts.
pub const APP_NAME: &str = crate::brand::APP_FOLDER;
const PREVIOUS_APP: &str = crate::brand::PREVIOUS_FOLDER;
/// The same two under the app's earlier names, newest first. An app installed under one of
/// them is the installed app; it moves to the names above (src/rename.rs). Updaters that
/// shipped look for these folders, so a release keeps a zip for each (Relay/release.sh).
pub const EARLIER_APP_NAMES: [&str; 2] = ["Rex DUO Beacon.app", "Rex DUO Helper.app"];
pub const EARLIER_PREVIOUS_APPS: [&str; 2] = ["Rex DUO Beacon.previous.app", "Rex DUO Helper.previous.app"];

/// True for a folder name the Mac app may have, in a download or where it is installed: its
/// name or one of the earlier ones. The one list of them; Relay/setup.sh has the same.
pub fn allowed_app_name(name: &std::ffi::OsStr) -> bool {
    name == APP_NAME || EARLIER_APP_NAMES.iter().any(|earlier| name == *earlier)
}
pub(crate) const BUNDLE_ID: &str = "dev.abrahamgonzalez.rexduo.helper";
const TEAM_ID: &str = "R2PVQ496X7";
/// How the folder starts in which a new version that did not start waits to be deleted, beside
/// the app. The process id and `.app` follow. It names no product, so it stays as it is.
pub(crate) const FAILED_PREFIX: &str = ".beacon-failed-";
const LOCK_FILE: &str = "update.lock";
const RESULT_FILE: &str = "update_result.json";
/// How the last check from the command line ended, in the state folder, for the service.
const CHECK_FILE: &str = "update_check.json";
/// update_check.json is a few short fields. A larger file is not one.
const MAX_CHECK_FILE: u64 = 1024;
/// Keys received by handover, in the state folder.
const TRUSTED_KEYS_FILE: &str = "trusted_keys.json";
/// The highest manifest version accepted so far, in the state folder.
const HIGH_WATER_FILE: &str = "update_high_water.json";
/// What the release list last turned off (`Switches`).
const SWITCHES_FILE: &str = "switches.json";
/// The most handed-over keys kept. A fifth pushes out the oldest.
pub const HANDED_LIMIT: usize = 4;
/// The launchd job the old program runs as while it restarts the helper on a Mac.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))] // only a Mac loads the finisher through launchd
const FINISHER_LABEL: &str = "dev.abrahamgonzalez.rexduo.helper.update";
const FINISHER_PLIST: &str = "update-finisher.plist";

// MARK: Versions

/// `major.minor.patch`, digits only.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version(u64, u64, u64);

impl Version {
    pub fn parse(s: &str) -> Option<Version> {
        let mut parts = s.split('.').map(|p| {
            let plain = (1..=9).contains(&p.len()) && p.bytes().all(|b| b.is_ascii_digit()) && (p == "0" || !p.starts_with('0'));
            plain.then(|| p.parse::<u64>().ok()).flatten()
        });
        let v = Version(parts.next()??, parts.next()??, parts.next()??);
        parts.next().is_none().then_some(v)
    }
}

/// True only when `candidate` is a later version than `current`. A version that doesn't parse
/// is an error, never "newer".
pub fn is_newer(candidate: &str, current: &str) -> Result<bool, String> {
    let c = Version::parse(candidate).ok_or_else(|| format!("\"{}\" is not a version", clip(candidate)))?;
    let cur = Version::parse(current).ok_or_else(|| format!("\"{}\" is not a version", clip(current)))?;
    Ok(c > cur)
}

fn clip(s: &str) -> String {
    s.chars().filter(|c| !c.is_control()).take(40).collect()
}

// MARK: What went wrong, in words fit for anyone

/// Why an update or a check for one failed. The app and status.json only ever see one of
/// these sentences. The details (addresses, paths, what a tool or a server said) stay in the
/// helper's own log, because any Rex client may ask for the status.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Problem {
    NotSetUp,
    CannotUpdate,
    Unreachable,
    Rejected,
    Expired,
    Replayed,
    NoBuild,
    Download,
    Checks,
    Install,
    RolledBack,
    NotRestarted,
    Busy,
}

impl Problem {
    #[cfg(test)]
    pub const ALL: [Problem; 13] = [
        Problem::NotSetUp,
        Problem::CannotUpdate,
        Problem::Unreachable,
        Problem::Rejected,
        Problem::Expired,
        Problem::Replayed,
        Problem::NoBuild,
        Problem::Download,
        Problem::Checks,
        Problem::Install,
        Problem::RolledBack,
        Problem::NotRestarted,
        Problem::Busy,
    ];

    pub fn sentence(self) -> &'static str {
        match self {
            Problem::NotSetUp => "Updates are not set up in this build.",
            Problem::CannotUpdate => concat!("This copy of ", crate::beacon_name!(), " can't update itself."),
            Problem::Unreachable => "The release list could not be downloaded.",
            Problem::Rejected => "The release list was not accepted.",
            Problem::Expired => "The release list is out of date.",
            Problem::Replayed => concat!("The release list is older than one ", crate::beacon_name!(), " has already seen."),
            Problem::NoBuild => "The newest version has no build for this computer.",
            Problem::Download => "The update could not be downloaded.",
            Problem::Checks => "The downloaded update did not pass its checks.",
            Problem::Install => "The update could not be installed.",
            Problem::RolledBack => "The new version did not start, so the previous version was put back.",
            Problem::NotRestarted => concat!(crate::beacon_name!(), " could not restart into the new version, so the previous version was kept."),
            Problem::Busy => "Another update is running.",
        }
    }
}

/// A problem, with the details for the log and the terminal.
#[derive(Clone, Debug, PartialEq)]
pub struct Fault {
    pub problem: Problem,
    pub detail: String,
}

impl Fault {
    fn new(problem: Problem, detail: impl Into<String>) -> Fault {
        Fault { problem, detail: detail.into() }
    }
}

impl std::fmt::Display for Fault {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.detail)
    }
}

// MARK: Manifest

#[derive(Clone, Debug, PartialEq)]
pub struct Asset {
    pub url: String,
    /// Lowercase hex.
    pub sha256: String,
    pub size: u64,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Manifest {
    pub version: String,
    /// A helper older than this should be updated before anything else is expected of it.
    pub min_version: String,
    /// Seconds since 1970. From then on the manifest is refused.
    pub expires_at: i64,
    /// A key the publisher is moving to, for the helper to trust from now on.
    pub next_key: Option<[u8; 32]>,
    /// The features the publisher has turned off (`disabled`), by name. None when the list
    /// leaves the field out or holds anything there but a list of names: then the list says
    /// nothing about them.
    pub disabled: Option<Vec<String>>,
    /// When the list was signed (`signed_at`), seconds since 1970. release.sh writes it with
    /// `disabled`, each time later than the last (`Switches`).
    pub signed_at: Option<i64>,
    pub assets: BTreeMap<String, Asset>,
}

/// The most names taken from a list's `disabled`, and the longest name.
const MAX_DISABLED: usize = 32;
const MAX_FEATURE_NAME: usize = 64;

/// What the publisher has turned off in every Beacon, as the newest accepted release list
/// that says so has it. Kept in the state folder, so it holds while the list can't be had
/// and across restarts. Only `accept_and_remember` writes it, from a list whose signature,
/// expiry and version were accepted; nothing that came over the network unverified can.
///
/// A list is taken for this only when it was signed later than the one that set what is
/// kept (`signed_at`), so an older signed list played back can't turn back on what a newer
/// one turned off. Nothing kept (no list ever said anything) means nothing is off.
pub struct Switches;

impl Switches {
    /// The names turned off, as kept. Nothing kept, or a file that can't be read: none.
    pub fn load(state_dir: &Path) -> Vec<String> {
        let kept: Value = read_json(&state_dir.join(SWITCHES_FILE));
        kept.get("disabled").and_then(names).unwrap_or_default()
    }

    /// When the list that set what is kept was signed.
    fn stored_at(state_dir: &Path) -> Option<i64> {
        read_json::<Value>(&state_dir.join(SWITCHES_FILE)).str("signed_at").and_then(parse_iso8601)
    }

    pub(crate) fn store(state_dir: &Path, disabled: &[String], signed_at: i64) {
        write_json(&state_dir.join(SWITCHES_FILE), &json!({"disabled": disabled, "signed_at": iso8601(signed_at)}));
    }

    /// Takes what the accepted list `m` says, when it says anything and was signed later
    /// than what is kept. A name this Beacon doesn't know is kept and means nothing here.
    fn follow(state_dir: &Path, m: &Manifest) {
        let Some(disabled) = &m.disabled else { return };
        match (m.signed_at, Switches::stored_at(state_dir)) {
            (Some(at), kept) if kept.map_or(true, |kept| at > kept) => {
                if *disabled != Switches::load(state_dir) {
                    info!("update: the release list turns off: {}", if disabled.is_empty() { "nothing".to_string() } else { disabled.join(", ") });
                }
                Switches::store(state_dir, disabled, at);
            }
            (Some(_), _) => {}
            (None, _) => info!("update: the release list names what is turned off but not when it was signed; that is not taken"),
        }
    }
}

/// A list of feature names: short words of small letters, digits and `_`. None for anything
/// else, one odd entry included.
fn names(v: &Value) -> Option<Vec<String>> {
    let list = v.as_array().filter(|a| a.len() <= MAX_DISABLED)?;
    let name = |n: &Value| n.as_str().filter(|n| (1..=MAX_FEATURE_NAME).contains(&n.len()) && n.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_')).map(String::from);
    list.iter().map(name).collect()
}

/// A public key as update-key.pub and the manifest write it: the base64 of 32 bytes, 44
/// characters. All zeros is the placeholder, which is no key.
fn key_from_base64(s: &str) -> Option<[u8; 32]> {
    let key: [u8; 32] = base64_decode(s).filter(|_| s.len() == 44)?.try_into().ok()?;
    (key != [0u8; 32]).then_some(key)
}

/// True for an address of a file in this repository's releases, spelled plainly: the exact
/// prefix, then only letters, digits, `.`, `-`, `_` and `/`, with no `..` or `//` that a
/// server could resolve to somewhere else.
pub fn release_url_ok(url: &str) -> bool {
    let Some(rest) = url.strip_prefix(RELEASE_PREFIX) else { return false };
    (1..=300).contains(&rest.len())
        && !rest.contains("..")
        && !rest.contains("//")
        && !rest.starts_with('/')
        && rest.bytes().all(|b| b.is_ascii_alphanumeric() || b"._-/".contains(&b))
}

impl Manifest {
    /// Reads manifest.json. Call it only on bytes whose signature was verified.
    pub fn parse(data: &[u8]) -> Result<Manifest, String> {
        let v: Value = serde_json::from_slice(data).map_err(|_| "the update manifest is not JSON")?;
        let version = v.str("version").filter(|s| Version::parse(s).is_some()).ok_or("the update manifest has no valid version")?;
        let min_version = v.str("min_version").filter(|s| Version::parse(s).is_some()).ok_or("the update manifest has no valid min_version")?;
        // A release can't require more than itself: no helper could ever satisfy it.
        if Version::parse(min_version) > Version::parse(version) {
            return Err("the update manifest's min_version is newer than its version".into());
        }
        let expires_at = v.str("expires_at").and_then(parse_iso8601).ok_or("the update manifest has no valid expires_at")?;
        let next_key = match v.get("next_key") {
            None | Some(Value::Null) => None,
            Some(k) => Some(k.as_str().and_then(key_from_base64).ok_or("the update manifest's next_key is not a key")?),
        };
        let mut assets = BTreeMap::new();
        for (name, a) in v.get("assets").and_then(Value::as_object).ok_or("the update manifest lists no files")? {
            let url = a.str("url").filter(|u| release_url_ok(u)).ok_or_else(|| format!("the update manifest's {} address is not allowed", clip(name)))?;
            let sha256 = a
                .str("sha256")
                .filter(|h| h.len() == 64 && h.bytes().all(|b| b.is_ascii_hexdigit()))
                .ok_or_else(|| format!("the update manifest's {} hash is malformed", clip(name)))?;
            let size = a
                .get("size")
                .and_then(Value::as_u64)
                .filter(|n| (1..=MAX_ASSET).contains(n))
                .ok_or_else(|| format!("the update manifest's {} size is not allowed", clip(name)))?;
            assets.insert(name.clone(), Asset { url: url.into(), sha256: sha256.to_ascii_lowercase(), size });
        }
        // A field this helper doesn't know never spoils the list, and neither does one of
        // these two that is not what it should be: the list is taken without it.
        let disabled = v.get("disabled").and_then(names);
        let signed_at = v.str("signed_at").and_then(parse_iso8601);
        Ok(Manifest { version: version.into(), min_version: min_version.into(), expires_at, next_key, disabled, signed_at, assets })
    }
}

/// The manifest's first entry for a Mac: a zip that holds the app under the oldest of its
/// earlier folder names, which the updater of version 0.3.0 looks for.
pub const MAC_KEY: &str = "macos-universal";
/// The entry for the same app in a zip that holds it under the newer of its earlier folder
/// names, which the updater of version 0.3.1 looks for.
pub const MAC_BEACON_KEY: &str = "macos-universal-beacon";
/// The entry for the same app in a zip that holds it under its name. The entry's name and its
/// file's name say nothing of what the app is called, so they stay when that changes.
pub const MAC_APP_KEY: &str = "macos-app";
/// The entries a Mac takes its file from: the first of these that a list has.
pub(crate) const MAC_KEYS: [&str; 3] = [MAC_APP_KEY, MAC_BEACON_KEY, MAC_KEY];

/// The manifest's name for the file this computer runs (`std::env::consts::{OS, ARCH}`).
pub fn platform_key(os: &str, arch: &str) -> Option<&'static str> {
    match (os, arch) {
        ("macos", _) => Some(MAC_KEY),
        ("linux", "x86_64") => Some("linux-x86_64"),
        ("linux", "aarch64") => Some("linux-aarch64"),
        _ => None,
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum Plan {
    UpToDate,
    Update { version: String, asset: Asset },
}

/// What a manifest means for a helper at version `current` on `platform`.
pub fn plan(m: &Manifest, current: &str, platform: Option<&str>) -> Result<Plan, String> {
    if !is_newer(&m.version, current)? {
        return Ok(Plan::UpToDate);
    }
    let asset = match platform {
        Some(MAC_KEY) => MAC_KEYS.iter().find_map(|key| m.assets.get(*key)),
        Some(other) => m.assets.get(other),
        None => None,
    }
    .ok_or_else(|| format!("Version {} has no build for this computer.", m.version))?;
    Ok(Plan::Update { version: m.version.clone(), asset: asset.clone() })
}

// MARK: Keys and signatures

/// Reads update-key.pub: `#` lines are comments, every other line is a label (`primary` or
/// `recovery`) and the base64 of 32 bytes. The primary key signs releases; the recovery key is
/// kept apart from it and signs when the primary is lost or stolen. A helper trusts either.
/// An all-zero key is a placeholder and is left out; no key at all means updates are not set
/// up in this build.
pub fn update_keys(text: &str) -> Result<Vec<[u8; 32]>, String> {
    let (mut primary, mut recovery) = (None, None);
    for line in text.lines().map(str::trim).filter(|l| !l.is_empty() && !l.starts_with('#')) {
        let mut words = line.split_whitespace();
        let (label, b64) = (words.next().unwrap_or(""), words.next().unwrap_or(""));
        let slot = match label {
            "primary" => &mut primary,
            "recovery" => &mut recovery,
            _ => return Err("update-key.pub has a line that is neither a primary nor a recovery key".into()),
        };
        if slot.is_some() || words.next().is_some() {
            return Err(format!("update-key.pub has a malformed {label} line"));
        }
        let key: [u8; 32] =
            base64_decode(b64).filter(|_| b64.len() == 44).and_then(|k| k.try_into().ok()).ok_or_else(|| format!("update-key.pub's {label} key is not 32 bytes of base64"))?;
        *slot = Some(key);
    }
    let primary = primary.ok_or("update-key.pub has no primary key")?;
    Ok([Some(primary), recovery].into_iter().flatten().filter(|k| *k != [0u8; 32]).collect())
}

/// Checks a detached signature file over `message`: one base64 raw 64-byte ed25519 signature
/// per line. One signature that verifies under one of `keys` is enough, so a release can be
/// signed by the old and the new key while helpers move from one to the other.
pub fn verify_signatures(keys: &[[u8; 32]], message: &[u8], signature_file: &[u8]) -> Result<(), String> {
    let text = std::str::from_utf8(signature_file).map_err(|_| "the signature is malformed")?;
    let signatures: Vec<Vec<u8>> = text
        .lines()
        .map(str::trim)
        .filter(|l| !l.is_empty())
        .take(8)
        .filter_map(|l| base64_decode(l).filter(|s| s.len() == 64))
        .collect();
    if signatures.is_empty() {
        return Err("the signature is malformed".into());
    }
    let good = |key: &[u8; 32], sig: &[u8]| ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, key).verify(message, sig).is_ok();
    if signatures.iter().any(|sig| keys.iter().any(|key| good(key, sig))) {
        Ok(())
    } else {
        Err("the signature is not from a key this helper trusts".into())
    }
}

/// The keys a manifest or a Linux binary may be signed with: the ones compiled in, and the
/// ones an accepted manifest handed over.
#[derive(Clone, Debug, PartialEq)]
pub struct Trust {
    builtin: Vec<[u8; 32]>,
    /// Oldest first, at most `HANDED_LIMIT`.
    handed: Vec<[u8; 32]>,
}

impl Trust {
    pub fn new(builtin: Vec<[u8; 32]>, handed: Vec<[u8; 32]>) -> Trust {
        let mut trust = Trust { builtin, handed: vec![] };
        for key in handed {
            trust.hand_over(key);
        }
        trust
    }

    pub fn keys(&self) -> Vec<[u8; 32]> {
        self.builtin.iter().chain(&self.handed).copied().collect()
    }

    /// Adds a key an accepted manifest named as the next one. True when the set changed.
    pub fn hand_over(&mut self, key: [u8; 32]) -> bool {
        if key == [0u8; 32] || self.builtin.contains(&key) || self.handed.contains(&key) {
            return false;
        }
        if self.handed.len() >= HANDED_LIMIT {
            self.handed.remove(0);
        }
        self.handed.push(key);
        true
    }
}

/// Decides whether the bytes of a manifest are to be believed, in this order: a signature
/// from a trusted key, then the contents, then that it has not expired, then that it is not
/// older than the newest one this helper accepted before (an attacker who can't sign can
/// still replay an old, signed list to hold helpers on a version with a known hole).
pub fn accept_manifest(data: &[u8], signature_file: &[u8], trusted: &[[u8; 32]], high_water: Option<Version>, now: i64) -> Result<Manifest, Fault> {
    let rejected = |why: String| Fault::new(Problem::Rejected, format!("The update manifest was not accepted: {why}."));
    verify_signatures(trusted, data, signature_file).map_err(rejected)?;
    let m = Manifest::parse(data).map_err(rejected)?;
    if now >= m.expires_at {
        return Err(Fault::new(Problem::Expired, format!("The update manifest expired at {}.", iso8601(m.expires_at))));
    }
    if Version::parse(&m.version) < high_water {
        return Err(Fault::new(Problem::Replayed, format!("The update manifest names version {}, older than one already seen.", m.version)));
    }
    Ok(m)
}

/// A release list is signed again well before it expires. One that is this close to its end
/// was not, which the log says at every check.
const EXPIRY_NOTICE: i64 = 30 * 86_400;

/// Logs one line when an accepted manifest expires within `EXPIRY_NOTICE` of `now`.
fn note_expiry(expires_at: i64, now: i64) -> bool {
    let soon = expires_at - now < EXPIRY_NOTICE;
    if soon {
        info!("update: the release list is valid until {}; its publisher has to sign it again before then", iso8601(expires_at));
    }
    soon
}

fn load_trust(state_dir: &Path, builtin: Vec<[u8; 32]>) -> Trust {
    let file: Value = read_json(&state_dir.join(TRUSTED_KEYS_FILE));
    let handed = file.get("keys").and_then(Value::as_array).map(|a| a.iter().filter_map(|k| k.as_str().and_then(key_from_base64)).collect()).unwrap_or_default();
    Trust::new(builtin, handed)
}

fn load_high_water(state_dir: &Path) -> Option<Version> {
    read_json::<Value>(&state_dir.join(HIGH_WATER_FILE)).str("version").and_then(Version::parse)
}

/// `accept_manifest` against what the state folder remembers, which it then brings up to
/// date: the highest version seen, and a key the manifest hands over. Only a manifest that
/// was accepted changes either, so a `next_key` in a list nobody trusted is never read.
/// The same goes for what the list turns off (`Switches`).
fn accept_and_remember(state_dir: &Path, builtin: Vec<[u8; 32]>, data: &[u8], signature_file: &[u8], now: i64) -> Result<Manifest, Fault> {
    let mut trust = load_trust(state_dir, builtin);
    let high_water = load_high_water(state_dir);
    let m = accept_manifest(data, signature_file, &trust.keys(), high_water, now)?;
    if Version::parse(&m.version) > high_water {
        write_json(&state_dir.join(HIGH_WATER_FILE), &json!({"version": m.version}));
    }
    if m.next_key.is_some_and(|key| trust.hand_over(key)) {
        info!("update: the release list handed over a new signing key; it is trusted from now on");
        write_json(&state_dir.join(TRUSTED_KEYS_FILE), &json!({"keys": trust.handed.iter().map(|k| base64(k)).collect::<Vec<_>>()}));
    }
    Switches::follow(state_dir, &m);
    Ok(m)
}

/// What a Linux binary's detached signature covers. Not the file's bytes alone: the version
/// and the platform are in it, so a signed file can't be served as another version or for
/// another architecture.
pub fn binary_message(version: &str, platform: &str, sha256: &str) -> String {
    format!("rex-duo-helper|{version}|{platform}|{}", sha256.to_ascii_lowercase())
}

// MARK: Size and hash

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Writes a download while counting and hashing it. It stops at the size the manifest gave
/// (and at `MAX_ASSET`), so a wrong or endless file never fills the disk.
pub struct Checked<W: std::io::Write> {
    out: W,
    hash: ring::digest::Context,
    written: u64,
    limit: u64,
}

impl<W: std::io::Write> Checked<W> {
    pub fn new(out: W, expected_size: u64) -> Checked<W> {
        Checked { out, hash: ring::digest::Context::new(&ring::digest::SHA256), written: 0, limit: expected_size.min(MAX_ASSET) }
    }

    pub fn write(&mut self, chunk: &[u8]) -> Result<(), String> {
        if self.written + chunk.len() as u64 > self.limit {
            return Err("the download is larger than the manifest says".into());
        }
        self.out.write_all(chunk).map_err(|e| format!("could not write the download: {e}"))?;
        self.hash.update(chunk);
        self.written += chunk.len() as u64;
        Ok(())
    }

    /// The writer back, if exactly `size` bytes with this SHA-256 went through.
    pub fn finish(mut self, size: u64, sha256: &str) -> Result<W, String> {
        if self.written != size {
            return Err("the download is shorter than the manifest says".into());
        }
        if !hex(self.hash.finish().as_ref()).eq_ignore_ascii_case(sha256) {
            return Err("the download's SHA-256 does not match the manifest".into());
        }
        self.out.flush().map_err(|e| format!("could not write the download: {e}"))?;
        Ok(self.out)
    }
}

// MARK: Where the helper is installed

/// The thing an update replaces.
#[derive(Clone, Debug, PartialEq)]
pub enum Place {
    /// The app's folder, under its name or an earlier one.
    MacApp(PathBuf),
    /// `~/.local/bin/rex-duo-helper`
    LinuxBinary(PathBuf),
}

impl Place {
    /// Where this program is installed, from its own path, or why it can't update itself.
    /// `linux_install` is where `install` puts the binary.
    pub fn detect(os: &str, exe: &Path, linux_install: &Path) -> Result<Place, String> {
        if exe.components().any(|c| c.as_os_str() == "target") {
            return Err("This copy runs from a cargo target folder.".into());
        }
        match os {
            "macos" => {
                let app = exe
                    .parent()
                    .filter(|macos| macos.ends_with("Contents/MacOS"))
                    .and_then(|macos| macos.parent()?.parent())
                    .filter(|app| app.file_name().is_some_and(allowed_app_name))
                    .ok_or(concat!(crate::beacon_name!(), " is not running from its app."))?;
                if app.to_string_lossy().contains("/AppTranslocation/") {
                    return Err(concat!("Move ", crate::beacon_name!(), " to the Applications folder and open it again.").into());
                }
                Ok(Place::MacApp(app.to_path_buf()))
            }
            "linux" if exe == linux_install => Ok(Place::LinuxBinary(exe.to_path_buf())),
            "linux" => Err(format!("This copy is not the installed one ({}).", linux_install.display())),
            _ => Err("Updates are not available on this system.".into()),
        }
    }

    /// The place for a path the old program was told (`finish-update --place`).
    /// None on a system that has no such place.
    fn at(os: &str, path: PathBuf) -> Option<Place> {
        match os {
            "macos" => Some(Place::MacApp(path)),
            "linux" => Some(Place::LinuxBinary(path)),
            _ => None,
        }
    }

    pub fn path(&self) -> &Path {
        match self {
            Place::MacApp(p) | Place::LinuxBinary(p) => p,
        }
    }

    fn dir(&self) -> &Path {
        self.path().parent().unwrap_or(Path::new("/"))
    }

    /// Where a new version goes. A Mac app always goes under `APP_NAME`, beside the installed
    /// one, whichever of its names that one has.
    pub fn target(&self) -> PathBuf {
        match self {
            Place::MacApp(_) => self.dir().join(APP_NAME),
            Place::LinuxBinary(p) => p.clone(),
        }
    }

    /// The program the background service runs: the one in the new version's place while
    /// something is there, else the installed one.
    fn program(&self) -> PathBuf {
        match self {
            Place::MacApp(p) => {
                let target = self.target();
                if target.exists() { target } else { p.clone() }.join("Contents/MacOS").join(service::NAME)
            }
            Place::LinuxBinary(p) => p.clone(),
        }
    }

    /// Where the version before the update stays until the new one is confirmed.
    pub fn previous(&self) -> PathBuf {
        match self {
            Place::MacApp(_) => self.dir().join(PREVIOUS_APP),
            Place::LinuxBinary(p) => self.dir().join(format!("{}.previous", p.file_name().unwrap_or_default().to_string_lossy())),
        }
    }

    /// The old program, once it has been moved aside.
    fn previous_binary(&self) -> PathBuf {
        match self {
            Place::MacApp(_) => self.previous().join("Contents/MacOS").join(service::NAME),
            Place::LinuxBinary(_) => self.previous(),
        }
    }
}

/// What the helper knows about itself when it decides whether it may update.
pub struct Env {
    pub dry_run: bool,
    pub debug_build: bool,
    /// The keys of update-key.pub. Empty when it only holds the placeholder.
    pub keys: Result<Vec<[u8; 32]>, String>,
    pub place: Result<Place, String>,
    /// A background service (LaunchAgent, systemd unit) is set up to be restarted.
    pub service: bool,
    /// The folder the helper sits in can be written.
    pub writable: bool,
}

pub const NO_KEY: &str = "Updates are not set up in this build (update-key.pub is the placeholder).";

/// Why this helper can't replace itself, or None when it can.
pub fn blocker(e: &Env) -> Option<String> {
    if e.dry_run {
        return Some("A dry run never updates.".into());
    }
    if e.debug_build {
        return Some("A debug build never updates.".into());
    }
    match &e.keys {
        Ok(keys) if !keys.is_empty() => {}
        Ok(_) => return Some(NO_KEY.into()),
        Err(why) => return Some(format!("Updates are not set up in this build ({why}).")),
    }
    let place = match &e.place {
        Ok(p) => p,
        Err(why) => return Some(why.clone()),
    };
    if !e.service {
        return Some(concat!(crate::beacon_name!(), " is not installed as a background service.").into());
    }
    if !e.writable {
        return Some(format!("{BEACON} can't write to {}.", place.dir().display()));
    }
    None
}

// MARK: One update at a time

/// update.lock in the state folder, holding the pid of the process that updates.
#[derive(Debug)]
pub struct UpdateLock {
    path: PathBuf,
    held: bool,
}

impl UpdateLock {
    /// Takes the lock, or says who has it. A lock whose process is gone, or that is older than
    /// any update takes, is taken over.
    pub fn acquire(dir: &Path, alive: impl Fn(u64) -> bool) -> Result<UpdateLock, String> {
        use std::io::Write;
        let path = dir.join(LOCK_FILE);
        for _ in 0..2 {
            match std::fs::OpenOptions::new().write(true).create_new(true).open(&path) {
                Ok(mut f) => {
                    let _ = write!(f, "{}", std::process::id());
                    return Ok(UpdateLock { path, held: true });
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                    let pid = std::fs::read_to_string(&path).ok().and_then(|s| s.trim().parse::<u64>().ok());
                    let age = std::fs::metadata(&path).and_then(|m| m.modified()).ok().and_then(|t| SystemTime::now().duration_since(t).ok());
                    let fresh = age.is_none_or(|a| a < LOCK_MAX_AGE);
                    match pid {
                        Some(pid) if fresh && (pid == u64::from(std::process::id()) || alive(pid)) => {
                            return Err(format!("Another update is running (pid {pid})."));
                        }
                        _ => {
                            let _ = std::fs::remove_file(&path);
                        }
                    }
                }
                Err(e) => return Err(format!("could not write {}: {e}", path.display())),
            }
        }
        Err("Another update is running.".into())
    }

    /// True while a live process holds the lock: an update, or a move of the Mac app or of
    /// its LaunchAgent's label.
    #[cfg(any(target_os = "macos", test))]
    pub(crate) fn busy(dir: &Path, alive: impl Fn(u64) -> bool) -> bool {
        let path = dir.join(LOCK_FILE);
        let pid = std::fs::read_to_string(&path).ok().and_then(|s| s.trim().parse::<u64>().ok());
        let age = std::fs::metadata(&path).and_then(|m| m.modified()).ok().and_then(|t| SystemTime::now().duration_since(t).ok());
        pid.is_some_and(|pid| age.is_none_or(|a| a < LOCK_MAX_AGE) && alive(pid))
    }

    /// Takes over the lock of the process that started this one (`finish-update`).
    pub(crate) fn adopt(dir: &Path) -> UpdateLock {
        let path = dir.join(LOCK_FILE);
        let _ = std::fs::write(&path, std::process::id().to_string());
        UpdateLock { path, held: true }
    }

    /// Leaves the lock in place for the process that carries on.
    pub(crate) fn hand_over(mut self) {
        self.held = false;
    }

    /// Removes a lock this process handed over that nobody adopted (it still names this
    /// process), so the next update is not held up by one that never got going. True if so.
    pub(crate) fn take_back(dir: &Path) -> bool {
        let path = dir.join(LOCK_FILE);
        let mine = std::fs::read_to_string(&path).is_ok_and(|s| s.trim() == std::process::id().to_string());
        mine && std::fs::remove_file(&path).is_ok()
    }
}

impl Drop for UpdateLock {
    fn drop(&mut self) {
        if self.held {
            let _ = std::fs::remove_file(&self.path);
        }
    }
}

// MARK: Downloading

fn download_host_ok(u: &Url) -> bool {
    u.secure && u.port == 443 && DOWNLOAD_HOSTS.contains(&u.host.as_str())
}

type HostRule = dyn Fn(&Url) -> bool + Send + Sync;
type Sink<'a> = dyn FnMut(&[u8]) -> Result<(), String> + Send + 'a;

/// GETs `url` into `sink`, following redirects only to addresses `allowed` accepts. The
/// address is checked before anything connects to it.
async fn fetch(url: &str, allowed: &HostRule, sink: &mut Sink<'_>) -> Result<(), String> {
    let mut url = url.to_string();
    for _ in 0..=MAX_REDIRECTS {
        let u = Url::parse(&url).ok_or("bad download address")?;
        if !allowed(&u) {
            return Err(format!("refusing to download from {}://{}", if u.secure { "https" } else { "http" }, u.authority()));
        }
        let headers = [("User-Agent", gateway::USER_AGENT.to_string()), ("Accept", "*/*".to_string())];
        let x = tokio::time::timeout(CONNECT_TIMEOUT, Exchange::open("GET", &u, &headers, None))
            .await
            .map_err(|_| format!("{} did not answer", u.host))?
            .map_err(|e| format!("could not reach {}: {e}", u.host))?;
        match x.status {
            200 => return x.read_body(sink).await,
            301 | 302 | 303 | 307 | 308 => {
                let to = x.header("location").ok_or("redirect without an address")?.to_string();
                url = if to.starts_with('/') && !to.starts_with("//") {
                    format!("{}://{}{to}", if u.secure { "https" } else { "http" }, u.authority())
                } else {
                    to
                };
            }
            s => return Err(format!("{} answered {s}", u.host)),
        }
    }
    Err("too many redirects".into())
}

/// Where release files come from: which addresses may be asked for, and which hosts a
/// redirect may lead to. Tests stand a local server in for GitHub.
#[derive(Clone, Copy)]
struct Origin {
    url_ok: fn(&str) -> bool,
    host_ok: fn(&Url) -> bool,
}

const RELEASES: Origin = Origin { url_ok: release_url_ok, host_ok: download_host_ok };

/// A small release file (the manifest, a signature) in memory.
async fn fetch_small(origin: Origin, url: &str, limit: usize) -> Result<Vec<u8>, String> {
    if !(origin.url_ok)(url) {
        return Err("that address is not one of this project's releases".into());
    }
    let mut out = Vec::new();
    let mut keep = |chunk: &[u8]| {
        if out.len() + chunk.len() > limit {
            return Err("the file is larger than expected".to_string());
        }
        out.extend_from_slice(chunk);
        Ok(())
    };
    tokio::time::timeout(Duration::from_secs(60), fetch(url, &origin.host_ok, &mut keep)).await.map_err(|_| "the download took too long")??;
    Ok(out)
}

/// Downloads to a new file `dest`, readable by this user only, and keeps it only if its size
/// and SHA-256 are the expected ones.
async fn download_to(url: &str, allowed: &HostRule, dest: &Path, size: u64, sha256: &str) -> Result<(), String> {
    let file = crate::platform::create_private(dest).map_err(|e| format!("could not create {}: {e}", dest.display()))?;
    let mut out = Checked::new(file, size);
    let got = tokio::time::timeout(DOWNLOAD_TIMEOUT, fetch(url, allowed, &mut |chunk: &[u8]| out.write(chunk)))
        .await
        .unwrap_or_else(|_| Err("the download took too long".into()));
    let done = got.and_then(|()| out.finish(size, sha256)).and_then(|f| f.sync_all().map_err(|e| e.to_string()));
    if done.is_err() {
        let _ = std::fs::remove_file(dest);
    }
    done
}

/// A signature file holds a few lines of 88 characters.
const MAX_SIGNATURE: usize = 2048;

// MARK: Checking what was downloaded (macOS)

pub(crate) fn os(s: impl Into<OsString>) -> OsString {
    s.into()
}

/// The designated requirement the new app must meet: our bundle id, signed with a Developer ID
/// certificate of our team, on Apple's chain.
fn requirement() -> String {
    format!(
        "identifier \"{BUNDLE_ID}\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists \
         and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"{TEAM_ID}\""
    )
}

/// The tools that must each succeed on a downloaded app, as a program path and an argument
/// list. Never a shell string.
fn mac_checks(app: &Path) -> Vec<(&'static str, Vec<OsString>)> {
    vec![
        ("/usr/bin/codesign", vec![os("--verify"), os("--deep"), os("--strict"), os(app)]),
        ("/usr/bin/codesign", vec![os("--verify"), os(format!("-R={}", requirement())), os(app)]),
    ]
}

fn gatekeeper_check(app: &Path) -> (&'static str, Vec<OsString>) {
    ("/usr/sbin/spctl", vec![os("--assess"), os("--type"), os("execute"), os("-vv"), os(app)])
}

/// Gatekeeper must accept the app and name a notarized Developer ID as the reason.
fn gatekeeper_ok(success: bool, output: &str) -> bool {
    success && output.lines().any(|l| l.trim() == "source=Notarized Developer ID")
}

/// True when both `codesign` checks pass: the app is intact, and it is ours.
pub(crate) fn mac_signature_ok(app: &Path) -> Result<bool, String> {
    for (program, args) in mac_checks(app) {
        if !tool(program, &args)?.0 {
            return Ok(false);
        }
    }
    Ok(true)
}

/// Runs a system tool (a full path, or a name `tools` looks up) and returns whether it
/// succeeded and what it printed.
pub(crate) fn tool(program: &str, args: &[OsString]) -> Result<(bool, String), String> {
    let mut command = crate::tools::command(program).ok_or_else(|| format!("{program} is not on this system"))?;
    let o = command.args(args).stdin(Stdio::null()).output().map_err(|e| format!("{program}: {e}"))?;
    Ok((o.status.success(), format!("{}{}", String::from_utf8_lossy(&o.stdout), String::from_utf8_lossy(&o.stderr))))
}

/// The app in an unzipped download: the folder holds one entry and no more, and that entry is
/// a real folder, not a link, whose name is on the list of allowed names (so it ends in
/// `.app` and starts with no dot) and which holds this program where an app has it, as a real
/// file. Anything else is refused before any other check looks at it.
fn sole_app(unpacked: &Path) -> Result<PathBuf, String> {
    let refused = || format!("The download does not hold {BEACON} alone.");
    let mut entries = std::fs::read_dir(unpacked).map_err(|_| refused())?;
    let (Some(Ok(entry)), None) = (entries.next(), entries.next()) else { return Err(refused()) };
    let name = entry.file_name();
    let plain = name.to_str().is_some_and(|n| n.ends_with(".app") && !n.starts_with('.'));
    let app = entry.path();
    let real = |path: &Path, wanted: fn(&std::fs::Metadata) -> bool| std::fs::symlink_metadata(path).is_ok_and(|m| wanted(&m));
    if !plain || !allowed_app_name(&name) || !real(&app, std::fs::Metadata::is_dir) {
        return Err(refused());
    }
    if !real(&app.join("Contents/MacOS").join(service::NAME), std::fs::Metadata::is_file) {
        return Err(format!("The download does not hold {BEACON}."));
    }
    Ok(app)
}

/// Unzips the download and checks the app in it. Returns the app, still in the scratch folder.
fn unpack_and_check_mac(zip: &Path, into: &Path, version: &str) -> Result<PathBuf, String> {
    let (ok, _) = tool("/usr/bin/ditto", &[os("-x"), os("-k"), os(zip), os(into)])?;
    if !ok {
        return Err("The download could not be unzipped.".into());
    }
    // Each of a release's zips holds the app under one of its names. The app is the same in
    // all of them, and `swap_mac` gives it its name.
    let app = sole_app(into)?;
    if !mac_signature_ok(&app)? {
        return Err("The downloaded app's code signature was not accepted.".into());
    }
    let (program, args) = gatekeeper_check(&app);
    let (ok, output) = tool(program, &args)?;
    if !gatekeeper_ok(ok, &output) {
        return Err("macOS did not accept the downloaded app as notarized.".into());
    }
    let plist = app.join("Contents/Info.plist");
    let (ok, found) = tool("/usr/bin/plutil", &[os("-extract"), os("CFBundleShortVersionString"), os("raw"), os("-o"), os("-"), os(&plist)])?;
    if !ok || found.trim() != version {
        return Err(format!("The downloaded app is not version {version}."));
    }
    Ok(app)
}

// MARK: Swapping, and putting the old one back

/// Puts a checked binary in place of the installed one, which stays as `<name>.previous`
/// until the new one is confirmed.
fn swap_linux(new: &Path, place: &Place) -> Result<(), String> {
    let (installed, previous) = (place.path(), place.previous());
    crate::platform::make_executable(new).map_err(|e| e.to_string())?;
    let _ = std::fs::remove_file(&previous);
    // A second name for the running file, so it survives the rename over its first name.
    if std::fs::hard_link(installed, &previous).is_err() {
        std::fs::copy(installed, &previous).map_err(|e| format!("could not keep the current version: {e}"))?;
    }
    // In one step: there is no moment without a helper at this path.
    std::fs::rename(new, installed).map_err(|e| format!("could not install the new version: {e}"))
}

/// Puts a checked app in under its name, `APP_NAME`. The installed one, under any of its
/// names, moves to `PREVIOUS_APP` beside it until the new one is confirmed. Both moves are
/// renames on one volume. A copy set aside under any name by an earlier update goes first.
fn swap_mac(new_app: &Path, place: &Place) -> Result<(), String> {
    let (installed, previous, target) = (place.path(), place.previous(), place.target());
    for old in std::iter::once(previous.clone()).chain(EARLIER_PREVIOUS_APPS.map(|name| place.dir().join(name))) {
        if old.exists() {
            std::fs::remove_dir_all(&old).map_err(|e| format!("could not remove {}: {e}", old.display()))?;
        }
    }
    std::fs::rename(installed, &previous).map_err(|e| format!("could not move the current app aside: {e}"))?;
    if let Err(e) = std::fs::rename(new_app, &target) {
        let _ = std::fs::rename(&previous, installed);
        return Err(format!("could not install the new app: {e}"));
    }
    Ok(())
}

/// Puts the previous version back where it was, under the name it had, and takes the new one
/// away.
fn roll_back(place: &Place) -> Result<(), String> {
    let (installed, previous) = (place.path(), place.previous());
    if !previous.exists() {
        return Err(format!("{} is missing", previous.display()));
    }
    match place {
        Place::LinuxBinary(_) => std::fs::rename(&previous, installed).map_err(|e| e.to_string()),
        Place::MacApp(_) => {
            let failed = place.dir().join(format!("{FAILED_PREFIX}{}.app", std::process::id()));
            let _ = std::fs::remove_dir_all(&failed);
            let target = place.target();
            std::fs::rename(&target, &failed).map_err(|e| e.to_string())?;
            if let Err(e) = std::fs::rename(&previous, installed) {
                let _ = std::fs::rename(&failed, &target);
                return Err(e.to_string());
            }
            let _ = std::fs::remove_dir_all(&failed);
            Ok(())
        }
    }
}

/// Removes the previous version, once the new one is confirmed. The program that does this
/// may be running from that copy: it keeps running after the copy's name is gone.
fn remove_previous(place: &Place) -> std::io::Result<()> {
    let previous = place.previous();
    let gone = |removed: std::io::Result<()>| removed.or_else(|e| if e.kind() == std::io::ErrorKind::NotFound { Ok(()) } else { Err(e) });
    match place {
        Place::LinuxBinary(_) => gone(std::fs::remove_file(&previous)),
        // Under every name.
        Place::MacApp(_) => EARLIER_PREVIOUS_APPS.iter().fold(gone(std::fs::remove_dir_all(&previous)), |so_far, name| so_far.and(gone(std::fs::remove_dir_all(place.dir().join(name))))),
    }
}

/// A file or folder that is removed when this goes out of scope.
struct Scratch(PathBuf);

impl Drop for Scratch {
    fn drop(&mut self) {
        if std::fs::symlink_metadata(&self.0).is_ok_and(|m| m.is_dir()) {
            let _ = std::fs::remove_dir_all(&self.0);
        } else {
            let _ = std::fs::remove_file(&self.0);
        }
    }
}

/// Checks a downloaded Linux binary against the manifest (size, SHA-256) and its detached
/// signature, then swaps it in. Nothing is swapped unless all three hold.
fn check_and_swap_linux(new: &Path, signature_file: &[u8], trusted: &[[u8; 32]], version: &str, platform: &str, asset: &Asset, place: &Place) -> Result<(), Fault> {
    let failed = |why: String| Fault::new(Problem::Checks, format!("The downloaded file was not accepted: {why}."));
    let bytes = std::fs::read(new).map_err(|e| failed(e.to_string()))?;
    if bytes.len() as u64 != asset.size || !sha256_hex(&bytes).eq_ignore_ascii_case(&asset.sha256) {
        return Err(failed("it is not the file the manifest names".into()));
    }
    verify_signatures(trusted, binary_message(version, platform, &asset.sha256).as_bytes(), signature_file).map_err(failed)?;
    swap_linux(new, place).map_err(|e| Fault::new(Problem::Install, e))
}

/// Downloads the new version next to the installed one, checks it, and swaps it in. After
/// this the new version is on disk and the old one still runs.
async fn stage_and_swap(origin: Origin, place: &Place, trusted: Vec<[u8; 32]>, version: &str, platform: &str, asset: &Asset) -> Result<(), Fault> {
    let download = |e: String| Fault::new(Problem::Download, e);
    if !(origin.url_ok)(&asset.url) {
        return Err(download("that address is not one of this project's releases".into()));
    }
    let pid = std::process::id();
    let (place, version, platform, asset) = (place.clone(), version.to_string(), platform.to_string(), asset.clone());
    let joined = |e: tokio::task::JoinError| Fault::new(Problem::Install, e.to_string());
    match &place {
        Place::LinuxBinary(_) => {
            let tmp = Scratch(place.dir().join(format!(".{}.download-{pid}", service::NAME)));
            let _ = std::fs::remove_file(&tmp.0);
            download_to(&asset.url, &origin.host_ok, &tmp.0, asset.size, &asset.sha256).await.map_err(download)?;
            let sig = fetch_small(origin, &format!("{}.sig", asset.url), MAX_SIGNATURE).await.map_err(|e| download(format!("could not get the file's signature: {e}")))?;
            let new = tmp.0.clone();
            let work = move || check_and_swap_linux(&new, &sig, &trusted, &version, &platform, &asset, &place);
            tokio::task::spawn_blocking(work).await.map_err(joined)?
        }
        Place::MacApp(_) => {
            let scratch = Scratch(place.dir().join(format!(".rex-duo-helper-update-{pid}")));
            let _ = std::fs::remove_dir_all(&scratch.0);
            crate::platform::create_private_dir(&scratch.0)
                .map_err(|e| Fault::new(Problem::Install, format!("could not create {}: {e}", scratch.0.display())))?;
            let zip = scratch.0.join("download.zip");
            download_to(&asset.url, &origin.host_ok, &zip, asset.size, &asset.sha256).await.map_err(download)?;
            let unpacked = scratch.0.join("unpacked");
            let work = move || -> Result<(), Fault> {
                let app = unpack_and_check_mac(&zip, &unpacked, &version).map_err(|e| Fault::new(Problem::Checks, e))?;
                swap_mac(&app, &place).map_err(|e| Fault::new(Problem::Install, e))
            };
            tokio::task::spawn_blocking(work).await.map_err(joined)?
        }
    }
}

// MARK: Restart, confirm, roll back

/// The outside world `finish` needs, so tests can stand in for the service manager.
pub struct Effects<'a> {
    pub restart: &'a dyn Fn() -> bool,
    /// True once the helper that ran before the restart has exited.
    pub old_gone: &'a dyn Fn() -> bool,
    /// The version the running helper reports in status.json, if one runs.
    pub running_version: &'a dyn Fn() -> Option<String>,
    /// How long the old helper gets to exit.
    pub exit_wait: Duration,
    /// How long the new one then gets to report in.
    pub wait: Duration,
    pub poll: Duration,
}

/// Restarts the background service into the swapped-in version and waits for it to report
/// that version. When it does, the previous version is removed: one copy of the helper is
/// installed. If it doesn't, puts the previous version back and restarts again.
///
/// The wait has two parts. First for the old helper to exit: a service manager lets it finish
/// what it is doing, and that time must not be taken out of the new one's. Only then does the
/// time the new version has to report in begin.
pub fn finish(place: &Place, version: &str, fx: &Effects) -> Result<(), String> {
    (fx.restart)();
    let asked = Instant::now();
    while !(fx.old_gone)() && asked.elapsed() < fx.exit_wait {
        std::thread::sleep(fx.poll);
    }
    let began = Instant::now();
    loop {
        if (fx.running_version)().as_deref() == Some(version) {
            // The update holds either way; a copy that could not be removed is replaced by
            // the next update.
            if let Err(e) = remove_previous(place) {
                info!("update: could not remove {}: {e}", place.previous().display());
            }
            return Ok(());
        }
        if began.elapsed() >= fx.wait {
            break;
        }
        std::thread::sleep(fx.poll);
    }
    roll_back(place).map_err(|e| format!("Version {version} did not start, and the previous version could not be put back: {e}."))?;
    (fx.restart)();
    Err(format!("Version {version} did not start, so the previous version was put back."))
}

/// `old_pid` is the helper that ran when the update began, if one did.
fn real_finish(place: &Place, version: &str, old_pid: Option<u64>) -> Result<(), String> {
    finish(
        place,
        version,
        &Effects {
            // After a swap the program is the new version's; after a roll back, the old one's.
            restart: &|| service::restart_into(&place.program()),
            old_gone: &|| old_pid.is_none_or(|pid| !crate::platform::process_alive(pid)),
            running_version: &|| service::running().map(|r| r.version),
            exit_wait: EXIT_TIMEOUT,
            wait: CONFIRM_TIMEOUT,
            poll: Duration::from_millis(250),
        },
    )
}

/// update_result.json: how the last update ended, for the helper that starts after it.
fn record_result(state_dir: &Path, version: &str, result: &Result<(), String>) {
    let v = json!({"version": version, "ok": result.is_ok(), "error": result.as_ref().err(), "at": now_iso()});
    let tmp = state_dir.join(format!("{RESULT_FILE}.tmp"));
    if std::fs::write(&tmp, v.to_string()).is_ok() {
        let _ = std::fs::rename(&tmp, state_dir.join(RESULT_FILE));
    }
}

/// A failed update this helper should remember: the version that didn't start. Clears the
/// file once it no longer says anything (the update worked, or this helper is already at or
/// past that version).
fn failed_update(state_dir: &Path, current: &str) -> Option<String> {
    let path = state_dir.join(RESULT_FILE);
    let v: Value = serde_json::from_slice(&std::fs::read(&path).ok()?).ok()?;
    let failed = match (v.str("version"), v.bool("ok")) {
        (Some(version), Some(false)) if is_newer(version, current) == Ok(true) => Some(version.to_string()),
        _ => None,
    };
    if failed.is_none() {
        let _ = std::fs::remove_file(&path);
    }
    failed
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))] // only a Mac loads the finisher through launchd
fn xml(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// What the old program is started with to finish an update.
fn finisher_args(version: &str, place: &Place, state_dir: &Path, old_pid: u32) -> Vec<OsString> {
    vec![
        os("finish-update"),
        os("--version"),
        os(version),
        os("--place"),
        os(place.path()),
        os("--state-dir"),
        os(state_dir),
        os("--old-pid"),
        os(old_pid.to_string()),
    ]
}

/// The one-shot launchd job the finisher runs as on a Mac: it starts when it is loaded and is
/// not started again when it ends, however it ends.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))] // only a Mac loads the finisher through launchd
fn finisher_plist(program: &Path, args: &[OsString]) -> String {
    let strings: String = std::iter::once(program.as_os_str())
        .chain(args.iter().map(OsString::as_os_str))
        .map(|a| format!("<string>{}</string>", xml(&a.to_string_lossy())))
        .collect();
    format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{FINISHER_LABEL}</string>
  <key>ProgramArguments</key>
  <array>{strings}</array>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>AssociatedBundleIdentifiers</key><string>{BUNDLE_ID}</string>
</dict>
</plist>
"#
    )
}

/// The command that starts the finisher outside the helper's own service. `domain` and
/// `plist` are only used on a Mac. None on a system that has no such command.
fn finisher_start(os_name: &str, program: &Path, args: &[OsString], domain: &str, plist: &Path) -> Option<(&'static str, Vec<OsString>)> {
    match os_name {
        "macos" => Some(("/bin/launchctl", vec![os("bootstrap"), os(domain), os(plist)])),
        "linux" => {
            let mut a = vec![os("--user"), os("--collect"), os("--quiet"), os("--"), os(program)];
            a.extend(args.iter().cloned());
            Some(("systemd-run", a))
        }
        _ => None,
    }
}

/// The command that unloads a finisher job left from an earlier update on a Mac.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))] // only a Mac loads the finisher through launchd
fn finisher_clear(domain: &str) -> (&'static str, Vec<OsString>) {
    ("/bin/launchctl", vec![os("bootout"), os(format!("{domain}/{FINISHER_LABEL}"))])
}

/// Starts the old program, now moved aside, to restart the service and watch the new version
/// come up. It must outlive the restart of the service it was started from.
///
/// On Linux it runs as its own transient systemd unit (`systemd-run --user`), outside the
/// service's control group, which `systemctl restart` stops as a whole.
///
/// On a Mac it runs as its own launchd job, loaded from a one-shot plist in the state folder
/// with `launchctl bootstrap`, the way the helper's own agent is loaded. A plain child would
/// not do: `launchctl kickstart -k` kills the service, and when a job dies launchd kills what
/// is left in the job's process group (launchd.plist(5), `AbandonProcessGroup`). A child in a
/// group of its own escapes that rule as written, but it would still be something the
/// service's job left behind, and whether launchd lets such a process live is not a promise
/// it makes. A job of its own is not part of the service at all, which is the same
/// separation `systemd-run` gives on Linux. `launchctl submit` would also make one, but it
/// tells launchd to start the program again whenever it fails, and a finisher that rolled back
/// must not run twice.
fn spawn_finisher(place: &Place, version: &str, state_dir: &Path) -> Result<(), String> {
    spawn_job(&place.previous_binary(), &finisher_args(version, place, state_dir, std::process::id()), state_dir)
}

/// Starts `program` with `args` as the job described above. One such job runs at a time: the
/// process that starts it holds update.lock.
#[cfg_attr(not(target_os = "macos"), allow(unused_variables))] // the job's file is for launchd
pub(crate) fn spawn_job(program: &Path, args: &[OsString], state_dir: &Path) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    let (domain, plist) = {
        let (domain, plist) = (service::domain(), state_dir.join(FINISHER_PLIST));
        // The job of an earlier update stays loaded after its program ended. Unload it, or
        // launchd refuses a second one under the same label. bootout returns before the job
        // is gone.
        if service::loaded_label(FINISHER_LABEL) {
            let (program, args) = finisher_clear(&domain);
            let _ = tool(program, &args);
            let asked = Instant::now();
            while service::loaded_label(FINISHER_LABEL) && asked.elapsed() < Duration::from_secs(3) {
                std::thread::sleep(Duration::from_millis(100));
            }
        }
        std::fs::write(&plist, finisher_plist(program, args)).map_err(|e| format!("could not write {}: {e}", plist.display()))?;
        (domain, plist)
    };
    #[cfg(target_os = "linux")]
    let (domain, plist) = (String::new(), PathBuf::new());
    let Some((starter, starter_args)) = finisher_start(std::env::consts::OS, program, args, &domain, &plist) else {
        return Err("could not start the restart step: this system has no way to".into());
    };
    match tool(starter, &starter_args) {
        Ok((true, _)) => Ok(()),
        Ok((false, said)) => Err(format!("could not start the restart step ({starter} failed: {})", said.trim().chars().take(200).collect::<String>())),
        Err(e) => Err(format!("could not start the restart step: {e}")),
    }
}

/// Removes the job's file once the job runs. launchd has read it; the job itself stays loaded
/// until the next one unloads it or the user logs out, and is not started again.
pub(crate) fn forget_job(state_dir: &Path) {
    let _ = std::fs::remove_file(state_dir.join(FINISHER_PLIST));
}

/// `rex-duo-helper finish-update --version V --place PATH [--state-dir DIR] [--old-pid PID]`:
/// what the old program runs after a swap. Not for people.
pub fn finish_command(args: &[String]) -> i32 {
    let value = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
    let (Some(version), Some(path)) = (value("--version").filter(|v| Version::parse(v).is_some()), value("--place")) else {
        eprintln!("finish-update is run by {BEACON} itself");
        return 2;
    };
    let state_dir = value("--state-dir").map(PathBuf::from).unwrap_or_else(default_state_dir);
    let old_pid = value("--old-pid").and_then(|p| p.parse::<u64>().ok());
    if cfg!(target_os = "macos") {
        let _ = crate::util::log_to_file(crate::config::default_log_file());
        forget_job(&state_dir);
    }
    let Some(place) = Place::at(std::env::consts::OS, PathBuf::from(path)) else {
        eprintln!("finish-update has nothing to finish on this system");
        return 2;
    };
    // Released when this function returns, whether the update held or was rolled back.
    let _lock = UpdateLock::adopt(&state_dir);
    info!("update: restarting into {version}");
    let result = real_finish(&place, &version, old_pid);
    record_result(&state_dir, &version, &result);
    match &result {
        Ok(()) => info!("update: {BEACON} {version} is running"),
        Err(e) => info!("update: {e}"),
    }
    i32::from(result.is_err())
}

// MARK: When the next check is due

/// How a check ended, as the schedule sees it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Ended {
    /// The release list arrived and was accepted.
    #[default]
    Passed,
    /// The list or its signature could not be downloaded: no connection, a timeout, a 404, a
    /// 5xx. This can pass by itself, so it is tried again soon.
    Unreachable,
    /// The list arrived and did not pass its checks (signature, expiry, rollback). Only a
    /// newly published list changes that, so the normal schedule finds it.
    Refused,
}

impl Ended {
    /// What a check that ended with `error` counts as. A list that was accepted counts as
    /// passed even when it has no build for this computer.
    pub fn of(error: Option<Problem>) -> Ended {
        match error {
            Some(Problem::Unreachable) => Ended::Unreachable,
            Some(Problem::Rejected | Problem::Expired | Problem::Replayed) => Ended::Refused,
            _ => Ended::Passed,
        }
    }
}

/// The seconds from one check to the next: `base`, plus up to `spread` more picked at random,
/// so helpers don't all ask at once.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Wait {
    pub base: u64,
    pub spread: u64,
}

impl Wait {
    fn pick(self) -> u64 {
        self.base + random_below(self.spread)
    }
}

/// 12 hours, give or take half an hour.
pub const NORMAL_WAIT: Wait = Wait { base: 12 * 3600 - 1800, spread: 3600 };
/// After the first, second and third check in a row that could not reach the list: about 15
/// minutes, 1 hour and 3 hours.
pub const RETRY_WAITS: [Wait; 3] = [Wait { base: 15 * 60, spread: 2 * 60 }, Wait { base: 3600, spread: 5 * 60 }, Wait { base: 3 * 3600, spread: 15 * 60 }];

/// How long to wait after a check that ended as `ended`, the `failures`th in a row that could
/// not reach the list. From the fourth on, and after any other ending, the normal schedule.
pub fn next_wait(ended: Ended, failures: u32) -> Wait {
    match (ended, failures) {
        (Ended::Unreachable, n @ 1..=3) => RETRY_WAITS[n as usize - 1],
        _ => NORMAL_WAIT,
    }
}

/// The seconds left at `now` until a check is due `wait` seconds after the last one, which
/// ran at `checked` (None: no check ran yet). Never more than `wait`, whatever the clock says.
fn time_left(checked: Option<i64>, wait: u64, now: i64) -> u64 {
    let wait_s = i64::try_from(wait).unwrap_or(i64::MAX);
    checked.map_or(wait, |at| at.saturating_add(wait_s).saturating_sub(now).clamp(0, wait_s) as u64)
}

// MARK: A check from the command line
//
// `rex-duo-helper update` and `update --check` run in a process of their own, beside the
// service. When their check has ended they write how it ended to update_check.json in the
// state folder: one small file, readable by this user only, written whole to a temporary file
// and renamed into place, so a reader sees the previous result or the new one, never a part.
// The service reads the file when it answers `helper_status` and before each scheduled check,
// and takes the result when it is newer than its own last check: the status then says what
// the command found, and the schedule counts from that check. A file is the whole mechanism.
// The service listens on nothing for it, the command needs no running service, and the file
// holds only what `helper_status` shows to any client anyway.

/// What update_check.json holds.
#[derive(Clone, Debug, PartialEq)]
struct Reported {
    /// When the check ended, in seconds since 1970.
    at: i64,
    latest_version: Option<String>,
    min_version: Option<String>,
    manifest_expires_at: Option<i64>,
    /// Why the check failed, or None.
    error: Option<Problem>,
}

/// The problems a check can end with, which are the ones update_check.json may name.
const CHECK_PROBLEMS: [Problem; 5] = [Problem::Unreachable, Problem::Rejected, Problem::Expired, Problem::Replayed, Problem::NoBuild];

impl Reported {
    fn json(&self) -> Value {
        json!({
            "checked_at": iso8601(self.at),
            "latest_version": self.latest_version,
            "min_version": self.min_version,
            "manifest_expires_at": self.manifest_expires_at.map(iso8601),
            "error": self.error.map(Problem::sentence),
        })
    }

    /// Reads the file's contents. Every field has to be what `json` writes: a time as
    /// `iso8601` spells it, a version, one of the sentences of `CHECK_PROBLEMS`, or null.
    fn parse(data: &[u8]) -> Option<Reported> {
        let v: Value = serde_json::from_slice(data).ok()?;
        // Some(None) for null or absent, Some(Some(text)) for a string, None for anything else.
        let text = |key: &str| match v.get(key) {
            None | Some(Value::Null) => Some(None),
            Some(x) => x.as_str().map(Some),
        };
        let version = |key: &str| match text(key)? {
            None => Some(None),
            Some(s) => Version::parse(s).map(|_| Some(s.to_string())),
        };
        let at = parse_iso8601(v.str("checked_at")?)?;
        let manifest_expires_at = match text("manifest_expires_at")? {
            None => None,
            Some(s) => Some(parse_iso8601(s)?),
        };
        let error = match text("error")? {
            None => None,
            Some(s) => Some(CHECK_PROBLEMS.into_iter().find(|p| p.sentence() == s)?),
        };
        let r = Reported { at, latest_version: version("latest_version")?, min_version: version("min_version")?, manifest_expires_at, error };
        // A check that passed names the version it found.
        (Ended::of(error) != Ended::Passed || r.latest_version.is_some()).then_some(r)
    }
}

/// The result in update_check.json, or None when there is no such file or it is not one this
/// program wrote: not a regular file, larger than `MAX_CHECK_FILE`, or with a field off.
fn read_check_file(state_dir: &Path) -> Option<Reported> {
    let path = state_dir.join(CHECK_FILE);
    let meta = std::fs::symlink_metadata(&path).ok()?;
    if !meta.is_file() || meta.len() > MAX_CHECK_FILE {
        return None;
    }
    Reported::parse(&std::fs::read(&path).ok()?)
}

// MARK: The updater

#[derive(Clone, Debug, Default)]
struct State {
    latest_version: Option<String>,
    /// The newest manifest's `min_version`.
    min_version: Option<String>,
    checked_at: Option<String>,
    /// When the last accepted manifest stops being valid, in seconds since 1970.
    manifest_expires_at: Option<i64>,
    last_error: Option<Problem>,
    updating: bool,
    /// A version that was installed, did not start and was rolled back. The timer leaves it
    /// alone; asking for an update tries it again.
    failed_version: Option<String>,
    /// When the first of the current run of failed checks ended, in seconds since 1970. None
    /// when the last check passed or none ran.
    failing_since: Option<i64>,
    /// How the last check ended.
    ended: Ended,
    /// How many checks in a row could not reach the list, the last one included.
    failures: u32,
}

impl State {
    /// When the last check ended, in seconds since 1970.
    fn last_check(&self) -> Option<i64> {
        self.checked_at.as_deref().and_then(parse_iso8601)
    }

    /// Notes a check that ended at `at` with `error`, or with none.
    fn checked(&mut self, at: i64, error: Option<Problem>) {
        self.checked_at = Some(iso8601(at));
        self.last_error = error.or(self.failed_version.as_ref().map(|_| Problem::RolledBack));
        self.ended = Ended::of(error);
        match self.ended {
            Ended::Passed => (self.failing_since, self.failures) = (None, 0),
            Ended::Unreachable => {
                self.failing_since.get_or_insert(at);
                self.failures = self.failures.saturating_add(1);
            }
            Ended::Refused => {
                self.failing_since.get_or_insert(at);
                self.failures = 0;
            }
        }
    }

    /// Takes over a check the command line ran. What it learned replaces what this helper
    /// knew, and the schedule starts again from it: the next check is a normal wait away.
    fn take(&mut self, r: Reported) {
        if r.latest_version.is_some() {
            (self.latest_version, self.min_version, self.manifest_expires_at) = (r.latest_version, r.min_version, r.manifest_expires_at);
        }
        self.checked(r.at, r.error);
        self.failures = 0;
    }

    /// What `checked` and the fields beside it say, as update_check.json holds it. None
    /// before any check.
    fn report(&self) -> Option<Reported> {
        Some(Reported {
            at: self.last_check()?,
            latest_version: self.latest_version.clone(),
            min_version: self.min_version.clone(),
            manifest_expires_at: self.manifest_expires_at,
            error: self.last_error.filter(|p| CHECK_PROBLEMS.contains(p)),
        })
    }
}

/// How an install ends for the process that runs it.
#[derive(Clone, Copy, PartialEq)]
pub enum Restart {
    /// From the running service: hand the restart to the old program outside the service.
    Detached,
    /// From `rex-duo-helper update` in a terminal: restart the service and wait here.
    Inline,
}

pub struct Updater {
    blocker: Option<String>,
    /// The keys compiled in, or why this build has none.
    keys: Result<Vec<[u8; 32]>, String>,
    place: Option<Place>,
    state_dir: PathBuf,
    /// Check on a timer and install what is found.
    auto: bool,
    state: Mutex<State>,
    /// What the release list has turned off (`Switches`), as read last from the state folder.
    disabled: Mutex<Vec<String>>,
    /// Called after the state changed (the relay rewrites status.json).
    on_change: Mutex<Option<Box<dyn Fn() + Send + Sync>>>,
}

/// True if a file can be created in `dir`.
fn can_write(dir: &Path) -> bool {
    let probe = dir.join(format!(".rex-duo-helper-probe-{}", std::process::id()));
    let ok = std::fs::OpenOptions::new().write(true).create_new(true).open(&probe).is_ok();
    let _ = std::fs::remove_file(&probe);
    ok
}

fn random_below(n: u64) -> u64 {
    let mut b = [0u8; 8];
    let _ = ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut b);
    u64::from_le_bytes(b) % n.max(1)
}

impl Updater {
    /// Looks at how this helper was built and where it runs from.
    pub fn new(dry_run: bool, auto: bool, state_dir: &Path) -> Arc<Updater> {
        let install = crate::config::home().join(".local/bin").join(service::NAME);
        let place = std::env::current_exe()
            .and_then(|p| p.canonicalize())
            .map_err(|e| format!("{BEACON} can't tell where it runs from ({e})."))
            .and_then(|exe| Place::detect(std::env::consts::OS, &exe, &install.canonicalize().unwrap_or(install)));
        let mut env = Env { dry_run, debug_build: cfg!(debug_assertions), keys: update_keys(UPDATE_KEY_FILE), place, service: true, writable: true };
        // The service and the folder are only looked at when nothing else rules an update out.
        if blocker(&env).is_none() {
            env.service = service::installed();
            env.writable = env.place.as_ref().is_ok_and(|p| can_write(p.dir()));
        }
        Updater::with_env(env, auto, state_dir)
    }

    pub fn with_env(env: Env, auto: bool, state_dir: &Path) -> Arc<Updater> {
        let blocker = blocker(&env);
        let mut state = State::default();
        if let Some(version) = failed_update(state_dir, VERSION) {
            state.failed_version = Some(version);
            state.last_error = Some(Problem::RolledBack);
        }
        let keys = match env.keys {
            Ok(keys) if !keys.is_empty() => Ok(keys),
            Ok(_) => Err(NO_KEY.to_string()),
            Err(why) => Err(format!("Updates are not set up in this build ({why}).")),
        };
        if keys.is_err() {
            // Nothing can be checked without a key, so say so where the app looks.
            state.last_error = Some(Problem::NotSetUp);
        }
        Arc::new(Updater {
            auto: auto && !env.dry_run && !env.debug_build && keys.is_ok(),
            blocker,
            keys,
            place: env.place.ok(),
            state_dir: state_dir.to_path_buf(),
            state: Mutex::new(state),
            disabled: Mutex::new(Switches::load(state_dir)),
            on_change: Mutex::new(None),
        })
    }

    /// True when the publisher has turned `feature` off (the release list's `disabled`), by
    /// the newest list this Beacon accepted that said anything, now or before a restart.
    pub fn disabled(&self, feature: &str) -> bool {
        self.disabled.lock().unwrap().iter().any(|name| name == feature)
    }

    /// Reads again what the state folder keeps as turned off: a check, here or from the
    /// command line, may have written it.
    fn reload_switches(&self) {
        *self.disabled.lock().unwrap() = Switches::load(&self.state_dir);
    }

    /// `reload_switches`, and everything that follows a change.
    #[cfg(test)]
    pub(crate) fn switches_changed(&self) {
        self.reload_switches();
        self.change(|_| {});
    }

    pub fn set_on_change(&self, f: impl Fn() + Send + Sync + 'static) {
        *self.on_change.lock().unwrap() = Some(Box::new(f));
    }

    fn change(&self, f: impl FnOnce(&mut State)) {
        f(&mut self.state.lock().unwrap());
        if let Some(notify) = self.on_change.lock().unwrap().as_ref() {
            notify();
        }
    }

    /// Why this helper can't replace itself, if it can't: the sentence for the app, and the
    /// details for the terminal and the log.
    pub fn blocker(&self) -> Option<Fault> {
        let detail = self.blocker.clone()?;
        Some(Fault::new(if self.keys.is_err() { Problem::NotSetUp } else { Problem::CannotUpdate }, detail))
    }

    /// The `helper_status` result. status.json carries the same fields.
    pub fn status(&self) -> Value {
        let s = self.state.lock().unwrap().clone();
        let newer = |v: &Option<String>| v.as_deref().is_some_and(|v| is_newer(v, VERSION) == Ok(true));
        json!({
            "version": VERSION,
            "latest_version": s.latest_version,
            "min_version": s.min_version,
            "update_available": newer(&s.latest_version),
            "update_required": newer(&s.min_version),
            "checked_at": s.checked_at,
            "manifest_expires_at": s.manifest_expires_at.map(iso8601),
            "updating": s.updating,
            "can_update": self.blocker.is_none(),
            "last_error": s.last_error.map(Problem::sentence),
            "failing_since": s.failing_since,
        })
    }

    /// Takes the result of a check the command line ran, when update_check.json holds one
    /// that is newer than this helper's own last check and not from the future. True if so.
    pub fn take_command_result(&self) -> bool {
        self.take_command_result_at(now() as i64)
    }

    fn take_command_result_at(&self, now: i64) -> bool {
        let Some(r) = read_check_file(&self.state_dir) else { return false };
        let own = self.state.lock().unwrap().last_check();
        if r.at > now || own.is_some_and(|own| r.at <= own) {
            return false;
        }
        // That check kept what its list turns off where this one reads it.
        self.reload_switches();
        self.change(|s| s.take(r));
        true
    }

    /// Writes this process's last check to update_check.json, for the running service. The
    /// command line calls it once its check has ended.
    fn report_check(&self) {
        if let Some(r) = self.state.lock().unwrap().report() {
            write_json(&self.state_dir.join(CHECK_FILE), &r.json());
        }
    }

    /// The signed manifest, believed only after `accept_manifest` said so.
    async fn latest_manifest(&self, builtin: Vec<[u8; 32]>) -> Result<Manifest, Fault> {
        let unreachable = |what: &str, e: String| Fault::new(Problem::Unreachable, format!("Could not get the update manifest{what}: {e}."));
        let data = fetch_small(RELEASES, MANIFEST_URL, MAX_MANIFEST).await.map_err(|e| unreachable("", e))?;
        let sig = fetch_small(RELEASES, &format!("{MANIFEST_URL}.sig"), MAX_SIGNATURE).await.map_err(|e| unreachable("'s signature", e))?;
        accept_and_remember(&self.state_dir, builtin, &data, &sig, now() as i64)
    }

    /// Gets the manifest now and says what it means for this helper. The only place that
    /// talks to the network before an install.
    pub async fn check(&self) -> Result<Plan, Fault> {
        let builtin = self.keys.clone().map_err(|why| Fault::new(Problem::NotSetUp, why))?;
        let latest = self.latest_manifest(builtin).await;
        self.took(latest)
    }

    /// What follows the fetch in `check`: `latest` is the list as `accept_and_remember` gave
    /// it. What the list turns off is read again before anyone is told of the change, so
    /// whoever follows this (`set_on_change`) acts on it within the same check. A list that
    /// was not had or not accepted leaves that as it was.
    fn took(&self, latest: Result<Manifest, Fault>) -> Result<Plan, Fault> {
        self.reload_switches();
        match latest {
            Ok(m) => {
                let plan = plan(&m, VERSION, platform_key(std::env::consts::OS, std::env::consts::ARCH)).map_err(|e| Fault::new(Problem::NoBuild, e));
                note_expiry(m.expires_at, now() as i64);
                // The version is known even when this platform has no file for it.
                self.change(|s| {
                    s.manifest_expires_at = Some(m.expires_at);
                    s.latest_version = Some(m.version.clone());
                    s.min_version = Some(m.min_version.clone());
                    s.checked(now() as i64, plan.as_ref().err().map(|f| f.problem));
                });
                plan
            }
            Err(e) => {
                info!("update: {e}");
                self.change(|s| s.checked(now() as i64, Some(e.problem)));
                Err(e)
            }
        }
    }

    /// The version being installed right now, if one is.
    pub fn updating(&self) -> Option<String> {
        let s = self.state.lock().unwrap();
        s.updating.then(|| s.latest_version.clone().unwrap_or_default())
    }

    /// Downloads, checks and swaps in `version`, then restarts into it. With
    /// `Restart::Detached` this returns once the old program has been started to do the
    /// restart; this process ends moments later. With `Restart::Inline` it returns when the new
    /// version runs, or after the old one was put back.
    ///
    /// However it ends, nothing is left that would stop the next attempt: the lock is released
    /// here or by the old program, and `updating` goes back to false.
    pub async fn install(&self, version: &str, asset: &Asset, restart: Restart) -> Result<(), Fault> {
        if let Some(why) = self.blocker() {
            return Err(why);
        }
        let builtin = self.keys.clone().map_err(|why| Fault::new(Problem::NotSetUp, why))?;
        let Some(place) = self.place.clone() else { return Err(Fault::new(Problem::CannotUpdate, concat!(crate::beacon_name!(), " can't tell where it is installed."))) };
        {
            let mut s = self.state.lock().unwrap();
            if s.updating {
                return Err(Fault::new(Problem::Busy, "An update is already running."));
            }
            s.updating = true;
        }
        self.change(|_| {});
        info!("update: installing {BEACON} {version}");
        let mut result = self.install_locked(&place, builtin, version, asset, restart).await;
        if result.is_ok() && restart == Restart::Detached {
            // The old program restarts this service within seconds. Still here much later: it
            // didn't. If it never even took over the lock, it never ran, and the new version
            // sits where the service would start it unwatched. Put the old one back.
            tokio::time::sleep(Duration::from_secs(90)).await;
            let mut detail = format!("Version {version} was swapped in, but {BEACON} was not restarted into it.");
            if UpdateLock::take_back(&self.state_dir) {
                match roll_back(&place) {
                    Ok(()) => detail += " The previous version was put back.",
                    Err(e) => detail += &format!(" The previous version could not be put back: {e}."),
                }
            }
            result = Err(Fault::new(Problem::NotRestarted, detail));
        }
        if let Err(e) = &result {
            info!("update: {e}");
        }
        self.change(|s| {
            s.updating = false;
            if let Err(e) = &result {
                s.last_error = Some(e.problem);
            }
        });
        result
    }

    async fn install_locked(&self, place: &Place, builtin: Vec<[u8; 32]>, version: &str, asset: &Asset, restart: Restart) -> Result<(), Fault> {
        let lock = UpdateLock::acquire(&self.state_dir, crate::platform::process_alive).map_err(|e| Fault::new(Problem::Busy, e))?;
        let trusted = load_trust(&self.state_dir, builtin).keys();
        let platform = platform_key(std::env::consts::OS, std::env::consts::ARCH).unwrap_or_default();
        stage_and_swap(RELEASES, place, trusted, version, platform, asset).await?;
        match restart {
            Restart::Detached => {
                if let Err(e) = spawn_finisher(place, version, &self.state_dir) {
                    let back = roll_back(place).err().map(|b| format!(" (and the previous version could not be put back: {b})")).unwrap_or_default();
                    return Err(Fault::new(Problem::Install, format!("{e}{back}")));
                }
                lock.hand_over();
                Ok(())
            }
            Restart::Inline => {
                let (place, version, state_dir) = (place.clone(), version.to_string(), self.state_dir.clone());
                let done = tokio::task::spawn_blocking(move || {
                    let r = real_finish(&place, &version, service::running().map(|r| r.pid));
                    record_result(&state_dir, &version, &r);
                    r
                });
                let result = done.await.map_err(|e| Fault::new(Problem::Install, e.to_string()))?;
                drop(lock);
                result.map_err(|e| Fault::new(Problem::RolledBack, e))
            }
        }
    }

    /// Checks at start plus up to 10 minutes, then about every 12 hours, and installs what it
    /// finds. After a check that could not reach the list the next ones come sooner
    /// (`next_wait`). Does nothing when `auto_update` is off, in a dry run, in a debug build,
    /// or without an update key.
    pub async fn run_timer(self: Arc<Self>) {
        if !self.auto {
            return;
        }
        tokio::time::sleep(Duration::from_secs(random_below(600))).await;
        loop {
            self.check_and_install().await;
            // The wait counts from the last check, whoever ran it. One that the app asked for
            // or the command line ran during the wait starts a new wait from its own time.
            loop {
                let (checked, wait) = self.schedule();
                tokio::time::sleep(Duration::from_secs(time_left(checked, wait.pick(), now() as i64))).await;
                self.take_command_result();
                if self.schedule().0 == checked {
                    break;
                }
            }
        }
    }

    /// When the last check ended, and the wait that follows it.
    fn schedule(&self) -> (Option<i64>, Wait) {
        let s = self.state.lock().unwrap();
        (s.last_check(), next_wait(s.ended, s.failures))
    }

    async fn check_and_install(&self) {
        let Ok(Plan::Update { version, asset }) = self.check().await else { return };
        if self.blocker.is_some() || self.state.lock().unwrap().failed_version.as_deref() == Some(version.as_str()) {
            return;
        }
        // On success the old program restarts this service within seconds.
        let _ = self.install(&version, &asset, Restart::Detached).await;
    }
}

/// `rex-duo-helper update [--check]`.
pub async fn cli(check_only: bool) -> i32 {
    let updater = Updater::new(false, false, &default_state_dir());
    println!("{BEACON} {VERSION}");
    let checked = updater.check().await;
    // The running service takes the result from here (see "A check from the command line").
    updater.report_check();
    let (version, asset) = match checked {
        Err(e) => {
            eprintln!("{e}");
            return 1;
        }
        Ok(Plan::UpToDate) => {
            println!("This is the latest version.");
            return 0;
        }
        Ok(Plan::Update { version, asset }) => (version, asset),
    };
    if check_only {
        println!("Version {version} is available. To install it: rex-duo-helper update");
        return 0;
    }
    if let Some(why) = updater.blocker() {
        eprintln!("Version {version} is available, but this copy can't update itself. {why}");
        return 1;
    }
    println!("Downloading and checking version {version}...");
    match updater.install(&version, &asset, Restart::Inline).await {
        Ok(()) => {
            println!("{BEACON} {version} is running. The previous version was removed.");
            0
        }
        Err(e) => {
            eprintln!("The update failed. {e}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::net::testing::{canned, serve, Canned};
    use crate::util::base64url;
    use ring::signature::{Ed25519KeyPair, KeyPair};

    /// A key pair made for this test run. Never a real key.
    fn keypair() -> (Ed25519KeyPair, [u8; 32]) {
        let pkcs8 = Ed25519KeyPair::generate_pkcs8(&ring::rand::SystemRandom::new()).unwrap();
        let pair = Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap();
        let public = pair.public_key().as_ref().try_into().unwrap();
        (pair, public)
    }

    fn sign(pair: &Ed25519KeyPair, message: &[u8]) -> Vec<u8> {
        format!("{}\n", base64url(pair.sign(message).as_ref())).into_bytes()
    }

    /// 2026-11-17T12:00:00Z, the `released_at` of the manifests below. They expire a year on.
    const RELEASED: i64 = 1_794_916_800;
    const EXPIRES: i64 = RELEASED + 365 * 86_400;

    fn sha256(data: &[u8]) -> String {
        hex(ring::digest::digest(&ring::digest::SHA256, data).as_ref())
    }

    fn manifest_json(version: &str) -> String {
        let base = format!("{RELEASE_PREFIX}helper-v{version}");
        json!({
            "version": version, "min_version": "0.3.0", "released_at": iso8601(RELEASED), "expires_at": iso8601(EXPIRES), "next_key": null,
            "assets": {
                "macos-universal": {"url": format!("{base}/Rex.DUO.Helper.zip"), "sha256": "AB".repeat(32), "size": 123},
                "linux-x86_64": {"url": format!("{base}/rex-duo-helper-linux-x86_64"), "sha256": "cd".repeat(32), "size": 456},
                "linux-aarch64": {"url": format!("{base}/rex-duo-helper-linux-aarch64"), "sha256": "ef".repeat(32), "size": 789}
            }
        })
        .to_string()
    }

    fn temp(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("update-{tag}-{}-{}", std::process::id(), crate::util::now()));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        p
    }

    #[test]
    fn versions() {
        assert_eq!(Version::parse("0.3.0"), Some(Version(0, 3, 0)));
        assert_eq!(Version::parse("12.0.345"), Some(Version(12, 0, 345)));
        for bad in ["", "1", "1.2", "1.2.3.4", "v1.2.3", "1.2.3-beta", "1.2.x", "1..3", "01.2.3", "1.2.3 ", " 1.2.3", "1.2.-3", "1.2.+3", "1.2.99999999999999999999"] {
            assert_eq!(Version::parse(bad), None, "{bad:?}");
        }
        assert_eq!(is_newer("0.3.1", "0.3.0"), Ok(true));
        assert_eq!(is_newer("0.10.0", "0.9.9"), Ok(true));
        assert_eq!(is_newer("1.0.0", "0.99.99"), Ok(true));
        assert_eq!(is_newer("0.3.0", "0.3.0"), Ok(false));
        assert_eq!(is_newer("0.2.9", "0.3.0"), Ok(false));
        assert!(is_newer("9.9", "0.3.0").is_err());
        assert!(is_newer("latest", "0.3.0").is_err());
        assert!(is_newer("0.3.1", "dev").is_err());
    }

    #[test]
    fn asset_for_each_platform() {
        assert_eq!(platform_key("macos", "aarch64"), Some("macos-universal"));
        assert_eq!(platform_key("macos", "x86_64"), Some("macos-universal"));
        assert_eq!(platform_key("linux", "x86_64"), Some("linux-x86_64"));
        assert_eq!(platform_key("linux", "aarch64"), Some("linux-aarch64"));
        assert_eq!(platform_key("linux", "riscv64"), None);
        assert_eq!(platform_key("windows", "x86_64"), None);
        let m = Manifest::parse(manifest_json("0.3.1").as_bytes()).unwrap();
        let Plan::Update { version, asset } = plan(&m, "0.3.0", Some("linux-aarch64")).unwrap() else { panic!("expected an update") };
        assert_eq!(version, "0.3.1");
        assert!(asset.url.ends_with("/helper-v0.3.1/rex-duo-helper-linux-aarch64"));
        assert_eq!((asset.size, asset.sha256.as_str()), (789, "ef".repeat(32).as_str()));
        let Plan::Update { asset, .. } = plan(&m, "0.3.0", Some("macos-universal")).unwrap() else { panic!("expected an update") };
        assert_eq!(asset.sha256, "ab".repeat(32), "hashes compare in lowercase");
    }

    #[test]
    fn only_a_strictly_newer_version_is_an_update() {
        let m = Manifest::parse(manifest_json("0.3.1").as_bytes()).unwrap();
        assert_eq!(plan(&m, "0.3.1", Some("linux-x86_64")), Ok(Plan::UpToDate));
        assert_eq!(plan(&m, "0.4.0", Some("linux-x86_64")), Ok(Plan::UpToDate));
        // Up to date wins over "no build for this computer".
        assert_eq!(plan(&m, "0.3.1", None), Ok(Plan::UpToDate));
        assert!(plan(&m, "0.3.0", None).unwrap_err().contains("no build"));
        assert!(plan(&m, "0.3.0", Some("linux-riscv64")).is_err());
        assert!(plan(&m, "nonsense", Some("linux-x86_64")).is_err());
    }

    #[test]
    fn only_release_addresses() {
        assert!(release_url_ok("https://github.com/theabecaster/rexduo/releases/download/helper-v0.3.0/Rex.DUO.Helper.zip"));
        assert!(release_url_ok(MANIFEST_URL));
        assert!(release_url_ok(&format!("{MANIFEST_URL}.sig")));
        for bad in [
            "",
            "https://github.com/theabecaster/rexduo/releases/download/",
            "http://github.com/theabecaster/rexduo/releases/download/helper-v0.3.0/x",
            "https://github.com/theabecaster/rexduo/releases/downloads/helper-v0.3.0/x",
            "https://github.com/someone-else/rexduo/releases/download/helper-v0.3.0/x",
            "https://github.com/theabecaster/rexduo-evil/releases/download/helper-v0.3.0/x",
            "https://github.com.evil.example/theabecaster/rexduo/releases/download/helper-v0.3.0/x",
            "https://evil.example/https://github.com/theabecaster/rexduo/releases/download/helper-v0.3.0/x",
            "https://github.com/theabecaster/rexduo/releases/download/../../../../evil/repo/releases/download/v1/x",
            "https://github.com/theabecaster/rexduo/releases/download/helper-v0.3.0//x",
            "https://github.com/theabecaster/rexduo/releases/download//x",
            "https://github.com/theabecaster/rexduo/releases/download/helper-v0.3.0/x?y=1",
            "https://github.com/theabecaster/rexduo/releases/download/helper-v0.3.0/x#y",
            "https://github.com/theabecaster/rexduo/releases/download/helper-v0.3.0/%2e%2e/x",
            "https://github.com/theabecaster/rexduo/releases/download/helper-v0.3.0/x y",
            " https://github.com/theabecaster/rexduo/releases/download/helper-v0.3.0/x",
            "HTTPS://GITHUB.COM/theabecaster/rexduo/releases/download/helper-v0.3.0/x",
        ] {
            assert!(!release_url_ok(bad), "{bad}");
        }
    }

    #[test]
    fn a_manifest_with_anything_off_is_refused() {
        let good: Value = serde_json::from_str(&manifest_json("0.3.1")).unwrap();
        assert_eq!(Manifest::parse(good.to_string().as_bytes()).unwrap().assets.len(), 3);
        let broken = |edit: &dyn Fn(&mut Value)| {
            let mut v = good.clone();
            edit(&mut v);
            Manifest::parse(v.to_string().as_bytes())
        };
        assert!(broken(&|v| v["version"] = json!("0.3")).is_err());
        assert!(broken(&|v| v["version"] = json!(3)).is_err());
        assert!(broken(&|v| v["assets"] = json!([])).is_err());
        // One bad address spoils the manifest, whichever platform it is for.
        assert!(broken(&|v| v["assets"]["linux-aarch64"]["url"] = json!("https://example.com/rex-duo-helper")).is_err());
        assert!(broken(&|v| v["assets"]["macos-universal"]["url"] = json!("http://github.com/theabecaster/rexduo/releases/download/a/b")).is_err());
        assert!(broken(&|v| v["assets"]["linux-x86_64"]["sha256"] = json!("abc")).is_err());
        assert!(broken(&|v| v["assets"]["linux-x86_64"]["sha256"] = json!("zz".repeat(32))).is_err());
        assert!(broken(&|v| v["assets"]["linux-x86_64"]["size"] = json!(0)).is_err());
        assert!(broken(&|v| v["assets"]["linux-x86_64"]["size"] = json!(MAX_ASSET + 1)).is_err());
        assert!(broken(&|v| v["assets"]["linux-x86_64"]["size"] = json!("456")).is_err());
        assert!(broken(&|v| v["assets"]["linux-x86_64"]["size"] = json!(-1)).is_err());
        assert!(Manifest::parse(b"not json").is_err());

        // The fields that guard against replay and downgrade are required and strict.
        let m = Manifest::parse(good.to_string().as_bytes()).unwrap();
        assert_eq!((m.min_version.as_str(), m.expires_at, m.next_key), ("0.3.0", EXPIRES, None));
        let drop = |key: &'static str| move |v: &mut Value| drop(v.as_object_mut().unwrap().remove(key));
        assert!(broken(&drop("expires_at")).unwrap_err().contains("expires_at"));
        assert!(broken(&drop("min_version")).unwrap_err().contains("min_version"));
        // `next_key` may be left out or null. Anything else must be a key.
        assert_eq!(broken(&drop("next_key")).unwrap().next_key, None);
        for bad in [json!("2027-11-17"), json!("2027-11-17T12:00:00+00:00"), json!("2027-11-17 12:00:00Z"), json!("never"), json!(1_826_452_800), Value::Null] {
            assert!(broken(&|v| v["expires_at"] = bad.clone()).is_err(), "expires_at {bad}");
        }
        for bad in [json!("0.3"), json!("latest"), json!(3), Value::Null, json!("0.3.2"), json!("1.0.0")] {
            assert!(broken(&|v| v["min_version"] = bad.clone()).is_err(), "min_version {bad}");
        }
        assert_eq!(broken(&|v| v["min_version"] = json!("0.3.1")).unwrap().min_version, "0.3.1");
        let (_, key) = keypair();
        assert_eq!(broken(&|v| v["next_key"] = json!(base64(&key))).unwrap().next_key, Some(key));
        for bad in [json!(""), json!("AAAA"), json!(base64(&[0u8; 32])), json!(base64(&[1u8; 31])), json!(base64(&[1u8; 33])), json!(base64url(&key)), json!(7), json!([base64(&key)]), json!(false)] {
            assert!(broken(&|v| v["next_key"] = bad.clone()).unwrap_err().contains("next_key"), "next_key {bad}");
        }
    }

    #[test]
    fn manifest_signature() {
        let (pair, public) = keypair();
        let manifest = manifest_json("0.3.1").into_bytes();
        let sig = sign(&pair, &manifest);
        assert_eq!(verify_signatures(&[public], &manifest, &sig), Ok(()));
        // Standard base64 with padding, as `openssl base64` writes it, is the same signature.
        let standard = String::from_utf8(sig.clone()).unwrap().trim().replace('-', "+").replace('_', "/") + "==";
        assert_eq!(verify_signatures(&[public], &manifest, standard.as_bytes()), Ok(()));

        // Tampered: one byte of the manifest changed (0.3.1 -> 0.3.2).
        let tampered = String::from_utf8(manifest.clone()).unwrap().replace("\"version\":\"0.3.1\"", "\"version\":\"0.3.2\"").into_bytes();
        assert_ne!(tampered, manifest);
        assert_eq!(verify_signatures(&[public], &tampered, &sig).unwrap_err(), "the signature is not from a key this helper trusts");

        // Signed with another key.
        let (other, other_public) = keypair();
        assert!(verify_signatures(&[public], &manifest, &sign(&other, &manifest)).is_err());
        assert!(verify_signatures(&[other_public], &manifest, &sig).is_err());
        // No trusted key at all accepts nothing.
        assert!(verify_signatures(&[], &manifest, &sig).is_err());

        // Not a signature at all.
        for junk in [&b""[..], b"AAAA", b"not base64 !!", b"\n\n", &[0xff, 0xfe][..]] {
            assert_eq!(verify_signatures(&[public], &manifest, junk).unwrap_err(), "the signature is malformed");
        }
        // The all-zero placeholder key verifies nothing, and is never used anyway.
        assert!(verify_signatures(&[[0u8; 32]], &manifest, &sig).is_err());
    }

    #[test]
    fn one_good_signature_from_any_trusted_key_is_enough() {
        let (primary, primary_public) = keypair();
        let (recovery, recovery_public) = keypair();
        let (stranger, _) = keypair();
        let trusted = [primary_public, recovery_public];
        let manifest = manifest_json("0.3.1").into_bytes();
        let line = |pair: &Ed25519KeyPair| String::from_utf8(sign(pair, &manifest)).unwrap();
        // Each key alone.
        assert_eq!(verify_signatures(&trusted, &manifest, line(&primary).as_bytes()), Ok(()));
        assert_eq!(verify_signatures(&trusted, &manifest, line(&recovery).as_bytes()), Ok(()));
        assert!(verify_signatures(&trusted, &manifest, line(&stranger).as_bytes()).is_err());
        // Several lines: a stranger's signature and junk beside a good one do no harm, in any
        // order, with blank lines and Windows line ends.
        let files = [
            format!("{}{}", line(&stranger), line(&recovery)),
            format!("{}{}", line(&primary), line(&stranger)),
            format!("not a signature\n\n{}\n", line(&primary).trim()),
            format!("{}\r\n{}\r\n", line(&stranger).trim(), line(&primary).trim()),
        ];
        for file in &files {
            assert_eq!(verify_signatures(&trusted, &manifest, file.as_bytes()), Ok(()), "{file:?}");
        }
        // Only strangers and junk: refused.
        let bad = format!("{}not a signature\n{}", line(&stranger), line(&stranger));
        assert!(verify_signatures(&trusted, &manifest, bad.as_bytes()).is_err());
        // A good signature over another message is not one for this.
        let other = sign(&primary, b"something else");
        assert!(verify_signatures(&trusted, &manifest, &other).is_err());
        // A file stuffed with lines is read only so far.
        let buried = format!("{}{}", line(&stranger).repeat(8), line(&primary));
        assert!(verify_signatures(&trusted, &manifest, buried.as_bytes()).is_err());
    }

    fn signed(pair: &Ed25519KeyPair, edit: &dyn Fn(&mut Value), version: &str) -> (Vec<u8>, Vec<u8>) {
        let mut v: Value = serde_json::from_str(&manifest_json(version)).unwrap();
        edit(&mut v);
        let data = v.to_string().into_bytes();
        let sig = sign(pair, &data);
        (data, sig)
    }

    #[test]
    fn an_expired_or_replayed_manifest_is_refused() {
        let (pair, public) = keypair();
        let (data, sig) = signed(&pair, &|_| {}, "0.3.1");
        let accept = |high: Option<&str>, now: i64| accept_manifest(&data, &sig, &[public], high.and_then(Version::parse), now);
        assert_eq!(accept(None, RELEASED).unwrap().version, "0.3.1");
        // Up to the second before it expires, and not from that second on.
        assert!(accept(None, EXPIRES - 1).is_ok());
        for now in [EXPIRES, EXPIRES + 1, EXPIRES + 10 * 365 * 86_400] {
            let e = accept(None, now).unwrap_err();
            assert_eq!(e.problem, Problem::Expired);
            assert_eq!(e.problem.sentence(), "The release list is out of date.");
        }
        // The same or a higher version than the highest seen is fine; a lower one is an old
        // list played back.
        assert!(accept(Some("0.3.0"), RELEASED).is_ok());
        assert!(accept(Some("0.3.1"), RELEASED).is_ok());
        for high in ["0.3.2", "0.4.0", "1.0.0"] {
            assert_eq!(accept(Some(high), RELEASED).unwrap_err().problem, Problem::Replayed, "{high}");
        }
        // The signature comes first: an unsigned list is rejected whatever else it says.
        let (other, _) = keypair();
        let unsigned = accept_manifest(&data, &sign(&other, &data), &[public], None, RELEASED).unwrap_err();
        assert_eq!(unsigned.problem, Problem::Rejected);
        assert_eq!(accept_manifest(&data, &sign(&other, &data), &[public], None, EXPIRES + 1).unwrap_err().problem, Problem::Rejected);
        // Signed, but not a manifest this helper can read.
        let (junk, junk_sig) = signed(&pair, &|v| v["expires_at"] = json!("soon"), "0.3.1");
        assert_eq!(accept_manifest(&junk, &junk_sig, &[public], None, RELEASED).unwrap_err().problem, Problem::Rejected);
    }

    #[test]
    fn a_list_with_fields_this_helper_does_not_know_is_read_as_before() {
        let mut v: Value = serde_json::from_str(&manifest_json("0.4.0")).unwrap();
        v["desk"] = json!("on");
        v["presence"] = json!({"anything": [1, 2]});
        v["a_later_field"] = json!("whatever");
        let m = Manifest::parse(v.to_string().as_bytes()).unwrap();
        let plain = Manifest::parse(manifest_json("0.4.0").as_bytes()).unwrap();
        // A list signed with the field of the desk switch that never shipped reads as one without.
        assert_eq!(m, plain);
        assert_eq!((&plain.disabled, plain.signed_at), (&None, None));
        // What is turned off, and when the list was signed, are read when they are what
        // they should be; anything else there leaves the rest of the list as it is.
        v["disabled"] = json!(["port_share", "something_later"]);
        v["signed_at"] = json!(iso8601(RELEASED));
        let m = Manifest::parse(v.to_string().as_bytes()).unwrap();
        assert_eq!((m.disabled.as_deref(), m.signed_at), (Some(&["port_share".to_string(), "something_later".to_string()][..]), Some(RELEASED)));
        assert_eq!(Manifest { disabled: None, signed_at: None, ..m }, plain);
        v["disabled"] = json!([]);
        assert_eq!(Manifest::parse(v.to_string().as_bytes()).unwrap().disabled, Some(vec![]));
        let long = "x".repeat(MAX_FEATURE_NAME + 1);
        for odd in [json!("port_share"), json!({"port_share": true}), json!(["port_share", 1]), json!(["Port Share"]), json!([""]), json!([long]), json!(vec!["a"; MAX_DISABLED + 1]), Value::Null] {
            v["disabled"] = odd.clone();
            v["signed_at"] = json!("yesterday");
            let m = Manifest::parse(v.to_string().as_bytes()).unwrap();
            assert_eq!(m, plain, "{odd}");
        }
    }

    /// The list as every released Beacon reads it: `Manifest` and `Manifest::parse` as they
    /// are in the release tagged helper-v0.6.0, letter for letter. Between helper-v0.3.0 and
    /// that release the function differs by one comment, and `accept_manifest`,
    /// `verify_signatures`, `release_url_ok`, `key_from_base64` and `parse_iso8601` not at all.
    mod released {
        use super::super::*;

        #[derive(Clone, Debug, PartialEq)]
        pub struct Manifest {
            pub version: String,
            pub min_version: String,
            pub expires_at: i64,
            pub next_key: Option<[u8; 32]>,
            pub assets: BTreeMap<String, Asset>,
        }

        impl Manifest {
        pub fn parse(data: &[u8]) -> Result<Manifest, String> {
            let v: Value = serde_json::from_slice(data).map_err(|_| "the update manifest is not JSON")?;
            let version = v.str("version").filter(|s| Version::parse(s).is_some()).ok_or("the update manifest has no valid version")?;
            let min_version = v.str("min_version").filter(|s| Version::parse(s).is_some()).ok_or("the update manifest has no valid min_version")?;
            // A release can't require more than itself: no helper could ever satisfy it.
            if Version::parse(min_version) > Version::parse(version) {
                return Err("the update manifest's min_version is newer than its version".into());
            }
            let expires_at = v.str("expires_at").and_then(parse_iso8601).ok_or("the update manifest has no valid expires_at")?;
            let next_key = match v.get("next_key") {
                None | Some(Value::Null) => None,
                Some(k) => Some(k.as_str().and_then(key_from_base64).ok_or("the update manifest's next_key is not a key")?),
            };
            let mut assets = BTreeMap::new();
            for (name, a) in v.get("assets").and_then(Value::as_object).ok_or("the update manifest lists no files")? {
                let url = a.str("url").filter(|u| release_url_ok(u)).ok_or_else(|| format!("the update manifest's {} address is not allowed", clip(name)))?;
                let sha256 = a
                    .str("sha256")
                    .filter(|h| h.len() == 64 && h.bytes().all(|b| b.is_ascii_hexdigit()))
                    .ok_or_else(|| format!("the update manifest's {} hash is malformed", clip(name)))?;
                let size = a
                    .get("size")
                    .and_then(Value::as_u64)
                    .filter(|n| (1..=MAX_ASSET).contains(n))
                    .ok_or_else(|| format!("the update manifest's {} size is not allowed", clip(name)))?;
                assets.insert(name.clone(), Asset { url: url.into(), sha256: sha256.to_ascii_lowercase(), size });
            }
            // A field this helper doesn't know (such as `desk` and `signed_at`, which no released
            // helper reads) never spoils the list.
            Ok(Manifest { version: version.into(), min_version: min_version.into(), expires_at, next_key, assets })
        }
        }
    }

    #[test]
    fn released_beacons_read_a_list_that_turns_something_off_as_they_read_any_other() {
        let (pair, public) = keypair();
        // As release.sh writes it: one field per line, the new ones among the rest.
        let mut v: Value = serde_json::from_str(&manifest_json("0.7.0")).unwrap();
        v["disabled"] = json!(["port_share"]);
        v["signed_at"] = json!(iso8601(RELEASED + 60));
        let data = format!("{}\n", serde_json::to_string_pretty(&v).unwrap()).into_bytes();
        let sig = sign(&pair, &data);
        // The signature is over the file's bytes as they were fetched, whatever they hold.
        assert!(verify_signatures(&[public], &data, &sig).is_ok());
        // The released reader takes each field by its name and leaves the rest.
        let old = released::Manifest::parse(&data).expect("a released Beacon reads the list");
        let plain = released::Manifest::parse(manifest_json("0.7.0").as_bytes()).unwrap();
        assert_eq!(old, plain);
        // And it is the list this Beacon reads, with what is turned off besides.
        let new = accept_manifest(&data, &sig, &[public], Version::parse("0.6.0"), RELEASED).unwrap();
        assert_eq!((&new.version, &new.min_version, new.expires_at, new.next_key, &new.assets), (&old.version, &old.min_version, old.expires_at, old.next_key, &old.assets));
        assert_eq!(new.disabled, Some(vec!["port_share".to_string()]));
    }

    #[test]
    fn what_the_list_turns_off_follows_the_newest_accepted_list_that_says_so() {
        let (pair, public) = keypair();
        let (stranger, _) = keypair();
        let dir = temp("switches");
        let off = || Switches::load(&dir);
        // A list of `version`, signed by `by` `after` seconds after RELEASED when given,
        // with `disabled` when given; accepted at `now`.
        let accept = |by: &Ed25519KeyPair, disabled: Option<Value>, after: Option<i64>, version: &str, now: i64| {
            let (data, sig) = signed(
                by,
                &|v| {
                    if let Some(d) = &disabled {
                        v["disabled"] = d.clone();
                    }
                    if let Some(t) = after {
                        v["signed_at"] = json!(iso8601(RELEASED + t));
                    }
                },
                version,
            );
            accept_and_remember(&dir, vec![public], &data, &sig, now).map(|m| m.version)
        };
        let port_share = || Some(json!(["port_share"]));
        // Nothing was ever said: nothing is off, and nothing is kept.
        assert!(accept(&pair, None, None, "0.7.0", RELEASED).is_ok());
        assert!(off().is_empty() && !dir.join(SWITCHES_FILE).exists());
        // Turned off.
        assert!(accept(&pair, port_share(), Some(10), "0.7.0", RELEASED).is_ok());
        assert_eq!((off(), Switches::stored_at(&dir)), (vec!["port_share".to_string()], Some(RELEASED + 10)));
        // A list without the field (every list before this one, and a release made without
        // it), or with something else there, is taken as a list and changes nothing here.
        assert!(accept(&pair, None, None, "0.7.0", RELEASED).is_ok());
        assert!(accept(&pair, None, Some(99), "0.7.1", RELEASED).is_ok());
        for odd in [json!("off"), json!([1]), json!(["Port Share"])] {
            assert!(accept(&pair, Some(odd), Some(50), "0.7.1", RELEASED).is_ok());
        }
        assert_eq!(off(), ["port_share"]);
        // A list that is not accepted changes nothing: signed by a stranger, expired, or of
        // a version older than one already seen.
        assert_eq!(accept(&stranger, Some(json!([])), Some(60), "0.7.1", RELEASED).unwrap_err().problem, Problem::Rejected);
        assert_eq!(accept(&pair, Some(json!([])), Some(60), "0.7.1", EXPIRES).unwrap_err().problem, Problem::Expired);
        assert_eq!(accept(&pair, Some(json!([])), Some(60), "0.7.0", RELEASED).unwrap_err().problem, Problem::Replayed);
        assert_eq!(off(), ["port_share"]);
        // An accepted list that was signed before the one that turned it off, or at the same
        // moment, or that does not say when: an older copy played back turns nothing on.
        for earlier in [Some(5), Some(10), None] {
            assert!(accept(&pair, Some(json!([])), earlier, "0.7.1", RELEASED).is_ok(), "{earlier:?}");
            assert_eq!((off(), Switches::stored_at(&dir)), (vec!["port_share".to_string()], Some(RELEASED + 10)), "{earlier:?}");
        }
        // One signed later does. A name this Beacon doesn't know is kept and harms nothing.
        assert!(accept(&pair, Some(json!(["something_later"])), Some(20), "0.7.1", RELEASED).is_ok());
        assert_eq!((off(), Switches::stored_at(&dir)), (vec!["something_later".to_string()], Some(RELEASED + 20)));
        assert!(accept(&pair, Some(json!([])), Some(30), "0.7.1", RELEASED).is_ok());
        assert!(off().is_empty());
        // And the older "off" can't come back over it either.
        assert!(accept(&pair, port_share(), Some(10), "0.7.1", RELEASED).is_ok());
        assert!(off().is_empty());
        // A file someone damaged counts as nothing kept.
        std::fs::write(dir.join(SWITCHES_FILE), "{\"disabled\": \"all\"}").unwrap();
        assert!(off().is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_check_acts_on_what_its_list_turns_off_and_a_failed_one_keeps_what_was() {
        let (pair, public) = keypair();
        let dir = temp("switch-check");
        let env = || Env { dry_run: false, debug_build: true, keys: Ok(vec![public]), place: Err("test".into()), service: false, writable: false };
        let u = Updater::with_env(env(), false, &dir);
        assert!(!u.disabled("port_share"), "nothing ever verified: on");
        // Whoever follows the updater is told within the check, with the new state there to read.
        let seen = Arc::new(Mutex::new(vec![]));
        let (told, weak) = (seen.clone(), Arc::downgrade(&u));
        u.set_on_change(move || told.lock().unwrap().push(weak.upgrade().unwrap().disabled("port_share")));
        let list = |disabled: Value, after: i64| {
            let (data, sig) = signed(
                &pair,
                &|v| {
                    v["disabled"] = disabled.clone();
                    v["signed_at"] = json!(iso8601(RELEASED + after));
                },
                "0.7.0",
            );
            accept_and_remember(&dir, vec![public], &data, &sig, RELEASED)
        };
        let _ = u.took(list(json!(["port_share"]), 10));
        assert!(u.disabled("port_share") && !u.disabled("something_else"));
        assert_eq!(seen.lock().unwrap().last(), Some(&true));
        // The list can't be had (offline), or is not accepted: what was verified last stays.
        let _ = u.took(Err(Fault::new(Problem::Unreachable, "Could not get the update manifest.")));
        let _ = u.took(Err(Fault::new(Problem::Rejected, "The update manifest was not accepted.")));
        assert!(u.disabled("port_share"));
        assert_eq!(seen.lock().unwrap().as_slice(), [true, true, true]);
        // It holds across a restart, before any check.
        assert!(Updater::with_env(env(), false, &dir).disabled("port_share"));
        // A check the command line ran, in a process of its own, is taken the same way by
        // the service when it next looks.
        let service = Updater::with_env(env(), false, &dir);
        let command = Updater::with_env(env(), false, &dir);
        let _ = command.took(list(json!([]), 20));
        command.report_check();
        assert!(service.disabled("port_share"), "not before the service looks");
        assert!(service.take_command_result());
        assert!(!service.disabled("port_share"));
        let _ = u.took(list(json!([]), 30));
        assert!(!u.disabled("port_share") && !Updater::with_env(env(), false, &dir).disabled("port_share"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_high_water_mark_survives_a_restart() {
        let (pair, public) = keypair();
        let dir = temp("highwater");
        let accept = |version: &str| {
            let (data, sig) = signed(&pair, &|_| {}, version);
            accept_and_remember(&dir, vec![public], &data, &sig, RELEASED)
        };
        assert_eq!(load_high_water(&dir), None);
        assert!(accept("0.3.1").is_ok());
        assert_eq!(load_high_water(&dir), Version::parse("0.3.1"));
        assert!(accept("0.4.0").is_ok());
        // Each call reads the folder afresh, as a restarted helper would: the older list is
        // now refused, and being refused does not lower the mark.
        assert_eq!(accept("0.3.1").unwrap_err().problem, Problem::Replayed);
        assert_eq!(accept("0.3.9").unwrap_err().problem, Problem::Replayed);
        assert_eq!(load_high_water(&dir), Version::parse("0.4.0"));
        assert!(accept("0.4.0").is_ok());
        // A file someone damaged counts as no mark, not as an error.
        std::fs::write(dir.join(HIGH_WATER_FILE), "{\"version\": \"junk\"}").unwrap();
        assert_eq!(load_high_water(&dir), None);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn a_key_is_handed_over_only_by_a_trusted_manifest() {
        use std::os::unix::fs::PermissionsExt;
        let (primary, primary_public) = keypair();
        let (recovery, recovery_public) = keypair();
        let (next, next_public) = keypair();
        let (stranger, stranger_public) = keypair();
        let builtin = vec![primary_public, recovery_public];
        let dir = temp("handover");
        let accept = |pair: &Ed25519KeyPair, next_key: Option<[u8; 32]>, version: &str| {
            let (data, sig) = signed(pair, &|v| v["next_key"] = json!(next_key.map(|k| base64(&k))), version);
            accept_and_remember(&dir, builtin.clone(), &data, &sig, RELEASED)
        };

        // Before any handover the new key is a stranger's.
        assert_eq!(accept(&next, None, "0.3.1").unwrap_err().problem, Problem::Rejected);
        // A manifest nobody trusted can't introduce a key, its own or another.
        assert!(accept(&stranger, Some(stranger_public), "0.3.1").is_err());
        assert!(accept(&stranger, Some(next_public), "0.3.1").is_err());
        assert!(!dir.join(TRUSTED_KEYS_FILE).exists());
        assert!(accept(&stranger, None, "0.3.1").is_err());
        assert!(accept(&next, None, "0.3.1").is_err());

        // Both built-in keys are accepted; the recovery key hands over the next one.
        assert!(accept(&primary, None, "0.3.1").is_ok());
        assert!(accept(&recovery, Some(next_public), "0.3.2").is_ok());
        let file = dir.join(TRUSTED_KEYS_FILE);
        assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
        let on_disk: Value = serde_json::from_slice(&std::fs::read(&file).unwrap()).unwrap();
        assert_eq!(on_disk, json!({"keys": [base64(&next_public)]}));

        // From now on, and after a restart (every call loads the folder), the new key signs.
        assert!(accept(&next, None, "0.3.3").is_ok());
        assert_eq!(load_trust(&dir, builtin.clone()).keys(), [primary_public, recovery_public, next_public]);
        // The old keys still do, and the stranger still doesn't.
        assert!(accept(&primary, None, "0.3.3").is_ok());
        assert!(accept(&stranger, None, "0.3.4").is_err());
        // Naming a key that is already trusted changes nothing.
        assert!(accept(&next, Some(primary_public), "0.3.3").is_ok());
        assert!(accept(&next, Some(next_public), "0.3.3").is_ok());
        assert_eq!(load_trust(&dir, builtin.clone()).handed, [next_public]);

        // An expired or replayed list hands nothing over either.
        let (late, late_public) = keypair();
        let (data, sig) = signed(&primary, &|v| v["next_key"] = json!(base64(&late_public)), "0.3.3");
        assert_eq!(accept_and_remember(&dir, builtin.clone(), &data, &sig, EXPIRES).unwrap_err().problem, Problem::Expired);
        assert_eq!(accept(&primary, Some(late_public), "0.3.0").unwrap_err().problem, Problem::Replayed);
        assert!(accept(&late, None, "0.3.3").is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn at_most_four_handed_over_keys_are_kept() {
        let (_, builtin) = keypair();
        let keys: Vec<[u8; 32]> = (1..=6u8).map(|n| [n; 32]).collect();
        let mut trust = Trust::new(vec![builtin], vec![]);
        assert!(!trust.hand_over(builtin), "already trusted");
        assert!(!trust.hand_over([0u8; 32]), "the placeholder is no key");
        for key in &keys {
            assert!(trust.hand_over(*key));
            assert!(!trust.hand_over(*key));
        }
        // The two oldest went. The built-in key is never pushed out.
        assert_eq!(trust.handed, keys[2..]);
        assert_eq!(trust.keys(), [&[builtin][..], &keys[2..]].concat());
        // A file with more than four, a repeat and junk is cut down the same way when read.
        let dir = temp("cap");
        let mut listed: Vec<Value> = keys.iter().map(|k| json!(base64(k))).collect();
        listed.extend([json!(base64(&keys[5])), json!("junk"), json!(7), json!(base64(&[0u8; 32]))]);
        std::fs::write(dir.join(TRUSTED_KEYS_FILE), json!({"keys": listed}).to_string()).unwrap();
        assert_eq!(load_trust(&dir, vec![builtin]).handed, keys[2..]);
        std::fs::write(dir.join(TRUSTED_KEYS_FILE), "not json").unwrap();
        assert_eq!(load_trust(&dir, vec![builtin]).keys(), [builtin]);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_key_file_names_a_primary_and_a_recovery_key() {
        let (_, a) = keypair();
        let (_, b) = keypair();
        let zero = base64(&[0u8; 32]);
        assert_eq!(update_keys(&format!("# keys\nprimary  {}\nrecovery {}\n", base64(&a), base64(&b))), Ok(vec![a, b]));
        assert_eq!(update_keys(&format!("recovery {}\n\nprimary {}\n", base64(&b), base64(&a))), Ok(vec![a, b]), "primary first, however the file orders them");
        assert_eq!(update_keys(&format!("primary {}\n", base64(&a))), Ok(vec![a]));
        // The all-zero placeholder is no key; with nothing else, updates are not set up.
        assert_eq!(update_keys(&format!("primary {zero}\nrecovery {zero}\n")), Ok(vec![]));
        assert_eq!(update_keys(&format!("primary {zero}\nrecovery {}\n", base64(&b))), Ok(vec![b]));
        for bad in [
            String::new(),
            "# only a comment\n".into(),
            base64(&a),
            format!("recovery {}\n", base64(&b)),
            format!("primary {}\nprimary {}\n", base64(&a), base64(&b)),
            format!("primary {}\nbackup {}\n", base64(&a), base64(&b)),
            format!("primary {} extra\n", base64(&a)),
            "primary AAAA\n".into(),
            "primary\n".into(),
            format!("primary {}\n", base64url(&a)),
            format!("primary {}\n", base64(&[1u8; 33])),
        ] {
            assert!(update_keys(&bad).is_err(), "{bad:?}");
        }
        // The file compiled into this build holds the two published keys.
        let published = update_keys(UPDATE_KEY_FILE).unwrap();
        assert_eq!(published.iter().map(|k| base64(k)).collect::<Vec<_>>(), ["Yn851QvA2ZzvkX/TkpqQcsiIOqUd2wi0jAFRbh+0OP0=", "p6Uwh2Qc232RxSymb4uFSkx/A/4Czn+/+QTz16RbLGE="]);
    }

    #[test]
    fn the_placeholder_key_means_updates_are_not_set_up() {
        let dir = temp("placeholder");
        let env = Env { dry_run: false, debug_build: false, keys: Ok(vec![]), place: Ok(Place::LinuxBinary("/home/u/.local/bin/rex-duo-helper".into())), service: true, writable: true };
        assert_eq!(blocker(&env).as_deref(), Some(NO_KEY));
        let u = Updater::with_env(env, true, &dir);
        let s = u.status();
        assert_eq!(s["can_update"], false);
        assert_eq!(s["last_error"], "Updates are not set up in this build.");
        assert_eq!(s["update_available"], false);
        assert_eq!(u.blocker().unwrap().problem, Problem::NotSetUp);
        assert!(!u.auto, "the timer is off without a key");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn without_a_key_nothing_is_fetched_or_installed() {
        let dir = temp("nokey");
        let env = Env { dry_run: false, debug_build: false, keys: Ok(vec![]), place: Err("x".into()), service: true, writable: true };
        let u = Updater::with_env(env, true, &dir);
        assert_eq!(u.check().await.unwrap_err(), Fault::new(Problem::NotSetUp, NO_KEY));
        let asset = Asset { url: format!("{RELEASE_PREFIX}helper-v9.9.9/x"), sha256: "ab".repeat(32), size: 1 };
        assert_eq!(u.install("9.9.9", &asset, Restart::Inline).await.unwrap_err(), Fault::new(Problem::NotSetUp, NO_KEY));
        assert_eq!(u.status()["updating"], false);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn what_stops_an_update() {
        let (_, public) = keypair();
        let env = || Env {
            dry_run: false,
            debug_build: false,
            keys: Ok(vec![public]),
            place: Ok(Place::MacApp(concat!("/Applications/", crate::beacon_name!(), ".app").into())),
            service: true,
            writable: true,
        };
        assert_eq!(blocker(&env()), None);
        assert!(blocker(&Env { dry_run: true, ..env() }).unwrap().contains("dry run"));
        assert!(blocker(&Env { debug_build: true, ..env() }).unwrap().contains("debug build"));
        assert!(blocker(&Env { keys: Err("update-key.pub is not 32 bytes of base64".into()), ..env() }).unwrap().contains("not set up"));
        assert_eq!(blocker(&Env { place: Err("This copy runs from a cargo target folder.".into()), ..env() }).unwrap(), "This copy runs from a cargo target folder.");
        assert!(blocker(&Env { service: false, ..env() }).unwrap().contains("background service"));
        assert_eq!(blocker(&Env { writable: false, ..env() }).unwrap(), concat!(crate::beacon_name!(), " can't write to /Applications."));
    }

    #[test]
    fn where_the_helper_is_installed() {
        let install = Path::new("/home/u/.local/bin/rex-duo-helper");
        let mac = |p: &str| Place::detect("macos", Path::new(p), install);
        assert_eq!(mac(concat!("/Applications/", crate::beacon_name!(), ".app/Contents/MacOS/rex-duo-helper")), Ok(Place::MacApp(concat!("/Applications/", crate::beacon_name!(), ".app").into())));
        assert!(mac("/Users/u/.local/bin/rex-duo-helper").is_err());
        assert!(mac("/Applications/Other.app/Contents/MacOS/rex-duo-helper").is_err());
        assert!(mac(concat!("/Applications/", crate::beacon_name!(), ".previous.app/Contents/MacOS/rex-duo-helper")).is_err());
        assert!(mac(concat!("/private/var/folders/x/AppTranslocation/ABC/d/", crate::beacon_name!(), ".app/Contents/MacOS/rex-duo-helper")).unwrap_err().contains("Applications"));
        assert!(mac("/Users/u/rexduo/Relay/target/release/rex-duo-helper").unwrap_err().contains("cargo target"));
        assert!(mac(concat!("/Users/u/target/", crate::beacon_name!(), ".app/Contents/MacOS/rex-duo-helper")).unwrap_err().contains("cargo target"));
        assert_eq!(Place::detect("linux", install, install), Ok(Place::LinuxBinary(install.into())));
        assert!(Place::detect("linux", Path::new("/tmp/rex-duo-helper-linux-x86_64"), install).is_err());
        assert!(Place::detect("linux", Path::new("/home/u/src/target/release/rex-duo-helper"), install).is_err());
        assert!(Place::detect("freebsd", install, install).is_err());

        let app = Place::MacApp(concat!("/Applications/", crate::beacon_name!(), ".app").into());
        assert_eq!(app.previous(), Path::new(concat!("/Applications/", crate::beacon_name!(), ".previous.app")));
        assert_eq!(app.previous_binary(), Path::new(concat!("/Applications/", crate::beacon_name!(), ".previous.app/Contents/MacOS/rex-duo-helper")));
        let bin = Place::LinuxBinary(install.into());
        assert_eq!(bin.previous(), Path::new("/home/u/.local/bin/rex-duo-helper.previous"));
        assert_eq!(bin.previous_binary(), bin.previous());
    }

    #[test]
    fn size_and_hash_of_a_download() {
        let data = b"the new helper, byte for byte".to_vec();
        let (size, sha) = (data.len() as u64, sha256(&data));
        let feed = |limit: u64, chunks: &[&[u8]]| {
            let mut c = Checked::new(Vec::new(), limit);
            for chunk in chunks {
                c.write(chunk)?;
            }
            Ok::<_, String>(c)
        };
        // Whole, in pieces, with the hash in either case.
        assert_eq!(feed(size, &[&data]).unwrap().finish(size, &sha).unwrap(), data);
        assert_eq!(feed(size, &[&data[..5], &data[5..]]).unwrap().finish(size, &sha.to_uppercase()).unwrap(), data);
        // One byte more than the manifest says stops the transfer, before it is written.
        let mut over = feed(size, &[&data]).unwrap();
        assert!(over.write(b"!").unwrap_err().contains("larger"));
        assert_eq!(over.out, data);
        // Short.
        assert!(feed(size, &[&data[..10]]).unwrap().finish(size, &sha).unwrap_err().contains("shorter"));
        // Right size, wrong bytes.
        let mut flipped = data.clone();
        flipped[3] ^= 1;
        assert!(feed(size, &[&flipped]).unwrap().finish(size, &sha).unwrap_err().contains("SHA-256"));
        // The hard cap holds whatever size is claimed.
        assert_eq!(Checked::new(Vec::new(), u64::MAX).limit, MAX_ASSET);
    }

    #[test]
    fn one_update_at_a_time() {
        let dir = temp("lock");
        let nobody = |_: u64| false;
        let everybody = |_: u64| true;
        let lock = UpdateLock::acquire(&dir, nobody).unwrap();
        assert_eq!(std::fs::read_to_string(dir.join(LOCK_FILE)).unwrap(), std::process::id().to_string());
        // Held by this process: busy, whatever the pid check says.
        assert!(UpdateLock::acquire(&dir, nobody).unwrap_err().contains("Another update"));
        drop(lock);
        assert!(!dir.join(LOCK_FILE).exists());
        assert!(!UpdateLock::busy(&dir, everybody));

        // Held by another live process: busy, and the lock is left alone.
        std::fs::write(dir.join(LOCK_FILE), "4242").unwrap();
        assert_eq!(UpdateLock::acquire(&dir, everybody).unwrap_err(), "Another update is running (pid 4242).");
        assert_eq!(std::fs::read_to_string(dir.join(LOCK_FILE)).unwrap(), "4242");
        assert!(UpdateLock::busy(&dir, everybody) && !UpdateLock::busy(&dir, nobody));
        // Its process is gone: stale, taken over.
        let taken = UpdateLock::acquire(&dir, nobody).unwrap();
        assert_eq!(std::fs::read_to_string(dir.join(LOCK_FILE)).unwrap(), std::process::id().to_string());
        drop(taken);
        // Unreadable: stale too.
        std::fs::write(dir.join(LOCK_FILE), "garbage").unwrap();
        drop(UpdateLock::acquire(&dir, everybody).unwrap());

        // Handed over: stays for the process that carries on, which adopts it and ends it.
        UpdateLock::acquire(&dir, nobody).unwrap().hand_over();
        assert!(dir.join(LOCK_FILE).exists());
        drop(UpdateLock::adopt(&dir));
        assert!(!dir.join(LOCK_FILE).exists());

        // Handed over to a process that never started: taken back, and the next update runs.
        UpdateLock::acquire(&dir, nobody).unwrap().hand_over();
        assert!(UpdateLock::acquire(&dir, everybody).is_err());
        assert!(UpdateLock::take_back(&dir));
        assert!(!UpdateLock::take_back(&dir), "nothing left to take back");
        drop(UpdateLock::acquire(&dir, everybody).unwrap());
        // One that another process adopted is that process's to release.
        std::fs::write(dir.join(LOCK_FILE), "4242").unwrap();
        assert!(!UpdateLock::take_back(&dir));
        assert!(dir.join(LOCK_FILE).exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn redirects_only_to_githubs_file_servers() {
        let ok = |s: &str| download_host_ok(&Url::parse(s).unwrap());
        assert!(ok("https://github.com/theabecaster/rexduo/releases/download/helper-latest/manifest.json"));
        assert!(ok("https://objects.githubusercontent.com/github-production-release-asset/1?X-Amz-Signature=abc"));
        assert!(ok("https://release-assets.githubusercontent.com/github-production-release-asset/1?sp=r&sig=abc"));
        assert!(!ok("http://github.com/x"));
        assert!(!ok("https://github.com:8443/x"));
        assert!(!ok("https://raw.githubusercontent.com/x"));
        assert!(!ok("https://github.com.evil.example/x"));
        assert!(!ok("https://evil.example/github.com"));
        assert!(!ok("http://127.0.0.1/x"));
    }

    fn loopback(u: &Url) -> bool {
        u.is_loopback()
    }

    #[tokio::test]
    async fn a_download_is_kept_only_if_size_and_hash_match() {
        let dir = temp("download");
        let data = "0123456789".repeat(1000);
        let (size, sha) = (data.len() as u64, sha256(data.as_bytes()));
        let chunked = Canned { chunked: true, ..canned(200, &data) };
        let (base, seen) = serve(vec![canned(200, &data), chunked, canned(200, &format!("{data}!")), canned(200, &data[1..]), canned(404, "no")]).await;
        let url = format!("{base}/file");

        for name in ["sized", "chunked"] {
            let dest = dir.join(name);
            download_to(&url, &loopback, &dest, size, &sha).await.unwrap();
            assert_eq!(std::fs::read_to_string(&dest).unwrap(), data);
            // An existing file is never written over.
            assert!(download_to(&url, &loopback, &dest, size, &sha).await.is_err());
        }
        assert_eq!(seen.lock().unwrap().len(), 2);
        let dest = dir.join("bad");
        assert!(download_to(&url, &loopback, &dest, size, &sha).await.unwrap_err().contains("larger"));
        assert!(!dest.exists());
        assert!(download_to(&url, &loopback, &dest, size, &sha).await.is_err());
        assert!(!dest.exists());
        assert_eq!(download_to(&url, &loopback, &dest, size, &sha).await.unwrap_err(), "127.0.0.1 answered 404");
        assert!(!dest.exists());
        // The right bytes under a wrong hash.
        let (base, _) = serve(vec![canned(200, &data)]).await;
        assert!(download_to(&base, &loopback, &dest, size, &"00".repeat(32)).await.unwrap_err().contains("SHA-256"));
        assert!(!dest.exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_redirect_is_checked_before_it_is_followed() {
        let dir = temp("redirect");
        let to = |location: &str| Canned { headers: format!("Location: {location}\r\n"), ..canned(302, "") };
        let (target, _) = serve(vec![canned(200, "abc")]).await;
        let (base, seen) = serve(vec![
            to("https://evil.example/file"),
            to("http://github.com/theabecaster/rexduo/releases/download/x/y"),
            to(&format!("{target}/moved")),
            to("/again"),
        ])
        .await;
        let dest = dir.join("f");
        let sha = sha256(b"abc");
        // Elsewhere, and plain http: refused by name, with no connection made to them.
        assert_eq!(download_to(&base, &loopback, &dest, 3, &sha).await.unwrap_err(), "refusing to download from https://evil.example");
        assert_eq!(download_to(&base, &loopback, &dest, 3, &sha).await.unwrap_err(), "refusing to download from http://github.com");
        // An allowed one is followed.
        download_to(&base, &loopback, &dest, 3, &sha).await.unwrap();
        assert_eq!(std::fs::read(&dest).unwrap(), b"abc");
        std::fs::remove_file(&dest).unwrap();
        // A loop ends.
        assert_eq!(download_to(&base, &loopback, &dest, 3, &sha).await.unwrap_err(), "too many redirects");
        assert_eq!(seen.lock().unwrap().len(), 3 + MAX_REDIRECTS + 1);
        // The real rule takes only GitHub over https, so nothing here is reachable through it.
        assert!(fetch_small(RELEASES, &format!("{base}/manifest.json"), 10).await.unwrap_err().contains("not one of this project's releases"));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn linux_swap_keeps_the_old_binary_and_rolls_back() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temp("swaplinux");
        let place = Place::LinuxBinary(dir.join("rex-duo-helper"));
        std::fs::write(place.path(), "old").unwrap();
        std::fs::write(place.previous(), "older").unwrap();
        let new = dir.join(".rex-duo-helper.download-1");
        std::fs::write(&new, "new").unwrap();
        std::fs::set_permissions(&new, std::fs::Permissions::from_mode(0o600)).unwrap();
        swap_linux(&new, &place).unwrap();
        assert_eq!(std::fs::read_to_string(place.path()).unwrap(), "new");
        assert_eq!(std::fs::metadata(place.path()).unwrap().permissions().mode() & 0o777, 0o755);
        assert_eq!(std::fs::read_to_string(place.previous()).unwrap(), "old");
        assert!(!new.exists());
        roll_back(&place).unwrap();
        assert_eq!(std::fs::read_to_string(place.path()).unwrap(), "old");
        assert!(!place.previous().exists());
        assert!(roll_back(&place).is_err(), "nothing to go back to twice");
        std::fs::remove_dir_all(dir).unwrap();
    }

    fn fake_app(at: &Path, marker: &str) {
        std::fs::create_dir_all(at.join("Contents/MacOS")).unwrap();
        std::fs::write(at.join("Contents/MacOS/rex-duo-helper"), marker).unwrap();
    }

    fn marker(app: &Path) -> String {
        std::fs::read_to_string(app.join("Contents/MacOS/rex-duo-helper")).unwrap()
    }

    #[test]
    fn mac_swap_keeps_the_old_app_and_rolls_back() {
        let dir = temp("swapmac");
        let place = Place::MacApp(dir.join(APP_NAME));
        fake_app(place.path(), "old");
        fake_app(&place.previous(), "older");
        let new = dir.join(".rex-duo-helper-update-1/unpacked").join(APP_NAME);
        fake_app(&new, "new");
        swap_mac(&new, &place).unwrap();
        assert_eq!(marker(place.path()), "new");
        assert_eq!(marker(&place.previous()), "old");
        assert!(!new.exists());
        roll_back(&place).unwrap();
        assert_eq!(marker(place.path()), "old");
        assert!(!place.previous().exists());
        // Nothing else is left beside the app.
        let left: Vec<String> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
        assert!(left.iter().all(|n| n == APP_NAME || n == ".rex-duo-helper-update-1"), "{left:?}");
        // A new app that can't be moved in leaves the installed one where it was.
        assert!(swap_mac(&dir.join("missing.app"), &place).is_err());
        assert_eq!(marker(place.path()), "old");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn finish_confirms_the_new_version_or_rolls_back() {
        use std::cell::Cell;
        let dir = temp("finish");
        let place = Place::LinuxBinary(dir.join("rex-duo-helper"));
        let install = |new: &str| {
            std::fs::write(place.path(), "old").unwrap();
            let staged = dir.join("staged");
            std::fs::write(&staged, new).unwrap();
            swap_linux(&staged, &place).unwrap();
        };
        let restarts = Cell::new(0);
        let restart = || {
            restarts.set(restarts.get() + 1);
            true
        };
        let quick = |running: &dyn Fn() -> Option<String>| {
            let fx = Effects {
                restart: &restart,
                old_gone: &|| true,
                running_version: running,
                exit_wait: Duration::from_millis(60),
                wait: Duration::from_millis(60),
                poll: Duration::from_millis(5),
            };
            finish(&place, "0.3.1", &fx)
        };

        // The new version reports in after a moment: it stays, and the previous one is removed.
        install("new");
        let polls = Cell::new(0);
        let comes_up = || {
            polls.set(polls.get() + 1);
            Some(if polls.get() < 3 { "0.3.0" } else { "0.3.1" }.to_string())
        };
        assert_eq!(quick(&comes_up), Ok(()));
        assert_eq!(restarts.get(), 1);
        assert_eq!(std::fs::read_to_string(place.path()).unwrap(), "new");
        assert!(!place.previous().exists());
        let left: Vec<String> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
        assert_eq!(left, ["rex-duo-helper"]);

        // Nothing reports in: the old binary is back, and the service was restarted again.
        install("broken");
        restarts.set(0);
        assert!(quick(&|| None).unwrap_err().contains("previous version was put back"));
        assert_eq!(restarts.get(), 2);
        assert_eq!(std::fs::read_to_string(place.path()).unwrap(), "old");
        assert!(!place.previous().exists());

        // The old version is what answers (the new one crashed and something else runs): same.
        install("broken");
        assert!(quick(&|| Some("0.3.0".into())).is_err());
        assert_eq!(std::fs::read_to_string(place.path()).unwrap(), "old");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_confirm_window_starts_when_the_old_helper_is_gone() {
        let dir = temp("timing");
        let place = Place::LinuxBinary(dir.join("rex-duo-helper"));
        let install = || {
            std::fs::write(place.path(), "old").unwrap();
            let staged = dir.join("staged");
            std::fs::write(&staged, "new").unwrap();
            swap_linux(&staged, &place).unwrap();
        };
        let began = std::cell::Cell::new(Instant::now());
        let restart = || {
            began.set(Instant::now());
            true
        };
        // The old helper takes 150 ms to stop, longer than the whole 100 ms the new one gets
        // to report in. The new one reports 40 ms after the old one is gone.
        let old_gone = || began.get().elapsed() >= Duration::from_millis(150);
        let running = || (began.get().elapsed() >= Duration::from_millis(190)).then(|| "0.3.1".to_string());
        let fx = |exit_wait: u64| Effects {
            restart: &restart,
            old_gone: &old_gone,
            running_version: &running,
            exit_wait: Duration::from_millis(exit_wait),
            wait: Duration::from_millis(100),
            poll: Duration::from_millis(5),
        };
        // Counted from the old helper's exit, the new version is in time.
        install();
        assert_eq!(finish(&place, "0.3.1", &fx(1000)), Ok(()));
        assert_eq!(std::fs::read_to_string(place.path()).unwrap(), "new");
        assert!(!place.previous().exists());

        // An old helper that never goes away does not hold the update up for ever: after
        // `exit_wait` the window starts anyway, and with nothing reporting in it rolls back.
        install();
        let stuck = Effects { old_gone: &|| false, running_version: &|| None, ..fx(40) };
        let asked = Instant::now();
        assert!(finish(&place, "0.3.1", &stuck).is_err());
        let took = asked.elapsed();
        assert!(took >= Duration::from_millis(140) && took < Duration::from_secs(5), "{took:?}");
        assert_eq!(std::fs::read_to_string(place.path()).unwrap(), "old");
        std::fs::remove_dir_all(dir).unwrap();
    }

    fn loopback_origin() -> Origin {
        Origin { url_ok: |u| u.starts_with("http://127.0.0.1:"), host_ok: loopback }
    }

    #[tokio::test]
    async fn linux_stage_swap_finish_and_roll_back() {
        let (pair, public) = keypair();
        let (_, other_public) = keypair();
        let dir = temp("stagelinux");
        let place = Place::LinuxBinary(dir.join("rex-duo-helper"));
        std::fs::write(place.path(), "old helper").unwrap();
        let new = "the new helper";
        let sha = sha256(new.as_bytes());
        let sig_for = |version: &str, platform: &str, sha: &str| String::from_utf8(sign(&pair, binary_message(version, platform, sha).as_bytes())).unwrap();
        let good = sig_for("0.3.1", "linux-x86_64", &sha);
        // Each attempt asks for the binary, then its signature.
        let (base, seen) = serve(vec![
            canned(200, new),
            canned(200, &good),
            // Signed for the other architecture, and for another version.
            canned(200, new),
            canned(200, &sig_for("0.3.1", "linux-aarch64", &sha)),
            canned(200, new),
            canned(200, &sig_for("0.3.0", "linux-x86_64", &sha)),
            // A signature over the file's bytes alone, as releases before this one had.
            canned(200, new),
            canned(200, &String::from_utf8(sign(&pair, new.as_bytes())).unwrap()),
            // Other bytes than the manifest names.
            canned(200, "the evil helper"),
            // No signature beside the file.
            canned(200, new),
            canned(404, "no"),
            // The good one again, for the roll back below.
            canned(200, new),
            canned(200, &good),
        ])
        .await;
        let asset = Asset { url: format!("{base}/rex-duo-helper-linux-x86_64"), sha256: sha.clone(), size: new.len() as u64 };
        let stage = |trusted: Vec<[u8; 32]>| stage_and_swap(loopback_origin(), &place, trusted, "0.3.1", "linux-x86_64", &asset);
        let installed = || std::fs::read_to_string(place.path()).unwrap();
        let leftovers = || {
            let mut names: Vec<String> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
            names.sort();
            names
        };

        // Staged, checked and swapped in; the old one stays beside it until the new one is confirmed.
        stage(vec![other_public, public]).await.unwrap();
        assert_eq!(installed(), new);
        assert_eq!(std::fs::read_to_string(place.previous()).unwrap(), "old helper");
        assert_eq!(leftovers(), ["rex-duo-helper", "rex-duo-helper.previous"]);
        assert_eq!(seen.lock().unwrap()[1].path, "/rex-duo-helper-linux-x86_64.sig");

        // Everything else leaves the installed helper as it is and nothing behind.
        std::fs::write(place.path(), "old helper").unwrap();
        std::fs::remove_file(place.previous()).unwrap();
        for (why, problem) in [("other architecture", Problem::Checks), ("other version", Problem::Checks), ("signature over the bytes", Problem::Checks), ("other bytes", Problem::Download), ("no signature", Problem::Download)] {
            assert_eq!(stage(vec![public]).await.unwrap_err().problem, problem, "{why}");
            assert_eq!(installed(), "old helper", "{why}");
            assert_eq!(leftovers(), ["rex-duo-helper"], "{why}");
        }
        // An address outside the releases is refused before anything is asked for.
        let asked = seen.lock().unwrap().len();
        let elsewhere = Asset { url: "http://127.0.0.2/x".into(), ..asset.clone() };
        assert_eq!(stage_and_swap(loopback_origin(), &place, vec![public], "0.3.1", "linux-x86_64", &elsewhere).await.unwrap_err().problem, Problem::Download);
        assert_eq!(seen.lock().unwrap().len(), asked);
        // A key that is not trusted: the right signature counts for nothing.
        assert_eq!(check_and_swap_linux(place.path(), good.as_bytes(), &[other_public], "0.3.1", "linux-x86_64", &asset, &place).unwrap_err().problem, Problem::Checks);

        // Staged again, then the new version never reports in: the old one comes back.
        stage(vec![public]).await.unwrap();
        assert_eq!(installed(), new);
        let fx = Effects {
            restart: &|| true,
            old_gone: &|| true,
            running_version: &|| Some("0.3.0".into()),
            exit_wait: Duration::from_millis(20),
            wait: Duration::from_millis(40),
            poll: Duration::from_millis(5),
        };
        assert!(finish(&place, "0.3.1", &fx).is_err());
        assert_eq!(installed(), "old helper");
        assert_eq!(leftovers(), ["rex-duo-helper"]);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn mac_swap_finish_and_roll_back() {
        let dir = temp("stagemac");
        let place = Place::MacApp(dir.join(APP_NAME));
        let stage = |version: &str| {
            let new = dir.join(".rex-duo-helper-update-1/unpacked").join(APP_NAME);
            fake_app(&new, version);
            swap_mac(&new, &place).unwrap();
        };
        let apps = || {
            let mut names: Vec<String> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).filter(|n| n.ends_with(".app")).collect();
            names.sort();
            names
        };
        fake_app(place.path(), "old");
        let restarts = std::cell::Cell::new(0);
        let restart = || {
            restarts.set(restarts.get() + 1);
            true
        };
        let (new_runs, old_runs) = (|| Some("0.3.1".to_string()), || Some("0.3.0".to_string()));
        let fx = |running_version| Effects {
            restart: &restart,
            old_gone: &|| true,
            running_version,
            exit_wait: Duration::from_millis(20),
            wait: Duration::from_millis(40),
            poll: Duration::from_millis(5),
        };
        // Until the new app is confirmed the old one is beside it, where the finisher runs from.
        stage("new");
        assert_eq!((marker(place.path()).as_str(), marker(&place.previous()).as_str()), ("new", "old"));
        assert_eq!(std::fs::read_to_string(place.previous_binary()).unwrap(), "old");
        // The new app comes up: it stays, and the old one is removed.
        assert_eq!(finish(&place, "0.3.1", &fx(&new_runs)), Ok(()));
        assert_eq!(marker(place.path()), "new");
        assert_eq!(apps(), [APP_NAME]);
        assert_eq!(restarts.get(), 1);
        // The next update's app never reports in: the one that ran before it is back, alone.
        stage("newer");
        assert_eq!(apps(), [APP_NAME, PREVIOUS_APP]);
        restarts.set(0);
        assert!(finish(&place, "0.3.2", &fx(&old_runs)).unwrap_err().contains("previous version was put back"));
        assert_eq!(marker(place.path()), "new");
        assert_eq!(apps(), [APP_NAME]);
        assert_eq!(restarts.get(), 2, "once into the new app, once back into the old");
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_finisher_runs_outside_the_service() {
        let place = Place::MacApp(concat!("/Applications/", crate::beacon_name!(), ".app").into());
        let state = Path::new("/home/u/state");
        let args = finisher_args("0.3.1", &place, state, 4242);
        assert_eq!(
            args,
            ["finish-update", "--version", "0.3.1", "--place", concat!("/Applications/", crate::beacon_name!(), ".app"), "--state-dir", "/home/u/state", "--old-pid", "4242"].map(os)
        );
        let program = place.previous_binary();

        // Linux: a transient unit of its own. The program and each argument are separate
        // words after `--`, never a shell string.
        let bin = Place::LinuxBinary("/home/u/.local/bin/rex-duo-helper".into());
        let (starter, words) = finisher_start("linux", &bin.previous_binary(), &args, "", Path::new("")).unwrap();
        assert_eq!(starter, "systemd-run");
        assert_eq!(words[..5], ["--user", "--collect", "--quiet", "--", "/home/u/.local/bin/rex-duo-helper.previous"].map(os));
        assert_eq!(words[5..], args[..]);

        // Mac: a launchd job of its own, loaded from a plist.
        let plist_path = state.join(FINISHER_PLIST);
        let (starter, words) = finisher_start("macos", &program, &args, "gui/501", &plist_path).unwrap();
        assert_eq!(starter, "/bin/launchctl");
        assert_eq!(words, [os("bootstrap"), os("gui/501"), os(&plist_path)]);
        let (clearer, words) = finisher_clear("gui/501");
        assert_eq!((clearer, words), ("/bin/launchctl", vec![os("bootout"), os("gui/501/dev.abrahamgonzalez.rexduo.helper.update")]));
        // Not the service's own label: unloading it must never stop the helper.
        assert_ne!(FINISHER_LABEL, BUNDLE_ID);

        let plist = finisher_plist(&program, &args);
        assert!(plist.contains("<key>Label</key><string>dev.abrahamgonzalez.rexduo.helper.update</string>"));
        assert!(plist.contains(&format!(
            "<array><string>/Applications/{PREVIOUS_APP}/Contents/MacOS/rex-duo-helper</string><string>finish-update</string>\
             <string>--version</string><string>0.3.1</string><string>--place</string><string>/Applications/{APP_NAME}</string>"
        )));
        assert!(plist.contains("<string>--old-pid</string><string>4242</string></array>"));
        assert!(plist.contains("<key>RunAtLoad</key><true/>"));
        // It runs once. launchd must not start it again after a roll back.
        assert!(!plist.contains("KeepAlive"));
        // A path with markup in it stays text.
        let odd = finisher_plist(Path::new("/tmp/a<b>&c/rex-duo-helper"), &[os("</string><string>x")]);
        assert!(odd.contains("<string>/tmp/a&lt;b&gt;&amp;c/rex-duo-helper</string><string>&lt;/string&gt;&lt;string&gt;x</string>"));
        assert_eq!(odd.matches("<string>").count(), plist.matches("<string>").count() - args.len() + 1);
    }

    /// A minimal app bundle with the helper's bundle id: a shell script and an Info.plist.
    #[cfg(target_os = "macos")]
    fn fixture_app(dir: &Path) -> PathBuf {
        use std::os::unix::fs::PermissionsExt;
        let app = dir.join(APP_NAME);
        std::fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
        let exe = app.join("Contents/MacOS").join(service::NAME);
        std::fs::write(&exe, "#!/bin/sh\nexit 0\n").unwrap();
        std::fs::set_permissions(&exe, std::fs::Permissions::from_mode(0o755)).unwrap();
        let plist = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>{BUNDLE_ID}</string>
<key>CFBundleExecutable</key><string>{}</string>
<key>CFBundleName</key><string>{BEACON}</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>9.9.9</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
"#,
            service::NAME
        );
        std::fs::write(app.join("Contents/Info.plist"), plist).unwrap();
        app
    }

    /// The real `codesign` checks against apps built here. Nothing is installed or run: the
    /// tools only read a folder under the temp dir.
    #[cfg(target_os = "macos")]
    #[test]
    fn the_real_codesign_checks_reject_an_app_that_is_not_ours() {
        let dir = temp("codesign");
        let app = fixture_app(&dir);
        let run = |n: usize| {
            let (program, args) = mac_checks(&app).swap_remove(n);
            tool(program, &args).unwrap()
        };

        // Unsigned: not even an intact signature.
        assert_eq!(mac_signature_ok(&app), Ok(false));
        assert!(!run(0).0 && !run(1).0);

        // Signed by nobody in particular (ad hoc), with our bundle id. The signature is
        // intact, so the first check passes: it is the requirement, our team on a Developer
        // ID certificate, that turns it away.
        let (signed, said) = tool("/usr/bin/codesign", &[os("-s"), os("-"), os("--identifier"), os(BUNDLE_ID), os(&app)]).unwrap();
        assert!(signed, "could not ad-hoc sign the fixture: {said}");
        let (intact, said) = run(0);
        assert!(intact, "{said}");
        let (ours, said) = run(1);
        assert!(!ours, "an ad-hoc signature met the requirement");
        assert!(said.contains("does not satisfy its designated Requirement") || said.contains("failed to satisfy"), "{said}");
        assert_eq!(mac_signature_ok(&app), Ok(false));

        // The whole check of a download refuses it too, before Gatekeeper is even asked.
        let zip = dir.join("download.zip");
        let (zipped, said) = tool("/usr/bin/ditto", &[os("-c"), os("-k"), os("--keepParent"), os(&app), os(&zip)]).unwrap();
        assert!(zipped, "{said}");
        assert_eq!(unpack_and_check_mac(&zip, &dir.join("unpacked"), "9.9.9").unwrap_err(), "The downloaded app's code signature was not accepted.");

        // Changed after signing: the signature is no longer intact.
        std::fs::write(app.join("Contents/MacOS").join(service::NAME), "#!/bin/sh\nexit 1\n").unwrap();
        assert!(!run(0).0);
        assert_eq!(mac_signature_ok(&app), Ok(false));
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// An app installed under an earlier name is the installed app. An update puts the new
    /// version beside it under the app's name, and a roll back puts the old one back under the
    /// name it had.
    #[test]
    fn an_update_of_an_app_under_an_earlier_name_ends_under_the_new_name() {
        let install = Path::new("/home/u/.local/bin/rex-duo-helper");
        let named = Place::MacApp(format!("/Applications/{APP_NAME}").into());
        assert_eq!(named.target(), named.path());
        assert_eq!(Place::LinuxBinary(install.into()).target(), install);
        for (earlier, earlier_previous) in EARLIER_APP_NAMES.into_iter().zip(EARLIER_PREVIOUS_APPS) {
            let old = Place::detect("macos", Path::new(&format!("/Applications/{earlier}/Contents/MacOS/rex-duo-helper")), install).unwrap();
            assert_eq!(old, Place::MacApp(format!("/Applications/{earlier}").into()));
            assert_eq!(old.target(), named.path());
            assert_eq!(old.previous(), Path::new(&format!("/Applications/{PREVIOUS_APP}")));

            let dir = temp("swapold");
            let place = Place::MacApp(dir.join(earlier));
            let apps = || {
                let mut names: Vec<String> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).filter(|n| n.ends_with(".app")).collect();
                names.sort();
                names
            };
            let stage = |version: &str, folder: &str| {
                let new = dir.join(".rex-duo-helper-update-1/unpacked").join(folder);
                fake_app(&new, version);
                swap_mac(&new, &place).unwrap();
            };
            let programs = std::cell::RefCell::new(vec![]);
            let restart = || {
                programs.borrow_mut().push(place.program());
                true
            };
            let (new_runs, old_runs) = (|| Some("0.3.2".to_string()), || Some("0.3.1".to_string()));
            let fx = |running_version| Effects { restart: &restart, old_gone: &|| true, running_version, exit_wait: Duration::from_millis(20), wait: Duration::from_millis(40), poll: Duration::from_millis(5) };

            // The new version does not start: the old app is back under the earlier name, alone,
            // and the service was started from the new place and then from the old one. A copy
            // set aside under any name by an earlier update is gone, and so is the folder the
            // version that did not start waited in.
            fake_app(place.path(), "0.3.1");
            for previous in EARLIER_PREVIOUS_APPS {
                fake_app(&dir.join(previous), "0.3.0");
            }
            fake_app(&place.previous(), "0.2.0");
            stage("0.3.2", earlier);
            assert_eq!(apps(), [APP_NAME, PREVIOUS_APP]);
            assert_eq!((marker(&place.target()).as_str(), marker(&place.previous()).as_str()), ("0.3.2", "0.3.1"));
            assert!(finish(&place, "0.3.2", &fx(&old_runs)).is_err());
            assert_eq!(apps(), [earlier]);
            assert_eq!(marker(place.path()), "0.3.1");
            assert_eq!(*programs.borrow(), [place.target().join("Contents/MacOS/rex-duo-helper"), place.path().join("Contents/MacOS/rex-duo-helper")]);

            // It starts: one app, under the new name, whichever folder name the zip gave it.
            for folder in EARLIER_APP_NAMES.into_iter().chain([APP_NAME]) {
                fake_app(place.path(), "0.3.1");
                fake_app(&dir.join(earlier_previous), "0.3.0");
                let _ = std::fs::remove_dir_all(place.target());
                stage("0.3.2", folder);
                assert_eq!(finish(&place, "0.3.2", &fx(&new_runs)), Ok(()), "{folder}");
                assert_eq!(apps(), [APP_NAME], "{folder}");
                assert_eq!(marker(&place.target()), "0.3.2");
            }

            // An app already under the new name beside it is not written over.
            fake_app(place.path(), "0.3.1");
            let new = dir.join(".rex-duo-helper-update-1/unpacked").join(APP_NAME);
            fake_app(&new, "0.3.3");
            assert!(swap_mac(&new, &place).is_err());
            assert_eq!((marker(place.path()).as_str(), marker(&place.target()).as_str()), ("0.3.1", "0.3.2"));
            let mut both = vec![APP_NAME.to_string(), earlier.to_string()];
            both.sort();
            assert_eq!(apps(), both);
            std::fs::remove_dir_all(dir).unwrap();
        }
    }

    /// The folder a version that did not start waits in before it is deleted has a name of
    /// its own, which says nothing of what the app is called.
    #[test]
    fn a_version_that_did_not_start_waits_under_a_name_that_is_no_app_name() {
        assert_eq!(FAILED_PREFIX, ".beacon-failed-");
        let name = format!("{FAILED_PREFIX}{}.app", 4242);
        assert!(!allowed_app_name(std::ffi::OsStr::new(&name)) && !name.contains(BEACON));
    }

    /// The one list of folder names the Mac app may have.
    #[test]
    fn the_allowed_folder_names() {
        let allowed = |name: &str| allowed_app_name(std::ffi::OsStr::new(name));
        assert!(allowed(APP_NAME));
        assert_eq!(APP_NAME, format!("{BEACON}.app"));
        for earlier in EARLIER_APP_NAMES {
            assert!(allowed(earlier), "{earlier}");
        }
        for other in [PREVIOUS_APP, EARLIER_PREVIOUS_APPS[0], "Other.app", "", ".app", &format!(".{APP_NAME}"), &format!("{APP_NAME} "), &APP_NAME.to_lowercase(), BEACON] {
            assert!(!allowed(other), "{other}");
        }
    }

    /// What an unzipped download must look like before any other check looks at it.
    #[cfg(unix)]
    #[test]
    fn a_download_holds_the_app_alone_as_a_real_folder_of_an_allowed_name() {
        let dir = temp("sole");
        let unpacked = dir.join("unpacked");
        let fresh = || {
            let _ = std::fs::remove_dir_all(&unpacked);
            std::fs::create_dir_all(&unpacked).unwrap();
        };
        let alone = format!("The download does not hold {BEACON} alone.");

        // Under its name, and under each earlier one.
        for name in [APP_NAME].into_iter().chain(EARLIER_APP_NAMES) {
            fresh();
            fake_app(&unpacked.join(name), "0.4.0");
            assert_eq!(sole_app(&unpacked), Ok(unpacked.join(name)), "{name}");
        }
        // Nothing at all, and no folder to look in.
        fresh();
        assert_eq!(sole_app(&unpacked).unwrap_err(), alone);
        assert_eq!(sole_app(&dir.join("missing")).unwrap_err(), alone);
        // Two apps, of allowed names both.
        fresh();
        fake_app(&unpacked.join(APP_NAME), "0.4.0");
        fake_app(&unpacked.join(EARLIER_APP_NAMES[0]), "0.4.0");
        assert_eq!(sole_app(&unpacked).unwrap_err(), alone);
        // The app and a file beside it, seen or hidden.
        for extra in ["README", ".hidden"] {
            fresh();
            fake_app(&unpacked.join(APP_NAME), "0.4.0");
            std::fs::write(unpacked.join(extra), "x").unwrap();
            assert_eq!(sole_app(&unpacked).unwrap_err(), alone, "{extra}");
        }
        // A link of the app's name, to an app that is whole.
        fresh();
        fake_app(&dir.join("real.app"), "0.4.0");
        std::os::unix::fs::symlink(dir.join("real.app"), unpacked.join(APP_NAME)).unwrap();
        assert_eq!(sole_app(&unpacked).unwrap_err(), alone);
        // A name that starts with a dot, one that is not on the list, one that is no app, and
        // the name of a copy an update sets aside.
        for name in [format!(".{APP_NAME}"), "Other.app".to_string(), BEACON.to_string(), PREVIOUS_APP.to_string(), format!("{FAILED_PREFIX}1.app")] {
            fresh();
            fake_app(&unpacked.join(&name), "0.4.0");
            assert_eq!(sole_app(&unpacked).unwrap_err(), alone, "{name}");
        }
        // A file of the app's name.
        fresh();
        std::fs::write(unpacked.join(APP_NAME), "x").unwrap();
        assert_eq!(sole_app(&unpacked).unwrap_err(), alone);
        // A folder of the app's name without this program in it, or with a link where it is.
        let missing = format!("The download does not hold {BEACON}.");
        fresh();
        std::fs::create_dir_all(unpacked.join(APP_NAME).join("Contents/MacOS")).unwrap();
        assert_eq!(sole_app(&unpacked).unwrap_err(), missing);
        std::os::unix::fs::symlink("/usr/bin/true", unpacked.join(APP_NAME).join("Contents/MacOS").join(service::NAME)).unwrap();
        assert_eq!(sole_app(&unpacked).unwrap_err(), missing);
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// A release list names the Mac app three times, once for each folder name a zip holds
    /// it under: `macos-app` (its name), `macos-universal-beacon` and `macos-universal` (the
    /// earlier ones, which the updaters of versions 0.3.1 and 0.3.0 read).
    #[test]
    fn a_mac_takes_the_newest_entry_a_list_has() {
        let base = format!("{RELEASE_PREFIX}helper-v0.3.1");
        let mut list: Value = serde_json::from_str(&manifest_json("0.3.1")).unwrap();
        list["assets"]["macos-universal"]["url"] = json!(format!("{base}/Rex-DUO-Helper.zip"));
        let mac = platform_key("macos", "aarch64");
        assert_eq!(mac, Some(MAC_KEY));
        assert_eq!((MAC_APP_KEY, MAC_BEACON_KEY, MAC_KEY), ("macos-app", "macos-universal-beacon", "macos-universal"));
        let url = |list: &Value, platform: Option<&str>| match plan(&Manifest::parse(list.to_string().as_bytes()).unwrap(), "0.3.0", platform) {
            Ok(Plan::Update { asset, .. }) => asset.url,
            other => panic!("{other:?}"),
        };

        // A list with the first entry alone, as version 0.3.0 was published: it is taken.
        assert_eq!(url(&list, mac), format!("{base}/Rex-DUO-Helper.zip"));

        // With the second, as version 0.3.1 was published: a Mac takes that, and Linux is as before.
        list["assets"][MAC_BEACON_KEY] = json!({"url": format!("{base}/Rex-DUO-Beacon.zip"), "sha256": "12".repeat(32), "size": 124});
        assert_eq!(url(&list, mac), format!("{base}/Rex-DUO-Beacon.zip"));
        assert_eq!(url(&list, Some("linux-x86_64")), format!("{base}/rex-duo-helper-linux-x86_64"));

        // With all three: the zip that holds the app under its name.
        list["assets"][MAC_APP_KEY] = json!({"url": format!("{base}/Beacon-macOS.zip"), "sha256": "34".repeat(32), "size": 125});
        assert_eq!(url(&list, mac), format!("{base}/Beacon-macOS.zip"));
        assert_eq!(url(&list, Some("linux-x86_64")), format!("{base}/rex-duo-helper-linux-x86_64"));
        let m = Manifest::parse(list.to_string().as_bytes()).unwrap();
        assert_eq!(m.assets.len(), 5);
        // The entries the earlier updaters read are still there, and every entry has the three
        // fields in the form those updaters require of each entry they find.
        assert_eq!(m.assets[MAC_KEY].url, format!("{base}/Rex-DUO-Helper.zip"));
        assert_eq!(m.assets[MAC_BEACON_KEY].url, format!("{base}/Rex-DUO-Beacon.zip"));
        for (name, asset) in &m.assets {
            assert!(release_url_ok(&asset.url) && asset.sha256.len() == 64 && (1..=MAX_ASSET).contains(&asset.size), "{name}");
        }
        // Whichever entries are left, the newest of them is taken.
        list["assets"].as_object_mut().unwrap().remove(MAC_KEY);
        assert_eq!(url(&list, mac), format!("{base}/Beacon-macOS.zip"));
        list["assets"].as_object_mut().unwrap().remove(MAC_APP_KEY);
        assert_eq!(url(&list, mac), format!("{base}/Rex-DUO-Beacon.zip"));
        // No Mac entry at all: no build. A Linux computer never takes a Mac's entry.
        list["assets"].as_object_mut().unwrap().remove(MAC_BEACON_KEY);
        assert!(plan(&Manifest::parse(list.to_string().as_bytes()).unwrap(), "0.3.0", mac).is_err());
        list["assets"][MAC_APP_KEY] = json!({"url": format!("{base}/Beacon-macOS.zip"), "sha256": "34".repeat(32), "size": 125});
        list["assets"].as_object_mut().unwrap().remove("linux-aarch64");
        assert!(plan(&Manifest::parse(list.to_string().as_bytes()).unwrap(), "0.3.0", Some("linux-aarch64")).is_err());
        assert!(plan(&Manifest::parse(list.to_string().as_bytes()).unwrap(), "0.3.0", None).is_err());
    }

    /// What a person reads takes the names from src/brand.rs. An earlier name is in quotes
    /// only on a line that says `EARLIER`: the folder names an old install has, and the name
    /// the state folder and the log keep.
    #[test]
    fn no_sentence_names_the_program_by_an_earlier_name() {
        let needle = concat!("Rex ", "DUO");
        let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut seen = 0;
        let files = [src.clone(), src.join("platform")].map(|dir| std::fs::read_dir(dir).unwrap());
        for entry in files.into_iter().flatten() {
            let path = entry.unwrap().path();
            if path.is_dir() {
                continue;
            }
            let text = std::fs::read_to_string(&path).unwrap();
            for (n, line) in text.lines().enumerate() {
                // Comments may name an earlier app. Only what is in quotes can reach a person.
                let code = line.trim_start();
                if code.starts_with("//") {
                    continue;
                }
                for (i, _) in code.match_indices(needle) {
                    let in_quotes = code[..i].matches('"').count() % 2 == 1;
                    assert!(!in_quotes || code.contains("EARLIER_"), "{}:{}: {line}", path.display(), n + 1);
                    seen += 1;
                }
            }
        }
        assert!(seen > 0, "the earlier names are still read somewhere");
    }

    /// The release lists in `Relay/fixtures`, which the release tooling writes
    /// (`tests-setup/make-fixtures.sh`) and the app's tests read too: one format, three readers.
    #[test]
    fn the_shared_fixtures_are_read_as_the_tooling_wrote_them() {
        let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures");
        let read = |name: &str| std::fs::read(dir.join(name)).unwrap_or_else(|e| panic!("{name}: {e}"));
        let text = String::from_utf8(read("test-key.pub")).unwrap();
        let word = text.lines().find_map(|l| l.strip_prefix("primary")).unwrap().trim();
        let key: [u8; 32] = crate::util::base64_decode(word).unwrap().try_into().unwrap();
        let now = now() as i64;

        let m = accept_manifest(&read("manifest.json"), &read("manifest.json.sig"), &[key], None, now).unwrap();
        assert_eq!((m.version.as_str(), m.assets.len()), ("9.8.7", 3));
        let linux = &m.assets["linux-x86_64"];
        let message = binary_message(&m.version, "linux-x86_64", &linux.sha256);
        verify_signatures(&[key], message.as_bytes(), &read("rex-duo-helper-linux-x86_64.sig")).unwrap();
        // A signature for one platform is not one for another.
        let other = binary_message(&m.version, "linux-aarch64", &linux.sha256);
        assert!(verify_signatures(&[key], other.as_bytes(), &read("rex-duo-helper-linux-x86_64.sig")).is_err());

        let expired = accept_manifest(&read("manifest-expired.json"), &read("manifest-expired.json.sig"), &[key], None, now);
        assert_eq!(expired.unwrap_err().problem, Problem::Expired);
        let seen = Version::parse("9.8.7");
        let older = accept_manifest(&read("manifest-older.json"), &read("manifest-older.json.sig"), &[key], seen, now);
        assert_eq!(older.unwrap_err().problem, Problem::Replayed);
        let untrusted = accept_manifest(&read("manifest.json"), &read("manifest-untrusted.json.sig"), &[key], None, now);
        assert_eq!(untrusted.unwrap_err().problem, Problem::Rejected);

        // manifest.json is a list as version 0.3.0 was published, with one entry for a Mac.
        // manifest-beacon.json is the same release with the second one.
        let mac = platform_key("macos", "aarch64");
        let taken = |m: &Manifest| match plan(m, "0.3.0", mac) {
            Ok(Plan::Update { asset, .. }) => asset.url,
            other => panic!("{other:?}"),
        };
        assert!(taken(&m).ends_with("/helper-v9.8.7/Rex-DUO-Helper.zip"));
        let both = accept_manifest(&read("manifest-beacon.json"), &read("manifest-beacon.json.sig"), &[key], None, now).unwrap();
        assert_eq!((both.version.as_str(), both.assets.len()), ("9.8.7", 4));
        assert_eq!(both.assets[MAC_KEY], m.assets[MAC_KEY]);
        assert!(taken(&both).ends_with("/helper-v9.8.7/Rex-DUO-Beacon.zip"));
        // manifest-app.json has all three, as a release has today.
        let all = accept_manifest(&read("manifest-app.json"), &read("manifest-app.json.sig"), &[key], None, now).unwrap();
        assert_eq!((all.version.as_str(), all.assets.len()), ("9.8.7", 5));
        assert_eq!(all.assets[MAC_BEACON_KEY], both.assets[MAC_BEACON_KEY]);
        assert!(taken(&all).ends_with("/helper-v9.8.7/Beacon-macOS.zip"));
    }

    /// The helper against what `release.sh` really writes. `Relay/test-install.sh` runs this
    /// with a release it made from keys of its own (it is skipped otherwise):
    /// `REXDUO_RELEASE_DIR=<dist/release> REXDUO_RELEASE_KEY_FILE=<update-key.pub> cargo test release_sh -- --ignored`.
    #[test]
    #[ignore]
    fn release_sh_output_is_what_the_helper_accepts() {
        let dir = PathBuf::from(std::env::var("REXDUO_RELEASE_DIR").expect("REXDUO_RELEASE_DIR"));
        let keys = update_keys(&std::fs::read_to_string(std::env::var("REXDUO_RELEASE_KEY_FILE").expect("REXDUO_RELEASE_KEY_FILE")).unwrap()).unwrap();
        assert_eq!(keys.len(), 2);
        let read = |name: &str| std::fs::read(dir.join(name)).unwrap_or_else(|e| panic!("{name}: {e}"));
        let (data, sig) = (read("manifest.json"), read("manifest.json.sig"));
        let m = accept_manifest(&data, &sig, &keys, None, now() as i64).unwrap();
        // Good for release.sh's default of 180 days, give or take the minutes the release took.
        let left = m.expires_at - now() as i64;
        assert!((179 * 86_400..=180 * 86_400).contains(&left), "{left}");
        assert_eq!(accept_manifest(&data, &sig, &keys, None, m.expires_at).unwrap_err().problem, Problem::Expired);
        // Each key alone accepts it or not, and exactly one of the two signed it.
        assert_eq!(keys.iter().filter(|k| accept_manifest(&data, &sig, &[**k], None, now() as i64).is_ok()).count(), 1);
        for platform in ["linux-x86_64", "linux-aarch64"] {
            let asset = &m.assets[platform];
            let name = asset.url.rsplit('/').next().unwrap();
            let (file, sig) = (read(name), read(&format!("{name}.sig")));
            assert_eq!((file.len() as u64, sha256(&file)), (asset.size, asset.sha256.clone()), "{platform}");
            assert_eq!(verify_signatures(&keys, binary_message(&m.version, platform, &asset.sha256).as_bytes(), &sig), Ok(()), "{platform}");
            // Not for the other platform, another version, or the bytes alone.
            let other = if platform == "linux-x86_64" { "linux-aarch64" } else { "linux-x86_64" };
            assert!(verify_signatures(&keys, binary_message(&m.version, other, &asset.sha256).as_bytes(), &sig).is_err());
            assert!(verify_signatures(&keys, binary_message("0.0.1", platform, &asset.sha256).as_bytes(), &sig).is_err());
            assert!(verify_signatures(&keys, &file, &sig).is_err());
        }
        // The Mac app three times: the entries the updaters of versions 0.3.0 and 0.3.1 read,
        // and the one a Mac takes now. Each names its zip, and the zips are three files.
        let mac = platform_key("macos", "aarch64");
        let (first, second, third) = (&m.assets[MAC_KEY], &m.assets[MAC_BEACON_KEY], &m.assets[MAC_APP_KEY]);
        assert!(first.url.ends_with(&format!("/helper-v{}/Rex-DUO-Helper.zip", m.version)), "{}", first.url);
        assert!(second.url.ends_with(&format!("/helper-v{}/Rex-DUO-Beacon.zip", m.version)), "{}", second.url);
        assert!(third.url.ends_with(&format!("/helper-v{}/Beacon-macOS.zip", m.version)), "{}", third.url);
        assert!(first.sha256 != second.sha256 && second.sha256 != third.sha256 && first.sha256 != third.sha256);
        for asset in [first, second, third] {
            let file = read(asset.url.rsplit('/').next().unwrap());
            assert_eq!((file.len() as u64, sha256(&file)), (asset.size, asset.sha256.clone()), "{}", asset.url);
        }
        assert_eq!(m.assets.len(), 5);
        assert_eq!(plan(&m, "0.0.1", mac), Ok(Plan::Update { version: m.version.clone(), asset: third.clone() }));
    }

    #[test]
    fn what_the_app_is_told_names_no_path_address_or_tool() {
        let mut seen = std::collections::HashSet::new();
        for p in Problem::ALL {
            let s = p.sentence();
            assert!(seen.insert(s), "two problems share {s:?}");
            assert!(s.ends_with('.') && s.len() < 120, "{s:?}");
            for hint in ["/", "\\", "http", "github", "://", ".json", ".app", "codesign", "spctl", "systemd", "launchctl", "{", "pid"] {
                assert!(!s.to_lowercase().contains(hint), "{s:?} names {hint:?}");
            }
        }
        assert_eq!(seen.len(), Problem::ALL.len());
    }

    #[test]
    fn mac_checks_are_argument_lists_with_absolute_tools() {
        let app = Path::new(concat!("/Applications/.rex-duo-helper-update-1/unpacked/", crate::beacon_name!(), ".app"));
        let checks = mac_checks(app);
        assert_eq!(checks[0].0, "/usr/bin/codesign");
        assert_eq!(checks[0].1, [os("--verify"), os("--deep"), os("--strict"), os(app)]);
        let req = checks[1].1[1].to_string_lossy().into_owned();
        assert_eq!(
            req,
            "-R=identifier \"dev.abrahamgonzalez.rexduo.helper\" and anchor apple generic and \
             certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists \
             and certificate leaf[subject.OU] = \"R2PVQ496X7\""
        );
        assert_eq!(checks[1].1.last(), Some(&os(app)));
        let (program, args) = gatekeeper_check(app);
        assert_eq!(program, "/usr/sbin/spctl");
        assert_eq!(args, [os("--assess"), os("--type"), os("execute"), os("-vv"), os(app)]);
        // The path with its space is one argument, whatever it holds.
        assert!(checks.iter().all(|(p, a)| p.starts_with('/') && a.last() == Some(&os(app))));
    }

    #[test]
    fn gatekeeper_must_say_notarized() {
        let accepted = concat!("/Applications/", crate::beacon_name!(), ".app: accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: A (R2PVQ496X7)\n");
        assert!(gatekeeper_ok(true, accepted));
        assert!(!gatekeeper_ok(false, accepted));
        assert!(!gatekeeper_ok(true, "x.app: accepted\nsource=Developer ID\n"));
        assert!(!gatekeeper_ok(true, "x.app: accepted\nsource=Unnotarized Developer ID\n"));
        assert!(!gatekeeper_ok(true, "x.app: accepted\nsource=Mac App Store\n"));
        assert!(!gatekeeper_ok(true, "/tmp/source=Notarized Developer ID.app: accepted\nsource=no usable signature\n"));
        assert!(!gatekeeper_ok(true, ""));
    }

    #[test]
    fn a_manifest_near_its_end_is_reported_and_logged() {
        crate::util::testing::capture_log();
        let now = EXPIRES - 31 * 86_400;
        assert!(!note_expiry(EXPIRES, now));
        assert!(!note_expiry(EXPIRES, EXPIRES - EXPIRY_NOTICE));
        assert_eq!(crate::util::testing::captured_log(), "");
        assert!(note_expiry(EXPIRES, EXPIRES - EXPIRY_NOTICE + 1));
        let line = crate::util::testing::captured_log();
        assert_eq!(line, format!("update: the release list is valid until {}; its publisher has to sign it again before then", iso8601(EXPIRES)));
        assert_eq!(line.lines().count(), 1);

        let (_, public) = keypair();
        let dir = temp("expiry");
        let env = Env { dry_run: false, debug_build: false, keys: Ok(vec![public]), place: Err("test".into()), service: true, writable: true };
        let u = Updater::with_env(env, false, &dir);
        assert_eq!(u.status()["manifest_expires_at"], Value::Null);
        u.change(|s| s.manifest_expires_at = Some(EXPIRES));
        assert_eq!(u.status()["manifest_expires_at"], iso8601(EXPIRES));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_wait_after_a_check() {
        use Ended::{Passed, Refused, Unreachable};
        // The list could not be reached: about 15 minutes, 1 hour, 3 hours, then as usual.
        assert_eq!(next_wait(Unreachable, 1), Wait { base: 900, spread: 120 });
        assert_eq!(next_wait(Unreachable, 2), Wait { base: 3600, spread: 300 });
        assert_eq!(next_wait(Unreachable, 3), Wait { base: 10_800, spread: 900 });
        for later in [4, 5, 100, u32::MAX] {
            assert_eq!(next_wait(Unreachable, later), NORMAL_WAIT, "{later}");
        }
        assert_eq!(NORMAL_WAIT, Wait { base: 12 * 3600 - 1800, spread: 3600 });
        // A check that passed, and one whose list was refused, keep the normal schedule
        // however many came before.
        for failures in 0..6 {
            assert_eq!(next_wait(Passed, failures), NORMAL_WAIT);
            assert_eq!(next_wait(Refused, failures), NORMAL_WAIT);
        }
        // Each wait is its base plus less than its spread.
        for wait in RETRY_WAITS.into_iter().chain([NORMAL_WAIT]) {
            for _ in 0..50 {
                assert!((wait.base..wait.base + wait.spread).contains(&wait.pick()));
            }
        }

        // What each problem counts as.
        assert_eq!(Ended::of(None), Passed);
        assert_eq!(Ended::of(Some(Problem::NoBuild)), Passed);
        assert_eq!(Ended::of(Some(Problem::Unreachable)), Unreachable);
        for p in [Problem::Rejected, Problem::Expired, Problem::Replayed] {
            assert_eq!(Ended::of(Some(p)), Refused);
        }

        // The same through the state a run of checks leaves.
        let mut s = State::default();
        let mut after = |error: Option<Problem>| {
            s.checked(RELEASED, error);
            next_wait(s.ended, s.failures)
        };
        assert_eq!(after(Some(Problem::Unreachable)), RETRY_WAITS[0]);
        assert_eq!(after(Some(Problem::Unreachable)), RETRY_WAITS[1]);
        assert_eq!(after(Some(Problem::Unreachable)), RETRY_WAITS[2]);
        assert_eq!(after(Some(Problem::Unreachable)), NORMAL_WAIT);
        assert_eq!(after(Some(Problem::Unreachable)), NORMAL_WAIT);
        // A check that passes starts the count again.
        assert_eq!(after(None), NORMAL_WAIT);
        assert_eq!(after(Some(Problem::Unreachable)), RETRY_WAITS[0]);
        assert_eq!(after(Some(Problem::Unreachable)), RETRY_WAITS[1]);
        // A list that failed verification is on the normal schedule, and so is the count.
        for refused in [Problem::Rejected, Problem::Expired, Problem::Replayed] {
            assert_eq!(after(Some(refused)), NORMAL_WAIT);
        }
        assert_eq!(after(Some(Problem::Unreachable)), RETRY_WAITS[0]);
    }

    #[test]
    fn the_wait_counts_from_the_last_check() {
        assert_eq!(time_left(None, 900, RELEASED), 900);
        assert_eq!(time_left(Some(RELEASED), 900, RELEASED), 900);
        assert_eq!(time_left(Some(RELEASED), 900, RELEASED + 300), 600);
        assert_eq!(time_left(Some(RELEASED), 900, RELEASED + 900), 0);
        assert_eq!(time_left(Some(RELEASED), 900, RELEASED + 5000), 0);
        // A clock that went back never makes the wait longer than it is.
        assert_eq!(time_left(Some(RELEASED), 900, RELEASED - 5000), 900);
        assert_eq!(time_left(Some(i64::MAX), u64::MAX, i64::MIN), i64::MAX as u64);
    }

    fn test_updater(dir: &Path) -> Arc<Updater> {
        let (_, public) = keypair();
        let env = Env { dry_run: false, debug_build: false, keys: Ok(vec![public]), place: Err("test".into()), service: true, writable: true };
        Updater::with_env(env, false, dir)
    }

    #[test]
    fn failing_since_is_when_the_run_of_failed_checks_began() {
        let dir = temp("failing");
        let u = test_updater(&dir);
        assert_eq!(u.status()["failing_since"], Value::Null);
        // Set by the first failed check, and left alone by the ones after it, of either kind.
        u.change(|s| s.checked(RELEASED, Some(Problem::Unreachable)));
        assert_eq!(u.status()["failing_since"], RELEASED);
        u.change(|s| s.checked(RELEASED + 900, Some(Problem::Unreachable)));
        u.change(|s| s.checked(RELEASED + 4500, Some(Problem::Expired)));
        let s = u.status();
        assert_eq!(s["failing_since"], RELEASED);
        assert_eq!(s["checked_at"], iso8601(RELEASED + 4500));
        assert_eq!(s["last_error"], "The release list is out of date.");
        // A check that passes clears it and the error.
        u.change(|s| s.checked(RELEASED + 9000, None));
        let s = u.status();
        assert_eq!((&s["failing_since"], &s["last_error"]), (&Value::Null, &Value::Null));
        assert_eq!(s["checked_at"], iso8601(RELEASED + 9000));
        // The next run has its own beginning.
        u.change(|s| s.checked(RELEASED + 9500, Some(Problem::Rejected)));
        assert_eq!(u.status()["failing_since"], RELEASED + 9500);
        // A list that was accepted is a check that passed, with or without a build in it.
        u.change(|s| s.checked(RELEASED + 9600, Some(Problem::NoBuild)));
        let s = u.status();
        assert_eq!(s["failing_since"], Value::Null);
        assert_eq!(s["last_error"], "The newest version has no build for this computer.");
        // A version that was rolled back stays the error after a check that passed.
        u.change(|s| {
            s.failed_version = Some("999.0.0".into());
            s.checked(RELEASED + 9700, None);
        });
        assert_eq!(u.status()["last_error"], Problem::RolledBack.sentence());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_service_takes_a_newer_check_from_the_command_line() {
        let dir = temp("taken");
        let t = now() as i64 - 10_000;
        let service = test_updater(&dir);
        let changes = Arc::new(Mutex::new(0));
        let counter = changes.clone();
        service.set_on_change(move || *counter.lock().unwrap() += 1);
        // No file: nothing to take.
        assert!(!service.take_command_result());
        // The service has failed three times to reach the list.
        for n in 0..3 {
            service.change(|s| s.checked(t + n * 100, Some(Problem::Unreachable)));
        }
        assert_eq!(service.schedule(), (Some(t + 200), RETRY_WAITS[2]));
        *changes.lock().unwrap() = 0;

        // The command, a process of its own with its own state, checks and passes.
        let command = test_updater(&dir);
        command.report_check();
        assert!(!dir.join(CHECK_FILE).exists(), "nothing is reported before a check");
        command.change(|s| {
            s.latest_version = Some("999.0.0".into());
            s.min_version = Some("0.3.0".into());
            s.manifest_expires_at = Some(EXPIRES);
            s.checked(t + 500, None);
        });
        command.report_check();
        let file: Value = serde_json::from_slice(&std::fs::read(dir.join(CHECK_FILE)).unwrap()).unwrap();
        assert_eq!(
            file,
            json!({"checked_at": iso8601(t + 500), "latest_version": "999.0.0", "min_version": "0.3.0", "manifest_expires_at": iso8601(EXPIRES), "error": null})
        );

        // The service shows that result, tells its listener, and is back on the normal schedule.
        assert!(service.take_command_result());
        assert_eq!(*changes.lock().unwrap(), 1);
        let s = service.status();
        assert_eq!((&s["last_error"], &s["failing_since"]), (&Value::Null, &Value::Null));
        assert_eq!(s["checked_at"], iso8601(t + 500));
        assert_eq!((s["latest_version"].as_str(), s["update_available"].as_bool()), (Some("999.0.0"), Some(true)));
        assert_eq!((s["min_version"].as_str(), s["manifest_expires_at"].as_str()), (Some("0.3.0"), Some(iso8601(EXPIRES).as_str())));
        assert_eq!(service.schedule(), (Some(t + 500), NORMAL_WAIT));
        // The same file is taken once.
        assert!(!service.take_command_result());
        assert_eq!(*changes.lock().unwrap(), 1);

        // A command whose check failed: the error and the time are taken, what was known of
        // the newest version stays, and the schedule is the normal one from that check.
        command.change(|s| s.checked(t + 600, Some(Problem::Unreachable)));
        command.report_check();
        assert!(service.take_command_result());
        let s = service.status();
        assert_eq!(s["last_error"], "The release list could not be downloaded.");
        assert_eq!((s["checked_at"].as_str(), s["failing_since"].as_i64()), (Some(iso8601(t + 600).as_str()), Some(t + 600)));
        assert_eq!(s["latest_version"], "999.0.0");
        assert_eq!(service.schedule(), (Some(t + 600), NORMAL_WAIT));
        // The service's own next failure is then the first of its run.
        service.change(|s| s.checked(t + 700, Some(Problem::Unreachable)));
        assert_eq!(service.schedule(), (Some(t + 700), RETRY_WAITS[0]));
        assert_eq!(service.status()["failing_since"], t + 600);

        // Before any check of its own, a service takes what the command found.
        let fresh = test_updater(&dir);
        assert!(fresh.take_command_result());
        assert_eq!(fresh.status()["checked_at"], iso8601(t + 600));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn an_older_malformed_or_oversized_command_result_is_ignored() {
        let dir = temp("ignored");
        let t = now() as i64 - 10_000;
        let service = test_updater(&dir);
        service.change(|s| {
            s.latest_version = Some("0.3.1".into());
            s.checked(t, Some(Problem::Expired));
        });
        let before = service.status();
        let changes = Arc::new(Mutex::new(0));
        let counter = changes.clone();
        service.set_on_change(move || *counter.lock().unwrap() += 1);
        let path = dir.join(CHECK_FILE);
        let good = |at: i64| json!({"checked_at": iso8601(at), "latest_version": "999.0.0", "min_version": "0.3.0", "manifest_expires_at": iso8601(EXPIRES), "error": null});
        let offered = |v: &Value| {
            std::fs::write(&path, v.to_string()).unwrap();
            service.take_command_result()
        };

        // Older than the service's own check, and of the same second.
        assert!(!offered(&good(t - 1)));
        assert!(!offered(&good(t)));
        // From the future.
        assert!(!offered(&good(now() as i64 + 3600)));
        assert!(!service.take_command_result_at(t));
        // A field off.
        let broken = |edit: &dyn Fn(&mut Value)| {
            let mut v = good(t + 1);
            edit(&mut v);
            v
        };
        for (why, v) in [
            ("no time", broken(&|v| v["checked_at"] = Value::Null)),
            ("a time as a number", broken(&|v| v["checked_at"] = json!(t + 1))),
            ("a time spelled another way", broken(&|v| v["checked_at"] = json!("2026-11-17 12:00:00"))),
            ("not a version", broken(&|v| v["latest_version"] = json!("latest"))),
            ("a version as a number", broken(&|v| v["latest_version"] = json!(1))),
            ("not a minimum version", broken(&|v| v["min_version"] = json!("0.3"))),
            ("not an expiry", broken(&|v| v["manifest_expires_at"] = json!("never"))),
            ("an unknown error", broken(&|v| v["error"] = json!("Something else went wrong."))),
            ("an error that no check ends with", broken(&|v| v["error"] = json!(Problem::Install.sentence()))),
            ("an error as a number", broken(&|v| v["error"] = json!(7))),
            ("passed without a version", broken(&|v| v["latest_version"] = Value::Null)),
            ("a list", json!([good(t + 1)])),
        ] {
            assert!(!offered(&v), "{why}");
        }
        for junk in ["", "not json", "{", "null"] {
            std::fs::write(&path, junk).unwrap();
            assert!(!service.take_command_result(), "{junk:?}");
        }
        // Larger than the file ever is, though what it says is in order.
        let padded = format!("{}{}", good(t + 1), " ".repeat(MAX_CHECK_FILE as usize));
        std::fs::write(&path, &padded).unwrap();
        assert!(!service.take_command_result());
        // Not a regular file.
        std::fs::remove_file(&path).unwrap();
        std::fs::write(dir.join("elsewhere.json"), good(t + 1).to_string()).unwrap();
        std::os::unix::fs::symlink(dir.join("elsewhere.json"), &path).unwrap();
        assert!(!service.take_command_result());
        std::fs::remove_file(&path).unwrap();
        std::fs::create_dir(&path).unwrap();
        assert!(!service.take_command_result());
        std::fs::remove_dir(&path).unwrap();

        // Through all of it the service kept its own result and told nobody of a change.
        assert_eq!(service.status(), before);
        assert_eq!(*changes.lock().unwrap(), 0);
        // The same result, in order and one second newer, is taken.
        assert!(offered(&good(t + 1)));
        assert_eq!(service.status()["latest_version"], "999.0.0");
        // A failed check names no version, and each sentence a check can end with is read back.
        for p in CHECK_PROBLEMS {
            let r = Reported { at: t, latest_version: None, min_version: None, manifest_expires_at: None, error: Some(p) };
            let parsed = Reported::parse(r.json().to_string().as_bytes());
            assert_eq!(parsed, (p != Problem::NoBuild).then_some(r), "{p:?}");
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn the_command_result_is_private_and_written_whole() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temp("checkfile");
        let command = test_updater(&dir);
        let path = dir.join(CHECK_FILE);
        let tmp = dir.join(format!("{CHECK_FILE}.tmp"));
        let names = || {
            let mut names: Vec<String> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
            names.sort();
            names
        };
        let t = now() as i64 - 100;
        command.change(|s| s.checked(t, Some(Problem::Rejected)));
        command.report_check();
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(names(), [CHECK_FILE], "the temporary file was renamed into place");
        let first = std::fs::read(&path).unwrap();
        assert!((first.len() as u64) < MAX_CHECK_FILE);
        assert_eq!(Reported::parse(&first).unwrap().error, Some(Problem::Rejected));
        // It holds the five fields the status shows, and nothing else.
        let v: Value = serde_json::from_slice(&first).unwrap();
        let keys: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(keys, ["checked_at", "error", "latest_version", "manifest_expires_at", "min_version"]);

        // The next result replaces the file by a rename: the name then belongs to another
        // file, and the one a reader had open is unchanged. A temporary file left by a
        // process that died, readable by others, is not reused.
        use std::os::unix::fs::MetadataExt;
        let open = std::fs::File::open(&path).unwrap();
        let inode = std::fs::metadata(&path).unwrap().ino();
        std::fs::write(&tmp, "left behind").unwrap();
        std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o644)).unwrap();
        command.change(|s| {
            s.latest_version = Some("999.0.0".into());
            s.checked(t + 50, None);
        });
        command.report_check();
        assert_ne!(std::fs::metadata(&path).unwrap().ino(), inode);
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        assert_eq!(names(), [CHECK_FILE]);
        let mut still = Vec::new();
        std::io::Read::read_to_end(&mut &open, &mut still).unwrap();
        assert_eq!(still, first);
        assert_eq!(Reported::parse(&std::fs::read(&path).unwrap()).unwrap().at, t + 50);
        // The longest result there is fits the limit a reader sets.
        let longest = Reported { at: t, latest_version: Some("999999999.999999999.999999999".into()), min_version: Some("999999999.999999999.999999999".into()), manifest_expires_at: Some(EXPIRES), error: Some(Problem::Replayed) };
        assert!((serde_json::to_vec_pretty(&longest.json()).unwrap().len() as u64) < MAX_CHECK_FILE / 2);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn status_and_the_memory_of_a_failed_update() {
        let (_, public) = keypair();
        let dir = temp("status");
        let env = || Env {
            dry_run: false,
            debug_build: false,
            keys: Ok(vec![public]),
            place: Ok(Place::LinuxBinary("/home/u/.local/bin/rex-duo-helper".into())),
            service: true,
            writable: true,
        };
        let u = Updater::with_env(env(), true, &dir);
        assert_eq!(
            u.status(),
            json!({"version": VERSION, "latest_version": null, "min_version": null, "update_available": false, "update_required": false,
                "checked_at": null, "manifest_expires_at": null, "updating": false, "can_update": true, "last_error": null, "failing_since": null})
        );
        assert!(u.auto);
        assert!(!Updater::with_env(env(), false, &dir).auto, "auto_update: false turns the timer off");
        assert!(!Updater::with_env(Env { dry_run: true, ..env() }, true, &dir).auto);
        let dry = Updater::with_env(Env { dry_run: true, ..env() }, true, &dir);
        assert_eq!(dry.status()["can_update"], false);
        assert_eq!(dry.blocker().unwrap().problem, Problem::CannotUpdate);

        let changes = Arc::new(Mutex::new(0));
        let counter = changes.clone();
        u.set_on_change(move || *counter.lock().unwrap() += 1);
        u.change(|s| {
            s.latest_version = Some("999.0.0".into());
            s.min_version = Some(VERSION.into());
            s.checked_at = Some("2026-11-17T12:00:00Z".into());
        });
        assert_eq!(*changes.lock().unwrap(), 1);
        let s = u.status();
        assert_eq!((s["latest_version"].as_str(), s["update_available"].as_bool()), (Some("999.0.0"), Some(true)));
        assert_eq!(s["checked_at"], "2026-11-17T12:00:00Z");
        // A newer release that still works with this one: available, not required.
        assert_eq!((s["min_version"].as_str(), s["update_required"].as_bool()), (Some(VERSION), Some(false)));
        // One that names a higher minimum: this helper is too old.
        u.change(|s| s.min_version = Some("998.0.0".into()));
        let s = u.status();
        assert_eq!((s["min_version"].as_str(), s["update_required"].as_bool()), (Some("998.0.0"), Some(true)));
        // What went wrong reaches the app as one fixed sentence.
        u.change(|s| s.last_error = Some(Problem::Expired));
        assert_eq!(u.status()["last_error"], "The release list is out of date.");

        // A version that was rolled back is remembered by the helper that starts next. The
        // details stay in update_result.json and the log.
        record_result(&dir, "999.0.0", &Err(concat!("Version 999.0.0 did not start: /Applications/", crate::beacon_name!(), ".app is damaged.").into()));
        let next = Updater::with_env(env(), true, &dir);
        assert_eq!(next.state.lock().unwrap().failed_version.as_deref(), Some("999.0.0"));
        assert_eq!(next.status()["last_error"], "The new version did not start, so the previous version was put back.");
        assert!(dir.join(RESULT_FILE).exists());
        // An update that worked, or one this helper is already past, leaves nothing behind.
        record_result(&dir, "999.0.0", &Ok(()));
        assert_eq!(Updater::with_env(env(), true, &dir).status()["last_error"], Value::Null);
        assert!(!dir.join(RESULT_FILE).exists());
        record_result(&dir, "0.0.1", &Err("old news".into()));
        assert_eq!(failed_update(&dir, VERSION), None);
        assert!(!dir.join(RESULT_FILE).exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
