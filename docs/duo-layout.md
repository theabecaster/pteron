# iPhone Duo layout and the vertical bar

How Rex DUO lays out the sidebar and the tab, and how it uses the system's vertical bar on the
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
  wide or more (every landscape, the unfolded Duo, the folded Duo on its side) the sidebar sits
  inline at 260 pt. Narrower (folded Duo, iPhone portrait, half the inner screen) the same sidebar
  is a drawer over the tab.
- **Resize and collapse.** Drag the sidebar's edge: 200 pt to half the window inline, up to 85% as a
  drawer. It snaps to 260 pt and, inline, to the crease. Let go under 140 pt and it collapses. The
  width is remembered per posture. The toggle button, the Toggle Sidebar command and a swipe from
  the left edge show and hide it. A drag or toggle resizes the terminals once, never per frame.
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
- **Vertical bar.** Where `verticalBarEdge` reports a bar, the navigation bar shows and its items
  go there: the sidebar toggle (leading, top), then All Tabs and Pane Actions. The tab's title,
  status and pane dots stay in the thin title bar, since text stays horizontal. Elsewhere the
  navigation bar stays hidden and the title bar holds the same buttons.
- **Key bar.** The keyboard runs under the vertical bar, so the key bar has a safe-area inset there.
  Where the bar sits beside it, the hide key moves into that column as a glass circle in line with
  the bar's items (the whole column takes the tap), and the keys scroll across the full width
  (`KeyBarPlacement`). Elsewhere the hide key stays at the bar's end. With a vertical crease, the key
  that would sit on it moves 12 pt past it, with the bar scrolled to its start.
- **Key bar look.** The iOS 26 keyboard is a glass panel with rounded top corners, so the bar has no
  background of its own. The keys sit bare in a glass capsule tinted with the keyboard's color, 6 pt
  from the sides like the keyboard's keys, with 4 pt of air above and below. At the bar's end the
  hide key is a matching glass circle; in the vertical bar's column it is plain glass, like that
  bar's items. A pressed key or an active ctrl/alt shows a pill. With a hardware keyboard the bar
  still shows on its own at the bottom, for esc, ctrl and the arrows; its hide key puts it away.
- **Keyboard room.** The root ignores SwiftUI's keyboard safe area and pads its bottom by
  `KeyboardInset`, computed from the keyboard's last reported frame and the root's frame on every
  keyboard change and layout. SwiftUI's own could stay at a frame the keyboard had for a moment
  (both panes' key bars during a pane swipe) and leave a band of chrome above the key bar.
  The panes' frames follow that room, but a fitted terminal's grid doesn't: the keyboard covers
  it ([terminal.md](terminal.md), Fit and mirror).
- **Background.** The chrome color runs edge to edge under the status bar and the vertical bar.
  The panes stay inside the safe area, so no terminal text sits under system UI. Below the panes
  the terminal's color runs on to the window's bottom: under the home indicator with the keyboard
  down, and behind the key bar and the keyboard's corners with it up. No band of chrome shows
  under the terminal.
- **Short windows** (landscape iPhone): the title bar is 34 pt with no subtitle, and the key bar is
  42 pt.
- **Offline screen** (`OfflineLayout`). It fills the tab, so an inline sidebar stays beside it. Where
  the crease crosses it with room on both sides, it is two pages: the glyph large on the left (or top)
  page, the card on the other, each centered in its page and 12 pt clear of the crease. With room for
  the card on one page only (sidebar over the left page, keyboard up), the card sits alone on that
  page. Elsewhere it is one centered card, tighter in windows under 480 pt tall. Pages are measured
  inside the safe area, so the vertical bar never tips the choice to the wrong page.

[hig]: https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo
[bar]: https://developer.apple.com/videos/play/tech-talks/111462/
[prep]: https://developer.apple.com/videos/play/tech-talks/111461/
