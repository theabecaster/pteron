import XCTest
@testable import RexConnect

/// The Ghostty engine against the SwiftTerm engine, member by member of the seam, where the
/// answer is a number or bytes that can be compared. See docs/ghostty-parity.md.
@MainActor
final class GhosttyParityTests: XCTestCase {
    private final class Sink: TerminalEngineDelegate {
        var sent: [[UInt8]] = []
        var all: [UInt8] { sent.flatMap { $0 } }
        func engineGridChanged(cols: Int, rows: Int) {}
        func engineSend(_ bytes: [UInt8]) { sent.append(bytes) }
    }

    private func show(_ bytes: [UInt8]) -> String {
        bytes.map { $0 >= 0x20 && $0 < 0x7f ? String(UnicodeScalar($0)) : String(format: "\\x%02x", $0) }.joined()
    }

    private func engines(_ setup: String = "") -> (GhosttyTerminalView, Sink, RexTerminalView, Sink) {
        let g = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: 12, cols: 40, rows: 10)
        let gs = Sink()
        g.engineDelegate = gs
        g.feed(text: setup)
        g.core.sync()
        let t = RexTerminalView(fontSize: 12, theme: ThemeStore.fallback)
        // As TerminalHost does: with SwiftTerm's own accessory in place, its ctrl flag wins over the view's.
        t.inputAccessoryView = UIView()
        let ts = Sink()
        t.engineDelegate = ts
        t.feed(text: setup)
        return (g, gs, t, ts)
    }

    /// What `action` makes each engine send. The SwiftTerm adapter delivers on a later main-actor turn.
    private func sent(_ setup: String = "", _ action: (any TerminalEngineView) -> Void) async -> (ghostty: String, swiftTerm: String) {
        let (g, gs, t, ts) = engines(setup)
        action(g)
        action(t)
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        return (show(gs.all), show(ts.all))
    }

    // MARK: Fit grid

    /// Fit mode resizes the pane on the server to the grid that fits, so the cell size decides
    /// what the Mac gets. Columns are the same on both engines at every font size the pinch
    /// allows. Rows are not: SwiftTerm rounds the line height up to a whole point, Ghostty to a
    /// whole device pixel, so Ghostty's rows are up to a point shorter and a pane fits up to
    /// about a tenth more of them (never fewer).
    func testFitGridColumnsMatchSwiftTermAndRowsAreNeverFewer() {
        let panes = [CGSize(width: 402, height: 480), CGSize(width: 402, height: 760), CGSize(width: 466, height: 600),
                     CGSize(width: 475.5, height: 620), CGSize(width: 951, height: 620)]
        var size = TerminalHost.fontRange.lowerBound
        var sameRows = 0, steps = 0
        while size <= TerminalHost.fontRange.upperBound {
            let ghostty = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: size).cellSize
            let swiftTerm = RexTerminalView(fontSize: size, theme: ThemeStore.fallback).cellSize
            XCTAssertEqual(ghostty.width, swiftTerm.width, accuracy: 0.01, "cell width at \(size) pt")
            XCTAssertLessThanOrEqual(ghostty.height, swiftTerm.height + 0.01, "cell height at \(size) pt")
            XCTAssertGreaterThan(ghostty.height, swiftTerm.height - 1.01, "cell height at \(size) pt")
            for pane in panes {
                let a = TerminalLayout.fitGrid(in: pane, cell: ghostty), b = TerminalLayout.fitGrid(in: pane, cell: swiftTerm)
                XCTAssertEqual(a.cols, b.cols, "columns at \(size) pt in \(pane)")
                XCTAssertGreaterThanOrEqual(a.rows, b.rows, "rows at \(size) pt in \(pane)")
                XCTAssertLessThanOrEqual(Double(a.rows), Double(b.rows) * 1.12 + 1, "rows at \(size) pt in \(pane)")
                steps += 1
                if a.rows == b.rows { sameRows += 1 }
            }
            size += 0.5
        }
        print("PARITY fit grid: columns equal in all \(steps) cases, rows equal in \(sameRows)")
    }

    // MARK: Key bar modifiers with keys that aren't characters (system keyboard)

    func testOneShotControlWithReturnOrTabSendsThePlainKeyInLegacyMode() async {
        // SwiftTerm swallows the key. Ghostty sends it plain; never the encoder's CSI 27 form,
        // which a shell would print.
        var r = await sent { $0.controlModifier = true; ($0 as? any UIKeyInput)?.insertText("\n") }
        XCTAssertEqual(r.ghostty, "\\x0d")
        XCTAssertEqual(r.swiftTerm, "")
        r = await sent { $0.controlModifier = true; ($0 as? any UIKeyInput)?.insertText("\t") }
        XCTAssertEqual(r.ghostty, "\\x09")
        // The flag is used up either way.
        let (g, _, _, _) = engines()
        g.controlModifier = true
        g.insertText("\n")
        XCTAssertFalse(g.controlModifier)
        // A program that asked for the Kitty protocol gets the real chord.
        r = await sent("\u{1b}[>1u") { $0.controlModifier = true; ($0 as? any UIKeyInput)?.insertText("\n") }
        XCTAssertEqual(r.ghostty, "\\x1b[13;5u")
    }

    /// Recorded differences, where Ghostty sends what a terminal's Alt and Ctrl mean and SwiftTerm
    /// drops the modifier (and leaves its flag set).
    func testOneShotModifierDifferencesThatAreIntended() async {
        var r = await sent { $0.metaModifier = true; ($0 as? any UIKeyInput)?.deleteBackward() }
        XCTAssertEqual(r.ghostty, "\\x1b\\x7f", "Alt+Backspace: delete a word")
        XCTAssertEqual(r.swiftTerm, "\\x7f")
        r = await sent { $0.controlModifier = true; ($0 as? any UIKeyInput)?.deleteBackward() }
        XCTAssertEqual(r.ghostty, "\\x08", "Ctrl+Backspace, as Ghostty sends it")
        XCTAssertEqual(r.swiftTerm, "\\x7f")
        r = await sent { $0.metaModifier = true; ($0 as? any UIKeyInput)?.insertText("\n") }
        XCTAssertEqual(r.ghostty, "\\x1b\\x0d")
        XCTAssertEqual(r.swiftTerm, "\\x1b\\x0a")
        r = await sent { $0.controlModifier = true; $0.metaModifier = true; ($0 as? any UIKeyInput)?.insertText("a") }
        XCTAssertEqual(r.ghostty, "\\x1b\\x01", "both modifiers apply")
        XCTAssertEqual(r.swiftTerm, "\\x01")
    }

    /// Ghostty drops an empty paste, as the Ghostty app does; SwiftTerm sends an empty bracket.
    func testAnEmptyPasteSendsNothing() async {
        let r = await sent("\u{1b}[?2004h") { $0.pasteText("") }
        XCTAssertEqual(r.ghostty, "")
        XCTAssertEqual(r.swiftTerm, "\\x1b[200~\\x1b[201~")
    }

    // MARK: Theme

    func testThemeReachesEveryPartOnBothEngines() {
        for theme in ThemeStore.all {
            let (g, _, t, _) = engines()
            g.apply(theme: theme)
            t.apply(theme: theme)
            XCTAssertEqual(g.keyboardAppearance, t.keyboardAppearance, theme.name)
            XCTAssertEqual(g.keyboardAppearance, theme.isDark ? .dark : .light, theme.name)
            XCTAssertEqual(g.backgroundColor, theme.uiBG, theme.name)
            _ = g.renderer.frame.update(core: g.core)
            g.core.sync()
            _ = g.renderer.frame.update(core: g.core)
            g.scroller.apply(g.core.scroll.snapshot)
            XCTAssertEqual(g.scroller.surface.indicatorStyle, t.indicatorStyle, theme.name)
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
