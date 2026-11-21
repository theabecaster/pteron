# Tab mode

Tab mode is the app's second navigation style, like the Rex Mac app's horizontal tabs: a tab
strip takes the title bar's place, at its height, and there is no sidebar. Sidebar mode is the
default and is unchanged. The choice is Settings → Appearance → Navigation: Sidebar or Tabs
(`NavigationStyle`, stored as `Prefs.navigation`), and the session popover's last row switches
back.

A change applies at once. `SidebarSplit` stops building the sidebar and gives the tab the
window's width, and the tab's header draws the strip instead of the title bar. The tab stays the
same view with the same panes and terminals (`NavigationSwitchTests`). On a wide window the
panes gain the sidebar's width, which is one fit resize; on a narrow one nothing changes size.

## The strip

`TabStrip` draws it and `StripLayout`, a pure type, says what shows and where, from the bar's
width alone. Left to right:

| Part | What it is |
| --- | --- |
| Session chip | The session on screen. A tap opens the session popover. |
| Tab chips | The session's tabs, in Rex's order. The row scrolls. |
| Pane dots | Which pane of the tab is on screen, as in the title bar. |
| Waiting pill | Agents waiting elsewhere. A tap shows the first. |
| Unzoom | Only while the tab is zoomed. |
| New Tab | "+". |
| Floating windows | A narrow tab's control for its floating windows, only while it has one. |
| Pane menu | Pane Actions, as in the title bar. |

- Every part a finger taps is 44 pt wide or more. 6 pt lie between the session chip and the
  chips, between two chips, and after the chips.
- The strip is 44 pt tall, and 34 pt in a short window, as the title bar is.
- Where the system has a vertical bar (the iPhone Duo), Unzoom and the pane menu are in that
  bar and not in the strip.
- **Compact.** Where the full strip would leave the chips less than 144 pt, New Tab and Unzoom
  are left to the Pane Actions menu, the dots are a count ("2/5") and the session chip is a
  glyph. That is under 440 pt beside a vertical bar and under 520 pt without one: every iPhone
  in portrait, the folded Duo, half the inner screen. The form is decided for the bar with
  every part in it, so a pill or dots that come and go never move the rest.
- **Text size.** The strip keeps its height at every text size. The chips' text grows up to
  the largest standard size (`StripStyle.chipTypeLimit`) and no further: at the accessibility
  sizes the strip is the same strip, and a long title truncates.

## Tab chips

A chip shows up to three pane icons, the tab's title and its status (`TabChip`, drawn by
`TabChipView`).

- The active chip is a filled capsule. It shows the status of the pane on screen, the waking
  mark and a close button. The close button goes where the chips have less than 144 pt; Close
  Tab stays in the pane menu.
- Any other chip shows its tab's status as its sidebar row does, and cuts its title at 120 pt.
- A tap shows the tab. The row scrolls to keep the tab on screen in view.
- Touch and hold: Rename Tab…, Move Tab Backward, Move Tab Forward, Close Tab, Close Other
  Tabs. They run what the sidebar's tab rows run (`StripRoutes`). A tab with an agent, or with
  two panes or more, asks before it closes; Close Other Tabs always asks.
- A move shows at once and is held for the server. A server without `session.move_window`
  offers no Move rows. Chips aren't dragged: a sideways drag scrolls the row.
- Only the chips in view are drawn, and a status or a title that changes draws its own chip
  again and nothing else.

## Session chip and popover

The session chip shows the session's name and a chevron, a dot while agents wait in that
session, and the computer's name under it where more than one computer is set up and the bar is
tall enough.

- **Width.** The chip is as wide as its name needs, between 44 pt and 120 pt; a longer name
  truncates. The room a short name leaves goes to the tab chips. The strip measures the chip
  (`SessionChipIdeal`, drawn hidden) and hands the width to `StripLayout`, which stays pure.
  The measure always keeps room for the waiting dot, so the dot comes and goes without moving
  the tabs.
- **The popover** (`SessionPopover`, `SessionPopoverView`) is one scrolling list:
  - each computer with its status, "+" for a new session there, Reconnect while it is down,
    and the globe of its web ports while it has one, which opens them in a sheet
    (`PortsSheet`);
  - its sessions: a tap shows the session's front tab; touch and hold for Rename Session… and
    Close Session (none on a computer that is down);
  - the computers that aren't added, each with Add;
  - a footer: Go to Anything…, Agents, Settings, Switch to Sidebar.
- With no session on screen the chip says "Sessions", and the strip holds little else.

## Where the sidebar's things are

| Thing | Sidebar mode | Tab mode |
| --- | --- | --- |
| Sessions | sidebar | session chip → popover; Change Session (⌘K by default) |
| Tabs | sidebar rows, title menu, title swipe | tab chips; All Tabs |
| Computers, status, Reconnect | sidebar headers | popover headings |
| Computers not added | sidebar | popover; Settings → Computers |
| Ports | sidebar header's globe | popover heading's globe |
| Agents | sidebar's Agents mode, ⌘. | popover's Agents row, ⌘. (the Agents sheet) |
| Settings | sidebar's gear, ⌘, | popover's Settings row, ⌘, |
| Go to Anything | title menu, ⌘P | popover's row, ⌘P |
| Rename and Close Session | sidebar row's menu | popover row's menu |
| Reorder sessions | drag in the sidebar | sidebar mode only |

- Show/Hide Sidebar does nothing in tab mode and isn't in the palette. The swipe from the left
  edge is off. The board's "+K more" opens the Agents sheet.
- With no tab on screen the strip stays, for its session chip, and the screen says "Pick a
  session." with Change Session. A computer that is down shows its offline screen below the
  strip, so another computer's sessions stay a tap away.
- Nothing in tab mode writes the sidebar's state (`SidebarState.write`). Back in sidebar mode
  it shows as it was left.
- Typing in a short window (a phone on its side) hides the strip with the keyboard, as it
  hides the title bar, so the terminal keeps its rows. Hide Keyboard brings it back.

## Postures and the crease

The strip is laid out from its bar's width and the fold's reserved region, never from the
device or the orientation ([duo-layout.md](duo-layout.md)).

- **Vertical bar.** Sessions takes the sidebar toggle's place in the bar and opens the same
  popover from the item. Nothing else in the bar moves, so it holds as many items in both modes
  (`TabActions.verticalBar`).
- **Book mode.** The whole strip, New Tab included, is on the left page and ends 3 pt short of
  the crease. Flat, it runs the bar's width as the title bar does.
- **A crease near the bar's start.** A bar with less than a hit target before the crease has
  its strip past the crease instead, 3 pt clear of it. With a hit target on neither side the
  strip keeps the wider side and the session chip is cut to it. Nothing is ever drawn on the
  crease (`StripLayout.run`).
- **Tabletop.** The fold runs across the window and the tab is above it, so the strip is the
  top of the upper half at full width.
- `StripLayoutTests` lays the strip out in every posture of `DuoSimulation.postures`, with and
  without the vertical bar's items, and checks that every frame is inside the bar, none is on
  the crease, and both modes' bar lists fit.

## The dismissal wait

A popover row that puts up a sheet, an alert or the palette can't do it while the popover is
still on screen: a sheet doesn't open over a popover, and the palette's field wants the
keyboard. So the row's action is held until the popover has gone (`DismissalWait`).

- The popover's content leaving the screen is the signal: that is the end of the real
  dismissal, however long the system takes.
- A cap of 1 s. If no signal comes, the action runs when the cap runs out, so a row never
  does nothing.
- The action is held before the popover is told to close, and it runs once.
- Rows that present nothing (a session, New Session, Reconnect, Switch to Sidebar) run at once.
- The ports lists use the same wait: the sidebar's ports popover, and tab mode's ports sheet,
  where the sheet's own dismissal is the signal.

The sleep behind the cap is given to the type, so `DismissalWaitTests` drive the cap
themselves and no test waits on a clock.

## Testing

`-navigation tabs|sidebar` starts a run in that style without changing the saved choice
([debug-args.md](debug-args.md)). With `-simulateDuo <posture>` it shows the strip in every
posture on one simulator.

| What | Tests |
| --- | --- |
| The strip's frames, compact rules, crease, postures | `StripLayoutTests` |
| Chips, the session chip and the popover's rows | `TabStripModelTests` |
| What each row and chip action runs | `StripRoutesTests` |
| The measured session chip, text sizes, fifty tabs, taps | `StripViewTests` |
| The dismissal wait and its cap | `DismissalWaitTests` |
| A change of mode keeps the tab and its panes | `NavigationSwitchTests` |
| The Navigation setting | `SettingsTests` |
