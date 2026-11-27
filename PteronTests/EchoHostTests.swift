import Metal
import Synchronization
import XCTest
@testable import Pteron
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
        /// Settles that passed and whose task has run on: it tells its observer in the same
        /// turn of the main queue.
        private(set) var passed = 0

        func sleep(_ d: Duration) async {
            guard d == .milliseconds(50) else {
                try? await Task.sleep(for: d)
                return
            }
            await withCheckedContinuation { waiting.append($0) }
            passed += 1
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
        let giveUp = ContinuousClock.now + .seconds(10)
        for _ in 0..<2500 where ContinuousClock.now < giveUp {
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
        panes.append(p)
        if settled, stream.writeObserver != nil { await settle(p) }
        return p
    }

    /// How long `settle` waits for the settle's task, each way. The task is ready within a few
    /// turns of the main queue; on a loaded machine those turns can be slow to come, so the
    /// wait is bounded by time, not by a count of turns.
    private static let settleLimit = Duration.seconds(5)

    /// Lets the settle of the last answer (or of the moment the host began to listen) pass: its
    /// task is waiting soon after, and tells the core in the turn that resumes it.
    private func settle(_ p: Pane, file: StaticString = #filePath, line: UInt = #line) async {
        let clock = ContinuousClock()
        var deadline = clock.now + Self.settleLimit
        while p.settles.count == 0, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertGreaterThan(p.settles.count, 0, "no settle was waiting within \(Self.settleLimit)", file: file, line: line)
        let want = p.settles.passed + p.settles.count
        p.settles.pass()
        deadline = clock.now + Self.settleLimit
        while p.settles.passed < want, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(p.settles.passed, want, "the settle's task did not run on within \(Self.settleLimit)", file: file, line: line)
        p.core.sync()
    }

    private var panesBefore = 0
    private var panes: [Pane] = []

    override func setUp() async throws {
        panesBefore = GhosttyRenderThread.shared.paneCount
    }

    /// Every pane a test made is gone when it ends: predicted echo holds on to no host, stream
    /// or core (the host's watch on the gate, the core's event handler and the stream's
    /// observers are all weak).
    override func tearDown() async throws {
        weak let host = panes.first?.host
        weak let stream = panes.first?.stream
        for p in panes {
            p.settles.pass()
            }
        panes = []
        // No more than at the start: a pane another test left there may go while this one runs.
        let end = Date().addingTimeInterval(30)
        while GhosttyRenderThread.shared.paneCount > panesBefore, Date() < end {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertLessThanOrEqual(GhosttyRenderThread.shared.paneCount, panesBefore,
                       "LEAKCHECK \(name): panes left; the first host is \(host == nil ? "gone" : "alive"), its stream \(stream == nil ? "gone" : "alive")")
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
    }

    /// Without OSC 133 the tty is read once a line's first key was echoed, but not when the
    /// program in front can prove nothing whatever the tty says: over `ssh` no call is made.
    func testTheTtyIsNotReadWhenTheProgramInFrontCanProveNothing() async {
        for (foreground, reads) in [("ssh", 0), ("zsh", 1)] {
            let p = await pane(level: .slow, foreground: foreground, prompt: "$ ")
            p.link.inputMode = (echo: false, canonical: false)
            await type(p, "l")
            await echo(p, "l", row: "$ l")
            await wait("the reading, if one is made") { p.link.inputModeReads == reads && self.modeSettled(p) }
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(p.link.inputModeReads, reads, foreground)
            // The answer of "l" has settled already (`type`).
            p.host.term.insertText("s")
            XCTAssertEqual(guesses(p), reads == 1 ? "s" : "", "\(foreground): drawn only with proof")
        }
    }

    /// The predictor's request for a reading has been answered (with a reading or with none).
    private func modeSettled(_ p: Pane) -> Bool {
        p.core.sync()
        return true
    }

    func testAnAgentPaneNeverPredicts() async {
        let p = await pane(level: .slow, agent: true, foreground: "claude")
        for c in "hello agent, this is fifty keys of typing in a box".prefix(50) { p.host.term.insertText(String(c)) }
        await wait("the writes") { !p.stream.hasPendingInput }
        p.core.sync()
        XCTAssertEqual(p.core.echoCounters?.placed, 0, "no key was even tracked")
        XCTAssertEqual(p.core.echo.publishes.load(ordering: .relaxed), 0)
        XCTAssertNil(p.core.publishedEcho)
    }

    func testOtherProgramsAndAnUnknownForegroundNeverPredict() async {
        for (foreground, context) in [("vim", true), ("python3", true), ("sleep", true), (nil, true), ("zsh", false)] as [(String?, Bool)] {
            let p = await pane(level: .slow, foreground: foreground, context: context)
            await type(p, "l")
            await echo(p, "l", row: "$ l")
            p.host.term.insertText("s")
            XCTAssertEqual(guesses(p), "", "\(foreground ?? "nil") context=\(context)")
            XCTAssertEqual(p.core.echoCounters?.placed, 0, "\(foreground ?? "nil") context=\(context)")
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
    }

    /// The focus report of a pane that comes to the front is input the user did not type
    /// (`TerminalHost.refreshProgramFocus`). To predicted echo it is a boundary like any
    /// report: the key after it is not a guess. Nothing else changes: what was typed is sent
    /// as typed, in order, and the screen and the stream are as they were.
    func testAFocusReportEndsTheGuessesAndChangesNothingElse() async {
        let p = await pane(level: .slow)
        p.host.hardwareKeyboard = { false }
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        window.isHidden = false
        window.addSubview(p.host)
        p.host.appActiveChanged(true)
        defer {
            // Let go at once: out of its window alone, the host would hold on to itself until
            // it has stayed away.
            p.host.removeFromSuperview()
            p.host.evict()
            window.isHidden = true
        }
        // The program asks for focus reports. Its pane is not the active one: it is told nothing.
        p.link.deliver(Array("\u{1b}[?1004h".utf8))
        await wait("the mode") { p.core.sync(); return p.core.input.modes.focusEvents }
        await type(p, "l")
        await echo(p, "l", row: "$ l")
        p.host.term.insertText("s")
        XCTAssertEqual(guesses(p), "s")
        let placed = p.core.echoCounters?.placed

        // The pane becomes the active one: the front pane.
        p.host.isActive = true
        await wait("the keys and then the report") { p.link.written.joined() == "ls\u{1b}[I" }
        p.host.term.insertText("x")
        XCTAssertFalse(guesses(p).contains("x"), "a key after the report is not drawn ahead of its echo")
        XCTAssertEqual(p.core.echoCounters?.placed, placed, "and not tracked")
        await wait("the write of x") { p.link.written.joined() == "ls\u{1b}[Ix" && !p.stream.hasPendingInput }
        XCTAssertEqual(p.link.written.joined(), "ls\u{1b}[Ix", "what was typed is what was sent, with the report between")
        XCTAssertEqual(rowText(p), "$ l", "the screen is the program's")
        XCTAssertFalse(p.stream.isFenced)
        XCTAssertTrue(p.stream.inputObserver === p.host, "the host still listens")
    }

    /// A prompt whose shell says a click moves the cursor with arrow keys.
    private static let clickPrompt = "\u{1b}]133;A;cl=line\u{07}$ \u{1b}]133;B\u{07}"

    /// A tap on the prompt while guesses are drawn is sent at once, counted from the cursor the
    /// user sees: its arrows leave behind the typed keys, and nothing waits for the echo.
    func testAPromptClickIsSentAtOnceCountedFromTheCursorOnScreen() async {
        let p = await pane(level: .slow, prompt: Self.clickPrompt)
        let view = p.host.term
        // "echo hello" typed and echoed, then "xy" typed and not echoed yet.
        await type(p, "e")
        await echo(p, "e", row: "$ e")
        for c in "cho hello" { p.host.term.insertText(String(c)) }
        await wait("the writes") { p.link.written.joined() == "echo hello" }
        await echo(p, "cho hello", row: "$ echo hello")
        for c in "xy" { p.host.term.insertText(String(c)) }
        XCTAssertEqual(guesses(p), "xy")
        XCTAssertTrue(p.core.echoUnsettled)
        // The frame on screen shows the guesses and their cursor on column 14.
        _ = view.renderer.frame.update(core: view.core)
        view.scroller.apply(view.core.scroll.snapshot)
        XCTAssertEqual(p.core.frameEcho?.cursor, .init(col: 14, row: 0))
        // A tap on column 4 (the "h" of echo), on text the program has: the engine counts 8 from its
        // cursor on column 12, and the two pending keys come on top.
        let rect = view.viewportRect(row: 0, columns: 4..<5)
        XCTAssertTrue(view.tapOpensLinkOrMovesCursor(at: CGPoint(x: rect.midX, y: rect.midY), focused: true, shift: false), "the tap is used")
        let arrows = String(repeating: "\u{1b}[D", count: 10)
        await wait("the keys and then the arrows") { p.link.written.joined() == "echo helloxy" + arrows }
        XCTAssertEqual(p.link.written.joined(), "echo helloxy" + arrows, "sent with no echo of xy yet, behind the typed keys")
        XCTAssertEqual(rowText(p), "$ echo hello", "the program has not echoed xy")
    }

    /// A tap on a guessed character: the engine sees a blank cell there, so the columns to the
    /// cursor on screen are counted.
    func testAPromptClickOnAGuessedCharacterCountsFromTheCursorOnScreen() async {
        let p = await pane(level: .slow, prompt: Self.clickPrompt)
        let view = p.host.term
        await type(p, "e")
        await echo(p, "e", row: "$ e")
        for c in "cho hello world" { p.host.term.insertText(String(c)) }
        XCTAssertEqual(guesses(p), "chohelloworld")
        _ = view.renderer.frame.update(core: view.core)
        view.scroller.apply(view.core.scroll.snapshot)
        XCTAssertEqual(p.core.frameEcho?.cursor, .init(col: 18, row: 0))
        // Column 8 is the guessed "e" of hello: ten columns left of the cursor on screen.
        let rect = view.viewportRect(row: 0, columns: 8..<9)
        XCTAssertTrue(view.tapOpensLinkOrMovesCursor(at: CGPoint(x: rect.midX, y: rect.midY), focused: true, shift: false))
        let arrows = String(repeating: "\u{1b}[D", count: 10)
        await wait("the keys and then the arrows") { p.link.written.joined() == "echo hello world" + arrows }
        XCTAssertEqual(p.link.written.joined(), "echo hello world" + arrows)
    }

    private func rowText(_ p: Pane) -> String {
        p.core.sync()
        return p.core.rowText(0)
    }

    // MARK: Release

    /// What predicted echo makes or touches for a pane, held weakly.
    private struct Held {
        weak var host: TerminalHost?
        weak var stream: TerminalStream?
        weak var core: GhosttyCore?
        weak var predictor: EchoPredictor?
        weak var renderer: GhosttyRenderer?
        weak var frame: GhosttyFrameBuilder?
        weak var watch: EchoGateWatch?
        var hadPredictor: Bool
        var hadEchoBuffers: Bool

        var alive: [String] {
            let all: [(String, AnyObject?)] = [("host", host), ("stream", stream), ("core", core), ("predictor", predictor),
                                               ("renderer", renderer), ("frame builder", frame), ("gate watch", watch)]
            return all.filter { $0.1 != nil }.map(\.0)
        }
    }

    private enum Leaving: CaseIterable {
        /// The pane is closed.
        case stopped
        /// The pane leaves the screen, parks, and the park lets it go.
        case parkedThenEvicted
        /// The pane parks and its computer is removed from the app.
        case computerRemoved
        /// The link changes under the gate, then the pane is closed.
        case gateResetThenStopped
        /// The pane parks, comes back on screen, and is closed.
        case parkedUnparkedThenStopped
    }

    /// Makes a pane, types at it (on a slow link until a guess is drawn and its buffers are
    /// filled), lets it leave by `how`, and returns what it held. Nothing of the pane is in
    /// scope when it returns.
    private func used(gate level: EchoLevel?, leaving how: Leaving, gate out: inout EchoGate?) async throws -> Held {
        let p = await pane(level: level)
        out = p.gate
        await type(p, "l")
        await echo(p, "l", row: "$ l")
        p.host.term.insertText("s")
        if level != nil {
            XCTAssertEqual(guesses(p), "s", "\(how)")
            // A frame with the guess: the row builder's echo lists and the renderer's buffers.
            let metal = try XCTUnwrap(GhosttyMetal.shared)
            let m = p.host.term.atlas.metrics
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 80 * m.cellWidth, height: 24 * m.cellHeight, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            let texture = try XCTUnwrap(metal.device.makeTexture(descriptor: d))
            XCTAssertTrue(p.host.term.renderer.renderOffscreen(into: texture, now: 100))
        } else {
            XCTAssertEqual(guesses(p), "")
        }
        p.core.sync()
        let predictor = p.core.echo.predictor
        let held = Held(host: p.host, stream: p.stream, core: p.core, predictor: predictor, renderer: p.host.term.renderer,
                        frame: p.host.term.renderer.frame, watch: p.host.echoWatch, hadPredictor: predictor != nil,
                        hadEchoBuffers: p.host.term.renderer.hasEchoBuffers)
        panes.removeAll { $0.host === p.host }
        p.settles.pass()
        let pool = TerminalHostPool()
        let server = UUID()
        switch how {
        case .stopped:
            p.host.stop()
        case .parkedThenEvicted:
            pool.add(p.host, for: TerminalHostPool.Key(server: server, session: "s", block: "b"))
            p.host.park()
            pool.evictParked()
        case .computerRemoved:
            pool.add(p.host, for: TerminalHostPool.Key(server: server, session: "s", block: "b"))
            p.host.park()
            pool.keep(selected: nil, servers: [], sessions: [:])
            XCTAssertNil(pool.host(for: TerminalHostPool.Key(server: server, session: "s", block: "b")), "the pool let the pane go")
        case .gateResetThenStopped:
            p.gate.reset()
            p.host.stop()
        case .parkedUnparkedThenStopped:
            let key = TerminalHostPool.Key(server: server, session: "s", block: "b")
            pool.add(p.host, for: key)
            p.host.park()
            XCTAssertTrue(p.host.isParked)
            pool.bringBack(key)
            XCTAssertFalse(p.host.isParked, "the pane is back")
            p.host.stop()
        }
        return held
    }

    private func assertReleased(_ held: Held, gate: EchoGate?, _ what: String, file: StaticString = #filePath, line: UInt = #line) async {
        var turns = 0
        let giveUp = ContinuousClock.now + .seconds(10)
        while !held.alive.isEmpty || (gate?.watcherCount ?? 0) > 0, turns < 1500, ContinuousClock.now < giveUp {
            turns += 1
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(held.alive, [], "\(what): still alive", file: file, line: line)
        XCTAssertEqual(gate?.watcherCount ?? 0, 0, "\(what): the gate still holds the pane's watch", file: file, line: line)
    }

    /// A pane that drew guesses leaves nothing behind, however it leaves: its host and stream,
    /// its core with the predictor, its renderer with the echo buffers, the row builder with
    /// the echo lists, and its watch on the gate all go, and the gate forgets the watch.
    func testAPaneThatPredictedIsReleasedHoweverItLeaves() async throws {
        for how in Leaving.allCases {
            var gate: EchoGate?
            let held = try await used(gate: .slow, leaving: how, gate: &gate)
            XCTAssertTrue(held.hadPredictor, "\(how): the pane had a predictor")
            XCTAssertTrue(held.hadEchoBuffers, "\(how): the pane had echo buffers")
            await assertReleased(held, gate: gate, "\(how)")
            // And the gate itself goes once nothing uses it.
            weak let gone = gate
            gate = nil
            XCTAssertNil(gone, "\(how): the gate")
        }
    }

    /// The same for a pane whose gate stayed off (a fast link): it never had a predictor or an
    /// echo buffer, and it is released the same way.
    func testAPaneOnAFastLinkIsReleasedHoweverItLeaves() async throws {
        for how in Leaving.allCases {
            var gate: EchoGate?
            let held = try await used(gate: nil, leaving: how, gate: &gate)
            XCTAssertFalse(held.hadPredictor, "\(how): no predictor on a fast link")
            XCTAssertFalse(held.hadEchoBuffers, "\(how): no echo buffers on a fast link")
            await assertReleased(held, gate: gate, "\(how)")
        }
    }

    // MARK: Across a park

    private func screen(_ p: Pane) -> [String] {
        p.core.sync()
        return (0..<6).map { p.core.rowText($0) }
    }

    /// Guesses do not outlive a park. What was drawn goes when the pane parks, nothing of it
    /// comes back with the pane, and once it is back the predictor draws nothing until the
    /// shell announces a new prompt: the marks from before the park say nothing about a pane
    /// that was not watched meanwhile.
    func testNothingDrawnBeforeAParkIsDrawnAfterItAndThePromptIsProvenAgain() async {
        let p = await pane(level: .slow)
        let pool = TerminalHostPool()
        let key = TerminalHostPool.Key(server: UUID(), session: "s", block: "b")
        pool.add(p.host, for: key)
        await type(p, "l")
        await echo(p, "l", row: "$ l")
        p.host.term.insertText("s")
        XCTAssertEqual(guesses(p), "s")
        XCTAssertTrue(p.core.echoUnsettled)

        p.host.park()
        XCTAssertNil(p.core.frameEcho, "parked: the frame it will show again carries no guess")
        XCTAssertEqual(guesses(p), "", "parked: the guess is gone")
        XCTAssertNil(p.core.publishedEcho)
        XCTAssertFalse(p.core.echoUnsettled)

        pool.bringBack(key)
        XCTAssertEqual(guesses(p), "", "back: nothing from before the park")
        await wait("the stream to be back with its fence down") { p.link.isOpen && !p.stream.isFenced }
        XCTAssertEqual(guesses(p), "")
        XCTAssertNotNil(p.core.echoCounters, "the gate is still on: the pane still has its predictor")

        // Typing where the pane came back: tracked by nobody, drawn by nobody, even after the
        // program echoes it.
        let before = screen(p)
        let placed = p.core.echoCounters?.placed
        let written = p.link.written.joined()
        p.host.term.insertText("x")
        XCTAssertEqual(guesses(p), "")
        await wait("the write of x") { p.link.written.joined() == written + "x" && !p.stream.hasPendingInput }
        p.link.deliver(Array("x".utf8))
        await wait("the echo of x") { self.screen(p) != before }
        await settle(p)
        p.host.term.insertText("y")
        XCTAssertEqual(guesses(p), "", "the marks from before the park do not open the input")
        XCTAssertEqual(p.core.echoCounters?.placed, placed, "no key was tracked")
        await wait("the write of y") { p.link.written.joined() == written + "xy" && !p.stream.hasPendingInput }
        p.link.deliver(Array("y".utf8))

        // The shell draws a new prompt and says so: guesses start again, tentatively.
        p.link.deliver(Array(("\r\n" + EchoPane.prompt).utf8))
        await wait("the new prompt") { self.screen(p).contains("$") }
        await settle(p)
        p.host.term.insertText("a")
        XCTAssertEqual(guesses(p), "", "a line's first key is only tracked")
        XCTAssertEqual(p.core.echoCounters?.placed, (placed ?? 0) + 1)
        await wait("the write of a") { p.link.written.joined() == written + "xya" && !p.stream.hasPendingInput }
        p.link.deliver(Array("a".utf8))
        await wait("the echo of a") { self.screen(p).contains("$ a") }
        p.host.term.insertText("b")
        XCTAssertEqual(guesses(p), "b")
        XCTAssertEqual(p.core.echoCounters?.mismatchedDrawn, 0)
    }

    // MARK: A plain key is sent before the keyboard is told (`GhosttyPlainInsertion`)

    /// Order: the guess is drawn and the key is on its way to the program when the keyboard is
    /// told that the text changed, and the guess comes before the send, as it always did.
    func testAGuessIsDrawnAndItsKeySentBeforeTheKeyboardIsTold() async {
        let p = await pane(level: .slow)
        await type(p, "l")
        await echo(p, "l", row: "$ l")
        let log = KeyOrderLog()
        p.host.term.inputDelegate = log
        var guessWhenTold: String?, onItsWayWhenTold: Bool?, writtenWhenTold: String?
        log.onTextDid = {
            guessWhenTold = self.guesses(p)
            onItsWayWhenTold = p.stream.hasPendingInput
            writtenWhenTold = p.link.written.joined()
        }
        p.host.term.insertText("s")
        XCTAssertEqual(log.events, [.selectionWill, .textWill, .textDid, .selectionDid])
        XCTAssertEqual(guessWhenTold, "s", "drawn before the keyboard heard of the key")
        XCTAssertEqual(onItsWayWhenTold, true, "its write was out")
        XCTAssertEqual(writtenWhenTold, "ls", "and with the socket (`StreamLink.start`)")
        XCTAssertEqual(p.core.publishedEcho?.cells.first?.col, 3)
        await wait("the write") { p.link.written.joined() == "ls" && !p.stream.hasPendingInput }
        await echo(p, "s", row: "$ ls")
        XCTAssertEqual(guesses(p), "", "the server shows it")
        XCTAssertEqual(p.core.echoCounters?.mismatched, 0)
    }

    /// Order: behind the catch-up fence a plain key reaches the fence before the keyboard is
    /// told, and the fence holds it: nothing is sent until the stream is current, then the key
    /// goes out once.
    func testAPlainKeyBehindTheFenceIsHeldBeforeTheKeyboardIsTold() async {
        let p = await pane(level: nil)
        let log = KeyOrderLog()
        p.host.term.inputDelegate = log
        // The app came back: nobody knows yet what the program wrote meanwhile.
        p.stream.returned()
        XCTAssertTrue(p.stream.isFenced)
        var heldWhenTold: Int?, pendingWhenTold: Bool?
        log.onTextDid = {
            heldWhenTold = p.stream.fence.heldCount
            pendingWhenTold = p.stream.hasPendingInput
        }
        p.host.term.insertText("x")
        XCTAssertEqual(log.events, [.selectionWill, .textWill, .textDid, .selectionDid])
        XCTAssertEqual(heldWhenTold, 1, "the fence had the key")
        XCTAssertEqual(pendingWhenTold, false, "and kept it out of the queue")
        XCTAssertEqual(p.link.written, [], "nothing leaves behind the fence")
        await wait("the fence to come down and the key to go out") { !p.stream.isFenced && p.link.written.joined() == "x" }
        await wait("the answer") { !p.stream.hasPendingInput }
        XCTAssertEqual(p.link.written.joined(), "x", "sent once")
    }
}
