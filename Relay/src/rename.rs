//! The Mac app takes its name, `brand::APP_FOLDER`.
//!
//! The app had other names before (`update::EARLIER_APP_NAMES`), and a release still carries
//! a zip for each of them that holds the app under that folder name, for the updaters of the
//! versions that look for exactly that folder. So this program can start from a bundle of any
//! of those names. Started from an earlier one, it renames its bundle where it sits, has the
//! LaunchAgent run it from the new path, restarts there, and confirms that the helper runs
//! from there. The bundle id, the state folder and the log keep their names, so macOS keeps
//! what the user allowed.
//!
//! macOS keeps the app's path in its Launch Services record too. `lsregister` forgets the
//! earlier path and records the new one, and after that the LaunchAgent is written for the
//! new path and loaded. `lsregister` is best effort: one that is missing or fails changes
//! nothing about the move.
//!
//! The LaunchAgent has a label of its own to move to (src/label.rs). An app that an earlier
//! version's updater installed runs under an earlier name and an earlier label, and makes
//! both moves as one, with one restart (`carry_out_with`): the bundle is renamed, Launch
//! Services is told, the new label's file is written for the new path, the earlier jobs are
//! booted out and the new one loaded, and once the helper reports in from there the earlier
//! labels' files are deleted. So the entry in Login Items is made for the app under its name.
//! An app that has its name and still runs under an earlier label makes the label's move alone.
//!
//! Two things start a move:
//!
//! - The background service, a while after it started (`at_start`). It cannot restart itself:
//!   unloading its own job ends it. It starts the same separate launchd job that finishes an
//!   update (`update::spawn_job`), as `finish-move`, and that job does every step.
//! - `install` and opening the app (`on_install`), which are not the service and do the steps
//!   themselves.
//!
//! A service that starts while the new label and an earlier one both have a file settles that
//! before it serves (`before_start`).
//!
//! What to do is decided by `plan` and done by `carry_out`, both tested below with stand-ins
//! for launchd and codesign. A step that fails leaves the app where it was, running, with one
//! line in the log. The start that the way back causes leaves it at that, and the start after
//! it tries again.

use crate::label::Agents;
use crate::service::NAME;
use crate::update::{Version, APP_NAME, EARLIER_APP_NAMES, EARLIER_PREVIOUS_APPS};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// What `plan` asks about an app that is already under the new name.
pub struct Look<'a> {
    /// The app's code signature is intact and ours.
    pub signature_ok: &'a dyn Fn(&Path) -> bool,
    /// The version in the app's Info.plist.
    pub version: &'a dyn Fn(&Path) -> Option<String>,
}

/// One move, decided.
#[derive(Clone, Debug, PartialEq)]
pub struct Step {
    /// The bundle under an earlier name.
    pub from: PathBuf,
    /// The app's name, beside it.
    pub to: PathBuf,
    /// True when `to` is already there, whole and at least as new: then nothing is renamed,
    /// the helper starts from `to`, and `from` is removed.
    pub leftover: bool,
}

/// What to do about `bundle`, the app this program runs from. `Ok(None)` when it has its name
/// already or is no app of ours; `Err` says in plain words why it stays as it is.
///
/// The bundle is only touched when it is a real folder, not a link, directly in one of
/// `homes` (`/Applications` and `~/Applications`).
pub fn plan(bundle: &Path, homes: &[PathBuf], own_version: &str, look: &Look) -> Result<Option<Step>, String> {
    if !bundle.file_name().is_some_and(is_earlier_name) {
        return Ok(None);
    }
    let Some(home) = bundle.parent().filter(|dir| homes.iter().any(|h| h == dir)) else {
        return Err("it is not in an Applications folder".into());
    };
    if !std::fs::symlink_metadata(bundle).is_ok_and(|m| m.is_dir()) {
        return Err("it is a link, not a folder".into());
    }
    let to = home.join(APP_NAME);
    let step = |leftover| Ok(Some(Step { from: bundle.to_path_buf(), to: to.clone(), leftover }));
    match std::fs::symlink_metadata(&to) {
        Err(_) => step(false),
        Ok(m) => {
            let newer = (look.version)(&to).and_then(|v| Version::parse(&v)).is_some_and(|v| Some(v) >= Version::parse(own_version));
            if m.is_dir() && newer && (look.signature_ok)(&to) {
                step(true)
            } else {
                Err(format!("something else is at {}", to.display()))
            }
        }
    }
}

/// True for one of the folder names the app had before.
fn is_earlier_name(name: &std::ffi::OsStr) -> bool {
    EARLIER_APP_NAMES.iter().any(|earlier| name == *earlier)
}

/// The outside world `carry_out` needs, so tests can stand in for launchd.
pub struct Effects<'a> {
    /// Tells Launch Services about an app's path: `-u` forgets it, `-f` records the app
    /// that is there. Whatever comes of it, the move goes on.
    pub launch_services: &'a dyn Fn(&str, &Path),
    /// The app's code signature is intact and ours.
    pub signature_ok: &'a dyn Fn(&Path) -> bool,
    /// Has the LaunchAgent run the helper inside this app and starts it there. False when
    /// that could not be done.
    pub start_at: &'a dyn Fn(&Path) -> bool,
    /// Called once the helper reports in from the new place, before the leftovers go.
    pub settled: &'a dyn Fn(),
    /// True once the helper that ran before has exited.
    pub old_gone: &'a dyn Fn() -> bool,
    /// The app the running helper reports it runs from, if one runs.
    pub running_from: &'a dyn Fn() -> Option<PathBuf>,
    /// How long the helper that ran before gets to exit.
    pub exit_wait: Duration,
    /// How long the helper then has to report in from the new place.
    pub wait: Duration,
    pub poll: Duration,
}

/// Does one move: renames the bundle (unless the new one is already there), has Launch
/// Services forget the earlier path and record the new one, starts the helper from the new
/// place, and waits until it reports in from there. Then the earlier names' leftovers go, and
/// Launch Services forgets them: the bundle itself when it was not renamed, an app still there
/// under any other earlier name, and a copy an update set aside under any earlier name.
///
/// When the helper does not come up there, everything goes back: the bundle to its earlier
/// name, Launch Services to the earlier path, the LaunchAgent to its earlier path, and the
/// helper is started from there again.
pub fn carry_out(step: &Step, fx: &Effects) -> Result<(), String> {
    if !step.leftover {
        std::fs::rename(&step.from, &step.to).map_err(|e| format!("it could not be renamed ({e})"))?;
    }
    // Before the LaunchAgent is written for the new path.
    (fx.launch_services)("-u", &step.from);
    (fx.launch_services)("-f", &step.to);
    let started = (fx.start_at)(&step.to);
    if started {
        let asked = Instant::now();
        while !(fx.old_gone)() && asked.elapsed() < fx.exit_wait {
            std::thread::sleep(fx.poll);
        }
        let began = Instant::now();
        loop {
            if (fx.running_from)().as_deref() == Some(step.to.as_path()) {
                (fx.settled)();
                // The program that does this may be running from the folder it removes: it
                // keeps running after the folder's name is gone.
                if step.leftover {
                    let _ = std::fs::remove_dir_all(&step.from);
                    (fx.launch_services)("-u", &step.from);
                }
                remove_other_earlier(&step.to, &step.from, fx.signature_ok, fx.launch_services);
                remove_old_previous(&step.to, fx.signature_ok, fx.launch_services);
                return Ok(());
            }
            if began.elapsed() >= fx.wait {
                break;
            }
            std::thread::sleep(fx.poll);
        }
    }
    if !step.leftover {
        std::fs::rename(&step.to, &step.from).map_err(|e| format!("it did not start under its new name, and could not be renamed back ({e})"))?;
        (fx.launch_services)("-u", &step.to);
    }
    (fx.launch_services)("-f", &step.from);
    (fx.start_at)(&step.from);
    Err(if started { "it did not start under its new name".into() } else { "its background job could not be pointed at the new name".into() })
}

/// What `carry_out_with` needs besides the LaunchAgent's files and jobs.
pub struct World<'a> {
    pub launch_services: &'a dyn Fn(&str, &Path),
    /// The app's code signature is intact and ours.
    pub signature_ok: &'a dyn Fn(&Path) -> bool,
    /// True once the helper that ran before has exited.
    pub old_gone: &'a dyn Fn() -> bool,
    /// True once the helper reports that it runs this program under the new label.
    pub runs_new: &'a dyn Fn(&Path) -> bool,
    pub exit_wait: Duration,
    pub wait: Duration,
    pub poll: Duration,
}

/// One move, `carry_out`, with the LaunchAgent as it is found. Under an earlier label, the
/// label moves in the same steps (src/label.rs): the helper is started at the new place by
/// writing the new label's file for it, booting the earlier job out and loading the new one,
/// and the earlier label's file is deleted once the helper reports in. On the way back the
/// new job is booted out, its file removed, and the earlier job loaded from its file, which
/// still names the earlier path. Under the new label, its file is written for the new place
/// and the job loaded again.
pub fn carry_out_with(step: &Step, agents: &Agents, world: &World) -> Result<(), String> {
    let relabels = std::cell::Cell::new(false);
    carry_out(
        step,
        &Effects {
            launch_services: world.launch_services,
            signature_ok: world.signature_ok,
            start_at: &|app| {
                let program = program_in(app);
                if app == step.to && agents.has_earlier() {
                    relabels.set(true);
                    agents.begin(&program)
                } else if relabels.get() {
                    agents.back_out()
                } else {
                    agents.restart_into(&program)
                }
            },
            settled: &|| {
                if relabels.get() {
                    agents.settle();
                }
            },
            old_gone: world.old_gone,
            running_from: &|| (world.runs_new)(&program_in(&step.to)).then(|| step.to.clone()),
            exit_wait: world.exit_wait,
            wait: world.wait,
            poll: world.poll,
        },
    )
}

/// Removes the apps still beside `app` under an earlier name (`EARLIER_APP_NAMES`) and has
/// Launch Services forget them, so a Mac that had the app under two earlier names keeps one
/// app. `moved` is the bundle the move was about, which `carry_out` has dealt with itself. As
/// for a set-aside copy, only a real folder of such a name whose code signature is intact and
/// ours goes; another one stays where it is, with one line in the log.
fn remove_other_earlier(app: &Path, moved: &Path, signature_ok: &dyn Fn(&Path) -> bool, launch_services: &dyn Fn(&str, &Path)) {
    let Some(dir) = app.parent() else { return };
    for earlier in EARLIER_APP_NAMES.map(|name| dir.join(name)) {
        if earlier == moved || !std::fs::symlink_metadata(&earlier).is_ok_and(|m| m.is_dir()) {
            continue;
        }
        if !signature_ok(&earlier) {
            crate::info!("{} stays where it is: it did not pass the code signature check", earlier.display());
        } else if std::fs::remove_dir_all(&earlier).is_ok() {
            launch_services("-u", &earlier);
        }
    }
}

/// Removes the copies an update set aside beside `app` under an earlier name
/// (`EARLIER_PREVIOUS_APPS`) and has Launch Services forget them: a real folder of such a name
/// whose code signature is intact and ours. Another folder of that name stays where it is,
/// with one line in the log.
fn remove_old_previous(app: &Path, signature_ok: &dyn Fn(&Path) -> bool, launch_services: &dyn Fn(&str, &Path)) {
    let Some(dir) = app.parent() else { return };
    for previous in EARLIER_PREVIOUS_APPS.map(|name| dir.join(name)) {
        if !std::fs::symlink_metadata(&previous).is_ok_and(|m| m.is_dir()) {
            continue;
        }
        if !signature_ok(&previous) {
            crate::info!("{} stays where it is: it did not pass the code signature check", previous.display());
        } else if std::fs::remove_dir_all(&previous).is_ok() {
            launch_services("-u", &previous);
        }
    }
}

/// The tool that edits the Launch Services records. It is in no folder of `tools::DIRS`, so
/// it is run by this path.
#[cfg(any(target_os = "macos", test))]
const LSREGISTER: &str = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
/// How long one run of it may take.
#[cfg(any(target_os = "macos", test))]
const LSREGISTER_WAIT: Duration = Duration::from_secs(10);

/// Runs `tool`, which is `lsregister` or a test's stand-in for it, with `flag` and `app`. A
/// tool that is not there, can't be run, fails or takes too long is one line in the log, the
/// first time in this process, and nothing more.
#[cfg(any(target_os = "macos", test))]
fn tell_launch_services(tool: &Path, flag: &str, app: &Path) {
    static SAID: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
    if let Err(why) = bounded(tool, &[flag.into(), app.into()], LSREGISTER_WAIT) {
        if !SAID.swap(true, std::sync::atomic::Ordering::Relaxed) {
            crate::info!("Launch Services was not told about the app's name: lsregister {why}");
        }
    }
}

/// Runs a program by its full path and waits for it, for `limit` at most; then it is stopped.
/// `Err` says in plain words why it did not succeed.
#[cfg(any(target_os = "macos", test))]
fn bounded(program: &Path, args: &[std::ffi::OsString], limit: Duration) -> Result<(), String> {
    use std::process::Stdio;
    let mut command = crate::tools::command(program).ok_or("is not named by a full path")?;
    let mut child = command.args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).spawn().map_err(|e| format!("could not be run ({e})"))?;
    let began = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok(()),
            Ok(Some(status)) => return Err(format!("failed ({status})")),
            Ok(None) if began.elapsed() < limit => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err("took too long".into());
            }
        }
    }
}

/// The app a helper program sits in: `<app>/Contents/MacOS/rex-duo-helper`.
pub fn app_of(program: &Path) -> Option<PathBuf> {
    let macos = program.parent().filter(|dir| dir.ends_with("Contents/MacOS"))?;
    (program.file_name()? == NAME).then(|| macos.parent()?.parent().map(Path::to_path_buf)).flatten()
}

fn program_in(app: &Path) -> PathBuf {
    app.join("Contents/MacOS").join(NAME)
}

/// True while an installer run holds setup.lock in the state folder: its `owner` file names a
/// live process and a time within the last 30 minutes, the rule `Relay/setup.sh` applies. A
/// lock without that file counts as held for its first minute.
pub fn installer_busy(state_dir: &Path, now: u64, alive: impl Fn(u64) -> bool) -> bool {
    let lock = state_dir.join("setup.lock");
    let Ok(meta) = std::fs::symlink_metadata(&lock) else { return false };
    let Ok(owner) = std::fs::read_to_string(lock.join("owner")) else {
        let age = meta.modified().ok().and_then(|t| t.elapsed().ok());
        return age.is_none_or(|a| a < Duration::from_secs(60));
    };
    let mut words = owner.split_whitespace().map(|w| w.parse::<u64>().ok());
    match (words.next().flatten(), words.next().flatten()) {
        (Some(pid), Some(at)) => alive(pid) && now.saturating_sub(at) <= 1800,
        _ => false,
    }
}

// MARK: On this Mac

#[cfg(target_os = "macos")]
mod mac {
    use super::*;
    use crate::label::{self, AtStart, Confirm};
    use crate::brand::BEACON;
    use crate::service::LABEL;
    use crate::update::{forget_job, mac_signature_ok, os, spawn_job, tool, UpdateLock, VERSION};
    use crate::{info, service};

    /// How long after its start the service waits before it moves. An updater that restarted
    /// it is still watching it come up, and holds update.lock until it has.
    const START_DELAY: Duration = Duration::from_secs(30);
    /// How long the service then waits for an update or an installer run to end.
    const QUIET_WAIT: Duration = Duration::from_secs(10 * 60);
    const EXIT_TIMEOUT: Duration = Duration::from_secs(15);
    const CONFIRM_TIMEOUT: Duration = Duration::from_secs(20);

    fn homes() -> Vec<PathBuf> {
        vec![PathBuf::from("/Applications"), crate::config::home().join("Applications")]
    }

    fn app_version(app: &Path) -> Option<String> {
        let plist = app.join("Contents/Info.plist");
        let (ok, found) = tool("/usr/bin/plutil", &[os("-extract"), os("CFBundleShortVersionString"), os("raw"), os("-o"), os("-"), os(&plist)]).ok()?;
        ok.then(|| found.trim().to_string())
    }

    fn real_plan(bundle: &Path) -> Result<Option<Step>, String> {
        plan(bundle, &homes(), VERSION, &Look { signature_ok: &signature_ok, version: &app_version })
    }

    fn real_carry_out(step: &Step, old_pid: Option<u64>) -> Result<(), String> {
        carry_out_with(
            step,
            &service::agents(),
            &World {
                launch_services: &launch_services,
                signature_ok: &signature_ok,
                old_gone: &|| old_pid.is_none_or(|pid| !service::pid_alive(pid)),
                runs_new: &service::runs_new,
                exit_wait: EXIT_TIMEOUT,
                wait: CONFIRM_TIMEOUT,
                poll: Duration::from_millis(250),
            },
        )
    }

    fn launch_services(flag: &str, app: &Path) {
        tell_launch_services(Path::new(LSREGISTER), flag, app);
    }

    fn signature_ok(app: &Path) -> bool {
        mac_signature_ok(app).unwrap_or(false)
    }

    fn stays(why: &str) {
        info!("the app keeps its earlier name for now: {why}");
    }

    fn keeps_label(why: &str) {
        info!("the background job keeps its earlier label for now: {why}");
    }

    /// This program, as a real path.
    fn own_exe() -> Option<PathBuf> {
        std::env::current_exe().and_then(|p| p.canonicalize()).ok()
    }

    /// The app this program runs from, as a real path.
    fn own_app() -> Option<(PathBuf, PathBuf)> {
        let exe = own_exe()?;
        let app = app_of(&exe)?;
        Some((exe, app))
    }

    /// What the separate job is started with. Without an app to move, it moves the label.
    fn job_args(from: Option<&Path>, state_dir: &Path) -> Vec<std::ffi::OsString> {
        let mut args = vec![os("finish-move")];
        if let Some(from) = from {
            args.extend([os("--from"), os(from)]);
        }
        args.extend([os("--state-dir"), os(state_dir), os("--old-pid"), os(std::process::id().to_string())]);
        args
    }

    /// Called by the background service before it takes its place as the one helper, for a
    /// Mac where the new label and an earlier one have a file (src/label.rs). Under the new
    /// label the earlier jobs are booted out and their files deleted. Under an earlier label,
    /// with the new job loaded, this process does not serve: true is returned, after the
    /// separate job was started to boot the earlier jobs out and delete their files.
    pub fn before_start(state_dir: &Path, dry_run: bool) -> bool {
        if dry_run || cfg!(debug_assertions) || state_dir != crate::config::default_state_dir() {
            return false;
        }
        let agents = service::agents();
        let moving = UpdateLock::busy(state_dir, service::pid_alive);
        match agents.at_start(service::own_label(), moving) {
            AtStart::DropEarlier => {
                agents.drop_earlier();
                false
            }
            AtStart::StepAside => {
                step_aside(state_dir);
                true
            }
            AtStart::Serve | AtStart::Migrate => false,
        }
    }

    fn step_aside(state_dir: &Path) {
        let Some(exe) = own_exe() else { return };
        // Whoever holds the lock is at work on the job already.
        let Ok(lock) = UpdateLock::acquire(state_dir, service::pid_alive) else { return };
        if let Err(e) = spawn_job(&exe, &job_args(None, state_dir), state_dir) {
            return keeps_label(&e);
        }
        lock.hand_over();
        // The job boots this one out within seconds.
        std::thread::sleep(Duration::from_secs(90));
        UpdateLock::take_back(state_dir);
    }

    /// Called by the background service when it starts. From the app under its name, a copy
    /// an update set aside under an earlier name goes. From the app under an earlier name,
    /// or as a job under an earlier label, the move is started in the background, once: a
    /// move that does not happen is tried again at the next start.
    pub fn at_start(state_dir: &Path, dry_run: bool) {
        if dry_run || cfg!(debug_assertions) || state_dir != crate::config::default_state_dir() {
            return;
        }
        let Some(exe) = own_exe() else { return };
        let app = app_of(&exe);
        if let Some(app) = app.as_ref().filter(|app| app.file_name().is_some_and(|n| n == APP_NAME) && app.parent().is_some_and(|dir| homes().iter().any(|h| h == dir))) {
            remove_old_previous(app, &signature_ok, &launch_services);
        }
        // Only the helper the LaunchAgent runs moves: it is the one a restart brings back.
        let moves = app.filter(|app| app.file_name().is_some_and(is_earlier_name) && service::agent_runs(&exe));
        let relabels = service::agents().at_start(service::own_label(), false) == AtStart::Migrate;
        // A move that did not hold started this helper again: this start leaves it at that.
        if (moves.is_none() && !relabels) || label::was_put_off(state_dir) {
            return;
        }
        let state_dir = state_dir.to_path_buf();
        std::thread::spawn(move || {
            std::thread::sleep(START_DELAY);
            let said: fn(&str) = if moves.is_some() { stays } else { keeps_label };
            let asked = Instant::now();
            let lock = loop {
                let quiet = !installer_busy(&state_dir, crate::util::now() as u64, service::pid_alive);
                match quiet.then(|| UpdateLock::acquire(&state_dir, service::pid_alive)) {
                    Some(Ok(lock)) => break lock,
                    _ if asked.elapsed() >= QUIET_WAIT => return said("an update or an install was running"),
                    _ => std::thread::sleep(Duration::from_secs(15)),
                }
            };
            let from = match moves.as_deref().map(real_plan) {
                Some(Ok(Some(step))) => Some(step.from),
                Some(Err(why)) => {
                    stays(&why);
                    None
                }
                Some(Ok(None)) | None => None,
            };
            // An app that stays where it is still moves its label.
            if from.is_none() && !relabels {
                return;
            }
            if let Err(e) = spawn_job(&exe, &job_args(from.as_deref(), &state_dir), &state_dir) {
                return said(&e);
            }
            lock.hand_over();
            // The job restarts this service within seconds. Still here much later: it never
            // ran, and nothing was changed.
            std::thread::sleep(Duration::from_secs(90));
            if UpdateLock::take_back(&state_dir) {
                said("the step that moves it did not start");
            }
        });
    }

    /// `rex-duo-helper finish-move [--from APP] [--state-dir DIR] --old-pid PID`: what the
    /// service starts as a job of its own to move its app, or with no app to move, its
    /// LaunchAgent's label. Not for people. It decides again what to do, from the app it was
    /// started in.
    pub fn finish_command(args: &[String]) -> i32 {
        let value = |name: &str| args.iter().position(|a| a == name).and_then(|i| args.get(i + 1)).cloned();
        let from = value("--from").map(PathBuf::from);
        let old_pid = value("--old-pid").and_then(|p| p.parse::<u64>().ok());
        let (Some(exe), true) = (own_exe(), from.is_some() || old_pid.is_some()) else {
            eprintln!("finish-move is run by {BEACON} itself");
            return 2;
        };
        let state_dir = value("--state-dir").map(PathBuf::from).unwrap_or_else(crate::config::default_state_dir);
        let _ = crate::util::log_to_file(crate::config::default_log_file());
        forget_job(&state_dir);
        // Released when this function returns, however the move ended.
        let _lock = UpdateLock::adopt(&state_dir);
        let agents = service::agents();
        let result = match &from {
            Some(from) => match app_of(&exe).map(|app| real_plan(&app)) {
                Some(Ok(Some(step))) if step.from == *from => real_carry_out(&step, old_pid),
                Some(Err(why)) => Err(why),
                _ => Err("it is not the app that asked".into()),
            },
            // With the new label's file there, the move goes on from its second step.
            None if agents.has_earlier() => {
                let confirm = Confirm { runs: &service::runs_new, wait: service::LABEL_WAIT, poll: Duration::from_millis(250) };
                if agents.has(LABEL) {
                    agents.resume(&confirm)
                } else {
                    agents.migrate(&exe, &confirm)
                }
            }
            None => Ok(()),
        };
        match (&result, &from) {
            (Ok(()), Some(_)) => info!("the app is now {APP_NAME}"),
            (Ok(()), None) => info!("the background job is now {LABEL}"),
            (Err(why), Some(_)) => stays(why),
            (Err(why), None) => keeps_label(why),
        }
        if result.is_err() {
            label::put_off(&state_dir);
        }
        i32::from(result.is_err())
    }

    /// Called by `install` and by opening the app, before they set up the LaunchAgent. When
    /// this program runs from the app under an earlier name, the move is done here and now.
    /// Returns the app the helper then runs from, or None when nothing was moved.
    pub fn on_install() -> Option<PathBuf> {
        let (_, app) = own_app()?;
        let step = match real_plan(&app) {
            Ok(step) => step?,
            Err(why) => {
                stays(&why);
                return None;
            }
        };
        let state_dir = crate::config::default_state_dir();
        let _ = std::fs::create_dir_all(&state_dir);
        let Ok(_lock) = UpdateLock::acquire(&state_dir, service::pid_alive) else {
            stays("an update is running");
            return None;
        };
        match real_carry_out(&step, service::running().map(|r| r.pid)) {
            Ok(()) => Some(step.to),
            Err(why) => {
                stays(&why);
                None
            }
        }
    }
}

#[cfg(target_os = "macos")]
pub use mac::{at_start, before_start, finish_command, on_install};

#[cfg(test)]
mod tests {
    use super::*;
    use crate::label::fake::{self, FakeLaunchd};
    use crate::service::{EARLIER_LABELS, LABEL};
    use std::cell::Cell;

    /// One of the names the app had before, with the name a copy an update set aside had
    /// then and the label its job had. Each test below runs once for each of them.
    #[derive(Clone, Copy)]
    struct Earlier {
        app: &'static str,
        previous: &'static str,
        label: &'static str,
    }

    fn generations() -> [Earlier; 2] {
        [0, 1].map(|i| Earlier { app: EARLIER_APP_NAMES[i], previous: EARLIER_PREVIOUS_APPS[i], label: EARLIER_LABELS[i] })
    }

    /// What was asked of lsregister and launchd, with the names of one earlier generation
    /// written as `Earlier.app`, `Earlier.previous.app` and `earlier`, and the app's own name
    /// as `New.app`, so one set of expectations holds for every generation.
    fn plain(text: &str, was: Earlier) -> String {
        text.replace(was.previous, "Earlier.previous.app").replace(was.app, "Earlier.app").replace(APP_NAME, "New.app").replace(fake::short(was.label), "earlier")
    }

    /// A folder that stands in for /Applications, and beside it the LaunchAgent files and a
    /// stand-in for launchd, whose events also hold the calls of lsregister, in order.
    struct Mac {
        dir: PathBuf,
        apps: PathBuf,
        launchd: FakeLaunchd,
    }

    impl Mac {
        fn new(tag: &str) -> Mac {
            let dir = std::env::temp_dir().join(format!("rename-{tag}-{}-{}", std::process::id(), crate::util::now()));
            let _ = std::fs::remove_dir_all(&dir);
            let apps = dir.join("Applications");
            std::fs::create_dir_all(&apps).unwrap();
            Mac { launchd: FakeLaunchd::new(&dir.join("LaunchAgents")), apps, dir }
        }

        /// An app folder with a program in it that says which build it is.
        fn app(&self, name: &str, build: &str) -> PathBuf {
            let app = self.apps.join(name);
            std::fs::create_dir_all(app.join("Contents/MacOS")).unwrap();
            std::fs::write(program_in(&app), build).unwrap();
            app
        }

        fn build(&self, name: &str) -> Option<String> {
            std::fs::read_to_string(program_in(&self.apps.join(name))).ok()
        }

        fn homes(&self) -> Vec<PathBuf> {
            vec![self.apps.clone()]
        }

        /// A LaunchAgent of that label whose job runs the helper of `app`.
        fn seed(&self, label: &str, app: &Path) {
            self.launchd.seed(label, &program_in(app));
        }

        /// The app a label's file names.
        fn agent_app(&self, label: &str) -> Option<PathBuf> {
            app_of(&self.launchd.program(label)?)
        }

        /// The app the helper runs from, and the label it runs under.
        fn running(&self) -> Option<(String, PathBuf)> {
            let (label, program) = self.launchd.running.borrow().clone()?;
            Some((fake::short(&label).to_string(), app_of(&program)?))
        }

        /// A path as the events name it: from the folder that stands in for /Applications.
        fn short(&self, path: &Path) -> String {
            path.strip_prefix(&self.apps).unwrap_or(path).display().to_string()
        }

        /// The events since the last call, in the words of `plain`.
        fn events(&self, was: Earlier) -> Vec<String> {
            self.launchd.events().iter().map(|event| plain(event, was)).collect()
        }

        /// The label files that exist, and the app and label the helper runs from and under.
        fn left(&self, was: Earlier) -> (Vec<String>, Option<(String, PathBuf)>) {
            (self.launchd.files().iter().map(|name| plain(name, was)).collect(), self.running().map(|(label, app)| (plain(&label, was), app)))
        }

        /// The move as this Mac does it, with the stand-ins for lsregister and launchd.
        fn carry_out(&self, step: &Step) -> Result<(), String> {
            carry_out_with(
                step,
                &Agents { dir: self.launchd.dir.clone(), launchd: &self.launchd },
                &World {
                    launch_services: &|flag, app| self.launchd.note(&format!("lsregister {flag} {}", self.short(app))),
                    signature_ok: &|app| self.build(app.file_name().unwrap().to_str().unwrap()).is_some_and(|build| build != "not ours"),
                    old_gone: &|| true,
                    runs_new: &|program| self.launchd.runs_new(program),
                    exit_wait: Duration::from_millis(40),
                    wait: Duration::from_millis(40),
                    poll: Duration::from_millis(5),
                },
            )
        }
    }

    impl Drop for Mac {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    fn look<'a>(signature_ok: &'a dyn Fn(&Path) -> bool, version: &'a dyn Fn(&Path) -> Option<String>) -> Look<'a> {
        Look { signature_ok, version }
    }

    const NOBODY: Look<'static> = Look { signature_ok: &|_| panic!("no app to check"), version: &|_| panic!("no app to read") };

    #[test]
    fn the_names() {
        assert_eq!(APP_NAME, crate::brand::APP_FOLDER);
        // Every earlier name has the name its set-aside copy had, and none is the app's own.
        for was in generations() {
            assert_eq!(was.previous, was.app.replace(".app", ".previous.app"));
            assert!(was.app != APP_NAME && was.app.ends_with(".app") && !was.app.starts_with('.'));
        }
    }

    #[test]
    fn an_app_under_an_earlier_name_and_label_moves_to_both_in_one_sequence() {
        for was in generations() {
            let mac = Mac::new("moves");
            let from = mac.app(was.app, "0.3.1");
            mac.app(was.previous, "0.3.0");
            // As the updater of an earlier version leaves it: the earlier label's job runs the app.
            mac.seed(was.label, &from);
            assert_eq!(mac.agent_app(was.label).as_deref(), Some(from.as_path()));

            let step = plan(&from, &mac.homes(), "0.3.1", &NOBODY).unwrap().unwrap();
            assert_eq!(step, Step { from: from.clone(), to: mac.apps.join(APP_NAME), leftover: false });
            assert_eq!(mac.carry_out(&step), Ok(()));
            // Launch Services forgets the earlier path and records the new one. Only then is the
            // new label's file written, beside the earlier one, and the jobs swapped: the helper
            // is restarted once. The earlier label's file is gone before the leftovers go, and
            // the copy that was set aside is forgotten when it is gone.
            assert_eq!(
                mac.events(was),
                [
                    "lsregister -u Earlier.app [earlier]",
                    "lsregister -f New.app [earlier]",
                    "boot out earlier [agent earlier]",
                    "bootstrap agent [agent earlier]",
                    "lsregister -u Earlier.previous.app [agent]",
                ]
            );
            // One app, under its name, with the same contents; one LaunchAgent, under its label,
            // names it and runs it; the copy an update had set aside under the earlier name is gone.
            assert_eq!(mac.build(APP_NAME).as_deref(), Some("0.3.1"));
            assert_eq!(mac.agent_app(LABEL).as_deref(), Some(step.to.as_path()));
            assert_eq!(mac.launchd.loaded_now(), ["agent"]);
            assert_eq!(mac.left(was), (vec!["agent".to_string()], Some(("agent".to_string(), step.to.clone()))));
            let left: Vec<_> = std::fs::read_dir(&mac.apps).unwrap().map(|e| e.unwrap().file_name()).collect();
            assert_eq!(left, [APP_NAME]);
            // From there, nothing is left to do.
            assert_eq!(plan(&step.to, &mac.homes(), "0.3.1", &NOBODY), Ok(None));
        }
    }

    /// A Mac two names behind whose job already moved one label on, and one with files of both
    /// earlier labels: one move, and one app, one file and one job are left.
    #[test]
    fn the_oldest_name_moves_whatever_earlier_labels_have_a_file() {
        let [newer, oldest] = generations();
        for labels in [&[newer.label][..], &[oldest.label, newer.label][..]] {
            let mac = Mac::new("mixed");
            let from = mac.app(oldest.app, "0.4.0");
            mac.app(newer.previous, "0.3.1");
            mac.app(oldest.previous, "0.3.0");
            for label in labels {
                mac.seed(label, &from);
            }
            let step = plan(&from, &mac.homes(), "0.4.0", &NOBODY).unwrap().unwrap();
            assert_eq!(mac.carry_out(&step), Ok(()), "{labels:?}");
            assert_eq!((mac.launchd.files(), mac.launchd.loaded_now()), (vec!["agent".to_string()], vec!["agent".to_string()]), "{labels:?}");
            assert_eq!(mac.running(), Some(("agent".to_string(), step.to.clone())));
            let left: Vec<_> = std::fs::read_dir(&mac.apps).unwrap().map(|e| e.unwrap().file_name()).collect();
            assert_eq!(left, [APP_NAME], "{labels:?}");
            // Each earlier path that held an app is forgotten once.
            let forgot = |name: &str| mac.launchd.events.borrow().iter().filter(|event| event.starts_with(&format!("lsregister -u {name} "))).count();
            assert_eq!((forgot(oldest.app), forgot(newer.previous), forgot(oldest.previous)), (1, 1, 1));
        }
    }

    #[test]
    fn a_copy_set_aside_under_an_earlier_name_goes_only_when_its_signature_is_ours() {
        for was in generations() {
            let mac = Mac::new("previous");
            let app = mac.app(APP_NAME, "0.3.1");
            let previous = mac.app(was.previous, "0.3.0");
            let forgot = Cell::new(0);
            let forget = |flag: &str, path: &Path| {
                assert_eq!((flag, path), ("-u", previous.as_path()));
                forgot.set(forgot.get() + 1);
            };
            // A folder of that name that does not pass the check stays, with what it holds, and
            // Launch Services is told nothing.
            remove_old_previous(&app, &|path| path != previous, &forget);
            assert_eq!((mac.build(was.previous).as_deref(), forgot.get()), (Some("0.3.0"), 0));
            // One that passes goes, and Launch Services forgets it.
            remove_old_previous(&app, &|path| path == previous, &forget);
            assert_eq!((previous.exists(), forgot.get()), (false, 1));
            // With none there, and with a link of that name, nothing is checked or removed.
            let nothing: &dyn Fn(&Path) -> bool = &|_| panic!("nothing to check");
            remove_old_previous(&app, nothing, &forget);
            std::os::unix::fs::symlink(&app, &previous).unwrap();
            remove_old_previous(&app, nothing, &forget);
            assert!(previous.is_symlink() && app.is_dir());
            assert_eq!(forgot.get(), 1);

            // After a move: the same rule, and the move holds either way.
            std::fs::remove_file(&previous).unwrap();
            std::fs::remove_dir_all(&app).unwrap();
            let from = mac.app(was.app, "0.3.1");
            mac.app(was.previous, "not ours");
            mac.seed(was.label, &from);
            let step = plan(&from, &mac.homes(), "0.3.1", &NOBODY).unwrap().unwrap();
            assert_eq!(mac.carry_out(&step), Ok(()));
            assert_eq!((mac.build(APP_NAME).as_deref(), mac.build(was.previous).as_deref()), (Some("0.3.1"), Some("not ours")));
            assert!(!mac.events(was).iter().any(|event| event.contains("Earlier.previous.app")));
        }
    }

    /// A Mac that had the app under both earlier names: whichever of them the move is about,
    /// the other one goes too once the helper runs from the new place.
    #[test]
    fn an_app_left_under_the_other_earlier_name_goes_with_the_move() {
        for (was, other) in [(generations()[0], generations()[1]), (generations()[1], generations()[0])] {
            // Renamed, and beside an app already under the new name: the same either way.
            for leftover in [false, true] {
                let mac = Mac::new("two-earlier");
                let from = mac.app(was.app, "0.3.1");
                let stale = mac.app(other.app, "0.3.0");
                if leftover {
                    mac.app(APP_NAME, "0.3.1");
                }
                mac.seed(was.label, &from);
                let yes: &dyn Fn(&Path) -> bool = &|_| true;
                let step = plan(&from, &mac.homes(), "0.3.1", &look(yes, &|_| Some("0.3.1".to_string()))).unwrap().unwrap();
                assert_eq!(step.leftover, leftover);
                assert_eq!(mac.carry_out(&step), Ok(()));
                assert_eq!(std::fs::read_dir(&mac.apps).unwrap().count(), 1, "{} beside {}, leftover {leftover}", was.app, other.app);
                assert_eq!(mac.build(APP_NAME).as_deref(), Some("0.3.1"));
                // Launch Services forgets the other one after it is deleted, as the last thing.
                let forgot = format!("lsregister -u {}", mac.short(&stale));
                assert!(mac.launchd.events().last().is_some_and(|event| event.starts_with(&forgot)));
            }

            // One whose signature is not ours stays with what it holds, and so does a link of
            // that name with what it points at. Launch Services is told nothing about either.
            for kind in ["not ours", "link"] {
                let mac = Mac::new("two-earlier-kept");
                let from = mac.app(was.app, "0.3.1");
                let elsewhere = mac.dir.join("elsewhere.app");
                if kind == "link" {
                    std::fs::create_dir_all(&elsewhere).unwrap();
                    std::os::unix::fs::symlink(&elsewhere, mac.apps.join(other.app)).unwrap();
                } else {
                    mac.app(other.app, "not ours");
                }
                mac.seed(was.label, &from);
                let step = plan(&from, &mac.homes(), "0.3.1", &NOBODY).unwrap().unwrap();
                assert_eq!(mac.carry_out(&step), Ok(()));
                assert!(std::fs::symlink_metadata(mac.apps.join(other.app)).is_ok(), "{kind}");
                assert!(kind != "link" || elsewhere.is_dir());
                assert!(kind != "not ours" || mac.build(other.app).as_deref() == Some("not ours"));
                assert!(!mac.launchd.events().iter().any(|event| event.contains(other.app)), "{kind}");
            }

            // When the helper does not come up under the new name, everything goes back and
            // the other earlier app is still there.
            let mut mac = Mac::new("two-earlier-back");
            let from = mac.app(was.app, "0.3.1");
            mac.app(other.app, "0.3.0");
            mac.seed(was.label, &from);
            let earlier_place = program_in(&from);
            mac.launchd.comes_up = Box::new(move |_, program| program == earlier_place);
            let step = plan(&from, &mac.homes(), "0.3.1", &NOBODY).unwrap().unwrap();
            assert!(mac.carry_out(&step).is_err());
            assert_eq!((mac.build(was.app).as_deref(), mac.build(other.app).as_deref()), (Some("0.3.1"), Some("0.3.0")));
        }
    }

    #[test]
    fn an_app_whose_job_has_the_new_label_moves_and_the_launch_agent_follows() {
        for was in generations() {
            let mac = Mac::new("follows");
            let from = mac.app(was.app, "0.3.1");
            mac.seed(LABEL, &from);
            let step = plan(&from, &mac.homes(), "0.3.1", &NOBODY).unwrap().unwrap();
            assert_eq!(mac.carry_out(&step), Ok(()));
            // The job is booted out, its file written for the new path, and loaded again.
            assert_eq!(mac.events(was), ["lsregister -u Earlier.app [agent]", "lsregister -f New.app [agent]", "boot out agent [agent]", "bootstrap agent [agent]"]);
            assert_eq!(mac.agent_app(LABEL).as_deref(), Some(step.to.as_path()));
            assert_eq!(mac.running(), Some(("agent".to_string(), step.to.clone())));
        }
    }

    #[test]
    fn an_app_that_does_not_start_under_its_new_name_goes_back() {
        for was in generations() {
            let mut mac = Mac::new("back");
            let from = mac.app(was.app, "0.3.1");
            mac.app(was.previous, "0.3.0");
            mac.seed(was.label, &from);
            let before = std::fs::read_to_string(mac.launchd.dir.join(format!("{}.plist", was.label))).unwrap();
            let step = plan(&from, &mac.homes(), "0.3.1", &NOBODY).unwrap().unwrap();

            let earlier_place = program_in(&from);
            mac.launchd.comes_up = Box::new(move |_, program| program == earlier_place);
            assert_eq!(mac.carry_out(&step).unwrap_err(), "it did not start under its new name");
            // Started at the new place under the new label, then again at the earlier one, where
            // everything is as it was. Launch Services is told about the way back too: the new
            // path is forgotten and the earlier one recorded again, before the earlier job is
            // loaded again. The earlier label's file was there throughout.
            assert_eq!(
                mac.events(was),
                [
                    "lsregister -u Earlier.app [earlier]",
                    "lsregister -f New.app [earlier]",
                    "boot out earlier [agent earlier]",
                    "bootstrap agent [agent earlier]",
                    "lsregister -u New.app [agent earlier]",
                    "lsregister -f Earlier.app [agent earlier]",
                    "boot out agent [agent earlier]",
                    "bootstrap earlier [earlier]",
                ]
            );
            assert_eq!(mac.build(was.app).as_deref(), Some("0.3.1"));
            assert_eq!(mac.build(was.previous).as_deref(), Some("0.3.0"));
            assert!(!step.to.exists());
            assert_eq!(std::fs::read_to_string(mac.launchd.dir.join(format!("{}.plist", was.label))).unwrap(), before);
            assert_eq!(mac.launchd.loaded_now(), [fake::short(was.label)]);
            assert_eq!(mac.left(was), (vec!["earlier".to_string()], Some(("earlier".to_string(), from.clone()))));

            // A LaunchAgent that could not be pointed at the new place: the same.
            let refused = Effects {
                launch_services: &|_, _| {},
                signature_ok: &|_| true,
                start_at: &|app| app == from,
                settled: &|| panic!("nothing was started"),
                old_gone: &|| true,
                running_from: &|| panic!("nothing was started"),
                exit_wait: Duration::ZERO,
                wait: Duration::ZERO,
                poll: Duration::from_millis(1),
            };
            assert_eq!(carry_out(&step, &refused).unwrap_err(), "its background job could not be pointed at the new name");
            assert!(from.is_dir() && !step.to.exists());

            // A bundle that can't be renamed: nothing is started at all, and Launch Services is
            // told nothing.
            std::fs::remove_dir_all(&from).unwrap();
            let untouched = Effects { launch_services: &|_, _| panic!("nothing was renamed"), start_at: &|_| panic!("nothing to start"), ..refused };
            assert!(carry_out(&step, &untouched).unwrap_err().starts_with("it could not be renamed"));
        }
    }

    #[test]
    fn only_a_real_folder_in_an_applications_folder_is_moved() {
        for was in generations() {
            let mac = Mac::new("guards");
            let from = mac.app(was.app, "0.3.1");
            // Somewhere else: a download folder, a translocated copy.
            let elsewhere = mac.dir.join("Downloads");
            std::fs::create_dir_all(elsewhere.join(was.app)).unwrap();
            assert_eq!(plan(&elsewhere.join(was.app), &mac.homes(), "0.3.1", &NOBODY).unwrap_err(), "it is not in an Applications folder");
            // A folder inside an Applications folder is not that Applications folder.
            std::fs::create_dir_all(mac.apps.join("Tools").join(was.app)).unwrap();
            assert!(plan(&mac.apps.join("Tools").join(was.app), &mac.homes(), "0.3.1", &NOBODY).is_err());
            // A link to the app.
            std::fs::rename(&from, mac.dir.join("real.app")).unwrap();
            std::os::unix::fs::symlink(mac.dir.join("real.app"), &from).unwrap();
            assert_eq!(plan(&from, &mac.homes(), "0.3.1", &NOBODY).unwrap_err(), "it is a link, not a folder");
            // An app of another name is none of this module's business.
            for other in [APP_NAME, was.previous, "Other.app"] {
                assert_eq!(plan(&mac.apps.join(other), &mac.homes(), "0.3.1", &NOBODY), Ok(None), "{other}");
            }
            assert!(!mac.apps.join(APP_NAME).exists());
        }
    }

    #[test]
    fn an_app_already_under_the_new_name_decides_which_one_stays() {
        for was in generations() {
            let mut mac = Mac::new("both");
            let from = mac.app(was.app, "0.3.1");
            let to = mac.app(APP_NAME, "0.3.2");
            mac.seed(was.label, &from);
            let yes: &dyn Fn(&Path) -> bool = &|_| true;
            let no: &dyn Fn(&Path) -> bool = &|_| false;
            let at = |v: &'static str| move |_: &Path| Some(v.to_string());

            // In the way: an older one, one whose signature is not accepted, one without a
            // version, a link, a file. Nothing is planned and nothing changes.
            let blocked = format!("something else is at {}", to.display());
            assert_eq!(plan(&from, &mac.homes(), "0.3.1", &look(yes, &at("0.3.0"))).unwrap_err(), blocked);
            assert_eq!(plan(&from, &mac.homes(), "0.3.1", &look(no, &at("0.3.2"))).unwrap_err(), blocked);
            assert_eq!(plan(&from, &mac.homes(), "0.3.1", &look(yes, &|_| None)).unwrap_err(), blocked);
            std::fs::rename(&to, mac.dir.join("aside.app")).unwrap();
            for kind in ["link", "file"] {
                if kind == "link" {
                    std::os::unix::fs::symlink(mac.dir.join("aside.app"), &to).unwrap();
                } else {
                    std::fs::write(&to, "").unwrap();
                }
                assert_eq!(plan(&from, &mac.homes(), "0.3.1", &look(yes, &at("0.3.2"))).unwrap_err(), blocked, "{kind}");
                std::fs::remove_file(&to).unwrap();
            }
            std::fs::rename(mac.dir.join("aside.app"), &to).unwrap();
            assert_eq!((mac.build(was.app).as_deref(), mac.build(APP_NAME).as_deref()), (Some("0.3.1"), Some("0.3.2")));

            // Whole, ours, and the same version or a newer one: the earlier name is the leftover.
            for version in ["0.3.1", "0.3.2"] {
                let step = plan(&from, &mac.homes(), "0.3.1", &look(yes, &at(version))).unwrap().unwrap();
                assert_eq!(step, Step { from: from.clone(), to: to.clone(), leftover: true }, "{version}");
            }
            let step = Step { from: from.clone(), to: to.clone(), leftover: true };

            // The new one does not start: the earlier one is started again and both stay.
            let earlier_place = program_in(&from);
            mac.launchd.comes_up = Box::new(move |_, program| program == earlier_place);
            assert!(mac.carry_out(&step).is_err());
            assert_eq!(mac.agent_app(was.label).as_deref(), Some(from.as_path()));
            assert_eq!(mac.left(was), (vec!["earlier".to_string()], Some(("earlier".to_string(), from.clone()))));
            // The app under the new name is still there, so it is not forgotten.
            assert_eq!(
                mac.events(was),
                [
                    "lsregister -u Earlier.app [earlier]",
                    "lsregister -f New.app [earlier]",
                    "boot out earlier [agent earlier]",
                    "bootstrap agent [agent earlier]",
                    "lsregister -f Earlier.app [agent earlier]",
                    "boot out agent [agent earlier]",
                    "bootstrap earlier [earlier]",
                ]
            );
            assert_eq!((mac.build(was.app).as_deref(), mac.build(APP_NAME).as_deref()), (Some("0.3.1"), Some("0.3.2")));

            // It starts: the LaunchAgent names it, under the new label, and the earlier one is
            // removed. Nothing was renamed.
            mac.launchd.comes_up = Box::new(|_, _| true);
            assert_eq!(mac.carry_out(&step), Ok(()));
            assert_eq!(mac.agent_app(LABEL).as_deref(), Some(to.as_path()));
            assert_eq!(mac.left(was), (vec!["agent".to_string()], Some(("agent".to_string(), to.clone()))));
            assert_eq!((mac.build(was.app), mac.build(APP_NAME).as_deref()), (None, Some("0.3.2")));
            // The earlier path is forgotten again once its folder is deleted.
            assert_eq!(
                mac.events(was),
                [
                    "lsregister -u Earlier.app [earlier]",
                    "lsregister -f New.app [earlier]",
                    "boot out earlier [agent earlier]",
                    "bootstrap agent [agent earlier]",
                    "lsregister -u Earlier.app [agent]",
                ]
            );
        }
    }

    #[test]
    fn a_move_does_not_depend_on_lsregister() {
        assert!(Path::new(LSREGISTER).is_absolute() && LSREGISTER.ends_with("/Support/lsregister"));
        let was = generations()[0];
        let mac = Mac::new("lsregister");
        // A tool that is not there, one that is no program, and one that fails.
        let no_program = mac.dir.join("lsregister");
        std::fs::write(&no_program, "").unwrap();
        for tool in [mac.dir.join("missing"), no_program, PathBuf::from("/usr/bin/false")] {
            let from = mac.app(was.app, "0.3.1");
            let step = plan(&from, &mac.homes(), "0.3.1", &NOBODY).unwrap().unwrap();
            let asked = Cell::new(0);
            let fx = Effects {
                launch_services: &|flag, app| {
                    asked.set(asked.get() + 1);
                    tell_launch_services(&tool, flag, app);
                },
                signature_ok: &|_| true,
                start_at: &|_| true,
                settled: &|| {},
                old_gone: &|| true,
                running_from: &|| Some(step.to.clone()),
                exit_wait: Duration::ZERO,
                wait: Duration::ZERO,
                poll: Duration::from_millis(1),
            };
            assert_eq!(carry_out(&step, &fx), Ok(()), "{}", tool.display());
            assert_eq!(asked.get(), 2);
            assert!(step.to.is_dir() && !from.exists());
            std::fs::remove_dir_all(&step.to).unwrap();
        }
    }

    #[test]
    fn a_tool_is_run_by_its_full_path_for_a_limited_time() {
        let sh = Path::new("/bin/sh");
        let run = |script: &str, limit: u64| bounded(sh, &["-c".into(), script.into()], Duration::from_millis(limit));
        assert_eq!(run("exit 0", 5000), Ok(()));
        assert!(run("exit 3", 5000).unwrap_err().starts_with("failed"));
        let began = Instant::now();
        assert_eq!(run("sleep 30", 100).unwrap_err(), "took too long");
        assert!(began.elapsed() < Duration::from_secs(10));
        // Its arguments reach it as they are, spaces and all.
        let app = format!("/Applications/{APP_NAME}");
        let script = format!("[ \"$1 $2\" = \"-u {app}\" ]");
        assert_eq!(run(&script, 5000).map_err(|_| ()), Err(()));
        let args = ["-c".into(), script.into(), "sh".into(), "-u".into(), app.into()];
        assert_eq!(bounded(sh, &args, Duration::from_secs(5)), Ok(()));
        // A bare name is never looked up.
        assert_eq!(bounded(Path::new("bin/sh"), &[], Duration::from_secs(5)).unwrap_err(), "is not named by a full path");
        assert!(bounded(Path::new("/nowhere/lsregister"), &[], Duration::from_secs(5)).unwrap_err().starts_with("could not be run"));
    }

    #[test]
    fn the_move_waits_for_the_helper_that_ran_before_to_exit() {
        let mac = Mac::new("waits");
        let from = mac.app(generations()[0].app, "0.3.1");
        let step = plan(&from, &mac.homes(), "0.3.1", &NOBODY).unwrap().unwrap();
        // The helper reports in only after the old one took a while to go: the time it has
        // to report in starts then.
        let polls = Cell::new(0);
        let fx = Effects {
            launch_services: &|_, _| {},
            signature_ok: &|_| true,
            start_at: &|_| true,
            settled: &|| {},
            old_gone: &|| {
                polls.set(polls.get() + 1);
                polls.get() > 20
            },
            running_from: &|| (polls.get() > 20).then(|| step.to.clone()),
            exit_wait: Duration::from_secs(5),
            wait: Duration::from_millis(1),
            poll: Duration::from_millis(2),
        };
        assert_eq!(carry_out(&step, &fx), Ok(()));
        assert!(step.to.is_dir());
    }

    #[test]
    fn an_installer_run_holds_the_move_off() {
        let mac = Mac::new("busy");
        let lock = mac.dir.join("setup.lock");
        let alive = |pid: u64| pid == 4242;
        assert!(!installer_busy(&mac.dir, 10_000, alive));
        std::fs::create_dir_all(&lock).unwrap();
        // Just taken, its owner not yet written.
        assert!(installer_busy(&mac.dir, 10_000, alive));
        std::fs::write(lock.join("owner"), "4242 9000\n").unwrap();
        assert!(installer_busy(&mac.dir, 10_000, alive));
        // Left over: older than any install takes, a process that is gone, or no owner at all.
        assert!(!installer_busy(&mac.dir, 9000 + 1801, alive));
        std::fs::write(lock.join("owner"), "77 9000\n").unwrap();
        assert!(!installer_busy(&mac.dir, 10_000, alive));
        std::fs::write(lock.join("owner"), "not an owner\n").unwrap();
        assert!(!installer_busy(&mac.dir, 10_000, alive));
    }

    #[test]
    fn a_program_names_its_app() {
        let app = format!("/Applications/{APP_NAME}");
        assert_eq!(app_of(Path::new(&format!("{app}/Contents/MacOS/rex-duo-helper"))), Some(PathBuf::from(&app)));
        assert_eq!(app_of(Path::new(&format!("{app}/Contents/MacOS/rex-duo-notify"))), None);
        assert_eq!(app_of(Path::new("/home/u/.local/bin/rex-duo-helper")), None);
    }
}
