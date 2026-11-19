import CoreGraphics
import Testing
@testable import RexDuo

/// The board's layout for a number of agents and a window: it never needs to scroll.
struct BoardLayoutTests {
    /// The folded Duo inside its vertical bar and home indicator, upright and on its side.
    private let tall = CGSize(width: 382, height: 658)
    private let wide = CGSize(width: 594, height: 446)
    private let narrow = CGSize(width: 233, height: 658)

    private func decide(_ n: Int, _ size: CGSize, footer: Bool = false, scale: CGFloat = 1) -> BoardLayout {
        BoardLayout.decide(count: n, size: size, hasFooter: footer, typeScale: scale)
    }

    @Test func noAgentIsTheQuietBoard() {
        for size in [tall, wide, narrow] {
            let l = decide(0, size)
            #expect(l.style == .quiet)
            #expect(l.cells == 0)
            #expect(l.frames(in: BoardLayout.area(size, hasFooter: false)).isEmpty)
        }
    }

    @Test func oneAgentIsAHero() {
        for size in [tall, wide, narrow] {
            let l = decide(1, size)
            #expect(l.style == .hero)
            #expect((l.rows, l.cols, l.shown, l.more) == (1, 1, 1, 0))
        }
    }

    @Test func twoStackInATallWindowAndSitSideBySideInAWideOne() {
        #expect((decide(2, tall).rows, decide(2, tall).cols) == (2, 1))
        #expect((decide(2, wide).rows, decide(2, wide).cols) == (1, 2))
        #expect(decide(2, tall).style == .regular)
        #expect(decide(2, wide).style == .regular)
    }

    @Test func threeAreFullRowsWhereTheWindowIsTallEnough() {
        let t = decide(3, tall)
        #expect((t.rows, t.cols) == (3, 1))
        #expect(t.style == .regular)
        let w = decide(3, wide)
        #expect((w.rows, w.cols) == (2, 2))
        #expect(w.leadsWide, "the first tile takes the whole first row")
    }

    @Test func fourAreTwoByTwo() {
        for size in [tall, wide] {
            let l = decide(4, size)
            #expect((l.rows, l.cols, l.shown, l.more) == (2, 2, 4, 0))
            #expect(l.style == .regular)
            #expect(!l.leadsWide)
        }
    }

    @Test func fiveToEightAreCompactInTwoColumns() {
        for n in 5...8 {
            for size in [tall, wide] {
                let l = decide(n, size)
                #expect(l.cols == 2)
                #expect(l.rows == (n + 1) / 2)
                #expect(l.style == .compact)
                #expect((l.shown, l.more) == (n, 0))
                #expect(l.leadsWide == (n % 2 == 1))
            }
        }
        // Upright there is room for the message and the place; on its side for less.
        #expect(decide(8, tall).messageLines == 2)
        #expect(decide(8, tall).showsPlace)
        #expect(decide(8, wide).messageLines <= 1)
    }

    @Test func moreThanEightShowsSevenAndCountsTheRest() {
        for size in [tall, wide] {
            let l = decide(12, size)
            #expect((l.shown, l.more, l.cells) == (7, 5, 8))
            #expect(!l.leadsWide)
        }
        #expect((decide(9, tall).shown, decide(9, tall).more) == (7, 2))
        #expect((decide(40, tall).shown, decide(40, tall).more) == (7, 33))
    }

    @Test func aNarrowWindowHasOneColumn() {
        let l = decide(6, narrow)
        #expect((l.rows, l.cols) == (6, 1))
        #expect(l.style == .compact)
        #expect(decide(2, narrow).cols == 1)
        #expect(decide(4, narrow).cols == 1)
    }

    @Test func aShortWindowShowsFewerTilesAndNeverOverflows() {
        let short = CGSize(width: 594, height: 250)
        let l = decide(8, short)
        #expect(l.more > 0)
        #expect(l.shown + l.more == 8)
        #expect(l.cell.height >= BoardLayout.minCell)
    }

    @Test func largerTextShowsFewerTiles() {
        let size = CGSize(width: 594, height: 400)
        let plain = decide(8, size)
        let large = decide(8, size, scale: 1.25)
        #expect(plain.more == 0)
        #expect(large.more > 0)
        #expect(large.cell.height >= BoardLayout.minCell * 1.25)
    }

    /// Every cell lies inside the tile area and no two overlap, for every count and size.
    @Test func cellsStayInsideTheAreaAndNeverOverlap() {
        for size in [tall, wide, narrow, CGSize(width: 475, height: 669), CGSize(width: 402, height: 778), CGSize(width: 594, height: 250)] {
            for footer in [false, true] {
                for n in 1...14 {
                    let l = decide(n, size, footer: footer)
                    let area = BoardLayout.area(size, hasFooter: footer)
                    let frames = l.frames(in: area)
                    #expect(frames.count == l.cells)
                    #expect(l.cells <= BoardLayout.most)
                    for (i, f) in frames.enumerated() {
                        #expect(area.insetBy(dx: -0.01, dy: -0.01).contains(f), "\(n) in \(size): cell \(i)")
                        #expect(f.height >= BoardLayout.minCell - 0.01, "\(n) in \(size): cell \(i)")
                        for g in frames[(i + 1)...] {
                            #expect(!f.insetBy(dx: 0.01, dy: 0.01).intersects(g), "\(n) in \(size)")
                        }
                    }
                }
            }
        }
    }

    /// At the largest text the header is half again as tall, and the tiles start under it.
    @Test func theHeaderGrowsWithTheTextAndTheTilesStartBelowIt() {
        #expect(BoardLayout.header(tall) == 84)
        #expect(BoardLayout.header(tall, headScale: 1.5) == 126)
        #expect(BoardLayout.header(wide) == 68)
        #expect(BoardLayout.header(wide, headScale: 1.5) == 102)
        for size in [tall, wide, narrow] {
            for n in 1...12 {
                for footer in [false, true] {
                    let l = BoardLayout.decide(count: n, size: size, hasFooter: footer, typeScale: 1.25, headScale: 1.5)
                    let area = BoardLayout.area(size, hasFooter: footer, typeScale: 1.25, headScale: 1.5)
                    let headerBottom = BoardLayout.pad + BoardLayout.header(size, headScale: 1.5)
                    #expect(l.headerHeight == BoardLayout.header(size, headScale: 1.5))
                    #expect(area.minY == headerBottom)
                    let frames = l.frames(in: area)
                    #expect(frames.count == l.cells)
                    for f in frames {
                        #expect(f.minY >= headerBottom - 0.01, "\(n) in \(size): a tile under the header")
                        #expect(f.maxY <= size.height - BoardLayout.pad - l.footerHeight + 0.01, "\(n) in \(size): a tile over the footer")
                        #expect(f.height >= BoardLayout.minCell * 1.25 - 0.01 || l.cells == 1, "\(n) in \(size)")
                    }
                }
            }
        }
        // The taller header takes room: fewer tiles than at the standard size.
        let plain = BoardLayout.decide(count: 8, size: wide, hasFooter: false)
        let large = BoardLayout.decide(count: 8, size: wide, hasFooter: false, typeScale: 1.25, headScale: 1.5)
        #expect(plain.more == 0)
        #expect(large.more > 0)
        #expect(large.shown + large.more == 8)
    }

    @Test func theFooterTakesRoomFromTheTiles() {
        #expect(BoardLayout.area(tall, hasFooter: true).height == BoardLayout.area(tall, hasFooter: false).height - 22)
        #expect(BoardLayout.area(tall, hasFooter: true).minY == BoardLayout.area(tall, hasFooter: false).minY)
    }
}
