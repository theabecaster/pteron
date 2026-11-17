//! The helper's names before the rename to Rex DUO Helper, and the one-time move off them.
//!
//! An install of the old name keeps the registered phones in its own state folder. On first
//! run the new helper stops the old background service (service::stop_legacy) and moves that
//! folder's files to the new one, so phones stay registered without opening the app again.
//! Every old name lives in this file; delete it once no old install is left.

#[cfg(target_os = "macos")]
use crate::config::home;
use crate::config::{default_state_dir, state_dir};
use std::path::{Path, PathBuf};

/// The old binary and Linux systemd unit name.
pub const OLD_NAME: &str = "rex-connect-helper";
/// The old Mac app name, which named its state folder and log.
pub const OLD_APP_NAME: &str = "Rex Connect Helper";
/// The old Mac LaunchAgent label (and app bundle id).
#[cfg(target_os = "macos")]
pub const OLD_LABEL: &str = "dev.abrahamgonzalez.rexconnect.helper";

/// Files the old process owned while it ran; they mean nothing to the new one.
const RUNTIME_FILES: &[&str] = &["status.json", "helper.lock"];

/// Stops the old service and moves its state. Returns one line per thing it did.
pub fn migrate() -> Vec<String> {
    let mut notes = crate::service::stop_legacy();
    notes.extend(move_state(&state_dir(OLD_APP_NAME, OLD_NAME), &default_state_dir()));
    #[cfg(target_os = "macos")]
    for log in [format!("{OLD_APP_NAME}.log"), format!("{OLD_APP_NAME}.old.log")] {
        let _ = std::fs::remove_file(home().join("Library/Logs").join(log));
    }
    notes
}

/// Moves each file of `old` that `new` doesn't have yet into `new` (an existing file in `new`
/// wins), drops the old process's runtime files, and removes `old` once it is empty.
pub fn move_state(old: &Path, new: &Path) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(old) else { return vec![] };
    let mut notes = vec![];
    if let Err(e) = std::fs::create_dir_all(new) {
        return vec![format!("could not create {}: {e}", new.display())];
    }
    for entry in entries.flatten() {
        let name = entry.file_name();
        let from: PathBuf = entry.path();
        if RUNTIME_FILES.iter().any(|f| name == *f) {
            let _ = std::fs::remove_file(&from);
            continue;
        }
        let to = new.join(&name);
        if to.exists() {
            notes.push(format!("kept {} (both folders have {})", to.display(), name.to_string_lossy()));
            continue;
        }
        match std::fs::rename(&from, &to) {
            Ok(()) => notes.push(format!("moved {} to {}", from.display(), to.display())),
            Err(e) => notes.push(format!("could not move {}: {e}", from.display())),
        }
    }
    if std::fs::remove_dir(old).is_ok() {
        notes.push(format!("removed {}", old.display()));
    }
    notes
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("legacy-{tag}-{}-{}", std::process::id(), crate::util::now()));
        let _ = std::fs::remove_dir_all(&p);
        p
    }

    #[test]
    fn moves_files_and_removes_old_folder() {
        let (old, new) = (temp("old1"), temp("new1"));
        std::fs::create_dir_all(&old).unwrap();
        std::fs::write(old.join("devices.json"), "[1]").unwrap();
        std::fs::write(old.join("config.json"), "{}").unwrap();
        std::fs::write(old.join("status.json"), "{}").unwrap();
        std::fs::write(old.join("helper.lock"), "").unwrap();
        move_state(&old, &new);
        assert_eq!(std::fs::read_to_string(new.join("devices.json")).unwrap(), "[1]");
        assert!(new.join("config.json").exists());
        assert!(!new.join("status.json").exists());
        assert!(!new.join("helper.lock").exists());
        assert!(!old.exists());
        std::fs::remove_dir_all(&new).unwrap();
    }

    #[test]
    fn existing_new_file_wins() {
        let (old, new) = (temp("old2"), temp("new2"));
        std::fs::create_dir_all(&old).unwrap();
        std::fs::create_dir_all(&new).unwrap();
        std::fs::write(old.join("devices.json"), "[\"old\"]").unwrap();
        std::fs::write(new.join("devices.json"), "[\"new\"]").unwrap();
        move_state(&old, &new);
        assert_eq!(std::fs::read_to_string(new.join("devices.json")).unwrap(), "[\"new\"]");
        // The old copy stays, so nothing is lost.
        assert!(old.join("devices.json").exists());
        std::fs::remove_dir_all(&old).unwrap();
        std::fs::remove_dir_all(&new).unwrap();
    }

    #[test]
    fn no_old_folder_is_a_no_op() {
        let (old, new) = (temp("old3"), temp("new3"));
        assert!(move_state(&old, &new).is_empty());
        assert!(!new.exists());
    }
}
