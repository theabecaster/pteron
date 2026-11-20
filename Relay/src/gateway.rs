//! Sending a push: one `POST <gateway>/v1/push` per phone, with the secret that phone minted
//! for this helper. The gateway holds the APNs key and the phone's token; the helper holds
//! neither.

use crate::devices::Device;
use crate::info;
use crate::net::{Exchange, Url};
use crate::presence::{lease_outcome, LeaseAnswer};
use crate::push::PushMessage;
use crate::util::{now, Json};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, Ordering};
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
    /// 202: the gateway held the push (`hold_if_desk`): the person is at a desk that shows the
    /// agent's server. Nothing reached the phone; ask again after these seconds.
    Held(u64),
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
    if let Some(tags) = m.hold_if_desk.as_ref().filter(|t| !t.is_empty()) {
        body["hold_if_desk"] = json!(tags);
    }
    body
}

/// What a dry run logs in place of sending.
pub fn describe(m: &PushMessage) -> String {
    let mut h = format!("priority={}", m.priority());
    if let Some(c) = &m.collapse_id {
        h += &format!(" collapse-id={c}");
    }
    if let Some(tags) = m.hold_if_desk.as_ref().filter(|t| !t.is_empty()) {
        h += &format!(" hold-if-desk={}", tags.len());
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
        202 if v.get("held").and_then(Value::as_bool) == Some(true) => {
            SendResult::Held(v.get("retry_after").and_then(Value::as_u64).filter(|s| (1..=3600).contains(s)).unwrap_or(60))
        }
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
    /// `--dry-run --send-local`: sends to a gateway on this machine (`http://127.0.0.1…`), as
    /// a test runs one, and logs everything else as `DryRun` does. Nothing leaves the machine.
    DryRunLocal,
}

impl Sender {
    /// True when this sender sends to `d`'s gateway for real.
    fn reaches(&self, d: &Device) -> bool {
        match self {
            Sender::Gateway => true,
            Sender::DryRun => false,
            Sender::DryRunLocal => Url::parse(&d.gateway).is_some_and(|u| u.is_loopback()),
        }
    }

    /// True for a sender that asks a gateway at all (a dry run's answers are made up).
    pub fn asks(&self) -> bool {
        !matches!(self, Sender::DryRun)
    }

    /// The lease of one desk for `d`'s phone, for `ttl` seconds (0 removes it). A dry run that
    /// can't reach the gateway pretends it was stored and writes nothing.
    pub async fn lease(&self, d: &Device, tag: &str, ttl: u32) -> LeaseAnswer {
        if !self.reaches(d) {
            crate::debug!("DRY-RUN lease -> {} ttl={ttl}", d.who());
            return LeaseAnswer::Stored;
        }
        put_presence(d, tag, ttl).await
    }

    pub async fn send(&self, m: &PushMessage, d: &Device) -> SendResult {
        if self.reaches(d) {
            return post(m, d).await;
        }
        match self {
            Sender::Gateway => unreachable!("the gateway is always reached"),
            Sender::DryRun | Sender::DryRunLocal => {
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

/// `PUT <gateway>/v1/presence`: one desk's lease, with the phone's secret. One request, no
/// retry: the next look sends it again if it still matters.
async fn put_presence(d: &Device, tag: &str, ttl: u32) -> LeaseAnswer {
    let Some(url) = Url::parse(&format!("{}/v1/presence", d.gateway)) else {
        return LeaseAnswer::Retry("bad gateway address".into());
    };
    let body = json!({"desk": tag, "ttl": ttl}).to_string();
    let headers = [
        ("Authorization", format!("Bearer {}", d.push_secret)),
        ("Content-Type", "application/json".to_string()),
        ("User-Agent", USER_AGENT.to_string()),
    ];
    let exchange = async {
        let x = Exchange::open("PUT", &url, &headers, Some(body.as_bytes())).await?;
        let (status, retry_after) = (x.status, x.header("retry-after").map(String::from));
        let body = x.body(16 << 10).await.unwrap_or_default();
        Ok::<_, String>(lease_outcome(status, &body, retry_after.as_deref()))
    };
    match tokio::time::timeout(TIMEOUT, exchange).await {
        Ok(Ok(a)) => a,
        Ok(Err(e)) => LeaseAnswer::Retry(format!("could not reach the gateway: {e}")),
        Err(_) => LeaseAnswer::Retry("the gateway did not answer in 10 s".into()),
    }
}

/// Said once per run: a gateway refused a question that names its wait.
static PLAIN_AGAIN_LOGGED: AtomicBool = AtomicBool::new(false);

/// One request, no retry: a push that is late is worth less than the next one. The one
/// exception is a question that names its wait (`record`, `fp`, the category with actions)
/// and gets a 400: a gateway from before those fields refuses it whole, so it goes once
/// more as the question every gateway takes, without them. The phone then shows it with no
/// actions, which is better than not at all. Whatever that second request brings stands.
async fn post(m: &PushMessage, d: &Device) -> SendResult {
    let (status, result) = post_once(m, d).await;
    if status != Some(400) || m.wait.is_none() {
        return result;
    }
    if !PLAIN_AGAIN_LOGGED.swap(true, Ordering::Relaxed) {
        info!("the gateway refused a question that names its wait (400): sending such questions again without it");
    }
    post_once(&m.without_wait(), d).await.1
}

/// One request and what came of it, with the status when the gateway answered.
async fn post_once(m: &PushMessage, d: &Device) -> (Option<u16>, SendResult) {
    let Some(url) = Url::parse(&format!("{}/v1/push", d.gateway)) else {
        return (None, SendResult::Failed("bad gateway address".into()));
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
        Ok::<_, String>((Some(status), outcome(status, &body, retry_after.as_deref())))
    };
    match tokio::time::timeout(TIMEOUT, exchange).await {
        Ok(Ok(r)) => r,
        Ok(Err(e)) => (None, SendResult::Failed(format!("could not reach the gateway: {e}"))),
        Err(_) => (None, SendResult::Failed("the gateway did not answer in 10 s".into())),
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
        // A push the gateway held (its 202 for `hold_if_desk`) reached no phone: not Sent, so
        // nothing counts it as shown, and a held question stays held.
        assert_eq!(outcome(202, br#"{"held":true,"retry_after":60}"#, None), SendResult::Held(60));
        assert_eq!(outcome(202, br#"{"held":true,"retry_after":90}"#, None), SendResult::Held(90));
        assert_eq!(outcome(202, br#"{"held":true}"#, None), SendResult::Held(60));
        assert_eq!(outcome(202, br#"{"held":true,"retry_after":99999}"#, None), SendResult::Held(60));
        // A 202 that does not say it held the push is no hold.
        assert!(matches!(outcome(202, b"{}", None), SendResult::Failed(_)));
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

    /// A question that names its wait, as the policy makes one.
    fn question() -> PushMessage {
        let mut i = PushIntent::new(PushCategory::Blocked, BlockRef { server: "https://rex.example.ts.net".into(), session_id: "session:s1".into(), block_id: "block:01a1-b1".into() });
        i.state = Some("blocked".into());
        i.record_id = Some("claude".into());
        i.text = Some("Which DB?".into());
        i.fp = Some(crate::policy::fingerprint("blocked", None, Some("Which DB?")));
        PushMessage::compose(&i, &BlockContext { window_id: Some("window:w1".into()), ..Default::default() }).stacked()
    }

    #[tokio::test]
    async fn a_gateway_from_before_the_wait_gets_the_question_once_more_without_it() {
        crate::util::testing::capture_log();
        let (base, seen) = serve(vec![canned(400, r#"{"error":"invalid_request"}"#), canned(200, r#"{"apns_id":"11111111-2222"}"#)]).await;
        let m = question();
        assert_eq!(m.payload()["aps"]["category"], "AGENT_BLOCKED_ACT");
        let r = Sender::Gateway.send(&m, &phone(&base)).await;
        assert_eq!(r, SendResult::Sent(Some("11111111-2222".into())));
        let bodies: Vec<Value> = seen.lock().unwrap().iter().map(|q| serde_json::from_slice(&q.body).unwrap()).collect();
        assert_eq!(bodies.len(), 2);
        assert_eq!(bodies[0]["payload"], m.payload());
        // The second is the same push in every other way.
        let mut plain = m.payload();
        plain.as_object_mut().unwrap().remove("record");
        plain.as_object_mut().unwrap().remove("fp");
        plain["aps"]["category"] = json!("AGENT_BLOCKED");
        assert_eq!(bodies[1]["payload"], plain);
        assert_eq!((&bodies[1]["collapse_id"], &bodies[1]["priority"], &bodies[1]["push_type"]), (&bodies[0]["collapse_id"], &bodies[0]["priority"], &bodies[0]["push_type"]));
        assert!(bodies[1]["payload"].get("record").is_none() && bodies[1]["payload"].get("fp").is_none());

        // Refused again: that stands, and there is no third request.
        let (base, seen) = serve(vec![canned(400, r#"{"error":"invalid_request"}"#), canned(400, r#"{"error":"invalid_request"}"#), canned(200, "{}")]).await;
        assert_eq!(Sender::Gateway.send(&m, &phone(&base)).await, SendResult::Failed("gateway answered 400 invalid_request".into()));
        assert_eq!(seen.lock().unwrap().len(), 2);
        // Whatever the second brings is the answer.
        let (base, seen) = serve(vec![canned(400, r#"{"error":"invalid_request"}"#), canned(410, r#"{"error":"unregistered","reason":"Unregistered"}"#)]).await;
        assert_eq!(Sender::Gateway.send(&m, &phone(&base)).await, SendResult::Gone("Unregistered".into()));
        assert_eq!(seen.lock().unwrap().len(), 2);
        // Said once, however often it happens, and without a word of the push.
        let log = crate::util::testing::captured_log();
        assert!(log.matches("refused a question that names its wait").count() <= 1, "{log}");
        assert!(!log.contains("Which DB?") && !log.contains("claude"), "{log}");
    }

    #[tokio::test]
    async fn nothing_else_is_ever_sent_twice() {
        // Any other answer to a question that names its wait: one request.
        for (status, body) in [(401, r#"{"error":"unauthorized"}"#), (413, r#"{"error":"payload_too_large"}"#), (429, r#"{"error":"rate_limited"}"#), (500, "boom"), (502, r#"{"error":"apns_error"}"#)] {
            let (base, seen) = serve(vec![canned(status, body), canned(200, "{}")]).await;
            assert!(!matches!(Sender::Gateway.send(&question(), &phone(&base)).await, SendResult::Sent(_)), "{status}");
            assert_eq!(seen.lock().unwrap().len(), 1, "{status}");
        }
        // A 400 for a push that names no wait: one request. There is nothing to leave out.
        for m in [question().without_wait(), message(PushCategory::Done), message(PushCategory::Notice), PushMessage::test("https://rex.example.ts.net")] {
            let (base, seen) = serve(vec![canned(400, r#"{"error":"invalid_request"}"#), canned(200, "{}")]).await;
            assert_eq!(Sender::Gateway.send(&m, &phone(&base)).await, SendResult::Failed("gateway answered 400 invalid_request".into()));
            assert_eq!(seen.lock().unwrap().len(), 1);
        }
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
        assert_eq!(Sender::DryRun.lease(&phone(&base), "tag", 600).await, LeaseAnswer::Stored);
        assert!(seen.lock().unwrap().is_empty());
        // With --send-local, a gateway on this machine is asked; any other is not.
        assert!(!Sender::DryRunLocal.reaches(&phone("https://push.example.com")));
        assert!(!Sender::DryRunLocal.reaches(&phone("http://127.0.0.1.evil.example")));
        assert_eq!(Sender::DryRunLocal.send(&message(PushCategory::Blocked), &phone("https://push.example.com")).await, SendResult::Sent(None));
        assert_eq!(Sender::DryRunLocal.send(&message(PushCategory::Blocked), &phone(&base)).await, SendResult::Sent(None));
        assert_eq!(seen.lock().unwrap().len(), 1);
    }

    #[test]
    fn a_push_carries_hold_if_desk_only_when_it_names_a_desk() {
        let mut m = message(PushCategory::Blocked);
        assert!(push_body(&m, 0.0).get("hold_if_desk").is_none());
        m.hold_if_desk = Some(vec![]);
        assert!(push_body(&m, 0.0).get("hold_if_desk").is_none());
        m.hold_if_desk = Some(vec!["deskMacBook0000000000a".into()]);
        assert_eq!(push_body(&m, 0.0)["hold_if_desk"], json!(["deskMacBook0000000000a"]));
        assert!(describe(&m).contains("hold-if-desk=1"));
    }

    #[tokio::test]
    async fn a_lease_is_one_put_with_the_secret_and_its_answers_read_as_meant() {
        let retry = Canned { headers: "Retry-After: 30\r\n".into(), ..canned(429, r#"{"error":"rate_limited"}"#) };
        let (base, seen) = serve(vec![
            canned(200, r#"{"stored":true}"#),
            canned(200, r#"{"stored":false}"#),
            canned(404, r#"{"error":"not_found"}"#),
            retry,
            canned(503, r#"{"error":"presence_unavailable"}"#),
        ])
        .await;
        let d = phone(&format!("{base}/gw"));
        assert_eq!(Sender::Gateway.lease(&d, "deskMacBook0000000000a", 600).await, LeaseAnswer::Stored);
        assert_eq!(Sender::Gateway.lease(&d, "deskMacBook0000000000a", 0).await, LeaseAnswer::NotStored);
        assert_eq!(Sender::Gateway.lease(&d, "deskMacBook0000000000a", 600).await, LeaseAnswer::Absent);
        assert_eq!(Sender::Gateway.lease(&d, "deskMacBook0000000000a", 600).await, LeaseAnswer::Limited(30.0));
        assert!(matches!(Sender::Gateway.lease(&d, "deskMacBook0000000000a", 600).await, LeaseAnswer::Retry(_)));
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 5);
        let q = &seen[0];
        assert_eq!((q.method.as_str(), q.path.as_str()), ("PUT", "/gw/v1/presence"));
        assert_eq!(q.header("authorization"), Some(format!("Bearer {SECRET}").as_str()));
        let body: Value = serde_json::from_slice(&q.body).unwrap();
        assert_eq!(body, json!({"desk": "deskMacBook0000000000a", "ttl": 600}));
        assert_eq!(serde_json::from_slice::<Value>(&seen[1].body).unwrap()["ttl"], 0);
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
