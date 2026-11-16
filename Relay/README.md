# Rex Connect Helper

A small background app for the Mac that sends Rex Connect push notifications. Rex has no push
support of its own, so the helper connects to Rex as an ordinary client (named `rex-push-relay`,
which is what the iOS app looks for), watches every session, and sends APNs pushes when:

| Event | Category | Interruption level |
| --- | --- | --- |
| An agent becomes `blocked` (OSC 7501: question, permission, sign-in) | `AGENT_BLOCKED` | `time-sensitive`, sound |
| An agent reports `done` or `error` | `AGENT_DONE` | `passive`, no sound |
| A terminal raises a desktop notification (OSC 9 / OSC 777) | `NOTICE` | `active`, sound |

It skips a phone while Rex Connect is open on it, since the app shows its own toasts then.
Device tokens reach the relay through Rex itself (client actions), so it opens no ports.

macOS 14+, no third-party dependencies. JSON helpers and `RexError` come from the repo's local
`Packages/RexKit`, shared with the iOS app. The connection code (`RexConnection.swift`,
`WebSocket.swift`) stays here: it speaks the control protocol over Rex's Unix socket with
Network.framework, which the app's `URLSession` client can't do.

## Install (for a friend)

1. Unzip `Rex Connect Helper.zip` and drag **Rex Connect Helper** to Applications.
2. Open it once. A small window says it's running. It adds itself to Open at login.
3. Open Rex Connect on the iPhone and turn on notifications.

That's all: no config file, no Terminal. The app has no Dock or menu bar icon. Open it again to
see the window, change **Open at login**, or **Quit**. To remove it, turn Open at login off,
quit, and delete the app. macOS lists it under System Settings > General > Login Items.

## How it finds Rex

Before each connection attempt, in order:

1. `REX_SERVER`, which Rex sets in its terminals (when run from a Rex shell).
2. The local socket `~/Library/Application Support/rex/server.sock`. The control WebSocket
   (`rex.control.v1`) runs over it via `Network.framework`, with a small RFC 6455 client in
   `WebSocket.swift`, since `URLSession` can't use Unix sockets.
3. `rex --autostart=false server status --json` (never starts a server): its `endpoint`, else
   its Tailscale HTTPS URL.

Pushes name the server by its Tailscale HTTPS URL, read from `session.bootstrap`, because that's
how Rex Connect knows it.

## Performance

Event driven. While connected, nothing runs until Rex sends something: Rex pings every 120 s and
the helper answers; a local server that quits closes the socket. The only timers are the
reconnect backoff (1 s to 60 s, while Rex is down), the 30 s debounce for a block that flaps,
and per-request timeouts. The APNs JWT is re-signed lazily when a push goes out and the token is
over 50 minutes old. The window is plain AppKit and is freed when it closes.

## Build and ship

```sh
Relay/package.sh                # build universal, sign, notarize, staple, zip
Relay/package.sh --no-notarize  # sign only, for a quick local test
```

Output: `Relay/dist/Rex Connect Helper.zip` (gitignored). The script:

- builds `RexConnectHelper` for arm64 and x86_64 and wraps it in a bundle (`LSUIElement`,
  bundle id `dev.abrahamgonzalez.rexconnect.helper`, icon made from the iOS app icon);
- copies the APNs key `~/.appstoreconnect/private_keys/AuthKey_5G2D4URHAC.p8` into the bundle
  as `Contents/Resources/AuthKey.p8`. The key id, team and topic go in `Info.plist`. The key
  only ever sits in `Relay/.stage` (gitignored, deleted on exit) and the zip; it's never
  committed;
- signs with `Developer ID Application: Abraham Gonzalez (R2PVQ496X7)`, hardened runtime, no
  entitlements (no sandbox, so it can reach the socket and run `rex`);
- notarizes with `xcrun notarytool` and the App Store Connect API key `2M674J7J7N`
  (`ASC_ISS` from `~/rexduo/.asc.env`), staples, then checks `stapler validate` and `spctl`.

**The distributed app contains the APNs push key.** Anyone with the app can extract it and send
pushes to Rex Connect users whose device tokens they know. That's fine for a few trusted
friends. If the helper is ever shared widely, move sending to a hosted push gateway that holds
the key, and have the helper forward events to it. Revoke `5G2D4URHAC` in the developer portal if
a copy leaks.

## Run from source

```sh
swift run rex-push-relay --dry-run   # command-line relay, logs pushes instead of sending them
swift test
```

The app takes the same switches as launch arguments, e.g.
`open "/Applications/Rex Connect Helper.app" --args --dry-run`:

| Option | Meaning |
| --- | --- |
| `--dry-run` | Log each push (headers and payload) instead of sending it. `REX_CONNECT_DRY_RUN=1` works too. |
| `--verbose` | Also log working/idle reports and every "no push" decision. |
| `--check-apns` | Push to a fake token in both environments, then quit. `BadDeviceToken` means the key works. |
| `--unregister` | Remove the login item, then quit. |
| `--no-window` | Don't show the window on this launch. |

The command-line `rex-push-relay` also takes `--server ADDR` (repeatable, `unix:///…` or
`https://…`), `--state-dir`, and `--config`; it reads the APNs key from the config.

Logs go to the unified log:

```sh
log stream --predicate 'subsystem == "dev.abrahamgonzalez.rexconnect.helper"'
```

## Config (optional)

`~/Library/Application Support/Rex Connect Helper/config.json`. The normal install has none.
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

`servers` replaces discovery. The app ignores `apns.key_path` and `key_id` (it uses its bundled
key) but honors `apns.topic`. The JWT (ES256, CryptoKit) is reused for 50 minutes, then re-signed.

`devices.json` holds the registered phones. A device whose token APNs rejects with
`410 Unregistered` or `BadDeviceToken` is removed.

## What the app must do

### 1. Put a device id in the Rex client label

Pick a stable per-install id of 8 lowercase hex characters, e.g. the first 8 hex digits of
`identifierForVendor`. End the `label` in the hello with ` #<device_id>`:

```json
{"type": "hello", "api_revision": 14,
 "client": {"kind": "app", "platform": "ios", "name": "Rex Connect", "version": "1.0",
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

Result: `{"result": {"registered": true, "devices": 1, "push_enabled": true, "relay_version": "0.1.0"}, "performed_by": "client:<relay id>"}`.
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

```sh
open "/Applications/Rex Connect Helper.app" --args --dry-run
rex new zz-push-test -- sh -c 'sleep 2
  printf "\033]7501;state=blocked:app=claude:msg=%s\033\\\\" "$(printf "Ready?" | base64)"
  printf "\033]9;Build finished\a"; sleep 30'
rex kill zz-push-test
```

With `--dry-run`, the helper logs one `AGENT_BLOCKED` and one `NOTICE` push (see the `log stream`
command above). `rex client list` shows it as `rex-push-relay`, over unix.
