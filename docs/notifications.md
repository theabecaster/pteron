# Notifications

Two paths, one per app state.

## While the app runs: toasts, no system notifications

`ServerConnection` watches block events. A program status record turning `blocked` posts an
`AgentAlert` ("<Agent> needs permission / has a question / needs a password / is waiting for you")
to `AgentNotifier` (one instance, shared by all servers), which also plays a warning haptic at most
once every 3 s (`AgentNotifier.hapticInterval`). Both are always on; iOS's System Haptics setting
mutes the haptic. Desktop notifications (OSC 9 / 777) show nothing in the app.

`Features/Notifications` turns alerts into a toast. `.agentToasts()` is applied once, in
`RexDuoApp`. The rules are in `ToastPolicy` (tested):

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
- On, but a connected server has no helper: a row per server with **Install** (below). A
  computer that belongs to someone else says to ask its owner instead. It clears by itself when
  the helper connects (`client_joined`).
- A helper in `--dry-run`: "running in test mode". A helper from before the gateway, or one
  without `helper_identity`: "too old for this version of Rex DUO".
- A helper whose key differs from the pinned one: "Rex DUO Helper on <name> changed. Only trust it
  if you reinstalled the helper there." with a "Trust" button. Until then it gets nothing.
- A helper that failed in another way, or kept refusing after a repair: one line saying so, with
  **Repair**. The "changed" line also has **Reinstall**, and a helper that needs an update it
  can't do itself has **Repair** on its row. All three run the install below.
- Each connected helper has a row with its version, and an Update button when a newer release is
  out (`helper_status`, `update_helper`). A version below the release list's minimum reads
  "needs an update to keep working".

## While the app is closed: Rex DUO Helper

Rex has no push support, so `Relay/` builds **Rex DUO Helper**, one Rust program
(`rex-duo-helper`) for macOS and Linux that connects to the local Rex as a client named
`rex-push-relay`, watches every session and sends pushes to registered phones through the push
gateway (below). Each machine
with a Rex server runs its own. On a Mac it ships as `Rex DUO Helper.app` (bundle id
`dev.abrahamgonzalez.rexduo.helper`; open once, it runs as a LaunchAgent); on Linux
`rex-duo-helper install` sets up a systemd user service. It is event driven: no polling
while connected. It updates itself from this repository's GitHub releases (docs/helper.md).
`Relay/README.md` is the full reference: discovery, config, debounce and rate limits, updates,
and how to verify by hand.

| Event | Category | Level |
|---|---|---|
| Agent becomes `blocked` | `AGENT_BLOCKED` | time-sensitive, sound |
| Agent reports `done` or `error` | `AGENT_DONE` | passive |
| Desktop notification (OSC 9 / 777) | `NOTICE` | active, sound |

The push decisions (debounce, rate limit, skip phones that are in front) are in
`Relay/src/policy.rs` and `devices.rs`, tested with `cargo test`. The app doesn't share that
code.

## Installing the helper from the app

The app can install Rex DUO Helper on the user's own Mac or Linux computer. `State/HelperRelease.swift`,
`HelperSetup.swift` and `HelperSetupRunner.swift` hold it; `Features/HelperSetup` is the sheet.

**When it is offered** (`HelperOffer`): the server's platform is `darwin_*` or `linux_*`, no
helper is connected on the server's own machine, the server's owner and this iPhone's login are
not two different known logins, and no install for it is running. After pairing it is a page
after "added" ("Get notifications from <Name>?", Install / Skip; Skip is remembered in
`Prefs.helperOfferSkipped`). In Settings → Notifications it is the Install, Repair and Reinstall
rows.

**What runs.** Install first asks iOS for the notification permission; if iOS says no, nothing
runs on the computer. Then:

1. The phone fetches the release list (`manifest.json` and `.sig` on the `helper-latest`
   release) and each Linux build's `.sig`, at most 64 KiB each, on a session that keeps no
   cookies or cache and follows redirects only to the release hosts. It downloads no build.
2. It checks the list as the helper does (`Relay/src/update.rs`): a signature from a trusted key
   before anything is read, the fields, the expiry, and that the version is not below the newest
   one this phone accepted (Keychain) or `HelperRelease.floor`. Trusted keys are the two in
   `State/HelperKeys.swift` (the values of `Relay/update-key.pub`; a test compares them) and up
   to four `next_key`s from lists it accepted. Every asset address must equal the one the app
   builds itself. Each Linux build's signature must cover
   `rex-duo-helper|<version>|<platform>|<sha256>`.
3. It checks the server can run a command as a terminal's program: `server.version` reports
   `api_revision` 13 or later and the shell flavor's `options_schema` in `block_creator.list` has
   `command` and `shell`. Otherwise the sheet says how to install by hand.
4. It creates a session "Rex DUO Helper setup" whose one block runs
   `/bin/sh -c <setup.sh> rexduo-setup <12 arguments>` with `shell: "none"` (`SetupBlock`). The
   script is `Relay/setup.sh`, copied into the app at build time. The arguments (`SetupArgs`) are
   the mode `2`, the version, the floor, each build's hash and size, the trusted keys joined by
   `,` (the key that signed the release list first, then the other built-in and handed-over
   keys, six at most), `ask`/`skip` for the logout setting, and a reserved `-`. Each is checked
   against its pattern, and a value outside it means nothing is sent. A server at its session
   limit gets a tab in the session the app last showed instead. The app records the tab it made
   (UserDefaults) and leaves that session out of its sidebar.

**The setup code.** Each run makes a one-time code (32 random bytes as 64 hex characters,
`SetupCode`). It is in no argument, no option of the block and no log. The installer turns echo
off, reports the step `code`, and reads one line from its terminal; the app then writes the code
and a Return with `terminal.write`. It writes only while `input_mode` says echo is off and
`process` shows the block's own program in front (`foreground` is `child`, or a shell of the same
path that `child` started; `SetupCode.allows`). If that doesn't hold, or the write fails, the app
closes the tab and the sheet reads "Rex DUO can't get the helper right now". The installer hands
the code to the helper it installs.

**Progress.** The installer reports one OSC 7501 record (`id` and `app` `rexduo-setup`; `title`
is the step: `download`, `verify`, `code`, `install`, `start`, `notify`, `linger`, `done`,
`fail:<CODE>`), which moves the step list; `code` is part of Installing. Its exit code (`child_exited`, or `process.last_exit`)
decides failure; the codes and their sentences are `SetupError(exitCode:)`. `SetupState` is the
whole mapping, and it is pure.

**What decides "Connected".** Not the terminal. Three things: the installer exited with 0, the
helper showed this run's setup proof, and that helper registered. Once the installer's `start`
step is over, the app asks the helper then in `client.list` for the proof: `helper_identity` with
a `setup_challenge`, answered with `setup_proof` (HMAC-SHA256 keyed by the setup code over
`rexduo-setup-v1`, the challenge, the helper's client id and the app's, joined by `\n`). A reply
without a proof is asked again after 2 s, three requests in all (`SetupProof.requests`; the helper
answers three per code). With a valid proof the helper's key becomes the pin, also in place of a
key pinned before, so a reinstall needs no "Trust"; then the secret is minted and `register_push`
sent. A wrong proof, or none in three replies, ends the run as "Rex DUO Helper on <name>
changed": nothing is pinned, no secret is handed over, and the helper waits for "Trust" in
Settings. From the moment the code is written until the sheet closes, no other registration with
that server's helper goes out (`HelperAdmission`); pinning a key on first use happens only
outside an install. No helper within 60 s of the exit reads "installed but didn't start", with
Repair.

**What a person does.** On a Mac, a card says to click Allow on the computer; it goes when
`helper_status.notices` is no longer `undetermined`, or on Done. On Linux, when the installer
reports `blocked` / `auth`, a card asks for the account password that lets the helper keep
running after logout. The password is written to the terminal once, only while `input_mode` says
echo is off and `process.foreground.path` is `pkttyagent` or `loginctl` in `/usr/bin` or `/bin`
(`PasswordGuard`); otherwise the card says to type it on the computer. It is never stored.

**Ending.** Done destroys the setup session. After a failure it stays for "Show details" (the
app's terminal view in mirror mode, taking no touches) until Close or Try Again. Stop closes the
block, then the session. A dropped connection leaves the installer running; after the reconnect
the app reads `program_status` and `process` and goes on. After each sync the app destroys a
setup session it recorded more than an hour ago.

A helper reports when its release list expires (`manifest_expires_at`). Within 30 days of that
date the app logs it, and Debug builds show one line in Settings → Notifications.

Tests: `RexDuoTests/HelperReleaseTests.swift`, `HelperSetupTests.swift`. `-simulateHelperSetup`
(docs/debug-args.md) shows each state of the sheet with no server.

## The push gateway

A helper holds no Apple key and never sees a phone's APNs token, so it can be a public download.
`Gateway/` is a Cloudflare Worker that holds both:

1. The phone sends its APNs token and environment to the gateway (`POST /v1/devices`) and gets a
   device id and an owner key. The gateway keeps only a hash of the key.
2. For each server the phone mints one secret (`POST /v1/devices/{id}/secrets`, labelled with the
   server's name) and hands that server's helper the gateway's address and the secret
   (`register_push`). The registration, and per server the secret, its id and the helper's pinned
   key, stay in one Keychain item (`KeychainRegistrationStore`).
3. For each notification the helper posts the payload to the gateway with its secret. The gateway
   adds the APNs topic and the provider token and passes it to Apple, sandbox or production as
   the phone registered. A secret can reach one phone and nothing else.
4. A rotated APNs token is a `PUT` with the owner key; the secrets, and so every helper, are
   unaffected. Removing a server from the app deletes its secret
   (`DELETE /v1/devices/{id}/secrets/{secret_id}`). Turning notifications off deletes the
   registration (`DELETE`), which stops every helper's secret at once, also on computers that
   are off. If the gateway can't be reached, or the Keychain won't delete the item, the delete is
   retried on each launch and return to front, and nothing of the old registration is reused.
5. Every Keychain call is checked. A registration or secret that couldn't be saved is taken back
   at the gateway and never handed to a helper; Settings says the setup couldn't be saved.

Owner-key routes answer `401 unauthorized` for an unknown phone and for a wrong key alike. Only
that JSON body counts as "the gateway forgot this phone"; a 401 from anything in between is
treated as the gateway being unreachable.

The API, limits and deploy steps are in `Gateway/README.md`; `GatewayLink` (`State/PushGateway.swift`)
is the phone's side, tested in `RexDuoTests/PushGatewayTests.swift`.

## Contract between app and helper

The helper opens no ports; everything goes through Rex.

1. The app ends its client label with ` #<device_id>` (8 lowercase hex).
2. It finds the relay with `client.list`: the last client named `rex-push-relay` that isn't `lost`
   and whose `principal.kind` is `peer` or `windows_peer`, which Rex asserts for a client on the
   server's own machine. A client of that name from the tailnet is ignored.
3. It asks who the helper is: `helper_identity` with `challenge` (32 random bytes, base64url) and
   `device_id`. The reply carries `public_key`, `signature` (ed25519, both base64) and
   `client_id`. The signed message is five lines joined by `\n`: `rexduo-helper-identity-v1`, the
   challenge, the helper's client id, the app's client id, the `device_id`. The app checks the
   signature, that `client_id` is the client it called and that the fourth line is its own
   `RexControl.clientID`, so a third client can't relay the challenge to the real helper.
4. It pins the key the first time it meets a server's helper. The same key later: go on. Another
   key: hand over nothing and show the "changed" line; "Trust" deletes the old helper's secret,
   pins the key that was offered and registers with a new secret. A helper that doesn't know
   `helper_identity` counts as too old. During an install from the app the first-use pin does
   not apply: the helper is pinned only after it showed the run's setup proof ("Installing the
   helper from the app").
5. It registers with `register_push`, args `gateway` (its address), `push_secret` (that server's),
   `environment` (`sandbox` for debug builds, `production` for TestFlight), `device_name`,
   `device_id`. The reply carries `helper_version`.
   During an install from the app, after the setup proof, it adds `setup_seal`: base64 of
   HMAC-SHA256 keyed by the setup code over `rexduo-setup-register-v1`, the `push_secret` and
   the `device_id`, joined by `\n` (`SetupSeal`). No other registration carries it.
6. It reports `push_presence {active}` on background and foreground, so the helper skips phones
   that show their own notifications.
7. It unregisters with `unregister_push {device_id}` when notifications are turned off.
8. `helper_status` reports the helper's version, the newest release, whether it can update and
   `update_required`; `update_helper` starts an update and replies before the helper restarts.
9. A helper whose secret stopped working says so: `registered: false` in the `push_presence` and
   `helper_status` results, or the `secret_dropped` error from `register_push`. The app then asks
   the gateway (`GET /v1/devices/{id}`). Phone gone: it registers again, keeping the pins, and
   every server gets a new secret as it syncs. Phone still there: that server's secret is
   replaced. Then it registers with the helper again. One such repair per server per connection;
   a helper that still refuses gets a line in Settings and is left alone until the next connection.

The first `register_push` from a `device_id` the helper has never seen posts one desktop
notification on the computer, "Rex DUO connected" with the phone's name (`Relay/src/notice.rs`;
on a Mac from the app's own `rex-duo-notify`, so it shows as Rex DUO Helper and needs the
permission macOS asks for when the app is first opened; `notify-send` on Linux when it is installed). Seen ids are kept in
`seen_devices.json`, so it is once per phone, not per connect or per helper start.

Pushes carry `server` (the Tailscale URL as entered in the app), `session_id`, `window_id` and
`block_id`, so a tap can open the pane. The gateway sets the APNs topic, the bundle id
`dev.abrahamgonzalez.rexduo`.

## The app's side

`PushRegistrar` (`State/`, owned by `AppModel`) implements the contract. Its pure parts are in
`PushSupport.swift` (tested in `RexDuoTests/NotificationTests.swift`) and `HelperTrust.swift`
(`HelperIdentity`, `HelperFailure`, `SecretRepair`, `SecretLabel`; `RexDuoTests/HelperTrustTests.swift`).

- Device id: the first 8 hex digits of `identifierForVendor`. `PushIdentity.clientLabel` builds
  `"<device name> #<id>"`, shortening the name to fit Rex's 64 bytes.
- Environment: read from the build's `embedded.mobileprovision` (`aps-environment`), so a Release
  build installed with a development profile still says `sandbox`. No profile (TestFlight, App
  Store) means `production`; the simulator is always `sandbox`.
- Registration runs after each server's bootstrap. It is keyed on `ServerConnection.connectionSerial`,
  so a resync on the same connection costs nothing, and every new connection registers again.
  A new APNs token (rotation) goes to the gateway only; helpers keep their secrets. Each
  server's helper is verified and registered separately, with its own secret. While push is off and was never registered, nothing is called.
- Presence: `push_presence` false on background (inside a background task) and true on
  foreground and after each registration, since a resumed connection keeps its client id.
- Turning push off deletes the gateway registration and sends `unregister_push` now, or on the
  server's next connect if it is offline (`pushToken.servers` in UserDefaults remembers where the
  phone is registered). Nothing is unregistered before iOS has reported the permission.
- An install from before the gateway needs nothing from the user: on its next connect it
  registers with the gateway and gives an updated helper a secret. A helper that is still the
  old version refuses, and Settings says to install the new one.
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

- Simulator registration: stop the installed helper (see `Relay/README.md`, "Verify by hand"), run
  `cargo run --manifest-path Relay/Cargo.toml -- run --dry-run --verbose` and launch the app with
  push on. Simulators on Apple silicon get sandbox
  tokens; `-pushToken <hex>` (debug builds) fakes one and skips the permission check, and
  `-pushGateway <url>` registers with another gateway.
- Push taps: `xcrun simctl push <sim> dev.abrahamgonzalez.rexduo payload.json` with the payload
  above, app in the background or not running, then tap the banner.
- Toasts: a throwaway `zz-` session printing OSC 7501 `blocked` (see `Relay/README.md`,
  "Verify by hand").
