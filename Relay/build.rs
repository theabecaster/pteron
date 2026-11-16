// Embeds the APNs auth key in the binary, so the installed helper needs no key file.
//
// REX_APNS_KEY      path to the .p8 (default ~/.appstoreconnect/private_keys/AuthKey_<id>.p8),
//                   or "none" to build without a key (pushes are then disabled)
// REX_APNS_KEY_ID   default 5G2D4URHAC
// REX_APNS_TEAM_ID  default R2PVQ496X7
// REX_APNS_TOPIC    default dev.abrahamgonzalez.rexduo
//
// The key is copied into Cargo's OUT_DIR under target/ (gitignored) and into the binary.
// It is never written into the source tree.
use std::{env, fs, path::PathBuf};

fn main() {
    for v in ["REX_APNS_KEY", "REX_APNS_KEY_ID", "REX_APNS_TEAM_ID", "REX_APNS_TOPIC", "HOME"] {
        println!("cargo:rerun-if-env-changed={v}");
    }
    let key_id = env::var("REX_APNS_KEY_ID").unwrap_or_else(|_| "5G2D4URHAC".into());
    let team_id = env::var("REX_APNS_TEAM_ID").unwrap_or_else(|_| "R2PVQ496X7".into());
    let topic = env::var("REX_APNS_TOPIC").unwrap_or_else(|_| "dev.abrahamgonzalez.rexduo".into());
    let path = env::var("REX_APNS_KEY").unwrap_or_else(|_| {
        format!("{}/.appstoreconnect/private_keys/AuthKey_{key_id}.p8", env::var("HOME").unwrap_or_default())
    });

    let out = PathBuf::from(env::var("OUT_DIR").unwrap()).join("apns_key.p8");
    let key = if path != "none" { fs::read_to_string(&path).ok() } else { None };
    match key {
        Some(k) => {
            println!("cargo:rerun-if-changed={path}");
            fs::write(&out, k).unwrap();
        }
        None => {
            if path != "none" {
                println!("cargo:warning=no APNs key at {path}; this build can't send pushes");
            }
            fs::write(&out, "").unwrap();
        }
    }
    println!("cargo:rustc-env=REX_APNS_KEY_ID={key_id}");
    println!("cargo:rustc-env=REX_APNS_TEAM_ID={team_id}");
    println!("cargo:rustc-env=REX_APNS_TOPIC={topic}");
}
