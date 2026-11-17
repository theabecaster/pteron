//! Running in the background: `install`, `status`, `uninstall`, and the Mac app's
//! open-once flow. Linux uses a systemd user service; macOS a per-user LaunchAgent.

use crate::config::{default_state_dir, home};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

/// Prints a line, ignoring a closed pipe (`status | head`).
macro_rules! say {
    ($($t:tt)*) => {{
        use std::io::Write;
        let _ = writeln!(std::io::stdout(), $($t)*);
    }};
}

pub const NAME: &str = "rex-duo-helper";
#[cfg(any(target_os = "macos", test))]
pub const LABEL: &str = "dev.abrahamgonzalez.rexduo.helper";

/// What the running helper last wrote to status.json, if it is alive.
pub struct Running {
    pub pid: u64,
    pub version: String,
    pub connected: bool,
    pub servers: Vec<String>,
    pub dry_run: bool,
    #[cfg_attr(not(target_os = "macos"), allow(dead_code))] // used to restart an updated Mac app
    pub exe_mtime: u64,
    /// The newest version the helper knows of, when it is newer than the one running.
    pub update: Option<String>,
    /// Why the last update check or update failed.
    pub update_error: Option<String>,
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
        pid,
        version: v["version"].as_str().unwrap_or("?").into(),
        connected: v["connected"].as_bool().unwrap_or(false),
        servers: v["servers"].as_array().map(|a| a.iter().filter_map(|s| s.as_str().map(String::from)).collect()).unwrap_or_default(),
        dry_run: v["dry_run"].as_bool().unwrap_or(false),
        exe_mtime: v["exe_mtime"].as_u64().unwrap_or(0),
        update: v["latest_version"].as_str().filter(|_| v["update_available"].as_bool() == Some(true)).map(String::from),
        update_error: v["last_error"].as_str().map(String::from),
    })
}

pub fn pid_alive(pid: u64) -> bool {
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

/// Runs a system tool (by name) or a program (by full path); true if it succeeded.
fn quiet(cmd: &str, args: &[&str]) -> bool {
    let Some(mut command) = crate::tools::command(cmd) else { return false };
    command.args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status().is_ok_and(|s| s.success())
}

/// What a system tool or a program printed, if it succeeded.
fn output(cmd: &str, args: &[&str]) -> Option<String> {
    let o = crate::tools::command(cmd)?.args(args).stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
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
            let mode = if r.dry_run { " (dry run: pushes are logged, not sent)" } else { "" };
            if r.connected {
                format!("Rex DUO Helper {} is running and connected to Rex at {}{mode}.", r.version, r.servers.join(", "))
            } else {
                format!("Rex DUO Helper {} is running and waiting for Rex to start{mode}.", r.version)
            }
        }
    }
}

/// What the running helper knows about updates, for `status`. Nothing when there is nothing to say.
fn update_note(r: &Option<Running>) -> Option<String> {
    let r = r.as_ref()?;
    match (&r.update, &r.update_error) {
        (Some(v), Some(e)) => Some(format!("Version {v} is available. {e}")),
        (Some(v), None) => Some(format!("Version {v} is available. To install it now: {NAME} update")),
        (None, Some(e)) => Some(format!("Updates: {e}")),
        (None, None) => None,
    }
}

/// Phones in devices.json that this helper can push to (an entry from before the push gateway
/// has no secret and doesn't count).
fn phones() -> usize {
    std::fs::read(default_state_dir().join("devices.json"))
        .ok()
        .and_then(|d| serde_json::from_slice::<Vec<Value>>(&d).ok())
        .map_or(0, |v| v.iter().filter(|d| d["push_secret"].is_string() && d["owner"].is_string()).count())
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

/// True if the systemd user service is set up.
#[cfg(not(target_os = "macos"))]
pub fn installed() -> bool {
    unit_path().exists()
}

/// Restarts the background service, so it runs the binary that is on disk now.
#[cfg(not(target_os = "macos"))]
pub fn restart() -> bool {
    systemctl(&["restart", NAME])
}

#[cfg(not(target_os = "macos"))]
fn user() -> String {
    std::env::var("USER").ok().or_else(|| output("id", &["-un"])).unwrap_or_default()
}

/// The arguments that ask `loginctl` whether `user`'s services outlive their last session.
#[cfg(any(not(target_os = "macos"), test))]
fn linger_query(user: &str) -> [&str; 5] {
    ["show-user", user, "-p", "Linger", "--value"]
}

/// What `loginctl` printed for that question: `yes` or `no`. Anything else is no answer.
#[cfg(any(not(target_os = "macos"), test))]
fn parse_linger(printed: &str) -> Option<bool> {
    match printed.trim() {
        "yes" => Some(true),
        "no" => Some(false),
        _ => None,
    }
}

#[cfg(not(target_os = "macos"))]
fn linger() -> Option<bool> {
    output("loginctl", &linger_query(&user())).and_then(|v| parse_linger(&v))
}

/// Whether the helper keeps running after logout, for `helper_status`. None when `loginctl`
/// is missing or doesn't say.
#[cfg(not(target_os = "macos"))]
pub async fn linger_state() -> Option<bool> {
    let loginctl = crate::tools::program(Path::new("loginctl"))?;
    let printed = crate::discovery::run(&loginctl, &linger_query(&user())).await?;
    parse_linger(&String::from_utf8_lossy(&printed))
}

/// Lingering is a systemd setting; a Mac has no such question.
#[cfg(target_os = "macos")]
pub async fn linger_state() -> Option<bool> {
    None
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

/// A program's path as one word of a unit file's `ExecStart=`: in double quotes, so spaces
/// stay inside the word, with `\` and `"` escaped as systemd's quoting has them, and `%`
/// and `$` doubled, because a single one starts a specifier or a variable. None for a path a unit file can't hold:
/// one that is not text, or has a control character in it.
#[cfg(any(not(target_os = "macos"), test))]
fn unit_word(path: &Path) -> Option<String> {
    let text = path.to_str().filter(|t| !t.chars().any(char::is_control))?;
    Some(format!("\"{}\"", text.replace('\\', "\\\\").replace('"', "\\\"").replace('%', "%%").replace('$', "$$")))
}

/// The systemd user unit that runs the helper at `bin`.
#[cfg(any(not(target_os = "macos"), test))]
fn unit_text(bin: &Path) -> Option<String> {
    Some(format!(
        "[Unit]\n\
         Description=Rex DUO Helper (push notifications from Rex to the Rex DUO iPhone app)\n\n\
         [Service]\n\
         ExecStart={} run\n\
         Restart=on-failure\n\
         RestartSec=5\n\
         Nice=5\n\n\
         [Install]\n\
         WantedBy=default.target\n",
        unit_word(bin)?
    ))
}

/// `config_changed` is for the Mac, which restarts a running helper only when it has to; here
/// the service is always restarted.
#[cfg(not(target_os = "macos"))]
pub fn install(_config_changed: bool) -> i32 {
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
    let Some(unit) = unit_text(&bin) else {
        eprintln!("Could not install: a systemd unit can't name the path {}.", bin.display());
        return 1;
    };
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
    if let Some(note) = update_note(&r) {
        say!("{note}");
    }
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
pub(crate) fn domain() -> String {
    format!("gui/{}", output("/usr/bin/id", &["-u"]).unwrap_or_else(|| "501".into()))
}

#[cfg(target_os = "macos")]
fn loaded() -> bool {
    loaded_label(LABEL)
}

#[cfg(target_os = "macos")]
pub(crate) fn loaded_label(label: &str) -> bool {
    quiet("/bin/launchctl", &["print", &format!("{}/{label}", domain())])
}

/// True if the LaunchAgent is set up.
#[cfg(target_os = "macos")]
pub fn installed() -> bool {
    plist_path().exists()
}

/// Restarts the background job, so it runs the app that is on disk now.
#[cfg(target_os = "macos")]
pub fn restart() -> bool {
    quiet("/bin/launchctl", &["kickstart", "-k", &format!("{}/{LABEL}", domain())])
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

/// Text as the content of an XML element.
#[cfg(any(target_os = "macos", test))]
fn xml(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;")
}

/// The LaunchAgent that runs the helper at `program`, now and at every login.
#[cfg(any(target_os = "macos", test))]
fn agent_plist(program: &Path) -> String {
    format!(
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
    )
}

/// Writes the LaunchAgent and (re)starts the helper. Quiet; returns an error to show. A helper
/// that already runs this version is left running unless `restart` says its config changed.
#[cfg(target_os = "macos")]
fn start_agent(restart: bool) -> Result<(), String> {
    // From the app, run the binary inside it; otherwise install a copy to ~/.local/bin.
    let program = match bundle() {
        Some(_) => std::env::current_exe().map_err(|e| e.to_string())?,
        None => install_binary()?,
    };
    let plist = agent_plist(&program);
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
        if stale || restart {
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
pub fn install(config_changed: bool) -> i32 {
    for note in crate::legacy::migrate() {
        say!("Moving from the old name: {note}");
    }
    if let Err(e) = start_agent(config_changed) {
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
    if let Some(note) = update_note(&r) {
        say!("{note}");
    }
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

/// How the app's own binary was started without a command.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Opening {
    /// Opened by the person, from Finder or the Dock: start the helper and say so in a dialog.
    ByHand,
    /// Opened by Rex DUO's setup (`open -g -a … --args phone-setup`) while the person is at
    /// their phone: start the helper and ask for the notification permission. No dialog.
    PhoneSetup,
}

/// What opening the app does to the Mac. The flow below decides which of these happen; the
/// real ones are `MacApp`.
#[cfg(any(target_os = "macos", test))]
trait AppHost {
    /// True when the app runs from where it was put, not from a translocated copy.
    fn in_place(&self) -> bool;
    /// Starts the background helper, now and at every login.
    fn start(&mut self) -> Result<(), String>;
    fn stop(&mut self);
    /// Asks macOS whether the helper may show notifications, if that is still undecided.
    fn authorize(&mut self);
    /// Waits a moment for the helper to come up and returns what it reports.
    fn started(&mut self) -> Option<Running>;
    /// Shows a dialog; returns the button clicked.
    fn dialog(&mut self, text: &str, buttons: &[&str]) -> String;
}

/// Opening Rex DUO Helper.app: start the background helper (and at every login). Opened by
/// hand it then says so in one small dialog; opened by Rex DUO's setup it only asks for the
/// notification permission, and shows nothing of its own whatever happens. The process
/// exits; only the helper keeps running.
#[cfg(any(target_os = "macos", test))]
fn open_flow(opening: Opening, host: &mut dyn AppHost) -> i32 {
    if opening == Opening::PhoneSetup {
        if !host.in_place() || host.start().is_err() {
            return 1;
        }
        host.authorize();
        return 0;
    }
    if !host.in_place() {
        host.dialog("Move Rex DUO Helper to your Applications folder, then open it again.", &["OK"]);
        return 0;
    }
    if let Err(e) = host.start() {
        host.dialog(&format!("Rex DUO Helper couldn't start.\n\n{e}"), &["OK"]);
        return 1;
    }
    // The permission question for the "Rex DUO connected" notice, next to the welcome.
    host.authorize();
    let r = host.started();
    let state = match &r {
        Some(r) if r.connected => "It's connected to Rex on this Mac",
        Some(_) => "It's waiting for Rex to start on this Mac",
        None => "It's starting",
    };
    let text = format!(
        "Rex DUO Helper is on.\n\n{state}, and it starts by itself when you log in.\n\n\
         On your iPhone, open Rex DUO and turn on notifications. You'll get a push when an agent needs you or finishes."
    );
    if host.dialog(&text, &["Turn Off", "Done"]) == "Turn Off" {
        host.stop();
        host.dialog("Rex DUO Helper is off. Open it again to turn it back on.", &["OK"]);
    }
    0
}

#[cfg(target_os = "macos")]
struct MacApp;

#[cfg(target_os = "macos")]
impl AppHost for MacApp {
    fn in_place(&self) -> bool {
        bundle().is_some_and(|b| !b.to_string_lossy().contains("/AppTranslocation/"))
    }
    fn start(&mut self) -> Result<(), String> {
        crate::legacy::migrate();
        start_agent(false)
    }
    fn stop(&mut self) {
        stop_agent();
    }
    fn authorize(&mut self) {
        crate::notice::authorize();
    }
    fn started(&mut self) -> Option<Running> {
        wait_for_start(Duration::from_secs(5))
    }
    fn dialog(&mut self, text: &str, buttons: &[&str]) -> String {
        dialog(text, buttons)
    }
}

#[cfg(target_os = "macos")]
pub fn open_app(opening: Opening) -> i32 {
    open_flow(opening, &mut MacApp)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn running(update: Option<&str>, error: Option<&str>) -> Option<Running> {
        Some(Running {
            pid: 1,
            version: "0.3.0".into(),
            connected: true,
            servers: vec!["https://rex.example.ts.net".into()],
            dry_run: false,
            exe_mtime: 0,
            update: update.map(String::from),
            update_error: error.map(String::from),
        })
    }

    #[test]
    fn status_sentences() {
        assert_eq!(describe(&None), "Rex DUO Helper is not running.");
        assert_eq!(describe(&running(None, None)), "Rex DUO Helper 0.3.0 is running and connected to Rex at https://rex.example.ts.net.");
        let mut dry = running(None, None);
        dry.as_mut().unwrap().dry_run = true;
        dry.as_mut().unwrap().connected = false;
        assert_eq!(describe(&dry), "Rex DUO Helper 0.3.0 is running and waiting for Rex to start (dry run: pushes are logged, not sent).");
    }

    #[test]
    fn update_notes() {
        assert_eq!(update_note(&None), None);
        assert_eq!(update_note(&running(None, None)), None);
        assert_eq!(update_note(&running(Some("0.3.1"), None)).unwrap(), "Version 0.3.1 is available. To install it now: rex-duo-helper update");
        assert_eq!(update_note(&running(None, Some("Could not get the update manifest."))).unwrap(), "Updates: Could not get the update manifest.");
        assert!(update_note(&running(Some("0.3.1"), Some("It did not start."))).unwrap().starts_with("Version 0.3.1 is available. It did"));
    }

    #[test]
    fn lingering_is_asked_of_loginctl_and_read_as_yes_or_no() {
        assert_eq!(linger_query("alex"), ["show-user", "alex", "-p", "Linger", "--value"]);
        assert_eq!(parse_linger("yes\n"), Some(true));
        assert_eq!(parse_linger("no"), Some(false));
        for other in ["", "Linger=yes", "YES", "true", "yes no"] {
            assert_eq!(parse_linger(other), None, "{other:?}");
        }
    }

    #[test]
    fn the_unit_names_the_helper_as_one_quoted_word() {
        let plain = unit_text(Path::new("/home/alex/.local/bin/rex-duo-helper")).unwrap();
        assert!(plain.contains("\n[Service]\nExecStart=\"/home/alex/.local/bin/rex-duo-helper\" run\nRestart=on-failure\n"));
        // A space, a quote, a percent sign, a dollar sign and a backslash in the home folder's name.
        let odd = unit_text(Path::new(r#"/home/Alex "A" 100%\x $HOME ${a}/.local/bin/rex-duo-helper"#)).unwrap();
        assert!(odd.contains(concat!("\nExecStart=", r#""/home/Alex \"A\" 100%%\\x $$HOME $${a}/.local/bin/rex-duo-helper" run"#, "\n")), "{odd}");
        assert_eq!(unit_word(Path::new("/home/us$er/rex-duo-helper")).as_deref(), Some(r#""/home/us$$er/rex-duo-helper""#));
        // Everything else in the unit is the same, line for line.
        assert_eq!(odd.lines().count(), plain.lines().count());
        assert_eq!(odd.lines().filter(|l| !l.starts_with("ExecStart=")).collect::<Vec<_>>(), plain.lines().filter(|l| !l.starts_with("ExecStart=")).collect::<Vec<_>>());
        // A path that would end the line, and one that is not text, are not written at all.
        assert_eq!(unit_text(Path::new("/home/a\nExecStartPre=/bin/x/rex-duo-helper")), None);
        assert_eq!(unit_text(Path::new("/home/a\tb/rex-duo-helper")), None);
        use std::os::unix::ffi::OsStrExt;
        assert_eq!(unit_text(Path::new(std::ffi::OsStr::from_bytes(b"/home/\xff/rex-duo-helper"))), None);
    }

    #[test]
    fn the_launch_agent_names_the_helper_as_text() {
        let plain = agent_plist(Path::new("/Applications/Rex DUO Helper.app/Contents/MacOS/rex-duo-helper"));
        assert!(plain.contains(
            "<array><string>/Applications/Rex DUO Helper.app/Contents/MacOS/rex-duo-helper</string><string>run</string><string>--log-file</string></array>"
        ));
        assert!(plain.contains("<key>Label</key><string>dev.abrahamgonzalez.rexduo.helper</string>"));
        // A home folder with markup in its name stays one string.
        let odd = agent_plist(Path::new(r#"/Users/A&B <c> "d" 'e'/.local/bin/rex-duo-helper"#));
        assert!(odd.contains(r#"<array><string>/Users/A&amp;B &lt;c&gt; "d" 'e'/.local/bin/rex-duo-helper</string><string>run</string>"#), "{odd}");
        for tag in ["<string>", "</string>", "<key>", "<dict>", "<array>"] {
            assert_eq!(odd.matches(tag).count(), plain.matches(tag).count(), "{tag}");
        }
        assert_eq!(odd.matches('&').count(), 3);
    }

    /// Records what opening the app did. A dialog shown during a phone setup fails the test
    /// on the spot.
    struct FakeApp {
        in_place: bool,
        start: Result<(), String>,
        click: &'static str,
        dialogs_allowed: bool,
        did: Vec<String>,
    }

    impl FakeApp {
        fn new(dialogs_allowed: bool) -> FakeApp {
            FakeApp { in_place: true, start: Ok(()), click: "Done", dialogs_allowed, did: vec![] }
        }
    }

    impl AppHost for FakeApp {
        fn in_place(&self) -> bool {
            self.in_place
        }
        fn start(&mut self) -> Result<(), String> {
            self.did.push("start".into());
            self.start.clone()
        }
        fn stop(&mut self) {
            self.did.push("stop".into());
        }
        fn authorize(&mut self) {
            self.did.push("authorize".into());
        }
        fn started(&mut self) -> Option<Running> {
            self.did.push("started".into());
            running(None, None)
        }
        fn dialog(&mut self, text: &str, _buttons: &[&str]) -> String {
            assert!(self.dialogs_allowed, "a dialog was shown: {text}");
            self.did.push(format!("dialog: {}", text.lines().next().unwrap_or("")));
            self.click.into()
        }
    }

    #[test]
    fn a_phone_setup_starts_the_helper_and_asks_permission_without_a_dialog() {
        let mut app = FakeApp::new(false);
        assert_eq!(open_flow(Opening::PhoneSetup, &mut app), 0);
        assert_eq!(app.did, ["start", "authorize"]);

        // Nothing it runs into brings up a dialog either.
        let mut failing = FakeApp::new(false);
        failing.start = Err("launchctl bootstrap failed".into());
        assert_eq!(open_flow(Opening::PhoneSetup, &mut failing), 1);
        assert_eq!(failing.did, ["start"]);
        let mut moved = FakeApp::new(false);
        moved.in_place = false;
        assert_eq!(open_flow(Opening::PhoneSetup, &mut moved), 1);
        assert!(moved.did.is_empty());
    }

    #[test]
    fn opening_the_app_by_hand_shows_its_dialogs() {
        let mut app = FakeApp::new(true);
        assert_eq!(open_flow(Opening::ByHand, &mut app), 0);
        assert_eq!(app.did, ["start", "authorize", "started", "dialog: Rex DUO Helper is on."]);

        let mut off = FakeApp::new(true);
        off.click = "Turn Off";
        assert_eq!(open_flow(Opening::ByHand, &mut off), 0);
        assert_eq!(off.did[3..], ["dialog: Rex DUO Helper is on.", "stop", "dialog: Rex DUO Helper is off. Open it again to turn it back on."]);

        let mut failing = FakeApp::new(true);
        failing.start = Err("no".into());
        assert_eq!(open_flow(Opening::ByHand, &mut failing), 1);
        assert_eq!(failing.did, ["start", "dialog: Rex DUO Helper couldn't start."]);
        let mut moved = FakeApp::new(true);
        moved.in_place = false;
        assert_eq!(open_flow(Opening::ByHand, &mut moved), 0);
        assert_eq!(moved.did, ["dialog: Move Rex DUO Helper to your Applications folder, then open it again."]);
    }
}
