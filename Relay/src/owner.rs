//! `port_owner`: who holds a listening port, and what started it.
//!
//! A dev server is often not the program a person started: `npm run dev` starts a shell that
//! starts `node`, and `node` holds the port. The phone app stops a server by sending Ctrl-C
//! into its pane, which reaches the pane's foreground process group. So before it offers
//! Stop it has to know that the port's holder is in that group, or under the pane's
//! foreground process. This says what is needed for that: the holder's process group, the
//! group in the foreground of its terminal, and the chain of processes that started it.
//!
//! For Restart the app also has to know what to type again, so each process of the chain
//! comes with the arguments it was started with and its working directory.
//!
//! It only reports. Beacon never signals a process and starts none. And it reports only
//! about this user's own processes: the chain ends where another user's process begins.
//!
//! Arguments can hold secrets (a token in a flag). They leave this module only in the
//! action's result, to the phone that asked: nothing here logs, stores or sends them
//! anywhere else, and no error names one. A process's environment is never read out.

use crate::platform::{Invocation, Process, UserId};
use serde_json::{json, Value};
use std::time::Duration;

/// The most processes of one chain.
pub const DEPTH: usize = 32;

/// How long the system's tool may take to name a port's holder.
const WAIT: Duration = Duration::from_secs(5);
/// How much it may print.
const PRINT_LIMIT: usize = 64 * 1024;

/// True when the process that listens on TCP `port` is one of the user Beacon runs as. The
/// system's tool names only this user's processes, and the one it names is read again to be
/// sure of whose it is.
pub async fn listens_as_me(port: u16) -> bool {
    let me = crate::platform::user_id();
    listener(port).await.and_then(crate::platform::process).is_some_and(|p| p.uid == me)
}

/// One process of the chain.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Link {
    pub pid: u32,
    pub ppid: u32,
    pub pgid: u32,
    pub sid: u32,
    pub name: String,
    /// The program's full path; empty when the system does not say.
    pub path: String,
    /// How it was started. None when that can't be read, or the process was no longer the
    /// same one after reading it.
    pub started: Option<Invocation>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Owner {
    /// The group in the foreground of the holder's terminal. None without a terminal.
    pub tty_pgid: Option<u32>,
    /// The holder first, then what started it, and so on up.
    pub chain: Vec<Link>,
}

/// The holder `pid` and its ancestry, as `read` describes each process. None when there is
/// no such process, or it is not `me`'s.
///
/// The chain ends at the first process, going up, that is the system's first (pid 1), can't
/// be read, belongs to another user, or was met before (a process id that was given out
/// again between two reads can make a loop), and after `DEPTH` processes at the latest.
///
/// `started` gives a process's arguments and folder. It is asked only for a process that is
/// `me`'s, and its answer is kept only when the process is still the same one afterwards (a
/// process may end, and its id be given to another, between two reads).
pub fn owner(pid: u32, me: UserId, read: &dyn Fn(u32) -> Option<Process>, started: &dyn Fn(u32) -> Option<Invocation>) -> Option<Owner> {
    let own = |pid: u32| read(pid).filter(|p| p.uid == me);
    let holder = own(pid)?;
    let tty_pgid = holder.tty_pgid;
    let mut chain: Vec<Link> = vec![];
    let mut next = Some((pid, holder));
    while let Some((pid, p)) = next.take() {
        let parent = p.ppid;
        let how = started(pid).filter(|_| own(pid).is_some_and(|again| again == p));
        chain.push(Link { pid, ppid: p.ppid, pgid: p.pgid, sid: p.sid, name: p.name, path: p.path, started: how });
        if parent > 1 && chain.len() < DEPTH && !chain.iter().any(|l| l.pid == parent) {
            next = own(parent).map(|p| (parent, p));
        }
    }
    Some(Owner { tty_pgid, chain })
}

impl Owner {
    /// The action's result.
    pub fn json(&self) -> Value {
        let holder = &self.chain[0];
        json!({
            "pid": holder.pid,
            "pgid": holder.pgid,
            "tty_foreground_pgid": self.tty_pgid,
            "foreground": self.tty_pgid == Some(holder.pgid),
            "ancestry": self.chain.iter().map(Link::json).collect::<Vec<_>>(),
        })
    }
}

impl Link {
    fn json(&self) -> Value {
        // JSON holds text: an argument that is not UTF-8 is given with U+FFFD in place of
        // what is not, and the process is marked, since typing that again is not the same.
        let lossy = self.started.as_ref().is_some_and(|s| s.argv.iter().any(|a| std::str::from_utf8(a).is_err()));
        let argv = self.started.as_ref().map(|s| s.argv.iter().map(|a| String::from_utf8_lossy(a).into_owned()).collect::<Vec<_>>());
        json!({
            "pid": self.pid,
            "ppid": self.ppid,
            "pgid": self.pgid,
            "sid": self.sid,
            "group_leader": self.pid == self.pgid,
            "session_leader": self.pid == self.sid,
            "name": self.name,
            "path": self.path,
            "argv": argv,
            "argv_lossy": lossy,
            "truncated": self.started.as_ref().is_some_and(|s| s.truncated),
            "cwd": self.started.as_ref().and_then(|s| s.cwd.clone()),
        })
    }
}

/// The process that listens on TCP `port`, asked of the system's own tool
/// (`platform::listener_query`). None when nothing of this user listens there.
pub async fn listener(port: u16) -> Option<u32> {
    let (tool, args) = crate::platform::listener_query(port);
    let mut command = crate::tools::async_command(tool)?;
    command.args(args);
    crate::platform::listener_pid(&String::from_utf8_lossy(&crate::tools::printed(command, PRINT_LIMIT, WAIT).await?))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    const ME: UserId = 501;

    fn p(name: &str, uid: UserId, ppid: u32, pgid: u32, tty_pgid: Option<u32>) -> Process {
        Process { path: format!("/usr/bin/{name}"), name: name.into(), uid, ppid, pgid, sid: 900, tty_pgid }
    }

    fn how(args: &[&[u8]], cwd: &str) -> Invocation {
        Invocation { argv: args.iter().map(|a| a.to_vec()).collect(), truncated: false, cwd: Some(cwd.into()) }
    }

    /// The chain when nothing about how the processes started can be read.
    fn ask(table: &HashMap<u32, Process>, pid: u32) -> Option<Owner> {
        owner(pid, ME, &|pid| table.get(&pid).cloned(), &|_| None)
    }

    #[test]
    fn each_process_comes_with_its_arguments_its_folder_and_what_it_leads() {
        let table = wrapper();
        let started = HashMap::from([
            (4242, how(&[b"node", b"/app/node_modules/.bin/next", b"dev"], "/app")),
            (4201, how(&[b"sh", b"-c", b"next dev --name \"two words\""], "/app")),
            (4200, how(&[b"npm", b"run", b"dev", b"", b"it's"], "/app")),
            (900, how(&[b"-zsh"], "/home/alex")),
        ]);
        let v = owner(4242, ME, &|pid| table.get(&pid).cloned(), &|pid| started.get(&pid).cloned()).unwrap().json();
        // The job the pane's shell started: it leads its process group. Its arguments are
        // an array, each as it was, the empty one too.
        assert_eq!(
            v["ancestry"][2],
            json!({"pid": 4200, "ppid": 900, "pgid": 4200, "sid": 900, "group_leader": true, "session_leader": false, "name": "npm", "path": "/usr/bin/npm",
                "argv": ["npm", "run", "dev", "", "it's"], "argv_lossy": false, "truncated": false, "cwd": "/app"})
        );
        assert_eq!(v["ancestry"][1]["argv"], json!(["sh", "-c", "next dev --name \"two words\""]));
        assert_eq!((v["ancestry"][0]["group_leader"].as_bool(), v["ancestry"][0]["argv"][1].as_str()), (Some(false), Some("/app/node_modules/.bin/next")));
        // The pane's shell leads the session.
        assert_eq!((v["ancestry"][3]["session_leader"].as_bool(), v["ancestry"][3]["group_leader"].as_bool(), v["ancestry"][3]["cwd"].as_str()), (Some(true), Some(true), Some("/home/alex")));
        // The process above it could not be read that far: no arguments, no folder.
        assert_eq!((v["ancestry"][4]["argv"].clone(), v["ancestry"][4]["cwd"].clone(), v["ancestry"][4]["truncated"].as_bool()), (Value::Null, Value::Null, Some(false)));
    }

    #[test]
    fn arguments_that_are_cut_or_not_text_are_marked() {
        let table = HashMap::from([(10, p("tool", ME, 1, 10, None))]);
        let cut = Invocation { argv: vec![b"tool".to_vec()], truncated: true, cwd: None };
        let v = owner(10, ME, &|pid| table.get(&pid).cloned(), &|_| Some(cut.clone())).unwrap().json();
        assert_eq!((v["ancestry"][0]["argv"].clone(), v["ancestry"][0]["truncated"].as_bool(), v["ancestry"][0]["argv_lossy"].as_bool()), (json!(["tool"]), Some(true), Some(false)));
        // Bytes that are no UTF-8: shown with U+FFFD, and marked as not exact.
        let odd = how(&[b"tool", b"caf\xe9", b"ok"], "/tmp");
        let v = owner(10, ME, &|pid| table.get(&pid).cloned(), &|_| Some(odd.clone())).unwrap().json();
        assert_eq!((v["ancestry"][0]["argv"].clone(), v["ancestry"][0]["argv_lossy"].as_bool()), (json!(["tool", "caf\u{fffd}", "ok"]), Some(true)));
    }

    #[test]
    fn a_process_that_ended_while_it_was_read_has_no_arguments_of_another() {
        use std::cell::Cell;
        // The id was given to another program between the two looks.
        let reads = Cell::new(0);
        let read = |_: u32| {
            reads.set(reads.get() + 1);
            Some(if reads.get() == 1 { p("node", ME, 1, 10, None) } else { p("other", ME, 1, 10, None) })
        };
        let v = owner(10, ME, &read, &|_| Some(how(&[b"other", b"--token=abc"], "/x"))).unwrap().json();
        assert_eq!((v["ancestry"][0]["name"].as_str(), v["ancestry"][0]["argv"].clone(), v["ancestry"][0]["cwd"].clone()), (Some("node"), Value::Null, Value::Null));
        // It ended: the second look finds nothing.
        let reads = Cell::new(0);
        let read = |_: u32| {
            reads.set(reads.get() + 1);
            (reads.get() == 1).then(|| p("node", ME, 1, 10, None))
        };
        let v = owner(10, ME, &read, &|_| Some(how(&[b"node"], "/x"))).unwrap().json();
        assert_eq!(v["ancestry"][0]["argv"], Value::Null);
        // Arguments are never asked for a process of another user.
        let table = HashMap::from([(10, p("a", ME, 11, 10, None)), (11, p("root-thing", 0, 1, 11, None))]);
        let asked = std::cell::RefCell::new(vec![]);
        let started = |pid: u32| {
            asked.borrow_mut().push(pid);
            None
        };
        owner(10, ME, &|pid| table.get(&pid).cloned(), &started).unwrap();
        assert_eq!(*asked.borrow(), [10]);
    }

    /// `npm run dev` in a pane: the pane's shell 900 started npm 4200 as a job of its own,
    /// npm started a shell 4201, and that started node 4242, which holds the port.
    fn wrapper() -> HashMap<u32, Process> {
        HashMap::from([
            (4242, p("node", ME, 4201, 4200, Some(4200))),
            (4201, p("sh", ME, 4200, 4200, Some(4200))),
            (4200, p("npm", ME, 900, 4200, Some(4200))),
            (900, p("zsh", ME, 850, 900, Some(4200))),
            (850, p("rex", ME, 1, 850, None)),
            (1, p("launchd", 0, 0, 1, None)),
        ])
    }

    #[test]
    fn a_server_behind_a_wrapper_is_in_the_group_of_what_the_pane_runs() {
        let o = ask(&wrapper(), 4242).unwrap();
        let chain: Vec<(u32, u32, u32, &str)> = o.chain.iter().map(|l| (l.pid, l.ppid, l.pgid, l.name.as_str())).collect();
        assert_eq!(chain, [(4242, 4201, 4200, "node"), (4201, 4200, 4200, "sh"), (4200, 900, 4200, "npm"), (900, 850, 900, "zsh"), (850, 1, 850, "rex")]);
        assert!(o.chain.iter().all(|l| l.started.is_none()));
        assert_eq!(o.tty_pgid, Some(4200));
        let v = o.json();
        // The holder is not what the pane started (npm, 4200), but it is in npm's group,
        // which is the one in the foreground of the terminal: Ctrl-C there reaches it.
        assert_eq!((v["pid"].as_u64(), v["pgid"].as_u64(), v["tty_foreground_pgid"].as_u64(), v["foreground"].as_bool()), (Some(4242), Some(4200), Some(4200), Some(true)));
        assert_eq!((v["ancestry"][2]["pid"].as_u64(), v["ancestry"][2]["name"].as_str(), v["ancestry"][2]["group_leader"].as_bool()), (Some(4200), Some("npm"), Some(true)));
        assert_eq!(v["ancestry"].as_array().unwrap().len(), 5);
    }

    #[test]
    fn a_server_in_the_background_or_without_a_terminal_is_not_in_the_foreground() {
        // Started with `&`: the shell is in the foreground of the terminal again.
        let mut table = wrapper();
        for pid in [4242, 4201, 4200, 900] {
            table.get_mut(&pid).unwrap().tty_pgid = Some(900);
        }
        let v = ask(&table, 4242).unwrap().json();
        assert_eq!((v["pgid"].as_u64(), v["tty_foreground_pgid"].as_u64(), v["foreground"].as_bool()), (Some(4200), Some(900), Some(false)));
        // A service: no terminal at all.
        let table = HashMap::from([(77, p("postgres", ME, 1, 77, None))]);
        let v = ask(&table, 77).unwrap().json();
        assert_eq!((v["tty_foreground_pgid"].clone(), v["foreground"].as_bool()), (Value::Null, Some(false)));
        assert_eq!((v["ancestry"].as_array().unwrap().len(), v["ancestry"][0]["ppid"].as_u64()), (1, Some(1)));
    }

    #[test]
    fn a_process_that_is_missing_or_someone_elses_has_no_owner() {
        let mut table = wrapper();
        assert_eq!(ask(&table, 5555), None);
        assert_eq!(ask(&table, 1), None, "the system's first process is root's");
        table.get_mut(&4242).unwrap().uid = ME + 1;
        assert_eq!(ask(&table, 4242), None);
        // A parent that ended, or that is another user's, ends the chain below it.
        let mut table = wrapper();
        table.remove(&4200);
        assert_eq!(ask(&table, 4242).unwrap().chain.iter().map(|l| l.pid).collect::<Vec<_>>(), [4242, 4201]);
        let mut table = wrapper();
        table.get_mut(&900).unwrap().uid = 0;
        assert_eq!(ask(&table, 4242).unwrap().chain.iter().map(|l| l.pid).collect::<Vec<_>>(), [4242, 4201, 4200]);
    }

    #[test]
    fn a_loop_of_parents_and_an_endless_chain_both_end() {
        // 10 says 11 started it, and 11 says 10 did.
        let table = HashMap::from([(10, p("a", ME, 11, 10, None)), (11, p("b", ME, 10, 10, None))]);
        assert_eq!(ask(&table, 10).unwrap().chain.iter().map(|l| l.pid).collect::<Vec<_>>(), [10, 11]);
        // A process that names itself.
        let table = HashMap::from([(10, p("a", ME, 10, 10, None))]);
        assert_eq!(ask(&table, 10).unwrap().chain.len(), 1);
        // Every process has a parent, for ever: the chain stops at `DEPTH`.
        let o = owner(1000, ME, &|pid| Some(p("deep", ME, pid + 1, pid, None)), &|_| None).unwrap();
        assert_eq!(o.chain.len(), DEPTH);
        assert_eq!((o.chain[0].pid, o.chain[DEPTH - 1].pid), (1000, 1000 + DEPTH as u32 - 1));
    }

    #[test]
    fn this_process_has_itself_at_the_start_of_its_chain() {
        let me = std::process::id();
        let Some(o) = owner(me, crate::platform::user_id(), &crate::platform::process, &crate::platform::invocation) else {
            // Linux reads /proc, macOS the kernel: both know this process.
            panic!("this process is not read");
        };
        assert_eq!(o.chain[0].pid, me);
        // The test program's own arguments and folder, as the system has them.
        let started = o.chain[0].started.as_ref().expect("its own arguments");
        let mine: Vec<Vec<u8>> = std::env::args_os().map(|a| a.into_encoded_bytes()).collect();
        assert_eq!((&started.argv, started.truncated), (&mine, false));
        assert_eq!(started.cwd.as_deref().map(std::path::Path::new).and_then(|p| p.canonicalize().ok()), std::env::current_dir().ok().and_then(|p| p.canonicalize().ok()));
        assert!(o.chain.len() <= DEPTH && o.chain.iter().all(|l| !l.name.is_empty()), "{o:?}");
    }

    #[tokio::test]
    async fn the_system_names_the_process_that_listens_on_a_port() {
        let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = l.local_addr().unwrap().port();
        // The tool is the system's own; a system without it names nothing.
        let (tool, _) = crate::platform::listener_query(port);
        if crate::tools::program(std::path::Path::new(tool)).is_none() {
            return;
        }
        let found = listener(port).await;
        // Never another process; and where the tool is known to name it (macOS's lsof), this one.
        assert!(found.is_none_or(|pid| pid == std::process::id()), "{found:?}");
        if cfg!(target_os = "macos") {
            assert_eq!(found, Some(std::process::id()));
        }
        if found.is_some() {
            assert!(listens_as_me(port).await);
        }
        drop(l);
        assert_eq!(listener(port).await, None);
        assert!(!listens_as_me(port).await);
    }
}
