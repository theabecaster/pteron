//! The desktop notice for a phone's first registration: "Rex DUO connected".
//! Which phone is new and what the notice says are pure and unit-tested; `post` is the effect.

use crate::{debug, info};
use std::collections::BTreeSet;
use std::process::Stdio;
use std::time::Duration;

pub const TITLE: &str = "Rex DUO connected";
/// Longest device name shown, in characters.
const NAME_LIMIT: usize = 64;

/// Device ids that have registered at least once (seen_devices.json). An id stays here after
/// the phone unregisters, so it gets one notice ever.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SeenDevices(BTreeSet<String>);

impl SeenDevices {
    pub fn new(ids: impl IntoIterator<Item = String>) -> SeenDevices {
        SeenDevices(ids.into_iter().map(|i| i.to_lowercase()).collect())
    }

    /// Records the id. True the first time, which is when the notice is due.
    pub fn observe(&mut self, id: &str) -> bool {
        self.0.insert(id.to_lowercase())
    }

    pub fn ids(&self) -> impl Iterator<Item = &String> {
        self.0.iter()
    }
}

/// The notice body. The name comes from the phone, so it is cut to one short line.
pub fn body(device_name: Option<&str>) -> String {
    let name: String = device_name
        .unwrap_or("")
        .chars()
        .map(|c| if c.is_control() { ' ' } else { c })
        .collect::<String>()
        .trim()
        .chars()
        .take(NAME_LIMIT)
        .collect();
    let name = name.trim_end();
    format!("{} can now open your sessions on this computer.", if name.is_empty() { "A new iPhone" } else { name })
}

/// The program and arguments that show a notification on `os` (`std::env::consts::OS`), or
/// None where there is no way. The texts are separate arguments after `--`, never part of
/// the AppleScript source or an option, so nothing in a device name is run or parsed.
pub fn command(os: &str, title: &str, body: &str) -> Option<(&'static str, Vec<String>)> {
    let fixed: (&'static str, &[&str]) = match os {
        "macos" => (
            "/usr/bin/osascript",
            &["-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)", "-e", "end run"],
        ),
        "linux" => ("notify-send", &["--app-name", "Rex DUO"]),
        _ => return None,
    };
    let args = fixed.1.iter().copied().chain(["--", title, body]).map(String::from).collect();
    Some((fixed.0, args))
}

/// Shows the notice without waiting for it. Nothing here fails the caller: a machine with no
/// `notify-send` or no desktop session (a headless Linux box) only gets a log line.
pub fn post(body: &str, dry_run: bool) {
    if dry_run {
        info!("DRY-RUN notice -> {TITLE}: {body}");
        return;
    }
    let Some((program, args)) = command(std::env::consts::OS, TITLE, body) else { return };
    let child = tokio::process::Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn();
    let mut child = match child {
        Ok(c) => c,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            debug!("no desktop notice: {program} is not installed");
            return;
        }
        Err(e) => {
            info!("no desktop notice: {program}: {e}");
            return;
        }
    };
    tokio::spawn(async move {
        match tokio::time::timeout(Duration::from_secs(10), child.wait()).await {
            Ok(Ok(status)) if status.success() => {}
            Ok(Ok(status)) => info!("no desktop notice: {program} ended with {status}"),
            Ok(Err(e)) => info!("no desktop notice: {program}: {e}"),
            Err(_) => info!("no desktop notice: {program} did not finish"),
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_new_device_id_is_new() {
        let mut seen = SeenDevices::default();
        assert!(seen.observe("a1b2c3d4"));
        assert!(!seen.observe("a1b2c3d4"));
        assert!(!seen.observe("A1B2C3D4"));
        assert!(seen.observe("ffff0000"));
        assert!(!SeenDevices::new(["AAAA1111".to_string()]).observe("aaaa1111"));
    }

    #[test]
    fn body_names_the_device() {
        assert_eq!(body(Some("Abe's iPhone")), "Abe's iPhone can now open your sessions on this computer.");
    }

    #[test]
    fn body_falls_back_without_a_name() {
        let fallback = "A new iPhone can now open your sessions on this computer.";
        assert_eq!(body(None), fallback);
        assert_eq!(body(Some("")), fallback);
        assert_eq!(body(Some(" \n\t ")), fallback);
    }

    #[test]
    fn body_caps_the_name_and_flattens_control_characters() {
        let long = body(Some(&"é".repeat(200)));
        assert_eq!(long, format!("{} can now open your sessions on this computer.", "é".repeat(64)));
        assert_eq!(body(Some("a\nb\u{7}c\u{1b}[31m")), "a b c [31m can now open your sessions on this computer.");
    }

    #[test]
    fn hostile_names_stay_one_argument() {
        for name in ["\"; do shell script \"touch /tmp/x\" --\"", "back\\slash \\\" quote", "-e", "--icon=x", "$(id) `id` 'q'"] {
            let text = body(Some(name));
            assert!(text.starts_with(name));
            for os in ["macos", "linux"] {
                let (_, args) = command(os, TITLE, &text).unwrap();
                let n = args.len();
                // Both texts come after `--`, whole and unchanged; nothing before it varies.
                assert_eq!(args[n - 3..], ["--".to_string(), TITLE.to_string(), text.clone()]);
                assert_eq!(args[..n - 3], command(os, "", "").unwrap().1[..n - 3]);
            }
        }
    }

    #[test]
    fn command_per_platform() {
        let (program, args) = command("macos", "T", "B").unwrap();
        assert_eq!(program, "/usr/bin/osascript");
        assert_eq!(
            args,
            ["-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)", "-e", "end run", "--", "T", "B"]
        );
        let (program, args) = command("linux", "T", "B").unwrap();
        assert_eq!(program, "notify-send");
        assert_eq!(args, ["--app-name", "Rex DUO", "--", "T", "B"]);
        assert!(command("windows", "T", "B").is_none());
    }
}
