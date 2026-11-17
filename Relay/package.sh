#!/bin/bash
# Builds Rex DUO Helper for macOS and Linux into Relay/dist:
#
#   Rex DUO Helper.zip                 the Mac app: the Rust binary in a signed, notarized bundle,
#                                      with rex-duo-notify (Packaging/notify.swift) beside it
#   rex-duo-helper-linux-x86_64        static Linux binaries (musl)
#   rex-duo-helper-linux-aarch64
#
#   Relay/package.sh                   everything: sign, notarize, staple, verify
#   Relay/package.sh --no-notarize     sign only, for a quick local test
#   Relay/package.sh --mac-only | --linux-only
#
# Needs Rust (rustup targets aarch64/x86_64-apple-darwin and -unknown-linux-musl), Xcode,
# cargo-zigbuild and zig (ZIG, or zig on PATH) for Linux, the Developer ID Application
# identity, and an App Store Connect API key for notarytool. Every path and id below can be
# overridden from the environment.
#
# The binaries hold no key: pushes go through the push gateway (src/gateway.rs). The only key
# material compiled in is the public update key, Relay/update-key.pub. Relay/.stage is deleted
# when the script exits.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Rex DUO Helper"
BIN=rex-duo-helper
NOTIFIER=rex-duo-notify
BUNDLE_ID="dev.abrahamgonzalez.rexduo.helper"
VERSION="$(sed -n 's/^version = "\(.*\)"/\1/p' "$HERE/Cargo.toml" | head -1)"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$HERE" rev-list --count HEAD 2>/dev/null || echo 1)}"
IDENTITY="${IDENTITY:-Developer ID Application: Abraham Gonzalez (R2PVQ496X7)}"

# notarytool auth. ASC_ISS (the issuer id) comes from the environment or $ASC_ENV.
ASC_KEY_ID="${ASC_KEY_ID:-2M674J7J7N}"
ASC_KEY="${ASC_KEY:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
ASC_ENV="${ASC_ENV:-$HOME/rexduo/.asc.env}"

ICON_SRC="$HERE/../RexDuo/Resources/Assets.xcassets/AppIcon.appiconset/icon.png"
STAGE="$HERE/.stage"
DIST="$HERE/dist"
APP="$STAGE/$APP_NAME.app"
ZIP="$DIST/$APP_NAME.zip"

NOTARIZE=1 MAC=1 LINUX=1
for a in "$@"; do
  case "$a" in
    --no-notarize) NOTARIZE=0 ;;
    --mac-only) LINUX=0 ;;
    --linux-only) MAC=0 ;;
    *) echo "unknown option $a" >&2; exit 2 ;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
# rustup's proxies, if cargo isn't already on PATH.
command -v cargo >/dev/null || export PATH="/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH"
if [[ $MAC == 1 && $NOTARIZE == 1 ]]; then
  [[ -f "$ASC_KEY" ]] || die "App Store Connect API key not found: $ASC_KEY"
  if [[ -z "${ASC_ISS:-}" && -f "$ASC_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$ASC_ENV"
  fi
  [[ -n "${ASC_ISS:-}" ]] || die "ASC_ISS is not set (looked in $ASC_ENV)"
fi

# Panic messages carry source paths, and every one starts in this Mac's home folder (the
# registry, the toolchain, this checkout), which names its user. The binaries say ~ instead.
REMAP="--remap-path-prefix=$HOME=~"

trap 'rm -rf "$STAGE"' EXIT
rm -rf "$STAGE"
mkdir -p "$STAGE" "$DIST"
cd "$HERE"

if [[ $LINUX == 1 ]]; then
  echo "==> Building Linux x86_64 and aarch64 (static, musl)"
  [[ -n "${ZIG:-}" ]] && export PATH="$(dirname "$ZIG"):$PATH"
  command -v zig >/dev/null || die "zig not found: set ZIG=/path/to/zig"
  CARGO_TARGET_X86_64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="$REMAP" CARGO_TARGET_AARCH64_UNKNOWN_LINUX_MUSL_RUSTFLAGS="$REMAP" \
    cargo zigbuild --release --locked --target x86_64-unknown-linux-musl --target aarch64-unknown-linux-musl
  for arch in x86_64 aarch64; do
    install -m 0755 "target/$arch-unknown-linux-musl/release/$BIN" "$DIST/$BIN-linux-$arch"
  done
fi

if [[ $MAC == 1 ]]; then
  echo "==> Building $APP_NAME $VERSION ($BUILD_NUMBER), universal"
  # The minimum macOS goes to the two target links only. Set for the whole build
  # (MACOSX_DEPLOYMENT_TARGET), it also reaches the proc-macro crates cargo builds for this Mac,
  # and rustc then fails to find them ("can't find crate for tokio_macros").
  MIN_MACOS="-C link-arg=-mmacosx-version-min=14.0"
  CARGO_TARGET_AARCH64_APPLE_DARWIN_RUSTFLAGS="$MIN_MACOS $REMAP" CARGO_TARGET_X86_64_APPLE_DARWIN_RUSTFLAGS="$MIN_MACOS $REMAP" \
    cargo build --release --locked --target aarch64-apple-darwin --target x86_64-apple-darwin
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  # The notices of the crates in the binary go with it.
  python3 "$HERE/third-party-licenses.py" "$APP/Contents/Resources/THIRD_PARTY_LICENSES.txt"
  lipo -create -output "$APP/Contents/MacOS/$BIN" \
    "target/aarch64-apple-darwin/release/$BIN" "target/x86_64-apple-darwin/release/$BIN"

  # The notifier: what posts a desktop notification under the app's own name (src/notice.rs).
  for arch in arm64 x86_64; do
    xcrun swiftc -O -swift-version 6 -parse-as-library -target "$arch-apple-macos14.0" \
      -o "$STAGE/$NOTIFIER-$arch" "$HERE/Packaging/notify.swift"
  done
  lipo -create -output "$APP/Contents/MacOS/$NOTIFIER" "$STAGE/$NOTIFIER-arm64" "$STAGE/$NOTIFIER-x86_64"

  # The binary is the app: opened from Finder it starts itself as a LaunchAgent and shows
  # one dialog (src/service.rs, open_app). No Dock icon.
  cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$BIN</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHumanReadableCopyright</key><string>Sends Rex DUO notifications from Rex on this Mac.</string>
</dict>
</plist>
EOF
  plutil -lint "$APP/Contents/Info.plist" >/dev/null
  printf 'APPL????' > "$APP/Contents/PkgInfo"
  swift "$HERE/Packaging/make-iconset.swift" "$ICON_SRC" "$STAGE/AppIcon.iconset"
  iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$STAGE/AppIcon.iconset"

  echo "==> Signing with $IDENTITY (hardened runtime, no entitlements)"
  # Code inside the bundle is signed before the bundle that seals it.
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP/Contents/MacOS/$NOTIFIER"
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$APP"
  codesign --verify --strict --verbose=2 "$APP"

  if [[ $NOTARIZE == 1 ]]; then
    echo "==> Notarizing"
    ditto -c -k --keepParent "$APP" "$STAGE/upload.zip"
    xcrun notarytool submit "$STAGE/upload.zip" \
      --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISS" \
      --wait --output-format json > "$STAGE/notary.json"
    STATUS="$(plutil -extract status raw -o - "$STAGE/notary.json")"
    SUBMISSION="$(plutil -extract id raw -o - "$STAGE/notary.json")"
    echo "    submission $SUBMISSION: $STATUS"
    if [[ "$STATUS" != "Accepted" ]]; then
      xcrun notarytool log "$SUBMISSION" --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISS" || true
      die "notarization failed"
    fi
    xcrun stapler staple "$APP"

    echo "==> Verifying"
    xcrun stapler validate "$APP"
    spctl -a -vv -t exec "$APP"
  fi

  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
fi

echo "==> $DIST"
ls -l "$DIST"
