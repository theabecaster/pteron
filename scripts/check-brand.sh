#!/usr/bin/env bash
# Fails when a tracked file still says an earlier product name ("Rex DUO", "Rex-DUO", the
# mascot "Rexie") or a wrong spelling of Superlogical ("Super Logical", "SuperLogical"). The
# product is named in two constants (GlanceModel's Brand, Relay/src/brand.rs); nothing else may
# spell a name that came before.
#
# A name is found in any letter case ("rex duo", "REXIE"), with spaces or tabs between its
# words, and when a line break falls between its words, in prose and in a comment of any
# language. Two spellings are matched as written. "SuperLogical": in another case it is the right
# spelling. And all-lowercase `rex-duo` is no name but an identifier, like `rexduo`: the crate
# and the binaries (`rex-duo-helper`, `rex-duo-notify`) keep it.
#
#   scripts/check-brand.sh              check the tracked files; lists each line that fails
#   scripts/check-brand.sh --self-test  check the rules below against sample lines
#
# An earlier name has to stay in a few places, and only there, line by line:
#   - the release files Rex-DUO-Beacon.zip and Rex-DUO-Helper.zip, wherever they are named:
#     installed Beacons and apps ask for them by these names for good;
#   - a line that defines an EARLIER_* or OLD_* constant, in Rust or shell: the folders, labels
#     and state an installed Beacon is moved on from. The line has to begin with the definition
#     (`pub const EARLIER_X: … =`, `OLD_X=`); a line that only mentions such a name does not count;
#   - the test data for those moves: Relay/fixtures, Relay/tests-setup, Relay/test-install.sh;
#   - the history in docs/helper.md, docs/release.md and Relay/README.md: inside a code span
#     (a file, folder or path of that time), or on a line that says "before", "earlier" or a
#     0.3 version.
# So a stray earlier name in update.rs, in setup.sh or in a sentence of a doc fails.
#
# Runs in CI's Linux job: bash, git and awk are all it needs.
set -euo pipefail
cd "$(dirname "$0")/.."

# Lowercase, as the text is before it is matched. Words are parted by spaces or tabs.
NAMES='rex[ \t]+duo|rex-duo|rexie|super[ \t]+logical'
# Matched as written.
EXACT='SuperLogical'

# Reads "file:line:text" lines and prints the ones no rule allows.
judge() {
  awk -v names="$NAMES" -v exact="$EXACT" '
    function named(t) { return tolower(t) ~ names || t ~ exact }
    {
      file = $0; sub(/:.*/, "", file)
      text = $0; sub(/^[^:]*:[^:]*:/, "", text)
      if (file ~ /^Relay\/(fixtures|tests-setup)\// || file == "Relay/test-install.sh") next
      rest = text
      gsub(/Rex-DUO-(Beacon|Helper)\.zip/, "", rest)
      gsub(/rex-duo/, "", rest)
      if (!named(rest)) next
      if (text ~ /^[ \t]*((pub(\([a-z]+\))?[ \t]+)?(const|static)[ \t]+|(readonly|local|export)[ \t]+)?(EARLIER|OLD)_[A-Z0-9_]+(:[^=]+)?[ \t]*=/) next
      if (file == "docs/helper.md" || file == "docs/release.md" || file == "Relay/README.md") {
        gsub(/`[^`]*`/, "", rest)
        if (!named(rest)) next
        if (text ~ /before|earlier|version 0\.3\./) next
      }
      print
    }'
}

# Reads every line of the files as "file:line:text", in order, and prints the second line of a
# name that a line break parts: one line ends with its first word and the next begins with its
# second, after the indentation and whatever marks a comment, a quote or a list item there.
wrapped() {
  awk '
    {
      file = $0; sub(/:.*/, "", file)
      text = $0; sub(/^[^:]*:[^:]*:/, "", text)
      if (file != last_file) { tail = ""; last_file = file }
      head = tolower(text)
      sub(/^[ \t]*(\/\/[\/!]?|\/?\*+|#+|--|>+|-)?[ \t]*/, "", head)
      if ((tail ~ /(^|[^a-z0-9])rex-?$/ && head ~ /^duo([^a-z0-9]|$)/ && !(raw ~ /rex-$/ && text ~ /^[ \t]*duo-/)) ||
          (tail ~ /(^|[^a-z0-9])super$/ && head ~ /^logical([^a-z0-9]|$)/)) print
      raw = text; sub(/[ \t]+$/, "", raw)
      tail = tolower(raw)
    }'
}

if [[ "${1:-}" == "--self-test" ]]; then
  bad="$(judge <<'SAMPLES'
Relay/src/update.rs:1:pub const EARLIER_APP_NAMES: [&str; 2] = ["Rex DUO Beacon.app", "Rex DUO Helper.app"];
Relay/src/update.rs:2:    pub(crate) static OLD_LABEL: &str = "Rex DUO Helper";
Relay/setup.sh:1:EARLIER_BEACON="Rex DUO Beacon"
Relay/setup.sh:3:  readonly EARLIER_STATE="Rex DUO Helper"
Relay/release.sh:1:OLD_ZIPS=("Rex-DUO-Beacon.zip")
Relay/setup.sh:2:MAC_ASSETS="Beacon-macOS.zip Rex-DUO-Beacon.zip Rex-DUO-Helper.zip"
RexDuo/State/HelperRelease.swift:1:        case .mac: "Rex-DUO-Helper.zip"
Relay/test-install.sh:1:fake_app "$box/app" 9.8.7 "" "Rex DUO Helper.app"
Relay/fixtures/manifest.json:1:      "url": "https://example.com/Rex-DUO-Helper.zip",
docs/helper.md:1:It had two names before: Rex DUO Helper and Rex DUO Beacon.
docs/helper.md:2:The state folder keeps its name (`Rex DUO Helper`).
Relay/README.md:1:Log: `~/Library/Logs/Rex DUO Helper.log`.
NOTICE:1:Rex is a separate product by Superlogical.
RexDuo/State/Pairing.swift:1:        let client = RexDuoClient(name: "rexduo")
Relay/Cargo.toml:1:name = "rex-duo-helper"
Relay/README.md:2:systemctl --user stop rex-duo-helper
README.md:2:The app is an iOS remote for Rex. Duo owners get more room.
SAMPLES
)"
  [[ -z "$bad" ]] || { echo "check-brand: these lines must pass and don't:"; echo "$bad"; exit 1; }
  stray="$(cat <<'SAMPLES'
Relay/src/update.rs:1:    eprintln!("Rex DUO Beacon could not update");
Relay/setup.sh:1:say "Installing Rex DUO Beacon"
Relay/setup.sh:2:EARLIER="Rex DUO Beacon"
RexDuo/State/Pairing.swift:1:        title: "Update Rex DUO",
README.md:1:Rex DUO is a native iPhone app
docs/helper.md:1:Rex DUO Beacon runs on the computer.
docs/notifications.md:1:It had two names before: `Rex DUO Helper`.
NOTICE:1:Rex is a separate product by Super Logical.
README.md:3:the rex duo app, REX DUO, Rex Duo and REXIE in any case
README.md:4:Open REX-duo on the phone.
docs/sidebar.md:1:Rex  DUO with two spaces, and Rex	DUO with a tab.
NOTICE:2:Rex is a separate product by Super  Logical.
NOTICE:3:Rex is a separate product by SuperLogical.
RexDuo/App/RootView.swift:1:    // Made by SuperLogical, not by us.
Relay/setup.sh:4:say "moving on from $OLD_NAME = Rex DUO Helper"
Relay/setup.sh:5:# EARLIER_BEACON="Rex DUO Beacon" was the name
Relay/src/update.rs:3:    if name == EARLIER_NAME { log("Rex DUO Beacon"); let x = 1; }
Relay/src/update.rs:4:    let folder = OLD_FOLDERS[0]; // = "Rex DUO Helper"
SAMPLES
)"
  want="$(printf '%s\n' "$stray" | wc -l | tr -d ' ')"
  got="$(printf '%s\n' "$stray" | judge | wc -l | tr -d ' ')"
  [[ "$got" == "$want" ]] || {
    echo "check-brand: $got of $want stray lines were caught; missed:"
    diff <(printf '%s\n' "$stray") <(printf '%s\n' "$stray" | judge) | sed -n 's/^< //p'
    exit 1
  }
  # A name parted by a line break: in prose, and in a comment in Swift, Rust and shell.
  parted="$(wrapped <<'SAMPLES'
README.md:1:It is still called Rex
README.md:2:DUO in this sentence.
README.md:3:> a quote that ends with Rex
README.md:4:> DUO too.
RexDuo/App/RootView.swift:1:    /// The first screen of Rex
RexDuo/App/RootView.swift:2:    /// DUO, as it was called.
RexDuo/App/RootView.swift:3:    // lowercase rex
RexDuo/App/RootView.swift:4:    // duo counts as well.
RexDuo/App/RootView.swift:5:    /* A block comment about Rex
RexDuo/App/RootView.swift:6:     * DUO in its second line. */
Relay/src/main.rs:1://! The helper of Rex-
Relay/src/main.rs:2://! DUO, hyphenated over the break.
Relay/setup.sh:1:# Installs the helper of Rex
Relay/setup.sh:2:# DUO on this computer.
NOTICE:1:Rex is a product by Super
NOTICE:2:Logical, misspelled over two lines.
SAMPLES
)"
  [[ "$(printf '%s\n' "$parted" | wc -l | tr -d ' ')" == 8 ]] || { echo "check-brand: 8 parted names must be caught, got:"; echo "$parted"; exit 1; }
  whole="$(wrapped <<'SAMPLES'
README.md:1:An iOS remote for Rex
README.md:2:Duolingo is something else, and so is a duo of panes after Rex.
README.md:3:The last word of this file is Rex
docs/sidebar.md:1:DUO starts another file, which is no wrapped name.
RexDuo/App/RootView.swift:1:    /// Connects to Rex
RexDuo/App/RootView.swift:2:    /// and to nothing else. Superlogical
RexDuo/App/RootView.swift:3:    /// logical order follows.
Relay/README.md:1:    systemctl --user stop rex-
Relay/README.md:2:    duo-helper
SAMPLES
)"
  [[ -z "$whole" ]] || { echo "check-brand: these lines part no name and were caught:"; echo "$whole"; exit 1; }
  echo "check-brand: the rules hold"
  exit 0
fi

# -I: text files only. This script names what it looks for, so it is left out.
found="$(git grep -I -n -i -E "$(printf '%s' "$NAMES" | sed 's/\\t/	/g')|superlogical" -- . ':!scripts/check-brand.sh' | judge || true)"
# A name broken over two lines ("Rex" ends one, "DUO" starts the next), in every text file.
parted="$(git grep -I -n -e '' -- . ':!scripts/check-brand.sh' ':!Relay/fixtures' ':!Relay/tests-setup' ':!Relay/test-install.sh' | wrapped || true)"
if [[ -n "$found$parted" ]]; then
  echo "check-brand: an earlier name is left in these lines (the rules are at the top of scripts/check-brand.sh):"
  [[ -z "$found" ]] || echo "$found"
  [[ -z "$parted" ]] || echo "$parted"
  exit 1
fi
echo "check-brand: no earlier name outside the places that keep one"
