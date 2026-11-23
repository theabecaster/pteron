# Go to Anything and the command palette

One palette, three ways in, each the Rex Mac app's action of the same name. Keys come from the
server's keymap (the user's init.lua wins), never fixed:

| Action | Opens | Default key | Field says |
|---|---|---|---|
| `pane.go_to` (Go to Anything…) | places first, then up to five commands | ⌘P | Go to tab, pane or session |
| `session.switch` (Change Session…) | sessions | ⌘K | Change session |
| `client.palette.toggle` (Command Palette…) | commands | ⇧⌘P | Run a command |

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
- The app's commands that apply now. Pane and tab commands need a tab on screen; Zoom only when
  the tab can zoom; Arrange's commands follow `PaneArrange.isAvailable`, the pane menu's gate.
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
- Copy mode, dimmed ("Copy mode is only on the Mac."), only where the keymap binds one of its
  actions.

Empty field: Go to Anything shows Waiting (three at most, oldest first) and Recent (eight,
without the tab on screen); with neither, every place. Change Session lists sessions; the
commands palette shows recent commands, then all by category.

Matching folds case, accents and width (`é`, `É` and `ｅ` read `e`) and scores word starts,
runs and a field's start. Every word must match some field. Weights: tab title 1.0, session 0.9,
pane name and program 0.7, directory 0.7, machine 0.6, the last six hex digits of an ID 0.5
(only for a query of four hex digits or more). Boosts: recent use up to +30% (halving every three
days), a waiting agent +15%, the tab on screen −30%, an offline server −40%. Ties keep sidebar
order. A digit query puts that tab of the current session first. In Go to Anything, Close Pane,
Close Tab, Clear and Reset are never row 1; if every row is one, nothing is selected.

The selection is an item, not a row number: a rebuild landing between ↓ and Return runs what
was selected. While open, the list is rebuilt at most every 250 ms when servers, sessions, tabs
or agents change; a title or directory change doesn't rebuild it.

## Running

- A session opens its active tab, a tab its tab, a pane its pane: through `AppModel.openPane`
  and the tab selection, which move the Mac's focused pane and active tab exactly as a pane
  switch, Agents mode and Jump to Waiting do today (`session.focus_block`,
  `session.focus_window`). Nothing new reaches the Mac.
- An app command runs as its key does (`AppModel.perform`).
- A Lua or block action runs on the target pane through its input queue, behind the keys typed
  before it, with `origin: "palette"`. With no tab, a Lua action runs with no `session_id`.
  Without a connection it fails at once with "Didn't run Dev Layout: the connection dropped."
  and is never sent later; a key-bound action keeps today's queue. After 1.5 s without an answer
  "Running Dev Layout…" shows on the notice job lane, for about 6 s at most.
- A place that closed meanwhile says "That tab closed." and leaves the recents.

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

Simulator (iPad Pro 13-inch M5, iOS 27.2), optimized build (`SWIFT_OPTIMIZATION_LEVEL=-O`,
`GoToPerfTests`, `GoToSourcePerfTests`), 2026-11-20:

| Work | Budget (device) | Measured |
|---|---|---|
| Copy at open, main actor, 1,860 rows | ≤ 3 ms for 2k | 3.1 ms first, 2.2 ms after |
| Index build, 2k items, off main | ≤ 25 ms | 1 ms |
| Query, 2k items | ≤ 4 ms | < 1 ms |
| Query, 10k items, worst of six | ≤ 20 ms | 10 ms |

A Debug build is about ten times slower. Instruments' Animation Hitches on the Duo (300 tabs,
typing six letters) is still to be recorded; it needs an install on the phone.
