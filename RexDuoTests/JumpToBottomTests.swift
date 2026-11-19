import RexKit
import Testing
import XCTest
@testable import RexDuo

/// When the jump-to-bottom button shows: well into the scrollback, with nothing else going on,
/// and without flickering around a threshold.
struct JumpToBottomRuleTests {
    /// The rule in a box: `#expect` can't call a mutating member.
    private final class Rule {
        private var rule = JumpToBottomRule()
        var shown: Bool { rule.shown }
        var unseen: Bool { rule.unseen }
        func update(_ input: JumpToBottomRule.Input) -> Bool { rule.update(input) }
    }

    private func input(_ rowsAbove: Double, screenRows: Int = 24, blocked: Bool = false, total: Int = 100, rebase: Int = 0,
                       sequence: Int = 0) -> JumpToBottomRule.Input {
        JumpToBottomRule.Input(rowsAbove: rowsAbove, screenRows: screenRows, blocked: blocked, total: total, rebase: rebase,
                               sequence: sequence)
    }

    @Test func showsFromHalfAScreenUp() {
        let rule = Rule()
        #expect(!rule.update(input(0)))
        #expect(!rule.update(input(11.9)))
        #expect(!rule.shown)
        #expect(rule.update(input(12)))
        #expect(rule.shown)
        #expect(!rule.unseen)
    }

    @Test func aShortScreenStillNeedsThreeRows() {
        #expect(JumpToBottomRule.showRows(screenRows: 4) == 3)
        #expect(JumpToBottomRule.showRows(screenRows: 0) == 3)
        #expect(JumpToBottomRule.showRows(screenRows: 7) == 3)
        #expect(JumpToBottomRule.showRows(screenRows: 8) == 4)
        #expect(JumpToBottomRule.showRows(screenRows: 51) == 25)
        let rule = Rule()
        #expect(!rule.update(input(2.9, screenRows: 4)))
        #expect(rule.update(input(3, screenRows: 4)))
    }

    /// Between the two thresholds the button keeps the state it has.
    @Test func noFlickerBetweenTheThresholds() {
        let rule = Rule()
        for rows in [1.5, 6, 11.5, 2, 11.9] {
            #expect(!rule.update(input(rows)), "\(rows)")
            #expect(!rule.shown)
        }
        #expect(rule.update(input(12)))
        for rows in [11.9, 6, 1.1, 11, 1.01] {
            #expect(!rule.update(input(rows)), "\(rows)")
            #expect(rule.shown)
        }
        #expect(rule.update(input(1)))
        #expect(!rule.shown)
        #expect(!rule.update(input(5)))
        #expect(!rule.shown)
    }

    @Test func blockedHidesAndKeepsHidden() {
        let rule = Rule()
        #expect(!rule.update(input(40, blocked: true)))
        #expect(!rule.shown)
        #expect(rule.update(input(40)))
        #expect(rule.shown)
        // A selection, a pinch or a program that takes the drags: gone, wherever the view is.
        #expect(rule.update(input(40, blocked: true)))
        #expect(!rule.shown)
        #expect(!rule.update(input(40, blocked: true)))
        #expect(rule.update(input(40)))
        #expect(rule.shown)
    }

    @Test func newRowsWhileShownAreUnseen() {
        let rule = Rule()
        #expect(rule.update(input(20, total: 100)))
        #expect(!rule.unseen)
        // Scrolling on changes nothing.
        #expect(!rule.update(input(25, total: 100, sequence: 3)))
        #expect(!rule.unseen)
        #expect(rule.update(input(26, total: 101, sequence: 3)))
        #expect(rule.unseen)
        // It stays until the button hides.
        #expect(!rule.update(input(30, total: 101, sequence: 4)))
        #expect(rule.unseen)
    }

    /// A full scrollback: new rows push old ones out, the total stays and the terminal moves.
    @Test func theTerminalMovingByItselfIsUnseen() {
        let rule = Rule()
        #expect(rule.update(input(20, rebase: 0, sequence: 5)))
        #expect(rule.update(input(20, rebase: -32, sequence: 5)))
        #expect(rule.unseen)
    }

    /// A line, page or prompt jump moves the terminal too, by a request of ours.
    @Test func aMoveWeAskedForIsNotUnseen() {
        let rule = Rule()
        #expect(rule.update(input(40, rebase: 0, sequence: 5)))
        #expect(!rule.update(input(30, rebase: 160, sequence: 6)))
        #expect(!rule.unseen)
        #expect(rule.shown)
    }

    @Test func hidingForgetsUnseenAndShowingStartsWithout() {
        let rule = Rule()
        #expect(rule.update(input(20, total: 100)))
        #expect(rule.update(input(20, total: 110)))
        #expect(rule.unseen)
        #expect(rule.update(input(0, total: 110)))
        #expect(!rule.shown)
        #expect(!rule.unseen)
        // Output while hidden, and in the very update that shows the button, doesn't count.
        #expect(!rule.update(input(0, total: 150)))
        #expect(rule.update(input(20, total: 160)))
        #expect(rule.shown)
        #expect(!rule.unseen)
        // Blocked forgets it as well.
        #expect(rule.update(input(20, total: 170)))
        #expect(rule.unseen)
        #expect(rule.update(input(20, blocked: true, total: 170)))
        #expect(rule.update(input(20, total: 170)))
        #expect(!rule.unseen)
    }
}

/// The engine's scroll place, and the host's button on top of it.
@MainActor
final class JumpToBottomViewTests: XCTestCase {
    /// Sizes `view` to a 40×10 grid, prints `count` lines and applies one frame's state.
    private func fill(_ view: GhosttyTerminalView, lines count: Int) {
        view.setGrid(cols: 40, rows: 10, force: true)
        let cell = view.cellSize
        view.frame = CGRect(x: 0, y: 0, width: 40 * cell.width, height: 10 * cell.height)
        view.layoutIfNeeded()
        view.feed(text: (1...count).map { "\($0) line\r\n" }.joined())
        frame(view)
    }

    /// Runs one frame the way the render thread would, and hands its state to the scroller.
    private func frame(_ view: GhosttyTerminalView) {
        view.core.sync()
        _ = view.renderer.frame.update(core: view.core)
        view.scroller.apply(view.core.scroll.snapshot)
    }

    private func makeHost() -> TerminalHost {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let host = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: "b"), sizing: .mirror,
                                fontSize: 12, theme: ThemeStore.fallback)
        // Too small to lay out, so the host never starts its stream and leaves the engine view alone.
        host.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        return host
    }

    func testTheScrollPlaceIsZeroAtTheBottomAndCountsRowsIntoTheScrollback() {
        let view = GhosttyTerminalView(frame: .zero, fontSize: 12, cols: 40, rows: 10)
        var places: [GhosttyScrollPlace] = []
        view.scrollPlaceHook = { places.append($0) }
        fill(view, lines: 100)
        let cell = view.cellSize.height
        XCTAssertEqual(places.last?.rowsAbove, 0)
        XCTAssertEqual(places.last?.total, view.core.scroll.snapshot.total)
        XCTAssertEqual(places.last?.programScroll, false)

        // A scroll step tells at once, before the terminal has drawn it.
        places.removeAll()
        view.scroller.setOffset(71 * cell, animated: false)
        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places.last?.rowsAbove ?? 0, 20, accuracy: 0.01)
        frame(view)
        XCTAssertEqual(places.last?.rowsAbove ?? 0, 20, accuracy: 0.05)
        XCTAssertEqual(places.last?.sequence, view.scroller.lastRequest)

        // Output below leaves the view where it is, further from the newest line.
        view.feed(text: (101...110).map { "\($0) line\r\n" }.joined())
        frame(view)
        XCTAssertEqual(places.last?.rowsAbove ?? 0, 30, accuracy: 0.05)

        // In the rows the keyboard covers, past the last row position, the view is at the bottom.
        view.setCover(3 * cell)
        frame(view)
        view.scrollToBottomForInput()
        frame(view)
        XCTAssertEqual(places.last?.rowsAbove, 0)
        XCTAssertNil(view.scroller.lastUserMove, "none of this was the user's finger")

        view.feed(text: "\u{1b}[?1049h")
        frame(view)
        XCTAssertEqual(places.last?.programScroll, true)
    }

    func testTheButtonShowsInTheScrollbackAndItsTapJumpsBackWithoutTakingTheKeyboard() {
        let host = makeHost()
        let term = host.term, button = host.jumpButton
        fill(term, lines: 100)
        let cell = term.cellSize.height
        XCTAssertFalse(button.shown)
        XCTAssertTrue(button.isHidden)
        XCTAssertFalse(button.isAccessibilityElement)
        XCTAssertFalse(button.isUserInteractionEnabled)

        // Two rows up is not enough for a 10 row screen; half of it is.
        term.scroller.setOffset(89 * cell, animated: false)
        frame(term)
        XCTAssertFalse(button.shown)
        term.scroller.setOffset(86 * cell, animated: false)
        XCTAssertTrue(button.shown, "on the scroll step itself")
        frame(term)
        XCTAssertTrue(button.shown)
        XCTAssertFalse(button.isHidden)
        XCTAssertTrue(button.isAccessibilityElement)
        XCTAssertTrue(button.isUserInteractionEnabled)
        XCTAssertFalse(button.unseen)
        XCTAssertNil(button.accessibilityValue)

        term.feed(text: "more output\r\n")
        frame(term)
        XCTAssertTrue(button.unseen)
        XCTAssertEqual(button.accessibilityValue, "New output")

        // The tap, as a finger sends it.
        button.sendActions(for: .touchUpInside)
        frame(term)
        XCTAssertTrue(term.core.scroll.snapshot.active)
        XCTAssertFalse(button.shown)
        XCTAssertTrue(button.isHidden)
        XCTAssertFalse(button.unseen)
        XCTAssertFalse(term.isFirstResponder, "the jump doesn't raise the keyboard")
        XCTAssertFalse(host.userHidKeyboard)
    }

    func testASelectionOrAProgramThatTakesTheDragsHidesTheButton() {
        let host = makeHost()
        let term = host.term, button = host.jumpButton
        fill(term, lines: 100)
        let cell = term.cellSize.height
        term.scroller.setOffset(50 * cell, animated: false)
        frame(term)
        XCTAssertTrue(button.shown)

        // A selection is up: the button goes with the next scroll step, and comes back when
        // a tap clears the selection.
        term.beginSelection(at: CGPoint(x: 2, y: cell * 1.5), word: true)
        term.endSelectionDrag()
        XCTAssertTrue(term.hasActiveSelection)
        term.scroller.setOffset(49 * cell, animated: false)
        XCTAssertFalse(button.shown)
        XCTAssertEqual(host.tap(at: CGPoint(x: 2, y: cell * 6.5), shift: false, keyboardUp: true, hadSelection: true), .dismissSelection)
        XCTAssertFalse(term.hasActiveSelection)
        XCTAssertTrue(button.shown)

        term.feed(text: "\u{1b}[?1049h")
        frame(term)
        XCTAssertFalse(button.shown)
    }

    func testTheButtonSitsInTheBottomTrailingCornerAndKeepsItsTouchFromThePane() {
        let host = makeHost()
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 18)
        host.layoutIfNeeded()
        let button = host.jumpButton
        XCTAssertEqual(button.bounds.size, CGSize(width: 44, height: 44))
        XCTAssertEqual(button.center.x, 300 - 12 - 17)
        XCTAssertEqual(button.center.y, 18 - 12 - 17)
        XCTAssertTrue(host.subviews.contains(button), "on the host, not in the zoomed canvas")
        // No tap recognizer above the button begins for a touch on it.
        XCTAssertFalse(button.gestureRecognizerShouldBegin(UITapGestureRecognizer()))
        XCTAssertTrue(button.gestureRecognizerShouldBegin(UIPanGestureRecognizer()))
    }

    func testOnlyTheRoundTargetTakesATouchAndTheFramesCornersReachThePane() {
        let host = makeHost()
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 400)
        host.layoutIfNeeded()
        let button = host.jumpButton
        button.set(shown: true, unseen: false, animated: false)
        let center = button.center
        XCTAssertTrue(host.hitTest(center, with: nil) === button)
        XCTAssertTrue(host.hitTest(CGPoint(x: center.x + 21, y: center.y), with: nil) === button)
        // The frame's corner, outside the 44 pt circle.
        let corner = CGPoint(x: button.frame.maxX - 2, y: button.frame.maxY - 2)
        XCTAssertTrue(button.frame.contains(corner))
        XCTAssertFalse(host.hitTest(corner, with: nil) === button)
    }
}
