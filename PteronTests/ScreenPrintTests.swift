import XCTest
@testable import Pteron

/// Keys typed behind the catch-up fence go only if the screen comes back the one on show when
/// the hold began (`GhosttyCore.showsHeldScreen`): the same text, styles, cursor, input modes
/// and grid.
final class ScreenPrintTests: XCTestCase {
    private let left = "00041 the last line of the transcript\r\n> "

    /// A pane showing `left`, held as the fence goes up.
    private func held(cols: Int = 40, rows: Int = 4) -> GhosttyCore {
        let core = GhosttyCore(cols: cols, rows: rows)
        core.feed(Array(left.utf8))
        core.sync()
        core.setCatchUpHold(true, limited: false)
        return core
    }

    private func feed(_ core: GhosttyCore, _ text: String) {
        core.feed(Array(text.utf8))
        core.sync()
    }

    func testARedrawForAResizeThereAndBackIsTheSameScreen() {
        // Back from the background: the Mac's grid, then ours again, and the program reprints.
        let core = held()
        core.resize(cols: 120, rows: 30, cellWidthPx: 14, cellHeightPx: 28)
        feed(core, "\u{1b}[2J\u{1b}[3J\u{1b}[H" + left)
        core.resize(cols: 40, rows: 4, cellWidthPx: 14, cellHeightPx: 28)
        feed(core, "\u{1b}[2J\u{1b}[3J\u{1b}[H" + left)
        XCTAssertTrue(core.showsHeldScreen())
    }

    func testOtherTextIsAnotherScreen() {
        let core = held()
        feed(core, "\u{1b}[2J\u{1b}[HDo you want to proceed?\r\n> 1. Yes")
        XCTAssertFalse(core.showsHeldScreen())
    }

    func testAnotherStyleIsAnotherScreen() {
        // A menu that marks its choice by colour alone.
        let core = held()
        feed(core, "\u{1b}[2J\u{1b}[H00041 the last line of the transcript\r\n\u{1b}[7m> \u{1b}[0m")
        XCTAssertFalse(core.showsHeldScreen())
    }

    func testTheCursorElsewhereIsAnotherScreen() {
        let core = held()
        feed(core, "\u{1b}[1;1H")
        XCTAssertFalse(core.showsHeldScreen())
    }

    func testAModeThatShapesKeysMakesAnotherScreen() {
        // Cursor keys in application mode send other bytes.
        let core = held()
        feed(core, "\u{1b}[?1h")
        XCTAssertFalse(core.showsHeldScreen())
    }

    func testAKeyboardModeMakesAnotherScreen() {
        let core = held()
        feed(core, "\u{1b}[>1u")
        XCTAssertFalse(core.showsHeldScreen())
    }

    func testAnotherGridIsAnotherScreen() {
        let core = held()
        core.resize(cols: 50, rows: 4, cellWidthPx: 14, cellHeightPx: 28)
        core.sync()
        XCTAssertFalse(core.showsHeldScreen())
    }

    func testNothingHeldIsNoScreenToTypeAt() {
        let core = GhosttyCore(cols: 40, rows: 4)
        feed(core, left)
        XCTAssertFalse(core.showsHeldScreen())
    }

    func testASnapshotOfTheSameScreenIsTheSameScreen() throws {
        // A long time away: the stream starts fresh and its snapshot replaces the terminal.
        let core = held()
        let source = GhosttyCore(cols: 40, rows: 4)
        source.feed(Array(left.utf8))
        source.sync()
        core.restore(snapshot: try XCTUnwrap(source.encodeSnapshot())) { _ in }
        core.sync()
        XCTAssertTrue(core.showsHeldScreen())
    }

    func testTheHoldKeepsTheScreenOfItsBeginning() {
        // Raised again while held, the hold keeps the screen the user saw first.
        let core = held()
        feed(core, "more")
        core.setCatchUpHold(true)
        feed(core, "\u{1b}[2J\u{1b}[H" + left)
        XCTAssertTrue(core.showsHeldScreen())
    }
}
