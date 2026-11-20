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
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Process {
    pub path: String,
    pub uid: UserId,
    /// The process that started it: following it from process to process walks up the tree.
    pub ppid: u32,
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
