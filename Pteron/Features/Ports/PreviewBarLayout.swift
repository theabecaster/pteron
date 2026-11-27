import CoreGraphics

/// Where back, forward and reload go in the browser, in its view's coordinates: where a
/// navigation controller's toolbar puts three such items; and where Done, the title and the
/// menu go (`top`): where its navigation bar puts them. The system gives no metrics for
/// that, so these are rules read off its toolbar on iOS 27.2. They are keyed on what the view
/// can read and nothing else: its size, its vertical size class, whether its sheet reaches the
/// window's bottom edge, the layout direction, and the system's vertical bar. Never the
/// device, its orientation or the idiom, so a size nobody measured (Split View, another
/// iPhone) gets the rule of the case it is. Pure, so it is tested.
struct PreviewBarLayout: Equatable {
    /// The side of the view the system's vertical bar is on.
    enum Side: Equatable {
        case left, right
    }

    /// How far above the view's bottom edge the page ends. The view's own bottom inset counts
    /// in it: a home indicator adds nothing. Zero beside a vertical bar, which takes no room
    /// from the page's height.
    var room: CGFloat
    /// The strip under the page that the buttons stand on. A vertical bar has none: the system
    /// draws no background there.
    var strip: CGRect?
    var back: CGRect
    var forward: CGRect
    var reload: CGRect

    /// - Parameters:
    ///   - size: the browser's view.
    ///   - verticalBar: where the system's vertical bar is, if it has one here.
    ///   - compactHeight: the vertical size class is compact (an iPhone on its side).
    ///   - floats: the sheet ends above the window's bottom edge (a form sheet on an iPad).
    ///   - rightToLeft: back is then on the right, as in a toolbar.
    static func make(size: CGSize, verticalBar: Side?, compactHeight: Bool, floats: Bool, rightToLeft: Bool) -> PreviewBarLayout {
        func square(_ x: CGFloat, _ y: CGFloat, _ side: CGFloat) -> CGRect {
            CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)
        }
        if let verticalBar {
            // In the bar's column, from the bottom up: reload, forward, back.
            let x = verticalBar == .right ? size.width - 40 : 40
            return PreviewBarLayout(room: 0, strip: nil, back: square(x, size.height - 196, 48),
                                    forward: square(x, size.height - 108, 48), reload: square(x, size.height - 48, 48))
        }
        // The buttons' size, their centres' distance from the bottom and the sides, and from
        // back to forward.
        let room: CGFloat, button: CGFloat, up: CGFloat, inset: CGFloat, step: CGFloat
        if floats {
            (room, button, up, inset, step) = (64, 44, 32, 32, 84)
        } else if compactHeight {
            (room, button, up, inset, step) = (78, 44, 46, 60, 84)
        } else {
            (room, button, up, inset, step) = (86, 48, 52, 52, 88)
        }
        let y = size.height - up
        let first = rightToLeft ? size.width - inset : inset
        let last = rightToLeft ? inset : size.width - inset
        // Forward keeps a toolbar's distance from back, and in a view too narrow for that
        // stays clear of reload.
        let reach = max(0, min(step, abs(last - first) - button - 8))
        let second = rightToLeft ? first - reach : first + reach
        return PreviewBarLayout(room: room, strip: CGRect(x: 0, y: size.height - room, width: size.width, height: room),
                                back: square(first, y, button), forward: square(second, y, button), reload: square(last, y, button))
    }

    /// Done, the title and the menu, where an opaque navigation bar puts them in a sheet.
    struct Top: Equatable {
        /// How far under the view's top inset the bar reaches; the page starts there. A sheet's
        /// navigation bar starts a little below the sheet's top edge (16 pt; 24 on an iPhone on
        /// its side, 10 in a sheet that floats), and its background reaches up to the edge.
        var height: CGFloat
        var done: CGRect
        var more: CGRect
        /// Where the title's centre goes, and the room it may take.
        var titleCentre: CGPoint
        var title: CGRect
    }

    /// - Parameters:
    ///   - size: the browser's view.
    ///   - inset: the view's own top inset (none in a sheet), which the bar starts under.
    ///   - verticalBar: where the system's vertical bar is, if it has one here. Done and the
    ///     menu are then in it, from the top down, and the strip holds the title alone.
    ///   - compactHeight, floats, rightToLeft: as for `make`. Done is on the leading side.
    static func top(size: CGSize, inset: CGFloat, verticalBar: Side?, compactHeight: Bool, floats: Bool,
                    rightToLeft: Bool) -> Top {
        func square(_ x: CGFloat, _ y: CGFloat, _ side: CGFloat) -> CGRect {
            CGRect(x: x - side / 2, y: y - side / 2, width: side, height: side)
        }
        let lead: CGFloat = verticalBar != nil ? 16 : floats ? 10 : compactHeight ? 24 : 16
        let top = inset + lead
        if let verticalBar {
            // The column of the bottom bar's buttons (`make`), and the strip's width beside it.
            let x = verticalBar == .right ? size.width - 40 : 40
            let column: CGFloat = 60
            let left = verticalBar == .left ? column : 0
            let right = verticalBar == .right ? size.width - column : size.width
            // From the top down, under the strip on its side, and under the status the
            // system's bar shows at its top when upright.
            let y: CGFloat = compactHeight ? 98 : 190
            return Top(height: lead + 58, done: square(x, y, 48), more: square(x, y + 60, 48),
                       titleCentre: CGPoint(x: (left + right) / 2, y: top + 24),
                       title: CGRect(x: left + 16, y: top, width: max(0, right - left - 32), height: 58))
        }
        // The buttons' distance from the sides.
        let side: CGFloat = floats ? 10 : compactHeight ? 38 : 16
        let button: CGFloat = 44, y = top + 22
        let leading = square(side + button / 2, y, button)
        let trailing = square(size.width - side - button / 2, y, button)
        let room = CGRect(x: leading.maxX + 8, y: top, width: max(0, trailing.minX - leading.maxX - 16), height: 54)
        return Top(height: lead + 54, done: rightToLeft ? trailing : leading, more: rightToLeft ? leading : trailing,
                   titleCentre: CGPoint(x: size.width / 2, y: y), title: room)
    }
}
