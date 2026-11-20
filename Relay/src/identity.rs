//! The helper's own identity: an ed25519 key made on first run, which never leaves this
//! computer. A phone pins the public half the first time it meets this helper and afterwards
//! hands its push secret only to a helper that proves it holds the private half. Another Rex
//! client that calls itself `rex-push-relay` can't.

use crate::auth::is_device_id;
use crate::util::{base64, base64_decode};
use ring::signature::{Ed25519KeyPair, KeyPair};
use serde_json::{json, Value};
use std::path::Path;

/// The first line of every message this key signs, so a signature made here can't be used for
/// anything else.
const DOMAIN: &str = "rexduo-helper-identity-v1";

pub struct HelperKey {
    pair: Ed25519KeyPair,
}

impl HelperKey {
    /// Reads `identity.key` (PKCS#8), or makes it. The file is created readable by this user
    /// only and is never written again: a new key would look to every phone like another helper.
    /// A file that is there but can't be used is an error for the same reason.
    pub fn load_or_create(path: &Path) -> Result<HelperKey, String> {
        use std::io::Write;
        match std::fs::read(path) {
            Ok(data) => {
                let pair = Ed25519KeyPair::from_pkcs8(&data).map_err(|_| format!("{} is not an ed25519 key", path.display()))?;
                // Tighten a file that was copied around with wider permissions.
                let _ = crate::platform::make_private(path);
                Ok(HelperKey { pair })
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                let made = Ed25519KeyPair::generate_pkcs8(&ring::rand::SystemRandom::new()).map_err(|_| "could not make a key".to_string())?;
                let pair = Ed25519KeyPair::from_pkcs8(made.as_ref()).map_err(|_| "could not make a key".to_string())?;
                if let Some(dir) = path.parent() {
                    std::fs::create_dir_all(dir).map_err(|e| format!("could not create {}: {e}", dir.display()))?;
                }
                // `create_new`: private from the moment it exists, and never over another key.
                let mut f = crate::platform::create_private(path).map_err(|e| format!("could not create {}: {e}", path.display()))?;
                f.write_all(made.as_ref()).and_then(|()| f.sync_all()).map_err(|e| format!("could not write {}: {e}", path.display()))?;
                Ok(HelperKey { pair })
            }
            Err(e) => Err(format!("could not read {}: {e}", path.display())),
        }
    }

    pub fn public_key(&self) -> [u8; 32] {
        self.pair.public_key().as_ref().try_into().expect("an ed25519 public key is 32 bytes")
    }

    /// The `helper_identity` result: the public key, and a signature over `message`.
    pub fn answer(&self, challenge: &str, helper_client: &str, requester_client: &str, device_id: &str) -> Result<Value, &'static str> {
        let message = message(challenge, helper_client, requester_client, device_id)?;
        Ok(json!({
            "public_key": base64(&self.public_key()),
            "signature": base64(self.pair.sign(message.as_bytes()).as_ref()),
            "client_id": helper_client,
        }))
    }
}

/// A challenge is the base64url of 32 random bytes: 43 characters, or 44 with its padding.
pub fn is_challenge(s: &str) -> bool {
    let body = s.strip_suffix('=').unwrap_or(s);
    body.len() == 43
        && body.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
        && base64_decode(body).is_some_and(|raw| raw.len() == 32)
}

/// What the helper signs: five lines joined by `\n`, with no newline at the end.
///
/// Both client ids are in it. The phone checks that the third line is the client it called and
/// the fourth is itself, so a client in the middle can't pass the phone's challenge on to the
/// real helper and hand back the answer as its own.
pub fn message(challenge: &str, helper_client: &str, requester_client: &str, device_id: &str) -> Result<String, &'static str> {
    if !is_challenge(challenge) {
        return Err("challenge must be the base64url of 32 bytes");
    }
    if !is_device_id(device_id) {
        return Err("device_id must be 8 lowercase hex digits");
    }
    // A line break in an id would let one message read as another.
    let one_line = |s: &str| !s.is_empty() && s.len() <= 200 && !s.chars().any(char::is_control);
    if !one_line(helper_client) || !one_line(requester_client) {
        return Err("a client id is not usable");
    }
    Ok([DOMAIN, challenge, helper_client, requester_client, device_id].join("\n"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::util::base64url;

    fn temp(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("identity-{tag}-{}-{}", std::process::id(), crate::util::now()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn challenge(fill: u8) -> String {
        base64url(&[fill; 32])
    }

    fn verify(public: &[u8], message: &str, signature: &[u8]) -> bool {
        ring::signature::UnparsedPublicKey::new(&ring::signature::ED25519, public).verify(message.as_bytes(), signature).is_ok()
    }

    #[test]
    fn the_message_is_exactly_five_lines() {
        let c = challenge(7);
        assert_eq!(c.len(), 43);
        assert_eq!(
            message(&c, "client:helper", "client:phone", "a1b2c3d4").unwrap(),
            format!("rexduo-helper-identity-v1\n{c}\nclient:helper\nclient:phone\na1b2c3d4")
        );
        // The challenge goes in as it came, padding included.
        let padded = format!("{c}=");
        assert_eq!(message(&padded, "h", "p", "a1b2c3d4").unwrap().lines().nth(1), Some(padded.as_str()));
    }

    #[test]
    fn the_signature_verifies_over_the_exact_message() {
        let dir = temp("sign");
        let key = HelperKey::load_or_create(&dir.join("identity.key")).unwrap();
        let c = challenge(1);
        let answer = key.answer(&c, "client:helper", "client:phone", "a1b2c3d4").unwrap();
        let keys: Vec<&str> = answer.as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(keys, ["client_id", "public_key", "signature"]);
        assert_eq!(answer["client_id"], "client:helper");
        let public = base64_decode(answer["public_key"].as_str().unwrap()).unwrap();
        let signature = base64_decode(answer["signature"].as_str().unwrap()).unwrap();
        assert_eq!((public.len(), signature.len()), (32, 64));
        assert_eq!(public, key.public_key());
        // Standard base64 with padding, which is what CryptoKit's `Data(base64Encoded:)` reads.
        assert!(answer["public_key"].as_str().unwrap().ends_with('='));
        assert!(answer["signature"].as_str().unwrap().ends_with("=="));

        let signed = format!("rexduo-helper-identity-v1\n{c}\nclient:helper\nclient:phone\na1b2c3d4");
        assert!(verify(&public, &signed, &signature));
        // Any other requester, challenge, helper or device is another message, which this
        // signature does not cover.
        for other in [
            message(&c, "client:helper", "client:other", "a1b2c3d4").unwrap(),
            message(&challenge(2), "client:helper", "client:phone", "a1b2c3d4").unwrap(),
            message(&c, "client:impostor", "client:phone", "a1b2c3d4").unwrap(),
            message(&c, "client:helper", "client:phone", "ffff0000").unwrap(),
            format!("{signed}\n"),
        ] {
            assert_ne!(other, signed);
            assert!(!verify(&public, &other, &signature), "{other:?}");
        }
        // And each of those gets its own signature.
        let relayed = key.answer(&c, "client:helper", "client:other", "a1b2c3d4").unwrap();
        assert_ne!(relayed["signature"], answer["signature"]);
        let again = key.answer(&challenge(2), "client:helper", "client:phone", "a1b2c3d4").unwrap();
        assert_ne!(again["signature"], answer["signature"]);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn a_bad_challenge_or_id_is_refused() {
        let dir = temp("refuse");
        let key = HelperKey::load_or_create(&dir.join("identity.key")).unwrap();
        let good = challenge(3);
        assert!(is_challenge(&good) && is_challenge(&format!("{good}=")));
        for bad in [
            String::new(),
            "AAAA".into(),
            base64url(&[3; 31]),
            base64url(&[3; 33]),
            base64url(&[3; 64]),
            format!("{good}=="),
            format!("{}+", &good[..42]),
            format!("{}/", &good[..42]),
            format!("{} ", &good[..42]),
            format!("{}\n", &good[..42]),
            format!("{good}\nclient:helper"),
            "é".repeat(43),
        ] {
            assert!(!is_challenge(&bad), "{bad:?}");
            assert!(key.answer(&bad, "client:helper", "client:phone", "a1b2c3d4").is_err(), "{bad:?}");
        }
        for bad_id in ["", "A1B2C3D4", "a1b2c3d", "a1b2c3d4e", "a1b2c3dg", "a1b2\nc3d"] {
            assert!(key.answer(&good, "client:helper", "client:phone", bad_id).is_err(), "{bad_id:?}");
        }
        assert!(key.answer(&good, "", "client:phone", "a1b2c3d4").is_err());
        assert!(key.answer(&good, "client:helper", "", "a1b2c3d4").is_err());
        assert!(key.answer(&good, "client:helper", "client:phone\nx", "a1b2c3d4").is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn the_key_file_is_made_once_private_and_reused() {
        use std::os::unix::fs::PermissionsExt;
        let dir = temp("file");
        // The state folder may not exist yet on a first run.
        let path = dir.join("state/identity.key");
        let first = HelperKey::load_or_create(&path).unwrap();
        let mode = |p: &Path| std::fs::metadata(p).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode(&path), 0o600);
        let on_disk = std::fs::read(&path).unwrap();
        assert!(Ed25519KeyPair::from_pkcs8(&on_disk).is_ok(), "PKCS#8");

        // The next start reads the same key and leaves the file alone.
        let second = HelperKey::load_or_create(&path).unwrap();
        assert_eq!(second.public_key(), first.public_key());
        assert_eq!(std::fs::read(&path).unwrap(), on_disk);
        // Wider permissions are narrowed again.
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert_eq!(HelperKey::load_or_create(&path).unwrap().public_key(), first.public_key());
        assert_eq!(mode(&path), 0o600);

        // Another folder gets another key.
        let other = HelperKey::load_or_create(&dir.join("other/identity.key")).unwrap();
        assert_ne!(other.public_key(), first.public_key());

        // A damaged file is an error and is not replaced: a new key would be a new identity.
        std::fs::write(&path, b"not a key").unwrap();
        assert!(HelperKey::load_or_create(&path).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"not a key");
        std::fs::remove_dir_all(dir).unwrap();
    }
}
