# Rex DUO Helper

Sends Rex DUO push notifications for the Rex server on the same machine. Rex has no push
support of its own, so the helper connects to Rex as an ordinary client (named `rex-push-relay`,
which is what the iOS app looks for), watches every session, and sends APNs pushes when:

| Event | Category | Interruption level |
| --- | --- | --- |
| An agent becomes `blocked` (OSC 7501: question, permission, sign-in) | `AGENT_BLOCKED` | `time-sensitive`, sound |
| An agent reports `done` or `error` | `AGENT_DONE` | `passive`, no sound |
| A terminal raises a desktop notification (OSC 9 / OSC 777) | `NOTICE` | `active`, sound |

It skips a phone while Rex DUO is open on it, since the app shows its own toasts then.
Phones register through Rex itself (client actions), so the helper opens no ports. Every
machine that runs a Rex server needs its own helper.

One Rust program, `rex-duo-helper`, runs on macOS and Linux. On a Mac it ships inside
**Rex DUO Helper.app**, whose only executable is that same binary.

## Install

**Mac**

1. Unzip `Rex DUO Helper.zip` and drag **Rex DUO Helper** to Applications.
2. Open it once. A small dialog says it's on. It keeps running and starts at every login.
3. Open Rex DUO on the iPhone and turn on notifications.

Open the app again to see whether it's connected, or click **Turn Off** to stop it. Then drag the
app to the Trash to remove it. macOS lists it under System Settings > General > Login Items.

**Linux**

```sh
chmod +x rex-duo-helper-linux-x86_64     # or -aarch64
./rex-duo-helper-linux-x86_64 install
```

`install` copies itself to `~/.local/bin/rex-duo-helper`, adds a systemd user service, starts
it, turns on lingering so it survives logout (or says how, if it can't), and prints one line such
as `Rex DUO Helper 0.2.0 is running and connected to Rex at https://….` Without systemd it
says how to start it by hand. Then `rex-duo-helper status` and `rex-duo-helper uninstall`.
Logs: `journalctl --user -u rex-duo-helper`.

The same three commands work on a Mac (from
`/Applications/Rex DUO Helper.app/Contents/MacOS/rex-duo-helper`).

## How it finds Rex

Before each connection attempt, in order:

1. `REX_SERVER`, which Rex sets in its terminals (when run from a Rex shell).
2. The default socket: macOS `~/Library/Application Support/rex/server.sock`, Linux
   `$XDG_RUNTIME_DIR/rex/server.sock` (`/run/user/<uid>/rex/server.sock`). The control WebSocket
   (`rex.control.v1`) runs over it.
3. `rex --autostart=false server status --json` (never starts a server): its `endpoint`, else
   its Tailscale HTTPS URL (over TLS).

Pushes name the server by its Tailscale HTTPS URL, read from `session.bootstrap`, because that's
how Rex DUO knows it.

## Running in the background

- **Mac:** opening the app writes `~/Library/LaunchAgents/dev.abrahamgonzalez.rexduo.helper.plist`
  (runs the binary in the app with `run --log-file`, `KeepAlive` on crash, tied to the app in
  Login Items) and loads it with `launchctl`. If the app was updated, opening it restarts the
  helper. Log: `~/Library/Logs/Rex DUO Helper.log` (rotated at 1 MB).
- **Linux:** `~/.config/systemd/user/rex-duo-helper.service`, `Restart=on-failure`, `Nice=5`.
- Either way only one helper runs per user (a lock in the state folder), and it writes
  `status.json` there for `status` and the Mac dialog.
- **Upgrading from the old name** (`src/legacy.rs` lists it): on first run the helper stops the
  old service, removes its LaunchAgent or unit and its `~/.local/bin` copy, and moves its state
  folder (the registered phones in `devices.json`) to the new one. Then drag the old app to the
  Trash.

## Performance

Event driven, on one thread (tokio's current-thread runtime). While connected, nothing runs until
Rex sends something: Rex pings every 120 s and the helper answers; a local server that quits
closes the socket. The only timers are the reconnect backoff (1 s to 60 s, while Rex is down), the
30 s debounce for a block that flaps, per-request timeouts, and a 330 s silence check on remote
(HTTPS) servers. The APNs JWT is re-signed lazily when a push goes out and the token is over 50
minutes old; the HTTP/2 connection to APNs opens on the first push. Idle: about 3.5 MB of memory
and no CPU.

## Build and ship

```sh
cd Relay
cargo test                         # policy, payload, JWT, devices, parsing; under a second
cargo run -- run --dry-run         # foreground relay, logs pushes instead of sending them
./package.sh                       # Mac app (sign, notarize, staple) + Linux binaries
./package.sh --no-notarize         # sign only, for a quick local test
./package.sh --mac-only | --linux-only
```

Output in `Relay/dist/` (gitignored): `Rex DUO Helper.zip` (universal) and
`rex-duo-helper-linux-x86_64` / `-aarch64` (static musl, cross-compiled with `cargo zigbuild`;
set `ZIG=/path/to/zig` if zig isn't on PATH). The script:

- builds with `build.rs` embedding the APNs key `~/.appstoreconnect/private_keys/AuthKey_5G2D4URHAC.p8`
  (key id, team and topic too) into every binary. Override with `REX_APNS_KEY`,
  `REX_APNS_KEY_ID`, `REX_APNS_TEAM_ID`, `REX_APNS_TOPIC`; `REX_APNS_KEY=none` builds without a key.
  The key only sits in `target/` and `dist/`, both gitignored; it's never committed;
- wraps the universal Mac binary in a bundle (`LSUIElement`, bundle id
  `dev.abrahamgonzalez.rexduo.helper`, icon made from the iOS app icon by
  `Packaging/make-iconset.swift`);
- signs with `Developer ID Application: Abraham Gonzalez (R2PVQ496X7)`, hardened runtime, no
  entitlements, and notarizes with `xcrun notarytool` and the App Store Connect API key
  `2M674J7J7N` (`ASC_ISS` from `~/rexduo/.asc.env`), staples, then checks `spctl`.

**Every distributed binary contains the APNs push key**, the Mac app and the Linux files alike.
Anyone with a copy can extract it and send pushes to Rex DUO users whose device tokens they
know. That's fine for a few trusted machines and friends. If the helper is ever shared widely,
move sending to a hosted push gateway that holds the key. Revoke `5G2D4URHAC` in the developer
portal if a copy leaks.

## Commands and options

| Command | Meaning |
| --- | --- |
| `install` / `status` / `uninstall` | Run in the background, report, or stop and remove it. |
| `run` | Run in the foreground (what the service runs). |
| `check-apns` | Push to a fake token in both environments, then exit. `BadDeviceToken` means the key works. |

`run` takes `--dry-run` (log each push, headers and payload, instead of sending it;
`REX_DUO_DRY_RUN=1` works too), `--verbose` (also log working/idle reports and every "no push"
decision), `--server ADDR` (repeatable, `unix:///…` or `https://…`), `--state-dir`, `--config`,
and `--log-file`.

## Config (optional)

`config.json` in the state folder: macOS `~/Library/Application Support/Rex DUO Helper/`,
Linux `~/.local/state/rex-duo-helper/` (`$XDG_STATE_HOME`). The normal install has none.
Every field is optional.

```json
{
  "servers": ["unix:///Users/me/Library/Application%20Support/rex/server.sock"],
  "label": "rex-push-relay",
  "apns": {
    "key_path": "~/.appstoreconnect/private_keys/AuthKey_5G2D4URHAC.p8",
    "key_id": "5G2D4URHAC",
    "team_id": "R2PVQ496X7",
    "topic": "dev.abrahamgonzalez.rexduo"
  },
  "debounce_seconds": 30,
  "rate_limit_burst": 10,
  "rate_limit_per_minute": 10
}
```

`servers` replaces discovery. `apns.key_path` with `key_id` replaces the built-in key. The JWT
(ES256, `ring`) is reused for 50 minutes, then re-signed.

`devices.json` in the same folder holds the registered phones. A device whose token APNs rejects with `410 Unregistered` or `BadDeviceToken` is removed.

The first time a phone registers, the computer shows one desktop notification: "Rex DUO
connected", "<device name> can now open your sessions on this computer." It shows once per
`device_id`, ever: `seen_devices.json` in the same folder keeps every id that has registered, so
a new token, a reconnect, a helper restart or an unregister followed by a register shows nothing.
Phones already in `devices.json` when the helper is upgraded count as seen, and a registration
without a `device_id` shows nothing. On a Mac the notification goes through `osascript`; on
Linux through `notify-send`, and only if it is installed and a desktop session is there
(otherwise the helper logs a line and carries on). `--dry-run` logs `DRY-RUN notice` instead.

## What the app must do

### 1. Put a device id in the Rex client label

Pick a stable per-install id of 8 lowercase hex characters, e.g. the first 8 hex digits of
`identifierForVendor`. End the `label` in the hello with ` #<device_id>`:

```json
{"type": "hello", "api_revision": 14,
 "client": {"kind": "app", "platform": "ios", "name": "Rex DUO", "version": "1.0",
            "label": "Abe's iPhone #a1b2c3d4"}}
```

Rex caps labels at 64 bytes, so shorten the device name, never the suffix.

### 2. Find the relay

Call `client.list` with no arguments. The relay is the client whose `info.name` is
`rex-push-relay` and whose `connection_state` isn't `lost`. If there are several, use the last one
(clients are listed in connection order).

Don't rely on `target.resolve` with the label: a relay that just restarted can linger for 60 s as
`lost` under the same label, which makes the lookup ambiguous. If no relay is connected, skip
registration quietly and try again on the next connect.

### 3. Register

```json
{"type": "request", "id": "7", "method": "client.perform", "payload": {
  "client_id": "client:<relay id>",
  "action": "register_push",
  "args": {"token": "<APNs token, hex>", "environment": "sandbox",
           "device_name": "Abe's iPhone", "device_id": "a1b2c3d4"},
  "timeout_ms": 5000}}
```

- `token` (required): the APNs device token as hex.
- `environment` (required): `sandbox` for Xcode debug builds, `production` for TestFlight and the
  App Store. It must match the `aps-environment` entitlement of the build.
- `device_name`: shown in the relay's log.
- `device_id`: the id from step 1. Without it, the relay falls back to matching the phone's
  Tailscale device name, which is less exact.

Result: `{"result": {"registered": true, "devices": 1, "push_enabled": true, "relay_version": "0.2.0"}, "performed_by": "client:<relay id>"}`.
`push_enabled` is false while the relay has no APNs key or runs with `--dry-run`.

Errors arrive as normal `client.perform` errors: `bad_request` for a malformed token, environment,
or device id; `not_found` or `client_unavailable` if the relay left; `timeout` if it didn't answer.

Registering is idempotent. Send it after every successful connect once the app has a token, and
again whenever APNs hands the app a new token. A new token with the same `device_id` replaces
the old entry.

### 4. Report background and foreground

When iOS suspends the app, its WebSocket isn't closed. Rex keeps the client `connected` for
several minutes until its keepalive pings fail, and the relay would keep skipping pushes. So:

- On `scenePhase == .background`, inside `beginBackgroundTask`, call
  `client.perform` with `action: "push_presence"` and `args: {"active": false}`.
- On `scenePhase == .active`, send `{"active": true}`.

The relay keys this on the calling client's id, which Rex fills in and can't be faked. A
reconnect with a new client id counts as foreground. Closing the control socket on background
works too: the client then leaves at once.

### 5. Unregister

When the user turns notifications off: `action: "unregister_push"`, `args: {"token": "<hex>"}`.
Result `{"removed": true|false}`.

### 6. Handle the push

```json
{
  "aps": {
    "alert": {"title": "Claude · api", "subtitle": "work", "body": "Which database should I use?"},
    "interruption-level": "time-sensitive",
    "sound": "default",
    "thread-id": "block:<uuid>",
    "category": "AGENT_BLOCKED"
  },
  "server": "https://macbook-pro-rex.tail8657d0.ts.net",
  "session_id": "session:<uuid>",
  "window_id": "window:<uuid>",
  "block_id": "block:<uuid>"
}
```

- `server` is the server's Tailscale HTTPS URL, as entered in the app's server list.
- `window_id` is left out when the block isn't in a window.
- Title is `<agent> · <tab>`, subtitle is the session when it differs from the tab.
- `apns-collapse-id` is set for agent pushes, so a later state of the same block replaces the
  earlier notification.
- The time-sensitive level needs the Time Sensitive Notifications capability in the app.
- Categories `AGENT_BLOCKED`, `AGENT_DONE`, and `NOTICE` exist so the app can register actions.

## Debounce and rate limits

- **Blocked:** pushed when a record enters `blocked`, or reports a new message while blocked.
  At most one push per block per 30 s. A block that flaps (blocked, working, blocked) inside the
  window gets one trailing push when the window ends, and only if it's still blocked then.
- **Done / error:** pushed on entering the state, once per block and state per 30 s.
- **Notifications:** identical title and body from the same block within 30 s are dropped.
- **Rate limit:** per device, a burst of 10, then 10 per minute.
- Re-reports of an unchanged state never push.

## Verify by hand

Stop the background helper (only one runs per user), run a dry run in the foreground, and drive a
throwaway session from another terminal:

```sh
# Mac: launchctl kill TERM gui/$(id -u)/dev.abrahamgonzalez.rexduo.helper
# Linux: systemctl --user stop rex-duo-helper
rex-duo-helper run --dry-run
rex new zz-push-test -- sh -c 'sleep 2
  printf "\033]7501;state=blocked:app=claude:msg=%s\033\\\\" "$(printf "Ready?" | base64)"
  printf "\033]9;Build finished\a"; sleep 30'
rex kill zz-push-test
# Mac: launchctl kickstart gui/$(id -u)/dev.abrahamgonzalez.rexduo.helper
# Linux: systemctl --user start rex-duo-helper
```

The dry run logs one `AGENT_BLOCKED` and one `NOTICE` push. `rex client list` shows the helper as
`rex-push-relay` over unix.
