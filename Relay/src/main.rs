//! Rex DUO Helper: sends Rex DUO push notifications for the Rex server on this
//! machine. One binary for macOS and Linux; see Relay/README.md.

mod apns;
mod config;
mod devices;
mod discovery;
mod legacy;
mod notice;
mod policy;
mod push;
mod relay;
mod rex;
mod service;
mod util;

use apns::{Apns, Jwt, Sender};
use config::{default_log_file, default_state_dir, expand, Config};
use std::path::PathBuf;
use std::time::Duration;

const USAGE: &str = "\
usage: rex-duo-helper <command> [options]

Sends Rex DUO push notifications when an agent in this machine's Rex needs you or
finishes, or a terminal raises a desktop notification.

Commands:
  install      install and start it in the background; it also starts at login
  status       say whether it's running and connected to Rex
  uninstall    stop it and remove the background service
  run          run in the foreground (what the background service runs)
  check-apns   test the built-in APNs key with Apple, then exit
  version      print the version

Options for run:
  --dry-run          log each push instead of sending it (or REX_DUO_DRY_RUN=1)
  --verbose          also log working/idle reports and every \"no push\" decision
  --server ADDR      Rex server to watch: unix:///path/server.sock or https://host
                     (repeatable; replaces discovery and config.json's servers)
  --state-dir DIR    where config.json and devices.json live
  --config FILE      config file (default <state-dir>/config.json)
  --log-file         log to the default log file instead of stdout
";

struct RunOptions {
    dry_run: bool,
    servers: Vec<String>,
    state_dir: PathBuf,
    config: Option<PathBuf>,
    log_file: bool,
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();

    // Opened from Finder: the Mac app's flow (start in the background, one dialog).
    #[cfg(target_os = "macos")]
    if args.iter().all(|a| a.starts_with("-psn_")) && service::bundle().is_some() {
        std::process::exit(service::open_app());
    }

    let (cmd, rest) = match args.first().map(String::as_str) {
        None | Some("help" | "--help" | "-h") => {
            let _ = std::io::Write::write_all(&mut std::io::stdout(), USAGE.as_bytes());
            return;
        }
        Some("version" | "--version") => {
            println!("{}", relay::VERSION);
            return;
        }
        // Options alone mean `run`, as the old command-line relay took them.
        Some(a) if a.starts_with('-') => ("run", &args[..]),
        Some(a) => (a, &args[1..]),
    };
    let code = match cmd {
        "install" => service::install(),
        "status" => service::status(),
        "uninstall" => service::uninstall(),
        "run" | "check-apns" => {
            let check = cmd == "check-apns" || rest.iter().any(|a| a == "--check-apns");
            match parse_run(rest) {
                Ok(o) if check => runtime().block_on(check_apns(o)),
                Ok(o) => runtime().block_on(run(o)),
                Err(e) => {
                    eprintln!("{e}\n\n{USAGE}");
                    2
                }
            }
        }
        other => {
            eprintln!("unknown command {other}\n\n{USAGE}");
            2
        }
    };
    std::process::exit(code);
}

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread().enable_all().build().expect("tokio runtime")
}

fn parse_run(args: &[String]) -> Result<RunOptions, String> {
    let env_dry = std::env::var("REX_DUO_DRY_RUN").is_ok_and(|v| !v.is_empty() && v != "0");
    let mut o = RunOptions { dry_run: env_dry, servers: vec![], state_dir: default_state_dir(), config: None, log_file: false };
    let mut it = args.iter();
    while let Some(a) = it.next() {
        let mut value = || it.next().cloned().ok_or(format!("{a} needs a value"));
        match a.as_str() {
            "--dry-run" => o.dry_run = true,
            "--verbose" | "-v" => util::set_verbose(true),
            "--check-apns" => {}
            "--server" => o.servers.push(value()?),
            "--state-dir" => o.state_dir = expand(&value()?),
            "--config" => o.config = Some(expand(&value()?)),
            "--log-file" => o.log_file = true,
            _ => return Err(format!("unknown option {a}")),
        }
    }
    Ok(o)
}

/// The APNs signer: config.json's key if it names one, else the key built into this binary.
fn load_jwt(cfg: &Config) -> Option<Jwt> {
    let team = cfg.team_id();
    if let Some(a) = &cfg.apns {
        if let (Some(path), Some(id)) = (&a.key_path, &a.key_id) {
            let pem = std::fs::read_to_string(expand(path));
            return match pem.map_err(|e| e.to_string()).and_then(|p| Jwt::from_pem(&p, id, &team)) {
                Ok(j) => Some(j),
                Err(e) => {
                    info!("could not load APNs key {path}: {e}");
                    None
                }
            };
        }
    }
    if apns::EMBEDDED_KEY.is_empty() {
        info!("this build has no APNs key; pushes are disabled");
        return None;
    }
    Jwt::from_pem(apns::EMBEDDED_KEY, apns::EMBEDDED_KEY_ID, &team)
        .map_err(|e| info!("could not load the built-in APNs key: {e}"))
        .ok()
}

fn load_config(o: &RunOptions) -> Result<Config, String> {
    let mut cfg = Config::load(&o.config.clone().unwrap_or_else(|| o.state_dir.join("config.json")))?;
    if !o.servers.is_empty() {
        cfg.servers = Some(o.servers.clone());
    }
    Ok(cfg)
}

async fn check_apns(o: RunOptions) -> i32 {
    let cfg = match load_config(&o) {
        Ok(c) => c,
        Err(e) => {
            eprintln!("{e}");
            return 1;
        }
    };
    let Some(jwt) = load_jwt(&cfg) else { return 1 };
    if apns::check(&Apns::new(jwt, cfg.topic())).await { 0 } else { 1 }
}

async fn run(o: RunOptions) -> i32 {
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
    // One helper per user: a second would show up as a second relay in Rex.
    let lock = std::fs::OpenOptions::new().create(true).truncate(false).write(true).open(o.state_dir.join("helper.lock"));
    let _lock = match lock {
        Ok(f) if f.try_lock().is_ok() => f,
        _ => {
            info!("Rex DUO Helper is already running for this user (see: rex-duo-helper status). Stop it first.");
            return 1;
        }
    };
    let sender = if o.dry_run {
        Some(Sender::DryRun { topic: cfg.topic() })
    } else {
        load_jwt(&cfg).map(|j| Sender::Apns(Box::new(Apns::new(j, cfg.topic()))))
    };
    let devices_path = o.state_dir.join("devices.json");
    let store = if o.dry_run { devices::DeviceStore::open_dry_run(devices_path) } else { devices::DeviceStore::open(devices_path) };
    let relay = relay::Relay::new(
        cfg.endpoints(),
        store,
        sender,
        relay::Options {
            dry_run: o.dry_run,
            label: cfg.label.clone(),
            debounce: cfg.debounce_seconds.unwrap_or(30.0),
            burst: cfg.rate_limit_burst.unwrap_or(10.0),
            per_minute: cfg.rate_limit_per_minute.unwrap_or(10.0),
            status_path: if o.state_dir == default_state_dir() {
                service::status_path()
            } else {
                o.state_dir.join("status.json")
            },
        },
    );
    relay.start();

    // On SIGINT/SIGTERM, close the connections to Rex with a close frame so the server drops
    // this client at once instead of keeping it as "lost" for 60 s.
    use tokio::signal::unix::{signal, SignalKind};
    let (mut int, mut term) = match (signal(SignalKind::interrupt()), signal(SignalKind::terminate())) {
        (Ok(i), Ok(t)) => (i, t),
        _ => {
            info!("could not install signal handlers");
            return 1;
        }
    };
    tokio::select! {
        _ = int.recv() => {}
        _ = term.recv() => {}
    }
    info!("stopping");
    relay.stop();
    tokio::time::sleep(Duration::from_millis(300)).await;
    0
}
