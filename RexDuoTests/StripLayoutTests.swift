import CoreGraphics
import Testing
@testable import RexDuo

/// What the tab strip shows at each width and where (`StripLayout`): the compact rules on every
/// phone width, the full strip in wide bars, the crease cap, and frames a finger can hit.
struct StripLayoutTests {
    /// A bar with everything in it: a zoomed tab of six panes shown one at a time, and an agent
    /// waiting elsewhere.
    private func busy(_ width: CGFloat, bar: Bool, height: CGFloat = 44) -> StripLayout.Input {
        StripLayout.Input(width: width, height: height, bar: bar, zoomed: true, panes: 6, waiting: 1)
    }

    private func checkFrames(_ l: StripLayout, _ i: StripLayout.Input, _ note: String) {
        Self.checkFrames(l, i, note)
    }

    /// The frames are in order, apart, inside the bar's paddings and as tall as the bar; every
    /// part a finger taps is at least 44 pt wide; the chips keep their gap on both sides.
    static func checkFrames(_ l: StripLayout, _ i: StripLayout.Input, _ note: String) {
        let parts = l.parts
        #expect(parts.first == .session, "\(note)")
        #expect(l.start >= StripLayout.leading(bar: i.bar), "\(note)")
        var x = l.start
        for part in parts {
            guard let f = l.frame(part) else { Issue.record("\(note): \(part) has no frame"); continue }
            #expect(f.minX >= x, "\(note): \(part) overlaps the part before it")
            #expect(f.minY == 0 && f.height == i.height, "\(note): \(part)")
            if part.tappable { #expect(f.width >= StripLayout.hit, "\(note): \(part) is \(f.width) pt wide") }
            x = f.maxX
        }
        #expect(x <= l.end, "\(note): the strip runs past its end")
        #expect(l.end <= i.width - StripLayout.trailing, "\(note)")
        if let chips = l.frame(.chips), let session = l.frame(.session) {
            #expect(chips.minX - session.maxX >= StripLayout.gap, "\(note): the first chip touches the session chip")
            if let next = parts.drop(while: { $0 != .chips }).dropFirst().first.flatMap(l.frame) {
                #expect(next.minX - chips.maxX >= StripLayout.gap, "\(note): the last chip touches what follows")
            }
        }
    }

    // MARK: Phone widths

    /// 375 (SE class), 382 (the folded Duo inside its vertical bar), 402 (iPhone 17 Pro) and
    /// 430 pt, with the waiting pill, the pane dots and zoom all present: the compact rules.
    @Test(arguments: [375, 382, 402, 430] as [CGFloat], [false, true])
    func aPhoneWidthIsCompact(width: CGFloat, bar: Bool) {
        let i = busy(width, bar: bar)
        let l = StripLayout(i)
        let note = "\(width) pt, bar \(bar)"
        #expect(l.compact, "\(note)")
        // "+" and Unzoom are left to the Pane Actions menu.
        #expect(!l.shows(.newTab) && !l.shows(.unzoom), "\(note)")
        // The dots are "n/m", the session chip a glyph.
        #expect(l.dots == .count, "\(note)")
        #expect(l.session == .glyph, "\(note)")
        #expect(l.frame(.session)?.width == StripLayout.hit, "\(note)")
        #expect(l.shows(.waiting), "\(note)")
        // The pane menu is in the vertical bar where there is one.
        #expect(l.shows(.paneMenu) == !bar, "\(note)")
        #expect(l.parts == (bar ? [.session, .chips, .dots, .waiting] : [.session, .chips, .dots, .waiting, .paneMenu]), "\(note)")
        // The chips keep the active chip with its close button and one more chip in view.
        #expect(l.chipsWidth >= StripLayout.chipsRoom, "\(note): the chips have \(l.chipsWidth) pt")
        #expect(l.showsClose, "\(note)")
        #expect(l.activeChip.lowerBound == StripLayout.closeChipMin && l.activeChip.upperBound == l.chipsWidth, "\(note)")
        #expect(l.chip.lowerBound == StripLayout.chipMin, "\(note)")
        checkFrames(l, i, note)
    }

    /// The exact frames at 375 pt without a vertical bar and at 382 pt beside one.
    @Test func thePhoneFramesAreExact() {
        let phone = StripLayout(busy(375, bar: false))
        #expect(phone.frame(.session) == CGRect(x: 4, y: 0, width: 44, height: 44))
        #expect(phone.frame(.chips) == CGRect(x: 54, y: 0, width: 186, height: 44))
        #expect(phone.frame(.dots) == CGRect(x: 246, y: 0, width: 37, height: 44))
        #expect(phone.frame(.waiting) == CGRect(x: 283, y: 0, width: 44, height: 44))
        #expect(phone.frame(.paneMenu) == CGRect(x: 327, y: 0, width: 44, height: 44))

        let duo = StripLayout(busy(382, bar: true))
        #expect(duo.frame(.session) == CGRect(x: 12, y: 0, width: 44, height: 44))
        #expect(duo.frame(.chips) == CGRect(x: 62, y: 0, width: 229, height: 44))
        #expect(duo.frame(.dots) == CGRect(x: 297, y: 0, width: 37, height: 44))
        #expect(duo.frame(.waiting) == CGRect(x: 334, y: 0, width: 44, height: 44))
        #expect(duo.frame(.paneMenu) == nil)
    }

    // MARK: Wide bars

    /// The folded Duo on its side (594 pt beside its bar), tabletop (669), an iPhone in
    /// landscape (750) and the unfolded Duo (867 beside its bar): every part in its full form.
    @Test(arguments: [(594, true), (669, false), (750, false), (867, true)] as [(CGFloat, Bool)])
    func aWideBarShowsEveryPart(width: CGFloat, bar: Bool) {
        for height in [34, 44] as [CGFloat] {
            let i = busy(width, bar: bar, height: height)
            let l = StripLayout(i)
            let note = "\(width) pt, bar \(bar), \(height) pt tall"
            #expect(!l.compact, "\(note)")
            #expect(l.session == .name, "\(note)")
            #expect(l.dots == .dots(6), "\(note)")
            #expect(l.shows(.newTab), "\(note)")
            // Unzoom follows the pane menu: both are in the vertical bar where there is one.
            #expect(l.shows(.unzoom) == !bar && l.shows(.paneMenu) == !bar, "\(note)")
            #expect(l.parts == (bar ? [.session, .chips, .dots, .waiting, .newTab]
                                    : [.session, .chips, .dots, .waiting, .unzoom, .newTab, .paneMenu]), "\(note)")
            #expect(l.chipsWidth >= StripLayout.chipsRoom && l.showsClose, "\(note)")
            checkFrames(l, i, note)
        }
    }

    /// Compact starts where the full strip would leave the chips less than the active chip with
    /// its close button and one more: under 440 pt beside a vertical bar, under 520 pt without.
    @Test func compactStartsWhereTheChipsWouldBeSqueezed() {
        #expect(StripLayout(busy(439, bar: true)).compact)
        #expect(!StripLayout(busy(440, bar: true)).compact)
        #expect(StripLayout(busy(440, bar: true)).chipsWidth == StripLayout.chipsRoom)
        #expect(StripLayout(busy(519, bar: false)).compact)
        #expect(!StripLayout(busy(520, bar: false)).compact)
        #expect(StripLayout(busy(520, bar: false)).chipsWidth == StripLayout.chipsRoom)
    }

    /// A pill, the dots or zoom coming and going moves nothing but the chips' end: the form of
    /// the strip and of the session chip depend on the bar alone.
    @Test func whatComesAndGoesNeverChangesTheForm() {
        for width in [375, 382, 402, 430, 452.5, 594, 750, 867] as [CGFloat] {
            for bar in [false, true] {
                let busy = StripLayout(busy(width, bar: bar))
                let quiet = StripLayout(.init(width: width, bar: bar))
                #expect(busy.compact == quiet.compact, "\(width) pt, bar \(bar)")
                #expect(busy.session == quiet.session && busy.frame(.session) == quiet.frame(.session))
                #expect(busy.shows(.newTab) == quiet.shows(.newTab) && busy.frame(.newTab) == quiet.frame(.newTab))
                #expect(busy.frame(.paneMenu) == quiet.frame(.paneMenu))
                #expect(busy.frame(.chips)?.minX == quiet.frame(.chips)?.minX)
                #expect(!quiet.shows(.dots) && !quiet.shows(.waiting) && !quiet.shows(.unzoom))
            }
        }
    }

    // MARK: Crease

    #if DEBUG
    /// Book mode on the Duo: the whole strip, "+" included, ends 3 pt short of the crease, on the
    /// left page. Flat, the same window's strip runs the bar's width as the title bar does.
    @Test func bookModeCapsTheStripAtTheCrease() throws {
        let book = try #require(DuoSimulation.named("book"))
        let crease = try #require(book.rootDivision).frame
        var i = busy(book.rootSize.width, bar: true)
        i.crease = crease
        let l = StripLayout(i)
        #expect(l.end == crease.minX - 3)
        #expect(l.end == 452.5)
        // The capped strip has room for every part beside the vertical bar.
        #expect(!l.compact && l.shows(.newTab))
        #expect(l.frame(.newTab)?.maxX == 452.5)
        for part in l.parts {
            #expect(try #require(l.frame(part)).maxX <= crease.minX - 3, "\(part) reaches the crease")
        }
        checkFrames(l, i, "book")

        let flat = try #require(DuoSimulation.named("unfolded"))
        let open = StripLayout(busy(flat.rootSize.width, bar: true))
        #expect(open.end == flat.rootSize.width - StripLayout.trailing)
        #expect(open.frame(.newTab)?.maxX == 863)
    }
    #endif

    /// The crease is in the root's coordinates and the bar may start elsewhere: the strip ends
    /// at the crease's leading edge, less 3 pt, less the bar's own origin.
    @Test func theCreaseIsConvertedThroughTheBarsOrigin() {
        let crease = CGRect(x: 455.5, y: 0, width: 40, height: 669)
        var i = busy(867, bar: true)
        i.crease = crease
        i.originX = 100
        #expect(StripLayout.creaseSpan(i) == 352.5...398.5)
        let l = StripLayout(i)
        #expect(l.start == 12 && l.end == 352.5)
        // What is left is a phone's width: the compact rules.
        #expect(l.compact && !l.shows(.newTab))
        checkFrames(l, i, "offset bar")
    }

    /// A crease that doesn't cross the bar caps nothing: a bar that ends before it, and one
    /// that starts after it.
    @Test func aCreaseOutsideTheBarCapsNothing() {
        let crease = CGRect(x: 455.5, y: 0, width: 40, height: 669)
        var left = busy(402, bar: false)
        left.crease = crease
        #expect(StripLayout.creaseSpan(left) == nil)
        #expect(StripLayout(left) == StripLayout(busy(402, bar: false)))

        var right = busy(360, bar: true)
        right.crease = crease
        right.originX = 500
        #expect(StripLayout.creaseSpan(right) == nil)
        #expect(StripLayout(right).start == 12 && StripLayout(right).end == 356)
    }

    /// The session chip never crosses the strip's end. Down to 56 pt beside a vertical bar
    /// (48 pt without one) the left page still holds it as a 44 pt glyph, and it ends 3 pt
    /// short of the crease.
    @Test(arguments: [false, true])
    func theSessionChipEndsAtTheCrease(bar: Bool) throws {
        let lead = StripLayout.leading(bar: bar)
        for cap in [lead + 44, lead + 60, lead + 120, 200] as [CGFloat] {
            var i = busy(867, bar: bar)
            // The longest name: without the crease its chip is 120 pt.
            i.sessionIdeal = 300
            i.crease = CGRect(x: cap + 3, y: 0, width: 40, height: 669)
            let l = StripLayout(i)
            let chip = try #require(l.frame(.session))
            #expect(l.start == lead && l.end == cap, "cap \(cap)")
            #expect(chip.minX == lead && chip.maxX <= cap && chip.width >= StripLayout.hit, "cap \(cap): \(chip)")
            // What has no room between the chip and the crease isn't there (it stays in the
            // pane menu, which is kept first, or in the vertical bar); nothing is drawn across
            // the crease or over the chip.
            for part in l.parts where part != .session {
                let f = try #require(l.frame(part))
                #expect(f.minX >= chip.maxX && f.maxX <= cap, "cap \(cap): \(part) at \(f)")
            }
            if !bar { #expect(l.shows(.paneMenu) == (cap >= lead + 88), "cap \(cap)") }
            checkFrames(l, i, "cap \(cap), bar \(bar)")
        }
    }

    /// A crease that leaves less than a hit target before it (a cap under 56 pt beside a
    /// vertical bar, under 48 pt without one): the strip starts past the crease, 3 pt clear of
    /// it, so the session chip is whole and nothing is on the fold.
    @Test(arguments: [false, true])
    func aCreaseTooNearTheBarsStartMovesTheStripPastIt(bar: Bool) throws {
        let lead = StripLayout.leading(bar: bar)
        for cap in [lead + 43, lead + 20, lead, 5, -10] as [CGFloat] {
            var i = busy(867, bar: bar)
            i.sessionIdeal = 90
            i.crease = CGRect(x: cap + 3, y: 0, width: 40, height: 669)
            let past = cap + 3 + 40 + 3
            let l = StripLayout(i)
            #expect(l.start == past && l.end == 867 - StripLayout.trailing, "cap \(cap)")
            #expect(try #require(l.frame(.session)) == CGRect(x: past, y: 0, width: 90, height: 44), "cap \(cap)")
            for part in l.parts {
                #expect(try #require(l.frame(part)).minX >= past, "cap \(cap): \(part) is on the crease")
            }
            checkFrames(l, i, "cap \(cap), bar \(bar)")
        }
    }

    /// A bar with a hit target on neither side of the crease keeps the wider side, and the
    /// session chip is cut to what is there: it never reaches the crease.
    @Test func aBarWithNoRoomOnEitherSideCutsTheSessionChip() throws {
        // 30 pt before the crease, 28 pt after it.
        var i = StripLayout.Input(width: 120, bar: false, hasSession: false, hasPane: false)
        i.crease = CGRect(x: 37, y: 0, width: 48, height: 669)
        let l = StripLayout(i)
        #expect(l.start == 4 && l.end == 34)
        #expect(try #require(l.frame(.session)) == CGRect(x: 4, y: 0, width: 30, height: 44))
        // More room after it: the strip is there.
        i.crease = CGRect(x: 23, y: 0, width: 48, height: 669)
        let after = StripLayout(i)
        #expect(after.start == 74 && after.end == 116)
        #expect(try #require(after.frame(.session)) == CGRect(x: 74, y: 0, width: 42, height: 44))
    }

    // MARK: The floats slot

    /// A tab with floating windows keeps a slot beside the pane menu. At the four phone widths,
    /// with everything else present too: the slot is a hit target, it sits against the pane
    /// menu (against the strip's end beside a vertical bar), and its room comes out of the chips.
    @Test(arguments: [375, 382, 402, 430] as [CGFloat], [false, true])
    func theFloatsSlotTakesItsRoomFromTheChips(width: CGFloat, bar: Bool) throws {
        var i = busy(width, bar: bar)
        let without = StripLayout(i)
        i.hasFloatsControl = true
        let l = StripLayout(i)
        let note = "\(width) pt, bar \(bar)"
        #expect(!without.shows(.floats), "\(note)")
        #expect(l.compact, "\(note)")
        #expect(l.parts == (bar ? [.session, .chips, .dots, .waiting, .floats]
                                : [.session, .chips, .dots, .waiting, .floats, .paneMenu]), "\(note)")
        let slot = try #require(l.frame(.floats))
        #expect(slot.width == StripLayout.hit, "\(note)")
        #expect(slot.maxX == (l.frame(.paneMenu)?.minX ?? l.end), "\(note)")
        #expect(l.chipsWidth == without.chipsWidth - StripLayout.hit, "\(note)")
        // The chips still hold the active chip with its close button; the button itself needs
        // one more chip's room, which only 375 pt without a vertical bar lacks (142 pt).
        #expect(l.chipsWidth >= StripLayout.closeChipMin, "\(note): the chips have \(l.chipsWidth) pt")
        #expect(l.showsClose == (l.chipsWidth >= StripLayout.chipsRoom), "\(note)")
        #expect(l.showsClose == !(width == 375 && !bar), "\(note)")
        // The other parts stay where they are without the slot, but for the ones before it.
        #expect(l.frame(.session) == without.frame(.session) && l.frame(.paneMenu) == without.frame(.paneMenu), "\(note)")
        checkFrames(l, i, note)
    }

    /// The slot takes part in the form: with it, the strip is compact 44 pt sooner, and it is
    /// there in both forms. Off, nothing is kept and nothing changes.
    @Test func theFloatsSlotCountsTowardCompact() {
        func strip(_ width: CGFloat, bar: Bool) -> StripLayout {
            var i = busy(width, bar: bar)
            i.hasFloatsControl = true
            return StripLayout(i)
        }
        #expect(strip(483, bar: true).compact && !strip(484, bar: true).compact)
        #expect(strip(563, bar: false).compact && !strip(564, bar: false).compact)
        #expect(strip(564, bar: false).chipsWidth == StripLayout.chipsRoom)
        #expect(strip(564, bar: false).parts == [.session, .chips, .dots, .waiting, .unzoom, .newTab, .floats, .paneMenu])
        #expect(strip(594, bar: true).parts == [.session, .chips, .dots, .waiting, .newTab, .floats])
        #expect(StripLayout.fullParts(bar: true, floats: true) == StripLayout.fullParts(bar: true) + StripLayout.hit)
        // It needs no pane menu beside it, and no session's chips.
        var bare = StripLayout.Input(width: 402, hasSession: false, hasPane: false)
        bare.hasFloatsControl = true
        #expect(StripLayout(bare).parts == [.session, .floats])
    }

    /// The crease cap holds for the slot too: in book mode it ends 3 pt short of the crease.
    @Test func theFloatsSlotStaysOffTheCrease() throws {
        var i = busy(867, bar: true)
        i.crease = CGRect(x: 455.5, y: 0, width: 40, height: 669)
        i.hasFloatsControl = true
        let l = StripLayout(i)
        #expect(try #require(l.frame(.floats)).maxX == 452.5)
        // The slot's 44 pt make the left page's strip compact.
        #expect(l.compact && !l.shows(.newTab))
        checkFrames(l, i, "book with floats")
    }

    // MARK: Chips

    /// The close button shows only while the chips hold the active chip with it and one more.
    /// Narrower (Split View), the active chip is a plain chip, and no chip is under 44 pt.
    @Test func theCloseButtonNeedsRoom() {
        // 144 pt of chips at 333 pt, 143 at 332.
        let fits = StripLayout(busy(333, bar: false))
        #expect(fits.chipsWidth == 144 && fits.showsClose)
        #expect(fits.activeChip == 94...144)
        let tight = StripLayout(busy(332, bar: false))
        #expect(tight.chipsWidth == 143 && !tight.showsClose)
        #expect(tight.activeChip == 44...143)
        #expect(tight.chip == 44...143)
        // The pane menu, with Close Tab in it, is still there.
        #expect(tight.shows(.paneMenu))
    }

    /// Chips never get less than one chip's width: with less, they aren't drawn, and the parts
    /// that are keep their places.
    @Test func chipsNeedAChipsWidth() {
        let one = StripLayout(busy(233, bar: false))
        #expect(one.chipsWidth == 44)
        let none = StripLayout(busy(232, bar: false))
        #expect(!none.shows(.chips))
        #expect(none.parts == [.session, .dots, .waiting, .paneMenu])
        #expect(none.chip.lowerBound == StripLayout.chipMin && none.activeChip.lowerBound == StripLayout.chipMin)
    }

    // MARK: Parts

    @Test func theDotsAreDotsUpToSixPanesInAWideBar() {
        func dots(_ panes: Int, width: CGFloat = 750) -> StripLayout {
            StripLayout(.init(width: width, panes: panes))
        }
        #expect(dots(0).dots == nil && dots(1).dots == nil)
        #expect(dots(2).dots == .dots(2) && dots(2).frame(.dots)?.width == 32)
        #expect(dots(6).dots == .dots(6) && dots(6).frame(.dots)?.width == 60)
        // As the title bar: more than six is a count.
        #expect(dots(7).dots == .count && dots(7).frame(.dots)?.width == 37)
        #expect(dots(12).frame(.dots)?.width == 51)
        // Compact: always a count.
        #expect(dots(2, width: 402).dots == .count)
        #expect(dots(1, width: 402).dots == nil)
    }

    @Test func theWaitingPillGrowsWithItsCount() {
        #expect(StripLayout.waitingWidth(1) == 44)
        #expect(StripLayout.waitingWidth(9) == 44)
        #expect(StripLayout.waitingWidth(12) == 49)
        #expect(!StripLayout(.init(width: 402, waiting: 0)).shows(.waiting))
        #expect(StripLayout(.init(width: 402, waiting: 12)).frame(.waiting)?.width == 49)
    }

    /// The session chip takes its name's width, between a hit target and its most.
    @Test func theSessionChipFitsItsName() {
        func width(_ ideal: CGFloat?, bar: CGFloat = 750) -> CGFloat? {
            StripLayout(.init(width: bar, sessionIdeal: ideal)).frame(.session)?.width
        }
        #expect(width(nil) == StripLayout.sessionMax)
        #expect(width(72) == 72)
        #expect(width(20) == StripLayout.hit)
        #expect(width(120) == 120 && width(121) == StripLayout.sessionMax)
        #expect(width(300) == StripLayout.sessionMax)
        // What a short name leaves goes to the chips, which start 6 pt after the chip.
        let short = StripLayout(.init(width: 750, sessionIdeal: 72)), long = StripLayout(.init(width: 750, sessionIdeal: 300))
        #expect(short.frame(.chips)?.minX == 4 + 72 + 6 && long.frame(.chips)?.minX == 4 + 120 + 6)
        #expect(short.chipsWidth == long.chipsWidth + 48)
        #expect(short.frame(.chips)?.maxX == long.frame(.chips)?.maxX && short.frame(.newTab) == long.frame(.newTab))
        // The name's width doesn't decide the form.
        #expect(!StripLayout(.init(width: 520, sessionIdeal: 300)).compact)
        // As a glyph it is a hit target, whatever the name.
        #expect(width(300, bar: 402) == StripLayout.hit)
    }

    /// No session on screen: the session chip alone. A session whose tab closed: its chips and
    /// New Tab, and nothing that needs a pane.
    @Test func withoutASessionOrAPane() {
        var none = busy(750, bar: false)
        none.hasSession = false
        none.hasPane = false
        none.waiting = 0
        #expect(StripLayout(none).parts == [.session])
        // Another machine's agent may still wait.
        none.waiting = 2
        #expect(StripLayout(none).parts == [.session, .waiting])

        var closed = busy(750, bar: false)
        closed.hasPane = false
        #expect(StripLayout(closed).parts == [.session, .chips, .waiting, .newTab])
        closed.width = 402
        #expect(StripLayout(closed).parts == [.session, .chips, .waiting])
    }

    /// Only the dots take no tap.
    @Test func theDotsAreTheOnlyPartWithoutATap() {
        #expect(StripLayout.Part.allCases.filter { !$0.tappable } == [.dots])
    }

    // MARK: Every posture

    #if DEBUG
    /// The strip in every posture `-simulateDuo` knows, as tab mode lays it out there: as wide
    /// as the window inside its insets, capped by the crease book mode settles on. With and
    /// without the vertical bar's items (a simulator draws no vertical bar), busy and quiet,
    /// with a floating windows control, with no session, and with short and long session names:
    /// every frame is inside the bar, none is on the crease, and what a finger taps is a hit
    /// target clear of its neighbors.
    @Test func everyPostureKeepsItsFramesInsideAndOffTheCrease() throws {
        var barEdges = Set<String>(), capped: [String] = []
        for p in DuoSimulation.postures {
            let width = p.rootSize.width
            let crease = CreaseSettle().crease(p.rootDivision)
            let height: CGFloat = p.vertical == .compact ? 34 : 44
            let hasBar = p.safeArea.leading == 84 || p.safeArea.trailing == 84
            if hasBar { barEdges.insert(p.safeArea.leading == 84 ? "leading" : "trailing") }
            if crease != nil { capped.append(p.name) }
            for bar in hasBar ? [true, false] : [false] {
                var inputs: [(String, StripLayout.Input)] = []
                for ideal in [nil, 44, 80, 300] as [CGFloat?] {
                    var full = busy(width, bar: bar, height: height)
                    full.crease = crease
                    full.sessionIdeal = ideal
                    inputs.append(("busy", full))
                    var floats = full
                    floats.hasFloatsControl = true
                    inputs.append(("floats", floats))
                    var quiet = StripLayout.Input(width: width, height: height, crease: crease, bar: bar)
                    quiet.sessionIdeal = ideal
                    inputs.append(("quiet", quiet))
                    var empty = quiet
                    empty.hasSession = false
                    empty.hasPane = false
                    inputs.append(("no session", empty))
                }
                for (what, i) in inputs {
                    let l = StripLayout(i)
                    let note = "\(p.name), bar \(bar), \(what), name \(i.sessionIdeal.map { "\($0)" } ?? "unmeasured")"
                    checkFrames(l, i, note)
                    for part in l.parts {
                        let f = try #require(l.frame(part))
                        #expect(f.minX >= StripLayout.leading(bar: bar) && f.maxX <= width - StripLayout.trailing, "\(note): \(part) at \(f)")
                        #expect(f.width > 0 && f.minY == 0 && f.maxY == height, "\(note): \(part) at \(f)")
                        if let crease {
                            // The bar starts at the root's leading edge: the same coordinates.
                            let fold = crease.insetBy(dx: -StripLayout.creaseClearance, dy: 0)
                            #expect(f.maxX <= fold.minX || f.minX >= fold.maxX, "\(note): \(part) at \(f) is on the crease \(fold)")
                        }
                    }
                    // The way to the sessions and, with a pane, to its menu: in the strip, or
                    // in the vertical bar, never neither.
                    #expect(l.shows(.session), "\(note)")
                    #expect(l.frame(.session).map { $0.width >= StripLayout.hit } == true, "\(note)")
                    if i.hasPane { #expect(l.shows(.paneMenu) == !bar, "\(note)") }
                    if i.hasSession { #expect(l.chipsWidth >= StripLayout.closeChipMin, "\(note): the chips have \(l.chipsWidth) pt") }
                }
            }
        }
        #expect(barEdges == ["leading", "trailing"], "a posture with the bar on each edge")
        // Only book mode has a crease the strip must end at.
        #expect(capped == ["book"])
    }

    /// Tabletop: the fold runs across the window and the tab is above it. The strip is the top
    /// of the upper half, at the window's full width, far from the fold.
    @Test func tabletopKeepsTheStripAboveTheFold() throws {
        let p = try #require(DuoSimulation.named("tabletop"))
        let fold = try #require(p.rootDivision)
        #expect(fold.isActive && !fold.isVertical)
        // A fold across the window caps nothing.
        #expect(CreaseSettle().crease(fold) == nil)
        let i = busy(p.rootSize.width, bar: false)
        let l = StripLayout(i)
        #expect(l.start == 4 && l.end == p.rootSize.width - StripLayout.trailing && !l.compact)
        for part in l.parts {
            #expect(try #require(l.frame(part)).maxY <= fold.frame.minY - StripLayout.creaseClearance, "\(part)")
        }
        checkFrames(l, i, "tabletop")
    }

    /// The vertical bar's items in every posture that has the bar, on either edge, typing or
    /// not, zoomed or not: tab mode's list is sidebar mode's with Sessions where the sidebar
    /// toggle is, so the bar holds as many items either way and they fit above the keyboard.
    /// What the strip leaves to the bar there (the pane menu, Unzoom) is in the bar's list.
    @Test func bothModesBarListsFitEveryPostureWithABar() {
        var edges = Set<String>()
        for p in DuoSimulation.postures where p.safeArea.leading == 84 || p.safeArea.trailing == 84 {
            let leading = p.safeArea.leading == 84
            edges.insert(leading ? "leading" : "trailing")
            let column = CGRect(x: leading ? 0 : p.size.width - 84, y: 0, width: 84, height: p.size.height)
            let room = TabActions.keyBarRoom(column: column, compactHeight: p.vertical == .compact)
            for typing in [false, true] {
                for zoomed in [false, true] {
                    let note = "\(p.name), typing \(typing), zoomed \(zoomed)"
                    let sidebar = TabActions.verticalBar(.sidebar, zoomed: zoomed, hidesKeyboard: typing, room: room)
                    let tabs = TabActions.verticalBar(.tabs, zoomed: zoomed, hidesKeyboard: typing, room: room)
                    #expect(tabs == sidebar.map { $0 == .sidebar ? .sessions : $0 }, "\(note)")
                    #expect(!tabs.contains(.sidebar) && !sidebar.contains(.sessions), "\(note)")
                    if typing {
                        #expect(tabs.count <= room, "\(note): \(tabs)")
                        #expect(tabs.first == .hideKeyboard, "\(note)")
                    } else {
                        #expect(tabs.first == .sessions && sidebar.first == .sidebar, "\(note)")
                    }
                    // The strip beside the bar has no pane menu and no Unzoom of its own.
                    var i = busy(p.rootSize.width, bar: true, height: p.vertical == .compact ? 34 : 44)
                    i.zoomed = zoomed
                    let l = StripLayout(i)
                    #expect(!l.shows(.paneMenu) && !l.shows(.unzoom), "\(note)")
                    #expect(tabs.contains(.paneActions) && sidebar.contains(.paneActions), "\(note)")
                    if zoomed, !typing { #expect(tabs.contains(.unzoom), "\(note)") }
                    // The session chip is in the strip whether or not Sessions is in the bar.
                    #expect(l.shows(.session), "\(note)")
                }
            }
        }
        #expect(edges == ["leading", "trailing"])
    }
    #endif
}
