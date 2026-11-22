# iPhone Duo layout and the vertical bar

How Pteron lays out the sidebar and the tab, and how it uses the system's vertical bar on the
iPhone Duo. Checked against the iOS 27.2 SDK and Apple's docs, November 2026.

## What Apple says about the vertical bar

On the Duo's outer screen (and its inner screen in landscape), the system puts the status bar, the
Dynamic Island, toolbars and the tab bar in a column on one edge: the trailing edge for a full-screen
app, the outer edge in Split View ([HIG][hig]).

- **Background.** The bar has no background or scroll-edge effect of its own; it gets one only with
  Reduce Transparency on ([111462][bar]). The app's content shows under it, so a black column means
  the app drew nothing there. "Keep interactive content inside, let backgrounds extend behind bars"
  ([111461][prep]).
- **Which bars go vertical.** Only bars owned by a `NavigationStack`, `NavigationSplitView` or
  `TabView` (UIKit: navigation and tab bar controllers). A custom header or a standalone `UIToolbar`
  never does ([111462][bar]). In a split view only the detail column does.
- **Placement.** Top of the bar: navigation (Back, Close), then prominent actions; groups keep their
  grouping, and overflow fills from the bottom ([HIG][hig]). Custom back or close buttons use
  `.cancellationAction`; leading items go first ([111462][bar]).
- **Items.** Give each item a title and a symbol; text-only items and complex custom views stay
  horizontal. A custom view opts in with `.axisBehavior(.verticalPreferred)` and must fit the bar's
  fixed width. Reserve the ellipsis for the system overflow menu (`ToolbarOverflowMenu`); give other
  menus another symbol ([HIG][hig], [111462][bar]).
- **Safe area.** The bar adds a leading or trailing safe-area inset. Handle each inset on its own;
  don't hard-code a side ([HIG][hig]).
- **Appearance.** No tint or color API for the bar itself. Items take the app's tint; the bar shows
  whatever the app draws behind it.
- **Opting out.** `.toolbarVerticalBehavior(.disabled)` (UIKit: `preferredVerticalBarBehavior`) moves
  items back to horizontal bars and the status bar back to the top. Apple reserves it for
  full-screen, non-scrolling UIs such as Calculator ([111462][bar]).

SDK (iOS 27.1+): `UITraitCollection.verticalBarEdge`, SwiftUI `EnvironmentValues.toolbarVerticalEdge`,
`UIViewController.preferredVerticalBarBehavior`, `UIBarButtonItem.axisBehavior`,
`UINavigationItem.verticalBarCompressionBehavior`, `ToolbarItemVisibilityPriority`.

## What the app does

- **One sidebar model** (`Arrangement`, `SidebarSplit`). The tab always fills the window. At 600 pt
  wide or more inside the safe area (the unfolded Duo, iPhones in landscape) the sidebar sits
  inline at 260 pt. Narrower (folded Duo, iPhone portrait, half the inner screen, and the folded
  Duo on its side, which is 594 pt inside its vertical bar) the same sidebar is a drawer over the
  tab.
- **Tab mode** (`NavigationStyle`, `Prefs.navigation`). The other way around the app, like the
  Mac app's tabs above: no sidebar in any posture, and in the title bar's place, at 44 pt (34 pt in a short window),
  the tab strip (`TabStrip`). The choice is Settings → Appearance → Navigation; sidebar mode
  is the default. [tab-mode.md](tab-mode.md) has all of it; what follows is what the window
  and the fold decide.
  - **A change applies at once.** `SidebarSplit` stops building the sidebar and gives the tab the
    window's width, and the tab's header draws the strip instead of the title bar. The tab stays
    the same view with the same panes and terminals (`NavigationSwitchTests`). On a wide window
    the panes gain the sidebar's width, one fit resize; on a narrow one nothing changes size.
  - **What the strip shows** is decided from its width alone (`StripLayout`), left to right: the
    session chip, the session's tabs as chips (they scroll), the pane dots, the waiting pill,
    Unzoom, New Tab, the pane menu. Unzoom and the pane menu are in the vertical bar where there
    is one. The layout can keep one more 44 pt slot beside the pane menu, for a control of a
    tab's floating windows (`hasFloatsControl`); with it the strip is compact 44 pt sooner. Parts a finger taps are 44 pt wide or more; 6 pt lie between the session chip and
    the chips, between chips, and after them.
  - **Compact.** Where the full strip would leave the chips less than 144 pt (the active chip
    with its close button and one more chip), it is compact: New Tab and Unzoom are left to the
    Pane Actions menu and the session chip is a glyph with its waiting dot. That is under
    440 pt beside a vertical bar and under 520 pt without one: every iPhone in portrait, the
    folded Duo, half the inner screen. It is decided for the bar with every part in it, so a
    pill or dots that come and go never move the rest. The pane dots are the title bar's
    while they read clearly (up to six panes, and the chips keep 144 pt), else a count ("2/5")
    where it fits, else nothing ([tab-mode.md](tab-mode.md)). The title bar's own dots are
    unchanged.
  - **Chips.** The active chip shows the tab's title, the status of the pane on screen, the
    waking mark and a close button (`TabChip`); the close button goes where the chips have less
    than 144 pt, and Close Tab stays in the pane menu. Any other chip shows its tab's status as
    its sidebar row does, and cuts its title at 120 pt. A chip shows up to three pane icons.
  - **Crease.** In book mode the whole strip, New Tab included, ends 3 pt short of the crease,
    on the left page. Flat, it runs the bar's width as the title bar does. A bar with too
    little before the crease for the session chip (and the pane menu, where the strip has
    one) has its strip past the crease instead, and under 16 pt of room it draws nothing, so
    nothing is ever on the fold (`StripLayout.run`).
  - **Chips do** what the sidebar's tab rows do (`StripRoutes`). A tap shows the tab, and the
    row of chips scrolls to keep the tab on screen in view. Touch and hold for Rename Tab…,
    Move Tab Backward, Move Tab Forward, Close Tab and Close Other Tabs. A tab with an agent or
    two panes or more asks before it closes, as everywhere (`CloseTabAsk`); Close Other Tabs
    always asks. A move takes the sidebar drag's path:
    the new order shows at once and is held for the server, and a server without
    `session.move_window` offers no Move rows. Chips aren't dragged: a sideways drag scrolls
    the row.
  - **The session chip** opens the sessions in a popover (`SessionPopover`): each machine with
    its status, "+" for a new session there, Reconnect while it is down, and the globe of its
    web ports while it has one, which opens them in a sheet (`PortsSheet`); its sessions, a tap
    away, each with Rename Session… and Close Session on its menu, as in the sidebar (none on a
    computer that is down); the computers that aren't added; then Go to Anything…, Agents and
    Settings. A row that puts up a sheet, an alert or the palette runs once the popover has
    gone, and after 1 s at the latest (`DismissalWait`). The chip is as wide as its session's name needs, up to 120 pt.
  - **Vertical bar.** No sidebar toggle and no sessions item: the session chip beside the tabs
    opens the sessions, and the strip places it in every posture with the bar. The bar is Hide
    Keyboard while the key bar is up, then Show All Tabs, then Pane Actions (Unzoom above All
    Tabs while zoomed, with the keyboard down). With no toggle, All Tabs stays below Hide
    Keyboard while typing where the bar fits three (`TabActions.tabItems`). Back in sidebar mode
    the toggle is back and the bar is as before.
  - **Without the sidebar.** cmd+. and the board's "+K more" open the Agents sheet
    (`AppModel.showAgents`). Show/Hide Sidebar does nothing and isn't in the palette; the swipe
    from the left edge is off. With no tab on screen the strip stays, for its session chip,
    and the screen says "Pick a session." with Change Session, which opens the palette's
    sessions. A machine that is down shows its offline screen below the strip, so another
    machine's sessions stay a tap away; its Show Sidebar is Change Session.
  - **The sidebar is left as it was.** Nothing in tab mode writes whether it shows or which
    mode it is in (`SidebarState.write`): not a tab that is shown, not book mode, not a key.
    Back in sidebar mode it shows as before. Only two things differ: the list starts at its
    top, and the tab on screen has its row, its session and machine opened if they were folded.
  - **Typing in a short window** (a phone on its side) hides the strip with the keyboard, as
    it hides the title bar, so the terminal keeps its rows. Hide Keyboard brings it back, and
    the hardware keys work meanwhile.
- **A cold launch opens on its tab.** In a narrow window (the folded Duo) the drawer starts
  closed, so the tab viewed last shows (`SidebarState.launchHold`). Only at a process start in
  sidebar mode, and only with a tab to show: the tab viewed last on a computer still added, or
  the `-autoOpen` session's. It is decided from saved state when the model is made
  (`AppModel.launchHold`), so the first frame already has it, and the first window takes it: a
  scene the system rebuilds, a return from the background and tab mode are as before. Only the
  drawer: beside the tab the sidebar shows as at any launch. Never saved. The first change to the
  sidebar ends it, and so does the window turning wide, where the sidebar shows beside the tab.
- **Resize and collapse.** Drag the sidebar's edge: 200 pt to half the window inline, up to 85% as a
  drawer. It snaps to 260 pt and, inline, to the crease. Let go under 140 pt and it collapses. The
  width is remembered per posture. The toggle button, the Show/Hide Sidebar command and a swipe from
  the left edge show and hide it. A drag or toggle resizes the terminals once, never per frame.
  Hidden, it moves past the window's edge, also past a leading inset (the vertical bar on the
  left in Split View or landscape, the Dynamic Island), so none of it shows under the bar.
  `-simulateDuo foldedLandscapeBarLeft`, `halfWindowBarLeft` and `iPhoneLandscape`
  with `-sidebar closed` show those windows ([debug-args.md](debug-args.md)).
- **Book mode** (`BookSplit`). Partly folded with a vertical crease, a tab that shows its splits
  draws the side-by-side divider nearest the crease on the crease: the panes on its left fill the
  left page and the panes on its right fill the right page, each side keeping its proportions.
  Panes stay 3 pt clear of the fold's reserved region, which already includes Apple's tap margins.
  - **On** only when all of these hold: the fold reports an active vertical region; the tab has
    a side-by-side divider that runs the panes' full height (stacked splits may sit on either
    side of it); and every pane still keeps 40×8 cells on its page.
  - **Book mode collapses the sidebar** (`BookSidebar`). Beside the open sidebar the left page
    has too little room for a legible pane (191.5 pt of it beside the 260 pt sidebar; 40 columns
    need 264 pt at 11 pt text). So when the phone settles into book mode and the tab on screen
    has a split that fits the two pages with the sidebar collapsed (also one too narrow to show
    beside the sidebar), the sidebar collapses, with
    its usual slide, and the split moves to the crease in the same layout. When book mode ends,
    the sidebar comes back at the width it had, and the tab makes room once it has slid in.
    - Only on the way into book mode. Another tab, or a split made later, collapses nothing. A
      tab with nothing to align (one pane, a stacked top split, panes too narrow even with the
      sidebar collapsed) leaves the sidebar as it is.
    - The user's own choice stands. Show the sidebar during book mode and it stays; the tab is
      then laid out as when flat, and nothing collapses the sidebar again until the next time
      the phone goes into book mode. Hide it yourself and it stays hidden afterwards.
    - It is never stored: the sidebar's widths are saved only by a drag of its edge, and a
      launch starts with the sidebar showing. Only the inline sidebar is concerned; the drawer
      of a narrow window is left alone. Folded shut from book mode, the sidebar comes back when
      the window is wide again.
  - **Off**, and laid out exactly as when flat, in every other case: flat, tabletop, a single
    pane, a zoomed pane, one pane at a time, a tab whose top split is stacked, three columns too
    narrow for a page.
  - **Arrange.** Swap With keeps the splits. Balance Splits changes Rex's ratios while the aligned
    divider stays on the crease, display only. A tab that drops to one pane goes flat, and
    `BookSidebar` doesn't reopen the sidebar until book mode ends; a tab that gains a split
    while the sidebar is open stays flat.
  - **Display only.** Rex's split ratios don't change and the Mac's layout stays as it is. The
    panes are fitted to their new widths like after any layout change: one `terminal.resize`
    per pane each time the phone settles into or out of book mode, columns only.
  - **No handle on the aligned divider.** It sits on the crease whatever its ratio, so a drag
    would move the Mac's layout while nothing moved on the phone, and nothing tappable belongs
    in the crease. Flatten the phone (or use the Mac) to change that ratio. Other dividers keep
    their handles. A split that holds the aligned one (`a | b | c` with `b|c` on the crease)
    is dragged within its page, and Rex gets the ratio that puts the border where the finger
    let go.
  - **Settle** (`CreaseSettle`). A hand near the angle where the fold turns active flips it back
    and forth. The fold has to hold for 400 ms before book mode goes on or off (and before the
    sidebar moves), then the fit claim's 120 ms settle sends one resize. The first layout doesn't
    wait, and a crease that is gone or has moved (fully folded, rotated) is dropped at once.
  - **Floating windows** keep off the crease whether or not book mode is on: each moves onto
    the page that holds its center, 3 pt clear of the fold, narrowed to the page if it must be;
    if a pane in it would drop under 40×8 cells the tab shows one pane at a time instead. The
    tiled layer under them is laid out as above. Whether book mode collapses the sidebar is
    asked of the tiled splits alone, as for a tab without floats ([terminal.md](terminal.md),
    Floating windows).
- **Floating windows by posture.** Wide windows (unfolded, book, tabletop, iPhone landscape)
  draw them where the Mac places them, grown until each pane is legible. Narrow windows (folded,
  iPhone portrait, half the inner screen) lay the tiled panes out as without floats and show one
  float at a time in a sheet over them, from the title bar's floats glyph ([terminal.md](terminal.md),
  Floating windows, The float sheet). A tab whose floats are all minimized is laid out as if it
  had none.
- **Tent mode** (`TentDetector`, `Features/Board`). Folded back and stood on a desk as a tent,
  the phone shows the agent board on its outer screen instead of the tab: who needs you, read
  from a meter away.
  - **The hinge is used here and only here, to enter and to leave.** Enter: the window fills
    its screen, has no fold in it (an inactive one counts, so the inner screen never
    qualifies, and Split View there doesn't fill the screen), and the hinge has stayed between
    20° and 160° for one second. Leave at once: the hinge goes under 15° or stops reporting, or
    a fold appears in the window. Between 15° and 20° and above 160° a tent stays a tent. The
    decision reads the angle, never the hinge's status (`-hingeLog` logs both). An iPhone
    without a hinge, an iOS before 27.1, and a hinge that reports 0° on the outer screen never
    enter. Nothing about layout reads the hinge.
  - **Only where there is a hinge.** UIKit has no "does this device have a hinge" question;
    the one sign is a `UIHingeInteraction` update that carries a `UIHinge` (iOS 27.1+). A view
    of no size holds that interaction, and the rest of tent mode (detector, timers, touch
    watch, power observer, the panes' key hook) starts with the first such update. An iPhone
    that never reports a hinge, and any iOS before 27.1, gets an empty overlay and nothing else.
  - **What it shows.** One large line for the most urgent state ("2 waiting", else "1 error",
    "3 working", "All done", "All quiet"), and under it the machine, or how many are connected.
    Then a tile per agent that isn't idle, from the same data and in the same order as the
    sidebar's Agents mode, across machines: waiting (the longest first), error, working, done.
    A tile has the agent's glyph (its maker's mark in the foreground, `AgentGlyph`) in a ring
    for its state (an arc that turns slowly, or fills to its progress; a solid ring that
    breathes, with a raised hand; a full ring with a check or an x), its name, the state in the
    Agents mode's words, its last message and "session › tab".
    A waiting tile also says for how long ("12m"), the one time the app tracks. The machine's
    name shows only when the tiles span machines. Idle agents are a "+N idle" line. The edges
    glow in the most urgent state's color while somebody waits, fails or works.
  - **Layout by count, from the board's own size, never scrolling** (`BoardLayout`). One agent:
    a hero tile. Two: side by side or stacked, by the window's shape. Three: full rows in a
    tall window. Up to eight: two columns, the first tile on a row of its own when the count is
    odd. More, or more than the height holds: one tile fewer and "+K more", which opens the
    sidebar in Agents mode. Under 300 pt of width, one column. Larger text makes the header
    taller (up to 1.5×) and the tiles too (up to 1.25×), so fewer tiles show and none is cut.
  - **Quiet.** With no agent at work it is a desk clock with "All quiet" under it. With no
    server it says "No computers yet", with no button.
  - **Never stale as current.** Only connected machines count in the headline and the glow. A
    machine whose connection is down keeps its last known tiles, dimmed and after the live
    ones. The headline is "Reconnecting…" with none connected, and also instead of "All quiet"
    or "All done" while such tiles show: a dimmed tile that last needed you is not quiet. A pane whose program has exited
    has no tile.
  - **Display only** (`TerminalHostPool.setCovered`). The tab stays mounted under the board,
    with its streams, so it is there at once afterwards. Meanwhile its panes draw nothing and
    take no key, from a hardware keyboard or the key bar's cmd. Nothing is claimed, resized or
    given back on the Mac when the board comes or goes, also when the phone turns under it:
    `FIT_RESIZE` stays silent. The software keyboard and a sidebar drawer are put away on the
    way in, and the keyboard stays down afterwards, as after the hide key. A pane that showed
    only its key bar for a hardware keyboard gets it back.
  - **Touch** (`BoardPresence`). A tile opens its agent's tab with its pane in view, as in
    Agents mode, and the board goes. So does anything else that puts the app on screen: the
    sidebar, Settings, a tab opened from a push, an app shortcut. Still in tent, the board
    comes back after 60 s without a touch or a key; a keyboard on screen or a sheet counts as
    use. A sheet that is up when tent begins is left alone, and the board shows when it closes.
    Leaving tent removes the board.
  - **Around it.** No toast shows over the board; pushes are unchanged. Waiting agents' toasts
    are dropped (the board lists them); programs' notices wait and show as one toast after it. The screen stays awake
    while it shows, except in Low Power Mode, and the idle timer is given back when it goes or
    the app leaves the foreground. Reduce Motion holds the rings still, Reduce Transparency
    removes the glow, and VoiceOver reads the headline, then one button per tile.
  - **Reorder** (`BoardOrderThrottle`). Agents that change state quickly reorder the tiles at
    most once a second, with a spring; a tile that comes or goes fades at once.
- **Vertical bar.** Where `verticalBarEdge` reports a bar, the navigation bar shows and its items
  go there: the sidebar toggle (leading, top), then Show All Tabs and Pane Actions, then Floating
  Windows while a narrow tab has a float and the keyboard is down. While a pane's key bar is up,
  they are Hide Keyboard, the sidebar toggle, then Pane Actions (`TabActions`). Tab mode has no
  toggle: there they are Hide Keyboard, All Tabs, Pane Actions, and with the keyboard down All
  Tabs and Pane Actions. The tab's title,
  status and pane dots stay in the thin title bar, since text stays horizontal. Elsewhere the
  navigation bar stays hidden and the title bar holds the same buttons.
- **The browser's buttons.** A page's sheet (docs/terminal.md, Ports) has Done and its menu in
  the vertical bar, by the system, and back, forward and reload at the bar's bottom, by the app
  (`PreviewBarLayout`): they are not a toolbar's items, so the system does not move them.
- **Hide Keyboard.** The key bar's hide key, moved into the vertical bar beside the keyboard. It
  shows while the pane's key bar does, over the software keyboard or alone for a hardware one,
  and does what the hide key does: the software keyboard resigns, the bar alone goes quiet and
  hardware keys still type. The pane's host says when its key bar is up with the hide key in the
  bar (`TerminalHost.barHidesKeyboard`), never a keyboard notification alone; the notification
  only gives the swap the keyboard's animation, so it happens with the keyboard. With the
  keyboard up the bar has room for three items (the outer screen upright, and on its side with
  the bar on the right): a fourth, in any placement or priority, sends Pane Actions or the
  sidebar toggle into the system's "…" menu. So Hide Keyboard takes All Tabs' place in the count
  and goes first, at the top of the bar above the sidebar toggle (the root draws both), since
  while typing it is the item used most (owner's call, November 2026). With the keyboard down it
  is not in the bar at all, and the bar is the sidebar toggle, All Tabs, Pane Actions, as before;
  while typing All Tabs stays in the Pane Actions menu's first section and in the title menu.
  In tab mode the toggle's place is free, so All Tabs keeps its own below Hide Keyboard. In
  sidebar mode VoiceOver finds one of the two in the
  bar, and one Hide Keyboard in every state: the item, or without a vertical bar the key bar's
  own. On its side with the bar on the left, the bar's items start lower, past the camera, and
  with the keyboard up only two fit (iOS 27.2 simulator, November 2026). There, while the key bar
  is up, the sidebar toggle (in tab mode All Tabs) leaves the bar and it shows Hide Keyboard,
  then Pane Actions; what left comes back with the keyboard. Unzoom,
  where it shows, leaves first in any posture, and stays in the Pane Actions menu. Nothing goes into the "…" menu
  (`TabActions.keyBarRoom`). The system reports neither the items' frames nor the camera's
  offset, so the room comes from the bar's column on the screen's left and a compact height.
- **Key bar.** The keyboard keeps its full width and runs under the vertical bar; only the key
  bar's own views keep out of the bar's column. That column is the app window's safe-area inset
  on the bar's edge (`KeyBarPlacement.column`), read with the edge on every change of the traits
  behind it, the safe area and the layout (`VerticalBarObserver`), so a rotation or a fold moves
  it, and handed to each pane's key bar in screen coordinates. Beside it the key bar draws no
  hide key, its keys' capsule ends 6 pt short of the column, as at a screen edge, and it takes no
  touch in the column, which belongs to the bar's items. The find bar in the keyboard's accessory
  slot ends short of it the same way and keeps Done, which closes find. Without a vertical bar
  (iPhones, the inner screen in portrait, tabletop) the hide key stays at the bar's end as
  before. Either way the pinned Return closes the keys' capsule on the trailing side, so it sits
  next to the keyboard's own return, with the pinned attach key before it; both stay clear of a
  vertical crease in every posture (`PinnedAttachKeyTests`, `KeyBarColumnTests`). With a vertical
  crease, the key that would sit on it moves 12 pt past it, with the bar scrolled to its start.
- **Key bar look.** The iOS 26 keyboard is a glass panel with rounded top corners, so the bar has no
  background of its own. The keys sit bare in a glass capsule tinted with the keyboard's color, 6 pt
  from the sides like the keyboard's keys, with 4 pt of air above and below. At the bar's end the
  hide key is a matching glass circle. A pressed key or an active ctrl/alt shows a pill. With a
  hardware keyboard the bar still shows on its own at the bottom, for esc, ctrl and the arrows;
  its hide key, or Hide Keyboard in the vertical bar, puts it away.
- **Keyboard room.** The root ignores SwiftUI's keyboard safe area and pads its bottom by
  `KeyboardInset`, computed from the keyboard's last reported frame and the root's frame on every
  keyboard change and layout. SwiftUI's own could stay at a frame the keyboard had for a moment
  (both panes' key bars during a pane swipe) and leave a band of chrome above the key bar.
  While the keyboard is up the key bar's own top is a floor, for reports without it
  ([terminal.md](terminal.md), Input, Keyboard room).
  The panes' frames follow that room, but a fitted terminal's grid doesn't: the keyboard covers
  it ([terminal.md](terminal.md), Fit and mirror).
- **Background.** The chrome color runs edge to edge under the status bar and the vertical bar.
  The panes stay inside the safe area, so no terminal text sits under system UI. Below the panes
  the terminal's color runs on to the window's bottom: under the home indicator with the keyboard
  down, and behind the key bar and the keyboard's corners with it up. No band of chrome shows
  under the terminal.
- **Title bar** (`TitleLine`). One line, like the Mac's title bar: the tab's title (semibold),
  its status, then the session's name in the secondary color (with the computer's name when
  more than one is set up), then the menu chevron. When both don't fit, the session's name
  keeps up to a third of the line and both truncate; where the title would keep less than
  64 pt, the session's name leaves the line.
  - **Height.** As tall as its content, the taller of the line (from the font's metrics) and the
    22 pt glyphs, with 6 pt above and below: 34 pt at the default text size, nothing above or
    below it. It grows with the text size up to the strip's limit (`StripStyle.chipTypeLimit`),
    where the text stops growing too, so nothing in the bar clips. The session's name leaving
    the line changes nothing: one line, one height. Every button keeps its 44 pt width and
    takes the bar's height as its hit height; no hit area reaches over the terminal.
  - **Short windows** (landscape iPhone): 4 pt above and below, 30 pt at the default text size
    and never more than 34 pt.
- **Short windows** (landscape iPhone): the strip is 34 pt and the key bar 42 pt.
- **Offline screen** (`OfflineLayout`). It fills the tab, so an inline sidebar stays beside it. Where
  the crease crosses it with room on both sides, it is two pages: the glyph large on the left (or top)
  page, the card on the other, each centered in its page and 12 pt clear of the crease. With room for
  the card on one page only (sidebar over the left page, keyboard up), the card sits alone on that
  page. Elsewhere it is one centered card, tighter in windows under 480 pt tall. Pages are measured
  inside the safe area, so the vertical bar never tips the choice to the wrong page.

[hig]: https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo
[bar]: https://developer.apple.com/videos/play/tech-talks/111462/
[prep]: https://developer.apple.com/videos/play/tech-talks/111461/
