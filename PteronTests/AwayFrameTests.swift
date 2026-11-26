import RexKit
import XCTest
@testable import Pteron

/// Back from the background, a pane shows the screen the user left, at its own size, until
/// its return has caught up: never the last frame stretched over the Mac's grid.
@MainActor
final class AwayFrameTests: XCTestCase {
    private let phone = "client:phone"
    private let mac = "client:mac"
    private var window: UIWindow!

    override func setUp() async throws {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
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
    }

    private func pause(_ seconds: TimeInterval) {
        let done = expectation(description: "pause")
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { done.fulfill() }
        wait(for: [done], timeout: seconds + 5)
    }

    private func eventually(_ seconds: TimeInterval = 3, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { pause(0.01) }
        return condition()
    }

    // MARK: The rule

    func testOnlyAPaneThatShowsAScreenInAWindowKeepsIt() {
        var a = AwayFrame()
        XCTAssertFalse(a.left(showing: (40, 50), hasScreen: false, inWindow: true), "nothing drawn yet")
        XCTAssertFalse(a.left(showing: (40, 50), hasScreen: true, inWindow: false), "off screen")
        XCTAssertFalse(a.left(showing: (0, 0), hasScreen: true, inWindow: true), "no grid yet")
        XCTAssertFalse(a.isOn)
        XCTAssertTrue(a.left(showing: (40, 50), hasScreen: true, inWindow: true))
        XCTAssertTrue(a.isOn)
    }

    func testTheViewKeepsTheGridOfTheFrameOnShow() {
        var a = AwayFrame()
        XCTAssertTrue(a.layoutGrid(engine: (211, 57)) == (211, 57), "nothing kept: the engine's grid")
        _ = a.left(showing: (40, 50), hasScreen: true, inWindow: true)
        XCTAssertTrue(a.layoutGrid(engine: (211, 57)) == (40, 50), "the Mac's grid came: the frame keeps its own")
    }

    func testASecondDepartureKeepsTheFrameTheUserSawFirst() {
        var a = AwayFrame()
        _ = a.left(showing: (40, 50), hasScreen: true, inWindow: true)
        XCTAssertFalse(a.returned(catchingUp: true))
        XCTAssertFalse(a.left(showing: (211, 57), hasScreen: true, inWindow: true), "already kept")
        XCTAssertTrue(a.layoutGrid(engine: (211, 57)) == (40, 50))
    }

    func testItStaysUntilTheReturnHasCaughtUp() {
        var a = AwayFrame()
        _ = a.left(showing: (40, 50), hasScreen: true, inWindow: true)
        XCTAssertFalse(a.caughtUp(inBackground: true), "a fence that falls in the background changes nothing")
        XCTAssertFalse(a.returned(catchingUp: true), "back, and the stream is catching up")
        XCTAssertTrue(a.isOn)
        XCTAssertTrue(a.caughtUp(inBackground: false))
        XCTAssertFalse(a.isOn)
        XCTAssertFalse(a.caughtUp(inBackground: false), "once")
    }

    func testAReturnWithNothingToCatchUpEndsItAtOnce() {
        var a = AwayFrame()
        _ = a.left(showing: (40, 50), hasScreen: true, inWindow: true)
        XCTAssertTrue(a.returned(catchingUp: false))
        XCTAssertFalse(a.isOn)
    }

    func testLeavingTheScreenEndsIt() {
        var a = AwayFrame()
        XCTAssertFalse(a.end())
        _ = a.left(showing: (40, 50), hasScreen: true, inWindow: true)
        XCTAssertTrue(a.end())
        XCTAssertFalse(a.isOn)
    }

    // MARK: The engine

    private func build(_ text: String, cols: Int = 20, rows: Int = 4) -> (GhosttyCore, GhosttyFrameBuilder) {
        let core = GhosttyCore(cols: cols, rows: rows)
        core.feed(Array(text.utf8))
        core.sync()
        let frame = GhosttyFrameBuilder(atlas: GhosttyGlyphAtlas(pointSize: 12, scale: 2))
        XCTAssertTrue(frame.update(core: core))
        return (core, frame)
    }

    func testTheAwayHoldHasNoTimeLimit() {
        let (core, frame) = build("old")
        core.setCatchUpHold(true, limited: false)
        core.feed(Array("\r\u{1b}[Knewer".utf8))
        core.resize(cols: 60, rows: 20, cellWidthPx: 14, cellHeightPx: 28)
        core.sync()
        // Seconds or minutes away: the frame on show is still the one the user left.
        _ = frame.update(core: core, now: CACurrentMediaTime() + 600)
        XCTAssertEqual(frame.rows[0].glyphs.count, 3)
        XCTAssertEqual(frame.cols, 20, "at its own grid")
        XCTAssertTrue(core.isCatchUpHeld)
        core.setCatchUpHold(false)
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rows[0].glyphs.count, 5, "then everything in one frame")
        XCTAssertEqual(frame.cols, 60)
    }

    func testASnapshotRestoredUnderTheHoldKeepsTheHeldRows() throws {
        // A long time away: the stream starts fresh, and its snapshot replaces the terminal
        // while the frame is held. The held rows stay as built; no empty frame in between.
        let (core, frame) = build("left here")
        core.setCatchUpHold(true, limited: false)
        let source = GhosttyCore(cols: 30, rows: 6)
        source.feed(Array("the new screen".utf8))
        source.sync()
        let snapshot = try XCTUnwrap(source.encodeSnapshot())
        core.restore(snapshot: snapshot) { _ in }
        core.sync()
        XCTAssertFalse(frame.update(core: core), "nothing new to draw")
        XCTAssertEqual(frame.rows[0].glyphs.count, 8, "the screen the user left (spaces draw no glyph)")
        XCTAssertEqual(frame.cols, 20)
        core.setCatchUpHold(false)
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rows[0].glyphs.count, 12)
        XCTAssertEqual(frame.cols, 30)
    }

    func testAFrameIsNeverScaledToTheLayer() {
        // Between a new size and the first frame drawn for it, the layer shows the last frame at
        // its own scale, never stretched to the new bounds.
        let view = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 200, height: 100), fontSize: 12)
        XCTAssertEqual(view.metalView.contentMode, .topLeft)
        XCTAssertNotEqual(view.metalView.layer.contentsGravity, .resize)
    }

    // MARK: The host

    /// A fitted pane on screen that has claimed its size and caught up.
    private func pane() throws -> (host: TerminalHost, transport: FakeFitTransport) {
        let transport = FakeFitTransport()
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = TerminalStream(control: control, sessionID: "s", blockID: "b1")
        let claim = FitClaim(transport: transport, settle: {})
        let host = TerminalHost(stream: stream, sizing: .fit, fontSize: 12, theme: ThemeStore.fallback, claim: claim)
        host.hardwareKeyboard = { false }
        host.ownClientID = { [phone] in phone }
        host.clientGeneration = { 0 }
        host.frame = window.bounds
        window.addSubview(host)
        host.layoutIfNeeded()
        XCTAssertTrue(eventually { transport.calls.count == 2 }, "own and resize")
        let size = try XCTUnwrap(host.claimWanted)
        host.streamResized(cols: size.cols, rows: size.rows, owner: phone)
        XCTAssertTrue(eventually { !host.stream.isClaimPending })
        host.streamSnapshot("$ ")
        pause(0.1)
        host.stream.stop()
        XCTAssertFalse(host.isCatchingUp)
        return (host, transport)
    }

    func testTheMacsSizeInTheBackgroundLeavesTheFrameAsTheUserSawIt() throws {
        let (host, transport) = try pane()
        let shown = host.term.frame
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertTrue(eventually { transport.calls.contains("disown") }, "handed back to the Mac, as before")
        XCTAssertTrue(host.term.awayHold)
        // The Mac takes the pane while the app still runs in the background.
        host.streamResized(cols: 211, rows: 57, owner: mac)
        XCTAssertEqual(host.term.frame, shown, "not laid out at the Mac's grid")
        XCTAssertTrue(host.term.core.isCatchUpHeld, "the frame the user left is kept")
        // Back: the stream catches up behind its fence while the claim takes the pane again.
        host.stream.start()
        XCTAssertTrue(host.isCatchingUp)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        host.layoutIfNeeded()
        XCTAssertEqual(host.term.frame, shown, "still the frame the user left, at its size")
        XCTAssertTrue(host.term.core.isCatchUpHeld)
        XCTAssertTrue(eventually { transport.calls.filter { $0 == "own" }.count == 2 }, "one claim on the return")
        XCTAssertTrue(eventually { !host.stream.isClaimPending }, "answered")
        let size = try XCTUnwrap(host.claimWanted)
        host.streamResized(cols: size.cols, rows: size.rows, owner: phone)
        // The echo of our resize back from the Mac's grid: the program's redraw for it is still
        // to come, so the frame stays until the stream has caught up.
        XCTAssertTrue(host.term.awayHold)
        XCTAssertEqual(host.term.frame, shown)
        // Caught up: the screen follows the terminal again, at the pane's own size.
        host.stream.stop()
        XCTAssertFalse(host.term.awayHold)
        XCTAssertFalse(host.term.core.isCatchUpHeld)
        XCTAssertEqual(host.term.frame, shown)
        XCTAssertEqual(transport.calls.filter { $0 == "own" }.count, 2, "one take as it opened, one on the return")
        XCTAssertEqual(transport.calls.filter { $0.hasPrefix("resize") }.count, 2, "and one resize each: nothing extra")
    }

    func testAReturnWithNothingToCatchUpFollowsTheTerminalAtOnce() throws {
        let (host, _) = try pane()
        let shown = host.term.frame
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        host.streamResized(cols: 211, rows: 57, owner: mac)
        XCTAssertEqual(host.term.frame, shown)
        // The stream is not running, so nothing will catch up: no fence, no frame kept.
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertFalse(host.term.awayHold)
        XCTAssertFalse(host.term.core.isCatchUpHeld)
        XCTAssertGreaterThan(host.term.frame.width, shown.width, "the terminal's grid, as before")
    }

    func testAMirrorPaneKeepsItsFrameToo() throws {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = TerminalStream(control: control, sessionID: "s", blockID: "b1")
        let host = TerminalHost(stream: stream, sizing: .mirror, fontSize: 12, theme: ThemeStore.fallback)
        host.hardwareKeyboard = { false }
        host.frame = window.bounds
        window.addSubview(host)
        host.layoutIfNeeded()
        host.streamResized(cols: 80, rows: 24, owner: mac)
        host.streamSnapshot("$ ")
        pause(0.1)
        stream.stop()
        let shown = host.term.frame, zoom = host.zoomScale
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        host.streamResized(cols: 160, rows: 48, owner: mac)
        XCTAssertEqual(host.term.frame, shown)
        XCTAssertEqual(host.zoomScale, zoom, "the same scale")
        stream.start()
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        XCTAssertEqual(host.term.frame, shown)
        stream.stop()
        XCTAssertNotEqual(host.term.frame, shown, "caught up: the new grid, scaled to the width")
        XCTAssertLessThan(host.zoomScale, zoom)
    }
}
