#!/bin/zsh
# Builds Vendor/GhosttyVt.xcframework (libghostty-vt: macOS, iOS and iOS Simulator slices).
# Everything stays under Vendor/ (gitignored): Zig, its caches and the Ghostty checkout.
# Nothing is installed system-wide. Pins live in scripts/ghostty.version.
# A cold run downloads Zig (51 MB) and Ghostty with its dependencies: about 130 s, 1.3 GB.
#   scripts/build-ghostty.sh           build if the pins or patches changed
#   scripts/build-ghostty.sh --force   rebuild
set -euo pipefail

# Anything but --force is refused, so a mistyped flag can't start a 130 s build.
case "${1:-}" in
  ""|--force) ;;
  -h|--help) echo "usage: scripts/build-ghostty.sh [--force]   (--force rebuilds even when up to date)"; exit 0 ;;
  *) echo "usage: scripts/build-ghostty.sh [--force]" >&2; exit 2 ;;
esac

ROOT=${0:A:h:h}
VENDOR=$ROOT/Vendor
source $ROOT/scripts/ghostty.version

OUT=$VENDOR/GhosttyVt.xcframework
# What the framework was built from: Ghostty commit, Zig version and a hash of our patches.
# scripts/check-ghostty.sh compares it with the pins before every build, sync and archive.
STAMP=$VENDOR/GhosttyVt.stamp
CHECK=$ROOT/scripts/check-ghostty.sh
# What this run builds from, read once: pins or patches edited while it runs are not stamped.
EXPECTED=$($CHECK --expected)
# Up to date only with a matching stamp, and the stamp is written last, after every check below.
if [[ "${1:-}" != "--force" && -f $OUT/Info.plist && -f $STAMP && "$(<$STAMP)" == "$EXPECTED" ]]; then
  exit 0
fi

mkdir -p $VENDOR
[[ "$(uname -m)" == arm64 ]] || { echo "build-ghostty.sh: needs an Apple silicon Mac" >&2; exit 1; }

# 1. Zig, unpacked locally and checked against the pinned hash.
ZIG_DIR=$VENDOR/zig-$ZIG_VERSION
if [[ ! -x $ZIG_DIR/zig ]]; then
  echo "Fetching Zig $ZIG_VERSION"
  TARBALL=$VENDOR/zig-$ZIG_VERSION.tar.xz
  curl -fL --retry 3 -o $TARBALL https://ziglang.org/download/$ZIG_VERSION/zig-aarch64-macos-$ZIG_VERSION.tar.xz
  echo "$ZIG_SHA256_AARCH64_MACOS  $TARBALL" | shasum -a 256 -c -
  rm -rf $ZIG_DIR $VENDOR/zig-aarch64-macos-$ZIG_VERSION
  tar -xJf $TARBALL -C $VENDOR
  mv $VENDOR/zig-aarch64-macos-$ZIG_VERSION $ZIG_DIR
  rm -f $TARBALL
fi
ZIG=$ZIG_DIR/zig

# 2. Ghostty at the pinned commit, plus our patches (scripts/ghostty-patches/*.patch).
SRC=$VENDOR/ghostty
if [[ ! -d $SRC/.git ]]; then
  git clone --filter=blob:none $GHOSTTY_REPO $SRC
fi
if ! git -C $SRC cat-file -e "$GHOSTTY_COMMIT^{commit}" 2>/dev/null; then
  git -C $SRC fetch --quiet origin
fi
git -C $SRC checkout --quiet --force $GHOSTTY_COMMIT
git -C $SRC clean -fdq -e zig-out -e .zig-cache
for p in $ROOT/scripts/ghostty-patches/*.patch(N); do
  echo "Applying ${p:t}"
  git -C $SRC apply $p
done

# 3. The libghostty-vt xcframework. Zig's caches stay in Vendor/ too.
export ZIG_GLOBAL_CACHE_DIR=$VENDOR/zig-global-cache
cd $SRC
START=$SECONDS
$ZIG build -Demit-lib-vt=true -Demit-xcframework=true -Doptimize=ReleaseFast
echo "zig build took $(( SECONDS - START ))s"

# 4. Check the framework where nothing uses it yet, then put it in place, the stamp last.
# The stamp says "this framework passed the checks and came from these pins". So a framework
# that fails stays in the staging folder and is deleted, the old stamp goes before the old
# framework does, and the new stamp is written only after the new framework is in place.
# Whatever stops the script, a framework without a stamp is all it can leave, and both
# check-ghostty.sh and the next run treat that as not built.
STAGE=$(mktemp -d $VENDOR/.GhosttyVt.stage.XXXXXX)
trap 'rm -rf $STAGE' EXIT
cp -R $SRC/zig-out/lib/ghostty-vt.xcframework $STAGE/GhosttyVt.xcframework
[[ -f $STAGE/GhosttyVt.xcframework/Info.plist ]] || { echo "build-ghostty.sh: zig build left no xcframework" >&2; exit 1; }
# A framework that references private system symbols (App Store review rejects those) is never
# installed: a re-pin that brings one back stops here.
$ROOT/scripts/check-symbols.sh $STAGE/GhosttyVt.xcframework
print -r -- $EXPECTED > $STAGE/GhosttyVt.stamp
# `.ghostty-built` is the marker of builds before the stamp existed. Nothing reads it any more.
rm -f $STAMP $VENDOR/.ghostty-built
rm -rf $OUT
mv $STAGE/GhosttyVt.xcframework $OUT
mv $STAGE/GhosttyVt.stamp $STAMP
du -sh $OUT
