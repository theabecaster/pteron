import RexKit
import Synchronization
import XCTest
@testable import RexDuo

/// Predicted echo against what real shells wrote: recorded sessions played through the real
/// `GhosttyCore`, its `GhosttyEchoGrid` and the predictor on the feed queue. Nothing here draws;
/// the overlay the core publishes is what a frame would latch.
final class EchoScriptTests: XCTestCase {
    /// What one play showed.
    private struct Run {
        var moments: [EchoPlayer.Moment] = []
        var counters = EchoPredictor.Counters()
        var modeRequests = 0
        var modeReplies: [EchoInputMode?] = []
        /// Overlay cells seen at any moment, by mark (nil before the first).
        func cells(after mark: String) -> Int {
            guard let from = moments.firstIndex(where: { $0.event == .mark(mark) }) else { return -1 }
            return moments[from...].reduce(0) { $0 + ($1.overlay?.cells.count ?? 0) }
        }
        func overlays(after mark: String) -> Int {
            guard let from = moments.firstIndex(where: { $0.event == .mark(mark) }) else { return -1 }
            return moments[from...].filter { $0.overlay != nil }.count
        }
        var everDrew: Bool { moments.contains { !($0.overlay?.cells.isEmpty ?? true) } }
    }

    /// Plays `name` and checks, at every moment, what must hold for every session:
    /// - a guessed glyph without a mask sits on a blank cell (no frame can show a guess over the
    ///   server's text);
    /// - no guess, mask or predicted cursor is outside the grid, and none in the last column.
    private func play(_ name: String, level: EchoLevel = .slow, split: Bool = false,
                      file: StaticString = #filePath, line: UInt = #line) throws -> Run {
        let fixture = try EchoFixture.load(name, file: file, line: line)
        let player = EchoPlayer(fixture, level: level)
        player.splitsOutput = split
        var run = Run()
        var cols = fixture.cols, rows = fixture.rows
        var trace: [String] = []
        player.play { m in
            run.moments.append(m)
            if case .resized = m.event, let size = fixture.steps.first(where: { $0.resize != nil })?.resize {
                cols = size[0]
                rows = size[1]
            }
            guard let overlay = m.overlay else { return }
            for cell in overlay.cells {
                XCTAssertTrue(cell.col >= 0 && cell.col < cols - 1 && cell.row >= 0 && cell.row < rows,
                              "\(name) at \(m.time): a guess at \(cell.col),\(cell.row) is outside a \(cols)x\(rows) grid or in its last column", file: file, line: line)
                if cell.hasGlyph, cell.mask == nil {
                    let have = player.shown(col: cell.col, row: cell.row)
                    XCTAssertEqual(have, 0, "\(name) at \(m.time): a guess is drawn over the server's text at column \(cell.col)", file: file, line: line)
                }
            }
            if let c = overlay.cursor {
                XCTAssertTrue(c.col >= 0 && c.col < cols && c.row >= 0 && c.row < rows, "\(name) at \(m.time): the predicted cursor is outside the grid", file: file, line: line)
            }
            if Self.traces {
                let text = String(String.UnicodeScalarView(overlay.cells.map { Unicode.Scalar($0.scalar > 0x20 ? $0.scalar : ($0.mask != nil ? 0x23 : 0x5f)) ?? "?" }))
                trace.append("\(String(format: "%.3f", m.time)) \(m.event) [\(text)] at \(overlay.cells.first?.col ?? -1)")
            }
        }
        run.counters = player.counters
        run.modeRequests = player.modeRequests
        run.modeReplies = player.modeReplies
        if Self.traces {
            print("ECHOTRACE \(name) split=\(split) counters=\(run.counters) requests=\(run.modeRequests) replies=\(run.modeReplies)")
            for t in trace { print("ECHOTRACE   \(t)") }
        }
        return run
    }

    /// `TEST_RUNNER_ECHO_TRACE=1` prints every moment that drew something.
    private static let traces = ProcessInfo.processInfo.environment["ECHO_TRACE"] != nil

    // MARK: Never at a no-echo prompt

    func testReadSilentNeverDraws() throws {
        for name in ["read-s", "read-s-133"] {
            let run = try play(name)
            XCTAssertEqual(run.overlays(after: "secret"), 0, "\(name): nothing is drawn while the shell reads with echo off")
            XCTAssertTrue(run.everDrew, "\(name): the command line before it was predicted, so the gate is alive")
            XCTAssertEqual(run.counters.mismatched, 0, name)
            XCTAssertEqual(run.counters.vanished, 0, name)
        }
    }

    /// A stand-in for sudo: a second of cooked tty with another program in front, then a prompt
    /// and a read with echo off, with the word typed ahead across that moment.
    func testAPasswordTypedAheadNeverDraws() throws {
        for name in ["password-typeahead", "password-typeahead-133"] {
            for split in [false, true] {
                let run = try play(name, split: split)
                XCTAssertEqual(run.overlays(after: "secret"), 0, "\(name) split=\(split): no letter of the word is ever drawn")
                XCTAssertTrue(run.everDrew, name)
                XCTAssertEqual(run.counters.vanished, 0, name)
            }
        }
        // Without OSC 133 the reading came back while echo was still on, with `sleep` in front:
        // an echoing tty proves nothing.
        let run = try play("password-typeahead")
        XCTAssertTrue(run.modeReplies.contains(EchoInputMode(echo: true, canonical: true)), "the fixture has the reading that must not count")
    }

    /// The worst case: the shell itself is in front with the tty cooked, a key typed ahead
    /// echoes and a reading says (echo, canonical), and then echo goes off with no output and no
    /// key of the user's to say so.
    func testEchoThatGoesOffSilentlyNeverDraws() throws {
        let run = try play("silent-read-s")
        XCTAssertTrue(run.modeReplies.contains(EchoInputMode(echo: true, canonical: true)), "the fixture has the reading that must not count")
        XCTAssertEqual(run.overlays(after: "secret"), 0, "no key typed after Enter is drawn: it may be the secret")
        XCTAssertEqual(run.counters.vanished, 0)
    }

    // MARK: Not in a full-screen program

    func testNothingIsPredictedInVim() throws {
        let run = try play("vim")
        let from = try XCTUnwrap(run.moments.firstIndex { $0.event == .mark("screen") })
        let to = try XCTUnwrap(run.moments.firstIndex { $0.event == .mark("back") })
        XCTAssertEqual(run.moments[from..<to].filter { $0.overlay != nil }.count, 0, "nothing is drawn while vim has the screen")
        XCTAssertGreaterThan(run.cells(after: "back"), 0, "and the prompt after it is predicted again")
        XCTAssertEqual(run.counters.mismatched, 0)
        XCTAssertEqual(run.counters.vanished, 0)
    }

    // MARK: At the prompt

    /// The floor: at a prompt, most printable keys that are not the first of their epoch are
    /// drawn as guesses, on each of the two ways the prompt state opens.
    func testTypingAtThePromptIsPredictedOnBothPaths() throws {
        for (name, requests) in [("zsh-typing", true), ("zsh-typing-133", false)] {
            let run = try play(name)
            XCTAssertEqual(run.counters.mismatched, 0, name)
            XCTAssertEqual(run.counters.vanished, 0, name)
            XCTAssertEqual(run.counters.capped, 0, name)
            // 19 printable keys follow the two that start their epochs ("cho hello world", "s -d /").
            XCTAssertGreaterThanOrEqual(run.counters.drawn, 17, "\(name): at least 90% of 19")
            XCTAssertEqual(run.modeRequests > 0, requests, "\(name): input_mode is read only without OSC 133")
        }
    }

    func testATypoFixedWithBackspaceIsNeverAMismatch() throws {
        for split in [false, true] {
            let run = try play("typo", split: split)
            XCTAssertEqual(run.counters.mismatched, 0, "split=\(split)")
            XCTAssertEqual(run.counters.vanished, 0, "split=\(split)")
            XCTAssertGreaterThan(run.counters.drawn, 10, "split=\(split)")
            XCTAssertTrue(run.moments.contains { $0.overlay?.cells.contains { $0.mask != nil } ?? false },
                          "a character under a pending Backspace is masked")
        }
    }

    /// Every echo arrives 900 ms after the link alone would bring it: a guess stays until its
    /// echo, and nothing is taken back.
    func testALateEchoKeepsItsGuess() throws {
        let fixture = try EchoFixture.load("late-echo")
        let player = EchoPlayer(fixture)
        // Each guessed character, from the moment it is drawn, is on screen at every moment
        // until the line ends: as a guess, or as the server's text.
        var drawn: [Int: UInt32] = [:]
        var row = 0
        player.play { m in
            for (col, scalar) in drawn {
                let guessed = m.overlay?.cells.contains { $0.col == col && $0.scalar == scalar } ?? false
                XCTAssertTrue(guessed || player.shown(col: col, row: row) == scalar,
                              "at \(m.time) column \(col) shows neither the guess nor the server's character")
            }
            for cell in m.overlay?.cells ?? [] where cell.hasGlyph {
                drawn[cell.col] = cell.scalar
                row = cell.row
            }
        }
        // "cho l" is guessed; the keys typed 300 ms after the first unconfirmed guess's answer
        // wait for it, so no new guess is stacked on an unproven one.
        XCTAssertGreaterThanOrEqual(drawn.count, 4)
        XCTAssertEqual(player.counters.mismatched, 0)
        XCTAssertEqual(player.counters.vanished, 0)
        XCTAssertEqual(player.counters.capped, 0)
    }

    /// A two-line prompt redrawn every second while the line is typed (`zle reset-prompt`): the
    /// cursor goes up a row and comes back, in one message or across two.
    func testAPromptRedrawIsNotAMismatch() throws {
        for split in [false, true] {
            let run = try play("prompt-redraw", split: split)
            XCTAssertEqual(run.counters.mismatched, 0, "split=\(split)")
            XCTAssertEqual(run.counters.vanished, 0, "split=\(split)")
            XCTAssertGreaterThan(run.counters.drawn, 10, "split=\(split)")
        }
    }

    func testARightPromptIsNeverDrawnOver() throws {
        let run = try play("right-prompt")
        XCTAssertEqual(run.counters.mismatched, 0)
        XCTAssertEqual(run.counters.vanished, 0)
        XCTAssertGreaterThan(run.counters.drawn, 10)
        // The right prompt starts at column 37 of 40: no guess within a cell of it while it shows.
        XCTAssertFalse(run.moments.contains { $0.overlay?.cells.contains { $0.col >= 36 } ?? false })
    }

    func testALineThatWrapsEndsItsGuessesBeforeTheLastColumn() throws {
        let run = try play("wrap")
        XCTAssertEqual(run.counters.mismatched, 0)
        XCTAssertEqual(run.counters.vanished, 0)
        XCTAssertGreaterThan(run.counters.drawn, 10)
        XCTAssertFalse(run.moments.contains { $0.overlay?.cells.contains { $0.col >= 29 || $0.row != 0 } ?? false },
                       "no guess in the last column of 30, and none on the wrapped row")
    }

    func testAResizeTakesEveryGuessAtOnce() throws {
        let run = try play("resize")
        let at = try XCTUnwrap(run.moments.firstIndex { $0.event == .resized })
        XCTAssertNotNil(run.moments[at - 1].overlay, "guesses were pending when the pane was resized")
        XCTAssertNil(run.moments[at].overlay, "and none is left with the new grid")
        XCTAssertEqual(run.counters.mismatched, 0)
        XCTAssertEqual(run.counters.vanished, 0)
        XCTAssertGreaterThan(run.moments[(at + 1)...].reduce(0) { $0 + ($1.overlay?.cells.count ?? 0) }, 0, "typing after it is predicted again")
    }

    // MARK: Predictions off

    /// With the pane's level off, the feed path does nothing for predicted echo: no predictor is
    /// made and nothing is ever published, whatever is typed and whatever arrives.
    func testWithPredictionsOffTheFeedPathDoesNothing() throws {
        for level in [EchoLevel?.none, .off] {
            let fixture = try EchoFixture.load("zsh-typing")
            let core = GhosttyCore(cols: fixture.cols, rows: fixture.rows)
            if let level { core.setEchoLevel(level, ack: (lastSeq: 0, answeredThrough: 0, settled: true)) }
            for step in fixture.steps {
                if let hex = step.out { core.feed(EchoFixture.bytes(hex: hex)) }
                // What a host would not send at all while the level is off; sent here, it still
                // does nothing.
                if let key = step.key, let seq = step.seq { core.echoTyped(.char(key), seq: seq, at: step.t) }
                if let seq = step.answered { core.echoAnswered(through: seq, at: step.t) }
            }
            core.resize(cols: 70, rows: 20, cellWidthPx: 8, cellHeightPx: 16)
            core.sync()
            XCTAssertEqual(core.echo.created.load(ordering: .relaxed), 0, "no predictor")
            XCTAssertEqual(core.echo.publishes.load(ordering: .relaxed), 0, "nothing published")
            XCTAssertNil(core.publishedEcho)
            XCTAssertNil(core.echoCounters)
            XCTAssertFalse(core.echoUnsettled)
        }
    }

    /// The level going back to off retires the predictor once nothing is pending.
    func testTheLevelGoingOffRetiresThePredictor() throws {
        let fixture = try EchoFixture.load("zsh-typing")
        let player = EchoPlayer(fixture)
        player.play { _ in }
        XCTAssertNotNil(player.core.echoCounters)
        player.core.setEchoLevel(.off, ack: (lastSeq: 0, answeredThrough: 0, settled: true))
        player.core.sync()
        XCTAssertNil(player.core.echoCounters, "the predictor is gone")
        XCTAssertNil(player.core.publishedEcho)
        XCTAssertEqual(player.core.echo.created.load(ordering: .relaxed), 1)
    }
}
