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
