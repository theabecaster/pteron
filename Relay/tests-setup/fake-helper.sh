#!/bin/sh
# A stand-in for rex-duo-helper, for Relay/test-install.sh. It starts nothing: `install` only
# writes the status.json a started helper would write, into the test's own home folder, and
# `uninstall` only deletes the service's entry there. Every
# call is logged to helper.log there, and to helper-runs.log with the version that was called.
# On a Mac `install` also writes the program it was called as into the LaunchAgent's file, and
# an app that calls itself Rex DUO Beacon in a folder named Rex DUO Helper.app first renames
# that folder, as the helper does (`no-move` in the home folder keeps it where it is).
# The LaunchAgent is handled as the helper handles it, through the tests' stand-in for
# launchctl, whose log names these calls as the helper's. An app that calls itself Rex DUO
# Beacon uses the service's name and moves a service from the earlier name to it: the new
# file is written, the earlier job booted out, the new one loaded, and then the earlier file
# deleted. When it does not start (`no-start`) it goes back: the new job is booted out, its
# file removed and the earlier job loaded again. With `no-report` it does all of an install
# but never says that it runs. An app of another name is a build from before the service's
# name, which knows the earlier one alone.
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

agents="$home/Library/LaunchAgents"
label="dev.abrahamgonzalez.rexduo.beacon"
earlier="dev.abrahamgonzalez.rexduo.helper"
# The stand-in of Relay/test-install.sh, which keeps the jobs it has in the folder `loaded`.
launchctl() { REXDUO_TEST_BY=helper "$home/../../tools-mac/launchctl" "$@"; }
load() { [ -e "$home/loaded/$1" ] || launchctl bootstrap "gui/$(/usr/bin/id -u)" "$agents/$1.plist"; }
boot_out() { [ ! -e "$home/loaded/$1" ] || launchctl bootout "gui/$(/usr/bin/id -u)/$1"; }

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
    if [ -f "$plist" ]; then
      app="$(cd "$here/../.." && pwd)"
      name="$(/usr/bin/plutil -extract CFBundleName raw -o - "$plist" 2>/dev/null || :)"
      if [ "${app##*/}" = "Rex DUO Helper.app" ] && [ "$name" = "Rex DUO Beacon" ] && [ ! -f "$home/no-move" ] && [ ! -e "${app%/*}/Rex DUO Beacon.app" ]; then
        mv "$app" "${app%/*}/Rex DUO Beacon.app"
        app="${app%/*}/Rex DUO Beacon.app"
      fi
      mkdir -p "$agents"
      moved=0
      if [ "$name" != "Rex DUO Beacon" ]; then label="$earlier"; fi
      printf '%s\n' "$app/Contents/MacOS/rex-duo-helper" >"$agents/$label.plist"
      if [ "$label" != "$earlier" ] && [ -f "$agents/$earlier.plist" ]; then
        moved=1
        boot_out "$earlier"
      fi
      load "$label"
    fi
    if [ -f "$home/slow-install" ]; then sleep "$(cat "$home/slow-install")"; fi
    if [ -f "$home/no-start" ]; then
      if [ "${moved:-0}" = 1 ]; then
        boot_out "$label"
        rm -f "$agents/$label.plist"
        load "$earlier"
      fi
      exit 1
    fi
    if [ "${moved:-0}" = 1 ]; then rm -f "$agents/$earlier.plist"; fi
    if [ -f "$home/no-report" ]; then exit 0; fi
    mkdir -p "$state"
    printf '{"version":"%s","pid":%s,"connected":true,"min_version":"99.0.0","latest_version":"99.9.9"}\n' \
      "$version" "${REXDUO_TEST_PID:?}" >"$state/status.json"
    ;;
  update)
    # With a version in `update-to`, the app becomes that version, as a real update would. An
    # app in a folder of the earlier name stays in that folder and becomes a build that calls
    # itself Rex DUO Beacon, as an update by the updater of version 0.3.0 leaves it.
    [ -f "$home/update-to" ] && [ -f "$plist" ] || exit 1
    /usr/bin/plutil -replace CFBundleShortVersionString -string "$(cat "$home/update-to")" "$plist"
    /usr/bin/plutil -replace CFBundleName -string "Rex DUO Beacon" "$plist"
    ;;
  uninstall)
    # The service's entry goes, as the helper's uninstall removes it. `no-uninstall` makes it fail.
    if [ -f "$home/no-uninstall" ]; then exit 1; fi
    if [ -f "$plist" ]; then
      name="$(/usr/bin/plutil -extract CFBundleName raw -o - "$plist" 2>/dev/null || :)"
      if [ "$name" = "Rex DUO Beacon" ]; then
        boot_out "$label"
        rm -f "$agents/$label.plist"
      fi
      boot_out "$earlier"
      rm -f "$agents/$earlier.plist"
    else
      rm -f "$home/.config/systemd/user/rex-duo-helper.service"
    fi
    ;;
  *) exit 2 ;;
esac
