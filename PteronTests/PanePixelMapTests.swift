import RexKit
import XCTest
@testable import Pteron
@testable import RexKit

/// Records which way the engine sent its bytes.
private final class ReportSpy: TerminalEngineDelegate {
    var typed: [[UInt8]] = []
    var reports: [[UInt8]] = []
    func engineGridChanged(cols: Int, rows: Int) {}
    func engineSend(_ bytes: [UInt8]) { typed.append(bytes) }
    func engineSendReport(_ bytes: [UInt8]) -> Bool {
        reports.append(bytes)
        return true
    }
}

/// SGR-Pixels mouse reports (mode 1016) in the pane's own pixels on the server (`PanePixelMap`),
/// so the program finds the cell the finger is on. A Rex pane tells its program 8 x 16 pixel
/// cells; the phone draws other ones.
@MainActor
final class PanePixelMapTests: XCTestCase {
    /// 80 x 24 cells of 10 x 20 device pixels.
    private let device = GhosttyMouseReporter.Geometry(width: 800, height: 480, cellWidth: 10, cellHeight: 20)
    private let rex = CellPixels(width: 8, height: 16)!
    /// The middle of cell column 2, row 1 (0-based).
    private let point = CGPoint(x: 25, y: 30)

    private func core(_ modes: String, cols: Int = 80, rows: Int = 24) -> GhosttyCore {
        let core = GhosttyCore(cols: cols, rows: rows)
        core.feed(Array(modes.utf8))
        core.sync()
        return core
    }

    private func text(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\u{1b}", with: "ESC")
    }

    /// The column and row (0-based) a program finds in the first SGR-Pixels report of `bytes`
    /// (a click is a press and a release), told `cell`.
    private func cellOf(_ bytes: [UInt8], cell: CellPixels) -> (col: Int, row: Int)? {
        let s = String(decoding: bytes, as: UTF8.self)
        guard s.hasPrefix("\u{1b}[<"), let end = s.firstIndex(where: { $0 == "M" || $0 == "m" }) else { return nil }
        let fields = s[s.index(s.startIndex, offsetBy: 3)..<end].split(separator: ";").compactMap { Int($0) }
        guard fields.count == 3 else { return nil }
        return (fields[1] / cell.width, fields[2] / cell.height)
    }

    // MARK: The mapping

    func testAnUnknownCellSizeMapsNothing() {
        XCTAssertNil(PanePixelMap.map(point, device: device, pane: nil, cols: 80, rows: 24))
        let flat = GhosttyMouseReporter.Geometry(width: 800, height: 480, cellWidth: 0, cellHeight: 20)
        XCTAssertNil(PanePixelMap.map(point, device: flat, pane: rex, cols: 80, rows: 24))
        XCTAssertNil(PanePixelMap.map(point, device: device, pane: rex, cols: 0, rows: 24))
    }

    func testTheFractionOfACellIsKeptInThePanesCells() {
        let m = PanePixelMap.map(point, device: device, pane: rex, cols: 80, rows: 24)
        XCTAssertEqual(m?.position, CGPoint(x: 20, y: 24), "2.5 x 8, 1.5 x 16")
        XCTAssertEqual(m?.geometry, .init(width: 640, height: 384, cellWidth: 8, cellHeight: 16), "Rex's 640 x 384")
        XCTAssertEqual(PanePixelMap.map(.zero, device: device, pane: rex, cols: 80, rows: 24)?.position, .zero)
    }

    /// Every device pixel of the grid lands in its own cell, whatever the two cell sizes are.
    func testEveryPixelLandsInItsCell() {
        let sizes: [(device: (Int, Int), pane: (Int, Int))] = [((10, 20), (8, 16)), ((17, 35), (8, 16)), ((7, 15), (8, 16)),
                                                                 ((21, 44), (7, 15)), ((8, 16), (8, 16))]
        for s in sizes {
            let cols = 23, rows = 9
            let g = GhosttyMouseReporter.Geometry(width: cols * s.device.0, height: rows * s.device.1,
                                                  cellWidth: s.device.0, cellHeight: s.device.1)
            let pane = CellPixels(width: s.pane.0, height: s.pane.1)!
            for x in 0..<g.width {
                for y in stride(from: 0, to: g.height, by: 3) {
                    // A touch is fractional: half a pixel in, and the pixel's far edge.
                    for dx in [0, 0.5, 0.999] as [CGFloat] {
                        let p = CGPoint(x: CGFloat(x) + dx, y: CGFloat(y) + dx)
                        guard let m = PanePixelMap.map(p, device: g, pane: pane, cols: cols, rows: rows) else {
                            return XCTFail("\(s)")
                        }
                        XCTAssertEqual(Int(m.position.x) / pane.width, x / s.device.0, "\(s) x \(p.x)")
                        XCTAssertEqual(Int(m.position.y) / pane.height, y / s.device.1, "\(s) y \(p.y)")
                    }
                }
            }
        }
    }

    func testAPointPastTheGridOnTheViewIsTheLastCell() {
        // The view is wider and taller than the grid by part of a cell.
        let view = GhosttyMouseReporter.Geometry(width: 806, height: 492, cellWidth: 10, cellHeight: 20)
        let m = PanePixelMap.map(CGPoint(x: 805, y: 491), device: view, pane: rex, cols: 80, rows: 24)
        XCTAssertEqual(m?.position, CGPoint(x: 639, y: 383))
        // A drag that left the view keeps going: the program may want to know.
        XCTAssertEqual(PanePixelMap.map(CGPoint(x: 900, y: -21), device: view, pane: rex, cols: 80, rows: 24)?.position,
                       CGPoint(x: 720, y: -17))
    }

    // MARK: The reports

    /// H-F3e: with no cell size from the server, a program that asked for pixels gets SGR cell
    /// reports, which every program that reads SGR-Pixels also reads.
    func testUnknownCellSizeReportsSGRCells() {
        let r = GhosttyMouseReporter(), c = core("\u{1b}[?1003h\u{1b}[?1016h")
        XCTAssertEqual(text(r.mouse(.press, button: .left, at: point, buttonHeld: true, geometry: device, core: c)), "ESC[<0;3;2M")
        XCTAssertEqual(text(r.mouse(.release, button: .left, at: point, buttonHeld: false, geometry: device, core: c)), "ESC[<0;3;2m")
        XCTAssertEqual(text(r.mouse(.motion, button: .none, at: CGPoint(x: 36, y: 30), buttonHeld: false, geometry: device, core: c)),
                       "ESC[<35;4;2M")
        XCTAssertEqual(r.mouse(.motion, button: .none, at: CGPoint(x: 38, y: 31), buttonHeld: false, geometry: device, core: c), [],
                       "once per cell, as SGR")
        // Known again: pixels again.
        XCTAssertEqual(text(r.mouse(.press, button: .left, at: point, buttonHeld: true, geometry: device, pane: rex, core: c)),
                       "ESC[<0;20;24M")
    }

    func testPixelReportsAreInThePanesPixels() {
        let r = GhosttyMouseReporter(), c = core("\u{1b}[?1003h\u{1b}[?1016h")
        func send(_ a: GhosttyMouseReporter.Action, _ b: GhosttyMouseReporter.Button, _ p: CGPoint, held: Bool,
                  mods: GhosttyMouseReporter.Modifiers = [], count: Int = 1) -> String {
            text(r.mouse(a, button: b, at: p, modifiers: mods, buttonHeld: held, geometry: device, pane: rex, count: count, core: c))
        }
        XCTAssertEqual(send(.press, .left, point, held: true), "ESC[<0;20;24M")
        XCTAssertEqual(send(.release, .left, point, held: false), "ESC[<0;20;24m")
        XCTAssertEqual(send(.press, .right, point, held: true, mods: .control), "ESC[<18;20;24M")
        XCTAssertEqual(send(.press, .wheelDown, point, held: false, count: 2), "ESC[<65;20;24MESC[<65;20;24M")
        // Never deduplicated: every pixel of motion counts.
        XCTAssertEqual(send(.motion, .none, CGPoint(x: 26.5, y: 30), held: false), "ESC[<35;21;24M")
        XCTAssertEqual(send(.motion, .none, CGPoint(x: 28, y: 30), held: false), "ESC[<35;22;24M")
        // The last pixel of the grid is in the last cell: 799 / 10 x 8 = 639.2.
        XCTAssertEqual(send(.press, .left, CGPoint(x: 799, y: 479), held: true), "ESC[<0;639;383M")
        // A drag out of the pane still reports, past its edge.
        XCTAssertEqual(send(.press, .left, point, held: true), "ESC[<0;20;24M")
        XCTAssertEqual(send(.motion, .left, CGPoint(x: 850, y: 30), held: true), "ESC[<32;680;24M")
    }

    /// The format is the one the program set last: 1016 can be on under 1006.
    func testTheLastFormatSetDecides() {
        let cases: [(String, String)] = [
            ("\u{1b}[?1000h\u{1b}[?1016h\u{1b}[?1006h", "ESC[<0;3;2M"),
            ("\u{1b}[?1000h\u{1b}[?1006h\u{1b}[?1016h", "ESC[<0;20;24M"),
            ("\u{1b}[?1000h\u{1b}[?1016h\u{1b}[?1016l\u{1b}[?1006h", "ESC[<0;3;2M"),
            ("\u{1b}[?9h\u{1b}[?1016h", "ESC[<0;20;24M"),
        ]
        for (modes, want) in cases {
            let r = GhosttyMouseReporter(), c = core(modes)
            XCTAssertEqual(text(r.mouse(.press, button: .left, at: point, buttonHeld: true, geometry: device, pane: rex, core: c)),
                           want, text(Array(modes.utf8)))
        }
        // A program that switches format between two clicks.
        let r = GhosttyMouseReporter(), c = core("\u{1b}[?1000h\u{1b}[?1016h")
        XCTAssertEqual(text(r.mouse(.press, button: .left, at: point, buttonHeld: true, geometry: device, pane: rex, core: c)),
                       "ESC[<0;20;24M")
        c.feed(Array("\u{1b}[?1006h".utf8))
        c.sync()
        XCTAssertEqual(text(r.mouse(.press, button: .left, at: point, buttonHeld: true, geometry: device, pane: rex, core: c)),
                       "ESC[<0;3;2M")
        c.feed(Array("\u{1b}[?1016h".utf8))
        c.sync()
        XCTAssertEqual(text(r.mouse(.press, button: .left, at: point, buttonHeld: true, geometry: device, pane: rex, core: c)),
                       "ESC[<0;20;24M")
    }

    /// H-F3a: every other format sends exactly the bytes it sent before, with the pane's cell
    /// size known or not. The literal reports are the ones `GhosttyMouseTests` pinned before
    /// pixel reports were mapped.
    func testOtherFormatsAreByteIdentical() {
        XCTAssertEqual(text(press("\u{1b}[?1000h\u{1b}[?1006h", pane: rex)), "ESC[<0;3;2M")
        XCTAssertEqual(press("\u{1b}[?1000h", pane: rex), [0x1b, 0x5b, 0x4d, 32, 32 + 3, 32 + 2])
        XCTAssertEqual(text(press("\u{1b}[?1002h\u{1b}[?1006h", pane: rex)), "ESC[<0;3;2M")
        XCTAssertEqual(text(press("\u{1b}[?1003h\u{1b}[?1015h", pane: rex)), "ESC[32;3;2M")

        let modes = ["\u{1b}[?9h", "\u{1b}[?1000h", "\u{1b}[?1002h", "\u{1b}[?1003h"]
        let formats = ["", "\u{1b}[?1005h", "\u{1b}[?1006h", "\u{1b}[?1015h", "\u{1b}[?1016h\u{1b}[?1006h"]
        // On the grid, in the view's margin, and out of the view.
        let points = [point, .zero, CGPoint(x: 799, y: 479), CGPoint(x: 803, y: 485), CGPoint(x: -4, y: 30),
                      CGPoint(x: 900, y: 600), CGPoint(x: 135.5, y: 211.9)]
        let view = GhosttyMouseReporter.Geometry(width: 806, height: 492, cellWidth: 10, cellHeight: 20)
        for mode in modes {
            for format in formats {
                let c = core(mode + format)
                let before = GhosttyMouseReporter(), after = GhosttyMouseReporter()
                var events = 0
                func both(_ a: GhosttyMouseReporter.Action, _ b: GhosttyMouseReporter.Button, _ p: CGPoint, held: Bool,
                          mods: GhosttyMouseReporter.Modifiers = []) {
                    let old = before.mouse(a, button: b, at: p, modifiers: mods, buttonHeld: held, geometry: view, core: c)
                    let new = after.mouse(a, button: b, at: p, modifiers: mods, buttonHeld: held, geometry: view, pane: rex, core: c)
                    XCTAssertEqual(old, new, "\(text(Array((mode + format).utf8))) \(a) \(b) \(p)")
                    if !old.isEmpty { events += 1 }
                }
                for p in points {
                    both(.press, .left, p, held: true)
                    both(.motion, .left, CGPoint(x: p.x + 7, y: p.y + 3), held: true)
                    both(.motion, .left, CGPoint(x: p.x + 31, y: p.y + 22), held: true)
                    both(.release, .left, CGPoint(x: p.x + 31, y: p.y + 22), held: false)
                    both(.motion, .none, p, held: false)
                    both(.press, .wheelUp, p, held: false, mods: [.shift, .alt])
                    both(.press, .middle, p, held: true, mods: .control)
                    both(.release, .middle, p, held: false)
                }
                XCTAssertGreaterThan(events, 0, "the program got reports")
            }
        }
    }

    private func press(_ modes: String, pane: CellPixels?) -> [UInt8] {
        GhosttyMouseReporter().mouse(.press, button: .left, at: point, buttonHeld: true, geometry: device, pane: pane,
                                     core: core(modes))
    }

    /// H-F3c: each report uses the cell sizes of its moment: the server's newest (a resize or
    /// a font change there) and the phone's (a pinch here).
    func testReportsFollowTheNewestCellSizes() {
        let r = GhosttyMouseReporter(), c = core("\u{1b}[?1000h\u{1b}[?1016h")
        func click(_ g: GhosttyMouseReporter.Geometry, _ pane: CellPixels?, _ p: CGPoint) -> String {
            text(r.mouse(.press, button: .left, at: p, buttonHeld: true, geometry: g, pane: pane, core: c))
        }
        XCTAssertEqual(click(device, rex, point), "ESC[<0;20;24M")
        XCTAssertEqual(click(device, CellPixels(width: 10, height: 20), point), "ESC[<0;25;30M", "a larger font on the server")
        XCTAssertEqual(click(device, rex, point), "ESC[<0;20;24M")
        // A pinch here: cells of 14 x 28. The middle of column 2, row 1 is (35, 42).
        let pinched = GhosttyMouseReporter.Geometry(width: 1120, height: 672, cellWidth: 14, cellHeight: 28)
        XCTAssertEqual(click(pinched, rex, CGPoint(x: 35, y: 42)), "ESC[<0;20;24M")
        // A server resize: the grid is 100 x 30 now, and its far corner is still on the grid.
        c.resize(cols: 100, rows: 30, cellWidthPx: 10, cellHeightPx: 20)
        c.sync()
        let wide = GhosttyMouseReporter.Geometry(width: 1000, height: 600, cellWidth: 10, cellHeight: 20)
        XCTAssertEqual(click(wide, rex, CGPoint(x: 999, y: 599)), "ESC[<0;799;479M")
    }

    // MARK: Through the view

    /// A view of `cols` x `rows` whose program asked for `modes`.
    private func view(_ modes: String, cols: Int = 40, rows: Int = 10) -> GhosttyTerminalView {
        let v = GhosttyTerminalView(frame: .zero, fontSize: 12, cols: cols, rows: rows)
        let cell = v.cellSize
        v.frame = CGRect(x: 0, y: 0, width: cell.width * CGFloat(cols), height: cell.height * CGFloat(rows))
        v.layoutIfNeeded()
        v.feed(text: modes)
        v.core.sync()
        _ = v.renderer.frame.update(core: v.core)
        v.scroller.apply(v.core.scroll.snapshot)
        return v
    }

    private final class Zooms: NSObject, UIScrollViewDelegate {
        let content: UIView
        init(_ content: UIView) { self.content = content }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }
    }

    /// H-F3b: a mirror zoom and pan and a pane's place in a split change where the finger is on
    /// the glass, not the cell the program finds.
    func testZoomPanAndASplitLandOnTheTouchedCell() {
        let term = view("\u{1b}[?1000h\u{1b}[?1016h")
        term.paneCellPixels = rex
        let cell = term.cellSize
        // The pane is the right half of a split, in a zoomed and panned scroll view.
        let left: CGFloat = 213
        let content = UIView(frame: CGRect(x: 0, y: 0, width: left + term.bounds.width, height: term.bounds.height + 40))
        term.frame.origin = CGPoint(x: left, y: 40)
        content.addSubview(term)
        let screen = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 60, width: 400, height: 640))
        screen.addSubview(scroll)
        scroll.addSubview(content)
        scroll.contentSize = content.bounds.size
        let zooms = Zooms(content)
        scroll.delegate = zooms
        scroll.minimumZoomScale = 0.2
        scroll.maximumZoomScale = 4

        for (zoom, pan) in [(CGFloat(1), CGPoint.zero), (0.55, CGPoint(x: 30, y: 12)), (1.7, CGPoint(x: 260, y: 90)),
                            (0.31, CGPoint(x: 0, y: 0))] {
            scroll.zoomScale = zoom
            scroll.contentOffset = pan
            for (col, row) in [(0, 0), (5, 3), (17, 9), (39, 9), (39, 0)] {
                // Where the cell's middle is on the screen, worked out by hand from where the
                // zoomed content lies in the scroll view.
                let inContent = CGPoint(x: left + (CGFloat(col) + 0.5) * cell.width, y: 40 + (CGFloat(row) + 0.5) * cell.height)
                let onScreen = CGPoint(x: content.frame.minX + inContent.x * zoom - pan.x + scroll.frame.minX,
                                       y: content.frame.minY + inContent.y * zoom - pan.y + scroll.frame.minY)
                // What a gesture's location in the pane gives.
                let touch = screen.convert(onScreen, to: term)
                let bytes = term.scroller.tapBytes(at: touch)
                let found = cellOf(bytes, cell: rex)
                XCTAssertEqual(found?.col, col, "zoom \(zoom) pan \(pan) \(text(bytes))")
                XCTAssertEqual(found?.row, row, "zoom \(zoom) pan \(pan) \(text(bytes))")
            }
        }
        withExtendedLifetime(zooms) {}
    }

    /// The view's grid is the server's whatever the phone's font: a mirrored pane drawn small.
    func testAMirroredPaneAtAnyFontFindsTheCell() {
        for size in [CGFloat(7), 12, 19] {
            let term = GhosttyTerminalView(frame: .zero, fontSize: size, cols: 120, rows: 40)
            let cell = term.cellSize
            term.frame = CGRect(x: 0, y: 0, width: cell.width * 120, height: cell.height * 40)
            term.layoutIfNeeded()
            term.feed(text: "\u{1b}[?1000h\u{1b}[?1016h")
            term.core.sync()
            _ = term.renderer.frame.update(core: term.core)
            term.scroller.apply(term.core.scroll.snapshot)
            term.paneCellPixels = rex
            for (col, row) in [(0, 0), (64, 21), (119, 39)] {
                let bytes = term.scroller.tapBytes(at: CGPoint(x: (CGFloat(col) + 0.2) * cell.width, y: (CGFloat(row) + 0.8) * cell.height))
                let found = cellOf(bytes, cell: rex)
                XCTAssertEqual(found?.col, col, "font \(size) \(text(bytes))")
                XCTAssertEqual(found?.row, row, "font \(size) \(text(bytes))")
            }
        }
    }

    /// H-F3d: a pixel report goes the way every report goes (`engineSendReport`), never as typing.
    func testPixelReportsGoAsReports() {
        let term = view("\u{1b}[?1003h\u{1b}[?1016h")
        term.paneCellPixels = rex
        let spy = ReportSpy()
        term.engineDelegate = spy
        let cell = term.cellSize
        // Fractions that make no whole pixel: 2.3 x 8 = 18.4, 1.4 x 16 = 22.4.
        let click = term.scroller.forwardTap(at: CGPoint(x: 2.3 * cell.width, y: 1.4 * cell.height))
        let motion = term.scroller.forwardMotion(at: CGPoint(x: 7.3 * cell.width, y: 3.6 * cell.height), buttonHeld: false)
        XCTAssertEqual(text(click), "ESC[<0;18;22MESC[<0;18;22m")
        XCTAssertEqual(text(motion), "ESC[<35;58;57M")
        XCTAssertEqual(spy.reports, [click, motion])
        XCTAssertEqual(spy.typed, [])
    }

    /// H-F3d: behind the catch-up fence a pixel report is dropped, as every report is.
    func testAPixelReportIsDroppedBehindTheFence() {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = TerminalStream(control: control, sessionID: "s", blockID: "b")
        let host = TerminalHost(stream: stream, sizing: .mirror, fontSize: 12, theme: ThemeStore.fallback)
        host.term.setGrid(cols: 40, rows: 10, force: true)
        let cell = host.term.cellSize
        host.term.frame = CGRect(x: 0, y: 0, width: cell.width * 40, height: cell.height * 10)
        host.term.layoutIfNeeded()
        host.term.feed(text: "\u{1b}[?1000h\u{1b}[?1016h")
        host.term.core.sync()
        _ = host.term.renderer.frame.update(core: host.term.core)
        host.term.scroller.apply(host.term.core.scroll.snapshot)
        host.term.paneCellPixels = rex
        let at = CGPoint(x: 2.3 * cell.width, y: 1.4 * cell.height)
        // Current: queued like any input (no connection here, so it waits).
        XCTAssertEqual(text(host.term.scroller.forwardTap(at: at)), "ESC[<0;18;22MESC[<0;18;22m")
        XCTAssertTrue(stream.hasPendingInput)
        stream.stop()
        stream.start()
        XCTAssertTrue(stream.isFenced)
        XCTAssertFalse(host.term.scroller.forwardTap(at: at).isEmpty)
        XCTAssertFalse(stream.hasPendingInput, "not sent and not held")
        stream.stop()
    }

    /// H-F3c and H-F3e through the host: each size the stream says sets the pane's cell size, and
    /// one without it (an older server) clears it.
    func testTheHostTakesEachSizeTheStreamSays() {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = TerminalStream(control: control, sessionID: "s", blockID: "b")
        let host = TerminalHost(stream: stream, sizing: .mirror, fontSize: 12, theme: ThemeStore.fallback)
        let nonce: UInt64 = 4242
        stream.beginStream(nonce: nonce, collectSnapshot: false)
        func resize(_ extra: String) {
            let json = "{\"type\":\"resize\",\"cols\":80,\"rows\":24\(extra),\"owner\":null}"
            stream.consume(Data("\u{1b}_rex1;\(nonce);\(json)\u{1b}\\".utf8))
        }
        XCTAssertNil(host.term.paneCellPixels)
        resize(",\"cell_width_px\":8,\"cell_height_px\":16")
        XCTAssertEqual(host.term.paneCellPixels, rex)
        resize(",\"cell_width_px\":11,\"cell_height_px\":22")
        XCTAssertEqual(host.term.paneCellPixels, CellPixels(width: 11, height: 22))
        resize("")
        XCTAssertNil(host.term.paneCellPixels, "an older server")
        resize(",\"cell_width_px\":0,\"cell_height_px\":0")
        XCTAssertNil(host.term.paneCellPixels, "a size the server doesn't know")
        stream.stop()
    }
}
