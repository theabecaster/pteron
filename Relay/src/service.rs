//! Running in the background: `install`, `status`, `uninstall`, and the Mac app's
//! open-once flow. Linux uses a systemd user service; macOS a per-user LaunchAgent.

use crate::config::{default_state_dir, home};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

/// Prints a line, ignoring a closed pipe (`status | head`).
macro_rules! say {
    ($($t:tt)*) => {{
        use std::io::Write;
        let _ = writeln!(std::io::stdout(), $($t)*);
    }};
}

pub const NAME: &str = "rex-duo-helper";
#[cfg(target_os = "macos")]
pub const LABEL: &str = "dev.abrahamgonzalez.rexduo.helper";

/// What the running helper last wrote to status.json, if it is alive.
pub struct Running {
    pub version: String,
    pub connected: bool,
    pub servers: Vec<String>,
    pub dry_run: bool,
    pub push_enabled: bool,
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))] // used to restart an updated Mac app
    pub exe_mtime: u64,
}

pub fn status_path() -> PathBuf {
    default_state_dir().join("status.json")
}

pub fn running() -> Option<Running> {
    let v: Value = serde_json::from_slice(&std::fs::read(status_path()).ok()?).ok()?;
    let pid = v.get("pid")?.as_u64()?;
    if !pid_alive(pid) {
        return None;
    }
    Some(Running {
        version: v["version"].as_str().unwrap_or("?").into(),
        connected: v["connected"].as_bool().unwrap_or(false),
        servers: v["servers"].as_array().map(|a| a.iter().filter_map(|s| s.as_str().map(String::from)).collect()).unwrap_or_default(),
        dry_run: v["dry_run"].as_bool().unwrap_or(false),
        push_enabled: v["push_enabled"].as_bool().unwrap_or(false),
        exe_mtime: v["exe_mtime"].as_u64().unwrap_or(0),
    })
}

fn pid_alive(pid: u64) -> bool {
    if Path::new("/proc/self").exists() {
        return Path::new(&format!("/proc/{pid}")).exists();
    }
    quiet("/bin/kill", &["-0", &pid.to_string()])
}

/// Modification time of a file in seconds, to tell an updated binary from the running one.
pub fn mtime(p: &Path) -> u64 {
    std::fs::metadata(p)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn quiet(cmd: &str, args: &[&str]) -> bool {
    Command::new(cmd).args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status().is_ok_and(|s| s.success())
}

fn output(cmd: &str, args: &[&str]) -> Option<String> {
    let o = Command::new(cmd).args(args).stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    o.status.success().then(|| String::from_utf8_lossy(&o.stdout).trim().to_string())
}

/// Waits up to `limit` for the helper to start (and connect, if Rex is up).
fn wait_for_start(limit: Duration) -> Option<Running> {
    let start = Instant::now();
    let mut last = None;
    while start.elapsed() < limit {
        last = running();
        if last.as_ref().is_some_and(|r| r.connected) {
            break;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    last
}

/// One plain sentence about the running helper.
pub fn describe(r: &Option<Running>) -> String {
    match r {
        None => "Rex DUO Helper is not running.".into(),
        Some(r) => {
            let mode = if r.dry_run {
                " (dry run: pushes are logged, not sent)"
            } else if !r.push_enabled {
                " (pushes are off: this build has no APNs key)"
            } else {
                ""
            };
            if r.connected {
                format!("Rex DUO Helper {} is running and connected to Rex at {}{mode}.", r.version, r.servers.join(", "))
            } else {
                format!("Rex DUO Helper {} is running and waiting for Rex to start{mode}.", r.version)
            }
        }
    }
}

fn phones() -> usize {
    std::fs::read(default_state_dir().join("devices.json"))
        .ok()
        .and_then(|d| serde_json::from_slice::<Vec<Value>>(&d).ok())
        .map_or(0, |v| v.len())
}

fn plural(n: usize) -> String {
    format!("{n} phone{} registered", if n == 1 { "" } else { "s" })
}

/// Copies this binary to `~/.local/bin` unless it already runs from there. Returns that path.
fn install_binary() -> Result<PathBuf, String> {
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let dir = home().join(".local/bin");
    let target = dir.join(NAME);
    if exe.canonicalize().ok() == target.canonicalize().ok() {
        return Ok(target);
    }
    std::fs::create_dir_all(&dir).map_err(|e| format!("could not create {}: {e}", dir.display()))?;
    let tmp = dir.join(format!(".{NAME}.new"));
    std::fs::copy(&exe, &tmp).map_err(|e| format!("could not copy to {}: {e}", dir.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&tmp, std::fs::Permissions::from_mode(0o755));
    }
    // Renaming over a running binary is fine on Unix: the old process keeps its copy.
    std::fs::rename(&tmp, &target).map_err(|e| format!("could not install {}: {e}", target.display()))?;
    Ok(target)
}

fn tilde(p: &Path) -> String {
    match p.strip_prefix(home()) {
        Ok(rest) => format!("~/{}", rest.display()),
        Err(_) => p.display().to_string(),
    }
}

// MARK: Linux (systemd --user)

#[cfg(not(target_os = "macos"))]
fn unit_path_for(name: &str) -> PathBuf {
    std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| home().join(".config"))
        .join(format!("systemd/user/{name}.service"))
}

#[cfg(not(target_os = "macos"))]
fn unit_path() -> PathBuf {
    unit_path_for(NAME)
}

#[cfg(not(target_os = "macos"))]
fn systemctl(args: &[&str]) -> bool {
    let mut a = vec!["--user"];
    a.extend_from_slice(args);
    quiet("systemctl", &a)
}

#[cfg(not(target_os = "macos"))]
fn user() -> String {
    std::env::var("USER").ok().or_else(|| output("id", &["-un"])).unwrap_or_default()
}

#[cfg(not(target_os = "macos"))]
fn linger() -> Option<bool> {
    output("loginctl", &["show-user", &user(), "-p", "Linger", "--value"]).map(|v| v == "yes")
}

/// Stops and removes the service and binary of the helper's old name (legacy.rs).
#[cfg(not(target_os = "macos"))]
pub fn stop_legacy() -> Vec<String> {
    let old = crate::legacy::OLD_NAME;
    let mut notes = vec![];
    let unit = unit_path_for(old);
    if unit.exists() {
        systemctl(&["disable", "--now", "--quiet", old]);
        let _ = std::fs::remove_file(&unit);
        systemctl(&["daemon-reload"]);
        notes.push(format!("stopped and removed the old {old} service"));
    }
    let bin = home().join(".local/bin").join(old);
    if std::fs::remove_file(&bin).is_ok() {
        notes.push(format!("removed {}", tilde(&bin)));
    }
    notes
}

#[cfg(not(target_os = "macos"))]
pub fn install() -> i32 {
    for note in crate::legacy::migrate() {
        say!("Moving from the old name: {note}");
    }
    let bin = match install_binary() {
        Ok(b) => b,
        Err(e) => {
            eprintln!("Could not install: {e}");
            return 1;
        }
    };
    if !systemctl(&["show-environment"]) {
        say!("Installed {}, but systemd isn't available for your user here, so it can't start by itself.", tilde(&bin));
        say!("Start it yourself and keep it running, for example from your shell's startup file:");
        say!("  nohup {} run >/dev/null 2>&1 &", bin.display());
        return 0;
    }
    let unit = format!(
        "[Unit]\n\
         Description=Rex DUO Helper (push notifications from Rex to the Rex DUO iPhone app)\n\n\
         [Service]\n\
         ExecStart={} run\n\
         Restart=on-failure\n\
         RestartSec=5\n\
         Nice=5\n\n\
         [Install]\n\
         WantedBy=default.target\n",
        bin.display()
    );
    let path = unit_path();
    if let Err(e) = path.parent().map(std::fs::create_dir_all).unwrap_or(Ok(())).and_then(|_| std::fs::write(&path, unit)) {
        eprintln!("Could not write {}: {e}", path.display());
        return 1;
    }
    // Restart, so an update replaces the running copy.
    if !(systemctl(&["daemon-reload"]) && systemctl(&["enable", "--quiet", NAME]) && systemctl(&["restart", NAME])) {
        eprintln!("Could not start the service. See: systemctl --user status {NAME}");
        return 1;
    }
    let r = wait_for_start(Duration::from_secs(6));
    say!("{}", describe(&r));
    // Without lingering, systemd stops user services when the last session ends.
    if linger() == Some(false) {
        // Allowed without sudo on most systems for your own user.
        quiet("loginctl", &["enable-linger", &user()]);
        if linger() == Some(false) {
            say!("Note: it stops when you log out. To keep it running, run: sudo loginctl enable-linger {}", user());
        }
    }
    if !std::env::var("PATH").unwrap_or_default().split(':').any(|p| Path::new(p) == bin.parent().unwrap_or(Path::new("/"))) {
        say!("Note: {} isn't on your PATH; use {} status", tilde(bin.parent().unwrap()), bin.display());
    }
    if r.is_some() { 0 } else { 1 }
}

#[cfg(not(target_os = "macos"))]
pub fn status() -> i32 {
    let r = running();
    say!("{}", describe(&r));
    if unit_path().exists() {
        let active = output("systemctl", &["--user", "is-active", NAME]).unwrap_or_else(|| "inactive".into());
        let linger = match linger() {
            Some(true) => "keeps running after logout",
            Some(false) => "stops at logout (sudo loginctl enable-linger to keep it)",
            None => "",
        };
        say!("Service: {active}, starts at boot; {linger}. Logs: journalctl --user -u {NAME}");
    } else {
        say!("Not installed as a service. Run: {NAME} install");
    }
    say!("{}.", plural(phones()));
    if r.is_some() { 0 } else { 3 }
}

#[cfg(not(target_os = "macos"))]
pub fn uninstall() -> i32 {
    systemctl(&["disable", "--now", "--quiet", NAME]);
    let _ = std::fs::remove_file(unit_path());
    systemctl(&["daemon-reload"]);
    let _ = std::fs::remove_file(home().join(".local/bin").join(NAME));
    say!(
        "Rex DUO Helper is stopped and removed. Registered phones stay in {}; delete that folder to forget them.",
        tilde(&default_state_dir())
    );
    0
}

// MARK: macOS (LaunchAgent)

#[cfg(target_os = "macos")]
fn plist_path() -> PathBuf {
    home().join(format!("Library/LaunchAgents/{LABEL}.plist"))
}

#[cfg(target_os = "macos")]
fn domain() -> String {
    format!("gui/{}", output("/usr/bin/id", &["-u"]).unwrap_or_else(|| "501".into()))
}

#[cfg(target_os = "macos")]
fn loaded() -> bool {
    loaded_label(LABEL)
}

#[cfg(target_os = "macos")]
fn loaded_label(label: &str) -> bool {
    quiet("/bin/launchctl", &["print", &format!("{}/{label}", domain())])
}

/// Stops and removes the LaunchAgent and binary of the helper's old name (legacy.rs). The old
/// app itself stays wherever the user put it.
#[cfg(target_os = "macos")]
pub fn stop_legacy() -> Vec<String> {
    let old = crate::legacy::OLD_LABEL;
    let mut notes = vec![];
    if loaded_label(old) {
        quiet("/bin/launchctl", &["bootout", &format!("{}/{old}", domain())]);
        // bootout returns before the job is fully gone, and the job writes its state on exit.
        let t = Instant::now();
        while loaded_label(old) && t.elapsed() < Duration::from_secs(3) {
            std::thread::sleep(Duration::from_millis(100));
        }
        notes.push(format!("stopped the old {old} LaunchAgent"));
    }
    let plist = home().join(format!("Library/LaunchAgents/{old}.plist"));
    if std::fs::remove_file(&plist).is_ok() {
        notes.push(format!("removed {}", tilde(&plist)));
    }
    let bin = home().join(".local/bin").join(crate::legacy::OLD_NAME);
    if std::fs::remove_file(&bin).is_ok() {
        notes.push(format!("removed {}", tilde(&bin)));
    }
    notes
}

/// The app bundle this binary runs from, if any.
#[cfg(target_os = "macos")]
pub fn bundle() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let macos = exe.parent()?;
    let contents = macos.parent()?;
    let app = contents.parent()?;
    (macos.ends_with("Contents/MacOS") && app.extension().is_some_and(|e| e == "app")).then(|| app.to_path_buf())
}

#[cfg(target_os = "macos")]
fn xml(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// Writes the LaunchAgent and (re)starts the helper. Quiet; returns an error to show.
#[cfg(target_os = "macos")]
fn start_agent() -> Result<(), String> {
    // From the app, run the binary inside it; otherwise install a copy to ~/.local/bin.
    let program = match bundle() {
        Some(_) => std::env::current_exe().map_err(|e| e.to_string())?,
        None => install_binary()?,
    };
    let plist = format!(
        r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>{LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>{}</string><string>run</string><string>--log-file</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Background</string>
  <key>AssociatedBundleIdentifiers</key><string>{LABEL}</string>
</dict>
</plist>
"#,
        xml(&program.display().to_string())
    );
    let path = plist_path();
    let changed = std::fs::read_to_string(&path).ok().as_deref() != Some(plist.as_str());
    if changed {
        std::fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
        std::fs::write(&path, &plist).map_err(|e| format!("could not write {}: {e}", path.display()))?;
    }
    let target = format!("{}/{LABEL}", domain());
    if changed && loaded() {
        quiet("/bin/launchctl", &["bootout", &target]);
        // bootout returns before the job is fully gone.
        let t = Instant::now();
        while loaded() && t.elapsed() < Duration::from_secs(3) {
            std::thread::sleep(Duration::from_millis(100));
        }
    }
    if !loaded() {
        if !quiet("/bin/launchctl", &["bootstrap", &domain(), &path.display().to_string()]) {
            return Err("macOS refused to start the background job (launchctl bootstrap failed)".into());
        }
    } else {
        // Already set up: start it if it stopped, restart it if the binary was updated.
        let stale = match running() {
            None => true,
            Some(r) => r.version != crate::relay::VERSION || r.exe_mtime != mtime(&program),
        };
        if stale {
            quiet("/bin/launchctl", &["kickstart", "-k", &target]);
        }
    }
    Ok(())
}

#[cfg(target_os = "macos")]
fn stop_agent() {
    quiet("/bin/launchctl", &["bootout", &format!("{}/{LABEL}", domain())]);
    let _ = std::fs::remove_file(plist_path());
}

#[cfg(target_os = "macos")]
pub fn install() -> i32 {
    for note in crate::legacy::migrate() {
        say!("Moving from the old name: {note}");
    }
    if let Err(e) = start_agent() {
        eprintln!("Could not start Rex DUO Helper: {e}");
        return 1;
    }
    let r = wait_for_start(Duration::from_secs(6));
    say!("{}", describe(&r));
    if r.is_some() { 0 } else { 1 }
}

#[cfg(target_os = "macos")]
pub fn status() -> i32 {
    let r = running();
    say!("{}", describe(&r));
    if plist_path().exists() {
        say!(
            "Starts at login ({}). Log: {}",
            if loaded() { "loaded" } else { "not loaded" },
            tilde(&crate::config::default_log_file())
        );
    } else {
        say!("Not set up to start at login. Open Rex DUO Helper.app, or run: {NAME} install");
    }
    say!("{}.", plural(phones()));
    if r.is_some() { 0 } else { 3 }
}

#[cfg(target_os = "macos")]
pub fn uninstall() -> i32 {
    stop_agent();
    say!("Rex DUO Helper is stopped and won't start at login. To remove it, drag the app to the Trash.");
    0
}

/// Shows a dialog with the app's icon; returns the button clicked.
#[cfg(target_os = "macos")]
fn dialog(text: &str, buttons: &[&str]) -> String {
    let esc = |s: &str| s.replace('\\', "\\\\").replace('"', "\\\"");
    let list = buttons.iter().map(|b| format!("\"{}\"", esc(b))).collect::<Vec<_>>().join(", ");
    let icon = bundle()
        .map(|b| b.join("Contents/Resources/AppIcon.icns"))
        .filter(|p| p.exists())
        .map(|p| format!(" with icon (POSIX file \"{}\")", esc(&p.display().to_string())))
        .unwrap_or_default();
    let script = format!(
        "display dialog \"{}\" with title \"Rex DUO Helper\" buttons {{{list}}} default button \"{}\"{icon}",
        esc(text),
        esc(buttons.last().unwrap())
    );
    output("/usr/bin/osascript", &["-e", &script])
        .and_then(|o| o.strip_prefix("button returned:").map(String::from))
        .unwrap_or_default()
}

/// Opening Rex DUO Helper.app: start the background helper (and at every login), then
/// say so in one small dialog. The dialog's process exits; only the helper keeps running.
#[cfg(target_os = "macos")]
pub fn open_app() -> i32 {
    let in_place = bundle().is_some_and(|b| !b.to_string_lossy().contains("/AppTranslocation/"));
    if !in_place {
        dialog("Move Rex DUO Helper to your Applications folder, then open it again.", &["OK"]);
        return 0;
    }
    crate::legacy::migrate();
    if let Err(e) = start_agent() {
        dialog(&format!("Rex DUO Helper couldn't start.\n\n{e}"), &["OK"]);
        return 1;
    }
    // The permission question for the "Rex DUO connected" notice, next to the welcome.
    crate::notice::authorize();
    let r = wait_for_start(Duration::from_secs(5));
    let state = match &r {
        Some(r) if r.connected => "It's connected to Rex on this Mac",
        Some(_) => "It's waiting for Rex to start on this Mac",
        None => "It's starting",
    };
    let text = format!(
        "Rex DUO Helper is on.\n\n{state}, and it starts by itself when you log in.\n\n\
         On your iPhone, open Rex DUO and turn on notifications. You'll get a push when an agent needs you or finishes."
    );
    if dialog(&text, &["Turn Off", "Done"]) == "Turn Off" {
        stop_agent();
        dialog("Rex DUO Helper is off. Open it again to turn it back on.", &["OK"]);
    }
    0
}
