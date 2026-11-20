//! Desk presence: whether the person sits at this computer, at a Rex desktop app that shows the
//! server an agent runs on. While they do, Beacon holds the pushes they would see on the
//! computer anyway (`hold.rs`), so the phone's Lock Screen does not fill up while they work.
//!
//! Pure: the readings come from `idle.rs` and the times from the caller, so every state is
//! tested. Anything unknown means not present, and a push that is not held is sent as before.

use crate::devices::ClientSnapshot;
use std::sync::OnceLock;
use std::time::{Duration, Instant};

// Fixed choices (Relay/README.md, "Desk presence").

/// Away after this long without input.
pub const AWAY_AFTER: f64 = 300.0;
/// A held question reaches the phone after this long at most, at the desk or not.
pub const HOLD_CAP: f64 = 600.0;
/// How often idle time, lock and display are read while a question is held.
pub const POLL: Duration = Duration::from_secs(30);
/// An in-front claim (`push_presence {active: true}`) lasts this long unless it is renewed.
pub const CLAIM_LIFE: f64 = 180.0;
/// How long the computer's sleep waits for held questions to go out.
pub const SLEEP_GRACE: Duration = Duration::from_secs(3);
/// How long a desktop notification waits before its pane is asked for an OSC 7501 record, so
/// a status sent right after it counts.
pub const NOTICE_WAIT: Duration = Duration::from_secs(1);
/// A pane that lost an OSC 7501 record still counts as having one for this long (seconds), as
/// in the phone app (`NoticeFilter.agentMemory`).
pub const NOTICE_MEMORY: f64 = 10.0;
/// A wall clock that went back by more than this makes earlier times unknown.
const CLOCK_SLACK: f64 = 5.0;

/// Seconds since this process started, on a clock no change of the date can move.
pub fn mono() -> f64 {
    static START: OnceLock<Instant> = OnceLock::new();
    START.get_or_init(Instant::now).elapsed().as_secs_f64()
}

/// A moment on two clocks: the wall clock, which survives a restart and keeps counting while
/// the computer sleeps, and a monotonic one, which a change of the date can't move. A time read
/// back from a file has the wall clock only.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Moment {
    pub wall: f64,
    pub mono: Option<f64>,
}

impl Moment {
    pub fn now() -> Moment {
        Moment { wall: crate::util::now(), mono: Some(mono()) }
    }

    /// Seconds from this moment to `later`: the longer of the two clocks' counts, so neither a
    /// clock set forward nor a sleep the monotonic clock misses makes a wait longer. A wall
    /// clock that went back makes it infinite: when unsure, the wait is over.
    pub fn elapsed_to(&self, later: &Moment) -> f64 {
        let wall = later.wall - self.wall;
        if wall < -CLOCK_SLACK {
            return f64::INFINITY;
        }
        let mono = match (self.mono, later.mono) {
            (Some(a), Some(b)) => b - a,
            _ => 0.0,
        };
        wall.max(mono)
    }
}

/// The login session as the window server describes it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Session {
    pub locked: bool,
    /// This user owns the console: false while another user is switched in.
    pub on_console: bool,
}

/// One reading of the computer. None is a source that could not be read.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Reading {
    /// Seconds since the last keyboard, mouse or trackpad input.
    pub idle: Option<f64>,
    /// None when the window server gave no session (no GUI login, or the call failed).
    pub session: Option<Session>,
    pub display_asleep: Option<bool>,
}

impl Reading {
    /// Why nobody is at this computer, or None when someone is. Every part must be known.
    pub fn away(&self, away_after: f64) -> Option<&'static str> {
        let Some(idle) = self.idle else { return Some("no idle time") };
        let Some(session) = self.session else { return Some("no login session") };
        let Some(asleep) = self.display_asleep else { return Some("no display state") };
        if !session.on_console {
            Some("another user has the screen")
        } else if session.locked {
            Some("screen locked")
        } else if asleep {
            Some("display asleep")
        } else if !(0.0..away_after).contains(&idle) {
            Some("no input")
        } else {
            None
        }
    }
}

/// Whether someone is at the desk, from the readings and the computer's power events, and when
/// that changed.
#[derive(Debug, Default)]
pub struct Desk {
    present: bool,
    /// Between "will sleep" and "has powered on". Readings in that time (a dark wake, Power
    /// Nap) never count.
    sleeping: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Edge {
    Arrived,
    Left(&'static str),
}

impl Desk {
    pub fn present(&self) -> bool {
        self.present
    }

    /// Takes a reading. Returns the change it made, if any.
    pub fn observe(&mut self, r: &Reading, away_after: f64) -> Option<Edge> {
        let away = if self.sleeping { Some("asleep") } else { r.away(away_after) };
        self.set(away)
    }

    /// The computer is going to sleep.
    pub fn will_sleep(&mut self) -> Option<Edge> {
        self.sleeping = true;
        self.set(Some("asleep"))
    }

    /// The computer woke up. The next reading decides; until then nobody is there.
    pub fn powered_on(&mut self) {
        self.sleeping = false;
    }

    fn set(&mut self, away: Option<&'static str>) -> Option<Edge> {
        let present = away.is_none();
        let changed = present != self.present;
        self.present = present;
        match (changed, away) {
            (false, _) => None,
            (true, None) => Some(Edge::Arrived),
            (true, Some(why)) => Some(Edge::Left(why)),
        }
    }
}

/// A process as the kernel describes it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Process {
    pub path: String,
    pub uid: u32,
    pub ppid: u32,
}

/// True when `c` is a Rex desktop app that runs on this computer for this user: a connected
/// `app` client that is not on iOS, whose process (`principal.pid`) is the main program of an
/// app bundle (`….app/Contents/MacOS/<name>`), runs as `uid`, and was started by launchd
/// (parent pid 1), as an app the person opened is. The Mac app of another computer reaches this
/// server through SSH: its process here is a bridge started by sshd, so it doesn't count.
pub fn is_local_desktop_app(c: &ClientSnapshot, uid: u32, process: &dyn Fn(u32) -> Option<Process>) -> bool {
    let desktop = c.kind.as_deref() == Some("app")
        && c.platform.as_deref().is_some_and(|p| !p.is_empty() && p != "ios")
        && c.connection_state.as_deref() == Some("connected");
    let Some(pid) = c.pid.filter(|p| *p > 1) else { return false };
    desktop && process(pid).is_some_and(|p| p.uid == uid && p.ppid == 1 && is_app_main(&p.path))
}

/// `/Applications/Rex.app/Contents/MacOS/Rex`: the program right inside an app bundle's
/// `Contents/MacOS`.
fn is_app_main(path: &str) -> bool {
    let Some((bundle, name)) = path.rsplit_once(".app/Contents/MacOS/") else { return false };
    path.starts_with('/') && !bundle.is_empty() && !name.is_empty() && !name.contains('/')
}

#[cfg(test)]
mod tests {
    use super::*;

    const AWAY: f64 = AWAY_AFTER;

    fn at_desk() -> Reading {
        Reading { idle: Some(2.0), session: Some(Session { locked: false, on_console: true }), display_asleep: Some(false) }
    }

    #[test]
    fn present_only_when_every_reading_says_so() {
        assert_eq!(at_desk().away(AWAY), None);
        let cases: [(&str, Reading); 8] = [
            ("no idle time", Reading { idle: None, ..at_desk() }),
            ("no login session", Reading { session: None, ..at_desk() }),
            ("no display state", Reading { display_asleep: None, ..at_desk() }),
            // Locked with fresh input (a key pressed at the lock screen) is still away.
            ("screen locked", Reading { session: Some(Session { locked: true, on_console: true }), ..at_desk() }),
            // Fast user switching: another user has the console, whatever the idle time says.
            ("another user has the screen", Reading { session: Some(Session { locked: false, on_console: false }), ..at_desk() }),
            ("display asleep", Reading { display_asleep: Some(true), ..at_desk() }),
            ("no input", Reading { idle: Some(AWAY), ..at_desk() }),
            ("no input", Reading { idle: Some(-1.0), ..at_desk() }),
        ];
        for (why, r) in cases {
            assert_eq!(r.away(AWAY), Some(why), "{r:?}");
        }
        assert_eq!(Reading::default().away(AWAY), Some("no idle time"));
        assert_eq!(Reading { idle: Some(AWAY - 0.5), ..at_desk() }.away(AWAY), None);
    }

    #[test]
    fn edges_come_once_and_sleep_is_away_until_woken_and_read() {
        let mut d = Desk::default();
        assert!(!d.present());
        assert_eq!(d.observe(&at_desk(), AWAY), Some(Edge::Arrived));
        assert_eq!(d.observe(&at_desk(), AWAY), None);
        assert_eq!(d.will_sleep(), Some(Edge::Left("asleep")));
        assert_eq!(d.will_sleep(), None);
        // A dark wake reads like a desk (Power Nap, a timer): still asleep.
        assert_eq!(d.observe(&at_desk(), AWAY), None);
        assert!(!d.present());
        d.powered_on();
        assert!(!d.present(), "nobody is there until a reading says so");
        assert_eq!(d.observe(&Reading { display_asleep: Some(true), ..at_desk() }, AWAY), None);
        assert_eq!(d.observe(&at_desk(), AWAY), Some(Edge::Arrived));
        assert_eq!(d.observe(&Reading { idle: Some(400.0), ..at_desk() }, AWAY), Some(Edge::Left("no input")));
        // A missing source after it was present: away.
        d.observe(&at_desk(), AWAY);
        assert_eq!(d.observe(&Reading { idle: None, ..at_desk() }, AWAY), Some(Edge::Left("no idle time")));
    }

    #[test]
    fn waits_count_the_longer_clock_and_a_clock_set_back_ends_them() {
        let start = Moment { wall: 1000.0, mono: Some(10.0) };
        assert_eq!(start.elapsed_to(&Moment { wall: 1060.0, mono: Some(70.0) }), 60.0);
        // Slept 20 minutes: the monotonic clock stood still, the wall clock did not.
        assert_eq!(start.elapsed_to(&Moment { wall: 2200.0, mono: Some(12.0) }), 1200.0);
        // The date set forward a day: over at once rather than late.
        assert!(start.elapsed_to(&Moment { wall: 87400.0, mono: Some(11.0) }) >= HOLD_CAP);
        // Set back an hour: unknown, so over.
        assert_eq!(start.elapsed_to(&Moment { wall: -2600.0, mono: Some(20.0) }), f64::INFINITY);
        // A small correction back is no jump; the monotonic clock carries on.
        assert_eq!(start.elapsed_to(&Moment { wall: 998.0, mono: Some(40.0) }), 30.0);
        // Read back from a file after a restart: the wall clock alone.
        let stored = Moment { wall: 1000.0, mono: None };
        assert_eq!(stored.elapsed_to(&Moment { wall: 1300.0, mono: Some(1.0) }), 300.0);
        assert!(mono() >= 0.0);
    }

    fn client(platform: &str, state: &str, pid: Option<u32>) -> ClientSnapshot {
        ClientSnapshot {
            client_id: "client:mac".into(),
            kind: Some("app".into()),
            platform: Some(platform.into()),
            name: Some("Rex".into()),
            label: Some("MBP_M4MAX".into()),
            connection_state: Some(state.into()),
            pid,
        }
    }

    fn procs(pid: u32) -> Option<Process> {
        let p = |path: &str, uid, ppid| Some(Process { path: path.into(), uid, ppid });
        match pid {
            100 => p("/Applications/Rex Beta.app/Contents/MacOS/Rex", 501, 1),
            // The bridge an SSH session starts for the Mac app of another computer.
            200 => p("/Users/me/Library/Application Support/com.superlogical.rex/RexServer/Versions/Current/Rex Server.app/Contents/MacOS/rex", 501, 4242),
            201 => p("/usr/bin/ssh", 501, 4242),
            300 => p("/Applications/Rex.app/Contents/MacOS/Rex", 502, 1),
            400 => p("/usr/local/bin/rex", 501, 1),
            500 => p("/Applications/Rex.app/Contents/MacOS/Helpers/rex-helper", 501, 1),
            _ => None,
        }
    }

    #[test]
    fn only_a_desktop_app_running_here_for_this_user_counts() {
        assert!(is_local_desktop_app(&client("macos", "connected", Some(100)), 501, &procs));
        for (c, why) in [
            (client("macos", "connected", Some(200)), "bridged through SSH"),
            (client("macos", "connected", Some(201)), "an ssh process"),
            (client("macos", "connected", Some(300)), "another user's app"),
            (client("macos", "connected", Some(400)), "not an app bundle"),
            (client("macos", "connected", Some(500)), "a helper inside a bundle"),
            (client("macos", "connected", Some(999)), "a process that is gone"),
            (client("macos", "connected", None), "no pid (not a peer, or an older Rex)"),
            (client("macos", "connected", Some(1)), "launchd"),
            (client("ios", "connected", Some(100)), "the phone app"),
            (client("", "connected", Some(100)), "no platform"),
            (client("macos", "lost", Some(100)), "lost"),
        ] {
            assert!(!is_local_desktop_app(&c, 501, &procs), "{why}");
        }
        let mut other = client("macos", "connected", Some(100));
        other.kind = Some("other".into());
        assert!(!is_local_desktop_app(&other, 501, &procs), "Beacon itself, or a script");
        assert!(is_app_main("/A.app/Contents/MacOS/A"));
        assert!(!is_app_main("A.app/Contents/MacOS/A"));
        assert!(!is_app_main("/.app/Contents/MacOS/"));
    }
}
