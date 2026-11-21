//! Beacon: sends the phone app's push notifications for the Rex server on this
//! machine. One binary for macOS and Linux; see Relay/README.md.

mod auth;
mod brand;
mod config;
mod desk;
mod devices;
mod discovery;
mod gateway;
mod hold;
mod host;
mod identity;
mod idle;
#[cfg(any(target_os = "macos", test))]
mod label;
mod legacy;
mod net;
mod notice;
mod owner;
mod platform;
mod policy;
mod presence;
mod proxy;
mod push;
mod relay;
#[cfg(any(target_os = "macos", test))]
mod rename;
mod rex;
mod service;
mod setup;
mod share;
mod tailscale;
mod tools;
mod update;
mod util;
mod waiting;

use brand::BEACON;
use config::{default_log_file, default_state_dir, expand, Config};
use std::path::PathBuf;
use std::time::Duration;

const USAGE: &str = concat!(
    "\
usage: rex-duo-helper <command> [options]

Sends ",
    app_name!(),
    " push notifications when an agent in this machine's Rex needs you or
finishes, or a terminal raises a desktop notification.

Commands:
  install      install and start it in the background; it also starts at login
               (--server ADDR also watches that Rex server; --setup-nonce-file is for ",
    app_name!(),
    ")
  status       say whether it's running and connected to Rex
  uninstall    stop it and remove the background service
  run          run in the foreground (what the background service runs)
  update       look for a newer version; download, check and install it if there is one
               (--check only looks)
  forget ID    remove a phone's registration by its device id (alone: list the phones)
  version      print the version (--json: as a JSON object)

Options for run:
  --dry-run          log each push instead of sending it (or REX_DUO_DRY_RUN=1)
  --verbose          also log working/idle reports and every \"no push\" decision
  --server ADDR      Rex server to watch: unix:///path/server.sock or https://host
                     (repeatable; replaces discovery and config.json's servers)
  --state-dir DIR    where config.json, devices.json and identity.key live
  --config FILE      config file (default <state-dir>/config.json)
  --log-file         log to the default log file instead of stdout

Only with --dry-run, to try desk presence without the real helper noticing:
  --idle-away SECS   count the desk as away after SECS without input (default 300)
  --client-name NAME connect to Rex under NAME instead of rex-push-relay, so the
                     phone app does not take this run for the helper
  --session ID       watch only this Rex session (repeatable), and no other's events
  --desk-file FILE   at the desk or away as FILE says (\"present\" or \"away\")
  --hold-cap SECS    hold a question SECS at most instead of 600
  --send-local       send to a gateway on this machine (http://127.0.0.1:…) for real
"
);

struct RunOptions {
    dry_run: bool,
    servers: Vec<String>,
    state_dir: PathBuf,
    config: Option<PathBuf>,
    log_file: bool,
    idle_away: Option<f64>,
    client_name: Option<String>,
    sessions: Vec<String>,
    desk_file: Option<PathBuf>,
    hold_cap: Option<f64>,
    send_local: bool,
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    // The Mac app opened without a command: by hand (start in the background, one dialog), or
    // by the phone app's setup (the same without a dialog).
    #[cfg(target_os = "macos")]
    if let Some(opening) = opening(&args, service::bundle().is_some()) {
        std::process::exit(service::open_app(opening));
    }
    #[cfg(not(target_os = "macos"))]
    if opening(&args, false).is_some() {
        eprintln!("phone-setup is how {BEACON}.app is opened on a Mac");
        std::process::exit(2);
    }

    let (cmd, rest) = match args.first().map(String::as_str) {
        None | Some("help" | "--help" | "-h") => {
            let _ = std::io::Write::write_all(&mut std::io::stdout(), USAGE.as_bytes());
            return;
        }
        // The name, for the scripts that package and release this program (Relay/package.sh).
        Some("brand") if args.len() == 1 => {
            println!("{}", brand::line());
            return;
        }
        Some("version" | "--version") => match version_line(&args[1..]) {
            Some(line) => {
                println!("{line}");
                return;
            }
            None => {
                eprintln!("usage: rex-duo-helper version [--json]");
                std::process::exit(2);
            }
        },
        // Options alone mean `run`, as the old command-line relay took them.
        Some(a) if a.starts_with('-') => ("run", &args[..]),
        Some(a) => (a, &args[1..]),
    };
    let code = match cmd {
        "install" => install(rest),
        "status" => service::status(),
        "uninstall" => service::uninstall(),
        "update" => match rest {
            [] => runtime().block_on(update::cli(false)),
            [only] if only == "--check" => runtime().block_on(update::cli(true)),
            _ => {
                eprintln!("usage: rex-duo-helper update [--check]");
                2
            }
        },
        "forget" => forget(rest),
        // What the helper runs itself after it swapped in a new version (src/update.rs).
        "finish-update" => update::finish_command(rest),
        // What the helper runs itself to give its Mac app its name (src/rename.rs).
        #[cfg(target_os = "macos")]
        "finish-move" => rename::finish_command(rest),
        "run" => match parse_run(rest) {
            Ok(o) => runtime().block_on(run(o)),
            Err(e) => {
                eprintln!("{e}\n\n{USAGE}");
                2
            }
        },
        other => {
            eprintln!("unknown command {other}\n\n{USAGE}");
            2
        }
    };
    std::process::exit(code);
}

/// How the app's binary was opened, when it was opened rather than given a command: with no
/// arguments of its own (macOS may add a `-psn_…` one), or with `phone-setup` alone. Only the
/// app is opened; the bare binary with no arguments prints the usage.
fn opening(args: &[String], in_app: bool) -> Option<service::Opening> {
    let own: Vec<&str> = args.iter().map(String::as_str).filter(|a| !a.starts_with("-psn_")).collect();
    match own.as_slice() {
        [] if in_app => Some(service::Opening::ByHand),
        ["phone-setup"] => Some(service::Opening::PhoneSetup),
        _ => None,
    }
}

/// What `version` prints: the version, or with `--json` an object a script can read. Every
/// installer that shipped reads that object by its exact shape, `{"version":"…"}`, so it
/// never gains a field: what else a script needs gets a command of its own (`brand`).
fn version_line(args: &[String]) -> Option<String> {
    match args {
        [] => Some(relay::VERSION.to_string()),
        [json] if json == "--json" => Some(serde_json::json!({"version": relay::VERSION}).to_string()),
        _ => None,
    }
}

/// `install`'s options, checked: the server address to add and the setup code to keep, or
/// the message that refuses them. It looks at the socket and takes the code out of its file,
/// which it removes; it changes nothing else.
fn checked_install(args: &[String], uid: platform::UserId) -> Result<(Option<String>, Option<String>), String> {
    let options = setup::parse_install(args)?;
    // Read first: the file is gone after this run whatever the other option turns out to be.
    let nonce = options.nonce_file.as_deref().map(|path| setup::read_nonce_file(std::path::Path::new(path), uid)).transpose();
    let server = options.server.as_deref().map(|s| setup::check_server(s, uid)).transpose()?;
    Ok((server, nonce?))
}

/// `rex-duo-helper install [--server ADDR] [--setup-nonce-file PATH]`. Both options are
/// checked before anything is written or started, so a refused one leaves the computer as it
/// was but for the code's file.
fn install(args: &[String]) -> i32 {
    let (server, nonce) = match checked_install(args, platform::user_id()) {
        Ok(checked) => checked,
        Err(e) => {
            eprintln!("{e}");
            return 2;
        }
    };
    let mut config_changed = false;
    if server.is_some() || nonce.is_some() {
        // An old install's files move into the state folder first, so nothing written below
        // stands in their way.
        for note in legacy::migrate() {
            println!("Moving from the old name: {note}");
        }
        let state_dir = default_state_dir();
        let written = server.map_or(Ok(false), |addr| setup::add_server(&state_dir.join("config.json"), &addr)).and_then(|changed| {
            nonce.map_or(Ok(()), |nonce| setup::store_nonce(&state_dir, &nonce, util::now() as i64)).map(|()| changed)
        });
        match written {
            Ok(changed) => config_changed = changed,
            Err(e) => {
                eprintln!("Could not install: {e}");
                return 1;
            }
        }
    }
    service::install(config_changed)
}

/// `rex-duo-helper forget [<device_id>] [--state-dir DIR]`: the way out when a phone is
/// registered to an account that can't unregister it any more. It only edits devices.json;
/// the running helper notices.
fn forget(args: &[String]) -> i32 {
    let (mut id, mut state_dir) = (None, default_state_dir());
    let mut it = args.iter();
    while let Some(a) = it.next() {
        match (a.as_str(), it.len()) {
            ("--state-dir", n) if n > 0 => state_dir = expand(it.next().unwrap()),
            (a, _) if !a.starts_with('-') && id.is_none() => id = Some(a.to_string()),
            _ => {
                eprintln!("usage: rex-duo-helper forget [<device id>] [--state-dir DIR]");
                return 2;
            }
        }
    }
    let path = state_dir.join("devices.json");
    let Some(id) = id else {
        let phones = devices::DeviceStore::open_dry_run(path).devices;
        if phones.is_empty() {
            println!("No phone is registered.");
        }
        for d in phones {
            println!("{}  {}  registered {} by {}", d.device_id, d.device_name.as_deref().unwrap_or("(no name)"), d.registered_at, d.owner);
        }
        return 0;
    };
    match devices::forget(&path, &id) {
        Ok(true) => {
            println!("Forgot {id}. It gets no more pushes from this computer until it registers again.");
            0
        }
        Ok(false) => {
            println!("No phone with the id {id} is registered. `rex-duo-helper forget` alone lists them.");
            1
        }
        Err(e) => {
            eprintln!("{e}");
            2
        }
    }
}

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread().enable_all().build().expect("tokio runtime")
}

fn parse_run(args: &[String]) -> Result<RunOptions, String> {
    let env_dry = std::env::var("REX_DUO_DRY_RUN").is_ok_and(|v| !v.is_empty() && v != "0");
    let mut o = RunOptions {
        dry_run: env_dry,
        servers: vec![],
        state_dir: default_state_dir(),
        config: None,
        log_file: false,
        idle_away: None,
        client_name: None,
        sessions: vec![],
        desk_file: None,
        hold_cap: None,
        send_local: false,
    };
    let mut it = args.iter();
    while let Some(a) = it.next() {
        let mut value = || it.next().cloned().ok_or(format!("{a} needs a value"));
        match a.as_str() {
            "--dry-run" => o.dry_run = true,
            "--verbose" | "-v" => util::set_verbose(true),
            "--server" => o.servers.push(value()?),
            "--state-dir" => o.state_dir = expand(&value()?),
            "--config" => o.config = Some(expand(&value()?)),
            "--log-file" => o.log_file = true,
            "--idle-away" => {
                let secs = value()?;
                o.idle_away = Some(secs.parse::<f64>().ok().filter(|s| (1.0..=3600.0).contains(s)).ok_or(format!("--idle-away takes 1 to 3600 seconds, not {secs}"))?);
            }
            "--client-name" => {
                let name = value()?;
                if name.is_empty() || name.len() > 64 || !name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') {
                    return Err(format!("--client-name takes letters, digits, - and _, not {name:?}"));
                }
                o.client_name = Some(name);
            }
            "--session" => {
                let id = value()?;
                let ok = id.strip_prefix("session:").is_some_and(|rest| (1..=64).contains(&rest.len()) && rest.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-'));
                if !ok {
                    return Err(format!("--session takes a session id (session:<uuid>), not {id:?}"));
                }
                o.sessions.push(id);
            }
            "--desk-file" => o.desk_file = Some(expand(&value()?)),
            "--hold-cap" => {
                let secs = value()?;
                o.hold_cap = Some(secs.parse::<f64>().ok().filter(|s| (10.0..=3600.0).contains(s)).ok_or(format!("--hold-cap takes 10 to 3600 seconds, not {secs}"))?);
            }
            "--send-local" => o.send_local = true,
            _ => return Err(format!("unknown option {a}")),
        }
    }
    // These change what the real helper relies on: only a dry run takes them.
    let trial = o.idle_away.is_some() || o.client_name.is_some() || !o.sessions.is_empty() || o.desk_file.is_some() || o.hold_cap.is_some() || o.send_local;
    if !o.dry_run && trial {
        return Err("--idle-away, --client-name, --session, --desk-file, --hold-cap and --send-local are only for --dry-run".into());
    }
    Ok(o)
}

fn load_config(o: &RunOptions) -> Result<Config, String> {
    let mut cfg = Config::load(&o.config.clone().unwrap_or_else(|| o.state_dir.join("config.json")))?;
    if !o.servers.is_empty() {
        cfg.servers = Some(o.servers.clone());
    }
    Ok(cfg)
}

async fn run(o: RunOptions) -> i32 {
    // A service starts with few files allowed open; never a reason not to start.
    let _ = platform::raise_fd_limit();
    if o.log_file {
        if let Err(e) = util::log_to_file(default_log_file()) {
            eprintln!("could not open the log file: {e}");
        }
    }
    if o.state_dir == default_state_dir() {
        for note in legacy::migrate() {
            info!("moving from the old name: {note}");
        }
    }
    let cfg = match load_config(&o) {
        Ok(c) => c,
        Err(e) => {
            info!("{e}");
            return 1;
        }
    };
    if let Err(e) = std::fs::create_dir_all(&o.state_dir) {
        info!("could not create {}: {e}", o.state_dir.display());
        return 1;
    }
    // A Mac's helper under the earlier label of its background job gives way to one under
    // the new label (src/label.rs).
    #[cfg(target_os = "macos")]
    if rename::before_start(&o.state_dir, o.dry_run) {
        return 0;
    }
    // One helper per user: a second would show up as a second relay in Rex.
    let lock = std::fs::OpenOptions::new().create(true).truncate(false).write(true).open(o.state_dir.join("helper.lock"));
    let _lock = match lock {
        Ok(f) if f.try_lock().is_ok() => f,
        _ => {
            info!("{BEACON} is already running for this user (see: rex-duo-helper status). Stop it first.");
            return 1;
        }
    };
    let (gateways, unusable) = auth::Gateways::new(cfg.gateways.as_deref().unwrap_or_default());
    for entry in unusable {
        info!("config.json: \"{entry}\" is not a gateway address this helper can use (https://host, or http://127.0.0.1:port)");
    }
    // Without the key the helper still pushes for phones that registered before; a phone
    // that asks who this is gets an error and hands over nothing.
    let key = match identity::HelperKey::load_or_create(&o.state_dir.join("identity.key")) {
        Ok(k) => Some(k),
        Err(e) => {
            info!("no identity key, so no phone can register: {e}");
            None
        }
    };
    #[cfg(target_os = "macos")]
    rename::at_start(&o.state_dir, o.dry_run);
    let sender = match (o.dry_run, o.send_local) {
        (false, _) => gateway::Sender::Gateway,
        (true, false) => gateway::Sender::DryRun,
        (true, true) => gateway::Sender::DryRunLocal,
    };
    let system: std::sync::Arc<dyn idle::Sense> = std::sync::Arc::new(idle::System);
    let sense: std::sync::Arc<dyn idle::Sense> = match &o.desk_file {
        Some(path) => std::sync::Arc::new(idle::DeskFile { inner: system, path: path.clone() }),
        None => system,
    };
    let updater = update::Updater::new(o.dry_run, cfg.auto_update.unwrap_or(true), &o.state_dir);
    let devices_path = o.state_dir.join("devices.json");
    let store = if o.dry_run { devices::DeviceStore::open_dry_run(devices_path) } else { devices::DeviceStore::open(devices_path) };
    let relay = relay::Relay::new(
        cfg.watch(),
        store,
        sender,
        updater,
        relay::Options {
            dry_run: o.dry_run,
            label: cfg.label.clone(),
            name: o.client_name.clone(),
            debounce: cfg.debounce_seconds.unwrap_or(30.0),
            burst: cfg.rate_limit_burst.unwrap_or(10.0),
            per_minute: cfg.rate_limit_per_minute.unwrap_or(10.0),
            status_path: if o.state_dir == default_state_dir() {
                service::status_path()
            } else {
                o.state_dir.join("status.json")
            },
            gateways,
            key,
            state_dir: o.state_dir.clone(),
            os: host::os(),
            sense,
            away_after: o.idle_away.unwrap_or(desk::AWAY_AFTER),
            sessions: o.sessions.clone(),
            hold_cap: o.hold_cap,
        },
    );
    relay.start();

    // On SIGINT/SIGTERM, close the connections to Rex with a close frame so the server drops
    // this client at once instead of keeping it as "lost" for 60 s.
    let Ok(mut stop) = platform::stop_signal() else {
        info!("could not install signal handlers");
        return 1;
    };
    stop.wait().await;
    info!("stopping");
    relay.stop();
    tokio::time::sleep(Duration::from_millis(300)).await;
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use service::Opening;

    fn args(words: &[&str]) -> Vec<String> {
        words.iter().map(|w| w.to_string()).collect()
    }

    #[test]
    fn the_app_is_opened_by_hand_or_by_a_phone_setup() {
        assert_eq!(opening(&args(&[]), true), Some(Opening::ByHand));
        assert_eq!(opening(&args(&["-psn_0_12345"]), true), Some(Opening::ByHand));
        assert_eq!(opening(&args(&["phone-setup"]), true), Some(Opening::PhoneSetup));
        assert_eq!(opening(&args(&["-psn_0_12345", "phone-setup"]), true), Some(Opening::PhoneSetup));
        // The bare binary with no arguments prints its usage.
        assert_eq!(opening(&args(&[]), false), None);
        assert_eq!(opening(&args(&["-psn_0_12345"]), false), None);
        // Anything else is a command.
        for command in [&["install"][..], &["run", "--dry-run"], &["phone-setup", "extra"], &["install", "phone-setup"], &["--dry-run"], &["status"]] {
            assert_eq!(opening(&args(command), true), None, "{command:?}");
        }
    }

    #[test]
    fn the_desk_trial_options_are_for_a_dry_run_only() {
        let o = parse_run(&args(&["--dry-run", "--idle-away", "5", "--client-name", "rex-push-relay-test"])).unwrap();
        assert_eq!((o.idle_away, o.client_name.as_deref()), (Some(5.0), Some("rex-push-relay-test")));
        assert!(parse_run(&args(&["--idle-away", "5"])).is_err());
        assert!(parse_run(&args(&["--client-name", "x"])).is_err());
        for bad in [&["--dry-run", "--idle-away", "0"][..], &["--dry-run", "--idle-away", "soon"], &["--dry-run", "--client-name", "a b"], &["--dry-run", "--client-name", ""]] {
            assert!(parse_run(&args(bad)).is_err(), "{bad:?}");
        }
        let plain = parse_run(&args(&["--dry-run"])).unwrap();
        assert_eq!((plain.idle_away, plain.client_name), (None, None));
        assert!(plain.sessions.is_empty() && plain.desk_file.is_none() && plain.hold_cap.is_none() && !plain.send_local);

        let trial = parse_run(&args(&[
            "--dry-run",
            "--session",
            "session:0b8e6a52-1c2d-4e5f-8a9b-0c1d2e3f4a5b",
            "--session",
            "session:abc",
            "--desk-file",
            "/tmp/desk",
            "--hold-cap",
            "90",
            "--send-local",
        ]))
        .unwrap();
        assert_eq!(trial.sessions, ["session:0b8e6a52-1c2d-4e5f-8a9b-0c1d2e3f4a5b", "session:abc"]);
        assert_eq!((trial.desk_file.as_deref(), trial.hold_cap, trial.send_local), (Some(std::path::Path::new("/tmp/desk")), Some(90.0), true));
        for only_dry in [&["--session", "session:abc"][..], &["--desk-file", "/tmp/desk"], &["--hold-cap", "90"], &["--send-local"]] {
            assert!(parse_run(&args(only_dry)).is_err(), "{only_dry:?}");
        }
        for bad in [&["--dry-run", "--session", "abc"][..], &["--dry-run", "--session", "session:a b"], &["--dry-run", "--hold-cap", "5"], &["--dry-run", "--hold-cap", "soon"]] {
            assert!(parse_run(&args(bad)).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn version_prints_text_or_json() {
        assert_eq!(version_line(&[]).unwrap(), relay::VERSION);
        let json = version_line(&args(&["--json"])).unwrap();
        assert_eq!(json, format!("{{\"version\":\"{}\"}}", relay::VERSION));
        assert!(!json.contains(char::is_whitespace));
        // The one field, and nothing of the name: installers in the field strip the two ends
        // and take what is left for the version.
        let inner = json.strip_prefix("{\"version\":\"").and_then(|rest| rest.strip_suffix("\"}")).unwrap();
        assert_eq!(inner, relay::VERSION);
        assert_eq!(serde_json::from_str::<serde_json::Value>(&json).unwrap().as_object().unwrap().len(), 1);
        assert!(!json.contains(brand::APP));
        assert_eq!(version_line(&args(&["--yaml"])), None);
        assert_eq!(version_line(&args(&["--json", "--json"])), None);
    }

    #[cfg(unix)]
    #[test]
    fn install_refuses_bad_options_before_it_does_anything() {
        use std::os::unix::fs::PermissionsExt;
        let nonce = "ab".repeat(32);
        let dir = std::env::temp_dir().join(format!("main-install-{}-{}", std::process::id(), util::now() as u64 % 100_000));
        std::fs::create_dir_all(&dir).unwrap();
        let uid = platform::user_id();
        let file = dir.join("code");
        let path = file.to_str().unwrap();
        let write = |content: &str| {
            std::fs::write(&file, content).unwrap();
            std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o600)).unwrap();
        };
        for bad in [
            &["--force"][..],
            &["--setup-nonce", &nonce],
            &["--server", "http://rex-box.example.ts.net"],
            &["--server", "unix:///nonexistent/rex/server.sock"],
        ] {
            assert!(checked_install(&args(bad), uid).is_err(), "{bad:?}");
        }
        // One bad option refuses the whole command, whatever the other is, and the code's
        // file is removed either way.
        for (content, bad) in [
            ("abc", &["--setup-nonce-file", path][..]),
            ("abc", &["--server", "https://rex-box.example.ts.net", "--setup-nonce-file", path]),
            (&nonce, &["--setup-nonce-file", path, "--server", "ftp://rex-box.example.ts.net"]),
        ] {
            write(content);
            assert!(checked_install(&args(bad), uid).is_err(), "{bad:?}");
            assert!(!file.exists(), "{bad:?}");
        }
        assert_eq!(checked_install(&[], uid), Ok((None, None)));
        write(&format!("{nonce}\n"));
        assert_eq!(
            checked_install(&args(&["--server", "https://rex-box.example.ts.net", "--setup-nonce-file", path]), uid),
            Ok((Some("https://rex-box.example.ts.net".into()), Some(nonce.clone())))
        );
        assert!(!file.exists());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
