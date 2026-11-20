# Glance surfaces

What the app offers outside its own window: the agents widget on the Home Screen and the Lock
Screen, two controls, and the links they open the app with. A watch app comes later and adds
its part here.

## The agents widget

One widget, "Agents" (kind `dev.abrahamgonzalez.rexduo.widget.agents`, `RexDuoWidgets/GlanceWidget.swift`),
in six families. It says how many agents need you, where, and for how long, as the app last
saw them. It connects to nothing: it reads the snapshot the app wrote (below).

| Family | Shows | A tap opens |
|---|---|---|
| `systemSmall` (also StandBy) | the headline; the ring, name and wait of the agent waiting longest; then its place, or the snapshot's age | `rexduo://waiting`, or `open` when nobody waits |
| `systemMedium` | the headline, the machine line and the other counts; up to 3 waiting agents, or each machine's counts when nobody waits | a row: `rexduo://pane?…`; elsewhere as small |
| `systemLarge` | the headline; what the longest-waiting agent asks; up to 6 waiting agents; each machine's counts; "+N more" | as medium |
| `accessoryCircular` | a raised hand over the waiting count; with nobody waiting, the mark over the working count in an arc; else the mark | `waiting` |
| `accessoryRectangular` | "2 need you"; "Claude · api › tests"; "waiting 12 minutes" or the age | `waiting` |
| `accessoryInline` | "2 need you · 3 working" | the app |

- **Configured the iOS way, by size.** There are no widget settings and no intent.
- **The headline** is the agent board's: "2 need you", "1 error", "3 working", "All done",
  "All quiet", counted over the machines that were connected at the write (`GlanceDigest`;
  a test in the app holds it to `AgentBoard` over the board's own demo scenarios).
- **Many machines.** The headline sums them, a machine's name shows only when there are
  several, and nothing scrolls: what doesn't fit is "+N more". A snapshot keeps at most 8
  waiting agents per machine.
- **The gallery and the placeholder** show made-up agents (`GlanceDemo`), never the person's.
- The app is iPhone-only, so there is no iPad widget. On a Mac, the iPhone's widget can sit on
  the desktop, and a click there hands off to the phone.
- **No Live Activity**, by decision.

### Calm

The widgets never ask for attention. `CalmRuleTests` (in `Packages/RexGlance`) reads the
sources and fails on a line that breaks one of these:

- **Passive.** A widget exists only where the person added one. Nothing in the app offers,
  suggests or mentions adding a widget, and the app looks the same with or without one.
- **No Live Activity**: no ActivityKit, no `NSSupportsLiveActivities`.
- **No sound, haptic or notification** from the widgets, the watcher or the writer.
- **No motion of their own.** The ring is still. Nothing repeats, pulses or animates, and no
  transition or symbol effect is chosen; what moves is the system's own change from one
  timeline entry to the next.
- **A stale widget is quiet.** Its counts dim and a small line in the secondary color says
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
| over 1 h | counts and rows at 40%; on the Home Screen sizes also "Open Pteron to refresh". The Lock Screen accessories keep their counts, dimmed, and say nothing more: no refresh line and no running wait time |
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
  while the phone is locked, which is when the system is expected to ask for privacy. That
  has not been seen on a device yet.
- **A message is never on the Lock Screen:** no accessory carries one
  (`GlanceDigest.accessory`), and the large widget's is private.
- **Locked, the accessories carry counts only.** When the system asks for redaction, the
  accessory is built without any name or place, instead of leaving grey bars. Counts always show.
- **To check on a device** (a simulator has no passcode, so it never locks this way): with
  Complete, the widgets must still draw after the first unlock and while unlocked, and redact
  while locked. If they don't draw, drop the entitlement and keep the Lock Screen to counts.

### Design

- **Colors** come from the snapshot's palette, slot by the system's mode, drawn in the
  theme's own appearance (`GlanceColors`): the widget's background is the app's canvas, tiles
  are the sidebar color, secondary and tertiary text the app's, all through the same
  perceptual `Color.mix` and fractions as `TermTheme.Chrome` (a test in the app compares them
  for every theme in both slots, and every agent's tint with the sidebar's).
- **State** has the board's colors (waiting ANSI 3, error 1, working 4, done 2) and always a
  word or a badge as well. A 1.5 pt edge in the most urgent state's color shows only while
  someone waits, fails or works.
- **`GlanceRing`** is the board's ring with no motion.
- **Type**: the system font. Headline 22 pt bold in small, 20 pt elsewhere; names 13 pt
  semibold; state words 12 pt semibold; places 11 pt. Dynamic Type stops at xxLarge.
- **Tinted, clear and vibrant** (`GlanceStyle`): no palette; text is primary or secondary,
  never under 60%; the count and the ring's lines take the system's accent; a state reads
  from its shape and its word.
- **A text that updates itself needs a frame of a set width**, never `fixedSize()`: on the
  Home Screen that leaves the whole widget empty. A view drawn in a test doesn't show it, so
  a change to the wait time's layout is checked on a simulator's Home Screen.

### Files

`RexDuoWidgets/`: `GlanceWidget.swift` (the widget and the view that picks a family),
`Provider.swift` (the timeline), `Demo.swift` (the gallery), `Views/` (the families and
`GlanceStyle`; compiled into the app's tests too, which draw every size, state and mode:
`GlanceRenderTests`). Everything the views show is decided in `GlanceDigest`, which is pure.

## Controls

The extension `RexDuoWidgets` (bundle id `dev.abrahamgonzalez.rexduo.widgets`) declares two
controls for Control Center, the Lock Screen's bottom slots and the Action button
(`RexDuoWidgets/Controls.swift`):

| Control | Kind | Opens |
|---|---|---|
| Open Pteron | `dev.abrahamgonzalez.rexduo.control.open` | `rexduo://open` |
| Jump to Waiting | `dev.abrahamgonzalez.rexduo.control.waiting` | `rexduo://waiting` |

- Each is a `ControlWidgetButton` whose action is `OpenLinkIntent`
  (`RexDuoWidgets/OpenLinkIntent.swift`), an intent of our own with `openAppWhenRun`. The file
  is compiled into the extension and into the app: the system finds the intent in the
  extension and runs it in the app, which it brings forward first.
- In the app the intent does one thing: it opens the link's URL
  (`RexDuo/App/OpenLinkIntent+App.swift`). So a control takes the same single path into the app
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
- **Why not `OpenURLIntent` alone.** Checked on the iOS 27.2 simulator, by tapping the control
  in Control Center:

  | Action of the button | Result |
  |---|---|
  | `OpenURLIntent(rexduo://…)` itself | fails: `CHSErrorDomain 1107`, "Encountered action intent without linkAction" |
  | an intent in the extension only, returning `.result(opensIntent: OpenURLIntent(…))` | "succeeds"; the app never opens |
  | the same with `openAppWhenRun` | fails |
  | an intent in both targets with `openAppWhenRun`, returning `opensIntent: OpenURLIntent(…)` | the app opens; the URL never reaches `onOpenURL` |
  | an intent in both targets with `openAppWhenRun` that opens the URL itself (what ships) | the app opens and takes the link, from a cold launch too |

## Links

`DeepLink` (`Packages/RexGlance`, `GlanceModel`) is the one list of links, and the one parser.
The app registers the `rexduo` scheme (`CFBundleURLTypes`) and takes links in `onOpenURL`
(`RexDuoApp` → `AppModel.openLink`).

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

- `xcrun simctl openurl <sim> rexduo://waiting` fires a link. A Debug build logs one
  `OPEN_LINK <link> run|queued` line for each link it takes and one `OPEN_WAITING <step>` line
  when a jump ends. `OPEN_LINK <link> refused` means a control's intent ran in the app and the
  system would not open its URL. Read them with `xcrun simctl spawn <sim> log show --last 1m --predicate 'eventMessage
  CONTAINS "OPEN_"'`.
- In a test launch (`-autoOpen <label>`) a link jumps only to agents in the session with that
  label, and a pane link opens only a pane of that session, so a test can't open, focus or
  resize a pane in a real session.
- The widgets: `-glanceDemo <scenario>` writes a made-up snapshot, and `-glanceLive YES` with
  `-autoOpen <label>` writes the real one for that session only
  ([debug-args.md](debug-args.md)). Add the widget on a simulator's Home Screen (touch and hold,
  Edit, Add Widget) or Lock Screen (touch and hold, Customize). A widget's tap starts the app
  without launch arguments, like `openurl`: save safe arguments in the simulator's defaults first.
- `GlanceRenderTests` draws every family, state, color scheme and rendering mode into the test
  host's temporary folder (`glance-renders`), one picture each and a sheet per family.
- `simctl openurl` starts an app that isn't running **without** launch arguments, and a plain
  launch opens the last real tab. To test a cold launch from a link, first save the arguments
  in the simulator's own defaults, which the app reads like launch arguments:
  `xcrun simctl spawn <sim> defaults write dev.abrahamgonzalez.rexduo autoOpen zz-test` (and
  `servers`, `sizing` and the like the same way). Delete them, or the simulator, afterwards.
- The controls show in the simulator's Control Center (swipe down from the top right, "+",
  "Add a Control") and work there. The Lock Screen slots, the Action button and a locked phone
  need a device: try each control with the app not running, in the background, and with the
  phone locked.
