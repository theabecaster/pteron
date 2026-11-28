# Glance surfaces

What the app offers outside its own window: the agents widget on the Home Screen and the Lock
Screen, two controls, the links they open the app with, and a watch app that shows the same
agents on the wrist.

## The agents widget

One widget, "Agents" (kind `dev.abrahamgonzalez.rexduo.widget.agents`, `PteronWidgets/GlanceWidget.swift`),
in six families. It says how many agents need you, where, and for how long, as the app last
saw them. It connects to nothing: it reads the snapshot the app wrote (below).

| Family | Shows | A tap opens |
|---|---|---|
| `systemSmall` (also StandBy) | someone waits: the headline; the ring, name and wait of the agent waiting longest; then its place, or the snapshot's age. Working or an error: the headline over Glide in the state's ring, and the other counts. Quiet, done, no agents, no snapshot, no machines: Glide over one line ("All quiet · 4 idle", "No agents running", "Open Pteron", "Pair a computer") | `rexduo://waiting`, or `open` when nobody waits |
| `systemMedium` | the headline, the machine line and the other counts; on the right the agent waiting longest as a row, and the strip of agent tiles (up to 8, "+N"). No agents: Glide, "No agents running" and the machines | a row or a waiting agent's tile: `rexduo://pane?…`; elsewhere as small |
| `systemLarge` | someone waits: the headline; what the longest-waiting agent asks; up to 4 waiting agents; the strip; a card per machine where there is room. Nobody waits: a Glide hero with the headline, the strip, one card per machine | as medium |
| `accessoryCircular` | a raised hand over the waiting count; with nobody waiting, the mark over the working count in an arc; else the mark | `waiting` |
| `accessoryRectangular` | "2 waiting"; "Claude · api › tests"; "waiting 12 minutes" or the age | `waiting` |
| `accessoryInline` | "2 need you · 3 working" | the app |

- **Configured the iOS way, by size.** There are no widget settings and no intent.
- **The headline** is the agent board's: "2 waiting", "1 error", "3 working", "All done",
  "All quiet", counted over the machines that were connected at the write (`GlanceDigest`;
  a test in the app holds it to `AgentBoard` over the board's own demo scenarios).
- **Many machines.** The headline sums them, a machine's name shows only when there are
  several, and nothing scrolls: what doesn't fit is "+N more". A snapshot keeps at most 8
  waiting agents per machine.
- **The gallery and the placeholder** show made-up agents (`GlanceDemo`), never the person's.
- The widget and the controls run on an iPad too, from the same snapshot. On a Mac, the
  iPhone's widget can sit on the desktop, and a click there hands off to the phone.
- **No Live Activity**, by decision.

### Calm

The widgets never ask for attention. `CalmRuleTests` (in `Packages/RexGlance`) reads the
sources and fails on a line that breaks one of these:

- **Passive.** A widget exists only where the person added one. Nothing in the app offers,
  suggests or mentions adding a widget, and the app looks the same with or without one.
- **No Live Activity**: no ActivityKit, no `NSSupportsLiveActivities`.
- **No sound, haptic or notification** from the widgets, the watcher or the writer.
- **Motion only once, on a change, and only through `GlanceMotion`**
  (`PteronWidgets/Views/GlanceMotion.swift`, the one file of the widget path that may hold
  any). A count's digits roll (`numericText`) when it changes; a tile whose agent's state
  changed, and the top row when the agent waiting longest changes, are pushed up from below.
  Each animation is tied to a value (`.animation(_, value:)`), 0.4 s at most. Nothing moves
  with the screen dimmed (`isLuminanceReduced`) or where the system draws vibrant (StandBy at
  night, the Lock Screen); with Reduce Motion it is a fade. Never: `repeatForever` or a
  repeating effect, `symbolEffect`, `TimelineView`, `withAnimation`, springs, `.timer` or
  `.relative` text. The ring is still, the complications and the shared packages have no
  motion, and a wait's time still changes by the minute only.
- **A stale widget is quiet.** Its counts dim (to 60% on the Home Screen) and a small line in the secondary color says
  "as of 12:04" or, after an hour and on the Home Screen sizes only, "Open Pteron to refresh"
  (`GlanceDigest.refreshText`, from
  `Brand.appName`). "Last seen 12:04" is in the secondary color and not bold. No warning color,
  no icon, and the colored edge is off.
- **No extra work.** One call reloads the widgets (`GlanceReload`, of their own kind only),
  and `WriteThrottle` alone decides when: at most once in 10 s while the app is in front (360
  an hour, which iOS doesn't count against the widget's budget), at most once each time the app
  leaves, and never while it is closed. The writer schedules no background work and wakes nothing.

### The snapshot

`glance/snapshot.json` in the App Group `group.dev.abrahamgonzalez.rexduo`, about 1 to 4 KB
(`GlanceSnapshot`, `GlanceStore`):

```json
{
  "v": 1,
  "seq": 4182,
  "asOf": "2026-11-19T12:04:00Z",
  "palette": {
    "dark":  {"appearance": "dark", "bg": "#22272e", "fg": "#adbac7", "accent": "#539bf5",
              "ansi": ["#545d68", "#f47067", "#57ab5a", "#c69026", "#539bf5", "#b083f0"]},
    "light": {"appearance": "light", "bg": "#ffffff", "fg": "#1f2328", "accent": "#0969da", "ansi": ["…"]}
  },
  "machines": [{
    "id": "<ServerConfig.id>", "name": "studio", "link": "live", "seen": "2026-11-19T12:04:00Z",
    "counts": {"waiting": 2, "error": 0, "working": 3, "done": 1, "idle": 4},
    "busy": [{"kind": "codex", "symbol": "hexagon", "state": "working"}, {"symbol": "terminal", "state": "idle"}],
    "waiting": [{
      "session": "session:…", "window": "window:…", "block": "block:…",
      "kind": "claude", "name": "Claude", "symbol": "asterisk", "why": "question",
      "place": "api › work", "since": "2026-11-19T11:52:00Z", "record": "<status record id>",
      "msg": "Which database should I use?"
    }]
  }]
}
```

- **One writer.** Only the app writes it (`GlanceWriter` → `SnapshotFileWriter`;
  [architecture.md](architecture.md), The snapshot for the widgets). The write is atomic and
  the file is protected until the first unlock after a restart; before that a reader finds
  nothing and shows its placeholder.
- **What it holds.** What a push already shows, and nothing else: no server address, no token,
  no secret (a test lists every key the file may have). `id` is the server's id in the app, a
  random UUID. The file never syncs and stays on the phone.
- **Version rule.** `v` changes only for a breaking change. A field added later keeps `v` and
  is optional: `seq` and a machine's `seen` are such fields, and the file as first specified,
  without them, is a test fixture that must keep decoding. A reader ignores fields it doesn't
  know, takes a `link` word it doesn't know as `stale`, and shows its placeholder for a higher
  `v`, a missing file or one that isn't a snapshot.
- **`kind` and `symbol`.** An agent's glyph is drawn by its `kind`: its maker's mark, a custom
  symbol (`AgentGlyph` in GlanceUI; the marks and their sources are in `Brand/agents/README.md`).
  `symbol` is the SF Symbol the app had for that kind (`AgentKind.symbol`), still written for
  readers older than the marks, and drawn when `kind` is missing or has no mark in the reader:
  another program, Amp (which publishes only a wordmark), or a kind from a newer app.
- **`seq`** counts the app's writes across launches (the count is kept in a file of its own
  beside the snapshot). It orders two snapshots when the clock doesn't
  (`GlanceSnapshot.isNewer`, which falls back to `asOf` when one has no `seq`).
- **`link`** is the board's rule at the write: `live` (connected, sessions loaded), `stale`
  (the connection was down), `never` (not connected since launch and never written). `seen` is
  when the app last wrote the machine while it was live.
- **A machine the app hasn't reached since it was launched** keeps what the snapshot before
  said about it, marked `stale`: a launch with a server down doesn't wipe it.
- **`since`** belongs to a wait, not to an agent, and means "waiting at least since". Rex gives
  no start time for a wait, so it is when the phone first saw it. It carries over from the
  snapshot before only for the same wait: the same server and pane, the same status record
  with an id that isn't empty, the same message and the same reason (`GlanceSince`). Any other
  case starts again from when this run of the app first saw the agent waiting, so the time
  shown is never too long.
- **`msg`** is clipped to 200 characters. Only the large widget shows it.
- **`busy`** (optional): a machine's agents that don't wait, as the strip's tiles draw them:
  `kind` (left out for another program), `symbol` and `state` (`error`, `working`, `done`,
  `idle`), the most urgent first. Nothing private, and at most 12 over all machines: errors
  first wherever they are, then working, done and idle (`GlanceSummary.capBusy`). A machine the
  app hasn't reached keeps its last list. Built in the writer's one pass from `agentKeys`, with
  no metadata read. The watch ignores it; a widget reading a file without it draws each
  machine's counts where the strip would be. It is not part of the picture that decides a
  reload (`visibleKey`), so it adds no reload: agents that only trade states show at the next
  reload.
- **`palette`**: the themes chosen for Dark Mode and for Light Mode, each with its own
  `appearance`, since a dark theme can be the one chosen for Light Mode.
- Every date is a whole second.

### When the app writes, and when the widgets redraw

`GlanceWatcher` tells the writer that something changed, and `WriteThrottle` decides:

| | |
|---|---|
| A new waiting agent | written within 0.5 s |
| Any other change | written 2 s after the first change not yet written |
| Going to the background | always written, inside a background task, through the same writer |
| Reload while the app is active | when the picture changed (counts, who waits, links, colors), at most once in 10 s |
| Reload on the way to the background | only if the picture changed since the last reload |
| While active with a machine connected | rewritten and reloaded every 15 min, so "as of" doesn't age while the app watches |

- The picture includes, for each waiting agent, since when it waits, why, and what it asks. An
  agent that is answered and asks again in the same pane is a new picture, so the widgets
  reload and never keep the old question and time.
- A message that changes while its agent goes on waiting without a change of state is not
  seen by the watcher: it reaches the file at the next write, at most 15 minutes later while
  the app is open.
- The app never writes from a launch that doesn't reach the screen, and never in a test launch.
- **Known limit.** Beacon doesn't push "stopped waiting", and the widget can't ask Rex. An
  agent answered on the computer while the app is closed stays in the widget, dated, until
  the app is next opened.

### Age

The timeline has an entry for now and one for each moment the snapshot's age changes what is
shown, and never reloads by itself (`GlanceTimeline`, `GlanceFreshness`):

| Age of `asOf` | Shown |
|---|---|
| under 2 min, machine live | as current |
| 2 min to 1 h | with "as of 12:04" |
| over 1 h | counts, rows and tiles at 60%; on the Home Screen sizes also "Open Pteron to refresh". The Lock Screen accessories keep their counts, dimmed, and say nothing more: no refresh line and no running wait time |
| a machine that was down at the write | its agents dimmed and last, with no running wait time; over them the headline says "Last seen 12:04", never "All quiet" |

- A wait's length counts by itself (a system date text), with no reload.
- A snapshot dated in the future (the clock was set back) is taken as written now.

### Privacy

- **Private:** an agent's name, its place and its message, and on the Home Screen sizes a
  machine's name. The views mark them `privacySensitive()`, and that is what redacts them: the
  system draws marked views as bars wherever it asks for privacy.
- **Data Protection Complete** (`com.apple.developer.default-data-protection` on the
  extension) redacts nothing by itself. It makes Complete the default protection of files the
  extension creates (it creates none) and tells the system the widget's content is protected
  while the phone is locked, which is when the system is expected to ask for privacy.
- **A message is never on the Lock Screen:** no accessory carries one
  (`GlanceDigest.accessory`), and the large widget's is private.
- **Locked, the accessories carry counts only.** When the system asks for redaction, the
  accessory is built without any name or place, instead of leaving grey bars. Counts always show.
- **To check on a device** (a simulator has no passcode, so it never locks this way): with
  Complete, the widgets must still draw after the first unlock and while unlocked, and redact
  while locked. If they don't draw, drop the entitlement and keep the Lock Screen to counts.

### Design

- **Colors** come from the snapshot's palette, slot by the system's mode, drawn in the
  theme's own appearance (`GlanceColors`), through the same `Color.mix` and fractions as
  `TermTheme.Chrome` (a test in the app compares them for every theme in both slots, and every
  agent's tint and glyph color with the app's).
- **State** has the board's colors (waiting ANSI 3, error 1, working 4, done 2) and always a
  word or a badge as well. A 1.5 pt edge in the most urgent state's color shows only while
  someone waits, fails or works. The headline takes its state's color ("All quiet" plain;
  "Last seen" and an old snapshot never a warning color). `GlanceCanvas` carries one faint,
  still wash at the top in the same color, else the theme's accent.
- **Glide** (`GlanceGlide` and `GlanceGlideMark` in GlanceUI, shared with the watch) stands
  where nothing needs a look; working or failing with nobody waiting, it sits in the state's
  still ring.
- **Tiles** (`GlanceTileView`) follow the sidebar's rule: a circle for an agent, a rounded
  square for another program, the agent's tint and glyph (`kind`, else `symbol`), and the
  state's badge. Idle and last-known tiles are dimmed. A waiting agent's tile opens its pane;
  the others open what the widget opens.
- **`GlanceRing`** is the board's ring with no motion. Its glyph is never recolored: only a
  kind without a mark takes its tint (`AgentGlyph.ink`); the state's color is on the ring,
  never on the mark.
- **Type**: the system font; Dynamic Type stops at xxLarge.
- **Tinted, clear and vibrant** (`GlanceStyle`): no palette; text is primary or secondary,
  never under 60%; a state reads from its shape and its word.
- **A text that updates itself needs a frame of a set width**, never `fixedSize()`: on the
  Home Screen that leaves the whole widget empty. A view drawn in a test doesn't show it, so
  a change to the wait time's layout is checked on a simulator's Home Screen.

### Files

`PteronWidgets/`: `GlanceWidget.swift` (the widget and the view that picks a family),
`Provider.swift` (the timeline), `Demo.swift` (the gallery), `Views/` (the families,
`GlanceStyle` and `GlanceMotion`; compiled into the app's tests too, which draw every size,
state and mode, hold the Lock Screen's accessories to the same pixels with and without
`busy`, and the longest names at the largest text inside every size: `GlanceRenderTests`).
Everything the views show is decided in `GlanceDigest`, which is pure (`GlanceTilesTests`).

## The watch

A watch app, `PteronWatch` (bundle id `dev.abrahamgonzalez.rexduo.watchkitapp`), and its
complications, `PteronWatchWidgets` (`….watchkitapp.widgets`). From the wrist: who needs you,
where, and for how long, as the iPhone app last saw it.

- **It shows, and it can give two answers.** A row opens its detail screen. Under a waiting
  agent are Enter and Interrupt, each behind a question (Actions from the wrist, below).
  Nothing else on the watch touches a session.
- **It connects to nothing.** A watch can't reach a Rex server (there is no Tailscale for
  watchOS), so everything it knows is the snapshot the phone's app sent, and an action goes
  through the phone's app. It can't run without the iPhone app
  (`WKRunsIndependentlyOfCompanionApp` is false).
- **One thing goes from the watch to the phone:** an action the person confirmed. There is no
  other message and no request for a refresh, so the watch wakes the phone's app only for that.
- **No settings** on either device, and the iPhone app shows nothing about the watch.

### From the phone to the watch

```
GlanceWriter (writes the phone's file)
   └─ each written snapshot, with the file's bytes ─▶ GlanceBridge ─ WatchDelivery decides ─▶ WCSession
                                                                                                 │
watch:  WatchSession (delegate) ─▶ WatchInbox decides ─▶ the watch's glance/snapshot.json ◀──────┘
                                        └─ replaced ─▶ WatchReload (complications) and WatchModel (the app)
```

- **`GlanceBridge`** (`Pteron/State/GlanceBridge.swift`, owned by `AppModel`) is given each
  snapshot the writer writes, with the bytes that went to the file, and sends them on as
  `["s": <bytes>]`. It knows nothing of `AppModel` or the servers. The one message it takes
  from the watch is an action, which it hands to `GlanceActions` and answers.
- **The session is activated at launch** (`listen()`, after `init`, off the launch path), so an
  action that woke the app is delivered, and without asking anything first (its properties
  hold real values only after activation). The test host and a test launch that writes no
  snapshot never touch WatchConnectivity.
- **Before each send** it checks that the session is activated, a watch is paired and the
  watch app is installed. Otherwise nothing is sent, and nothing counts as sent.
- **When the session opens** (activation ends, the watch app gets installed, or the person
  switched watches and the session was activated again) the newest snapshot goes once, so a
  new watch app has the state at once.
- **`WatchDelivery`** (GlanceModel, pure) decides what goes, since every delivery can wake the
  watch:

  | | |
  |---|---|
  | A change in who waits | `updateApplicationContext` at once, and the next no sooner than 30 s after the last delivery |
  | Any other change (counts, a link, a color) | no sooner than 60 s after the last delivery |
  | Nothing new to show | nothing |
  | While the app watches and nothing changes | the 15 min restamp, so "as of" doesn't age |
  | The app goes to the background | a change still held goes now, inside the same background task as the file's last write |
  | The count of waiting agents changed, a complication is on a face, and the day's budget has transfers left | also `transferCurrentComplicationUserInfo`, which the system delivers ahead of the queue |

- **The worst case** is 120 deliveries an hour, only while the iPhone app is in front and who
  waits changes all the time; an open, quiet app makes 4 an hour, a closed or suspended one
  none. The system keeps only the newest application context. Complication transfers are at
  most 50 a day, by the system's budget.
- **`WatchSession`** (the watch's delegate) hands each payload to **`WatchInbox`** (GlanceModel,
  pure), the one writer of the watch's `glance/snapshot.json`, in the watch's own container of
  the same App Group. The bytes are written as they arrived. Which payload wins:

  | Arrived | Kept on the watch | |
  |---|---|---|
  | not a snapshot | anything | dropped |
  | a higher `v` than the watch app reads | anything | written; the watch shows its placeholder |
  | a snapshot | nothing, or a file it can't read | written |
  | a snapshot | dated over 2 min in the watch's future (the phone's clock went back) | written |
  | a higher `seq` | a snapshot | written |
  | the same or a lower `seq` | a snapshot | written only when its `asOf` is later (the app was installed anew and its count started again); else dropped, as late or as the same snapshot delivered twice (a context and a complication transfer) |
  | no `seq` on either side | a snapshot | written when its `asOf` is later |

- **After a write** the watch reloads its complications' timeline (`WatchReload`, the one
  call) and the open app reads the file again.
- **While the watch app isn't open**, the system starts it in the background for a delivery
  (`.backgroundTask(.watchConnectivity)`), and the task stays until the session has nothing
  more to hand over, 10 s at most (`WatchDrain`). The watch app asks for no background time of
  its own: no refresh schedule, no extended session, no background mode.
- **The phone away, asleep, or the app closed:** the watch keeps the last snapshot and dates
  it. It never claims to be current: under 2 min it shows as is, then "as of 12:04", and after
  an hour everything dims with "Open Pteron on iPhone to refresh" (`GlanceFreshness`, the
  widgets' rule). The open app works its screen out again at those moments by itself.
- **Versions.** The widgets' rule holds: the watch app ignores fields it doesn't know (and
  keeps them on disk), reads a file from an older phone app that lacks later fields, and
  shows "Open Pteron on iPhone" for a higher `v`.

### What it shows

`WatchScreen` (GlanceModel, pure) is built from the widgets' `GlanceDigest`, so the watch
counts, orders, dates and dims as they do.

| Snapshot | The watch app |
|---|---|
| none yet, one it can't read, or a higher `v` | the mark and "Open Pteron on iPhone" |
| no computers | "No computers yet" |
| agents | the headline ("2 waiting"), the computer line when there are several, the age when there is one; the waiting agents, the longest wait first: ring, name, "Needs your permission" (the sidebar's words: `WatchScreen.words(why:)`, one set for every surface), "12 minutes", place; "+N more"; then one row of counts per machine |
| a machine that was down at the write | its agents dimmed and last, with no running wait time; the headline says "Last seen 12:04" |
| over an hour old | everything dimmed, no running wait times, "Open Pteron on iPhone to refresh" |

- **A row's detail screen:** the ring, the name, what it waits for and for how long, what it
  asks, its place and its machine, then Enter and Interrupt. A row that is only last known, or
  whose wait the snapshot can't name, has "Answer on your iPhone or computer" instead. If the
  agent stops waiting while the screen is open, it says "No longer waiting".
- **Complications and the Smart Stack** (kind `dev.abrahamgonzalez.rexduo.widget.agents`):

  | Family | Shows |
  |---|---|
  | `accessoryCircular` | a raised hand over the waiting count; else the mark over the working count in an arc; else the mark |
  | `accessoryCorner` | the count with "waiting" or "working" curved beside it; else the mark |
  | `accessoryRectangular` (also the Smart Stack) | "2 waiting"; "Claude · api › tests"; "waiting 12 minutes" or the age |
  | `accessoryInline` | "2 need you · 3 working" |

  The circular, rectangular and inline families are the iPhone Lock Screen's views and the
  timeline is the iPhone widget's (`PteronWidgets/Views`, `Provider.swift`), compiled into the
  watch extension as they are. A tap opens the watch app.
- **In the Smart Stack** an entry in which an agent waits on a connected machine, in a
  snapshot under an hour old, has a relevance score (the number waiting, 10 at most); every
  other entry has none (`GlanceDigest.relevance`). It only orders the stack.

### Actions from the wrist

Enter and Interrupt for a waiting agent: Return (`\r`) or Control-C (`0x03`) typed into its
pane. A question's notification on the phone has the same two actions, and they go through
the same `GlanceActions` and the same guard: [notifications.md](notifications.md), Answering
from a notification.

```
watch:  [Enter] [Interrupt] ─ tap ─▶ "Send Enter to Claude?" ─ confirmed ─▶ WatchActions ─▶ WatchSession.send
                                                                              (WCSession.sendMessage, one message)
phone:  WCSessionLink ─▶ GlanceBridge ─▶ GlanceActions: read the status ─▶ ActionGuard ─▶ one terminal.write
                                                             └────────── the answer, one word ──────────▶ watch
```

- **A tap only asks.** Each button opens a question ("Send Enter to Claude?", "Interrupt
  Claude?"); only the question's own button sends. There is no swipe action, no Double Tap and
  no shortcut, and nothing is offered with the wrist down.
- **What travels:** a `WatchAction` (GlanceModel): the tap's own id, the kind, and the wait it
  answers (`Target`: the server's id, session, pane, the status record's id, and the wait's
  fingerprint). The fingerprint (`ActionGuard.fingerprint`, the snapshot's optional `fp`) is a
  hash of the record's state, kind and whole message, written by the phone from the record as
  the server gave it. A row offers actions only when it is current and has a record id and a
  fingerprint.
- **On the phone, `GlanceActions`** (`Pteron/State/GlanceActions.swift`) does three things, in
  order:
  1. reads the pane's status records from the server, now;
  2. `ActionGuard.allows`: the pane's top record is still `blocked`, has the same id, and gives
     the same fingerprint. Anything else types nothing;
  3. types once. A write that left is never sent again, and a tap that reaches the phone twice
     is answered from memory.

  A wait is answered once, whether from the watch or from a notification's action: for
  15 s after a write left for it, another action for the same wait types nothing and the
  watch hears `changed` ([notifications.md](notifications.md), Answering from a
  notification).
- **Which connection it uses:**

  | The phone's app | Status read | The write |
  |---|---|---|
  | in front, the server connected, the pane on screen | the server's connection | the pane's own input queue (`TerminalStream.sendOnce`), behind what was typed on the phone; dropped, never sent late, if it can't leave within 3 s |
  | in front, the server connected, the pane not on screen | the server's connection | one `terminal.write` on that connection (no stream, so no queue to pass) |
  | anything else: in the background, woken or launched by the system for the message, or the server not connected | one short connection (`OneShotActionChannel`) | one `terminal.write` on it, then it closes |

- **The short connection** says hello with a label that has no device id (so no Beacon takes
  it for the app being open), attaches to the pane's session alone (Rex answers for a pane only
  on a connection attached to its session), reads, writes at most once and closes. It asks for
  no session list, no server events and no data stream, so nothing is opened, claimed or
  resized. It gets one attempt.
- **A wake starts no server.** The system launches or resumes the app in the background to
  deliver the message, and builds its scene there. `sceneVisible()` is not called while the app
  is in the background (`ScenePhases.appearedCounts`), so no server connects, and no snapshot
  is written by such a launch (`GlanceWatcher`).
- **The answer,** and the one quiet line the watch shows under the agent (`WatchText.outcome`):

  | Answer | When | The watch says |
  |---|---|---|
  | `sent` | the computer took the write | "Sent Enter" |
  | `changed` | the guard refused, or the pane or session is gone | "Not sent. It no longer waits for this." |
  | `unreachable` | the phone couldn't reach the computer; nothing left the phone | "Not sent. Your iPhone can't reach the computer." |
  | `unconfirmed` | the write left and no answer came, or no reply came from the phone in 30 s | "Couldn't confirm. Check the pane." |
  | (none) | the message never reached the phone | "Not sent. Can't reach your iPhone." |

- **Nothing is tried again by itself,** on either device. While an action is on its way the
  buttons are gone ("Sending…"). After `sent`, `changed` or `unconfirmed` they stay gone for
  that wait; after the two "not reachable" lines the person may tap again
  (`WatchActionState`). There is no sound, haptic or motion for any of it.
- **Limits:** the phone gives the status read 5 s and the write's answer 8 s, so it answers
  well inside the watch's 30 s.
- **In a test launch** (`-glanceLive YES -autoOpen <label>`) the phone types only into panes of
  the session with that label; any other launch that shows made-up state takes no action.
- Unchecked on a device: the wake of a suspended or closed app by a real watch, how fast an
  unreachable phone fails there, and Enter and Control-C as raw bytes in a program that asked
  for the kitty keyboard protocol.

### Calm, on the watch

`CalmRuleTests` reads the watch's sources too:

- **No sound, no haptic, no notification** from the watch app or its complications, and no
  Live Activity. (A push from Beacon still mirrors to the watch as iOS does it; this app adds
  nothing to that.)
- **Complications have no motion of their own**, nor does anything they share with the
  iPhone's widgets (`PteronWatchWidgets`, `Packages/RexGlance/Sources`, and the accessory views
  and `GlanceStyle` they compile from `PteronWidgets`). The iPhone's Home Screen sizes move
  only through `GlanceMotion`, which the watch doesn't compile.
- **The watch app moves only through `WatchMotion`** (`PteronWatch/Views/WatchMotion.swift`):
  no other file of the app may hold an animation, and every modifier there that moves reads
  Reduce Motion and the wrist and asks `WatchMotion` what to do (Motion, below).
- **Nothing to press** but a row and, on its screen, Enter and Interrupt with their question:
  no field, toggle, gesture, alert or intent, and nothing that sends without the confirmation.
- **One message is sent to the phone**, a confirmed action, from one call; the watch app opens
  no connection, and sends nothing again by itself.
- **On the phone** the action starts no server, types through one call, and never repeats it.
- **No prompt on the iPhone:** the app never mentions the watch.
- **One reload call** on the watch, only after a delivery replaced the file.
- **A stale watch is quiet:** dimmed, a small line in the secondary color, no warning color,
  and nothing raised in the Smart Stack.
- **The delivery rate is bounded** as above.

### Privacy on the wrist

- **What an agent asks is not shown with the wrist down.** While the screen is dimmed
  (`isLuminanceReduced`), the detail screen leaves the message out altogether
  (`WatchScreen.Row.message(wristDown:)`).
- **Names, places, machines' names and the message are `privacySensitive()`**, in the app and
  in the complications: the system redacts them where it asks for privacy (a dimmed
  always-on screen, a locked watch).
- **A complication asked to be private carries counts only:** it is built without any name or
  place (`GlanceDigest.accessory(private:)`), and no complication ever carries a message.
- **The file** holds what the phone's does, protected until the first unlock after a restart.
  It holds no server address, token or secret, and it stays on the watch.
- Unchecked on a device: how the system redacts on a real watch (wrist down with Always On,
  locked).

### Design

- **Colors:** the theme chosen for Dark Mode when it is a dark theme, else the default dark
  theme (`WatchScreen.palette`), over the watch's black. Row platters are the sidebar color at
  90%. State has the board's colors and always its words.
- **The brand** (`GlanceGlide` in GlanceUI, from `Brand/AppIcon.icon`): behind every screen,
  the icon's deep blue fading to black (`containerBackground`); black with the wrist down.
- **State colors:** the headline takes its state's color; "All quiet" is the foreground. An old
  snapshot keeps the foreground, dimmed, and "Last seen" stays secondary: a stale watch never
  shows a warning color. A machine's counts are each in their state's color (idle secondary),
  except on a machine that is down or in an old snapshot, where they are all secondary.
- **Contrast:** every text color reads at 4.5:1 or more on black, on a platter and on the top
  of the ground, for the default theme (`WatchStyleTests`). Secondary text is the foreground at
  72%, not the app's 55%, which reads under 4.5:1 at the watch's sizes.
- **Type:** the system's text styles, which follow the person's text size; rows wrap.
- **Rings:** `GlanceRing`. The longest-waiting agent's ring in the list, and a waiting agent's
  ring on its own screen, have a soft glow in the waiting color.
- **Native:** a `NavigationStack` and a `List`. Double Tap is not claimed.
- **Complications** take the watch face's tint (`widgetAccentable` on the count and the first
  line). On a face in full color the count takes the waiting color while someone waits.

### Motion

Short and soft, in the app only (`WatchMotion`). No haptic or sound goes with any of it.

| Moment | Motion | With Reduce Motion | Wrist down (Always On) |
|---|---|---|---|
| The list first shows | the headline, rows and machines fade in and rise 10 pt, 45 ms apart (the first seven), a 0.5 s spring | a 0.25 s fade | there at once |
| A delivery changes the screen | the count's digits roll (`numericText`), rows come and go, colors change: 0.4 s | a 0.2 s cross-fade | no animation |
| Nothing to list | Glide glides in from the lower left, tilted and small, and lands (0.9 s spring); the line follows | a fade | there at once |
| An agent's screen opens | the system's slide; the ring springs up from 60% and the words rise after it | a fade | — |
| An agent waits | its ring's glow breathes, 1.8 s in and 1.8 s out, while it is on screen: the longest-waiting row in the list, and the agent's own screen | a still glow | no glow |

- **One loop only:** the breath. Everything else runs once and stops.
- **The first entrance waits 0.25 s** after the screen appears, so it isn't spent behind the
  system's own opening of the app.
- No zoom transition: on watchOS 27.2 `navigationTransition(.zoom)` keeps the system's slide.
- The app shows nothing until it has read its file (`WatchModel.loaded`), so "Open Pteron on
  iPhone" never flashes, and Glide never glides in, on the way to the list.

### Files and tests

- `PteronWatch/`: `PteronWatchApp.swift`, `WatchSession.swift` (the delegate, the background
  task and the one send), `WatchModel.swift`, `WatchActions.swift`, `WatchReload.swift`,
  `WatchDemo.swift`, `Views/`.
- `PteronWatchWidgets/`: the bundle, the widget and the corner view.
- `Pteron/State/GlanceBridge.swift`: the bridge and `WCSessionLink`, the system's session.
  `Pteron/State/GlanceActions.swift`: the actions and their two channels.
- GlanceModel: `WatchDelivery`, `WatchInbox` (with `WatchPayload`, `WatchDrain`), `WatchScreen`
  (with `WatchText`), `WatchAction` (with `ActionGuard`, `WatchActionWire`, `WatchActionState`),
  each with tests that run on macOS.
- `GlanceBridgeTests` (the app's tests) runs the bridge against a stand-in session, and
  `GlanceActionsTests` runs the actions against a stand-in channel and a stand-in server: the
  order, the one write, each refusal, and that a wake starts no server. RexKit's
  `StreamInputTests` holds `sendOnce` to the queue's rules.
- `PteronWatchTests` runs in the watch app on a watchOS simulator (scheme `PteronWatch`):
  the model, `WatchStyleTests` (what Reduce Motion and the wrist turn each motion into, the
  headline's colors and the contrast of every text color), and `WatchRenderTests`, which draws
  the list, the detail screen and every complication family in every state into the test
  host's `tmp/watch-renders`, each part where it lands (`watchLanded`).

```sh
xcodebuild -project Pteron.xcodeproj -scheme PteronWatch -destination id=<watch-sim-id> \
  -derivedDataPath build/dd-watch test
xcrun simctl install <watch-sim-id> build/dd-watch/Build/Products/Debug-watchsimulator/PteronWatch.app
xcrun simctl launch <watch-sim-id> dev.abrahamgonzalez.rexduo.watchkitapp -glanceDemo several
```

- The watch app takes `-glanceDemo <scenario>` (Debug builds) for its own file, with
  `-glanceDetail YES|later`, `-glanceDemoThen <scenario>` and `-glanceDim YES`
  ([debug-args.md](debug-args.md)). For the actions: `-glanceScroll YES` opens the agent's
  screen at its end, `-glanceAsk enter|interrupt` with that question up,
  `-glanceOutcome sending|sent|changed|unreachable|unconfirmed|noPhone` with that line and
  nothing sent, and `-glanceConfirm enter|interrupt` sends that action 6 s after launch as a
  confirmed tap would (the phone logs `GLANCE_ACTION <kind> <answer>`). **`-glanceConfirm`
  types into a real pane:** use it only with the phone's app launched or saved as
  `-glanceLive YES -autoOpen zz-…`, so the watch knows that session alone.
- Reduce Motion: `xcrun simctl spawn <watch-sim-id> defaults write com.apple.Accessibility
  ReduceMotionEnabled -bool YES`, then launch again. To record the motion: `xcrun simctl io
  <watch-sim-id> recordVideo --codec=h264 motion.mp4` in the background, then interrupt it.
- The iPhone app's `-glanceDemo` also sends its scenario to a paired watch simulator. A Debug
  build logs `GLANCE_WATCH seq=<n> complication=<0|1>` for each delivery (`GLANCE_WATCH demo
  bytes=<n>` for a demo) and `GLANCE_WATCH <event> activated=… paired=… installed=…` for each
  change of the session. Between two simulators the session can take a minute or two to
  activate after a launch.
- A watchOS simulator runtime is needed to run the watch app and its tests, not to build
  them. Delete a paired watch simulator a test made (`xcrun simctl delete <id>`).

## Controls

The extension `PteronWidgets` (bundle id `dev.abrahamgonzalez.rexduo.widgets`) declares two
controls for Control Center, the Lock Screen's bottom slots and the Action button
(`PteronWidgets/Controls.swift`):

| Control | Kind | Opens |
|---|---|---|
| Open Pteron | `dev.abrahamgonzalez.rexduo.control.open` | `rexduo://open` |
| Jump to Waiting | `dev.abrahamgonzalez.rexduo.control.waiting` | `rexduo://waiting` |

- Each is a `ControlWidgetButton` whose action is `OpenLinkIntent`
  (`PteronWidgets/OpenLinkIntent.swift`), an intent of our own with `openAppWhenRun`. The file
  is compiled into the extension and into the app: the system finds the intent in the
  extension and runs it in the app, which it brings forward first.
- In the app the intent does one thing: it opens the link's URL
  (`Pteron/App/OpenLinkIntent+App.swift`). So a control takes the same single path into the app
  as any other link, `onOpenURL`, and nothing is injected into the intent.
- The intent is marked not discoverable, to stay out of Shortcuts and Spotlight.
- The extension links `GlanceModel` (for `DeepLink`) and nothing else of ours: no RexKit, no
  engine.
- Every word and symbol the controls show is in `ControlText`, at the top of `Controls.swift`.
  The name is `Brand.appName` (GlanceModel). The symbols are custom ones, `mark.open` (the
  mascot) and `mark.waiting` (the mascot with a mark for a waiting agent), symbol templates in
  the extension's own `Assets.xcassets`: a control can only draw a symbol, and one from the
  app's catalog would draw blank. Each template has three weights with the same path layout, so
  the system can set it at any weight; `xcrun actool` on the catalog says so when one is wrong.
- On a locked phone the system asks for the unlock before it opens the app.
- **Why not `OpenURLIntent`.** On the iOS 27.2 simulator: `OpenURLIntent` as the button's
  action fails (`CHSErrorDomain 1107`); an extension-only intent returning
  `opensIntent: OpenURLIntent(…)` never opens the app (and fails with `openAppWhenRun`); an
  intent in both targets returning `OpenURLIntent` opens the app but the URL never reaches
  `onOpenURL`. Only the shipped form, an intent in both targets with `openAppWhenRun` that opens
  the URL itself, takes the link, from a cold launch too.

## Links

`DeepLink` (`Packages/RexGlance`, `GlanceModel`) is the one list of links, and the one parser.
The app registers the `rexduo` scheme (`CFBundleURLTypes`) and takes links in `onOpenURL`
(`PteronApp` → `AppModel.openLink`).

| URL | Effect |
|---|---|
| `rexduo://open` | The app comes forward. Nothing else changes: the tab, an open sheet and the agent board stay. |
| `rexduo://waiting` | `AppModel.openWaiting()`: opens the agent that has waited longest. |
| `rexduo://pane?server=<id>&session=…&window=…&block=…` | `AppModel.openPane(link:)`: opens that pane, as a tapped push for it would (`PaneLink`). A widget's row. |
| `rexduo://pair` | Opens "Pair via QR Code", but only onto the bare app: with Settings, the scanner or a Beacon install up, it does nothing. The widget when the app has no servers. |
| any other `rexduo:` URL | As `open`. |
| a URL of another scheme | Ignored. |

- Only an exact host with no path, user, password or port names a link. A query and a fragment
  are ignored, except by a pane link, which needs exactly its four values, each once.
- Any app or web page can fire a link, so a link only navigates. It never types, never resizes
  by itself, and never acts on a pane the app hasn't loaded.
- A link that arrives before the first screen is up waits in `AppModel` until
  `AppDelegate.attach` releases it, as a tapped push waits.

### Jump to Waiting

After a cold launch no server has said yet which agents wait, so the link can't decide at once
as the waiting pill does. `OpenWaiting` (`State/OpenWaiting.swift`) holds the rules as a pure
step, and `AppModel.openWaiting` feeds it every 0.1 s:

- **It waits** until every server either knows its agents' states or shows a connection
  problem, for at most 10 s. "Knows" is `ServerConnection.agentsCurrent`: a full read of the
  states has ended since the latest connect, resync or trip to the background, and
  `agentKeys` was brought up to date with it. `synced` is not
  enough, because it turns true when the tabs are in and the states are not.
- **Once one server knows of a waiting agent**, the others get 2 s more, then the jump goes
  without them.
- **It gives up only on the person's own move**: the tab on screen is neither the one that was
  there when the link arrived nor one `autoSelect()` put there since (`AppModel.autoSelected`).
  The launch landing on the last tab by itself doesn't cancel the jump; a tapped tab or a
  tapped push does.
- **Which agent.** The one waiting longest, by the time the phone first saw it waiting; ties go
  by server order, then by block order. Agents first seen after the link arrived all tie,
  because after a cold launch those times only say which server synced first. The pill, the
  keyboard shortcut and the magic tap keep their own order (`Waiting.all`), so just after a
  cold launch they can pick a different agent than the control does.
- **With nobody waiting, no servers, or the 10 s run out**, nothing happens: no notice and no
  haptic. The app is just open. (The pill's and the shortcut's "No agent is waiting for you."
  is unchanged.)
- A second `waiting` link replaces a wait that is still running.

### A pane link

`OpenPaneLink` (`State/OpenPaneLink.swift`) holds the rules as a pure step:

- **The server is matched by id only**, the server's id in the app, a random UUID
  (`ServerConfig.id`). That id is the real guard: it is in the App Group's snapshot and
  nowhere else, and only the app's own targets can read the App Group, so another app or a web
  page can't make a pane link the app accepts. (Matching by host stays for pushes only, since
  Beacon doesn't know the id.)
- **The pane must be one the app has loaded, or one the snapshot lists as waiting** for that
  server. Anything else does nothing: the app is just open.
- **A pane only in the snapshot** (a cold launch from the widget) waits for its session to
  load, 10 s at most, and gives up only on the person's own move, never on the launch landing
  on the last tab by itself, as "Jump to Waiting" does.
- It opens the tab that holds the pane now, whatever tab the link named.
- A second pane or `waiting` link replaces one that is still waiting.

### Effects on the computer

A `waiting` link that finds an agent, and a pane link that is accepted, have exactly the effects
of a tapped push for that agent, and no others:

- `session.focus_block` for the agent's pane and `session.focus_window` for its tab. So a tap
  on a widget's row moves the focus on the computer to that pane, the same as tapping a push
  for it does.
- When the pane shows, fit mode claims and resizes it, as for any tab the person opens.
- It sets `AppModel.openRequest`, so Settings, the pairing sheet, a Beacon install's cover and
  the agent board are put away, as a push tap puts them away. An install keeps running;
  Settings → Notifications shows its row again.

`open`, `pair`, an unknown link, a pane link that is refused and a `waiting` link that finds
nobody send nothing to any server.

## Testing

- `xcrun simctl openurl <sim> rexduo://waiting` fires a link; the `OPEN_…` log lines are in
  [debug-args.md](debug-args.md). Read them with `xcrun simctl spawn <sim> log show --last 1m
  --predicate 'eventMessage CONTAINS "OPEN_"'`.
- In a test launch (`-autoOpen <label>`) a link jumps only to agents in the session with that
  label, and a pane link opens only a pane of that session, so a test can't open, focus or
  resize a pane in a real session.
- **A cold launch from a link or a widget's tap gets no launch arguments**, and a plain launch
  opens the last real tab. First save safe arguments in the simulator's own defaults, which the
  app reads like launch arguments: `xcrun simctl spawn <sim> defaults write
  dev.abrahamgonzalez.rexduo autoOpen zz-test` (and `servers`, `sizing` and the like the same
  way). Delete them, or the simulator, afterwards.
- The widgets: `-glanceDemo <scenario>` writes a made-up snapshot, and `-glanceLive YES` with
  `-autoOpen <label>` writes the real one for that session only
  ([debug-args.md](debug-args.md)). Add the widget on a simulator's Home Screen (touch and hold,
  Edit, Add Widget) or Lock Screen (touch and hold, Customize).
- `GlanceRenderTests` draws every family, state, color scheme and rendering mode into the test
  host's temporary folder (`glance-renders`), one picture each and a sheet per family.
- The controls show in the simulator's Control Center (swipe down from the top right, "+",
  "Add a Control") and work there. The Lock Screen slots, the Action button and a locked phone
  need a device: try each control with the app not running, in the background, and with the
  phone locked.
