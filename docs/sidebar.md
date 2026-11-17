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

- Tap a machine or session header to fold it. The rows animate in and out (`.snappy`, 0.25 s).
- The state is saved per item in `Prefs.sidebarCollapsed`: `m:<server id>` and
  `s:<server id>:<session id>`. Everything starts open. Keys of sessions a connected server no
  longer has, and of removed servers, are dropped.
- A closed header sums up what it holds: the tab count (sessions for a machine), and the waiting and
  working pills. A closed machine still shows that an agent needs you. Summaries take the widest
  form that fits (`ViewThatFits`): words ("3 tabs", "2 waiting"), then glyphs and digits, then the
  pills alone, then the most urgent pill. They stay on one line.

## Agents mode

- The sidebar's top has a two-segment switch: **Sessions | Agents**. The Agents segment carries
  a waiting count in the blocked color when any agent waits.
- Agents mode lists agents grouped by machine. Machines keep their order. Inside a machine, the
  order is waiting (oldest first), error, working, done, idle. Machine headers here don't fold:
  a waiting agent is never hidden.
- Tapping an agent opens its tab with its pane shown. Swipe gives Interrupt, Enter (when waiting)
  and Jump, as the old sheet did. The notification prompt card shows at the top when offered.
- It replaces the Agents sheet. `cmd+.` (`client.sidebar.activity.toggle`) now toggles the mode:
  it shows the sidebar in Agents mode, or returns to Sessions when Agents is already showing.
  Jump to Waiting stays on the waiting pill and the VoiceOver magic tap.

## Not added

Machines in a server's `hosts.list` that aren't saved show under a quiet **Not added** header:
glyph, name and an **Add** button that starts adding that machine. `NotAddedHosts` is the one
place that knows how. It opens Settings → Add Server for now; it switches to
`AppModel.startPairing(prefilled:name:guessed:)` when the pairing card lands. `hosts.list` only
gives `ssh://` addresses, so that address is a guess.

## Postures

The same sidebar runs inline (200 pt to half the window), as the drawer, folded, unfolded and on
any iPhone. Long names truncate at the end on one line, or wrap to two at accessibility sizes.
Badges never wrap: they shrink to glyphs first. Pills stop growing at `accessibility1`, icons at
`xxxLarge`, and the whole sidebar at `accessibility2`: past that a machine's name breaks mid-word
even on two lines in a 260 pt sidebar.

## Performance

- One flat `ForEach` over `SidebarOutline.rows`, with ids `m:`, `s:`, `t:` that never change for an
  item, so `List` diffs folds as inserts and removes.
- Rows (`MachineRow`, `SessionRow`, `TabRow`) are equatable views without closures; actions and
  dialogs go through one `SidebarActions` object. A fold re-renders only the rows it changes.
- Status reads stay in leaf views: a tab's status in `TabRowLabel`, a closed group's summary in
  `GroupSummary`, the waiting count in the mode switch. A status change re-renders only them.
- `List` is lazy (a collection view). Agents mode is its own view, built only while it shows.
- No work per event on the main thread beyond reading the boxes that changed.

## Accessibility

- Headers are buttons with the header trait. VoiceOver reads "workdesk, machine, 3 sessions,
  1 agent waiting, collapsed". Sessions read "qr-pairing, session, 2 tabs, expanded".
- The mode switch reads as two selectable buttons, "Sessions" and "Agents, 2 waiting".
- Rows are buttons, so Full Keyboard Access moves through them and Space opens or folds.
