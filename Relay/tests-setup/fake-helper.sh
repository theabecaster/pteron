#!/bin/sh
# A stand-in for rex-duo-helper, for Relay/test-install.sh. It starts nothing: `install` only
# writes the status.json a started helper would write, into the test's own home folder. Every
# call is logged to helper.log there, and to helper-runs.log with the version that was called.
# test-install.sh puts a version in place of @VERSION@; inside an app bundle the version is
# the bundle's.
set -eu
home="${REXDUO_TEST_HOME:?fake-helper.sh runs only inside Relay/test-install.sh}"
version="@VERSION@"
here="$(cd "$(dirname "$0")" && pwd)"
plist="$here/../Info.plist"
if [ -f "$plist" ]; then
  version="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - "$plist")"
  state="$home/Library/Application Support/Rex DUO Helper"
else
  state="$home/.local/state/rex-duo-helper"
fi
printf '%s\n' "$*" >>"$home/helper.log"
printf '%s %s\n' "$version" "${1:-}" >>"$home/helper-runs.log"

case "${1:-}" in
  version)
    if [ "${2:-}" = --json ]; then printf '{"version":"%s"}\n' "$version"; else printf '%s\n' "$version"; fi
    ;;
  install)
    # The setup code comes in a file, which the helper reads and deletes. What the file was is
    # written down for the test: its mode, then its contents.
    file=""
    shift
    while [ $# -gt 0 ]; do
      if [ "$1" = --setup-nonce-file ] && [ $# -ge 2 ]; then file="$2"; fi
      shift
    done
    if [ -n "$file" ]; then
      { /usr/bin/stat -f %Lp "$file"; /usr/bin/stat -f %Lp "$(dirname "$file")"; cat "$file"; } >"$home/code.seen"
      rm -f "$file"
    fi
    if [ -f "$home/slow-install" ]; then sleep "$(cat "$home/slow-install")"; fi
    if [ -f "$home/no-start" ]; then exit 1; fi
    mkdir -p "$state"
    printf '{"version":"%s","pid":%s,"connected":true,"min_version":"99.0.0","latest_version":"99.9.9"}\n' \
      "$version" "${REXDUO_TEST_PID:?}" >"$state/status.json"
    ;;
  update)
    # With a version in `update-to`, the app becomes that version, as a real update would.
    [ -f "$home/update-to" ] && [ -f "$plist" ] || exit 1
    /usr/bin/plutil -replace CFBundleShortVersionString -string "$(cat "$home/update-to")" "$plist"
    ;;
  *) exit 2 ;;
esac
