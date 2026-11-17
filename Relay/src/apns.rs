//! APNs over HTTP/2 with token auth (ES256 JWT), one lazily opened connection per host.

use crate::devices::Device;
use crate::info;
use crate::policy::{BlockRef, PushCategory, PushIntent};
use crate::push::{BlockContext, PushMessage};
use crate::util::{base64_decode, base64url, now};
use bytes::Bytes;
use ring::rand::SystemRandom;
use ring::signature::{EcdsaKeyPair, ECDSA_P256_SHA256_FIXED_SIGNING};
use serde_json::json;
use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Duration;
use tokio::net::TcpStream;

/// The key `build.rs` embedded (empty when built without one).
pub const EMBEDDED_KEY: &str = include_str!(concat!(env!("OUT_DIR"), "/apns_key.p8"));
pub const EMBEDDED_KEY_ID: &str = env!("REX_APNS_KEY_ID");

/// APNs provider token: an ES256 JWT `{alg, kid}.{iss, iat}` signed with the .p8 key.
/// Apple accepts a token for up to an hour and rejects refreshes more often than every 20
/// minutes, so it's reused and replaced after `lifetime` (50 minutes).
pub struct Jwt {
    key: EcdsaKeyPair,
    pub key_id: String,
    pub team_id: String,
    pub lifetime: f64,
    cached: Option<(String, f64)>,
}

impl Jwt {
    /// Reads an `AuthKey_XXXXXXXXXX.p8` (PKCS#8 PEM).
    pub fn from_pem(pem: &str, key_id: &str, team_id: &str) -> Result<Jwt, String> {
        let body: String = pem.lines().filter(|l| !l.starts_with("-----")).collect();
        let der = base64_decode(&body).ok_or("the key is not valid base64")?;
        let key = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &der, &SystemRandom::new())
            .map_err(|e| format!("not a P-256 PKCS#8 key: {e}"))?;
        Ok(Jwt { key, key_id: key_id.into(), team_id: team_id.into(), lifetime: 50.0 * 60.0, cached: None })
    }

    pub fn current(&mut self, now: f64) -> String {
        if let Some((t, issued)) = &self.cached {
            if now - issued < self.lifetime {
                return t.clone();
            }
        }
        let t = self.make(now as i64);
        self.cached = Some((t.clone(), now));
        t
    }

    pub fn invalidate(&mut self) {
        self.cached = None;
    }

    pub fn make(&self, issued_at: i64) -> String {
        let header = json!({"alg": "ES256", "kid": self.key_id});
        let claims = json!({"iss": self.team_id, "iat": issued_at});
        let input = format!("{}.{}", base64url(header.to_string().as_bytes()), base64url(claims.to_string().as_bytes()));
        // JWS ES256 wants the raw 64-byte r||s form, not DER (that's what the FIXED algorithm gives).
        let sig = self.key.sign(&SystemRandom::new(), input.as_bytes()).map(|s| s.as_ref().to_vec()).unwrap_or_default();
        format!("{input}.{}", base64url(&sig))
    }
}

#[derive(Clone, Debug, PartialEq)]
pub enum SendResult {
    Sent(Option<String>),
    /// The token is dead (410 Unregistered, BadDeviceToken): forget the device.
    DropDevice(String),
    Failed(String),
}

pub fn host_for(environment: &str) -> &'static str {
    if environment == "production" {
        "api.push.apple.com"
    } else {
        "api.sandbox.push.apple.com"
    }
}

/// The request for one push: URI and headers (body is `m.payload_bytes()`).
pub fn request(m: &PushMessage, d: &Device, topic: &str, jwt: &str, now: f64) -> http::Request<()> {
    let mut r = http::Request::post(format!("https://{}/3/device/{}", host_for(&d.environment), d.token))
        .header("authorization", format!("bearer {jwt}"))
        .header("apns-topic", topic)
        .header("apns-push-type", "alert")
        .header("apns-priority", m.priority().to_string())
        .header("apns-expiration", (now as i64 + 3600).to_string())
        .header("content-type", "application/json");
    if let Some(c) = &m.collapse_id {
        r = r.header("apns-collapse-id", c);
    }
    r.body(()).expect("valid request")
}

/// TLS settings shared by APNs and remote Rex servers, built on first use (most helpers only
/// ever talk to a local socket and push rarely).
pub fn tls_config(alpn: &[u8]) -> Arc<rustls::ClientConfig> {
    static ROOTS: OnceLock<Arc<rustls::RootCertStore>> = OnceLock::new();
    let roots = ROOTS.get_or_init(|| {
        let mut r = rustls::RootCertStore::empty();
        r.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
        Arc::new(r)
    });
    let mut cfg = rustls::ClientConfig::builder_with_provider(Arc::new(rustls::crypto::ring::default_provider()))
        .with_safe_default_protocol_versions()
        .expect("TLS versions")
        .with_root_certificates(roots.clone())
        .with_no_client_auth();
    cfg.alpn_protocols = vec![alpn.to_vec()];
    Arc::new(cfg)
}

pub async fn tls_connect(
    host: &str,
    port: u16,
    alpn: &[u8],
) -> Result<tokio_rustls::client::TlsStream<TcpStream>, String> {
    let tcp = TcpStream::connect((host, port)).await.map_err(|e| e.to_string())?;
    let _ = tcp.set_nodelay(true);
    let name = rustls::pki_types::ServerName::try_from(host.to_string()).map_err(|e| e.to_string())?;
    tokio_rustls::TlsConnector::from(tls_config(alpn)).connect(name, tcp).await.map_err(|e| e.to_string())
}

pub enum Sender {
    Apns(Box<Apns>),
    /// `--dry-run`: logs what would be sent.
    DryRun { topic: String },
}

impl Sender {
    pub async fn send(&self, m: &PushMessage, d: &Device) -> SendResult {
        match self {
            Sender::Apns(a) => a.send(m, d).await,
            Sender::DryRun { topic } => {
                info!("DRY-RUN push -> {} [{}] {}", d.device_name.as_deref().unwrap_or("?"), d.environment, describe(m, topic));
                SendResult::Sent(None)
            }
        }
    }

    pub fn topic(&self) -> &str {
        match self {
            Sender::Apns(a) => &a.topic,
            Sender::DryRun { topic } => topic,
        }
    }
}

pub fn describe(m: &PushMessage, topic: &str) -> String {
    let mut h = format!("topic={topic} priority={}", m.priority());
    if let Some(c) = &m.collapse_id {
        h += &format!(" collapse-id={c}");
    }
    format!("{h} payload={}", m.payload())
}

pub struct Apns {
    pub topic: String,
    jwt: Mutex<Jwt>,
    conns: tokio::sync::Mutex<HashMap<&'static str, h2::client::SendRequest<Bytes>>>,
}

impl Apns {
    pub fn new(jwt: Jwt, topic: String) -> Apns {
        Apns { topic, jwt: Mutex::new(jwt), conns: tokio::sync::Mutex::new(HashMap::new()) }
    }

    pub async fn send(&self, m: &PushMessage, d: &Device) -> SendResult {
        let mut fresh_token = false;
        for attempt in 0..3 {
            let jwt = self.jwt.lock().unwrap().current(now());
            let req = request(m, d, &self.topic, &jwt, now());
            let host = host_for(&d.environment);
            match tokio::time::timeout(Duration::from_secs(20), self.post(host, req, m.payload_bytes())).await {
                Ok(Ok((status, apns_id, body))) => {
                    if status == 200 {
                        return SendResult::Sent(apns_id);
                    }
                    let reason = serde_json::from_slice::<serde_json::Value>(&body)
                        .ok()
                        .and_then(|v| v.get("reason").and_then(|r| r.as_str()).map(String::from))
                        .unwrap_or_else(|| format!("HTTP {status}"));
                    match (status, reason.as_str()) {
                        (410, _) | (_, "BadDeviceToken") | (_, "Unregistered") => return SendResult::DropDevice(reason),
                        (403, "ExpiredProviderToken") if !fresh_token => {
                            fresh_token = true;
                            self.jwt.lock().unwrap().invalidate();
                        }
                        _ => return SendResult::Failed(format!("{status} {reason}")),
                    }
                }
                // A connection Apple closed while idle fails here once; retry on a new one.
                Ok(Err(e)) if attempt == 0 => {
                    crate::debug!("APNs connection to {host} failed ({e}); reconnecting");
                    self.conns.lock().await.remove(host);
                }
                Ok(Err(e)) => return SendResult::Failed(e),
                Err(_) => {
                    self.conns.lock().await.remove(host);
                    return SendResult::Failed("timed out".into());
                }
            }
        }
        SendResult::Failed("provider token rejected".into())
    }

    async fn post(&self, host: &'static str, req: http::Request<()>, body: Vec<u8>) -> Result<(u16, Option<String>, Vec<u8>), String> {
        let client = {
            let mut conns = self.conns.lock().await;
            let existing = conns.get(host).cloned();
            let c = match existing {
                Some(c) => c,
                None => {
                    let tls = tls_connect(host, 443, b"h2").await?;
                    let (c, conn) = h2::client::handshake(tls).await.map_err(|e| e.to_string())?;
                    tokio::spawn(async move {
                        let _ = conn.await;
                    });
                    conns.insert(host, c.clone());
                    c
                }
            };
            match c.ready().await {
                Ok(c) => c,
                Err(e) => {
                    conns.remove(host);
                    return Err(e.to_string());
                }
            }
        };
        let mut client = client;
        let (resp, mut stream) = client.send_request(req, false).map_err(|e| e.to_string())?;
        stream.send_data(Bytes::from(body), true).map_err(|e| e.to_string())?;
        let resp = resp.await.map_err(|e| e.to_string())?;
        let status = resp.status().as_u16();
        let apns_id = resp.headers().get("apns-id").and_then(|v| v.to_str().ok()).map(String::from);
        let mut body = resp.into_body();
        let mut data = vec![];
        while let Some(chunk) = body.data().await {
            let chunk = chunk.map_err(|e| e.to_string())?;
            let _ = body.flow_control().release_capacity(chunk.len());
            data.extend_from_slice(&chunk);
        }
        Ok((status, apns_id, data))
    }
}

/// `check-apns`: pushes to a fake token in each APNs environment. Apple answering
/// `BadDeviceToken` means it accepted the key; nothing is delivered anywhere.
pub async fn check(apns: &Apns) -> bool {
    let mut i = PushIntent::new(
        PushCategory::Notice,
        BlockRef { server: "check".into(), session_id: String::new(), block_id: "check".into() },
    );
    i.headline = Some("Rex Connect Helper".into());
    i.text = Some("APNs check".into());
    let m = PushMessage::compose(&i, &BlockContext::default());
    let mut ok = true;
    for env in ["sandbox", "production"] {
        let fake = Device::new(&"0".repeat(64), env);
        let r = apns.send(&m, &fake).await;
        let good = r == SendResult::DropDevice("BadDeviceToken".into());
        ok &= good;
        println!("{}: {r:?} -> {}", host_for(env), if good { "key accepted" } else { "unexpected" });
    }
    ok
}

#[cfg(test)]
mod tests {
    use super::*;
    use ring::signature::{KeyPair, UnparsedPublicKey, ECDSA_P256_SHA256_FIXED};

    fn test_key() -> (String, Vec<u8>) {
        let rng = SystemRandom::new();
        let pkcs8 = EcdsaKeyPair::generate_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, &rng).unwrap();
        let b64 = crate::util::base64url(pkcs8.as_ref()).replace('-', "+").replace('_', "/");
        let pem = format!("-----BEGIN PRIVATE KEY-----\n{b64}\n-----END PRIVATE KEY-----\n");
        let pair = EcdsaKeyPair::from_pkcs8(&ECDSA_P256_SHA256_FIXED_SIGNING, pkcs8.as_ref(), &rng).unwrap();
        (pem, pair.public_key().as_ref().to_vec())
    }

    #[test]
    fn jwt_format() {
        let (pem, public) = test_key();
        let jwt = Jwt::from_pem(&pem, "5G2D4URHAC", "R2PVQ496X7").unwrap().make(1_763_300_000);
        let parts: Vec<&str> = jwt.split('.').collect();
        assert_eq!(parts.len(), 3);
        for p in &parts {
            assert!(!p.contains('=') && !p.contains('+') && !p.contains('/'));
        }
        let header: serde_json::Value = serde_json::from_slice(&base64_decode(parts[0]).unwrap()).unwrap();
        assert_eq!(header, json!({"alg": "ES256", "kid": "5G2D4URHAC"}));
        let claims: serde_json::Value = serde_json::from_slice(&base64_decode(parts[1]).unwrap()).unwrap();
        assert_eq!(claims, json!({"iss": "R2PVQ496X7", "iat": 1_763_300_000}));
        let sig = base64_decode(parts[2]).unwrap();
        assert_eq!(sig.len(), 64, "ES256 JWS signature is raw r||s");
        let input = format!("{}.{}", parts[0], parts[1]);
        UnparsedPublicKey::new(&ECDSA_P256_SHA256_FIXED, public).verify(input.as_bytes(), &sig).unwrap();
    }

    #[test]
    fn token_is_reused_then_refreshed() {
        let (pem, _) = test_key();
        let mut t = Jwt::from_pem(&pem, "K", "T").unwrap();
        let now = 1_763_300_000.0;
        let a = t.current(now);
        assert_eq!(t.current(now + 49.0 * 60.0), a);
        let b = t.current(now + 51.0 * 60.0);
        assert_ne!(a, b);
        t.invalidate();
        assert_ne!(t.current(now + 52.0 * 60.0), b);
    }

    #[test]
    fn rejects_bad_keys() {
        assert!(Jwt::from_pem("-----BEGIN PRIVATE KEY-----\nAAAA\n-----END PRIVATE KEY-----", "K", "T").is_err());
    }

    #[test]
    fn embedded_key_loads_when_present() {
        if !EMBEDDED_KEY.is_empty() {
            assert!(Jwt::from_pem(EMBEDDED_KEY, EMBEDDED_KEY_ID, "T").is_ok());
        }
    }

    #[test]
    fn request_headers() {
        let r = BlockRef { server: "s".into(), session_id: "session:1".into(), block_id: "block:1".into() };
        let mut i = PushIntent::new(PushCategory::Blocked, r);
        i.state = Some("blocked".into());
        i.record_id = Some(String::new());
        let m = PushMessage::compose(&i, &BlockContext::default());
        let mut dev = Device::new(&"ab".repeat(32), "sandbox");
        let req = request(&m, &dev, "dev.abrahamgonzalez.rexduo", "x.y.z", 1000.0);
        assert_eq!(req.uri().to_string(), format!("https://api.sandbox.push.apple.com/3/device/{}", dev.token));
        let h = req.headers();
        assert_eq!(h["authorization"], "bearer x.y.z");
        assert_eq!(h["apns-topic"], "dev.abrahamgonzalez.rexduo");
        assert_eq!(h["apns-push-type"], "alert");
        assert_eq!(h["apns-priority"], "10");
        assert_eq!(h["apns-expiration"], "4600");
        assert!(h.contains_key("apns-collapse-id"));
        dev.environment = "production".into();
        assert_eq!(request(&m, &dev, "t", "j", 0.0).uri().host(), Some("api.push.apple.com"));
    }
}
