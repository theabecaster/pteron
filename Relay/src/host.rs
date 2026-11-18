//! The name of this computer's system, as `helper_status` reports it in `os`: "macOS 15.5",
//! "Ubuntu 24.04.1 LTS". One plain line of at most `OS_LIMIT` printable ASCII characters,
//! read once when the helper starts.

/// The most characters of an `os` value.
pub const OS_LIMIT: usize = 64;

/// The system this helper runs on.
pub fn os() -> String {
    #[cfg(target_os = "macos")]
    return macos(product_version().as_deref());
    #[cfg(not(target_os = "macos"))]
    return linux(std::fs::read_to_string("/etc/os-release").ok().as_deref());
}

/// What `sw_vers -productVersion` printed, if it ran.
#[cfg(target_os = "macos")]
fn product_version() -> Option<String> {
    use std::process::Stdio;
    let o = crate::tools::command("sw_vers")?.arg("-productVersion").stdin(Stdio::null()).stderr(Stdio::null()).output().ok()?;
    o.status.success().then(|| String::from_utf8_lossy(&o.stdout).into_owned())
}

/// "macOS " and the product version, or "macOS" alone when there is none to show.
#[cfg_attr(not(any(target_os = "macos", test)), allow(dead_code))]
pub fn macos(version: Option<&str>) -> String {
    let version = clean(version.and_then(|v| v.lines().next()).unwrap_or(""), OS_LIMIT - "macOS ".len());
    if version.is_empty() {
        "macOS".into()
    } else {
        format!("macOS {version}")
    }
}

/// `PRETTY_NAME` of an os-release file, or "Linux" when the file or the name is missing.
#[cfg_attr(not(any(not(target_os = "macos"), test)), allow(dead_code))]
pub fn linux(os_release: Option<&str>) -> String {
    let name = os_release.and_then(pretty_name).map(|n| clean(&n, OS_LIMIT)).unwrap_or_default();
    if name.is_empty() {
        "Linux".into()
    } else {
        name
    }
}

/// The value of the last `PRETTY_NAME=` line, without its quotes. os-release is written as
/// shell assignments: a value may stand bare, in single quotes, or in double quotes where a
/// backslash keeps the next character as it is.
fn pretty_name(os_release: &str) -> Option<String> {
    let value = os_release.lines().filter_map(|l| l.trim().strip_prefix("PRETTY_NAME=")).next_back()?.trim();
    let inner = |quote: char| value.strip_prefix(quote).and_then(|v| v.strip_suffix(quote)).filter(|_| value.len() >= 2);
    if let Some(v) = inner('"') {
        let mut out = String::new();
        let mut chars = v.chars();
        while let Some(c) = chars.next() {
            out.push(if c == '\\' { chars.next().unwrap_or(c) } else { c });
        }
        Some(out)
    } else {
        Some(inner('\'').unwrap_or(value).to_string())
    }
}

/// Printable ASCII only, runs of spaces as one, no space at either end, at most `limit`
/// characters. Every other character is left out.
fn clean(text: &str, limit: usize) -> String {
    let printable: String = text.chars().map(|c| if c == '\t' { ' ' } else { c }).filter(|c| (' '..='~').contains(c)).collect();
    let line = printable.split(' ').filter(|w| !w.is_empty()).collect::<Vec<_>>().join(" ");
    line.chars().take(limit).collect::<String>().trim_end().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_mac_is_named_by_its_product_version() {
        assert_eq!(macos(Some("15.5\n")), "macOS 15.5");
        assert_eq!(macos(Some("26.0.1")), "macOS 26.0.1");
        assert_eq!(macos(Some("  14.7.2  \nmore\n")), "macOS 14.7.2");
        // No answer from the tool, or an empty one.
        for none in [None, Some(""), Some("\n"), Some(" \t ")] {
            assert_eq!(macos(none), "macOS", "{none:?}");
        }
    }

    #[test]
    fn linux_is_named_by_pretty_name_without_its_quotes() {
        let ubuntu = "NAME=\"Ubuntu\"\nVERSION_ID=\"24.04\"\nPRETTY_NAME=\"Ubuntu 24.04.1 LTS\"\nID=ubuntu\n";
        assert_eq!(linux(Some(ubuntu)), "Ubuntu 24.04.1 LTS");
        assert_eq!(linux(Some("PRETTY_NAME='Arch Linux'\n")), "Arch Linux");
        assert_eq!(linux(Some("ID=nixos\nPRETTY_NAME=NixOS\n")), "NixOS");
        assert_eq!(linux(Some("  PRETTY_NAME=\"Debian GNU/Linux 12 (bookworm)\"  ")), "Debian GNU/Linux 12 (bookworm)");
        // A backslash in double quotes keeps the character after it.
        assert_eq!(linux(Some(r#"PRETTY_NAME="Omarchy \"3\" \$HOME \\ end""#)), r#"Omarchy "3" $HOME \ end"#);
        // The last assignment is the one a shell would keep.
        assert_eq!(linux(Some("PRETTY_NAME=First\nPRETTY_NAME=\"Second\"\n")), "Second");
        // A quote without its pair stays as it is written.
        assert_eq!(linux(Some("PRETTY_NAME=\"Half")), "\"Half");
        assert_eq!(linux(Some("PRETTY_NAME=\"")), "\"");
    }

    #[test]
    fn linux_without_a_name_is_linux() {
        for none in [None, Some(""), Some("NAME=Ubuntu\nID=ubuntu\n"), Some("PRETTY_NAME=\n"), Some("PRETTY_NAME=\"\"\n"), Some("PRETTY_NAME=''"), Some("# PRETTY_NAME=x\nMY_PRETTY_NAME=y"), Some("PRETTY_NAME=\"日本語\"")] {
            assert_eq!(linux(none), "Linux", "{none:?}");
        }
    }

    #[test]
    fn a_name_is_cut_and_holds_printable_ascii_only() {
        let long = linux(Some(&format!("PRETTY_NAME=\"{}\"", "Distros ".repeat(40))));
        assert_eq!(long.len(), 63, "cut at 64, and the space the cut left at the end is gone");
        assert!(long.starts_with("Distros Distros ") && long.ends_with("Distros"));
        assert_eq!(linux(Some(&format!("PRETTY_NAME={}", "x".repeat(500)))), "x".repeat(64));
        assert_eq!(macos(Some(&"9".repeat(500))), format!("macOS {}", "9".repeat(58)));
        assert_eq!(macos(Some(&"9".repeat(500))).len(), 64);
        // Letters outside ASCII, control characters and escape sequences are left out.
        assert_eq!(linux(Some("PRETTY_NAME=\"Café  Linux\u{7} 1\u{1b}[31m\t2 \u{2028}é\"")), "Caf Linux 1[31m 2");
        assert_eq!(macos(Some("15.5 \u{1f600}\u{0}beta")), "macOS 15.5 beta");
        for text in [linux(Some("PRETTY_NAME=\"a\u{7f}b\u{80}c\rd\"")), macos(Some("1\u{7f}2\u{9b}3"))] {
            assert!(text.len() <= OS_LIMIT && text.bytes().all(|b| (0x20..=0x7e).contains(&b)), "{text:?}");
        }
    }

    #[test]
    fn this_system_has_a_name() {
        let name = os();
        assert!(!name.is_empty() && name.len() <= OS_LIMIT, "{name:?}");
        assert!(name.bytes().all(|b| (0x20..=0x7e).contains(&b)), "{name:?}");
        if cfg!(target_os = "macos") {
            assert!(name.starts_with("macOS"), "{name:?}");
        }
    }
}
