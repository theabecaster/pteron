import CoreGraphics

/// How far the launch hole must grow to clear the screen.
///
/// The hole is the launch art's silhouette, scaled about a pivot inside it. It has cleared the
/// screen once, in every direction from the pivot, the scaled silhouette reaches the screen's
/// edge. `extent` says how far the silhouette reaches in each direction, so the answer is the
/// largest ratio of the two, a little over a thousand operations, once a launch.
enum LaunchClearing {
    /// Past the exact fit, so the soft, scaled-up edge is off screen too.
    static let margin: CGFloat = 1.06

    /// The hole's final scale. `pivot` is in `bounds`' coordinates; `extent[i]` is the silhouette's
    /// reach from the pivot along the angle `2π i / extent.count` (x toward y), in the same units.
    static func scale(pivot: CGPoint, in bounds: CGRect, extent: [CGFloat]) -> CGFloat {
        var most: CGFloat = 1
        for (i, reach) in extent.enumerated() where reach > 0 {
            let angle = 2 * CGFloat.pi * CGFloat(i) / CGFloat(extent.count)
            most = max(most, edgeDistance(from: pivot, in: bounds, dx: cos(angle), dy: sin(angle)) / reach)
        }
        return most * margin
    }

    /// From a point inside `bounds` to its edge along a direction.
    static func edgeDistance(from p: CGPoint, in bounds: CGRect, dx: CGFloat, dy: CGFloat) -> CGFloat {
        let tx = dx > 0 ? (bounds.maxX - p.x) / dx : dx < 0 ? (bounds.minX - p.x) / dx : .infinity
        let ty = dy > 0 ? (bounds.maxY - p.y) / dy : dy < 0 ? (bounds.minY - p.y) / dy : .infinity
        return max(min(tx, ty), 0)
    }
}
