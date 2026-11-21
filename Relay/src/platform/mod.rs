//! What Beacon asks of the operating system, in one place. The rest of the program names no
//! system type or call: it asks here for a file only this user can read, whether a process is
//! alive and what started it, the connection to Rex's local server, a listener, and the signal
//! to stop.
//!
//! `unix.rs` answers for macOS and Linux. A system without a file here does not build: each
//! thing the rest of the program asks for is a name this module has to give. The pieces that
//! differ between the two systems but need no system call (the service manager, where the
//! binary is installed, the system's name) stay in their own files, each under an explicit
//! `target_os`, and where one function answers for both it matches on `OS`, so a new system
//! is a compile error at every such place until it has its answer.

#[cfg(unix)]
mod unix;
#[cfg(unix)]
pub use unix::*;

/// The systems Beacon runs on. `OS` is the one this program was built for.
#[allow(dead_code)] // a build is for one of them, so the other is never made
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Os {
    Mac,
    Linux,
}

/// A process as the kernel describes it.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Process {
    /// The program's full path. Empty when the system does not say (Linux, for a process of
    /// another user).
    pub path: String,
    /// The program's name: the last part of `path`, or the kernel's short name without one.
    pub name: String,
    pub uid: UserId,
    /// The process that started it: following it from process to process walks up the tree.
    pub ppid: u32,
    /// Its process group: what a terminal's Ctrl-C reaches as one.
    pub pgid: u32,
    /// Its session: the shell a terminal started leads one. 0 when the system does not say.
    pub sid: u32,
    /// The process group in the foreground of its terminal. None without a terminal.
    pub tty_pgid: Option<u32>,
}

/// The most bytes of one process's arguments that are read out, and the most arguments.
pub const ARGV_MAX: usize = 8 * 1024;
pub const ARGS_MAX: usize = 256;

/// How a process was started: its arguments and the folder it works in. The arguments are
/// bytes, as the system holds them; they can hold secrets, so nothing here is ever logged or
/// stored. The environment is not part of this and is never read out.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Invocation {
    /// The arguments, the program's own name first, as they are in the process's memory now:
    /// a program may have written over them since it started.
    pub argv: Vec<Vec<u8>>,
    /// True when they did not fit `ARGV_MAX` or `ARGS_MAX`, or could not be read to their
    /// end: `argv` then holds only the whole arguments that came before the cut.
    pub truncated: bool,
    /// Its working directory now. None when it can't be read.
    pub cwd: Option<String>,
}

/// Keeps the arguments that fit the two limits, and says whether any were left out. `cut`:
/// the source already ended early.
#[cfg_attr(not(unix), allow(dead_code))]
pub(crate) fn capped<'a>(args: impl Iterator<Item = &'a [u8]>, cut: bool) -> (Vec<Vec<u8>>, bool) {
    let (mut kept, mut bytes) = (vec![], 0);
    for arg in args {
        bytes += arg.len() + 1;
        if bytes > ARGV_MAX || kept.len() == ARGS_MAX {
            return (kept, true);
        }
        kept.push(arg.to_vec());
    }
    (kept, cut)
}

/// What `check_socket` found at a path.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SocketCheck {
    /// Nothing is there, or it can't be looked at.
    Missing,
    NotSocket,
    OtherUser,
    /// A socket that belongs to the user asked about.
    Ours,
}
