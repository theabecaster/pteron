import CoreGraphics
import Testing
@testable import RexDuo

/// Layouts as Rex sends them: every node with its normalized rect.
private indirect enum Node {
    case pane(String)
    case row(Node, Node, Double)     // side by side ("horizontal")
    case column(Node, Node, Double)  // stacked ("vertical")

    var first: String {
        switch self {
        case .pane(let id): id
        case .row(let a, _, _), .column(let a, _, _): a.first
        }
    }

    var last: String {
        switch self {
        case .pane(let id): id
        case .row(_, let b, _), .column(_, let b, _): b.last
        }
    }

    func leaves(_ r: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [(id: String, rect: CGRect)] {
        switch self {
        case .pane(let id): return [(id, r)]
        case .row(let a, let b, let ratio):
            let w = r.width * ratio
            return a.leaves(CGRect(x: r.minX, y: r.minY, width: w, height: r.height))
                + b.leaves(CGRect(x: r.minX + w, y: r.minY, width: r.width - w, height: r.height))
        case .column(let a, let b, let ratio):
            let h = r.height * ratio
            return a.leaves(CGRect(x: r.minX, y: r.minY, width: r.width, height: h))
                + b.leaves(CGRect(x: r.minX, y: r.minY + h, width: r.width, height: r.height - h))
        }
    }

    func splits(_ r: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [BookSplit.Split] {
        switch self {
        case .pane: return []
        case .row(let a, let b, let ratio):
            let w = r.width * ratio
            return [(id: "", direction: "horizontal", ratio: ratio, rect: r, beforeFirst: a.last, afterFirst: b.first)]
                + a.splits(CGRect(x: r.minX, y: r.minY, width: w, height: r.height))
                + b.splits(CGRect(x: r.minX + w, y: r.minY, width: r.width - w, height: r.height))
        case .column(let a, let b, let ratio):
            let h = r.height * ratio
            return [(id: "", direction: "vertical", ratio: ratio, rect: r, beforeFirst: a.last, afterFirst: b.first)]
                + a.splits(CGRect(x: r.minX, y: r.minY, width: r.width, height: h))
                + b.splits(CGRect(x: r.minX, y: r.minY + h, width: r.width, height: r.height - h))
        }
    }
}

struct BookSplitTests {
    // The inner screen in landscape, sidebar collapsed: a 951 pt window with an 84 pt vertical bar,
    // the splits' area 3 pt inside the canvas, and `-simulateDuo book`'s 40 pt crease from 455.5
    // to 495.5.
    let canvas = CGSize(width: 867, height: 600)
    let area = CGSize(width: 861, height: 594)
    let areaMinX: CGFloat = 3
    let crease = CGRect(x: 455.5, y: 0, width: 40, height: 669)

    private func decide(_ n: Node, crease: CGRect?, width: CGFloat? = nil, minX: CGFloat? = nil, fontSize: Double = 11) -> BookSplit? {
        BookSplit.decide(leaves: n.leaves().map(\.rect), splits: n.splits(), areaWidth: width ?? area.width,
                         areaMinX: minX ?? areaMinX, crease: crease,
                         canvas: CGSize(width: (width ?? area.width) + 6, height: canvas.height), fontSize: fontSize)
    }

    private func decide(_ n: Node) -> BookSplit? { decide(n, crease: crease) }

    /// The panes' frames in the root's coordinates, as the canvas draws them.
    private func frames(_ n: Node, _ book: BookSplit) -> [String: CGRect] {
        Dictionary(uniqueKeysWithValues: n.leaves().map {
            ($0.id, PaneLayout.split(book.rect($0.rect), in: area).offsetBy(dx: areaMinX, dy: 0))
        })
    }

    @Test func theDividerLandsOnTheCrease() throws {
        for ratio in [0.5, 0.3, 0.62] {
            let n = Node.row(.pane("a"), .pane("b"), ratio)
            let book = try #require(decide(n))
            // The crease's edges, whole points outward, in the area: 452 and 493.
            #expect(abs(book.rect(n.leaves()[0].rect).maxX * area.width - 452) < 1e-9)
            #expect(abs(book.rect(n.leaves()[1].rect).minX * area.width - 493) < 1e-9)
            let f = frames(n, book)
            // Each pane keeps today's 3 pt inset, so it ends 3 pt or more outside the crease.
            #expect(abs(f["a"]!.minX - 6) < 1e-9)
            #expect(abs(f["a"]!.maxX - 452) < 1e-9)
            #expect(abs(f["b"]!.minX - 499) < 1e-9)
            #expect(abs(f["b"]!.maxX - 861) < 1e-9)
            #expect(f["a"]!.maxX <= crease.minX - 3 && f["b"]!.minX >= crease.maxX + 3)
            // Heights are as before.
            #expect(f["a"]!.height == 588 && f["b"]!.height == 588)
        }
    }

    @Test func eachSideKeepsItsProportions() throws {
        // a | (b over c) | d, with the root divider on the crease: b|d keeps 0.4 of the right page.
        let n = Node.row(.pane("a"), .row(.column(.pane("b"), .pane("c"), 0.3), .pane("d"), 0.4), 0.5)
        let book = try #require(decide(n, crease: crease, fontSize: 5))
        #expect(book.before == "a" && book.after == "b")
        let r = Dictionary(uniqueKeysWithValues: n.leaves().map { ($0.id, book.rect($0.rect)) })
        let right = 1 - book.trail
        #expect(abs(r["b"]!.minX - book.trail) < 1e-9)
        #expect(abs(r["b"]!.width - right * 0.4) < 1e-9)
        #expect(abs(r["d"]!.width - right * 0.6) < 1e-9)
        #expect(abs(r["d"]!.maxX - 1) < 1e-9)
        // y is not touched.
        #expect(abs(r["b"]!.height - 0.3) < 1e-9 && abs(r["c"]!.minY - 0.3) < 1e-9)
        #expect(r["c"]!.minX == r["b"]!.minX && r["c"]!.width == r["b"]!.width)
    }

    @Test func theNearestFullHeightDividerIsAligned() throws {
        // Dividers at 0.2 and 0.6: the crease's middle is at 0.549.
        let far = Node.row(.pane("a"), .row(.pane("b"), .pane("c"), 0.5), 0.2)
        let book = try #require(decide(far, crease: crease, fontSize: 5))
        #expect(abs(book.divider - 0.6) < 1e-9)
        #expect(book.before == "b" && book.after == "c")
        // Dividers at 0.5 and 0.75.
        let near = Node.row(.pane("a"), .row(.pane("b"), .pane("c"), 0.5), 0.5)
        #expect(try #require(decide(near, crease: crease, fontSize: 5)).divider == 0.5)
    }

    @Test func ofTwoEquallyNearTheLeftOneIsAligned() throws {
        // Dividers at 0.25 and 0.75 of 800, the crease's middle at 400.
        let n = Node.row(.pane("a"), .row(.pane("b"), .pane("c"), 2.0 / 3), 0.25)
        let book = try #require(decide(n, crease: CGRect(x: 380, y: 0, width: 40, height: 600), width: 800, minX: 0, fontSize: 4))
        #expect(book.divider == 0.25)
        #expect(book.before == "a")
    }

    @Test func aDividerUnderAStackedSplitIsNotACandidate() throws {
        // (a | b) over c: the divider is half the height.
        #expect(decide(.column(.row(.pane("a"), .pane("b"), 0.5), .pane("c"), 0.5)) == nil)
        #expect(decide(.column(.pane("a"), .pane("b"), 0.5)) == nil)
        // a | (b over (c | d)): only the root's divider runs the full height.
        let n = Node.row(.pane("a"), .column(.pane("b"), .row(.pane("c"), .pane("d"), 0.1), 0.5), 0.8)
        #expect(try #require(decide(n, crease: crease, fontSize: 1)).divider == 0.8)
    }

    @Test func offWithoutACreaseInsideTheArea() {
        let n = Node.row(.pane("a"), .pane("b"), 0.5)
        #expect(decide(n, crease: nil) == nil)
        #expect(decide(.pane("a")) == nil)
        // The sidebar fills the left page: the area starts at the crease, or inside it.
        #expect(decide(n, crease: crease, width: 400, minX: 455.5) == nil)
        #expect(decide(n, crease: crease, width: 400, minX: 470) == nil)
        // The crease at or past the area's far edge.
        #expect(decide(n, crease: crease, width: 493, minX: 3) == nil)
        #expect(decide(n, crease: crease, width: 300, minX: 3) == nil)
    }

    @Test func offWhenAPaneWouldNotBeLegible() {
        let n = Node.row(.pane("a"), .pane("b"), 0.5)
        // Sidebar open at 260 pt: the left page is 191.5 pt, and 40 columns at 11 pt need 264.
        #expect(decide(n, crease: crease, width: 600, minX: 264) == nil)
        // Three columns on the right page are too narrow at 11 pt, and fit at 5 pt.
        let three = Node.row(.pane("a"), .row(.pane("b"), .row(.pane("c"), .pane("d"), 0.5), 1.0 / 3), 0.5)
        #expect(decide(three) == nil)
        #expect(decide(three, crease: crease, fontSize: 5) != nil)
    }

    @Test func theAlignedDividerHasNoHandleAndTheOthersKeepTheirRatio() throws {
        let n = Node.row(.pane("a"), .column(.pane("b"), .pane("c"), 0.3), 0.3)
        let book = try #require(decide(n))
        let s = n.splits()
        #expect(book.isAligned(s[0]) && !book.isAligned(s[1]))
        #expect(book.handle(s[0]) == nil)
        let h = try #require(book.handle(s[1]))
        #expect(h.ratio == 0.3)
        #expect(h.rect == book.rect(s[1].rect))
        #expect(book.ratio(s[1], shown: 0.45) == 0.45)
        // The handle sits on the border between b and c.
        let g = SplitGeometry(rect: h.rect, ratio: h.ratio, direction: h.direction, canvas: area)
        #expect(abs(g.origin.x - 493) < 1e-9)
        #expect(abs(g.origin.y - 0.3 * area.height) < 1e-9)
        #expect(abs(g.length - 368) < 1e-9)
    }

    @Test func aDragOnAMappedSplitGivesTheRatioOfTheSameDragUnmapped() throws {
        // a | (b | c) with the root on the crease: b|c is drawn narrower than Rex has it.
        let n = Node.row(.pane("a"), .row(.pane("b"), .pane("c"), 0.4), 0.5)
        let book = try #require(decide(n, crease: crease, fontSize: 5))
        let s = n.splits()[1]
        let h = try #require(book.handle(s))
        let mapped = SplitGeometry(rect: h.rect, ratio: h.ratio, direction: h.direction, canvas: area)
        let plain = SplitGeometry(rect: s.rect, ratio: s.ratio, direction: s.direction, canvas: area)
        #expect(abs(mapped.origin.x - (493 + 0.4 * 368)) < 1e-9)
        // The same share of the split's width, dragged on either drawing.
        for share in [-0.2, 0.07, 0.1, 0.33] {
            let a = mapped.ratio(after: share * mapped.span), b = plain.ratio(after: share * plain.span)
            #expect(abs(a - b) < 1e-9)
            #expect(abs(book.ratio(s, shown: a) - b) < 1e-9)
        }
        // The 50% detent is still an even split.
        #expect(mapped.detent(0.09 * mapped.span).snapped)
        #expect(abs(mapped.ratio(after: mapped.detent(0.09 * mapped.span).offset) - 0.5) < 1e-9)
    }

    @Test func aSplitThatHoldsTheAlignedOneIsDraggedOnItsPage() throws {
        // a | (b | c) with b|c on the crease: a and b share the left page.
        let n = Node.row(.pane("a"), .row(.pane("b"), .pane("c"), 0.5), 0.2)
        let book = try #require(decide(n, crease: crease, fontSize: 5))
        let root = n.splits()[0]
        #expect(book.isAligned(n.splits()[1]) && !book.isAligned(root))
        let h = try #require(book.handle(root))
        // The handle's rect is the left page, and the divider sits where a ends: 0.2 / 0.6 of it.
        #expect(h.rect.minX == 0 && abs(h.rect.maxX - book.lead) < 1e-12)
        #expect(abs(h.ratio - 1.0 / 3) < 1e-9)
        let g = SplitGeometry(rect: h.rect, ratio: h.ratio, direction: h.direction, canvas: area)
        let a = book.rect(n.leaves()[0].rect)
        #expect(abs(g.origin.x - a.maxX * area.width) < 1e-9)
        // No drag: Rex's ratio as it is.
        #expect(abs(book.ratio(root, shown: h.ratio) - 0.2) < 1e-9)
        // Dragged to half the page: with that ratio, a ends at half the page.
        let r = book.ratio(root, shown: 0.5)
        let after = Node.row(.pane("a"), .row(.pane("b"), .pane("c"), 0.5), r)
        let moved = try #require(decide(after, crease: crease, fontSize: 5))
        #expect(moved.before == "b")
        #expect(abs(moved.rect(after.leaves()[0].rect).maxX - moved.lead / 2) < 1e-9)

        // (a | b) | c with a|b on the crease: b and c share the right page.
        let m = Node.row(.row(.pane("a"), .pane("b"), 0.5), .pane("c"), 0.8)
        let bookM = try #require(decide(m, crease: crease, fontSize: 4))
        #expect(abs(bookM.divider - 0.4) < 1e-9)
        let hm = try #require(bookM.handle(m.splits()[0]))
        #expect(abs(hm.rect.minX - bookM.trail) < 1e-12 && abs(hm.rect.maxX - 1) < 1e-9)
        #expect(abs(hm.ratio - 2.0 / 3) < 1e-9)
        #expect(abs(bookM.ratio(m.splits()[0], shown: hm.ratio) - 0.8) < 1e-9)
        let rm = bookM.ratio(m.splits()[0], shown: 0.6)
        let afterM = Node.row(.row(.pane("a"), .pane("b"), 0.5), .pane("c"), rm)
        let movedM = try #require(decide(afterM, crease: crease, fontSize: 4))
        #expect(abs(movedM.rect(afterM.leaves()[2].rect).minX - (movedM.trail + (1 - movedM.trail) * 0.6)) < 1e-9)
        // Rex's limits hold.
        #expect(book.ratio(root, shown: 0.999) == 0.95)
    }

    @Test func besideTheSidebarATabKnowsWhetherItWouldFitCollapsed() {
        // The sidebar takes 261 pt: beside it the left page is too narrow, collapsed it is not.
        let beside = CGSize(width: canvas.width - 261, height: canvas.height)
        func fits(_ n: Node, crease: CGRect? = nil) -> Bool {
            BookSplit.fitsCollapsed(leaves: n.leaves().map(\.rect), splits: n.splits(), canvas: canvas,
                                    crease: crease ?? self.crease, fontSize: 11)
        }
        let n = Node.row(.pane("a"), .pane("b"), 0.5)
        #expect(BookSplit.decide(leaves: n.leaves().map(\.rect), splits: n.splits(), areaWidth: beside.width - 6, areaMinX: 264,
                                 crease: crease, canvas: beside, fontSize: 11) == nil)
        #expect(fits(n))
        // The same answer as book mode itself once the sidebar is collapsed.
        #expect(decide(n) != nil)
        #expect(!fits(.column(.pane("a"), .pane("b"), 0.5)))
        #expect(!fits(.pane("a")))
        #expect(!fits(.row(.pane("a"), .row(.pane("b"), .pane("c"), 0.5), 0.5)))
        #expect(!fits(n, crease: CGRect(x: 0, y: 455.5, width: 951, height: 0)))
        // Beside the sidebar a 32% pane is too narrow and one pane shows at a time; collapsed, both fit.
        let narrow = Node.row(.pane("a"), .pane("b"), 0.32)
        #expect(!SplitGeometry.legible(narrow.leaves().map(\.rect), canvas: beside, fontSize: 11))
        #expect(fits(narrow))
        // Too narrow as Rex lays it out even collapsed: one pane at a time, and book mode stays out.
        #expect(!fits(.row(.pane("a"), .pane("b"), 0.2)))
    }

    @Test func theRestSizeIsAsWideAsThePane() throws {
        // The keyboard covers a pane only if its remembered size has the pane's width.
        let n = Node.row(.pane("a"), .column(.pane("b"), .pane("c"), 0.5), 0.3)
        let book = try #require(decide(n))
        for leaf in n.leaves() {
            let r = book.rect(leaf.rect)
            let rest = try #require(PaneLayout.splitRest(r, canvas: canvas))
            // The keyboard is up: the area is shorter, its width the same. The terminal sits
            // inside the pane's corner clearance.
            let frame = PaneLayout.split(r, in: CGSize(width: area.width, height: 300))
            let inset = PaneLayout.clearance(radius: PaneLayout.splitRadius) * 2
            let terminal = CGSize(width: frame.width - inset, height: frame.height - inset)
            #expect(abs(rest.width - terminal.width) < 1e-9)
            #expect(TerminalLayout.fitSize(bounds: terminal, rest: rest, alternateScreen: false) == rest)
        }
    }
}

struct CreaseSettleTests {
    private let flat = Division(frame: CGRect(x: 475.5, y: 0, width: 0, height: 669), isActive: false)
    private let book = Division(frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), isActive: true)
    private let tabletop = Division(frame: CGRect(x: 0, y: 455.5, width: 669, height: 40), isActive: true)

    @Test func onlyAnActiveVerticalCreaseCounts() {
        #expect(CreaseSettle.live(book) == book.frame)
        #expect(CreaseSettle.live(flat) == nil)
        #expect(CreaseSettle.live(tabletop) == nil)
        #expect(CreaseSettle.live(nil) == nil)
    }

    @Test func theFirstLayoutUsesTheCreaseAtOnce() {
        let s = CreaseSettle()
        #expect(!s.started)
        #expect(s.crease(book) == book.frame)
        #expect(s.crease(flat) == nil)
        #expect(s.crease(tabletop) == nil)
    }

    @MainActor @Test func aFlipCountsOnlyOnceItHasHeld() {
        var s = CreaseSettle()
        s.settle(flat)
        #expect(s.started)
        // Bent, and not yet held for the delay: still flat.
        #expect(s.crease(book) == nil)
        s.settle(book)
        #expect(s.crease(book) == book.frame)
        // Flat again, not yet held: still book, against the crease that held.
        #expect(s.crease(flat) == book.frame)
        s.settle(flat)
        #expect(s.crease(flat) == nil)
        #expect(CreaseSettle.delay == 400_000_000)
        #expect(CreaseSettle.delay > FitClaim.settleDelay)
    }

    @Test func aCreaseThatIsGoneOrMovedIsDroppedAtOnce() {
        var s = CreaseSettle()
        s.settle(book)
        // Fully folded, or turned so the crease is horizontal.
        #expect(s.crease(nil) == nil)
        #expect(s.crease(tabletop) == nil)
        // Another window: the crease is somewhere else, and counts once it has held.
        let moved = Division(frame: book.frame.offsetBy(dx: -120, dy: 0), isActive: true)
        #expect(s.crease(moved) == nil)
        s.settle(moved)
        #expect(s.crease(moved) == moved.frame)
        // A point of noise in the reported frame is the same crease.
        let near = Division(frame: moved.frame.offsetBy(dx: 0.5, dy: 0), isActive: true)
        #expect(s.crease(near) == moved.frame)
    }

    /// Opened from shut straight into book mode, the window turns wide before the fold has held:
    /// book mode is pending, not over, so a book-collapsed sidebar must not come back yet.
    @Test func bentButNotYetHeldIsPending() {
        var s = CreaseSettle()
        // The first layout decides at once.
        #expect(!s.pending(book))
        s.settle(book)
        #expect(!s.pending(book))
        // Folded shut and held: no crease.
        s.settle(nil)
        #expect(!s.pending(nil))
        #expect(!s.pending(flat))
        // Bent open again, not yet held.
        #expect(s.pending(book))
        #expect(!s.pending(tabletop))
        s.settle(book)
        #expect(!s.pending(book))
    }
}

struct BookSidebarTests {
    @Test func bookModeCollapsesTheSidebarAndBringsItBack() {
        var s = BookSidebar()
        #expect(s.update(book: false, fits: false, open: true, inline: true) == nil)
        #expect(s.update(book: true, fits: true, open: true, inline: true) == .collapse)
        s.sidebarChanged(open: false)
        // Still in book mode: nothing more.
        #expect(s.update(book: true, fits: true, open: false, inline: true) == nil)
        #expect(s.update(book: false, fits: false, open: false, inline: true) == .reopen)
        s.sidebarChanged(open: true)
        #expect(!s.collapsedIt)
        #expect(s.update(book: false, fits: false, open: true, inline: true) == nil)
        // And again the next time.
        #expect(s.update(book: true, fits: true, open: true, inline: true) == .collapse)
    }

    @Test func nothingToAlignLeavesTheSidebarAlone() {
        var s = BookSidebar()
        #expect(s.update(book: true, fits: false, open: true, inline: true) == nil)
        #expect(s.update(book: false, fits: false, open: true, inline: true) == nil)
        // Collapsed by the user already.
        #expect(s.update(book: true, fits: true, open: false, inline: true) == nil)
        #expect(s.update(book: false, fits: false, open: false, inline: true) == nil)
        // A drawer is not book mode's to close.
        #expect(s.update(book: true, fits: true, open: true, inline: false) == nil)
        #expect(s.update(book: false, fits: false, open: true, inline: false) == nil)
    }

    @Test func onlyTheWayIntoBookModeCollapses() {
        var s = BookSidebar()
        #expect(s.update(book: true, fits: false, open: true, inline: true) == nil)
        // Another tab, or a split made later, while still in book mode.
        #expect(s.update(book: true, fits: true, open: true, inline: true) == nil)
        #expect(s.update(book: true, fits: nil, open: true, inline: true) == nil)
        #expect(s.update(book: true, fits: true, open: true, inline: true) == nil)
        #expect(s.update(book: false, fits: false, open: true, inline: true) == nil)
    }

    @Test func aLaunchInBookModeDecidesOnceTheTabIsMeasured() {
        var s = BookSidebar()
        #expect(s.update(book: true, fits: nil, open: true, inline: true) == nil)
        #expect(s.update(book: true, fits: nil, open: true, inline: true) == nil)
        #expect(s.update(book: true, fits: true, open: true, inline: true) == .collapse)

        var t = BookSidebar()
        #expect(t.update(book: true, fits: nil, open: true, inline: true) == nil)
        #expect(t.update(book: true, fits: false, open: true, inline: true) == nil)
        #expect(t.update(book: true, fits: true, open: true, inline: true) == nil)
    }

    @Test func theUsersOwnChoiceStands() {
        // Opened during book mode: it stays open, and nothing collapses it again.
        var s = BookSidebar()
        #expect(s.update(book: true, fits: true, open: true, inline: true) == .collapse)
        s.sidebarChanged(open: false)
        #expect(s.collapsedIt)
        s.sidebarChanged(open: true)
        #expect(!s.collapsedIt)
        #expect(s.update(book: true, fits: false, open: true, inline: true) == nil)
        #expect(s.update(book: true, fits: true, open: true, inline: true) == nil)
        #expect(s.update(book: false, fits: false, open: true, inline: true) == nil)

        // Opened and closed again by the user: closed is how they left it.
        var t = BookSidebar()
        #expect(t.update(book: true, fits: true, open: true, inline: true) == .collapse)
        t.sidebarChanged(open: false)
        t.sidebarChanged(open: true)
        t.sidebarChanged(open: false)
        #expect(t.update(book: false, fits: false, open: false, inline: true) == nil)

        // A change before ours was seen is the user's too.
        var u = BookSidebar()
        #expect(u.update(book: true, fits: true, open: true, inline: true) == .collapse)
        u.sidebarChanged(open: true)
        #expect(!u.collapsedIt)
    }

    @Test func foldedShutTheSidebarWaitsForAWideWindow() {
        var s = BookSidebar()
        #expect(s.update(book: true, fits: true, open: true, inline: true) == .collapse)
        s.sidebarChanged(open: false)
        // Fully folded: a narrow window, where the sidebar would be a drawer over the tab.
        #expect(s.update(book: false, fits: false, open: false, inline: false) == nil)
        #expect(s.collapsedIt)
        // Bent open again without ever lying flat: still collapsed, still book mode's doing.
        #expect(s.update(book: true, fits: true, open: false, inline: true) == nil)
        #expect(s.update(book: false, fits: false, open: false, inline: true) == .reopen)
    }
}
