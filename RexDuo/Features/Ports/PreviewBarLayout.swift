import CoreGraphics

/// Where back, forward and reload go in the browser, in its view's coordinates: where a
/// navigation controller's toolbar puts three such items. The system gives no metrics for
/// that, so these are its toolbar's own places, measured on iOS 27.2 on each shape: an iPhone
/// upright and on its side, with and without a home indicator, a sheet that floats (iPad), and
/// the iPhone Duo, whose toolbars stand in the vertical bar. Pure, so it is tested.
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
        let second = rightToLeft ? first - step : first + step
        let last = rightToLeft ? inset : size.width - inset
        return PreviewBarLayout(room: room, strip: CGRect(x: 0, y: size.height - room, width: size.width, height: room),
                                back: square(first, y, button), forward: square(second, y, button), reload: square(last, y, button))
    }
}
