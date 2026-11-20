//! Desk presence across computers, through the push gateway (Relay/README.md, "Desk
//! presence"). A Beacon at a desk writes leases at the gateway, "the person is at desk D until
//! T"; a Beacon whose agents run on a computer nobody sits at names the desks that show its
//! server in `hold_if_desk`, and the gateway holds the push while one of them has a lease.
//!
//! A desk is named by a tag the gateway can't read back: an HMAC of the Rex desktop app's
//! label under a key the phone made and gave only to its own computers (`presence_key` in
//! `register_push`). Without a key nothing here runs for that phone, and it is pushed to as
//! before.
//!
//! Pure: the leases' state and the reading of the gateway's answers. relay.rs sends.

use crate::devices::ClientSnapshot;
use crate::util::{base64_decode, base64url, Json};
use serde_json::Value;
use std::collections::HashMap;

// Fixed choices (Relay/README.md, "Desk presence").

/// How long a lease runs, in seconds. The gateway takes at most 900.
pub const LEASE_TTL: u32 = 600;
/// A lease is written again this long after the last one the gateway stored.
pub const RENEW_AFTER: f64 = 300.0;
/// A question the gateway held is asked about again this often, one per phone and server.
pub const PROBE_EVERY: f64 = 60.0;
/// The most desk tags one push names (the gateway ignores the field past that).
pub const MAX_HOLD_TAGS: usize = 8;
/// A gateway without presence (`404`) is asked again after this long.
pub const ABSENT_BACKOFF: f64 = 86_400.0;

const TAG_CONTEXT: &str = "rexduo-desk-v1\n";

/// The phone's presence key: 32 bytes, as base64url without padding (43 characters).
#[derive(Clone)]
pub struct PresenceKey([u8; 32]);

impl PresenceKey {
    /// The key in the only spelling 32 bytes have, or None.
    pub fn parse(s: &str) -> Option<PresenceKey> {
        if s.len() != 43 || !s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') {
            return None;
        }
        let bytes: [u8; 32] = base64_decode(s)?.try_into().ok()?;
        (base64url(&bytes) == s).then_some(PresenceKey(bytes))
    }

    /// The desk's tag: `base64url(HMAC-SHA256(key, "rexduo-desk-v1\n" + label))[:22]`.
    pub fn tag(&self, label: &str) -> String {
        let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, &self.0);
        let mac = ring::hmac::sign(&key, format!("{TAG_CONTEXT}{label}").as_bytes());
        base64url(mac.as_ref())[..22].to_string()
    }
}

/// A Rex desktop app among a server's clients: connected, not the phone app, with a label
/// (the computer's name, which the same app has on every server it shows). Where it runs plays
/// no part: the Mac app of another computer reaches this server through SSH under its own
/// label, and that is the desk this server's questions may wait for.
pub fn shows_desk(c: &ClientSnapshot) -> bool {
    c.kind.as_deref() == Some("app")
        && c.platform.as_deref().is_some_and(|p| !p.is_empty() && p != "ios")
        && c.connection_state.as_deref() == Some("connected")
        && c.label.as_deref().is_some_and(|l| !l.trim().is_empty())
}

/// `hold_if_desk` for one phone: the tags of the desks that show the agent's server, at most
/// `MAX_HOLD_TAGS`, or none.
pub fn hold_tags(key: &PresenceKey, server_clients: &[ClientSnapshot]) -> Vec<String> {
    let mut labels: Vec<&str> = server_clients.iter().filter(|c| shows_desk(c)).filter_map(|c| c.label.as_deref()).collect();
    labels.sort_unstable();
    labels.dedup();
    labels.truncate(MAX_HOLD_TAGS);
    labels.into_iter().map(|l| key.tag(l)).collect()
}

/// What the gateway said to one `PUT /v1/presence`.
#[derive(Clone, Debug, PartialEq)]
pub enum LeaseAnswer {
    /// Stored, or removed for `ttl: 0`.
    Stored,
    /// The secret is not flagged as the phone's own computer: no lease for this phone until it
    /// registers again.
    NotStored,
    /// A gateway without presence (`404`, or the `"off": true` an unreleased one answered).
    Absent,
    /// `429`, with the seconds to wait.
    Limited(f64),
    /// The gateway's own `401`: as for a push (`devices::Strikes`).
    Unauthorized,
    /// `410`: as for a push, the phone is gone.
    Gone(String),
    /// Anything else (no network, `503`, a proxy's answer): tried again at the next look.
    Retry(String),
}

/// Reads the gateway's answer to a lease.
pub fn lease_outcome(status: u16, body: &[u8], retry_after: Option<&str>) -> LeaseAnswer {
    let v: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
    match status {
        200 => match v.get("stored").and_then(Value::as_bool) {
            Some(true) => LeaseAnswer::Stored,
            Some(false) if v.get("off").and_then(Value::as_bool) == Some(true) => LeaseAnswer::Absent,
            Some(false) => LeaseAnswer::NotStored,
            None => LeaseAnswer::Retry("the gateway's answer did not say whether it stored the lease".into()),
        },
        404 => LeaseAnswer::Absent,
        429 => LeaseAnswer::Limited(retry_after.and_then(|s| s.trim().parse::<f64>().ok()).filter(|s| s.is_finite() && *s > 0.0).unwrap_or(60.0)),
        401 if v.str("error") == Some("unauthorized") => LeaseAnswer::Unauthorized,
        410 => {
            let reason = v.str("reason").filter(|r| (1..=40).contains(&r.len()) && r.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_'));
            LeaseAnswer::Gone(reason.unwrap_or("unregistered").into())
        }
        s => LeaseAnswer::Retry(format!("the gateway answered {s}")),
    }
}

/// One request to make: this phone's lease of this desk, for `ttl` seconds (0 removes it).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Put {
    pub device_id: String,
    pub tag: String,
    pub ttl: u32,
}

/// A lease the gateway stored, by this computer's clock.
#[derive(Clone, Copy, Debug)]
struct Lease {
    until: f64,
    renewed_at: f64,
}

#[derive(Debug, Default)]
struct Phone {
    leases: HashMap<String, Lease>,
    /// The gateway said this phone's secret is not one of its own computers'.
    stopped: bool,
    /// Nothing is written before this (a gateway without presence, a rate limit).
    wait_until: f64,
}

/// The leases this Beacon holds at the gateway, per phone, kept in memory: after a restart a
/// lease left at the gateway ends by itself within `LEASE_TTL`.
#[derive(Debug, Default)]
pub struct Leases {
    phones: HashMap<String, Phone>,
}

impl Leases {
    /// What to send for one phone at `now`, given the desks it should hold (`want`; none when
    /// nobody is at a desk here, the computer sleeps, or the phone has no key): a lease for a
    /// desk not held yet or held `RENEW_AFTER`, a removal for one held and no longer wanted.
    /// A removal that fails is sent again at each look until the lease would have ended.
    pub fn plan(&mut self, device_id: &str, want: &[String], now: f64) -> Vec<Put> {
        let phone = self.phones.entry(device_id.to_string()).or_default();
        phone.leases.retain(|_, l| l.until > now);
        if phone.stopped || now < phone.wait_until {
            return vec![];
        }
        let put = |tag: &str, ttl| Put { device_id: device_id.to_string(), tag: tag.to_string(), ttl };
        let mut out: Vec<Put> = want
            .iter()
            .filter(|t| phone.leases.get(*t).is_none_or(|l| now - l.renewed_at >= RENEW_AFTER || now < l.renewed_at))
            .map(|t| put(t, LEASE_TTL))
            .collect();
        let mut gone: Vec<&String> = phone.leases.keys().filter(|t| !want.contains(t)).collect();
        gone.sort();
        out.extend(gone.into_iter().map(|t| put(t, 0)));
        out
    }

    /// What the gateway answered to `put` at `now`.
    pub fn answer(&mut self, put: &Put, answer: &LeaseAnswer, now: f64) {
        let phone = self.phones.entry(put.device_id.clone()).or_default();
        match answer {
            LeaseAnswer::Stored if put.ttl > 0 => {
                phone.leases.insert(put.tag.clone(), Lease { until: now + f64::from(put.ttl), renewed_at: now });
            }
            LeaseAnswer::Stored => {
                phone.leases.remove(&put.tag);
            }
            LeaseAnswer::NotStored => {
                phone.stopped = true;
                phone.leases.clear();
            }
            LeaseAnswer::Absent => {
                phone.wait_until = now + ABSENT_BACKOFF;
                phone.leases.clear();
            }
            LeaseAnswer::Limited(wait) => phone.wait_until = now + wait.max(1.0),
            LeaseAnswer::Unauthorized | LeaseAnswer::Gone(_) => phone.leases.clear(),
            LeaseAnswer::Retry(_) => {}
        }
    }

    /// The phone registered again: a gateway that said no, or to wait, is asked again.
    pub fn registered(&mut self, device_id: &str) {
        if let Some(p) = self.phones.get_mut(device_id) {
            p.stopped = false;
            p.wait_until = 0.0;
        }
    }

    /// The phone is no longer registered here: its secret went with it, and at the gateway its
    /// leases with that.
    pub fn forget(&mut self, device_id: &str) {
        self.phones.remove(device_id);
    }

    /// The phones this holds something for, so a phone whose key went still gets its removals.
    pub fn phones(&self) -> Vec<String> {
        self.phones.iter().filter(|(_, p)| !p.leases.is_empty()).map(|(id, _)| id.clone()).collect()
    }

    /// True while a lease of this phone is held, as far as this Beacon knows.
    pub fn holds(&self, device_id: &str, tag: &str) -> bool {
        self.phones.get(device_id).is_some_and(|p| p.leases.contains_key(tag))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Thirty-two bytes 0..32, as base64url.
    const KEY: &str = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
    const PHONE: &str = "a1b2c3d4";

    fn key() -> PresenceKey {
        PresenceKey::parse(KEY).unwrap()
    }

    #[test]
    fn a_key_is_32_bytes_in_their_one_spelling() {
        assert!(PresenceKey::parse(KEY).is_some());
        for bad in ["", "short", &KEY[..42], &format!("{KEY}A"), &format!("{}=", &KEY[..42]), &KEY.replace('A', "+"), &KEY.replace('A', "/")] {
            assert!(PresenceKey::parse(bad).is_none(), "{bad:?}");
        }
        // The last character carries 2 spare bits: only the spelling with them clear is one.
        assert!(PresenceKey::parse(&format!("{}9", &KEY[..42])).is_none());
    }

    #[test]
    fn the_tag_is_the_hmac_the_gateway_and_the_app_agree_on() {
        // HMAC-SHA256(key 0..32, "rexduo-desk-v1\nMBP_M4MAX"), base64url, the first 22.
        let expected = {
            let k = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, &(0u8..32).collect::<Vec<_>>());
            base64url(ring::hmac::sign(&k, b"rexduo-desk-v1\nMBP_M4MAX").as_ref())[..22].to_string()
        };
        let t = key().tag("MBP_M4MAX");
        assert_eq!(t, expected);
        assert_eq!(t.len(), 22);
        assert!(t.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'));
        assert_ne!(key().tag("MBP_M4MAX"), key().tag("macdesk"));
        let other = PresenceKey::parse("AQECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8").unwrap();
        assert_ne!(other.tag("MBP_M4MAX"), t, "another phone's key makes another tag");
    }

    fn client(label: &str, platform: &str, state: &str) -> ClientSnapshot {
        ClientSnapshot {
            client_id: format!("client:{label}"),
            kind: Some("app".into()),
            platform: Some(platform.into()),
            label: Some(label.into()),
            connection_state: Some(state.into()),
            ..Default::default()
        }
    }

    #[test]
    fn a_push_names_the_desks_that_show_its_server_and_no_more_than_eight() {
        let clients = [
            client("MBP_M4MAX", "macos", "connected"),
            client("MBP_M4MAX", "macos", "connected"),
            client("macdesk", "macos", "connected"),
            client("Alex's iPhone #a1b2c3d4", "ios", "connected"),
            client("gone", "macos", "lost"),
            client(" ", "macos", "connected"),
        ];
        let tags = hold_tags(&key(), &clients);
        assert_eq!(tags, vec![key().tag("MBP_M4MAX"), key().tag("macdesk")]);
        let mut beacon = client("rex-push-relay", "macos", "connected");
        beacon.kind = Some("other".into());
        assert!(hold_tags(&key(), &[beacon]).is_empty());
        let many: Vec<ClientSnapshot> = (0..12).map(|n| client(&format!("desk{n:02}"), "linux", "connected")).collect();
        assert_eq!(hold_tags(&key(), &many).len(), MAX_HOLD_TAGS);
    }

    #[test]
    fn the_gateways_answers_read_as_the_gateway_means_them() {
        assert_eq!(lease_outcome(200, br#"{"stored":true}"#, None), LeaseAnswer::Stored);
        assert_eq!(lease_outcome(200, br#"{"stored":false}"#, None), LeaseAnswer::NotStored);
        assert_eq!(lease_outcome(200, br#"{"stored":false,"off":true}"#, None), LeaseAnswer::Absent);
        assert!(matches!(lease_outcome(200, b"<html>", None), LeaseAnswer::Retry(_)));
        assert_eq!(lease_outcome(404, br#"{"error":"not_found"}"#, None), LeaseAnswer::Absent);
        assert_eq!(lease_outcome(429, b"{}", Some("120")), LeaseAnswer::Limited(120.0));
        assert_eq!(lease_outcome(429, b"{}", Some("soon")), LeaseAnswer::Limited(60.0));
        assert_eq!(lease_outcome(401, br#"{"error":"unauthorized"}"#, None), LeaseAnswer::Unauthorized);
        assert!(matches!(lease_outcome(401, b"sign in", None), LeaseAnswer::Retry(_)), "a proxy's 401 says nothing about the secret");
        assert_eq!(lease_outcome(410, br#"{"error":"unregistered"}"#, None), LeaseAnswer::Gone("unregistered".into()));
        for s in [400, 500, 502, 503] {
            assert!(matches!(lease_outcome(s, br#"{"error":"presence_unavailable"}"#, None), LeaseAnswer::Retry(_)), "{s}");
        }
    }

    fn tags(names: &[&str]) -> Vec<String> {
        names.iter().map(|n| key().tag(n)).collect()
    }

    fn put(tag: &str, ttl: u32) -> Put {
        Put { device_id: PHONE.into(), tag: key().tag(tag), ttl }
    }

    #[test]
    fn a_desk_is_leased_on_arrival_renewed_every_five_minutes_and_removed_on_leaving() {
        let mut l = Leases::default();
        let want = tags(&["MBP_M4MAX"]);
        assert_eq!(l.plan(PHONE, &want, 0.0), vec![put("MBP_M4MAX", LEASE_TTL)]);
        l.answer(&put("MBP_M4MAX", LEASE_TTL), &LeaseAnswer::Stored, 0.0);
        assert!(l.holds(PHONE, &want[0]));
        // Looked at every 30 s: nothing until the renewal.
        for t in [30.0, 60.0, RENEW_AFTER - 1.0] {
            assert!(l.plan(PHONE, &want, t).is_empty(), "{t}");
        }
        assert_eq!(l.plan(PHONE, &want, RENEW_AFTER), vec![put("MBP_M4MAX", LEASE_TTL)]);
        l.answer(&put("MBP_M4MAX", LEASE_TTL), &LeaseAnswer::Stored, RENEW_AFTER);
        // Away: removed at once.
        assert_eq!(l.plan(PHONE, &[], RENEW_AFTER + 30.0), vec![put("MBP_M4MAX", 0)]);
        l.answer(&put("MBP_M4MAX", 0), &LeaseAnswer::Stored, RENEW_AFTER + 30.0);
        assert!(l.plan(PHONE, &[], RENEW_AFTER + 60.0).is_empty());
        assert!(l.phones().is_empty());
    }

    #[test]
    fn a_failed_removal_is_tried_again_until_the_lease_would_have_ended() {
        let mut l = Leases::default();
        l.answer(&put("MBP_M4MAX", LEASE_TTL), &LeaseAnswer::Stored, 0.0);
        for t in [30.0, 60.0, 590.0] {
            assert_eq!(l.plan(PHONE, &[], t), vec![put("MBP_M4MAX", 0)], "{t}");
            l.answer(&put("MBP_M4MAX", 0), &LeaseAnswer::Retry("no network".into()), t);
        }
        assert!(l.plan(PHONE, &[], f64::from(LEASE_TTL)).is_empty(), "it has ended at the gateway by itself");
        // A failed lease is tried again at the next look too.
        assert_eq!(l.plan(PHONE, &tags(&["macdesk"]), 700.0), vec![put("macdesk", LEASE_TTL)]);
        l.answer(&put("macdesk", LEASE_TTL), &LeaseAnswer::Retry("503".into()), 700.0);
        assert_eq!(l.plan(PHONE, &tags(&["macdesk"]), 730.0), vec![put("macdesk", LEASE_TTL)]);
    }

    #[test]
    fn not_stored_stops_until_the_next_registration_and_a_404_waits_a_day() {
        let mut l = Leases::default();
        let want = tags(&["MBP_M4MAX"]);
        l.answer(&put("MBP_M4MAX", LEASE_TTL), &LeaseAnswer::NotStored, 0.0);
        assert!(l.plan(PHONE, &want, 30.0).is_empty());
        assert!(l.plan(PHONE, &want, 10.0 * ABSENT_BACKOFF).is_empty(), "until the phone registers again");
        l.registered(PHONE);
        assert_eq!(l.plan(PHONE, &want, 10.0 * ABSENT_BACKOFF).len(), 1);

        let mut l = Leases::default();
        l.answer(&put("MBP_M4MAX", LEASE_TTL), &LeaseAnswer::Absent, 0.0);
        assert!(l.plan(PHONE, &want, ABSENT_BACKOFF - 1.0).is_empty());
        assert_eq!(l.plan(PHONE, &want, ABSENT_BACKOFF).len(), 1);

        let mut l = Leases::default();
        l.answer(&put("MBP_M4MAX", LEASE_TTL), &LeaseAnswer::Limited(120.0), 0.0);
        assert!(l.plan(PHONE, &want, 119.0).is_empty());
        assert_eq!(l.plan(PHONE, &want, 120.0).len(), 1);

        // The gateway refused the secret or dropped the phone: nothing held is remembered.
        let mut l = Leases::default();
        l.answer(&put("MBP_M4MAX", LEASE_TTL), &LeaseAnswer::Stored, 0.0);
        l.answer(&put("MBP_M4MAX", LEASE_TTL), &LeaseAnswer::Gone("unregistered".into()), 30.0);
        assert!(l.phones().is_empty());
    }

    #[test]
    fn several_desks_each_have_their_lease_and_a_clock_set_back_renews() {
        let mut l = Leases::default();
        let both = tags(&["MBP_M4MAX", "macdesk"]);
        assert_eq!(l.plan(PHONE, &both, 1000.0).len(), 2);
        for t in &both {
            l.answer(&Put { device_id: PHONE.into(), tag: t.clone(), ttl: LEASE_TTL }, &LeaseAnswer::Stored, 1000.0);
        }
        assert_eq!(l.plan(PHONE, &tags(&["macdesk"]), 1030.0), vec![put("MBP_M4MAX", 0)]);
        assert_eq!(l.plan(PHONE, &both, 900.0), vec![put("MBP_M4MAX", LEASE_TTL), put("macdesk", LEASE_TTL)]);
        l.forget(PHONE);
        assert!(l.phones().is_empty());
    }
}
