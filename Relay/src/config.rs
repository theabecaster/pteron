//! Optional `config.json` in the state directory, and where that directory is.

use crate::discovery::Endpoint;
use serde::Deserialize;
use std::path::{Path, PathBuf};

/// The entry of `servers` that keeps discovery on beside the servers the list names.
pub const DISCOVER: &str = "discover";

/// Every field is optional; the normal install has no config file.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Config {
    pub servers: Option<Vec<String>>,
    pub label: Option<String>,
    /// Push gateways phones may register besides the built-in one: `https://…` origins, or
    /// `http://127.0.0.1:<port>` for a gateway under test on this machine.
    pub gateways: Option<Vec<String>>,
    /// `false` turns the update timer off; `rex-duo-helper update` and the app still update.
    pub auto_update: Option<bool>,
    pub debounce_seconds: Option<f64>,
    pub rate_limit_burst: Option<f64>,
    pub rate_limit_per_minute: Option<f64>,
}

impl Config {
    pub fn load(path: &Path) -> Result<Config, String> {
        match std::fs::read(path) {
            Ok(data) => serde_json::from_slice(&data).map_err(|e| format!("could not read {}: {e}", path.display())),
            Err(_) => Ok(Config::default()),
        }
    }

    /// The servers to watch, each one once. None stands for the server discovery finds: the
    /// whole list when the config names no server, and wherever the list has the word
    /// `discover`.
    pub fn watch(&self) -> Vec<Option<Endpoint>> {
        let Some(servers) = self.servers.as_ref().filter(|s| !s.is_empty()) else { return vec![None] };
        let mut watch: Vec<Option<Endpoint>> = vec![];
        for entry in servers {
            let next = if entry.trim() == DISCOVER { Some(None) } else { Endpoint::parse(entry).map(Some) };
            let Some(next) = next else { continue };
            let listed = watch.iter().any(|w| match (w, &next) {
                (None, None) => true,
                (Some(a), Some(b)) => a.same(b),
                _ => false,
            });
            if !listed {
                watch.push(next);
            }
        }
        watch
    }
}

pub fn home() -> PathBuf {
    PathBuf::from(std::env::var_os("HOME").unwrap_or_else(|| "/".into()))
}

/// Expands a leading `~/`.
pub fn expand(p: &str) -> PathBuf {
    match p.strip_prefix("~/") {
        Some(rest) => home().join(rest),
        None => PathBuf::from(p),
    }
}

/// Where config.json, devices.json, identity.key and status.json live.
/// What a Mac's state folder and log are called: the name the program first had. They keep
/// it whatever the program is called, so an update finds the phones that registered before.
pub(crate) const EARLIER_NAME: &str = "Rex DUO Helper";

/// macOS: `~/Library/Application Support/<EARLIER_NAME>`.
/// Linux: `$XDG_STATE_HOME/rex-duo-helper`, else `~/.local/state/rex-duo-helper`.
pub fn default_state_dir() -> PathBuf {
    state_dir(EARLIER_NAME, "rex-duo-helper")
}

/// The state folder for an app name (macOS) or a binary name (Linux).
pub fn state_dir(mac_name: &str, linux_name: &str) -> PathBuf {
    if cfg!(target_os = "macos") {
        home().join("Library/Application Support").join(mac_name)
    } else {
        std::env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .unwrap_or_else(|| home().join(".local/state"))
            .join(linux_name)
    }
}

/// The log file for `run --log-file` (the Mac's background job; Linux uses the journal).
pub fn default_log_file() -> PathBuf {
    if cfg!(target_os = "macos") {
        home().join("Library/Logs").join(format!("{EARLIER_NAME}.log"))
    } else {
        default_state_dir().join("helper.log")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_optional_keys_and_ignores_old_ones() {
        let c: Config =
            serde_json::from_str(r#"{"auto_update": false, "debounce_seconds": 5, "gateways": ["https://push.example.com"], "apns": {"key_id": "OLD"}}"#).unwrap();
        assert_eq!(c.auto_update, Some(false));
        assert_eq!(c.gateways.as_deref(), Some(&["https://push.example.com".to_string()][..]));
        assert_eq!(c.debounce_seconds, Some(5.0));
        assert_eq!(serde_json::from_str::<Config>("{}").unwrap().auto_update, None);
    }

    #[test]
    fn servers_replace_discovery_unless_the_list_says_discover() {
        let watch = |json: &str| serde_json::from_str::<Config>(json).unwrap().watch();
        let a = Endpoint::parse("https://rex-a.example.ts.net");
        let b = Endpoint::parse("unix:///run/user/1000/rex-b/server.sock");
        assert_eq!(watch("{}"), [None]);
        assert_eq!(watch(r#"{"servers": []}"#), [None]);
        assert_eq!(watch(r#"{"servers": ["https://rex-a.example.ts.net"]}"#), std::slice::from_ref(&a));
        assert_eq!(watch(r#"{"servers": ["discover", "unix:///run/user/1000/rex-b/server.sock"]}"#), [None, b.clone()]);
        // Each server once, and an entry that is no address is skipped.
        assert_eq!(
            watch(r#"{"servers": ["https://rex-a.example.ts.net", "discover", "nonsense", "https://REX-A.example.ts.net:443", "discover", "unix:///run/user/1000/rex-b/server.sock"]}"#),
            [a, None, b]
        );
    }

    #[test]
    fn the_state_folder_and_the_log_are_where_this_system_keeps_them() {
        let state = state_dir("An App", "a-binary");
        if cfg!(target_os = "macos") {
            assert_eq!(state, home().join("Library/Application Support/An App"));
            assert_eq!(default_state_dir(), home().join("Library/Application Support").join(EARLIER_NAME));
            assert_eq!(default_log_file(), home().join("Library/Logs").join(format!("{EARLIER_NAME}.log")));
        } else if cfg!(target_os = "linux") {
            assert!(state.is_absolute() && state.ends_with("a-binary"), "{state:?}");
            assert!(default_state_dir().ends_with("rex-duo-helper"));
            assert_eq!(default_log_file(), default_state_dir().join("helper.log"));
        }
    }
}
