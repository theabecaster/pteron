import CoreGraphics
import Testing
@testable import RexDuo

struct TerminalLayoutTests {
    @Test func fitsWholeCells() {
        let g = TerminalLayout.fitGrid(in: CGSize(width: 400, height: 300), cell: CGSize(width: 7, height: 15))
        #expect(g.cols == 57)
        #expect(g.rows == 20)
    }

    @Test func exactMultipleKeepsTheLastCell() {
        // 30 cells of 6.7 pt can measure a hair under 201 in floating point.
        let g = TerminalLayout.fitGrid(in: CGSize(width: 6.7 * 30, height: 13.1 * 10), cell: CGSize(width: 6.7, height: 13.1))
        #expect(g.cols == 30)
        #expect(g.rows == 10)
    }

    @Test func neverBelowTheFloor() {
        let g = TerminalLayout.fitGrid(in: CGSize(width: 20, height: 10), cell: CGSize(width: 7, height: 15))
        #expect(g.cols == TerminalLayout.minCols)
        #expect(g.rows == TerminalLayout.minRows)
    }

    @Test func zeroCellIsSafe() {
        let g = TerminalLayout.fitGrid(in: CGSize(width: 100, height: 100), cell: .zero)
        #expect(g.cols == 100 && g.rows == 100)
    }
}

struct SplitGeometryTests {
    let canvas = CGSize(width: 1000, height: 500)

    @Test func sideBySideDivider() {
        let g = SplitGeometry(rect: CGRect(x: 0, y: 0, width: 1, height: 1), ratio: 0.6, direction: "horizontal", canvas: canvas)
        #expect(g.sideBySide)
        #expect(g.origin == CGPoint(x: 600, y: 0))
        #expect(g.length == 500)
        #expect(g.span == 1000)
    }

    @Test func stackedDividerInANestedRect() {
        let g = SplitGeometry(rect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1), ratio: 0.25, direction: "vertical", canvas: canvas)
        #expect(!g.sideBySide)
        #expect(g.origin == CGPoint(x: 500, y: 125))
        #expect(g.length == 500)
        #expect(g.span == 500)
    }

    @Test func snapsToHalfNearTheMiddle() {
        let g = SplitGeometry(rect: CGRect(x: 0, y: 0, width: 1, height: 1), ratio: 0.4, direction: "horizontal", canvas: canvas)
        let near = g.detent(95)  // 0.4 + 0.095 = 0.495
        #expect(near.snapped)
        #expect(abs(near.offset - 100) < 1e-9)
        let far = g.detent(50)
        #expect(!far.snapped)
        #expect(far.offset == 50)
    }

    @Test func ratioAfterDragIsClamped() {
        let g = SplitGeometry(rect: CGRect(x: 0, y: 0, width: 1, height: 1), ratio: 0.5, direction: "horizontal", canvas: canvas)
        #expect(abs(g.ratio(after: 100) - 0.6) < 1e-9)
        #expect(g.ratio(after: -2000) == 0.05)
        #expect(g.ratio(after: 2000) == 0.95)
    }
}

struct KeyboardCoverLayoutTests {
    private let rest = CGSize(width: 400, height: 600)

    @Test func theGridFitsThePaneAsItIsWithTheKeyboardDown() {
        // The keyboard took 300 pt of the pane: the grid still fits the 600.
        let s = TerminalLayout.fitSize(bounds: CGSize(width: 400, height: 300), rest: rest, alternateScreen: false)
        #expect(s == rest)
        let cell = CGSize(width: 7, height: 15)
        #expect(TerminalLayout.fitGrid(in: s, cell: cell) == TerminalLayout.fitGrid(in: rest, cell: cell))
    }

    @Test func theAlternateScreenFitsWhatShows() {
        let bounds = CGSize(width: 400, height: 300)
        #expect(TerminalLayout.fitSize(bounds: bounds, rest: rest, alternateScreen: true) == bounds)
    }

    @Test func aRestSizeOfAnotherWidthOrNoneIsNotUsed() {
        // After a rotation or a fold the remembered size is another pane's.
        let bounds = CGSize(width: 700, height: 200)
        #expect(TerminalLayout.fitSize(bounds: bounds, rest: rest, alternateScreen: false) == bounds)
        #expect(TerminalLayout.fitSize(bounds: bounds, rest: nil, alternateScreen: false) == bounds)
    }

    @Test func aPaneTallerThanItsRestSizeFitsItself() {
        // The title bar stepped aside: the pane has more room than with the keyboard down.
        let bounds = CGSize(width: 400, height: 640)
        #expect(TerminalLayout.fitSize(bounds: bounds, rest: rest, alternateScreen: false) == bounds)
    }

    @Test func coverIsWhatThePaneHidesOfTheTerminal() {
        #expect(TerminalLayout.cover(terminal: 574, pane: 291) == 283)
        // A grid that fits its pane can be a point taller than it.
        #expect(TerminalLayout.cover(terminal: 574.5, pane: 573.3) == 0)
        #expect(TerminalLayout.cover(terminal: 300, pane: 576) == 0)
    }

    @Test func paneSizesWithTheKeyboardDown() {
        let canvas = CGSize(width: 800, height: 600)
        #expect(PaneLayout.single(canvas: canvas, rounded: false) == canvas)
        #expect(PaneLayout.single(canvas: canvas, rounded: true) == CGSize(width: 788, height: 588))
        #expect(PaneLayout.single(canvas: .zero, rounded: false) == nil)
        // The lower half of a split is laid out and measured the same way.
        let lower = CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        let area = CGSize(width: 794, height: 594)
        #expect(PaneLayout.splitRest(lower, canvas: canvas) == PaneLayout.split(lower, in: area).size)
        #expect(PaneLayout.splitRest(lower, canvas: canvas) == CGSize(width: 788, height: 291))
        #expect(PaneLayout.splitRest(lower, canvas: .zero) == nil)
    }
}
