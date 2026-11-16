# Notifications

Two paths, one per app state.

## While the app runs: toasts, no system notifications

`ServerConnection` watches block events. A program status record turning `blocked` posts an
`AgentAlert` ("<Agent> needs permission / has a question / needs a password / is waiting for you")
to `AgentNotifier` (one instance, shared by all servers), which also plays a warning haptic at most
once every 3 s (`AgentNotifier.hapticInterval`). Both are always on; iOS's System Haptics setting
mutes the haptic. Desktop notifications (OSC 9 / 777) show nothing in the app.

`Features/Notifications` turns alerts into a toast. `.agentToasts()` is applied once, in
`RexConnectApp`. The rules are in `ToastPolicy` (tested):

- Only while the app is active, and only for a pane that isn't on screen. `ScreenInspector` reads
  the visible panes from UIKit (`TerminalHost` views at least half inside the key window), so the
  tab and sidebar views don't report anything.
- One toast at a time. A new alert updates the toast on screen ("2 more agents are waiting").
- A sheet, cover or alert holds the toast until it closes (dropped after 2 minutes or once the
  agent stops waiting). The same pane toasts at most once per 30 s.
- It fades after 6 s and can be swiped up. A tap opens the pane (`AppModel.openPane`).

`NotificationDelegate` (in `App/AppDelegate.swift`) shows no banners while the app is in front.

## Permission

The app never asks at launch. `NotificationPromptCard` ("Get notified when an agent needs you",
Turn On / Not now) shows once: in the toast slot about 2.5 s after a server is connected and has
agents, and at the top of the Agents view. Turn On asks iOS (first time only) and registers; Not
now or a swipe hides it for good (`Prefs.pushPromptDismissed`). Settings → Notifications always
has the toggle:

- Denied in iOS: the toggle is disabled, with a line and an "Open Settings" button.
- Provisional: a line that notifications arrive quietly, with "Open Settings". Provisional and
  ephemeral both count as allowed, so the app registers.
- On, but a connected server has no helper: "Mac helper isn't running" and three steps. It clears
  by itself when the helper connects (`client_joined`).
- A helper in `--dry-run` or without a key: "running in test mode".

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

## The app's side

`PushRegistrar` (`State/`, owned by `AppModel`) implements the contract; `PushSupport.swift` holds
its pure parts, tested in `RexConnectTests/NotificationTests.swift`.

- Device id: the first 8 hex digits of `identifierForVendor`. `PushIdentity.clientLabel` builds
  `"<device name> #<id>"`, shortening the name to fit Rex's 64 bytes.
- Environment: read from the build's `embedded.mobileprovision` (`aps-environment`), so a Release
  build installed with a development profile still says `sandbox`. No profile (TestFlight, App
  Store) means `production`; the simulator is always `sandbox`.
- Registration runs after each server's bootstrap. It is keyed on `ServerConnection.connectionSerial`,
  so a resync on the same connection costs nothing, and every new connection registers again.
  A new APNs token (rotation) re-registers everywhere. Each server's helper is registered
  separately. While push is off and was never registered, nothing is called.
- Presence: `push_presence` false on background (inside a background task) and true on
  foreground and after each registration, since a resumed connection keeps its client id.
- Turning push off sends `unregister_push` now, or on the server's next connect if it is offline
  (`pushToken.servers` in UserDefaults remembers where the phone is registered).
- `project.yml` gives the app `aps-environment` (development; export for App Store Connect switches
  it to production) and `com.apple.developer.usernotifications.time-sensitive`.

### Tapping a push

`AppDelegate` sets the notification delegate in `didFinishLaunching`, so it also gets the tap that
cold-launched the app; the route waits there until the app attaches its model.
`PushRoute(userInfo:)` reads `server`, `session_id`, `window_id`, `block_id`. `AppModel.open(_:)`
finds the server by host (as entered, or the Tailscale name it reports), waits up to 30 s for the
session to load, focuses the pane and sets `openRequest`; `RootView` shows that tab, and the toast
modifier closes any sheet. The three categories are registered without actions; iOS groups by the
payload's `thread-id`.

### Testing

- Simulator registration: run the helper with `swift run --package-path Relay rex-push-relay
  --dry-run --verbose` and launch the app with push on. Simulators on Apple silicon get sandbox
  tokens; `-pushToken <hex>` (debug builds) fakes one and skips the permission check.
- Push taps: `xcrun simctl push <sim> dev.abrahamgonzalez.rexduo payload.json` with the payload
  above, app in the background or not running, then tap the banner.
- Toasts: a throwaway `zz-` session printing OSC 7501 `blocked` (see `Relay/README.md`,
  "Verify by hand").
