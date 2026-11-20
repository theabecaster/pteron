# Notifications

Two paths, one per app state.

## While the app runs: toasts, no system notifications

`ServerConnection` watches block events. A program status record turning `blocked` posts an
`AgentAlert` ("<Agent> needs permission / has a question / needs a password / is waiting for you")
to `AgentNotifier` (one instance, shared by all servers), which also plays a warning haptic at most
once every 3 s (`AgentNotifier.hapticInterval`). Both are always on; iOS's System Haptics setting
mutes the haptic.

A desktop notification (OSC 9 / 777, the terminal's `desktop_notification` block event) becomes a
notice: `ServerConnection.receiveNotice` waits 1 s, so an agent status sent right after it still
counts, then drops it if the pane runs an agent (by its status app, foreground or title), has any
OSC 7501 record, or lost one less than 10 s ago (`NoticeFilter`): agents already alert through
their status. It also drops an empty one, one whose body starts with `4;` (an older server passing
an OSC 9;4 progress report through), and one whose connection changed during the wait. Else it
posts an `AgentAlert` of kind `.notice` (`AgentNotifier.postNotice`): the program's title, or the
tab's name for OSC 9, and "session › tab — text", cleaned of control characters and direction
overrides (`AlertCopy`), so a program can't pose as the app. No haptic. Only servers whose
terminal creator lists the event get notices (Compatibility in [rex-protocol.md](rex-protocol.md)).

`Features/Notifications` turns alerts into a toast. `.agentToasts()` is applied once, in
`RexDuoApp`. The rules are in `ToastPolicy` (tested):

- Only while the app is active, and only for a pane that isn't on screen. `VisiblePanes` reads
  the visible panes from UIKit (`TerminalHost` views at least half inside the key window), so the
  tab and sidebar views don't report anything; the Waiting pill asks it too.
- One toast at a time. A new alert updates the toast on screen ("2 more agents are waiting").
- A sheet, cover or alert holds the toast until it closes (dropped after 2 minutes or once the
  agent stops waiting). The same pane toasts at most once per 30 s.
- No toast while the agent board shows (tent mode, [duo-layout.md](duo-layout.md)): it lists
  every waiting agent itself. A toast already up goes when the board comes.
- It fades after 6 s and can be swiped up. A tap opens the pane (`AppModel.openPane`).

Waiting agents keep exactly that sequence: they read `AgentNotifier.latest`, so posts in one
main-actor turn collapse to the newest, and nothing queues behind them (`WaitingSequenceTests`
plays main's logic against `ToastState`). Notices have their own rules (`ToastState`,
`ToastPolicy.decideNotice`):

- A pane that floods is held back before the 1 s wait: the same text from it within 30 s is
  dropped, and at most 5 of its notices wait at once. The notifier queues them, at most 5 per
  pane (that pane's oldest goes) and 50 in all (the oldest of the busiest pane goes), so a noisy
  pane never pushes out another's. The toast drains the queue on each change, so every notice
  of a turn is decided, in order.
- A waiting agent outranks a notice: it replaces a notice toast, and a notice never updates or
  replaces a toast. A notice that can't show now (a toast is up, less than 10 s since the last
  notice toast, or its pane toasted a notice less than 30 s ago) waits in one slot, newest per
  pane, never dropped. When it may, the slot shows as one toast that counts the rest ("2 more
  notifications"), after held waiting alerts.
- A sheet or the agent board holds notices per pane, with no age limit; a notice toast up when
  the board comes goes back to the hold. They show as one toast once both are gone. Waiting
  alerts are still dropped on the board, which lists them.
- A notice for a pane on screen, when posted or when it would show, is dropped: the user is
  looking at it. So is the same text from the same pane within 30 s, and any notice in the first
  2 s after the app comes to the front (what came while it was away was the helper's to push).
- The toast: a bell in the secondary color, the same size, place, motion, swipe and tap.

`NotificationDelegate` (in `App/AppDelegate.swift`) shows no banners while the app is in front,
except the one "Send Test Notification" asks for (thread id `rexduo-test`, `PushTest`).

## The screen: Settings → Notifications

One master switch, "Notifications", in a group of its own with its line and the section's
footer. Under it, while the switch is on, the group "Computers": one cell per computer, with
its name as the cell's title, a switch, and directly under the name one status line, with its button, when it has one, under that. This section is the only place
that shows a computer's Beacon: its version, its state, its one button and its menu. In the
app's words the program on the computer is "Pteron Beacon" where a screen first names it and
"Beacon" after that, which is also the name it has on the computer (the Mac's prompts, Login
Items, `Pteron Beacon.app`). The code, the actions and this document's prose call it the
helper, and its command-line program keeps the file name `rex-duo-helper`, which the app shows
only inside the command to run. A test reads every sentence of the feature for the name
(`noSentenceCallsTheProgramAnAddOnOrAHelper`).

`State/NotificationStatus.swift` is the whole mapping: plain facts in (`MasterFacts`,
`ComputerFacts`), a row out (`MasterStatus`, `ComputerStatus`: `switchOn`, `switchEnabled`,
`line` with its text, tint and spinner, `fix`, `menu`). Every word on the screen is in that
file. `PushRegistrar` gathers the facts (`master`, `computers`, `status(for:)`) from what
`PushReconciler` found (below, "Signing the phone up") and performs
the actions (`setMaster`, `setComputer`, `fix`, `sendTest`, `details`, `showSetupDetails`,
`removeConfirm`, `removeHelper`, `cancel`, `reinstall`). `Features/Settings/NotificationSettings.swift`
only lays the rows out and holds what is up over them: a confirm, the details sheet, the manual
steps.

Rules:

1. The switch is the user's choice; the line under it is what is true. A switch never moves by
   itself, with two exceptions: the master switch shows off while iOS has notifications turned
   off, and a computer with no helper shows off until an install starts.
2. A computer where all is well shows Beacon's version and nothing after it. A problem is
   one short line in the warning tint (`chrome.blocked`, the colour of an agent that needs the
   person) and at most one button, the fix. Something the app is doing by itself is a spinner
   and a plain line. Information is a line in the secondary tint.
3. Everything else is in the row's menu, opened with a long press or the `…` button, which
   shows only when the menu has items. Items that cannot work in a state are left out.
4. The app never asks at launch. The master switch asks iOS the first time it is turned on.
5. A computer's cell with no line is as tall as any single-line cell of Settings: the name and
   the switch. One with a line is taller by that line, and one with a button taller again by
   the button, which sits on a line of its own under the words at the leading edge, never
   beside the switch, with a 44 pt touch target. Nothing truncates: a long name and a long line
   wrap as far as they need, and the `…` button and the switch stay by the name's first line.
   A spinner follows the words, so they start under the name. The name, the switch and the
   line sit at the same place in the cell whatever is under them; only the bottom edge moves.
6. A switch pauses and resumes. It never deletes anything: not the phone's registration, not a
   computer's secret, not a helper's key.

### Master switch

| State | Switch | Line | Button |
|---|---|---|---|
| Off (the user's choice) | off | none | none |
| iOS not asked yet | off | none | none; turning it on shows the iOS prompt |
| On, iOS allows | on | none | none |
| On, iOS delivers quietly (provisional, or banners and sounds both off) | on | "Notifications arrive quietly" (secondary) | Open Settings |
| iOS turned off | off; a tap opens iOS Settings and the switch stays off | "Turned off in iOS Settings" | Open Settings |
| iOS gave this phone no notification address | on | "Can't reach Apple's notification service" with a spinner | none; the app asks again every 30 s |

The computers' group shows only while the switch is on. Footer, under the switch's own group:
"Get notified when an agent finishes or needs you. Each computer needs Pteron Beacon to send
notifications." The
permission is read at start and every time the app becomes active, so coming back from iOS
Settings with notifications allowed turns everything on again with no tap. The master choice
(`Prefs.pushEnabled`) and each computer's choice (`Prefs.notificationsOff`; a server that is not
in it is on) are kept while iOS has notifications off and while the master switch is off. So
are the phone's registration, each computer's secret and each helper's pinned key (below,
"Signing the phone up").

### A computer's row

| State | Switch | Status line | Fix | Menu |
|---|---|---|---|---|
| Healthy: Beacon is the latest version or newer, or the app has no release list to compare it with | on | "Version <version>" (secondary) | none | Send Test Notification, Show Details, Reinstall Beacon, Remove Beacon… |
| Beacon is older than the latest version | on | "Update available" (secondary) | Update | as healthy |
| On and reachable, and Beacon has not taken this phone on this connection yet or has not said its version | on | spinner + "Connecting…" | none | Show Details, Reinstall Beacon, Remove Beacon… |
| Off by the user | off | none | none | Show Details, Remove Beacon… |
| Offline | as chosen | "Offline" (secondary) | none | none |
| Turned off while it could not be reached, until its Beacon has heard | off | "Turns off when it's back" (secondary) | none | none |
| Beacon not installed | off | none | none | none |
| Not installed, and the computer's Rex can't run the installer (or the computer is someone else's) | on | "Install Beacon by hand" | How | Show Details |
| Setting up | on | spinner + "Downloading…", "Checking…", "Installing…", "Starting…", "Connecting…" | none | Show Details, Cancel Install |
| Setting up, waiting for the person | on | "Waiting for you" | Continue | Show Details, Cancel Install |
| Setup failed | on | "Couldn't download Beacon", "The download didn't pass its check", "No room for Beacon", "Didn't let Beacon install" or "Beacon didn't start" | Retry | Show Details, Remove Beacon… |
| Beacon too old: below the oldest version the release list allows (`min_version`), or too old to take the registration and say its version | on | "Beacon needs an update" | Update | Reinstall Beacon, Remove Beacon… |
| Updating itself, after Update or by itself | on | spinner + "Updating…" | none | Reinstall Beacon, Remove Beacon… |
| Beacon installed but not running | on | "Beacon isn't running" | Repair | Reinstall Beacon, Remove Beacon… |
| Repairing the connection to the notification service | on | spinner + "Reconnecting…" | none | Reinstall Beacon, Remove Beacon… |
| Repair did not work | on | "Couldn't reconnect" | Retry | Reinstall Beacon, Remove Beacon… |
| Beacon changed | on | "Beacon has changed" | Trust… (a confirm) | Reinstall Beacon, Remove Beacon… |
| The notification service holds as many computers for this phone as it takes (`409 too_many_secrets`) | on | "Too many computers for this phone" | Retry; the app does not try again by itself | Reinstall Beacon, Remove Beacon… |
| Mac needs a click | on | spinner + "Click Allow for Pteron Beacon" | none | Show Details, Cancel Install |
| The notification service asked the phone to wait | on | "Too many tries. Try again in N minutes." under an hour, "…in an hour." or "…in N hours." from an hour on, "…tomorrow." when the wait ends at or after the next midnight in UTC, "…later." when the service gave no time (`RateLimit.text`, from `Retry-After`) | none; the app tries again by itself when the wait is over | Remove Beacon… |
| A test was sent, for 3 s | on | "Test notification sent" (secondary), or why it was not | none | as healthy |
| Removing | off, disabled | spinner + "Removing…" | none | none |
| Remove failed | as chosen | "Couldn't remove Beacon" | Retry | Show Details |

When two things are true the first of these decides the row: Removing, Turns off when the
computer is back, Offline, Remove failed, off, Beacon changed, an install, Updating, Beacon too
old, Beacon isn't running, Too many computers, Reconnecting or Couldn't reconnect, Too many
tries, Connecting, the result of a test, Update available, the version.

No status line holds the computer's name: the row's title is the name, right above the line.
The name is in the confirms, in the title of Show Details and in the install sheet, where no
title stands beside the words.

A row that is on always has a line. A healthy row's line is its Beacon's version, which the
app takes from the answer to `register_push` (`helper_version`) or from `helper_status`
(`version`), whichever arrives first; every Beacon gives the second, and the app asks for it up
to three times after a registration. Until a version is there, and before Beacon has taken
this phone on this connection, the row reads "Connecting…" with a spinner and its menu has no
Send Test Notification.

**Which version is the latest.** The app decides, from the signed release list it reads
itself, and every computer's row is compared against that one result, so two computers never
disagree. `ReleaseCheck` (`State/ReleaseCheck.swift`) reads the list with
`HelperReleaseFetcher` and keeps the latest version and `min_version` with the time of the
read. `PushRegistrar` asks for it at launch, on each return to the front, when notifications
are turned on and when a Beacon takes the phone; a result stands for an hour, so all of
these and all computers share one read. A read that fails leaves the last good result in place
and is tried again on the next of these no sooner than five minutes later. Nothing is read
while notifications are off or no computer is listed. A Beacon supplies only its own version
(`LatestRelease.standing` compares it; `ComputerFacts.judged` turns that into the row's facts):
equal or newer is healthy, older is "Update available", below `min_version` is "Beacon needs an
update". With no result yet (the first read failed, or a version that is not three numbers) the
row shows the version and claims nothing. What a Beacon thinks of its own version
(`update_available`, `update_required`, `latest_version`, `last_error`, `failing_since` in its
status) is not read.

When a computer's Beacon restarts, as after any update or reinstall, it is a new client on the
server. `client_joined` and `client_left` reach `PushRegistrar.helperClientChanged`, the
reconciler hands the new client the stored secret, and that registration asks Beacon's
status once, so the row shows the version that runs now without a tap. A status held from the
Beacon before is dropped when the registration names another version. On the return to the
front the app also reads each computer's client list, in case the events were missed while it
was away: another Beacon client than the one known is taken the same way, and the one known
is asked for its status.

"Reconnecting…" shows while a computer that is on and was signed up before has not confirmed
on this connection that it holds the phone's secret and is not paused, while the app puts
right a helper that lost the phone or holds it paused, and while a try failed and the next one
is on its way;
"Couldn't reconnect" once the app's own tries are used up, with Retry to start them again.

- **Switch on:** resumes this phone on that computer (`set_push_paused` false), after signing
  it up there if it never was. With no helper there (`Prefs.helperSeen` tells "never had one"
  from "not running") it starts the install, with the install sheet.
- **Switch off:** the computer's helper is told to hold this phone's notifications back
  (`set_push_paused` true). While the computer can't be reached the choice waits on the phone
  (`Prefs.helpersToTell`), the row reads "Turns off when it's back", and the helper is
  told on the server's next connection. Nothing at the gateway changes and no secret is taken
  back. An install under way is stopped.
- **Master off:** the same for every computer that is on, and the app goes off Apple's remote
  notifications (`unregisterForRemoteNotifications`), so nothing arrives. **Master on:** the app
  goes back on them, and each computer that is on resumes at once, with the permission as
  last read and the address the phone already has; nothing waits for iOS. If iOS gives another
  address than before, that is one request to the gateway; otherwise none. Whatever order the
  switches are moved in and however fast, each helper ends at the last choice: a switch moved
  during a run asks for one more run, which reads the choice as it is then.
- **Update:** one tap, and `HelperUpdate.route` decides how. A Beacon that says it can replace
  itself (`can_update`) is asked to (`update_helper`, which has its own checks and its own pause
  between two updates); the row reads "Updating…" until Beacon reports the latest version
  (`HelperUpdate.reached`), looked at every 3 s and on the restarted Beacon's registration.
  The installer replaces Beacon instead, as a repair, with the install sheet: for one that
  reported nothing about itself (too old to register), one that can't replace itself, one that
  refused or answered that nothing started, and one that has not reached the new version 90 s
  after it was asked (`HelperUpdate.limit`). The installer needs nothing from Beacon that
  is there: the one it installs shows the install's proof and registers. After either the row
  shows the new version.
- **Send Test Notification:** the helper's `send_test`. "Test notification sent" shows in the
  row for 3 s. Its errors read "Wait a few seconds" (`test_too_soon`), "Too many tries. Try
  again later." (`limit_reached`; the helper does not pass the wait on), "Couldn't reach the
  notification service" (`no_connection`), "Beacon needs an update" (a helper without the
  action), "Couldn't send the test notification" (anything else). Three answers the app puts
  right by itself: `not_registered` (the helper gets the stored secret again), `paused` (it
  resumes) and `phone_gone` (the phone and its secrets go to the gateway again). `TestOutcome`
  is the mapping.
- **Show Details:** a small read-only sheet titled with the computer's name: "Beacon version",
  "System" (`os`), "Last notification" (`last_push_at`: "2 minutes ago", "Never" for null, no
  row when the field is absent), from `helper_status` (`HelperDetails`), and "Update check",
  which is the app's own read of the release list: "OK", or "Couldn't check" when its last
  read failed. When no helper answers it reads "Pteron Beacon on <name>
  isn't answering." For a computer whose install is under way or failed, Show Details brings
  back the install's sheet instead, at the installer's output (`showSetupDetails`).
- **How:** beside "Install Beacon by hand". A small sheet, "Install by Hand", with where to
  download Pteron Beacon and the step for a Mac ("drag Pteron Beacon to Applications and open
  it once") and for Linux ("run rex-duo-helper install"; `NotificationCopy.manualSteps`).
- **Trust…:** a confirm, "Trust Beacon on <name>?", "Did you reinstall or remove Beacon on
  <name>? If you did, trust it. If you didn't, don't: something else is answering for it."
  Trust, Cancel. The confirm is shown for the key the helper offers at that moment
  (`PushRegistrar.offeredKey`), and Trust pins exactly that key (`trust(_:key:)`). If the
  helper offers another key by the time Trust is tapped, nothing is pinned, the row stays at
  "Beacon has changed", and its button shows the confirm again, for the key offered then.
- **Remove Beacon…:** a destructive confirm, "Remove Pteron Beacon from <name>?", "<name>
  will stop sending notifications to this phone", plus "and to N other phones", where N is
  `helper_status.other_phones` (the phones on that computer that others registered) or, from
  a helper that does not give it, `helper_status.devices - 1`; "and to any other phone that
  uses Beacon" when the helper gives neither. Remove, Cancel. Then, in this order (`HelperRemoval`): the phone's secret for
  that helper is deleted at the gateway and the helper hears `unregister_push`; the installer
  script runs in its remove mode in a tab of its own (`SetupArgs.removeCommand`: `/bin/sh -c
  <setup.sh> rexduo-setup 3 -`, created as an install's tab is, and closed when the script
  ends well; `HelperSetupCenter.remove`); on exit code 0 the phone forgets the helper's key, the secret's
  entry and `helperSeen`, and the computer's switch goes off. Any other exit leaves the phone
  unregistered and the row at "Couldn't remove Beacon" with Retry.

## While the app is closed: Pteron Beacon

Rex has no push support, so `Relay/` builds **Pteron Beacon**, one Rust program
(`rex-duo-helper`) for macOS and Linux that connects to the local Rex as a client named
`rex-push-relay`, watches every session and sends pushes to registered phones through the push
gateway (below). Each machine
with a Rex server runs its own. On a Mac it ships as `Pteron Beacon.app` (bundle id
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

The helper doesn't push notices from panes with an OSC 7501 status (below), so a Claude OSC 9 next
to its `blocked` status gives one push. The app's toasts filter them too (above).

**Desk presence.** While the person sits at a Mac whose Rex app shows the agent's server, Beacon
holds what they would see there anyway: a question waits until they leave or for 10 minutes at
most, and a `done` or a notice isn't pushed, except a `done` that replaces a question the phone
shows. The Mac's own Beacon does it for that Mac's server; for a server elsewhere (workdesk,
shown on the Mac over SSH), the Mac's Beacon writes leases at the push gateway and workdesk's
Beacon asks the gateway to hold its pushes while one is live (below, The push gateway). That
needs the phone's presence key, which the app gives with `register_push` (`presence_key`) only to
computers it confirmed as its owner's own; without it the phone is pushed to as before. There is
no switch. Pteron counts as in front only while it renews a claim (`push_presence {active:
true}`, 3 minutes; the app renews every 60 s), a server's pushes share one stack (`thread-id` is
the server's address), a pane's notices replace each other, and notices from a pane with an OSC
7501 status (now, or until 10 s after it went) are dropped; an agent that reports no status
still gets its notices pushed. Relay/README.md, Desk presence, has the rules, the files and the
fixed choices.

Known limits of what Beacon remembers a phone shows (`delivered.json`):

- It can't see the phone. When Pteron clears a question itself (notify-app's tidy on coming to
  the front), Beacon still takes the question as shown, so the agent's `done` at the desk adds
  one passive "Finished" to the list rather than replacing anything.
- When an agent's OSC 7501 record is removed before its `done` (the agent quit), no `done`
  comes: a question the phone shows stays there until Pteron opens.
- An entry pushed out after 512 others, or lost with the state folder, leaves its question to
  the same fate.

The push decisions (debounce, rate limit, skip phones that are in front) are in
`Relay/src/policy.rs` and `devices.rs`, tested with `cargo test`. The app doesn't share that
code.

## Installing the helper from the app

The app can install Pteron Beacon on the user's own Mac or Linux computer. `State/HelperRelease.swift`,
`HelperSetup.swift` and `HelperSetupRunner.swift` hold it; `Features/HelperSetup` is the sheet.

**When it is offered** (`HelperOffer`): the server's platform is `darwin_*` or `linux_*`, no
helper is connected on the server's own machine, the server's owner and this iPhone's login are
not two different known logins, and no install for it is running. After pairing it is a page
after "added" ("Get notifications from <Name>?", Install / Skip; Skip is remembered in
`Prefs.helperOfferSkipped`). In Settings → Notifications a computer's switch, its Retry, Update
and Repair buttons and "Reinstall Beacon" in its menu start it.

**What runs.** An install turns the master switch and that computer's switch on and asks iOS
for the notification permission if it never has (`PushRegistrar.prepareForSetup`). Whatever iOS
answers, the helper is installed: while the install runs the computer registers all the same,
and with notifications off in iOS the sheet's last screen adds "Turn on notifications in iOS
Settings to be notified." Then:

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
4. It creates a session "Pteron Beacon setup" whose one block runs
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
closes the tab and the sheet reads "Pteron can't get Beacon right now". The installer hands
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
sent. A wrong proof, or none in three replies, ends the run as "Pteron Beacon on <name> has
changed": nothing is pinned, no secret is handed over, and the helper waits for "Trust…" in
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

**Without the sheet.** "Hide" in the sheet (`HelperSetupCenter.hide`) closes it and lets the
install go on; the computer's row shows where it stands, "Continue" or "Show Details" (`show`)
brings the sheet back, and "Cancel Install" stops it. How an install ended stays for the row
until the next one (`HelperSetupCenter.failures`); one that failed with its sheet closed keeps
its tab until then, so "Show Details" still has the installer's output.

**Ending.** The setup session is the app's own, and the app closes it and nothing else
(`SetupSessionCloser`). Every tab the app makes goes into a list in UserDefaults
(`SetupSessions`) with the ids the server gave, and leaves the list when the server has closed
it. A tab is closed by those ids and only while it is in the list; a session that merely has
the installer's name is never touched.

Before anything closes, the app reads the session from the server (`session.view`) and closes
only what is still its own (`SetupTabClose.decide`). This holds for every close: a script that
ended well, Done, Close, Try Again, Stop, "Cancel Install", and a tab left over on a connection.

| What the session holds now | What is closed | The entry |
|---|---|---|
| One window with one block, the tab's, in a session the app made for it | the session (`session.destroy`) | leaves the list |
| The tab's block alone in its window, and other windows (or a session of the person's) | that window (`session.close_window`) | leaves the list |
| The tab's block beside other blocks in its window | that block (`block.close`) | leaves the list |
| No block with the tab's id, no such session, or an answer that is no view of it | nothing | leaves the list |
| No answer (the connection is gone) | nothing | stays for the next connection |

- The script exits with 0 (an install, a repair or a removal): the tab closes at once, whether
  or not the sheet is open. The run goes on to the helper's proof without it.
- The script fails: the tab stays, because "Show details" shows its terminal (the app's
  terminal view in mirror mode, taking no touches). It closes on Close or Try Again in the
  sheet (Try Again closes the old tab before its run opens a new one), on Stop or the row's
  "Cancel Install", and when the sheet goes away after the installer's output was on screen.
- After each sync with a server the app closes every tab in its list for that server that no
  run in this app session uses (`SetupSessionCloser.connected`). That covers a failed run's
  tab when the app was killed before the person was done with it, and a close the server did
  not take because the connection dropped. A tab is in use while the server's install runs,
  while its failed run keeps the tab for "Show Details", and while a removal runs. A tab the
  server closed, or no longer has, leaves the list; one it did not close stays for the next
  connection.

A dropped connection leaves the installer running; after the reconnect the app reads
`program_status` and `process` and goes on.

A helper reports when its release list expires (`manifest_expires_at`);
`HelperRelease.renewalNotice` turns a date within 30 days into a line for whoever publishes
releases. No screen shows it.

Tests: `RexDuoTests/HelperReleaseTests.swift`, `HelperSetupTests.swift`,
`NotificationStatusTests.swift`, `PushReconcilerTests.swift`. `-simulateHelperSetup` and `-simulateNotifications`
(docs/debug-args.md) show each state of the sheet and of the Notifications screen with no server.

## The push gateway

A helper holds no Apple key and never sees a phone's APNs token, so it can be a public download.
`Gateway/` is a Cloudflare Worker that holds both:

1. The phone chooses an owner key (32 random bytes) and the device id that belongs to it (the
   first 22 characters of base64url(SHA-256("rexduo-device-v1\n" + owner key))), and sends its
   APNs token and environment under them (`PUT /v1/devices/{id}`). The gateway keeps only a
   hash of the key.
2. For each server the phone chooses a secret and the id it is stored under, sends them
   (`PUT /v1/devices/{id}/secrets/{secret_id}`, labelled with the server's name) and hands that
   server's helper the gateway's address and the secret (`register_push`). With the secret it
   says whose computer that is, when it knows (`presence`, "Whose computer" below).
3. For each notification the helper posts the payload to the gateway with its secret. The gateway
   adds the APNs topic and the provider token and passes it to Apple, sandbox or production as
   the phone registered. A secret can reach one phone and nothing else.
4. A rotated APNs token is the same `PUT` with the owner key; the secrets, and so every helper,
   are unaffected.

Both requests can be sent again and give the same answer: the gateway makes nothing new and
writes nothing when it already holds what the request carries.

Owner-key routes answer `401 unauthorized` for an unknown phone and for a wrong key alike. Only
that JSON body counts as "the gateway no longer has this phone"; a 401 from anything in between
is treated as the gateway being unreachable.

**Desk presence across computers.** The gateway also keeps which of a phone's desks
are in use, so a Beacon on a computer nobody sits at (workdesk) can hold a question while the
person is at a Mac whose Rex app shows that server. A Beacon on the Mac writes a lease
(`PUT /v1/presence`, an HMAC tag of the desk and an end time); another Beacon names the desks
that show its server in `hold_if_desk` on a push and gets `202 {"held": true}` while one of
them holds a lease. Only a secret the phone flagged as one of its own computers
(`"presence": true` on the secret's `PUT`) takes part; clearing the flag or deleting the secret
removes the phone's leases. There is no switch: a Beacon or an app that sends none of this
gets the gateway as before. Beacon writes the leases and names the desks
(Relay/README.md, Desk presence); the app gives the key and sends the flag ("Whose computer"
below).
Gateway/README.md, Desk presence, has the rules.

The API, limits and deploy steps are in `Gateway/README.md`; `PushGateway`
(`State/PushGateway.swift`) is the phone's side, tested in `RexDuoTests/PushGatewayTests.swift`.

## Signing the phone up

`PushReconciler` (`State/PushReconciler.swift`) owns it. `PushRegistrar` tells it what the
person wants for each computer (`PushIntent`: paused, waiting for iOS, or on with the phone's
address) and renders what it found. In normal use the gateway is contacted once per install of
the app, for the device, and once per computer, for its secret. A switch never contacts it.

**What is stored where.**

| What | Where |
|---|---|
| The master choice, each computer's choice (`notificationsOff`), where a helper was seen (`helperSeen`), which helpers still have to hear of a pause (`helpersToTell`) | UserDefaults (`Prefs`) |
| The phone's last APNs token | UserDefaults |
| The owner key and device id; the token and environment the gateway confirmed; per computer the secret id, the secret and the helper's pinned key; what the gateway has not confirmed yet (`unconfirmed`, on the device and on each secret); secrets taken back and not yet deleted (`retired`) | one Keychain item (`KeychainRegistrationStore`, `GatewayRegistration`) |

Every Keychain item of the feature is written through `KeychainItem`:
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and never synchronizable, so it stays on
this phone and is in no backup another phone can restore. The owner key and the device id are
made once and reused from then on, also after the app is deleted and installed again, since the
Keychain item stays.

**Written before it is sent.** The owner key and device id, and each secret with its id, are
written to the Keychain, marked `unconfirmed`, before the request that carries them. A request
whose answer was lost, and an app that was closed before the answer, send the same request
again, and the gateway makes one device and one secret.

**One run** for a computer compares what is wanted with what is true and does the first
missing step:

1. The master switch or the computer's switch is off: the helper is paused, if it has not
   confirmed that yet. Nothing else.
2. On, and iOS has not allowed notifications or has given no address: nothing.
3. The gateway holds the device with the current token; otherwise one `PUT`. Every computer
   that asks at the same moment shares that one request.
4. The helper there proves its key (`helper_identity`) and is admitted (`HelperAdmission`). The
   computer has a secret the gateway confirmed; otherwise one `PUT`.
5. The helper holds that secret and is not paused; otherwise `register_push` (sealed after an
   install), or `set_push_paused` false for a helper that took the secret on this connection.
6. Nothing is missing: no request to the gateway and no write to the Keychain.

**When it runs.** At launch, on the return to the front, when a server's connection comes up,
on a network change (`NetworkWatch`), on a switch, at the end of an install, for a new APNs
token, and when a helper joins or leaves a server. Runs for one computer never overlap; a
trigger during a run asks for one more after it.

**When a step fails** the run is made again by itself: after 2 s, then twice as long each
time, at most 5 minutes, each wait up to half as long again so phones don't retry in step
(`PushBackoff`). `Retry-After` on a 429 or a 503 is obeyed, and wins when it is longer: no
request goes to the gateway before that time, whatever asks for one. One computer gets 6
tries per stay of the app in front; after them its row reads "Couldn't reconnect" with Retry,
which starts them again, as does the app's next return to the front.

**What mends itself.**

- A helper that says it holds nothing for this phone (it was installed again with the same
  files, or lost them; `registered: false` in `helper_status` or `push_presence`): it gets the
  stored secret again, if it proves the pinned key. No request to the gateway. A helper that
  says so more than twice on one connection is left alone until Retry.
- A helper that says it holds the phone paused while the computer is on (`paused: true` in
  `helper_status`, or the `paused` answer to a test): it resumes.
- A helper that proves another key: the row reads "Beacon has changed" and nothing is
  sent. "Trust…" pins the key its confirm was shown for, deletes the old secret at the gateway
  and stores one new one. It does nothing when the helper offers another key by then.
- A helper that says the gateway no longer takes its secret (`secret_dropped`, or `phone_gone`
  from a test): the phone's address was dead. The device and each computer's secret are marked
  unconfirmed and go to the gateway again once each, under the same owner key and ids. The
  computer whose helper saw the refusal gets a new secret under its id, because a helper never
  takes a secret again that it saw refused.
- The gateway's own 401 for the device: the same, and the same `PUT` makes the device again.
- An empty Keychain: a new owner key and device.

**A secret the gateway refuses.** `409 conflict` to a secret's `PUT` means the gateway holds
that value in another row. The phone makes a fresh value under the same secret id, writes it
before it is sent, and sends once more. A second `409 conflict` ends the run: no automatic
try follows, and the row reads "Couldn't reconnect" with Retry. `409 too_many_secrets` (the
device holds as many secrets as it may) ends the run at once: the row reads "Too many
computers for this phone" with Retry, and the app does not try again by itself, on a trigger
or on its return to the front (`PushReconciler.full`).

**Entries for computers the app does not list** (`PushOrphans`). The Keychain item stays when
the app is deleted; the list of computers does not, and a computer that is added again has a
new id. At launch, once the computers are loaded (`PushReconciler.computersLoaded`), every
stored entry (secret id, secret, pinned key) whose computer id is not in the list is set
aside.

- A computer with no entry whose helper proves the key pinned in one of them takes that entry
  over as it is, outside an install: its secret is the one that helper holds, so nothing is
  sent to the gateway.
- The rest are retired: their entries leave the store and their secrets are deleted at the
  gateway through `retired`, so a delete the gateway did not confirm is sent again later. This
  happens at the end of the first run after which every listed computer's helper has been
  looked at on a connection (it proved its key, is too old to, or there is none), or 60 s
  after a computer is listed (`PushOrphans.wait`), whichever is first.
- While no computer is listed, the entries stay as they are.
- Entries of listed computers are never set aside.

**A switch off or on** is `set_push_paused` and nothing else. A helper without the action
answers `not_supported`: it then hears `unregister_push` for off and `register_push` with the
same stored secret for on.

**A secret is deleted** (`DELETE /v1/devices/{id}/secrets/{secret_id}`) only by "Remove
Beacon…", by "Trust…" of a changed Beacon, when the server is removed from the app, and for a
stored entry of a computer the app does not list (above). A
delete the gateway did not confirm is kept (`retired`) and sent again on a later launch or
return to the front. The device itself is never deleted by the app.

**A phone that registered with an earlier version** keeps the device and the secrets it has:
its stored registration is used as it is, and the `PUT` routes serve only a computer that has
no secret yet. If the gateway no longer has that device, the phone chooses an owner key and
device as a new install does, keeping each helper's pinned key.

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
   key: hand over nothing and show the "changed" line; "Trust…" deletes the old helper's secret,
   pins the key its confirm was shown for and registers with a new secret. A helper that doesn't know
   `helper_identity` counts as too old. During an install from the app the first-use pin does
   not apply: the helper is pinned only after it showed the run's setup proof ("Installing the
   helper from the app").
5. It registers with `register_push`, args `gateway` (its address), `push_secret` (that server's),
   `environment` (`sandbox` for debug builds, `production` for TestFlight), `device_name`,
   `device_id`, and `paused` false. The reply carries `helper_version`.
   During an install from the app, after the setup proof, it adds `setup_seal`: base64 of
   HMAC-SHA256 keyed by the setup code over `rexduo-setup-register-v1`, the `push_secret` and
   the `device_id`, joined by `\n` (`SetupSeal`). No other registration carries it.
   For a computer confirmed as the person's own it adds `presence_key`, the phone's presence
   key ("Whose computer" below); every other registration leaves the argument out, and a helper
   that held a key lets it go.
6. It reports `push_presence {active}` on background and foreground, so the helper skips phones
   that show their own notifications. It says `true` only once the app is active on screen
   ("In front" below).
7. It pauses and resumes with `set_push_paused {paused}` when the master switch or the
   computer's switch is turned off or on. The helper keeps the registration and sends a paused
   phone nothing; `helper_status` reports `paused`, and `send_test` answers the error `paused`.
   `unregister_push {device_id}` is sent before the helper is removed, and to a helper without
   `set_push_paused` in place of a pause.
8. `helper_status` reports the helper's `version`, whether it can replace itself (`can_update`)
   and whether it is doing so (`updating`); `update_helper` starts an update and replies before
   the helper restarts, with `started` false when its own check finds nothing newer. The status
   also carries the helper's own view of the releases (`latest_version`, `update_available`,
   `update_required`, `last_error`, `failing_since`), which the app does not read: see "Which
   version is the latest".
9. A helper that holds nothing for this phone says so: `registered: false` in the
   `push_presence` and `helper_status` results. One that has seen the gateway refuse its secret
   answers `register_push` with the `secret_dropped` error. What the app does for each is in
   "Signing the phone up", "What mends itself".
10. `send_test` (no arguments) has the helper send one notification to the requester's own
    phone; `helper_status` also reports `os`, `devices`, `other_phones` (how many of the
    phones on that computer were registered by others than the asking phone's Rex user) and
    `last_push_at`. A helper without them answers `not_supported` and leaves the fields out,
    and the app says so or shows less.

**What the checks separate.** The helper's per-phone checks (who may pause, resume, test,
re-register or unregister a phone, and whose phones `other_phones` counts) tell users apart by
their Rex identity. Phones signed in to Rex as the same user are that user's own devices: on a
computer, each can pause, test and re-register the others.

The first `register_push` from a `device_id` the helper has never seen posts one desktop
notification on the computer, "Pteron connected" with the phone's name (`Relay/src/notice.rs`;
on a Mac from the app's own `rex-duo-notify`, so it shows as Pteron Beacon and needs the
permission macOS asks for when the app is first opened; `notify-send` on Linux when it is installed). Seen ids are kept in
`seen_devices.json`, so it is once per phone, not per connect or per helper start.

Pushes carry `server` (the Tailscale URL as entered in the app), `session_id`, `window_id` and
`block_id`, so a tap can open the pane. The gateway sets the APNs topic, the bundle id
`dev.abrahamgonzalez.rexduo`.

## The app's side

`PushRegistrar` (`State/`, owned by `AppModel`) and its `PushReconciler` implement the
contract. Their pure parts are in `PushSupport.swift` (tested in
`RexDuoTests/NotificationTests.swift`) and `HelperTrust.swift` (`HelperIdentity`,
`HelperFailure`, `SecretLabel`; `RexDuoTests/HelperTrustTests.swift`).

- Device id: the first 8 hex digits of `identifierForVendor`. `PushIdentity.clientLabel` builds
  `"<device name> #<id>"`, shortening the name to fit Rex's 64 bytes.
- Environment: read from the build's `embedded.mobileprovision` (`aps-environment`), so a Release
  build installed with a development profile still says `sandbox`. No profile (TestFlight, App
  Store) means `production`; the simulator is always `sandbox`.
- Sign-up runs after each server's bootstrap and on the other triggers above. What a
  connection learned of its helper belongs to that connection (`ServerConnection.connectionSerial`),
  so a resync on the same connection costs nothing, and a new connection has the helper prove
  its key and take the secret again. While the master switch is off and nothing waits to be
  told, nothing is called.
- Presence: `push_presence` false on background (inside a background task, `State/BackgroundTask.swift`)
  and true on foreground and after each registration made while the app is in front, since a
  resumed connection keeps its client id.
- **Renewal.** A helper keeps "in front" for 3 minutes after it was last told
  (`CLAIM_LIFE` in `Relay/src/desk.rs`), so a phone whose `false` never arrived stops counting
  by itself. While the app is in front it therefore sends `push_presence {active: true}` again
  every 60 s to each helper that holds the phone, which leaves room for two lost calls.
  `becameActive()` starts the repeats, whether or not the registrar has started, and
  `enteredBackground()` ends them before it sends `false`; nothing is repeated in the
  background. `PresenceRenewal` (`State/PresenceRenewal.swift`) holds the timing, with the
  clock passed in (`RexDuoTests/PresenceRenewalTests.swift`). A helper from before the claim
  takes each repeat as the same news again.
- **In front.** `PushRegistrar.inFront` starts false, and only `becameActive()` sets it, which
  `RexDuoApp` calls at the `.active` scene phase. So a launch that never reaches the screen
  tells no helper that the phone is in use, and the helper goes on sending its pushes. There
  is no gap either way: a registration that ends before the app is active is followed by the
  `push_presence true` that `becameActive()` sends, and one that ends after sends its own.
  Such a launch also opens no connection at all ([architecture.md](architecture.md), Launch).
- iOS turning notifications off changes nothing on the phone, at the gateway or on a helper:
  the choices and the sign-up stay, and iOS shows nothing meanwhile.
- An install from before the gateway needs nothing from the user: on its next connect it
  signs up with the gateway and gives an updated helper a secret. A helper that is still the
  old version refuses, and its row reads "Beacon needs an update"; Update replaces it through
  the installer.
- `project.yml` gives the app `aps-environment` (development; export for App Store Connect switches
  it to production) and `com.apple.developer.usernotifications.time-sensitive`.

### Whose computer

The gateway keeps one flag per secret, `presence`: the secret's computer is one of the person's
own. The app sends it with the secret's `PUT` as a JSON boolean, and only when it can tell:

| What the server says | `presence` |
|---|---|
| Its owner's login and this phone's login are both known and equal, without case | `true` |
| Both are known and differ | `false` |
| Either is unknown: a tagged server, a local connection, a name that is not a login, no answer yet | not sent |

`ServerIdentity.isConfirmedOwn` (RexKit) is the first row. It is stricter than the offer to
install Beacon, which only holds back when the two logins are known to differ. A request
without the field leaves the gateway's flag as it is, and a gateway that does not know the
field ignores it.

A secret the gateway confirmed before the app knew the owner has no flag yet. Once per launch
and computer, when sign-up has nothing left to do and the answer is known, the reconciler sends
the same secret once more with the flag (`PushReconciler.flagOwnership`); the gateway writes
only the flag, or nothing when it holds it already. A change of the answer is sent once in the
same way. This is no part of signing up: a request that fails changes nothing in Settings and
is made again the next time the app comes to the front. A computer that is turned off is not
flagged. `RexDuoTests/PushOwnershipTests.swift` counts the requests.

**The presence key.** The helpers on the person's own computers name a desk to the gateway by
a tag, and the tag is made with a key only those helpers and the phone hold, so the gateway
can match what two of them say without being told which desk it is. The phone makes the key:
32 bytes from the system's random source, written as base64url without padding (43 characters,
`PresenceKey` in `State/PushGateway.swift`; the helper reads it with `PresenceKey::parse`,
`Relay/src/presence.rs`).

- It is made the first time a computer of the person's own is registered, written to the
  store before it is sent, and reused from then on. It lives in the registration's Keychain
  item with the owner key and the secrets (`KeychainItem`: readable after the first unlock,
  this device only, never in iCloud Keychain). A registration that starts over starts without
  a key, and the next own computer to register gets a new one.
- It goes to a helper in `register_push`, and only for the first row of the table above: the
  same answer that sends `presence: true` (`PushReconciler.ownership`). It never goes to the
  gateway.
- A helper that was registered before the answer was known, or before it changed, is
  registered once more on that connection: with the key when the computer is the person's
  own, without it otherwise, which takes the key away from a helper that held one. A paused
  computer is left paused and gets this with the registration that resumes it.
- A helper from before the key ignores the argument.
- The key has one way out, `PresenceKey.wireValue`, used for that call. Every description of
  it and of the record that holds it reads `<redacted>`.

`RexDuoTests/PresenceKeyTests.swift` covers all of this with stand-ins.

### Clearing notifications that no longer hold

A push about an agent stays in Notification Center after the agent was answered at the
computer. While the app is in front, `NotificationTidier` (`State/NotificationTidy.swift`)
removes the ones that say nothing true any more, with `removeDeliveredNotifications`. It shows
and plays nothing.

- Only `AGENT_BLOCKED` and `AGENT_DONE` are ever removed. A `NOTICE` is its only copy and
  always stays, and so does the test notification.
- On a server whose agents' states have all been read on a live connection
  (`ServerConnection.agentsCurrent`), a question or a "finished" goes when the agent in its
  pane does not wait now; a pane that is gone counts as not waiting. The pane is the payload's
  `block_id`, whatever the notification's identifier is.
- A notification from a server that is no longer in the app goes too, but only while every
  server of the app is known: one that is not connected has not said its name yet, so the
  push may be its own.
- Anything that can't be told stays: no `server` or `block_id` in the payload, a server that
  is offline or still loading.

A pass runs when the app becomes active, when a server's agents have just been read, and when
an agent changes state while they are known, at most once a second, and never in the
background. Opening a pane starts no pass of its own: the rule reads only the agents' states,
so the pass that follows a change of state already covers a pane the person opened and answered. `NotificationTidy.stale` is the rule (`RexDuoTests/NotificationTidyTests.swift`).

### Tapping a push

`AppDelegate` sets the notification delegate in `didFinishLaunching`, so it also gets the tap that
cold-launched the app; the route waits there until the app attaches its model.
`PushRoute(userInfo:)` reads `server`, `session_id`, `window_id`, `block_id`. `AppModel.open(_:)`
finds the server by host (as entered, or the Tailscale name it reports), waits up to 30 s for the
session to load, focuses the pane and sets `openRequest`; `RootView` shows that tab, and the toast
modifier closes any sheet. The three categories are registered without actions; iOS groups by the
payload's `thread-id`.

### Testing

- The loop: `RexDuoTests/PushReconcilerTests.swift` counts the requests at stand-ins for the
  gateway and the helpers, with time moved by hand (`PushStandIns.swift`).
- Simulator registration: stop the installed helper (see `Relay/README.md`, "Verify by hand"), run
  `cargo run --manifest-path Relay/Cargo.toml -- run --dry-run --verbose` and launch the app with
  push on. Simulators on Apple silicon get sandbox
  tokens; `-pushToken <hex>` (debug builds) fakes one and skips the permission check, and
  `-pushGateway <url>` registers with another gateway.
- Push taps: `xcrun simctl push <sim> dev.abrahamgonzalez.rexduo payload.json` with the payload
  above, app in the background or not running, then tap the banner.
- Toasts: a throwaway `zz-` session printing OSC 7501 `blocked` (see `Relay/README.md`,
  "Verify by hand").
