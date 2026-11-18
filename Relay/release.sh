#!/usr/bin/env bash
# Builds a Rex DUO Beacon release and, with --publish, puts it on GitHub.
#
#   Relay/release.sh                 # build, sign, notarize, write Relay/dist/release. Publishes nothing.
#   Relay/release.sh --skip-build    # reuse what Relay/package.sh already left in Relay/dist
#   Relay/release.sh --publish       # also create the GitHub releases (asks nothing: be sure)
#   Relay/release.sh --resign        # sign the current release list again with a new expiry date.
#                                    # Builds nothing. With --publish, uploads the list and install.sh.
#
# What a release is (the helper's updater, the Rex DUO app and setup.sh rely on every part):
#   - a GitHub release tagged helper-v<version> with the Mac app (zipped, twice), the two Linux
#     binaries and a signature beside each Linux binary. The Mac app is one signed, notarized
#     bundle in two zips: Rex-DUO-Beacon.zip holds it as "Rex DUO Beacon.app", the manifest's
#     macos-universal-beacon entry, which the installer, the app and the helper's updater take.
#     Rex-DUO-Helper.zip holds it as "Rex DUO Helper.app", the manifest's macos-universal
#     entry: the updater of version 0.3.0 reads that entry and looks for that folder. A
#     bundle's folder name is no part of its code signature, and the app gives itself its
#     name once it runs (src/rename.rs);
#   - the release tagged helper-latest, which only ever holds manifest.json, manifest.json.sig and
#     install.sh, so their addresses never change. install.sh is Relay/setup.sh under the name
#     people run it by, with two values written in: the release's version and the list's expiry
#     date. Run by hand on a Mac, it installs nothing older and nothing after that date. They
#     go into that copy only: Relay/setup.sh, which the app carries, is read and never changed.
#     The copy's SHA-256 is printed and written into docs/helper.md between the install-sha
#     markers, for people who check the script before they run it. Commit that with the release.
#
# The manifest (the release list) is signed as a file. A Linux binary's signature covers the text
#   rex-duo-helper|<version>|<platform>|<sha256 of the file>
# so a signed file can't be served as another version or for another architecture. Both are made
# with the ed25519 key at UPDATE_KEY (default ~/.config/rexduo/helper-update.key), which must be
# one of the two in Relay/update-key.pub: the primary key, or the recovery key. The Mac app is
# signed and notarized by package.sh; the helper checks that with macOS's own tools.
#
# The manifest also says:
#   min_version  helpers older than this are told they must update. Default: this release.
#                Set MIN_VERSION to an older version when this release still works with it.
#   expires_at   EXPIRES_DAYS from now (default 180). The helper, the app and setup.sh refuse
#                the list after that, so a list must be signed again (--resign) before then even
#                when nothing is released.
#   next_key     null, or with NEXT_KEY=<base64 of 32 bytes> a public key helpers trust from then
#                on. That is how the signing key is replaced: publish a list that names the new
#                key, signed with a key helpers already trust (the recovery key, if the primary
#                is the one being replaced), then sign with the new key.
#
# Beside the release it writes Relay/dist/release/fixtures: the same list and one Linux
# signature, signed by a key made on the spot and thrown away, with that key's public half in
# test-key.pub. Tests of the app read them; they are never published.
#
# Needs: what package.sh needs, openssl 3 (OPENSSL, or Homebrew's), python3, and gh for --publish.
set -euo pipefail

cd "$(dirname "$0")"

REPO="${REPO:-theabecaster/rexduo}"
UPDATE_KEY="${UPDATE_KEY:-$HOME/.config/rexduo/helper-update.key}"
OPENSSL="${OPENSSL:-}"
PUBLISH=0
BUILD=1
RESIGN=0
PACKAGE_ARGS=()

die() {
  echo "release: $*" >&2
  exit 1
}

for arg in "$@"; do
  case "$arg" in
    --publish) PUBLISH=1 ;;
    --skip-build) BUILD=0 ;;
    --resign) RESIGN=1 ;;
    --no-notarize) PACKAGE_ARGS+=("--no-notarize") ;;
    *) die "unknown option $arg" ;;
  esac
done
[[ $PUBLISH -eq 1 && ${#PACKAGE_ARGS[@]} -gt 0 ]] && die "--publish needs a notarized build: the helper refuses to install any other"

if [[ -z "$OPENSSL" ]]; then
  for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl openssl; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" pkeyutl -help 2>&1 | grep -q -- '-rawin'; then
      OPENSSL="$candidate"
      break
    fi
  done
fi
[[ -n "$OPENSSL" ]] || die "openssl 3 is needed (macOS's own is LibreSSL). Install it or set OPENSSL."

VERSION="$(sed -n 's/^version = "\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)"$/\1/p' Cargo.toml | head -n 1)"
[[ -n "$VERSION" ]] || die "no version in Cargo.toml"
TAG="helper-v$VERSION"
BASE="https://github.com/$REPO/releases/download"
MIN_VERSION="${MIN_VERSION:-$VERSION}"
[[ "$MIN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "MIN_VERSION must look like 1.2.3"
NEXT_KEY="${NEXT_KEY:-}"
EXPIRES_DAYS="${EXPIRES_DAYS:-180}"
[[ "$EXPIRES_DAYS" =~ ^[1-9][0-9]{0,3}$ ]] || die "EXPIRES_DAYS must be a number of days from 1 to 9999"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The committed public keys, and that the signing key is one of them and setup.sh agrees.
committed_key() { sed -n "s/^$1[[:space:]][[:space:]]*\([A-Za-z0-9+\/=]*\)[[:space:]]*$/\1/p" update-key.pub; }
PRIMARY="$(committed_key primary)"
RECOVERY="$(committed_key recovery)"
[[ ${#PRIMARY} -eq 44 && ${#RECOVERY} -eq 44 ]] || die "update-key.pub must hold a primary and a recovery key"
[[ -r "$UPDATE_KEY" ]] || die "no signing key at $UPDATE_KEY (set UPDATE_KEY)"
public="$("$OPENSSL" pkey -in "$UPDATE_KEY" -pubout -outform DER | tail -c 32 | "$OPENSSL" base64 -A)"
case "$public" in
  "$PRIMARY") SIGNER=primary ;;
  "$RECOVERY") SIGNER=recovery ;;
  *) die "the signing key is neither the primary nor the recovery key in update-key.pub" ;;
esac
grep -q "^PRIMARY_KEY=\"$PRIMARY\"$" setup.sh || die "setup.sh carries a different primary key than update-key.pub"
grep -q "^RECOVERY_KEY=\"$RECOVERY\"$" setup.sh || die "setup.sh carries a different recovery key than update-key.pub"
if [[ -n "$NEXT_KEY" ]]; then
  [[ "$(printf '%s' "$NEXT_KEY" | "$OPENSSL" base64 -d -A 2>/dev/null | wc -c | tr -d ' ')" == "32" && ${#NEXT_KEY} -eq 44 ]] \
    || die "NEXT_KEY must be the base64 of a 32-byte ed25519 public key"
fi
echo "==> Signing with the $SIGNER key"

# A public key as a file openssl reads: the fixed 12-byte header of an ed25519 key, then the key.
key_der() { # key_der <base64 key> <out>
  { printf '\060\052\060\005\006\003\053\145\160\003\041\000'; printf '%s' "$1" | "$OPENSSL" base64 -d -A; } > "$2"
}
key_der "$PRIMARY" "$work/primary.der"
key_der "$RECOVERY" "$work/recovery.der"

sign_with() { # sign_with <key file> <file> <signature file>: the base64 of the raw signature over the file's bytes
  "$OPENSSL" pkeyutl -sign -inkey "$1" -rawin -in "$2" | "$OPENSSL" base64 -A > "$3"
  echo >> "$3"
}
sign() { sign_with "$UPDATE_KEY" "$@"; } # sign <file> <signature file>
verify() { # verify <file> <signature file>: against the committed public keys, never the private one
  "$OPENSSL" base64 -d -A -in "$2" -out "$work/sig.raw"
  [[ "$(wc -c < "$work/sig.raw" | tr -d ' ')" == "64" ]] || return 1
  local der
  for der in "$work/primary.der" "$work/recovery.der"; do
    if "$OPENSSL" pkeyutl -verify -pubin -keyform DER -inkey "$der" -rawin -in "$1" -sigfile "$work/sig.raw" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}
sha256_of() { "$OPENSSL" dgst -sha256 -r "$1" | cut -c 1-64; }
# What a Linux binary's signature covers. No newline at the end.
binary_text() { # binary_text <file> <platform> <out>
  printf 'rex-duo-helper|%s|%s|%s' "$VERSION" "$2" "$(sha256_of "$1")" > "$3"
}

OUT="dist/release"
DOC="../docs/helper.md"

# EXPIRES_DAYS from now, in the one spelling the helper, the app and setup.sh read.
EXPIRES_AT="$(python3 -c 'import datetime, sys; print((datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=int(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%SZ"))' "$EXPIRES_DAYS")"

# What the app's tests read: the release list as it is published and the signature of its
# x86_64 Linux binary, both signed by a key that exists only for the length of this function.
write_fixtures() {
  local dir="$OUT/fixtures" key="$work/fixture.key"
  rm -rf "$dir"
  mkdir -p "$dir"
  "$OPENSSL" genpkey -algorithm ed25519 -out "$key" 2>/dev/null
  {
    echo "# A key made by Relay/release.sh for tests and thrown away. It signs nothing that is published."
    echo "primary  $("$OPENSSL" pkey -in "$key" -pubout -outform DER | tail -c 32 | "$OPENSSL" base64 -A)"
  } > "$dir/test-key.pub"
  cp "$OUT/manifest.json" "$dir/manifest.json"
  sign_with "$key" "$dir/manifest.json" "$dir/manifest.json.sig"
  python3 - "$dir/manifest.json" > "$work/fixture.txt" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
sys.stdout.write("rex-duo-helper|%s|linux-x86_64|%s" % (m["version"], m["assets"]["linux-x86_64"]["sha256"]))
PY
  sign_with "$key" "$work/fixture.txt" "$dir/rex-duo-helper-linux-x86_64.sig"
  rm -f "$key"
}

# write_installer <version> <expires at>: setup.sh as install.sh, with the two values a run by
# hand on a Mac goes by. Nothing else differs, and setup.sh itself is only read.
write_installer() {
  [[ "$(grep -c '^MANUAL_MAC_FLOOR=""$' setup.sh)" == 1 && "$(grep -c '^MANUAL_MAC_EXPIRES=""$' setup.sh)" == 1 ]] \
    || die "setup.sh must have the lines MANUAL_MAC_FLOOR=\"\" and MANUAL_MAC_EXPIRES=\"\" once each"
  sed -e "s|^MANUAL_MAC_FLOOR=\"\"\$|MANUAL_MAC_FLOOR=\"$1\"|" -e "s|^MANUAL_MAC_EXPIRES=\"\"\$|MANUAL_MAC_EXPIRES=\"$2\"|" setup.sh > "$OUT/install.sh"
  chmod 0755 "$OUT/install.sh"
  [[ "$(diff setup.sh "$OUT/install.sh" | grep -c '^>')" == 2 ]] || die "install.sh differs from setup.sh in more than the two values"
  INSTALL_SHA="$(sha256_of "$OUT/install.sh")"
}

# Says the SHA-256 of install.sh and writes it into docs/helper.md between its two markers.
note_installer() {
  echo "==> SHA-256 of install.sh: $INSTALL_SHA"
  if [[ -f "$DOC" ]] && grep -qx '<!-- install-sha -->' "$DOC" && grep -qx '<!-- /install-sha -->' "$DOC"; then
    python3 - "$DOC" "$INSTALL_SHA" <<'PY'
import re, sys
path, digest = sys.argv[1:]
with open(path) as f:
    text = f.read()
block = "<!-- install-sha -->\n```\n%s  install.sh\n```\n<!-- /install-sha -->" % digest
text, count = re.subn(r"<!-- install-sha -->\n.*?<!-- /install-sha -->", lambda _: block, text, count=1, flags=re.S)
if count != 1:
    sys.exit("release: the install-sha markers in %s are not in order" % path)
with open(path, "w") as f:
    f.write(text)
PY
    echo "    docs/helper.md now names it. Commit that with the release."
  else
    echo "    It goes into docs/helper.md, between <!-- install-sha --> and <!-- /install-sha -->."
  fi
}

if [[ $RESIGN -eq 1 ]]; then
  [[ $BUILD -eq 1 && ${#PACKAGE_ARGS[@]} -eq 0 ]] || die "--resign builds nothing: leave out --skip-build and --no-notarize"
  if [[ ! -f "$OUT/manifest.json" ]]; then
    command -v gh >/dev/null 2>&1 || die "no $OUT/manifest.json here, and gh is needed to download the published one"
    mkdir -p "$OUT"
    gh release download helper-latest --repo "$REPO" --pattern manifest.json --dir "$OUT"
  fi
  # Only the dates and, when asked, the next key change. The files it names stay as they are.
  python3 - "$OUT/manifest.json" "$EXPIRES_AT" "$NEXT_KEY" <<'PY'
import json, re, sys
path, expires_at, next_key = sys.argv[1:]
with open(path) as f:
    manifest = json.load(f)
if not re.fullmatch(r"\d+\.\d+\.\d+", str(manifest.get("version", ""))) or not isinstance(manifest.get("assets"), dict):
    sys.exit(f"release: {path} is not a release list")
manifest.setdefault("min_version", manifest["version"])
manifest["expires_at"] = expires_at
if next_key:
    manifest["next_key"] = next_key
manifest.setdefault("next_key", None)
with open(path, "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
  sign "$OUT/manifest.json" "$OUT/manifest.json.sig"
  verify "$OUT/manifest.json" "$OUT/manifest.json.sig" || die "the new signature of manifest.json does not verify"
  write_fixtures
  # install.sh carries the expiry date, so it is written again for the version the list names.
  rm -f "$OUT/install.sh"
  write_installer "$(sed -n 's/^  "version": "\([0-9.]*\)",$/\1/p' "$OUT/manifest.json")" "$EXPIRES_AT"
  echo "==> Signed Relay/$OUT/manifest.json again. It expires at $EXPIRES_AT."
  note_installer
  if [[ $PUBLISH -eq 0 ]]; then
    echo "Nothing was published. Run again with --resign --publish."
    exit 0
  fi
  command -v gh >/dev/null 2>&1 || die "gh is needed to publish"
  gh release upload helper-latest --repo "$REPO" --clobber "$OUT/install.sh"
  # The signature before the manifest: a helper that reads the new manifest finds its signature.
  gh release upload helper-latest --repo "$REPO" --clobber "$OUT/manifest.json.sig"
  gh release upload helper-latest --repo "$REPO" --clobber "$OUT/manifest.json"
  echo "==> Published the re-signed list and install.sh."
  exit 0
fi

if [[ $BUILD -eq 1 ]]; then
  ./package.sh ${PACKAGE_ARGS[@]+"${PACKAGE_ARGS[@]}"}
fi

ZIP_SRC="dist/Rex DUO Beacon.zip"
LINUX=(rex-duo-helper-linux-x86_64 rex-duo-helper-linux-aarch64)
[[ -f "$ZIP_SRC" ]] || die "missing $ZIP_SRC (run without --skip-build)"
for f in "${LINUX[@]}"; do [[ -f "dist/$f" ]] || die "missing dist/$f"; done

rm -rf "$OUT"
mkdir -p "$OUT"
# No spaces in a release file's name: GitHub would rewrite them.
ZIP="Rex-DUO-Beacon.zip"
OLD_ZIP="Rex-DUO-Helper.zip"
APP_DIR="Rex DUO Beacon.app"
OLD_APP_DIR="Rex DUO Helper.app"
cp "$ZIP_SRC" "$OUT/$ZIP"
# The second zip: the same bundle, file for file, in a folder of the earlier name.
/usr/bin/ditto -x -k "$OUT/$ZIP" "$work/app"
[[ "$(ls -A "$work/app")" == "$APP_DIR" ]] || die "$ZIP_SRC must hold $APP_DIR alone"
mkdir "$work/old"
/usr/bin/ditto "$work/app/$APP_DIR" "$work/old/$OLD_APP_DIR"
/usr/bin/ditto -c -k --keepParent "$work/old/$OLD_APP_DIR" "$OUT/$OLD_ZIP"
for f in "${LINUX[@]}"; do cp "dist/$f" "$OUT/$f"; done
# The notices of the crates in the binaries, and a stop for a crate whose terms are not listed.
NOTICES="THIRD_PARTY_LICENSES.txt"
python3 ./third-party-licenses.py "$OUT/$NOTICES" || die "the crate licences could not be listed"
# The installer goes out under the name people run it by.
write_installer "$VERSION" "$EXPIRES_AT"

# The app in each zip must be this version, or every helper would refuse it, and the two zips
# must hold the same bundle, each alone under its folder name.
/usr/bin/ditto -x -k "$OUT/$OLD_ZIP" "$work/app-old"
[[ "$(ls -A "$work/app-old")" == "$OLD_APP_DIR" ]] || die "$OLD_ZIP must hold $OLD_APP_DIR alone"
for app in "$work/app/$APP_DIR" "$work/app-old/$OLD_APP_DIR"; do
  found="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$app/Contents/Info.plist")"
  [[ "$found" == "$VERSION" ]] || die "the app in ${app##*/} is version $found, not $VERSION"
  [[ "$(/usr/bin/plutil -extract CFBundleName raw -o - "$app/Contents/Info.plist")" == "Rex DUO Beacon" ]] || die "the app in ${app##*/} is not named Rex DUO Beacon"
done
diff -r "$work/app/$APP_DIR" "$work/app-old/$OLD_APP_DIR" >/dev/null || die "the two zips hold different apps"
# A signed build keeps its code signature under either folder name.
if /usr/bin/codesign --verify --deep --strict "$work/app/$APP_DIR" >/dev/null 2>&1; then
  /usr/bin/codesign --verify --deep --strict "$work/app-old/$OLD_APP_DIR" >/dev/null 2>&1 || die "the app in $OLD_ZIP lost its code signature"
fi

for f in "${LINUX[@]}"; do
  binary_text "$OUT/$f" "${f#rex-duo-helper-}" "$work/$f.txt"
  sign "$work/$f.txt" "$OUT/$f.sig"
done

# One field per line (indent=2): setup.sh reads this file with sed and awk.
python3 - "$OUT" "$VERSION" "$BASE/$TAG" "$ZIP" "$OLD_ZIP" "$MIN_VERSION" "$EXPIRES_AT" "$NEXT_KEY" "${LINUX[@]}" <<'PY'
import datetime, hashlib, json, os, sys
out, version, base, zip_name, old_zip_name, min_version, expires_at, next_key, *linux = sys.argv[1:]

def number(v):
    return tuple(int(part) for part in v.split("."))

if number(min_version) > number(version):
    sys.exit(f"release: MIN_VERSION {min_version} is newer than the release, {version}")

def asset(name):
    path = os.path.join(out, name)
    with open(path, "rb") as f:
        digest = hashlib.sha256(f.read()).hexdigest()
    return {"url": f"{base}/{name}", "sha256": digest, "size": os.path.getsize(path)}

# macos-universal is the entry the updater of version 0.3.0 reads: the zip with the folder it
# looks for. It takes every entry of "assets" that has these three fields, so the second Mac
# entry sits beside the first.
assets = {"macos-universal": asset(old_zip_name), "macos-universal-beacon": asset(zip_name)}
for name in linux:
    assets[name.removeprefix("rex-duo-helper-")] = asset(name)
manifest = {
    "version": version,
    "min_version": min_version,
    "released_at": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "expires_at": expires_at,
    "next_key": next_key or None,
    "assets": assets,
}
with open(os.path.join(out, "manifest.json"), "w") as f:
    json.dump(manifest, f, indent=2)
    f.write("\n")
PY
sign "$OUT/manifest.json" "$OUT/manifest.json.sig"

# Everything again, from the files as they will be published and the committed public keys.
verify "$OUT/manifest.json" "$OUT/manifest.json.sig" || die "the signature of manifest.json does not verify"
for f in "${LINUX[@]}"; do
  binary_text "$OUT/$f" "${f#rex-duo-helper-}" "$work/$f.check"
  verify "$work/$f.check" "$OUT/$f.sig" || die "the signature of $f does not verify"
  grep -q "\"sha256\": \"$(sha256_of "$OUT/$f")\"" "$OUT/manifest.json" || die "manifest.json does not name the hash of $f"
done
for f in "$ZIP" "$OLD_ZIP"; do
  grep -q "\"sha256\": \"$(sha256_of "$OUT/$f")\"" "$OUT/manifest.json" || die "manifest.json does not name the hash of $f"
done
write_fixtures

echo "==> Release $VERSION is in Relay/$OUT (min_version $MIN_VERSION, expires $EXPIRES_AT):"
ls -1 "$OUT"
note_installer

if [[ $PUBLISH -eq 0 ]]; then
  echo "Nothing was published. Run again with --publish (add --skip-build to reuse this build)."
  exit 0
fi

command -v gh >/dev/null 2>&1 || die "gh is needed to publish"
# The app must be notarized and stapled, or no Mac would take the update.
for app in "$work/app/$APP_DIR" "$work/app-old/$OLD_APP_DIR"; do
  xcrun stapler validate "$app" >/dev/null 2>&1 || die "the Mac app in ${app##*/} is not notarized and stapled"
done
if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  die "$TAG is already released. Raise the version in Cargo.toml."
fi

echo "==> Publishing $TAG to $REPO"
# The files first. Helpers only learn of them from the manifest, which goes up last.
gh release create "$TAG" --repo "$REPO" --title "Rex DUO Beacon $VERSION" --latest \
  --notes "Rex DUO Beacon $VERSION. Install steps: https://github.com/$REPO/blob/main/docs/helper.md" \
  "$OUT/$ZIP" "$OUT/$OLD_ZIP" "$OUT/${LINUX[0]}" "$OUT/${LINUX[0]}.sig" "$OUT/${LINUX[1]}" "$OUT/${LINUX[1]}.sig" "$OUT/$NOTICES"

if ! gh release view helper-latest --repo "$REPO" >/dev/null 2>&1; then
  gh release create helper-latest --repo "$REPO" --title "Rex DUO Beacon: latest version" --latest=false \
    --notes "Holds only the list of the current Rex DUO Beacon release and the installer. Installed copies, the Rex DUO app and install.sh read them from here. Downloads are in the newest helper-v release."
fi
gh release upload helper-latest --repo "$REPO" --clobber "$OUT/install.sh"
# The signature before the manifest: a helper that reads the new manifest finds its signature.
gh release upload helper-latest --repo "$REPO" --clobber "$OUT/manifest.json.sig"
gh release upload helper-latest --repo "$REPO" --clobber "$OUT/manifest.json"

echo "==> Published. Installed copies pick it up within 12 hours, or at once with: rex-duo-helper update"
