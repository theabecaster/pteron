#!/bin/zsh
# Checks that Vendor/GhosttyVt.xcframework exists and was built from the pins in
# scripts/ghostty.version and the patches in scripts/ghostty-patches. build-ghostty.sh records
# what it built in Vendor/GhosttyVt.stamp; this compares the two and prints one line.
#   scripts/check-ghostty.sh             exit 1 with an "error:" line if missing or stale
#   scripts/check-ghostty.sh --expected  print the stamp the current pins should produce
# Used by build-ghostty.sh, sync-macdesk.sh, ship-macdesk.sh and the app target's pre-build phase.
set -eu

ROOT=${0:A:h:h}
source $ROOT/scripts/ghostty.version
PATCHES=($ROOT/scripts/ghostty-patches/*.patch(N))
if (( $#PATCHES )); then
  # Xcode's script sandbox denies files that are not inputs of the build phase. Without this
  # check the hash would silently be that of no bytes.
  for p in $PATCHES; do
    if ! { : < $p } 2>/dev/null; then
      echo "error: cannot read scripts/ghostty-patches/${p:t}. List it under the app target's preBuildScripts inputFiles in project.yml, then run xcodegen generate." >&2
      exit 1
    fi
  done
  PATCH_SUM=$(cat $PATCHES | shasum -a 256 | cut -c1-16)
else
  PATCH_SUM=none
fi
EXPECTED="GHOSTTY_COMMIT=$GHOSTTY_COMMIT
ZIG_VERSION=$ZIG_VERSION
PATCHES=$PATCH_SUM"
if [[ "${1:-}" == --expected ]]; then echo $EXPECTED; exit 0; fi

FIX="Run scripts/build-ghostty.sh on an Apple silicon Mac (about 2 minutes the first time)"
if [[ ! -f $ROOT/Vendor/GhosttyVt.xcframework/Info.plist ]]; then
  echo "error: Vendor/GhosttyVt.xcframework is missing. $FIX." >&2
  exit 1
fi
if [[ ! -f $ROOT/Vendor/GhosttyVt.stamp ]]; then
  echo "error: Vendor/GhosttyVt.stamp is missing, so the framework's Ghostty commit is unknown. $FIX." >&2
  exit 1
fi
BUILT=$(<$ROOT/Vendor/GhosttyVt.stamp)
if [[ "$BUILT" != "$EXPECTED" ]]; then
  echo "error: Vendor/GhosttyVt.xcframework was built from (${BUILT//$'\n'/, }) but scripts/ghostty.version wants (${EXPECTED//$'\n'/, }). $FIX." >&2
  exit 1
fi
echo "GhosttyVt.xcframework matches the pins (Ghostty ${GHOSTTY_COMMIT[1,12]}, Zig $ZIG_VERSION)"
