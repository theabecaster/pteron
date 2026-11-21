//! What the scripts beside this program read from it: `brand` (Relay/package.sh and
//! Relay/release.sh) and `version --json` (Relay/setup.sh, in every copy that shipped).

use std::process::Command;

fn printed(args: &[&str]) -> (bool, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_rex-duo-helper")).args(args).output().expect("the helper runs");
    (out.status.success(), String::from_utf8(out.stdout).unwrap())
}

/// The `BEACON=` line of setup.sh: the name without its quotes.
fn setup_name() -> String {
    let setup = include_str!("../setup.sh");
    let line = setup.lines().find(|l| l.starts_with("BEACON=")).expect("setup.sh has a BEACON= line");
    line.trim_start_matches("BEACON=").trim_matches('"').to_string()
}

#[test]
fn brand_prints_the_name_on_one_line() {
    let (ok, said) = printed(&["brand"]);
    assert!(ok);
    assert_eq!(said, format!("{}\n", setup_name()));
    assert!(said.trim_end().ends_with(" Beacon"));
    // It takes no arguments: anything more is not this command.
    assert!(!printed(&["brand", "--json"]).0);
}

#[test]
fn version_json_is_one_field_in_one_shape() {
    let version = env!("CARGO_PKG_VERSION");
    assert_eq!(printed(&["version", "--json"]), (true, format!("{{\"version\":\"{version}\"}}\n")));
    assert_eq!(printed(&["version"]), (true, format!("{version}\n")));
    assert_eq!(printed(&["--version"]), (true, format!("{version}\n")));
}

/// `run` ends by itself on the two signals a service manager and a terminal send: it says so,
/// removes its status.json and exits with 0. It runs as a dry run that watches a socket nothing
/// listens on, in a home and a state folder of its own.
#[cfg(unix)]
#[test]
fn run_stops_cleanly_on_a_stop_signal() {
    use std::io::Read;
    use std::process::Stdio;
    use std::time::{Duration, Instant};

    struct Running(std::process::Child);
    impl Drop for Running {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }

    for signal in ["-TERM", "-INT"] {
        let dir = std::env::temp_dir().join(format!("commands-stop{signal}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let state = dir.join("state");
        std::fs::create_dir_all(&state).unwrap();
        let child = Command::new(env!("CARGO_BIN_EXE_rex-duo-helper"))
            .args(["run", "--dry-run", "--state-dir"])
            .arg(&state)
            .arg("--server")
            .arg(format!("unix://{}", dir.join("no-rex.sock").display()))
            .env("HOME", &dir)
            .env_remove("REX_SERVER")
            .env_remove("XDG_STATE_HOME")
            .env_remove("XDG_RUNTIME_DIR")
            // Under systemd, as on a CI runner, the helper leaves the time off each line.
            .env_remove("JOURNAL_STREAM")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("the helper runs");
        let mut running = Running(child);
        // status.json is written just before `run` starts to wait for a signal.
        let status = state.join("status.json");
        let asked = Instant::now();
        while !status.exists() {
            assert!(asked.elapsed() < Duration::from_secs(20), "{signal}: no status.json");
            std::thread::sleep(Duration::from_millis(20));
        }
        std::thread::sleep(Duration::from_millis(500));
        assert!(Command::new("/bin/kill").args([signal, &running.0.id().to_string()]).status().unwrap().success());
        let asked = Instant::now();
        let code = loop {
            if let Some(ended) = running.0.try_wait().unwrap() {
                break ended.code();
            }
            assert!(asked.elapsed() < Duration::from_secs(20), "{signal}: still running");
            std::thread::sleep(Duration::from_millis(20));
        };
        let mut said = String::new();
        running.0.stdout.take().unwrap().read_to_string(&mut said).unwrap();
        assert_eq!(code, Some(0), "{signal}: {said}");
        assert!(said.lines().last().is_some_and(|line| line.ends_with(" stopping")), "{signal}: {said}");
        assert!(!status.exists(), "{signal}");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
