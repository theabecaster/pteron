#!/bin/zsh
# Build a Release copy of the current tree on macdesk and install it on the iPhone Duo paired there.
# Usage: scripts/install-duo.sh [build-number]
set -euo pipefail
DEVICE=00008160-000602EC0EF00036
BUILD=${1:-$(date +%y%m%d%H%M)}
cd "$(dirname "$0")/.."
# Checks Vendor/GhosttyVt.xcframework, generates the project and copies both with the sources.
scripts/sync-macdesk.sh
ssh macdesk "sudo launchctl asuser \$(id -u) sudo -u \$USER zsh -lc 'cd ~/rexduo-build && xcodebuild -project RexDuo.xcodeproj -scheme RexDuo -configuration Release -destination id=$DEVICE -derivedDataPath build/dd -allowProvisioningUpdates -allowProvisioningDeviceRegistration CURRENT_PROJECT_VERSION=$BUILD build > build.log 2>&1' || { grep -E 'error:' ~/rexduo-build/build.log | head -20; exit 1; }
/usr/bin/xcrun devicectl device install app --device $DEVICE ~/rexduo-build/build/dd/Build/Products/Release-iphoneos/RexDuo.app | grep -E 'App installed'"
echo "installed build $BUILD"
