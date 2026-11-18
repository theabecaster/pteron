//! Sending a push: one `POST <gateway>/v1/push` per phone, with the secret that phone minted
//! for this helper. The gateway holds the APNs key and the phone's token; the helper holds
//! neither.

use crate::devices::Device;
use crate::info;
use crate::net::{Exchange, Url};
use crate::push::PushMessage;
use crate::util::{now, Json};
use serde_json::{json, Value};
use std::time::Duration;

pub const USER_AGENT: &str = concat!("rex-duo-helper/", env!("CARGO_PKG_VERSION"));
/// For the whole request, connect to last byte.
const TIMEOUT: Duration = Duration::from_secs(10);
/// How long APNs keeps a push for a phone that is off.
const KEEP_SECONDS: i64 = 3600;

#[derive(Clone, Debug, PartialEq)]
pub enum SendResult {
    /// With Apple's id for the push, when the gateway passed one on.
    Sent(Option<String>),
    /// 410: Apple dropped the phone's token and the gateway deleted the phone with all its
    /// secrets. Forget the registration; the phone has to register again.
    Gone(String),
    /// 401 in the gateway's own words: it does not know this secret. Once can be a fault on
    /// its side, so the relay gives the secret up only when it hears this twice, a minute
    /// apart (`devices::Strikes`).
    Unauthorized,
    /// 429: the gateway's allowance for this phone is used up. This push is lost like a
    /// failed one.
    Limited(String),
    /// This push is lost. It is not sent again.
    Failed(String),
}

/// The body of `POST /v1/push`: the APNs payload as push.rs builds it, and what used to be
/// the APNs headers.
pub fn push_body(m: &PushMessage, now: f64) -> Value {
    let mut body = json!({
        "payload": m.payload(),
        "push_type": "alert",
        "priority": m.priority(),
        "expiration": now as i64 + KEEP_SECONDS,
    });
    if let Some(c) = &m.collapse_id {
        body["collapse_id"] = json!(c);
    }
    body
}

/// What a dry run logs in place of sending.
pub fn describe(m: &PushMessage) -> String {
    let mut h = format!("priority={}", m.priority());
    if let Some(c) = &m.collapse_id {
        h += &format!(" collapse-id={c}");
    }
    format!("{h} payload={}", m.payload())
}

/// What the gateway's answer means for this phone.
pub fn outcome(status: u16, body: &[u8], retry_after: Option<&str>) -> SendResult {
    let v: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
    // Short machine words only (`unregistered`, `BadDeviceToken`, a UUID), never free text, and
    // nothing as long as a secret.
    let word = |k: &str| {
        v.str(k).filter(|s| (1..=40).contains(&s.len()) && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-'))
    };
    let code = word("error").unwrap_or("error");
    match status {
        200 => SendResult::Sent(word("apns_id").map(String::from)),
        // Every 401 of the gateway has exactly this `error`. A 401 from something in between
        // (a proxy, a sign-in page) says nothing about the secret.
        401 if v.str("error") == Some("unauthorized") => SendResult::Unauthorized,
        401 => SendResult::Failed("something that is not the gateway answered 401".into()),
        410 => SendResult::Gone(word("reason").unwrap_or("unregistered").into()),
        429 => {
            let wait = retry_after.and_then(|s| s.parse::<u32>().ok()).map(|s| format!(", retry after {s} s")).unwrap_or_default();
            SendResult::Limited(format!("the gateway is rate limiting (429{wait})"))
        }
        s => match word("reason") {
            Some(reason) => SendResult::Failed(format!("gateway answered {s} {code}: {reason}")),
            None => SendResult::Failed(format!("gateway answered {s} {code}")),
        },
    }
}

pub enum Sender {
    Gateway,
    /// `--dry-run`: logs what would be sent and makes no network call.
    DryRun,
}

impl Sender {
    pub async fn send(&self, m: &PushMessage, d: &Device) -> SendResult {
        match self {
            Sender::Gateway => post(m, d).await,
            Sender::DryRun => {
                info!(
                    "DRY-RUN push -> {} [{}] via {} {}",
                    d.device_name.as_deref().unwrap_or("?"),
                    d.environment,
                    Url::parse(&d.gateway).map(|u| u.host).unwrap_or_default(),
                    describe(m)
                );
                SendResult::Sent(None)
            }
        }
    }
}

/// One request, no retry: a push that is late is worth less than the next one.
async fn post(m: &PushMessage, d: &Device) -> SendResult {
    let Some(url) = Url::parse(&format!("{}/v1/push", d.gateway)) else {
        return SendResult::Failed("bad gateway address".into());
    };
    let body = push_body(m, now()).to_string();
    let headers = [
        ("Authorization", format!("Bearer {}", d.push_secret)),
        ("Content-Type", "application/json".to_string()),
        ("User-Agent", USER_AGENT.to_string()),
    ];
    let exchange = async {
        let x = Exchange::open("POST", &url, &headers, Some(body.as_bytes())).await?;
        let (status, retry_after) = (x.status, x.header("retry-after").map(String::from));
        // An answer that isn't the gateway's small JSON still tells the status.
        let body = x.body(16 << 10).await.unwrap_or_default();
        Ok::<_, String>(outcome(status, &body, retry_after.as_deref()))
    };
    match tokio::time::timeout(TIMEOUT, exchange).await {
        Ok(Ok(r)) => r,
        Ok(Err(e)) => SendResult::Failed(format!("could not reach the gateway: {e}")),
        Err(_) => SendResult::Failed("the gateway did not answer in 10 s".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::net::testing::{canned, serve, Canned};
    use crate::policy::{BlockRef, PushCategory, PushIntent};
    use crate::push::BlockContext;

    const SECRET: &str = "S3cr3tS3cr3tS3cr3tS3cr3tS3cr3tS3cr3tS3cr3t0";

    fn message(category: PushCategory) -> PushMessage {
        let r = BlockRef { server: "https://rex.example.ts.net".into(), session_id: "session:1".into(), block_id: "block:01a1".into() };
        let mut i = PushIntent::new(category, r);
        i.state = Some("blocked".into());
        i.record_id = Some("rec".into());
        i.agent = Some("claude".into());
        i.text = Some("Which DB?".into());
        PushMessage::compose(&i, &BlockContext { window_id: Some("window:w1".into()), ..Default::default() })
    }

    fn phone(base: &str) -> Device {
        let mut d = Device::new("a1b2c3d4", base, SECRET, "sandbox", "tailscale:12345");
        d.device_name = Some("Alex's iPhone".into());
        d
    }

    /// Against a deployed gateway, by hand (it is skipped otherwise):
    /// `REXDUO_GATEWAY=https://… REXDUO_PUSH_SECRET=… cargo test live_gateway -- --ignored`,
    /// with the secret of a registration whose token no device has. Apple refuses that token,
    /// so the gateway answers 410 and nothing is delivered. It proves this client against the
    /// real TLS endpoint, which the local server in the other tests can't.
    #[tokio::test]
    #[ignore]
    async fn live_gateway_refuses_a_dead_token() {
        let base = std::env::var("REXDUO_GATEWAY").expect("REXDUO_GATEWAY");
        let secret = std::env::var("REXDUO_PUSH_SECRET").expect("REXDUO_PUSH_SECRET");
        let d = Device::new("a1b2c3d4", &base, &secret, "sandbox", "tailscale:12345");
        let first = Sender::Gateway.send(&message(PushCategory::Blocked), &d).await;
        assert!(matches!(first, SendResult::Gone(_)), "{first:?}");
        // The gateway deleted the registration: the secret is now unknown.
        let second = Sender::Gateway.send(&message(PushCategory::Blocked), &d).await;
        assert_eq!(second, SendResult::Unauthorized);
    }

    #[test]
    fn body_is_the_contract() {
        let m = message(PushCategory::Blocked);
        let b = push_body(&m, 1000.9);
        assert_eq!(b["payload"], m.payload());
        assert_eq!(b["payload"]["aps"]["category"], "AGENT_BLOCKED");
        assert_eq!(b["payload"]["aps"]["interruption-level"], "time-sensitive");
        assert_eq!(b["payload"]["aps"]["thread-id"], "block:01a1");
        assert_eq!(b["payload"]["window_id"], "window:w1");
        assert_eq!(b["push_type"], "alert");
        assert_eq!(b["priority"], 10);
        assert_eq!(b["expiration"], 4600);
        assert_eq!(b["collapse_id"], m.collapse_id.clone().unwrap());
        let keys: Vec<&str> = b.as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(keys, ["collapse_id", "expiration", "payload", "priority", "push_type"]);
        // Passive pushes go at priority 5; a notice has no collapse id.
        assert_eq!(push_body(&message(PushCategory::Done), 0.0)["priority"], 5);
        assert!(push_body(&message(PushCategory::Notice), 0.0).get("collapse_id").is_none());
    }

    #[test]
    fn outcomes() {
        assert_eq!(outcome(200, br#"{"apns_id":"abc-1"}"#, None), SendResult::Sent(Some("abc-1".into())));
        assert_eq!(outcome(200, br#"{"apns_id":""}"#, None), SendResult::Sent(None));
        assert_eq!(outcome(200, b"", None), SendResult::Sent(None));
        assert_eq!(outcome(401, br#"{"error":"unauthorized","message":"unknown secret"}"#, None), SendResult::Unauthorized);
        // A 401 that is not the gateway's own JSON is a fault on the way, not a verdict.
        for other in [&b""[..], b"<html>Sign in</html>", b"unauthorized", br#"{"error":"Unauthorized"}"#, br#"{"error":"forbidden"}"#, br#"{"message":"unauthorized"}"#, br#"["unauthorized"]"#] {
            assert!(matches!(outcome(401, other, None), SendResult::Failed(_)), "{}", String::from_utf8_lossy(other));
        }
        assert_eq!(
            outcome(410, br#"{"error":"unregistered","reason":"BadDeviceToken"}"#, None),
            SendResult::Gone("BadDeviceToken".into())
        );
        assert_eq!(outcome(410, b"gone", None), SendResult::Gone("unregistered".into()));
        assert_eq!(
            outcome(429, br#"{"error":"rate_limited"}"#, Some("42")),
            SendResult::Limited("the gateway is rate limiting (429, retry after 42 s)".into())
        );
        assert_eq!(
            outcome(502, br#"{"error":"apns_error","status":403,"reason":"InvalidProviderToken"}"#, None),
            SendResult::Failed("gateway answered 502 apns_error: InvalidProviderToken".into())
        );
        assert_eq!(outcome(413, br#"{"error":"payload_too_large"}"#, None), SendResult::Failed("gateway answered 413 payload_too_large".into()));
        assert_eq!(outcome(500, b"<html>", None), SendResult::Failed("gateway answered 500 error".into()));
        // Free text from the other end stays out of the log.
        assert_eq!(outcome(500, br#"{"error":"two words"}"#, None), SendResult::Failed("gateway answered 500 error".into()));
    }

    #[tokio::test]
    async fn posts_what_the_contract_says() {
        let (base, seen) = serve(vec![canned(200, r#"{"apns_id":"11111111-2222"}"#)]).await;
        let m = message(PushCategory::Blocked);
        let r = Sender::Gateway.send(&m, &phone(&format!("{base}/gw"))).await;
        assert_eq!(r, SendResult::Sent(Some("11111111-2222".into())));
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 1);
        let q = &seen[0];
        assert_eq!((q.method.as_str(), q.path.as_str()), ("POST", "/gw/v1/push"));
        assert_eq!(q.header("authorization"), Some(format!("Bearer {SECRET}").as_str()));
        assert_eq!(q.header("content-type"), Some("application/json"));
        assert_eq!(q.header("user-agent"), Some(concat!("rex-duo-helper/", env!("CARGO_PKG_VERSION"))));
        let body: Value = serde_json::from_slice(&q.body).unwrap();
        assert_eq!(body["payload"], m.payload());
        assert_eq!(body["push_type"], "alert");
        assert_eq!(body["priority"], 10);
        assert_eq!(body["collapse_id"], m.collapse_id.clone().unwrap());
        let expiration = body["expiration"].as_i64().unwrap();
        assert!((expiration - now() as i64 - 3600).abs() < 30);
    }

    #[tokio::test]
    async fn each_status_is_one_request() {
        let retry = Canned { headers: "Retry-After: 7\r\n".into(), ..canned(429, r#"{"error":"rate_limited"}"#) };
        let chunked = Canned { chunked: true, ..canned(410, r#"{"error":"unregistered","reason":"Unregistered"}"#) };
        let (base, seen) = serve(vec![
            canned(401, r#"{"error":"unauthorized","message":"x"}"#),
            chunked,
            retry,
            canned(500, "oops"),
            canned(502, r#"{"error":"apns_unreachable"}"#),
        ])
        .await;
        let (m, d) = (message(PushCategory::Blocked), phone(&base));
        assert_eq!(Sender::Gateway.send(&m, &d).await, SendResult::Unauthorized);
        assert_eq!(Sender::Gateway.send(&m, &d).await, SendResult::Gone("Unregistered".into()));
        assert_eq!(Sender::Gateway.send(&m, &d).await, SendResult::Limited("the gateway is rate limiting (429, retry after 7 s)".into()));
        assert_eq!(Sender::Gateway.send(&m, &d).await, SendResult::Failed("gateway answered 500 error".into()));
        assert_eq!(Sender::Gateway.send(&m, &d).await, SendResult::Failed("gateway answered 502 apns_unreachable".into()));
        assert_eq!(seen.lock().unwrap().len(), 5, "one request per push, no retry");
    }

    #[tokio::test]
    async fn a_gateway_that_is_not_there_fails_the_push() {
        // Bind, note the port, close: nothing listens there now.
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let base = format!("http://127.0.0.1:{}", l.local_addr().unwrap().port());
        drop(l);
        let r = Sender::Gateway.send(&message(PushCategory::Notice), &phone(&base)).await;
        assert!(matches!(&r, SendResult::Failed(why) if why.starts_with("could not reach the gateway")), "{r:?}");
    }

    #[tokio::test]
    async fn a_dry_run_makes_no_request() {
        let (base, seen) = serve(vec![canned(200, "{}")]).await;
        assert_eq!(Sender::DryRun.send(&message(PushCategory::Blocked), &phone(&base)).await, SendResult::Sent(None));
        assert!(seen.lock().unwrap().is_empty());
    }

    #[test]
    fn results_never_carry_the_secret() {
        let echo = format!(r#"{{"error":"{SECRET}","reason":"{SECRET}","message":"{SECRET}","apns_id":"ok"}}"#);
        for status in [200, 401, 410, 429, 500, 502] {
            let text = format!("{:?}", outcome(status, echo.as_bytes(), Some(SECRET)));
            assert!(!text.contains(SECRET), "{text}");
        }
        assert!(!describe(&message(PushCategory::Blocked)).contains(SECRET));
    }
}
