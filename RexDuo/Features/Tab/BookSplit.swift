import CoreGraphics

/// Book mode: on a partly folded Duo with a vertical crease, the tab's side-by-side divider nearest
/// the crease is drawn on the crease, so each page holds whole panes and no text sits in the fold.
///
/// Display only. The panes on one side of that divider keep their proportions and fill the left
/// page; the others fill the right page. Rex's ratios are not changed, so the Mac's layout stays as
/// it is. All rects are normalized (0...1) in the splits' area, like Rex's layout rects.
struct BookSplit: Equatable {
    typealias Split = (id: String, direction: String, ratio: Double, rect: CGRect, beforeFirst: String, afterFirst: String)

    /// The aligned divider's x in Rex's layout.
    let divider: CGFloat
    /// The crease's edges in the splits' area: whole points, rounded outward.
    let lead: CGFloat
    let trail: CGFloat
    /// The panes on each side of the aligned divider (the split's `beforeFirst` and `afterFirst`).
    let before: String
    let after: String

    private static let epsilon: CGFloat = 1e-4

    /// Book mode for a layout drawn in an area `areaWidth` wide that starts at `areaMinX`, with the
    /// crease's frame in the same coordinates. Nil leaves the layout as Rex has it: no crease, a
    /// crease at or past the area's edge (the sidebar fills the left page), no side-by-side divider
    /// that runs the area's full height, or a pane that would not keep a legible grid.
    static func decide(leaves: [CGRect], splits: [Split], areaWidth: CGFloat, areaMinX: CGFloat,
                       crease: CGRect?, canvas: CGSize, fontSize: Double) -> BookSplit? {
        guard let crease, areaWidth > 0 else { return nil }
        let c0 = (crease.minX - areaMinX).rounded(.down), c1 = (crease.maxX - areaMinX).rounded(.up)
        guard c0 > 0, c1 < areaWidth else { return nil }
        let mid = crease.midX - areaMinX
        // A side-by-side split as tall as the area is reached from the root through side-by-side
        // splits only, so no pane lies across its divider.
        var best: (split: Split, x: CGFloat, distance: CGFloat)?
        for s in splits where s.direction != "vertical" && s.rect.minY <= epsilon && s.rect.height >= 1 - epsilon {
            let x = dividerX(s)
            let distance = abs(x * areaWidth - mid)
            guard let b = best else { best = (s, x, distance); continue }
            // The nearest to the crease's middle; of two equally near, the left one.
            if distance < b.distance - 1e-6 || (abs(distance - b.distance) <= 1e-6 && x < b.x) { best = (s, x, distance) }
        }
        guard let best, best.x > epsilon, best.x < 1 - epsilon else { return nil }
        let book = BookSplit(divider: best.x, lead: c0 / areaWidth, trail: c1 / areaWidth,
                             before: best.split.beforeFirst, after: best.split.afterFirst)
        guard SplitGeometry.legible(leaves.map(book.rect), canvas: canvas, fontSize: fontSize) else { return nil }
        return book
    }

    /// Whether a tab would be in book mode with the inline sidebar collapsed, when its panes'
    /// canvas is `canvas` and starts at the root's leading edge: its splits would show there
    /// (every pane legible as Rex lays them out), and book mode would take them.
    static func fitsCollapsed(leaves: [CGRect], splits: [Split], canvas: CGSize, crease: CGRect?, fontSize: Double) -> Bool {
        guard SplitGeometry.legible(leaves, canvas: canvas, fontSize: fontSize) else { return false }
        return decide(leaves: leaves, splits: splits, areaWidth: canvas.width - PaneLayout.splitPadding * 2,
                      areaMinX: PaneLayout.splitPadding, crease: crease, canvas: canvas, fontSize: fontSize) != nil
    }

    /// Where a pane, or a split on one side of the aligned divider, is drawn.
    func rect(_ r: CGRect) -> CGRect {
        let left = r.maxX <= divider + Self.epsilon
        let x0 = left ? leftX(r.minX) : rightX(r.minX), x1 = left ? leftX(r.maxX) : rightX(r.maxX)
        return CGRect(x: x0, y: r.minY, width: x1 - x0, height: r.height)
    }

    /// The split whose divider sits on the crease.
    func isAligned(_ s: Split) -> Bool {
        s.direction != "vertical" && s.beforeFirst == before && s.afterFirst == after
            && abs(Self.dividerX(s) - divider) <= Self.epsilon
    }

    /// The split as its drag handle sees it: the rect the divider moves in on screen, and the
    /// divider's place in it. Nil for the aligned split: its divider stays on the crease whatever
    /// its ratio, so there is nothing to drag, and nothing tappable sits in the crease.
    ///
    /// A split on one side of the aligned divider keeps its ratio. A split that holds the aligned
    /// one (`H(a, H(b, c))` with `b|c` on the crease) shows on one page only the part up to the
    /// crease, so its handle gets that part and the divider's share of it.
    func handle(_ s: Split) -> Split? {
        guard !isAligned(s) else { return nil }
        var h = s
        switch holds(s) {
        case .none:
            h.rect = rect(s.rect)
        case .after:
            let x0 = leftX(s.rect.minX)
            h.rect = CGRect(x: x0, y: s.rect.minY, width: lead - x0, height: s.rect.height)
            h.ratio = Double((Self.dividerX(s) - s.rect.minX) / (divider - s.rect.minX))
        case .before:
            h.rect = CGRect(x: trail, y: s.rect.minY, width: rightX(s.rect.maxX) - trail, height: s.rect.height)
            h.ratio = Double((Self.dividerX(s) - divider) / (s.rect.maxX - divider))
        }
        return h
    }

    /// Rex's ratio for split `s` when its handle (`handle(s)`) was dragged to `shown`. The same
    /// number except for a split that holds the aligned one: there the ratio is the one that puts
    /// the divider where the drag ended, with the aligned divider still on the crease.
    func ratio(_ s: Split, shown: Double) -> Double {
        let q = CGFloat(shown), x = Self.dividerX(s)
        let r: CGFloat
        switch holds(s) {
        case .none:
            return shown
        case .after:
            // The aligned divider sits at a fixed share `t` of this split's second side.
            let t = (divider - x) / (s.rect.maxX - x)
            r = q * t / (1 - q + q * t)
        case .before:
            // It sits at a fixed share `t` of the first side.
            let t = (divider - s.rect.minX) / (x - s.rect.minX)
            r = q / (1 - t + q * t)
        }
        return min(max(Double(r), SplitGeometry.ratioRange.lowerBound), SplitGeometry.ratioRange.upperBound)
    }

    private enum Side { case before, after }

    /// Which side of split `s` holds the aligned split, if `s` lies across the aligned divider.
    private func holds(_ s: Split) -> Side? {
        guard s.direction != "vertical", s.rect.minX < divider - Self.epsilon, s.rect.maxX > divider + Self.epsilon else { return nil }
        return Self.dividerX(s) < divider ? .after : .before
    }

    private static func dividerX(_ s: Split) -> CGFloat { s.rect.minX + s.rect.width * CGFloat(s.ratio) }
    private func leftX(_ x: CGFloat) -> CGFloat { x * lead / divider }
    private func rightX(_ x: CGFloat) -> CGFloat { trail + (x - divider) * (1 - trail) / (1 - divider) }
}

/// The crease book mode lays out against. A hand holding the phone near the angle where the fold
/// turns active flips it back and forth, and every flip would resize each pane on the Mac. So a
/// crease counts once it has held for `delay`, and stays that long after the fold goes flat.
///
/// Two cases don't wait. The first layout uses the crease as it is, so a launch in book mode claims
/// each pane's size once. And a crease that is gone or has moved (fully folded, rotated, another
/// window size) is dropped at once: nothing is laid out against a crease that isn't there.
struct CreaseSettle: Equatable {
    static let delay: UInt64 = 400_000_000

    /// The crease last held for `delay`. `.none` before the first one.
    private var settled: CGRect??

    /// False until the first `settle`.
    var started: Bool { settled != nil }

    /// The fold as book mode wants it now: an active vertical crease's frame.
    static func live(_ division: Division?) -> CGRect? {
        guard let d = division, d.isVertical, d.isActive else { return nil }
        return d.frame
    }

    /// The crease to lay out against.
    func crease(_ division: Division?) -> CGRect? {
        guard let d = division, d.isVertical else { return nil }
        guard let settled else { return Self.live(d) }
        guard let settled, abs(settled.midX - d.frame.midX) <= 1 else { return nil }
        return settled
    }

    /// The fold is bent into book mode but hasn't held still yet, so the settle that is due
    /// decides, not a change of window width or tab on the way.
    func pending(_ division: Division?) -> Bool { Self.live(division) != nil && crease(division) == nil }

    /// The fold has held as it is for `delay` (or this is the first layout).
    mutating func settle(_ division: Division?) { settled = .some(Self.live(division)) }
}

/// Book mode and the inline sidebar. Beside the sidebar the left page has no room for a pane, so
/// when the phone settles into book mode and the tab on screen has a split that would fit the two
/// pages, the sidebar collapses; when book mode ends it comes back. It is the phone making room,
/// not the user's choice, so it is never stored, and it stands back as soon as the user shows or
/// hides the sidebar themselves.
struct BookSidebar: Equatable {
    enum Action: Equatable { case collapse, reopen }

    /// How long a reopened sidebar slides over the tab before the tab makes room for it
    /// (`SidebarSplit`). Book mode ends then, so the panes change size once.
    static let slideTime: UInt64 = 260_000_000

    private var inBook = false
    /// Book mode began and the tab on screen isn't measured yet (a launch): it decides once it is.
    private var deciding = false
    /// Book mode collapsed the sidebar, and the user hasn't shown or hidden it since.
    private(set) var collapsedIt = false
    /// What `open` becomes through our own action, so that change isn't taken for the user's.
    private var expecting: Bool?

    /// Call when book mode begins or ends, when the tab's answer changes, and when the window
    /// turns wide or narrow.
    /// - book: the phone has settled into book mode.
    /// - fits: the tab on screen has a split that would fit the two pages with the sidebar
    ///   collapsed; nil while no tab is measured.
    /// - open: the sidebar shows.
    /// - inline: the window is wide, so the sidebar sits beside the tab. A drawer is left alone.
    mutating func update(book: Bool, fits: Bool?, open: Bool, inline: Bool) -> Action? {
        guard book else {
            inBook = false
            deciding = false
            // Narrow (folded shut): the sidebar would come back as a drawer over the tab. It
            // waits for a wide window.
            guard collapsedIt, inline else { return nil }
            collapsedIt = false
            guard !open else { return nil }
            expecting = true
            return .reopen
        }
        // Only on the way into book mode: another tab, or a split made later, collapses nothing.
        if !inBook {
            inBook = true
            deciding = true
        }
        guard deciding, let fits else { return nil }
        deciding = false
        guard fits, open, inline else { return nil }
        collapsedIt = true
        expecting = false
        return .collapse
    }

    /// The sidebar showed or hid. Unless book mode did it, the user did, and the sidebar is theirs
    /// again: nothing reopens it, and nothing collapses it until book mode begins anew.
    mutating func sidebarChanged(open: Bool) {
        if expecting != open { collapsedIt = false }
        expecting = nil
    }
}
