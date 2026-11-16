import CoreGraphics

/// Where a split's divider sits on the canvas and how a drag changes its ratio.
/// `rect` is the split's normalized rect from Rex's layout; `canvas` is the size it is drawn at.
struct SplitGeometry {
    /// Within this distance of 50% (as a ratio), a drag snaps to an even split.
    static let detentWidth = 0.025
    /// Rex's limits for `session.resize_pane`.
    static let ratioRange = 0.05...0.95

    let rect: CGRect
    let ratio: Double
    /// Rex's "horizontal" split puts panes side by side, with a vertical divider.
    let sideBySide: Bool
    let canvas: CGSize

    init(rect: CGRect, ratio: Double, direction: String, canvas: CGSize) {
        self.rect = rect
        self.ratio = ratio
        self.sideBySide = direction != "vertical"
        self.canvas = canvas
    }

    /// The divider's start point in canvas points.
    var origin: CGPoint {
        CGPoint(x: (rect.minX + (sideBySide ? rect.width * ratio : 0)) * canvas.width,
                y: (rect.minY + (sideBySide ? 0 : rect.height * ratio)) * canvas.height)
    }

    /// The divider's length in points.
    var length: CGFloat { sideBySide ? rect.height * canvas.height : rect.width * canvas.width }

    /// The split's extent along the drag axis, in points.
    var span: CGFloat { max(sideBySide ? rect.width * canvas.width : rect.height * canvas.height, 1) }

    /// The drag offset to show for a raw translation, and whether it sits in the 50% detent.
    func detent(_ translation: CGFloat) -> (offset: CGFloat, snapped: Bool) {
        let snapped = abs(ratio + translation / span - 0.5) < Self.detentWidth
        return (snapped ? (0.5 - ratio) * span : translation, snapped)
    }

    /// The ratio after dragging the divider by `offset` points, within Rex's limits.
    func ratio(after offset: CGFloat) -> Double {
        min(max(ratio + offset / span, Self.ratioRange.lowerBound), Self.ratioRange.upperBound)
    }
}
