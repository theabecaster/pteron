#!/bin/bash
# Builds "Rex Connect Helper.app", signs it with Developer ID (hardened runtime), notarizes and
# staples it, and zips it to Relay/dist/Rex Connect Helper.zip.
#
#   Relay/package.sh                 full build: sign, notarize, staple, verify, zip
#   Relay/package.sh --no-notarize   sign only, for a quick local test
#
# Needs Xcode, the Developer ID Application identity in the keychain, the APNs key that gets
# embedded in the app, and an App Store Connect API key for notarytool. Every path and id
# below can be overridden from the environment.
#
# The APNs key is copied into a staging bundle under Relay/.stage only. That folder and
# Relay/dist are gitignored, and the staging folder is deleted when the script exits.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="Rex Connect Helper"
BUNDLE_ID="dev.abrahamgonzalez.rexconnect.helper"
VERSION="$(sed -n 's/.*static let version = "\(.*\)"/\1/p' "$HERE/Sources/RelayCore/Relay.swift")"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$HERE" rev-list --count HEAD 2>/dev/null || echo 1)}"
IDENTITY="${IDENTITY:-Developer ID Application: Abraham Gonzalez (R2PVQ496X7)}"

# APNs key embedded in the app.
APNS_KEY_ID="${APNS_KEY_ID:-5G2D4URHAC}"
APNS_TEAM_ID="${APNS_TEAM_ID:-R2PVQ496X7}"
APNS_TOPIC="${APNS_TOPIC:-dev.abrahamgonzalez.rexduo}"
APNS_KEY="${APNS_KEY:-$HOME/.appstoreconnect/private_keys/AuthKey_$APNS_KEY_ID.p8}"

# notarytool auth. ASC_ISS (the issuer id) comes from the environment or $ASC_ENV.
ASC_KEY_ID="${ASC_KEY_ID:-2M674J7J7N}"
ASC_KEY="${ASC_KEY:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
ASC_ENV="${ASC_ENV:-$HOME/rexduo/.asc.env}"

ICON_SRC="$HERE/../RexConnect/Resources/Assets.xcassets/AppIcon.appiconset/icon.png"
STAGE="$HERE/.stage"
DIST="$HERE/dist"
APP="$STAGE/$APP_NAME.app"
ZIP="$DIST/$APP_NAME.zip"

NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0

die() { echo "error: $*" >&2; exit 1; }
[[ -f "$APNS_KEY" ]] || die "APNs key not found: $APNS_KEY"
if [[ $NOTARIZE == 1 ]]; then
  [[ -f "$ASC_KEY" ]] || die "App Store Connect API key not found: $ASC_KEY"
  if [[ -z "${ASC_ISS:-}" && -f "$ASC_ENV" ]]; then
    # shellcheck disable=SC1090
    source "$ASC_ENV"
  fi
  [[ -n "${ASC_ISS:-}" ]] || die "ASC_ISS is not set (looked in $ASC_ENV)"
fi

trap 'rm -rf "$STAGE"' EXIT
rm -rf "$STAGE"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$DIST"

echo "==> Building $APP_NAME $VERSION ($BUILD_NUMBER), universal release"
BUILD_ARGS=(-c release --arch arm64 --arch x86_64 --product RexConnectHelper --package-path "$HERE")
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
cp "$BIN_DIR/RexConnectHelper" "$APP/Contents/MacOS/$APP_NAME"

echo "==> Assembling the bundle"
cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
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
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Sends Rex Connect notifications from Rex on this Mac.</string>
  <key>RexConnectAPNsKeyID</key><string>$APNS_KEY_ID</string>
  <key>RexConnectAPNsTeamID</key><string>$APNS_TEAM_ID</string>
  <key>RexConnectAPNsTopic</key><string>$APNS_TOPIC</string>
</dict>
</plist>
EOF
plutil -lint "$APP/Contents/Info.plist" >/dev/null
printf 'APPL????' > "$APP/Contents/PkgInfo"

swift "$HERE/Packaging/make-iconset.swift" "$ICON_SRC" "$STAGE/AppIcon.iconset"
iconutil -c icns -o "$APP/Contents/Resources/AppIcon.icns" "$STAGE/AppIcon.iconset"
install -m 0644 "$APNS_KEY" "$APP/Contents/Resources/AuthKey.p8"

echo "==> Signing with $IDENTITY (hardened runtime, no entitlements)"
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
echo "==> $ZIP"
