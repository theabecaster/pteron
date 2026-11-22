import Synchronization
import XCTest
@testable import RexDuo
@_spi(Bench) @testable import RexKit

/// Predicted echo through a whole pane on a slow link: the host follows its server's gate,
/// listens to its stream only while predictions are on, and lets a key be a guess only at a
/// shell's prompt.
@MainActor
final class EchoHostTests: XCTestCase {
    /// Holds the stream's 50 ms settle (the only wait of that length in the stream) until the
    /// test lets it pass, so the acknowledgement rule's window is the test's to open: no test
    /// here waits for real time to make a guess possible. Every other wait passes as it is.
    @MainActor private final class Settles {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        var count: Int { waiting.count }

        func sleep(_ d: Duration) async {
            guard d == .milliseconds(50) else {
                try? await Task.sleep(for: d)
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }

        func pass() {
            let all = waiting
            waiting = []
            for w in all { w.resume() }
        }
    }

    @MainActor private struct Pane {
        let settles: Settles
        let host: TerminalHost
        let stream: TerminalStream
        let link: ScriptedEchoLink
        let gate: EchoGate
        var core: GhosttyCore { host.term.core }
    }

    private func wait(_ what: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    /// A live pane at a prompt marked with OSC 133, on a link whose gate says `level`. With
    /// `settled`, the 50 ms since the host began to listen have passed.
    private func pane(level: EchoLevel?, agent: Bool = false, foreground: String? = "zsh", context: Bool = true,
                      prompt: String = EchoPane.prompt, settled: Bool = true) async -> Pane {
        let link = ScriptedEchoLink(writeDelay: .zero) { _ in await Task.yield() }
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let gate = EchoGate(forced: level)
        let stream = link.stream(control: control, sessionID: "s", blockID: "b", echoGate: gate)
        let settles = Settles()
        stream.sleep = settles.sleep
        let host = TerminalHost(stream: stream, sizing: .mirror, fontSize: 12, theme: ThemeStore.fallback)
        if context { host.echoContext = { (agent: agent, foreground: foreground) } }
        stream.start()
        await wait("the stream to be live with its fence down") { link.isOpen && !stream.isFenced }
        link.deliver(Array(prompt.utf8))
        await wait("the prompt") { host.term.core.sync(); return host.term.core.rowText(0) == "$" }
        let p = Pane(settles: settles, host: host, stream: stream, link: link, gate: gate)
        if settled, stream.writeObserver != nil { await settle(p) }
        return p
    }

    /// Lets the settle of the last answer (or of the moment the host began to listen) pass: its
    /// task is waiting within a few turns of the main queue, and tells the core in the turn
    /// that resumes it.
    private func settle(_ p: Pane, file: StaticString = #filePath, line: UInt = #line) async {
        var turns = 0
        while p.settles.count == 0, turns < 20 {
            turns += 1
            await Task.yield()
        }
        XCTAssertGreaterThan(p.settles.count, 0, "no settle was waiting", file: file, line: line)
        p.settles.pass()
        await Task.yield()
        p.core.sync()
    }

    /// Types one key and waits until its write was answered. `settled` lets the answer's 50 ms
    /// pass as well.
    private func type(_ p: Pane, _ text: String, settled: Bool = true) async {
        let before = p.link.written.joined().count
        p.host.term.insertText(text)
        await wait("the write of \(text)") { p.link.written.joined().count == before + text.count && !p.stream.hasPendingInput }
        if settled, p.stream.writeObserver != nil { await settle(p) }
        p.core.sync()
    }

    private func echo(_ p: Pane, _ text: String, row: String) async {
        p.link.deliver(Array(text.utf8))
        await wait("the echo \(text)") { p.core.sync(); return p.core.rowText(0) == row }
    }

    private func guesses(_ p: Pane) -> String {
        p.core.sync()
        return String(String.UnicodeScalarView((p.core.publishedEcho?.cells ?? []).filter(\.hasGlyph).compactMap { Unicode.Scalar($0.scalar) }))
    }

    func testOnASlowLinkAKeyAtAShellPromptIsDrawnAtOnce() async {
        let p = await pane(level: .slow)
        XCTAssertTrue(p.stream.inputObserver === p.host, "the host listens while predictions are on")
        XCTAssertEqual(p.core.echo.created.load(ordering: .relaxed), 1)
        // The first key of an epoch is tracked, not drawn, until the shell echoes it
        // (`EchoPredictor.Epoch.tentative`).
        p.host.term.insertText("l")
        XCTAssertEqual(guesses(p), "")
        XCTAssertEqual(p.core.echoCounters?.placed, 1, "tracked in the turn it was typed")
        await wait("the write") { p.link.written.joined() == "l" && !p.stream.hasPendingInput }
        await echo(p, "l", row: "$ l")
        // From here a key shows the moment it is typed, underlined: the link is slow. Nothing
        // is waited for between the key and the guess: the host hands the key to the feed
        // queue in the turn it is typed, and no answer, timer or turn of the main queue is
        // needed before the core publishes it.
        p.host.term.insertText("s")
        XCTAssertEqual(guesses(p), "s")
        XCTAssertEqual(p.core.publishedEcho?.cells.first?.underlined, true)
        XCTAssertEqual(p.core.publishedEcho?.cells.first?.col, 3)
        XCTAssertTrue(p.core.echoUnsettled)
        await wait("the write") { p.link.written.joined() == "ls" }
        await echo(p, "s", row: "$ ls")
        XCTAssertEqual(guesses(p), "", "the server shows it")
        XCTAssertEqual(p.link.written.joined(), "ls", "what was typed is what was sent")
        XCTAssertEqual(p.core.echoCounters?.mismatched, 0)
        p.host.stop()
    }

    /// The acknowledgement rule (`EchoPredictor.acknowledged(before:)`): a line's first key is
    /// tracked only once all earlier input is answered and 50 ms have passed. A key typed
    /// inside that window is not a guess; it shows when its echo arrives, as without predicted
    /// echo. Once the window has passed the next key starts the line's guesses.
    func testAKeyInsideTheSettleWindowIsNotAGuess() async {
        let p = await pane(level: .slow, settled: false)
        p.host.term.insertText("l")
        XCTAssertEqual(guesses(p), "")
        XCTAssertEqual(p.core.echoCounters?.placed, 0, "the host began to listen less than 50 ms ago")
        await wait("the write") { p.link.written.joined() == "l" && !p.stream.hasPendingInput }
        await echo(p, "l", row: "$ l")
        // Its answer has not settled either.
        p.host.term.insertText("s")
        XCTAssertEqual(guesses(p), "")
        XCTAssertEqual(p.core.echoCounters?.placed, 0)
        await wait("the write") { p.link.written.joined() == "ls" && !p.stream.hasPendingInput }
        await echo(p, "s", row: "$ ls")
        // 50 ms after the last answer: the next key is tracked, and the one after it drawn.
        await settle(p)
        p.host.term.insertText("x")
        XCTAssertEqual(guesses(p), "")
        XCTAssertEqual(p.core.echoCounters?.placed, 1)
        await wait("the write") { p.link.written.joined() == "lsx" && !p.stream.hasPendingInput }
        await echo(p, "x", row: "$ lsx")
        p.host.term.insertText("y")
        XCTAssertEqual(guesses(p), "y")
        XCTAssertEqual(p.core.echoCounters?.mismatched, 0)
        p.host.stop()
    }

    func testAnAgentPaneNeverPredicts() async {
        let p = await pane(level: .slow, agent: true, foreground: "claude")
        for c in "hello agent, this is fifty keys of typing in a box".prefix(50) { p.host.term.insertText(String(c)) }
        await wait("the writes") { !p.stream.hasPendingInput }
        p.core.sync()
        XCTAssertEqual(p.core.echoCounters?.placed, 0, "no key was even tracked")
        XCTAssertEqual(p.core.echo.publishes.load(ordering: .relaxed), 0)
        XCTAssertNil(p.core.publishedEcho)
        p.host.stop()
    }

    func testOtherProgramsAndAnUnknownForegroundNeverPredict() async {
        for (foreground, context) in [("vim", true), ("python3", true), ("sleep", true), (nil, true), ("zsh", false)] as [(String?, Bool)] {
            let p = await pane(level: .slow, foreground: foreground, context: context)
            await type(p, "l")
            await echo(p, "l", row: "$ l")
            p.host.term.insertText("s")
            XCTAssertEqual(guesses(p), "", "\(foreground ?? "nil") context=\(context)")
            XCTAssertEqual(p.core.echoCounters?.placed, 0, "\(foreground ?? "nil") context=\(context)")
            p.host.stop()
        }
    }

    func testASelectionOrFindOrAScrolledViewMakesKeysBoundaries() async {
        let p = await pane(level: .slow)
        await type(p, "l")
        await echo(p, "l", row: "$ l")
        // A selection is up.
        p.host.term.beginSelection(at: p.host.term.viewportRect(row: 0, columns: 0..<1).origin, word: true)
        XCTAssertTrue(p.host.term.hasActiveSelection)
        let placed = p.core.echoCounters?.placed
        p.host.sendKey([0x73])
        XCTAssertEqual(guesses(p), "")
        XCTAssertEqual(p.core.echoCounters?.placed, placed, "a key typed under a selection is not tracked")
        p.host.stop()
    }

    func testSeveralBytesInOneCallAreNeverAGuess() async {
        let p = await pane(level: .slow)
        await type(p, "l")
        await echo(p, "l", row: "$ l")
        let placed = p.core.echoCounters?.placed
        // A paste, a swipe-typed word, an armed Control: none is a single printable byte.
        p.host.sendKey(Array("ab".utf8))
        p.host.sendKey([0x03])
        p.host.sendKey(Array("\u{1b}[A".utf8))
        XCTAssertEqual(guesses(p), "")
        XCTAssertEqual(p.core.echoCounters?.placed, placed)
        p.host.stop()
    }

    func testTheHostStopsListeningWhenTheGateTurnsPredictionsOff() async {
        let p = await pane(level: .slow)
        await type(p, "l")
        await echo(p, "l", row: "$ l")
        XCTAssertNotNil(p.stream.inputObserver)
        p.gate.forced = .off
        await wait("the predictor to retire") { p.stream.inputObserver == nil && p.stream.writeObserver == nil }
        p.core.sync()
        XCTAssertNil(p.core.echoCounters, "the predictor is gone")
        let seq = p.stream.inputSeq
        p.host.term.insertText("s")
        XCTAssertEqual(p.stream.inputSeq, seq, "input is not numbered any more")
        XCTAssertNil(p.core.publishedEcho)
        // And on again.
        p.gate.forced = .on
        XCTAssertNotNil(p.stream.inputObserver)
        p.core.sync()
        XCTAssertEqual(p.core.echo.created.load(ordering: .relaxed), 2)
        p.host.stop()
    }

    func testAGateResetClearsEveryGuess() async {
        let p = await pane(level: .slow)
        await type(p, "l")
        await echo(p, "l", row: "$ l")
        p.host.term.insertText("s")
        XCTAssertEqual(guesses(p), "s")
        // A reconnect or a change of route: what was guessed over the old link goes.
        p.gate.reset()
        XCTAssertEqual(guesses(p), "")
        XCTAssertFalse(p.core.echoUnsettled)
        p.host.stop()
    }

    /// A prompt whose shell says a click moves the cursor with arrow keys.
    private static let clickPrompt = "\u{1b}]133;A;cl=line\u{07}$ \u{1b}]133;B\u{07}"

    /// A tap on the prompt while a drawn guess is unconfirmed waits: its arrows are counted
    /// from the real cursor, which lags the one on screen.
    func testAPromptClickWaitsForGuessesToSettle() async {
        let p = await pane(level: .slow, prompt: Self.clickPrompt)
        let view = p.host.term
        var now: CFTimeInterval = 100
        view.taps.clock = { now }
        // "echo hello" typed and echoed, then "xy" typed and not echoed yet.
        await type(p, "e")
        await echo(p, "e", row: "$ e")
        for c in "cho hello" { p.host.term.insertText(String(c)) }
        await wait("the writes") { p.link.written.joined() == "echo hello" }
        await echo(p, "cho hello", row: "$ echo hello")
        for c in "xy" { p.host.term.insertText(String(c)) }
        await wait("the writes") { p.link.written.joined() == "echo helloxy" }
        XCTAssertEqual(guesses(p), "xy")
        XCTAssertTrue(p.core.echoUnsettled)
        let sent = p.link.written.count
        // A tap on column 4 (the "c"): held, nothing is sent.
        _ = view.renderer.frame.update(core: view.core)
        view.scroller.apply(view.core.scroll.snapshot)
        let rect = view.viewportRect(row: 0, columns: 4..<5)
        XCTAssertTrue(view.tapOpensLinkOrMovesCursor(at: CGPoint(x: rect.midX, y: rect.midY), focused: true, shift: false), "the tap is used")
        XCTAssertNotNil(view.taps.heldPrompt)
        await Task.yield()
        XCTAssertEqual(p.link.written.count, sent, "no arrow was sent from the lagging cursor")
        // The echo of "xy": the guesses settle and the tap is decided against the grid now.
        now += 0.3
        await echo(p, "xy", row: "$ echo helloxy")
        await wait("the held tap to go") { p.link.written.count == sent + 1 }
        XCTAssertNil(view.taps.heldPrompt)
        // The cursor is on column 14: ten steps left to column 4.
        XCTAssertEqual(p.link.written.last, String(repeating: "\u{1b}[D", count: 10))
        p.host.stop()
    }

    func testAHeldPromptClickIsDroppedByAKeyAndByTime() async {
        let p = await pane(level: .slow, prompt: Self.clickPrompt)
        let view = p.host.term
        var now: CFTimeInterval = 100
        view.taps.clock = { now }
        await type(p, "e")
        await echo(p, "e", row: "$ e")
        for c in "cho hello" { p.host.term.insertText(String(c)) }
        await wait("the writes") { p.link.written.joined() == "echo hello" }
        await echo(p, "cho hello", row: "$ echo hello")
        p.host.term.insertText("x")
        await wait("the write") { p.link.written.joined() == "echo hellox" }
        _ = view.renderer.frame.update(core: view.core)
        view.scroller.apply(view.core.scroll.snapshot)
        let rect = view.viewportRect(row: 0, columns: 4..<5)
        let point = CGPoint(x: rect.midX, y: rect.midY)
        // A key typed while the tap waits: the tap is of another moment.
        XCTAssertTrue(view.tapOpensLinkOrMovesCursor(at: point, focused: true, shift: false))
        XCTAssertNotNil(view.taps.heldPrompt)
        p.host.term.insertText("y")
        XCTAssertNil(view.taps.heldPrompt)
        await wait("the write") { p.link.written.joined() == "echo helloxy" }
        // A tap that waited more than two seconds is not sent when the guesses settle.
        now += 3
        XCTAssertTrue(view.tapOpensLinkOrMovesCursor(at: point, focused: true, shift: false))
        XCTAssertNotNil(view.taps.heldPrompt)
        now += GhosttyTapState.heldPromptLife + 0.1
        let sent = p.link.written.count
        await echo(p, "xy", row: "$ echo helloxy")
        // The core's `settled` event reaches the host one turn of the main queue later.
        for _ in 0..<5 { await Task.yield() }
        XCTAssertNil(view.taps.heldPrompt)
        XCTAssertEqual(p.link.written.count, sent, "nothing was sent")
        p.host.stop()
    }
}
