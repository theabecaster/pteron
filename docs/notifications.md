# Notifications

Two paths, one per app state.

## While the app runs: local notifications

`ServerConnection` watches block events and hands them to `AgentNotifier` (one instance, shared by
all servers):

- A program status record turning `blocked` posts "<Agent> needs permission / has a question /
  needs a password / is waiting for you" when Settings → "Notify when an agent is waiting" is on, and plays a
  warning haptic at most once every 3 s (`AgentNotifier.hapticInterval`), however many agents block.
- A terminal's desktop notification (OSC 9 / OSC 777, `desktop_notification`) posts as is.
- Permission is requested once per launch, on the first notification. `NotificationDelegate` shows
  banners while the app is in front.

## While the app is closed: Rex Connect Helper

Rex has no push support, so `Relay/` builds **Rex Connect Helper**, a background Mac app
(bundle id `dev.abrahamgonzalez.rexconnect.helper`) that connects to the local Rex as a client
named `rex-push-relay`, watches every session and sends APNs pushes to registered phones.
It is event driven: no polling while connected. `Relay/README.md` is the full reference: install,
discovery, config, debounce and rate limits, and how to verify by hand.

| Event | Category | Level |
|---|---|---|
| Agent becomes `blocked` | `AGENT_BLOCKED` | time-sensitive, sound |
| Agent reports `done` or `error` | `AGENT_DONE` | passive |
| Desktop notification (OSC 9 / 777) | `NOTICE` | active, sound |

The push decisions (debounce, rate limit, skip phones that are in front) are in
`Relay/Sources/RelayCore/Policy.swift` and tested in `Relay/Tests`. The app doesn't share that
code.

## Contract between app and helper

The helper opens no ports; everything goes through Rex.

1. The app ends its client label with ` #<device_id>` (8 lowercase hex).
2. It finds the relay with `client.list`: the last client named `rex-push-relay` that isn't `lost`.
3. It registers with `client.perform`, action `register_push`, args `token` (hex), `environment`
   (`sandbox` for debug builds, `production` for TestFlight), `device_name`, `device_id`.
4. It reports `push_presence {active}` on background and foreground, so the helper skips phones
   that show their own notifications.
5. It unregisters with `unregister_push {token}` when notifications are turned off.

Pushes carry `server` (the Tailscale URL as entered in the app), `session_id`, `window_id` and
`block_id`, so a tap can open the pane. The APNs topic is the bundle id,
`dev.abrahamgonzalez.rexduo`.

Status: the helper side is built and tested. The app does not yet send the device id, register,
or report presence; that work follows the contract above (details in `Relay/README.md`,
"What the app must do").
