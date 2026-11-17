#!/bin/sh
# Installs Rex DUO Helper on a Mac or a Linux computer and starts it in the background.
#
# One file, two ways to run it:
#
#   From Rex DUO on the phone. The app keeps this file inside itself and starts it in a tab on the
#   computer as `/bin/sh -c <this file> rexduo-setup <12 arguments>`. The app has already checked
#   the signed release list, and the arguments carry what it learned: the version, the size and
#   SHA-256 of the file for each kind of computer, and the keys it trusts. The app's one-time
#   setup code is no argument: the app types it into the tab when this script asks for it.
#
#   By hand, with no arguments. It is published as install.sh:
#     curl -fsSL https://github.com/theabecaster/rexduo/releases/download/helper-latest/install.sh | sh
#   It then reads the release list itself and checks it with the two keys below. On a Mac, whose
#   own openssl does not check such a signature, Apple's checks of the app decide, within the
#   version and the date Relay/release.sh writes into the published copy.
#
# Either way the steps are the same: find the system's own tools, download one file, check its
# size and SHA-256 (and the Linux signature or the Mac code signature and notarization), put it
# in place in one step, start the service and wait until the helper reports that it runs.
# Nothing runs as an administrator, and nothing that was downloaded runs before it was checked.
#
# Progress goes to the terminal as plain sentences and as an OSC 7501 program-status record
# (id and app `rexduo-setup`), which Rex shows and the app follows. The exit code says how it
# ended: 0 done, 10 arguments or setup code, 11 no build for this computer, 12 no curl or wget, 13 network,
# 14 a check failed, 15 could not write, 16 another install is running, 17 installed but not
# started, 18 nobody is logged in on the Mac, 19 no systemd for this user, 20 the Mac kept the
# old app, 21 macOS is older than 14.
#
# Everything is a function and the last line starts it, so a copy that broke off half way runs
# nothing. Relay/test-install.sh tests this file.
set -eu
set -f
set -C
umask 077

# Where releases are published. Files of version V are at $BASE/helper-vV/<name>.
BASE="https://github.com/theabecaster/rexduo/releases/download"
# The keys releases are signed with (ed25519, 32 raw bytes in base64): the primary key signs
# releases, the recovery key is kept apart from it. Relay/release.sh refuses to publish when
# these differ from Relay/update-key.pub, which the helper checks its own updates with.
PRIMARY_KEY="Yn851QvA2ZzvkX/TkpqQcsiIOqUd2wi0jAFRbh+0OP0="
RECOVERY_KEY="p6Uwh2Qc232RxSymb4uFSkx/A/4Czn+/+QTz16RbLGE="
# For a run by hand on a Mac: the oldest version this copy installs and the time it stops
# installing (YYYY-MM-DDTHH:MM:SSZ). Both are empty here and in the copy Rex DUO carries.
# Relay/release.sh fills them in, in the copy it publishes as install.sh and nowhere else.
MANUAL_MAC_FLOOR=""
MANUAL_MAC_EXPIRES=""
# The only folders a tool is taken from: the system's own, which belong to root.
TOOL_DIRS="/usr/bin /bin /usr/sbin /sbin /run/current-system/sw/bin"
DOWNLOADERS="curl wget"
# https only, also across GitHub's redirect to its download host.
CURL_ONLY="--proto =https --proto-redir =https --tlsv1.2"
WGET_ONLY="--https-only"
SYSTEM_APPS="/Applications"
# How long the helper has to report that it runs.
WAIT_SECONDS=20
# How long Rex DUO has to type its setup code.
CODE_SECONDS=60

APP_NAME="Rex DUO Helper.app"
# The name an installed app waits under while the one that replaces it starts.
PREVIOUS_NAME="Rex DUO Helper.previous.app"
BIN_NAME="rex-duo-helper"
# What the Mac app's code signature must say: our bundle id, a Developer ID certificate of our
# team, on Apple's chain. The same text as Relay/src/update.rs.
REQUIREMENT='identifier "dev.abrahamgonzalez.rexduo.helper" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "R2PVQ496X7"'
MAX_ASSET=67108864
NO_KEY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

MODE=manual
RECORDS=0
STAGE=""
LOCK=""
LOCK_MINE=0
NEW_TMP=""
PREV_APP=""
OLD_APP=""
OLD_OK=0
TTY_STATE=""
DIRS=""
LS=""
BASE64=""
OPENSSL=""
SHA256SUM=""
CURL=""
WGET=""
SIGNED=0
NONCE=""
SERVER=""
LINGER=ask

say() { printf '%s\n' "$*"; }

# b64 <text>: the text in base64 on one line.
b64() {
  if [ -n "$BASE64" ]; then
    printf '%s' "$1" | "$BASE64" | tr -d '\n'
  elif [ -n "$OPENSSL" ]; then
    printf '%s' "$1" | "$OPENSSL" base64 -A
  else
    return 1
  fi
}

# record <state> <title> <sentence> [<field>]: one OSC 7501 report. Title and sentence travel in
# base64, as Rex reads them.
record() {
  [ "$RECORDS" = 1 ] || return 0
  r_title="$(b64 "$2")" || return 0
  r_msg="$(b64 "$3")" || return 0
  printf '\033]7501;id=rexduo-setup:app=rexduo-setup:state=%s%s:title=%s:msg=%s\033\\' "$1" "${4:+:$4}" "$r_title" "$r_msg"
}

# step <title> <percent> <sentence>: says what happens next.
step() {
  say "$3"
  record working "$1" "$3" "progress=$2"
}

# fail <CODE> <sentence>: says why, reports it and stops with the code's number.
fail() {
  case "$1" in
    ARGS) f_code=10 ;;
    ARCH) f_code=11 ;;
    NO_DOWNLOADER) f_code=12 ;;
    NET) f_code=13 ;;
    VERIFY) f_code=14 ;;
    WRITE) f_code=15 ;;
    BUSY) f_code=16 ;;
    SERVICE) f_code=17 ;;
    NO_GUI) f_code=18 ;;
    NO_SYSTEMD) f_code=19 ;;
    APP_MGMT) f_code=20 ;;
    *) f_code=21 ;;
  esac
  printf '%s\n' "$2" >&2
  record error "fail:E_$1" "$2"
  exit "$f_code"
}

# The app that was set aside goes back under its own name, in place of a new one that did not
# get as far as running, and is started again if its code signature was accepted.
put_back() {
  pb_app="${PREV_APP%/*}/$APP_NAME"
  rm -rf "$pb_app" 2>/dev/null
  if [ ! -e "$pb_app" ] && mv "$PREV_APP" "$pb_app" 2>/dev/null; then
    say "The Rex DUO Helper that was installed before is back in its place."
    if [ "$OLD_OK" = 1 ]; then
      set -- "$pb_app/Contents/MacOS/$BIN_NAME" install
      if [ -n "$SERVER" ]; then set -- "$@" --server "$SERVER"; fi
      "$@" </dev/null >/dev/null 2>&1 3<&-
    fi
  fi
  PREV_APP=""
}

# A signal ends the script through cleanup, once: signals that follow are not acted on.
stop() {
  trap '' HUP INT TERM
  exit "$1"
}

# Runs however the script ends: the terminal gets its echo back, an app that was set aside
# goes back, and the staging folder, a half-placed copy and the lock go away. It runs to its
# end whatever signal arrives, and the exit code stays what it was.
cleanup() {
  c_code=$?
  set +e
  trap - EXIT
  trap '' HUP INT TERM
  if [ -n "$TTY_STATE" ]; then stty "$TTY_STATE" <&3 2>/dev/null; fi
  if [ -n "$NEW_TMP" ]; then rm -rf "$NEW_TMP"; fi
  if [ -n "$PREV_APP" ]; then put_back; fi
  if [ -n "$STAGE" ]; then rm -rf "$STAGE"; fi
  if [ "$LOCK_MINE" = 1 ]; then rm -rf "$LOCK"; fi
  exit "$c_code"
}

# The script's own surroundings: a fixed PATH, none of the variables that change how a shell or
# a tool behaves, and the terminal on its own descriptor, 3, so that no tool reads from it
# unless it is handed over: the tab's input when the app started the script, else where the
# messages go. The helper is always started without it.
harden() {
  PATH=/usr/bin:/bin:/usr/sbin:/sbin
  LC_ALL=C
  export PATH LC_ALL
  for h_name in IFS ENV BASH_ENV CDPATH CURL_HOME CURL_CA_BUNDLE WGETRC SSL_CERT_FILE SSL_CERT_DIR OPENSSL_CONF PERL5OPT PERL5LIB \
    LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH TMPDIR; do
    unset "$h_name" 2>/dev/null || :
  done
  trap cleanup EXIT
  trap 'stop 129' HUP
  trap 'stop 130' INT
  trap 'stop 143' TERM
  if [ "$MODE" = app ] && [ -t 0 ]; then
    exec 3<&0
  elif [ -t 2 ]; then
    exec 3<&2
  else
    exec 3</dev/null
  fi
  exec </dev/null
  # In the app's tab, what is typed is not shown, and only the setup code is read.
  if [ "$MODE" = app ] && [ -t 3 ]; then
    TTY_STATE="$(stty -g <&3 2>/dev/null)" || TTY_STATE=""
    if [ -n "$TTY_STATE" ]; then stty -echo <&3 2>/dev/null || TTY_STATE=""; fi
  fi
}

# trusted <path>: true when the file or folder belongs to root and nobody else may change it.
trusted() {
  [ -e "$1" ] || return 1
  "$LS" -ldnL "$1" 2>/dev/null | {
    read -r t_mode t_links t_owner t_rest || exit 1
    case "$t_owner" in
      0) ;; # root
      *) exit 1 ;;
    esac
    case "$t_mode" in
      ?????w* | ????????w*) exit 1 ;;
    esac
    exit 0
  }
}

# tool <name>: the path of a system tool, from the trusted folders only.
tool() {
  for t_dir in $DIRS; do
    if [ -f "$t_dir/$1" ] && [ -x "$t_dir/$1" ] && trusted "$t_dir/$1"; then
      printf '%s' "$t_dir/$1"
      return 0
    fi
  done
  return 1
}

resolve_tools() {
  for r_dir in $TOOL_DIRS; do
    if [ -x "$r_dir/ls" ]; then
      LS="$r_dir/ls"
      break
    fi
  done
  r_path=""
  if [ -n "$LS" ]; then
    for r_dir in $TOOL_DIRS; do
      if [ -d "$r_dir" ] && trusted "$r_dir"; then
        DIRS="$DIRS $r_dir"
        r_path="$r_path${r_path:+:}$r_dir"
      fi
    done
  fi
  [ -n "$r_path" ] || fail ARCH "This computer's system tools are not where the installer looks for them."
  PATH="$r_path"
  BASE64="$(tool base64)" || BASE64=""
  OPENSSL="$(tool openssl)" || OPENSSL=""
  SHA256SUM="$(tool sha256sum)" || SHA256SUM=""
  UNAME="$(tool uname)" || fail ARCH "This computer has no uname, so the installer can't tell what it is."
  MKTEMP="$(tool mktemp)" || fail ARCH "This computer has no mktemp, which the installer needs."
  [ -n "$SHA256SUM$OPENSSL" ] || fail ARCH "This computer has neither sha256sum nor openssl, which the installer needs to check the download."
  for r_name in $DOWNLOADERS; do
    case "$r_name" in
      curl) CURL="$(tool curl)" || CURL="" ;;
      wget) WGET="$(tool wget)" || WGET="" ;;
    esac
  done
  # Checking an ed25519 signature takes openssl 3.
  if [ -n "$OPENSSL" ] && "$OPENSSL" pkeyutl -help 2>&1 | grep -q -- '-rawin'; then SIGNED=1; fi
}

# MARK: What the arguments must look like

is_hex64() {
  [ ${#1} -eq 64 ] || return 1
  case "$1" in *[!0-9a-f]*) return 1 ;; esac
}

# One part of a version: 1 to 4 digits, written without a leading zero.
is_part() {
  case "$1" in "" | *[!0-9]* | 0?* | ?????*) return 1 ;; esac
}

is_version() {
  case "$1" in *.*.*.* | *[!0-9.]*) return 1 ;; *.*.*) ;; *) return 1 ;; esac
  iv_rest="${1#*.}"
  is_part "${1%%.*}" && is_part "${iv_rest%%.*}" && is_part "${iv_rest#*.}"
}

# A file size: digits, more than nothing and at most 64 MiB.
is_size() {
  case "$1" in "" | *[!0-9]* | 0* | ?????????*) return 1 ;; esac
  [ "$1" -le "$MAX_ASSET" ]
}

is_key() {
  [ ${#1} -eq 44 ] || return 1
  case "$1" in *=) ;; *) return 1 ;; esac
  case "${1%=}" in *[!A-Za-z0-9+/]*) return 1 ;; esac
}

# A list of keys: 1 to 6 of them with a comma between each two.
is_keys() {
  ik_rest="$1,"
  ik_count=0
  while [ -n "$ik_rest" ]; do
    is_key "${ik_rest%%,*}" || return 1
    ik_rest="${ik_rest#*,}"
    ik_count=$((ik_count + 1))
  done
  [ "$ik_count" -le 6 ]
}

# A time as the release list writes it: YYYY-MM-DDTHH:MM:SSZ, in UTC.
is_stamp() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) ;;
    *) return 1 ;;
  esac
}

# past <time>: true from that second on. The digits alone compare as the times do.
past() {
  p_now="$(date -u +%Y%m%d%H%M%S)"
  [ "$p_now" -ge "$(printf '%s' "$1" | tr -cd 0-9)" ]
}

ver_num() {
  vn_rest="${1#*.}"
  printf '%s' "$((${1%%.*} * 100000000 + ${vn_rest%%.*} * 10000 + ${vn_rest#*.}))"
}

# ver_lt <a> <b>: true when version a is older than version b.
ver_lt() { [ "$(ver_num "$1")" -lt "$(ver_num "$2")" ]; }

# The 12 arguments the app passes: `2`, the version, the oldest version it accepts, a SHA-256
# and a size for the Mac file and for each of the two Linux files, the keys the app trusts,
# `ask` or `skip` for lingering, and `-`. Anything else stops here, before anything is
# downloaded.
check_args() {
  ca_bad="The installer was started with arguments it doesn't accept. Nothing was installed."
  [ $# -eq 12 ] || fail ARGS "$ca_bad"
  [ "$1" = 2 ] || fail ARGS "$ca_bad"
  is_version "$2" && is_version "$3" || fail ARGS "$ca_bad"
  is_hex64 "$4" && is_size "$5" && is_hex64 "$6" && is_size "$7" && is_hex64 "$8" && is_size "$9" || fail ARGS "$ca_bad"
  is_keys "${10}" || fail ARGS "$ca_bad"
  case "${11}" in ask | skip) ;; *) fail ARGS "$ca_bad" ;; esac
  [ "${12}" = - ] || fail ARGS "$ca_bad"
  if ver_lt "$2" "$3"; then fail ARGS "$ca_bad"; fi
  VERSION="$2"
  MAC_SHA="$4"
  MAC_SIZE="$5"
  X64_SHA="$6"
  X64_SIZE="$7"
  A64_SHA="$8"
  A64_SIZE="$9"
  KEYS="${10}"
  LINGER="${11}"
}

# The setup code: 64 hex digits that Rex DUO types into this tab, followed by Return, once the
# `code` record says the installer waits for it. The echo is off by then, and the code is
# never printed and never part of a command line: the shell's own `read` takes it, and the
# shell's own `printf` later writes it to a file for the helper.
#
# POSIX sh has no read with a time limit, so the terminal keeps the time. Without line editing
# and with `min 0 time 10`, a read that gets nothing for one second returns with nothing, which
# ends `read` without a line. The loop counts those seconds and keeps what came so far, so a
# code that arrives in pieces is still one line. No other process is started while it waits.
read_code() {
  rc_none="Rex DUO did not send its setup code. Nothing was installed."
  [ "$(command -v printf)" = printf ] || fail ARCH "The installer needs a shell with its own printf."
  [ -n "$TTY_STATE" ] || fail ARGS "$rc_none"
  rc_quiet="$(stty -g <&3 2>/dev/null)" || fail ARGS "$rc_none"
  # What was typed before this moment is dropped.
  stty -icanon icrnl min 0 time 0 <&3 2>/dev/null || fail ARGS "$rc_none"
  cat <&3 >/dev/null 2>&1 || :
  stty min 0 time 10 <&3 2>/dev/null || fail ARGS "$rc_none"
  step code 5 "Waiting for the setup code from Rex DUO…"
  rc_left="$CODE_SECONDS"
  rc_code=""
  rc_line=0
  while [ "$rc_left" -gt 0 ] && [ ${#rc_code} -le 64 ]; do
    rc_part=""
    if IFS= read -r rc_part <&3; then rc_line=1; fi
    rc_code="$rc_code$rc_part"
    [ "$rc_line" = 0 ] || break
    rc_left=$((rc_left - 1))
  done
  stty "$rc_quiet" <&3 2>/dev/null || :
  [ "$rc_line" = 1 ] || fail ARGS "$rc_none"
  is_hex64 "$rc_code" || fail ARGS "What arrived is not a setup code of Rex DUO. Nothing was installed."
  NONCE="$rc_code"
  rc_code=""
  rc_part=""
}

# MARK: This computer

platform() {
  OS="$("$UNAME" -s)" || OS=""
  p_cpu="$("$UNAME" -m)" || p_cpu=""
  case "$OS" in
    Darwin)
      PLATFORM=macos-universal
      ASSET="Rex-DUO-Helper.zip"
      SW_VERS="$(tool sw_vers)" || fail ARCH "This Mac has no sw_vers, so the installer can't tell its macOS version."
      p_major="$("$SW_VERS" -productVersion)" || p_major=""
      p_major="${p_major%%.*}"
      case "$p_major" in "" | *[!0-9]* | ?????*) fail ARCH "The installer can't tell this Mac's macOS version." ;; esac
      [ "$p_major" -ge 14 ] || fail OLD_MACOS "Rex DUO Helper needs macOS 14 or later."
      for p_name in ditto codesign spctl plutil launchctl; do
        tool "$p_name" >/dev/null || fail ARCH "This Mac has no $p_name, which the installer needs."
      done
      DITTO="$(tool ditto)"
      CODESIGN="$(tool codesign)"
      SPCTL="$(tool spctl)"
      PLUTIL="$(tool plutil)"
      LAUNCHCTL="$(tool launchctl)"
      ;;
    Linux)
      case "$p_cpu" in
        x86_64 | amd64) PLATFORM=linux-x86_64 ;;
        aarch64 | arm64) PLATFORM=linux-aarch64 ;;
        *) fail ARCH "Rex DUO Helper has no build for this kind of computer yet." ;;
      esac
      ASSET="$BIN_NAME-$PLATFORM"
      SYSTEMCTL="$(tool systemctl)" || SYSTEMCTL=""
      LOGINCTL="$(tool loginctl)" || LOGINCTL=""
      ;;
    *) fail ARCH "Rex DUO Helper runs on macOS and Linux only." ;;
  esac
  say "This computer: $PLATFORM."
}

# The home folder as the account database has it.
account_home() {
  case "$OS" in
    Darwin)
      ah_dscl="$(tool dscl)" || return 1
      "$ah_dscl" . -read "/Users/$USER_NAME" NFSHomeDirectory 2>/dev/null | sed -n -e 's/^NFSHomeDirectory: *\(\/.*\)$/\1/p' -e 's/^ \(\/.*\)$/\1/p' | sed -n 1p
      ;;
    *)
      if ah_getent="$(tool getent)"; then
        "$ah_getent" passwd "$USER_ID" | cut -d : -f 6
      else
        awk -F : -v id="$USER_ID" '$3 == id { print $6; exit }' /etc/passwd
      fi
      ;;
  esac
}

# private_dir <folder>: true for a real folder that is ours and closed to everyone else.
private_dir() {
  [ -n "$1" ] || return 1
  if [ ! -d "$1" ] || [ -L "$1" ]; then return 1; fi
  "$LS" -ldn "$1" 2>/dev/null | {
    read -r p_mode p_links p_owner p_rest || exit 1
    [ "$p_owner" = "$USER_ID" ] || exit 1
    case "$p_mode" in drwx------*) exit 0 ;; esac
    exit 1
  }
}

account() {
  USER_ID="$(id -u)" || USER_ID=""
  USER_NAME="$(id -un)" || USER_NAME=""
  case "$USER_ID" in "" | *[!0-9]*) fail WRITE "The installer can't tell which account it runs as." ;; esac
  case "$USER_NAME" in "" | */* | .*) fail WRITE "The installer can't tell which account it runs as." ;; esac
  HOME="$(account_home)" || HOME=""
  case "$HOME" in /*) ;; *) HOME="" ;; esac
  if [ -z "$HOME" ] || [ ! -d "$HOME" ]; then fail WRITE "The installer can't find this account's home folder."; fi
  export HOME
  case "$OS" in
    Darwin) STATE="$HOME/Library/Application Support/Rex DUO Helper" ;;
    *)
      # What the helper's service needs to reach systemd when the tab's environment lacks it.
      if [ -z "${XDG_RUNTIME_DIR:-}" ] && private_dir "/run/user/$USER_ID"; then
        XDG_RUNTIME_DIR="/run/user/$USER_ID"
        export XDG_RUNTIME_DIR
      fi
      if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -S "$XDG_RUNTIME_DIR/bus" ]; then
        DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
        export DBUS_SESSION_BUS_ADDRESS
      fi
      case "${XDG_STATE_HOME:-}" in
        /*) STATE="$XDG_STATE_HOME/$BIN_NAME" ;;
        *) STATE="$HOME/.local/state/$BIN_NAME" ;;
      esac
      ;;
  esac
  # The Rex server this tab belongs to. Rex sets it in every terminal it starts.
  SERVER="${REX_SERVER:-}"
  case "$SERVER" in
    *[[:cntrl:]]*) SERVER="" ;;
    unix:///* | https://?*) if [ ${#SERVER} -gt 512 ]; then SERVER=""; fi ;;
    *) SERVER="" ;;
  esac
}

# tilde <path>: the path as it is shown, with ~ for the home folder.
tilde() {
  case "$1" in
    "$HOME"/*) printf '~/%s' "${1#"$HOME"/}" ;;
    *) printf '%s' "$1" ;;
  esac
}

# MARK: One install at a time

# True when the lock is left over: nobody wrote who holds it, that process is gone, or it is
# older than 30 minutes.
lock_stale() {
  if [ ! -f "$LOCK/owner" ]; then
    sleep 1
    [ -f "$LOCK/owner" ] || return 0
  fi
  l_pid=""
  l_at=""
  read -r l_pid l_at l_rest <"$LOCK/owner" || :
  case "$l_pid" in "" | *[!0-9]* | 0* | ??????????*) return 0 ;; esac
  case "$l_at" in "" | *[!0-9]* | ?????????????*) return 0 ;; esac
  kill -0 "$l_pid" 2>/dev/null || return 0
  l_now="$(date +%s)"
  if [ $((l_now - l_at)) -gt 1800 ]; then return 0; fi
  return 1
}

take_lock() {
  mkdir -p "$STATE" 2>/dev/null || fail WRITE "The installer couldn't create $(tilde "$STATE")."
  LOCK="$STATE/setup.lock"
  if ! mkdir "$LOCK" 2>/dev/null; then
    [ -d "$LOCK" ] || fail WRITE "The installer couldn't write to $(tilde "$STATE")."
    lock_stale || fail BUSY "Another install of Rex DUO Helper is already running on this computer."
    rm -rf "$LOCK"
    mkdir "$LOCK" 2>/dev/null || fail BUSY "Another install of Rex DUO Helper is already running on this computer."
  fi
  LOCK_MINE=1
  printf '%s %s\n' "$$" "$(date +%s)" >"$LOCK/owner" || fail WRITE "The installer couldn't write to $(tilde "$STATE")."
}

# The folder downloads are kept in until they are checked: per user and closed to others.
stage_root() {
  case "$OS" in
    Darwin)
      sr_getconf="$(tool getconf)" || sr_getconf=""
      sr=""
      if [ -n "$sr_getconf" ]; then sr="$("$sr_getconf" DARWIN_USER_TEMP_DIR 2>/dev/null)" || sr=""; fi
      sr="${sr%/}"
      if private_dir "$sr"; then
        printf '%s' "$sr"
        return 0
      fi
      sr="$HOME/Library/Caches"
      ;;
    *)
      for sr in "${XDG_RUNTIME_DIR:-}" "/run/user/$USER_ID"; do
        if private_dir "$sr"; then
          printf '%s' "$sr"
          return 0
        fi
      done
      sr="$HOME/.cache"
      ;;
  esac
  mkdir -p "$sr" 2>/dev/null || return 1
  printf '%s' "$sr"
}

make_stage() {
  STAGE_ROOT="$(stage_root)" || STAGE_ROOT=""
  [ -n "$STAGE_ROOT" ] || fail WRITE "The installer found no folder to keep the download in."
  # This run holds the lock, so a staging folder already there is from a run that was cut short.
  set +f
  for ms_old in "$STAGE_ROOT"/rexduo-setup.*; do
    if [ -d "$ms_old" ] && [ ! -L "$ms_old" ]; then rm -rf "$ms_old"; fi
  done
  set -f
  STAGE="$("$MKTEMP" -d "$STAGE_ROOT/rexduo-setup.XXXXXX")" || STAGE=""
  [ -n "$STAGE" ] || fail WRITE "The installer couldn't create a folder to keep the download in."
}

# MARK: Downloading and checking

size_of() { wc -c <"$1" | tr -d ' '; }

sha256_of() {
  if [ -n "$SHA256SUM" ]; then
    "$SHA256SUM" "$1" | cut -c 1-64
  else
    "$OPENSSL" dgst -sha256 -r "$1" | cut -c 1-64
  fi
}

# fetch <address> <file> <most bytes>: 0 when the file is there, 1 when the network failed, 2
# when the file is larger than allowed. What the tool printed is not shown.
fetch() {
  rm -f "$2"
  f_rc=0
  if [ -n "$CURL" ]; then
    # shellcheck disable=SC2086 # CURL_ONLY is a list of options
    "$CURL" -q -fsSL $CURL_ONLY --max-redirs 5 --retry 2 --connect-timeout 20 --max-time 900 --max-filesize "$3" -o "$2" "$1" 2>/dev/null || f_rc=$?
    case "$f_rc" in
      0) ;;
      63) return 2 ;;
      *) return 1 ;;
    esac
  elif [ -n "$WGET" ]; then
    if "$WGET" --version 2>/dev/null | grep -q 'GNU Wget'; then
      # shellcheck disable=SC2086 # WGET_ONLY is a list of options
      "$WGET" --no-config -q $WGET_ONLY --max-redirect=5 --tries=3 --timeout=20 -O "$2" "$1" 2>/dev/null || return 1
    else
      "$WGET" -q -T 20 -O "$2" "$1" 2>/dev/null || return 1
    fi
  else
    fail NO_DOWNLOADER "This computer needs curl or wget to download Rex DUO Helper. Install curl, then try again."
  fi
  [ -f "$2" ] || return 1
  [ "$(size_of "$2")" -le "$3" ] || return 2
}

# key_der <base64 key> <file>: the public key as a file openssl reads, which is the fixed
# 12-byte header of an ed25519 key, then the key. The all-zero placeholder is no key.
key_der() {
  [ "$1" != "$NO_KEY" ] || return 1
  rm -f "$2"
  {
    printf '\060\052\060\005\006\003\053\145\160\003\041\000'
    printf '%s' "$1" | "$OPENSSL" base64 -d -A
  } >"$2" 2>/dev/null || return 1
  [ "$(size_of "$2")" = 44 ]
}

# verify_sig <file> <signature file> <keys>: true when one of the first 8 lines of the
# signature file is the base64 of an ed25519 signature over the file's bytes by one of the
# keys, which come as one list with commas between them.
verify_sig() {
  vs_lines=0
  while IFS= read -r vs_line || [ -n "$vs_line" ]; do
    vs_line="$(printf '%s' "$vs_line" | tr -d '\r\t ')"
    [ -n "$vs_line" ] || continue
    vs_lines=$((vs_lines + 1))
    [ "$vs_lines" -le 8 ] || break
    rm -f "$STAGE/sig.raw"
    printf '%s' "$vs_line" | "$OPENSSL" base64 -d -A >"$STAGE/sig.raw" 2>/dev/null || continue
    [ "$(size_of "$STAGE/sig.raw")" = 64 ] || continue
    vs_keys="$3,"
    while [ -n "$vs_keys" ]; do
      vs_key="${vs_keys%%,*}"
      vs_keys="${vs_keys#*,}"
      key_der "$vs_key" "$STAGE/key.der" || continue
      if "$OPENSSL" pkeyutl -verify -pubin -keyform DER -inkey "$STAGE/key.der" -rawin -in "$1" -sigfile "$STAGE/sig.raw" </dev/null >/dev/null 2>&1; then
        return 0
      fi
    done
  done <"$2"
  return 1
}

# fingerprint <base64 key>: SHA-256 of the 32 raw bytes, in hex.
fingerprint() {
  rm -f "$STAGE/fingerprint.raw"
  printf '%s' "$1" | "$OPENSSL" base64 -d -A >"$STAGE/fingerprint.raw"
  sha256_of "$STAGE/fingerprint.raw"
}

# The release list is written by release.sh with one field per line, two spaces of indent per
# level. These read exactly that shape and print nothing for anything else.

# top_field <manifest> <name>: a string field of the manifest itself.
top_field() {
  sed -n "s/^  \"$2\": \"\\([^\"]*\\)\",\\{0,1\\}\$/\\1/p" "$1"
}

# asset_field <manifest> <platform> <name>: a field of one entry of "assets".
asset_field() {
  awk -v start="    \"$2\": {" -v key="      \"$3\": " '
    $0 == start { inside = 1; next }
    inside && /^    }/ { inside = 0 }
    inside && index($0, key) == 1 {
      value = substr($0, length(key) + 1)
      sub(/,$/, "", value)
      gsub(/"/, "", value)
      print value
    }
  ' "$1"
}

# Run by hand on a Mac. macOS's own openssl does not check an ed25519 signature, so what is
# installed there is decided by Apple's checks of the app (its code signature, our team and
# identifier, its notarization) and by the two values of the published copy: no version below
# MANUAL_MAC_FLOOR, and nothing after MANUAL_MAC_EXPIRES. A copy without them installs nothing.
manual_mac() {
  mm_page="${BASE%/download}"
  if ! is_version "$MANUAL_MAC_FLOOR" || ! is_stamp "$MANUAL_MAC_EXPIRES"; then
    fail VERIFY "This copy of the installer is not the install.sh of a release, so by hand it installs nothing on a Mac. Download Rex DUO Helper from $mm_page instead."
  fi
  if past "$MANUAL_MAC_EXPIRES"; then
    fail VERIFY "This installer is out of date (it expired at $MANUAL_MAC_EXPIRES). Download the current one, or Rex DUO Helper itself, from $mm_page."
  fi
}

# Run by hand: reads the release list and checks it as the helper's updater does (signature,
# then contents, then that it has not expired). Sets the version and this computer's file.
read_release() {
  rr_none="Nothing was installed."
  say "Getting the list of releases…"
  for rr_name in manifest.json manifest.json.sig; do
    rr_max=65536
    if [ "$rr_name" = manifest.json.sig ]; then rr_max=2048; fi
    rr_rc=0
    fetch "$BASE/helper-latest/$rr_name" "$STAGE/$rr_name" "$rr_max" || rr_rc=$?
    case "$rr_rc" in
      0) ;;
      2) fail VERIFY "The release list is larger than a release list can be. $rr_none" ;;
      *) fail NET "This computer couldn't download the release list. Check its internet connection and try again." ;;
    esac
  done
  rr_list="$STAGE/manifest.json"
  if [ "$SIGNED" = 1 ]; then
    say "Releases of Rex DUO Helper are signed with one of these keys (SHA-256 of the key):"
    say "  primary   $(fingerprint "$PRIMARY_KEY")"
    say "  recovery  $(fingerprint "$RECOVERY_KEY")"
    verify_sig "$rr_list" "$rr_list.sig" "$PRIMARY_KEY,$RECOVERY_KEY" || fail VERIFY "The release list's signature doesn't match. $rr_none"
  elif [ "$OS" != Darwin ]; then
    fail VERIFY "openssl 3 or newer is needed to check the release list's signature. $rr_none"
  else
    # Here the list only names the version to get. What is installed is decided by the app's
    # code signature, its notarization and its version, all checked below.
    say "On this Mac the release list's signature is not checked. Apple's code signature and notarization checks of the app are."
  fi
  VERSION="$(top_field "$rr_list" version)"
  is_version "$VERSION" || fail VERIFY "The release list has no version. $rr_none"
  rr_min="$(top_field "$rr_list" min_version)"
  is_version "$rr_min" || fail VERIFY "The release list has no oldest supported version. $rr_none"
  if ver_lt "$VERSION" "$rr_min"; then fail VERIFY "The release list asks for a newer version than it names. $rr_none"; fi
  if [ "$OS" = Darwin ] && ver_lt "$VERSION" "$MANUAL_MAC_FLOOR"; then
    fail VERIFY "The release list names version $VERSION, older than this installer installs ($MANUAL_MAC_FLOOR). $rr_none"
  fi
  rr_expires="$(top_field "$rr_list" expires_at)"
  is_stamp "$rr_expires" || fail VERIFY "The release list doesn't say when it expires. $rr_none"
  if past "$rr_expires"; then fail VERIFY "The release list is out of date (it expired at $rr_expires). $rr_none"; fi
  WANT_SHA="$(asset_field "$rr_list" "$PLATFORM" sha256)"
  WANT_SIZE="$(asset_field "$rr_list" "$PLATFORM" size)"
  is_hex64 "$WANT_SHA" || fail VERIFY "The release list names no file for $PLATFORM. $rr_none"
  is_size "$WANT_SIZE" || fail VERIFY "The release list names no size for $PLATFORM. $rr_none"
  KEYS="$PRIMARY_KEY,$RECOVERY_KEY"
}

# From the app: the file for this computer, out of the three the arguments describe.
pick_asset() {
  case "$PLATFORM" in
    macos-universal)
      WANT_SHA="$MAC_SHA"
      WANT_SIZE="$MAC_SIZE"
      ;;
    linux-x86_64)
      WANT_SHA="$X64_SHA"
      WANT_SIZE="$X64_SIZE"
      ;;
    *)
      WANT_SHA="$A64_SHA"
      WANT_SIZE="$A64_SIZE"
      ;;
  esac
}

# sig_ok <app>: the app is intact and it is ours.
sig_ok() {
  "$CODESIGN" --verify --deep --strict "$1" >/dev/null 2>&1 && "$CODESIGN" --verify "-R=$REQUIREMENT" "$1" >/dev/null 2>&1
}

# notarized <app>: Gatekeeper accepts it and names a notarized Developer ID as the reason.
notarized() {
  n_out="$("$SPCTL" --assess --type execute -vv "$1" 2>&1)" || return 1
  printf '%s\n' "$n_out" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -qx 'source=Notarized Developer ID'
}

# app_version <app>: the version in its Info.plist. Runs nothing of the app.
app_version() {
  av="$("$PLUTIL" -extract CFBundleShortVersionString raw -o - "$1/Contents/Info.plist" 2>/dev/null)" || return 1
  is_version "$av" || return 1
  printf '%s' "$av"
}

# helper_version <binary>: what an installed Linux helper says its version is.
helper_version() {
  hv="$("$1" version --json 2>/dev/null </dev/null)" || return 1
  case "$hv" in
    '{"version":"'*'"}')
      hv="${hv#'{"version":"'}"
      hv="${hv%'"}'}"
      ;;
  esac
  is_version "$hv" || return 1
  printf '%s' "$hv"
}

# MARK: What is already here

# Sets PLAN: `keep` (a newer helper is installed: only the service is repaired), `same` (this
# version is installed and intact: nothing to download) or `fetch`. Removes what a run that was
# cut short left behind.
look() {
  PLAN=fetch
  HAVE=""
  case "$OS" in
    Darwin)
      for lk_dir in "$SYSTEM_APPS" "$HOME/Applications"; do
        [ -d "$lk_dir" ] || continue
        set +f
        for lk_old in "$lk_dir"/".$APP_NAME.new-"*; do
          if [ -d "$lk_old" ] && [ ! -L "$lk_old" ]; then rm -rf "$lk_old" 2>/dev/null || :; fi
        done
        set -f
        # An update that stopped between its two moves: the app it set aside goes back.
        if [ ! -e "$lk_dir/$APP_NAME" ] && [ -d "$lk_dir/$PREVIOUS_NAME" ]; then
          mv "$lk_dir/$PREVIOUS_NAME" "$lk_dir/$APP_NAME" 2>/dev/null || :
        fi
        if [ -z "$OLD_APP" ] && [ -d "$lk_dir/$APP_NAME" ] && [ ! -L "$lk_dir/$APP_NAME" ]; then OLD_APP="$lk_dir/$APP_NAME"; fi
      done
      if [ -n "$OLD_APP" ] && sig_ok "$OLD_APP"; then
        # The app is whole, so a copy set aside beside it has no further use. It stays while the
        # helper is in the middle of an update of its own, which still needs it to go back to.
        lk_old="${OLD_APP%/*}/$PREVIOUS_NAME"
        if [ -d "$lk_old" ] && [ ! -L "$lk_old" ] && [ ! -e "$STATE/update.lock" ]; then
          rm -rf "$lk_old" 2>/dev/null || :
        fi
        HAVE="$(app_version "$OLD_APP")" || HAVE=""
        if [ -n "$HAVE" ]; then
          if ver_lt "$VERSION" "$HAVE"; then
            PLAN=keep
          elif [ "$HAVE" = "$VERSION" ] && notarized "$OLD_APP"; then
            PLAN=same
          fi
        fi
        if [ "$PLAN" != fetch ]; then APP="$OLD_APP"; fi
      fi
      ;;
    *)
      BIN_DIR="$HOME/.local/bin"
      BIN="$BIN_DIR/$BIN_NAME"
      if [ -d "$BIN_DIR" ]; then
        set +f
        for lk_old in "$BIN_DIR"/".$BIN_NAME.new."*; do
          if [ -f "$lk_old" ] && [ ! -L "$lk_old" ]; then rm -f "$lk_old" 2>/dev/null || :; fi
        done
        set -f
      fi
      if [ -f "$BIN" ] && [ -x "$BIN" ]; then
        HAVE="$(helper_version "$BIN")" || HAVE=""
        if [ -n "$HAVE" ]; then
          if ver_lt "$VERSION" "$HAVE"; then
            PLAN=keep
          elif [ "$HAVE" = "$VERSION" ] && [ "$(sha256_of "$BIN")" = "$WANT_SHA" ]; then
            PLAN=same
          fi
        fi
      fi
      ;;
  esac
  case "$PLAN" in
    keep) say "Rex DUO Helper $HAVE is already installed, newer than $VERSION. It stays." ;;
    same) say "Rex DUO Helper $VERSION is already installed and intact." ;;
  esac
}

# MARK: Download, check, put in place

download() {
  step download 10 "Downloading Rex DUO Helper $VERSION…"
  d_rc=0
  fetch "$BASE/helper-v$VERSION/$ASSET" "$STAGE/asset" "$WANT_SIZE" || d_rc=$?
  case "$d_rc" in
    0) ;;
    2) fail VERIFY "The download is not the size the release list names. Nothing was installed." ;;
    *) fail NET "This computer couldn't download Rex DUO Helper. Check its internet connection and try again." ;;
  esac
}

verify() {
  step verify 50 "Checking it's the real Rex DUO Helper (SHA-256 ${WANT_SHA%"${WANT_SHA#????????????}"}…)…"
  v_none="Nothing was installed."
  [ "$(size_of "$STAGE/asset")" = "$WANT_SIZE" ] || fail VERIFY "The download is not the size the release list names. $v_none"
  [ "$(sha256_of "$STAGE/asset")" = "$WANT_SHA" ] || fail VERIFY "The download is not the file the release list names. $v_none"
  case "$OS" in
    Darwin)
      "$DITTO" -x -k "$STAGE/asset" "$STAGE/x" >/dev/null 2>&1 || fail VERIFY "The download could not be unzipped. $v_none"
      v_app="$STAGE/x/$APP_NAME"
      [ "$("$LS" -A "$STAGE/x")" = "$APP_NAME" ] || fail VERIFY "The download does not hold Rex DUO Helper alone. $v_none"
      if [ ! -d "$v_app" ] || [ -L "$v_app" ] || [ ! -f "$v_app/Contents/MacOS/$BIN_NAME" ] || [ -L "$v_app/Contents/MacOS/$BIN_NAME" ]; then
        fail VERIFY "The download does not hold Rex DUO Helper. $v_none"
      fi
      sig_ok "$v_app" || fail VERIFY "The downloaded app's code signature was not accepted. $v_none"
      notarized "$v_app" || fail VERIFY "macOS did not accept the downloaded app as notarized. $v_none"
      [ "$(app_version "$v_app")" = "$VERSION" ] || fail VERIFY "The downloaded app is not version $VERSION. $v_none"
      if [ "$MODE" = manual ] && ver_lt "$(app_version "$v_app")" "$MANUAL_MAC_FLOOR"; then
        fail VERIFY "The downloaded app is older than this installer installs ($MANUAL_MAC_FLOOR). $v_none"
      fi
      ;;
    *)
      # The signature covers the version, the platform and the hash, so a signed file can't
      # stand in for another version or another kind of computer.
      if [ "$SIGNED" = 1 ]; then
        v_rc=0
        fetch "$BASE/helper-v$VERSION/$ASSET.sig" "$STAGE/asset.sig" 2048 || v_rc=$?
        case "$v_rc" in
          0) ;;
          2) fail VERIFY "The download's signature is not a signature. $v_none" ;;
          *) fail NET "This computer couldn't download the signature of Rex DUO Helper. Check its internet connection and try again." ;;
        esac
        rm -f "$STAGE/signed.txt"
        printf 'rex-duo-helper|%s|%s|%s' "$VERSION" "$PLATFORM" "$WANT_SHA" >"$STAGE/signed.txt"
        verify_sig "$STAGE/signed.txt" "$STAGE/asset.sig" "$KEYS" || fail VERIFY "The download's signature doesn't match. $v_none"
      fi
      ;;
  esac
}

# Puts the checked app beside its place under another name, checks that copy, and renames it.
# An app that is there already is renamed to Rex DUO Helper.previous.app first and stays
# beside the new one until the new one runs. From that rename on, any way the script ends
# other than with the new helper running puts it back (cleanup).
place_app() {
  NEW_TMP="$DEST/.$APP_NAME.new-$$"
  rm -rf "$NEW_TMP"
  "$DITTO" "$STAGE/x/$APP_NAME" "$NEW_TMP" >/dev/null 2>&1 || fail WRITE "This Mac couldn't save Rex DUO Helper in $(tilde "$DEST"). Check it has free space, then try again."
  sig_ok "$NEW_TMP" || fail VERIFY "The copy of the app in $(tilde "$DEST") did not pass its check. Nothing was installed."
  pa_kept="This Mac didn't let the old Rex DUO Helper be replaced. Drag it from Applications to the Trash, then try again."
  if [ -n "$OLD_APP" ]; then
    pa_prev="$DEST/$PREVIOUS_NAME"
    rm -rf "$pa_prev" 2>/dev/null || :
    if [ -e "$pa_prev" ] || ! mv "$OLD_APP" "$pa_prev" 2>/dev/null; then fail APP_MGMT "$pa_kept"; fi
    PREV_APP="$pa_prev"
  fi
  if [ -e "$DEST/$APP_NAME" ]; then fail APP_MGMT "$pa_kept"; fi
  mv "$NEW_TMP" "$DEST/$APP_NAME" 2>/dev/null || fail WRITE "This Mac couldn't put Rex DUO Helper in $(tilde "$DEST")."
  NEW_TMP=""
  APP="$DEST/$APP_NAME"
  if pa_xattr="$(tool xattr)"; then "$pa_xattr" -dr com.apple.quarantine "$APP" >/dev/null 2>&1 || :; fi
}

install_mac() {
  if [ -n "$OLD_APP" ]; then
    DEST="${OLD_APP%/*}"
    # macOS lets an app be replaced by its own maker's code, so an installed helper updates
    # itself. One that can't is set aside while the new one takes its place and starts.
    if sig_ok "$OLD_APP"; then
      OLD_OK=1
      say "An older Rex DUO Helper is installed. Asking it to update itself…"
      "$OLD_APP/Contents/MacOS/$BIN_NAME" update </dev/null >/dev/null 2>&1 3<&- || :
      im_now="$(app_version "$OLD_APP")" || im_now=""
      if [ -n "$im_now" ] && ! ver_lt "$im_now" "$VERSION" && sig_ok "$OLD_APP" && notarized "$OLD_APP"; then
        APP="$OLD_APP"
        say "It is now version $im_now."
        return 0
      fi
    fi
    say "Replacing the old Rex DUO Helper…"
  elif [ -d "$SYSTEM_APPS" ] && [ -w "$SYSTEM_APPS" ]; then
    DEST="$SYSTEM_APPS"
  else
    DEST="$HOME/Applications"
    (umask 022 && mkdir -p "$DEST") 2>/dev/null || fail WRITE "This Mac couldn't create $(tilde "$DEST")."
  fi
  place_app
}

install_linux() {
  il_full="This computer couldn't save Rex DUO Helper in $(tilde "$BIN_DIR"). Check it has free space, then try again."
  (umask 022 && mkdir -p "$BIN_DIR") 2>/dev/null || fail WRITE "$il_full"
  NEW_TMP="$BIN_DIR/.$BIN_NAME.new.$$"
  rm -f "$NEW_TMP" 2>/dev/null || :
  cp "$STAGE/asset" "$NEW_TMP" 2>/dev/null || fail WRITE "$il_full"
  chmod 0755 "$NEW_TMP" 2>/dev/null || fail WRITE "$il_full"
  # Checked again where it will run from, then into place in one step.
  [ "$(sha256_of "$NEW_TMP")" = "$WANT_SHA" ] || fail VERIFY "The copy in $(tilde "$BIN_DIR") is not the file that was checked. Nothing was installed."
  mv -f "$NEW_TMP" "$BIN" 2>/dev/null || fail WRITE "$il_full"
  NEW_TMP=""
}

# MARK: The service

# start_service <helper binary>: the helper sets itself up to run in the background. The setup
# code goes to it here and nowhere else, as a file only this account can read, in the staging
# folder, which is closed to other accounts. The helper reads the file and deletes it.
start_service() {
  set -- "$1" install
  if [ -n "$SERVER" ]; then set -- "$@" --server "$SERVER"; fi
  if [ -n "$NONCE" ]; then
    rm -f "$STAGE/code"
    printf '%s' "$NONCE" >"$STAGE/code" || fail WRITE "The installer couldn't write to its own folder."
    NONCE=""
    set -- "$@" --setup-nonce-file "$STAGE/code"
  fi
  "$@" </dev/null >/dev/null 2>&1 3<&- || :
  rm -f "$STAGE/code"
}

# True when status.json names a running helper of the wanted version or a newer one.
status_ok() {
  [ -f "$STATE/status.json" ] || return 1
  so_ver="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([0-9.]*\)".*/\1/p' "$STATE/status.json" | sed -n 1p)"
  so_pid="$(sed -n 's/.*"pid"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$STATE/status.json" | sed -n 1p)"
  is_version "$so_ver" || return 1
  case "$so_pid" in "" | 0* | 1 | ??????????*) return 1 ;; esac
  kill -0 "$so_pid" 2>/dev/null || return 1
  if ver_lt "$so_ver" "$VERSION"; then return 1; fi
}

wait_running() {
  wr=0
  while ! status_ok; do
    [ "$wr" -lt "$WAIT_SECONDS" ] || return 1
    sleep 1
    wr=$((wr + 1))
  done
}

start() {
  step start 85 "Starting Rex DUO Helper…"
  s_stuck="Rex DUO Helper is installed but didn't start."
  case "$OS" in
    Darwin)
      "$LAUNCHCTL" print "gui/$USER_ID" >/dev/null 2>&1 || fail NO_GUI "Nobody is logged in on this Mac. Log in on it, then try again."
      start_service "$APP/Contents/MacOS/$BIN_NAME"
      wait_running || fail SERVICE "$s_stuck"
      ;;
    *)
      start_service "$BIN"
      if [ -n "$SYSTEMCTL" ] && "$SYSTEMCTL" --user show-environment >/dev/null 2>&1; then
        wait_running || fail SERVICE "$s_stuck"
      elif ! status_ok; then
        fail NO_SYSTEMD "This computer doesn't start background services for your account with systemd. Start the helper yourself and keep it running: $(tilde "$BIN") run"
      fi
      ;;
  esac
}

# The Mac asks whether the helper may show its own short notices. Not waited for.
notify() {
  n_open="$(tool open)" || return 0
  step notify 95 "This Mac may ask whether Rex DUO Helper can show notifications."
  "$n_open" -g -a "$APP" --args phone-setup </dev/null >/dev/null 2>&1 3<&- || :
}

linger_state() {
  ls_out="$("$LOGINCTL" show-user "$USER_NAME" -p Linger --value 2>/dev/null)" || ls_out=""
  printf '%s' "${ls_out#Linger=}"
}

# Without lingering, systemd stops the helper when the account logs out. Turning it on may ask
# for the account's password, which is typed into this terminal and read by systemd alone.
linger() {
  [ -n "$LOGINCTL" ] || return 0
  [ "$(linger_state)" = no ] || return 0
  if [ "$LINGER" = ask ]; then
    l_ask="Keeping the helper running after you log out may need the password for $USER_NAME."
    say "$l_ask"
    record blocked linger "$l_ask" kind=auth
    # Ctrl-C at the password question skips the question, not the install.
    trap : INT
    if [ -t 3 ]; then
      # What was typed before this moment is dropped, then the terminal behaves as usual.
      if [ -n "$TTY_STATE" ]; then
        stty -icanon min 0 time 0 <&3 2>/dev/null || :
        cat <&3 >/dev/null 2>&1 || :
        stty "$TTY_STATE" <&3 2>/dev/null || :
      fi
      "$LOGINCTL" enable-linger "$USER_NAME" <&3 >/dev/null 2>&1 || :
      if [ -n "$TTY_STATE" ]; then stty -echo <&3 2>/dev/null || :; fi
    else
      "$LOGINCTL" enable-linger "$USER_NAME" </dev/null >/dev/null 2>&1 || :
    fi
    trap 'stop 130' INT
  fi
  if [ "$(linger_state)" = no ]; then
    step linger 97 "linger=off: the helper stops when you log out of this computer."
  else
    step linger 97 "linger=on: the helper keeps running after you log out."
  fi
}

main() {
  if [ $# -gt 0 ]; then MODE=app; fi
  harden
  resolve_tools
  if [ "$MODE" = app ] || [ -t 1 ]; then RECORDS=1; fi
  if [ "$MODE" = app ]; then
    check_args "$@"
    read_code
  fi
  platform
  account
  if [ "$MODE" = manual ] && [ "$OS" = Darwin ]; then manual_mac; fi
  take_lock
  make_stage
  if [ "$MODE" = app ]; then pick_asset; else read_release; fi
  look
  if [ "$PLAN" = fetch ]; then
    download
    verify
    step install 70 "Installing Rex DUO Helper $VERSION…"
    case "$OS" in
      Darwin) install_mac ;;
      *) install_linux ;;
    esac
  fi
  start
  # The new helper runs, so the app it replaced goes.
  if [ -n "$PREV_APP" ]; then
    m_prev="$PREV_APP"
    PREV_APP=""
    rm -rf "$m_prev" 2>/dev/null || :
  fi
  case "$OS" in
    Darwin) notify ;;
    *) linger ;;
  esac
  if [ "$OS" = Darwin ]; then d_where="$(tilde "$APP")"; else d_where="$(tilde "$BIN")"; fi
  d_done="Rex DUO Helper is installed and running ($d_where)."
  say "$d_done"
  record "done" "done" "$d_done"
  if [ "$MODE" = manual ]; then say "In Rex DUO on your phone, turn on Settings → Notifications."; fi
  exit 0
}

main "$@"
