#!/bin/zsh -l
# Archive Rex Connect and upload it to App Store Connect. Runs on macdesk inside the GUI session
# (keychain unlocked), from a copy of the repo that already has the generated project:
# see docs/release.md. Usage: scripts/ship-macdesk.sh <build-number>
# DEST=export writes build/export/RexConnect.ipa and uploads nothing.
cd "${0:A:h}/.." || exit 1
# The copy must hold the libghostty-vt framework for this tree's pins (scripts/sync-macdesk.sh
# sends it). Checked before the log redirect so the reason reaches the caller.
scripts/check-ghostty.sh || { echo "ship-macdesk.sh: run scripts/sync-macdesk.sh from a checkout with a current framework, then retry" >&2; exit 1; }
BUILD=${1:-1}
LOG=build/ship.log
mkdir -p build
exec > $LOG 2>&1
echo "== start $(date) build $BUILD"
rm -rf build/RexConnect.xcarchive build/export
xcodebuild -project RexConnect.xcodeproj -scheme RexConnect -configuration Release \
  -destination "generic/platform=iOS" -derivedDataPath build/dd -clonedSourcePackagesDirPath build/spm \
  -skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION=$BUILD -archivePath build/RexConnect.xcarchive archive | grep -E "error:|ARCHIVE|warning: .*sign" 
[ -d build/RexConnect.xcarchive ] || { echo "== ARCHIVE_FAILED"; exit 1; }
cat > build/ExportOptions.plist <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string><key>destination</key><string>${DEST:-upload}</string>
<key>teamID</key><string>R2PVQ496X7</string><key>signingStyle</key><string>automatic</string>
<key>uploadSymbols</key><true/><key>manageAppVersionAndBuildNumber</key><false/>
<key>testFlightInternalTestingOnly</key><false/></dict></plist>
P
PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH xcodebuild -exportArchive -archivePath build/RexConnect.xcarchive -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates 2>&1 | tail -25
echo "== done $(date) rc=$?"
