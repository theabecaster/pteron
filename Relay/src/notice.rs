//! The desktop notice for a phone's first registration: "Rex DUO connected".
//! Which phone is new and what the notice says are pure and unit-tested; `post` is the effect.

use crate::{debug, info};
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

pub const TITLE: &str = "Rex DUO connected";
/// The program in the Mac app, next to the helper, that posts as Rex DUO Helper
/// (Packaging/notify.swift). macOS names the app a notification comes from by its bundle, so a
/// script runner would show under its own name.
#[cfg(target_os = "macos")]
pub const NOTIFIER: &str = "rex-duo-notify";
/// Longest device name shown, in characters.
const NAME_LIMIT: usize = 64;
/// Most device ids remembered. A new id past this pushes out the oldest.
pub const SEEN_LIMIT: usize = 512;
/// Longest device id remembered, in characters. The app sends 8.
const ID_LIMIT: usize = 64;
/// Most notices shown in any `NOTICE_WINDOW`, so a client that registers many new ids cannot
/// flood the desktop.
pub const NOTICE_LIMIT: usize = 3;
pub const NOTICE_WINDOW: Duration = Duration::from_secs(60);

/// Device ids that have registered at least once (seen_devices.json), oldest first. An id stays
/// here after the phone unregisters, so it gets one notice, until `SEEN_LIMIT` newer ids push
/// it out.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SeenDevices(Vec<String>);

fn is_valid_id(id: &str) -> bool {
    (1..=ID_LIMIT).contains(&id.len()) && id.bytes().all(|b| b.is_ascii_alphanumeric())
}

impl SeenDevices {
    /// `ids` oldest first, as the file has them.
    pub fn new(ids: impl IntoIterator<Item = String>) -> SeenDevices {
        let mut seen = SeenDevices::default();
        for id in ids {
            seen.observe(&id);
        }
        seen
    }

    /// Records the id. True the first time, which is when the notice is due. An id that is not
    /// 1 to 64 letters or digits is no id: never new, never recorded.
    pub fn observe(&mut self, id: &str) -> bool {
        self.observe_keeping(id, |_| false)
    }

    /// `observe`, where a full set drops its oldest id that `keep` doesn't hold on to (the
    /// oldest of all when it holds on to every one).
    pub fn observe_keeping(&mut self, id: &str, keep: impl Fn(&str) -> bool) -> bool {
        let id = id.to_lowercase();
        if !is_valid_id(&id) || self.0.contains(&id) {
            return false;
        }
        if self.0.len() >= SEEN_LIMIT {
            let oldest = self.0.iter().position(|s| !keep(s)).unwrap_or(0);
            self.0.remove(oldest);
        }
        self.0.push(id);
        true
    }

    /// Oldest first.
    pub fn ids(&self) -> impl Iterator<Item = &String> {
        self.0.iter()
    }
}

/// Holds notices back past `NOTICE_LIMIT` in `NOTICE_WINDOW`. The caller passes the time.
#[derive(Debug, Default)]
pub struct NoticeLimiter(VecDeque<Instant>);

impl NoticeLimiter {
    /// True if a notice may show at `now`, which then counts against the window.
    pub fn allow(&mut self, now: Instant) -> bool {
        while self.0.front().is_some_and(|t| now.saturating_duration_since(*t) >= NOTICE_WINDOW) {
            self.0.pop_front();
        }
        if self.0.len() >= NOTICE_LIMIT {
            return false;
        }
        self.0.push_back(now);
        true
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
/// None where there is no way: a Mac helper that isn't running from its app has no `notifier`.
/// The texts are separate arguments after `--`, never part of an option, so nothing in a device
/// name is run or parsed. Linux notification servers read the texts as markup, so there `&`,
/// `<` and `>` are escaped; the Mac notifier shows text as it is.
pub fn command(os: &str, notifier: Option<&Path>, title: &str, body: &str) -> Option<(String, Vec<String>)> {
    let (program, fixed, markup): (String, &[&str], bool) = match os {
        "macos" => (notifier?.display().to_string(), &["post"], false),
        "linux" => ("notify-send".into(), &["--app-name", "Rex DUO"], true),
        _ => return None,
    };
    let text = |s: &str| if markup { escape_markup(s) } else { s.to_string() };
    let args = fixed.iter().map(|s| s.to_string()).chain(["--".to_string(), text(title), text(body)]).collect();
    Some((program, args))
}

/// `&` first, so the `&` of an escape written here is not escaped again.
fn escape_markup(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// The notifier inside the app this helper runs from, if it is there.
#[cfg(target_os = "macos")]
fn notifier() -> Option<PathBuf> {
    let p = crate::service::bundle()?.join("Contents/MacOS").join(NOTIFIER);
    p.is_file().then_some(p)
}

#[cfg(not(target_os = "macos"))]
fn notifier() -> Option<PathBuf> {
    None
}

/// Asks macOS, once, whether Rex DUO Helper may show notifications. Called when the app is
/// opened, so the question comes with the welcome and not out of nowhere later. It doesn't
/// wait for the answer, and a "no" only means the notice is never shown.
#[cfg(target_os = "macos")]
pub fn authorize() {
    let Some(notifier) = notifier() else { return };
    let Some(mut command) = crate::tools::command(notifier) else { return };
    let _ = command
        .arg("authorize")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
}

/// What the notifier's `status` printed, when it is one of the three words it prints.
pub fn parse_status(printed: &str) -> Option<&'static str> {
    ["allowed", "denied", "undetermined"].into_iter().find(|word| printed.trim() == *word)
}

/// Whether Rex DUO Helper may show notifications on this Mac: `allowed`, `denied` or
/// `undetermined`, as its notifier reports it. It never asks. None anywhere else, and when the
/// notifier can't say (the helper isn't running from its app, or it took too long).
pub async fn status() -> Option<&'static str> {
    let printed = crate::discovery::run(&notifier()?, &["status"]).await?;
    parse_status(&String::from_utf8_lossy(&printed))
}

/// Shows the notice without waiting for it. Nothing here fails the caller: a Mac where
/// notifications are off, or a machine with no `notify-send` or no desktop session (a headless
/// Linux box), only gets a log line.
pub fn post(body: &str, dry_run: bool) {
    if dry_run {
        info!("DRY-RUN notice -> {TITLE}: {body}");
        return;
    }
    let Some((program, args)) = command(std::env::consts::OS, notifier().as_deref(), TITLE, body) else {
        debug!("no desktop notice: nothing here can show one");
        return;
    };
    // `notify-send` is looked up in the system's folders, not on PATH.
    let Some(mut command) = crate::tools::async_command(&program) else {
        debug!("no desktop notice: {program} is not installed");
        return;
    };
    let child = command
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
        // Long enough for the person to answer the permission question the first time.
        match tokio::time::timeout(Duration::from_secs(330), child.wait()).await {
            Ok(Ok(status)) if status.success() => {}
            // Notifications are turned off for the helper: the person's choice, not a fault.
            Ok(Ok(status)) if status.code() == Some(1) => debug!("no desktop notice: not allowed"),
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
    fn a_full_set_drops_the_oldest_id() {
        let id = |n: usize| format!("{n:08x}");
        let mut seen = SeenDevices::new((0..SEEN_LIMIT).map(id));
        assert!(seen.observe("ffff0000"));
        assert_eq!(seen.ids().count(), SEEN_LIMIT);
        assert_eq!(seen.ids().next(), Some(&id(1)));
        assert_eq!(seen.ids().last().map(String::as_str), Some("ffff0000"));
        // The id that was dropped is new again; one that stayed is not.
        assert!(!seen.observe(&id(1)));
        assert!(seen.observe(&id(0)));
        assert_eq!(seen.ids().count(), SEEN_LIMIT);
    }

    #[test]
    fn a_full_set_keeps_the_ids_it_is_told_to() {
        let id = |n: usize| format!("{n:08x}");
        let mut seen = SeenDevices::new((0..SEEN_LIMIT).map(id));
        assert!(seen.observe_keeping("ffff0000", |s| s == id(0) || s == id(1)));
        assert_eq!(seen.ids().take(3).collect::<Vec<_>>(), [&id(0), &id(1), &id(3)]);
        // Everything kept: the oldest goes, so the set still cannot grow.
        assert!(seen.observe_keeping("ffff0001", |_| true));
        assert_eq!(seen.ids().count(), SEEN_LIMIT);
        assert_eq!(seen.ids().next(), Some(&id(1)));
    }

    #[test]
    fn invalid_ids_are_ignored() {
        let mut seen = SeenDevices::default();
        for id in ["", " ", "a1-b2", "a1b2c3d4\n", "../x", "é1b2c3d4", &"a".repeat(65)] {
            assert!(!seen.observe(id), "{id:?}");
        }
        assert_eq!(seen.ids().count(), 0);
        assert!(seen.observe("a"));
        assert!(seen.observe(&"a".repeat(64)));
        assert_eq!(SeenDevices::new(["a1b2c3d4".to_string(), "<b>".to_string()]).ids().collect::<Vec<_>>(), ["a1b2c3d4"]);
    }

    #[test]
    fn notices_are_limited_per_window() {
        let start = Instant::now();
        let at = |s: u64| start + Duration::from_secs(s);
        let mut limiter = NoticeLimiter::default();
        for s in [0, 10, 20] {
            assert!(limiter.allow(at(s)));
        }
        assert!(!limiter.allow(at(30)));
        assert!(!limiter.allow(at(59)));
        // The first one leaves the window at 60 s: one more passes, and only one.
        assert!(limiter.allow(at(60)));
        assert!(!limiter.allow(at(61)));
        assert!(limiter.allow(at(70)));
        assert_eq!(NOTICE_LIMIT, 3);
        assert_eq!(NOTICE_WINDOW, Duration::from_secs(60));
    }

    #[test]
    fn linux_texts_are_escaped_as_markup_and_mac_texts_are_not() {
        let notifier = Path::new("/Applications/Rex DUO Helper.app/Contents/MacOS/rex-duo-notify");
        let name = "<b>x</b> & <a href=\"http://x\">y</a> &lt;";
        let text = body(Some(name));
        let (_, args) = command("linux", None, "a & b", &text).unwrap();
        assert_eq!(
            args,
            [
                "--app-name",
                "Rex DUO",
                "--",
                "a &amp; b",
                "&lt;b&gt;x&lt;/b&gt; &amp; &lt;a href=\"http://x\"&gt;y&lt;/a&gt; &amp;lt; can now open your sessions on this computer.",
            ]
        );
        let (_, args) = command("macos", Some(notifier), "a & b", &text).unwrap();
        assert_eq!(args, ["post", "--", "a & b", text.as_str()]);
    }

    #[test]
    fn body_names_the_device() {
        assert_eq!(body(Some("Alex's iPhone")), "Alex's iPhone can now open your sessions on this computer.");
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
            let notifier = Path::new("/Applications/Rex DUO Helper.app/Contents/MacOS/rex-duo-notify");
            for os in ["macos", "linux"] {
                let (_, args) = command(os, Some(notifier), TITLE, &text).unwrap();
                let n = args.len();
                // Both texts come after `--`, whole and unchanged; nothing before it varies.
                assert_eq!(args[n - 3..], ["--".to_string(), TITLE.to_string(), text.clone()]);
                assert_eq!(args[..n - 3], command(os, Some(notifier), "", "").unwrap().1[..n - 3]);
            }
        }
    }

    #[test]
    fn command_per_platform() {
        let notifier = Path::new("/Applications/Rex DUO Helper.app/Contents/MacOS/rex-duo-notify");
        let (program, args) = command("macos", Some(notifier), "T", "B").unwrap();
        assert_eq!(program, "/Applications/Rex DUO Helper.app/Contents/MacOS/rex-duo-notify");
        assert_eq!(args, ["post", "--", "T", "B"]);
        let (program, args) = command("linux", None, "T", "B").unwrap();
        assert_eq!(program, "notify-send");
        assert_eq!(args, ["--app-name", "Rex DUO", "--", "T", "B"]);
        assert!(command("windows", None, "T", "B").is_none());
    }

    #[test]
    fn the_notifiers_status_is_one_of_three_words() {
        assert_eq!(parse_status("allowed\n"), Some("allowed"));
        assert_eq!(parse_status("denied"), Some("denied"));
        assert_eq!(parse_status(" undetermined \n"), Some("undetermined"));
        for other in ["", "yes", "Allowed", "allowed denied", "allowed\ndenied", "authorized"] {
            assert_eq!(parse_status(other), None, "{other:?}");
        }
    }

    #[tokio::test]
    async fn outside_the_app_there_is_no_status() {
        // The tests don't run from an app bundle, so there is no notifier to ask.
        assert_eq!(status().await, None);
    }

    #[test]
    fn a_mac_helper_outside_its_app_shows_nothing() {
        // No script runner stands in: the notice would carry that program's name.
        assert!(command("macos", None, "T", "B").is_none());
    }
}
