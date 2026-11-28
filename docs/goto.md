# Go to Anything and the command palette

One palette, three ways in, each the Rex Mac app's action of the same name. Keys come from the
server's keymap (the user's init.lua wins), never fixed:

| Action | Opens | Default key | Field says |
|---|---|---|---|
| `pane.go_to` (Go to Anything…) | places first, then up to five commands | ⌘P | Go to tab, pane or session |
| `session.switch` (Change Session…) | sessions | ⌘K | Change session |
| `client.palette.toggle` (Command Palette…) | commands | ⇧⌘P | Run a command |

The key bar's ⌘ key and anything else that opens the commands palette call
`model.perform(.goTo(.commands))`: the tab on screen opens it on its active pane, and with no tab
the root opens it with no target.

`client.tab.overview` keeps its own key (⇧⌘\, Show All Tabs). On a setup whose init.lua binds
⌘K to Clear and ⇧⌘K to `session.switch`, ⌘K clears and ⇧⌘K opens Change Session.

Touch: "Go to Anything…" in the title bar's menu, right after Show All Tabs (with its key), in
tab mode the session popover's first footer row, and a VoiceOver action "Go to Anything" on the
title. No pull-down, no standing button.

Code: `Pteron/Features/GoTo/`.

- `GoToCenter`: opens, runs and closes; the keyboard hold and hand-back; the running notice;
  questions from the phone's own runs. Owned by `AppModel` (`palette`).
- `GoToModel`: one opening (`AppModel.goTo`): scope, target, query, rows, selection, question.
- `GoToSource`, `GoToCommands`: the copy of what it lists, made on the main actor.
- `GoToSearcher` (actor), `FuzzyMatch`, `GoToRanker`, `GoToRecents`: matching and ranking, off
  the main actor and pure.
- `GoToPanel`, `PaletteField`: the overlay and its field. `PalettePrompt`: questions.

## Keys inside it

↑ ↓ move (they repeat), Tab moves down, Return runs the selected row, Esc closes. `>` as the
first character of Go to Anything switches to commands; Backspace in the empty field goes back.
Another palette key switches scope and keeps the text; the same key closes it. Every other menu
key waits until it closes. While an input method composes, the field declares no keys, so Return,
Esc and the arrows reach the composition. A palette action bound with ⌥ or a function key works
from the field too (its ⌘ and ⌃ keys arrive as menu items, `AppShortcutCommands`).

## What it lists

- Every session, tab and pane on every saved server, in sidebar order. Panes only for tabs with
  more than one tiled pane; a pane's name is the one its menu uses (`PaneName`). An offline
  server stays listed, ranked lower, "offline" in the subtitle; opening it shows the offline
  screen, as a sidebar tap does. A server on its first connect gets a footer line.
- The app's commands that apply now, as the Rex Mac app's palette names, groups and orders them
  (below, "The commands"). Pane and tab commands need a tab on screen; Zoom only when the tab can
  zoom; Arrange's commands follow `PaneArrange.isAvailable`, the pane menu's gate.
- Every binding with fixed arguments that the app runs and no other row does is a row of its
  own, with its key: Go to Tab 1 to 8 and Go to Last Tab (only tabs that exist), and each key the
  Mac sends to the shell (Delete to Line Start, Move to Line End, a `pane.send_key` the user's
  init.lua binds, as "Send ⌃D"). A binding that does what a row already does (`pane.split` with
  `direction = "right"`) adds no row; its key shows on that row when no key is bound by name.
- The server's Lua actions (`kind: "lua"` from `client.keymap`): the target's server, or with no
  tab every online one. One that needs arguments shows dimmed ("Needs arguments the phone can't
  fill in."). A key bound with fixed arguments is a row of its own, with that key.
- Clear Terminal and Reset Terminal, where the target pane's creator lists the method.
- The target pane's files: Browse Files…, Insert Path…, Insert File… and Insert Photo…, each
  where the attach menu or its key would work for that pane (`ServerConnection.offers`;
  docs/terminal.md, Files), with the key the keymap binds, if any. They are also found by image,
  photo, picture, screenshot, attach, upload, file and send (`FilesCommand.keywords`).
- The ports of every connected machine's ports list: "Open localhost:3000 · Next.js", with
  the folder under it. It opens the page in the app, as the sidebar's row does; a port that
  closed meanwhile says "Nothing listens on that port now." (docs/terminal.md, Ports).
- A typed address, in Go to Anything only: `localhost:3000`, `127.0.0.1:3000/admin` or `:3000`
  (also `[::1]:3000` and `0.0.0.0:3000`, with or without `http://` or `https://`) puts one row
  a connected machine that listens there above the other results, "Desk · Next.js · anchor"
  over the address typed. Return opens the selected one, at the path typed. With none, one
  dimmed row says "Nothing is running on localhost:3000 on your computers." A bare number is
  not an address. The rows come from the port lists the app holds (`PortAddress`), on the main
  actor, with no call: about 7 µs a keystroke with ten machines of ten ports in a debug build.
- Copy mode, dimmed ("Copy mode works only in the Rex app."), under the Mac's titles (Enter Copy
  Mode, …), only where the keymap binds one of its actions.

Empty field: Go to Anything shows Waiting (three at most, oldest first) and Recent (eight,
without the tab on screen); with neither, every place. Change Session lists sessions; the
commands palette shows recent commands, then all by category.

Matching folds case, accents and width (`é`, `É` and `ｅ` read `e`) and scores word starts,
runs and a field's start. Every word must match some field. Weights: tab title 1.0, session 0.9,
pane name and program 0.7, directory 0.7, machine 0.6, the last six hex digits of an ID 0.5
(only for a query of four hex digits or more). Boosts: recent use up to +30% (halving every three
days), a waiting agent +15%, the tab on screen −30%, an offline server −40%. Ties keep sidebar
order. A digit query puts that tab of the current session first. In Go to Anything, Close Pane,
Close Tab, Close Other Tabs, Close Session, Clear and Reset are never row 1; if every row is
one, nothing is selected.

The selection is an item, not a row number: a rebuild landing between ↓ and Return runs what
was selected. While open, the list is rebuilt at most every 250 ms when servers, sessions, tabs
or agents change; a title or directory change doesn't rebuild it.

## The commands

The Rex Mac app's palette ("Mac Actions" in Rex's docs) as far as the phone runs it: its groups in
its order (Window, App, Session, Host, Tab, Pane, Keys, Find, View), and its order inside each
(`MacPalette`). The empty commands list shows them so, after Recent; ports, then the server's
Lua actions, come after. Each row shows the key the keymap runs it with (the user's init.lua
wins); the keys below are the defaults the app sends, which are the Mac's.

| Group | Command | Key | Shows when |
|---|---|---|---|
| App | Settings… | ⌘, | always |
| Session | New Session | ⌘N | always |
| Session | Change Session… | ⌘K | always (switches the palette to sessions) |
| Session | Next Session, Previous Session | | a session lies that way, in sidebar order across computers; no wrap |
| Session | Rename Session…, Close Session | | a tab is on screen (the sidebar's alert and question) |
| Session | Undo Close | ⇧⌘T | the computer can undo (revision 20) and is online (below) |
| Host | Add Computer… | | always (Settings → Add Computer) |
| Tab | New Tab | ⌘T | always |
| Tab | Close Tab | ⌥⌘W | a tab |
| Tab | Close Other Tabs | | the session has another tab (always asks) |
| Tab | Rename Tab… | | a tab |
| Tab | Show Next Tab, Show Previous Tab | ⌃⇥ ⌃⇧⇥ | a tab that way |
| Tab | Go to Tab 1–8, Go to Last Tab | ⌘1–⌘9 | that tab exists |
| Tab | Show All Tabs (the app's own) | ⇧⌘\ | a tab |
| Tab | Move Tab Backward, Move Tab Forward | ⌃⇧⇞ ⌃⇧⇟ | the server can, another tab |
| Tab | Move Tab to Session… (the app's own) | | the computer moves tabs (revision 22) and has another session (below) |
| Pane | Split Pane Left, Right, Up, Down | ⇧⌘← ⌘D ⇧⌘↑ ⇧⌘D | a pane |
| Pane | Split Pane Best Fit | ⌘↩ | a terminal pane |
| Pane | Focus Next Pane, Focus Previous Pane | ⌘] ⌘[ | another pane to show |
| Pane | Navigate Back, Navigate Forward | ⌥⌘[ ⌥⌘] | a place that way (below) |
| Pane | Minimize Floating Window | ⌥⌘M | Arrange's gate |
| Pane | Minimize All Floating Windows | ⌥⇧⌘↩ | Arrange's gate |
| Pane | Zoom Pane | ⇧⌘↩ | the tab can zoom |
| Pane | Close Pane, Close Other Panes, Balance Splits | ⌘W | a pane; Arrange's gate |
| Pane | Move Pane to New Tab, Move Pane to Tab… | | Arrange's gate |
| Pane | Browse Files… (the Mac's Go to Directory…) | | the pane's host lists folders |
| Pane | Go to Anything… | ⌘P | always (switches the palette to places) |
| Pane | Insert Path…, Insert Photo…, Insert File… | ⌃⌘I | as the attach menu |
| Pane | Paste into Pane, Select All in Pane | | a terminal pane |
| Pane | Copy from Pane | | text is selected in it |
| Pane | Delete to Line Start, Move to Line Start, Move to Line End, Move Back One Word, Move Forward One Word | ⌘⌫ ⌘← ⌘→ ⌥← ⌥→ | a terminal pane |
| Pane | Jump to Previous Prompt, Jump to Next Prompt | ⌘↑ ⌘↓ | a terminal pane |
| Pane | Scroll Page Up, Scroll Page Down | | a terminal pane |
| Pane | Clear Terminal, Reset Terminal (the terminal's own) | | its creator lists the method |
| Find | Find… | ⌘F | a terminal pane |
| Find | Find Next, Find Previous | ⌘G ⇧⌘G | find is open in the pane |
| View | Increase, Decrease, Reset Font Size | ⌘= ⌘- ⌘0 | always |
| View | Show/Hide Sidebar | ⌘/ | sidebar mode |
| View | Show/Hide Agents | ⌘. | always |
| View | Jump to Waiting (the app's own) | ⌥⌘. | an agent waits |

The app's wording wins where the Mac's breaks it: "…" where a question follows (Rename Tab…,
Rename Session…), Show/Hide for the Mac's Toggle (Toggle Sidebar, Toggle Activity), Send Key to
Rex for Send Key to Server, Add Computer… for Add Remote Host…. Pane commands run in the target
pane exactly as their keys do (`TerminalHost.performFromPalette`), behind the keys typed before.

The Mac's ⇧⌘G also opens Go to Directory… while find is closed; here a key runs one binding, so
⇧⌘G stays Find Previous. The Mac's ⇧⌘N is New Window; here ⌘N is New Session and ⇧⌘N nothing.

Not here, with the reason:

- Run only on the Mac, about the Mac app or its window: New Window, Close Window, Toggle Full
  Screen, Rex Diagnostics, Open Onboarding Session…, Grant System Permissions…, Toggle
  Visibility, the updates (Install Update, Relaunch when Idle, Check, Report, Install and
  Relaunch, Set Update Automation, Set Update Channel), Change Shortcut… (keys come from
  init.lua), Install Rex for Agents, Restart Server…, Move Tab to New Window, Quick Look, Toggle
  Toolbar Layout, Reveal Toolbar, Reveal Pane Header, Copy Config File Path, Import Theme File,
  Switch Appearance Mode, every Settings action (`client.setting.*`).
- The Mac's own view state the phone doesn't have: Collapse, Expand and Collapse Other Sessions
  (the sidebar folds by tap), Show Activity by Session or Priority, Focus Tab Filter, Mute Tab,
  Mark as Unread, Dismiss Notice, Switch Host, Change Theme… (Settings → Appearance).
- No server method the phone can call: Reload Config (`server.config_reload` answers only on the computer itself), Refresh Sessions
  (the list is live).
- Needs arguments: Go to Session, Split Pane, Focus Pane, Move Tab, Resize Pane, Send Key, Enter
  Mode. Their bound keys run, and bound ones with fixed arguments have rows (above).
- Duplicates: Close (`client.close`, Close Pane here), Focus Pane Left, Right, Up and Down (Focus
  Next and Previous Pane on the phone), Send Key to Rex (needs the key that ran it).
- Copy mode and key modes: only in the Rex app.
- Not yet: Move Pane Left, Right, Up and Down, Float Pane, New Floating
  Pane, Rename Pane, View Activity…, Pair Device with QR Code…, Copy Block ID, Copy Version Info,
  Copy Debug Info, Forward Port… (Ports covers it), New Session on Host….

## Running

- A session opens its active tab, a tab its tab, a pane its pane: through `AppModel.openPane`
  and the tab selection, which move the Mac's focused pane and active tab exactly as a pane
  switch, Agents mode and Jump to Waiting do (`session.focus_block`, `session.focus_window`).
  Nothing new reaches the Mac.
- An app command runs as its key does (`AppModel.perform`).
- A Lua or block action runs on the target pane through its input queue, behind the keys typed
  before it, with `origin: "palette"`. With no tab, a Lua action runs with no `session_id`.
  Without a connection it fails at once with "Didn't run Dev Layout: the connection dropped."
  and is never sent later; a key-bound action keeps the input queue's rules. After 1.5 s without an answer
  "Running Dev Layout…" shows on the notice job lane, for about 6 s at most.
- A place that closed meanwhile says "That tab closed." and leaves the recents.

## Move Tab to Session

The palette's way to Move to Session ([sidebar.md](sidebar.md), Move to Session). The Rex app
has no action for it, so the name follows Move Pane to Tab…, and it is the app's own action,
`client.tab.move_to_session`, listed after Move Tab Forward. A key the user's init.lua binds to
it works as any other.

- The row turns the palette into a session chooser in place, with an empty field and "Move tab to
  session" in it (`GoToScope.moveTab`): the target tab's computer's other sessions, in sidebar
  order, matched as Change Session matches. The key or a command run from elsewhere opens the
  palette in that scope on the tab on screen.
- Return or a tap moves the target tab to the session picked, last there, and closes the palette;
  the keyboard goes back to the pane, which stays on screen in its new session. Esc closes it
  and moves nothing.
- It shows only where the computer moves tabs and has another session.

## Undo Close

The Mac's Undo Close (`session.undo_close`, ⇧⌘T): the server's `client.undo_close` (revision
20) reopens the newest close this phone made on that computer, a pane, a tab or a session, within
about a minute, and the app shows it.

- **What can be undone.** Every close a person makes in the app asks to be undoable from revision
  20 (`ServerConnection.personsClose`): Close Pane, Close Other Panes, Close Tab (the menus, the
  swipe, Close Other Tabs), Close Session. The closes the app makes by itself never do: the
  placeholder of Move Pane to New Tab, a port's tunnel, the helper's setup tab.
- **Which computer.** The tab on screen's, else any online one that can; the row shows only then.
  With nothing left the server answers `not_found`: "Nothing to undo." Any other failure says
  why, as any other call does.
- **Showing it.** The answer names the session, tab and pane, which open as Go to Anything opens a
  pane (`openPane`). A session that comes back is announced as new (`session_created`) and the
  app attaches it; the tab waits for its view, 5 s at most. The close runs `CloseNext` as any
  close does; Undo then moves to what came back.
- **Streams.** The close ended the panes' streams. A pane the app kept off screen since then
  (`TerminalHostPool`) still holds that ended stream, so Undo lets every such pane of that
  computer go first (`dropClosedPanes`), and the pane opens a fresh one when it shows.

## Navigate Back and Forward

The Mac's "Goes back to the pane you were in before this one, in any tab or session" and
"Returns to the pane that Navigate Back left", with the Mac's keys (⌥⌘[ and ⌥⌘], from Rex's
Mac Actions page; the user's init.lua wins). With no tab on screen they work too.

- **The phone's own history** (`NavHistory`, kept by `AppModel`): a browser's back and forward
  lists of the places the phone showed, a place being a computer, session, tab and the pane the
  tab shows. A tab or pane the phone shows is a place once the turn ends, so a tap that sets
  both is one; the same place again is no step, and going somewhere new drops what lay
  forward. 64 places, like the Mac's server; not saved across launches.
- **Showing a place** is Go to Anything's pane pick (`openPane`): the tab, the pane in it, and
  `session.focus_block` and `session.focus_window`, nothing else. A place that can't show (its tab
  or pane closed, its pane is hidden in a minimized float, its computer isn't loaded) is passed
  over, and dropped when a step goes past it; with nowhere to go, Back bumps and nothing changes.
- **Only the phone's moves.** A focus change made on the Mac moves nothing in the list.
- **Not `focus_history.reverse`**: its history is the Tailscale login's (maybe shared with other
  devices) and leaves out the panes the phone pages on its own; it has no step forward and needs
  revision 19. docs/rex-protocol.md, Focus history, has the probes.

## Questions (rex.ui, revision 17)

A question shows in the palette only for a Lua or block action this phone ran (a key or the
palette), on the same server and connection, while that run's `client.action` still waits, and
within 10 s of the start (or of an answer from here). Input: a field with the action's
placeholder and value. Pick: the items as rows, filtered by the field; several with checks and
a confirm button; "Use “…”" for typed text where allowed. Cancel, Esc or a tap outside sends
`{"cancelled": true}`. It closes when another app answers, its timeout passes, or the connection
is new. Every other question is declined (docs/rex-protocol.md, Prompts).

## The pane never resizes

Opening the field takes the keyboard from the terminal, which takes the key bar's 44 pt with it;
opening from the menu raises the keyboard. Either would resize the panes and, in fit mode, the
pane on the Mac. So while the palette is open `PadHold` keeps the root's keyboard room as it was,
`WindowScreen` keeps `keyboardUp`, and find's fit hold is deferred (`FitHoldDeferral`). On close
the keyboard goes back to whoever had it (`KeyboardRecord`: shown, quiet, none, or the find
field); a pick of another pane owes that pane the keyboard for 2 s
(`TerminalHostPool.owe`). The hold ends at the first keyboard change after that, or 300 ms, and
at once when the root changes width. It ends with a fresh measure of the keyboard's room
(`PadHold.remeasure`), not the value it kept: that can be a report from the hand-back, before the
key bar was back above the keys.

## Measurements

Simulator (iPad Pro 13-inch M5), optimized build (`SWIFT_OPTIMIZATION_LEVEL=-O`,
`GoToPerfTests`, `GoToSourcePerfTests`):

| Work | Budget (device) | Measured |
|---|---|---|
| Copy at open, main actor, 1,860 rows | ≤ 3 ms for 2k | 3.1 ms first, 2.2 ms after |
| Index build, 2k items, off main | ≤ 25 ms | 1 ms |
| Query, 2k items | ≤ 4 ms | < 1 ms |
| Query, 10k items, worst of six | ≤ 20 ms | 10 ms |

A Debug build is about ten times slower.
