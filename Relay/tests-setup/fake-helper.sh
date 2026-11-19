#!/bin/sh
# A stand-in for rex-duo-helper, for Relay/test-install.sh. It starts nothing: `install` only
# writes the status.json a started helper would write, into the test's own home folder, and
# `uninstall` only deletes the service's entry there. Every
# call is logged to helper.log there, and to helper-runs.log with the version that was called.
#
# On a Mac it is one of three builds, told apart by what its Info.plist calls it:
#   - the program's name (`@BEACON@` here): the service is `….rexduo.agent`, and the app's
#     folder is `<name>.app`;
#   - `Rex DUO Beacon`, as version 0.3.1 was: the service is `….rexduo.beacon`, the folder
#     `Rex DUO Beacon.app`;
#   - anything else, as version 0.3.0 was: the service is `….rexduo.helper`, and the build
#     knows no other name of anything.
# `install` writes the program it was called as into the LaunchAgent's file. A build in a
# folder of a name from before its own first renames that folder, as the helper does
# (`no-move` in the home folder keeps it where it is; beside a copy that has the build's own
# name already it is deleted instead, and that copy is the one that runs), and moves a service from a name from
# before its own: the new file is written, the earlier jobs booted out, the new one loaded,
# and then the earlier files deleted. When it does not start (`no-start`) it goes back: the
# new job is booted out, its file removed and the earlier job loaded again. With `no-report`
# it does all of an install but never says that it runs. The LaunchAgent is handled through
# the tests' stand-in for launchctl, whose log names these calls as the helper's.
# test-install.sh puts a version in place of @VERSION@ and the program's name in place of
# @BEACON@; inside an app bundle the version is the bundle's.
set -eu
home="${REXDUO_TEST_HOME:?fake-helper.sh runs only inside Relay/test-install.sh}"
version="@VERSION@"
beacon="@BEACON@"
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
prefix="dev.abrahamgonzalez.rexduo"
# The stand-in of Relay/test-install.sh, which keeps the jobs it has in the folder `loaded`.
launchctl() { REXDUO_TEST_BY=helper "$home/../../tools-mac/launchctl" "$@"; }
load() { [ -e "$home/loaded/$1" ] || launchctl bootstrap "gui/$(/usr/bin/id -u)" "$agents/$1.plist"; }
boot_out() { [ ! -e "$home/loaded/$1" ] || launchctl bootout "gui/$(/usr/bin/id -u)/$1"; }

# Which build this is: its service's name, the names from before it (newest first), its
# folder, and the folders from before it, each between two bars.
build() {
  name="$(/usr/bin/plutil -extract CFBundleName raw -o - "$plist" 2>/dev/null || :)"
  case "$name" in
    "$beacon")
      label="$prefix.agent"
      earlier="$prefix.beacon $prefix.helper"
      folder="$beacon.app"
      before="|Rex DUO Beacon.app|Rex DUO Helper.app|"
      ;;
    "Rex DUO Beacon")
      label="$prefix.beacon"
      earlier="$prefix.helper"
      folder="Rex DUO Beacon.app"
      before="|Rex DUO Helper.app|"
      ;;
    *)
      label="$prefix.helper"
      earlier=""
      folder=""
      before="|"
      ;;
  esac
}

case "${1:-}" in
  version)
    if [ "${2:-}" = --json ]; then printf '{"version":"%s"}\n' "$version"; else printf '%s\n' "$version"; fi
    ;;
  brand)
    printf '%s\n' "$beacon"
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
    moved=""
    if [ -f "$plist" ]; then
      app="$(cd "$here/../.." && pwd)"
      build
      case "$before" in
        *"|${app##*/}|"*)
          if [ ! -f "$home/no-move" ]; then
            # A copy that is under the build's own name already is the one that runs, and
            # this one is the leftover, which goes.
            if [ -e "${app%/*}/$folder" ]; then rm -rf "$app"; else mv "$app" "${app%/*}/$folder"; fi
            app="${app%/*}/$folder"
          fi
          ;;
      esac
      mkdir -p "$agents"
      printf '%s\n' "$app/Contents/MacOS/rex-duo-helper" >"$agents/$label.plist"
      for old in $earlier; do
        if [ -f "$agents/$old.plist" ]; then
          # The newest of them is the one to go back to.
          if [ -z "$moved" ]; then moved="$old"; fi
          boot_out "$old"
        fi
      done
      load "$label"
    fi
    if [ -f "$home/slow-install" ]; then sleep "$(cat "$home/slow-install")"; fi
    if [ -f "$home/no-start" ]; then
      if [ -n "$moved" ]; then
        boot_out "$label"
        rm -f "$agents/$label.plist"
        load "$moved"
      fi
      exit 1
    fi
    if [ -n "$moved" ]; then
      for old in $earlier; do rm -f "$agents/$old.plist"; done
    fi
    if [ -f "$home/no-report" ]; then exit 0; fi
    mkdir -p "$state"
    printf '{"version":"%s","pid":%s,"connected":true,"min_version":"99.0.0","latest_version":"99.9.9"}\n' \
      "$version" "${REXDUO_TEST_PID:?}" >"$state/status.json"
    ;;
  update)
    # With a version in `update-to`, the app becomes that version, as a real update would. An
    # app in a folder of an earlier name stays in that folder and becomes a build that calls
    # itself by the program's name, as an update by an earlier version's updater leaves it.
    [ -f "$home/update-to" ] && [ -f "$plist" ] || exit 1
    /usr/bin/plutil -replace CFBundleShortVersionString -string "$(cat "$home/update-to")" "$plist"
    /usr/bin/plutil -replace CFBundleName -string "$beacon" "$plist"
    ;;
  uninstall)
    # The service's entry goes, as the helper's uninstall removes it, under every name this
    # build knows. `no-uninstall` makes it fail.
    if [ -f "$home/no-uninstall" ]; then exit 1; fi
    if [ -f "$plist" ]; then
      build
      for known in $label $earlier; do
        boot_out "$known"
        rm -f "$agents/$known.plist"
      done
    else
      rm -f "$home/.config/systemd/user/rex-duo-helper.service"
    fi
    ;;
  *) exit 2 ;;
esac
