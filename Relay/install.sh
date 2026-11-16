#!/bin/bash
# Builds rex-push-relay and installs it as a LaunchAgent for the current user.
#
#   Relay/install.sh            build, install, write config if missing, (re)load the agent
#   Relay/install.sh --no-load  same, but don't touch launchd
#
# Uninstall:
#   launchctl bootout gui/$(id -u)/dev.abrahamgonzalez.rex-push-relay
#   rm ~/Library/LaunchAgents/dev.abrahamgonzalez.rex-push-relay.plist
set -euo pipefail

LABEL="dev.abrahamgonzalez.rex-push-relay"
APP_DIR="$HOME/Library/Application Support/rex-push-relay"
BIN_DIR="$APP_DIR/bin"
BIN="$BIN_DIR/rex-push-relay"
CONFIG="$APP_DIR/config.json"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/rex-push-relay.log"
KEY_ID="5G2D4URHAC"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8"

LOAD=1
[[ "${1:-}" == "--no-load" ]] && LOAD=0

PKG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Building release binary"
swift build -c release --package-path "$PKG_DIR"
mkdir -p "$BIN_DIR" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
install -m 0755 "$(swift build -c release --package-path "$PKG_DIR" --show-bin-path)/rex-push-relay" "$BIN"
echo "    installed $BIN"

if [[ ! -f "$CONFIG" ]]; then
  echo "==> Writing default $CONFIG"
  cat > "$CONFIG" <<EOF
{
  "servers": ["https://macbook-pro-rex.tail8657d0.ts.net"],
  "apns": {
    "key_path": "$KEY_PATH",
    "key_id": "$KEY_ID",
    "team_id": "R2PVQ496X7",
    "topic": "dev.abrahamgonzalez.rexduo"
  },
  "debounce_seconds": 30,
  "rate_limit_burst": 10,
  "rate_limit_per_minute": 10
}
EOF
  chmod 600 "$CONFIG"
else
  echo "==> Keeping existing $CONFIG"
fi
[[ -f "$KEY_PATH" ]] || echo "    warning: APNs key $KEY_PATH not found; pushes stay disabled until it exists"

echo "==> Writing $PLIST"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>10</integer>
  <key>StandardOutPath</key>
  <string>$LOG</string>
  <key>StandardErrorPath</key>
  <string>$LOG</string>
</dict>
</plist>
EOF
plutil -lint "$PLIST" >/dev/null

echo "==> Checking the APNs key against Apple"
"$BIN" --check-apns || echo "    warning: APNs check failed; see above"

if [[ $LOAD == 1 ]]; then
  echo "==> (Re)loading $LABEL"
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "    running. Logs: tail -f \"$LOG\""
else
  echo "==> Not loaded. To start it: launchctl bootstrap gui/\$(id -u) \"$PLIST\""
fi
