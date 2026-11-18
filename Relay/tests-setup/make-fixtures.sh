#!/usr/bin/env bash
# Writes Relay/fixtures again: a small release list and its signatures, for the tests of the
# app and of the helper to read. Nothing in it is a secret. The two keys are made here and their
# private halves are deleted when the script ends, so nothing else can ever be signed with them
# and no release is.
#
#   Relay/tests-setup/make-fixtures.sh
#
#   test-key.pub                       the key the tests trust, in the format of update-key.pub
#   manifest.json, manifest.json.sig   version 9.8.7, expires in 2099, one entry for a Mac
#   manifest-beacon.json, .sig         the same list with the Mac's second entry, macos-universal-beacon
#   rex-duo-helper-linux-x86_64.sig    over rex-duo-helper|9.8.7|linux-x86_64|<sha256 in the list>
#   manifest-expired.json, .sig        the same list, expired in 2020
#   manifest-older.json, .sig          version 9.8.6
#   manifest-untrusted.json.sig        manifest.json signed by a key the tests don't trust
#
# The files the list names don't exist: their hashes are of the short texts below. Every run
# makes new keys, so every file changes; commit them together.
#
# Needs openssl 3 (OPENSSL, or Homebrew's) and python3.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
out="$here/../fixtures"
OPENSSL="${OPENSSL:-}"
if [[ -z "$OPENSSL" ]]; then
  for candidate in /opt/homebrew/opt/openssl@3/bin/openssl /usr/local/opt/openssl@3/bin/openssl openssl; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" pkeyutl -help 2>&1 | grep -q -- '-rawin'; then
      OPENSSL="$candidate"
      break
    fi
  done
fi
[[ -n "$OPENSSL" ]] || { echo "make-fixtures: openssl 3 is needed (set OPENSSL)" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/rexduo-fixtures.XXXXXX")"
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"
rm -f "$out"/manifest*.json "$out"/*.sig "$out/test-key.pub"

for name in test stranger; do
  "$OPENSSL" genpkey -algorithm ed25519 -out "$work/$name.key" 2>/dev/null
done
sign_with() { # sign_with <key name> <file> <signature file>
  "$OPENSSL" pkeyutl -sign -inkey "$work/$1.key" -rawin -in "$2" | "$OPENSSL" base64 -A > "$3"
  echo >> "$3"
}
{
  echo "# A key made by Relay/tests-setup/make-fixtures.sh for tests. Its private half was deleted."
  echo "primary  $("$OPENSSL" pkey -in "$work/test.key" -pubout -outform DER | tail -c 32 | "$OPENSSL" base64 -A)"
} > "$out/test-key.pub"

# The same shape release.sh writes: one field per line, two spaces of indent.
python3 - "$out" <<'PY'
import hashlib, json, os, sys
out = sys.argv[1]
base = "https://github.com/theabecaster/rexduo/releases/download"
files = {
    "macos-universal": ("Rex-DUO-Helper.zip", b"a helper for a Mac\n"),
    "linux-x86_64": ("rex-duo-helper-linux-x86_64", b"a helper for x86_64\n"),
    "linux-aarch64": ("rex-duo-helper-linux-aarch64", b"a helper for aarch64, a little longer\n"),
}

def manifest(version, expires_at):
    return {
        "version": version,
        "min_version": "9.8.0",
        "released_at": "2026-01-01T00:00:00Z",
        "expires_at": expires_at,
        "next_key": None,
        "assets": {
            platform: {"url": f"{base}/helper-v{version}/{name}", "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}
            for platform, (name, data) in files.items()
        },
    }

# The same release with the Mac app a second time, in the zip that holds it as Rex DUO Beacon.app.
beacon = manifest("9.8.7", "2099-01-01T00:00:00Z")
data = b"a beacon for a Mac\n"
beacon["assets"]["macos-universal-beacon"] = {"url": f"{base}/helper-v9.8.7/Rex-DUO-Beacon.zip", "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}

for name, m in {
    "manifest.json": manifest("9.8.7", "2099-01-01T00:00:00Z"),
    "manifest-beacon.json": beacon,
    "manifest-expired.json": manifest("9.8.7", "2020-01-01T00:00:00Z"),
    "manifest-older.json": manifest("9.8.6", "2099-01-01T00:00:00Z"),
}.items():
    with open(os.path.join(out, name), "w") as f:
        json.dump(m, f, indent=2)
        f.write("\n")
with open(os.path.join(out, "binary.txt"), "w") as f:
    f.write("rex-duo-helper|9.8.7|linux-x86_64|" + hashlib.sha256(files["linux-x86_64"][1]).hexdigest())
PY
mv "$out/binary.txt" "$work/binary.txt"

for name in manifest manifest-beacon manifest-expired manifest-older; do
  sign_with test "$out/$name.json" "$out/$name.json.sig"
done
sign_with test "$work/binary.txt" "$out/rex-duo-helper-linux-x86_64.sig"
sign_with stranger "$out/manifest.json" "$out/manifest-untrusted.json.sig"

echo "Wrote $(cd "$out" && pwd):"
ls -1 "$out"
