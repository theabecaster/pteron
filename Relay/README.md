# rex-push-relay

A small daemon on the Mac that sends Rex Connect push notifications. Rex has no push support of
its own, so the relay connects to Rex as an ordinary client, watches every session, and sends
APNs pushes when:

| Event | Category | Interruption level |
| --- | --- | --- |
| An agent becomes `blocked` (OSC 7501: question, permission, sign-in) | `AGENT_BLOCKED` | `time-sensitive`, sound |
| An agent reports `done` or `error` | `AGENT_DONE` | `passive`, no sound |
| A terminal raises a desktop notification (OSC 9 / OSC 777) | `NOTICE` | `active`, sound |

It skips a phone while Rex Connect is open on it, since the app shows its own toasts then.
Device tokens reach the relay through Rex itself (client actions), so it opens no ports.

macOS 15+, Swift 6 toolchain, no dependencies. The protocol code (`RexConnection.swift`) is
deliberately small and will move into a shared `RexKit` package later.

## Run

```sh
swift run rex-push-relay --dry-run          # print pushes instead of sending them
swift run rex-push-relay --check-apns       # verify the APNs key with Apple
swift test
```

| Option | Meaning |
| --- | --- |
| `--dry-run` | Print each push (headers and payload) instead of sending it. |
| `--server URL` | Rex server to watch. Repeatable. Overrides `servers` in the config. |
| `--state-dir DIR` | Where `config.json` and `devices.json` live. Default `~/Library/Application Support/rex-push-relay`. |
| `--config FILE` | Config file. Default `<state-dir>/config.json`. |
| `--check-apns` | Push to a fake token in both environments. `BadDeviceToken` means the key works. |
| `--verbose` | Also log working/idle reports and every "no push" decision. |

The relay reconnects to Rex forever, with backoff from 1 s to 60 s.

## Install

```sh
Relay/install.sh            # build, install, write config.json if missing, load the LaunchAgent
Relay/install.sh --no-load  # same, without touching launchd
```

- Binary: `~/Library/Application Support/rex-push-relay/bin/rex-push-relay`
- LaunchAgent: `~/Library/LaunchAgents/dev.abrahamgonzalez.rex-push-relay.plist` (KeepAlive)
- Log: `~/Library/Logs/rex-push-relay.log`
- Uninstall: `launchctl bootout gui/$(id -u)/dev.abrahamgonzalez.rex-push-relay`, then delete the plist.

## Config

`~/Library/Application Support/rex-push-relay/config.json`. Every field is optional.

```json
{
  "servers": ["https://macbook-pro-rex.tail8657d0.ts.net"],
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

Without `apns.key_path` and `apns.key_id`, the relay still runs and logs once an hour that pushes
are disabled. The JWT (ES256, CryptoKit) is reused for 50 minutes, then re-signed.

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
rex new zz-push-test -- sh -c 'sleep 2
  printf "\033]7501;state=blocked:app=claude:msg=%s\033\\\\" "$(printf "Ready?" | base64)"
  printf "\033]9;Build finished\a"; sleep 30'
rex kill zz-push-test
```

With `--dry-run`, the relay prints one `AGENT_BLOCKED` and one `NOTICE` push.
