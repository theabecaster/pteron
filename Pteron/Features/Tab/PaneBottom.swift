import CoreGraphics

/// Where the panes end at the bottom of the tab. Pure.
///
/// With the keyboard down the panes run to the window's bottom edge, on every device and in every
/// posture: the last row may sit under the home indicator, a thin line over text that would
/// otherwise be a band of empty background. Their area then ignores the bottom safe area. With the
/// software keyboard or the key bar alone up it keeps to the safe area as before, so the panes end
/// at the keyboard's top exactly where they always did.
///
/// `home` is the window's own bottom inset under the tab (the home indicator), which UIKit reports
/// whatever the keyboard does (`KeyboardInset.home`). SwiftUI's safe area can't give it: with the
/// keyboard up the indicator's inset becomes part of the keyboard's region.
///
/// What is chrome stays inside the safe area: floating windows keep clear of the home indicator,
/// and controls drawn in a pane keep clear of its bottom safe area (`clear(_:safeBottom:)`), as the
/// jump-to-bottom button and the find bar do with theirs.
struct PaneBottom: Equatable {
    /// The panes' area ignores the bottom safe area and runs to the window's edge.
    var reachesEdge: Bool
    /// How far the panes run past the safe area now: the home indicator's inset with the keyboard
    /// down, nothing with it up. Floating windows leave this much at the bottom, and of split
    /// panes only those on the bottom edge take it.
    var reach: CGFloat
    /// How far the canvas with the keyboard down (`PaneLayout.restCanvas`) runs past the safe
    /// area: the home indicator's inset, except while the key bar alone is up, whose canvas is
    /// the one above it. With the keyboard up the rest canvas gives it back with the keyboard's
    /// room; floating windows' rest sizes leave it out.
    var restReach: CGFloat

    /// - Parameters:
    ///   - home: the window's bottom inset under the tab.
    ///   - keyboardRoom: the room the docked keyboard or the key bar alone takes from the root's
    ///     bottom beyond that inset (`KeyboardInset`).
    ///   - reaches: the panes' area is at the bottom of the tab. Not in tabletop, where the panes
    ///     stay above the crease: there nothing changes.
    init(home: CGFloat, keyboardRoom: CGFloat, reaches: Bool = true) {
        let home = reaches ? max(home, 0) : 0
        let room = reaches ? max(keyboardRoom, 0) : 0
        reachesEdge = reaches && room == 0
        reach = room == 0 ? home : 0
        restReach = room == 0 || Self.softwareKeyboard(room) ? home : 0
    }

    /// The panes' area as measured: its size and the `restReach` it was laid out with. Either
    /// changing measures the rest canvas again.
    struct Measure: Equatable {
        var size: CGSize
        var restReach: CGFloat
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
