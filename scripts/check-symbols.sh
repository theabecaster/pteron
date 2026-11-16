#!/bin/zsh
# Fails when a binary imports a system symbol that is not public API. App Store review rejects
# such binaries (ITMS-90338, "non-public API usage").
#   scripts/check-symbols.sh                 check Vendor/GhosttyVt.xcframework
#   scripts/check-symbols.sh <path>...       an .xcframework, a static library (.a), an .app,
#                                            an .xcarchive or a linked Mach-O file
# Used by build-ghostty.sh (the framework it built) and ship-macdesk.sh (the framework before
# archiving, the archived app before export).
#
# What is checked, per architecture:
# - A linked binary: every symbol it imports from libSystem (`dyld_info -imports`).
#   A static library: every symbol it leaves undefined, which the app must import for it.
# - No symbol may match DENY.
# - Every C symbol must be declared in a header of the platform SDK (usr/include), or be in
#   ALLOW. A static library's symbols must also be exported by the SDK's libSystem or libc++.
# Imports from other libraries (Swift, UIKit and the rest) come from Swift and Objective-C
# code that compiles against the SDK's own interfaces, so they are not looked at.
set -euo pipefail

ROOT=${0:A:h:h}

# Private symbols we know of, named so the message says why. The header rule below catches
# these too; this list keeps the check alive if a header ever mentions one.
DENY=(
  '___ulock_*'   # private futex syscalls; the public API is os_sync_wait_on_address (iOS 17.4)
)

# In no SDK header, and still fine: the compiler or Apple's own runtime emits them.
ALLOW=(
  # Apple's libclang_rt (linked into every app) imports it for `@available` and `#available`.
  __availability_version_check
  # Emitted by clang and swiftc: stack probe and guard, sin+cos pairs, unwinding, lazy binding,
  # thread-local variables.
  ___chkstk_darwin ___stack_chk_fail ___stack_chk_guard
  ___sincos_stret ___sincosf_stret ___sincospi_stret ___sincospif_stret
  __Unwind_Resume dyld_stub_binder __tlv_bootstrap
  # The C++ runtime's exception personality (simdutf and highway are C++).
  ___gxx_personality_v0
  # x86_64 macOS only: what clang turns a zeroing memset into.
  ___bzero
  # Weak import of Apple's libswiftCompatibility56.a, which swiftc links by itself.
  _voucher_adopt
)

fail=0
note() { print -r -- "check-symbols.sh: $*" >&2 }

# check <label> <sdk name> <linked|archive> <file with one symbol per line>
check() {
  local label=$1 sdk=$2 kind=$3 list=$4
  local sdkpath; sdkpath=$(xcrun --sdk $sdk --show-sdk-path)
  [[ -d $sdkpath/usr/include ]] || { note "error: no $sdk SDK at $sdkpath"; exit 1 }
  local -a bad
  local -A denied
  local s d
  for s in ${(f)"$(<$list)"}; do
    for d in $DENY; do
      [[ $s == ${~d} ]] && { denied[$s]=1; bad+=("$s (denied: private API)") }
    done
  done

  # C symbols as the headers spell them: without the leading underscore and without a
  # `$VARIANT` suffix (close$NOCANCEL and realpath$DARWIN_EXTSN are what <unistd.h> and
  # <stdlib.h> produce through __DARWIN_ALIAS_C and __DARWIN_EXTSN). Mangled C++ and
  # Objective-C class symbols have no C declaration.
  local -A spelled
  for s in ${(f)"$(<$list)"}; do
    [[ $s == __Z* || $s == _OBJC_* || $s == '<'* ]] && continue
    (( ${ALLOW[(Ie)$s]} || ${+denied[$s]} )) && continue
    spelled[$s]=${${s#_}%%\$*}
  done
  if (( $#spelled )); then
    local tmp; tmp=$(mktemp -d)
    print -rl -- ${(u)spelled} > $tmp/names
    # One pass over the SDK's headers for all names at once.
    LC_ALL=C grep -rhowF -f $tmp/names $sdkpath/usr/include 2>/dev/null | LC_ALL=C sort -u > $tmp/declared || true
    local -A declared
    for d in ${(f)"$(<$tmp/declared)"}; do declared[$d]=1; done
    for s in ${(k)spelled}; do
      (( ${+declared[$spelled[$s]]} )) || bad+=("$s (in no $sdk SDK header)")
    done
    rm -rf $tmp
  fi

  if [[ $kind == archive ]]; then
    local tmp2; tmp2=$(mktemp -d)
    cat $sdkpath/usr/lib/libSystem.B.tbd $sdkpath/usr/lib/libc++.1.tbd $sdkpath/usr/lib/libc++abi.tbd 2>/dev/null \
      | LC_ALL=C grep -oE "[A-Za-z0-9_\$.]+" | LC_ALL=C sort -u > $tmp2/exports
    local -A exported
    for d in ${(f)"$(<$tmp2/exports)"}; do exported[$d]=1; done
    for s in ${(f)"$(<$list)"}; do
      (( ${+exported[$s]} )) || bad+=("$s (not exported by the $sdk SDK's libSystem or libc++)")
    done
    rm -rf $tmp2
  fi

  if (( $#bad )); then
    fail=1
    note "error: $label references non-public symbols:"
    print -rl -- ${(ou)bad} | sed 's/^/  /' >&2
  else
    print -r -- "ok: $label ($(wc -l < $list | tr -d ' ') system symbols, all public)"
  fi
}

# The SDK a Mach-O was built for, from its LC_BUILD_VERSION platform.
sdk_of() {
  local p; p=$(xcrun vtool -arch $2 -show-build $1 2>/dev/null | awk '$1 == "platform" { print $2; exit }')
  case $p in
    IOS) print iphoneos ;;
    IOSSIMULATOR) print iphonesimulator ;;
    MACOS) print macosx ;;
    *) note "error: $1 ($2): unknown platform '$p'"; exit 1 ;;
  esac
}

check_archive() {
  local lib=$1 sdk=$2 arch tmp
  for arch in $(xcrun lipo -archs $lib); do
    tmp=$(mktemp -d)
    # Undefined in some member and defined by no member: what the final link takes from the system.
    xcrun nm -arch $arch -u -j $lib 2>/dev/null | grep -v -e ':$' -e '^$' | LC_ALL=C sort -u > $tmp/undef || true
    xcrun nm -arch $arch -g -U -j $lib 2>/dev/null | grep -v -e ':$' -e '^$' | LC_ALL=C sort -u > $tmp/def || true
    LC_ALL=C comm -23 $tmp/undef $tmp/def > $tmp/need
    [[ -s $tmp/undef ]] || { note "error: could not read symbols of $lib ($arch)"; exit 1 }
    check "${lib#$ROOT/} ($arch)" $sdk archive $tmp/need
    rm -rf $tmp
  done
}

check_linked() {
  local bin=$1 arch tmp
  for arch in $(xcrun lipo -archs $bin); do
    tmp=$(mktemp -d)
    xcrun dyld_info -arch $arch -imports $bin > $tmp/imports
    awk '/\(from libSystem\)/ { print $2 }' $tmp/imports | LC_ALL=C sort -u > $tmp/need
    [[ -s $tmp/need ]] || { note "error: could not read imports of $bin ($arch)"; exit 1 }
    check "${bin#$ROOT/} ($arch)" $(sdk_of $bin $arch) linked $tmp/need
    rm -rf $tmp
  done
}

check_path() {
  local p=${1:A} lib bin
  case $p in
    *.xcframework)
      local -a libs; libs=($p/*/*.a(N))
      (( $#libs )) || { note "error: no static libraries in $p"; exit 1 }
      for lib in $libs; do
        case ${lib:h:t} in
          ios-*-simulator) check_archive $lib iphonesimulator ;;
          ios-*) check_archive $lib iphoneos ;;
          macos-*) check_archive $lib macosx ;;
          *) note "error: unknown slice ${lib:h:t} in $p"; exit 1 ;;
        esac
      done ;;
    *.a)
      local arch; arch=$(xcrun lipo -archs $p | awk '{ print $1 }')
      local tmp; tmp=$(mktemp -d)
      # The platform is recorded in the members, not in the archive.
      (cd $tmp && xcrun lipo -thin $arch $p -output thin.a 2>/dev/null || cp $p thin.a; xcrun ar -x thin.a && chmod 644 *.o)
      local member; member=($tmp/*.o(N[1]))
      local sdk; sdk=$(sdk_of $member $arch)
      rm -rf $tmp
      check_archive $p $sdk ;;
    *.xcarchive)
      for bin in $p/Products/Applications/*.app(N); do check_path $bin; done ;;
    *.app)
      bin=$p/${p:t:r}
      [[ -f $bin ]] || { note "error: no executable at $bin"; exit 1 }
      check_linked $bin
      # Embedded frameworks and dylibs, should the app ever get some.
      for bin in $p/Frameworks/*.framework/*(N.x) $p/Frameworks/*.dylib(N); do check_linked $bin; done ;;
    *)
      [[ -f $p ]] || { note "error: $1 not found"; exit 1 }
      check_linked $p ;;
  esac
}

(( $# )) || set -- $ROOT/Vendor/GhosttyVt.xcframework
for arg in "$@"; do check_path $arg; done
exit $fail
