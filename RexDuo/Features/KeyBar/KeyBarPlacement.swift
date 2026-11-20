import UIKit

/// Where the key bar puts its hide key, and how it keeps keys out of the system's vertical bar and
/// off the fold. Pure, so it is tested.
enum KeyBarPlacement {
    /// The hide key's place.
    enum HideKey: Equatable {
        /// At the bar's trailing end, after the keys' capsule: no vertical bar beside the keyboard.
        case inBar
        /// In the system's vertical bar, as its Hide Keyboard item (`HideKeyboardItem`): the key bar
        /// draws none, and nothing of it reaches into the bar's column.
        case verticalBar
    }

    /// The hide key goes into the vertical bar where the app's window has the bar's column
    /// (`VerticalBarObserver`). Elsewhere (a regular iPhone, bars along the top, a column the
    /// window doesn't report) it stays in the key bar, as it always was.
    static func hideKey(column: CGRect?) -> HideKey { column == nil ? .inBar : .verticalBar }

    /// The vertical bar's column in a window: the window's safe-area inset on the bar's edge, as
    /// tall as the window. Nil where there is no bar, or the window reports no inset there.
    /// - Parameters:
    ///   - edge: the system's vertical bar edge (`.leading` or `.trailing`), nil where bars are
    ///     horizontal. Mirrored under a right-to-left layout.
    ///   - bounds, insets: the window's bounds and safe-area insets.
    static func column(edge: NSDirectionalRectEdge?, rightToLeft: Bool, bounds: CGRect, insets: UIEdgeInsets) -> CGRect? {
        guard let edge else { return nil }
        let onRight = (edge == .trailing) != rightToLeft
        let inset = onRight ? insets.right : insets.left
        guard inset > 0, inset < bounds.width / 2 else { return nil }
        return onRight
            ? CGRect(x: bounds.maxX - inset, y: bounds.minY, width: inset, height: bounds.height)
            : CGRect(x: bounds.minX, y: bounds.minY, width: inset, height: bounds.height)
    }

    /// The part of a bar `width` wide that is outside the vertical bar's column: all of it without
    /// one. Nothing of the bar that takes touches reaches past it.
    /// - Parameter column: the vertical bar's column in the bar's coordinates, nil without one.
    static func reach(width: CGFloat, column: CGRect?) -> ClosedRange<CGFloat> {
        // A column off the bar (a stale frame during a rotation) bounds nothing.
        guard let column, column.maxX > 0, column.minX < width, width > 0 else { return 0...max(0, width) }
        return column.midX >= width / 2 ? 0...max(0, column.minX) : min(column.maxX, width)...width
    }

    /// Where the keys' capsule, and the hide key when it is in the bar, may go: `sideInset` inside
    /// the bar's safe-area insets, and with the vertical bar's column beside the keyboard,
    /// `sideInset` short of the column, as of a screen edge.
    /// - Parameters:
    ///   - width: the bar's width.
    ///   - leftInset, rightInset: its safe-area insets.
    ///   - column: the vertical bar's column in the bar's coordinates, nil without one.
    static func span(width: CGFloat, leftInset: CGFloat, rightInset: CGFloat, sideInset: CGFloat,
                     column: CGRect?) -> ClosedRange<CGFloat> {
        let open = reach(width: width, column: column)
        let lo = max(leftInset, open.lowerBound) + sideInset
        let hi = min(width - rightInset, open.upperBound) - sideInset
        return lo...max(lo, hi)
    }

    /// How far keys stay from the crease, as the offline screen's pages do.
    static let creaseClearance: CGFloat = 12

    /// The space to add before one key so that, with the bar scrolled to its start, no key sits on a
    /// vertical crease. Nil when no key touches it.
    /// - Parameters:
    ///   - widths: the keys' widths, in order.
    ///   - start: the first key's x; `spacing` is the space between keys.
    ///   - crease: the crease's span, in the same coordinates.
    static func creaseGap(widths: [CGFloat], start: CGFloat, spacing: CGFloat,
                          crease: ClosedRange<CGFloat>) -> (index: Int, extra: CGFloat)? {
        let lo = crease.lowerBound - creaseClearance, hi = crease.upperBound + creaseClearance
        var x = start
        for (i, w) in widths.enumerated() {
            if x >= hi { return nil }
            if x + w > lo { return (i, hi - x) }
            x += w + spacing
        }
        return nil
    }
}
