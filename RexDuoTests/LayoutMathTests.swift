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

    @Test func theRestCanvasTakesANewWidthAlsoWithTheKeyboardUp() {
        // The unfolded canvas with the keyboard down, then the phone folds with the keyboard up.
        let unfolded = CGSize(width: 606, height: 605)
        let foldedNow = CGSize(width: 382, height: 177)
        let rest = PaneLayout.restCanvas(kept: unfolded, now: foldedNow, keyboardUp: true)
        #expect(rest == CGSize(width: 382, height: 605), "the new width, the height from the keyboard down")
        // So the pane's grid has the folded columns and the rest rows, not the rows that show.
        let cell = CGSize(width: 6.6, height: 14.3)
        let grid = TerminalLayout.fitGrid(in: TerminalLayout.fitSize(bounds: foldedNow, rest: rest, alternateScreen: false), cell: cell)
        #expect(grid == TerminalLayout.fitGrid(in: CGSize(width: 382, height: 605), cell: cell))
        #expect(grid.cols < TerminalLayout.fitGrid(in: unfolded, cell: cell).cols)
    }

    @Test func theKeyboardAloneLeavesTheRestCanvasAsItWas() {
        let kept = CGSize(width: 382, height: 600)
        for h: CGFloat in [177, 250, 320] {
            #expect(PaneLayout.restCanvas(kept: kept, now: CGSize(width: 382, height: h), keyboardUp: true) == kept)
        }
        // Half a point of layout noise is no new width.
        #expect(PaneLayout.restCanvas(kept: kept, now: CGSize(width: 382.5, height: 177), keyboardUp: true) == kept)
        #expect(PaneLayout.restCanvas(kept: kept, now: CGSize(width: 382, height: 600), keyboardUp: false) == kept)
    }

    @Test func theRestCanvasFollowsTheCanvasWithTheKeyboardDownAndStaysUnmeasuredUntilThen() {
        #expect(PaneLayout.restCanvas(kept: CGSize(width: 606, height: 605), now: CGSize(width: 382, height: 600), keyboardUp: false)
                == CGSize(width: 382, height: 600))
        #expect(PaneLayout.restCanvas(kept: .zero, now: CGSize(width: 382, height: 177), keyboardUp: true) == .zero)
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
        // 6 pt around the pane, then 3 pt inside its rounded corners.
        #expect(PaneLayout.single(canvas: canvas, rounded: true) == CGSize(width: 782, height: 582))
        #expect(PaneLayout.single(canvas: .zero, rounded: false) == nil)
        // The lower half of a split is laid out and measured the same way.
        let lower = CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        let area = CGSize(width: 794, height: 594)
        let pane = PaneLayout.split(lower, in: area).size
        let clear = PaneLayout.clearance(radius: PaneLayout.splitRadius)
        #expect(PaneLayout.splitRest(lower, canvas: canvas) == CGSize(width: pane.width - 2 * clear, height: pane.height - 2 * clear))
        #expect(PaneLayout.splitRest(lower, canvas: canvas) == CGSize(width: 782, height: 285))
        #expect(PaneLayout.splitRest(lower, canvas: .zero) == nil)
    }

    @Test func cornerCellsClearARoundedPanesCurve() {
        for radius in [PaneLayout.singleRadius, PaneLayout.splitRadius] {
            let c = PaneLayout.clearance(radius: radius)
            // The grid's corner lies inside the corner's curve: no cell loses a corner.
            #expect(hypot(radius - c, radius - c) <= radius)
            #expect(c == 3)
        }
        #expect(PaneLayout.clearance(radius: 0) == 0)
    }

    /// iPhone 17 in landscape (insets 0, 62, 20, 62; a 34 pt title bar): the canvas is 750×348 and
    /// the rounded pane 738×336, exactly 24 rows of 14 pt. The last row lay on the pane's bottom
    /// edge, where the 10 pt corner cut a cursor there down to its top and right sides.
    @Test func theLastRowOfAnExactFitClearsTheBottomCorners() {
        let cell = CGSize(width: 7, height: 14)
        let canvas = CGSize(width: 750, height: 348)
        let pane = canvas.height - 2 * PaneLayout.roundedPadding
        let terminal = PaneLayout.single(canvas: canvas, rounded: true)!
        let rows = TerminalLayout.fitGrid(in: terminal, cell: cell).rows
        let clear = PaneLayout.clearance(radius: PaneLayout.singleRadius)
        // The grid starts `clear` down the pane and ends at least `clear` above its bottom.
        #expect(clear + CGFloat(rows) * cell.height <= pane - clear)
        #expect(rows == 23)
    }
}
