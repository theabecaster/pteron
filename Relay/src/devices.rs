//! Registered phones (devices.json) and "is Rex DUO open on this phone right now?".

use crate::info;
use crate::util::{now_iso, Json};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;
use std::path::PathBuf;

/// One phone that asked for pushes. Field names and date format match the Swift helper's
/// devices.json, so an existing file keeps working.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Device {
    /// Short id the app also puts at the end of its Rex client label ("… #<id>").
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub device_name: Option<String>,
    /// sandbox | production
    pub environment: String,
    #[serde(default)]
    pub registered_at: String,
    /// Tailscale device name the registration came from (fallback "app is open" match).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tailscale_node: Option<String>,
    /// APNs device token, lowercase hex.
    pub token: String,
    #[serde(default)]
    pub updated_at: String,
}

impl Device {
    pub fn new(token: &str, environment: &str) -> Device {
        let now = now_iso();
        Device {
            device_id: None,
            device_name: None,
            environment: environment.into(),
            registered_at: now.clone(),
            tailscale_node: None,
            token: token.into(),
            updated_at: now,
        }
    }

    pub fn is_valid_token(t: &str) -> bool {
        (32..=200).contains(&t.len()) && t.len().is_multiple_of(2) && t.bytes().all(|b| b.is_ascii_hexdigit())
    }

    pub fn is_valid_device_id(s: &str) -> bool {
        (4..=16).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_alphanumeric())
    }

    pub fn who(&self) -> String {
        self.device_name.clone().unwrap_or_else(|| self.token.chars().take(8).collect())
    }
}

/// devices.json: the registered phones, keyed by token.
pub struct DeviceStore {
    pub path: PathBuf,
    pub devices: Vec<Device>,
}

impl DeviceStore {
    pub fn open(path: PathBuf) -> DeviceStore {
        let devices = match std::fs::read(&path) {
            Ok(data) => serde_json::from_slice(&data).unwrap_or_else(|e| {
                info!("could not read {}: {e}", path.display());
                vec![]
            }),
            Err(_) => vec![],
        };
        DeviceStore { path, devices }
    }

    fn save(&self) {
        let write = || -> std::io::Result<()> {
            if let Some(dir) = self.path.parent() {
                std::fs::create_dir_all(dir)?;
            }
            let tmp = self.path.with_extension("json.tmp");
            std::fs::write(&tmp, serde_json::to_vec_pretty(&self.devices)?)?;
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o600))?;
            }
            std::fs::rename(&tmp, &self.path)
        };
        if let Err(e) = write() {
            info!("could not write {}: {e}", self.path.display());
        }
    }

    /// Adds or updates a device. A device id that moves to a new token replaces the old entry
    /// (the app reinstalled or APNs rotated the token).
    pub fn register(&mut self, mut d: Device) -> Device {
        d.token = d.token.to_lowercase();
        if let Some(old) = self.devices.iter().find(|o| o.token == d.token) {
            d.registered_at = old.registered_at.clone();
        }
        self.devices
            .retain(|o| o.token != d.token && !(d.device_id.is_some() && o.device_id == d.device_id));
        self.devices.push(d.clone());
        self.save();
        d
    }

    pub fn remove(&mut self, token: &str) -> bool {
        let token = token.to_lowercase();
        let n = self.devices.len();
        self.devices.retain(|d| d.token != token);
        if self.devices.len() == n {
            return false;
        }
        self.save();
        true
    }
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
    pub tailscale_node: Option<String>,
}

impl ClientSnapshot {
    pub fn parse(c: &Value) -> Option<ClientSnapshot> {
        let id = c.str("client_id")?;
        let info = c.obj("info").cloned().unwrap_or(Value::Null);
        let p = c.obj("principal").cloned().unwrap_or(Value::Null);
        let s = |v: &Value, k: &str| v.str(k).map(String::from);
        Some(ClientSnapshot {
            client_id: id.into(),
            kind: s(&info, "kind"),
            platform: s(&info, "platform"),
            name: s(&info, "name"),
            label: s(&info, "label"),
            connection_state: s(c, "connection_state"),
            tailscale_node: if p.str("kind") == Some("tailscale") { p.text("node") } else { None },
        })
    }
}

/// The device id at the end of a label: "Abe's iPhone #a1b2c3d4" -> "a1b2c3d4".
pub fn device_id_from_label(label: Option<&str>) -> Option<String> {
    let label = label?;
    let id = label[label.rfind('#')? + 1..].trim();
    Device::is_valid_device_id(id).then(|| id.to_lowercase())
}

/// True if an iOS app client from this device is connected and hasn't said it's in the
/// background. A client matches by the "#<device_id>" at the end of its label. Only a
/// registration that sent no device_id falls back to matching an unlabeled client by
/// Tailscale device name, because several apps (e.g. simulators on one Mac) can share a node.
pub fn is_app_open(d: &Device, clients: &[ClientSnapshot], backgrounded: &HashSet<String>) -> bool {
    clients.iter().any(|c| {
        if c.kind.as_deref() != Some("app")
            || c.platform.as_deref() != Some("ios")
            || c.connection_state.as_deref() == Some("lost")
            || backgrounded.contains(&c.client_id)
        {
            return false;
        }
        let label_id = device_id_from_label(c.label.as_deref());
        if let Some(want) = &d.device_id {
            return label_id.as_deref() == Some(want.to_lowercase().as_str());
        }
        match (&label_id, &d.tailscale_node, &c.tailscale_node) {
            (None, Some(node), Some(cn)) => node == cn,
            _ => false,
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn dev() -> Device {
        let mut d = Device::new(&"0".repeat(64), "sandbox");
        d.device_id = Some("a1b2c3d4".into());
        d.tailscale_node = Some("abes-iphone".into());
        d
    }

    fn app(id: &str, label: &str, state: &str, node: Option<&str>, platform: &str) -> ClientSnapshot {
        ClientSnapshot {
            client_id: id.into(),
            kind: Some("app".into()),
            platform: Some(platform.into()),
            name: Some("Rex DUO".into()),
            label: Some(label.into()),
            connection_state: Some(state.into()),
            tailscale_node: node.map(Into::into),
        }
    }

    fn none() -> HashSet<String> {
        HashSet::new()
    }

    #[test]
    fn label_device_id() {
        assert_eq!(device_id_from_label(Some("Abe's iPhone #A1B2C3D4")).as_deref(), Some("a1b2c3d4"));
        assert_eq!(device_id_from_label(Some("Abe's iPhone")), None);
        assert_eq!(device_id_from_label(Some("Room #1")), None);
    }

    #[test]
    fn matches_by_label_device_id() {
        assert!(is_app_open(&dev(), &[app("c1", "iPhone #a1b2c3d4", "connected", None, "ios")], &none()));
        assert!(!is_app_open(&dev(), &[app("c1", "iPhone #ffff0000", "connected", Some("abes-iphone"), "ios")], &none()));
    }

    #[test]
    fn ignores_lost_backgrounded_and_non_ios() {
        assert!(!is_app_open(&dev(), &[app("c1", "x #a1b2c3d4", "lost", None, "ios")], &none()));
        let bg: HashSet<String> = ["c1".to_string()].into();
        assert!(!is_app_open(&dev(), &[app("c1", "x #a1b2c3d4", "connected", None, "ios")], &bg));
        assert!(!is_app_open(&dev(), &[app("c1", "x #a1b2c3d4", "connected", None, "macos")], &none()));
    }

    #[test]
    fn tailscale_node_fallback_only_without_device_id() {
        // Registered with a device id: an unlabeled client on the same node is someone else.
        let c = |label: &str, node: &str| vec![app("c1", label, "connected", Some(node), "ios")];
        assert!(!is_app_open(&dev(), &c("iPhone", "abes-iphone"), &none()));
        let mut old = dev();
        old.device_id = None;
        assert!(is_app_open(&old, &c("iPhone", "abes-iphone"), &none()));
        assert!(!is_app_open(&old, &c("iPhone", "other"), &none()));
        assert!(!is_app_open(&old, &c("iPhone #a1b2c3d4", "abes-iphone"), &none()));
    }

    #[test]
    fn client_snapshot_parsing() {
        let c = ClientSnapshot::parse(&json!({"client_id": "client:1", "connection_state": "connected",
            "info": {"kind": "app", "platform": "ios", "label": "iPhone #abcd1234"},
            "principal": {"kind": "tailscale", "node": "abes-iphone"}}))
        .unwrap();
        assert_eq!(c.tailscale_node.as_deref(), Some("abes-iphone"));
        assert_eq!(c.label.as_deref(), Some("iPhone #abcd1234"));
    }

    #[test]
    fn device_store_round_trip() {
        let path = std::env::temp_dir().join(format!("devices-{}-{}.json", std::process::id(), crate::util::now()));
        let mut s = DeviceStore::open(path.clone());
        let mut a = Device::new(&"AB".repeat(32), "sandbox");
        a.device_id = Some("a1b2".into());
        s.register(a);
        // Same device id, new token: replaces the old entry.
        let mut b = Device::new(&"cd".repeat(32), "production");
        b.device_id = Some("a1b2".into());
        s.register(b);
        assert_eq!(DeviceStore::open(path.clone()).devices.iter().map(|d| d.token.clone()).collect::<Vec<_>>(), vec!["cd".repeat(32)]);
        assert!(s.remove(&"CD".repeat(32)));
        assert!(DeviceStore::open(path.clone()).devices.is_empty());
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn reads_swift_helper_file() {
        let swift = r#"[{"device_id":"ffa348c7","device_name":"iPhone","environment":"sandbox",
            "registered_at":"2026-11-16T19:56:39Z","tailscale_node":"iphone194",
            "token":"4514dd00000000000000000000000000","updated_at":"2026-11-16T22:40:18Z"}]"#;
        let d: Vec<Device> = serde_json::from_str(swift).unwrap();
        assert_eq!(d[0].device_id.as_deref(), Some("ffa348c7"));
        assert_eq!(d[0].registered_at, "2026-11-16T19:56:39Z");
    }

    #[test]
    fn token_and_id_validation() {
        assert!(Device::is_valid_token(&"ab".repeat(32)));
        assert!(!Device::is_valid_token(&"zz".repeat(32)));
        assert!(!Device::is_valid_token("abc"));
        assert!(Device::is_valid_device_id("a1b2c3d4"));
        assert!(!Device::is_valid_device_id("a1-b2"));
    }
}
