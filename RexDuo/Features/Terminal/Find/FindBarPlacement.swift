import CoreGraphics

/// Where the find bar floats in its pane while it isn't in the keyboard's accessory slot. Pure.
///
/// - Main screen: at the bottom, 8 pt from the sides, clear of the home indicator.
/// - Alternate screen (an editor, a pager): at the top, below the safe area and below the status
///   chip while it shows, so "tap to fit here" stays tappable. It moves to the bottom only while
///   the current match lies under it, and only when the user stepped or changed the needle.
/// - A vertical crease inside the pane: the bar stays on the side with more room, 12 pt clear of it.
enum FindBarPlacement {
    enum Edge: Equatable { case top, bottom }

    /// How much of the bar fits: the count and Previous go first.
    enum Size: Equatable {
        case full, compact, minimal
    }

    static let sideMargin: CGFloat = 8
    static let compactWidth: CGFloat = 300
    static let minimalWidth: CGFloat = 200
    /// The status chip's frame (`TerminalHost.layoutStatus`): y 8, height 22.
    static let chipBottom: CGFloat = 30

    static func size(width: CGFloat) -> Size {
        width < minimalWidth ? .minimal : width < compactWidth ? .compact : .full
    }

    /// The edge for this moment. `current` is the edge the bar is at now; `matchRows` the current
    /// match's span in points from the pane's top, if it is on screen; `flip` true only for a
    /// step or a needle change (output never moves the bar).
    static func edge(alternateScreen: Bool, current: Edge, barHeight: CGFloat, paneHeight: CGFloat, safeTop: CGFloat,
                     matchRows: ClosedRange<CGFloat>?, flip: Bool) -> Edge {
        guard alternateScreen else { return .bottom }
        guard flip else { return current }
        let topBar = (safeTop + sideMargin)...(safeTop + sideMargin + barHeight)
        if let m = matchRows, m.overlaps(topBar) { return .bottom }
        return .top
    }

    /// The bar's frame in the pane.
    /// - Parameters:
    ///   - chipShown: the status chip is up (the top bar goes below it).
    ///   - crease: a vertical crease's x span in the pane's coordinates, if one crosses it.
    static func frame(bounds: CGRect, safeTop: CGFloat, safeBottom: CGFloat, edge: Edge, barHeight: CGFloat,
                      chipShown: Bool, crease: ClosedRange<CGFloat>?) -> CGRect {
        var lo = bounds.minX + sideMargin, hi = bounds.maxX - sideMargin
        if let crease, crease.upperBound > lo, crease.lowerBound < hi {
            let left = crease.lowerBound - KeyBarPlacement.creaseClearance - lo
            let right = hi - (crease.upperBound + KeyBarPlacement.creaseClearance)
            if left >= right {
                hi = crease.lowerBound - KeyBarPlacement.creaseClearance
            } else {
                lo = crease.upperBound + KeyBarPlacement.creaseClearance
            }
        }
        let y: CGFloat
        switch edge {
        case .bottom:
            y = bounds.maxY - max(sideMargin, safeBottom + 4) - barHeight
        case .top:
            var top = bounds.minY + safeTop + sideMargin
            if chipShown { top = max(top, bounds.minY + chipBottom + 6) }
            y = top
        }
        return CGRect(x: lo, y: y, width: max(0, hi - lo), height: barHeight)
    }

    /// Points of the terminal the bottom bar covers: from its top to the pane's bottom. Zero for
    /// the top bar. In mirror mode the grid is scaled by `zoom`, and a grid that ends above the
    /// bar is covered by nothing.
    static func findInset(bar: CGRect, edge: Edge, paneHeight: CGFloat, alternateScreen: Bool,
                          zoom: CGFloat = 1, gridBottom: CGFloat? = nil) -> CGFloat {
        guard edge == .bottom, !alternateScreen else { return 0 }
        if let gridBottom, gridBottom <= bar.minY { return 0 }
        let inset = max(0, paneHeight - bar.minY)
        return inset / max(zoom, 0.01)
    }

    /// The jump-to-bottom button's center y with the bottom bar up: above the bar.
    static func jumpCenterY(bar: CGRect, radius: CGFloat) -> CGFloat {
        bar.minY - 8 - radius
    }
}
