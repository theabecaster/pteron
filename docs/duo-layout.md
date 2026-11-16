# iPhone Duo layout and the vertical bar

How Rex Connect lays out the sidebar and the tab, and how it uses the system's vertical bar on the
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
- **Vertical bar.** Where `verticalBarEdge` reports a bar, the navigation bar shows and its items
  go there: the sidebar toggle (leading, top), then All Tabs and Pane Actions. The tab's title,
  status and pane dots stay in the thin title bar, since text stays horizontal. Elsewhere the
  navigation bar stays hidden and the title bar holds the same buttons.
- **Background.** The chrome color runs edge to edge under the status bar and the vertical bar.
  The panes stay inside the safe area, so no terminal text sits under system UI.
- **Short windows** (landscape iPhone): the title bar is 34 pt with no subtitle, and the key bar is
  40 pt.
- **Offline screen** (`OfflineLayout`). It fills the tab, so an inline sidebar stays beside it. Where
  the crease crosses it with room on both sides, it is two pages: the glyph large on the left (or top)
  page, the card on the other, each centered in its page and 12 pt clear of the crease. With room for
  the card on one page only (sidebar over the left page, keyboard up), the card sits alone on that
  page. Elsewhere it is one centered card, tighter in windows under 480 pt tall. Pages are measured
  inside the safe area, so the vertical bar never tips the choice to the wrong page.

[hig]: https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo
[bar]: https://developer.apple.com/videos/play/tech-talks/111462/
[prep]: https://developer.apple.com/videos/play/tech-talks/111461/
