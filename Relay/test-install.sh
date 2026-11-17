#!/usr/bin/env bash
# Tests the helper's installer (setup.sh) and what release.sh signs for it. Needs bash; setup.sh
# itself runs under every POSIX shell found here (bash --posix, /bin/sh, /bin/dash).
#
#   bash Relay/test-install.sh
#
# It reaches nothing outside this computer and changes nothing outside a temporary folder:
#   - it makes its own keys and works on copies of release.sh and setup.sh;
#   - downloads come from tests-setup/mirror.py on 127.0.0.1, which serves that folder;
#   - the helper is tests-setup/fake-helper.sh, which starts nothing;
#   - a run as the app starts it happens in a pseudo-terminal of tests-setup/pty-run.py, which
#     types the setup code when the installer asks for it, as Rex DUO does;
#   - launchctl, systemctl, loginctl and open are stand-ins that only write down how they were
#     called, and every home folder is a folder made for one test.
#
# setup.sh has no switch for any of this. The tests run copies of it in which sed has replaced a
# few constant lines: the download address and its https-only options, the two keys, the tool
# folders and who may own a tool, where the home folder comes from, where downloads are kept,
# the system Applications folder and how long to wait for the helper and for the setup code.
# The first checks below make sure the file as committed still has the published values on
# those lines. The copies for a run by hand on a Mac are made from the install.sh that the
# copy of release.sh wrote, so they carry the two values exactly as a release does.
#
# Runs on a Mac (release.sh needs ditto and plutil) with openssl 3 (OPENSSL, or Homebrew's) and
# python3. With cargo on PATH, the helper's own code checks the same release too
# (SKIP_HELPER_CHECK=1 leaves that out). With a Developer ID build in dist/release, the real
# codesign and spctl judge it. KEEP_BOX=1 keeps the temporary folder to look at.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
setup="$here/setup.sh"
OPENSSL="${OPENSSL:-}"
if [[ -z "$OPENSSL" ]]; then
  for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl openssl; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" pkeyutl -help 2>&1 | grep -q -- '-rawin'; then
      OPENSSL="$(command -v "$candidate")"
      break
    fi
  done
fi
[[ -n "$OPENSSL" ]] || { echo "test-install: openssl 3 is needed (set OPENSSL)" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || { echo "test-install: runs on a Mac" >&2; exit 1; }

box="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/rexduo-test.XXXXXX")" && pwd -P)"
mirror_pid=""
finish() {
  [[ -n "$mirror_pid" ]] && kill "$mirror_pid" 2>/dev/null
  chmod -R u+w "$box" 2>/dev/null
  if [[ "${KEEP_BOX:-}" == 1 ]]; then echo "kept $box"; else rm -rf "$box"; fi
}
trap finish EXIT
relay="$box/Relay"
mirror="$box/mirror"
mkdir -p "$relay/dist" "$box/bin" "$mirror" "$box/h" "$box/saved"

# release.sh calls `openssl`; it must never reach GitHub from here.
ln -s "$OPENSSL" "$box/bin/openssl"
printf '#!/bin/sh\necho "test-install: gh was called: $*" >&2\nexit 99\n' > "$box/bin/gh"
chmod +x "$box/bin/gh"
export PATH="$box/bin:$PATH"
export OPENSSL

passed=0
group=0
label=""
ok() {
  passed=$((passed + 1))
  group=$((group + 1))
  printf 'ok    %s%s\n' "$label" "$1"
}
fail() {
  printf 'FAIL  %s%s\n' "$label" "$1" >&2
  exit 1
}

sha() { "$OPENSSL" dgst -sha256 -r "$1" | cut -c 1-64; }
size() { wc -c < "$1" | tr -d ' '; }

# MARK: setup.sh as committed

committed_key() { sed -n "s/^$1[[:space:]][[:space:]]*\([A-Za-z0-9+\/=]*\)[[:space:]]*$/\1/p" "$here/update-key.pub"; }
for line in \
  'BASE="https://github.com/theabecaster/rexduo/releases/download"' \
  "PRIMARY_KEY=\"$(committed_key primary)\"" \
  "RECOVERY_KEY=\"$(committed_key recovery)\"" \
  'TOOL_DIRS="/usr/bin /bin /usr/sbin /sbin /run/current-system/sw/bin"' \
  'DOWNLOADERS="curl wget"' \
  'CURL_ONLY="--proto =https --proto-redir =https --tlsv1.2"' \
  'WGET_ONLY="--https-only"' \
  'SYSTEM_APPS="/Applications"' \
  'WAIT_SECONDS=20' \
  'CODE_SECONDS=60' \
  'MANUAL_MAC_FLOOR=""' \
  'MANUAL_MAC_EXPIRES=""' \
  '      0) ;; # root' \
  '  HOME="$(account_home)" || HOME=""' \
  '  STAGE_ROOT="$(stage_root)" || STAGE_ROOT=""' \
  'start() {' \
  'main "$@"'; do
  [[ "$(grep -cxF -- "$line" "$setup")" == 1 ]] || fail "setup.sh must have this line exactly once: $line"
done
[[ "$(committed_key primary)" != "$(committed_key recovery)" && "$(committed_key primary)$(committed_key recovery)" =~ ^[A-Za-z0-9+/=]{88}$ ]] || fail "update-key.pub must hold two keys"
ok "setup.sh has the published address, the keys of update-key.pub, the system's tool folders and no values for a run by hand on a Mac"
if grep -nE 'REXDUO_|REX_DUO_|sudo|eval|http://' "$setup"; then fail "setup.sh has a test switch, sudo, eval or a plain http address"; fi
# What it takes from its environment: the Rex server of the tab and three systemd locations.
python3 -I - "$setup" <<'PY' || fail "setup.sh reads a variable from its environment beyond REX_SERVER, XDG_STATE_HOME, XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS"
import re, sys
text = open(sys.argv[1]).read()
used = set(re.findall(r"\$\{?([A-Z][A-Z0-9_]*)", text))
assigned = set(re.findall(r"(?:^|[\s;(])([A-Z][A-Z0-9_]*)=", text, re.M))
defaulted = set(re.findall(r"\$\{([A-Z][A-Z0-9_]*):", text))
assert used - assigned == {"REX_SERVER", "XDG_STATE_HOME"}, sorted(used - assigned)
assert defaulted == {"REX_SERVER", "XDG_STATE_HOME", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS"}, sorted(defaulted)
PY
ok "setup.sh has no switch that moves downloads, skips a check or changes keys"
[[ "$(size "$setup")" -lt 65536 ]] || fail "setup.sh must stay under 64 KiB"
ok "setup.sh is $(size "$setup") bytes, under 64 KiB"
for shell in /bin/sh /bin/dash; do
  [[ -x "$shell" ]] && { "$shell" -n "$setup" || fail "$shell does not parse setup.sh"; }
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -s sh "$setup" || fail "shellcheck -s sh setup.sh"
  ok "shellcheck -s sh setup.sh"
else
  echo "skip  shellcheck is not installed"
fi

# MARK: release.sh

# Keys made for this run.
for name in primary recovery next stranger extra1 extra2 extra3; do
  "$OPENSSL" genpkey -algorithm ed25519 -out "$box/$name.key" 2>/dev/null
done
public() { "$OPENSSL" pkey -in "$box/$1.key" -pubout -outform DER | tail -c 32 | "$OPENSSL" base64 -A; }
PRIMARY="$(public primary)"
RECOVERY="$(public recovery)"
NEXT="$(public next)"

# Copies of the scripts that trust those keys instead of the published ones.
cp "$here/release.sh" "$relay/release.sh"
sed -e "s|^PRIMARY_KEY=.*|PRIMARY_KEY=\"$PRIMARY\"|" -e "s|^RECOVERY_KEY=.*|RECOVERY_KEY=\"$RECOVERY\"|" "$setup" > "$relay/setup.sh"
printf '# test keys\nprimary  %s\nrecovery %s\n' "$PRIMARY" "$RECOVERY" > "$relay/update-key.pub"
printf '[package]\nname = "rex-duo-helper"\nversion = "9.8.7"\n' > "$relay/Cargo.toml"
# The crate licences are listed by a stand-in: the real script reads the real Cargo.lock, and
# cargo test runs its check. "$box/bad-licence" makes it refuse, as it does for an unlisted licence.
cat > "$relay/third-party-licenses.py" <<PY
import os, sys
if os.path.exists("$box/bad-licence"):
    sys.exit("a crate's licence is not on the list")
open(sys.argv[1], "w").write("notices\\n")
PY

# fake_helper <version> <out> [<note>]: the stand-in helper at that version.
fake_helper() {
  sed "s/@VERSION@/$1/g" "$here/tests-setup/fake-helper.sh" > "$2"
  [[ -z "${3:-}" ]] || printf '# %s\n' "$3" >> "$2"
  chmod 0755 "$2"
}
# fake_app <folder> <version> [true]: Rex DUO Helper.app in that folder. Its program is the
# stand-in helper, or with `true` a copy of /usr/bin/true (something codesign can sign).
fake_app() {
  local app="$1/Rex DUO Helper.app"
  mkdir -p "$app/Contents/MacOS"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>rex-duo-helper</string>
<key>CFBundleIdentifier</key><string>dev.abrahamgonzalez.rexduo.helper</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$2</string>
</dict></plist>
PLIST
  if [[ "${3:-}" == true ]]; then
    cp /usr/bin/true "$app/Contents/MacOS/rex-duo-helper"
  else
    fake_helper "$2" "$app/Contents/MacOS/rex-duo-helper"
  fi
}
zip_app() { /usr/bin/ditto -c -k --keepParent "$1/Rex DUO Helper.app" "$2"; }

# Stand-ins for what package.sh builds.
fake_helper 9.8.7 "$relay/dist/rex-duo-helper-linux-x86_64" "for x86_64"
fake_helper 9.8.7 "$relay/dist/rex-duo-helper-linux-aarch64" "for aarch64, a little longer"
fake_app "$box/app" 9.8.7
zip_app "$box/app" "$relay/dist/Rex DUO Helper.zip"

# A setting for one run is exported in a subshell around the call: placed before the call
# itself it would stay set afterwards when sh runs this file.
release() { # release <key name> [options]: runs the copy of release.sh; other settings come from the caller's environment
  local key="$1"
  shift
  (cd "$relay" && UPDATE_KEY="$box/$key.key" ./release.sh "$@")
}
sign_with() { # sign_with <key name> <file> <signature file>
  "$OPENSSL" pkeyutl -sign -inkey "$box/$1.key" -rawin -in "$2" | "$OPENSSL" base64 -A > "$3"
  echo >> "$3"
}
key_der() { # key_der <base64 key> <out>
  { printf '\060\052\060\005\006\003\053\145\160\003\041\000'; printf '%s' "$1" | "$OPENSSL" base64 -d -A; } > "$2"
}
verifies() { # verifies <base64 key> <file> <signature file>: the first line of the signature file is that key's signature
  key_der "$1" "$box/verifies.der"
  head -n 1 "$3" | "$OPENSSL" base64 -d -A -out "$box/verifies.raw"
  "$OPENSSL" pkeyutl -verify -pubin -keyform DER -inkey "$box/verifies.der" -rawin -in "$2" -sigfile "$box/verifies.raw" >/dev/null 2>&1
}

# release.sh: builds the release (nothing is published without --publish).
release primary --skip-build > "$box/release.log" 2>&1 || { cat "$box/release.log" >&2; fail "release.sh --skip-build"; }
grep -q "Nothing was published" "$box/release.log" || fail "release.sh did not say it published nothing"
out="$relay/dist/release"
for f in manifest.json manifest.json.sig install.sh THIRD_PARTY_LICENSES.txt Rex-DUO-Helper.zip rex-duo-helper-linux-x86_64 rex-duo-helper-linux-x86_64.sig rex-duo-helper-linux-aarch64 rex-duo-helper-linux-aarch64.sig; do
  [[ -s "$out/$f" ]] || fail "release.sh did not write $f"
done
# install.sh is setup.sh with the two values for a run by hand on a Mac, and nothing else.
list_expires() { sed -n 's/^  "expires_at": "\(.*\)",$/\1/p' "$out/manifest.json"; }
installer_check() { # installer_check <log of the run>: install.sh, its two values and its printed SHA-256
  [[ "$(diff "$relay/setup.sh" "$out/install.sh" | grep '^>')" == "> MANUAL_MAC_FLOOR=\"9.8.7\"
> MANUAL_MAC_EXPIRES=\"$(list_expires)\"" ]] || fail "install.sh differs from setup.sh in other than the two values: $(diff "$relay/setup.sh" "$out/install.sh")"
  [[ "$(diff "$relay/setup.sh" "$out/install.sh" | grep -c '^<')" == 2 ]] || fail "install.sh lost lines of setup.sh"
  cmp -s "$relay/setup.sh" "$box/setup.before" || fail "release.sh changed setup.sh"
  grep -qxF "==> SHA-256 of install.sh: $(sha "$out/install.sh")" "$1" || fail "release.sh did not print the SHA-256 of install.sh: $(cat "$1")"
}
cp "$relay/setup.sh" "$box/setup.before"
installer_check "$box/release.log"
[[ -x "$out/install.sh" ]] || fail "install.sh is not executable"
ok "release.sh: install.sh is setup.sh with the version and the list's expiry date, and setup.sh stays as it was"
grep -qF "It goes into docs/helper.md, between <!-- install-sha --> and <!-- /install-sha -->." "$box/release.log" || fail "without docs/helper.md, release.sh did not say where the SHA-256 goes"
ok "release.sh: prints the SHA-256 of install.sh and where it goes"
# With the document there (a copy of it), the value goes between its markers.
mkdir -p "$box/docs"
cp "$here/../docs/helper.md" "$box/docs/helper.md"
[[ "$(grep -cx -e '<!-- install-sha -->' -e '<!-- /install-sha -->' "$box/docs/helper.md")" == 2 ]] || fail "docs/helper.md has no install-sha markers"
doc_check() { # the document names the SHA-256 of install.sh between the markers and is otherwise the same
  python3 -I - "$here/../docs/helper.md" "$box/docs/helper.md" "$(sha "$out/install.sh")" <<'PY'
import re, sys
before, after, digest = open(sys.argv[1]).read(), open(sys.argv[2]).read(), sys.argv[3]
marked = re.compile(r"(?<=<!-- install-sha -->\n).*?(?=<!-- /install-sha -->)", re.S)
assert marked.findall(after) == ["```\n%s  install.sh\n```\n" % digest], marked.findall(after)
assert marked.sub("", before) == marked.sub("", after)
PY
}
manifest_check() { # manifest_check <days>
  python3 - "$out/manifest.json" "$1" <<'PY'
import datetime, json, re, sys
m = json.load(open(sys.argv[1]))
days = int(sys.argv[2])
assert list(m) == ["version", "min_version", "released_at", "expires_at", "next_key", "assets"], list(m)
assert m["version"] == "9.8.7" and m["min_version"] == "9.8.7" and m["next_key"] is None, m
stamp = "%Y-%m-%dT%H:%M:%SZ"
life = datetime.datetime.strptime(m["expires_at"], stamp) - datetime.datetime.strptime(m["released_at"], stamp)
assert datetime.timedelta(days=days - 1, hours=23) < life <= datetime.timedelta(days=days, minutes=5), life
assert set(m["assets"]) == {"macos-universal", "linux-x86_64", "linux-aarch64"}
for a in m["assets"].values():
    assert set(a) == {"url", "sha256", "size"} and re.fullmatch(r"[0-9a-f]{64}", a["sha256"]) and a["size"] > 0, a
PY
}
manifest_check 180 || fail "the manifest does not have the agreed fields"
ok "release.sh: manifest has version, min_version, expires_at (180 days), next_key and three assets"

# What the Linux signature covers is the text, not the file.
x86="$out/rex-duo-helper-linux-x86_64"
x86_sha="$(sha "$x86")"
printf 'rex-duo-helper|9.8.7|linux-x86_64|%s' "$x86_sha" > "$box/text"
verifies "$PRIMARY" "$box/text" "$x86.sig" || fail "the binary signature is not over rex-duo-helper|<version>|<platform>|<sha256>"
if verifies "$PRIMARY" "$x86" "$x86.sig"; then fail "the binary signature still verifies over the file's bytes"; fi
ok "release.sh: a Linux signature covers version, platform and hash"

# The fixtures for the app's tests: the same list, signed by a key that is not a release key.
fx="$out/fixtures"
check_fixtures() {
  local key
  key="$(sed -n 's/^primary[[:space:]]*//p' "$fx/test-key.pub")"
  [[ ${#key} -eq 44 && "$key" != "$PRIMARY" && "$key" != "$RECOVERY" ]] || return 1
  cmp -s "$fx/manifest.json" "$out/manifest.json" || return 1
  verifies "$key" "$fx/manifest.json" "$fx/manifest.json.sig" || return 1
  if verifies "$PRIMARY" "$fx/manifest.json" "$fx/manifest.json.sig"; then return 1; fi
  verifies "$key" "$box/text" "$fx/rex-duo-helper-linux-x86_64.sig" || return 1
  [[ "$(ls -1 "$fx" | tr '\n' ' ')" == "manifest.json manifest.json.sig rex-duo-helper-linux-x86_64.sig test-key.pub " ]]
}
check_fixtures || fail "release.sh did not write dist/release/fixtures signed by a test key"
! grep -rIl "PRIVATE KEY" "$out" >/dev/null || fail "release.sh left a private key in dist/release"
ok "release.sh: fixtures hold the list and a Linux signature, signed by a throwaway key"

# The helper itself reads the same release: its manifest rules and its Linux signature check.
if [[ "${SKIP_HELPER_CHECK:-}" == 1 ]]; then
  echo "skip  the helper's own check of the release (SKIP_HELPER_CHECK=1)"
elif command -v cargo >/dev/null 2>&1; then
  REXDUO_RELEASE_DIR="$out" REXDUO_RELEASE_KEY_FILE="$relay/update-key.pub" \
    cargo test --quiet --manifest-path "$here/Cargo.toml" release_sh_output -- --ignored > "$box/cargo.log" 2>&1 \
    || { cat "$box/cargo.log" >&2; fail "the helper does not accept what release.sh wrote"; }
  ok "the helper accepts the manifest and both Linux signatures release.sh wrote"
else
  echo "skip  the helper's own check of the release (cargo is not on PATH)"
fi
release primary --skip-build > "$box/release.log" 2>&1 || { cat "$box/release.log" >&2; fail "release.sh --skip-build, again"; }
installer_check "$box/release.log"
doc_check || fail "release.sh did not write the SHA-256 of install.sh into docs/helper.md"
grep -qF "docs/helper.md now names it." "$box/release.log" || fail "release.sh did not say it wrote docs/helper.md"
ok "release.sh: writes the SHA-256 of install.sh between the markers of docs/helper.md"
cp -R "$out" "$box/saved/release"

# release.sh --resign: the recovery key signs the same list again and hands over a new key.
sleep 1
( export NEXT_KEY="$NEXT" EXPIRES_DAYS=200; release recovery --resign > "$box/resign.log" 2>&1 ) || { cat "$box/resign.log" >&2; fail "release.sh --resign"; }
grep -q "Nothing was published" "$box/resign.log" || fail "--resign did not say it published nothing"
python3 - "$box/saved/release/manifest.json" "$out/manifest.json" "$NEXT" <<'PY' || fail "--resign changed more than the date and the next key"
import json, sys
before, after, next_key = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]
assert after["next_key"] == next_key and after["expires_at"] > before["expires_at"], after
for key in ("version", "min_version", "released_at", "assets"):
    assert after[key] == before[key], key
PY
verifies "$RECOVERY" "$out/manifest.json" "$out/manifest.json.sig" || fail "--resign did not sign with the key it was given"
check_fixtures || fail "--resign did not write the fixtures again"
installer_check "$box/resign.log"
doc_check || fail "--resign did not write the new SHA-256 into docs/helper.md"
cp "$out/manifest.json" "$box/saved/resigned.json"
cp "$out/manifest.json.sig" "$box/saved/resigned.json.sig"
ok "release.sh --resign: new expiry and next_key, everything else unchanged, fixtures and install.sh written again"

# What release.sh itself refuses.
if release stranger --skip-build > "$box/refused.log" 2>&1; then fail "release.sh signed with a key that is not in update-key.pub"; fi
grep -q "neither the primary nor the recovery key" "$box/refused.log" || fail "release.sh refused the stranger's key for another reason: $(cat "$box/refused.log")"
ok "release.sh: refuses a signing key that is not in update-key.pub"
: > "$box/bad-licence"
if release primary --skip-build > "$box/refused.log" 2>&1; then fail "release.sh released a crate whose licence is not on the list"; fi
rm -f "$box/bad-licence"
if ( export MIN_VERSION=9.9.0; release primary --skip-build > "$box/refused.log" 2>&1 ); then fail "release.sh took a MIN_VERSION newer than the release"; fi
ok "release.sh: refuses a MIN_VERSION newer than the release"
if ( export NEXT_KEY=AAAA; release primary --skip-build > "$box/refused.log" 2>&1 ); then fail "release.sh took a NEXT_KEY that is not a key"; fi
ok "release.sh: refuses a NEXT_KEY that is not a key"
if ( export EXPIRES_DAYS=soon; release primary --skip-build > "$box/refused.log" 2>&1 ); then fail "release.sh took an EXPIRES_DAYS that is not a number"; fi
ok "release.sh: refuses an EXPIRES_DAYS that is not a number of days"
( export MIN_VERSION=9.0.0 EXPIRES_DAYS=45; release primary --skip-build > "$box/release.log" 2>&1 ) || { cat "$box/release.log" >&2; fail "release.sh with MIN_VERSION"; }
grep -q '^  "min_version": "9.0.0",$' "$out/manifest.json" || fail "MIN_VERSION did not reach the manifest"
sed -i '' 's/"min_version": "9.0.0"/"min_version": "9.8.7"/' "$out/manifest.json"
manifest_check 45 || fail "EXPIRES_DAYS did not set the expiry"
ok "release.sh: MIN_VERSION sets min_version and EXPIRES_DAYS the expiry"
sed "s|^RECOVERY_KEY=.*|RECOVERY_KEY=\"$NEXT\"|" "$relay/setup.sh" > "$box/setup.other" && cp "$box/setup.other" "$relay/setup.sh"
if release primary --skip-build > "$box/refused.log" 2>&1; then fail "release.sh released a setup.sh with other keys than update-key.pub"; fi
grep -q "setup.sh carries a different recovery key" "$box/refused.log" || fail "release.sh refused setup.sh for another reason: $(cat "$box/refused.log")"
ok "release.sh: refuses when setup.sh and update-key.pub disagree"

# MARK: The committed fixtures (Relay/fixtures, written by tests-setup/make-fixtures.sh)

fixtures="$here/fixtures"
python3 - "$fixtures" <<'PY' || fail "Relay/fixtures does not hold what tests-setup/make-fixtures.sh writes"
import datetime, json, os, re, sys
d = sys.argv[1]
load = lambda name: json.load(open(os.path.join(d, name)))
good, expired, older = load("manifest.json"), load("manifest-expired.json"), load("manifest-older.json")
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
assert good["version"] == "9.8.7" and good["expires_at"].startswith("2099-") and older["expires_at"].startswith("2099-")
assert expired["expires_at"] < now and expired["version"] == good["version"]
assert older["version"] == "9.8.6"
for m in (good, expired, older):
    for platform, a in m["assets"].items():
        assert a["url"].startswith(f"https://github.com/theabecaster/rexduo/releases/download/helper-v{m['version']}/"), a
        assert re.fullmatch(r"[0-9a-f]{64}", a["sha256"]) and 0 < a["size"] <= 64 << 20, a
PY
fixture_key="$(sed -n 's/^primary[[:space:]]*//p' "$fixtures/test-key.pub")"
for name in manifest manifest-expired manifest-older; do
  verifies "$fixture_key" "$fixtures/$name.json" "$fixtures/$name.json.sig" || fail "Relay/fixtures/$name.json.sig is not the test key's signature"
done
if verifies "$fixture_key" "$fixtures/manifest.json" "$fixtures/manifest-untrusted.json.sig"; then fail "Relay/fixtures/manifest-untrusted.json.sig is signed by the test key"; fi
printf 'rex-duo-helper|9.8.7|linux-x86_64|%s' "$(sed -n '/"linux-x86_64"/,/}/s/.*"sha256": "\([0-9a-f]*\)".*/\1/p' "$fixtures/manifest.json")" > "$box/fixture.text"
verifies "$fixture_key" "$box/fixture.text" "$fixtures/rex-duo-helper-linux-x86_64.sig" || fail "Relay/fixtures: the Linux signature is not over the agreed text"
[[ "$fixture_key" != "$(committed_key primary)" && "$fixture_key" != "$(committed_key recovery)" ]] || fail "Relay/fixtures is signed by a release key"
! grep -rIl "PRIVATE KEY" "$fixtures" >/dev/null || fail "Relay/fixtures holds a private key"
ok "Relay/fixtures: three lists and a Linux signature by the test key, one signature by another key"

general=$group

# MARK: The mirror, the stand-in tools and the copies of setup.sh

mkdir -p "$mirror/helper-latest" "$mirror/helper-v9.8.7"
saved="$box/saved/release"
restore_mirror() {
  cp "$saved/manifest.json" "$saved/manifest.json.sig" "$mirror/helper-latest/"
  cp "$saved/Rex-DUO-Helper.zip" "$saved"/rex-duo-helper-linux-* "$mirror/helper-v9.8.7/"
  rm -f "$mirror/.delay"
}
restore_mirror
x86="$mirror/helper-v9.8.7/rex-duo-helper-linux-x86_64"
arm="$mirror/helper-v9.8.7/rex-duo-helper-linux-aarch64"
requests="$box/requests.log"
: > "$requests"
python3 -I "$here/tests-setup/mirror.py" "$mirror" "$box/port" "$requests" &
mirror_pid=$!
for _ in $(seq 50); do [[ -s "$box/port" ]] && break; sleep 0.1; done
PORT="$(cat "$box/port")"
[[ "$PORT" =~ ^[0-9]+$ ]] || fail "the mirror did not start"
asked() { grep -c "${1:-helper-v}" "$requests" || true; } # how many requests named that so far

uid="$(id -u)"
# stand_in <folder> <name> <what it does>: a tool that writes down how it was called.
stand_in() {
  mkdir -p "$1"
  printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$*" >> "$REXDUO_TEST_HOME/tools.log"\n%s\n' "$2" "$3" > "$1/$2"
  chmod +x "$1/$2"
}
linux_tools() { # linux_tools <folder>: this Mac says it is a Linux computer
  stand_in "$1" uname 'case "$1" in -s) echo "${REXDUO_TEST_OS:-Linux}" ;; -m) echo "${REXDUO_TEST_CPU:-x86_64}" ;; esac'
  stand_in "$1" systemctl 'if [ -f "$REXDUO_TEST_HOME/no-systemd" ]; then exit 1; fi'
  stand_in "$1" loginctl 'case "$1" in
  show-user) cat "$REXDUO_TEST_HOME/linger" 2>/dev/null || echo yes ;;
  enable-linger) echo yes > "$REXDUO_TEST_HOME/linger" ;;
esac'
  stand_in "$1" date 'if [ -n "${REXDUO_TEST_NOW:-}" ] && [ "$*" = "-u +%Y%m%d%H%M%S" ]; then echo "$REXDUO_TEST_NOW"; else exec /bin/date "$@"; fi'
}
linux_tools "$box/tools-linux"
ln -s "$OPENSSL" "$box/tools-linux/openssl"
linux_tools "$box/tools-linux-plain" # without openssl 3: only the system's LibreSSL
mac="$box/tools-mac"
stand_in "$mac" date 'if [ -n "${REXDUO_TEST_NOW:-}" ] && [ "$*" = "-u +%Y%m%d%H%M%S" ]; then echo "$REXDUO_TEST_NOW"; else exec /bin/date "$@"; fi'
# mv, which a test can stop at one of the two renames that replace an installed app.
stand_in "$mac" mv 'if [ -f "$REXDUO_TEST_HOME/no-rename" ]; then case "$*" in *".previous.app") exit 1 ;; esac; fi
if [ -f "$REXDUO_TEST_HOME/no-place" ]; then case "$*" in *".new-"*) exit 1 ;; esac; fi
exec /bin/mv "$@"'
stand_in "$mac" launchctl 'if [ -f "$REXDUO_TEST_HOME/no-gui" ]; then exit 1; fi'
stand_in "$mac" open ':'
stand_in "$mac" xattr ':'
stand_in "$mac" codesign 'if [ -f "$REXDUO_TEST_HOME/bad-signature" ]; then exit 1; fi'
stand_in "$mac" spctl 'echo "source=Notarized Developer ID" >&2'
stand_in "$mac" sw_vers 'if [ -f "$REXDUO_TEST_HOME/old-macos" ]; then echo 13.6.1; else exec /usr/bin/sw_vers "$@"; fi'

# copy <out> <tool folder, or "" for the system's alone> <more lines changed> [sed expressions]:
# a copy of setup.sh for tests. Fails when a line it replaces is not there any more.
# baked <out> …: the same from the install.sh of the release, which has two more lines changed.
COPY_FROM="$setup"
baked() { COPY_FROM="$saved/install.sh" copy "$@"; }
copy() {
  local to="$1" tools="$2" want=$((9 + $3))
  shift 3
  local -a edits=(
    -e "s|^BASE=.*|BASE=\"http://127.0.0.1:$PORT\"|"
    -e 's|^CURL_ONLY=.*|CURL_ONLY="--proto =http"|'
    -e "s|^PRIMARY_KEY=.*|PRIMARY_KEY=\"$PRIMARY\"|"
    -e "s|^RECOVERY_KEY=.*|RECOVERY_KEY=\"$RECOVERY\"|"
    -e 's|^SYSTEM_APPS=.*|SYSTEM_APPS="$REXDUO_TEST_HOME/SystemApplications"|'
    -e 's|^WAIT_SECONDS=.*|WAIT_SECONDS=2|'
    -e 's|^CODE_SECONDS=.*|CODE_SECONDS=3|'
    -e 's#^  HOME="$(account_home)" || HOME=""$#  HOME="$REXDUO_TEST_HOME"#'
    -e 's#^  STAGE_ROOT="$(stage_root)" || STAGE_ROOT=""$#  STAGE_ROOT="$REXDUO_TEST_HOME/tmp"#'
  )
  if [[ -n "$tools" ]]; then
    edits+=(-e "s|^TOOL_DIRS=.*|TOOL_DIRS=\"$tools /usr/bin /bin /usr/sbin /sbin\"|" -e "s@^      0) ;; # root\$@      0 | $uid) ;;@")
    want=$((want + 2))
  else
    # With the system's own tools nothing may get as far as the step that starts the service.
    edits+=(-e 's|^start() {$|start() { echo "TRIPWIRE: the start step was reached"; exit 99|')
    want=$((want + 1))
  fi
  sed "${edits[@]}" "$@" "$COPY_FROM" > "$to"
  [[ "$(awk 'NR == FNR { line[FNR] = $0; next } line[FNR] != $0 { n++ } END { print n + 0 }' "$setup" "$to")" == "$want" ]] \
    || fail "copy: sed changed other lines of setup.sh than the $want expected: $(diff "$setup" "$to" | grep '^>')"
}
copy "$box/linux.sh" "$box/tools-linux" 0
copy "$box/linux-plain.sh" "$box/tools-linux-plain" 0
copy "$box/linux-offline.sh" "$box/tools-linux" 0 -e 's|^BASE="http://127.0.0.1:.*|BASE="http://127.0.0.1:1"|'
copy "$box/linux-no-downloader.sh" "$box/tools-linux" 1 -e 's|^DOWNLOADERS=.*|DOWNLOADERS=""|'
copy "$box/mac.sh" "$mac" 0
copy "$box/mac-real.sh" "" 0
baked "$box/mac-baked.sh" "$mac" 2
baked "$box/mac-baked-floor.sh" "$mac" 2 -e 's|^MANUAL_MAC_FLOOR=.*|MANUAL_MAC_FLOOR="9.9.0"|'
baked "$box/mac-real-baked.sh" "" 2
grep -qx 'MANUAL_MAC_FLOOR="9.8.7"' "$box/mac-baked.sh" && grep -qx "MANUAL_MAC_EXPIRES=\"$(sed -n 's/^  "expires_at": "\(.*\)",$/\1/p' "$saved/manifest.json")\"" "$box/mac-baked.sh" \
  || fail "copy: the copy made from install.sh does not carry the release's two values"
# The tool folders with one a user owns in front, and the check of who owns a tool as shipped.
foreign="$box/foreign"
mkdir -p "$foreign"
for name in curl wget codesign spctl ditto plutil uname mktemp openssl sha256sum base64 launchctl open id rm; do
  printf '#!/bin/sh\necho "$0 $*" >> "%s"\nexit 0\n' "$box/foreign.log" > "$foreign/$name"
  chmod +x "$foreign/$name"
done
sed -e "s|^TOOL_DIRS=.*|TOOL_DIRS=\"$foreign /usr/bin /bin /usr/sbin /sbin\"|" "$box/mac-real.sh" > "$box/mac-real-foreign.sh"
grep -q "^TOOL_DIRS=\"$foreign " "$box/mac-real-foreign.sh" || fail "copy: the foreign tool folder is not in the copy"

NONCE="c0ffee11c0ffee22c0ffee33c0ffee44c0ffee55c0ffee66c0ffee77c0ffee88"
# What pty-run.py types when the installer asks for the setup code: the contents of this file.
printf '%s' "$NONCE" > "$box/code"
CODE_FILE="$box/code"
SERVER="unix:///tmp/zz-test/server.sock"
RUN_PATH="/usr/bin:/bin"
RUN_ENV=()
SHELL_CMD=(/bin/sh)
homes=0
new_home() { # a fresh home folder for one test, in H
  homes=$((homes + 1))
  H="$box/h/$homes"
  mkdir -p "$H/tmp"
}
# as_app <copy> <arguments>: sets APP_CMD to the command that starts the copy as the app does,
# in a pseudo-terminal, in the home folder H. What it prints goes to $H.out.
as_app() {
  local script="$1"
  shift
  APP_CMD=(python3 -I "$here/tests-setup/pty-run.py" "$H.out" "$CODE_FILE"
    /usr/bin/env -i PATH="$RUN_PATH" REXDUO_TEST_HOME="$H" REXDUO_TEST_PID="$$" REX_SERVER="$SERVER" ${RUN_ENV[@]+"${RUN_ENV[@]}"}
    "${SHELL_CMD[@]}" -c "$(cat "$script")" rexduo-setup "$@")
}
# run <copy> [arguments]: with arguments, starts the copy as the app does. Without, runs it by
# hand, with no terminal. Sets RC; what it printed is in $H.out.
run() {
  RC=0
  if [[ $# -gt 1 ]]; then
    as_app "$@"
    "${APP_CMD[@]}" || RC=$?
    CODE_FILE="$box/code" # one run's setting, for the same reason as in args
  else
    no_terminal "$@"
  fi
}
# no_terminal <copy> [arguments]: the copy with its input, output and messages not a terminal.
no_terminal() {
  local script="$1"
  shift
  RC=0
  env -i PATH="$RUN_PATH" REXDUO_TEST_HOME="$H" REXDUO_TEST_PID="$$" REX_SERVER="$SERVER" ${RUN_ENV[@]+"${RUN_ENV[@]}"} \
    "${SHELL_CMD[@]}" -c "$(cat "$script")" rexduo-setup "$@" < /dev/null > "$H.out" 2>&1 || RC=$?
}
# family <pid>: the process and everything it started.
family() {
  local kid
  echo "$1"
  for kid in $(pgrep -P "$1" || true); do family "$kid"; done
}
# args <version>: the 12 arguments the app would pass for that version on the mirror, in ARGS.
args() {
  local d="$mirror/helper-v$1"
  ARGS=(2 "$1" "${FLOOR:-9.0.0}"
    "$(sha "$d/Rex-DUO-Helper.zip")" "$(size "$d/Rex-DUO-Helper.zip")"
    "$(sha "$d/rex-duo-helper-linux-x86_64")" "$(size "$d/rex-duo-helper-linux-x86_64")"
    "$(sha "$d/rex-duo-helper-linux-aarch64")" "$(size "$d/rex-duo-helper-linux-aarch64")"
    "${KEYS_ARG:-$PRIMARY,$RECOVERY}" "${LINGER_ARG:-skip}" -)
  # One call's settings: when sh runs this file they would otherwise stay for the next call.
  unset FLOOR KEYS_ARG LINGER_ARG
}
ends() { # ends <code> <what>: the last run ended with that exit code
  [[ "$RC" == "$1" ]] || fail "$2: ended with $RC, expected $1: $(cat "$H.out")"
  ok "$2"
}
says() { grep -qF -- "$1" "$H.out" || fail "$2: did not say \"$1\": $(cat "$H.out")"; }
records() { python3 -I "$here/tests-setup/osc.py" "$H.out" | tr '\n' ';'; }
# Nothing of a run is left: no lock, no staging folder, no half-placed copy.
tidy() {
  [[ ! -e "$H/.local/state/rex-duo-helper/setup.lock" && ! -e "$H/Library/Application Support/Rex DUO Helper/setup.lock" ]] || fail "$1: the lock is still there"
  [[ -z "$(ls -A "$H/tmp")" ]] || fail "$1: the staging folder is still there: $(ls -A "$H/tmp")"
  [[ -z "$(find "$H" -name '.rex-duo-helper.new.*' -o -name '.Rex DUO Helper.app.new-*')" ]] || fail "$1: a half-placed copy is still there"
}
installed() { echo "$H/.local/bin/rex-duo-helper"; }
# The setup code, or any 12 characters in a row of it, in a file.
leaks() {
  NONCE="$NONCE" python3 -I - "$1" <<'PY'
import os, sys
nonce, data = os.environ["NONCE"], open(sys.argv[1], errors="replace").read()
sys.exit(0 if any(nonce[i:i + 12] in data for i in range(len(nonce) - 11)) else 1)
PY
}
# Every 12 characters in a row of the setup code, one per line, for grep -F -f.
NONCE="$NONCE" python3 -I -c 'import os; n = os.environ["NONCE"]; print("\n".join(n[i:i + 12] for i in range(len(n) - 11)))' > "$box/pieces"
# got_code <what>: the helper was handed the code in a file of mode 600, in a folder of mode
# 700 in the staging folder, as the last argument of `install`, and the file held the code alone.
got_code() {
  grep -qE "^install (--server [^ ]+ )?--setup-nonce-file $H/tmp/rexduo-setup\.[A-Za-z0-9]+/code\$" "$H/helper.log" || fail "$1: the helper's install got $(cat "$H/helper.log")"
  printf '600\n700\n%s' "$NONCE" | cmp -s - "$H/code.seen" || fail "$1: the code file was not mode 600 in a 700 folder with the code alone: $(cat "$H/code.seen" 2>&1)"
}
C="working code 5 -;"

# MARK: The installer, as a Linux computer sees it

linux_tests() {
  local before pid kids x i bad tried=0
  args 9.8.7
  local -a good=("${ARGS[@]}")

  # Arguments: one wrong value, or a wrong count, and nothing is downloaded or asked for.
  before="$(wc -l < "$requests")"
  local seven="$PRIMARY,$RECOVERY,$NEXT,$(public extra1),$(public extra2),$(public extra3),$(public stranger)"
  while read -r i bad; do
    tried=$((tried + 1))
    ARGS=("${good[@]}")
    ARGS[$((i - 1))]="$bad"
    new_home
    run "$box/linux.sh" "${ARGS[@]}"
    [[ "$RC" == 10 ]] || fail "argument $i as \"$bad\": ended with $RC, expected 10: $(cat "$H.out")"
    [[ "$(records)" == "error fail:E_ARGS - -;" ]] || fail "argument $i as \"$bad\": reported $(records)"
    [[ ! -e "$H/.local" ]] || fail "argument $i as \"$bad\": something was written"
  done <<EOF
1 1
1 3
1 02
2 9.8
2 9.8.7.1
2 09.8.7
2 9.8.x
2 12345.0.0
2 9.8.7;id
2 8.9.9
3 9..7
3 v9.0.0
3 9.9.0
4 ${good[3]%?}g
4 ${good[3]%?}
5 0
5 012
5 67108865
5 123456789
5 12a
6 ${good[5]%?}Z
7 -5
8 ${good[7]}0
9 1e3
10 ${PRIMARY%?}
10 ${PRIMARY%??}-=
10 $PRIMARY,
10 ,$PRIMARY
10 $PRIMARY,,$RECOVERY
10 $PRIMARY;$RECOVERY
10 $PRIMARY $RECOVERY
10 $PRIMARY,${RECOVERY%=}A
10 $seven
11 yes
11 ASK
12 x
12 --
12 $NONCE
EOF
  for bad in 11 13 1 old; do
    new_home
    case "$bad" in
      11) run "$box/linux.sh" "${good[@]:0:11}" ;;
      13) run "$box/linux.sh" "${good[@]}" extra ;;
      1) run "$box/linux.sh" 2 ;;
      # The 13 arguments of mode 1.
      old) run "$box/linux.sh" 1 "$NONCE" "${good[@]:1:8}" "$PRIMARY" "$RECOVERY" skip ;;
    esac
    [[ "$RC" == 10 ]] || fail "$bad arguments: ended with $RC, expected 10"
    [[ "$(records)" == "error fail:E_ARGS - -;" ]] || fail "$bad arguments: reported $(records)"
  done
  new_home
  run "$box/linux.sh" "${good[@]:0:11}" ""
  [[ "$RC" == 10 ]] || fail "an empty last argument: ended with $RC, expected 10"
  [[ "$(wc -l < "$requests")" == "$before" ]] || fail "a run with wrong arguments downloaded something"
  ok "$tried wrong values, across all 12 arguments, 4 wrong counts and the arguments of mode 1 end with 10, ask for no code and download nothing"

  # A good run, with the setup code watched in everything it prints and starts.
  new_home
  echo 1 > "$H/slow-install"
  : > "$box/ps.log"
  : > "$box/ps.seen"
  (while :; do
    ps -axww -o args= > "$box/ps.now" || true
    grep -F -f "$box/pieces" "$box/ps.now" >> "$box/ps.log" || true
    grep -c "rex-duo-helper install .*--setup-nonce-file" "$box/ps.now" >> "$box/ps.seen" || true
    sleep 0.05
  done) &
  pid=$!
  run "$box/linux.sh" "${good[@]}"
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null || true
  ends 0 "installs from the app's arguments and the code typed into the terminal"
  cmp -s "$(installed)" "$x86" || fail "the installed helper is not the file on the mirror"
  [[ "$(stat -f %Lp "$(installed)")" == 755 ]] || fail "the installed helper is not mode 755"
  tidy "a good run"
  [[ "$(records)" == "${C}working download 10 -;working verify 50 -;working install 70 -;working start 85 -;done done - -;" ]] || fail "a good run reported $(records)"
  ok "a good run reports code, download, verify, install, start and done as OSC 7501 records"
  got_code "a good run"
  grep -qF -- "--server $SERVER " "$H/helper.log" || fail "the helper was not started with --server: $(cat "$H/helper.log")"
  ok "the helper's install gets the Rex server of the tab and the code in a file of mode 600, which it deletes"
  if leaks "$H.out"; then fail "the output holds the setup code: $(cat "$H.out")"; fi
  if leaks "$H/tools.log" || leaks "$H/helper.log"; then fail "a tool or the helper was started with the setup code: $(cat "$H/tools.log" "$H/helper.log")"; fi
  grep -qx '[1-9][0-9]*' "$box/ps.seen" || fail "the process list never showed the helper's install (the watch did not work)"
  [[ ! -s "$box/ps.log" ]] || fail "a process was started with the setup code: $(cut -c 1-300 "$box/ps.log")"
  ok "the setup code is in no output and in no program's arguments"
  if grep -qF -e "$H" -e "${good[5]}" -e "$SERVER" -e "127.0.0.1" "$H.out"; then fail "the output holds a full path, a full hash or an address: $(cat "$H.out")"; fi
  says "~/.local/bin/rex-duo-helper" "a good run"
  says "SHA-256 ${good[5]:0:12}…" "a good run"
  ok "the output names paths from ~ and 12 characters of the hash"

  # The setup code: one line of 64 hex digits, within the time, from a terminal.
  before="$(wc -l < "$requests")"
  new_home
  CODE_FILE=- run "$box/linux.sh" "${good[@]}"
  ends 10 "no setup code within the time"
  says "did not send its setup code" "no setup code"
  [[ "$(records)" == "${C}error fail:E_ARGS - -;" ]] || fail "no setup code reported $(records)"
  for bad in "${NONCE%?}" "${NONCE}0" "$(printf '%s' "$NONCE" | tr a-f A-F)" "${NONCE%?}g" "${NONCE%??} 0" " $NONCE" ""; do
    printf '%s' "$bad" > "$box/code.bad"
    new_home
    CODE_FILE="$box/code.bad" run "$box/linux.sh" "${good[@]}"
    [[ "$RC" == 10 ]] || fail "the setup code as \"$bad\": ended with $RC, expected 10: $(cat "$H.out")"
    says "not a setup code" "the setup code as \"$bad\""
    [[ "$(records)" == "${C}error fail:E_ARGS - -;" ]] || fail "the setup code as \"$bad\" reported $(records)"
    if leaks "$H.out"; then fail "the setup code as \"$bad\": the output repeats what was typed"; fi
    [[ ! -e "$H/.local/bin" && ! -e "$H/helper.log" ]] || fail "the setup code as \"$bad\": something was installed"
  done
  ok "a setup code that is not 64 lowercase hex digits (7 kinds) ends with 10 and is not repeated"
  new_home
  no_terminal "$box/linux.sh" "${good[@]}"
  ends 10 "without a terminal there is no setup code"
  [[ "$(wc -l < "$requests")" == "$before" ]] || fail "a run without a setup code downloaded something"
  printf '%s|%s' "${NONCE:0:20}" "${NONCE:20}" > "$box/code.parts"
  new_home
  CODE_FILE="$box/code.parts" run "$box/linux.sh" "${good[@]}"
  ends 0 "a setup code that arrives in two parts is one line"
  got_code "a code in two parts"
  if leaks "$H.out"; then fail "a code in two parts: the output holds the setup code"; fi

  # The keys: 1 to 6, and a signature by any of them.
  new_home
  KEYS_ARG="$PRIMARY" args 9.8.7
  run "$box/linux.sh" "${ARGS[@]}"
  ends 0 "one key in the arguments"
  sign_with stranger "$box/text" "$x86.sig"
  new_home
  KEYS_ARG="$PRIMARY,$RECOVERY,$NEXT,$(public extra1),$(public extra2),$(public stranger)" args 9.8.7
  run "$box/linux.sh" "${ARGS[@]}"
  ends 0 "six keys in the arguments, and a signature by the last of them"
  new_home
  KEYS_ARG="$PRIMARY,$RECOVERY,$NEXT,$(public extra1),$(public extra2),$(public extra3)" args 9.8.7
  run "$box/linux.sh" "${ARGS[@]}"
  ends 14 "a signature by a key that is not among the six in the arguments"
  says "download's signature doesn't match" "a key that is not in the arguments"
  [[ ! -e "$(installed)" ]] || fail "a download signed by a key that is not in the arguments was installed"
  restore_mirror

  # Again: the same version is there, so nothing is downloaded. A newer one stays.
  new_home
  run "$box/linux.sh" "${good[@]}"
  before="$(asked)"
  rm -f "$H/.local/state/rex-duo-helper/status.json" "$H/code.seen"
  run "$box/linux.sh" "${good[@]}"
  ends 0 "a second run repairs the service"
  [[ "$(asked)" == "$before" ]] || fail "a second run downloaded again"
  [[ "$(records)" == "${C}working start 85 -;done done - -;" ]] || fail "a second run reported $(records)"
  got_code "a second run"
  ok "the same version already installed: no download"
  new_home
  mkdir -p "$H/.local/bin"
  fake_helper 9.9.0 "$(installed)"
  cp "$(installed)" "$box/newer"
  run "$box/linux.sh" "${good[@]}"
  ends 0 "a newer installed helper: the service is repaired"
  [[ "$(asked)" == "$before" ]] && cmp -s "$(installed)" "$box/newer" || fail "a newer installed helper was replaced"
  says "9.9.0 is already installed, newer than 9.8.7" "a newer installed helper"
  ok "a newer installed version is not replaced and nothing is downloaded"
  new_home
  mkdir -p "$H/.local/bin"
  fake_helper 9.8.0 "$(installed)"
  run "$box/linux.sh" "${good[@]}"
  ends 0 "an older installed helper is replaced"
  cmp -s "$(installed)" "$x86" || fail "an older installed helper stayed"
  new_home
  mkdir -p "$H/.local/bin"
  fake_helper 9.8.7 "$(installed)" "not the released file"
  run "$box/linux.sh" "${good[@]}"
  ends 0 "the same version with other contents is replaced"
  cmp -s "$(installed)" "$x86" || fail "a changed helper of the same version stayed"

  # What is on the mirror is not what the arguments name.
  new_home
  tr 'a' 'b' < "$saved/rex-duo-helper-linux-x86_64" > "$x86"
  run "$box/linux.sh" "${good[@]}"
  ends 14 "a download with changed bytes"
  says "not the file the release list names" "changed bytes"
  [[ ! -e "$(installed)" ]] || fail "a download with changed bytes was installed"
  tidy "a download with changed bytes"
  [[ "$(records)" == "${C}working download 10 -;working verify 50 -;error fail:E_VERIFY - -;" ]] || fail "a refused download reported $(records)"
  ok "a refused download reports fail:E_VERIFY as an OSC 7501 record"
  { cat "$saved/rex-duo-helper-linux-x86_64"; printf 'x'; } > "$x86"
  new_home
  run "$box/linux.sh" "${good[@]}"
  ends 14 "a download one byte longer"
  says "not the size the release list names" "one byte longer"
  head -c 100 "$saved/rex-duo-helper-linux-x86_64" > "$x86"
  new_home
  run "$box/linux.sh" "${good[@]}"
  ends 14 "a download cut short"
  [[ ! -e "$(installed)" ]] || fail "a download of the wrong size was installed"
  restore_mirror

  # The Linux signature, where openssl 3 is there to check it.
  sign_with stranger "$box/text" "$x86.sig"
  new_home
  run "$box/linux.sh" "${good[@]}"
  ends 14 "a download signed by a key that is not trusted"
  says "download's signature doesn't match" "a stranger's signature"
  KEYS_ARG="$(public stranger),$RECOVERY" args 9.8.7
  new_home
  run "$box/linux.sh" "${ARGS[@]}"
  ends 0 "the keys in the arguments are the ones the signature is checked with"
  new_home
  run "$box/linux-plain.sh" "${good[@]}"
  ends 0 "without openssl 3 the size and the hash decide"
  restore_mirror
  KEYS_ARG="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=,AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=" args 9.8.7
  new_home
  run "$box/linux.sh" "${ARGS[@]}"
  ends 14 "an all-zero key in the arguments is no key"

  # No network, no downloader.
  new_home
  run "$box/linux-offline.sh" "${good[@]}"
  ends 13 "the mirror is down"
  [[ "$(records)" == "${C}working download 10 -;error fail:E_NET - -;" ]] || fail "no network reported $(records)"
  tidy "the mirror is down"
  new_home
  run "$box/linux-no-downloader.sh" "${good[@]}"
  ends 12 "neither curl nor wget"
  tidy "neither curl nor wget"

  # The lock.
  new_home
  mkdir -p "$H/.local/state/rex-duo-helper/setup.lock"
  echo "$$ $(date +%s)" > "$H/.local/state/rex-duo-helper/setup.lock/owner"
  run "$box/linux.sh" "${good[@]}"
  ends 16 "another install holds the lock"
  [[ -f "$H/.local/state/rex-duo-helper/setup.lock/owner" && ! -e "$(installed)" ]] || fail "a held lock was removed"
  echo "$$ $(($(date +%s) - 1900))" > "$H/.local/state/rex-duo-helper/setup.lock/owner"
  run "$box/linux.sh" "${good[@]}"
  ends 0 "a lock older than 30 minutes is taken over"
  tidy "an old lock"
  new_home
  mkdir -p "$H/.local/state/rex-duo-helper/setup.lock"
  (exit 0) &
  wait $!
  echo "$! $(date +%s)" > "$H/.local/state/rex-duo-helper/setup.lock/owner"
  run "$box/linux.sh" "${good[@]}"
  ends 0 "a lock of a process that is gone is taken over"
  tidy "a dead process's lock"

  # Nowhere to write.
  new_home
  mkdir -p "$H/.local/bin"
  chmod 555 "$H/.local/bin"
  run "$box/linux.sh" "${good[@]}"
  ends 15 "a folder that can't be written"
  says "couldn't save Rex DUO Helper in ~/.local/bin" "an unwritable folder"
  chmod 755 "$H/.local/bin"
  tidy "an unwritable folder"
  new_home
  rmdir "$H/tmp"
  : > "$H/tmp"
  run "$box/linux.sh" "${good[@]}"
  [[ "$RC" == 15 ]] || fail "no folder for the download: ended with $RC, expected 15"
  rm -f "$H/tmp"
  mkdir "$H/tmp"

  # Stopped half way, then run again.
  new_home
  echo 30 > "$mirror/.delay"
  before="$(asked)"
  as_app "$box/linux.sh" "${good[@]}"
  "${APP_CMD[@]}" &
  pid=$!
  for _ in $(seq 100); do [[ "$(asked)" != "$before" ]] && break; sleep 0.1; done
  kids="$(family "$pid")"
  kill -9 $kids 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  [[ -d "$H/.local/state/rex-duo-helper/setup.lock" && -n "$(ls -A "$H/tmp")" ]] || fail "kill -9 while downloading: expected a lock and a staging folder to be left"
  rm -f "$mirror/.delay"
  mkdir -p "$H/.local/bin"
  : > "$H/.local/bin/.rex-duo-helper.new.4242"
  run "$box/linux.sh" "${good[@]}"
  ends 0 "killed while downloading, the next run installs"
  cmp -s "$(installed)" "$x86" || fail "after a kill the next run did not install"
  tidy "after a kill"
  ok "the next run removes the lock, the staging folder and the half-placed copy a kill left"
  new_home
  echo 30 > "$H/slow-install"
  as_app "$box/linux.sh" "${good[@]}"
  "${APP_CMD[@]}" &
  pid=$!
  for _ in $(seq 100); do [[ -s "$H/helper.log" ]] && grep -q "^install" "$H/helper.log" && break; sleep 0.1; done
  kids="$(family "$pid")"
  kill -9 $kids 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  rm -f "$H/slow-install"
  before="$(asked)"
  run "$box/linux.sh" "${good[@]}"
  ends 0 "killed while the service started, the next run repairs it"
  [[ "$(asked)" == "$before" ]] || fail "the repair after a kill downloaded again"
  tidy "after a kill at the service step"
  # Closing the tab: the hangup reaches the installer and its download, and nothing stays.
  new_home
  echo 30 > "$mirror/.delay"
  before="$(asked)"
  as_app "$box/linux.sh" "${good[@]}"
  "${APP_CMD[@]}" &
  pid=$!
  for _ in $(seq 100); do [[ "$(asked)" != "$before" ]] && break; sleep 0.1; done
  kill -HUP "$pid"
  RC=0
  wait "$pid" 2>/dev/null || RC=$?
  rm -f "$mirror/.delay"
  ends 129 "closing the terminal while downloading stops the installer"
  tidy "after a hangup"
  [[ ! -e "$(installed)" ]] || fail "a hangup while downloading installed something"

  # The service.
  new_home
  : > "$H/no-start"
  run "$box/linux.sh" "${good[@]}"
  ends 17 "the helper does not start"
  [[ "$(records)" == *"working start 85 -;error fail:E_SERVICE - -;" ]] || fail "a helper that does not start reported $(records)"
  new_home
  mkdir -p "$H/.local/state/rex-duo-helper"
  : > "$H/no-start"
  (exit 0) &
  wait $!
  echo "{\"version\":\"9.8.7\",\"pid\":$!}" > "$H/.local/state/rex-duo-helper/status.json"
  run "$box/linux.sh" "${good[@]}"
  ends 17 "a status.json of a helper that is gone does not count"
  echo "{\"latest_version\":\"9.9.9\",\"version\":\"9.8.6\",\"pid\":$$}" > "$H/.local/state/rex-duo-helper/status.json"
  run "$box/linux.sh" "${good[@]}"
  ends 17 "a status.json of an older running helper does not count"
  new_home
  : > "$H/no-systemd"
  : > "$H/no-start"
  run "$box/linux.sh" "${good[@]}"
  ends 19 "no systemd for this account"
  says "~/.local/bin/rex-duo-helper run" "no systemd"
  cmp -s "$(installed)" "$x86" || fail "without systemd the helper was not installed"

  # Lingering.
  new_home
  echo no > "$H/linger"
  LINGER_ARG=ask args 9.8.7
  run "$box/linux.sh" "${ARGS[@]}"
  ends 0 "lingering is off and the app said ask"
  grep -q "^loginctl enable-linger " "$H/tools.log" || fail "ask: loginctl enable-linger was not called"
  [[ "$(records)" == *"working start 85 -;blocked linger - auth;working linger 97 -;done done - -;" ]] || fail "ask reported $(records)"
  says "linger=on" "ask"
  new_home
  echo no > "$H/linger"
  run "$box/linux.sh" "${good[@]}"
  ends 0 "lingering is off and the app said skip"
  if grep -q "^loginctl enable-linger " "$H/tools.log"; then fail "skip: loginctl enable-linger was called"; fi
  says "linger=off" "skip"

  # Other computers.
  new_home
  RUN_ENV=(REXDUO_TEST_CPU=aarch64)
  run "$box/linux.sh" "${good[@]}"
  RUN_ENV=()
  ends 0 "an aarch64 computer gets the aarch64 file"
  cmp -s "$(installed)" "$arm" || fail "aarch64: the wrong file was installed"
  before="$(wc -l < "$requests")"
  for x in "REXDUO_TEST_CPU=riscv64" "REXDUO_TEST_CPU=armv7l" "REXDUO_TEST_OS=FreeBSD"; do
    new_home
    RUN_ENV=("$x")
    run "$box/linux.sh" "${good[@]}"
    RUN_ENV=()
    [[ "$RC" == 11 ]] || fail "$x: ended with $RC, expected 11"
  done
  [[ "$(wc -l < "$requests")" == "$before" ]] || fail "a computer with no build downloaded something"
  ok "a CPU or a system with no build ends with 11 before any download"

  # What the tab's environment holds does not steer the installer.
  new_home
  RUN_ENV=("HOME=$box/elsewhere" "TMPDIR=$box/elsewhere" "IFS=/" "ENV=$box/elsewhere/env" "BASH_ENV=$box/elsewhere/env" "CURL_HOME=$box/elsewhere" "LD_PRELOAD=$box/elsewhere/x.so")
  SERVER="not a server address"
  run "$box/linux.sh" "${good[@]}"
  SERVER="unix:///tmp/zz-test/server.sock"
  RUN_ENV=()
  ends 0 "HOME, IFS, ENV and the like in the environment change nothing"
  [[ ! -e "$box/elsewhere" ]] && cmp -s "$(installed)" "$x86" || fail "the environment moved the install"
  grep -q "^install --setup-nonce-file " "$H/helper.log" || fail "a REX_SERVER that is no address was passed on: $(cat "$H/helper.log")"
  ok "a REX_SERVER that is not a unix or https address is left out"
}

# MARK: The installer run by hand: the release list and its signatures

by_hand_tests() {
  local expires later before
  # accepted <what> / refused <what> <words>: a run with no arguments against the mirror as it is now.
  accepted() {
    new_home
    run "$box/linux.sh"
    ends 0 "by hand: $1"
    cmp -s "$(installed)" "${2:-$x86}" || fail "by hand: $1: the helper was not installed"
  }
  refused() {
    new_home
    run "$box/linux.sh"
    [[ "$RC" == 14 ]] || fail "by hand: $1: ended with $RC, expected 14: $(cat "$H.out")"
    says "$2" "by hand: $1"
    [[ ! -e "$(installed)" ]] || fail "by hand: $1: something was installed"
    ok "by hand: refuses $1"
  }
  list() { cp "$1" "$mirror/helper-latest/manifest.json"; cp "$2" "$mirror/helper-latest/manifest.json.sig"; }

  restore_mirror
  accepted "the release list release.sh signed"
  [[ "$(records)" == "" ]] || fail "by hand, with the output in a file, records were printed"
  grep -qxF "install --server $SERVER" "$H/helper.log" || fail "by hand: the helper's install got $(cat "$H/helper.log")"
  says "  primary   $(python3 -c 'import base64,hashlib,sys; print(hashlib.sha256(base64.b64decode(sys.argv[1])).hexdigest())' "$PRIMARY")" "by hand: fingerprints"
  says "  recovery  $(python3 -c 'import base64,hashlib,sys; print(hashlib.sha256(base64.b64decode(sys.argv[1])).hexdigest())' "$RECOVERY")" "by hand: fingerprints"
  ok "by hand: prints the SHA-256 of the two keys"
  new_home
  RC=0
  env -i PATH="$RUN_PATH" REXDUO_TEST_HOME="$H" REXDUO_TEST_PID="$$" "${SHELL_CMD[@]}" < "$box/linux.sh" > "$H.out" 2>&1 || RC=$?
  ends 0 "by hand: piped into the shell, as curl … | sh"
  RUN_ENV=(REXDUO_TEST_CPU=aarch64)
  accepted "the aarch64 file" "$arm"
  RUN_ENV=()

  # Tampered manifest: one character of a hash, and the version.
  sed 's/"sha256": "\(.\)/"sha256": "0\1/' "$saved/manifest.json" | cut -c 1-200 > "$box/tampered.json"
  list "$box/tampered.json" "$saved/manifest.json.sig"
  refused "a manifest with a changed hash" "signature doesn't match"
  sed 's/"version": "9.8.7"/"version": "9.8.8"/' "$saved/manifest.json" > "$box/tampered.json"
  list "$box/tampered.json" "$saved/manifest.json.sig"
  refused "a manifest with a changed version" "signature doesn't match"
  sign_with stranger "$saved/manifest.json" "$box/stranger.sig"
  list "$saved/manifest.json" "$box/stranger.sig"
  refused "a manifest signed by a key that is not trusted" "signature doesn't match"
  : > "$box/empty.sig"
  list "$saved/manifest.json" "$box/empty.sig"
  refused "a manifest with an empty signature file" "signature doesn't match"
  # Several signatures in one file: one good line is enough, wherever it is. Past 8 lines, none.
  { cat "$box/stranger.sig"; echo "not a signature"; echo; cat "$saved/manifest.json.sig"; } > "$box/many.sig"
  list "$saved/manifest.json" "$box/many.sig"
  accepted "a signature file with a stranger's line, junk and a good line"
  { for _ in 1 2 3 4 5 6 7 8; do cat "$box/stranger.sig"; done; cat "$saved/manifest.json.sig"; } > "$box/ninth.sig"
  list "$saved/manifest.json" "$box/ninth.sig"
  refused "a good signature on the ninth line" "signature doesn't match"
  head -c 70000 /dev/zero | tr '\0' ' ' > "$box/huge.json"
  list "$box/huge.json" "$saved/manifest.json.sig"
  refused "a release list over 64 KiB" "larger than a release list can be"

  # Expired: at the second it expires and long after. One second before is still good.
  list "$saved/manifest.json" "$saved/manifest.json.sig"
  expires="$(sed -n 's/^  "expires_at": "\(.*\)",$/\1/p' "$saved/manifest.json")"
  RUN_ENV=("REXDUO_TEST_NOW=$(printf '%s' "$expires" | tr -cd 0-9)")
  refused "a manifest at the second it expires" "out of date"
  RUN_ENV=(REXDUO_TEST_NOW=20990101000000)
  refused "a manifest long past its date" "out of date"
  later="$(python3 -c 'import datetime,sys; f="%Y-%m-%dT%H:%M:%SZ"; print((datetime.datetime.strptime(sys.argv[1], f) - datetime.timedelta(seconds=1)).strftime("%Y%m%d%H%M%S"))' "$expires")"
  RUN_ENV=("REXDUO_TEST_NOW=$later")
  accepted "a manifest one second before it expires"
  RUN_ENV=()

  # Signed, but missing what the installer must read: it stops instead of guessing.
  signed_list() { sign_with primary "$1" "$1.sig"; list "$1" "$1.sig"; }
  grep -v '"expires_at"' "$saved/manifest.json" > "$box/no-expiry.json"
  signed_list "$box/no-expiry.json"
  refused "a signed manifest without expires_at" "doesn't say when it expires"
  sed 's/"expires_at": "[^"]*"/"expires_at": "next year"/' "$saved/manifest.json" > "$box/bad-expiry.json"
  signed_list "$box/bad-expiry.json"
  refused "a signed manifest with a date in another spelling" "doesn't say when it expires"
  sed 's/"min_version": "9.8.7"/"min_version": "9.9.0"/' "$saved/manifest.json" > "$box/min.json"
  signed_list "$box/min.json"
  refused "a signed manifest that asks for more than it names" "newer version than it names"
  sed 's/"version": "9.8.7"/"version": "9.08.7"/' "$saved/manifest.json" > "$box/zero.json"
  signed_list "$box/zero.json"
  refused "a signed manifest with a version in another spelling" "has no version"
  python3 - "$saved/manifest.json" "$box/no-arm.json" "$box/no-size.json" "$box/big.json" <<'PY'
import json, sys
src, no_arm, no_size, big = sys.argv[1:]
m = json.load(open(src))
del m["assets"]["linux-aarch64"]
json.dump(m, open(no_arm, "w"), indent=2)
m = json.load(open(src))
del m["assets"]["linux-x86_64"]["size"]
json.dump(m, open(no_size, "w"), indent=2)
m = json.load(open(src))
m["assets"]["linux-x86_64"]["size"] = (64 << 20) + 1
json.dump(m, open(big, "w"), indent=2)
PY
  signed_list "$box/no-arm.json"
  RUN_ENV=(REXDUO_TEST_CPU=aarch64)
  refused "a manifest with no entry for this architecture" "names no file for linux-aarch64"
  RUN_ENV=()
  signed_list "$box/no-size.json"
  refused "a manifest with no size for this architecture" "names no size for linux-x86_64"
  signed_list "$box/big.json"
  refused "a manifest with a file over 64 MiB" "names no size for linux-x86_64"

  # Tampered binary: same size with one byte changed, and one byte longer.
  restore_mirror
  tr 'a' 'b' < "$saved/rex-duo-helper-linux-x86_64" > "$x86"
  refused "a binary with changed bytes" "not the file the release list names"
  { cat "$saved/rex-duo-helper-linux-x86_64"; printf 'x'; } > "$x86"
  refused "a binary of another size" "not the size the release list names"
  # The other architecture's signature, and its file under this architecture's name.
  restore_mirror
  cp "$saved/rex-duo-helper-linux-aarch64.sig" "$x86.sig"
  refused "the aarch64 signature for the x86_64 binary" "download's signature doesn't match"
  restore_mirror
  cp "$saved/rex-duo-helper-linux-aarch64" "$x86"
  refused "the aarch64 binary served as x86_64" "not the size the release list names"
  # A signature over the file itself, one for another version, and a stranger's.
  restore_mirror
  sign_with primary "$x86" "$x86.sig"
  refused "a signature over the file's bytes alone" "download's signature doesn't match"
  printf 'rex-duo-helper|9.8.6|linux-x86_64|%s' "$x86_sha" > "$box/older.txt"
  sign_with primary "$box/older.txt" "$x86.sig"
  refused "a signature made for another version" "download's signature doesn't match"
  sign_with stranger "$box/text" "$x86.sig"
  refused "a binary signed by a key that is not trusted" "download's signature doesn't match"
  sign_with recovery "$box/text" "$x86.sig"
  accepted "a binary signed by the recovery key"
  restore_mirror

  # The list re-signed by the recovery key, with a next key in it.
  list "$box/saved/resigned.json" "$box/saved/resigned.json.sig"
  accepted "the list re-signed by the recovery key"
  list "$box/saved/resigned.json" "$saved/manifest.json.sig"
  refused "the old signature for the re-signed list" "signature doesn't match"
  restore_mirror

  # Without openssl 3 a Linux computer can't check the list, and installs nothing.
  before="$(asked)"
  new_home
  run "$box/linux-plain.sh"
  ends 14 "by hand: without openssl 3 nothing is installed on Linux"
  says "openssl 3 or newer is needed" "by hand without openssl 3"
  [[ "$(asked)" == "$before" ]] || fail "by hand without openssl 3: the helper was downloaded"
  new_home
  run "$box/linux-offline.sh"
  ends 13 "by hand: the mirror is down"
  new_home
  run "$box/linux-no-downloader.sh"
  ends 12 "by hand: neither curl nor wget"
}

# MARK: The installer on this Mac

# on_mirror <version> <zip>: that zip as the Mac file of a version, beside the Linux files.
on_mirror() {
  mkdir -p "$mirror/helper-v$1"
  cp "$saved"/rex-duo-helper-linux-* "$mirror/helper-v$1/"
  cp "$2" "$mirror/helper-v$1/Rex-DUO-Helper.zip"
}
fake_app "$box/app-next" 9.8.9
zip_app "$box/app-next" "$box/next.zip"
on_mirror 9.8.9 "$box/next.zip"
adhoc=0
fake_app "$box/app-adhoc" 9.7.1 true
if /usr/bin/codesign --force -s - "$box/app-adhoc/Rex DUO Helper.app" >/dev/null 2>&1; then
  adhoc=1
  zip_app "$box/app-adhoc" "$box/adhoc.zip"
  on_mirror 9.7.1 "$box/adhoc.zip"
fi
# Two things in one zip.
mkdir -p "$box/two"
cp -R "$box/app/Rex DUO Helper.app" "$box/two/"
echo extra > "$box/two/README"
(cd "$box/two" && /usr/bin/zip -qr "$box/two.zip" .)
on_mirror 9.6.2 "$box/two.zip"
# A Developer ID build of the real helper, when package.sh left one. Only its checks run.
real_zip="$here/dist/release/Rex-DUO-Helper.zip"
real_version=""
if [[ -f "$real_zip" ]]; then
  mkdir -p "$box/real"
  /usr/bin/ditto -x -k "$real_zip" "$box/real"
  real_version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$box/real/Rex DUO Helper.app/Contents/Info.plist")"
  on_mirror "$real_version" "$real_zip"
fi

mac_app() { echo "$H/SystemApplications/Rex DUO Helper.app"; }
mac_untouched() { # nothing was placed, started or opened
  [[ ! -e "$H/SystemApplications" && ! -e "$H/Applications" && ! -e "$H/helper.log" ]] || fail "$1: something was installed or started"
  if grep -q TRIPWIRE "$H.out"; then fail "$1: the start step was reached"; fi
  tidy "$1"
}

mac_tests() {
  local before pid
  # With the system's own codesign and spctl: only a notarized app of this team passes.
  args 9.8.7
  new_home
  run "$box/mac-real.sh" "${ARGS[@]}"
  ends 14 "Mac: an unsigned app"
  says "code signature was not accepted" "an unsigned app"
  mac_untouched "an unsigned app"
  [[ "$(records)" == "${C}working download 10 -;working verify 50 -;error fail:E_VERIFY - -;" ]] || fail "Mac: an unsigned app reported $(records)"
  if [[ $adhoc == 1 ]]; then
    args 9.7.1
    new_home
    run "$box/mac-real.sh" "${ARGS[@]}"
    ends 14 "Mac: an app signed ad hoc, by nobody"
    says "code signature was not accepted" "an ad hoc signature"
    mac_untouched "an ad hoc signature"
  else
    echo "skip  ${label}Mac: an app signed ad hoc (codesign could not sign the fixture)"
  fi
  args 9.6.2
  new_home
  run "$box/mac-real.sh" "${ARGS[@]}"
  ends 14 "Mac: a zip that holds more than the app"
  says "does not hold Rex DUO Helper alone" "two things in the zip"
  mac_untouched "two things in the zip"
  if [[ -n "$real_version" ]]; then
    FLOOR=0.0.1 args "$real_version"
    new_home
    run "$box/mac-real.sh" "${ARGS[@]}"
    if [[ "$RC" == 14 ]] && grep -q "did not accept the downloaded app as notarized" "$H.out"; then
      ok "Mac: the Developer ID build in dist/release passes the code signature check and stops at notarization"
      mac_untouched "the Developer ID build"
    elif [[ "$RC" == 99 ]] && grep -q TRIPWIRE "$H.out"; then
      # A notarized build passes every check and is put in the test's home folder. The copy
      # under test stops there, before anything of it runs.
      [[ -d "$H/Applications/Rex DUO Helper.app" && ! -e "$H/helper.log" && ! -e "$H/tools.log" ]] || fail "Mac: the notarized build was not placed, or something was started"
      [[ "$(records)" == "${C}working download 10 -;working verify 50 -;working install 70 -;" ]] || fail "Mac: the notarized build reported $(records)"
      ok "Mac: the notarized Developer ID build in dist/release passes the system's own codesign and spctl"
    else
      fail "Mac: the Developer ID build in dist/release: ended with $RC: $(cat "$H.out")"
    fi
  else
    echo "skip  ${label}Mac: a Developer ID build that is not notarized (no dist/release/Rex-DUO-Helper.zip here)"
  fi

  # A PATH with other tools in front, and a tool folder that is not root's.
  args 9.8.7
  rm -f "$box/foreign.log"
  new_home
  RUN_PATH="$foreign:/usr/bin:/bin"
  run "$box/mac-real.sh" "${ARGS[@]}"
  RUN_PATH="/usr/bin:/bin"
  ends 14 "Mac: with other tools first on PATH the result is the same"
  [[ ! -e "$box/foreign.log" ]] || fail "a tool from PATH was used: $(cat "$box/foreign.log")"
  ok "a curl, codesign or uname on PATH is never run"
  new_home
  run "$box/mac-real-foreign.sh" "${ARGS[@]}"
  ends 14 "Mac: a tool folder that does not belong to root is left out"
  says "code signature was not accepted" "a tool folder of the user's"
  [[ ! -e "$box/foreign.log" ]] || fail "a tool from a folder that is not root's was used: $(cat "$box/foreign.log")"
  ok "a tool in a folder that is not root's is never run"

  # From here codesign, spctl, launchctl and open are stand-ins, to reach the steps after the checks.
  new_home
  mkdir "$H/SystemApplications"
  run "$box/mac.sh" "${ARGS[@]}"
  ends 0 "Mac: installs into the system Applications folder"
  [[ -x "$(mac_app)/Contents/MacOS/rex-duo-helper" ]] || fail "Mac: the app is not in place"
  tidy "Mac: a good run"
  [[ "$(records)" == "${C}working download 10 -;working verify 50 -;working install 70 -;working start 85 -;working notify 95 -;done done - -;" ]] || fail "Mac: a good run reported $(records)"
  got_code "Mac: a good run"
  grep -qxF "open -g -a $(mac_app) --args phone-setup" "$H/tools.log" || fail "Mac: open was not called for the notification question: $(cat "$H/tools.log")"
  [[ "$(grep -c '^launchctl ' "$H/tools.log")" == 1 ]] && grep -qxF "launchctl print gui/$uid" "$H/tools.log" || fail "Mac: launchctl was called for more than the login check"
  grep -q -- "-R=identifier \"dev.abrahamgonzalez.rexduo.helper\" and anchor apple generic and certificate 1\[field.1.2.840.113635.100.6.2.6\] exists and certificate leaf\[field.1.2.840.113635.100.6.1.13\] exists and certificate leaf\[subject.OU\] = \"R2PVQ496X7\" " "$H/tools.log" \
    || fail "Mac: codesign was not given the requirement of update.rs"
  grep -qF "codesign --verify --deep --strict $H/tmp/" "$H/tools.log" && grep -qF "spctl --assess --type execute -vv $H/tmp/" "$H/tools.log" || fail "Mac: the download was not checked as update.rs checks it"
  grep -qF "codesign --verify --deep --strict $H/SystemApplications/.Rex DUO Helper.app.new-" "$H/tools.log" || fail "Mac: the copy was not checked again where it was placed"
  if leaks "$H.out" || leaks "$H/tools.log" || leaks "$H/helper.log"; then fail "Mac: the setup code is in the output or in a program's arguments"; fi
  if grep -qF -e "$H" "$H.out"; then fail "Mac: the output holds a full path: $(cat "$H.out")"; fi
  ok "Mac: codesign and spctl get the arguments of update.rs, before and after the app is placed"
  ok "Mac: the helper's install gets the server and the code in a file, and open asks for phone-setup"
  before="$(asked)"
  rm -f "$H/Library/Application Support/Rex DUO Helper/status.json"
  run "$box/mac.sh" "${ARGS[@]}"
  ends 0 "Mac: a second run repairs the service"
  [[ "$(asked)" == "$before" ]] || fail "Mac: a second run downloaded again"
  ok "Mac: the same version already installed: no download"

  new_home
  run "$box/mac.sh" "${ARGS[@]}"
  ends 0 "Mac: installs into ~/Applications when the system folder can't be written"
  [[ -x "$H/Applications/Rex DUO Helper.app/Contents/MacOS/rex-duo-helper" ]] || fail "Mac: the app is not in ~/Applications"
  says "~/Applications/Rex DUO Helper.app" "Mac: ~/Applications"

  # An older app is there: it updates itself, or waits beside the new one until that one runs.
  local apps previous
  old_app() { # a fresh home with version 9.8.7 installed
    new_home
    apps="$H/SystemApplications"
    previous="$apps/Rex DUO Helper.previous.app"
    mkdir "$apps"
    cp -R "$box/app/Rex DUO Helper.app" "$apps/"
  }
  app_is() { [[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$(mac_app)/Contents/Info.plist")" == "$1" ]]; }
  runs() { tr '\n' ';' < "$H/helper-runs.log"; } # which version of the helper was called, and how
  args 9.8.9
  old_app
  echo 9.8.9 > "$H/update-to"
  run "$box/mac.sh" "${ARGS[@]}"
  ends 0 "Mac: an older app updates itself"
  grep -qx "update" "$H/helper.log" || fail "Mac: the older app was not asked to update"
  [[ ! -e "$previous" && ! -e "$H/.Trash" ]] || fail "Mac: an app that updated itself was set aside"
  says "It is now version 9.8.9." "Mac: self-update"
  got_code "Mac: self-update"
  old_app
  mkdir "$previous"
  run "$box/mac.sh" "${ARGS[@]}"
  ends 0 "Mac: an older app that can't update itself is replaced"
  app_is 9.8.9 || fail "Mac: the new app is not in place"
  [[ "$(ls -A "$apps")" == "Rex DUO Helper.app" && ! -e "$H/.Trash" ]] || fail "Mac: the app that was replaced is still there, or in the Trash: $(ls -A "$apps")"
  [[ "$(runs)" == "9.8.7 update;9.8.9 install;" ]] || fail "Mac: replacing an app called the helper as $(runs)"
  got_code "Mac: a replaced app"
  tidy "Mac: a replaced app"
  ok "Mac: the app that was replaced is removed once the new helper runs, and is never in the Trash"
  # The new one does not start: the old one is back, running, and the code is the failure's.
  old_app
  : > "$H/no-start"
  run "$box/mac.sh" "${ARGS[@]}"
  ends 17 "Mac: the new app does not start, so the old one is put back"
  app_is 9.8.7 || fail "Mac: the old app is not back in place"
  [[ "$(ls -A "$apps")" == "Rex DUO Helper.app" ]] || fail "Mac: after putting the old app back the folder holds $(ls -A "$apps")"
  [[ "$(runs)" == "9.8.7 update;9.8.9 install;9.8.7 install;" ]] || fail "Mac: putting the old app back called the helper as $(runs)"
  [[ "$(tail -n 1 "$H/helper.log")" == "install --server $SERVER" ]] || fail "Mac: the old app was started again as $(tail -n 1 "$H/helper.log")"
  says "installed before is back in its place" "Mac: the old app is put back"
  [[ "$(records)" == *"working start 85 -;error fail:E_SERVICE - -;" ]] || fail "Mac: a new app that does not start reported $(records)"
  tidy "Mac: the old app is put back"
  ok "Mac: the old app is started again, without the setup code"
  # The new app can't be renamed into place after the old one was set aside.
  old_app
  : > "$H/no-place"
  run "$box/mac.sh" "${ARGS[@]}"
  ends 15 "Mac: the new app can't be put in place, so the old one is put back"
  app_is 9.8.7 || fail "Mac: the old app is not back in place"
  [[ "$(ls -A "$apps")" == "Rex DUO Helper.app" ]] || fail "Mac: after a failed rename the folder holds $(ls -A "$apps")"
  [[ "$(runs)" == "9.8.7 update;9.8.7 install;" ]] || fail "Mac: after a failed rename the helper was called as $(runs)"
  tidy "Mac: a failed rename"
  # Closing the terminal while the new one starts.
  old_app
  echo 30 > "$H/slow-install"
  as_app "$box/mac.sh" "${ARGS[@]}"
  "${APP_CMD[@]}" &
  pid=$!
  for _ in $(seq 150); do [[ -d "$previous" ]] && grep -q "^9.8.9 install" "$H/helper-runs.log" 2>/dev/null && break; sleep 0.1; done
  [[ -d "$previous" ]] || fail "Mac: the old app was not set aside while the new one starts"
  rm -f "$H/slow-install"
  kill -HUP "$pid"
  RC=0
  wait "$pid" 2>/dev/null || RC=$?
  ends 129 "Mac: closing the terminal while the new app starts puts the old one back"
  app_is 9.8.7 && [[ "$(ls -A "$apps")" == "Rex DUO Helper.app" ]] || fail "Mac: after a hangup the folder holds $(ls -A "$apps")"
  pkill -f "$H/SystemApplications" 2>/dev/null || true
  tidy "Mac: a hangup while starting"
  # macOS does not let the old app be renamed: it stays, and nothing else changed.
  old_app
  : > "$H/no-rename"
  run "$box/mac.sh" "${ARGS[@]}"
  ends 20 "Mac: an old app that can't be set aside stays"
  app_is 9.8.7 || fail "Mac: the old app is gone though nothing replaced it"
  [[ "$(ls -A "$apps")" == "Rex DUO Helper.app" && "$(runs)" == "9.8.7 update;" ]] || fail "Mac: an old app that can't be set aside: $(ls -A "$apps"), $(runs)"
  tidy "Mac: an old app that can't be set aside"
  # An update that stopped between its two moves.
  args 9.8.7
  new_home
  mkdir "$H/SystemApplications"
  cp -R "$box/app/Rex DUO Helper.app" "$H/SystemApplications/Rex DUO Helper.previous.app"
  mkdir "$H/SystemApplications/.Rex DUO Helper.app.new-4242"
  before="$(asked)"
  run "$box/mac.sh" "${ARGS[@]}"
  ends 0 "Mac: an app that an update set aside is put back"
  [[ "$(asked)" == "$before" && -d "$(mac_app)" && ! -e "$H/SystemApplications/Rex DUO Helper.previous.app" ]] || fail "Mac: the set-aside app was not put back"
  tidy "Mac: leftovers"
  # A set-aside copy beside an app that is whole.
  args 9.8.7
  new_home
  mkdir "$H/SystemApplications"
  cp -R "$box/app/Rex DUO Helper.app" "$H/SystemApplications/Rex DUO Helper.app"
  cp -R "$box/app/Rex DUO Helper.app" "$H/SystemApplications/Rex DUO Helper.previous.app"
  run "$box/mac.sh" "${ARGS[@]}"
  ends 0 "Mac: a set-aside copy beside a whole app is removed"
  [[ "$(ls -A "$H/SystemApplications")" == "Rex DUO Helper.app" ]] || fail "Mac: the set-aside copy stayed: $(ls -A "$H/SystemApplications")"
  # While the helper is updating itself, it stays.
  new_home
  mkdir -p "$H/SystemApplications" "$H/Library/Application Support/Rex DUO Helper"
  : > "$H/Library/Application Support/Rex DUO Helper/update.lock"
  cp -R "$box/app/Rex DUO Helper.app" "$H/SystemApplications/Rex DUO Helper.app"
  cp -R "$box/app/Rex DUO Helper.app" "$H/SystemApplications/Rex DUO Helper.previous.app"
  run "$box/mac.sh" "${ARGS[@]}"
  [[ -d "$H/SystemApplications/Rex DUO Helper.previous.app" ]] || fail "Mac: the set-aside copy was removed during the helper's own update"
  tidy "Mac: a set-aside copy"

  new_home
  : > "$H/no-gui"
  run "$box/mac.sh" "${ARGS[@]}"
  ends 18 "Mac: nobody is logged in"
  [[ ! -e "$H/helper.log" ]] || fail "Mac: the helper was started with nobody logged in"
  new_home
  : > "$H/old-macos"
  before="$(wc -l < "$requests")"
  run "$box/mac.sh" "${ARGS[@]}"
  ends 21 "Mac: macOS 13"
  [[ "$(wc -l < "$requests")" == "$before" ]] || fail "Mac: macOS 13 downloaded something"
  new_home
  : > "$H/no-start"
  run "$box/mac.sh" "${ARGS[@]}"
  ends 17 "Mac: the helper does not start"
  [[ -d "$H/Applications/Rex DUO Helper.app" ]] || fail "Mac: a first install that did not start was removed"
  new_home
  mkdir "$H/SystemApplications"
  cp -R "$box/app/Rex DUO Helper.app" "$H/SystemApplications/"
  : > "$H/bad-signature"
  run "$box/mac.sh" "${ARGS[@]}"
  ends 14 "Mac: with a failing code signature nothing is run or replaced"
  [[ ! -e "$H/helper.log" && -d "$(mac_app)" ]] || fail "Mac: an app with a failing signature was run or removed"

  # By hand on a Mac: the copy must be the install.sh of a release, within its date, and the
  # list must name a version it installs. Then Apple's checks decide.
  local expires notice="On this Mac the release list's signature is not checked."
  expires="$(sed -n 's/^MANUAL_MAC_EXPIRES="\(.*\)"$/\1/p' "$box/mac-baked.sh" | tr -cd 0-9)"
  before="$(wc -l < "$requests")"
  new_home
  run "$box/mac.sh"
  ends 14 "Mac, by hand: a copy without the two values of a release installs nothing"
  says "is not the install.sh of a release" "Mac, by hand: no values"
  says "Download Rex DUO Helper from " "Mac, by hand: no values"
  mac_untouched "Mac, by hand: no values"
  new_home
  RUN_ENV=("REXDUO_TEST_NOW=$expires")
  run "$box/mac-baked.sh"
  ends 14 "Mac, by hand: at the second the installer expires it installs nothing"
  says "This installer is out of date" "Mac, by hand: expired"
  mac_untouched "Mac, by hand: expired"
  [[ "$(wc -l < "$requests")" == "$before" ]] || fail "Mac, by hand: a refused installer downloaded something"
  new_home
  RUN_ENV=("REXDUO_TEST_NOW=$((expires - 1))")
  run "$box/mac-baked.sh"
  RUN_ENV=()
  ends 0 "Mac, by hand: one second before, it installs the version the release list names"
  new_home
  before="$(asked)"
  run "$box/mac-baked-floor.sh"
  ends 14 "Mac, by hand: a version below the installer's own is not installed"
  says "older than this installer installs (9.9.0)" "Mac, by hand: below the floor"
  [[ "$(asked)" == "$before" ]] || fail "Mac, by hand: a version below the floor was downloaded"
  mac_untouched "Mac, by hand: below the floor"
  new_home
  run "$box/mac-baked.sh"
  ends 0 "Mac, by hand: the install.sh of a release installs the version the list names"
  [[ "$(grep -cF "$notice" "$H.out")" == 1 ]] || fail "Mac, by hand: the notice about the signature was not printed once: $(cat "$H.out")"
  says "Apple's code signature and notarization checks of the app are." "Mac, by hand: the notice"
  grep -qxF "install --server $SERVER" "$H/helper.log" || fail "Mac, by hand: the helper's install got $(cat "$H/helper.log")"
  [[ "$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$H/Applications/Rex DUO Helper.app/Contents/Info.plist")" == 9.8.7 ]] || fail "Mac, by hand: the app is not in place"
  ok "Mac, by hand: says that Apple's checks decide, not the list's signature"
  new_home
  run "$box/mac-real-baked.sh"
  ends 14 "Mac, by hand: an unsigned app"
  mac_untouched "Mac, by hand: an unsigned app"
}

# MARK: Every shell

counts=""
for shell in "bash --posix" /bin/sh /bin/dash; do
  read -r -a SHELL_CMD <<< "$shell"
  command -v "${SHELL_CMD[0]}" >/dev/null 2>&1 || { echo "skip  $shell is not on this computer"; continue; }
  label="$shell: "
  group=0
  linux_tests
  by_hand_tests
  mac_tests
  counts="$counts; $shell $group"
done
label=""

kill "$mirror_pid" 2>/dev/null
wait "$mirror_pid" 2>/dev/null || true
mirror_pid=""
! pgrep -f "$box" >/dev/null || fail "a process of the tests is still running: $(pgrep -fl "$box")"
printf '%s checks passed (release.sh and the files as committed %s%s).\n' "$passed" "$general" "$counts"
