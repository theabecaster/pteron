#!/bin/zsh
# Build a Release copy of the current tree and install it on the iPhone Duo.
# The Duo is paired with this Mac, so it builds and installs here by default.
# Usage: scripts/install-duo.sh [build-number]
#   VIA=macdesk scripts/install-duo.sh   builds and installs on that ssh host instead (Duo paired there).
#   PTERON_DEVICE=<udid>                 the phone (default: the developer's Duo).
set -euo pipefail
DEVICE=${PTERON_DEVICE:-${REXDUO_DEVICE:-00008160-000602EC0EF00036}}
BUILD=${1:-$(date +%y%m%d%H%M)}
cd "$(dirname "$0")/.."

if [[ "${VIA:-local}" != local ]]; then
  # Checks Vendor/GhosttyVt.xcframework, generates the project and copies both with the sources.
  PTERON_BUILD_HOST=$VIA scripts/sync-macdesk.sh
  ssh $VIA "sudo launchctl asuser \$(id -u) sudo -u \$USER zsh -lc 'cd ~/rexduo-build && xcodebuild -project Pteron.xcodeproj -scheme Pteron -configuration Release -destination id=$DEVICE -derivedDataPath build/dd -allowProvisioningUpdates -allowProvisioningDeviceRegistration CURRENT_PROJECT_VERSION=$BUILD build > build.log 2>&1' || { grep -E 'error:' ~/rexduo-build/build.log | head -20; exit 1; }
  /usr/bin/xcrun devicectl device install app --device $DEVICE ~/rexduo-build/build/dd/Build/Products/Release-iphoneos/Pteron.app | grep -E 'App installed'"
  echo "installed build $BUILD (via $VIA)"
  exit 0
fi

scripts/check-ghostty.sh
xcodegen generate --quiet
mkdir -p build
if ! xcodebuild -project Pteron.xcodeproj -scheme Pteron -configuration Release -destination id=$DEVICE \
    -derivedDataPath build/device -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
    CURRENT_PROJECT_VERSION=$BUILD build > build/install-duo.log 2>&1; then
  grep -E 'error:' build/install-duo.log | head -20
  exit 1
fi
xcrun devicectl device install app --device $DEVICE build/device/Build/Products/Release-iphoneos/Pteron.app | grep -E 'App installed'
echo "installed build $BUILD"
