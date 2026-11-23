import CoreText
import XCTest
@testable import Pteron

/// The terminal view where the answer is a number or bytes that can be checked: the cell that
/// decides the fit grid, the key bar's modifiers with keys that aren't characters, the theme.
/// See docs/terminal-checklist.md.
@MainActor
final class GhosttyViewTests: XCTestCase {
    private final class Sink: TerminalEngineDelegate {
        var sent: [[UInt8]] = []
        var all: [UInt8] { sent.flatMap { $0 } }
        func engineGridChanged(cols: Int, rows: Int) {}
        func engineSend(_ bytes: [UInt8]) { sent.append(bytes) }
    }

    private func show(_ bytes: [UInt8]) -> String {
        bytes.map { $0 >= 0x20 && $0 < 0x7f ? String(UnicodeScalar($0)) : String(format: "\\x%02x", $0) }.joined()
    }

    private func make(_ setup: String = "") -> (GhosttyTerminalView, Sink) {
        let view = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: 12, cols: 40, rows: 10)
        let sink = Sink()
        view.engineDelegate = sink
        view.feed(text: setup)
        view.core.sync()
        return (view, sink)
    }

    /// What `action` makes the view send.
    private func sent(_ setup: String = "", _ action: (GhosttyTerminalView) -> Void) -> String {
        let (view, sink) = make(setup)
        action(view)
        return show(sink.all)
    }

    // MARK: Fit grid

    /// Fit mode resizes the pane on the server to the grid that fits, so the cell size decides
    /// what the Mac gets. At every font size the pinch allows, a cell is the font's advance wide,
    /// rounded to a whole device pixel, so the columns are the ones the font gives. Its height
    /// is the font's line height in whole device pixels: never more than the line height
    /// rounded up to a whole point, and less than a point under it.
    func testFitGridFollowsTheFontAtEveryFontSize() {
        let panes = [CGSize(width: 402, height: 480), CGSize(width: 402, height: 760), CGSize(width: 466, height: 600),
                     CGSize(width: 475.5, height: 620), CGSize(width: 951, height: 620)]
        let scale = UIScreen.main.scale
        var size = TerminalHost.fontRange.lowerBound
        var steps = 0
        while size <= TerminalHost.fontRange.upperBound {
            let cell = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: size).cellSize
            let font = RexFont.ui(size) as CTFont
            var glyph = CGGlyph(0), character = UniChar(UInt8(ascii: "M"))
            XCTAssertTrue(CTFontGetGlyphsForCharacters(font, &character, &glyph, 1))
            let advance = (CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, nil, 1) * scale).rounded() / scale
            let line = ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font))
            XCTAssertEqual(cell.width, advance, accuracy: 0.01, "cell width at \(size) pt")
            XCTAssertLessThanOrEqual(cell.height, line + 0.01, "cell height at \(size) pt")
            XCTAssertGreaterThan(cell.height, line - 1.01, "cell height at \(size) pt")
            XCTAssertEqual((cell.height * scale).rounded(), cell.height * scale, accuracy: 0.001, "whole device pixels at \(size) pt")
            for pane in panes {
                let grid = TerminalLayout.fitGrid(in: pane, cell: cell)
                let byFont = TerminalLayout.fitGrid(in: pane, cell: CGSize(width: advance, height: line))
                XCTAssertEqual(grid.cols, byFont.cols, "columns at \(size) pt in \(pane)")
                XCTAssertGreaterThanOrEqual(grid.rows, byFont.rows, "rows at \(size) pt in \(pane)")
                XCTAssertLessThanOrEqual(Double(grid.rows), Double(byFont.rows) * 1.12 + 1, "rows at \(size) pt in \(pane)")
                steps += 1
            }
            size += 0.5
        }
        XCTAssertEqual(steps, 27 * panes.count)
    }

    // MARK: Key bar modifiers with keys that aren't characters (system keyboard)

    func testOneShotControlWithReturnOrTabSendsThePlainKeyInLegacyMode() {
        // The key goes out plain; never in the encoder's CSI 27 form, which a shell would print.
        XCTAssertEqual(sent { $0.controlModifier = true; $0.insertText("\n") }, "\\x0d")
        XCTAssertEqual(sent { $0.controlModifier = true; $0.insertText("\t") }, "\\x09")
        // The flag is used up either way.
        let (view, _) = make()
        view.controlModifier = true
        view.insertText("\n")
        XCTAssertFalse(view.controlModifier)
        // A program that asked for the Kitty protocol gets the real chord.
        XCTAssertEqual(sent("\u{1b}[>1u") { $0.controlModifier = true; $0.insertText("\n") }, "\\x1b[13;5u")
    }

    /// A one-shot modifier applies to keys that aren't characters too, with what a terminal's
    /// Alt and Ctrl mean.
    func testOneShotModifiersApplyToBackspaceAndReturn() {
        XCTAssertEqual(sent { $0.metaModifier = true; $0.deleteBackward() }, "\\x1b\\x7f", "Alt+Backspace: delete a word")
        XCTAssertEqual(sent { $0.controlModifier = true; $0.deleteBackward() }, "\\x08", "Ctrl+Backspace, as Ghostty sends it")
        XCTAssertEqual(sent { $0.metaModifier = true; $0.insertText("\n") }, "\\x1b\\x0d")
        XCTAssertEqual(sent { $0.controlModifier = true; $0.metaModifier = true; $0.insertText("a") }, "\\x1b\\x01",
                       "both modifiers apply")
    }

    /// An empty paste is dropped, as the Ghostty app drops it: no empty bracket.
    func testAnEmptyPasteSendsNothing() {
        XCTAssertEqual(sent("\u{1b}[?2004h") { $0.pasteText("") }, "")
    }

    // MARK: Theme

    func testThemeReachesEveryPart() {
        for theme in ThemeStore.all {
            let (g, _) = make()
            g.apply(theme: theme)
            XCTAssertEqual(g.keyboardAppearance, theme.isDark ? .dark : .light, theme.name)
            XCTAssertEqual(g.backgroundColor, theme.uiBG, theme.name)
            _ = g.renderer.frame.update(core: g.core)
            g.core.sync()
            _ = g.renderer.frame.update(core: g.core)
            g.scroller.apply(g.core.scroll.snapshot)
            // A scroll indicator that shows on the theme's background.
            XCTAssertEqual(g.scroller.surface.indicatorStyle, theme.isDark ? .white : .black, theme.name)
            // Background, foreground and cursor as the frame resolves them.
            func packed(_ hex: String) -> UInt32 {
                let v = GhosttyTerminalView.rgb(hex)
                return GhosttyRowBuilder.pack(UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff))
            }
            XCTAssertEqual(g.renderer.frame.background, packed(theme.background), theme.name)
            XCTAssertEqual(g.renderer.frame.foreground, packed(theme.foreground), theme.name)
            XCTAssertEqual(g.renderer.frame.cursor.color, packed(theme.cursor), theme.name)
        }
    }
}
