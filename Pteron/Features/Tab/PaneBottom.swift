import CoreGraphics

/// The window's bottom as the panes need it, all from UIKit's window and read in one pass
/// (`KeyboardInsetReader`): the home indicator's inset under the root, the side insets, and the
/// radii of its two bottom corners.
struct WindowBottom: Equatable {
    /// The window's bottom inset under the root (`KeyboardInset.home`).
    var home: CGFloat = 0
    /// The window's side safe insets: the landscape notch side, the Duo's vertical bar.
    var left: CGFloat = 0
    var right: CGFloat = 0
    /// The bottom corners' radii, from the window's own corner shape (iOS 26:
    /// `UICornerRadius.containerConcentric()`). Nil where the system doesn't say: then the panes
    /// keep to the safe area as before.
    var corners: Corners?

    struct Corners: Equatable {
        var left: CGFloat
        var right: CGFloat
        /// A window with square corners (`-simulateDuo`'s simulated one).
        static let square = Corners(left: 0, right: 0)
    }
}

/// Where the panes end at the bottom of the tab. Pure.
///
/// With the keyboard down the panes run on past the bottom safe area as far as the window's
/// rounded corners allow: no further than the height at which a corner would reach into the
/// first or last column (`cornerReach`), and never short of the safe area, where they always
/// ended. On a window with square corners, or where the corners stay outside the side insets
/// (a phone on its side, the Duo's bar side), that is the window's edge; an iPhone held upright,
/// whose corners would take cells off its last rows, keeps to the safe area as before. With the
/// software keyboard or the key bar alone up the panes keep to the safe area as before, so they
/// end at the keyboard's top exactly where they always did. The terminal's color runs on to the
/// edge in every case.
///
/// `home` is the window's own bottom inset under the tab (the home indicator), which UIKit reports
/// whatever the keyboard does (`KeyboardInset.home`). SwiftUI's safe area can't give it: with the
/// keyboard up the indicator's inset becomes part of the keyboard's region.
///
/// What is chrome stays inside the safe area: floating windows keep clear of the home indicator,
/// and controls drawn in a pane keep clear of its bottom safe area (`clear(_:safeBottom:)`), as the
/// jump-to-bottom button and the find bar do with theirs.
struct PaneBottom: Equatable {
    /// The panes' area ignores the bottom safe area and runs on past it, by `reach`.
    var reachesEdge: Bool
    /// How far the panes run past the safe area now: as far as the corners allow with the
    /// keyboard down, nothing with it up. Floating windows leave this much at the bottom, and of
    /// split panes only those on the bottom edge take it.
    var reach: CGFloat
    /// What is left of the bottom inset under the panes while they run past the safe area: the
    /// area ignores the inset and gives this back as padding.
    var trim: CGFloat
    /// How far the canvas with the keyboard down (`PaneLayout.restCanvas`) runs past the safe
    /// area: the corners' reach, except while the key bar alone is up, whose canvas is the one
    /// above it. With the keyboard up the rest canvas gives it back with the keyboard's room;
    /// floating windows' rest sizes leave it out.
    var restReach: CGFloat

    /// - Parameters:
    ///   - window: the window's bottom inset, side insets and corners.
    ///   - keyboardRoom: the room the docked keyboard or the key bar alone takes from the root's
    ///     bottom beyond that inset (`KeyboardInset`).
    ///   - padding: how far the panes' first and last columns sit inside the panes' area at the
    ///     bottom (`PaneLayout.bottomPadding`).
    ///   - tolerance: how far a corner may reach past that into a cell (`tolerance(fontSize:)`).
    ///   - reaches: the panes' area is at the bottom of the tab. Not in tabletop, where the panes
    ///     stay above the crease: there nothing changes.
    ///   - card: the part of `keyboardRoom` Compose's card takes, which stays while Compose is
    ///     open: the rest is the keyboard's (`EnvironmentValues.composeRoom`).
    init(window: WindowBottom, keyboardRoom: CGFloat, card: CGFloat = 0, padding: CGFloat, tolerance: CGFloat,
         reaches: Bool = true) {
        let room = reaches ? max(keyboardRoom, 0) : 0
        let corner = reaches ? Self.cornerReach(window, padding: padding, tolerance: tolerance) : 0
        reachesEdge = room == 0 && corner > 0
        reach = room == 0 ? corner : 0
        trim = reachesEdge ? max(window.home - corner, 0) : 0
        restReach = room == 0 || Self.softwareKeyboard(room - max(card, 0)) ? corner : 0
    }

    /// How far past the bottom safe area the panes may run with the keyboard down: up to the
    /// window's edge, less the height at which either bottom corner would reach further in than
    /// its side's gap (its side inset and `padding`) plus `tolerance`; never below the safe area.
    /// Nothing where the corners are unknown, so the panes end where they always did.
    static func cornerReach(_ w: WindowBottom, padding: CGFloat, tolerance: CGFloat) -> CGFloat {
        let home = max(w.home, 0)
        guard home > 0, let c = w.corners else { return 0 }
        let clear = max(clearHeight(radius: c.left, gap: max(w.left, 0) + padding + tolerance),
                        clearHeight(radius: c.right, gap: max(w.right, 0) + padding + tolerance))
        return max(home - clear, 0)
    }

    /// The lowest height above the window's bottom edge at which a corner of `radius` reaches in
    /// no further than `gap` from the side edge. The display draws continuous corners, which reach
    /// a little further than a circle of the same radius; measured against the masks of the
    /// iPhone 17 Pro, the iPad Pro and the iPhone Duo, a circle of `curve` times the radius plus
    /// `slack` stays outside them everywhere (`PaneBottomTests`).
    static func clearHeight(radius: CGFloat, gap: CGFloat) -> CGFloat {
        let r = max(radius, 0) * curve
        guard r > 0 else { return 0 }
        let g = min(max(gap - slack, 0), r)
        // A circle of radius r reaches in r - sqrt(r² - (r - y)²) at height y: no more than g
        // from r - sqrt(r² - (r - g)²) up.
        return r - (r * r - (r - g) * (r - g)).squareRoot()
    }

    static let curve: CGFloat = 1.09
    static let slack: CGFloat = 1

    /// How far a corner may reach into a pane's first or last cell: under half its width, so no
    /// cell loses most of its glyph. A cell is about 0.6 of the font size wide (`SplitGeometry`).
    static func tolerance(fontSize: Double) -> CGFloat { CGFloat(fontSize) * 0.3 }

    /// The canvas with the keyboard down kept inside the bottom safe area: `canvas` less the
    /// `restReach` it runs past it. What main's layout measured, and what every legibility
    /// decision reads (splits or pages, book mode, the floats and their sheet), so no tab shows
    /// differently because the drawn panes now run on to the edge. Floating windows' rest sizes
    /// come from it too. Nothing measured yet stays unmeasured.
    static func inside(_ canvas: CGSize, restReach: CGFloat) -> CGSize {
        guard canvas.width > 0, canvas.height > 0 else { return canvas }
        return CGSize(width: canvas.width, height: max(canvas.height - max(restReach, 0), 0))
    }

    /// The panes' area as measured: its size and the `restReach` it was laid out with. Either
    /// changing measures the rest canvas again.
    /// The panes' area's size with what its rest size is read from, taken in one layout: the
    /// keyboard's room and the card's part of it can change while the size stays (a keyboard the
    /// panes' host made room for before the root did), and the rest size must follow them too.
    struct Measure: Equatable {
        var size: CGSize
        var restReach: CGFloat
        var room: CGFloat = 0
        var card: CGFloat = 0
    }

    /// The room is the software keyboard's, not the key bar's alone (a hardware keyboard), whose
    /// room the grid fits above.
    static func softwareKeyboard(_ room: CGFloat) -> Bool { room > TentBoard.tallestKeyBar }

    /// The part of a pane's `bounds` clear of its bottom safe area `safeBottom` (the home
    /// indicator under a pane that reaches the window's edge): where a control may sit.
    static func clear(_ bounds: CGRect, safeBottom: CGFloat) -> CGRect {
        var r = bounds
        r.size.height = max(bounds.height - max(safeBottom, 0), 0)
        return r
    }
}
