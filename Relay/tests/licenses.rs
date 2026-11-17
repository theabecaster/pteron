//! Every crate in Cargo.lock has a licence the helper's own (AGPL-3.0-only) can be shipped with.
//! The list and the rules are in `third-party-licenses.py`, which also writes the notices file
//! each release carries.

use std::process::Command;

#[test]
fn every_crate_has_a_licence_from_the_list() {
    let script = concat!(env!("CARGO_MANIFEST_DIR"), "/third-party-licenses.py");
    let out = Command::new("python3").arg(script).arg("--check").output().expect("python3 runs the licence check");
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
}
