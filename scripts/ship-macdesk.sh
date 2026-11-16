#!/bin/zsh -l
# Archive Rex Duo and upload to App Store Connect. Runs inside the GUI session (keychain unlocked).
cd ~/rexduo-build || exit 1
BUILD=${1:-1}
LOG=build/ship.log
mkdir -p build
exec > $LOG 2>&1
echo "== start $(date) build $BUILD"
rm -rf build/RexDuo.xcarchive build/export
xcodebuild -project RexDuo.xcodeproj -scheme RexDuo -configuration Release \
  -destination "generic/platform=iOS" -derivedDataPath build/dd -clonedSourcePackagesDirPath build/spm \
  -skipPackagePluginValidation -skipMacroValidation -allowProvisioningUpdates \
  CURRENT_PROJECT_VERSION=$BUILD -archivePath build/RexDuo.xcarchive archive | grep -E "error:|ARCHIVE|warning: .*sign" 
[ -d build/RexDuo.xcarchive ] || { echo "== ARCHIVE_FAILED"; exit 1; }
cat > build/ExportOptions.plist <<P
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string><key>destination</key><string>${DEST:-upload}</string>
<key>teamID</key><string>R2PVQ496X7</string><key>signingStyle</key><string>automatic</string>
<key>uploadSymbols</key><true/><key>manageAppVersionAndBuildNumber</key><false/>
<key>testFlightInternalTestingOnly</key><false/></dict></plist>
P
PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH xcodebuild -exportArchive -archivePath build/RexDuo.xcarchive -exportOptionsPlist build/ExportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates 2>&1 | tail -25
echo "== done $(date) rc=$?"
