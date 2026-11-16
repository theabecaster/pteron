#!/bin/zsh -l
# Archive Rex Connect and upload it to App Store Connect. Runs on macdesk inside the GUI session
# (keychain unlocked), from a copy of the repo that already has the generated project:
# see docs/release.md. Usage: scripts/ship-macdesk.sh <build-number>
# DEST=export writes build/export/RexConnect.ipa and uploads nothing.
# Exits non-zero when any step fails. The log (build/ship.log) ends with "== done ... rc=0" only
# after a successful export or upload, and with "== <STEP>_FAILED" otherwise.
cd "${0:A:h}/.." || exit 1
# The build number has no default: one that App Store Connect already has would cost a whole
# archive and upload before it is refused.
if [[ $# -ne 1 || ! "$1" =~ '^[0-9]+(\.[0-9]+){0,2}$' ]]; then
  echo "usage: scripts/ship-macdesk.sh <build-number>   (such as 42 or 1.2.3; higher than the last upload)" >&2
  exit 2
fi
BUILD=$1
# xcodebuild, or a stand-in when the script itself is being tested.
XCODEBUILD=${XCODEBUILD:-xcodebuild}
# The copy must hold the libghostty-vt framework for this tree's pins (scripts/sync-macdesk.sh
# sends it). Checked before the log redirect so the reason reaches the caller.
scripts/check-ghostty.sh || { echo "ship-macdesk.sh: run scripts/sync-macdesk.sh from a checkout with a current framework, then retry" >&2; exit 1; }
# App Store review rejects binaries that import private system symbols (ITMS-90338). Checked
# here on the framework, so a bad one costs no archive, and below on the archived app.
scripts/check-symbols.sh Vendor/GhosttyVt.xcframework || { echo "ship-macdesk.sh: the framework references non-public symbols; nothing was archived" >&2; exit 1; }
LOG=build/ship.log
mkdir -p build
exec > $LOG 2>&1
echo "== start $(date) build $BUILD"
rm -rf build/RexConnect.xcarchive build/export
# Each xcodebuild's own status is taken from the pipe: the filter after it always succeeds.
$XCODEBUILD -project RexConnect.xcodeproj -scheme RexConnect -configuration Release \
  -destination "generic/platform=iOS" -derivedDataPath build/dd -clonedSourcePackagesDirPath build/spm \
  -skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION=$BUILD -archivePath build/RexConnect.xcarchive archive | grep -E "error:|ARCHIVE|warning: .*sign"
rc=$pipestatus[1]
if (( rc != 0 )) || [[ ! -d build/RexConnect.xcarchive ]]; then echo "== ARCHIVE_FAILED $(date) rc=$rc"; exit 1; fi
# The binary Apple will scan. Nothing is exported or uploaded if it imports a private symbol.
scripts/check-symbols.sh build/RexConnect.xcarchive || { echo "== SYMBOLS_FAILED"; exit 1; }
cat > build/ExportOptions.plist <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string><key>destination</key><string>${DEST:-upload}</string>
<key>teamID</key><string>R2PVQ496X7</string><key>signingStyle</key><string>automatic</string>
<key>uploadSymbols</key><true/><key>manageAppVersionAndBuildNumber</key><false/>
<key>testFlightInternalTestingOnly</key><false/></dict></plist>
P
PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH $XCODEBUILD -exportArchive -archivePath build/RexConnect.xcarchive -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates 2>&1 | tail -25
rc=$pipestatus[1]
if (( rc != 0 )); then echo "== EXPORT_FAILED $(date) rc=$rc"; exit 1; fi
if [[ "${DEST:-upload}" == export && ! -f build/export/RexConnect.ipa ]]; then echo "== EXPORT_FAILED $(date) no build/export/RexConnect.ipa"; exit 1; fi
echo "== done $(date) rc=0"
