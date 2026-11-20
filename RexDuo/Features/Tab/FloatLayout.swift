import CoreGraphics
import RexKit

/// Where a tab's floating windows are drawn: each floating layer where Rex places it, grown until
/// every pane in it keeps a legible grid, kept inside the panes' area and off a vertical crease.
///
/// Pure. Rects are fractions of the area the splits are drawn in (the canvas inset by
/// `PaneLayout.splitPadding`), the same space as Rex's window fractions, so a float that needs no
/// change is drawn exactly at the Mac's rect.
enum FloatLayout {
    struct Leaf: Equatable {
        var id: String
        var rect: CGRect
    }

    /// One floating window: its layer, the rect it is drawn at, and its panes inside that rect.
    struct Frame: Equatable, Identifiable {
        var id: String
        var rect: CGRect
        var leaves: [Leaf]
    }

    /// A vertical crease's edges, as fractions of the area's width.
    struct Crease: Equatable {
        var lead: CGFloat
        var trail: CGFloat
    }

    private static let epsilon: CGFloat = 1e-6

    /// The crease in the area's fractions, for a crease frame and an area that start in the same
    /// coordinates. Nil when there is no crease or it doesn't cross the area (the sidebar fills
    /// the left page). Edges are whole points rounded outward, as book mode rounds them.
    static func crease(_ crease: CGRect?, areaMinX: CGFloat, areaWidth: CGFloat) -> Crease? {
        guard let crease, areaWidth > 0 else { return nil }
        let c0 = (crease.minX - areaMinX).rounded(.down), c1 = (crease.maxX - areaMinX).rounded(.up)
        guard c0 > 0, c1 < areaWidth else { return nil }
        return Crease(lead: c0 / areaWidth, trail: c1 / areaWidth)
    }

    /// The smallest pane, as fractions of the canvas, that keeps `SplitGeometry`'s legible grid
    /// (40 × 8 cells). Nil for a canvas not measured yet.
    static func minimumPane(canvas: CGSize, fontSize: Double) -> CGSize? {
        guard canvas.width > 0, canvas.height > 0 else { return nil }
        let cellW = CGFloat(fontSize) * 0.6, cellH = CGFloat(fontSize) * 1.25
        return CGSize(width: CGFloat(SplitGeometry.legibleCols) * cellW / canvas.width,
                      height: CGFloat(SplitGeometry.legibleRows) * cellH / canvas.height)
    }

    /// One floating layer, placed. The layer grows as one unit around its center, each side only
    /// as far as its narrowest (or shortest) pane needs, then is kept inside the area. Across a
    /// crease it moves onto the page that holds its center, narrowed to that page if it must be.
    /// Nil when no size inside the area keeps every pane legible, or the layer has no place.
    static func place(_ layer: LayerInfo, canvas: CGSize, fontSize: Double, crease: Crease?) -> Frame? {
        guard layer.hasBounds, let leaves = layer.layout?.leaves, !leaves.isEmpty,
              let least = minimumPane(canvas: canvas, fontSize: fontSize) else { return nil }
        let b = layer.bounds
        // Each pane's share of its layer, which growing keeps.
        let shares = leaves.map { l in
            CGRect(x: (l.rect.minX - b.minX) / b.width, y: (l.rect.minY - b.minY) / b.height,
                   width: l.rect.width / b.width, height: l.rect.height / b.height)
        }
        guard shares.allSatisfy({ $0.width > 0 && $0.height > 0 }) else { return nil }
        let needW = max(b.width, shares.map { least.width / $0.width }.max() ?? 0)
        let needH = max(b.height, shares.map { least.height / $0.height }.max() ?? 0)
        guard needW <= 1 + epsilon, needH <= 1 + epsilon else { return nil }
        var w = min(needW, 1)
        let h = min(needH, 1)
        var x = clamp(b.midX - w / 2, 0, 1 - w)
        let y = clamp(b.midY - h / 2, 0, 1 - h)
        if let c = crease {
            let left = x + w / 2 < (c.lead + c.trail) / 2
            let lo = left ? 0 : c.trail, hi = left ? c.lead : 1
            if x < lo - epsilon || x + w > hi + epsilon {
                w = min(w, hi - lo)
                x = clamp(x, lo, hi - w)
                guard shares.allSatisfy({ $0.width * w >= least.width - epsilon }) else { return nil }
            }
        }
        let rect = CGRect(x: x, y: y, width: w, height: h)
        return Frame(id: layer.id, rect: rect, leaves: zip(leaves, shares).map { l, s in
            Leaf(id: l.id, rect: CGRect(x: rect.minX + s.minX * rect.width, y: rect.minY + s.minY * rect.height,
                                        width: s.width * rect.width, height: s.height * rect.height))
        })
    }

    /// Back to front: the server's order, with `front` (a layer raised on the phone that the
    /// server hasn't shown on top yet) moved to the front.
    static func ordered(_ layers: [LayerInfo], front: String?) -> [LayerInfo] {
        guard let front, let i = layers.firstIndex(where: { $0.id == front }), i != layers.count - 1 else { return layers }
        var out = layers
        out.append(out.remove(at: i))
        return out
    }

    private static func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(max(v, lo), max(lo, hi)) }
}

/// What a tap (or a long press, a two-finger tap, a pointer drag) on a floating pane sends. A
/// float behind another is raised; one in front only takes focus; one in front and focused sends
/// nothing, so repeated taps cost nothing.
enum FloatTap: Equatable {
    case none
    /// `session.focus_block`, as a tiled pane's tap.
    case focus
    /// `session.set_layer_state` with `focus`, which raises the layer and focuses the pane last
    /// focused in it; `focusBlock` follows it with `focus_block` when the layer holds several.
    case raise(focusBlock: Bool)

    /// - front: the front drawn float, with a raise the phone made counted.
    /// - canRaise: the server takes `set_layer_state`. Without it a float focuses as a tiled pane.
    static func decide(window w: WindowInfo, block: String, front: String?, canRaise: Bool) -> FloatTap {
        if canRaise, let layer = w.floatingLayer(of: block), layer.id != front {
            return .raise(focusBlock: layer.blocks.count > 1)
        }
        return block == w.focusedBlockID ? .none : .focus
    }
}
