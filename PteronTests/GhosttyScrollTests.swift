import Metal
import XCTest
@testable import Pteron

/// Counts heap allocations on one thread through libmalloc's `malloc_logger` hook.
///
/// `nonisolated(unsafe)`: the hook is a C callback and can't capture. The counter is only
/// written by the hook on the thread that armed it, and read by that thread.
private enum AllocationCounter {
    nonisolated(unsafe) static var count = 0
    nonisolated(unsafe) static var thread: pthread_t?
    private typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// Allocations made on this thread while `body` runs, or nil if the hook isn't available.
    static func measure(_ body: () -> Void) -> Int? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger") else { return nil }
        let slot = symbol.assumingMemoryBound(to: Logger?.self)
        let previous = slot.pointee
        count = 0
        thread = pthread_self()
        slot.pointee = { type, _, _, _, _, _ in
            // Bit 1 is "allocate" (a realloc has it too); frees have only bit 2.
            if type & 2 != 0, let t = AllocationCounter.thread, pthread_equal(t, pthread_self()) != 0 { AllocationCounter.count += 1 }
        }
        // The hook must see a known allocation, or its silence would prove nothing.
        let probe = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 8)
        probe.deallocate()
        guard count > 0 else {
            slot.pointee = previous
            return nil
        }
        count = 0
        body()
        let n = count
        slot.pointee = previous
        thread = nil
        return n
    }
}

final class GhosttyScrollTests: XCTestCase {
    private func lines(_ range: ClosedRange<Int>) -> [UInt8] {
        Array(range.map { "\u{1b}[3\($0 % 7 + 1)m\($0)\u{1b}[0m line of text for the scroll tests\r\n" }.joined().utf8)
    }

    /// A terminal with lines 1...count printed and a frame drawn. The last row is an empty line.
    private func make(_ count: Int, cols: Int = 40, rows: Int = 10) -> (GhosttyCore, GhosttyFrameBuilder) {
        let core = GhosttyCore(cols: cols, rows: rows)
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        // The view does this: the terminal knows the cell's pixel size.
        core.resize(cols: cols, rows: rows, cellWidthPx: atlas.metrics.cellWidth, cellHeightPx: atlas.metrics.cellHeight)
        core.feed(lines(1...count))
        core.sync()
        let frame = GhosttyFrameBuilder(atlas: atlas)
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(core.scroll.snapshot.cellHeight, atlas.metrics.cellHeight)
        return (core, frame)
    }

    private func number(_ core: GhosttyCore, row: Int) -> Int? {
        Int(core.rowText(row).prefix { $0.isNumber })
    }

    // MARK: Math

    func testResolveSplitsPixelsIntoRowFractionAndBounce() {
        typealias R = GhosttyScrollMath.Resolved
        XCTAssertEqual(GhosttyScrollMath.resolve(px: 0, maxRow: 100, cellHeight: 30), R(row: 0, fraction: 0, bounce: 0, bottom: false))
        XCTAssertEqual(GhosttyScrollMath.resolve(px: 29, maxRow: 100, cellHeight: 30), R(row: 0, fraction: 29, bounce: 0, bottom: false))
        XCTAssertEqual(GhosttyScrollMath.resolve(px: 30, maxRow: 100, cellHeight: 30), R(row: 1, fraction: 0, bounce: 0, bottom: false))
        XCTAssertEqual(GhosttyScrollMath.resolve(px: 1517, maxRow: 100, cellHeight: 30), R(row: 50, fraction: 17, bounce: 0, bottom: false))
        XCTAssertEqual(GhosttyScrollMath.resolve(px: 2999, maxRow: 100, cellHeight: 30), R(row: 99, fraction: 29, bounce: 0, bottom: false))
        // The last position follows the active area; past it is rubber band.
        XCTAssertEqual(GhosttyScrollMath.resolve(px: 3000, maxRow: 100, cellHeight: 30), R(row: 100, fraction: 0, bounce: 0, bottom: true))
        XCTAssertEqual(GhosttyScrollMath.resolve(px: 3045, maxRow: 100, cellHeight: 30), R(row: 100, fraction: 0, bounce: 45, bottom: true))
        XCTAssertEqual(GhosttyScrollMath.resolve(px: -12, maxRow: 100, cellHeight: 30), R(row: 0, fraction: 0, bounce: -12, bottom: false))
        // No scrollback: always at the bottom.
        XCTAssertEqual(GhosttyScrollMath.resolve(px: 0, maxRow: 0, cellHeight: 30), R(row: 0, fraction: 0, bounce: 0, bottom: true))
        XCTAssertEqual(GhosttyScrollMath.resolve(px: -5, maxRow: 0, cellHeight: 30), R(row: 0, fraction: 0, bounce: -5, bottom: true))
    }

    func testContentHeightMakesTheLastOffsetTheLastRow() {
        XCTAssertEqual(GhosttyScrollMath.maxRow(total: 110, len: 10), 100)
        XCTAssertEqual(GhosttyScrollMath.maxRow(total: 10, len: 10), 0)
        XCTAssertEqual(GhosttyScrollMath.maxRow(total: 4, len: 10), 0)
        let height = GhosttyScrollMath.contentHeight(total: 110, len: 10, cellHeight: 30, viewHeight: 301)
        XCTAssertEqual(height - 301, 100 * 30, "content height minus the view is the largest offset")
        XCTAssertEqual(GhosttyScrollMath.contentHeight(total: 10, len: 10, cellHeight: 30, viewHeight: 301), 301, "nothing to scroll")
        XCTAssertEqual(GhosttyScrollMath.position(offset: 50, fraction: 17, cellHeight: 30), 1517)
    }

    // MARK: Viewport

    func testStartsFollowingTheBottom() {
        let (core, frame) = make(100)
        let s = core.scroll.snapshot
        XCTAssertTrue(s.active)
        XCTAssertEqual(s.len, 10)
        XCTAssertEqual(s.total, 101)
        XCTAssertEqual(s.offset, 91)
        XCTAssertEqual(s.position, 91 * s.cellHeight)
        XCTAssertEqual(s.rebase, s.position, "a scroll view at 0 is told how far the terminal is from it")
        XCTAssertEqual(frame.scrollOffset, 0)
        XCTAssertEqual(frame.overscanBelow, 0, "nothing below the active area")
        XCTAssertEqual(frame.rows.count, 10)
    }

    func testPositionRequestMovesRowAndFractionTogether() {
        let (core, frame) = make(100)
        let cell = core.scroll.snapshot.cellHeight
        let rebase = core.scroll.snapshot.rebase
        // A scroll view that has applied the rebase is at `position`; go to row 50 plus 7 pixels.
        let sequence = core.scrollViewport(.position(px: 50 * cell + 7, rebaseSeen: rebase))
        XCTAssertTrue(core.scroll.hasPending)
        XCTAssertTrue(frame.update(core: core))
        let s = core.scroll.snapshot
        XCTAssertFalse(core.scroll.hasPending)
        XCTAssertEqual(s.appliedSequence, sequence)
        XCTAssertFalse(s.active)
        XCTAssertEqual(s.offset, 50)
        XCTAssertEqual(s.fraction, 7)
        XCTAssertEqual(s.rebase, rebase, "a position the sender chose is no news to it")
        XCTAssertEqual(frame.scrollOffset, 7)
        XCTAssertEqual(frame.overscanBelow, 1)
        XCTAssertEqual(frame.rows.count, 11, "the row cut at the bottom edge is drawn too")
        XCTAssertEqual(number(core, row: 0), 51)

        // Same row, other fraction: the terminal isn't touched and nothing is rebuilt.
        let calls = core.scroll.viewportCalls
        core.scrollViewport(.position(px: 50 * cell + 12, rebaseSeen: rebase))
        XCTAssertTrue(frame.update(core: core), "the offset changed, so a frame is due")
        XCTAssertEqual(core.scroll.viewportCalls, calls)
        XCTAssertEqual(frame.rowsBuilt, 0)
        XCTAssertEqual(frame.scrollOffset, 12)
        XCTAssertFalse(frame.update(core: core), "and then nothing")
    }

    func testOutputDoesNotMoveAScrolledUpView() {
        let (core, frame) = make(100)
        let cell = core.scroll.snapshot.cellHeight
        core.scrollViewport(.position(px: 50 * cell + 7, rebaseSeen: core.scroll.snapshot.rebase))
        XCTAssertTrue(frame.update(core: core))
        let before = core.scroll.snapshot
        core.feed(lines(101...140))
        core.sync()
        XCTAssertFalse(frame.update(core: core), "nothing on screen changed")
        let after = core.scroll.snapshot
        XCTAssertEqual(after.offset, 50)
        XCTAssertEqual(after.fraction, 7)
        XCTAssertEqual(after.total, before.total + 40)
        XCTAssertEqual(after.rebase, before.rebase, "the scroll view's offset is still right")
        XCTAssertEqual(number(core, row: 0), 51)
        XCTAssertEqual(frame.scrollOffset, 7)
    }

    func testOutputKeepsTheBottomPinnedAndRebases() {
        let (core, frame) = make(100)
        let before = core.scroll.snapshot
        core.feed(lines(101...140))
        core.sync()
        XCTAssertTrue(frame.update(core: core))
        let after = core.scroll.snapshot
        XCTAssertTrue(after.active)
        XCTAssertEqual(after.offset, before.offset + 40)
        XCTAssertEqual(after.rebase - before.rebase, 40 * after.cellHeight, "the scroll view is told to move down 40 rows")
        XCTAssertEqual(core.scroll.viewportCalls, 0, "following needs no scroll call")
    }

    func testAStalePositionIsReadWithTheRebaseItWasSentWith() {
        let (core, frame) = make(100)
        let seen = core.scroll.snapshot
        // 10 lines arrive that the main thread hasn't heard about, then its finger moves up 3 rows.
        core.feed(lines(101...110))
        core.sync()
        core.scrollViewport(.position(px: seen.position - 3 * seen.cellHeight - 5, rebaseSeen: seen.rebase))
        XCTAssertTrue(frame.update(core: core))
        let s = core.scroll.snapshot
        XCTAssertEqual(s.offset, seen.offset + 10 - 4, "3 rows and 5 pixels above the new bottom, not the old one")
        XCTAssertEqual(s.fraction, s.cellHeight - 5)
        XCTAssertEqual(s.rebase - seen.rebase, 10 * s.cellHeight)
    }

    func testRubberBandAtBothEnds() {
        let (core, frame) = make(100)
        let s0 = core.scroll.snapshot
        core.scrollViewport(.position(px: s0.position + 33, rebaseSeen: s0.rebase))
        XCTAssertTrue(frame.update(core: core))
        XCTAssertTrue(core.scroll.snapshot.active)
        XCTAssertEqual(core.scroll.snapshot.bounce, 33)
        XCTAssertEqual(frame.scrollOffset, 33, "the grid is drawn 33 pixels up")
        XCTAssertEqual(core.scroll.viewportCalls, 0)

        core.scrollViewport(.position(px: -20, rebaseSeen: s0.rebase))
        XCTAssertTrue(frame.update(core: core))
        let top = core.scroll.snapshot
        XCTAssertEqual(top.offset, 0)
        XCTAssertEqual(top.bounce, -20)
        XCTAssertEqual(top.position, 0)
        XCTAssertEqual(frame.scrollOffset, -20, "the grid is drawn 20 pixels down")
        XCTAssertEqual(number(core, row: 0), 1)

        core.scrollViewport(.position(px: 0, rebaseSeen: s0.rebase))
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.scrollOffset, 0)
    }

    func testReturningToTheLastPositionFollowsAgain() {
        let (core, frame) = make(100)
        let s0 = core.scroll.snapshot
        core.scrollViewport(.position(px: 10 * s0.cellHeight, rebaseSeen: s0.rebase))
        XCTAssertTrue(frame.update(core: core))
        XCTAssertFalse(core.scroll.snapshot.active)
        core.scrollViewport(.position(px: s0.position, rebaseSeen: s0.rebase))
        XCTAssertTrue(frame.update(core: core))
        XCTAssertTrue(core.scroll.snapshot.active)
        core.feed(lines(101...105))
        core.sync()
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(number(core, row: 8), 105, "new output shows")
    }

    func testPagesLinesTopAndBottom() {
        let (core, frame) = make(100)
        let s0 = core.scroll.snapshot
        core.scrollViewport(.pages(-1))
        XCTAssertTrue(frame.update(core: core))
        var s = core.scroll.snapshot
        XCTAssertEqual(s.offset, s0.offset - 10)
        XCTAssertEqual(s.rebase - s0.rebase, -10 * s.cellHeight, "a jump is news to the scroll view")
        core.scrollViewport(.lines(-2))
        core.scrollViewport(.lines(-1))
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(core.scroll.snapshot.offset, s0.offset - 13, "line requests add up")
        core.scrollViewport(.top)
        XCTAssertTrue(frame.update(core: core))
        s = core.scroll.snapshot
        XCTAssertEqual(s.offset, 0)
        XCTAssertEqual(s.position, 0)
        core.scrollViewport(.pages(1))
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(core.scroll.snapshot.offset, 10)
        core.scrollViewport(.bottom)
        XCTAssertTrue(frame.update(core: core))
        s = core.scroll.snapshot
        XCTAssertTrue(s.active)
        XCTAssertEqual(s.position, s0.position)
        XCTAssertEqual(s.rebase, s0.rebase)
    }

    func testAJumpDropsTheFraction() {
        let (core, frame) = make(100)
        let s0 = core.scroll.snapshot
        core.scrollViewport(.position(px: 40 * s0.cellHeight + 9, rebaseSeen: s0.rebase))
        XCTAssertTrue(frame.update(core: core))
        core.scrollViewport(.bottom)
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(core.scroll.snapshot.fraction, 0)
        XCTAssertEqual(frame.scrollOffset, 0)
    }

    func testPromptScrollUsesTheShellsMarks() {
        let core = GhosttyCore(cols: 40, rows: 10)
        var text = ""
        for p in 1...6 {
            text += "\u{1b}]133;A\u{07}prompt\(p)$ \u{1b}]133;B\u{07}cmd\r\n\u{1b}]133;C\u{07}"
            for i in 1...12 { text += "out \(p).\(i)\r\n" }
            text += "\u{1b}]133;D\u{07}"
        }
        core.feed(Array(text.utf8))
        core.sync()
        let frame = GhosttyFrameBuilder(atlas: GhosttyGlyphAtlas(pointSize: 12, scale: 2))
        XCTAssertTrue(frame.update(core: core))
        core.scrollViewport(.prompts(-1))
        XCTAssertTrue(frame.update(core: core))
        XCTAssertFalse(core.scroll.snapshot.active)
        XCTAssertTrue(core.rowText(0).hasPrefix("prompt6$"), core.rowText(0))
        core.scrollViewport(.prompts(-2))
        XCTAssertTrue(frame.update(core: core))
        XCTAssertTrue(core.rowText(0).hasPrefix("prompt4$"), core.rowText(0))
        core.scrollViewport(.prompts(1))
        XCTAssertTrue(frame.update(core: core))
        XCTAssertTrue(core.rowText(0).hasPrefix("prompt5$"), core.rowText(0))
    }

    func testAlternateScreenHasNothingToScroll() {
        let (core, frame) = make(100)
        core.feed(Array("\u{1b}[?1049hfull screen".utf8))
        core.sync()
        XCTAssertTrue(frame.update(core: core))
        let s = core.scroll.snapshot
        XCTAssertEqual(s.maxRow, 0)
        XCTAssertTrue(s.active)
        XCTAssertTrue(s.programScroll)
        core.scrollViewport(.pages(-1))
        _ = frame.update(core: core)
        XCTAssertEqual(core.scroll.snapshot.offset, 0)
        core.feed(Array("\u{1b}[?1049l".utf8))
        core.sync()
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(core.scroll.snapshot.offset, 91)
        XCTAssertFalse(core.scroll.snapshot.programScroll)
    }

    func testAScrollIsAppliedDuringARenderHold() {
        let (core, frame) = make(100)
        let s0 = core.scroll.snapshot
        core.feed(Array("\u{1b}[?2026h".utf8))
        core.sync()
        _ = frame.update(core: core)
        core.scrollViewport(.position(px: 20 * s0.cellHeight, rebaseSeen: s0.rebase))
        XCTAssertTrue(frame.update(core: core), "upstream: a hold may be ignored when someone scrolls")
        XCTAssertEqual(core.scroll.snapshot.offset, 20)
        core.feed(Array("\u{1b}[?2026l".utf8))
        core.sync()
    }

    func testAScrollIsAppliedDuringTheCatchUpHold() {
        let (core, frame) = make(100)
        let s0 = core.scroll.snapshot
        core.setCatchUpHold(true)
        _ = frame.update(core: core)
        // Into the history while the stream catches up: it keeps drawing.
        core.scrollViewport(.position(px: 20 * s0.cellHeight, rebaseSeen: s0.rebase))
        XCTAssertTrue(core.scroll.hasRequest)
        XCTAssertTrue(frame.update(core: core), "a scroll draws through the catch-up hold")
        XCTAssertEqual(core.scroll.snapshot.offset, 20)
        core.setCatchUpHold(false)
    }

    func testANewCoverWaitsForTheCatchUpHoldsLastFrame() {
        let (core, frame) = make(100)
        let cell = core.scroll.snapshot.cellHeight
        let shown = frame.rows.map(\.glyphs.count)
        core.setCatchUpHold(true)
        // The stream catches up to another grid's output, and the pane's layout follows it.
        core.feed(lines(101...103))
        core.sync()
        core.scroll.setCover(px: 4 * cell)
        XCTAssertTrue(core.scroll.hasPending, "a cover to take")
        XCTAssertFalse(core.scroll.hasRequest, "nothing asked to move the view")
        for _ in 0..<3 {
            _ = frame.update(core: core)
            XCTAssertEqual(core.scroll.snapshot.covered, 0, "no frame was built for the cover")
            XCTAssertEqual(frame.scrollOffset, 0)
            XCTAssertEqual(frame.rows.map(\.glyphs.count), shown, "still the screen of the hold's start")
        }
        XCTAssertTrue(core.scroll.hasPending, "the cover is still wanted")
        core.setCatchUpHold(false)
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(core.scroll.snapshot.covered, 4 * cell, "the hold's last frame took it")
        XCTAssertEqual(core.scroll.snapshot.bounce, 4 * cell)
        XCTAssertEqual(frame.scrollOffset, 4 * cell)
        XCTAssertFalse(core.scroll.hasPending)
    }

    func testANewCoverUnderAHoldThatIsNeverReleasedIsTakenAtTheLimit() {
        let (core, frame) = make(100)
        let cell = core.scroll.snapshot.cellHeight
        core.setCatchUpHold(true)
        core.scroll.setCover(px: 4 * cell)
        _ = frame.update(core: core)
        XCTAssertEqual(core.scroll.snapshot.covered, 0)
        XCTAssertTrue(frame.update(core: core, now: CACurrentMediaTime() + GhosttyCore.renderHoldTimeout + 0.1),
                      "the hold never sticks: after a second the screen follows again")
        XCTAssertEqual(core.scroll.snapshot.covered, 4 * cell)
        XCTAssertEqual(frame.scrollOffset, 4 * cell)
        XCTAssertFalse(core.scroll.hasPending)
    }

    func testANewCoverStillDrawsThroughAProgramsOwnHold() {
        let (core, frame) = make(100)
        let cell = core.scroll.snapshot.cellHeight
        core.feed(Array("\u{1b}[?2026h".utf8))
        core.sync()
        _ = frame.update(core: core)
        core.scroll.setCover(px: 4 * cell)
        XCTAssertTrue(frame.update(core: core), "the prompt comes above the keyboard at once")
        XCTAssertEqual(core.scroll.snapshot.covered, 4 * cell)
        XCTAssertEqual(frame.scrollOffset, 4 * cell)
        core.feed(Array("\u{1b}[?2026l".utf8))
        core.sync()
    }

    // MARK: Row reuse

    /// Rows as the renderer would draw them, for comparing two builders.
    private func drawn(_ frame: GhosttyFrameBuilder) -> [[UInt64]] {
        frame.rows.map { row in
            row.glyphs.array.map { UInt64($0.u) << 48 | UInt64($0.v) << 32 | UInt64($0.color) }
                + row.glyphs.array.map { UInt64(UInt16(bitPattern: $0.x)) << 32 | UInt64($0.col) << 16 | UInt64($0.row) }
                + row.backgrounds.array.map { UInt64($0.color) << 32 | UInt64($0.w) << 16 | UInt64($0.row) }
        }
    }

    func testAScrollStepReusesBuiltRows() {
        let (core, frame) = make(200, cols: 80, rows: 60)
        let atlas = frame.atlas
        let s0 = core.scroll.snapshot
        // The first step up also brings in the overscan row: every old row is still on screen.
        core.scrollViewport(.position(px: s0.position - s0.cellHeight, rebaseSeen: s0.rebase))
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rows.count, 61)
        XCTAssertEqual(frame.rowsBuilt, 1, "only the row that came into view")
        XCTAssertEqual(frame.rowsReused, 60)
        // Steady state: one row leaves at the bottom, one enters at the top.
        for step in 2...20 {
            core.scrollViewport(.position(px: s0.position - step * s0.cellHeight, rebaseSeen: s0.rebase))
            XCTAssertTrue(frame.update(core: core))
            XCTAssertEqual(frame.rowsBuilt, 1)
            XCTAssertEqual(frame.rowsReused, 60)
        }
        XCTAssertEqual(frame.rows.map(\.y), Array(0...60), "reused rows are restamped with their new place")

        // Exactly what building everything from scratch gives.
        let fresh = GhosttyFrameBuilder(atlas: atlas)
        fresh.invalidate()
        XCTAssertTrue(fresh.update(core: core))
        XCTAssertEqual(drawn(frame), drawn(fresh))

        // A jump with nothing in common rebuilds everything.
        core.scrollViewport(.top)
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rowsReused, 0)
        XCTAssertEqual(frame.rowsBuilt, 61)
    }

    func testReuseCanBeTurnedOffAndGivesTheSameRows() {
        let (core, frame) = make(200, cols: 80, rows: 60)
        frame.reusesRowsOnScroll = false
        let s0 = core.scroll.snapshot
        core.scrollViewport(.position(px: s0.position - 3 * s0.cellHeight, rebaseSeen: s0.rebase))
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rowsBuilt, 61)
        XCTAssertEqual(frame.rowsReused, 0)
    }

    func testARowThatChangedDuringTheScrollIsRebuilt() {
        let (core, frame) = make(200, cols: 80, rows: 60)
        let s0 = core.scroll.snapshot
        core.scrollViewport(.position(px: s0.position - 5 * s0.cellHeight, rebaseSeen: s0.rebase))
        XCTAssertTrue(frame.update(core: core))
        // Rows of the active area are on screen. One changes, and the view scrolls, in one frame.
        core.feed(Array("\u{1b}[10;1H\u{1b}[41mCHANGED\u{1b}[0m".utf8))
        core.sync()
        core.scrollViewport(.position(px: s0.position - 6 * s0.cellHeight, rebaseSeen: s0.rebase))
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rowsBuilt, 2, "the new top row and the changed row")
        XCTAssertEqual(frame.rowsReused, 59)
        let fresh = GhosttyFrameBuilder(atlas: frame.atlas)
        XCTAssertTrue(fresh.update(core: core))
        XCTAssertEqual(drawn(frame), drawn(fresh))
        XCTAssertTrue(frame.rows.contains { $0.backgrounds.count > 0 })
    }

    func testRowsWithGraphemeClustersAreNotReused() {
        let core = GhosttyCore(cols: 40, rows: 10)
        var text = ""
        for i in 1...60 { text += i % 2 == 0 ? "e\u{301} cluster \(i)\r\n" : "plain \(i)\r\n" }
        core.feed(Array(text.utf8))
        core.sync()
        let frame = GhosttyFrameBuilder(atlas: GhosttyGlyphAtlas(pointSize: 12, scale: 2))
        XCTAssertTrue(frame.update(core: core))
        let s0 = core.scroll.snapshot
        core.scrollViewport(.position(px: s0.position - 2 * s0.cellHeight, rebaseSeen: s0.rebase))
        XCTAssertTrue(frame.update(core: core))
        core.scrollViewport(.position(px: s0.position - 3 * s0.cellHeight, rebaseSeen: s0.rebase))
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rows.count, 11)
        XCTAssertEqual(frame.rowsReused, 5, "the plain rows that stayed")
        XCTAssertEqual(frame.rowsBuilt, 6)
    }

    func testOutputThatScrollsReusesRowsToo() {
        // Output that scrolls the screen marks every row dirty, like a scroll step. The rows
        // that only moved up are reused the same way (more in GhosttyPerfTests).
        let (core, frame) = make(200, cols: 80, rows: 24)
        core.feed(lines(201...201))
        core.sync()
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rowsBuilt, 2, "the new line and the empty line under it")
        XCTAssertEqual(frame.rowsReused, 22)
        let fresh = GhosttyFrameBuilder(atlas: frame.atlas)
        XCTAssertTrue(fresh.update(core: core))
        XCTAssertEqual(drawn(frame), drawn(fresh))
    }

    // MARK: Performance

    func testScrollStepCostWithAndWithoutRowReuse() throws {
        guard let metal = GhosttyMetal.shared else { throw XCTSkip("no Metal device") }
        let cols = 80, rows = 60
        let core = GhosttyCore(cols: cols, rows: rows)
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 3)
        let renderer = GhosttyRenderer(core: core, atlas: atlas)
        let m = atlas.metrics
        core.resize(cols: cols, rows: rows, cellWidthPx: m.cellWidth, cellHeightPx: m.cellHeight)
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GhosttyMetal.pixelFormat, width: cols * m.cellWidth,
                                                         height: rows * m.cellHeight, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        let texture = try XCTUnwrap(metal.device.makeTexture(descriptor: d))
        var text = ""
        for i in 1...10_000 {
            text += "\u{1b}[3\(i % 7 + 1)m\(i)\u{1b}[0m \u{1b}[1mdrwxr-xr-x\u{1b}[0m user \u{1b}[44m staff \u{1b}[0m "
            text += String(repeating: "file-\(i).swift ", count: 3) + "\r\n"
        }
        core.feed(Array(text.utf8))
        core.sync()
        renderer.renderOffscreen(into: texture)
        let s0 = core.scroll.snapshot
        XCTAssertGreaterThan(s0.maxRow, 9_000)

        /// Scrolls up one row per frame, as a slow drag does, and returns seconds per frame.
        func run(reuse: Bool, frames: Int, from start: Int) -> (build: Double, encode: Double) {
            renderer.frame.reusesRowsOnScroll = reuse
            var build = 0.0, encode = 0.0
            for i in 1...frames {
                core.scrollViewport(.position(px: start - i * s0.cellHeight, rebaseSeen: s0.rebase))
                renderer.renderOffscreen(into: texture)
                XCTAssertEqual(renderer.frame.rowsBuilt, reuse ? 1 : rows + 1)
                build += renderer.lastBuildSeconds
                encode += renderer.lastEncodeSeconds
            }
            return (build / Double(frames), encode / Double(frames))
        }
        _ = run(reuse: true, frames: 50, from: s0.position)
        let with = run(reuse: true, frames: 400, from: s0.position - 50 * s0.cellHeight)
        let without = run(reuse: false, frames: 400, from: s0.position - 450 * s0.cellHeight)
        print(String(format: "SCROLLPERF step %dx%d: row reuse build %.3f ms + encode %.3f ms = %.3f ms per frame; no reuse build %.3f ms + encode %.3f ms = %.3f ms per frame",
                     cols, rows, with.build * 1000, with.encode * 1000, (with.build + with.encode) * 1000,
                     without.build * 1000, without.encode * 1000, (without.build + without.encode) * 1000))
        XCTAssertLessThan(with.build, without.build, "reuse must be cheaper than rebuilding")
        XCTAssertLessThan(with.build + with.encode, 0.004, "half a 120 Hz frame")

        // Sub-row steps (most frames of a drag): no terminal call, no row work.
        var fractionBuild = 0.0
        let base = s0.position - 900 * s0.cellHeight
        for i in 0..<300 {
            core.scrollViewport(.position(px: base + i % (s0.cellHeight - 1) + 1, rebaseSeen: s0.rebase))
            renderer.renderOffscreen(into: texture)
            if i > 0 { XCTAssertEqual(renderer.frame.rowsBuilt + renderer.frame.rowsReused, 0) }
            fractionBuild += renderer.lastBuildSeconds
        }
        print(String(format: "SCROLLPERF sub-row step %dx%d: build %.4f ms per frame", cols, rows, fractionBuild / 300 * 1000))
    }

    func testAScrollFrameAllocatesNothingInTheSteadyState() throws {
        let (core, frame) = make(2_000, cols: 80, rows: 60)
        let s0 = core.scroll.snapshot
        let cell = s0.cellHeight
        // Warm up: row storage, scratch arrays and glyphs for every digit.
        for i in 1...300 {
            core.scrollViewport(.position(px: s0.position - i * cell, rebaseSeen: s0.rebase))
            XCTAssertTrue(frame.update(core: core))
        }
        // The library's own part of a frame (viewport move and render state update), to subtract.
        func libraryOnly(_ steps: ClosedRange<Int>, px: (Int) -> Int) -> Int {
            AllocationCounter.measure {
                var i = steps.lowerBound
                while i <= steps.upperBound {
                    core.scrollViewport(.position(px: px(i), rebaseSeen: s0.rebase))
                    if core.lockFrame(now: 0) != nil { core.unlockFrame() }
                    i += 1
                }
            } ?? 0
        }

        // Row steps: every frame moves the viewport one row. 60 rows are reused, one is built.
        var frames = 0, built = 0, reused = 0
        let rowSteps = AllocationCounter.measure {
            var i = 301
            while i <= 600 {
                core.scrollViewport(.position(px: s0.position - i * cell, rebaseSeen: s0.rebase))
                if frame.update(core: core) { frames += 1 }
                built += frame.rowsBuilt
                reused += frame.rowsReused
                i += 1
            }
        }
        guard let rowSteps else { throw XCTSkip("malloc_logger is not available here") }
        let rowLibrary = libraryOnly(601...900) { s0.position - $0 * cell }
        XCTAssertEqual(frames, 300)
        XCTAssertEqual(built, 300)
        XCTAssertEqual(reused, 300 * 60)

        // Sub-row steps: most frames of a drag. Nothing is built at all.
        let base = s0.position - 1_000 * cell
        core.scrollViewport(.position(px: base, rebaseSeen: s0.rebase))
        XCTAssertTrue(frame.update(core: core))
        frames = 0
        let subRow = AllocationCounter.measure {
            var i = 1
            while i <= 300 {
                core.scrollViewport(.position(px: base + 1 + i % (cell - 1), rebaseSeen: s0.rebase))
                if frame.update(core: core) { frames += 1 }
                i += 1
            }
        } ?? -1
        let subRowLibrary = libraryOnly(1...300) { base + 1 + $0 % (cell - 1) }
        XCTAssertEqual(frames, 300)

        print("SCROLLPERF allocations per frame: sub-row step \(Double(subRow - subRowLibrary) / 300) ours + \(Double(subRowLibrary) / 300) libghostty-vt; "
            + "row step \(Double(rowSteps - rowLibrary) / 300) ours + \(Double(rowLibrary) / 300) libghostty-vt")
        XCTAssertEqual(subRow - subRowLibrary, 0, "a sub-row scroll frame allocates nothing of ours")
        // Reusing 60 rows allocates nothing. Building the one new row may box the row builder's
        // captured locals in an unoptimized build (5 per row, plus a glyph now and then).
        XCTAssertLessThanOrEqual(rowSteps - rowLibrary, 6 * built)
    }
}

@MainActor
final class GhosttyScrollViewTests: XCTestCase {
    private final class Sink: TerminalEngineDelegate {
        var sent: [[UInt8]] = []
        func engineGridChanged(cols: Int, rows: Int) {}
        func engineSend(_ bytes: [UInt8]) { sent.append(bytes) }
    }

    /// A view with its grid filling its bounds, `count` lines printed and one frame's state applied.
    private func make(_ count: Int, cols: Int = 40, rows: Int = 10) -> GhosttyTerminalView {
        let view = GhosttyTerminalView(frame: .zero, fontSize: 12, cols: cols, rows: rows)
        let cell = view.cellSize
        view.frame = CGRect(x: 0, y: 0, width: CGFloat(cols) * cell.width, height: CGFloat(rows) * cell.height)
        view.layoutIfNeeded()
        if count > 0 { view.feed(text: (1...count).map { "\($0) line\r\n" }.joined()) }
        frame(view)
        return view
    }

    /// Runs one frame the way the render thread would, and hands its state to the scroller.
    private func frame(_ view: GhosttyTerminalView) {
        view.core.sync()
        _ = view.renderer.frame.update(core: view.core)
        view.scroller.apply(view.core.scroll.snapshot)
    }

    func testTheSurfaceCoversTheViewAndIsConfiguredLikeANativeScrollView() {
        let view = make(100)
        let surface = view.scroller.surface
        XCTAssertTrue(surface.superview === view)
        XCTAssertEqual(surface.frame, view.bounds)
        XCTAssertTrue(view.subviews.last === surface, "above the Metal view")
        XCTAssertFalse(surface.scrollsToTop)
        XCTAssertTrue(surface.showsVerticalScrollIndicator)
        XCTAssertFalse(surface.showsHorizontalScrollIndicator)
        XCTAssertEqual(surface.contentInsetAdjustmentBehavior, .never)
        XCTAssertTrue(surface.bounces)
        XCTAssertTrue(view.scrollPanRecognizer === surface.panGestureRecognizer)
        view.frame.size.height += 40
        view.layoutIfNeeded()
        XCTAssertEqual(surface.frame, view.bounds)
    }

    func testContentSizeAndOffsetFollowTheTerminal() {
        let view = make(100)
        let surface = view.scroller.surface
        let cell = view.cellSize.height
        XCTAssertEqual(surface.contentSize.height, 91 * cell + surface.bounds.height, accuracy: 0.01)
        XCTAssertEqual(surface.contentSize.width, surface.bounds.width)
        XCTAssertEqual(surface.contentOffset.y, 91 * cell, accuracy: 0.01, "at the bottom")
        // Output while following: the content grows and the offset stays at its end.
        view.feed(text: (101...120).map { "\($0) line\r\n" }.joined())
        frame(view)
        XCTAssertEqual(surface.contentOffset.y, 111 * cell, accuracy: 0.01)
        XCTAssertEqual(surface.contentSize.height - surface.bounds.height, 111 * cell, accuracy: 0.01)
    }

    func testScrollingTheSurfaceScrollsTheTerminalAndOutputLeavesItThere() {
        let view = make(100)
        let surface = view.scroller.surface
        let cell = view.cellSize.height
        view.scroller.setOffset(30.5 * cell, animated: false)
        frame(view)
        var s = view.core.scroll.snapshot
        XCTAssertEqual(s.offset, 30)
        XCTAssertEqual(s.fraction, s.cellHeight / 2, accuracy: 1)
        XCTAssertEqual(view.core.rowText(0), "31 line")
        view.feed(text: (101...150).map { "\($0) line\r\n" }.joined())
        frame(view)
        s = view.core.scroll.snapshot
        XCTAssertEqual(s.offset, 30)
        XCTAssertEqual(surface.contentOffset.y, 30.5 * cell, accuracy: 0.34, "the view didn't move")
        XCTAssertEqual(surface.contentSize.height - surface.bounds.height, 141 * cell, accuracy: 0.01, "there is more below")
    }

    func testThemeStylesTheIndicator() {
        let view = make(10)
        view.apply(theme: ThemeStore.theme("github-dark-dimmed"))
        frame(view)
        XCTAssertEqual(view.scroller.surface.indicatorStyle, .white)
        if let light = ThemeStore.all.first(where: { !$0.isDark }) {
            view.apply(theme: light)
            frame(view)
            XCTAssertEqual(view.scroller.surface.indicatorStyle, .black)
        }
    }

    func testInputJumpsBackToTheBottomAndOutputDoesNot() {
        let view = make(100)
        let cell = view.cellSize.height
        view.scroller.setOffset(20 * cell, animated: false)
        frame(view)
        XCTAssertFalse(view.core.scroll.snapshot.active)
        view.feed(text: "more output\r\n")
        frame(view)
        XCTAssertFalse(view.core.scroll.snapshot.active, "output alone never moves a scrolled-up view")
        view.scrollToBottomForInput()
        frame(view)
        XCTAssertTrue(view.core.scroll.snapshot.active)
        XCTAssertEqual(view.scroller.surface.contentOffset.y, 92 * cell, accuracy: 0.01)
    }

    func testScrollPageAndPrompt() {
        let view = make(100)
        let sink = Sink()
        view.engineDelegate = sink
        view.scrollPage(up: true)
        frame(view)
        XCTAssertEqual(view.core.scroll.snapshot.offset, 81)
        XCTAssertEqual(view.scroller.surface.contentOffset.y, 81 * view.cellSize.height, accuracy: 0.01)
        view.scrollPage(up: false)
        frame(view)
        XCTAssertTrue(view.core.scroll.snapshot.active)
        XCTAssertTrue(sink.sent.isEmpty)
        // On an alternate screen the program gets the key instead.
        view.feed(text: "\u{1b}[?1049h")
        frame(view)
        view.scrollPage(up: true)
        view.scrollPage(up: false)
        XCTAssertEqual(sink.sent, [Array("\u{1b}[5~".utf8), Array("\u{1b}[6~".utf8)])
        view.scrollToPrompt(next: false)
        frame(view)
    }

    func testProgramScrollTakesOneFingerDragsAndLeavesTwoForScrollback() {
        let view = make(100)
        let scroller = view.scroller
        XCTAssertFalse(scroller.programPan.isEnabled)
        XCTAssertEqual(scroller.surface.panGestureRecognizer.minimumNumberOfTouches, 1)
        view.feed(text: "\u{1b}[?1000h")
        frame(view)
        XCTAssertTrue(scroller.programPan.isEnabled)
        XCTAssertEqual(scroller.surface.panGestureRecognizer.minimumNumberOfTouches, 2)
        view.feed(text: "\u{1b}[?1000l\u{1b}[?1049h")
        frame(view)
        XCTAssertTrue(scroller.programPan.isEnabled, "an alternate screen has no scrollback to pan")
        view.feed(text: "\u{1b}[?1049l")
        frame(view)
        XCTAssertFalse(scroller.programPan.isEnabled)
        XCTAssertEqual(scroller.surface.panGestureRecognizer.minimumNumberOfTouches, 1)
    }

    func testGatesDecideWhetherPansAndTheTapBegin() {
        let view = make(100)
        let scroller = view.scroller
        let pan = scroller.surface.panGestureRecognizer
        XCTAssertTrue(scroller.shouldBegin(pan))
        var asked: [UIPanGestureRecognizer] = []
        view.panGate = { asked.append($0); return false }
        XCTAssertFalse(scroller.shouldBegin(pan))
        XCTAssertFalse(scroller.shouldBegin(scroller.programPan))
        XCTAssertFalse(scroller.shouldBegin(scroller.pointerScrolls[0]))
        XCTAssertEqual(asked.count, 3, "every pan of the view asks the gate")
        view.panGate = nil
        XCTAssertFalse(scroller.shouldBegin(scroller.pointerScrolls[0]), "no program to scroll: the scroll view takes it")
        view.feed(text: "\u{1b}[?1000h")
        frame(view)
        XCTAssertTrue(scroller.shouldBegin(scroller.pointerScrolls[0]))
        XCTAssertTrue(scroller.shouldBegin(scroller.pointerScrolls[1]))
        XCTAssertEqual(scroller.pointerScrolls.map(\.allowedScrollTypesMask), [.continuous, .discrete])
        XCTAssertTrue(scroller.pointerScrolls.allSatisfy { $0.allowedTouchTypes.isEmpty })

        XCTAssertTrue(scroller.shouldBegin(scroller.tap))
        view.tapGate = { false }
        XCTAssertFalse(scroller.shouldBegin(scroller.tap))
    }

    func testWheelDragSendsWheelReportsLineByLine() {
        let view = make(5)
        let sink = Sink()
        view.engineDelegate = sink
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        frame(view)
        let cell = view.cellSize
        let point = CGPoint(x: cell.width * 2.5, y: cell.height * 1.5)
        var accumulator = GhosttyWheelAccumulator()
        XCTAssertEqual(view.scroller.forwardWheel(distance: cell.height * 0.6, at: point, accumulator: &accumulator), [])
        // The finger moved down a line in total: wheel up, at the cell under it.
        XCTAssertEqual(view.scroller.forwardWheel(distance: cell.height * 0.6, at: point, accumulator: &accumulator),
                       Array("\u{1b}[<64;3;2M".utf8))
        XCTAssertEqual(view.scroller.forwardWheel(distance: -cell.height * 2.3, at: point, accumulator: &accumulator),
                       Array("\u{1b}[<65;3;2M\u{1b}[<65;3;2M".utf8))
        XCTAssertEqual(sink.sent.count, 2)
        // A notched wheel is one report however far it says it went.
        XCTAssertEqual(view.scroller.forwardWheel(distance: cell.height * 9, at: point, accumulator: &accumulator, precise: false),
                       Array("\u{1b}[<64;3;2M".utf8))
        // Outside the view nothing is reported.
        XCTAssertEqual(view.scroller.forwardWheel(distance: cell.height * 3, at: CGPoint(x: -5, y: 5), accumulator: &accumulator), [])
        // Shift keeps the scroll away from the program.
        XCTAssertEqual(view.scroller.forwardWheel(distance: cell.height * 3, at: point, flags: .shift, accumulator: &accumulator), [])
        // The key bar's ctrl goes along.
        view.controlModifier = true
        XCTAssertEqual(view.scroller.forwardWheel(distance: cell.height, at: point, accumulator: &accumulator),
                       Array("\u{1b}[<80;3;2M".utf8))
    }

    func testAlternateScrollSendsArrowKeysAndRespectsCursorKeyMode() {
        let view = make(5)
        let sink = Sink()
        view.engineDelegate = sink
        let cell = view.cellSize
        let point = CGPoint(x: 2, y: 2)
        var accumulator = GhosttyWheelAccumulator()
        // Alternate screen, alternate scroll off: the drag does nothing.
        view.feed(text: "\u{1b}[?1049h\u{1b}[?1007l")
        frame(view)
        XCTAssertEqual(view.scroller.forwardWheel(distance: cell.height * 2, at: point, accumulator: &accumulator), [])
        view.feed(text: "\u{1b}[?1007h")
        frame(view)
        XCTAssertEqual(view.scroller.forwardWheel(distance: cell.height * 2, at: point, accumulator: &accumulator),
                       Array("\u{1b}[A\u{1b}[A".utf8))
        XCTAssertEqual(view.scroller.forwardWheel(distance: -cell.height, at: point, accumulator: &accumulator), Array("\u{1b}[B".utf8))
        view.feed(text: "\u{1b}[?1h")
        frame(view)
        XCTAssertEqual(view.scroller.forwardWheel(distance: cell.height, at: point, accumulator: &accumulator), Array("\u{1b}OA".utf8))
        // Mouse tracking wins over alternate scroll.
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        frame(view)
        XCTAssertEqual(view.scroller.forwardWheel(distance: cell.height, at: point, accumulator: &accumulator),
                       Array("\u{1b}[<64;1;1M".utf8))
        // Back on the main screen with nothing tracking: nothing is sent.
        view.feed(text: "\u{1b}[?1000l\u{1b}[?1049l")
        frame(view)
        XCTAssertEqual(view.scroller.forwardWheel(distance: cell.height * 3, at: point, accumulator: &accumulator), [])
    }

    func testTapSendsPressAndReleaseAtTheCell() {
        let view = make(5)
        let sink = Sink()
        view.engineDelegate = sink
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        frame(view)
        let cell = view.cellSize
        let bytes = view.scroller.forwardTap(at: CGPoint(x: cell.width * 4.2, y: cell.height * 2.9))
        XCTAssertEqual(bytes, Array("\u{1b}[<0;5;3M\u{1b}[<0;5;3m".utf8))
        XCTAssertEqual(sink.sent, [bytes])
        // X10 tracking reports presses only.
        view.feed(text: "\u{1b}[?1000l\u{1b}[?1006l\u{1b}[?9h")
        frame(view)
        XCTAssertEqual(view.scroller.forwardTap(at: CGPoint(x: cell.width * 0.5, y: cell.height * 0.5)), [0x1b, 0x5b, 0x4d, 32, 33, 33])
        // The key bar's one-shot ctrl is used up by the click.
        view.feed(text: "\u{1b}[?9l\u{1b}[?1000h\u{1b}[?1006h")
        frame(view)
        view.controlModifier = true
        let reset = expectation(forNotification: .terminalEngineControlModifierReset, object: view)
        XCTAssertEqual(view.scroller.forwardTap(at: CGPoint(x: 1, y: 1)), Array("\u{1b}[<16;1;1M\u{1b}[<16;1;1m".utf8))
        XCTAssertFalse(view.controlModifier)
        wait(for: [reset], timeout: 1)
        // No tracking: no bytes.
        view.feed(text: "\u{1b}[?1000l")
        frame(view)
        XCTAssertEqual(view.scroller.forwardTap(at: CGPoint(x: 1, y: 1)), [])
    }

    func testMouseEventsOnScrollbackRowsAreNotReported() {
        let view = make(100)
        view.feed(text: "\u{1b}[?1000h\u{1b}[?1006h")
        frame(view)
        let cell = view.cellSize
        // Scrolled up 4 rows: the top 4 rows show scrollback, row 4 is the screen's first row.
        view.scroller.jump(.lines(-4))
        frame(view)
        XCTAssertNil(view.scroller.mousePosition(CGPoint(x: 5, y: cell.height * 3.5)))
        let p = view.scroller.mousePosition(CGPoint(x: 5, y: cell.height * 4.5))
        XCTAssertEqual(p?.y ?? -1, cell.height * 0.5 * view.displayScale, accuracy: 1)
        XCTAssertEqual(view.scroller.forwardTap(at: CGPoint(x: 5, y: cell.height * 3.5)), [])
        XCTAssertEqual(view.scroller.forwardTap(at: CGPoint(x: 5, y: cell.height * 5.5)), Array("\u{1b}[<0;1;2M\u{1b}[<0;1;2m".utf8))
    }

    func testHelpersForSelection() {
        let view = make(100)
        let cell = view.cellSize
        XCTAssertTrue(view.viewportCell(at: CGPoint(x: cell.width * 3.5, y: cell.height * 2.5)) == (3, 2))
        XCTAssertTrue(view.viewportCell(at: CGPoint(x: -4, y: -4)) == (0, 0))
        XCTAssertTrue(view.viewportCell(at: CGPoint(x: 9_999, y: 9_999)) == (39, 9))
        XCTAssertEqual(view.scrollbackRow(ofViewportRow: 2), 93)
        // Half a row scrolled past: points map half a row further down, rects sit half a row up.
        view.scroller.setOffset(30.5 * cell.height, animated: false)
        frame(view)
        XCTAssertTrue(view.viewportCell(at: CGPoint(x: 1, y: cell.height * 0.75)) == (0, 1))
        XCTAssertEqual(view.scrollbackRow(ofViewportRow: 1), 31)
        let rect = view.viewportRect(row: 1, columns: 2..<5)
        XCTAssertEqual(rect.minY, cell.height * 0.5, accuracy: 0.34)
        XCTAssertEqual(rect.minX, cell.width * 2, accuracy: 0.01)
        XCTAssertEqual(rect.width, cell.width * 3, accuracy: 0.01)
        XCTAssertEqual(rect.height, cell.height, accuracy: 0.01)
        // Autoscroll at the edges, one line at a time.
        XCTAssertEqual(view.autoscrollSelection(at: CGPoint(x: 10, y: cell.height * 5)), 0)
        XCTAssertEqual(view.autoscrollSelection(at: CGPoint(x: 10, y: 1)), -1)
        frame(view)
        XCTAssertEqual(view.core.scroll.snapshot.offset, 29)
        XCTAssertEqual(view.autoscrollSelection(at: CGPoint(x: 10, y: view.bounds.height - 1)), 1)
        frame(view)
        XCTAssertEqual(view.core.scroll.snapshot.offset, 30)
        view.scroller.jump(.bottom)
        frame(view)
        XCTAssertEqual(view.autoscrollSelection(at: CGPoint(x: 10, y: view.bounds.height - 1)), 0, "nowhere to go")
    }

    func testMainThreadCostOfAScrollStepThroughTenThousandLines() {
        let view = make(0, cols: 80, rows: 60)
        view.feed(text: (1...10_000).map { "\($0) line of scrollback\r\n" }.joined())
        frame(view)
        let scroller = view.scroller
        let bottom = scroller.surface.contentSize.height - scroller.surface.bounds.height
        XCTAssertGreaterThan(view.core.scroll.snapshot.maxRow, 9_000)
        let updates = scroller.updates
        scroller.measures = true
        let steps = 5_000
        // A fling: every step moves the offset; the render thread is not running here, so this
        // is exactly the work a scroll step puts on the main thread.
        for i in 1...steps {
            scroller.setOffset(bottom - CGFloat(i) * bottom / CGFloat(steps), animated: false)
        }
        XCTAssertEqual(scroller.scrollSteps, steps)
        XCTAssertEqual(scroller.updates, updates, "a fling brings nothing back to the main thread")
        let each = scroller.scrollStepSeconds / Double(steps)
        print(String(format: "SCROLLPERF main thread per scroll step over 10k lines: %.3f us", each * 1e6))
        XCTAssertLessThan(each, 0.0001)
        frame(view)
        XCTAssertEqual(view.core.scroll.snapshot.offset, 0)
    }

    func testOutputWhilePinnedIsCoalescedForTheMainThread() {
        let view = make(100)
        let scroller = view.scroller
        let pumped = expectation(description: "main queue ran")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { pumped.fulfill() }
        wait(for: [pumped], timeout: 2)
        let before = scroller.updates
        // 200 chunks of output, each drawn as its own frame.
        for i in 0..<200 {
            view.feed(text: "chunk \(i)\r\n")
            view.core.sync()
            _ = view.renderer.frame.update(core: view.core)
        }
        let settled = expectation(description: "published")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { settled.fulfill() }
        wait(for: [settled], timeout: 2)
        XCTAssertLessThanOrEqual(scroller.updates - before, 2, "one update for the whole burst, not one per chunk")
        XCTAssertGreaterThanOrEqual(scroller.updates - before, 1)
        let cell = view.cellSize.height
        XCTAssertEqual(scroller.surface.contentOffset.y, 291 * cell, accuracy: 0.01, "still pinned to the bottom")
    }

    /// Lets a drag go at the current offset with no momentum, as UIKit asks the delegate, and
    /// returns where it will come to rest.
    private func letGo(_ view: GhosttyTerminalView) -> CGFloat {
        let surface = view.scroller.surface
        var target = surface.contentOffset
        view.scroller.scrollViewWillEndDragging(surface, withVelocity: .zero, targetContentOffset: &target)
        view.scroller.setOffset(target.y, animated: false)
        frame(view)
        return target.y
    }

    func testAReleaseWithinARowOfThePinSticksAndOneFurtherUpStaysUnderOutput() {
        // 100 lines and the cursor's row on a screen of 20, the keyboard over 8 of them.
        let view = make(100, rows: 20)
        let scroller = view.scroller
        let surface = scroller.surface
        let cell = view.cellSize.height
        view.setCover(8 * cell)
        frame(view)
        var pinned = scroller.pinnedBottom
        XCTAssertEqual(pinned, 89 * cell, accuracy: 0.5, "the last row position plus the cover")
        XCTAssertEqual(surface.contentOffset.y, pinned, accuracy: 0.5)
        // A nudge, let go half a row up: back to the pin, and output follows there.
        scroller.setOffset(pinned - cell / 2, animated: false)
        frame(view)
        XCTAssertEqual(letGo(view), pinned, accuracy: 0.01)
        XCTAssertTrue(view.core.scroll.snapshot.following)
        // Two rows up: it stays where it was let go, through output.
        scroller.setOffset(pinned - 2 * cell, animated: false)
        frame(view)
        let held = letGo(view)
        XCTAssertEqual(held, pinned - 2 * cell, accuracy: 0.01)
        XCTAssertFalse(view.core.scroll.snapshot.following)
        for i in 101...105 {
            view.feed(text: "\(i) line\r\n")
            frame(view)
            XCTAssertEqual(surface.contentOffset.y, held, accuracy: 0.34, "after line \(i)")
            XCTAssertFalse(view.core.scroll.snapshot.following, "after line \(i)")
        }
        // A key: back to the pin, below the new rows.
        view.scrollToBottomForInput()
        frame(view)
        pinned = scroller.pinnedBottom
        XCTAssertEqual(pinned, 94 * cell, accuracy: 0.5)
        XCTAssertEqual(surface.contentOffset.y, pinned, accuracy: 0.5)
        XCTAssertTrue(view.core.scroll.snapshot.following)
    }

    func testAFlingThatComesToRestNearThePinSticks() {
        XCTAssertTrue(GhosttyScroller.sticks(target: 99.5, pinned: 100, cell: 17))
        XCTAssertTrue(GhosttyScroller.sticks(target: 83, pinned: 100, cell: 17))
        XCTAssertFalse(GhosttyScroller.sticks(target: 82.9, pinned: 100, cell: 17), "more than a row up")
        XCTAssertFalse(GhosttyScroller.sticks(target: 100, pinned: 100, cell: 17), "already there")
        XCTAssertFalse(GhosttyScroller.sticks(target: 120, pinned: 100, cell: 17), "past it, into the blank rows")
    }

    /// The cover goes (the keyboard goes down, or a fold's resize lands) and a frame takes it before
    /// the main thread has heard of that frame: the render side puts the shift inside the new cover
    /// and moves the terminal by itself. The main thread, still holding a snapshot drawn with the
    /// old cover, must not put the shift right as well, or the view lands that far up in the
    /// scrollback with a part of a row showing: a fold left the last row cut in half, the rows above
    /// it ones from before, until the keyboard came up again.
    func testAShiftDecidedAgainstAnOldCoverIsPutRightOnce() {
        let view = make(100, rows: 20)
        let scroller = view.scroller
        let cell = view.cellSize.height
        let scale = view.displayScale
        view.setCover(8 * cell)
        frame(view)
        let covered = view.core.scroll.snapshot
        XCTAssertGreaterThan(covered.bounce, 0, "shifted up by the cover")
        XCTAssertEqual(covered.covered, Int((8 * cell * scale).rounded()), "and says which cover it was decided against")

        view.setCover(0)
        view.core.sync()
        _ = view.renderer.frame.update(core: view.core)
        XCTAssertEqual(view.core.scroll.snapshot.covered, 0)
        XCTAssertEqual(view.core.scroll.snapshot.bounce, 0, "the render side put the shift inside the new cover")
        // The snapshot from before reaches the main thread only now.
        scroller.apply(covered)
        frame(view)
        let s = view.core.scroll.snapshot
        XCTAssertTrue(s.active, "still at the newest rows")
        XCTAssertEqual(s.bounce, 0)
        XCTAssertEqual(s.fraction, 0, "no part of a row")
        XCTAssertEqual(scroller.surface.contentOffset.y, scroller.pinnedBottom, accuracy: 0.5)
    }

    func testTheJumpButtonCountsRowsFromThePinAndOnlyTheScrollbackPutsTheKeyboardAway() {
        let view = make(100, rows: 20)
        let scroller = view.scroller
        let cell = view.cellSize.height
        var place = GhosttyScrollPlace()
        view.scrollPlaceHook = { place = $0 }
        view.setCover(8 * cell)
        frame(view)
        XCTAssertEqual(place.rowsAbove, 0, accuracy: 0.05)
        let pinned = scroller.pinnedBottom
        // Six rows up, among the covered rows: half of the 12 that show, so the button shows.
        scroller.setOffset(pinned - 6 * cell, animated: false)
        XCTAssertEqual(place.rowsAbove, 6, accuracy: 0.05)
        var rule = JumpToBottomRule()
        _ = rule.update(.init(rowsAbove: place.rowsAbove, screenRows: 12, blocked: false, total: place.total,
                              rebase: place.rebase, sequence: place.sequence))
        XCTAssertTrue(rule.shown)
        // The keyboard goes only a row or more past the covered rows (the last row position).
        let end = 81 * cell
        XCTAssertFalse(GhosttyScroller.reads(offset: pinned - 6 * cell, end: end, cell: cell))
        XCTAssertFalse(GhosttyScroller.reads(offset: end - cell / 2, end: end, cell: cell))
        XCTAssertTrue(GhosttyScroller.reads(offset: end - 1.01 * cell, end: end, cell: cell))
    }
}

extension GhosttyScrollTests {
    // MARK: The cover (the keyboard over a grid that keeps its rows)

    func testPinKeepsTheLastRowWithContentAboveTheCover() {
        // A full screen: shifted by the whole cover.
        XCTAssertEqual(GhosttyScrollMath.pin(cover: 300, rows: 40, contentRows: 40, cellHeight: 30), 300)
        // Four blank rows at the bottom are covered first.
        XCTAssertEqual(GhosttyScrollMath.pin(cover: 300, rows: 40, contentRows: 36, cellHeight: 30), 180)
        // A screen whose content ends above the cover isn't shifted.
        XCTAssertEqual(GhosttyScrollMath.pin(cover: 300, rows: 40, contentRows: 5, cellHeight: 30), 0)
        XCTAssertEqual(GhosttyScrollMath.pin(cover: 0, rows: 40, contentRows: 40, cellHeight: 30), 0)
    }

    func testACoveredFullScreenIsShiftedByTheCoverAndBack() {
        let (core, frame) = make(100)
        let cell = core.scroll.snapshot.cellHeight
        let before = core.scroll.snapshot
        core.scroll.setCover(px: 4 * cell)
        XCTAssertTrue(core.scroll.hasPending, "a new cover needs a frame")
        XCTAssertTrue(frame.update(core: core))
        var s = core.scroll.snapshot
        XCTAssertTrue(s.active)
        XCTAssertEqual(s.offset, before.offset, "the viewport stays on the same rows")
        XCTAssertEqual(s.bounce, 4 * cell)
        XCTAssertEqual(frame.scrollOffset, 4 * cell, "the grid is drawn shifted up by the cover")
        XCTAssertEqual(s.rebase, before.rebase + 4 * cell, "the scroll view is told, as for any move it didn't make")
        XCTAssertEqual(core.gridSize.rows, 10, "the grid keeps its rows")

        core.scroll.setCover(px: 0)
        XCTAssertTrue(frame.update(core: core))
        s = core.scroll.snapshot
        XCTAssertEqual(s.bounce, 0)
        XCTAssertEqual(frame.scrollOffset, 0)
        XCTAssertEqual(s.rebase, before.rebase)
    }

    func testAShortScreenIsShiftedOnlyAsItFills() {
        // Three lines and the cursor's row on a screen of ten: six blank rows at the bottom.
        let (core, frame) = make(3)
        let cell = core.scroll.snapshot.cellHeight
        core.scroll.setCover(px: 4 * cell)
        _ = frame.update(core: core)
        XCTAssertEqual(core.scroll.snapshot.bounce, 0, "the content ends above the cover")
        // Four more lines: eight rows with content, two blank, so two rows' worth of shift.
        core.feed(lines(4...7))
        core.sync()
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(core.scroll.snapshot.bounce, 2 * cell)
        core.feed(lines(8...30))
        core.sync()
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(core.scroll.snapshot.bounce, 4 * cell, "never more than the cover")
    }

    func testTheCoveredRowsScrollIntoViewAndStayUntilInput() {
        let (core, frame) = make(100)
        let cell = core.scroll.snapshot.cellHeight
        core.scroll.setCover(px: 4 * cell)
        _ = frame.update(core: core)
        var s = core.scroll.snapshot
        let end = s.maxRow * cell
        // The scroll view, having applied the rebase, is at the last position plus the cover.
        // A drag down by two rows shows two of the covered rows; the viewport stays at the bottom.
        core.scrollViewport(.position(px: end + 2 * cell, rebaseSeen: s.rebase))
        XCTAssertTrue(frame.update(core: core))
        s = core.scroll.snapshot
        XCTAssertTrue(s.active)
        XCTAssertEqual(s.bounce, 2 * cell)
        XCTAssertFalse(s.following)
        // Output doesn't pull the view back: one new row takes one row of the shift.
        core.feed(lines(101...101))
        core.sync()
        _ = frame.update(core: core)
        s = core.scroll.snapshot
        XCTAssertTrue(s.active)
        XCTAssertFalse(s.following)
        XCTAssertEqual(s.bounce, cell)
        // On into the scrollback: no shift there.
        core.scrollViewport(.position(px: 50 * cell, rebaseSeen: s.rebase))
        _ = frame.update(core: core)
        s = core.scroll.snapshot
        XCTAssertFalse(s.active)
        XCTAssertEqual(s.bounce, 0)
        // Input jumps to the bottom, which is the pin again.
        core.scrollViewport(.bottom)
        _ = frame.update(core: core)
        s = core.scroll.snapshot
        XCTAssertTrue(s.active)
        XCTAssertTrue(s.following)
        XCTAssertEqual(s.bounce, 4 * cell)
        XCTAssertEqual(frame.scrollOffset, 4 * cell)
    }

    func testACoverChangesNothingForAViewInTheScrollback() {
        let (core, frame) = make(100)
        let cell = core.scroll.snapshot.cellHeight
        core.scrollViewport(.position(px: 50 * cell + 7, rebaseSeen: core.scroll.snapshot.rebase))
        _ = frame.update(core: core)
        let before = core.scroll.snapshot
        for cover in [4 * cell, 0, 6 * cell, 0] {
            core.scroll.setCover(px: cover)
            _ = frame.update(core: core)
            let s = core.scroll.snapshot
            XCTAssertEqual(s.offset, before.offset)
            XCTAssertEqual(s.fraction, before.fraction)
            XCTAssertEqual(s.bounce, 0)
            XCTAssertEqual(s.rebase, before.rebase, "the reading position doesn't move")
        }
    }

    func testLinesGoThroughTheCoveredRows() {
        let (core, frame) = make(100)
        let cell = core.scroll.snapshot.cellHeight
        core.scroll.setCover(px: 3 * cell)
        _ = frame.update(core: core)
        let bottom = core.scroll.snapshot.offset
        // Up two lines: two covered rows come into view, the viewport stays.
        core.scrollViewport(.lines(-2))
        _ = frame.update(core: core)
        var s = core.scroll.snapshot
        XCTAssertEqual(s.bounce, cell)
        XCTAssertEqual(s.offset, bottom)
        // Up three more: the last covered row, then the scrollback.
        core.scrollViewport(.lines(-1))
        _ = frame.update(core: core)
        core.scrollViewport(.lines(-2))
        _ = frame.update(core: core)
        s = core.scroll.snapshot
        XCTAssertEqual(s.bounce, 0)
        XCTAssertEqual(s.offset, bottom - 2)
        // And down again to the pin.
        core.scrollViewport(.lines(2))
        _ = frame.update(core: core)
        core.scrollViewport(.lines(3))
        _ = frame.update(core: core)
        s = core.scroll.snapshot
        XCTAssertTrue(s.active)
        XCTAssertEqual(s.bounce, 3 * cell)
        XCTAssertTrue(s.following)
    }

    /// The cursor's row, as drawn, ends at or above the cover's edge.
    private func assertCursorAboveCover(_ core: GhosttyCore, _ frame: GhosttyFrameBuilder, cover: Int, _ message: String,
                                        file: StaticString = #filePath, line: UInt = #line) {
        let cell = core.scroll.snapshot.cellHeight
        let bottom = (core.cursorPosition.y + 1) * cell - frame.scrollOffset
        XCTAssertLessThanOrEqual(bottom, core.gridSize.rows * cell - cover, message, file: file, line: line)
    }

    func testACoverChangeAndAPositionInOneFrameKeepFollowing() {
        // Seven lines and the cursor's row on ten: two blank rows. A cover of four rows shifts by two.
        let (core, frame) = make(7)
        let cell = core.scroll.snapshot.cellHeight
        core.scroll.setCover(px: 4 * cell)
        _ = frame.update(core: core)
        var s = core.scroll.snapshot
        XCTAssertEqual(s.bounce, 2 * cell)
        // The keyboard's top is measured again a row lower. The scroll view, settling a snapshot
        // from before onto the smaller cover, asks for the bottom in the same frame.
        core.scroll.setCover(px: cell)
        core.scrollViewport(.position(px: s.position + cell, rebaseSeen: s.rebase))
        _ = frame.update(core: core)
        s = core.scroll.snapshot
        XCTAssertTrue(s.following, "the bottom of the new cover still follows the screen")
        // Output streams, a line a frame, and the keyboard's top goes back up: the cursor's row
        // stays above the cover all along.
        for i in 8...20 {
            core.feed(lines(i...i))
            core.sync()
            _ = frame.update(core: core)
            assertCursorAboveCover(core, frame, cover: cell, "after line \(i)")
        }
        core.scroll.setCover(px: 4 * cell)
        _ = frame.update(core: core)
        for i in 21...30 {
            core.feed(lines(i...i))
            core.sync()
            _ = frame.update(core: core)
            assertCursorAboveCover(core, frame, cover: 4 * cell, "after line \(i)")
        }
        XCTAssertEqual(core.scroll.snapshot.bounce, 4 * cell)
        XCTAssertTrue(core.scroll.snapshot.following)
    }

    func testLinesInTheFrameOfACoverChangeKeepFollowing() {
        let (core, frame) = make(7)
        let cell = core.scroll.snapshot.cellHeight
        core.scroll.setCover(px: 4 * cell)
        _ = frame.update(core: core)
        XCTAssertEqual(core.scroll.snapshot.bounce, 2 * cell)
        // Up one line (into the blank covered rows) while the cover shrinks to two rows: the
        // shift is one row, and with no blank row above the new cover's edge that is the pin.
        core.scroll.setCover(px: 2 * cell)
        core.scrollViewport(.lines(-1))
        _ = frame.update(core: core)
        XCTAssertTrue(core.scroll.snapshot.following)
        for i in 8...20 {
            core.feed(lines(i...i))
            core.sync()
            _ = frame.update(core: core)
            assertCursorAboveCover(core, frame, cover: 2 * cell, "after line \(i)")
        }
    }

    /// The first row drawn, as its line number (the frame's shift is whole rows here).
    private func topLine(_ core: GhosttyCore) -> Int? {
        let s = core.scroll.snapshot
        return number(core, row: s.active ? s.bounce / max(1, s.cellHeight) : 0)
    }

    /// The pin's first case: the keyboard comes up over a view at the bottom and the prompt sits
    /// above it, then stays there as output streams.
    func testTheKeyboardShowingBringsThePromptAboveItAndOutputKeepsItThere() {
        let (core, frame) = make(100)
        let cell = core.scroll.snapshot.cellHeight
        core.scroll.setCover(px: 4 * cell)
        _ = frame.update(core: core)
        XCTAssertTrue(core.scroll.snapshot.following)
        assertCursorAboveCover(core, frame, cover: 4 * cell, "on show")
        for i in 101...110 {
            core.feed(lines(i...i))
            core.sync()
            _ = frame.update(core: core)
            assertCursorAboveCover(core, frame, cover: 4 * cell, "after line \(i)")
        }
        XCTAssertTrue(core.scroll.snapshot.following)
    }

    /// The report: a small scroll with the keyboard up, to read, snapped back to the prompt on
    /// the next output. What shows now holds still: new rows take the shift down, then the view
    /// goes on into the scrollback, and only input brings it back.
    func testASmallScrollWithTheKeyboardUpHoldsStillUnderOutput() {
        let (core, frame) = make(100)
        let cell = core.scroll.snapshot.cellHeight
        core.scroll.setCover(px: 4 * cell)
        _ = frame.update(core: core)
        var s = core.scroll.snapshot
        // Two rows up from the pin: still among the covered rows, so the keyboard stays.
        core.scrollViewport(.position(px: s.position + 2 * cell, rebaseSeen: s.rebase))
        _ = frame.update(core: core)
        s = core.scroll.snapshot
        XCTAssertFalse(s.following)
        let top = topLine(core)
        let rebase = s.rebase
        XCTAssertNotNil(top)
        for i in 101...108 {
            core.feed(lines(i...i))
            core.sync()
            _ = frame.update(core: core)
            s = core.scroll.snapshot
            XCTAssertFalse(s.following, "after line \(i): output never takes the view back to the pin")
            XCTAssertEqual(topLine(core), top, "after line \(i): what the user reads holds still")
            XCTAssertEqual(s.rebase, rebase, "after line \(i): the scroll view has nothing to move")
        }
        XCTAssertFalse(s.active, "past the covered rows the view went on into the scrollback")
        XCTAssertEqual(s.bounce, 0)
        // A key or the jump-to-bottom button: back to the pin, the cursor above the keyboard.
        core.scrollViewport(.bottom)
        _ = frame.update(core: core)
        s = core.scroll.snapshot
        XCTAssertTrue(s.active)
        XCTAssertTrue(s.following)
        XCTAssertEqual(s.bounce, 4 * cell)
        assertCursorAboveCover(core, frame, cover: 4 * cell, "after the jump")
    }

    func testAViewOffThePinStaysOffItThroughAKeyboardHeightChangeAndARefit() {
        let (core, frame) = make(100)
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let cell = core.scroll.snapshot.cellHeight
        core.scroll.setCover(px: 4 * cell)
        _ = frame.update(core: core)
        var s = core.scroll.snapshot
        core.scrollViewport(.position(px: s.position + 2 * cell, rebaseSeen: s.rebase))
        _ = frame.update(core: core)
        let top = topLine(core)
        // The keyboard's top measured again (the emoji keyboard, the key bar): nothing moves.
        for cover in [5 * cell, 3 * cell, 4 * cell] {
            core.scroll.setCover(px: cover)
            _ = frame.update(core: core)
            s = core.scroll.snapshot
            XCTAssertFalse(s.following, "cover \(cover)")
            XCTAssertEqual(s.bounce, 2 * cell, "cover \(cover)")
            XCTAssertEqual(topLine(core), top, "cover \(cover)")
        }
        // A refit with the keyboard up (a fold): the view stays off the pin, and output after it
        // still leaves what shows alone.
        core.resize(cols: 40, rows: 12, cellWidthPx: atlas.metrics.cellWidth, cellHeightPx: atlas.metrics.cellHeight)
        core.sync()
        _ = frame.update(core: core)
        s = core.scroll.snapshot
        XCTAssertFalse(s.following, "after the refit")
        let refitTop = topLine(core)
        XCTAssertNotNil(refitTop)
        core.feed(lines(101...101))
        core.sync()
        _ = frame.update(core: core)
        XCTAssertFalse(core.scroll.snapshot.following, "output after the refit")
        XCTAssertEqual(topLine(core), refitTop, "output after the refit")
    }

    func testTheKeyboardShowingAgainBringsThePromptAboveItWhereverTheViewWasLeft() {
        // Off the pin among the covered rows, the keyboard put away with the hide key, then
        // brought back with a tap: the prompt comes above it, with or without output.
        let (core, frame) = make(100)
        let cell = core.scroll.snapshot.cellHeight
        core.scroll.setCover(px: 4 * cell)
        _ = frame.update(core: core)
        var s = core.scroll.snapshot
        core.scrollViewport(.position(px: s.position + 2 * cell, rebaseSeen: s.rebase))
        _ = frame.update(core: core)
        XCTAssertFalse(core.scroll.snapshot.following)
        core.scroll.setCover(px: 0)
        _ = frame.update(core: core)
        core.scroll.setCover(px: 4 * cell)
        _ = frame.update(core: core)
        s = core.scroll.snapshot
        XCTAssertTrue(s.following)
        XCTAssertEqual(s.bounce, 4 * cell)
        assertCursorAboveCover(core, frame, cover: 4 * cell, "on show")
    }

    func testAViewOffThePinOnAShortScreenHoldsAsTheScreenFills() {
        // Blank rows under the content: lines that fill them move no row, and the shift the user
        // left stays where it is.
        let (core, frame) = make(7)
        let cell = core.scroll.snapshot.cellHeight
        core.scroll.setCover(px: 4 * cell)
        _ = frame.update(core: core)
        var s = core.scroll.snapshot
        XCTAssertEqual(s.bounce, 2 * cell)
        core.scrollViewport(.position(px: s.position + cell, rebaseSeen: s.rebase))
        _ = frame.update(core: core)
        XCTAssertFalse(core.scroll.snapshot.following)
        core.feed(lines(8...8))
        core.sync()
        _ = frame.update(core: core)
        s = core.scroll.snapshot
        XCTAssertFalse(s.following)
        XCTAssertEqual(s.bounce, cell)
    }

    func testOutputLeavesAViewInTheScrollbackStill() {
        // Reading in the scrollback with the keyboard's cover: output never moves the view,
        // with or without a finger on it. Only input or a jump returns it.
        let (core, frame) = make(100)
        let cell = core.scroll.snapshot.cellHeight
        core.scroll.setCover(px: 4 * cell)
        _ = frame.update(core: core)
        core.scrollViewport(.position(px: 40 * cell, rebaseSeen: core.scroll.snapshot.rebase))
        _ = frame.update(core: core)
        let before = core.scroll.snapshot
        let top = core.rowText(0)
        for i in 101...110 {
            core.feed(lines(i...i))
            core.sync()
            _ = frame.update(core: core)
        }
        let s = core.scroll.snapshot
        XCTAssertFalse(s.active)
        XCTAssertFalse(s.following)
        XCTAssertEqual(s.offset, before.offset)
        XCTAssertEqual(s.bounce, 0)
        XCTAssertEqual(s.rebase, before.rebase)
        XCTAssertEqual(core.rowText(0), top)
    }

    func testWithoutACoverOutputMovesNoShift() {
        // A pane with no cover (mirror, the alternate screen fitted above the keyboard) has no
        // shift for output to set.
        let (core, frame) = make(100)
        for i in 101...110 {
            core.feed(lines(i...i))
            core.sync()
            _ = frame.update(core: core)
            XCTAssertEqual(core.scroll.snapshot.bounce, 0)
            XCTAssertEqual(frame.scrollOffset, 0)
        }
        core.feed(Array("\u{1b}[?1049h".utf8))
        core.sync()
        _ = frame.update(core: core)
        XCTAssertEqual(frame.scrollOffset, 0)
    }

    func testAShiftThatFollowsOnlyMovesWhenTheContentCrossesTheCover() {
        // No jitter: while lines stream onto a short screen the shift changes only when the last
        // row with content passes the cover's edge, one row at a time, and never back.
        let (core, frame) = make(1)
        let cell = core.scroll.snapshot.cellHeight
        core.scroll.setCover(px: 4 * cell)
        _ = frame.update(core: core)
        var shifts: [Int] = []
        for i in 2...30 {
            core.feed(lines(i...i))
            core.sync()
            _ = frame.update(core: core)
            shifts.append(frame.scrollOffset)
            assertCursorAboveCover(core, frame, cover: 4 * cell, "after line \(i)")
        }
        XCTAssertEqual(shifts, shifts.sorted(), "never back")
        XCTAssertTrue(zip(shifts, shifts.dropFirst()).allSatisfy { $1 - $0 == 0 || $1 - $0 == cell }, "a row at a time")
        XCTAssertEqual(shifts.last, 4 * cell)
    }

    func testTheSnapshotSaysWhichScreenTheProgramIsOn() {
        let (core, frame) = make(20)
        XCTAssertFalse(core.scroll.snapshot.alternateScreen)
        core.feed(Array("\u{1b}[?1049h".utf8))
        core.sync()
        _ = frame.update(core: core)
        XCTAssertTrue(core.scroll.snapshot.alternateScreen)
        core.feed(Array("\u{1b}[?1049l".utf8))
        core.sync()
        _ = frame.update(core: core)
        XCTAssertFalse(core.scroll.snapshot.alternateScreen)
    }
}
