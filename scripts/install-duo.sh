#!/bin/zsh
# Build a Release copy of the current tree on macdesk and install it on the iPhone Duo paired there.
# Usage: scripts/install-duo.sh [build-number]
set -euo pipefail
DEVICE=00008160-000602EC0EF00036
BUILD=${1:-$(date +%y%m%d%H%M)}
cd "$(dirname "$0")/.."
# Checks Vendor/GhosttyVt.xcframework, generates the project and copies both with the sources.
scripts/sync-macdesk.sh
ssh macdesk "sudo launchctl asuser \$(id -u) sudo -u \$USER zsh -lc 'cd ~/rexconnect-build && xcodebuild -project RexConnect.xcodeproj -scheme RexConnect -configuration Release -destination id=$DEVICE -derivedDataPath build/dd -clonedSourcePackagesDirPath build/spm -allowProvisioningUpdates -allowProvisioningDeviceRegistration -skipPackagePluginValidation -skipMacroValidation CURRENT_PROJECT_VERSION=$BUILD build > build.log 2>&1' || { grep -E 'error:' ~/rexconnect-build/build.log | head -20; exit 1; }
/usr/bin/xcrun devicectl device install app --device $DEVICE ~/rexconnect-build/build/dd/Build/Products/Release-iphoneos/RexConnect.app | grep -E 'App installed'"
echo "installed build $BUILD"
