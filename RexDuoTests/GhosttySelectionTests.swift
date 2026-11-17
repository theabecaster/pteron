import XCTest
@testable import RexDuo

/// Selection for the Ghostty engine: the terminal's selection through `GhosttyCore`, the geometry
/// math, and the selection members on `GhosttyTerminalView` as TerminalHost drives them.
final class GhosttySelectionTests: XCTestCase {
    private func makeCore(_ text: String, cols: Int = 20, rows: Int = 4) -> GhosttyCore {
        let core = GhosttyCore(cols: cols, rows: rows)
        feed(core, text)
        return core
    }

    private func feed(_ core: GhosttyCore, _ text: String) {
        core.feed(Array(text.utf8))
        core.sync()
    }

    /// Long press on a cell: the word there, or nil.
    private func word(_ core: GhosttyCore, _ col: Int, _ row: Int = 0) -> String? {
        let anchor = GhosttySelectionAnchor(core: core)
        defer { core.endSelection(anchor: anchor) }
        return core.beginSelection(col: col, row: row, word: true, anchor: anchor) ? core.selectedText : nil
    }

    /// Pointer drag from one cell to another: the text between them.
    private func drag(_ core: GhosttyCore, from: (Int, Int), to: (Int, Int)) -> String? {
        let anchor = GhosttySelectionAnchor(core: core)
        defer { core.endSelection(anchor: anchor) }
        core.beginSelection(col: from.0, row: from.1, word: false, anchor: anchor)
        _ = core.extendSelection(col: to.0, row: to.1, anchor: anchor, keepOnAnchor: true)
        return core.selectedText
    }

    // MARK: Words

    func testLongPressSelectsTheWord() {
        let core = makeCore("hello world")
        XCTAssertEqual(word(core, 1), "hello")
        XCTAssertEqual(word(core, 10), "world")
        XCTAssertTrue(core.hasSelection)
    }

    func testLongPressOnASpaceOrAnEmptyCellSelectsNothingAndClears() {
        let core = makeCore("hello world")
        XCTAssertEqual(word(core, 0), "hello")
        XCTAssertNil(word(core, 5), "the space between the words")
        XCTAssertFalse(core.hasSelection, "a press that finds no word clears the old selection")
        XCTAssertNil(word(core, 15), "never written")
        XCTAssertNil(word(core, 3, 2), "an empty row")
    }

    func testPathsSelectWhole() {
        let core = makeCore("cat /usr/local/bin/rex.sh now", cols: 40)
        XCTAssertEqual(word(core, 8), "/usr/local/bin/rex.sh")
        XCTAssertEqual(word(core, 22), "/usr/local/bin/rex.sh", "the dot inside a word stays")
        let home = makeCore("ls ~/Library/a-b_c+d@e:f=g%h", cols: 40)
        XCTAssertEqual(word(home, 10), "~/Library/a-b_c+d@e:f=g%h")
    }

    func testURLsSelectWholeWithoutBracketsOrSentencePunctuation() {
        let core = makeCore("see https://example.com/a?b=1&c=2#top. ok", cols: 60)
        XCTAssertEqual(word(core, 10), "https://example.com/a?b=1&c=2#top")
        let wrapped = makeCore("(https://rex.dev/x), <me@rex.dev>; done!", cols: 60)
        XCTAssertEqual(word(wrapped, 5), "https://rex.dev/x")
        XCTAssertEqual(word(wrapped, 23), "me@rex.dev")
        XCTAssertEqual(word(wrapped, 36), "done")
    }

    func testQuotesBracketsPipesAndBoxBarsEndAWord() {
        let core = makeCore("say \"quoted\" 'one' `two` [three] {four} a|b │name│", cols: 60)
        XCTAssertEqual(word(core, 6), "quoted")
        XCTAssertEqual(word(core, 14), "one")
        XCTAssertEqual(word(core, 20), "two")
        XCTAssertEqual(word(core, 27), "three")
        XCTAssertEqual(word(core, 35), "four")
        XCTAssertEqual(word(core, 40), "a")
        XCTAssertEqual(word(core, 42), "b")
        XCTAssertEqual(word(core, 46), "name")
        XCTAssertNil(word(core, 4), "a quote is not a word")
    }

    func testTrailingPunctuationIsTrimmedButNeverTheWholeWord() {
        let core = makeCore("wait... what?! ok: ... a.b", cols: 40)
        XCTAssertEqual(word(core, 1), "wait")
        XCTAssertEqual(word(core, 9), "what")
        XCTAssertEqual(word(core, 15), "ok")
        XCTAssertEqual(word(core, 20), ".", "punctuation alone keeps its first character")
        XCTAssertEqual(word(core, 24), "a.b")
    }

    func testCJKWordsAndBothHalvesOfAWideCharacter() {
        // Each of these is two cells wide: 你 0-1, 好 2-3, 世 4-5, 界 6-7.
        let core = makeCore("你好世界 abc")
        XCTAssertEqual(word(core, 2), "你好世界")
        XCTAssertEqual(word(core, 3), "你好世界", "the right half of a wide character")
        XCTAssertEqual(word(core, 7), "你好世界")
        XCTAssertEqual(word(core, 10), "abc")
        XCTAssertEqual(core.beginSelection(col: 2, row: 0, word: true, anchor: GhosttySelectionAnchor(core: core)), true)
        XCTAssertEqual(core.selectionExtent, GhosttySelectionExtent(cols: 20, rows: 4, startCol: 0, startRow: 0, endCol: 7, endRow: 0))
    }

    /// The word follows the soft wrap; it doesn't stop at the row's edge.
    func testAWordThatWrapsIsSelectedAcrossTheRows() {
        let core = makeCore("aaaaaaaaaabbbbb ccc", cols: 10)
        XCTAssertEqual(word(core, 2, 1), "aaaaaaaaaabbbbb")
        XCTAssertEqual(word(core, 2, 0), "aaaaaaaaaabbbbb")
        XCTAssertEqual(word(core, 7, 1), "ccc")
    }

    // MARK: Drags

    func testDragForwardAndBackwardSelectBothEnds() {
        let core = makeCore("0123456789")
        XCTAssertEqual(drag(core, from: (2, 0), to: (6, 0)), "23456")
        XCTAssertEqual(drag(core, from: (6, 0), to: (2, 0)), "23456")
        XCTAssertEqual(drag(core, from: (9, 0), to: (0, 0)), "0123456789")
    }

    func testDragAcrossRowsIsLinear() {
        let core = makeCore("alpha one\r\nbravo two\r\ncharlie three")
        XCTAssertEqual(drag(core, from: (6, 0), to: (4, 2)), "one\nbravo two\ncharl")
        XCTAssertEqual(drag(core, from: (4, 2), to: (6, 0)), "one\nbravo two\ncharl")
        XCTAssertEqual(core.selectionExtent, GhosttySelectionExtent(cols: 20, rows: 4, startCol: 6, startRow: 0, endCol: 4, endRow: 2))
    }

    func testTheFingerOnItsPressCellKeepsTheWordUntilItLeaves() {
        let core = makeCore("hello world")
        let anchor = GhosttySelectionAnchor(core: core)
        XCTAssertTrue(core.beginSelection(col: 7, row: 0, word: true, anchor: anchor))
        XCTAssertEqual(core.extendSelection(col: 7, row: 0, anchor: anchor, keepOnAnchor: true), .onAnchor)
        XCTAssertEqual(core.selectedText, "world")
        // Leaving the cell turns the word into anchor...finger.
        XCTAssertEqual(core.extendSelection(col: 9, row: 0, anchor: anchor, keepOnAnchor: true), .extended(changed: true))
        XCTAssertEqual(core.selectedText, "orl")
        XCTAssertEqual(core.extendSelection(col: 9, row: 0, anchor: anchor, keepOnAnchor: false), .extended(changed: false))
        XCTAssertEqual(core.extendSelection(col: 2, row: 0, anchor: anchor, keepOnAnchor: false), .extended(changed: true))
        XCTAssertEqual(core.selectedText, "llo wo")
        // Back on the press cell after moving: that one cell.
        XCTAssertEqual(core.extendSelection(col: 7, row: 0, anchor: anchor, keepOnAnchor: false), .extended(changed: true))
        XCTAssertEqual(core.selectedText, "o")
        core.endSelection(anchor: anchor)
        XCTAssertEqual(core.selectedText, "o", "ending the drag keeps the selection")
        XCTAssertEqual(core.extendSelection(col: 0, row: 0, anchor: anchor, keepOnAnchor: false), .noAnchor)
    }

    func testAPointerPressWithoutAWordSelectsNothingUntilItMoves() {
        let core = makeCore("hello world")
        let anchor = GhosttySelectionAnchor(core: core)
        XCTAssertFalse(core.beginSelection(col: 3, row: 0, word: false, anchor: anchor))
        XCTAssertEqual(core.extendSelection(col: 3, row: 0, anchor: anchor, keepOnAnchor: true), .onAnchor)
        XCTAssertFalse(core.hasSelection)
        XCTAssertNil(core.selectedText)
        XCTAssertEqual(core.extendSelection(col: 4, row: 0, anchor: anchor, keepOnAnchor: true), .extended(changed: true))
        XCTAssertEqual(core.selectedText, "lo")
    }

    func testCellsOutsideTheGridClampToIt() {
        let core = makeCore("abc\r\ndef")
        XCTAssertEqual(drag(core, from: (-5, -5), to: (500, 500)), "abc\ndef")
    }

    // MARK: Copy

    func testSoftWrappedRowsCopyAsOneLine() {
        let core = makeCore("abcdefghijklmnopqrstuvwxy\r\nnext", cols: 10)
        XCTAssertEqual(core.rowText(1), "klmnopqrst")
        XCTAssertEqual(drag(core, from: (0, 0), to: (3, 3)), "abcdefghijklmnopqrstuvwxy\nnext")
        XCTAssertEqual(drag(core, from: (8, 0), to: (1, 1)), "ijkl", "no line break where the terminal wrapped")
    }

    func testTrailingSpacesAndBlankLinesAreTrimmed() {
        let core = makeCore("abc   \r\n\r\n  def  \r\n", cols: 12, rows: 6)
        XCTAssertEqual(drag(core, from: (0, 0), to: (11, 5)), "abc\n\n  def")
        XCTAssertEqual(drag(core, from: (1, 0), to: (11, 0)), "bc")
    }

    func testSelectAllTakesScrollbackToo() {
        let core = makeCore((1...9).map { "line \($0)" }.joined(separator: "\r\n"), rows: 4)
        XCTAssertEqual(core.rowText(0), "line 6")
        XCTAssertTrue(core.selectAll())
        XCTAssertEqual(core.selectedText, (1...9).map { "line \($0)" }.joined(separator: "\n"))
        XCTAssertEqual(core.selectionExtent, GhosttySelectionExtent(cols: 20, rows: 4, startCol: 0, startRow: 0, endCol: 5, endRow: 3, startClipped: true),
                       "clipped to the rows in view")
        XCTAssertFalse(GhosttyCore(cols: 10, rows: 2).selectAll(), "nothing to select on an empty screen")
    }

    // MARK: Wide characters

    func testADragEndingOnEitherHalfOfAWideCharacterTakesAllOfIt() {
        // a 0, 你 1-2, b 3.
        let core = makeCore("a你b")
        XCTAssertEqual(drag(core, from: (0, 0), to: (1, 0)), "a你", "ends on the left half")
        XCTAssertEqual(core.selectionExtent?.endCol, 2)
        XCTAssertEqual(drag(core, from: (0, 0), to: (2, 0)), "a你", "ends on the right half")
        XCTAssertEqual(core.selectionExtent?.endCol, 2)
        XCTAssertEqual(drag(core, from: (3, 0), to: (2, 0)), "你b", "backward onto the right half")
        XCTAssertEqual(core.selectionExtent?.startCol, 1)
        XCTAssertEqual(drag(core, from: (2, 0), to: (3, 0)), "你b", "pressed on the right half")
        XCTAssertEqual(core.selectionExtent?.startCol, 1)
        XCTAssertEqual(drag(core, from: (3, 0), to: (1, 0)), "你b")
    }

    func testTheHighlightCoversBothCellsOfAWideCharacterAtTheEnd() {
        let core = makeCore("a你b")
        let frame = GhosttyFrameBuilder(atlas: GhosttyGlyphAtlas(pointSize: 12, scale: 2))
        _ = drag(core, from: (0, 0), to: (1, 0))
        XCTAssertTrue(frame.update(core: core))
        let m = frame.atlas.metrics
        let highlight = frame.rows[0].backgrounds.array.filter { $0.color == frame.builder.selectionColor }
        XCTAssertEqual(highlight.count, 1)
        XCTAssertEqual(Int(highlight[0].x), 0)
        XCTAssertEqual(Int(highlight[0].w), 3 * m.cellWidth)
    }

    // MARK: Tracking

    func testTheSelectionStaysOnItsTextWhileOutputScrolls() {
        let core = makeCore("one\r\ntwo\r\nthe target here\r\nfour", rows: 4)
        XCTAssertEqual(word(core, 5, 2), "target")
        XCTAssertEqual(core.selectionExtent?.startRow, 2)
        feed(core, "\r\nfive\r\nsix")
        XCTAssertEqual(core.rowText(0), "the target here")
        XCTAssertEqual(core.selectedText, "target")
        XCTAssertEqual(core.selectionExtent, GhosttySelectionExtent(cols: 20, rows: 4, startCol: 4, startRow: 0, endCol: 9, endRow: 0))
        // Scrolled out of view: still selected, nothing to draw a rect for.
        feed(core, "\r\nseven\r\neight")
        XCTAssertTrue(core.hasSelection)
        XCTAssertEqual(core.selectedText, "target")
        XCTAssertNil(core.selectionExtent)
    }

    func testTheAnchorFollowsItsCellWhileOutputScrollsMidDrag() {
        let core = makeCore("one\r\ntwo\r\nthree\r\nanchor row", rows: 4)
        let anchor = GhosttySelectionAnchor(core: core)
        core.beginSelection(col: 0, row: 3, word: false, anchor: anchor)
        feed(core, "\r\nnew line")
        XCTAssertEqual(core.rowText(2), "anchor row")
        // The finger hasn't moved: it is now over the new last row.
        XCTAssertEqual(core.extendSelection(col: 2, row: 3, anchor: anchor, keepOnAnchor: true), .extended(changed: true))
        XCTAssertEqual(core.selectedText, "anchor row\nnew")
        core.endSelection(anchor: anchor)
    }

    /// The viewport is the scroller's to move. After it did, the anchor is still on its cell.
    func testTheAnchorKeepsItsCellWhenTheViewportScrolls() {
        let core = makeCore((1...9).map { "line \($0)" }.joined(separator: "\r\n"), rows: 4)
        let frame = GhosttyFrameBuilder(atlas: GhosttyGlyphAtlas(pointSize: 12, scale: 2))
        let anchor = GhosttySelectionAnchor(core: core)
        core.beginSelection(col: 3, row: 1, word: false, anchor: anchor)  // on "line 7"
        XCTAssertEqual(core.extendSelection(col: 0, row: 0, anchor: anchor, keepOnAnchor: true), .extended(changed: true))
        XCTAssertEqual(core.rowText(0), "line 6", "extending never scrolls")
        core.scrollViewport(.lines(-1))
        _ = frame.update(core: core)
        XCTAssertEqual(core.rowText(0), "line 5", "the viewport went up a row")
        XCTAssertEqual(core.extendSelection(col: 0, row: 0, anchor: anchor, keepOnAnchor: false), .extended(changed: true))
        XCTAssertEqual(core.selectedText, "line 5\nline 6\nline")
        core.scrollViewport(.lines(-1))
        _ = frame.update(core: core)
        XCTAssertEqual(core.extendSelection(col: 0, row: 0, anchor: anchor, keepOnAnchor: false), .extended(changed: true))
        XCTAssertEqual(core.selectedText, "line 4\nline 5\nline 6\nline")
        XCTAssertEqual(core.selectionExtent, GhosttySelectionExtent(cols: 20, rows: 4, startCol: 0, startRow: 0, endCol: 3, endRow: 3))
        core.endSelection(anchor: anchor)
    }

    /// A selection made during a render hold is drawn at once (upstream: a hold may be ignored
    /// while the user selects), and the hold goes on afterwards.
    func testASelectionChangeIsDrawnDuringARenderHold() {
        let core = makeCore("alpha one")
        let frame = GhosttyFrameBuilder(atlas: GhosttyGlyphAtlas(pointSize: 12, scale: 2))
        XCTAssertTrue(frame.update(core: core))
        feed(core, "\u{1b}[?2026h\r\nheld text")
        XCTAssertFalse(frame.update(core: core), "held: the frame stays")
        func highlighted() -> Int {
            frame.rows.reduce(0) { $0 + $1.backgrounds.array.filter { $0.color == frame.builder.selectionColor }.count }
        }
        XCTAssertEqual(word(core, 1), "alpha")
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(highlighted(), 1)
        feed(core, "\r\nmore")
        XCTAssertFalse(frame.update(core: core), "still held")
        feed(core, "\u{1b}[?2026l")
        XCTAssertTrue(frame.update(core: core))
    }

    func testADragStopsWhenTheProgramSwitchesScreens() {
        let core = makeCore("primary text")
        let anchor = GhosttySelectionAnchor(core: core)
        core.beginSelection(col: 0, row: 0, word: false, anchor: anchor)
        feed(core, "\u{1b}[?1049halt screen")
        XCTAssertEqual(core.extendSelection(col: 5, row: 0, anchor: anchor, keepOnAnchor: true), .noAnchor)
        XCTAssertFalse(core.hasSelection)
        feed(core, "\u{1b}[?1049l")
        XCTAssertEqual(core.extendSelection(col: 6, row: 0, anchor: anchor, keepOnAnchor: true), .extended(changed: true))
        XCTAssertEqual(core.selectedText, "primary")
        core.endSelection(anchor: anchor)
    }

    func testTheSelectionSurvivesAReflow() {
        let core = makeCore("the quick brown fox jumps", cols: 30)
        XCTAssertEqual(word(core, 11), "brown")
        core.resize(cols: 8, rows: 6, cellWidthPx: 8, cellHeightPx: 16)
        core.sync()
        XCTAssertEqual(core.selectedText, "brown")
        XCTAssertEqual(core.selectionExtent, GhosttySelectionExtent(cols: 8, rows: 6, startCol: 2, startRow: 1, endCol: 6, endRow: 1))
    }

    // MARK: Cleared states

    func testClearAndReset() {
        let core = makeCore("hello world")
        XCTAssertFalse(core.clearSelection(), "nothing to clear")
        XCTAssertEqual(word(core, 0), "hello")
        XCTAssertTrue(core.clearSelection())
        XCTAssertFalse(core.hasSelection)
        XCTAssertNil(core.selectedText)
        XCTAssertNil(core.selectionExtent)
        XCTAssertEqual(word(core, 0), "hello")
        core.reset()
        core.sync()
        XCTAssertFalse(core.hasSelection, "a full reset drops the selection")
    }

    func testASnapshotRestoreDropsTheSelectionAndTheAnchor() throws {
        let core = makeCore("hello world", cols: 80, rows: 24)
        let anchor = GhosttySelectionAnchor(core: core)
        XCTAssertTrue(core.beginSelection(col: 0, row: 0, word: true, anchor: anchor))
        core.restore(snapshot: try ghosttyFixture("ghostty-history")) { _ in }
        core.sync()
        XCTAssertFalse(core.hasSelection)
        XCTAssertNil(core.selectedText)
        // The anchor came from the terminal that is gone.
        XCTAssertEqual(core.extendSelection(col: 4, row: 0, anchor: anchor, keepOnAnchor: false), .noAnchor)
        core.endSelection(anchor: anchor)
        XCTAssertEqual(GhosttyCore.liveTerminals.load(ordering: .relaxed) > 0, true)
    }

    // MARK: Drawing

    func testTheRenderStateHighlightsTheSelectionAndOnlyRedrawsWhenItChanges() {
        let core = makeCore("alpha one\r\nbravo two\r\ncharlie three")
        let frame = GhosttyFrameBuilder(atlas: GhosttyGlyphAtlas(pointSize: 12, scale: 2))
        XCTAssertTrue(frame.update(core: core))
        let m = frame.atlas.metrics
        func highlights() -> [[GhosttyRectInstance]] {
            frame.rows.map { $0.backgrounds.array.filter { $0.color == frame.builder.selectionColor } }
        }
        XCTAssertEqual(highlights().map(\.count), [0, 0, 0, 0])

        let anchor = GhosttySelectionAnchor(core: core)
        core.beginSelection(col: 6, row: 0, word: false, anchor: anchor)
        XCTAssertEqual(core.extendSelection(col: 4, row: 2, anchor: anchor, keepOnAnchor: true), .extended(changed: true))
        XCTAssertTrue(frame.update(core: core))
        let drawn = highlights()
        XCTAssertEqual(drawn.map(\.count), [1, 1, 1, 0])
        XCTAssertEqual(Int(drawn[0][0].x), 6 * m.cellWidth)
        XCTAssertEqual(Int(drawn[0][0].w), 14 * m.cellWidth, "the first row runs to the right edge")
        XCTAssertEqual(Int(drawn[1][0].x), 0)
        XCTAssertEqual(Int(drawn[1][0].w), 20 * m.cellWidth)
        XCTAssertEqual(Int(drawn[2][0].w), 5 * m.cellWidth)

        // Finger moves inside the same cell: the terminal isn't touched, nothing is rebuilt.
        XCTAssertEqual(core.extendSelection(col: 4, row: 2, anchor: anchor, keepOnAnchor: false), .extended(changed: false))
        XCTAssertFalse(frame.update(core: core))
        XCTAssertEqual(frame.rowsBuilt, 0)

        XCTAssertTrue(core.clearSelection())
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(highlights().map(\.count), [0, 0, 0, 0])
        core.endSelection(anchor: anchor)
    }

    // MARK: Rect shapes

    func testRectsForOneRowAndForSeveral() {
        let bounds = CGRect(x: 0, y: 0, width: 80, height: 80)
        func rects(_ e: GhosttySelectionExtent, shift: CGFloat = 0) -> [CGRect] {
            GhosttySelectionRects.make(e, bounds: bounds) { row, columns in
                CGRect(x: CGFloat(columns.lowerBound) * 8, y: CGFloat(row) * 16 - shift, width: CGFloat(columns.count) * 8, height: 16)
            }
        }
        let one = GhosttySelectionExtent(cols: 10, rows: 5, startCol: 2, startRow: 1, endCol: 4, endRow: 1)
        XCTAssertEqual(rects(one), [CGRect(x: 16, y: 16, width: 24, height: 16)])
        let two = GhosttySelectionExtent(cols: 10, rows: 5, startCol: 7, startRow: 1, endCol: 0, endRow: 2)
        XCTAssertEqual(rects(two), [CGRect(x: 56, y: 16, width: 24, height: 16), CGRect(x: 0, y: 32, width: 8, height: 16)])
        let four = GhosttySelectionExtent(cols: 10, rows: 5, startCol: 7, startRow: 0, endCol: 3, endRow: 3)
        XCTAssertEqual(rects(four), [
            CGRect(x: 56, y: 0, width: 24, height: 16),
            CGRect(x: 0, y: 16, width: 80, height: 32),
            CGRect(x: 0, y: 48, width: 32, height: 16),
        ])
        let block = GhosttySelectionExtent(cols: 10, rows: 5, startCol: 6, startRow: 1, endCol: 2, endRow: 3, rectangle: true)
        XCTAssertEqual(rects(block), [CGRect(x: 16, y: 16, width: 40, height: 48)])
        // The grid drawn 6 points up: the top row is cut by the view, a row under the grid shows.
        XCTAssertEqual(rects(one, shift: 6), [CGRect(x: 16, y: 10, width: 24, height: 16)])
        let top = GhosttySelectionExtent(cols: 10, rows: 5, startCol: 2, startRow: 0, endCol: 4, endRow: 0)
        XCTAssertEqual(rects(top, shift: 6), [CGRect(x: 16, y: 0, width: 24, height: 10)])
        let under = GhosttySelectionExtent(cols: 10, rows: 5, startCol: 0, startRow: 5, endCol: 9, endRow: 5)
        XCTAssertEqual(rects(under, shift: 6), [CGRect(x: 0, y: 74, width: 80, height: 6)])
        XCTAssertEqual(rects(under), [], "nothing of it shows without the shift")
    }

    // MARK: The view's selection members, as TerminalHost drives them

    @MainActor
    private func makeView(_ text: String, cols: Int = 20, rows: Int = 4) -> GhosttyTerminalView {
        let view = GhosttyTerminalView(frame: .zero, fontSize: 12, cols: cols, rows: rows)
        let cell = view.cellSize
        view.frame = CGRect(x: 0, y: 0, width: CGFloat(cols) * cell.width, height: CGFloat(rows) * cell.height)
        view.feed(text: text)
        view.core.sync()
        return view
    }

    /// Rects are built from device pixels, so they match to a rounding error.
    private func assertRects(_ got: [CGRect], _ want: [CGRect], _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        let same = got.count == want.count && zip(got, want).allSatisfy { a, b in
            abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
        }
        XCTAssertTrue(same, "\(got) is not \(want). \(message)", file: file, line: line)
    }

    /// The middle of a cell, in the view's coordinates.
    @MainActor
    private func point(_ view: GhosttyTerminalView, _ col: Int, _ row: Int) -> CGPoint {
        let cell = view.cellSize
        return CGPoint(x: (CGFloat(col) + 0.5) * cell.width, y: (CGFloat(row) + 0.5) * cell.height)
    }

    @MainActor
    func testTheViewHasAPlainLongPressForTheHostToRetarget() {
        let view = makeView("")
        let press = view.selectionPress
        XCTAssertTrue(type(of: press) == UILongPressGestureRecognizer.self)
        XCTAssertTrue(press.view === view)
        XCTAssertTrue(view.selectionPress === press, "one recognizer, not one per call")
        XCTAssertFalse(view.hasActiveSelection)
        XCTAssertNil(view.selectedText)
        XCTAssertEqual(view.selectionRects, [])
    }

    @MainActor
    func testLongPressThenReleaseGivesTheWordItsTextAndItsRect() {
        let view = makeView("alpha one\r\nbravo two")
        let cell = view.cellSize
        view.beginSelection(at: point(view, 7, 1), word: true)
        // The finger wobbles inside the cell before lifting.
        view.extendSelection(to: point(view, 7, 1), autoscroll: true)
        view.endSelectionDrag()
        XCTAssertTrue(view.hasActiveSelection)
        XCTAssertEqual(view.selectedText, "two")
        assertRects(view.selectionRects, [CGRect(x: 6 * cell.width, y: cell.height, width: 3 * cell.width, height: cell.height)])
        view.clearSelectedRange()
        XCTAssertFalse(view.hasActiveSelection)
        XCTAssertNil(view.selectedText)
        XCTAssertEqual(view.selectionRects, [])
    }

    @MainActor
    func testLongPressOnNothingLeavesNoSelection() {
        let view = makeView("alpha one")
        view.beginSelection(at: point(view, 1, 0), word: true)
        view.endSelectionDrag()
        XCTAssertTrue(view.hasActiveSelection)
        view.beginSelection(at: point(view, 5, 2), word: true)
        view.endSelectionDrag()
        XCTAssertFalse(view.hasActiveSelection)
        XCTAssertFalse(view.core.hasSelection)
        XCTAssertEqual(view.selectionRects, [])
    }

    @MainActor
    func testLongPressAndDragSelectsFromThePressCell() {
        let view = makeView("alpha one\r\nbravo two\r\ncharlie three")
        let cell = view.cellSize
        view.beginSelection(at: point(view, 7, 0), word: true)
        XCTAssertEqual(view.selectedText, "one")
        view.extendSelection(to: point(view, 2, 2), autoscroll: false)
        XCTAssertEqual(view.selectedText, "ne\nbravo two\ncha")
        view.endSelectionDrag()
        assertRects(view.selectionRects, [
            CGRect(x: 7 * cell.width, y: 0, width: 13 * cell.width, height: cell.height),
            CGRect(x: 0, y: cell.height, width: 20 * cell.width, height: cell.height),
            CGRect(x: 0, y: 2 * cell.height, width: 3 * cell.width, height: cell.height),
        ])
        // After the drag ended, a stray extend does nothing.
        view.extendSelection(to: point(view, 9, 3), autoscroll: false)
        XCTAssertEqual(view.selectedText, "ne\nbravo two\ncha")
    }

    /// The host's pointer path: begin without a word where the button went down, then extend.
    @MainActor
    func testPointerDrag() {
        let view = makeView("alpha one\r\nbravo two")
        view.beginSelection(at: point(view, 8, 1), word: false)
        view.extendSelection(to: point(view, 8, 1), autoscroll: false)
        XCTAssertFalse(view.hasActiveSelection, "no selection until the pointer leaves its cell")
        view.extendSelection(to: point(view, 6, 0), autoscroll: true)
        XCTAssertTrue(view.hasActiveSelection)
        XCTAssertEqual(view.selectedText, "one\nbravo two")
        // Cancelled: the host clears, then ends the drag.
        view.clearSelectedRange()
        view.endSelectionDrag()
        XCTAssertFalse(view.hasActiveSelection)
        XCTAssertFalse(view.core.hasSelection)
    }

    /// Runs one frame the way the render thread would, and hands its state to the scroller.
    @MainActor
    private func frame(_ view: GhosttyTerminalView) {
        view.core.sync()
        _ = view.renderer.frame.update(core: view.core)
        view.scroller.apply(view.core.scroll.snapshot)
    }

    /// The scroller moves the viewport (never the selection code), one line per move at an edge,
    /// and the selection reaches the row that came under the finger once that frame is drawn.
    @MainActor
    func testDraggingToTheTopEdgeScrollsALinePerMoveThroughTheScroller() {
        let view = makeView((1...9).map { "line \($0)" }.joined(separator: "\r\n"))
        view.layoutIfNeeded()
        frame(view)
        let cell = view.cellSize
        let calls = view.core.scroll.viewportCalls
        view.beginSelection(at: point(view, 3, 2), word: false)  // on "line 8"
        view.extendSelection(to: CGPoint(x: 2, y: 1), autoscroll: false)
        frame(view)
        XCTAssertEqual(view.core.rowText(0), "line 6", "no scrolling unless asked")
        XCTAssertEqual(view.core.scroll.viewportCalls, calls)

        view.extendSelection(to: CGPoint(x: 2, y: 2), autoscroll: true)
        XCTAssertEqual(view.core.rowText(0), "line 6", "the viewport moves with the next frame, not under the terminal lock here")
        XCTAssertEqual(view.selectedText, "line 6\nline 7\nline")
        frame(view)
        XCTAssertEqual(view.core.rowText(0), "line 5")
        XCTAssertEqual(view.core.scroll.viewportCalls, calls + 1, "one scroll, made by the scroll state")
        XCTAssertEqual(view.selectedText, "line 5\nline 6\nline 7\nline", "extended to the row that scrolled under the finger")
        XCTAssertEqual(view.scroller.surface.contentOffset.y, 4 * cell.height, accuracy: 0.01, "the scroll surface went along")

        view.extendSelection(to: CGPoint(x: 2, y: 1), autoscroll: true)
        frame(view)
        XCTAssertEqual(view.core.rowText(0), "line 4")
        XCTAssertEqual(view.scroller.surface.contentOffset.y, 3 * cell.height, accuracy: 0.01)
        view.endSelectionDrag()
        XCTAssertEqual(view.selectedText, "line 4\nline 5\nline 6\nline 7\nline")
        assertRects(view.selectionRects, [
            CGRect(x: 0, y: 0, width: 20 * cell.width, height: cell.height),
            CGRect(x: 0, y: cell.height, width: 20 * cell.width, height: 2 * cell.height),
            CGRect(x: 0, y: 3 * cell.height, width: 20 * cell.width, height: cell.height),
        ], "the rows in view; the last selected row is below the viewport")
        // A frame after the drag ended changes nothing.
        view.scrollLines(1)
        frame(view)
        XCTAssertEqual(view.selectedText, "line 4\nline 5\nline 6\nline 7\nline")
    }

    /// Scrolled into history by half a row: a press selects the word under the finger, and its
    /// rect is where that word is drawn.
    @MainActor
    func testHitTestingAndRectsAtAFractionalScrollOffsetInHistory() {
        let view = makeView((1...40).map { "row\($0) word\($0)" }.joined(separator: "\r\n"), rows: 6)
        view.layoutIfNeeded()
        frame(view)
        let cell = view.cellSize
        view.scroller.setOffset(10.5 * cell.height, animated: false)
        frame(view)
        let scroll = view.scrollSnapshot
        XCTAssertEqual(scroll.offset, 10)
        XCTAssertGreaterThan(scroll.fraction, 0)
        let shift = CGFloat(scroll.fraction) / view.displayScale
        XCTAssertEqual(view.core.rowText(0), "row11 word11")

        // A point three quarters of a cell down is on the second viewport row (row12).
        view.beginSelection(at: CGPoint(x: cell.width * 7.5, y: cell.height * 0.75), word: true)
        view.endSelectionDrag()
        XCTAssertEqual(view.selectedText, "word12")
        var rects = view.selectionRects
        XCTAssertEqual(rects.count, 1)
        XCTAssertEqual(rects[0].minX, 6 * cell.width, accuracy: 0.01)
        XCTAssertEqual(rects[0].width, 6 * cell.width, accuracy: 0.01)
        XCTAssertEqual(rects[0].minY, cell.height - shift, accuracy: 0.01)
        XCTAssertEqual(rects[0].height, cell.height, accuracy: 0.01)

        // The first row is half scrolled past: its rect is cut at the top of the view.
        view.beginSelection(at: CGPoint(x: cell.width * 1.5, y: 1), word: true)
        view.endSelectionDrag()
        XCTAssertEqual(view.selectedText, "row11")
        rects = view.selectionRects
        XCTAssertEqual(rects.first?.minY ?? -1, 0, accuracy: 0.01)
        XCTAssertEqual(rects.first?.height ?? -1, cell.height - shift, accuracy: 0.01)

        // A drag from row14 down to the bottom edge of the view.
        view.beginSelection(at: CGPoint(x: cell.width * 0.5, y: cell.height * 2.75), word: false)
        view.extendSelection(to: CGPoint(x: cell.width * 30, y: view.bounds.height - 1), autoscroll: false)
        XCTAssertEqual(view.selectedText, "row14 word14\nrow15 word15\nrow16 word16")
        // The view scrolls two lines up mid-drag: the selection stays on its text, and its rects
        // move down with it.
        view.scrollLines(-2)
        frame(view)
        XCTAssertEqual(view.core.rowText(0), "row9 word9")
        let nowShift = CGFloat(view.scrollSnapshot.fraction) / view.displayScale
        XCTAssertEqual(view.selectionRects.first?.minY ?? -1, 5 * cell.height - nowShift, accuracy: 0.01, "row14 is the last row in view now")
        view.endSelectionDrag()
    }

    /// With the view scrolled to a fraction, the row under the grid shows at the bottom edge; a
    /// selection that covers it has a rect for the part in view.
    @MainActor
    func testTheRowUnderTheGridHasARectForItsVisiblePart() {
        let view = makeView((1...40).map { "row\($0)" }.joined(separator: "\r\n"), rows: 6)
        view.layoutIfNeeded()
        frame(view)
        let cell = view.cellSize
        view.scroller.setOffset(10.5 * cell.height, animated: false)
        frame(view)
        let shift = CGFloat(view.scrollSnapshot.fraction) / view.displayScale
        // Rows 11 to 16 are the viewport; row17 is under it. Select row15 to row17 by scrolling
        // down a line mid-drag, then go back.
        view.beginSelection(at: CGPoint(x: 1, y: cell.height * 3.75), word: false)  // row15
        view.scroller.setOffset(11.5 * cell.height, animated: false)
        frame(view)
        view.extendSelection(to: CGPoint(x: cell.width * 3.5, y: cell.height * 4.75), autoscroll: false)  // "row1" of row17
        view.endSelectionDrag()
        XCTAssertEqual(view.selectedText, "row15\nrow16\nrow1")
        view.scroller.setOffset(10.5 * cell.height, animated: false)
        frame(view)
        let rects = view.selectionRects
        XCTAssertEqual(rects.last?.maxY ?? -1, view.bounds.height, accuracy: 0.01)
        XCTAssertEqual(rects.last?.minY ?? -1, 6 * cell.height - shift, accuracy: 0.01)
        XCTAssertEqual(rects.last?.width ?? -1, 4 * cell.width, accuracy: 0.01)
    }

    @MainActor
    func testSelectAllIsActiveButHasNoGestureRects() {
        let view = makeView("alpha\r\nbravo")
        view.selectAllText()
        XCTAssertTrue(view.hasActiveSelection)
        XCTAssertEqual(view.selectedText, "alpha\nbravo")
        XCTAssertEqual(view.selectionRects, [], "rects are for selections a gesture made")
        view.clearSelectedRange()
        XCTAssertFalse(view.core.hasSelection)
    }

    /// The terminal can drop a selection by itself; the view must not keep saying it has one.
    @MainActor
    func testTheViewNoticesWhenTheTerminalDroppedTheSelection() {
        let view = makeView("alpha one")
        view.beginSelection(at: point(view, 1, 0), word: true)
        view.endSelectionDrag()
        XCTAssertTrue(view.hasActiveSelection)
        view.feed(text: "\u{1b}c")  // RIS, as the host's stream reset sends
        view.core.sync()
        XCTAssertNil(view.selectedText)
        XCTAssertEqual(view.selectionRects, [])
        XCTAssertFalse(view.hasActiveSelection)
    }

    @MainActor
    func testTheSelectionAndItsRectFollowOutput() {
        let view = makeView("one\r\ntwo\r\nthe target here\r\nfour")
        let cell = view.cellSize
        view.beginSelection(at: point(view, 5, 2), word: true)
        view.endSelectionDrag()
        XCTAssertEqual(view.selectionRects.first?.minY, 2 * cell.height)
        view.feed(text: "\r\nfive")
        view.core.sync()
        XCTAssertEqual(view.selectedText, "target")
        assertRects(view.selectionRects, [CGRect(x: 4 * cell.width, y: cell.height, width: 6 * cell.width, height: cell.height)])
    }

    // MARK: Hit-testing: point to cell to rect

    /// For every row and several columns of the grid, at 2x and 3x and every font size the pinch
    /// allows, at every sub-row scroll offset: a point anywhere inside the rect a cell is drawn
    /// in maps back to that cell. (A cell is a whole number of pixels, a fraction of a point.)
    func testPointToCellToRectRoundTripAtEveryRowScaleFontSizeAndScrollFraction() {
        for scale in [2, 3] as [CGFloat] {
            var size: CGFloat = 7
            while size <= 20 {
                let m = GhosttyGlyphAtlas(pointSize: size, scale: scale).metrics
                let cols = 80, rows = 60
                for shift in Set([0, 1, m.cellHeight / 3, m.cellHeight / 2, m.cellHeight - 1]) {
                    let g = GhosttyGridGeometry(cellWidth: m.cellWidth, cellHeight: m.cellHeight, scale: scale, cols: cols, rows: rows, shift: shift)
                    var wrong = 0
                    for row in 0..<rows {
                        for col in [0, 1, 39, 79] {
                            let r = g.rect(row: row, columns: col..<(col + 1))
                            // Just inside each corner and the middle, half a pixel from the edges.
                            let d = 0.5 / scale
                            for p in [CGPoint(x: r.minX + d, y: r.minY + d), CGPoint(x: r.maxX - d, y: r.maxY - d), CGPoint(x: r.midX, y: r.midY)]
                            where p.y >= 0 {
                                let hit = g.cell(at: p)
                                if hit.col != col || hit.row != row { wrong += 1 }
                            }
                        }
                    }
                    XCTAssertEqual(wrong, 0, "\(size) pt at \(scale)x, shifted \(shift) px")
                    // Rows are drawn edge to edge: the last row's bottom is exactly rows cells down.
                    XCTAssertEqual(g.rect(row: rows - 1, columns: 0..<1).maxY, CGFloat(rows * m.cellHeight - shift) / scale, accuracy: 0.0001)
                }
                size += 0.5
            }
        }
    }

    /// The bug of build 7a0d37c: with the view resting at a fraction of a row (any scroll does
    /// that), a touch low in a row selected the row above, because the point was mapped without
    /// the scroll shift. Every row, pressed near its bottom edge, selects itself.
    @MainActor
    func testAPressLowInARowSelectsThatRowAtAnyScrollFraction() {
        let view = makeView((1...60).map { "w\($0)" }.joined(separator: "\r\n"), rows: 12)
        view.layoutIfNeeded()
        frame(view)
        let cell = view.cellSize
        for fraction in [0.0, 0.25, 0.5, 0.9] as [CGFloat] {
            view.scroller.setOffset((20 + fraction) * cell.height, animated: false)
            frame(view)
            let shift = CGFloat(view.scrollSnapshot.fraction) / view.displayScale
            for row in 0..<12 {
                // The row is drawn from row * height - shift; press a pixel above its bottom edge.
                let y = CGFloat(row + 1) * cell.height - shift - 1 / view.displayScale
                guard y >= 0, y < view.bounds.height else { continue }
                view.beginSelection(at: CGPoint(x: cell.width * 0.5, y: y), word: true)
                view.endSelectionDrag()
                XCTAssertEqual(view.selectedText, "w\(21 + row)", "row \(row) at fraction \(fraction)")
                let rect = view.selectionRects.first ?? .null
                XCTAssertTrue(rect.insetBy(dx: -0.01, dy: -0.01).contains(CGPoint(x: cell.width * 0.5, y: y)), "the rect is under the finger: \(rect)")
            }
        }
    }

    /// Fit mode puts the engine view at a negative y while the server catches up with a shorter
    /// pane (bottom rows kept in view), and mirror mode scales it. The host reads the press in
    /// the engine view's coordinates, so every row still selects itself.
    @MainActor
    func testHitTestingWhenTheViewIsBottomAnchoredOrScaled() {
        let view = makeView((1...12).map { "w\($0)" }.joined(separator: "\r\n"), rows: 12)
        view.layoutIfNeeded()
        frame(view)
        let cell = view.cellSize
        let host = UIView(frame: CGRect(x: 0, y: 0, width: view.bounds.width, height: 7.4 * cell.height))
        host.clipsToBounds = true
        host.addSubview(view)
        for (name, transform) in [("bottom anchored", CGAffineTransform.identity), ("scaled", CGAffineTransform(scaleX: 0.6, y: 0.6))] {
            view.transform = .identity
            view.frame.origin = CGPoint(x: 0, y: host.bounds.height - view.bounds.height)  // negative: the top rows are cut off
            view.transform = transform
            for row in 0..<12 {
                let inView = CGPoint(x: cell.width * 0.5, y: (CGFloat(row) + 0.9) * cell.height)
                let inHost = host.convert(inView, from: view)
                // What the host's recognizer reports: the touch, in the engine view's coordinates.
                let p = view.convert(inHost, from: host)
                view.beginSelection(at: p, word: true)
                view.endSelectionDrag()
                XCTAssertEqual(view.selectedText, "w\(row + 1)", "\(name), row \(row)")
                let rect = host.convert(view.selectionRects.first ?? .null, from: view)
                XCTAssertTrue(rect.insetBy(dx: -0.01, dy: -0.01).contains(inHost), "\(name), row \(row)")
            }
        }
        view.transform = .identity
    }
}
