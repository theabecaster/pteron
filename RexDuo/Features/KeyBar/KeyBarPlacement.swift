import UIKit

/// Where the key bar puts its hide key, and how it keeps keys off the fold. Pure, so it is tested.
enum KeyBarPlacement {
    /// The hide key's place.
    enum HideKey: Equatable {
        /// At the bar's trailing end, after the keys' capsule: no vertical bar beside the keyboard.
        case inBar
        /// In the column the system's vertical bar leaves beside the keyboard, so the keys get the
        /// bar's full width. `column` is the touch target, the whole inset; `midX` is the key's center,
        /// in line with the vertical bar's own items. Both in the key bar's coordinates.
        case strip(column: CGRect, midX: CGFloat)
    }

    /// The narrowest column that holds a full-size touch target.
    static let minStripWidth: CGFloat = 44
    /// The vertical bar centers its items in its inset less this margin at the screen's edge
    /// (iPhone Duo simulator, iOS 27.2: 84 pt inset, items centered 48 pt from the edge).
    static let stripEdgeMargin: CGFloat = 12

    /// The hide key goes into the vertical bar's column where the system has a vertical bar on that
    /// side and the bar's safe-area inset there is wide enough to tap. Elsewhere (a regular iPhone,
    /// bars along the top) it stays in the bar.
    /// - Parameters:
    ///   - barEdge: the system's vertical bar edge, nil where bars are horizontal.
    ///   - width, height: the key bar's size.
    ///   - leftInset, rightInset: the key bar's safe-area insets.
    static func hideKey(barEdge: NSDirectionalRectEdge?, rightToLeft: Bool, width: CGFloat, height: CGFloat,
                        leftInset: CGFloat, rightInset: CGFloat) -> HideKey {
        guard let barEdge else { return .inBar }
        let onRight = (barEdge == .trailing) != rightToLeft
        let inset = onRight ? rightInset : leftInset
        guard inset >= minStripWidth + stripEdgeMargin, inset < width / 2 else { return .inBar }
        let center = (inset - stripEdgeMargin) / 2
        return onRight
            ? .strip(column: CGRect(x: width - inset, y: 0, width: inset, height: height), midX: width - inset + center)
            : .strip(column: CGRect(x: 0, y: 0, width: inset, height: height), midX: inset - center)
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
