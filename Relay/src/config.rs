//! Optional `config.json` in the state directory, and where that directory is.

use crate::discovery::Endpoint;
use serde::Deserialize;
use std::path::{Path, PathBuf};

pub const DEFAULT_TEAM_ID: &str = env!("REX_APNS_TEAM_ID");
pub const DEFAULT_TOPIC: &str = env!("REX_APNS_TOPIC");

#[derive(Clone, Debug, Default, Deserialize)]
pub struct ApnsConfig {
    pub key_path: Option<String>,
    pub key_id: Option<String>,
    pub team_id: Option<String>,
    pub topic: Option<String>,
}

/// Every field is optional; the normal install has no config file.
#[derive(Clone, Debug, Default, Deserialize)]
pub struct Config {
    pub servers: Option<Vec<String>>,
    pub label: Option<String>,
    pub apns: Option<ApnsConfig>,
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

    /// Fixed servers from the config, or None to discover the local one.
    pub fn endpoints(&self) -> Option<Vec<Endpoint>> {
        let s = self.servers.as_ref().filter(|s| !s.is_empty())?;
        Some(s.iter().filter_map(|s| Endpoint::parse(s)).collect())
    }

    pub fn team_id(&self) -> String {
        self.apns.as_ref().and_then(|a| a.team_id.clone()).unwrap_or_else(|| DEFAULT_TEAM_ID.into())
    }

    pub fn topic(&self) -> String {
        self.apns.as_ref().and_then(|a| a.topic.clone()).unwrap_or_else(|| DEFAULT_TOPIC.into())
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

/// Where config.json, devices.json and status.json live.
/// macOS: `~/Library/Application Support/Rex Connect Helper` (same as the Swift helper used).
/// Linux: `$XDG_STATE_HOME/rex-connect-helper`, else `~/.local/state/rex-connect-helper`.
pub fn default_state_dir() -> PathBuf {
    if cfg!(target_os = "macos") {
        home().join("Library/Application Support/Rex Connect Helper")
    } else {
        std::env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .unwrap_or_else(|| home().join(".local/state"))
            .join("rex-connect-helper")
    }
}

/// The log file for `run --log-file` (the Mac's background job; Linux uses the journal).
pub fn default_log_file() -> PathBuf {
    if cfg!(target_os = "macos") {
        home().join("Library/Logs/Rex Connect Helper.log")
    } else {
        default_state_dir().join("helper.log")
    }
}
