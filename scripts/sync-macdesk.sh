#!/bin/zsh
# Copies the current tree to macdesk, ready for a device build or an archive there.
# Usage: scripts/sync-macdesk.sh [-n] [remote-dir]
#   -n          dry run: list what would be copied or deleted, change nothing on macdesk
#   remote-dir  relative to macdesk's home, default rexconnect-build
# From Vendor/ only GhosttyVt.xcframework and its stamp go across. The framework is built here by
# scripts/build-ghostty.sh; macdesk never builds it, so the Zig toolchain, the Ghostty checkout and
# the Zig cache stay behind. rsync skips files whose size and time are unchanged, so the 51 MB
# framework is only sent again after a rebuild.
set -euo pipefail
cd ${0:A:h:h}

DRY=()
if [[ "${1:-}" == -n ]]; then DRY=(-n -v); shift; fi
DIR=${1:-rexconnect-build}

# Fail here, with the fix, rather than in the linker on macdesk.
scripts/check-ghostty.sh
# The project is generated, not tracked: generate it here and copy it along with the sources.
xcodegen generate -q

# Vendor is a symlink in agent worktrees, and earlier versions of this copy sent the link itself.
(( $#DRY )) || ssh macdesk "mkdir -p $DIR && { [ ! -L $DIR/Vendor ] || rm $DIR/Vendor; } && mkdir -p $DIR/Vendor"
# Relay/dist holds a helper build with the APNs key inside.
rsync -a --delete $DRY --exclude .claude --exclude build --exclude .build --exclude .git --exclude .asc.env \
  --exclude /Vendor --exclude /Relay/dist ./ macdesk:$DIR/
# Paths through Vendor/ resolve the symlink; --delete only prunes inside the framework.
rsync -a --delete $DRY Vendor/GhosttyVt.xcframework Vendor/GhosttyVt.stamp macdesk:$DIR/Vendor/
