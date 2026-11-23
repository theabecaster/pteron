import XCTest
@testable import Pteron

final class GhosttyMouseTests: XCTestCase {
    /// 80 x 24 cells of 10 x 20 pixels.
    private let geometry = GhosttyMouseReporter.Geometry(width: 800, height: 480, cellWidth: 10, cellHeight: 20)
    /// The middle of cell column 3, row 2 (1-based: 3, 2).
    private let point = CGPoint(x: 25, y: 30)

    private func core(_ modes: String) -> GhosttyCore {
        let core = GhosttyCore(cols: 80, rows: 24)
        core.feed(Array(modes.utf8))
        core.sync()
        return core
    }

    private func text(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "\u{1b}", with: "ESC")
    }

    private func press(_ r: GhosttyMouseReporter, _ c: GhosttyCore, _ button: GhosttyMouseReporter.Button = .left,
                       at p: CGPoint? = nil, modifiers: GhosttyMouseReporter.Modifiers = []) -> [UInt8] {
        r.mouse(.press, button: button, at: p ?? point, modifiers: modifiers, buttonHeld: true, geometry: geometry, core: c)
    }

    private func release(_ r: GhosttyMouseReporter, _ c: GhosttyCore, at p: CGPoint? = nil) -> [UInt8] {
        r.mouse(.release, button: .left, at: p ?? point, buttonHeld: false, geometry: geometry, core: c)
    }

    private func motion(_ r: GhosttyMouseReporter, _ c: GhosttyCore, at p: CGPoint, held: Bool) -> [UInt8] {
        r.mouse(.motion, button: held ? .left : .none, at: p, buttonHeld: held, geometry: geometry, core: c)
    }

    // MARK: Formats

    func testNothingIsSentWithoutTracking() {
        let r = GhosttyMouseReporter(), c = core("")
        XCTAssertEqual(press(r, c), [])
        XCTAssertEqual(release(r, c), [])
        XCTAssertEqual(press(r, c, .wheelUp), [])
        XCTAssertEqual(motion(r, c, at: point, held: true), [])
    }

    func testX10Format() {
        let r = GhosttyMouseReporter(), c = core("\u{1b}[?1000h")
        XCTAssertEqual(press(r, c), [0x1b, 0x5b, 0x4d, 32, 32 + 3, 32 + 2])
        XCTAssertEqual(release(r, c), [0x1b, 0x5b, 0x4d, 32 + 3, 32 + 3, 32 + 2], "legacy releases are button 3")
        XCTAssertEqual(press(r, c, .wheelUp), [0x1b, 0x5b, 0x4d, 32 + 64, 35, 34])
        XCTAssertEqual(press(r, c, .wheelDown), [0x1b, 0x5b, 0x4d, 32 + 65, 35, 34])
        XCTAssertEqual(press(r, c, modifiers: [.shift, .control]), [0x1b, 0x5b, 0x4d, 32 + 4 + 16, 35, 34])
        // The format can't say columns past 223.
        let wide = GhosttyMouseReporter.Geometry(width: 3000, height: 480, cellWidth: 10, cellHeight: 20)
        XCTAssertEqual(r.mouse(.press, button: .left, at: CGPoint(x: 2500, y: 30), buttonHeld: true, geometry: wide, core: c), [])
    }

    func testUTF8Format() {
        let r = GhosttyMouseReporter(), c = core("\u{1b}[?1000h\u{1b}[?1005h")
        XCTAssertEqual(press(r, c), [0x1b, 0x5b, 0x4d, 32, 35, 34])
        // Column 201 is 233 in the report: two UTF-8 bytes.
        let wide = GhosttyMouseReporter.Geometry(width: 3000, height: 480, cellWidth: 10, cellHeight: 20)
        let far = r.mouse(.press, button: .left, at: CGPoint(x: 2005, y: 30), buttonHeld: true, geometry: wide, core: c)
        XCTAssertEqual(far, [0x1b, 0x5b, 0x4d, 32] + Array(String(UnicodeScalar(233)!).utf8) + [34])
    }

    func testSGRFormat() {
        let r = GhosttyMouseReporter(), c = core("\u{1b}[?1000h\u{1b}[?1006h")
        XCTAssertEqual(text(press(r, c)), "ESC[<0;3;2M")
        XCTAssertEqual(text(release(r, c)), "ESC[<0;3;2m")
        XCTAssertEqual(text(press(r, c, .middle)), "ESC[<1;3;2M")
        XCTAssertEqual(text(press(r, c, .right)), "ESC[<2;3;2M")
        XCTAssertEqual(text(press(r, c, .wheelUp)), "ESC[<64;3;2M")
        XCTAssertEqual(text(press(r, c, .wheelDown)), "ESC[<65;3;2M")
        XCTAssertEqual(text(press(r, c, modifiers: .shift)), "ESC[<4;3;2M")
        XCTAssertEqual(text(press(r, c, modifiers: .alt)), "ESC[<8;3;2M")
        XCTAssertEqual(text(press(r, c, modifiers: .control)), "ESC[<16;3;2M")
        XCTAssertEqual(text(press(r, c, at: CGPoint(x: 0, y: 0))), "ESC[<0;1;1M")
        XCTAssertEqual(text(press(r, c, at: CGPoint(x: 799, y: 479))), "ESC[<0;80;24M")
    }

    func testURxvtFormat() {
        let r = GhosttyMouseReporter(), c = core("\u{1b}[?1000h\u{1b}[?1015h")
        XCTAssertEqual(text(press(r, c)), "ESC[32;3;2M")
        XCTAssertEqual(text(release(r, c)), "ESC[35;3;2M")
        XCTAssertEqual(text(press(r, c, .wheelDown)), "ESC[97;3;2M")
    }

    func testSGRPixelsFormatReportsPixels() {
        let r = GhosttyMouseReporter(), c = core("\u{1b}[?1003h\u{1b}[?1016h")
        XCTAssertEqual(text(press(r, c)), "ESC[<0;25;30M")
        XCTAssertEqual(text(release(r, c)), "ESC[<0;25;30m")
        // Never deduplicated: every pixel of motion counts.
        XCTAssertEqual(text(motion(r, c, at: CGPoint(x: 26, y: 30), held: false)), "ESC[<35;26;30M")
        XCTAssertEqual(text(motion(r, c, at: CGPoint(x: 27, y: 30), held: false)), "ESC[<35;27;30M")
    }

    func testRepeatedReports() {
        let r = GhosttyMouseReporter(), c = core("\u{1b}[?1000h\u{1b}[?1006h")
        let three = r.mouse(.press, button: .wheelUp, at: point, buttonHeld: false, geometry: geometry, count: 3, core: c)
        XCTAssertEqual(text(three), "ESC[<64;3;2MESC[<64;3;2MESC[<64;3;2M")
        XCTAssertEqual(r.mouse(.press, button: .wheelUp, at: point, buttonHeld: false, geometry: geometry, count: 0, core: c), [])
    }

    // MARK: Tracking modes

    func testX10TrackingReportsPressesOnly() {
        let r = GhosttyMouseReporter(), c = core("\u{1b}[?9h\u{1b}[?1006h")
        XCTAssertEqual(text(press(r, c)), "ESC[<0;3;2M")
        XCTAssertEqual(release(r, c), [])
        XCTAssertEqual(press(r, c, .wheelUp), [], "X10 tracking knows three buttons")
        XCTAssertEqual(text(press(r, c, modifiers: .control)), "ESC[<0;3;2M", "and no modifiers")
        XCTAssertEqual(motion(r, c, at: point, held: true), [])
    }

    func testNormalTrackingReportsNoMotion() {
        let r = GhosttyMouseReporter(), c = core("\u{1b}[?1000h\u{1b}[?1006h")
        XCTAssertEqual(motion(r, c, at: point, held: true), [])
        XCTAssertEqual(motion(r, c, at: point, held: false), [])
    }

    func testButtonTrackingReportsDragsOncePerCell() {
        let r = GhosttyMouseReporter(), c = core("\u{1b}[?1002h\u{1b}[?1006h")
        XCTAssertEqual(text(press(r, c)), "ESC[<0;3;2M")
        XCTAssertEqual(motion(r, c, at: CGPoint(x: 27, y: 31), held: true), [], "same cell as the press")
        XCTAssertEqual(text(motion(r, c, at: CGPoint(x: 35, y: 30), held: true)), "ESC[<32;4;2M")
        XCTAssertEqual(motion(r, c, at: CGPoint(x: 38, y: 35), held: true), [], "still that cell")
        XCTAssertEqual(text(motion(r, c, at: CGPoint(x: 35, y: 50), held: true)), "ESC[<32;4;3M")
        XCTAssertEqual(text(release(r, c, at: CGPoint(x: 35, y: 50))), "ESC[<0;4;3m")
        // No button, no report.
        XCTAssertEqual(motion(r, c, at: CGPoint(x: 95, y: 90), held: false), [])
    }

    func testAnyEventTrackingReportsHover() {
        let r = GhosttyMouseReporter(), c = core("\u{1b}[?1003h\u{1b}[?1006h")
        XCTAssertEqual(text(motion(r, c, at: point, held: false)), "ESC[<35;3;2M")
        XCTAssertEqual(motion(r, c, at: CGPoint(x: 28, y: 22), held: false), [])
        XCTAssertEqual(text(motion(r, c, at: CGPoint(x: 5, y: 5), held: false)), "ESC[<35;1;1M")
        // A new hover starts fresh, even in the cell the last one ended in.
        r.resetMotion()
        XCTAssertEqual(text(motion(r, c, at: CGPoint(x: 5, y: 5), held: false)), "ESC[<35;1;1M")
        // Outside the grid: only while a button is held.
        XCTAssertEqual(motion(r, c, at: CGPoint(x: -30, y: 5), held: false), [])
        XCTAssertFalse(motion(r, c, at: CGPoint(x: -30, y: 45), held: true).isEmpty)
    }

    func testModeChangesAreSeenByTheNextEvent() {
        let r = GhosttyMouseReporter(), c = core("\u{1b}[?1003h\u{1b}[?1006h")
        XCTAssertEqual(text(motion(r, c, at: point, held: false)), "ESC[<35;3;2M")
        // The program turns tracking off between two motion events.
        c.feed(Array("\u{1b}[?1003l".utf8))
        c.sync()
        XCTAssertEqual(motion(r, c, at: CGPoint(x: 95, y: 90), held: false), [])
        XCTAssertEqual(press(r, c), [])
        // And picks another format.
        c.feed(Array("\u{1b}[?1000h\u{1b}[?1006l\u{1b}[?1015h".utf8))
        c.sync()
        XCTAssertEqual(text(press(r, c)), "ESC[32;3;2M")
    }

    func testAResetTerminalReportsNothing() {
        let r = GhosttyMouseReporter(), c = core("\u{1b}[?1000h\u{1b}[?1006h")
        XCTAssertFalse(press(r, c).isEmpty)
        c.reset()
        c.sync()
        XCTAssertEqual(press(r, c), [])
    }

    // MARK: Keys for alternate scroll and paging

    func testScrollKeysFollowTheProgramsModes() {
        let r = GhosttyMouseReporter(), c = core("")
        XCTAssertEqual(text(r.key(.arrowUp, core: c)), "ESC[A")
        XCTAssertEqual(text(r.key(.arrowDown, count: 3, core: c)), "ESC[BESC[BESC[B")
        XCTAssertEqual(text(r.key(.pageUp, core: c)), "ESC[5~")
        XCTAssertEqual(text(r.key(.pageDown, core: c)), "ESC[6~")
        c.feed(Array("\u{1b}[?1h".utf8))
        c.sync()
        XCTAssertEqual(text(r.key(.arrowUp, core: c)), "ESCOA", "application cursor keys")
        XCTAssertEqual(text(r.key(.arrowDown, core: c)), "ESCOB")
    }

    // MARK: Wheel, arrows or scrollback

    func testDragDecisionTable() {
        typealias T = GhosttyScrollRouting.Target
        // (fingers, mouse tracking, alternate screen, alternate scroll, shift) -> target
        let table: [(Int, Bool, Bool, Bool, Bool, T)] = [
            // Main screen, nothing tracking: the view's own scrollback, whatever mode 1007 says.
            (1, false, false, false, false, .scrollback),
            (1, false, false, true, false, .scrollback),
            (2, false, false, true, false, .scrollback),
            (0, false, false, true, false, .scrollback),
            // Mouse tracking: wheel reports, on either screen, with or without mode 1007.
            (1, true, false, false, false, .wheel),
            (1, true, false, true, false, .wheel),
            (1, true, true, false, false, .wheel),
            (1, true, true, true, false, .wheel),
            (0, true, false, false, false, .wheel),
            (0, true, true, true, false, .wheel),
            // Alternate screen without tracking: arrows if alternate scroll is on, else nothing.
            (1, false, true, true, false, .arrows),
            (0, false, true, true, false, .arrows),
            (1, false, true, false, false, .nothing),
            (0, false, true, false, false, .nothing),
            // Two fingers always scroll locally.
            (2, true, false, false, false, .scrollback),
            (2, true, true, true, false, .scrollback),
            (2, false, true, true, false, .scrollback),
            // Shift keeps the program out: a pointer scroll goes local, a finger drag does nothing.
            (0, true, false, false, true, .scrollback),
            (0, false, true, true, true, .scrollback),
            (1, true, false, false, true, .nothing),
            (1, false, true, true, true, .nothing),
            (1, false, false, false, true, .scrollback),
        ]
        for (fingers, tracking, alternate, alternateScroll, shift, expected) in table {
            XCTAssertEqual(GhosttyScrollRouting.target(fingers: fingers, mouseTracking: tracking, alternateScreen: alternate,
                                                       alternateScroll: alternateScroll, shift: shift), expected,
                           "fingers \(fingers) tracking \(tracking) alternate \(alternate) 1007 \(alternateScroll) shift \(shift)")
        }
        XCTAssertEqual(GhosttyScrollRouting.route(mouseTracking: true, alternateScreen: true, alternateScroll: true, shiftBypass: false), .mouse)
        XCTAssertEqual(GhosttyScrollRouting.route(mouseTracking: false, alternateScreen: true, alternateScroll: true, shiftBypass: false), .cursorKeys)
        XCTAssertEqual(GhosttyScrollRouting.route(mouseTracking: false, alternateScreen: false, alternateScroll: true, shiftBypass: false), .none)
        XCTAssertEqual(GhosttyScrollRouting.route(mouseTracking: true, alternateScreen: false, alternateScroll: false, shiftBypass: true), .none)
        XCTAssertTrue(GhosttyScrollRouting.captures(mouseTracking: false, alternateScreen: true))
        XCTAssertTrue(GhosttyScrollRouting.captures(mouseTracking: true, alternateScreen: false))
        XCTAssertFalse(GhosttyScrollRouting.captures(mouseTracking: false, alternateScreen: false))
    }

    func testTheTerminalsModesFeedTheDecision() {
        let c = core("")
        XCTAssertFalse(c.programScrollModes().mouseTracking)
        XCTAssertFalse(c.programScrollModes().alternateScreen)
        c.feed(Array("\u{1b}[?1049h\u{1b}[?1007h".utf8))
        c.sync()
        XCTAssertTrue(c.programScrollModes() == (false, true, true))
        c.feed(Array("\u{1b}[?1007l\u{1b}[?1002h".utf8))
        c.sync()
        XCTAssertTrue(c.programScrollModes() == (true, true, false))
    }

    func testAccumulatorKeepsPartLinesPerRoute() {
        var a = GhosttyWheelAccumulator()
        XCTAssertEqual(a.takeWholeLines(distance: 7, cellHeight: 10, route: .mouse), 0)
        XCTAssertEqual(a.takeWholeLines(distance: 7, cellHeight: 10, route: .mouse), 1)
        XCTAssertEqual(a.remainder, 4, accuracy: 0.001)
        XCTAssertEqual(a.takeWholeLines(distance: -30, cellHeight: 10, route: .mouse), -2)
        XCTAssertEqual(a.remainder, -6, accuracy: 0.001)
        // Travel banked for one route never turns into input on another.
        XCTAssertEqual(a.takeWholeLines(distance: -5, cellHeight: 10, route: .cursorKeys), 0)
        XCTAssertEqual(a.remainder, -5, accuracy: 0.001)
        a.reset()
        XCTAssertEqual(a.remainder, 0)
        XCTAssertEqual(a.takeWholeLines(distance: 25, cellHeight: 0, route: .mouse), 0)
    }

    func testBudgetBoundsBurstsAndRefills() {
        XCTAssertEqual(GhosttyWheelBudget.requested(lines: 0), 0)
        XCTAssertEqual(GhosttyWheelBudget.requested(lines: 3), 3)
        XCTAssertEqual(GhosttyWheelBudget.requested(lines: -40), 6)
        XCTAssertEqual(GhosttyWheelBudget.requested(lines: 40, precise: false), 1)
        var b = GhosttyWheelBudget(now: 0)
        XCTAssertEqual(b.grant(4, now: 0), 4)
        XCTAssertEqual(b.grant(4, now: 0), 2, "a burst is 6")
        XCTAssertEqual(b.grant(4, now: 0), 0)
        XCTAssertEqual(b.grant(4, now: 20_000_000), 2, "100 a second: 2 more after 20 ms")
        XCTAssertEqual(b.grant(9, now: 10_000_000_000), 6, "never more than a burst")
        XCTAssertEqual(b.grant(0, now: 10_000_000_000), 0)
    }
}
