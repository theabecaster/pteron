//! Registered phones (devices.json) and "is Rex DUO open on this phone right now?".

use crate::auth::is_device_id;
use crate::debug;
use crate::info;
use crate::net::Url;
use crate::notice::SeenDevices;
use crate::util::{now_iso, sha256_hex, Json};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

/// One phone that asked for pushes: where its push gateway is and the secret that lets this
/// helper push to it, and to no other phone. The helper never sees an APNs token.
#[derive(Clone, PartialEq, Serialize, Deserialize)]
pub struct Device {
    /// The app's install id (8 hex), which it also puts at the end of its Rex client label
    /// ("… #<id>"). One registration per id.
    pub device_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_name: Option<String>,
    /// sandbox | production. Informational: the gateway knows which APNs host the phone is on.
    pub environment: String,
    /// The gateway's origin (`https://host`), one the helper's allowlist holds.
    pub gateway: String,
    /// Who registered it, as the Rex server identified them (`auth::identity_of`). Only the
    /// same identity may replace or remove this registration.
    pub owner: String,
    /// Sent as the bearer token of every push to this phone. Never logged.
    pub push_secret: String,
    /// True while the phone's user has notifications from this computer switched off
    /// (`set_push_paused`). A paused phone is sent nothing; the rest of its registration
    /// stays, so switching back on needs nothing new from the gateway.
    #[serde(default)]
    pub paused: bool,
    #[serde(default)]
    pub registered_at: String,
    #[serde(default)]
    pub updated_at: String,
}

/// Leaves the secret out, so a `{:?}` in a log line or a failed assertion can't leak it.
impl std::fmt::Debug for Device {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Device")
            .field("device_id", &self.device_id)
            .field("device_name", &self.device_name)
            .field("environment", &self.environment)
            .field("gateway", &self.gateway)
            .field("owner", &self.owner)
            .field("paused", &self.paused)
            .finish_non_exhaustive()
    }
}

/// True for a stored gateway address the helper could send to at all. Whether it is still
/// one the helper may push through is the allowlist's call (`DeviceStore::keep_gateways`).
fn gateway_usable(s: &str) -> bool {
    Url::parse(s).is_some_and(|u| u.secure || u.is_loopback())
}

/// What the helper keeps of a secret it must recognise again without holding on to it.
pub fn secret_hash(secret: &str) -> String {
    sha256_hex(secret.as_bytes())
}

/// How long after a first `401` a second one must come before the secret is given up.
pub const STRIKE_GAP: f64 = 60.0;

/// The gateway's `401` answers per secret (by hash), kept in memory. One `401` can be a
/// passing fault at the gateway; a second one a minute or more later means the phone really
/// took the secret back.
#[derive(Debug, Default)]
pub struct Strikes(HashMap<String, f64>);

impl Strikes {
    /// Notes a `401` for this secret at `now`. True when it is the second one at least
    /// `STRIKE_GAP` after the first: drop the registration.
    pub fn refused(&mut self, hash: &str, now: f64) -> bool {
        match self.0.get(hash) {
            Some(first) if now - first >= STRIKE_GAP => {
                self.0.remove(hash);
                true
            }
            Some(_) => false,
            None => {
                self.0.insert(hash.to_string(), now);
                false
            }
        }
    }

    /// The gateway took the secret again, or the registration is gone: start over.
    pub fn clear(&mut self, hash: &str) {
        self.0.remove(hash);
    }
}

impl Device {
    pub fn new(device_id: &str, gateway: &str, push_secret: &str, environment: &str, owner: &str) -> Device {
        let now = now_iso();
        Device {
            device_id: device_id.into(),
            device_name: None,
            environment: environment.into(),
            gateway: gateway.into(),
            owner: owner.into(),
            push_secret: push_secret.into(),
            paused: false,
            registered_at: now.clone(),
            updated_at: now,
        }
    }

    /// The gateway hands out 43 base64url characters. Anything else that could sit in a header
    /// and a JSON file is refused.
    pub fn is_valid_secret(s: &str) -> bool {
        (16..=128).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    }

    /// An entry of devices.json this helper can use. One written before the gateway (it has an
    /// APNs token and no secret) is not, and neither is one that doesn't say who registered it.
    fn usable(&self) -> bool {
        is_device_id(&self.device_id) && Device::is_valid_secret(&self.push_secret) && gateway_usable(&self.gateway) && !self.owner.is_empty()
    }

    /// The name for log lines.
    pub fn who(&self) -> String {
        self.device_name.clone().unwrap_or_else(|| format!("#{}", self.device_id))
    }
}

/// devices.json: the registered phones, one per device id. Next to it, seen_devices.json: every
/// device id that ever registered, which outlives an unregister; and dropped_secrets.json: the
/// hashes of secrets the gateway refused.
pub struct DeviceStore {
    pub path: PathBuf,
    pub devices: Vec<Device>,
    seen: SeenDevices,
    /// SHA-256 of secrets the gateway refused, oldest first. Never the secrets themselves.
    dropped: Vec<String>,
    /// A dry run keeps the seen ids in memory only, so it doesn't use up a phone's notice.
    dry_run: bool,
    /// What devices.json looked like when this process last read or wrote it, to notice when
    /// `rex-duo-helper forget` changed it.
    stamp: Option<Stamp>,
}

/// Inode, size and modification time. Every write goes through a rename, so the inode alone
/// changes with each one.
type Stamp = (u64, u64, std::time::SystemTime);

fn stamp(path: &Path) -> Option<Stamp> {
    use std::os::unix::fs::MetadataExt;
    let m = std::fs::metadata(path).ok()?;
    Some((m.ino(), m.len(), m.modified().ok()?))
}

/// The most refused secrets remembered. Past it the oldest goes: by then the phone has long
/// had a new one.
pub const DROPPED_LIMIT: usize = 256;

pub(crate) fn read_json<T: serde::de::DeserializeOwned + Default>(path: &Path) -> T {
    match std::fs::read(path) {
        Ok(data) => serde_json::from_slice(&data).unwrap_or_else(|e| {
            info!("could not read {}: {e}", path.display());
            T::default()
        }),
        Err(_) => T::default(),
    }
}

/// Writes through a temporary file that only this user can read from the moment it exists.
pub(crate) fn write_json<T: Serialize + ?Sized>(path: &Path, value: &T) {
    let _ = try_write_json(path, value);
}

/// `write_json` for a caller that acts on a failure. The failure is logged here either way.
fn try_write_json<T: Serialize + ?Sized>(path: &Path, value: &T) -> Result<(), String> {
    let write = || -> std::io::Result<()> {
        use std::io::Write;
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = path.with_extension("json.tmp");
        let _ = std::fs::remove_file(&tmp);
        let mut f = std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(&tmp)?;
        f.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        f.write_all(&serde_json::to_vec_pretty(value)?)?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)
    };
    write().map_err(|e| {
        let why = format!("could not write {}: {e}", path.display());
        info!("{why}");
        why
    })
}

const SEEN_FILE: &str = "seen_devices.json";
const DROPPED_FILE: &str = "dropped_secrets.json";

/// The usable entries of a devices.json, one per device id.
fn usable_devices(entries: &[Value]) -> Vec<Device> {
    let mut devices: Vec<Device> = vec![];
    for d in entries.iter().filter_map(|e| serde_json::from_value::<Device>(e.clone()).ok()) {
        if d.usable() && !is_registered(&devices, &d.device_id) {
            devices.push(d);
        }
    }
    devices
}

fn is_registered(devices: &[Device], id: &str) -> bool {
    devices.iter().any(|d| d.device_id == id)
}

impl DeviceStore {
    pub fn open(path: PathBuf) -> DeviceStore {
        DeviceStore::load(path, false)
    }

    /// `open` for `--dry-run`: never writes seen_devices.json, and leaves a devices.json from an
    /// older helper as it is.
    pub fn open_dry_run(path: PathBuf) -> DeviceStore {
        DeviceStore::load(path, true)
    }

    fn load(path: PathBuf, dry_run: bool) -> DeviceStore {
        let entries: Vec<Value> = read_json(&path);
        // Entries from before the push gateway hold an APNs token and no secret. They can't be
        // used any more, so they go; the phone registers again the next time its app connects.
        let devices = usable_devices(&entries);
        // A phone registered before seen_devices.json existed (an older helper) counts as seen,
        // and so does one whose old entry was just dropped.
        let on_disk = SeenDevices::new(read_json::<Vec<String>>(&path.with_file_name(SEEN_FILE)));
        let mut seen = on_disk.clone();
        for id in entries.iter().filter_map(|e| e.str("device_id")) {
            seen.observe_keeping(id, |s| is_registered(&devices, s));
        }
        let dropped: Vec<String> = read_json::<Vec<String>>(&path.with_file_name(DROPPED_FILE))
            .into_iter()
            .filter(|h| h.len() == 64 && h.bytes().all(|b| b.is_ascii_hexdigit()))
            .collect();
        let mut store = DeviceStore { stamp: stamp(&path), path, devices, seen, dropped, dry_run };
        if store.seen != on_disk {
            store.save_seen();
        }
        if store.devices.len() != entries.len() && !dry_run {
            debug!("dropped {} registration(s) this helper can't use", entries.len() - store.devices.len());
            let _ = store.save();
        }
        store
    }

    /// Writes devices.json. When that fails, the registrations in memory go back to the ones
    /// in the file, so what the helper does now and what it does after a restart are the same.
    fn save(&mut self) -> Result<(), String> {
        let written = try_write_json(&self.path, &self.devices);
        if written.is_err() {
            self.devices = usable_devices(&read_json::<Vec<Value>>(&self.path));
        }
        self.stamp = stamp(&self.path);
        written
    }

    /// Reads devices.json again if something else wrote it since this process last did:
    /// `rex-duo-helper forget` removes a phone while the helper runs. Called before the
    /// registrations are used.
    pub fn sync(&mut self) {
        let now = stamp(&self.path);
        if now != self.stamp {
            self.devices = usable_devices(&read_json::<Vec<Value>>(&self.path));
            self.stamp = now;
        }
    }

    /// Drops registrations whose gateway `allowed` no longer takes (it left config.json).
    /// Returns how many went.
    pub fn keep_gateways(&mut self, allowed: impl Fn(&str) -> bool) -> usize {
        let before = self.devices.len();
        self.devices.retain(|d| allowed(&d.gateway));
        if self.devices.len() < before && !self.dry_run {
            // A file that could not be written keeps them, and so does the helper.
            let _ = self.save();
        }
        before - self.devices.len()
    }

    /// The registration of a device id, if it has one.
    pub fn get(&self, device_id: &str) -> Option<&Device> {
        self.devices.iter().find(|d| d.device_id == device_id)
    }

    /// True when `identity` registered at least one phone here.
    pub fn owns_any(&self, identity: &str) -> bool {
        self.devices.iter().any(|d| d.owner == identity)
    }

    /// True for a secret the gateway refused. It can't be registered again.
    pub fn is_dropped(&self, secret: &str) -> bool {
        self.dropped.contains(&secret_hash(secret))
    }

    /// The gateway refused this secret for good: remembers its hash and removes the
    /// registration that still holds it (not one the phone has replaced meanwhile). True when
    /// a registration went. One that could not be taken out of the file stays; its secret is
    /// remembered as refused all the same.
    pub fn drop_secret(&mut self, device_id: &str, secret: &str) -> bool {
        let hash = secret_hash(secret);
        if !self.dropped.contains(&hash) {
            if self.dropped.len() >= DROPPED_LIMIT {
                self.dropped.remove(0);
            }
            self.dropped.push(hash);
            if !self.dry_run {
                write_json(&self.path.with_file_name(DROPPED_FILE), &self.dropped);
            }
        }
        let n = self.devices.len();
        self.devices.retain(|d| !(d.device_id == device_id && d.push_secret == secret));
        self.devices.len() < n && self.save().is_ok()
    }

    /// An array of ids, oldest first.
    fn save_seen(&self) {
        if !self.dry_run {
            write_json(&self.path.with_file_name(SEEN_FILE), &self.seen.ids().collect::<Vec<_>>());
        }
    }

    /// True the first time this device id registers: not after a new secret, an unregister or a
    /// restart. A full seen set drops its oldest id that isn't registered now.
    pub fn first_sight(&mut self, device_id: &str) -> bool {
        let devices = &self.devices;
        let new = self.seen.observe_keeping(device_id, |s| is_registered(devices, s));
        if new {
            self.save_seen();
        }
        new
    }

    /// Adds a phone, or replaces the registration its device id already has (the phone rotated
    /// its secret, or the app was installed again). An error when the file could not be
    /// written: the registrations are then as they were.
    pub fn register(&mut self, mut d: Device) -> Result<Device, String> {
        if let Some(old) = self.devices.iter().find(|o| o.device_id == d.device_id) {
            d.registered_at = old.registered_at.clone();
        }
        self.devices.retain(|o| o.device_id != d.device_id);
        self.devices.push(d.clone());
        self.save()?;
        Ok(d)
    }

    /// Pauses or resumes a registered phone and writes the file when the value changed. False
    /// when the device id has no registration. An error when the file could not be written:
    /// the phone then has the value it had.
    pub fn set_paused(&mut self, device_id: &str, paused: bool) -> Result<bool, String> {
        let Some(d) = self.devices.iter_mut().find(|d| d.device_id == device_id) else { return Ok(false) };
        if d.paused != paused {
            d.paused = paused;
            d.updated_at = now_iso();
            self.save()?;
        }
        Ok(true)
    }

    /// Removes a phone's registration. False when it has none. An error when the file could
    /// not be written: the phone is then still registered.
    pub fn remove(&mut self, device_id: &str) -> Result<bool, String> {
        let n = self.devices.len();
        self.devices.retain(|d| d.device_id != device_id);
        if self.devices.len() == n {
            return Ok(false);
        }
        self.save()?;
        Ok(true)
    }
}

/// `rex-duo-helper forget <device_id>`: removes a phone's registration from devices.json, for
/// when the account that registered it can no longer unregister it itself. The running helper
/// notices the file changed (`DeviceStore::sync`). True if the phone was registered.
pub fn forget(path: &Path, device_id: &str) -> Result<bool, String> {
    if !is_device_id(device_id) {
        return Err("a device id is 8 lowercase hex digits, as `rex-duo-helper status` and the log show it".into());
    }
    let mut devices = usable_devices(&read_json::<Vec<Value>>(path));
    let n = devices.len();
    devices.retain(|d| d.device_id != device_id);
    if devices.len() == n {
        return Ok(false);
    }
    write_json(path, &devices);
    Ok(true)
}

/// A connected client, as `client.list` reports it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ClientSnapshot {
    pub client_id: String,
    pub kind: Option<String>,
    pub platform: Option<String>,
    pub name: Option<String>,
    pub label: Option<String>,
    pub connection_state: Option<String>,
}

impl ClientSnapshot {
    pub fn parse(c: &Value) -> Option<ClientSnapshot> {
        let id = c.str("client_id")?;
        let info = c.obj("info").cloned().unwrap_or(Value::Null);
        let s = |v: &Value, k: &str| v.str(k).map(String::from);
        Some(ClientSnapshot {
            client_id: id.into(),
            kind: s(&info, "kind"),
            platform: s(&info, "platform"),
            name: s(&info, "name"),
            label: s(&info, "label"),
            connection_state: s(c, "connection_state"),
        })
    }
}

/// The device id at the end of a label: "Alex's iPhone #a1b2c3d4" -> "a1b2c3d4".
pub fn device_id_from_label(label: Option<&str>) -> Option<String> {
    let label = label?;
    let id = label[label.rfind('#')? + 1..].trim().to_lowercase();
    is_device_id(&id).then_some(id)
}

/// True if an iOS app client from this device is connected and hasn't said it's in the
/// background. A client matches by the "#<device_id>" at the end of its label.
pub fn is_app_open(d: &Device, clients: &[ClientSnapshot], backgrounded: &HashSet<String>) -> bool {
    clients.iter().any(|c| {
        c.kind.as_deref() == Some("app")
            && c.platform.as_deref() == Some("ios")
            && c.connection_state.as_deref() != Some("lost")
            && !backgrounded.contains(&c.client_id)
            && device_id_from_label(c.label.as_deref()).is_some_and(|id| id == d.device_id)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const GATEWAY: &str = "https://push.example.workers.dev";

    fn secret(c: char) -> String {
        c.to_string().repeat(43)
    }

    const OWNER: &str = "tailscale:12345";

    fn phone(id: &str, c: char) -> Device {
        Device::new(id, GATEWAY, &secret(c), "sandbox", OWNER)
    }

    fn dev() -> Device {
        phone("a1b2c3d4", 's')
    }

    /// An entry as the helper wrote it before the gateway: a token, no secret.
    fn legacy(id: &str) -> Value {
        json!({"device_id": id, "device_name": "iPhone", "environment": "sandbox",
            "registered_at": "2026-11-16T19:56:39Z", "tailscale_node": "iphone194",
            "token": "4514dd00000000000000000000000000", "updated_at": "2026-11-16T22:40:18Z"})
    }

    fn app(id: &str, label: &str, state: &str, platform: &str) -> ClientSnapshot {
        ClientSnapshot {
            client_id: id.into(),
            kind: Some("app".into()),
            platform: Some(platform.into()),
            name: Some("Rex DUO".into()),
            label: Some(label.into()),
            connection_state: Some(state.into()),
        }
    }

    fn none() -> HashSet<String> {
        HashSet::new()
    }

    #[test]
    fn label_device_id() {
        assert_eq!(device_id_from_label(Some("Alex's iPhone #A1B2C3D4")).as_deref(), Some("a1b2c3d4"));
        assert_eq!(device_id_from_label(Some("Alex's iPhone")), None);
        assert_eq!(device_id_from_label(Some("Room #1")), None);
    }

    #[test]
    fn matches_by_label_device_id() {
        assert!(is_app_open(&dev(), &[app("c1", "iPhone #a1b2c3d4", "connected", "ios")], &none()));
        assert!(is_app_open(&dev(), &[app("c1", "iPhone #A1B2C3D4", "connected", "ios")], &none()));
        assert!(!is_app_open(&dev(), &[app("c1", "iPhone #ffff0000", "connected", "ios")], &none()));
        assert!(!is_app_open(&dev(), &[app("c1", "iPhone", "connected", "ios")], &none()));
    }

    #[test]
    fn ignores_lost_backgrounded_and_non_ios() {
        assert!(!is_app_open(&dev(), &[app("c1", "x #a1b2c3d4", "lost", "ios")], &none()));
        let bg: HashSet<String> = ["c1".to_string()].into();
        assert!(!is_app_open(&dev(), &[app("c1", "x #a1b2c3d4", "connected", "ios")], &bg));
        assert!(!is_app_open(&dev(), &[app("c1", "x #a1b2c3d4", "connected", "macos")], &none()));
    }

    #[test]
    fn client_snapshot_parsing() {
        let c = ClientSnapshot::parse(&json!({"client_id": "client:1", "connection_state": "connected",
            "info": {"kind": "app", "platform": "ios", "label": "iPhone #abcd1234"},
            "principal": {"kind": "tailscale", "node": "alexs-iphone"}}))
        .unwrap();
        assert_eq!(c.label.as_deref(), Some("iPhone #abcd1234"));
        assert_eq!(c.connection_state.as_deref(), Some("connected"));
    }

    fn temp_store(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("seen-{tag}-{}-{}", std::process::id(), crate::util::now()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("devices.json")
    }

    fn on_disk(path: &Path) -> Vec<Value> {
        serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap()
    }

    #[test]
    fn device_store_round_trip() {
        let path = temp_store("round");
        let mut s = DeviceStore::open(path.clone());
        let first = s.register(phone("a1b2c3d4", 'a')).unwrap();
        // Same device id, new secret: replaces the old entry and keeps when it first registered.
        let mut again = phone("a1b2c3d4", 'b');
        again.registered_at = "later".into();
        s.register(again).unwrap();
        s.register(phone("ffff0000", 'c')).unwrap();
        let loaded = DeviceStore::open(path.clone()).devices;
        assert_eq!(loaded.len(), 2);
        assert_eq!(loaded[0].push_secret, secret('b'));
        assert_eq!(loaded[0].registered_at, first.registered_at);
        assert!(!s.remove("00000000").unwrap());
        assert!(!s.remove("A1B2C3D4").unwrap(), "ids are lowercase");
        assert!(s.remove("a1b2c3d4").unwrap());
        assert_eq!(DeviceStore::open(path.clone()).devices, vec![s.devices[0].clone()]);
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn the_file_has_the_new_shape_and_only_its_owner_reads_it() {
        use std::os::unix::fs::PermissionsExt;
        let path = temp_store("shape");
        let mut d = dev();
        d.device_name = Some("Alex's iPhone".into());
        DeviceStore::open(path.clone()).register(d).unwrap();
        let file = on_disk(&path);
        let keys: Vec<&str> = file[0].as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(keys, ["device_id", "device_name", "environment", "gateway", "owner", "paused", "push_secret", "registered_at", "updated_at"]);
        assert_eq!(file[0]["paused"], false);
        assert_eq!(file[0]["owner"], OWNER);
        assert_eq!(file[0]["gateway"], GATEWAY);
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
        assert!(!path.with_extension("json.tmp").exists());
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn a_pause_is_stored_with_the_phone_and_survives_a_reload() {
        let path = temp_store("paused");
        let mut s = DeviceStore::open(path.clone());
        s.register(phone("a1b2c3d4", 'a')).unwrap();
        s.register(phone("ffff0000", 'b')).unwrap();
        assert!(s.set_paused("a1b2c3d4", true).unwrap());
        assert!(!s.set_paused("00000000", true).unwrap(), "no such phone");
        assert_eq!(on_disk(&path)[0]["paused"], true);
        assert!(!path.with_extension("json.tmp").exists());
        // The next start reads it back, with the secret and everything else as it was.
        let mut again = DeviceStore::open(path.clone());
        let paused: Vec<bool> = again.devices.iter().map(|d| d.paused).collect();
        assert_eq!(paused, [true, false]);
        assert_eq!(again.devices, s.devices);
        assert_eq!(again.get("a1b2c3d4").unwrap().push_secret, secret('a'));
        // Setting the value it already has writes nothing.
        let before = stamp(&path);
        assert!(again.set_paused("a1b2c3d4", true).unwrap());
        assert_eq!(stamp(&path), before);
        assert!(again.set_paused("a1b2c3d4", false).unwrap());
        assert!(DeviceStore::open(path.clone()).devices.iter().all(|d| !d.paused));
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn a_file_without_the_paused_field_reads_as_not_paused() {
        let path = temp_store("nopause");
        let mut entry = serde_json::to_value(dev()).unwrap();
        entry.as_object_mut().unwrap().remove("paused");
        std::fs::write(&path, json!([entry]).to_string()).unwrap();
        let s = DeviceStore::open(path.clone());
        assert_eq!(s.devices, vec![dev_at(&entry)]);
        assert!(!s.devices[0].paused);
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    /// `dev()` with the times of a stored entry.
    fn dev_at(entry: &Value) -> Device {
        let mut d = dev();
        d.registered_at = entry["registered_at"].as_str().unwrap().into();
        d.updated_at = entry["updated_at"].as_str().unwrap().into();
        d
    }

    #[test]
    fn legacy_entries_are_dropped_on_load() {
        let path = temp_store("legacy");
        let mut bad_gateway = serde_json::to_value(phone("0000aaaa", 'x')).unwrap();
        bad_gateway["gateway"] = json!("http://push.example.com");
        let good = dev();
        // Written before registrations had an owner: nobody could be allowed to replace it.
        let mut no_owner = serde_json::to_value(phone("0000bbbb", 'y')).unwrap();
        no_owner.as_object_mut().unwrap().remove("owner");
        let mut bad_id = serde_json::to_value(phone("0000cccc", 'z')).unwrap();
        bad_id["device_id"] = json!("NOT-HEX1");
        let file = json!([legacy("ffa348c7"), serde_json::to_value(&good).unwrap(), bad_gateway, no_owner, bad_id, "junk"]);
        std::fs::write(&path, file.to_string()).unwrap();
        let mut s = DeviceStore::open(path.clone());
        assert_eq!(s.devices, vec![good]);
        // The file is rewritten without them, and stays readable.
        let rewritten = on_disk(&path);
        assert_eq!(rewritten.len(), 1);
        assert!(rewritten[0].get("token").is_none());
        // A phone that was registered with the old helper is not new to this computer.
        assert!(!s.first_sight("ffa348c7"));
        assert!(!DeviceStore::open(path.clone()).first_sight("ffa348c7"));
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn a_dry_run_leaves_an_old_file_alone() {
        let path = temp_store("legacydry");
        let file = json!([legacy("ffa348c7")]).to_string();
        std::fs::write(&path, &file).unwrap();
        assert!(DeviceStore::open_dry_run(path.clone()).devices.is_empty());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), file);
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn first_sight_once_per_device_id() {
        let path = temp_store("once");
        let mut s = DeviceStore::open(path.clone());
        assert!(s.first_sight("a1b2c3d4"));
        s.register(phone("a1b2c3d4", 'a')).unwrap();
        // Again, and with a new secret.
        assert!(!s.first_sight("a1b2c3d4"));
        s.register(phone("a1b2c3d4", 'c')).unwrap();
        assert!(!s.first_sight("a1b2c3d4"));
        assert!(s.first_sight("ffff0000"));
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn ids_in_an_existing_devices_file_are_seen() {
        let path = temp_store("upgrade");
        std::fs::write(&path, serde_json::to_vec(&vec![phone("a1b2c3d4", 'a'), phone("ffff0000", 'c')]).unwrap()).unwrap();
        let mut s = DeviceStore::open(path.clone());
        assert!(!s.first_sight("a1b2c3d4"));
        assert!(!s.first_sight("ffff0000"));
        // Still seen once the phone is gone from devices.json, in this run and the next.
        assert!(s.remove("a1b2c3d4").unwrap());
        assert!(!s.first_sight("a1b2c3d4"));
        assert!(!DeviceStore::open(path.clone()).first_sight("a1b2c3d4"));
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn unregister_then_register_is_not_new() {
        let path = temp_store("unregister");
        let mut s = DeviceStore::open(path.clone());
        assert!(s.first_sight("a1b2c3d4"));
        s.register(phone("a1b2c3d4", 'a')).unwrap();
        assert!(s.remove("a1b2c3d4").unwrap());
        assert!(!s.first_sight("a1b2c3d4"));
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn seen_devices_survive_a_reload() {
        let path = temp_store("reload");
        let mut s = DeviceStore::open(path.clone());
        assert!(s.first_sight("a1b2c3d4"));
        // Never registered and nothing in devices.json: only seen_devices.json remembers it.
        let mut again = DeviceStore::open(path.clone());
        assert!(again.devices.is_empty());
        assert!(!again.first_sight("a1b2c3d4"));
        assert!(again.first_sight("ffff0000"));
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn a_dry_run_does_not_use_up_first_sight() {
        let path = temp_store("dry");
        std::fs::write(&path, serde_json::to_vec(&vec![phone("0000aaaa", 'e')]).unwrap()).unwrap();
        let mut dry = DeviceStore::open_dry_run(path.clone());
        assert!(dry.first_sight("a1b2c3d4"));
        dry.register(phone("a1b2c3d4", 'a')).unwrap();
        // Once per device in the run, and nothing on disk.
        assert!(!dry.first_sight("a1b2c3d4"));
        assert!(!dry.first_sight("0000aaaa"));
        assert!(!path.with_file_name(SEEN_FILE).exists());
        assert!(dry.remove("a1b2c3d4").unwrap());
        assert!(DeviceStore::open(path.clone()).first_sight("a1b2c3d4"));
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    fn seen_file(path: &Path) -> Vec<String> {
        serde_json::from_slice(&std::fs::read(path.with_file_name(SEEN_FILE)).unwrap()).unwrap()
    }

    #[test]
    fn seen_order_survives_a_reload() {
        let path = temp_store("order");
        let mut s = DeviceStore::open(path.clone());
        for id in ["ffff0000", "A1B2C3D4", "0000aaaa", "not an id"] {
            s.first_sight(id);
        }
        assert_eq!(seen_file(&path), ["ffff0000", "a1b2c3d4", "0000aaaa"]);
        let mut again = DeviceStore::open(path.clone());
        assert!(again.first_sight("77770000"));
        assert_eq!(seen_file(&path), ["ffff0000", "a1b2c3d4", "0000aaaa", "77770000"]);
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn a_full_seen_file_drops_its_oldest_id_but_not_a_registered_one() {
        use crate::notice::SEEN_LIMIT;
        let path = temp_store("cap");
        let ids: Vec<String> = (0..SEEN_LIMIT).map(|n| format!("{n:08x}")).collect();
        std::fs::write(path.with_file_name(SEEN_FILE), serde_json::to_vec(&ids).unwrap()).unwrap();
        let mut s = DeviceStore::open(path.clone());
        // The oldest id is a registered phone: the next oldest goes instead.
        s.register(phone(&ids[0], 'a')).unwrap();
        assert!(s.first_sight("ffff0000"));
        let on_disk = seen_file(&path);
        assert_eq!(on_disk.len(), SEEN_LIMIT);
        assert_eq!(on_disk[..2], [ids[0].clone(), ids[2].clone()]);
        assert_eq!(on_disk[SEEN_LIMIT - 1], "ffff0000");
        // In the next run too: the registered phone is not new, the dropped id is.
        let mut again = DeviceStore::open(path.clone());
        assert!(!again.first_sight(&ids[0]));
        assert!(again.first_sight(&ids[1]));
        assert_eq!(seen_file(&path).len(), SEEN_LIMIT);
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn unreadable_seen_file_falls_back_to_devices() {
        let path = temp_store("corrupt");
        std::fs::write(&path, serde_json::to_vec(&vec![phone("a1b2c3d4", 'a')]).unwrap()).unwrap();
        std::fs::write(path.with_file_name(SEEN_FILE), "not json").unwrap();
        let mut s = DeviceStore::open(path.clone());
        assert!(!s.first_sight("a1b2c3d4"));
        assert!(s.first_sight("ffff0000"));
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn a_stored_gateway_must_be_an_address_the_helper_can_send_to() {
        for good in ["https://push.example.workers.dev", "http://127.0.0.1:8787", "http://localhost:8787"] {
            assert!(gateway_usable(good), "{good}");
        }
        for bad in ["", "push.example.com", "http://push.example.com", "http://127.0.0.1.example.com", "ftp://127.0.0.1", "https://user:pw@push.example.com", "file:///etc/passwd"] {
            assert!(!gateway_usable(bad), "{bad}");
        }
    }

    #[test]
    fn a_gateway_that_left_the_allowlist_takes_its_registrations_with_it() {
        let path = temp_store("allow");
        let mut s = DeviceStore::open(path.clone());
        s.register(phone("a1b2c3d4", 'a')).unwrap();
        s.register(Device::new("ffff0000", "https://old.example.com", &secret('b'), "sandbox", OWNER)).unwrap();
        assert_eq!(s.keep_gateways(|g| g == GATEWAY), 1);
        assert_eq!(s.keep_gateways(|g| g == GATEWAY), 0);
        let left: Vec<String> = DeviceStore::open(path.clone()).devices.into_iter().map(|d| d.device_id).collect();
        assert_eq!(left, ["a1b2c3d4"]);
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn a_second_401_counts_only_a_minute_after_the_first() {
        let mut s = Strikes::default();
        let (a, b) = (secret_hash(&secret('a')), secret_hash(&secret('b')));
        assert!(!s.refused(&a, 1000.0), "the first is a warning");
        assert!(!s.refused(&a, 1001.0), "a burst is still the first");
        assert!(!s.refused(&a, 1059.9));
        // Another secret has its own count.
        assert!(!s.refused(&b, 1060.0));
        assert!(s.refused(&a, 1060.0), "a minute later: gone");
        // After that, or after a push the gateway took, the count starts over.
        assert!(!s.refused(&a, 2000.0));
        s.clear(&a);
        assert!(!s.refused(&a, 2100.0));
        assert!(s.refused(&b, 1120.0));
    }

    #[test]
    fn a_refused_secret_is_remembered_by_hash_only() {
        let path = temp_store("dropped");
        let mut s = DeviceStore::open(path.clone());
        s.register(phone("a1b2c3d4", 'a')).unwrap();
        s.register(phone("ffff0000", 'b')).unwrap();
        assert!(!s.is_dropped(&secret('a')));
        assert!(s.drop_secret("a1b2c3d4", &secret('a')));
        assert!(s.is_dropped(&secret('a')) && !s.is_dropped(&secret('b')));
        assert!(s.get("a1b2c3d4").is_none() && s.get("ffff0000").is_some());
        // The phone registered a new secret meanwhile: the old one is remembered, the new
        // registration stays.
        assert!(!s.drop_secret("ffff0000", &secret('z')));
        assert!(s.is_dropped(&secret('z')) && s.get("ffff0000").is_some());

        // On disk: hashes, never a secret, readable by the owner only. It survives a restart.
        use std::os::unix::fs::PermissionsExt;
        let file = path.with_file_name(DROPPED_FILE);
        let text = std::fs::read_to_string(&file).unwrap();
        let hashes: Vec<String> = serde_json::from_str(&text).unwrap();
        assert_eq!(hashes, [secret_hash(&secret('a')), secret_hash(&secret('z'))]);
        assert!(!text.contains(&secret('a')[..12]));
        assert_eq!(std::fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
        let again = DeviceStore::open(path.clone());
        assert!(again.is_dropped(&secret('a')) && again.is_dropped(&secret('z')) && !again.is_dropped(&secret('b')));
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn the_dropped_list_is_bounded() {
        let path = temp_store("droppedcap");
        let mut s = DeviceStore::open(path.clone());
        let nth = |n: usize| format!("{n:043}");
        for n in 0..DROPPED_LIMIT + 3 {
            s.drop_secret("a1b2c3d4", &nth(n));
        }
        let hashes: Vec<String> = serde_json::from_slice(&std::fs::read(path.with_file_name(DROPPED_FILE)).unwrap()).unwrap();
        assert_eq!(hashes.len(), DROPPED_LIMIT);
        // The oldest three went; the newest is last.
        assert!(!s.is_dropped(&nth(2)) && s.is_dropped(&nth(3)));
        assert_eq!(hashes[DROPPED_LIMIT - 1], secret_hash(&nth(DROPPED_LIMIT + 2)));
        // Anything in the file that is not a hash is ignored when it is read.
        std::fs::write(path.with_file_name(DROPPED_FILE), json!([secret('q'), hashes[0], 7]).to_string()).unwrap();
        assert!(!DeviceStore::open(path.clone()).is_dropped(&nth(3)), "a file with a wrong entry type is not trusted");
        std::fs::write(path.with_file_name(DROPPED_FILE), json!([secret('q'), hashes[0]]).to_string()).unwrap();
        let again = DeviceStore::open(path.clone());
        assert!(again.is_dropped(&nth(3)) && again.dropped.len() == 1);
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn a_phone_forgotten_from_the_command_line_is_gone_from_the_running_helper() {
        let path = temp_store("forget");
        let mut running = DeviceStore::open(path.clone());
        running.register(phone("a1b2c3d4", 'a')).unwrap();
        running.register(phone("ffff0000", 'b')).unwrap();
        // `rex-duo-helper forget` is another process with its own view of the file.
        assert_eq!(forget(&path, "a1b2c3d4"), Ok(true));
        assert_eq!(forget(&path, "a1b2c3d4"), Ok(false));
        assert!(forget(&path, "A1B2C3D4").is_err() && forget(&path, "nope").is_err());
        assert_eq!(running.devices.len(), 2, "not yet read again");
        running.sync();
        assert!(running.get("a1b2c3d4").is_none() && running.get("ffff0000").is_some());
        // The helper's next write keeps it gone.
        running.register(phone("0000aaaa", 'c')).unwrap();
        let left: Vec<String> = DeviceStore::open(path.clone()).devices.into_iter().map(|d| d.device_id).collect();
        assert_eq!(left, ["ffff0000", "0000aaaa"]);
        // Nothing changed on disk: nothing is read again.
        running.devices.clear();
        running.sync();
        assert!(running.devices.is_empty());
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }

    #[test]
    fn secret_and_id_validation() {
        assert!(Device::is_valid_secret(&secret('a')));
        assert!(Device::is_valid_secret("abcDEF012-_abcDEF012-_"));
        assert!(!Device::is_valid_secret("short"));
        assert!(!Device::is_valid_secret(&format!("{} x", secret('a'))));
        assert!(!Device::is_valid_secret(&format!("{}\r\nX: y", secret('a'))));
        assert!(!Device::is_valid_secret(&"a".repeat(129)));
        assert!(is_device_id("a1b2c3d4"));
        for bad in ["a1-b2", "A1B2C3D4", "a1b2c3d", "a1b2c3d4e", "a1b2c3dg", ""] {
            assert!(!is_device_id(bad), "{bad}");
        }
    }

    #[test]
    fn debug_output_leaves_the_secret_out() {
        let text = format!("{:?}", dev());
        assert!(text.contains("a1b2c3d4") && text.contains("paused: false") && !text.contains(&secret('s')), "{text}");
    }
}
