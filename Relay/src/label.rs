//! The label of the Mac's LaunchAgent, `dev.abrahamgonzalez.rexduo.beacon`, and the move to
//! it from the earlier label, `dev.abrahamgonzalez.rexduo.helper`.
//!
//! macOS lists a background job in System Settings → Login Items under the app it found when
//! the job's file first appeared, and keeps that for as long as the file exists. A file under
//! a new label that names the program in `Rex DUO Beacon.app` gets an entry of that name, and
//! the entry of the earlier file goes about a minute after that file is deleted. So the label
//! changes once, and at every moment of the change one of the two files exists.
//!
//! The move, wherever the earlier label's file is found (`Agents::migrate`):
//!
//! 1. the new label's file is written for the program's current path;
//! 2. the earlier job is booted out and the new one loaded;
//! 3. the helper reports in status.json that it runs under the new label;
//! 4. the earlier label's file is deleted.
//!
//! A helper that does not report in is booted out, its file removed, and the earlier job
//! loaded again from its file, which was never touched.
//!
//! A helper that starts while both files exist (a move that was cut short) settles that
//! (`Agents::at_start`). Under the new label it boots the earlier job out and deletes the
//! earlier file. Under the earlier label it has the move go on from step 2, with the new
//! file as it is (`Agents::resume`), and does not serve when the new job is loaded already.
//! The lock on helper.lock in the state folder stays the last guard: of two helpers that
//! launchd starts at a login, one gets it and the other ends.
//!
//! A job cannot boot itself out and live, so the service has the move done by the separate
//! launchd job that also finishes an update (src/rename.rs). `install` and opening the app
//! are not the service and do the steps themselves.
//!
//! A helper knows its label from `REXDUO_LABEL`, which every file written here sets for its
//! job. A file written by a version from before the new label sets no such variable; there
//! launchd's own `XPC_SERVICE_NAME`, the label of the job a process belongs to, tells.
//!
//! Everything here is tested with a stand-in for launchd.

use crate::service::{point_agent, program_of, EARLIER_LABEL, LABEL};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// A file in the state folder that says the last move did not hold. The helper that the way
/// back started leaves the move alone, and removes the file, so the next start tries again.
const PUT_OFF: &str = "move.failed";
/// How long that file counts: the helper it is meant for starts within seconds.
const PUT_OFF_FOR: Duration = Duration::from_secs(600);

/// launchd, as the helper uses it for its own jobs.
pub trait Launchd {
    fn loaded(&self, label: &str) -> bool;
    /// Boots a job out and waits until it is gone. Nothing when it is not loaded.
    fn boot_out(&self, label: &str);
    /// Loads a job from its file, which starts it. False when launchd refused.
    fn bootstrap(&self, label: &str, file: &Path) -> bool;
    /// Starts a loaded job that is not running. With `again`, one that runs is stopped first.
    fn kickstart(&self, label: &str, again: bool) -> bool;
}

/// How the helper that was started is waited for.
pub struct Confirm<'a> {
    /// True once the helper reports that it runs this program under the new label.
    pub runs: &'a dyn Fn(&Path) -> bool,
    pub wait: Duration,
    pub poll: Duration,
}

impl Confirm<'_> {
    fn reached(&self, program: &Path) -> bool {
        let began = Instant::now();
        loop {
            if (self.runs)(program) {
                return true;
            }
            if began.elapsed() >= self.wait {
                return false;
            }
            std::thread::sleep(self.poll);
        }
    }
}

/// What a helper that starts does about the two labels.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AtStart {
    /// Nothing: it is not a launchd job of ours, or only its own label's file exists.
    Serve,
    /// It runs under the new label and the earlier label's file is still there: the earlier
    /// job is booted out and its file deleted, by this process, before it serves.
    DropEarlier,
    /// It runs under the earlier label while the new label's job is loaded: it does not
    /// serve, and has the earlier job booted out and its file deleted (`Agents::resume`).
    StepAside,
    /// It runs under the earlier label and no job of the new one is loaded: it serves, and
    /// has the move done: all of it, or from its second step when the new file is there.
    Migrate,
}

/// The label a process runs under: what its job's file set (`ours`), else the label of the
/// launchd job it belongs to (`launchd`). None for a process that is no job of the helper's.
pub fn own(ours: Option<&str>, launchd: Option<&str>) -> Option<&'static str> {
    let known = |name: &str| [LABEL, EARLIER_LABEL].into_iter().find(|label| *label == name);
    ours.and_then(known).or_else(|| launchd.and_then(known))
}

/// The LaunchAgent files in one folder (`~/Library/LaunchAgents`) and their jobs.
pub struct Agents<'a> {
    pub dir: PathBuf,
    pub launchd: &'a dyn Launchd,
}

impl Agents<'_> {
    pub fn file(&self, label: &str) -> PathBuf {
        self.dir.join(format!("{label}.plist"))
    }

    pub fn has(&self, label: &str) -> bool {
        self.file(label).exists()
    }

    /// The label to restart, stop, check and print: the new one, or the earlier one while
    /// only its file exists.
    pub fn in_use(&self) -> &'static str {
        if !self.has(LABEL) && self.has(EARLIER_LABEL) {
            EARLIER_LABEL
        } else {
            LABEL
        }
    }

    fn remove(&self, label: &str) {
        let _ = std::fs::remove_file(self.file(label));
    }

    /// Loads a label's job from its file. One that is loaded already is started if it stopped.
    fn load(&self, label: &str) -> bool {
        if self.launchd.loaded(label) {
            self.launchd.kickstart(label, false)
        } else {
            self.launchd.bootstrap(label, &self.file(label))
        }
    }

    /// Writes a label's file for `program`. A job that was loaded from other contents is
    /// booted out, because launchd keeps what a job was loaded with. True when the file changed.
    fn write(&self, label: &str, program: &Path) -> Result<bool, String> {
        let unload = || self.launchd.boot_out(label);
        let changed = point_agent(&self.file(label), label, program, &unload)?;
        if changed {
            unload();
        }
        Ok(changed)
    }

    /// Steps 1 and 2 of the move: the new label's file is written while the earlier one still
    /// exists, then the earlier job is booted out and the new one loaded. False when the file
    /// could not be written or launchd refused the job.
    pub fn begin(&self, program: &Path) -> bool {
        if self.write(LABEL, program).is_err() {
            return false;
        }
        self.launchd.boot_out(EARLIER_LABEL);
        self.load(LABEL)
    }

    /// Step 4, once the helper runs under the new label: the earlier label's file goes.
    pub fn settle(&self) {
        self.remove(EARLIER_LABEL);
    }

    /// The way back: the new job is booted out, its file removed, and the earlier job loaded
    /// again from its file. Without that file the new one stays, so a file is always there.
    pub fn back_out(&self) -> bool {
        if !self.has(EARLIER_LABEL) {
            return self.load(LABEL);
        }
        self.launchd.boot_out(LABEL);
        self.remove(LABEL);
        self.load(EARLIER_LABEL)
    }

    /// The whole move, for a caller that is not the job it boots out.
    pub fn migrate(&self, program: &Path, confirm: &Confirm) -> Result<(), String> {
        if self.begin(program) && confirm.reached(program) {
            self.settle();
            return Ok(());
        }
        self.back_out();
        Err(format!("it did not start under the label {LABEL}"))
    }

    /// The program a label's file names.
    pub fn program(&self, label: &str) -> Option<PathBuf> {
        program_of(&std::fs::read_to_string(self.file(label)).ok()?)
    }

    /// The move from its second step, where the new label's file is there already: the file
    /// stays as it is, and the helper it names is the one waited for.
    pub fn resume(&self, confirm: &Confirm) -> Result<(), String> {
        let Some(program) = self.program(LABEL) else {
            return Err(format!("the file of the label {LABEL} names no program"));
        };
        self.launchd.boot_out(EARLIER_LABEL);
        if self.load(LABEL) && confirm.reached(&program) {
            self.settle();
            return Ok(());
        }
        self.back_out();
        Err(format!("it did not start under the label {LABEL}"))
    }

    /// Restarts the background job as `program`, under the label in use. While its file
    /// names that program the job is restarted as it is. When it names another, the file is
    /// written for this one and the job loaded again. A job of the earlier label beside a
    /// file of the new one is booted out first: one helper runs.
    pub fn restart_into(&self, program: &Path) -> bool {
        let label = self.in_use();
        if label == LABEL && self.has(EARLIER_LABEL) {
            self.launchd.boot_out(EARLIER_LABEL);
        }
        let file = self.file(label);
        match point_agent(&file, label, program, &|| self.launchd.boot_out(label)) {
            Err(_) => false,
            Ok(false) if self.launchd.loaded(label) => self.launchd.kickstart(label, true),
            Ok(_) => {
                self.launchd.boot_out(label);
                self.launchd.bootstrap(label, &file)
            }
        }
    }

    /// What `install` and opening the app do: the job runs `program` now and at every login.
    /// A new install writes and loads the new label alone. With the earlier label's file
    /// there, the move is done first (`may_move` is false while an update holds its lock);
    /// a move that did not hold leaves the job under the earlier label, and its reason is
    /// returned. A job that already runs is restarted when `again` says it should be.
    pub fn start(&self, program: &Path, may_move: bool, again: &dyn Fn() -> bool, confirm: &Confirm) -> Result<Option<String>, String> {
        let mut kept = None;
        if may_move && self.has(EARLIER_LABEL) {
            let fresh = !self.launchd.loaded(LABEL);
            match self.migrate(program, confirm) {
                // Loaded just now, from this program: nothing is left to restart.
                Ok(()) if fresh => return Ok(None),
                Ok(()) => {}
                Err(why) => kept = Some(why),
            }
        }
        let label = self.in_use();
        if self.write(label, program)? || !self.launchd.loaded(label) {
            if !self.launchd.bootstrap(label, &self.file(label)) {
                return Err("macOS refused to start the background job (launchctl bootstrap failed)".into());
            }
        } else if again() {
            self.launchd.kickstart(label, true);
        }
        Ok(kept)
    }

    /// What `uninstall` does: the jobs of both labels are booted out and their files deleted.
    pub fn stop_all(&self) {
        for label in [LABEL, EARLIER_LABEL] {
            self.launchd.boot_out(label);
            self.remove(label);
        }
    }

    /// What a helper that starts under `own` does. `moving` is true while an update or a
    /// move holds its lock: whoever holds it deletes the earlier file itself, or needs it to
    /// go back to.
    pub fn at_start(&self, own: Option<&str>, moving: bool) -> AtStart {
        if own == Some(LABEL) && self.has(EARLIER_LABEL) && !moving {
            AtStart::DropEarlier
        } else if own == Some(EARLIER_LABEL) && self.has(LABEL) && self.launchd.loaded(LABEL) {
            AtStart::StepAside
        } else if own == Some(EARLIER_LABEL) {
            AtStart::Migrate
        } else {
            AtStart::Serve
        }
    }

    /// `AtStart::DropEarlier`, done.
    pub fn drop_earlier(&self) {
        self.launchd.boot_out(EARLIER_LABEL);
        self.remove(EARLIER_LABEL);
    }
}

/// Notes that a move did not hold, for the helper that the way back started.
pub fn put_off(state_dir: &Path) {
    let _ = std::fs::write(state_dir.join(PUT_OFF), "");
}

/// True, once, for the helper that starts right after a move that did not hold.
pub fn was_put_off(state_dir: &Path) -> bool {
    let path = state_dir.join(PUT_OFF);
    let recent = std::fs::metadata(&path).and_then(|m| m.modified()).ok().and_then(|t| t.elapsed().ok()).is_some_and(|age| age < PUT_OFF_FOR);
    std::fs::remove_file(&path).is_ok() && recent
}

/// A stand-in for launchd, for the tests here and in src/rename.rs.
#[cfg(test)]
pub mod fake {
    use super::*;
    use std::cell::RefCell;
    use std::collections::BTreeSet;

    /// A label as the events name it: its last part.
    pub fn short(label: &str) -> &str {
        label.rsplit('.').next().unwrap_or(label)
    }

    /// Says whether the program a label's file names starts.
    pub type ComesUp = dyn Fn(&str, &Path) -> bool;

    /// Jobs are loaded and booted out as launchd would, and a loaded job runs the program
    /// its file named when it was loaded, unless `comes_up` says that program does not
    /// start. Every call is an event, with the label files that existed at that moment.
    pub struct FakeLaunchd {
        pub dir: PathBuf,
        pub loaded: RefCell<BTreeSet<String>>,
        /// The label and program of the helper that runs, if one does.
        pub running: RefCell<Option<(String, PathBuf)>>,
        pub comes_up: Box<ComesUp>,
        /// Labels launchd refuses to load.
        pub refused: RefCell<BTreeSet<String>>,
        pub events: RefCell<Vec<String>>,
    }

    impl FakeLaunchd {
        pub fn new(dir: &Path) -> FakeLaunchd {
            FakeLaunchd {
                dir: dir.to_path_buf(),
                loaded: RefCell::default(),
                running: RefCell::default(),
                comes_up: Box::new(|_, _| true),
                refused: RefCell::default(),
                events: RefCell::default(),
            }
        }

        /// The label files that exist, by their short names.
        pub fn files(&self) -> Vec<String> {
            [LABEL, EARLIER_LABEL].into_iter().filter(|l| self.dir.join(format!("{l}.plist")).exists()).map(|l| short(l).to_string()).collect()
        }

        pub fn loaded_now(&self) -> Vec<String> {
            self.loaded.borrow().iter().map(|l| short(l).to_string()).collect()
        }

        pub fn note(&self, event: &str) {
            self.events.borrow_mut().push(format!("{event} [{}]", self.files().join(" ")));
        }

        /// The events since the last call.
        pub fn events(&self) -> Vec<String> {
            self.events.take()
        }

        /// The program a label's file names.
        pub fn program(&self, label: &str) -> Option<PathBuf> {
            program_of(&std::fs::read_to_string(self.dir.join(format!("{label}.plist"))).ok()?)
        }

        /// A job that is loaded and runs, as an install before left it.
        pub fn seed(&self, label: &str, program: &Path) {
            crate::service::write_agent(&self.dir.join(format!("{label}.plist")), label, program).unwrap();
            self.loaded.borrow_mut().insert(label.into());
            *self.running.borrow_mut() = Some((label.into(), program.to_path_buf()));
        }

        /// True when the helper runs `program` under the new label.
        pub fn runs_new(&self, program: &Path) -> bool {
            self.running.borrow().as_ref().is_some_and(|(label, runs)| label == LABEL && runs == program)
        }

        fn spawn(&self, label: &str) {
            // One helper at a time: a second one finds the lock held and ends.
            if self.running.borrow().is_some() {
                return;
            }
            if let Some(program) = self.program(label).filter(|p| (self.comes_up)(label, p)) {
                *self.running.borrow_mut() = Some((label.into(), program));
            }
        }
    }

    impl Launchd for FakeLaunchd {
        fn loaded(&self, label: &str) -> bool {
            self.loaded.borrow().contains(label)
        }
        fn boot_out(&self, label: &str) {
            if self.loaded.borrow_mut().remove(label) {
                self.note(&format!("boot out {}", short(label)));
                self.running.borrow_mut().take_if(|(runs, _)| runs == label);
            }
        }
        fn bootstrap(&self, label: &str, file: &Path) -> bool {
            self.note(&format!("bootstrap {}", short(label)));
            if self.refused.borrow().contains(label) || !file.exists() || self.loaded(label) {
                return false;
            }
            self.loaded.borrow_mut().insert(label.into());
            self.spawn(label);
            true
        }
        fn kickstart(&self, label: &str, again: bool) -> bool {
            self.note(&format!("kickstart{} {}", if again { " -k" } else { "" }, short(label)));
            if !self.loaded(label) {
                return false;
            }
            if again {
                self.running.borrow_mut().take_if(|(runs, _)| runs == label);
            }
            self.spawn(label);
            true
        }
    }
}

#[cfg(test)]
mod tests {
    use super::fake::FakeLaunchd;
    use super::*;

    const NEW: &str = "/Applications/Rex DUO Beacon.app/Contents/MacOS/rex-duo-helper";
    const OLD: &str = "/Applications/Rex DUO Helper.app/Contents/MacOS/rex-duo-helper";

    fn temp(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("label-{tag}-{}-{}", std::process::id(), crate::util::now()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn confirm<'a>(runs: &'a dyn Fn(&Path) -> bool) -> Confirm<'a> {
        Confirm { runs, wait: Duration::from_millis(40), poll: Duration::from_millis(5) }
    }

    #[test]
    fn the_move_writes_the_new_file_swaps_the_jobs_confirms_and_then_deletes_the_earlier_file() {
        let dir = temp("order");
        let launchd = FakeLaunchd::new(&dir);
        let agents = Agents { dir: dir.clone(), launchd: &launchd };
        launchd.seed(EARLIER_LABEL, Path::new(NEW));
        let earlier_before = std::fs::read_to_string(agents.file(EARLIER_LABEL)).unwrap();

        // The helper is asked for only after the jobs were swapped, and the earlier label's
        // file is still there, as it was, each time.
        let asked = std::cell::Cell::new(0);
        let runs = |program: &Path| {
            asked.set(asked.get() + 1);
            assert_eq!(launchd.files(), ["beacon", "helper"]);
            assert_eq!(std::fs::read_to_string(agents.file(EARLIER_LABEL)).unwrap(), earlier_before);
            assert_eq!(launchd.loaded_now(), ["beacon"]);
            asked.get() > 2 && launchd.runs_new(program)
        };
        assert_eq!(agents.migrate(Path::new(NEW), &confirm(&runs)), Ok(()));
        // Both files exist when the earlier job is booted out and when the new one is loaded.
        assert_eq!(launchd.events(), ["boot out helper [beacon helper]", "bootstrap beacon [beacon helper]"]);
        assert_eq!(asked.get(), 3);
        assert_eq!((launchd.files(), launchd.loaded_now()), (vec!["beacon".to_string()], vec!["beacon".to_string()]));
        assert_eq!(launchd.program(LABEL).as_deref(), Some(Path::new(NEW)));
        assert_eq!(agents.in_use(), LABEL);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_new_job_that_does_not_come_up_restores_the_earlier_job_and_removes_the_new_file() {
        let dir = temp("back");
        let mut launchd = FakeLaunchd::new(&dir);
        launchd.comes_up = Box::new(|label, _| label == EARLIER_LABEL);
        let agents = Agents { dir: dir.clone(), launchd: &launchd };
        launchd.seed(EARLIER_LABEL, Path::new(OLD));
        let earlier_before = std::fs::read_to_string(agents.file(EARLIER_LABEL)).unwrap();

        let runs = |program: &Path| launchd.runs_new(program);
        assert_eq!(agents.migrate(Path::new(OLD), &confirm(&runs)).unwrap_err(), format!("it did not start under the label {LABEL}"));
        assert_eq!(
            launchd.events(),
            ["boot out helper [beacon helper]", "bootstrap beacon [beacon helper]", "boot out beacon [beacon helper]", "bootstrap helper [helper]"]
        );
        // As before: the earlier label's file, untouched, its job loaded, the helper running.
        assert_eq!((launchd.files(), launchd.loaded_now()), (vec!["helper".to_string()], vec!["helper".to_string()]));
        assert_eq!(std::fs::read_to_string(agents.file(EARLIER_LABEL)).unwrap(), earlier_before);
        assert_eq!(*launchd.running.borrow(), Some((EARLIER_LABEL.to_string(), PathBuf::from(OLD))));
        assert_eq!(agents.in_use(), EARLIER_LABEL);

        // A job launchd refuses to load: the same.
        launchd.refused.borrow_mut().insert(LABEL.into());
        assert!(agents.migrate(Path::new(OLD), &confirm(&|_| panic!("nothing was loaded"))).is_err());
        assert_eq!((launchd.files(), launchd.loaded_now()), (vec!["helper".to_string()], vec!["helper".to_string()]));
        // A file that can't be written: the earlier job is never booted out.
        launchd.events();
        std::fs::create_dir_all(agents.file(LABEL)).unwrap();
        assert!(!agents.begin(Path::new(OLD)));
        assert!(launchd.events().is_empty() && launchd.loaded(EARLIER_LABEL));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn the_way_back_never_leaves_the_mac_without_a_file() {
        let dir = temp("file");
        let launchd = FakeLaunchd::new(&dir);
        let agents = Agents { dir: dir.clone(), launchd: &launchd };
        launchd.seed(EARLIER_LABEL, Path::new(NEW));
        assert!(agents.begin(Path::new(NEW)));
        // The earlier file went meanwhile: the new one stays, loaded.
        std::fs::remove_file(agents.file(EARLIER_LABEL)).unwrap();
        assert!(agents.back_out());
        assert_eq!((launchd.files(), launchd.loaded_now()), (vec!["beacon".to_string()], vec!["beacon".to_string()]));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_new_install_touches_only_the_new_label() {
        let dir = temp("install");
        // The folder of the files is made when it is not there.
        let launchd = FakeLaunchd::new(&dir.join("LaunchAgents"));
        let agents = Agents { dir: dir.join("LaunchAgents"), launchd: &launchd };
        let nobody = confirm(&|_| panic!("nothing to move"));
        assert_eq!(agents.start(Path::new(NEW), true, &|| false, &nobody), Ok(None));
        assert_eq!(launchd.events(), ["bootstrap beacon [beacon]"]);
        assert_eq!((launchd.files(), launchd.loaded_now()), (vec!["beacon".to_string()], vec!["beacon".to_string()]));
        assert_eq!(std::fs::read_dir(&agents.dir).unwrap().count(), 1);
        let text = std::fs::read_to_string(agents.file(LABEL)).unwrap();
        assert!(text.contains("<key>Label</key><string>dev.abrahamgonzalez.rexduo.beacon</string>"));
        // Again, with the job loaded: left alone, or restarted when asked.
        assert_eq!(agents.start(Path::new(NEW), true, &|| false, &nobody), Ok(None));
        assert!(launchd.events().is_empty());
        assert_eq!(agents.start(Path::new(NEW), true, &|| true, &nobody), Ok(None));
        assert_eq!(launchd.events(), ["kickstart -k beacon [beacon]"]);
        // From another program: the job is loaded again, under the same label.
        assert_eq!(agents.start(Path::new(OLD), true, &|| false, &nobody), Ok(None));
        assert_eq!(launchd.events(), ["boot out beacon [beacon]", "bootstrap beacon [beacon]"]);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn an_install_over_the_earlier_label_moves_it_with_one_restart() {
        let dir = temp("over");
        let launchd = FakeLaunchd::new(&dir);
        let agents = Agents { dir: dir.clone(), launchd: &launchd };
        launchd.seed(EARLIER_LABEL, Path::new(OLD));
        let runs = |program: &Path| launchd.runs_new(program);
        assert_eq!(agents.start(Path::new(NEW), true, &|| true, &confirm(&runs)), Ok(None));
        assert_eq!(launchd.events(), ["boot out helper [beacon helper]", "bootstrap beacon [beacon helper]"]);
        assert_eq!((launchd.files(), launchd.loaded_now()), (vec!["beacon".to_string()], vec!["beacon".to_string()]));
        assert!(launchd.runs_new(Path::new(NEW)));

        // While an update holds its lock nothing is moved: the job stays under its label.
        let launchd = FakeLaunchd::new(&dir);
        let agents = Agents { dir: dir.clone(), launchd: &launchd };
        std::fs::remove_file(agents.file(LABEL)).unwrap();
        launchd.seed(EARLIER_LABEL, Path::new(NEW));
        assert_eq!(agents.start(Path::new(NEW), false, &|| false, &confirm(&|_| panic!("nothing to move"))), Ok(None));
        assert_eq!(launchd.files(), ["helper"]);
        assert!(!launchd.events().iter().any(|e| e.contains("beacon")));

        // A move that does not hold: the helper runs on under the earlier label, and the
        // reason is handed back.
        let mut launchd = FakeLaunchd::new(&dir);
        launchd.comes_up = Box::new(|label, _| label == EARLIER_LABEL);
        let agents = Agents { dir: dir.clone(), launchd: &launchd };
        launchd.seed(EARLIER_LABEL, Path::new(NEW));
        let runs = |program: &Path| launchd.runs_new(program);
        let kept = agents.start(Path::new(NEW), true, &|| false, &confirm(&runs)).unwrap();
        assert!(kept.is_some_and(|why| why.contains("did not start under the label")));
        assert_eq!((launchd.files(), launchd.loaded_now()), (vec!["helper".to_string()], vec!["helper".to_string()]));
        assert!(launchd.running.borrow().is_some());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn with_both_files_at_a_start_one_helper_is_left_under_the_new_label() {
        let dir = temp("both");
        let launchd = FakeLaunchd::new(&dir);
        let agents = Agents { dir: dir.clone(), launchd: &launchd };
        // A login with both files: launchd loads both jobs, and one of the two helpers runs.
        launchd.seed(LABEL, Path::new(NEW));
        launchd.seed(EARLIER_LABEL, Path::new(NEW));
        assert_eq!(agents.in_use(), LABEL);

        // Under the new label: the earlier job is booted out and its file deleted, by the
        // process itself. Not while a move or an update is at work.
        assert_eq!(agents.at_start(Some(LABEL), true), AtStart::Serve);
        assert_eq!(agents.at_start(Some(LABEL), false), AtStart::DropEarlier);
        // Under the earlier label, with the new job loaded: it steps aside.
        assert_eq!(agents.at_start(Some(EARLIER_LABEL), false), AtStart::StepAside);
        assert_eq!(agents.at_start(Some(EARLIER_LABEL), true), AtStart::StepAside);
        // Not a job of ours: nothing.
        assert_eq!(agents.at_start(None, false), AtStart::Serve);

        agents.drop_earlier();
        assert_eq!(launchd.events(), ["boot out helper [beacon helper]"]);
        assert_eq!((launchd.files(), launchd.loaded_now()), (vec!["beacon".to_string()], vec!["beacon".to_string()]));
        assert_eq!(agents.at_start(Some(LABEL), false), AtStart::Serve);

        // Stepping aside is the move from its second step, done by the separate job. The new
        // file stays as it is, whatever program the earlier one names; its job is loaded and
        // runs, so only the earlier one goes.
        launchd.seed(EARLIER_LABEL, Path::new(OLD));
        *launchd.running.borrow_mut() = Some((LABEL.into(), PathBuf::from(NEW)));
        let new_before = std::fs::read_to_string(agents.file(LABEL)).unwrap();
        let runs = |program: &Path| launchd.runs_new(program);
        assert_eq!(agents.resume(&confirm(&runs)), Ok(()));
        assert_eq!(launchd.events(), ["boot out helper [beacon helper]", "kickstart beacon [beacon helper]"]);
        assert_eq!((launchd.files(), launchd.loaded_now()), (vec!["beacon".to_string()], vec!["beacon".to_string()]));
        assert_eq!(std::fs::read_to_string(agents.file(LABEL)).unwrap(), new_before);

        // Both files, and only the earlier job loaded: the same steps, and the new job is loaded.
        launchd.seed(EARLIER_LABEL, Path::new(OLD));
        launchd.loaded.borrow_mut().remove(LABEL);
        assert_eq!(agents.at_start(Some(EARLIER_LABEL), false), AtStart::Migrate);
        assert_eq!(agents.resume(&confirm(&runs)), Ok(()));
        assert_eq!(launchd.events(), ["boot out helper [beacon helper]", "bootstrap beacon [beacon helper]"]);
        assert_eq!((launchd.files(), launchd.loaded_now()), (vec!["beacon".to_string()], vec!["beacon".to_string()]));
        assert!(launchd.runs_new(Path::new(NEW)));
        // A new job that does not come up there: back to the earlier one, as in the whole move.
        launchd.seed(EARLIER_LABEL, Path::new(OLD));
        launchd.loaded.borrow_mut().remove(LABEL);
        assert!(agents.resume(&confirm(&|_| false)).is_err());
        assert_eq!((launchd.files(), launchd.loaded_now()), (vec!["helper".to_string()], vec!["helper".to_string()]));
        assert_eq!(*launchd.running.borrow(), Some((EARLIER_LABEL.to_string(), PathBuf::from(OLD))));
        launchd.events();
        launchd.seed(LABEL, Path::new(NEW));
        agents.drop_earlier();
        launchd.events();

        // Only the earlier file: the whole move. Only the new one: nothing.
        std::fs::rename(agents.file(LABEL), agents.file(EARLIER_LABEL)).unwrap();
        assert_eq!(agents.at_start(Some(EARLIER_LABEL), false), AtStart::Migrate);
        std::fs::rename(agents.file(EARLIER_LABEL), agents.file(LABEL)).unwrap();
        assert_eq!(agents.at_start(Some(LABEL), false), AtStart::Serve);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_restart_uses_the_new_label_and_the_earlier_one_while_only_that_exists() {
        let dir = temp("restart");
        let launchd = FakeLaunchd::new(&dir);
        let agents = Agents { dir: dir.clone(), launchd: &launchd };
        // Nothing yet: the new label.
        assert_eq!(agents.in_use(), LABEL);
        // Only the earlier file, as an update by a version from before the new label finds
        // it: restarted as it is, or loaded again for another program, under that label.
        launchd.seed(EARLIER_LABEL, Path::new(OLD));
        assert_eq!(agents.in_use(), EARLIER_LABEL);
        assert!(agents.restart_into(Path::new(OLD)));
        assert_eq!(launchd.events(), ["kickstart -k helper [helper]"]);
        assert!(agents.restart_into(Path::new(NEW)));
        assert_eq!(launchd.events(), ["boot out helper [helper]", "bootstrap helper [helper]"]);
        assert_eq!(launchd.files(), ["helper"]);
        // Only the new file.
        std::fs::remove_file(agents.file(EARLIER_LABEL)).unwrap();
        launchd.loaded.borrow_mut().clear();
        launchd.seed(LABEL, Path::new(NEW));
        assert!(agents.restart_into(Path::new(NEW)));
        assert_eq!(launchd.events(), ["kickstart -k beacon [beacon]"]);
        // Both, with the earlier job loaded: it is booted out, and the new one runs alone.
        launchd.seed(EARLIER_LABEL, Path::new(NEW));
        launchd.loaded.borrow_mut().remove(LABEL);
        assert!(agents.restart_into(Path::new(NEW)));
        assert_eq!(launchd.events(), ["boot out helper [beacon helper]", "bootstrap beacon [beacon helper]"]);
        assert_eq!(launchd.loaded_now(), ["beacon"]);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn uninstall_removes_the_jobs_and_files_of_both_labels() {
        let dir = temp("uninstall");
        for labels in [&[LABEL][..], &[EARLIER_LABEL][..], &[LABEL, EARLIER_LABEL][..], &[][..]] {
            let launchd = FakeLaunchd::new(&dir);
            let agents = Agents { dir: dir.clone(), launchd: &launchd };
            for label in labels {
                launchd.seed(label, Path::new(NEW));
            }
            std::fs::write(dir.join("other.plist"), "").unwrap();
            agents.stop_all();
            assert!(launchd.files().is_empty() && launchd.loaded_now().is_empty(), "{labels:?}");
            assert_eq!(launchd.events().len(), labels.len(), "{labels:?}");
            assert!(dir.join("other.plist").exists());
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_process_knows_its_label_from_its_file_or_from_launchd() {
        assert_eq!(own(Some(LABEL), None), Some(LABEL));
        assert_eq!(own(Some(LABEL), Some(LABEL)), Some(LABEL));
        // A file from before the new label sets no variable: launchd's name for the job tells.
        assert_eq!(own(None, Some(EARLIER_LABEL)), Some(EARLIER_LABEL));
        assert_eq!(own(None, Some(LABEL)), Some(LABEL));
        // Started from a terminal, by an app, or as the job that finishes an update.
        for other in [None, Some("0"), Some("application.com.apple.Terminal.1.2"), Some("dev.abrahamgonzalez.rexduo.helper.update"), Some("")] {
            assert_eq!(own(None, other), None, "{other:?}");
            assert_eq!(own(Some("something else"), other), None, "{other:?}");
        }
    }

    #[test]
    fn a_move_that_did_not_hold_is_left_alone_by_the_start_it_caused() {
        let dir = temp("put-off");
        assert!(!was_put_off(&dir));
        put_off(&dir);
        assert!(was_put_off(&dir));
        // Once: the start after that tries again.
        assert!(!was_put_off(&dir));
        std::fs::remove_dir_all(dir).unwrap();
    }
}
