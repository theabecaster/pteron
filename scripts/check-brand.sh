#!/usr/bin/env bash
# Fails when a tracked file still says an earlier product name ("Rex DUO", "Rex-DUO", the
# mascot "Rexie") or the wrong spelling "Super Logical". The product is named in two constants
# (GlanceModel's Brand, Relay/src/brand.rs); nothing else may spell a name that came before.
#
#   scripts/check-brand.sh              check the tracked files; lists each line that fails
#   scripts/check-brand.sh --self-test  check the rules below against sample lines
#
# An earlier name has to stay in a few places, and only there, line by line:
#   - the release files Rex-DUO-Beacon.zip and Rex-DUO-Helper.zip, wherever they are named:
#     installed Beacons and apps ask for them by these names for good;
#   - a line that defines an EARLIER_* or OLD_* constant, in Rust or shell: the folders, labels
#     and state an installed Beacon is moved on from;
#   - the test data for those moves: Relay/fixtures, Relay/tests-setup, Relay/test-install.sh;
#   - the history in docs/helper.md, docs/release.md and Relay/README.md: inside a code span
#     (a file, folder or path of that time), or on a line that says "before", "earlier" or a
#     0.3 version.
# So a stray earlier name in update.rs, in setup.sh or in a sentence of a doc fails.
#
# Runs in CI's Linux job: bash, git and awk are all it needs.
set -euo pipefail
cd "$(dirname "$0")/.."

NAMES='Rex DUO|Rex-DUO|Rexie|Super Logical'

# Reads "file:line:text" lines and prints the ones no rule allows.
judge() {
  awk -v names="$NAMES" '
    {
      file = $0; sub(/:.*/, "", file)
      text = $0; sub(/^[^:]*:[^:]*:/, "", text)
      if (file ~ /^Relay\/(fixtures|tests-setup)\// || file == "Relay/test-install.sh") next
      rest = text
      gsub(/Rex-DUO-(Beacon|Helper)\.zip/, "", rest)
      if (rest !~ names) next
      if (text ~ /(^|[^A-Za-z0-9_])(EARLIER|OLD)_[A-Z0-9_]+(:[^=]+)?[ ]*=/) next
      if (file == "docs/helper.md" || file == "docs/release.md" || file == "Relay/README.md") {
        gsub(/`[^`]*`/, "", rest)
        if (rest !~ names) next
        if (text ~ /before|earlier|version 0\.3\./) next
      }
      print
    }'
}

if [[ "${1:-}" == "--self-test" ]]; then
  bad="$(judge <<'SAMPLES'
Relay/src/update.rs:1:pub const EARLIER_APP_NAMES: [&str; 2] = ["Rex DUO Beacon.app", "Rex DUO Helper.app"];
Relay/setup.sh:1:EARLIER_BEACON="Rex DUO Beacon"
Relay/release.sh:1:OLD_ZIPS=("Rex-DUO-Beacon.zip")
Relay/setup.sh:2:MAC_ASSETS="Beacon-macOS.zip Rex-DUO-Beacon.zip Rex-DUO-Helper.zip"
RexDuo/State/HelperRelease.swift:1:        case .mac: "Rex-DUO-Helper.zip"
Relay/test-install.sh:1:fake_app "$box/app" 9.8.7 "" "Rex DUO Helper.app"
Relay/fixtures/manifest.json:1:      "url": "https://example.com/Rex-DUO-Helper.zip",
docs/helper.md:1:It had two names before: Rex DUO Helper and Rex DUO Beacon.
docs/helper.md:2:The state folder keeps its name (`Rex DUO Helper`).
Relay/README.md:1:Log: `~/Library/Logs/Rex DUO Helper.log`.
SAMPLES
)"
  [[ -z "$bad" ]] || { echo "check-brand: these lines must pass and don't:"; echo "$bad"; exit 1; }
  want=8
  got="$(judge <<'SAMPLES' | wc -l | tr -d ' '
Relay/src/update.rs:1:    eprintln!("Rex DUO Beacon could not update");
Relay/setup.sh:1:say "Installing Rex DUO Beacon"
Relay/setup.sh:2:EARLIER="Rex DUO Beacon"
RexDuo/State/Pairing.swift:1:        title: "Update Rex DUO",
README.md:1:Rex DUO is a native iPhone app
docs/helper.md:1:Rex DUO Beacon runs on the computer.
docs/notifications.md:1:It had two names before: `Rex DUO Helper`.
NOTICE:1:Rex is a separate product by Super Logical.
SAMPLES
)"
  [[ "$got" == "$want" ]] || { echo "check-brand: $got of $want stray lines were caught"; exit 1; }
  echo "check-brand: the rules hold"
  exit 0
fi

# -I: text files only. This script names what it looks for, so it is left out.
found="$(git grep -I -n -E "$NAMES" -- . ':!scripts/check-brand.sh' | judge || true)"
# A name broken over two lines of prose ("Rex" ends one, "DUO" starts the next).
wrapped="$(git ls-files -z -- '*.md' '*.txt' NOTICE | xargs -0 awk '
  FNR == 1 { last = "" }
  last ~ /Rex$/ && $0 ~ /^[ >*-]*DUO/ { print FILENAME ":" FNR ":" $0 }
  { last = $0 }')"
if [[ -n "$found$wrapped" ]]; then
  echo "check-brand: an earlier name is left in these lines (the rules are at the top of scripts/check-brand.sh):"
  [[ -z "$found" ]] || echo "$found"
  [[ -z "$wrapped" ]] || echo "$wrapped"
  exit 1
fi
echo "check-brand: no earlier name outside the places that keep one"
