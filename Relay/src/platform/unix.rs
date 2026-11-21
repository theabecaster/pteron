//! macOS and Linux.

use super::{Invocation, Os, Process, SocketCheck};
use std::fs::File;
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::Stdio;

/// The system this program was built for.
#[cfg(target_os = "macos")]
pub const OS: Os = Os::Mac;
#[cfg(target_os = "linux")]
pub const OS: Os = Os::Linux;

/// Where system tools live, in the order they are tried. The last one is NixOS.
pub const TOOL_DIRS: [&str; 5] = ["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/run/current-system/sw/bin"];

// MARK: The user

/// How the system names a user.
pub type UserId = u32;

/// The user this process runs as.
pub fn user_id() -> UserId {
    extern "C" {
        fn geteuid() -> u32;
    }
    // Safe: geteuid takes nothing, touches no memory of ours and cannot fail.
    unsafe { geteuid() }
}

// MARK: Files only this user can read

/// A new file at `path` that only this user can read from the moment it exists, open for
/// writing. It fails when something has that name already: nothing is written over or through.
pub fn create_private(path: &Path) -> std::io::Result<File> {
    std::fs::OpenOptions::new().write(true).create_new(true).mode(0o600).open(path)
}

/// The file at `path`, open for writing with what it holds left as it is. When it is not
/// there it is made, for this user only.
pub fn open_private(path: &Path) -> std::io::Result<File> {
    std::fs::OpenOptions::new().create(true).truncate(false).write(true).mode(0o600).open(path)
}

/// Writes `path` through a temporary file beside it (`<name>.json.tmp`) that only this user
/// can read from the moment it exists, then renames it into place: a reader sees the old file
/// or the whole new one. `fill` writes what the file holds.
pub fn write_private_with(path: &Path, fill: impl FnOnce(&mut File) -> std::io::Result<()>) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let tmp = path.with_extension("json.tmp");
    let _ = std::fs::remove_file(&tmp);
    let mut f = create_private(&tmp)?;
    f.set_permissions(std::fs::Permissions::from_mode(0o600))?;
    fill(&mut f)?;
    f.sync_all()?;
    std::fs::rename(&tmp, path)
}

/// `write_private_with` for bytes the caller already has.
pub fn write_private(path: &Path, data: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    write_private_with(path, |f| f.write_all(data))
}

/// Takes the file at `path` away from everyone but its owner.
pub fn make_private(path: &Path) -> std::io::Result<()> {
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))
}

/// Makes the file at `path` a program anyone may run and only its owner may change.
pub fn make_executable(path: &Path) -> std::io::Result<()> {
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
}

/// Lets everyone read the open `file`, and only its owner change it, whatever the umask.
#[cfg(any(target_os = "macos", test))]
pub fn make_readable(file: &File) -> std::io::Result<()> {
    file.set_permissions(std::fs::Permissions::from_mode(0o644))
}

/// A new folder at `path` that only this user can open. Its parent has to be there.
pub fn create_private_dir(path: &Path) -> std::io::Result<()> {
    std::fs::DirBuilder::new().mode(0o700).create(path)
}

/// The file at `path`, open for reading, when it is a regular file (not a link to one) that
/// belongs to `user` and that no one else can open. It comes with what the system says about
/// the open file, which is the file that was looked at by name.
pub fn open_owned_private(path: &Path, user: UserId) -> Option<(File, std::fs::Metadata)> {
    let named = std::fs::symlink_metadata(path).ok().filter(|m| m.file_type().is_file())?;
    let file = File::open(path).ok()?;
    // What was opened is the file that was looked at by name.
    let m = file.metadata().ok().filter(|m| m.dev() == named.dev() && m.ino() == named.ino())?;
    if !m.is_file() || m.uid() != user || m.mode() & 0o077 != 0 {
        return None;
    }
    Some((file, m))
}

/// True when `path` is a file that someone may run.
pub fn is_executable(path: &Path) -> bool {
    std::fs::metadata(path).map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0).unwrap_or(false)
}

/// What tells one version of a file from the next: inode, size and modification time. A write
/// that goes through a rename changes the inode alone.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FileStamp(u64, u64, std::time::SystemTime);

/// The stamp of the file at `path` as it is now. None when it can't be looked at.
pub fn file_stamp(path: &Path) -> Option<FileStamp> {
    let m = std::fs::metadata(path).ok()?;
    Some(FileStamp(m.ino(), m.len(), m.modified().ok()?))
}

/// Whether `path` is a socket that belongs to `user`.
pub fn check_socket(path: &Path, user: UserId) -> SocketCheck {
    match std::fs::metadata(path) {
        Err(_) => SocketCheck::Missing,
        Ok(m) if !m.file_type().is_socket() => SocketCheck::NotSocket,
        Ok(m) if m.uid() != user => SocketCheck::OtherUser,
        Ok(_) => SocketCheck::Ours,
    }
}

/// Where a Linux user's runtime files live when `XDG_RUNTIME_DIR` doesn't say:
/// `/run/user/<uid>`, with the uid that owns `/proc/self`, or 1000 when that can't be read.
pub fn fallback_runtime_dir() -> PathBuf {
    let uid = std::fs::metadata("/proc/self").map(|m| m.uid()).unwrap_or(1000);
    PathBuf::from(format!("/run/user/{uid}"))
}

// MARK: Processes

/// True while a process with the id `pid` exists. Where there is a `/proc` it is read; anywhere
/// else `kill -0` asks, which also says no for a process of another user.
pub fn process_alive(pid: u64) -> bool {
    if Path::new("/proc/self").exists() {
        return Path::new(&format!("/proc/{pid}")).exists();
    }
    let Some(mut command) = crate::tools::command("/bin/kill") else { return false };
    command.args(["-0", &pid.to_string()]).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null()).status().is_ok_and(|s| s.success())
}

/// The program behind a process id, the user it runs as, the process that started it, its
/// process group and the group in the foreground of its terminal. None when there is no such
/// process or it can't be read. macOS asks the kernel; Linux reads `/proc/<pid>`.
#[cfg(target_os = "macos")]
pub fn process(pid: u32) -> Option<Process> {
    mac::process(pid)
}

#[cfg(target_os = "linux")]
pub fn process(pid: u32) -> Option<Process> {
    let dir = PathBuf::from(format!("/proc/{pid}"));
    let stat = std::fs::read_to_string(dir.join("stat")).ok()?;
    let status = std::fs::read_to_string(dir.join("status")).ok()?;
    // Only the process's own user (and root) can read the link.
    let exe = std::fs::read_link(dir.join("exe")).ok();
    proc_fs::process(pid, &stat, &status, exe.as_deref().and_then(Path::to_str))
}

/// How the process `pid` was started: its arguments and its working directory. None when
/// there is no such process or it is not this user's to read. macOS asks the kernel
/// (`KERN_PROCARGS2`, of which only the arguments are kept, and the process's vnode paths);
/// Linux reads `/proc/<pid>/cmdline` and the `cwd` link. The environment is never returned.
#[cfg(target_os = "macos")]
pub fn invocation(pid: u32) -> Option<Invocation> {
    mac::invocation(pid)
}

#[cfg(target_os = "linux")]
pub fn invocation(pid: u32) -> Option<Invocation> {
    use std::io::Read;
    let dir = PathBuf::from(format!("/proc/{pid}"));
    let mut bytes = vec![];
    // One byte past the limit says that there was more.
    File::open(dir.join("cmdline")).ok()?.take(super::ARGV_MAX as u64 + 1).read_to_end(&mut bytes).ok()?;
    let (argv, truncated) = proc_fs::cmdline(&bytes);
    let cwd = std::fs::read_link(dir.join("cwd")).ok().and_then(|p| p.to_str().map(String::from));
    Some(Invocation { argv, truncated, cwd })
}

/// The arguments in what `KERN_PROCARGS2` gives. The block is: the count of arguments (an
/// int), the program's path with its NUL, NULs up to the next multiple of 8 bytes, then each
/// argument with its NUL, then the environment in the same form.
///
/// Where the arguments begin is worked out from the path's length, never looked for: an
/// argument may be empty, so a NUL says nothing about where one starts. Exactly the counted
/// arguments are read from there and nothing after them, which is where the environment is.
/// None when the block is not of that form in any way (no path, padding that is not NULs,
/// fewer arguments than counted): then nothing of it is used.
#[cfg(any(target_os = "macos", test))]
fn procargs(buf: &[u8]) -> Option<(Vec<Vec<u8>>, bool)> {
    let count = usize::try_from(i32::from_ne_bytes(buf.get(..4)?.try_into().ok()?)).ok()?;
    let path = buf[4..].iter().position(|b| *b == 0).filter(|len| *len > 0)?;
    let start = 4 + (path + 1).div_ceil(8) * 8;
    if buf.get(4 + path..start)?.iter().any(|b| *b != 0) {
        return None;
    }
    let mut rest = &buf[start..];
    let mut args = Vec::with_capacity(count.min(super::ARGS_MAX + 1));
    for _ in 0..count {
        let end = rest.iter().position(|b| *b == 0)?;
        // More than is ever kept: the rest is counted off without being held.
        if args.len() <= super::ARGS_MAX {
            args.push(&rest[..end]);
        }
        rest = &rest[end + 1..];
    }
    Some(super::capped(args.into_iter(), false))
}

/// The last part of a program's path.
fn program_name(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

/// Linux's `/proc/<pid>` as text, read apart from the files so the same lines are tested on
/// every system.
#[cfg(any(target_os = "linux", test))]
mod proc_fs {
    use super::Process;

    /// A process from its `stat` and `status` files and what its `exe` link names, if that
    /// could be read. None when either file is not what the kernel writes, or is another
    /// process's.
    pub fn process(pid: u32, stat: &str, status: &str, exe: Option<&str>) -> Option<Process> {
        // `<pid> (<comm>) <state> <ppid> <pgrp> <session> <tty_nr> <tpgid> …`. The name may
        // hold spaces and brackets of its own, so it ends at the last one.
        let (before, after) = (stat.find('(')?, stat.rfind(')')?);
        if before >= after || stat[..before].trim().parse::<u32>().ok()? != pid {
            return None;
        }
        let comm = &stat[before + 1..after];
        let mut fields = stat[after + 1..].split_ascii_whitespace().skip(1);
        let mut number = || fields.next()?.parse::<i64>().ok();
        let (ppid, pgid, session, tty, tty_pgid) = (number()?, number()?, number()?, number()?, number()?);
        // `Uid:` lists the real, effective, saved and filesystem user: the effective one is
        // who the process acts as.
        let uid = status.lines().find_map(|l| l.strip_prefix("Uid:"))?.split_ascii_whitespace().nth(1)?.parse().ok()?;
        // The link of a program that was replaced on disk ends with " (deleted)".
        let path = exe.map(|e| e.strip_suffix(" (deleted)").unwrap_or(e)).filter(|e| e.starts_with('/')).unwrap_or("");
        Some(Process {
            path: path.to_string(),
            name: if path.is_empty() { comm.to_string() } else { super::program_name(path).to_string() },
            uid,
            ppid: u32::try_from(ppid).ok()?,
            pgid: u32::try_from(pgid).ok()?,
            sid: u32::try_from(session).unwrap_or(0),
            tty_pgid: (tty != 0).then_some(tty_pgid).and_then(|g| u32::try_from(g).ok()).filter(|g| *g > 0),
        })
    }

    /// The arguments in a `cmdline` file: each ends in a NUL. More bytes than `ARGV_MAX`
    /// means the file went on: the argument the cut fell in is left out.
    pub fn cmdline(bytes: &[u8]) -> (Vec<Vec<u8>>, bool) {
        let cut = bytes.len() > crate::platform::ARGV_MAX;
        let whole = match bytes.iter().rposition(|b| *b == 0) {
            Some(last) => &bytes[..last],
            // No NUL at all: nothing (a kernel thread, a process that has ended), or one
            // argument that never ended.
            None if bytes.is_empty() => return (vec![], false),
            None => return (vec![], true),
        };
        // A file that ends without a NUL was cut in an argument, wherever that was.
        let cut = cut || bytes.last() != Some(&0);
        crate::platform::capped(whole.split(|b| *b == 0), cut)
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn arguments_are_read_as_they_are_with_spaces_quotes_and_nothing() {
            let args = |bytes: &[u8]| cmdline(bytes);
            assert_eq!(args(b"npm\0run\0dev\0"), (vec![b"npm".to_vec(), b"run".to_vec(), b"dev".to_vec()], false));
            // Spaces, quotes and an empty argument are arguments like any other; so are
            // bytes that are no text.
            let odd = args(b"sh\0-c\0echo \"a b\" 'c'\0\0it's\0\xff\xfe\0");
            assert_eq!(odd, (vec![b"sh".to_vec(), b"-c".to_vec(), b"echo \"a b\" 'c'".to_vec(), vec![], b"it's".to_vec(), vec![0xff, 0xfe]], false));
            // A program that wrote a title over its arguments (node's `process.title`): one
            // argument with spaces in it, and whatever padding it left as empty ones. Nothing
            // tells this from a program started that way.
            assert_eq!(args(b"my server title\0\0\0"), (vec![b"my server title".to_vec(), vec![], vec![]], false));
            // A kernel thread, or a process that ended between two reads.
            assert_eq!(args(b""), (vec![], false));
        }

        #[test]
        fn arguments_past_the_limits_are_cut_at_a_whole_one_and_flagged() {
            use crate::platform::{ARGS_MAX, ARGV_MAX};
            // Read one byte past the limit: the last argument is not whole, and is left out.
            let mut long = b"node\0".to_vec();
            long.extend(std::iter::repeat_n(b'x', ARGV_MAX + 1 - long.len()));
            assert_eq!(cmdline(&long), (vec![b"node".to_vec()], true));
            // Exactly at the limit, whole: kept.
            let mut fits = b"node\0".to_vec();
            fits.extend(std::iter::repeat_n(b'x', ARGV_MAX - fits.len() - 1));
            fits.push(0);
            let (argv, truncated) = cmdline(&fits);
            assert_eq!((argv.len(), argv[1].len(), truncated), (2, ARGV_MAX - 6, false));
            // More arguments than the limit.
            let many = b"a\0".repeat(ARGS_MAX + 5);
            let (argv, truncated) = cmdline(&many);
            assert_eq!((argv.len(), truncated), (ARGS_MAX, true));
            // No NUL at the end, or none at all.
            assert_eq!(cmdline(b"node\0serv"), (vec![b"node".to_vec()], true));
            assert_eq!(cmdline(b"node"), (vec![], true));
        }

        const STATUS: &str = "Name:\tnode\nUmask:\t0022\nState:\tS (sleeping)\nTgid:\t4242\nPid:\t4242\nPPid:\t4201\nUid:\t1000\t1001\t1000\t1000\nGid:\t1000\t1000\t1000\t1000\n";

        #[test]
        fn a_process_is_read_from_its_stat_and_status_lines() {
            // A dev server in a terminal: its group is the one in the foreground there.
            let stat = "4242 (node) S 4201 4200 900 34817 4200 4194304 1 0 0 0 5 1 0 0 20 0 11 0 100 1 2\n";
            let p = process(4242, stat, STATUS, Some("/usr/bin/node")).unwrap();
            assert_eq!(p, Process { path: "/usr/bin/node".into(), name: "node".into(), uid: 1001, ppid: 4201, pgid: 4200, sid: 900, tty_pgid: Some(4200) });
            // No terminal: `tty_nr` is 0 and `tpgid` -1.
            let daemon = "4242 (node) S 1 4242 4242 0 -1 4194304 1 0\n";
            let p = process(4242, daemon, STATUS, Some("/usr/bin/node")).unwrap();
            assert_eq!((p.ppid, p.pgid, p.tty_pgid), (1, 4242, None));
            // A program replaced on disk still has its path; without the link (another
            // user's process) the kernel's short name is the name.
            let p = process(4242, stat, STATUS, Some("/opt/app/bin/server (deleted)")).unwrap();
            assert_eq!((p.path.as_str(), p.name.as_str()), ("/opt/app/bin/server", "server"));
            let p = process(4242, stat, STATUS, None).unwrap();
            assert_eq!((p.path.as_str(), p.name.as_str()), ("", "node"));
        }

        #[test]
        fn a_name_with_spaces_and_brackets_does_not_move_the_fields() {
            let stat = "77 (a) b (c) 9 9) R 12 34 56 34817 78 0 0\n";
            let p = process(77, stat, STATUS, None).unwrap();
            assert_eq!((p.name.as_str(), p.ppid, p.pgid, p.tty_pgid), ("a) b (c) 9 9", 12, 34, Some(78)));
        }

        #[test]
        fn text_that_is_no_process_is_none() {
            let stat = "4242 (node) S 4201 4200 900 34817 4200 0\n";
            assert!(process(4242, stat, STATUS, None).is_some());
            // Another process's file (the id was used again between two reads).
            assert!(process(4243, stat, STATUS, None).is_none());
            for bad in ["", "4242", "4242 node S 1 2 3 4 5", "4242 )node( S 1 2 3 4 5", "4242 (node) S 1 2", "4242 (node) S x 2 3 4 5", "4242 (node) S -1 2 3 4 5", "x (node) S 1 2 3 4 5"] {
                assert!(process(4242, bad, STATUS, None).is_none(), "{bad:?}");
            }
            for bad in ["", "Name:\tnode\n", "Uid:\n", "Uid:\t1000\n", "Uid:\t1000\tx\n"] {
                assert!(process(4242, stat, bad, None).is_none(), "{bad:?}");
            }
        }
    }
}

#[cfg(target_os = "macos")]
mod mac {
    use super::Process;
    use std::ffi::c_void;

    const PROC_PIDTBSDINFO: i32 = 3;
    const PROC_PIDVNODEPATHINFO: i32 = 9;
    const CTL_KERN: i32 = 1;
    const KERN_ARGMAX: i32 = 8;
    const KERN_PROCARGS2: i32 = 49;

    // libSystem.
    extern "C" {
        fn proc_pidpath(pid: i32, buffer: *mut c_void, size: u32) -> i32;
        fn proc_pidinfo(pid: i32, flavor: i32, arg: u64, buffer: *mut c_void, size: i32) -> i32;
        fn getsid(pid: i32) -> i32;
        fn sysctl(name: *mut i32, namelen: u32, oldp: *mut c_void, oldlenp: *mut usize, newp: *mut c_void, newlen: usize) -> i32;
    }

    /// `struct proc_vnodepathinfo` of <sys/proc_info.h>: the working directory and the root,
    /// each a `vnode_info` (152 bytes) and then its path.
    const VNODE_INFO: usize = 152;
    const VNODE_PATH: usize = VNODE_INFO + 1024;

    #[repr(C, align(8))]
    struct VnodePaths([u8; 2 * VNODE_PATH]);

    /// The process's working directory.
    fn cwd(pid: i32) -> Option<String> {
        let mut paths = VnodePaths([0; 2 * VNODE_PATH]);
        let size = std::mem::size_of::<VnodePaths>() as i32;
        // Safe: the buffer is as long as the size given, and the kernel writes at most that.
        let got = unsafe { proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, (&mut paths as *mut VnodePaths).cast(), size) };
        if got != size {
            return None;
        }
        let path = &paths.0[VNODE_INFO..VNODE_PATH];
        let path = &path[..path.iter().position(|b| *b == 0)?];
        std::str::from_utf8(path).ok().filter(|p| p.starts_with('/')).map(String::from)
    }

    pub fn invocation(pid: u32) -> Option<super::Invocation> {
        let pid = i32::try_from(pid).ok()?;
        // The kernel hands the arguments over together with the environment, in a block of
        // at most `kern.argmax` bytes. A smaller buffer would not get a part of it.
        let mut argmax: i32 = 0;
        let mut len = std::mem::size_of::<i32>();
        // Safe: two names, an int to write to and its length; nothing is set.
        let ok = unsafe { sysctl([CTL_KERN, KERN_ARGMAX].as_mut_ptr(), 2, (&mut argmax as *mut i32).cast(), &mut len, std::ptr::null_mut(), 0) };
        let argmax = usize::try_from(argmax).ok().filter(|n| ok == 0 && (4..=16 << 20).contains(n))?;
        let mut block = vec![0u8; argmax];
        let mut len = block.len();
        // Safe: the buffer is as long as the length given, and the kernel writes at most that.
        let ok = unsafe { sysctl([CTL_KERN, KERN_PROCARGS2, pid].as_mut_ptr(), 3, block.as_mut_ptr().cast(), &mut len, std::ptr::null_mut(), 0) };
        if ok != 0 || len > block.len() {
            return None;
        }
        let parsed = super::procargs(&block[..len]);
        // The block holds the environment too: it is wiped, not just let go, and the wipe
        // is one the compiler may not leave out.
        block.fill(0);
        std::hint::black_box(&mut block);
        let (argv, truncated) = parsed?;
        Some(super::Invocation { argv, truncated, cwd: cwd(pid) })
    }

    /// `struct proc_bsdinfo` of <sys/proc_info.h>, as far as Beacon reads it.
    #[repr(C)]
    struct BsdInfo {
        flags: u32,
        status: u32,
        xstatus: u32,
        pid: u32,
        ppid: u32,
        uid: u32,
        gid: u32,
        ruid: u32,
        rgid: u32,
        svuid: u32,
        svgid: u32,
        rfu_1: u32,
        comm: [u8; 16],
        name: [u8; 32],
        nfiles: u32,
        pgid: u32,
        pjobc: u32,
        e_tdev: u32,
        e_tpgid: u32,
        nice: i32,
        start_tvsec: u64,
        start_tvusec: u64,
    }

    pub fn process(pid: u32) -> Option<Process> {
        let pid = i32::try_from(pid).ok()?;
        let mut path = vec![0u8; 4096];
        // Safe: the buffer is as long as the size given, and the kernel writes at most that.
        let n = unsafe { proc_pidpath(pid, path.as_mut_ptr().cast(), path.len() as u32) };
        if n <= 0 {
            return None;
        }
        path.truncate(n as usize);
        // Safe: an all-zero BsdInfo is valid (integers only); the kernel fills at most `size`.
        let mut info: BsdInfo = unsafe { std::mem::zeroed() };
        let size = std::mem::size_of::<BsdInfo>() as i32;
        let got = unsafe { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, (&mut info as *mut BsdInfo).cast(), size) };
        if got != size || info.pid != pid as u32 {
            return None;
        }
        let path = String::from_utf8_lossy(&path).into_owned();
        Some(Process {
            name: super::program_name(&path).to_string(),
            path,
            uid: info.uid,
            ppid: info.ppid,
            pgid: info.pgid,
            // Safe: getsid takes a number and touches no memory of ours. -1: it can't say.
            sid: u32::try_from(unsafe { getsid(pid) }).unwrap_or(0),
            // Without a terminal the device is NODEV and the group 0.
            tty_pgid: (info.e_tdev != u32::MAX && info.e_tpgid != 0).then_some(info.e_tpgid),
        })
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn the_struct_matches_the_kernels() {
            // sizeof(struct proc_bsdinfo) on every macOS Beacon supports.
            assert_eq!(std::mem::size_of::<BsdInfo>(), 136);
        }

        #[test]
        fn this_process_is_read_as_itself() {
            let me = process(std::process::id()).expect("this process");
            assert_eq!(me.uid, crate::platform::user_id());
            assert!(me.path.starts_with('/'), "{}", me.path);
            assert!(!me.name.is_empty() && me.path.ends_with(&format!("/{}", me.name)), "{me:?}");
            assert!(me.ppid > 0 && me.pgid > 0, "{me:?}");
            assert!(process(0x7fff_fff0).is_none());
        }

        #[test]
        fn a_child_is_read_with_the_arguments_it_was_started_with_and_its_folder() {
            use std::process::Stdio;
            let here = std::env::temp_dir().canonicalize().unwrap();
            // A shell that waits for a line, started with arguments of every awkward kind.
            let args = ["-c", "read line; :", "two words", "", "it's \"quoted\"", "TOKEN=in-an-argument"];
            let mut child = crate::tools::command("sh").unwrap().args(args).current_dir(&here).env("BEACON_TEST_SECRET", "never-read-out").stdin(Stdio::piped()).spawn().unwrap();
            let read = invocation(child.id());
            let me = process(child.id()).unwrap();
            drop(child.stdin.take());
            child.wait().unwrap();
            let read = read.expect("the child's arguments");
            let argv: Vec<String> = read.argv.iter().map(|a| String::from_utf8(a.clone()).unwrap()).collect();
            assert!(argv[0].ends_with("sh") && me.path.ends_with("sh"), "the program's own name first: {argv:?}");
            assert_eq!(argv[1..], args);
            assert!(!read.truncated);
            assert_eq!(read.cwd.as_deref(), here.to_str());
            // The environment stands right behind the arguments in what the kernel gives;
            // none of it comes out.
            assert!(!format!("{read:?}").contains("never-read-out") && !format!("{read:?}").contains("BEACON_TEST_SECRET"));
            // A process that has ended, and one that never was.
            assert!(invocation(child.id()).is_none() && invocation(0x7fff_fff0).is_none());
        }

        /// What stands behind a child's arguments in the kernel's block.
        const MARKER: &str = "BEACON_ENV_MARKER_never_read_out";

        #[test]
        fn a_child_started_under_any_name_gives_its_arguments_and_nothing_of_its_environment() {
            use std::os::unix::process::CommandExt;
            let dir = std::env::temp_dir().join(format!("pf-argv0-{}", std::process::id()));
            std::fs::create_dir_all(&dir).unwrap();
            // The program's path in every length around the boundary the arguments are
            // aligned to, and its own name empty, plain, with spaces and long.
            for extra in 0..9 {
                let program = dir.join(format!("s{}", "x".repeat(extra)));
                std::os::unix::fs::symlink("/bin/sleep", &program).unwrap();
                for name in ["", "sleep", "two words", "a-name-longer-than-eight-bytes"] {
                    let mut command = crate::tools::command(&program).unwrap();
                    let mut child = command.arg0(name).arg("30").env_clear().env("FIRST", MARKER).env("SECOND", MARKER).spawn().unwrap();
                    let read = invocation(child.id());
                    child.kill().unwrap();
                    child.wait().unwrap();
                    let read = read.unwrap_or_else(|| panic!("{program:?} as {name:?}"));
                    assert_eq!((read.argv, read.truncated), (vec![name.as_bytes().to_vec(), b"30".to_vec()], false), "{program:?} as {name:?}");
                }
            }
            std::fs::remove_dir_all(dir).unwrap();
        }

        #[test]
        fn a_child_is_read_with_its_parent_and_its_group() {
            let mut child = crate::tools::command("sleep").unwrap().arg("30").spawn().unwrap();
            let p = process(child.id()).expect("the child");
            child.kill().unwrap();
            child.wait().unwrap();
            assert_eq!((p.name.as_str(), p.ppid), ("sleep", std::process::id()));
            // It was started without a group of its own, so it is in this process's.
            assert_eq!(p.pgid, process(std::process::id()).unwrap().pgid);
            assert!(p.sid > 0 && p.sid == process(std::process::id()).unwrap().sid, "{p:?}");
        }
    }
}

// MARK: Connections

/// A connection to a server on this computer.
pub type LocalStream = tokio::net::UnixStream;

/// Connects to the server that listens on the socket at `path`.
pub async fn connect_local(path: &Path) -> std::io::Result<LocalStream> {
    tokio::net::UnixStream::connect(path).await
}

/// A listener on `addr`, for a port share (share.rs). The address is taken only when nothing
/// else has it: no address reuse is asked for, so a port that a server holds on every address
/// of this computer is refused here instead of taken from it. The system probes a connection
/// that has gone quiet (keepalive), so one whose other end vanished ends by itself.
pub async fn bind_tcp(addr: std::net::SocketAddr) -> std::io::Result<tokio::net::TcpListener> {
    let socket = if addr.is_ipv4() { tokio::net::TcpSocket::new_v4()? } else { tokio::net::TcpSocket::new_v6()? };
    socket.set_keepalive(true)?;
    socket.bind(addr)?;
    socket.listen(128)
}

/// Whether a share may listen on the dev server's own port number when that is free on the
/// tailnet address. On macOS a server that later asks for the number on every address still
/// gets it (checked: the bind succeeds, and each keeps its own address). On Linux it would
/// be refused while the share has the number on one address, so there a share always takes
/// a port the system picks.
#[cfg(target_os = "macos")]
pub const SAME_PORT: bool = true;
#[cfg(target_os = "linux")]
pub const SAME_PORT: bool = false;

/// How a quiet connection of a share is probed: after `KEEPALIVE_IDLE` seconds without a
/// byte, every `KEEPALIVE_EVERY` seconds, and it ends after `KEEPALIVE_TRIES` probes without
/// an answer. A phone that vanished is noticed in about a minute and a half.
pub const KEEPALIVE_IDLE: u32 = 60;
pub const KEEPALIVE_EVERY: u32 = 10;
pub const KEEPALIVE_TRIES: u32 = 3;

mod sockopt {
    #[cfg(target_os = "macos")]
    pub const NAMES: (i32, i32, i32, i32, i32) = (0xffff, 0x0008, 0x10, 0x101, 0x102);
    #[cfg(target_os = "linux")]
    pub const NAMES: (i32, i32, i32, i32, i32) = (1, 9, 4, 5, 6);
    pub const TCP: i32 = 6;

    extern "C" {
        pub fn setsockopt(fd: i32, level: i32, name: i32, value: *const std::ffi::c_void, len: u32) -> i32;
        #[cfg(test)]
        pub fn getsockopt(fd: i32, level: i32, name: i32, value: *mut std::ffi::c_void, len: *mut u32) -> i32;
    }
}

/// Turns the probing above on for one connection.
pub fn keep_alive(stream: &tokio::net::TcpStream) -> std::io::Result<()> {
    use std::os::fd::AsRawFd;
    let (socket, keepalive, idle, every, tries) = sockopt::NAMES;
    for (level, name, value) in [(socket, keepalive, 1), (sockopt::TCP, idle, KEEPALIVE_IDLE), (sockopt::TCP, every, KEEPALIVE_EVERY), (sockopt::TCP, tries, KEEPALIVE_TRIES)] {
        let value = value as i32;
        // Safe: the descriptor is the open stream's, and the value is an int of the length given.
        if unsafe { sockopt::setsockopt(stream.as_raw_fd(), level, name, (&value as *const i32).cast(), 4) } != 0 {
            return Err(std::io::Error::last_os_error());
        }
    }
    Ok(())
}

/// How many files and sockets Beacon asks to be allowed open at once. A service starts
/// with as few as 256; the shares alone can hold 136 (64 connections, each with its
/// connection on to the dev server, and 8 listeners).
pub const FD_LIMIT: u64 = 1024;

/// Raises this process's limit of open files to `FD_LIMIT`, or as near as the system lets
/// it. Returns the limit as it is afterwards; None when the system would not say. It never
/// lowers a limit, and a system that refuses is left as it was.
#[cfg(target_pointer_width = "64")]
pub fn raise_fd_limit() -> Option<u64> {
    #[repr(C)]
    struct Limit {
        soft: u64,
        hard: u64,
    }
    #[cfg(target_os = "macos")]
    const NOFILE: i32 = 8;
    #[cfg(target_os = "linux")]
    const NOFILE: i32 = 7;
    extern "C" {
        fn getrlimit(resource: i32, limit: *mut Limit) -> i32;
        fn setrlimit(resource: i32, limit: *const Limit) -> i32;
    }
    let mut limit = Limit { soft: 0, hard: 0 };
    // Safe: the struct is the system's `rlimit` on a 64-bit system, and is ours to write to.
    if unsafe { getrlimit(NOFILE, &mut limit) } != 0 {
        return None;
    }
    let wanted = FD_LIMIT.min(limit.hard);
    if limit.soft >= wanted {
        return Some(limit.soft);
    }
    let raised = Limit { soft: wanted, hard: limit.hard };
    // Safe: as above; the hard limit is left as it is.
    Some(if unsafe { setrlimit(NOFILE, &raised) } == 0 { wanted } else { limit.soft })
}

#[cfg(not(target_pointer_width = "64"))]
pub fn raise_fd_limit() -> Option<u64> {
    None
}

// MARK: Tailscale and listening ports

/// Where the regular Tailscale client's command line is, in the order it is looked for: a
/// full path, or the name of a system tool (tools.rs).
#[cfg(target_os = "macos")]
pub const TAILSCALE: [&str; 3] = ["/Applications/Tailscale.app/Contents/MacOS/Tailscale", "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale"];
#[cfg(target_os = "linux")]
pub const TAILSCALE: [&str; 2] = ["tailscale", "/usr/local/bin/tailscale"];

/// The system tool that names the process listening on TCP `port`, and its arguments: `lsof`
/// on macOS, `ss` on Linux. Both answer for this user's own processes without more rights.
#[cfg(target_os = "macos")]
pub fn listener_query(port: u16) -> (&'static str, Vec<String>) {
    ("lsof", vec!["-nP".into(), format!("-iTCP:{port}"), "-sTCP:LISTEN".into(), "-Fp".into()])
}
#[cfg(target_os = "linux")]
pub fn listener_query(port: u16) -> (&'static str, Vec<String>) {
    ("ss", vec!["-H".into(), "-ltnp".into(), "sport".into(), "=".into(), format!(":{port}")])
}

/// The first process id in what `listener_query`'s tool printed.
#[cfg(target_os = "macos")]
pub fn listener_pid(output: &str) -> Option<u32> {
    listeners::lsof(output)
}
#[cfg(target_os = "linux")]
pub fn listener_pid(output: &str) -> Option<u32> {
    listeners::ss(output)
}

/// What the two tools print, read apart from running them so both are tested on every system.
mod listeners {
    /// `lsof -Fp`: one field per line, a process id as `p<pid>`.
    #[cfg(any(target_os = "macos", test))]
    pub fn lsof(output: &str) -> Option<u32> {
        output.lines().find_map(|l| l.strip_prefix('p')?.parse().ok()).filter(|pid| *pid > 0)
    }

    /// `ss -ltnp`: one socket per line, ending in `users:(("node",pid=4242,fd=23))`.
    #[cfg(any(target_os = "linux", test))]
    pub fn ss(output: &str) -> Option<u32> {
        output.lines().find_map(|l| {
            let rest = &l[l.find("users:(")?..];
            let digits = &rest[rest.find("pid=")? + 4..];
            digits[..digits.find(|c: char| !c.is_ascii_digit()).unwrap_or(digits.len())].parse().ok()
        }).filter(|pid| *pid > 0)
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn the_listening_process_is_read_from_what_each_tool_prints() {
            assert_eq!(lsof("p4242\nf23\n"), Some(4242));
            // Two processes hold the socket (a server and its worker): the first one listed.
            assert_eq!(lsof("p4242\nf23\np4250\nf23\n"), Some(4242));
            for none in ["", "\n", "f23\n", "px\n", "p0\n", "4242\n"] {
                assert_eq!(lsof(none), None, "{none:?}");
            }
            let line = "LISTEN 0      511        127.0.0.1:3000       0.0.0.0:*    users:((\"node\",pid=4242,fd=23))\n";
            assert_eq!(ss(line), Some(4242));
            assert_eq!(ss("LISTEN 0 511 *:3000 *:* users:((\"next-server (v1\",pid=77,fd=20),(\"node\",pid=78,fd=20))\n"), Some(77));
            // A socket of another user is listed without its process.
            for none in ["", "LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\n", "users:((\"x\",pid=,fd=1))", "users:((\"x\",pid=0,fd=1))", "pid=4242"] {
                assert_eq!(ss(none), None, "{none:?}");
            }
        }
    }
}

// MARK: Stopping

/// The signals that ask this program to stop: SIGINT and SIGTERM.
pub struct StopSignal {
    interrupt: tokio::signal::unix::Signal,
    terminate: tokio::signal::unix::Signal,
}

/// Starts listening for the signals to stop. From then on they no longer end the program by
/// themselves. Needs the runtime.
pub fn stop_signal() -> std::io::Result<StopSignal> {
    use tokio::signal::unix::{signal, SignalKind};
    match (signal(SignalKind::interrupt()), signal(SignalKind::terminate())) {
        (Ok(interrupt), Ok(terminate)) => Ok(StopSignal { interrupt, terminate }),
        (Err(e), _) | (_, Err(e)) => Err(e),
    }
}

impl StopSignal {
    /// Returns when either signal came.
    pub async fn wait(&mut self) {
        tokio::select! {
            _ = self.interrupt.recv() => {}
            _ = self.terminate.recv() => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    /// What the macOS kernel gives for a process: the count, the path, NULs up to a multiple
    /// of 8 bytes, the arguments, then the environment.
    fn block(count: i32, path: &str, args: &[&[u8]], env: &[&str]) -> Vec<u8> {
        let mut b = count.to_ne_bytes().to_vec();
        b.extend_from_slice(path.as_bytes());
        b.resize(4 + (path.len() + 1).div_ceil(8) * 8, 0);
        for part in args.iter().copied().chain(env.iter().map(|e| e.as_bytes())) {
            b.extend_from_slice(part);
            b.push(0);
        }
        b
    }

    #[test]
    fn the_kernels_block_gives_the_arguments_and_never_the_environment() {
        let env = ["API_TOKEN=secret-in-the-environment", "PATH=/usr/bin"];
        let args: [&[u8]; 6] = [b"node", b"/app/node_modules/.bin/next", b"dev", b"--name=two words", b"", b"\xff\xfe"];
        let (argv, truncated) = procargs(&block(6, "/usr/local/bin/node", &args, &env)).unwrap();
        assert_eq!(argv, args.iter().map(|a| a.to_vec()).collect::<Vec<_>>());
        assert!(!truncated);
        // A count of none: the environment that follows is still not arguments.
        assert_eq!(procargs(&block(0, "/bin/sh", &[], &env)), Some((vec![], false)));
        // An empty first argument (a program may be started under any name, also none): it
        // is an argument, and what stands behind the last one is still the environment.
        for path in ["/bin/sleep", "/bin/sh", "/usr/bin/a", "/usr/bin/ab", "/usr/bin/abc", "/usr/bin/abcd", "/usr/bin/abcde", "/usr/bin/abcdef", "/usr/bin/abcdefg", "/usr/bin/abcdefgh"] {
            let (argv, truncated) = procargs(&block(2, path, &[b"", b"5"], &env)).unwrap();
            assert_eq!((argv, truncated), (vec![vec![], b"5".to_vec()], false), "{path}");
            let (argv, _) = procargs(&block(3, path, &[b"", b"", b""], &env)).unwrap();
            assert_eq!(argv, vec![Vec::<u8>::new(); 3], "{path}");
            let shown = format!("{:?}", procargs(&block(1, path, &[b""], &env)));
            assert!(!shown.contains("API_TOKEN") && !shown.contains("PATH="), "{shown}");
        }
        // A count larger than the arguments there are would reach into the environment
        // only as far as the block goes; a block that ends before the count is met is not
        // used at all.
        let mut short = block(3, "/bin/sh", &[b"sh", b"-c"], &[]);
        short.extend_from_slice(b"half an argu");
        assert_eq!(procargs(&short), None);
        // Padding that is not NULs: not the form this reads.
        let mut odd = block(1, "/bin/s", &[b"sh"], &env);
        odd[4 + "/bin/s".len() + 1] = b'x';
        assert_eq!(procargs(&odd), None);
        // Many more arguments than are kept: counted off, cut at the limit.
        let many: Vec<&[u8]> = vec![b"a"; crate::platform::ARGS_MAX + 50];
        let (argv, truncated) = procargs(&block(many.len() as i32, "/bin/sh", &many, &env)).unwrap();
        assert_eq!((argv.len(), truncated), (crate::platform::ARGS_MAX, true));
        // More than fits the limit.
        let big = vec![b'x'; crate::platform::ARGV_MAX];
        let (argv, truncated) = procargs(&block(3, "/bin/sh", &[b"sh", &big, b"after"], &env)).unwrap();
        assert_eq!((argv, truncated), (vec![b"sh".to_vec()], true));
        for bad in [&b""[..], b"\x01\x00", b"\xff\xff\xff\xff/bin/sh\0sh\0", b"\x01\x00\x00\x00/bin/sh-without-an-end", b"\x01\x00\x00\x00\0\0\0\0sh\0", b"\x01\x00\x00\x00/bin/sh\0"] {
            assert_eq!(procargs(bad), None, "{bad:?}");
        }
    }

    fn temp(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("pf-{tag}-{}-{}", std::process::id(), crate::util::now() as u64 % 100_000));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn mode(path: &Path) -> u32 {
        std::fs::symlink_metadata(path).unwrap().permissions().mode() & 0o7777
    }

    #[test]
    fn private_files_and_folders_are_this_users_alone_from_the_start() {
        let dir = temp("private");
        // The modes hold whatever the umask: 0600 and 0700 take nothing a umask leaves.
        let file = dir.join("new");
        create_private(&file).unwrap().write_all(b"one").unwrap();
        assert_eq!(mode(&file), 0o600);
        // Never over a file that is there, and never through a link.
        assert_eq!(create_private(&file).unwrap_err().kind(), std::io::ErrorKind::AlreadyExists);
        let link = dir.join("link");
        std::os::unix::fs::symlink(dir.join("elsewhere"), &link).unwrap();
        assert_eq!(create_private(&link).unwrap_err().kind(), std::io::ErrorKind::AlreadyExists);
        assert!(!dir.join("elsewhere").exists());

        // `open_private` makes the file private, and leaves one that is there as it is.
        let lock = dir.join("lock");
        drop(open_private(&lock).unwrap());
        assert_eq!(mode(&lock), 0o600);
        std::fs::write(&lock, "kept").unwrap();
        std::fs::set_permissions(&lock, std::fs::Permissions::from_mode(0o644)).unwrap();
        drop(open_private(&lock).unwrap());
        assert_eq!((std::fs::read_to_string(&lock).unwrap().as_str(), mode(&lock)), ("kept", 0o644));

        let folder = dir.join("folder");
        create_private_dir(&folder).unwrap();
        assert_eq!(mode(&folder), 0o700);
        assert!(create_private_dir(&folder).is_err());
        assert!(create_private_dir(&dir.join("no/parent")).is_err());

        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o664)).unwrap();
        make_private(&file).unwrap();
        assert_eq!(mode(&file), 0o600);
        make_executable(&file).unwrap();
        assert_eq!(mode(&file), 0o755);
        make_readable(&File::open(&file).unwrap()).unwrap();
        assert_eq!(mode(&file), 0o644);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_private_write_replaces_the_file_whole_through_a_temporary_one() {
        let dir = temp("write");
        let path = dir.join("made/on/the/way/config.json");
        let tmp = path.with_extension("json.tmp");
        write_private(&path, b"one").unwrap();
        assert_eq!((std::fs::read(&path).unwrap().as_slice(), mode(&path)), (&b"one"[..], 0o600));
        assert!(!tmp.exists());
        // The stamp of a file nothing wrote stays.
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        let before = file_stamp(&path).unwrap();
        assert_eq!(file_stamp(&path), Some(before));
        // A file with wider permissions is replaced by a private one: a new file, not the old
        // one written over. A temporary file left behind, with anything in it, is not in the way.
        std::fs::write(&tmp, "left behind").unwrap();
        write_private(&path, b"two").unwrap();
        assert_eq!((std::fs::read(&path).unwrap().as_slice(), mode(&path)), (&b"two"[..], 0o600));
        assert_ne!(file_stamp(&path), Some(before));
        assert!(!tmp.exists());
        // A write that fails leaves the file as it was.
        let failed = write_private_with(&path, |f| f.write_all(b"half").and(Err(std::io::Error::other("stopped"))));
        assert_eq!(failed.unwrap_err().to_string(), "stopped");
        assert_eq!(std::fs::read(&path).unwrap(), b"two");
        assert_eq!(file_stamp(&dir.join("missing")), None);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn only_a_private_file_of_the_user_is_opened() {
        let dir = temp("owned");
        let me = user_id();
        let file = dir.join("code");
        std::fs::write(&file, "abc").unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
        let (_, meta) = open_owned_private(&file, me).unwrap();
        assert_eq!(meta.len(), 3);
        assert!(open_owned_private(&file, me + 1).is_none());
        for wide in [0o640, 0o604, 0o610, 0o601, 0o620, 0o602] {
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(wide)).unwrap();
            assert!(open_owned_private(&file, me).is_none(), "{wide:o}");
        }
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o400)).unwrap();
        assert!(open_owned_private(&file, me).is_some());
        let link = dir.join("link");
        std::os::unix::fs::symlink(&file, &link).unwrap();
        assert!(open_owned_private(&link, me).is_none());
        assert!(open_owned_private(&dir, me).is_none());
        assert!(open_owned_private(&dir.join("missing"), me).is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_socket_is_told_from_a_file_and_from_nothing() {
        let dir = temp("sock");
        let me = user_id();
        let sock = dir.join("s");
        let _listener = std::os::unix::net::UnixListener::bind(&sock).unwrap();
        assert_eq!(check_socket(&sock, me), SocketCheck::Ours);
        assert_eq!(check_socket(&sock, me + 1), SocketCheck::OtherUser);
        std::fs::write(dir.join("file"), "").unwrap();
        assert_eq!(check_socket(&dir.join("file"), me), SocketCheck::NotSocket);
        assert_eq!(check_socket(&dir, me), SocketCheck::NotSocket);
        assert_eq!(check_socket(&dir.join("missing"), me), SocketCheck::Missing);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_process_is_alive_until_it_has_ended() {
        assert!(process_alive(u64::from(std::process::id())));
        let mut child = crate::tools::command("sh").unwrap().args(["-c", "exit 0"]).spawn().unwrap();
        let pid = u64::from(child.id());
        assert!(process_alive(pid));
        child.wait().unwrap();
        assert!(!process_alive(pid));
    }

    #[test]
    fn the_runtime_folder_is_a_users_own() {
        let dir = fallback_runtime_dir();
        let uid = dir.strip_prefix("/run/user").unwrap().to_str().unwrap();
        assert!(uid.parse::<u32>().is_ok(), "{dir:?}");
        if !Path::new("/proc/self").exists() {
            assert_eq!(uid, "1000");
        }
    }

    #[tokio::test]
    async fn a_local_server_is_reached_and_a_listener_is_made() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let dir = temp("conn");
        let sock = dir.join("s");
        assert!(connect_local(&sock).await.is_err());
        let server = tokio::net::UnixListener::bind(&sock).unwrap();
        let mut client: LocalStream = connect_local(&sock).await.unwrap();
        let (mut served, _) = server.accept().await.unwrap();
        client.write_all(b"hi").await.unwrap();
        let mut got = [0u8; 2];
        served.read_exact(&mut got).await.unwrap();
        assert_eq!(&got, b"hi");

        let listener = bind_tcp("127.0.0.1:0".parse().unwrap()).await.unwrap();
        let addr = listener.local_addr().unwrap();
        assert!(addr.ip().is_loopback() && addr.port() != 0);
        let _dialed = tokio::net::TcpStream::connect(addr).await.unwrap();
        listener.accept().await.unwrap();
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_connection_is_probed_after_a_minute_of_silence() {
        use std::os::fd::AsRawFd;
        let listener = bind_tcp("127.0.0.1:0".parse().unwrap()).await.unwrap();
        let _dialed = tokio::net::TcpStream::connect(listener.local_addr().unwrap()).await.unwrap();
        let (taken, _) = listener.accept().await.unwrap();
        keep_alive(&taken).unwrap();
        let (socket, keepalive, idle, every, tries) = sockopt::NAMES;
        let read = |level: i32, name: i32| {
            let (mut value, mut len) = (0i32, 4u32);
            // Safe: an int to write to, and its length.
            assert_eq!(unsafe { sockopt::getsockopt(taken.as_raw_fd(), level, name, (&mut value as *mut i32).cast(), &mut len) }, 0);
            value
        };
        assert!(read(socket, keepalive) != 0);
        assert_eq!((read(sockopt::TCP, idle), read(sockopt::TCP, every), read(sockopt::TCP, tries)), (60, 10, 3));
    }

    #[test]
    fn the_limit_of_open_files_is_raised_and_never_lowered() {
        let first = raise_fd_limit();
        if cfg!(target_pointer_width = "64") {
            let now = first.expect("the system says its limit");
            assert!(now > 0);
            // Asking again changes nothing.
            assert_eq!(raise_fd_limit(), Some(now));
        }
    }

    #[tokio::test]
    async fn a_port_held_on_every_address_is_not_free_on_one_and_stays_free_for_whoever_asks_later() {
        // A dev server told to serve the network listens on every address, IPv4 or both.
        for everywhere in ["0.0.0.0:0", "[::]:0"] {
            let Ok(held) = tokio::net::TcpListener::bind(everywhere).await else { continue };
            let port = held.local_addr().unwrap().port();
            let one: std::net::SocketAddr = format!("127.0.0.1:{port}").parse().unwrap();
            // `[::]` also holds the IPv4 addresses unless the system was told otherwise.
            if everywhere == "0.0.0.0:0" || SAME_PORT {
                assert_eq!(bind_tcp(one).await.map(|_| ()).map_err(|e| e.kind()), Err(std::io::ErrorKind::AddrInUse), "{everywhere}");
            }
        }
        // The other way round, where a share may take the server's own number: a server
        // that starts later and asks for it on every address still gets it.
        if SAME_PORT {
            let ours = bind_tcp("127.0.0.1:0".parse().unwrap()).await.unwrap();
            let port = ours.local_addr().unwrap().port();
            assert!(tokio::net::TcpListener::bind(("0.0.0.0", port)).await.is_ok());
        }
    }

    #[tokio::test]
    async fn a_listener_never_takes_a_port_that_something_else_holds() {
        let held = bind_tcp("127.0.0.1:0".parse().unwrap()).await.unwrap();
        let addr = held.local_addr().unwrap();
        assert_eq!(bind_tcp(addr).await.unwrap_err().kind(), std::io::ErrorKind::AddrInUse);
        // Nor one a server made the usual way, with address reuse, listens on.
        let usual = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        assert_eq!(bind_tcp(usual.local_addr().unwrap()).await.unwrap_err().kind(), std::io::ErrorKind::AddrInUse);
    }
}
