//! Small helpers: loose JSON accessors (Rex's API is loosely typed), time, base64, logging.

use serde_json::Value;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

/// Read access to a JSON object, mirroring RexKit's accessors in the app.
pub trait Json {
    fn str(&self, k: &str) -> Option<&str>;
    /// A string field that is present and not blank, trimmed.
    fn text(&self, k: &str) -> Option<String>;
    fn obj(&self, k: &str) -> Option<&Value>;
    /// The objects in an array field (other elements are skipped).
    fn arr(&self, k: &str) -> Vec<&Value>;
    fn int(&self, k: &str) -> Option<i64>;
    fn bool(&self, k: &str) -> Option<bool>;
}

impl Json for Value {
    fn str(&self, k: &str) -> Option<&str> {
        self.get(k)?.as_str()
    }
    fn text(&self, k: &str) -> Option<String> {
        let t = self.str(k)?.trim();
        (!t.is_empty()).then(|| t.to_string())
    }
    fn obj(&self, k: &str) -> Option<&Value> {
        self.get(k).filter(|v| v.is_object())
    }
    fn arr(&self, k: &str) -> Vec<&Value> {
        match self.get(k) {
            Some(Value::Array(a)) => a.iter().filter(|v| v.is_object()).collect(),
            _ => vec![],
        }
    }
    fn int(&self, k: &str) -> Option<i64> {
        let v = self.get(k)?;
        v.as_i64().or_else(|| v.as_f64().map(|f| f as i64))
    }
    fn bool(&self, k: &str) -> Option<bool> {
        self.get(k)?.as_bool()
    }
}

/// Seconds since 1970, as the push policy counts time.
pub fn now() -> f64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

/// `2026-11-16T19:56:39Z`, the format devices.json has always used.
pub fn iso8601(secs: i64) -> String {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    // Civil date from days since the epoch (Howard Hinnant's algorithm).
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem % 3600 / 60, rem % 60)
}

pub fn now_iso() -> String {
    iso8601(now() as i64)
}

/// Seconds since 1970 for a time written exactly as `iso8601` writes it
/// (`YYYY-MM-DDTHH:MM:SSZ`). Any other spelling is refused, so two such strings also compare
/// as text, which is what install.sh does.
pub fn parse_iso8601(s: &str) -> Option<i64> {
    let b = s.as_bytes();
    let shape = b.len() == 20
        && b.iter().enumerate().all(|(i, c)| match i {
            4 | 7 => *c == b'-',
            10 => *c == b'T',
            13 | 16 => *c == b':',
            19 => *c == b'Z',
            _ => c.is_ascii_digit(),
        });
    if !shape {
        return None;
    }
    let n = |r: std::ops::Range<usize>| s[r].parse::<i64>().ok();
    let (y, m, d, h, min, sec) = (n(0..4)?, n(5..7)?, n(8..10)?, n(11..13)?, n(14..16)?, n(17..19)?);
    if !(1970..=9999).contains(&y) || !(1..=12).contains(&m) || !(1..=31).contains(&d) || h > 23 || min > 59 || sec > 59 {
        return None;
    }
    // Days since the epoch from a civil date (Howard Hinnant's algorithm, the inverse of the
    // one in `iso8601`).
    let y2 = if m <= 2 { y - 1 } else { y };
    let era = y2.div_euclid(400);
    let yoe = y2.rem_euclid(400);
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let secs = (era * 146_097 + doe - 719_468) * 86_400 + h * 3600 + min * 60 + sec;
    // A day that doesn't exist (February 30) would come back as another date.
    (iso8601(secs) == s).then_some(secs)
}

/// SHA-256 in lowercase hex.
pub fn sha256_hex(data: &[u8]) -> String {
    ring::digest::digest(&ring::digest::SHA256, data).as_ref().iter().map(|b| format!("{b:02x}")).collect()
}

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn encode64(data: &[u8], url: bool) -> String {
    let mut out = String::with_capacity(data.len() * 4 / 3 + 3);
    for chunk in data.chunks(3) {
        let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
        let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
        for i in 0..=chunk.len() {
            let c = B64[((n >> (18 - 6 * i)) & 63) as usize];
            out.push(match c {
                b'+' if url => '-',
                b'/' if url => '_',
                c => c as char,
            });
        }
        if !url {
            out.push_str(&"=".repeat(3 - chunk.len()));
        }
    }
    out
}

/// Standard base64 with padding: how the helper's public key and signatures go to the app.
pub fn base64(data: &[u8]) -> String {
    encode64(data, false)
}

/// Base64url without padding. Only tests encode this way (they sign with a key made on the spot).
#[cfg(test)]
pub fn base64url(data: &[u8]) -> String {
    encode64(data, true)
}

/// Decodes standard or url-safe base64, padded or not, skipping whitespace.
pub fn base64_decode(s: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0u32);
    for c in s.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            b'=' | b'\r' | b'\n' | b' ' | b'\t' => continue,
            _ => return None,
        };
        acc = (acc << 6) | u32::from(v);
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Some(out)
}

// MARK: Logging

static VERBOSE: AtomicBool = AtomicBool::new(false);
static FILE: Mutex<Option<LogFile>> = Mutex::new(None);

struct LogFile {
    path: PathBuf,
    file: std::fs::File,
    size: u64,
}

/// Rotates at 1 MB, keeping one older file, so the log never grows without bound.
const LOG_LIMIT: u64 = 1 << 20;

pub fn set_verbose(on: bool) {
    VERBOSE.store(on, Ordering::Relaxed);
}

pub fn verbose() -> bool {
    VERBOSE.load(Ordering::Relaxed)
}

/// Sends log lines to a file instead of stdout (the Mac's background job has no terminal).
pub fn log_to_file(path: PathBuf) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let file = std::fs::OpenOptions::new().create(true).append(true).open(&path)?;
    let size = file.metadata().map(|m| m.len()).unwrap_or(0);
    *FILE.lock().unwrap() = Some(LogFile { path, file, size });
    Ok(())
}

/// What a test's own thread logged, so a test can read its lines without the other tests'
/// (each test, and the tasks it spawns, runs on one thread).
#[cfg(test)]
pub mod testing {
    use std::cell::RefCell;

    thread_local! {
        pub(super) static CAPTURED: RefCell<Option<Vec<String>>> = const { RefCell::new(None) };
    }

    /// From now on this thread's log lines are kept instead of printed.
    pub fn capture_log() {
        CAPTURED.with(|c| *c.borrow_mut() = Some(vec![]));
    }

    pub fn captured_log() -> String {
        CAPTURED.with(|c| c.borrow().clone().unwrap_or_default().join("\n"))
    }
}

pub fn emit(line: &str) {
    #[cfg(test)]
    if testing::CAPTURED.with(|c| c.borrow_mut().as_mut().map(|lines| lines.push(line.to_string())).is_some()) {
        return;
    }
    // systemd's journal stamps lines itself.
    let stamped = if std::env::var_os("JOURNAL_STREAM").is_some() {
        format!("{line}\n")
    } else {
        format!("{} {line}\n", now_iso())
    };
    let mut guard = FILE.lock().unwrap();
    if let Some(f) = guard.as_mut() {
        if f.size > LOG_LIMIT {
            let old = f.path.with_extension("old.log");
            let _ = std::fs::rename(&f.path, old);
            if let Ok(nf) = std::fs::OpenOptions::new().create(true).append(true).open(&f.path) {
                f.file = nf;
                f.size = 0;
            }
        }
        let _ = f.file.write_all(stamped.as_bytes());
        f.size += stamped.len() as u64;
        return;
    }
    let mut out = std::io::stdout().lock();
    let _ = out.write_all(stamped.as_bytes());
    let _ = out.flush();
}

#[macro_export]
macro_rules! info {
    ($($t:tt)*) => { $crate::util::emit(&format!($($t)*)) };
}

#[macro_export]
macro_rules! debug {
    ($($t:tt)*) => { if $crate::util::verbose() { $crate::util::emit(&format!($($t)*)) } };
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates() {
        assert_eq!(iso8601(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso8601(1_763_322_999), "2025-11-16T19:56:39Z");
        assert_eq!(iso8601(951_782_400), "2000-02-29T00:00:00Z");
        for secs in [0, 1_763_322_999, 951_782_400, 1_826_539_200, 4_102_444_799] {
            assert_eq!(parse_iso8601(&iso8601(secs)), Some(secs));
        }
        for bad in ["", "2026-11-17", "2026-11-17T12:00:00", "2026-11-17 12:00:00Z", "2026-11-17T12:00:00+00:00", "2026-02-30T00:00:00Z",
            "2026-13-01T00:00:00Z", "2026-11-17T24:00:00Z", "2026-11-17T12:00:00.5Z", "2026-11-17t12:00:00z", " 2026-11-17T12:00:00Z"] {
            assert_eq!(parse_iso8601(bad), None, "{bad:?}");
        }
    }

    #[test]
    fn base64_round_trip() {
        for s in ["", "f", "fo", "foo", "foob", "fooba", "foobar", "\u{ff}\u{fe}?>"] {
            let enc = base64url(s.as_bytes());
            assert!(!enc.contains('=') && !enc.contains('+') && !enc.contains('/'));
            assert_eq!(base64_decode(&enc).unwrap(), s.as_bytes());
        }
        assert_eq!(base64url(b"foobar"), "Zm9vYmFy");
        assert_eq!(base64_decode("Zm9vYg==").unwrap(), b"foob");
        assert_eq!((base64(b"foob").as_str(), base64(b"fooba").as_str(), base64(b"foobar").as_str()), ("Zm9vYg==", "Zm9vYmE=", "Zm9vYmFy"));
        assert_eq!(base64(&[0xfb, 0xff]), "+/8=");
    }

    #[test]
    fn json_accessors() {
        let v = serde_json::json!({"a": " hi ", "b": "  ", "n": 3.0, "o": {"x": 1}, "l": [{"y": 1}, 2]});
        assert_eq!(v.text("a").as_deref(), Some("hi"));
        assert_eq!(v.text("b"), None);
        assert_eq!(v.int("n"), Some(3));
        assert!(v.obj("o").is_some() && v.obj("a").is_none());
        assert_eq!(v.arr("l").len(), 1);
    }
}
