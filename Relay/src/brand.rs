//! The product's names, in one place. Everything a person reads takes them from here:
//! messages, dialogs, the systemd unit's description, notices, push titles and the category
//! of the actions offered to Rex.
//!
//! To rename, change `app_name!` here, the `BEACON=` line of Relay/setup.sh (a test below
//! holds the two together) and the app's own constant (`Brand` in Packages/RexGlance).
//!
//! What a shipped copy looks for by name keeps the name it has: the binary
//! (`service::NAME`), the bundle id, the state folder and the log, the release addresses and
//! the manifest's entries. The app's earlier folder names and the LaunchAgent's earlier labels
//! are in src/update.rs and src/service.rs, each on a line that says `EARLIER`.

/// The phone app's name, as a literal, for `concat!` and for format strings.
#[macro_export]
macro_rules! app_name {
    () => {
        "Pteron"
    };
}

/// This program's name, as a literal.
#[macro_export]
macro_rules! beacon_name {
    () => {
        concat!($crate::app_name!(), " Beacon")
    };
}

/// The phone app.
pub const APP: &str = app_name!();
/// This program. Not `NAME`: `service::NAME` is the binary's name, which never changes.
pub const BEACON: &str = beacon_name!();
/// The Mac app's folder.
pub const APP_FOLDER: &str = concat!(beacon_name!(), ".app");
/// The name an installed Mac app waits under while the one that replaces it starts.
pub const PREVIOUS_FOLDER: &str = concat!(beacon_name!(), ".previous.app");

/// `rex-duo-helper brand`: this program's name, for the scripts that package and release it.
pub fn line() -> &'static str {
    BEACON
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The one place a test spells the name out.
    #[test]
    fn the_name() {
        assert_eq!(APP, "Pteron");
        assert_eq!(BEACON, format!("{APP} Beacon"));
        assert_eq!(APP_FOLDER, format!("{BEACON}.app"));
        assert_eq!(PREVIOUS_FOLDER, format!("{BEACON}.previous.app"));
        assert_eq!(line(), BEACON);
    }

    /// The name is written out twice in this folder, both times in this file: the constant
    /// and the test above. Every other file reads the constant.
    #[test]
    fn the_name_is_spelled_out_in_this_file_alone() {
        let src = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src");
        let mut found = vec![];
        let files = [src.clone(), src.join("platform")].map(|dir| std::fs::read_dir(dir).unwrap());
        for entry in files.into_iter().flatten() {
            let path = entry.unwrap().path();
            if path.extension().is_some_and(|e| e == "rs") {
                let count = std::fs::read_to_string(&path).unwrap().matches(APP).count();
                if count > 0 {
                    found.push((path.file_name().unwrap().to_string_lossy().into_owned(), count));
                }
            }
        }
        assert_eq!(found, [("brand.rs".to_string(), 2)]);
    }

    /// setup.sh ships alone, so it carries the name itself, on one line. The phone app's
    /// tests read the same line of the copy the app carries.
    #[test]
    fn setup_sh_carries_the_same_name() {
        let setup = include_str!("../setup.sh");
        let lines: Vec<&str> = setup.lines().filter(|l| l.starts_with("BEACON=")).collect();
        assert_eq!(lines, [format!("BEACON=\"{BEACON}\"")]);
        assert_eq!(setup.matches(APP).count(), 1, "setup.sh spells the name out once, on that line");
    }

    /// The phone app carries setup.sh and runs no copy over 64 KiB (`SetupScript.maxBytes`
    /// there). This line is lower, so the file is trimmed long before an app build would ship
    /// an installer it can't run. The app's tests hold the copy it carries to the same line.
    #[test]
    fn setup_sh_stays_small_enough_for_the_app() {
        let size = include_str!("../setup.sh").len();
        assert!(size < 62_000, "setup.sh is {size} bytes; trim it under 62,000");
    }

    /// The one line of a script that sets `name`, without its quotes.
    fn value<'a>(script: &'a str, name: &str) -> &'a str {
        let start = format!("{name}=");
        let lines: Vec<&str> = script.lines().filter(|l| l.starts_with(&start)).collect();
        assert_eq!(lines.len(), 1, "{name} is set on one line");
        lines[0][start.len()..].trim_matches(|c| c == '"' || c == '(' || c == ')')
    }

    /// setup.sh has its own copy of every list the program goes by: the app's folder names,
    /// the service's names, the release list's entries for a Mac and the files behind them.
    #[test]
    fn setup_sh_carries_the_same_lists() {
        use crate::{config, service, update};
        let setup = include_str!("../setup.sh");
        assert_eq!(value(setup, "APP_NAME"), "$BEACON.app");
        assert_eq!(APP_FOLDER, format!("{BEACON}.app"));
        assert_eq!(value(setup, "PREVIOUS_NAME"), "$BEACON.previous.app");
        assert_eq!(PREVIOUS_FOLDER, format!("{BEACON}.previous.app"));
        assert_eq!(value(setup, "EARLIER_APP_NAMES"), update::EARLIER_APP_NAMES.join(":"));
        assert_eq!(value(setup, "APP_NAMES"), "$APP_NAME:$EARLIER_APP_NAMES");
        assert_eq!(value(setup, "EARLIER_NAME"), config::EARLIER_NAME);
        assert_eq!(value(setup, "FAILED_PREFIX"), update::FAILED_PREFIX);
        assert_eq!(value(setup, "LABEL"), service::LABEL);
        assert_eq!(value(setup, "EARLIER_LABELS"), service::EARLIER_LABELS.join(" "));
        assert_eq!(value(setup, "LABELS"), "$LABEL $EARLIER_LABELS");
        assert_eq!(value(setup, "MAC_ENTRIES"), update::MAC_KEYS.join(" "));
        // The files are named by release.sh, which writes them: the one package.sh made,
        // then the two it makes from that one, in the order of the entries.
        let release = include_str!("../release.sh");
        let first = value(release, "ZIP_SRC").trim_start_matches("dist/");
        let earlier = value(release, "EARLIER_ZIPS").replace('"', "");
        assert_eq!(value(setup, "MAC_ASSETS"), format!("{first} {earlier}"));
        let folders = value(release, "EARLIER_APP_DIRS").trim_matches('"').split("\" \"").collect::<Vec<_>>().join(":");
        assert_eq!(folders, update::EARLIER_APP_NAMES.join(":"));
    }
}
