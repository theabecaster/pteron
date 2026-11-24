import RexKit
import XCTest
@testable import Pteron

/// A fitted pane that starts behind its fence: the grid it claims comes from the screen its
/// snapshot is on, known before a frame is drawn, and nothing is drawn for the sizes on the way.
@MainActor
final class CatchUpFitHostTests: XCTestCase {
    private let phone = "client:phone"
    private let mac = "client:mac"
    private var window: UIWindow!
    private var panes = PaneBaseline()

    override func setUp() async throws {
        panes = PaneBaseline()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        window.isHidden = false
    }

    override func tearDown() async throws {
        for v in window.subviews {
            (v as? TerminalHost)?.stop()
            v.removeFromSuperview()
        }
        window.isHidden = true
        window = nil
        let gone = await panes.cleared()
        XCTAssertTrue(gone, "LEAKCHECK \(name): \(panes.left) panes left")
    }

    private func eventually(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// The claim's settle time, ended by the test.
    @MainActor
    private final class Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var open = false
        /// How often a request began to settle.
        private(set) var asked = 0
        func wait() async {
            asked += 1
            if open { return }
            await withCheckedContinuation { waiting.append($0) }
        }
        func lift() {
            open = true
            let all = waiting
            waiting = []
            for w in all { w.resume() }
        }
    }

    private struct Pane {
        let host: TerminalHost
        let transport: FakeFitTransport
        let gate: Gate
    }

    /// The pane as it is with the software keyboard up: 250 points tall of the 500 it has with
    /// the keyboard down. Its stream has started and is behind its fence.
    private func pane(sizing: SizingMode = .fit, height: CGFloat = 250,
                      notYetPause: (@MainActor () async -> Void)? = nil) -> Pane {
        let transport = FakeFitTransport()
        let gate = Gate()
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = TerminalStream(control: control, sessionID: "s", blockID: "b1")
        let claim = notYetPause.map { FitClaim(transport: transport, settle: { await gate.wait() }, notYetPause: $0) }
            ?? FitClaim(transport: transport, settle: { await gate.wait() })
        let host = TerminalHost(stream: stream, sizing: sizing, fontSize: 12, theme: ThemeStore.fallback, claim: claim)
        host.hardwareKeyboard = { false }
        host.ownClientID = { [phone] in phone }
        host.clientGeneration = { 0 }
        host.frame = CGRect(x: 0, y: 0, width: 360, height: height)
        host.setRestSize(CGSize(width: 360, height: 500))
        window.addSubview(host)
        host.layoutIfNeeded()
        stream.start()
        XCTAssertTrue(host.isCatchingUp)
        XCTAssertTrue(host.term.core.isCatchUpHeld)
        return Pane(host: host, transport: transport, gate: gate)
    }

    private func grid(_ host: TerminalHost, height: CGFloat) -> (cols: Int, rows: Int) {
        TerminalLayout.fitGrid(in: CGSize(width: host.bounds.width, height: height), cell: host.term.cellSize)
    }

    /// A snapshot of a terminal 80 columns wide, on the alternate screen or not.
    private func snapshot(alternate: Bool, cols: Int = 80, rows: Int = 24) throws -> [UInt8] {
        let source = GhosttyCore(cols: cols, rows: rows)
        source.feed(Array(((alternate ? "\u{1b}[?1049h" : "") + "a program's screen\r\n").utf8))
        source.sync()
        return try XCTUnwrap(source.encodeSnapshot())
    }

    /// The stream's snapshot and the size that follows it.
    private func deliver(_ bytes: [UInt8], to host: TerminalHost, owner: String? = nil, cols: Int = 80, rows: Int = 24) {
        _ = host.streamGhosttySnapshot(.begin)
        bytes.withUnsafeBufferPointer { _ = host.streamGhosttySnapshot(.bytes($0)) }
        _ = host.streamGhosttySnapshot(.end(complete: true))
        host.streamResized(cols: cols, rows: rows, owner: owner)
    }

    private func resizes(_ p: Pane) -> [String] { p.transport.calls.filter { $0.hasPrefix("resize") } }

    func testASnapshotOnTheAlternateScreenClaimsTheVisibleGridAndSendsOneResize() async throws {
        let p = pane()
        let visible = grid(p.host, height: 250), rest = grid(p.host, height: 500)
        XCTAssertGreaterThan(rest.rows, visible.rows)
        XCTAssertFalse(p.host.alternateScreen)
        deliver(try snapshot(alternate: true), to: p.host)
        // No frame is drawn behind the fence: the screen is read from the parsed terminal.
        let known = await eventually { p.host.alternateScreen }
        XCTAssertTrue(known, "the host knows the screen before a frame")
        XCTAssertTrue(p.host.term.core.isCatchUpHeld, "and the hold is still on")
        p.host.layoutIfNeeded()
        p.gate.lift()
        let sent = await eventually { !self.resizes(p).isEmpty }
        XCTAssertTrue(sent)
        // The resize comes back in the stream and the pane is laid out for it, still behind the
        // fence: the last frame's state is of the terminal before the snapshot, and says nothing
        // about the screen now.
        p.host.streamResized(cols: visible.cols, rows: visible.rows, owner: phone)
        p.host.setNeedsLayout()
        p.host.layoutIfNeeded()
        await pause(0.3)
        XCTAssertTrue(p.host.alternateScreen, "no layout takes the screen back")
        XCTAssertEqual(resizes(p), ["resize \(visible.cols)x\(visible.rows)"], "the first claim is the visible grid, and the only one")
    }

    func testWithTheKeyboardDownASnapshotOnTheAlternateScreenDoesNotStartTheSettleOver() async throws {
        // Both screens fit the same grid here: the news of the screen asks for nothing again,
        // so the claim on its way lands when it would have.
        let p = pane(height: 500)
        let rest = grid(p.host, height: 500)
        let asked = await eventually { p.gate.asked == 1 }
        XCTAssertTrue(asked)
        deliver(try snapshot(alternate: true), to: p.host)
        let known = await eventually { p.host.alternateScreen }
        XCTAssertTrue(known)
        p.host.layoutIfNeeded()
        await pause(0.2)
        XCTAssertEqual(p.gate.asked, 1, "no second request, no new settle time")
        p.gate.lift()
        let sent = await eventually { !self.resizes(p).isEmpty }
        XCTAssertTrue(sent)
        await pause(0.3)
        XCTAssertEqual(resizes(p), ["resize \(rest.cols)x\(rest.rows)"])
    }

    func testASnapshotOnTheMainScreenStillClaimsTheRestHeightGrid() async throws {
        let p = pane()
        let rest = grid(p.host, height: 500)
        deliver(try snapshot(alternate: false), to: p.host)
        await pause(0.2)
        XCTAssertFalse(p.host.alternateScreen)
        p.host.layoutIfNeeded()
        p.gate.lift()
        let sent = await eventually { !self.resizes(p).isEmpty }
        XCTAssertTrue(sent)
        await pause(0.3)
        XCTAssertEqual(resizes(p), ["resize \(rest.cols)x\(rest.rows)"], "the keyboard covers the pane; it is not resized")
    }

    func testAProgramThatEntersTheAlternateScreenAfterTheSnapshotRefitsAtALaterLayout() async throws {
        let p = pane()
        let visible = grid(p.host, height: 250), rest = grid(p.host, height: 500)
        deliver(try snapshot(alternate: false), to: p.host)
        p.host.layoutIfNeeded()
        p.gate.lift()
        let first = await eventually { self.resizes(p) == ["resize \(rest.cols)x\(rest.rows)"] }
        XCTAssertTrue(first)
        p.host.streamResized(cols: rest.cols, rows: rest.rows, owner: phone)
        // The stream is current, and the program goes to the alternate screen: the frame that
        // shows it tells the host, as before.
        p.host.stream.stop()
        p.host.term.feed(text: "\u{1b}[?1049h")
        let known = await eventually { p.host.alternateScreen }
        XCTAssertTrue(known)
        let again = await eventually { self.resizes(p).last == "resize \(visible.cols)x\(visible.rows)" }
        XCTAssertTrue(again, "refitted to the visible grid: \(p.transport.calls)")
        XCTAssertEqual(resizes(p).count, 2)
    }

    func testAPaneAnotherClientHasIsNotClaimedOrResized() async throws {
        let p = pane()
        let rest = grid(p.host, height: 500)
        // Claimed, current, and then the Mac asks for the pane: the chip, and nothing is fought over.
        deliver(try snapshot(alternate: false), to: p.host)
        p.host.layoutIfNeeded()
        p.gate.lift()
        let claimed = await eventually { self.resizes(p).count == 1 }
        XCTAssertTrue(claimed)
        p.host.streamResized(cols: rest.cols, rows: rest.rows, owner: phone)
        p.host.stream.stop()
        let settled = await eventually { !p.host.stream.isClaimPending }
        XCTAssertTrue(settled)
        p.host.streamResized(cols: 211, rows: 57, owner: mac)
        XCTAssertFalse(p.host.fitted, "the Mac has the pane")
        // The phone leaves the line; that is all it says.
        await pause(0.4)
        let calls = p.transport.calls
        // A new start behind the fence, with a snapshot on the alternate screen.
        p.host.stream.start()
        deliver(try snapshot(alternate: true), to: p.host, owner: mac)
        let known = await eventually { p.host.alternateScreen }
        XCTAssertTrue(known)
        p.host.layoutIfNeeded()
        await pause(0.4)
        XCTAssertEqual(p.transport.calls, calls, "no claim and no resize")
        XCTAssertFalse(p.host.fitted)
    }

    func testAMirrorPaneClaimsNothingAndShowsItsSnapshotAtOnce() async throws {
        let p = pane(sizing: .mirror)
        deliver(try snapshot(alternate: true), to: p.host)
        XCTAssertFalse(p.host.term.core.isCatchUpHeld, "a mirror pane has no reflow to hide")
        let known = await eventually { p.host.alternateScreen }
        XCTAssertTrue(known)
        p.host.layoutIfNeeded()
        p.gate.lift()
        await pause(0.3)
        XCTAssertEqual(p.transport.calls, [], "mirror never claims")
        XCTAssertEqual(p.host.term.core.gridSize.cols, 80)
        XCTAssertEqual(p.host.term.core.gridSize.rows, 24)
    }

    func testAFencedFitPanesGridChangeAndLayoutDrawNothingUntilTheFenceFalls() async throws {
        // The claim never settles here, so the pane stays behind its fence with its hold on.
        let p = pane()
        let rest = grid(p.host, height: 500)
        let core = p.host.term.core
        deliver(try snapshot(alternate: false), to: p.host)
        p.host.layoutIfNeeded()
        await pause(0.1)
        XCTAssertTrue(p.host.stream.isClaimPending)
        XCTAssertTrue(core.isCatchUpHeld)
        // What is drawn so far: the grid the pane began with, and whatever that covers.
        let before = core.scroll.snapshot.covered
        // The stream catches up to a taller grid: the keyboard covers more of it, and the pane
        // is laid out for that.
        p.host.streamResized(cols: rest.cols, rows: rest.rows, owner: nil)
        p.host.setNeedsLayout()
        p.host.layoutIfNeeded()
        XCTAssertTrue(core.scroll.hasPending, "a cover to take")
        await pause(0.15)
        // Well inside the hold's limit: what follows says nothing once the hold has run out.
        XCTAssertTrue(core.isCatchUpHeld, "still behind the fence")
        XCTAssertEqual(core.scroll.snapshot.covered, before, "no frame was built on the way")
        XCTAssertTrue(core.scroll.hasPending)
        // The stream is current: one frame, with the cover.
        p.host.stream.stop()
        let drawn = await eventually { core.scroll.snapshot.covered > before && !core.scroll.hasPending }
        XCTAssertTrue(drawn, "the hold's last frame took the cover")
    }

    // MARK: The size report that ends the hold

    /// A pane behind its fence whose claim was answered: the snapshot said 80x24, the resize to
    /// the grid that fits went out and came back answered. Its echo is still to come.
    private func answeredPane() async throws -> (pane: Pane, fit: (cols: Int, rows: Int)) {
        let p = pane()
        let fit = grid(p.host, height: 500)
        deliver(try snapshot(alternate: false), to: p.host)
        p.host.layoutIfNeeded()
        p.gate.lift()
        let answered = await eventually { !self.resizes(p).isEmpty && !p.host.stream.isClaimPending }
        XCTAssertTrue(answered)
        XCTAssertEqual(resizes(p), ["resize \(fit.cols)x\(fit.rows)"])
        XCTAssertTrue(p.host.term.core.isCatchUpHeld)
        return (p, fit)
    }

    func testAResizeAnsweredBeforeItsEchoKeepsTheHoldUntilTheFenceFalls() async throws {
        let (p, fit) = try await answeredPane()
        let core = p.host.term.core
        let before = core.scroll.snapshot.covered
        // The echo, after the answer: the size that fits, from this client, nothing pending.
        p.host.streamResized(cols: fit.cols, rows: fit.rows, owner: phone)
        p.host.setNeedsLayout()
        p.host.layoutIfNeeded()
        XCTAssertTrue(core.scroll.hasPending, "a cover to take")
        await pause(0.15)
        XCTAssertTrue(core.isCatchUpHeld, "the redraw is still to come")
        XCTAssertEqual(core.scroll.snapshot.covered, before, "no frame was built on the way")
        p.host.stream.stop()
        let drawn = await eventually { core.scroll.snapshot.covered > before && !core.scroll.hasPending }
        XCTAssertTrue(drawn, "the fence's fall draws the final grid")
        XCTAssertFalse(core.isCatchUpHeld)
    }

    func testAnEchoBeforeItsAnswerKeepsTheHoldAsBefore() async throws {
        let p = pane()
        let fit = grid(p.host, height: 500)
        let core = p.host.term.core
        p.transport.held = ["resize"]
        deliver(try snapshot(alternate: false), to: p.host)
        p.host.layoutIfNeeded()
        p.gate.lift()
        let sent = await eventually { !self.resizes(p).isEmpty }
        XCTAssertTrue(sent)
        p.host.streamResized(cols: fit.cols, rows: fit.rows, owner: phone)
        XCTAssertTrue(core.isCatchUpHeld, "the claim is still on its way")
        p.transport.finish("resize")
        let answered = await eventually { !p.host.stream.isClaimPending }
        XCTAssertTrue(answered)
        XCTAssertTrue(core.isCatchUpHeld, "the answer ends no hold")
        p.host.stream.stop()
        XCTAssertFalse(core.isCatchUpHeld)
    }

    func testAHoldAfterOneThatSentAResizeEndsAtItsFirstReport() async throws {
        let (p, fit) = try await answeredPane()
        let core = p.host.term.core
        p.host.streamResized(cols: fit.cols, rows: fit.rows, owner: phone)
        XCTAssertTrue(core.isCatchUpHeld)
        p.host.streamFence(false, screen: true)
        XCTAssertFalse(core.isCatchUpHeld)
        // The pane comes back at the grid it has: nothing to reflow, nothing asked.
        p.host.streamFence(true, screen: true)
        XCTAssertTrue(core.isCatchUpHeld)
        p.host.streamResized(cols: fit.cols, rows: fit.rows, owner: phone)
        XCTAssertFalse(core.isCatchUpHeld, "the same grid: shown at once")
        XCTAssertEqual(resizes(p).count, 1, "and no resize went out for it")
    }

    func testARefusedResizeLeavesAHoldThatTheFenceEnds() async throws {
        let p = pane()
        let core = p.host.term.core
        p.transport.answers["resize"] = [.refused]
        deliver(try snapshot(alternate: false), to: p.host)
        p.host.layoutIfNeeded()
        p.gate.lift()
        let refused = await eventually { !self.resizes(p).isEmpty && !p.host.stream.isClaimPending }
        XCTAssertTrue(refused)
        XCTAssertFalse(p.host.fitted, "the pane is another client's")
        p.host.stream.stop()
        XCTAssertFalse(core.isCatchUpHeld, "the fence's fall ends the hold")
    }

    /// A pane behind its fence whose resize got an answer that has it asked again later: after
    /// the connection is back (`offline`) or after a pause (`notYet`). Neither comes here, so
    /// the claim stays on its way.
    private func paneWhoseResizeIsAskedAgain(after answer: FitClaimAnswer) async throws -> Pane {
        let again = Gate()
        let p = pane(notYetPause: { await again.wait() })
        p.transport.answers["resize"] = [answer]
        deliver(try snapshot(alternate: false), to: p.host)
        p.host.layoutIfNeeded()
        p.gate.lift()
        let waits = await eventually {
            !self.resizes(p).isEmpty && (answer == .offline ? p.transport.waitsForConnection : again.asked == 1)
        }
        XCTAssertTrue(waits)
        XCTAssertTrue(p.host.stream.isClaimPending, "the claim is still on its way")
        XCTAssertTrue(p.host.term.core.isCatchUpHeld)
        return p
    }

    /// The two ways such a hold ends: the fence falls, or it stays up and the engine's limit
    /// passes with the claim still waiting.
    private func assertTheFenceOrTheLimitEndsTheHold(after answer: FitClaimAnswer) async throws {
        let fallen = try await paneWhoseResizeIsAskedAgain(after: answer)
        fallen.host.stream.stop()
        XCTAssertFalse(fallen.host.term.core.isCatchUpHeld, "the fence's fall ends the hold")

        let kept = try await paneWhoseResizeIsAskedAgain(after: answer)
        await pause(GhosttyCore.renderHoldTimeout + 0.1)
        XCTAssertFalse(kept.host.term.core.isCatchUpHeld, "the limit ends the hold")
        XCTAssertTrue(kept.host.isCatchingUp, "while input still waits")
        XCTAssertTrue(kept.host.stream.isClaimPending, "and the claim is still on its way")
    }

    func testAResizeThatNeverReachedTheServerLeavesAHoldThatTheFenceOrTheLimitEnds() async throws {
        try await assertTheFenceOrTheLimitEndsTheHold(after: .offline)
    }

    func testAResizeAnsweredNotYetLeavesAHoldThatTheFenceOrTheLimitEnds() async throws {
        try await assertTheFenceOrTheLimitEndsTheHold(after: .notYet)
    }

    func testAHoldKeptForAnEchoEndsAtTheLimit() async throws {
        let (p, fit) = try await answeredPane()
        let core = p.host.term.core
        p.host.streamResized(cols: fit.cols, rows: fit.rows, owner: phone)
        XCTAssertTrue(core.isCatchUpHeld)
        // The fence never falls: the engine's limit ends the hold.
        await pause(GhosttyCore.renderHoldTimeout + 0.1)
        XCTAssertFalse(core.isCatchUpHeld)
        XCTAssertTrue(p.host.isCatchingUp, "while input still waits")
    }

    func testAColdMirrorPaneAtAnotherSizeThanTheHostsOwnShowsItsFirstPictureAtTheFirstReport() throws {
        let p = pane(sizing: .mirror)
        XCTAssertTrue(p.host.term.core.isCatchUpHeld)
        deliver(try snapshot(alternate: false, cols: 60, rows: 30), to: p.host, cols: 60, rows: 30)
        XCTAssertFalse(p.host.term.core.isCatchUpHeld, "no reflow to hide")
        XCTAssertTrue(p.host.isCatchingUp)
    }

    func testAColdFitPaneAlreadyAtTheSizeThatFitsShowsItsFirstPictureAtTheFirstReport() async throws {
        // The keyboard is down and the claim is answered before the snapshot arrives. The
        // server's size was not known, so the resize went out; the snapshot is of that size.
        let p = pane(height: 500)
        let fit = grid(p.host, height: 500)
        p.gate.lift()
        let answered = await eventually { !self.resizes(p).isEmpty && !p.host.stream.isClaimPending }
        XCTAssertTrue(answered)
        XCTAssertTrue(p.host.term.core.isCatchUpHeld)
        deliver(try snapshot(alternate: false, cols: fit.cols, rows: fit.rows), to: p.host, owner: phone, cols: fit.cols, rows: fit.rows)
        XCTAssertFalse(p.host.term.core.isCatchUpHeld, "the size it will keep: shown at once")
    }
}
