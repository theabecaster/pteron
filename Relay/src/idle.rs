//! What the operating system says about the person at this computer: the idle time, whether
//! the screen is locked or another user has it, whether the display sleeps, the computer's
//! sleep and wake, and the program behind a process id. `desk.rs` decides what it means.
//!
//! macOS only, through the system's own frameworks (no crate). Each reading takes microseconds
//! and asks nothing of the person: no permission prompt. On Linux every reading is unknown,
//! which means nobody is at the desk, so pushes go out as before.
//!
//! Nothing here is called while the desk switch is off.

use crate::desk::{Process, Reading};

/// The readings Beacon takes, so tests can stand in for the computer.
pub trait Sense: Send + Sync {
    fn read(&self) -> Reading;
    fn process(&self, pid: u32) -> Option<Process>;
    /// The computer's sleep and wake (`watch_power`). None: not watched.
    fn watch_power(&self) -> Option<tokio::sync::mpsc::UnboundedReceiver<Power>> {
        None
    }
}

/// This computer.
pub struct System;

impl Sense for System {
    fn read(&self) -> Reading {
        #[cfg(target_os = "macos")]
        {
            mac::read()
        }
        #[cfg(not(target_os = "macos"))]
        {
            Reading::default()
        }
    }

    fn process(&self, pid: u32) -> Option<Process> {
        #[cfg(target_os = "macos")]
        {
            mac::process(pid)
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = pid;
            None
        }
    }

    fn watch_power(&self) -> Option<tokio::sync::mpsc::UnboundedReceiver<Power>> {
        watch_power()
    }
}

/// The computer's sleep and wake. Only macOS sends them.
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
pub enum Power {
    /// It is about to sleep. Send on the channel (or drop it) once the held pushes have gone;
    /// sleep is allowed then, or after `desk::SLEEP_GRACE` at the latest.
    WillSleep(std::sync::mpsc::SyncSender<()>),
    /// It woke up.
    PoweredOn,
}

/// Starts listening for sleep and wake, on a dispatch queue of its own (no run loop). Only the
/// first call in a process gets the events; None on Linux, after the first call, or when macOS
/// refused.
pub fn watch_power() -> Option<tokio::sync::mpsc::UnboundedReceiver<Power>> {
    #[cfg(target_os = "macos")]
    {
        mac::watch_power()
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

#[cfg(target_os = "macos")]
mod mac {
    use super::Power;
    use crate::desk::{Process, Reading, Session, SLEEP_GRACE};
    use std::ffi::{c_char, c_void};
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::sync::OnceLock;

    type CFTypeRef = *const c_void;
    type IONotificationPortRef = *mut c_void;

    const UTF8: u32 = 0x0800_0100;
    const SINT64: isize = 4;
    const PROC_PIDTBSDINFO: i32 = 3;
    // iokit_common_msg(…): sys_iokit | sub_iokit_common | message.
    const CAN_SYSTEM_SLEEP: u32 = 0xE000_0270;
    const SYSTEM_WILL_SLEEP: u32 = 0xE000_0280;
    const SYSTEM_HAS_POWERED_ON: u32 = 0xE000_0300;

    #[link(name = "CoreFoundation", kind = "framework")]
    extern "C" {
        fn CFStringCreateWithCString(alloc: CFTypeRef, s: *const c_char, encoding: u32) -> CFTypeRef;
        fn CFDictionaryGetValue(dict: CFTypeRef, key: CFTypeRef) -> CFTypeRef;
        fn CFGetTypeID(cf: CFTypeRef) -> usize;
        fn CFNumberGetTypeID() -> usize;
        fn CFBooleanGetTypeID() -> usize;
        fn CFDataGetTypeID() -> usize;
        fn CFNumberGetValue(n: CFTypeRef, kind: isize, out: *mut c_void) -> u8;
        fn CFBooleanGetValue(b: CFTypeRef) -> u8;
        fn CFDataGetLength(d: CFTypeRef) -> isize;
        fn CFDataGetBytePtr(d: CFTypeRef) -> *const u8;
        fn CFRelease(cf: CFTypeRef);
    }

    #[link(name = "IOKit", kind = "framework")]
    extern "C" {
        fn IOServiceMatching(name: *const c_char) -> CFTypeRef;
        fn IOServiceGetMatchingService(main_port: u32, matching: CFTypeRef) -> u32;
        fn IORegistryEntryCreateCFProperty(entry: u32, key: CFTypeRef, alloc: CFTypeRef, options: u32) -> CFTypeRef;
        fn IOObjectRelease(object: u32) -> i32;
        fn IORegisterForSystemPower(
            refcon: *mut c_void,
            port: *mut IONotificationPortRef,
            callback: extern "C" fn(*mut c_void, u32, u32, *mut c_void),
            notifier: *mut u32,
        ) -> u32;
        fn IONotificationPortSetDispatchQueue(port: IONotificationPortRef, queue: *mut c_void);
        fn IOAllowPowerChange(root: u32, id: isize) -> i32;
    }

    #[link(name = "CoreGraphics", kind = "framework")]
    extern "C" {
        fn CGSessionCopyCurrentDictionary() -> CFTypeRef;
        fn CGMainDisplayID() -> u32;
        fn CGDisplayIsAsleep(display: u32) -> u32;
    }

    // libSystem.
    extern "C" {
        fn dispatch_queue_create(label: *const c_char, attr: *const c_void) -> *mut c_void;
        fn proc_pidpath(pid: i32, buffer: *mut c_void, size: u32) -> i32;
        fn proc_pidinfo(pid: i32, flavor: i32, arg: u64, buffer: *mut c_void, size: i32) -> i32;
    }

    /// A CF object this code made or copied, released when it goes.
    struct Owned(CFTypeRef);

    impl Owned {
        fn new(p: CFTypeRef) -> Option<Owned> {
            (!p.is_null()).then_some(Owned(p))
        }
    }

    impl Drop for Owned {
        fn drop(&mut self) {
            // Safe: a non-null object this code owns one reference to.
            unsafe { CFRelease(self.0) }
        }
    }

    fn cf_string(s: &std::ffi::CStr) -> Option<Owned> {
        // Safe: a NUL-terminated string; the result is owned and released by `Owned`.
        Owned::new(unsafe { CFStringCreateWithCString(std::ptr::null(), s.as_ptr(), UTF8) })
    }

    /// A CFBoolean, or None for anything else.
    fn boolean(v: CFTypeRef) -> Option<bool> {
        // Safe: `v` is checked to be a CFBoolean before it is read as one.
        unsafe { (!v.is_null() && CFGetTypeID(v) == CFBooleanGetTypeID()).then(|| CFBooleanGetValue(v) != 0) }
    }

    /// Seconds since the last input: IOHIDSystem's `HIDIdleTime`, in nanoseconds.
    fn idle() -> Option<f64> {
        // Safe: each object is checked for null, its type checked before it is read, and
        // released (IOObjectRelease, `Owned`). IOServiceGetMatchingService consumes `matching`.
        unsafe {
            let matching = IOServiceMatching(c"IOHIDSystem".as_ptr());
            if matching.is_null() {
                return None;
            }
            let service = IOServiceGetMatchingService(0, matching);
            if service == 0 {
                return None;
            }
            let key = cf_string(c"HIDIdleTime");
            let value = key.and_then(|k| Owned::new(IORegistryEntryCreateCFProperty(service, k.0, std::ptr::null(), 0)));
            IOObjectRelease(service);
            let value = value?;
            let id = CFGetTypeID(value.0);
            let mut ns: i64 = 0;
            if id == CFNumberGetTypeID() {
                if CFNumberGetValue(value.0, SINT64, (&mut ns as *mut i64).cast()) == 0 {
                    return None;
                }
            } else if id == CFDataGetTypeID() && CFDataGetLength(value.0) == 8 {
                let mut b = [0u8; 8];
                std::ptr::copy_nonoverlapping(CFDataGetBytePtr(value.0), b.as_mut_ptr(), 8);
                ns = i64::from_ne_bytes(b);
            } else {
                return None;
            }
            (ns >= 0).then(|| ns as f64 / 1e9)
        }
    }

    /// The login session: locked, and whether this user has the console. None when the window
    /// server gives no session (no GUI login, or a process outside it).
    fn session() -> Option<Session> {
        // Safe: the copied dictionary is owned and released; values are type-checked.
        unsafe {
            let dict = Owned::new(CGSessionCopyCurrentDictionary())?;
            let get = |name: &std::ffi::CStr| cf_string(name).map(|k| CFDictionaryGetValue(dict.0, k.0)).unwrap_or(std::ptr::null());
            // The lock key is there only while the screen is locked.
            let locked = boolean(get(c"CGSSessionScreenIsLocked")).unwrap_or(false);
            // An unreadable console key counts as someone else's console.
            let on_console = boolean(get(c"kCGSSessionOnConsoleKey")).unwrap_or(false);
            Some(Session { locked, on_console })
        }
    }

    fn display_asleep() -> Option<bool> {
        // Safe: plain calls on the main display's id; neither touches memory of ours.
        unsafe {
            let display = CGMainDisplayID();
            (display != 0).then(|| CGDisplayIsAsleep(display) != 0)
        }
    }

    pub fn read() -> Reading {
        Reading { idle: idle(), session: session(), display_asleep: display_asleep() }
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

    struct Watch {
        events: tokio::sync::mpsc::UnboundedSender<Power>,
        root: AtomicU32,
    }

    static WATCH: OnceLock<Watch> = OnceLock::new();

    /// Runs on the private dispatch queue. "Can sleep" is allowed at once. "Will sleep" waits
    /// for the relay to send what it holds, `SLEEP_GRACE` at most, then allows the sleep.
    extern "C" fn on_power(_refcon: *mut c_void, _service: u32, message: u32, argument: *mut c_void) {
        let Some(w) = WATCH.get() else { return };
        let root = w.root.load(Ordering::SeqCst);
        match message {
            CAN_SYSTEM_SLEEP => {
                // Safe: answers the notification this callback was given, on the root port.
                unsafe { IOAllowPowerChange(root, argument as isize) };
            }
            SYSTEM_WILL_SLEEP => {
                let (done, wait) = std::sync::mpsc::sync_channel(1);
                if w.events.send(Power::WillSleep(done)).is_ok() {
                    let _ = wait.recv_timeout(SLEEP_GRACE);
                }
                // Safe: as above.
                unsafe { IOAllowPowerChange(root, argument as isize) };
            }
            SYSTEM_HAS_POWERED_ON => {
                let _ = w.events.send(Power::PoweredOn);
            }
            _ => {}
        }
    }

    pub fn watch_power() -> Option<tokio::sync::mpsc::UnboundedReceiver<Power>> {
        let (tx, rx) = tokio::sync::mpsc::unbounded_channel();
        WATCH.set(Watch { events: tx, root: AtomicU32::new(0) }).ok()?;
        let mut port: IONotificationPortRef = std::ptr::null_mut();
        let mut notifier: u32 = 0;
        // Safe: out-pointers to locals; the callback is a plain function that only reads
        // WATCH, which lives for the whole process. The queue is never released.
        unsafe {
            let root = IORegisterForSystemPower(std::ptr::null_mut(), &mut port, on_power, &mut notifier);
            if root == 0 || port.is_null() {
                return None;
            }
            WATCH.get()?.root.store(root, Ordering::SeqCst);
            let queue = dispatch_queue_create(c"dev.abrahamgonzalez.rexduo.power".as_ptr(), std::ptr::null());
            if queue.is_null() {
                return None;
            }
            IONotificationPortSetDispatchQueue(port, queue);
        }
        Some(rx)
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
            assert_eq!(me.uid, crate::tools::uid());
            assert!(me.path.starts_with('/'), "{}", me.path);
            assert!(process(0x7fff_fff0).is_none());
        }
    }
}
