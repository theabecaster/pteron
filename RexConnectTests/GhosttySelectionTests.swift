import XCTest
@testable import RexConnect

/// Selection for the Ghostty engine: the terminal's selection through `GhosttyCore`, the geometry
/// math, and the seam members on `GhosttyTerminalView` as TerminalHost drives them.
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

    /// Ghostty follows the soft wrap; the SwiftTerm engine stops at the row's edge.
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
        // Leaving the cell turns the word into anchor...finger, as in the SwiftTerm engine.
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
        XCTAssertEqual(core.selectionExtent, GhosttySelectionExtent(cols: 20, rows: 4, startCol: 0, startRow: 0, endCol: 5, endRow: 3),
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

    func testADragAtTheEdgeScrollsTheViewportAndKeepsTheAnchor() {
        let core = makeCore((1...9).map { "line \($0)" }.joined(separator: "\r\n"), rows: 4)
        let anchor = GhosttySelectionAnchor(core: core)
        core.beginSelection(col: 3, row: 1, word: false, anchor: anchor)  // on "line 7"
        XCTAssertEqual(core.extendSelection(col: 0, row: 0, anchor: anchor, scrollRows: -1, keepOnAnchor: true), .extended(changed: true))
        XCTAssertEqual(core.rowText(0), "line 5", "the viewport went up a row")
        XCTAssertEqual(core.selectedText, "line 5\nline 6\nline")
        XCTAssertEqual(core.extendSelection(col: 0, row: 0, anchor: anchor, scrollRows: -1, keepOnAnchor: false), .extended(changed: true))
        XCTAssertEqual(core.selectedText, "line 4\nline 5\nline 6\nline")
        XCTAssertEqual(core.selectionExtent, GhosttySelectionExtent(cols: 20, rows: 4, startCol: 0, startRow: 0, endCol: 3, endRow: 3))
        core.endSelection(anchor: anchor)
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

    // MARK: Geometry

    func testPointToCell() {
        let g = GhosttySelectionGeometry(cell: CGSize(width: 8, height: 16), cols: 10, rows: 5,
                                         viewport: CGRect(x: 0, y: 0, width: 80, height: 80))
        XCTAssertTrue(g.cell(at: CGPoint(x: 0, y: 0)) == (0, 0))
        XCTAssertTrue(g.cell(at: CGPoint(x: 7.9, y: 15.9)) == (0, 0))
        XCTAssertTrue(g.cell(at: CGPoint(x: 8, y: 16)) == (1, 1))
        XCTAssertTrue(g.cell(at: CGPoint(x: 79, y: 79)) == (9, 4))
        XCTAssertTrue(g.cell(at: CGPoint(x: -20, y: -20)) == (0, 0), "clamped")
        XCTAssertTrue(g.cell(at: CGPoint(x: 900, y: 900)) == (9, 4), "clamped")
    }

    /// A view that scrolls natively reports points with its content offset in them.
    func testPointToCellWithAScrolledViewportAndAFractionalRow() {
        var g = GhosttySelectionGeometry(cell: CGSize(width: 8, height: 16), cols: 10, rows: 5,
                                         viewport: CGRect(x: 0, y: 1600, width: 80, height: 80))
        XCTAssertTrue(g.cell(at: CGPoint(x: 9, y: 1600)) == (1, 0))
        XCTAssertTrue(g.cell(at: CGPoint(x: 9, y: 1633)) == (1, 2))
        g.scrollShift = 6  // the grid is drawn 6 points up
        XCTAssertTrue(g.cell(at: CGPoint(x: 9, y: 1609)) == (1, 0))
        XCTAssertTrue(g.cell(at: CGPoint(x: 9, y: 1610)) == (1, 1))
        let e = GhosttySelectionExtent(cols: 10, rows: 5, startCol: 2, startRow: 0, endCol: 4, endRow: 0)
        XCTAssertEqual(g.rects(for: e), [CGRect(x: 16, y: 1600, width: 24, height: 10)], "the top row is cut by the viewport")
    }

    func testAutoscrollEdges() {
        let g = GhosttySelectionGeometry(cell: CGSize(width: 8, height: 16), cols: 10, rows: 5,
                                         viewport: CGRect(x: 0, y: 100, width: 80, height: 80))
        XCTAssertEqual(g.autoscrollRows(at: CGPoint(x: 5, y: 107)), -1)
        XCTAssertEqual(g.autoscrollRows(at: CGPoint(x: 5, y: 90)), -1)
        XCTAssertEqual(g.autoscrollRows(at: CGPoint(x: 5, y: 108)), 0)
        XCTAssertEqual(g.autoscrollRows(at: CGPoint(x: 5, y: 172)), 0)
        XCTAssertEqual(g.autoscrollRows(at: CGPoint(x: 5, y: 173)), 1)
    }

    func testRectsForOneRowAndForSeveral() {
        let g = GhosttySelectionGeometry(cell: CGSize(width: 8, height: 16), cols: 10, rows: 5,
                                         viewport: CGRect(x: 0, y: 0, width: 80, height: 80))
        let one = GhosttySelectionExtent(cols: 10, rows: 5, startCol: 2, startRow: 1, endCol: 4, endRow: 1)
        XCTAssertEqual(g.rects(for: one), [CGRect(x: 16, y: 16, width: 24, height: 16)])
        let two = GhosttySelectionExtent(cols: 10, rows: 5, startCol: 7, startRow: 1, endCol: 0, endRow: 2)
        XCTAssertEqual(g.rects(for: two), [CGRect(x: 56, y: 16, width: 24, height: 16), CGRect(x: 0, y: 32, width: 8, height: 16)])
        let four = GhosttySelectionExtent(cols: 10, rows: 5, startCol: 7, startRow: 0, endCol: 3, endRow: 3)
        XCTAssertEqual(g.rects(for: four), [
            CGRect(x: 56, y: 0, width: 24, height: 16),
            CGRect(x: 0, y: 16, width: 80, height: 32),
            CGRect(x: 0, y: 48, width: 32, height: 16),
        ])
        let block = GhosttySelectionExtent(cols: 10, rows: 5, startCol: 6, startRow: 1, endCol: 2, endRow: 3, rectangle: true)
        XCTAssertEqual(g.rects(for: block), [CGRect(x: 16, y: 16, width: 40, height: 48)])
    }

    // MARK: The seam, as TerminalHost drives it

    @MainActor
    private func makeView(_ text: String, cols: Int = 20, rows: Int = 4) -> GhosttyTerminalView {
        let view = GhosttyTerminalView(frame: .zero, fontSize: 12, cols: cols, rows: rows)
        let cell = view.cellSize
        view.frame = CGRect(x: 0, y: 0, width: CGFloat(cols) * cell.width, height: CGFloat(rows) * cell.height)
        view.feed(text: text)
        view.core.sync()
        return view
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
        let press = view.selectionPressRecognizer
        XCTAssertNotNil(press)
        XCTAssertTrue(press.map { type(of: $0) == UILongPressGestureRecognizer.self } ?? false)
        XCTAssertTrue(press?.view === view)
        XCTAssertTrue(view.selectionPressRecognizer === press, "one recognizer, not one per call")
        XCTAssertFalse(view.isBuiltInSelectionPan(UIPanGestureRecognizer()))
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
        XCTAssertEqual(view.selectionRects, [CGRect(x: 6 * cell.width, y: cell.height, width: 3 * cell.width, height: cell.height)])
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
        XCTAssertEqual(view.selectionRects, [
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

    @MainActor
    func testDraggingToTheTopEdgeScrollsALinePerMove() {
        let view = makeView((1...9).map { "line \($0)" }.joined(separator: "\r\n"))
        view.beginSelection(at: point(view, 3, 2), word: false)  // on "line 8"
        view.extendSelection(to: CGPoint(x: 2, y: 1), autoscroll: false)
        XCTAssertEqual(view.core.rowText(0), "line 6", "no scrolling unless asked")
        view.extendSelection(to: CGPoint(x: 2, y: 2), autoscroll: true)
        XCTAssertEqual(view.core.rowText(0), "line 5")
        view.extendSelection(to: CGPoint(x: 2, y: 1), autoscroll: true)
        XCTAssertEqual(view.core.rowText(0), "line 4")
        view.endSelectionDrag()
        XCTAssertEqual(view.selectedText, "line 4\nline 5\nline 6\nline 7\nline")
        let cell = view.cellSize
        XCTAssertEqual(view.selectionRects, [
            CGRect(x: 0, y: 0, width: 20 * cell.width, height: cell.height),
            CGRect(x: 0, y: cell.height, width: 20 * cell.width, height: 2 * cell.height),
            CGRect(x: 0, y: 3 * cell.height, width: 20 * cell.width, height: cell.height),
        ], "the rows in view; the last selected row is below the viewport")
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
        XCTAssertEqual(view.selectionRects, [CGRect(x: 4 * cell.width, y: cell.height, width: 6 * cell.width, height: cell.height)])
    }
}
