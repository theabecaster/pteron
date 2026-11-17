# Sidebar

The sidebar lists every machine (a Rex server), its sessions and their tabs, like the Rex Mac
app's sidebar, and switches to an Agents mode like the Mac's activity mode. Checked against
Apple's HIG (Sidebars, Disclosure controls, Outline views), November 2026.

## What Apple says

- Group hierarchy with disclosure controls, so the sidebar's height stays manageable.
- Show no more than two levels where possible. With more, give each group a short, clear label.
- A disclosure triangle points to the trailing side while closed and down while open, and the
  view grows or shrinks to fit. Keep people's expansion choices and show them again next time.
- Let people hide the sidebar; keep critical actions off its bottom edge.

Rex has three levels: machine, session, tab. Each level gets its own row style, so the depth reads
at a glance. Xcode's navigator, Finder and Slack use the same tools: indentation, one strong top
level, quiet group labels, and counts on closed groups.

## Hierarchy and visual language

All colors come from the theme's chrome (`TermTheme.Chrome`). All text uses text styles, so it
follows Dynamic Type.

| Level | Row | Type | Indent |
|---|---|---|---|
| Machine | OS glyph, name, connection dot, chevron. A down machine adds one quiet line saying why. | headline, `fg` | 0 |
| Session | name, `+` (New Tab, open sessions only), chevron | subheadline semibold, `fg` | under the machine's name |
| Tab | agent tile, title, pane count, status | 14 pt regular (scaled), `fg` at 80% | one step further |

Sessions are what people look for, so their names are full contrast and semibold; tabs are lighter.

- **Membership.** No lines: indentation, type and spacing say what holds what. A session's tabs
  sit one step in from its name, lighter and smaller than it, with no gap between them, and the next
  session starts after a gap. The selection highlight starts at the tab's indent, so a selected tab
  still reads as part of its session. Machines are separated by extra space and are the heaviest
  rows, so a session's machine is plain too.
- **OS glyph.** From `server.version`'s `platform`: Apple logo for darwin, `server.rack` for Linux,
  `pc` for Windows, `desktopcomputer` otherwise.
- **Rhythm.** Tighter within a group, looser between groups: 18 pt above each machine, 6 pt above
  each session after the first, none between tabs. Machine rows are 44 pt, session and tab rows
  36 pt. The gaps scale with Dynamic Type up to 30 and 10 pt.
- **Names first.** `NameAndSummary` keeps a header's name whole, or at least 55% of the row,
  before a folded group's summary takes its smaller forms.
- **Chevrons** sit at the trailing edge (iOS sidebar convention) and turn 90° when opening.

## Collapse and expand

- Tap a machine or session header to fold it, or press Return on a focused one.
- **Motion** (`SidebarMotion`), transforms and opacity only:
  - The chevron turns a quarter on its own spring.
  - Opening: the rows unfurl from under the header, top first. Each starts 6 pt up at 97% and
    transparent and settles on the fold's spring (`SidebarCollapse.animation`, 0.32 s, a little
    bounce). The cascade is real: `SidebarReveal` adds 3 rows a frame, so each frame builds only
    those. After 10 frames the rest come at once; they are below the screen by then.
  - Folding is the reverse and quicker (0.18 s): the lower rows go first, 4 ms apart, capped at 32 ms.
  - Rows are opaque and each is drawn over the rows above it, so the content below slides over a
    group's rows as they come and go instead of through them.
  - A header's folded summary and its `+` trade places: the leaving one fades in 80 ms, then the
    other fades in.
  - With Reduce Motion, rows and summaries only fade.
- The state is saved per item in `Prefs.sidebarCollapsed`: `m:<server id>` and
  `s:<server id>:<session id>`. Everything starts open. Keys of sessions a connected server no
  longer has, and of removed servers, are dropped.
- The tab on screen always has a row: when the selection changes (a tap, Jump to Waiting, a push,
  a toast, a new session), its session and machine open, animated (`SidebarCollapse.revealing`).
- A connected machine without sessions shows "No sessions" with New Session. With no servers at
  all, the sidebar says how to pair, with Pair via QR Code.
- A closed header sums up what it holds: the tab count (sessions for a machine), and the waiting and
  working pills. A closed machine still shows that an agent needs you. Summaries take the widest
  form that fits (`ViewThatFits`): words ("3 tabs", "2 waiting"), then glyphs and digits, then the
  pills alone, then the most urgent pill. They stay on one line.

## Agents mode

- The sidebar's top has a two-segment switch: **Sessions | Agents**. The Agents segment carries
  a waiting count in the blocked color when any agent waits. The mode is saved
  (`Prefs.sidebarMode`), as the Mac's sidebar keeps its mode.
- Agents mode lists agents grouped by machine. Machines keep their order. Inside a machine, the
  order is waiting (oldest first), error, working, done, idle. Machine headers here don't fold:
  a waiting agent is never hidden.
- Tapping an agent, or Return on a focused row, opens its tab with its pane shown. Swipe gives
  Interrupt, Enter (when waiting) and Jump, as the old sheet did. The notification prompt card
  shows at the top when offered.
- It replaces the Agents sheet. `cmd+.` (`client.sidebar.activity.toggle`) toggles the mode, as
  on the Mac: it shows the sidebar in Agents mode, or returns to Sessions when Agents is already
  showing. Jump to Waiting has its own action, `client.agents.jump_to_waiting` (`alt+cmd+.` by
  default), besides the waiting pill and the VoiceOver magic tap.

## Not added

Machines in a server's `hosts.list` that aren't saved (`KnownHost.unsaved`) show under a quiet
**Not added** header: glyph, name and an **Add** button. Add opens the pairing identity card for
that host's address (`AppModel.startPairing(prefilled:name:guessed:)`), named after its label.
`hosts.list` mostly gives `ssh://` endpoints, so the address is often worked out from the listing
server's (`guessed: true`); a failed check then says to pair with a code. Without any address,
Add opens the scanner.

## Postures

The same sidebar runs inline (200 pt to half the window), as the drawer, folded, unfolded and on
any iPhone. Long names truncate at the end on one line, or wrap to two at accessibility sizes.
Badges never wrap: they shrink to glyphs first. Pills stop growing at `accessibility1` and icons
at `xxxLarge`; text follows every size.

## Performance

- One flat `ForEach` over `SidebarOutline.rows`, with ids `m:`, `s:`, `t:` that never change for an
  item, so a fold is inserts and removes.
- Rows (`MachineRow`, `SessionRow`, `TabRow`) are equatable views without closures; actions and
  dialogs go through one `SidebarActions` object. A fold re-renders only the rows it changes.
- Headers get their tabs from the row, so they don't read `server.views` themselves.
- Status reads stay in leaf views: a tab's status in `TabRowLabel`, an agent's in `AgentRowLabel`,
  a closed group's summary in `GroupSummary`. A status change re-renders only them.
- Agents mode and the waiting count read `ServerConnection.agentKeys`: each agent's place, kind and
  state, recomputed once per main-actor turn and set only when one of those changes. A title,
  directory or status line change in some pane doesn't re-render or re-sort the list. The mode
  switch and `WaitingWatcher` share `AppModel.waitingAgentIDs`, built on it.
- Sessions mode is a `LazyVStack` in a `ScrollView`, not a `List`. On the device a `List` sizes
  every visible cell again on each fold (`UICollectionView` self-sizing in its batch update): 68% of
  a fold's main-thread time, and 18 to 43 ms a fold however cheap the rows (rows of one `Text`
  still took 18 to 42 ms). The stack builds only the rows that come into view and never measures the others again.
- What `List` gave, kept by hand: swipe actions (`SidebarSwipe`: a sideways-only UIKit pan, the first
  action at the edge, full swipe for the leading one, one row open at a time, a tap closes it,
  VoiceOver gets the same actions), pull to refresh, context menus, keyboard focus and Return on
  rows and headers, header traits for the VoiceOver rotor, and the scroll position, kept by the
  sidebar across a trip to Agents mode.
- Agents mode stays a `List` (it doesn't fold), its own view, built only while it shows.
- The drawer's shadow comes from its background alone, not from every row.
- `-sidebarFoldBench` (docs/debug-args.md) measures late frames while folding; it keeps the
  user's fold state aside and puts it back, also after a run that was cut short.
- No work per event on the main thread beyond reading the boxes that changed.

### Device measurements (iPhone Duo, 120 Hz)

Measured 2026-11-17 on the iPhone Duo (iOS 27.2.1), Debug builds with `-O`, `-sidebarFoldBench 8
-sidebarFoldBenchScope session`: a 50-tab throwaway session folded and opened 8 times each, on a
test server (`-servers`) with 54 rows open. A late frame is a gap over 12.5 ms (1.5 refreshes).
The worst frame per fold or open is the median of the 8 (the highest in brackets).

Unfolded (inner screen, landscape, sidebar inline at 200 pt), 16 toggles a run:

| Build | worst frame, fold ms | worst frame, open ms | late frames | late time ms |
| --- | --- | --- | --- | --- |
| `List` (main) | 30.4 (37.9) | 40.8 (42.9) | 102 | 792 |
| `List`, second run | 23.8 (38.6) | 35.3 (40.2) | 109 | 736 |
| `List`, rows only a `Text` | 24.6 (30.7) | 31.8 (41.7) | 61 | 518 |
| `List`, 4 rows added a frame | 24.3 (34.3) | 29.1 (33.3) | 89 | 851 |
| `List`, no animation | 19.2 (26.5) | 22.7 (26.2) | 24 | 280 |
| `LazyVStack`, all rows at once | 12.5 (12.5) | 23.4 (28.8) | 52 | 303 |
| `LazyVStack`, 4 rows a frame | 12.5 (12.5) | 17.3 (22.9) | 85 | 402 |
| `LazyVStack`, 8 rows a frame | 12.5 (15.7) | 22.8 (26.6) | 86 | 445 |
| Shipped: `LazyVStack`, 3 rows a frame, unfurl motion | pending | pending | pending | pending |

Folded (outer screen, sidebar as the drawer over the tab):

| Build | worst frame, fold ms | worst frame, open ms | late frames | late time ms |
| --- | --- | --- | --- | --- |
| `List` (main before), the 50-tab session | 24.7 (40.1) | 36.7 (42.3) | 74 | 625 |
| `List`, every machine and session | 26.8 (41.5) | 40.7 (43.6) | 77 | 667 |
| Shipped, the 50-tab session | 12.5 (21.7) | 16.7 (19.5) | 64 | 322 |
| Shipped, second run | 12.5 (21.8) | 18.0 (25.0) | 28 | 186 |
| Shipped, every machine and session | 14.6 (25.9) | 16.7 (20.9) | 23 | 170 |

Instruments' Animation Hitches template over the same 21 s run (launch included), folded: hitch
time 13.2 s before, 2.8 s after; the median hitch 12.1 ms before, 2.4 ms after. The device can't
screen-record (CoreDevice says the capability isn't supported), so the motion was checked from
screenshots taken during a run: rows dissolve under the content rising from below, open rows unfurl
with the chevron mid-turn, and the `+` comes in only after the summary has gone.

Reading it: 12.5 ms is one refresh late at most, which doesn't count as late. With `List` every fold
and open had a frame 17 to 43 ms long, animated or not. In the stack a fold is never late, and
opening a few rows a frame cuts the worst open frame by more than half and the late time per run
by half. The late frames left are short ones (about 13 ms) while the rows settle.

Root cause (Time Profiler on the device, unfolded): 68% of a fold's main-thread time was
`UICollectionView` `_updatePreferredAttributesForCurrentUpdate`, `List` building cells for the new
rows and sizing every visible cell again, existing ones too. That is why the earlier attempts
(no animation above 16 rows, no per-row insets) and adding rows a few per frame inside `List` did
not help: every step sized the whole screen again. With trivial rows (one `Text`) `List` still took
18 to 42 ms; a `LazyVStack` folded in under 12.5 ms on its first try.

## Accessibility

- Headers are buttons with the header trait. VoiceOver reads "workdesk, machine, 3 sessions,
  1 agent waiting, collapsed". Sessions read "qr-pairing, session, 2 tabs, expanded".
- The mode switch reads as two selectable buttons, "Sessions" and "Agents, 2 waiting".
- Rows are buttons, so Full Keyboard Access moves through them and Space opens or folds.
- Tab rows say their pane count and status ("2 panes", "waiting for you").
