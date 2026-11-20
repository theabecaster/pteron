//! macOS and Linux.

use super::{Os, Process, SocketCheck};
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

/// The program behind a process id, the user it runs as and the process that started it. None
/// when there is no such process or it can't be read. Linux does not read it yet: every
/// process is unknown there.
#[cfg(target_os = "macos")]
pub fn process(pid: u32) -> Option<Process> {
    mac::process(pid)
}

#[cfg(target_os = "linux")]
pub fn process(pid: u32) -> Option<Process> {
    let _ = pid;
    None
}

#[cfg(target_os = "macos")]
mod mac {
    use super::Process;
    use std::ffi::c_void;

    const PROC_PIDTBSDINFO: i32 = 3;

    // libSystem.
    extern "C" {
        fn proc_pidpath(pid: i32, buffer: *mut c_void, size: u32) -> i32;
        fn proc_pidinfo(pid: i32, flavor: i32, arg: u64, buffer: *mut c_void, size: i32) -> i32;
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
        (got == size && info.pid == pid as u32).then(|| Process { path: String::from_utf8_lossy(&path).into_owned(), uid: info.uid, ppid: info.ppid })
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
            assert!(process(0x7fff_fff0).is_none());
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

/// A listener on `addr`. Nothing listens yet: this is where a listener is made when Beacon
/// gets one, so what a system needs before it lets a program listen has one place.
#[allow(dead_code)] // no command listens yet
pub async fn bind_tcp(addr: std::net::SocketAddr) -> std::io::Result<tokio::net::TcpListener> {
    tokio::net::TcpListener::bind(addr).await
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
}
