import XCTest
@testable import RexConnect

/// The selection UI (docs/selection.md): the gesture's state machine, where the haptics fire,
/// the handles' geometry, word and line taps, and when copy-on-select happens. The controller
/// tests run it against a real Ghostty view, with recorders for haptics, loupe and clipboard.
final class SelectionUITests: XCTestCase {
    private typealias Effects = SelectionSession.Effects

    private func cell(_ col: Int, _ row: Int) -> TerminalGridCell { TerminalGridCell(col: col, row: row) }

    // MARK: State machine

    func testLongPressDragLiftAdjustClear() {
        var s = SelectionSession()
        XCTAssertEqual(s.touchDown(), .prepare, "the Taptic Engine is awake before the press is recognized")
        XCTAssertEqual(s.phase, .idle)

        let began = s.pressBegan(selected: true, cell: cell(3, 5))
        XCTAssertEqual(s.phase, .pressing)
        XCTAssertTrue(s.isTracking)
        XCTAssertEqual(began, [.hideMenu, .hideHandles, .showLoupe, .hapticStart, .prepare])

        XCTAssertEqual(s.pressMoved(selected: true, cell: cell(6, 5), now: 1), .moveLoupe, "same row: the loupe follows, nothing else")
        XCTAssertEqual(s.pressMoved(selected: true, cell: cell(6, 6), now: 2), [.moveLoupe, .hapticTick, .prepare])

        let lifted = s.pressEnded(selected: true)
        XCTAssertEqual(lifted, [.hideLoupe, .copy, .showHandles, .showMenu])
        XCTAssertEqual(s.phase, .selected)
        XCTAssertFalse(s.isTracking)

        XCTAssertEqual(s.handleGrabbed(.end, cell: cell(6, 6)), [.hideMenu, .hapticGrab, .showLoupe, .prepare])
        XCTAssertEqual(s.phase, .adjusting(.end))
        XCTAssertTrue(s.isTracking)
        XCTAssertEqual(s.handleMoved(cell: cell(9, 6), now: 3), [.moveLoupe, .showHandles])
        XCTAssertEqual(s.handleMoved(cell: cell(9, 8), now: 4), [.moveLoupe, .showHandles, .hapticTick, .prepare])
        XCTAssertEqual(s.handleReleased(selected: true), [.hideLoupe, .showHandles, .showMenu, .copy])
        XCTAssertEqual(s.phase, .selected)

        XCTAssertEqual(s.cleared(), [.hideLoupe, .hideHandles, .hideMenu])
        XCTAssertEqual(s.phase, .idle)
        XCTAssertEqual(s.cleared(), [], "clearing nothing does nothing")
    }

    func testAPressOnBlankSpaceStartsWhenTheDragFirstCoversACell() {
        var s = SelectionSession()
        let began = s.pressBegan(selected: false, cell: cell(0, 0))
        XCTAssertTrue(began.contains(.hapticGrab))
        XCTAssertFalse(began.contains(.hapticStart), "nothing is highlighted yet")
        XCTAssertEqual(s.pressMoved(selected: false, cell: cell(0, 0), now: 1), .moveLoupe)
        XCTAssertEqual(s.pressMoved(selected: true, cell: cell(1, 0), now: 2), [.moveLoupe, .hapticStart, .prepare])
        XCTAssertEqual(s.pressMoved(selected: true, cell: cell(2, 0), now: 3), .moveLoupe, "the start plays once")
    }

    func testAPressThatSelectsNothingOffersTheMenuAlone() {
        var s = SelectionSession()
        _ = s.pressBegan(selected: false, cell: cell(0, 0))
        XCTAssertEqual(s.pressEnded(selected: false), [.hideLoupe, .hideHandles, .showMenu])
        XCTAssertEqual(s.phase, .idle)
    }

    func testACancelledPressKeepsTheSelectionWithoutCopying() {
        var s = SelectionSession()
        _ = s.pressBegan(selected: true, cell: cell(0, 0))
        XCTAssertEqual(s.pressCancelled(selected: true), [.hideLoupe, .showHandles])
        XCTAssertEqual(s.phase, .selected)
    }

    func testEventsOutOfPlaceDoNothing() {
        var s = SelectionSession()
        XCTAssertEqual(s.pressMoved(selected: true, cell: cell(0, 0), now: 0), [])
        XCTAssertEqual(s.pressEnded(selected: true), [])
        XCTAssertEqual(s.handleGrabbed(.start, cell: nil), [], "no handle without a standing selection")
        XCTAssertEqual(s.handleMoved(cell: cell(1, 1), now: 0), [])
        XCTAssertEqual(s.handleReleased(selected: true), [])
        XCTAssertEqual(s.phase, .idle)
    }

    func testRowTicksAreRateLimited() {
        var s = SelectionSession()
        _ = s.pressBegan(selected: true, cell: cell(0, 0))
        XCTAssertTrue(s.pressMoved(selected: true, cell: cell(0, 1), now: 1.00).contains(.hapticTick))
        XCTAssertFalse(s.pressMoved(selected: true, cell: cell(0, 2), now: 1.02).contains(.hapticTick), "20 ms after the last")
        XCTAssertFalse(s.pressMoved(selected: true, cell: cell(0, 3), now: 1.04).contains(.hapticTick))
        XCTAssertTrue(s.pressMoved(selected: true, cell: cell(0, 4), now: 1.00 + SelectionSession.tickInterval).contains(.hapticTick))
        XCTAssertFalse(s.pressMoved(selected: true, cell: cell(5, 4), now: 9).contains(.hapticTick), "a new column is no tick")
    }

    func testAGrabThatMovesNothingDoesNotCopyAgain() {
        var s = SelectionSession()
        _ = s.tapSelected(true)
        _ = s.handleGrabbed(.start, cell: cell(2, 2))
        _ = s.handleMoved(cell: cell(2, 2), now: 1)
        XCTAssertEqual(s.handleReleased(selected: true), [.hideLoupe, .showHandles, .showMenu])
    }

    func testTapsAndSelectAll() {
        var s = SelectionSession()
        XCTAssertEqual(s.tapSelected(true), [.copy, .showHandles, .showMenu])
        XCTAssertEqual(s.phase, .selected)
        XCTAssertEqual(s.tapSelected(false), [.hideHandles, .hideMenu])
        XCTAssertEqual(s.phase, .idle)
        XCTAssertEqual(s.selectedAll(true, showsMenu: false), .showHandles, "Select All copies nothing by itself")
        XCTAssertEqual(s.selectedAll(true, showsMenu: true), [.showHandles, .showMenu])
        XCTAssertEqual(s.phase, .selected)
    }

    func testTapCounter() {
        var t = SelectionTapCounter()
        let p = CGPoint(x: 100, y: 100)
        XCTAssertEqual(t.tap(at: p, now: 0), 1)
        XCTAssertEqual(t.tap(at: CGPoint(x: 110, y: 95), now: 0.2), 2)
        XCTAssertEqual(t.tap(at: p, now: 0.4), 3)
        XCTAssertEqual(t.tap(at: p, now: 0.5), 1, "a fourth tap starts over")
        XCTAssertEqual(t.tap(at: p, now: 1.5), 1, "too late")
        XCTAssertEqual(t.tap(at: CGPoint(x: 200, y: 100), now: 1.6), 1, "too far")
        XCTAssertEqual(t.tap(at: CGPoint(x: 200, y: 100), now: 1.7), 2)
        t.reset()
        XCTAssertEqual(t.tap(at: CGPoint(x: 200, y: 100), now: 1.8), 1)
    }

    func testRules() {
        let visible = CGRect(x: 0, y: 100, width: 300, height: 400)
        XCTAssertEqual(SelectionRules.edge(of: CGPoint(x: 5, y: 110), in: visible), -1)
        XCTAssertEqual(SelectionRules.edge(of: CGPoint(x: 5, y: 90), in: visible), -1, "past the edge")
        XCTAssertEqual(SelectionRules.edge(of: CGPoint(x: 5, y: 300), in: visible), 0)
        XCTAssertEqual(SelectionRules.edge(of: CGPoint(x: 5, y: 490), in: visible), 1)

        func paste(_ tap: TerminalGridCell?, focused: Bool = true, cleared: Bool = false, program: Bool = false, menu: Bool = false) -> Bool {
            SelectionRules.tapShowsPaste(tap: tap, cursor: cell(10, 50), focused: focused, clearedSelection: cleared,
                                         tapsGoToProgram: program, menuVisible: menu)
        }
        XCTAssertTrue(paste(cell(10, 50)))
        XCTAssertTrue(paste(cell(13, 51)))
        XCTAssertFalse(paste(cell(14, 50)), "4 columns away")
        XCTAssertFalse(paste(cell(10, 52)), "2 rows away")
        XCTAssertFalse(paste(cell(10, 50), focused: false), "the first tap only focuses")
        XCTAssertFalse(paste(cell(10, 50), cleared: true), "a tap that cleared a selection shows no menu")
        XCTAssertFalse(paste(cell(10, 50), program: true), "a click for the program")
        XCTAssertFalse(paste(cell(10, 50), menu: true), "a tap hides a menu that is up")
        XCTAssertFalse(paste(nil))
    }

    // MARK: Handle geometry

    func testHandlesSitOnTheSelectionsEdges() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        let first = CGRect(x: 60, y: 100, width: 6, height: 12), last = CGRect(x: 120, y: 136, width: 6, height: 12)
        let layout = SelectionHandleLayout(start: first, end: last, in: bounds)
        let d = SelectionHandleLayout.knobDiameter
        XCTAssertEqual(layout.start?.bar, CGRect(x: 59, y: 100, width: 2, height: 12), "on the first cell's left edge, a row high")
        XCTAssertEqual(layout.start?.knob, CGRect(x: 60 - d / 2, y: 100 - d, width: d, height: d), "the start's knob is above its row")
        XCTAssertEqual(layout.end?.bar, CGRect(x: 125, y: 136, width: 2, height: 12), "on the last cell's right edge")
        XCTAssertEqual(layout.end?.knob, CGRect(x: 126 - d / 2, y: 148, width: d, height: d), "the end's knob is below its row")
        XCTAssertEqual(layout.start?.cell, CGPoint(x: 63, y: 106))
        XCTAssertEqual(layout.end?.cell, CGPoint(x: 123, y: 142))
    }

    func testAKnobThatWouldLeaveThePaneFlips() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        let layout = SelectionHandleLayout(start: CGRect(x: 0, y: 0, width: 6, height: 12),
                                           end: CGRect(x: 294, y: 388, width: 6, height: 12), in: bounds)
        XCTAssertEqual(layout.start?.knob.minY, 12, "under the first row")
        XCTAssertEqual(layout.end?.knob.maxY, 388, "over the last row")
    }

    func testAnEndOutOfViewHasNoHandle() {
        let layout = SelectionHandleLayout(start: nil, end: CGRect(x: 10, y: 10, width: 6, height: 12), in: CGRect(x: 0, y: 0, width: 100, height: 100))
        XCTAssertNil(layout.start)
        XCTAssertNotNil(layout.end)
        XCTAssertEqual(layout.handle(at: CGPoint(x: 16, y: 28)), .end)
    }

    func testHandleHitTargetsAreBigAndTheNearerOneWins() {
        let bounds = CGRect(x: 0, y: 0, width: 300, height: 400)
        // A three-letter word at 10 pt: the handles are 18 pt apart.
        let layout = SelectionHandleLayout(start: CGRect(x: 100, y: 200, width: 6, height: 12),
                                           end: CGRect(x: 112, y: 200, width: 6, height: 12), in: bounds)
        XCTAssertEqual(layout.handle(at: CGPoint(x: 100, y: 194)), .start, "on the start's knob")
        XCTAssertEqual(layout.handle(at: CGPoint(x: 118, y: 218)), .end, "on the end's knob")
        XCTAssertEqual(layout.handle(at: CGPoint(x: 80, y: 194)), .start, "20 pt off the knob still takes it")
        XCTAssertEqual(layout.handle(at: CGPoint(x: 138, y: 218)), .end)
        XCTAssertEqual(layout.handle(at: CGPoint(x: 109, y: 190)), .start, "above the word: the start")
        XCTAssertEqual(layout.handle(at: CGPoint(x: 109, y: 222)), .end, "below the word: the end")
        XCTAssertNil(layout.handle(at: CGPoint(x: 100, y: 150)), "50 pt away is the terminal's")
        XCTAssertGreaterThanOrEqual(SelectionHandleLayout.hitRadius * 2, 44, "Apple's minimum target")
    }

    // MARK: The controller on a Ghostty view

    @MainActor
    private final class Recorder: SelectionFeedback, SelectionLoupe {
        var played: [SelectionHaptic] = []
        var prepares = 0
        /// How many prepares had happened before each haptic played.
        var preparedBefore: [Int] = []
        var loupe: [String] = []
        var copied: [String] = []
        var shimmers = 0
        var menus: [CGRect] = []
        var dismissals = 0
        var tracking: [Bool] = []

        func prepare() { prepares += 1 }
        func play(_ haptic: SelectionHaptic) {
            played.append(haptic)
            preparedBefore.append(prepares)
        }
        func begin(at point: CGPoint, in view: UIView) { loupe.append("begin") }
        func move(to point: CGPoint, caret: CGRect?) { loupe.append(caret == nil ? "move" : "move+caret") }
        func end() { loupe.append("end") }
    }

    @MainActor
    private struct Rig {
        let host: UIView
        let view: GhosttyTerminalView
        let ui: TerminalSelectionController
        let rec: Recorder
        let time: Clock

        final class Clock { var now: TimeInterval = 100 }

        func point(_ col: Int, _ row: Int) -> CGPoint {
            let cell = view.cellSize
            return CGPoint(x: (CGFloat(col) + 0.5) * cell.width, y: (CGFloat(row) + 0.5) * cell.height)
        }
    }

    @MainActor
    private func makeRig(_ text: String, cols: Int = 30, rows: Int = 12) -> Rig {
        let view = GhosttyTerminalView(frame: .zero, fontSize: 12, cols: cols, rows: rows)
        let cell = view.cellSize
        // Room around the grid, so no row is at an edge of the host unless a test puts it there.
        let host = UIView(frame: CGRect(x: 0, y: 0, width: CGFloat(cols) * cell.width, height: CGFloat(rows) * cell.height))
        view.frame = host.bounds
        host.addSubview(view)
        view.feed(text: text)
        view.core.sync()
        let rec = Recorder(), time = Rig.Clock()
        let ui = TerminalSelectionController(term: view, feedback: rec, loupe: rec)
        ui.install(in: host, above: view)
        ui.clock = { time.now }
        ui.copyText = { rec.copied.append($0) }
        ui.playShimmer = { _ in rec.shimmers += 1 }
        ui.presentMenu = { rec.menus.append($0) }
        ui.dismissMenu = { rec.dismissals += 1 }
        ui.trackingChanged = { rec.tracking.append($0) }
        return Rig(host: host, view: view, ui: ui, rec: rec, time: time)
    }

    private static let lines = (0..<8).map { "line\($0) alpha beta gamma" }.joined(separator: "\r\n")

    @MainActor
    func testHapticsFireAtTheStartOnRowsOnCopyAndAfterAHandleAdjustment() {
        let r = makeRig(Self.lines)
        r.ui.touchDown()
        XCTAssertEqual(r.rec.prepares, 1, "prepared at touch down, before the press is recognized")
        XCTAssertEqual(r.rec.played, [])

        r.ui.pressBegan(at: r.point(7, 2))
        XCTAssertEqual(r.rec.played, [.start], "the moment the long press selects")
        XCTAssertEqual(r.view.selectedText, "alpha")
        XCTAssertEqual(r.rec.preparedBefore, [1])
        XCTAssertEqual(r.rec.prepares, 2, "and prepared again for what follows")

        r.time.now += 1
        r.ui.pressMoved(to: r.point(9, 2))
        XCTAssertEqual(r.rec.played, [.start], "moving along the row is silent")
        r.time.now += 1
        r.ui.pressMoved(to: r.point(9, 3))
        XCTAssertEqual(r.rec.played, [.start, .tick], "a new row ticks")
        r.time.now += 0.01
        r.ui.pressMoved(to: r.point(9, 4))
        XCTAssertEqual(r.rec.played, [.start, .tick], "10 ms later: rate limited")
        r.time.now += 1
        r.ui.pressMoved(to: r.point(9, 5))
        XCTAssertEqual(r.rec.played, [.start, .tick, .tick])
        XCTAssertEqual(r.rec.copied, [], "nothing is copied while the finger is down")

        let prepared = r.rec.prepares
        r.ui.pressEnded(at: r.point(9, 5))
        XCTAssertEqual(r.rec.played, [.start, .tick, .tick, .copy], "the copy confirmation, a different haptic from the start")
        XCTAssertGreaterThanOrEqual(prepared, 4, "the copy generator was prepared during the drag")
        XCTAssertEqual(r.rec.copied.count, 1)
        XCTAssertEqual(r.rec.shimmers, 1, "in step with the shimmer")

        // Take the end handle and pull it a row down.
        guard let end = r.ui.handles.layout.end else { return XCTFail("no end handle") }
        r.time.now += 1
        XCTAssertTrue(r.ui.handleBegan(at: CGPoint(x: end.knob.midX, y: end.knob.midY)))
        XCTAssertEqual(r.rec.played.last, .grab)
        let offset = r.ui.grabOffset
        let to = r.point(12, 6)
        r.time.now += 1
        r.ui.handleMoved(to: CGPoint(x: to.x + offset.width, y: to.y + offset.height))
        XCTAssertEqual(r.rec.played.last, .tick)
        r.ui.handleEnded(cancelled: false)
        XCTAssertEqual(r.rec.played, [.start, .tick, .tick, .copy, .grab, .tick, .copy], "copied again after the adjustment")
        XCTAssertEqual(r.rec.copied.count, 2)
        XCTAssertEqual(r.rec.shimmers, 2)
        XCTAssertTrue(r.rec.copied[1].hasPrefix("alpha"), "the same start")
        XCTAssertGreaterThan(r.rec.copied[1].count, r.rec.copied[0].count, "a longer selection")
    }

    @MainActor
    func testCopyOnSelectHappensOnLiftAndAfterAnAdjustmentThatChangedSomething() {
        let r = makeRig(Self.lines)
        r.ui.pressBegan(at: r.point(7, 1))
        XCTAssertEqual(r.rec.copied, [])
        XCTAssertEqual(r.rec.menus.count, 0)
        r.ui.pressEnded(at: r.point(7, 1))
        XCTAssertEqual(r.rec.copied, ["alpha"], "on lift")
        XCTAssertEqual(r.rec.menus.count, 1, "the menu comes with it")
        XCTAssertEqual(r.ui.session.phase, .selected)

        // A grab that moves nothing: the menu returns, nothing is copied again.
        guard let start = r.ui.handles.layout.start else { return XCTFail("no start handle") }
        let knob = CGPoint(x: start.knob.midX, y: start.knob.midY)
        XCTAssertTrue(r.ui.handleBegan(at: knob))
        XCTAssertEqual(r.rec.dismissals, 2, "the menu hides while a handle is held (and hid when the press began)")
        r.ui.handleMoved(to: knob)
        r.ui.handleEnded(cancelled: false)
        XCTAssertEqual(r.rec.copied, ["alpha"])
        XCTAssertEqual(r.view.selectedText, "alpha", "taking a handle doesn't move it")
        XCTAssertEqual(r.rec.menus.count, 2)

        // Pull the start back to the line's first word.
        XCTAssertTrue(r.ui.handleBegan(at: knob))
        let offset = r.ui.grabOffset, to = r.point(0, 1)
        r.ui.handleMoved(to: CGPoint(x: to.x + offset.width, y: to.y + offset.height))
        XCTAssertEqual(r.rec.copied, ["alpha"], "not while the handle is held")
        r.ui.handleEnded(cancelled: false)
        XCTAssertEqual(r.rec.copied, ["alpha", "line1 alpha"], "after the adjustment")

        // Select All copies nothing by itself.
        r.ui.selectAll(showsMenu: false)
        XCTAssertEqual(r.rec.copied.count, 2)
        XCTAssertEqual(r.ui.session.phase, .selected)

        r.view.clearSelectedRange()
        r.ui.selectionCleared()
        XCTAssertEqual(r.ui.session.phase, .idle)
        XCTAssertFalse(r.ui.handles.showsHandles)
    }

    @MainActor
    func testHandlesFollowTheSelectionAndTheLoupeTheGesture() {
        let r = makeRig(Self.lines)
        XCTAssertFalse(r.ui.handles.showsHandles, "no chrome without a selection")
        r.ui.pressBegan(at: r.point(7, 2))
        XCTAssertFalse(r.ui.handles.showsHandles, "no handles under the finger")
        XCTAssertEqual(r.rec.loupe, ["begin", "move+caret"], "the loupe is up as soon as the press selects")
        XCTAssertEqual(r.rec.tracking, [true])
        r.ui.pressMoved(to: r.point(15, 3))
        XCTAssertEqual(r.rec.loupe.last, "move+caret")
        r.ui.pressEnded(at: r.point(15, 3))
        XCTAssertEqual(r.rec.loupe.last, "end")
        XCTAssertEqual(r.rec.tracking, [true, false])

        // "alpha" starts at column 6 of row 2; the drag ended on column 15 of row 3.
        let layout = r.ui.handles.layout
        let first = r.view.viewportRect(row: 2, columns: 6..<7), last = r.view.viewportRect(row: 3, columns: 15..<16)
        XCTAssertEqual(layout.start?.bar.midX ?? 0, first.minX, accuracy: 0.01)
        XCTAssertEqual(layout.start?.bar.minY ?? 0, first.minY, accuracy: 0.01)
        XCTAssertEqual(layout.end?.bar.midX ?? 0, last.maxX, accuracy: 0.01)
        XCTAssertEqual(layout.end?.bar.maxY ?? 0, last.maxY, accuracy: 0.01)

        // The overlay takes touches on a handle and nothing else.
        XCTAssertTrue(r.ui.handles.point(inside: CGPoint(x: last.maxX, y: last.maxY + 6), with: nil))
        XCTAssertFalse(r.ui.handles.point(inside: r.point(2, 9), with: nil))
        XCTAssertEqual(r.ui.tap(at: CGPoint(x: last.maxX, y: last.maxY + 6), focused: true), .handle, "a tap on a handle is not a tap on the terminal")
    }

    @MainActor
    func testDraggingAHandlePastTheOtherEndTurnsTheSelectionAround() {
        let r = makeRig(Self.lines)
        r.ui.pressBegan(at: r.point(13, 2))
        r.ui.pressEnded(at: r.point(13, 2))
        XCTAssertEqual(r.view.selectedText, "beta")
        guard let end = r.ui.handles.layout.end else { return XCTFail("no end handle") }
        XCTAssertTrue(r.ui.handleBegan(at: CGPoint(x: end.knob.midX, y: end.knob.midY)))
        let offset = r.ui.grabOffset, to = r.point(6, 2)
        r.ui.handleMoved(to: CGPoint(x: to.x + offset.width, y: to.y + offset.height))
        r.ui.handleEnded(cancelled: false)
        XCTAssertEqual(r.view.selectedText, "alpha b", "from the cell the handle was dragged to, to the start that stayed")
    }

    @MainActor
    func testADragOutOfThePressedWordKeepsTheWordWhole() {
        let forward = makeRig(Self.lines)
        forward.ui.pressBegan(at: forward.point(13, 2))
        XCTAssertEqual(forward.view.selectedText, "beta")
        forward.ui.pressMoved(to: forward.point(15, 2))
        XCTAssertEqual(forward.view.selectedText, "beta", "moving inside the word changes nothing")
        forward.ui.pressMoved(to: forward.point(18, 2))
        XCTAssertEqual(forward.view.selectedText, "beta ga", "from the word's first letter, not from the cell that was pressed")
        forward.ui.pressMoved(to: forward.point(2, 3))
        XCTAssertEqual(forward.view.selectedText, "beta gamma\nlin")
        forward.ui.pressEnded(at: forward.point(2, 3))
        XCTAssertEqual(forward.rec.copied, ["beta gamma\nlin"])

        let backward = makeRig(Self.lines)
        backward.ui.pressBegan(at: backward.point(13, 2))
        backward.ui.pressMoved(to: backward.point(8, 2))
        XCTAssertEqual(backward.view.selectedText, "pha beta", "to the word's last letter when dragging back")
        backward.ui.pressEnded(at: backward.point(8, 2))
        XCTAssertEqual(backward.ui.session.phase, .selected)
    }

    @MainActor
    func testDoubleTapSelectsAWordAndTripleTapTheLine() {
        let r = makeRig(Self.lines)
        let p = r.point(13, 4)
        XCTAssertEqual(r.ui.tap(at: p, focused: false), .single(showsPaste: false))
        XCTAssertNil(r.view.selectedText)
        r.time.now += 0.15
        XCTAssertEqual(r.ui.tap(at: p, focused: true), .selected)
        XCTAssertEqual(r.view.selectedText, "beta")
        XCTAssertEqual(r.rec.copied, ["beta"])
        XCTAssertEqual(r.rec.played, [.copy], "a tap selection confirms the copy; there is no hold to start")
        XCTAssertTrue(r.ui.handles.showsHandles)
        r.time.now += 0.15
        XCTAssertEqual(r.ui.tap(at: p, focused: true), .selected)
        XCTAssertEqual(r.view.selectedText, "line4 alpha beta gamma")
        XCTAssertEqual(r.rec.copied, ["beta", "line4 alpha beta gamma"])

        // A slow second tap is a plain tap again.
        r.time.now += 2
        if case .selected = r.ui.tap(at: p, focused: true) { XCTFail("a tap long after is single") }
        // A double tap on nothing clears.
        r.view.clearSelectedRange()
        r.ui.selectionCleared()
        let blank = r.point(5, 10)
        r.time.now += 2
        _ = r.ui.tap(at: blank, focused: true)
        r.time.now += 0.1
        XCTAssertEqual(r.ui.tap(at: blank, focused: true), .selected)
        XCTAssertFalse(r.view.hasActiveSelection)
        XCTAssertFalse(r.ui.handles.showsHandles)
    }

    @MainActor
    func testATapByTheCursorOffersPaste() {
        let r = makeRig("one\r\ntwo\r\n$ ")
        // The cursor is at column 2 of row 2.
        XCTAssertEqual(r.view.cursorGridCell, TerminalGridCell(col: 2, row: 2))
        XCTAssertEqual(r.ui.tap(at: r.point(3, 2), focused: true), .single(showsPaste: true))
        r.time.now += 2
        XCTAssertEqual(r.ui.tap(at: r.point(3, 2), focused: false), .single(showsPaste: false), "the tap that focuses shows nothing")
        r.time.now += 2
        XCTAssertEqual(r.ui.tap(at: r.point(20, 2), focused: true), .single(showsPaste: false), "far from the cursor")
        r.time.now += 2
        r.ui.menuVisible = true
        XCTAssertEqual(r.ui.tap(at: r.point(3, 2), focused: true), .single(showsPaste: false), "the tap that hides the menu")
        r.ui.menuVisible = false
        // A program that tracks the mouse gets the tap as a click.
        r.view.feed(text: "\u{1b}[?1000h")
        r.view.core.sync()
        r.time.now += 2
        XCTAssertEqual(r.ui.tap(at: r.point(3, 2), focused: true), .single(showsPaste: false))
    }

    @MainActor
    func testTheSelectionDroppedByTheTerminalTakesItsHandlesAway() {
        let r = makeRig(Self.lines)
        r.ui.pressBegan(at: r.point(7, 2))
        r.ui.pressEnded(at: r.point(7, 2))
        XCTAssertTrue(r.ui.handles.showsHandles)
        r.view.feed(text: "\u{1b}c")
        r.view.core.sync()
        r.time.now += 1
        r.ui.tick()
        XCTAssertEqual(r.ui.session.phase, .idle)
        XCTAssertFalse(r.ui.handles.showsHandles)
    }

    // MARK: The selection UI members on the terminal view

    @MainActor
    func testSelectionEndsAdjustAndLine() {
        let r = makeRig(Self.lines)
        let view = r.view
        XCTAssertNil(view.selectionEnds, "no selection, no ends")
        XCTAssertFalse(view.beginSelectionAdjust(movingStart: true))

        XCTAssertTrue(view.selectLine(at: r.point(3, 5)))
        XCTAssertEqual(view.selectedText, "line5 alpha beta gamma")
        let ends = view.selectionEnds
        XCTAssertEqual(ends?.start, view.viewportRect(row: 5, columns: 0..<1))
        XCTAssertEqual(ends?.end, view.viewportRect(row: 5, columns: 21..<22))

        // Move the end: the start stays.
        XCTAssertTrue(view.beginSelectionAdjust(movingStart: false))
        view.extendSelection(to: r.point(4, 6), autoscroll: false)
        view.endSelectionDrag()
        XCTAssertEqual(view.selectedText, "line5 alpha beta gamma\nline6")
        // Move the start: the end stays.
        XCTAssertTrue(view.beginSelectionAdjust(movingStart: true))
        view.extendSelection(to: r.point(17, 5), autoscroll: false)
        view.endSelectionDrag()
        XCTAssertEqual(view.selectedText, "gamma\nline6")

        XCTAssertFalse(view.selectLine(at: r.point(3, 10)), "an empty line")
        XCTAssertFalse(view.hasActiveSelection)

        // Select All reaches both ends of what is on screen, and can be pulled back in.
        view.selectAllText()
        XCTAssertNotNil(view.selectionEnds?.start)
        XCTAssertTrue(view.beginSelectionAdjust(movingStart: false))
        view.extendSelection(to: r.point(4, 0), autoscroll: false)
        view.endSelectionDrag()
        XCTAssertEqual(view.selectedText, "line0")
        XCTAssertEqual(view.gridCell(at: r.point(4, 3)), TerminalGridCell(col: 4, row: 3))
    }
}
