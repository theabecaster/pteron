#!/bin/zsh
# Copies the current tree to macdesk, ready for a device build or an archive there.
# Usage: scripts/sync-macdesk.sh [-n] [remote-dir]
#   PTERON_BUILD_HOST  the ssh host to copy to (default macdesk, the developer's build Mac)
#   -n          dry run: list what would be copied or deleted, change nothing on macdesk
#   remote-dir  a folder directly under macdesk's home whose name starts with
#               rexduo-build; default rexduo-build
# From Vendor/ only GhosttyVt.xcframework and its stamp go across. The framework is built here by
# scripts/build-ghostty.sh; macdesk never builds it, so the Zig toolchain, the Ghostty checkout and
# the Zig cache stay behind. rsync skips files whose size and time are unchanged, so the 51 MB
# framework is only sent again after a rebuild.
set -euo pipefail
cd ${0:A:h:h}
HOST=${PTERON_BUILD_HOST:-${REXDUO_BUILD_HOST:-macdesk}}

DRY=()
if [[ "${1:-}" == -n ]]; then DRY=(-n -v); shift; fi
if (( $# > 1 )); then
  echo "usage: scripts/sync-macdesk.sh [-n] [remote-dir]" >&2
  exit 2
fi
DIR=${1-rexduo-build}
# `rsync --delete` empties whatever folder it is pointed at of everything this tree doesn't have.
# So the target is never taken on trust: one path component, no `.`, `..`, `~`, `/` or empty
# name, nothing the remote shell would expand, and only a name that marks the folder as ours.
if [[ ! $DIR =~ '^rexduo-build[A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)*$' ]]; then
  echo "sync-macdesk.sh: refusing to sync into '$DIR'. The remote folder must be directly under macdesk's home and its name must start with rexduo-build (letters, digits, '-', '_' and '.' after that)." >&2
  exit 2
fi

# Fail here, with the fix, rather than in the linker on macdesk.
scripts/check-ghostty.sh
# The project is generated, not tracked: generate it here and copy it along with the sources.
xcodegen generate -q

# Never copied: keys and the places that hold them. macdesk is a build box other machines log in
# to; a key there is a key in one more place.
#   .asc.env, .env*      App Store Connect and other credentials
#   /Relay/dist, /Relay/.stage, /Relay/target
#                        helper builds. Today's hold no key, but builds made before the push
#                        gateway embedded the APNs key and may still lie there.
#   *.p8 *.p12 *.pem *.key *.cer *.mobileprovision *.provisionprofile
#                        keys, certificates and profiles, wherever they are dropped
# Excluded paths are also left alone on macdesk (`--delete` doesn't touch them), so the staging
# folder is removed there by name, in case an earlier copy took it.
SECRETS=(--exclude .asc.env --exclude '.env' --exclude '.env.*' --exclude '*.env'
         --exclude /Relay/dist --exclude /Relay/.stage --exclude /Relay/target
         --exclude '*.p8' --exclude '*.p12' --exclude '*.pem' --exclude '*.key' --exclude '*.cer'
         --exclude '*.mobileprovision' --exclude '*.provisionprofile')

# Vendor is a symlink in agent worktrees, and earlier versions of this copy sent the link itself.
(( $#DRY )) || ssh $HOST "mkdir -p $DIR && { [ ! -L $DIR/Vendor ] || rm $DIR/Vendor; } && mkdir -p $DIR/Vendor && rm -rf $DIR/Relay/.stage"
rsync -a --delete $DRY --exclude .claude --exclude build --exclude .build --exclude .git $SECRETS \
  --exclude /Vendor ./ $HOST:$DIR/
# Paths through Vendor/ resolve the symlink; --delete only prunes inside the framework.
rsync -a --delete $DRY Vendor/GhosttyVt.xcframework Vendor/GhosttyVt.stamp $HOST:$DIR/Vendor/
