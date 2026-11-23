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
    private func pane(sizing: SizingMode = .fit, height: CGFloat = 250) -> Pane {
        let transport = FakeFitTransport()
        let gate = Gate()
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = TerminalStream(control: control, sessionID: "s", blockID: "b1")
        let host = TerminalHost(stream: stream, sizing: sizing, fontSize: 12, theme: ThemeStore.fallback,
                                claim: FitClaim(transport: transport, settle: { await gate.wait() }))
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

    /// A snapshot of a terminal 80 by 24, on the alternate screen or not.
    private func snapshot(alternate: Bool) throws -> [UInt8] {
        let source = GhosttyCore(cols: 80, rows: 24)
        source.feed(Array(((alternate ? "\u{1b}[?1049h" : "") + "a program's screen\r\n").utf8))
        source.sync()
        return try XCTUnwrap(source.encodeSnapshot())
    }

    /// The stream's snapshot and the size that follows it.
    private func deliver(_ bytes: [UInt8], to host: TerminalHost, owner: String? = nil) {
        _ = host.streamGhosttySnapshot(.begin)
        bytes.withUnsafeBufferPointer { _ = host.streamGhosttySnapshot(.bytes($0)) }
        _ = host.streamGhosttySnapshot(.end(complete: true))
        host.streamResized(cols: 80, rows: 24, owner: owner)
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
        XCTAssertEqual(p.gate.asked, 1)
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
        let p = pane()
        let rest = grid(p.host, height: 500)
        let core = p.host.term.core
        // The resize's answer is slow: its echo in the stream comes first.
        p.transport.held = ["resize"]
        deliver(try snapshot(alternate: false), to: p.host)
        p.host.layoutIfNeeded()
        p.gate.lift()
        let asked = await eventually { self.resizes(p).count == 1 }
        XCTAssertTrue(asked)
        XCTAssertTrue(p.host.stream.isClaimPending)
        await pause(0.2)
        XCTAssertEqual(core.scroll.snapshot.covered, 0)
        // The grid is now taller than the pane, the keyboard covers its last rows, and the pane
        // is laid out for that.
        p.host.streamResized(cols: rest.cols, rows: rest.rows, owner: phone)
        p.host.setNeedsLayout()
        p.host.layoutIfNeeded()
        XCTAssertTrue(core.isCatchUpHeld, "still behind the fence")
        XCTAssertTrue(core.scroll.hasPending, "a cover to take")
        await pause(0.3)
        XCTAssertEqual(core.scroll.snapshot.covered, 0, "no frame was built on the way")
        XCTAssertTrue(core.scroll.hasPending)
        // The claim is answered and the stream is current: one frame, with the cover.
        p.transport.finish("resize")
        p.host.stream.stop()
        let drawn = await eventually { core.scroll.snapshot.covered > 0 && !core.scroll.hasPending }
        XCTAssertTrue(drawn, "the hold's last frame took the cover")
    }
}
