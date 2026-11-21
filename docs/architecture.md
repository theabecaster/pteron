# Architecture

## Layers

App → Features → State → RexKit. Features also use DesignSystem. Nothing points back up.
The app and its extension both use `Packages/RexGlance`, which uses nothing of ours.

| Layer | Owns | Doesn't |
|---|---|---|
| `Packages/RexKit` | sockets, RPC, JSON → models, terminal byte stream | import UIKit or SwiftUI, read settings |
| `RexDuo/State` | `AppModel`, one `ServerConnection` per server, `Prefs`, `AgentNotifier`, `PushRegistrar` and its `PushReconciler` | build views |
| `RexDuo/Features` | screens, and UIKit where the terminal needs it | talk to `RexControl` for session changes (go through `ServerConnection`) |
| `RexDuo/DesignSystem` | `TermTheme`, chrome colors, fonts | hold state |
| `Packages/RexGlance` (`GlanceModel`) | what the app shares with its extensions: the links that open the app (`DeepLink`, `PaneLink`), the snapshot of the agents and everything decided from it (`GlanceSnapshot`, `GlanceSummary`, `GlanceSince`, `GlanceFreshness`, `GlanceDigest`, `WriteThrottle`, `GlanceStore`) | import anything but Foundation (no RexKit, no SwiftUI) |
| `Packages/RexGlance` (`GlanceUI`) | what the widgets draw with: colors from a snapshot's palette, the ring, the type | import anything but SwiftUI and `GlanceModel` (no WidgetKit, no UIKit, so a watch target can use it) |
| `RexDuoWatch`, `RexDuoWatchWidgets` (watch app and its extension) | the agents on the wrist: the snapshot the phone sent, the complications, and Enter or Interrupt for a waiting agent, sent to the phone after a confirmation ([glance.md](glance.md), The watch) | import RexKit, app code or the engine; connect to anything; send the phone anything but a confirmed action |
| `RexDuoWidgets` (app extension) | the agents widget (Home Screen and Lock Screen), the controls for Control Center, the Lock Screen and the Action button, and `OpenLinkIntent`, which the app compiles too | import RexKit, app code or the engine; connect to anything; write the snapshot (it only reads it) |

`Relay/` is a separate Rust crate (the push helper for macOS and Linux). It shares no code with
the app; it speaks the same control protocol over Rex's Unix socket.

## Data flow

1. `RexDuoApp` owns `Prefs` and `AppModel` as `@State` and injects both with `.environment`.
2. `AppModel` builds a `ServerConnection` per configured server (Settings → Computers). Each owns one `RexControl`, a `KeymapStore` and its `ServerCapabilities` (what that server can do; docs/rex-protocol.md, API revisions). None connects until a scene shows (Launch, below).
3. On connect, `ServerConnection.bootstrap` calls `session.bootstrap`, attaches every session,
   loads block metadata (program status, title, process), hosts and the keymap. The first
   sync with a server process also reads the creator list.
4. Server events update `ServerConnection` (`ServerConnection+Events.swift`). For an event the
   server had to drop, only what it would have changed is read again. Block events are coalesced (about 150 ms) and a status
   stays on screen at least a second, except a new "blocked", which shows at once. Each block's
   metadata sits in its own observable box, so one pane's change re-renders only its readers.
5. User actions call `ServerConnection` methods, then re-read the session's view. The server's
   `session_view_changed` is the truth for layout; nothing guesses a layout locally.
6. Each visible pane is `PaneView` → `TerminalHost` (UIKit) → `TerminalStream` (RexKit).
   Settings and theme are pushed into the host from `updateUIView`.
7. Reconnects, returning to the foreground and an event `seq` gap all trigger a full resync.

Three things from outside put a tab on screen, and all end in `AppModel.openRequest`, which
`RootView` shows:

- a tapped push: `AppDelegate` → `AppModel.open(_ route:)` (docs/notifications.md);
- a tapped toast: `AppModel.openPane`;
- a link from a control: `OpenLinkIntent` (run in the app) opens the URL → `RexDuoApp`'s
  `onOpenURL` → `AppModel.openLink` → `openWaiting()`,
  with the rules in `OpenWaiting` ([glance.md](glance.md)). `rexduo://open` only brings the app
  forward.

- a link from a widget's row: `onOpenURL` → `AppModel.openLink` → `openPane(link:)`, with the
  rules in `OpenPaneLink`.

Targets (`project.yml`): `RexDuo` (the app; it embeds `RexDuoWidgets`, so every build and test
of the app builds the extension, and `RexDuoWatch`, which embeds `RexDuoWatchWidgets`),
`RexDuoWidgets`, `RexDuoTests` (which also compiles the widgets' views, `RexDuoWidgets/Views`,
to draw them), and `RexDuoWatchTests` (the watch app's tests, in the scheme `RexDuoWatch`, on a
watchOS simulator).

## Which tab a launch opens

Every posture and both navigation styles open the same tab (`LaunchTab`, `State/LaunchTab.swift`,
run by `AppModel.autoSelect()`):

1. The tab viewed last (`Prefs.lastSelection`, the newest of the viewing history), while it is
   still there.
2. Else the top tab of its session, in the sidebar's order.
3. Else the top tab of the first session with tabs on that machine.
4. Else, or with nothing saved, as before: the first session with tabs on any machine, at the tab
   it shows. With nothing at all, the empty state.

- **From what is saved and synced.** No call of its own: the tab is picked from the machine's
  first sync, and selected without `session.focus_window`.
- **No tab swapped for another.** Until the machine viewed last has synced, the launch waits for
  it, so a machine that answers sooner doesn't put its own tab up first. A machine that is down
  or no longer added goes to rule 4.

## When the tab on screen closes

Rex keeps a session whose last pane closed: it stays listed with no tabs (`session.view` has no
`windows` and no `active_window_id`) until someone kills it, whatever the server's `exit-empty`
says (that one is about the server stopping). The app doesn't kill it either; nothing shows that
Rex.app does. It moves the screen instead, by one rule (`CloseNext`, `State/CloseNext.swift`):

1. A pane of the closed tab is now in another tab of the session (Move Pane to Tab took the
   last one): that tab.
2. The session still has tabs: the one viewed most recently, else the closed tab's next
   neighbour, then the previous one (Rex makes the same neighbour active after a close).
3. The session is empty or gone: the session viewed most recently on the same machine, then on
   another machine that is online, each at the tab viewed last there (else its active tab).
4. None viewed: the first session with tabs on the same machine, then on another online machine.
   Not in a test launch (`-autoOpen`), which only goes back where it was in that run.
5. Nothing left: the empty state.

- **Only the tab on screen.** `ServerConnection` hands every change of `views`, with the views
  before it, to `AppModel` in the same turn; only a change that took the selected tab away moves
  the screen. A tab or session closing elsewhere moves nothing, and so does a sync that couldn't
  read a session it still lists.
- **No empty state in between.** The move happens in the turn that changed the views, before
  anything draws. The phone's own Close Tab moves as soon as the server answers
  (`AppModel.closedTab`), without waiting for the view.
- **Moving is selecting.** The next tab is shown as a tap would (`select`, which sends
  `session.focus_window`); nothing is opened, resized or closed for it beyond what showing a tab
  does (fit mode takes its pane).
- **History.** `AppModel.recentTabs` (`TabHistory`): the last 32 tabs viewed, newest first, each
  once, saved in `Prefs.recentTabs` across launches; a test launch starts empty and saves nothing.
  Rex.app keeps the same kind of list (Go to Recent Session: "Shows the session you were in
  before this one").

## Launch

A launch opens no connection until the app is on its way to the screen.

- `AppModel.init` builds every `ServerConnection` and starts none.
- `RexDuoApp` reads one thing, the scene phase, and `ScenePhases` says what each phase asks:
  `.inactive` → `AppModel.sceneVisible()`; `.active` → `sceneVisible()`, then the resync and the
  helpers' "in front" as before; `.background` → the background steps.
- `sceneVisible()` starts every server, once (`mayConnect`). After it, `rebuildServers()`
  starts a new server at once; before it, a changed server list starts nothing.
- A launch iOS makes in the background (prewarming, and later a message from a watch or a
  notification action) has no scene, so it gets no visible phase: no server is started, no
  helper hears that the phone is in front ([notifications.md](notifications.md), In front),
  and no snapshot is written.
- The app reads no other launch state. `UIApplication.applicationState` is not usable for
  this: SwiftUI runs `App.init` before `UIApplicationMain`, where it reads as active, and
  `didFinishLaunching` reports background for an ordinary launch too.
- A Debug build logs one `SCENE_VISIBLE servers=<n>` line when the servers are started.

## The snapshot for the widgets

The agents widget can't reach Rex, so the app tells it what it knows through one file
([glance.md](glance.md), The snapshot).

- **One writer per file.** `glance/snapshot.json` in the App Group is written only by the app:
  `GlanceWriter` (owned by `AppModel`) builds it on the main actor and `SnapshotFileWriter`, an
  actor, writes it. Every write carries a number, and one that arrives after a newer one has
  landed is dropped. The extension only reads. A later writer (a watch, a notification
  extension) gets a file of its own.
- **When.** `GlanceWatcher`, a zero-size view beside `WaitingWatcher`, reads only what is
  already coalesced (`waitingAgentIDs`, each server's `agentKeys`, its link, the two themes)
  and tells the writer that something changed. `WriteThrottle` turns that into writes and into
  reloads of the widgets' timeline. Going to the background writes once more, inside a
  `BackgroundTask`.
- **On to the watch.** The writer hands each written snapshot to `GlanceBridge` (owned by
  `AppModel`), which sends it over WatchConnectivity when `WatchDelivery` says so. On the
  watch, `WatchInbox` is the one writer of the watch's own copy. Nothing comes back.
- **Off** in the test host and in every test launch (`GlanceWriter.Mode`), so made-up or
  throwaway state never replaces what the widgets know.

## Offline

- `RexControl` owns retries and reports each failure as a `ConnectionFailure` (error domain and
  code, the POSIX or TLS code under it, the upgrade's HTTP status, the close code). Its observer
  hears of a failure after `dormant`, `retryStopped` and `isHeld` are as that failure leaves them.
- **Why reconnecting is careful.** The phone's VPN keeps a packet for a computer that is off
  until its handshake gives up, about 90 s, out of one small pool shared by every computer, and
  each new packet starts that time over. An app that keeps asking a computer that is off can
  stop the whole tunnel. So a host that doesn't answer is asked rarely, hosts that are down share
  a budget, and nothing is asked in the background.
- **One policy.** Every number and rule is a value of `ReconnectPolicy` (RexKit, pure):
  `RexControl` keeps one host's state and `ReconnectGovernor` what the hosts share (one per app,
  made by `AppModel`), and both ask the policy. `ReconnectPolicyTests` holds the values in use.
  - *Schedule per host:* the waits before an episode's attempts are 0 to 1 s, 10 s, 2 min, then
    5 min, each a fifth shorter or longer. The first is the wait after a drop; an episode that
    begins with an attempt (`connect()`, the return to the foreground) has none, and its second
    attempt follows by the 10 s. Only a welcome starts it over.
  - *The floor:* from the third attempt on, none starts sooner than 2 min after the one before
    STARTED. `RexControl.scheduled` holds every attempt to it, whatever asked for it (the wait,
    the network, the return, the breaker letting a host go). Only a tap goes past it.
  - *Kinds of failure:* silent (a timeout, no route, a lost connection), answered (a refused
    port, a 5xx, an ordinary close: the normal schedule), final (not allowed, a 4xx, no common
    API revision: retries stop and only the user asks again). A TLS failure is tried again on
    the normal schedule, and is final only at the third in a row while another host is
    connected: a tunnel that is half up fails TLS too. For the breaker it is an answer (bytes
    came back from the host), never a silence.
  - *Dormant:* after 5 silent failures in a row. One attempt per 10 min, counted in the
    foreground: the background stops the wait and the return goes on with what was left, so
    short visits add up to a turn.
  - *The budget:* at most 2 attempts per 100 s across hosts that are down, and 2 under way. A
    host's first attempt of an episode and a user's tap are outside it, and a welcome gives the
    budget that host's attempts back (they were not to a host that is down). A host that is
    refused only because 2 attempts are under way keeps no timer and logs nothing: the
    governor tells it when one of them ends.
  - *The tunnel breaker:* its states and transitions are the table at the top of
    `ReconnectGovernor`. It opens when 2 hosts go silent within 30 s, each one connected until
    then or on its first two attempts, and no host is connected. One test host is tried and the
    others are held; a test host that stays silent passes the turn to the next (the one that was
    connected last first), so a computer that is off never keeps healthy ones held. A dormant
    host is never held and takes no turn: it keeps its own attempt per 10 min, open breaker or
    not, so one that comes back is found within about 10 min however many others are away;
    dormant hosts that come due together go 500 ms apart and within the budget. Any welcome
    or answer from any host closes it, and the held hosts go 500 ms apart, each when its floor
    and the budget allow.
  - *Triggers:* a tap is Try Again, a pull to refresh, or moving to another server (a tab or a
    pane of the same server is not one). It is one attempt now, past the floor, the budget and
    the breaker, at most once per 10 s per host and with fewer than 2 attempts under way; a pull
    to refresh tries one host that is down (`refreshTarget`), not all of them. A change of route
    (`RouteWatch`: another kind of interface, other tunnel addresses, or a path after none, once
    the path has been quiet for 2 s) pings a socket that is up and never tears it down; a host
    that is down gets one attempt if its last began 2 min ago, and a dormant host is brought
    forward at most once per 10 min, its next turn staying where it would have been. Other path
    reports ask for nothing. The return to the foreground pings what is up, moves a backing-off
    host forward subject to the floor, and leaves a dormant host alone unless it is selected.
    With no path nothing is tried and a failure counts toward nothing.
  - *An attempt under way:* no request cancels it or opens a second socket beside it, and the
    state is checked where the socket is opened (`openSocket`), so an attempt that was let
    through a turn earlier can't replace a socket that has since got its welcome or open one
    after a stop. A change of route (`RouteWatch`) alone gives the attempt a new socket, once
    (`moveAttempt`): the same attempt, with the old socket dropped, a full deadline for the new
    one and the floor counted from it. A launch opens one socket per server (`ControlKickTests`).
  - *Liveness:* a ping when nothing came in for 30 s, and at once when a request got nothing
    back for 5 s (10 s on cellular); no pong in 10 s (20 s) is a dead connection. The connect
    deadline is 10 s (15 s), the wake pong 2.5 s (5 s). There is one watchdog per connection,
    not a deadline per call: while any call waits (typed input is one), the silence is counted
    from the later of the last frame in and the oldest waiting call, and one wait is set for
    what is left of it. Frames that keep arriving keep it quiet however long a call takes. It
    neither waits nor fires in the background, and a wait set before a drop does nothing to the
    next connection (`ControlWatchdogTests`). A data socket's handshake has the connect
    deadline too (docs/terminal.md, Reconnect).
  - *Background:* `enteredBackground()` cancels every wait and the pings and gives up an attempt
    that is under way; `wake()` ends it.
- **One gate per host, for every socket.** The control connection is the only thing that asks a
  host that is down. The gate is in the code that opens a socket, so no caller can go around
  it: `RexControl.openDataSocket` (terminal streams and files) and `TunnelSession.open` (port
  tunnels; the session comes from `RexControl.makeTunnelSession`). Both refuse without the
  control connection's welcome. A terminal stream and a tunnel are also refused in the
  background and, after it, until the control connection has its verdict (`holdsData`): the
  pong to `wake()`'s ping, or a fresh welcome. A stream waits (`TerminalStream.mayOpen`) with
  its RESUME token kept, and its own ping at the return has no deadline of its own: it follows
  that verdict. A file's socket is not held in the background: it follows the answer to its
  `…_begin` call, and a send the user started goes on when they leave the app. Calls fail unsent
  before the socket, so the Ports list's reads and a folder listing open nothing either.
- **A dead control socket takes the host's other sockets with it** (`RexControl.hostDied`): when
  it gets no answer, every data socket and tunnel connection to that host is dropped at once,
  with no close frame. A stream keeps its token and raises its fence as on any drop, and resumes
  with the welcome. A close the server answered with leaves them alone.
- The watch's and a notification's one-shot channel makes one attempt for one user action and
  never retries; for a server that is dormant, or while the breaker is open, it opens nothing
  and answers as a connection that failed (`UnreachableActionChannel`).
  `DownHostSocketCountTests` counts every path, one by one, for a host that is down for an hour
  in the foreground and an hour in the background.
- A dormant or held server looks like any offline server: the same screen, the same sidebar
  line, Try Again. Nothing new is shown. A row whose tap asks a down computer to try again (a
  tab or a session of a computer other than the one on screen) has the VoiceOver hint "Tries
  again." (`OfflineCopy.tapHint`).
- **When every computer is silent together** the offline screen of a silent server says "Can't
  reach your computers" and "If Tailscale shows a warning, turn it off and on."
  (`ConnectionProblem.Kind.tunnelDown`), in place of that server's own problem. The rule is
  `TunnelSuspicion` (RexKit, pure): the breaker is open, the phone has a path, at least two
  servers are silent, and none is up or has answered; then ten seconds of that with the app in
  front. `AppModel.checkTunnel` is the one place that reads the governor for it (`breakerOpen`,
  `tunnelHosts`): it asks when the breaker, a connection or the path changes and tells the
  servers (`tunnelNoticeChanged`); `ConnectionProblem.under` words one server. A server that
  refused, answered over HTTP, failed TLS or turned the phone away keeps its own problem, as
  does one whose address is no Tailscale address, a phone with no Tailscale address (that
  screen already says to turn Tailscale on), and one server that is off. It ends in the turn
  the breaker closes (a welcome, an answer) or the app leaves the front, and `ProblemGate` has
  kept each server's own problem meanwhile. Once every server has gone dormant the breaker is
  closed and each says its own problem again: the tunnel's message
  is only for the time the app is still finding out. It is the same screen: no alert, toast,
  sound or button. The sidebar's line stays the server's own.
- `TunnelProbe`: as the breaker opens, one TCP connection to Tailscale's own service on the
  phone (100.100.100.100:53), with the app in front and a tailnet address on the phone. Its
  result is one line in the connection log (`probe`). Nothing reads it: no screen and no retry
  depends on it.
- A drop from online shows nothing for 5 s (`ServerConnection.phaseGrace`); most end sooner.
- `ServerConnection` turns failures into `ConnectionProblem`s (`State/ConnectionProblem.swift`):
  no internet, off the private network, host not on the tailnet, not answering (asleep, refused, or
  not Rex), not allowed, insecure, bad address, unknown. `NetworkWatch` (`NWPathMonitor` off the main
  thread) says whether there's a path and whether the phone has a Tailscale address; a path change
  retries every down server.
- Offline holds still: retries never show as "connecting", only a real connection leaves `.offline`,
  and `ProblemGate` changes the message only for a decisive kind or the same new kind twice.
  `recovering` keeps the screen up, saying the signal is back, until the sessions have reloaded.
- Waking up isn't a problem (`State/ForegroundWake.swift`). iOS suspends the app and its sockets
  die, so a return to the foreground usually finds the connection down for a moment. A drop
  while in the background, or within 5 s after the return, is held: `phase` stays `.online`, the
  tab keeps its last frame with no dim, input queues as usual, and `ServerConnection.waking` puts
  a small Glide beside the tab's title, breathing, if it lasts over a second (`WakingMark`, Core
  Animation, still with Reduce Motion; the sidebar's dot turns grey and still). On the return
  `RexControl.wake()` pings the connection: a failed ping, no pong in 2.5 s, or a drop in those
  seconds reconnects at once, not after the backoff. A reconnect inside the grace shows nothing
  more. No network, a decisive kind or a server that refused ends the hold at once, and a hold
  that runs out shows the offline screen as before. A server already offline when the app left
  keeps its screen.
- `Features/Offline`: `OfflineScreen` takes over the tab area only when no server is up (one down
  server among several is a line in the sidebar). Over a tab whose server dropped, it dims the stale
  tab and blocks touches. `SignalStatic` is Core Animation only (one noise texture, discrete
  `contentsRect` jumps, looping keyframes), off while not in a window, still with Reduce Motion.
- A `*.ts.net` server out of reach while this iPhone has no Tailscale address says "Tailscale isn't
  connected on this iPhone." and offers Get Tailscale (`TailscaleApp`) instead of Open Settings.
  At a `*.ts.net` address, can't-find says Tailscale here is signed in to another account and a
  refusal says Rex lets in only devices on its Tailscale account. Every other case is worded
  without naming a product, and names the computer, never "the Mac".

### Slow calls and the watchdog

No control call has a deadline in the app, and the watchdog is not one. When a call is 5 s old
(10 s on cellular) and nothing at all has come in since, the app sends one WebSocket ping. Only
a ping with no pong in 10 s (20 s) drops the host. A pong ends the watchdog until the next
request goes out, so a slow call on a host that is there costs one ping and nothing else, and
its answer is taken whenever it comes. After that the 30 s keepalive is the only thing that
asks. The most the watchdog can send is one ping for each 5 s (10 s) of silence, which needs
requests that keep going out with none answered (`ControlWatchdogTests`).

This rests on the server answering a ping while it works on a call. Rex answers a ping on the
control connection at once, also during an upload ([rex-protocol.md](rex-protocol.md), Files),
and it does not hold one call behind another (Ordered calls), so its reader is not kept by a
call. A pong during a call that takes more than 5 s has not been measured on a server: if a
server did hold its pong for 10 s (20 s), the host would be dropped 15 s (30 s) into that call
and connected again, and the call would fail as sent with no answer.

No answer time below is measured; "can be slow" is what the call's work suggests.

| Call | Answer time | What the watchdog does |
|---|---|---|
| `write`, `resize`, `client.key`, `client.action` | short | nothing while answers come; one ping when a host is silent for 5 s |
| `format` (a screen, All Output), `blob_read` | can be slow: grows with the scrollback | one ping at 5 s if nothing else comes in |
| `ports`, `process`, `program_status`, `title`, `size` | can be slow: the host reads its processes | the same |
| `list_dir` | can be slow: a large or remote folder | the same |
| `upload_begin`, `download_begin`, `data.connect` | short: they answer a ticket | the same; the bytes go on a data socket, which has its own handshake deadline ([terminal.md](terminal.md), Reconnect) |
| `session.new_block` (a dial tunnel) | can be slow: the host connects first | the same |
| `session.create`, `new_window`, `new_split` | can be slow: a shell starts | the same |
| `session.bootstrap`, `attach`, `view`, `list`, `hosts.list`, `block_creator.list`, `client.keymap` | can be slow on a busy host | the same |

An upload sends no control call per message: it paces itself with `RexControl.ping()`, the
connection's own ping with the pong deadline, so a host that stops answering during an upload
is dropped like any other. A terminal's snapshot comes on its data socket, not as a call.

### The connection log

What happened to the connections is kept in a file, so there is evidence after the app was closed
or crashed. Nothing shows it; `ConnectionLog.export` gives it as text for a diagnostics file the
user shares.

- **Where:** `Application Support/Diagnostics/connections.clog` (`State/ConnectionDiagnostics.swift`),
  left out of backups. Application Support and not Caches, which the system may empty. The types
  are in RexKit: `ConnectionEvent` (one line), `ConnectionJournal` (the rings and the file's
  format), `ConnectionLog` (the queue and the file), `ConnectionReporter` (a `RexControl`'s states
  as events).
- **What it holds:** per server the newest 200 events of its control connection: `connecting`
  (with what asked for the attempt: first, backoff, user, network, foreground, peer),
  `connected` (with the milliseconds the attempt took), `closed` (a kind such as timeout, lost,
  reset, refused, unreachable, dns, tls, http, auth, closed, policy, revision, plus the error
  code, the HTTP status or close code, and the POSIX or TLS code under it), `retry` (the wait
  before the next attempt), `dormant` and `stopped`. And 200 events of the app: each launch with its build
  number, each scene phase, the tunnel breaker opening and closing, the probe of Tailscale's own service that follows an opening, and each change of the network path as four yes-or-no facts
  (satisfied, expensive, constrained, a Tailscale address on an interface). At most 12 server
  rings; one server more pushes out the ring that was quiet longest.
- **The privacy rule:** an event is numbers only (`ConnectionEvent` has no text field). No host
  name, tailnet name, address, URL, computer label, session or pane name, terminal content or
  token can be in the file or in the exported text. A server is a hash of its id (a random UUID),
  salted with a number made on the device, and the export calls it "Server 1", "Server 2" in
  Settings' order; a failure keeps its codes and never its message or the server's close reason.
  `ConnectionLogTests.testNoNameOrAddressReachesTheFileOrTheExport` holds the rule. A new kind of
  event keeps it: add a number, never a string.
- **Cost:** only a change of connection state, of the network path or of the scene's phase
  records; nothing per frame, per key or on the terminal's feed path. `record` reads the time and
  hands the event to a serial utility queue (under a microsecond on the caller). The file is
  written on that queue at most once per 0.5 s however many events came, and at once when the
  app goes to the background. A write appends 32 bytes per event; every 400 appended events the
  file is written again from the rings, atomically, so it stays under 96 KB.
- **Damage:** every event has a check byte. A file that is not the format or holds a damaged
  event is dropped whole and started again; a file that ends inside an event (the app died in a
  write) keeps the whole events before it. A file that is there and can't be read (the phone was
  not unlocked yet) is left alone, and that launch's events stay in memory. Reading it never
  fails the launch.

## First run

`Features/Onboarding` is a short setup guide for an install with no computer yet.

- Who sees it: `AppModel.init` decides once (`FirstRun.start`): no server and
  `Prefs.onboardingDone` false. An update that finds servers sets the flag in `Prefs.init`, before
  the first frame, so existing users never see it. Test launches (`-servers`, `-autoOpen`,
  `-boardDemo`, `-simulateOffline`) and the test host never do. An existing user pays one saved flag.
- Where: `OnboardingCover`, one modifier in `RootView`, lays it over the root while
  `AppModel.guide` is set, so the launch peel opens onto it. Otherwise nothing of it exists.
- Steps (`OnboardingModel`): the welcome (Glide over `SignalStatic`, Get Started, I Have a Pairing
  Code); two cards (what the app is, answering agents), paged with a spring, each with one motion
  the first time it shows; the checklist (`ChecklistCopy`): Rex on the computer (Get Rex, Rex's
  installation page; nothing ticks it), Tailscale on this iPhone, Tailscale turned on in Rex
  (Mac or Linux), the pairing code, then Scan Code or Enter Address. VoiceOver reads each
  step as "Step n of 4, title", with done or not done only for the Tailscale step. Back, and Skip
  or Not Now, are toolbar items of the guide's own navigation stack (`BarLabel`): a plain
  navigation bar on iPhones, the system's vertical bar on the Duo, where they carry symbols; the
  root's bar is hidden while the guide shows, and each step's main button stays at the bottom of
  the screen, in reach. Steps cross-fade; Reduce Motion keeps only the fades. Each screen lays out like the
  offline screen (`OfflineLayout`): two pages on the unfolded Duo, nothing on the crease.
- I Have a Pairing Code opens the scanner only when this iPhone is on a tailnet. Off it, it opens
  the checklist with the Tailscale step marked as the one to do and a header that says why
  (`scanWhenConnected`); when `NetworkWatch` reports the tailnet up and nothing covers the
  checklist (a sheet, the App Store page, the app in the background), the scanner opens by
  itself after a beat to see the tick, once. Back, Scan Code, Enter Address and Not Now drop it.
- The Tailscale tick reads `NetworkWatch`, with no polling of its own (`PrivateNetwork`: IPv4
  100.64.0.0/10 only on a `utun` tunnel, since a cellular network can hand out that range;
  IPv6 fd7a:115c:a1e0::/48 anywhere). Apart from the pairing code above, it only tells. Get Tailscale shows
  the App Store page in the app (`SKStoreProductViewController`; Safari where it can't load).
- It asks for no permission: the scanner asks for the camera when Scan Code opens it, and the
  Beacon offer after pairing asks for notifications.
- It ends with Not Now (`closeGuide`, for good) or a computer added (`addServer`, Settings' Add
  Server; `Prefs.servers` marks the first run done). The `rexduo://pair` link opens pairing and
  sets the guide aside for that run. Setup Guide, on the empty state and in Settings → About,
  opens the checklist again.

## Pairing

`rex server tailscale pair` shows the server's https address as a QR code: no credential, nothing
else. `Features/Pairing` scans it (AVFoundation; the camera permission is asked for when the scanner
opens) and `PairingModel` (`State/Pairing.swift`) takes it from there, one step at a time:

1. Parse and normalize (`PairingCode`). A server that is already saved is opened, not added again.
2. Check (`AppModel.check`). `ServerProbe` (RexKit) sends a plain `GET /api/control`, which Rex
   answers with 426; redirects are not followed, so only the address asked can answer. A failure
   goes through `ConnectionProblem.classify` and is worded by `PairingProblem`.
3. Identify. `ServerPreview` (RexKit) opens one control connection, makes five read-only calls
   (`server.status`, `server.version`, `server.whoami`, `session.list`, `client.list`) and closes.
   It attaches to nothing, so the server drops the client the moment it closes (checked on a
   real server: gone from `client.list` right after, with no `lost` entry). It is one attempt,
   never retried, and its label has no device id, so the helper doesn't take it for the phone
   being open. A call that fails leaves its fields unknown, and `IdentityCopy` words the card
   from what the computer did say.
4. Add & Open (Add, when the computer says it has no session). The server is saved, connects
   and registers for pushes like any other, and `AppModel.openWhenReady` lands on its active tab
   once its sessions are in. A computer with none leaves the empty state saying "No sessions on
   <name> yet." with New Session (`EmptyStateCopy`).

A failed check is worded by `PairingProblem`. A tailnet name this iPhone can't reach while it is
on no tailnet gets one line, "This computer is on a private network this iPhone isn't part of
yet…", with Get Tailscale, and Try Again once `NetworkWatch` reports the tailnet up
(`PairingProblem.offTailnet`); a tailnet name not found while on a tailnet is another Tailscale
account. Out of range and can't-find never offer Add Anyway. A refusal and a guessed address
that isn't there offer Scan Code. An address typed in Settings → Add Computer takes the same
path from step 2 (`AppModel.preparePairing(typed:name:)`), in that page's own pairing sheet.
On the unfolded Duo the cards and the Beacon offer sit on the page past the crease
(`PairingLayout.cardRect`).

The camera's picture freezes under a dim from the moment a code is read; the cards sit on it.
`AppModel.startPairing(prefilled:name:guessed:)` starts at step 2 for an address that didn't come
from a code (a computer another server lists), with no camera.

Phone-only view state (zoomed tabs, when agents started waiting) lives in `PhoneState` and never
goes to the server, so the Mac's layout doesn't change because of the phone.

## Concurrency

- Swift 6 language mode for the app and RexKit.
- UI, state, `RexControl` and `TerminalStream` are `@MainActor`.
- `RexControl` decodes control messages on URLSession's queue, then handles them on the main
  actor. A screen read reply is up to ~1 MB and takes ~4 ms to parse; events take microseconds.
  `DecodedJSON` carries the decoded value across; it is `@unchecked Sendable` because
  JSONSerialization returns immutable values.
- Models and pure helpers (`APCFilter`, `DataFrame`, `TerminalLayout`, `SplitGeometry`) are
  value types.
- Reconnects bump a generation counter; every socket callback checks it before touching state.
- `RexControl` reads time and opens its socket through a seam (`ControlSeam.swift`): a
  `ControlClock` (now, a wait, a repeating timer) and a factory of `ControlSocket`s, whose
  requirements are `URLSessionWebSocketTask`'s own methods. The app always gets the system's clock
  and URLSession's task; tests pass a clock they move by hand and sockets whose callbacks they
  call themselves (`ControlTimingTests`), so the backoff, the deadlines and the generation checks
  are tested without a server or a real wait.
- `ConnectionLog` is called from the main actor and from the network monitor's queue; its state
  lives on its own serial queue, where the file is read and written.
- Ports' relay (`TunnelRelay`) runs off the main actor: after `data.connect` the bytes go between
  the phone's loopback connection (Network, on its own queue) and the tunnel's data connection
  (its own URLSession per open page, with a background delegate queue), 64 KiB at a time, each
  read waiting for the send before it. Only the slot count and the block's state are on the main
  actor.

## Where new code goes

- New server call: a method on `ServerConnection` using `control.call` or `blockCall`, then
  `refreshView`. Add it to [rex-protocol.md](rex-protocol.md).
- New server event: `ServerConnection.handle(event:)` or `handle(sessionID:event:)`.
- New screen: `RexDuo/Features/<Name>/`. Shared view pieces: `DesignSystem/`.
- New setting: only for a choice a user would understand and want to make; otherwise pick the best
  value and add it to "Fixed choices" in `Prefs`. A setting is a property on `Prefs` (saved in
  `didSet`), read with `@Environment(Prefs.self)`; clear a removed one's key in `Prefs.migrate`.
- Pure logic: its own type, with tests in `RexDuoTests` or `Packages/RexKit/Tests`.
- Something an extension needs too (a link, later the snapshot widgets read): `GlanceModel` in
  `Packages/RexGlance`, Foundation only, with tests in `Packages/RexGlance/Tests`.
- A message the user reads: the words in `State/Messages.swift` where it says something the app
  says elsewhere too (a computer is offline, not sent, the pane closed, Rex there is too old).
  An error is worded from its code (`Messages.reason`), never from the server's text, an
  error's `localizedDescription` or an action's id; RexKit reports what happened
  (`TerminalStream.Notice`) and the app words it. A computer is named by its name, never "the
  server" or "the Mac". Why an agent waits is `WatchScreen.words(why:)` in `GlanceModel`, the
  one set for the app, the widgets and the watch.
