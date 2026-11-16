#!/bin/zsh
# Builds Vendor/GhosttyVt.xcframework (libghostty-vt: macOS, iOS and iOS Simulator slices).
# Everything stays under Vendor/ (gitignored): Zig, its caches and the Ghostty checkout.
# Nothing is installed system-wide. Pins live in scripts/ghostty.version.
#   scripts/build-ghostty.sh           build if the pins changed
#   scripts/build-ghostty.sh --force   rebuild
set -euo pipefail

ROOT=${0:A:h:h}
VENDOR=$ROOT/Vendor
source $ROOT/scripts/ghostty.version

OUT=$VENDOR/GhosttyVt.xcframework
STAMP=$VENDOR/.ghostty-built
WANT="$(cat $ROOT/scripts/ghostty.version $ROOT/scripts/ghostty-patches/*.patch(N) | shasum -a 256 | cut -c1-16)"
if [[ -d $OUT && -f $STAMP && "$(cat $STAMP)" == "$WANT" && "${1:-}" != "--force" ]]; then
  echo "GhosttyVt.xcframework is up to date ($GHOSTTY_COMMIT)"
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

rm -rf $OUT
cp -R $SRC/zig-out/lib/ghostty-vt.xcframework $OUT
echo "$WANT" > $STAMP
du -sh $OUT
