import CoreGraphics
import Testing
@testable import Pteron

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

    @Test func theRestCanvasIsTheCanvasWithTheKeyboardsRoomGivenBack() {
        // The keyboard took 285 pt of a 576 pt canvas: with it down the canvas is 576 again.
        #expect(PaneLayout.restCanvas(now: CGSize(width: 382, height: 291), room: 285) == CGSize(width: 382, height: 576))
        #expect(PaneLayout.restCanvas(now: CGSize(width: 382, height: 576), room: 0) == CGSize(width: 382, height: 576))
        // The key bar alone (a hardware keyboard) takes its room: the grid fits above it.
        #expect(PaneLayout.restCanvas(now: CGSize(width: 382, height: 556), room: 20) == CGSize(width: 382, height: 556))
        // Nothing measured yet stays unmeasured.
        #expect(PaneLayout.restCanvas(now: .zero, room: 285) == .zero)
    }

    @MainActor @Test func composesCardStaysInTheRestCanvas() {
        // iPhone 17: 744 pt with the keyboard down. Up with Compose's card (120 pt of its 468 pt):
        // the grid fits above the card, and closing Compose gives the same 744 pt as before.
        let card = ComposeCard.height(compact: false) + KeyBar.cardGap
        let open = PaneLayout.restCanvas(now: CGSize(width: 402, height: 276), room: 468, card: card)
        #expect(open == CGSize(width: 402, height: 744 - card))
        #expect(PaneLayout.restCanvas(now: CGSize(width: 402, height: 396), room: 348) == CGSize(width: 402, height: 744))
        // The key bar alone (a hardware keyboard) with the card: the grid fits above both.
        #expect(PaneLayout.restCanvas(now: CGSize(width: 402, height: 570), room: 54 + card, card: card)
                == CGSize(width: 402, height: 570))
    }

    @MainActor @Test func aCardThatLeavesTooFewRowsCoversTheGridInstead() {
        let card = ComposeCard.height(compact: true) + KeyBar.cardGap
        let floor = PaneLayout.composeFloor(fontSize: 14)
        #expect(floor == 3 * 14 * 1.25)
        // An iPhone on its side, 372 pt with the keyboard down. With large text the card leaves
        // 40 pt, under the floor: the grid keeps its size without the card.
        #expect(PaneLayout.restCanvas(now: CGSize(width: 489, height: 40), room: 246 + card, card: card,
                                      cardFloor: floor) == CGSize(width: 489, height: 40 + 246 + card))
        // 58 pt is enough: the grid fits above the card.
        #expect(PaneLayout.restCanvas(now: CGSize(width: 489, height: 58), room: 246 + card, card: card,
                                      cardFloor: floor) == CGSize(width: 489, height: 58 + 246))
        // The key bar alone with the card, too short: the grid fits above the bar, under the card.
        #expect(PaneLayout.restCanvas(now: CGSize(width: 489, height: 40), room: 42 + card, card: card,
                                      cardFloor: floor) == CGSize(width: 489, height: 40 + card))
        // Compose closed: no floor applies.
        #expect(PaneLayout.restCanvas(now: CGSize(width: 489, height: 30), room: 246, cardFloor: floor)
                == CGSize(width: 489, height: 276))
    }

    @Test func aFoldWithTheKeyboardUpGivesTheNewPosturesCanvasNotTheOldOnesHeight() {
        // Landscape, keyboard down: 594x374. The phone turns to portrait with the keyboard up: the
        // canvas is 382x291 with 285 pt of keyboard. Its rest is portrait's 576, not landscape's 374
        // (which would size the panes for 26 rows, then resize them again when the keyboard went).
        let rest = PaneLayout.restCanvas(now: CGSize(width: 382, height: 291), room: 285)
        #expect(rest == CGSize(width: 382, height: 576))
        let cell = CGSize(width: 6.6, height: 14)
        let grid = TerminalLayout.fitGrid(in: TerminalLayout.fitSize(bounds: CGSize(width: 382, height: 291), rest: rest,
                                                                     alternateScreen: false), cell: cell)
        #expect(grid == TerminalLayout.fitGrid(in: CGSize(width: 382, height: 576), cell: cell),
                "the rows of the pane with the keyboard down, so its going down resizes nothing")
    }

    @Test func aHeaderThatSteppedAsideIsNotPartOfTheRestCanvas() {
        // A short window: the 34 pt strip steps aside while the keyboard is up.
        #expect(PaneLayout.restCanvas(now: CGSize(width: 594, height: 241), room: 167, header: 34)
                == CGSize(width: 594, height: 374))
        // The keyboard's room and the strip may change in either order: no layout in between
        // gives another rest canvas.
        #expect(PaneLayout.restCanvas(now: CGSize(width: 594, height: 408), room: 0, header: 34)
                == CGSize(width: 594, height: 374), "the strip stepped aside, the root not padded yet")
        #expect(PaneLayout.restCanvas(now: CGSize(width: 594, height: 207), room: 167)
                == CGSize(width: 594, height: 374), "the root padded, the strip still there")
    }

    @Test func tabletopKeepsThePanesAboveTheCrease() {
        // The keyboard sits below the crease and takes nothing from the panes above it.
        #expect(PaneLayout.restCanvas(now: CGSize(width: 669, height: 411), room: 300, limit: 411)
                == CGSize(width: 669, height: 411))
        // A keyboard tall enough to reach the region above the crease gives back only that much.
        #expect(PaneLayout.restCanvas(now: CGSize(width: 669, height: 380), room: 360, limit: 411)
                == CGSize(width: 669, height: 411))
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

    @Test func aGridAResizeWillReplaceIsCutNotCovered() {
        // The keyboard over a pane whose grid fits it with the keyboard down: covered as before.
        #expect(TerminalLayout.cover(terminal: 574, fits: 574, pane: 291) == 283)
        // A rotation: the old 574 pt grid in a pane that now fits 364 pt, the resize on its way.
        // Nothing is covered, so the rows aren't shifted up, then back when the resize lands.
        #expect(TerminalLayout.cover(terminal: 574, fits: 364, pane: 374) == 0)
        // The same with the keyboard up: only what it hides of the grid that fits.
        #expect(TerminalLayout.cover(terminal: 574, fits: 364, pane: 207) == 157)
        // A grid smaller than the one that fits (a resize to a bigger one on its way).
        #expect(TerminalLayout.cover(terminal: 300, fits: 574, pane: 576) == 0)
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
