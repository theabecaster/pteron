//! Starting other programs. Every program the helper runs is started here, by its full path:
//! a path the caller already has (the notifier inside the app, the `rex` it found), or a
//! system tool looked up by name in the system's own folders. `PATH` is never searched, so
//! what runs does not depend on the environment the helper was started in.

use std::path::{Path, PathBuf};

/// Where system tools live, in the order they are tried: the system's own list.
use crate::platform::TOOL_DIRS as DIRS;

/// The first of `dirs` that holds a regular file called `name` (a link to one counts).
pub fn find_in(dirs: &[&Path], name: &str) -> Option<PathBuf> {
    if name.is_empty() || name.contains('/') || name == "." || name == ".." {
        return None;
    }
    dirs.iter().map(|d| d.join(name)).find(|p| std::fs::metadata(p).is_ok_and(|m| m.is_file()))
}

/// The full path to run for `program`: itself when it is an absolute path, or the system tool
/// of that name. None for a relative path, and for a tool this system doesn't have.
pub fn program(program: &Path) -> Option<PathBuf> {
    if program.is_absolute() {
        return Some(program.to_path_buf());
    }
    let dirs = DIRS.map(Path::new);
    find_in(&dirs, program.to_str()?)
}

/// A command for `program`, to wait for on the calling thread.
pub fn command(program: impl AsRef<Path>) -> Option<std::process::Command> {
    self::program(program.as_ref()).map(std::process::Command::new)
}

/// A command for `program`, to wait for on the runtime.
pub fn async_command(program: impl AsRef<Path>) -> Option<tokio::process::Command> {
    self::program(program.as_ref()).map(tokio::process::Command::new)
}

/// Runs `command` and gives what it printed, whatever its exit status. None when it could
/// not be started, took longer than `wait`, or printed more than `limit` bytes: it is
/// stopped then, and nothing of what it printed is used. Its input and its errors go nowhere.
pub async fn printed(mut command: tokio::process::Command, limit: usize, wait: std::time::Duration) -> Option<Vec<u8>> {
    use std::process::Stdio;
    use tokio::io::AsyncReadExt;
    // Dropping the child, on any way out of here, ends it.
    let mut child = command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null()).kill_on_drop(true).spawn().ok()?;
    let out = child.stdout.take()?;
    let mut bytes = vec![];
    let read = async {
        out.take(limit as u64 + 1).read_to_end(&mut bytes).await.ok()?;
        if bytes.len() > limit {
            return None;
        }
        child.wait().await.ok()
    };
    tokio::time::timeout(wait, read).await.ok()??;
    Some(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("tools-{tag}-{}-{}", std::process::id(), crate::util::now()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[cfg(unix)]
    #[test]
    fn a_tool_is_the_first_regular_file_of_that_name_in_the_listed_folders() {
        let dir = temp("find");
        let (a, b, c) = (dir.join("a"), dir.join("b"), dir.join("c"));
        for d in [&a, &b, &c] {
            std::fs::create_dir_all(d).unwrap();
        }
        std::fs::write(b.join("systemctl"), "").unwrap();
        std::fs::write(c.join("systemctl"), "").unwrap();
        std::fs::write(c.join("loginctl"), "").unwrap();
        // A folder of that name is not a tool.
        std::fs::create_dir_all(a.join("loginctl")).unwrap();
        std::os::unix::fs::symlink(c.join("loginctl"), b.join("linked")).unwrap();
        std::os::unix::fs::symlink(c.join("nothing"), b.join("dangling")).unwrap();
        let dirs = [a.as_path(), b.as_path(), c.as_path()];
        assert_eq!(find_in(&dirs, "systemctl"), Some(b.join("systemctl")));
        assert_eq!(find_in(&dirs, "loginctl"), Some(c.join("loginctl")));
        assert_eq!(find_in(&dirs, "linked"), Some(b.join("linked")));
        for none in ["dangling", "missing", "", ".", "..", "b/systemctl", "../b/systemctl", "/bin/sh"] {
            assert_eq!(find_in(&dirs, none), None, "{none:?}");
        }
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn only_a_full_path_or_a_system_tool_is_run() {
        assert_eq!(DIRS, ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/run/current-system/sw/bin"]);
        assert_eq!(program(Path::new("/opt/x/rex")), Some(PathBuf::from("/opt/x/rex")));
        // `sh` is in one of the folders on every system the helper runs on.
        let sh = program(Path::new("sh")).unwrap();
        assert!(sh.is_absolute() && DIRS.iter().any(|d| sh.parent() == Some(Path::new(d))), "{sh:?}");
        for refused in ["", "bin/sh", "./sh", "../bin/sh", "no-such-tool-here"] {
            assert_eq!(program(Path::new(refused)), None, "{refused:?}");
            assert!(command(refused).is_none() && async_command(refused).is_none());
        }
        assert_eq!(command("sh").unwrap().get_program(), sh.as_os_str());
    }

    #[tokio::test]
    async fn what_a_program_prints_is_taken_whole_or_not_at_all() {
        use std::time::Duration;
        let sh = |script: &str| {
            let mut c = async_command("sh").unwrap();
            c.args(["-c", script]);
            c
        };
        let long = Duration::from_secs(20);
        assert_eq!(printed(sh("printf hello"), 64, long).await.as_deref(), Some(&b"hello"[..]));
        // Its exit status plays no part, and what it writes to its errors is not read.
        assert_eq!(printed(sh("printf out; printf err >&2; exit 3"), 64, long).await.as_deref(), Some(&b"out"[..]));
        assert_eq!(printed(sh("exit 1"), 64, long).await.as_deref(), Some(&b""[..]));
        // Exactly the limit is taken; one byte more and nothing is.
        assert_eq!(printed(sh("printf 12345678"), 8, long).await.map(|b| b.len()), Some(8));
        assert_eq!(printed(sh("printf 123456789"), 8, long).await, None);
        // A program that never stops printing, and one that never ends, are stopped.
        let began = std::time::Instant::now();
        assert_eq!(printed(sh("while :; do printf xxxxxxxxxxxxxxxx; done"), 4096, long).await, None);
        assert_eq!(printed(sh("sleep 30"), 64, Duration::from_millis(200)).await, None);
        assert!(began.elapsed() < Duration::from_secs(10));
    }

    /// Reads the crate's own source: `tools.rs` is the one file that makes a command, so no
    /// other file can start a program by a bare name.
    #[test]
    fn commands_are_made_only_here() {
        let needle = ["Command::", "new"].concat();
        let src = Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut seen = 0;
        let files = [src.clone(), src.join("platform")].map(|dir| std::fs::read_dir(dir).unwrap());
        for entry in files.into_iter().flatten() {
            let path = entry.unwrap().path();
            if path.extension().is_none_or(|e| e != "rs") {
                continue;
            }
            seen += 1;
            let count = std::fs::read_to_string(&path).unwrap().matches(&needle).count();
            let expected = if path.file_name().unwrap() == "tools.rs" { 2 } else { 0 };
            assert_eq!(count, expected, "{}", path.display());
        }
        assert!(seen >= 18, "read {seen} source files");
    }
}
