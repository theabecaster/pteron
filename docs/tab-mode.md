# Tab mode

Tab mode is the app's second navigation style, like the Rex Mac app's horizontal tabs: a tab
strip takes the title bar's place, and there is no sidebar. Sidebar mode is the
default. The choice is Settings → Appearance → Navigation: Sidebar or Tabs
(`NavigationStyle`, stored as `Prefs.navigation`).

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
| Floating windows | A narrow tab's control for its floating windows, only while it has one (`hasFloatsControl`: one more 44 pt slot, so the strip turns compact 44 pt sooner). |
| Pane menu | Pane Actions, as in the title bar. |

- Every part a finger taps is 44 pt wide or more. 6 pt lie between the session chip and the
  chips, between two chips, and after the chips.
- The strip is 44 pt tall, and 34 pt in a short window. (Sidebar mode's title bar is as tall as
  its one line: [duo-layout.md](duo-layout.md), Title bar.)
- Where the system has a vertical bar (the iPhone Duo), Unzoom and the pane menu are in that
  bar and not in the strip.
- **Compact.** Where the full strip would leave the chips less than 144 pt, New Tab and Unzoom
  are left to the Pane Actions menu and the session chip is a glyph. That is under 440 pt
  beside a vertical bar and under 520 pt without one: every iPhone in portrait, the folded
  Duo, half the inner screen. The form is decided for the bar with every part in it, so a pill
  or dots that come and go never move the rest.
- **Pane dots.** The title bar's dots (`PaneDots`) while they read clearly, else a count
  ("2/5") where it fits, else nothing (`StripLayout.dotsForm`). Dots read clearly up to six
  panes, the title bar's own cap, and while they leave the chips 144 pt (the active chip with
  its close button and one more). The count needs the chips to keep one chip's width; with no
  room for chips at all, whichever fits. The form is decided with the session chip at its
  widest, so a session's name never changes it. The title bar's own dots are unchanged.
- **Text size.** The strip keeps its height at every text size. The chips' text grows up to
  the largest standard size (`StripStyle.chipTypeLimit`) and no further: at the accessibility
  sizes the strip is the same strip, and a long title truncates.

## Tab chips

A chip shows up to three pane icons, the tab's title and its status (`TabChip`, drawn by
`TabChipView`).

- The pane icons stack like a deck, as the Mac's tabs stack them (`PaneStack`). The active
  pane's icon is in front at full size: the pane on screen on the active chip, the tab's own
  active pane on any other. Behind it come the panes after it in the tab's order, round to the
  first, each 6 pt further right and 2 pt higher, smaller (82 %, then 68 %) and dimmer, with a
  1.5 pt cutout around the icon over it. A stack of two is 21 pt wide and of three 27 pt. A
  one-pane tab shows its one icon.
- A new active pane on the same chip (a tap on another pane, a swipe between panes, a split's
  focus moving) brings its icon forward and sends the old one back in a 0.25 s spring. A tab
  switch, a chip's first draw and a relayout show the new order at once
  (`TabChip.stackMoves`). With Reduce Motion the stack crossfades. The motion is a transaction
  on the front pane's id changing: nothing runs while it rests.
- The icons are decoration, hidden from VoiceOver.
- The active chip is a filled capsule. It shows the status of the pane on screen, the waking
  mark and a close button. The close button goes where the chips have less than 144 pt; Close
  Tab stays in the pane menu.
- Any other chip shows its tab's status as its sidebar row does, and cuts its title at 120 pt.
- A tap shows the tab. The row scrolls to keep the tab on screen in view, also when a swipe on
  the terminal goes on to another tab ([terminal.md](terminal.md), Gestures).
- Touch and hold: Rename Tab…, Move Tab Backward, Move Tab Forward, Move to Session (a submenu
  of the computer's other sessions, in sidebar order, on a computer at revision 22 or later;
  [sidebar.md](sidebar.md), Move to Session), Close Tab, Close Other Tabs. They run what the
  sidebar's tab rows run (`StripRoutes`). VoiceOver's actions on a chip add "Move to <session>"
  for each session (`TabChip.spokenActions`). A tab with an agent, or with two panes or more,
  asks before it closes, as everywhere (`CloseTabAsk`); Close Other Tabs always asks.
- A question shows from the control that was tapped, never from the bottom of the screen:
  Close Tab at the chip's close button (at the chip, from its menu), Close Other Tabs at the
  chip, and Close Pane, Close Tab and Close Other Panes from the pane menu at the pane menu
  (`StripDialogs`, `ChipsAnchor`). The words are the sidebar's (`SidebarDialogs`). The chips'
  questions show from one view laid over the row, not from a chip: chips are drawn only in
  view, and the question stays up while they are drawn again, scrolled away or moved. Each
  question holds the ids it was asked about, so its answer closes that tab even after the
  computer reordered the tabs, and while one is up another tap asks nothing
  (`StripRoutesTests`, `StripViewTests`). The rename alert shows in the middle, as alerts do.
- A move shows at once and is held for the server. A server without `session.move_window`
  offers no Move rows. Chips aren't dragged: a sideways drag scrolls the row.
- Only the chips in view are drawn, and a status or a title that changes draws its own chip
  again and nothing else.

## Session chip and popover

The session chip shows the session's name and a chevron, a dot while agents wait in that
session, and the computer's name under it where more than one computer is set up and the bar is
tall enough.

- **Width.** The chip is as wide as its name needs, between 44 pt and 120 pt; a longer name
  truncates. The room a short name leaves goes to the tab chips. The strip's row (`StripRow`,
  a SwiftUI `Layout`) asks the chip for its own width while it places the parts and hands it
  to `StripLayout`, which stays pure: one layout pass, so a new strip never draws at one width
  and then shifts. The chip always keeps room for the waiting dot, so the dot comes and goes
  without moving the tabs.
- **The popover** (`SessionPopover`, `SessionPopoverView`) is one scrolling list:
  - each computer with its status, "+" for a new session there, Reconnect while it is down,
    and the globe of its web ports while it has one, which opens them in a sheet
    (`PortsSheet`);
  - its sessions: a tap shows the session's front tab; touch and hold for Rename Session… and
    Close Session (none on a computer that is down). Close Session asks from the session chip,
    once the popover has gone;
  - the computers that aren't added, each with Add;
  - a footer: Go to Anything…, Agents, Settings.
  - From iOS 26 it stands on the system's glass, arrow and all, with no fill of its own: the
    system puts the content under the arrow, so a fill there showed the glass's arrow and a rim
    of it at the corners. Before iOS 26 the sidebar's color fills it.
- With no session on screen the chip says "Sessions", and the strip holds little else.

## Where the sidebar's things are

| Thing | Sidebar mode | Tab mode |
| --- | --- | --- |
| Sessions | sidebar | session chip → popover; Change Session (⌘K by default) |
| Tabs | sidebar rows, title menu, title swipe, terminal swipe | tab chips; All Tabs; terminal swipe |
| Computers, status, Reconnect | sidebar headers | popover headings |
| Computers not added | sidebar | popover; Settings → Computers |
| Ports | sidebar header's globe | popover heading's globe |
| Agents | sidebar's Agents mode, ⌘. | popover's Agents row, ⌘. (the Agents sheet) |
| Settings | sidebar's gear, ⌘, | popover's Settings row, ⌘, |
| Go to Anything | title menu, ⌘P | popover's row, ⌘P |
| Rename and Close Session | sidebar row's menu | popover row's menu |
| Reorder sessions | drag in the sidebar | sidebar mode only |
| Move a tab to another session | tab row's menu, drag onto the session | chip's menu; Move Tab to Session… |

- Show/Hide Sidebar does nothing in tab mode and isn't in the palette. The swipe from the left
  edge is off. cmd+. and the board's "+K more" open the Agents sheet (`AppModel.showAgents`).
- With no tab on screen the strip stays, for its session chip, and the screen says "Pick a
  session." with Change Session, which opens the palette's sessions. A computer that is down
  shows its offline screen below the strip, so another computer's sessions stay a tap away; its
  Show Sidebar is Change Session.
- Nothing in tab mode writes the sidebar's state (`SidebarState.write`): not a tab that is
  shown, not book mode, not a key. Back in sidebar mode it shows as it was left, except that the
  list starts at its top and the tab on screen has its row, session and computer unfolded.
- Typing in a short window (a phone on its side) hides the strip with the keyboard, as it
  hides the title bar, so the terminal keeps its rows. Hide Keyboard brings it back; hardware
  keys work meanwhile.

## Postures and the crease

The strip is laid out from its bar's width and the fold's reserved region, never from the
device or the orientation ([duo-layout.md](duo-layout.md)).

- **Vertical bar.** The bar has no sidebar toggle and no item for the sessions: the session
  chip, which the strip places in every posture with the bar, opens them, so an item would
  repeat it. The bar is Hide Keyboard while the key bar is up, then Show All Tabs, then Pane
  Actions, with Unzoom above All Tabs while zoomed. With the keyboard down that is Unzoom, All
  Tabs, Pane Actions. While typing, the room the toggle leaves keeps All Tabs below Hide
  Keyboard where the bar fits three; where it fits two (the outer screen on its side, the bar on
  the left) the bar is Hide Keyboard and Pane Actions. Unzoom leaves first, as in sidebar mode,
  and nothing goes into the system's "…" menu (`TabActions.tabItems`).
- **Book mode.** The whole strip, New Tab included, is on the left page and ends 3 pt short of
  the crease. Flat, it runs the bar's width as the title bar does.
- **A crease near the bar's start.** The strip stays before the crease while that side holds
  the session chip as a hit target, and the pane menu with its gap where the strip has one. A
  bar with less has its strip past the crease instead, 3 pt clear of it. With that room on
  neither side the strip keeps the wider side and the session chip is cut to it; under 16 pt
  it draws nothing. A trailing part needs its width and a 6 pt gap beside the session chip,
  and the first without room ends them. Nothing is ever drawn on the crease
  (`StripLayout.run`).
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
  dismissal, however long the system takes. `PopoverRowsTests` tap every row in the real root
  and see what it presents come up.
- A cap of 1 s. If no signal comes, the action runs when the cap runs out, so a row never
  does nothing. The cap's timer keeps the wait alive, so that holds when the view that made
  the wait is torn down with the popover.
- The action is held before the popover is told to close, and it runs once.
- Rows that present nothing (a session, New Session, Reconnect) run at once.
- Tab mode's surfaces use it: the session chip's popover, and the ports sheet, where the
  sheet's own dismissal is the signal.
  Sidebar mode's title menu and its ports popover wait a fixed 350 ms.

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
| Every popover row presents what it should | `PopoverRowsTests` |
| A change of mode keeps the tab and its panes | `NavigationSwitchTests` |
| The Navigation setting | `SettingsTests` |
