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
| Tab | agent tile, title, pane count, status | 14 pt regular (scaled), `fg` at 80% | one step further, on a guide line |

Sessions are what people look for, so their names are full contrast and semibold; tabs are lighter.

- **Membership.** A hairline guide runs down the left of a session's tabs, from its header to its
  last tab, so a tab's session is plain. The selection highlight starts at the tab's indent.
  Machines are separated by extra space and are the heaviest rows, so a session's machine is plain too.
- **OS glyph.** From `server.version`'s `platform`: Apple logo for darwin, `server.rack` for Linux,
  `pc` for Windows, `desktopcomputer` otherwise.
- **Rhythm.** Tighter within a group, looser between groups: 18 pt above each machine, 6 pt above
  each session after the first, none between tabs. Machine rows are 44 pt, session and tab rows
  36 pt. The gaps scale with Dynamic Type up to 30 and 10 pt.
- **Names first.** `NameAndSummary` keeps a header's name whole, or at least 55% of the row,
  before a folded group's summary takes its smaller forms.
- **Chevrons** sit at the trailing edge (iOS sidebar convention) and turn 90° when opening.

## Collapse and expand

- Tap a machine or session header to fold it. The rows slide in and out (`.snappy`, 0.25 s).
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
  item, so `List` diffs folds as inserts and removes.
- Rows (`MachineRow`, `SessionRow`, `TabRow`) are equatable views without closures; actions and
  dialogs go through one `SidebarActions` object. A fold re-renders only the rows it changes.
- Headers get their tabs from the row, so they don't read `server.views` themselves.
- Status reads stay in leaf views: a tab's status in `TabRowLabel`, an agent's in `AgentRowLabel`,
  a closed group's summary in `GroupSummary`. A status change re-renders only them.
- Agents mode and the waiting count read `ServerConnection.agentKeys`: each agent's place, kind and
  state, recomputed once per main-actor turn and set only when one of those changes. A title,
  directory or status line change in some pane doesn't re-render or re-sort the list. The mode
  switch and `WaitingWatcher` share `AppModel.waitingAgentIDs`, built on it.
- `List` is lazy (a collection view). Agents mode is its own view, built only while it shows.
- `-sidebarFoldBench` (docs/debug-args.md) measures late frames while folding; it keeps the
  user's fold state aside and puts it back, also after a run that was cut short.
- No work per event on the main thread beyond reading the boxes that changed.

## Accessibility

- Headers are buttons with the header trait. VoiceOver reads "workdesk, machine, 3 sessions,
  1 agent waiting, collapsed". Sessions read "qr-pairing, session, 2 tabs, expanded".
- The mode switch reads as two selectable buttons, "Sessions" and "Agents, 2 waiting".
- Rows are buttons, so Full Keyboard Access moves through them and Space opens or folds.
- Tab rows say their pane count and status ("2 panes", "waiting for you").
