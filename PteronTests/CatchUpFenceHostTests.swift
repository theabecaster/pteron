import Metal
import RexKit
import XCTest
@testable import Pteron
@testable import RexKit

/// What a pane does while its stream catches up (`CatchUpFence`, RexKit): it keeps its screen
/// and shows the catch-up as one frame, its cursor is hollow, and reports are not sent.
@MainActor
final class CatchUpFenceHostTests: XCTestCase {
    private func makeHost(sizing: SizingMode = .mirror) -> (TerminalHost, TerminalStream) {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = TerminalStream(control: control, sessionID: "s", blockID: "b")
        return (TerminalHost(stream: stream, sizing: sizing, fontSize: 12, theme: ThemeStore.fallback), stream)
    }

    private var window: UIWindow?
    private var panesBefore = 0

    override func setUp() async throws {
        panesBefore = GhosttyRenderThread.shared.paneCount
    }

    /// A host that was in a window goes a few turns of the main queue after its test: the
    /// next test class starts with none of this one's panes left.
    override func tearDown() async throws {
        guard window != nil else { return }
        window?.isHidden = true
        window = nil
        var turns = 0
        let giveUp = ContinuousClock.now + .seconds(10)
        while GhosttyRenderThread.shared.paneCount > panesBefore, turns < 1500, ContinuousClock.now < giveUp {
            turns += 1
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Makes `host` the front pane (`PaneFront`): in a window, the tab's active pane, the app
    /// in front. Too small to lay out, so the host starts nothing by itself.
    private func bringToFront(_ host: TerminalHost) {
        let w = window ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        if window == nil {
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { w.windowScene = scene }
            w.isHidden = false
            window = w
        }
        host.hardwareKeyboard = { false }
        host.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        w.addSubview(host)
        host.appActiveChanged(true)
        host.isActive = true
    }

    /// Takes `host` out of the window and lets it go at once: a host that only leaves its
    /// window holds on to itself until it has stayed away (`TerminalHost.scheduleStop`).
    private func leave(_ host: TerminalHost) {
        host.removeFromSuperview()
        host.evict()
    }

    private func build(_ text: String) -> (GhosttyCore, GhosttyFrameBuilder) {
        let core = GhosttyCore(cols: 20, rows: 4)
        core.feed(Array(text.utf8))
        core.sync()
        let frame = GhosttyFrameBuilder(atlas: GhosttyGlyphAtlas(pointSize: 12, scale: 2))
        XCTAssertTrue(frame.update(core: core))
        return (core, frame)
    }

    // MARK: Hazard 5: no jump while the user reads

    func testACatchUpInSeveralChunksIsShownAsOneFrame() {
        let (core, frame) = build("old")
        core.setCatchUpHold(true)
        // The missed output arrives in pieces; each is parsed, none is drawn.
        for chunk in ["\r\u{1b}[Kn", "ew", "er\r\nsecond ", "line"] {
            core.feed(Array(chunk.utf8))
            core.sync()
            _ = frame.update(core: core)
            XCTAssertEqual(frame.rows[0].glyphs.count, 3, "still the screen the user was reading")
            XCTAssertEqual(frame.rows[1].glyphs.count, 0)
        }
        XCTAssertEqual(core.rowText(0), "newer", "the terminal itself has moved on")
        core.setCatchUpHold(false)
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rows[0].glyphs.count, 5)
        XCTAssertEqual(frame.rows[1].glyphs.count, 10, "everything in the one frame")
    }

    func testTheHoldKeepsTheScreenOfTheMomentItBegan() {
        let (core, frame) = build("old")
        // Parsed while the pane was not drawn: the screen to keep has it.
        core.feed(Array("er".utf8))
        core.sync()
        core.setCatchUpHold(true)
        core.feed(Array(" and more".utf8))
        core.sync()
        _ = frame.update(core: core)
        XCTAssertEqual(frame.rows[0].glyphs.count, 5)
    }

    func testAHoldThatIsNeverReleasedEndsAtItsLimit() {
        let (core, frame) = build("old")
        core.setCatchUpHold(true)
        XCTAssertTrue(core.isCatchUpHeld)
        core.feed(Array("\r\u{1b}[Knewer".utf8))
        core.sync()
        _ = frame.update(core: core)
        XCTAssertEqual(frame.rows[0].glyphs.count, 3)
        XCTAssertTrue(frame.update(core: core, now: CACurrentMediaTime() + GhosttyCore.renderHoldTimeout + 0.1))
        XCTAssertEqual(frame.rows[0].glyphs.count, 5, "after a second the screen follows the bytes again")
    }

    func testAProgramsOwnHoldStillHoldsAfterTheCatchUp() {
        let (core, frame) = build("old")
        core.setCatchUpHold(true)
        core.feed(Array("\u{1b}[?2026h\r\u{1b}[Knewer".utf8))
        core.sync()
        core.setCatchUpHold(false)
        _ = frame.update(core: core)
        XCTAssertEqual(frame.rows[0].glyphs.count, 3, "the program has not finished its frame")
        core.feed(Array("\u{1b}[?2026l".utf8))
        core.sync()
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rows[0].glyphs.count, 5)
    }

    // MARK: The look: only the cursor changes

    private func draw(_ renderer: GhosttyRenderer, _ device: MTLDevice, width: Int, height: Int) throws -> [UInt8] {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: d))
        XCTAssertTrue(renderer.renderOffscreen(into: texture))
        var out = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&out, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return out
    }

    func testAFencedPaneDrawsAHollowCursorAndNothingElseChanges() throws {
        let metal = try XCTUnwrap(GhosttyMetal.shared, "Metal and the shaders must be available")
        let core = GhosttyCore(cols: 10, rows: 3)
        core.feed(Array("\u{1b}[41m \u{1b}[0mtext\r\n\u{1b}[2 q".utf8))
        core.sync()
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let m = atlas.metrics
        let width = 10 * m.cellWidth, height = 3 * m.cellHeight
        let renderer = GhosttyRenderer(core: core, atlas: atlas)
        let solid = try draw(renderer, metal.device, width: width, height: height)
        renderer.setFenced(true)
        let fenced = try draw(renderer, metal.device, width: width, height: height)
        renderer.setFenced(false)
        let again = try draw(renderer, metal.device, width: width, height: height)

        func pixel(_ image: [UInt8], _ x: Int, _ y: Int) -> [UInt8] { Array(image[(y * width + x) * 4..<(y * width + x) * 4 + 4]) }
        let cursor: [UInt8] = [0xf5, 0x9b, 0x53, 0xff], background: [UInt8] = [0x2e, 0x27, 0x22, 0xff]
        // The cursor is at the start of row 1.
        let cx = m.cellWidth / 2, cy = m.cellHeight + m.cellHeight / 2
        XCTAssertEqual(pixel(solid, cx, cy), cursor)
        XCTAssertEqual(pixel(fenced, cx, cy), background, "hollow: the cell shows through")
        XCTAssertEqual(pixel(fenced, 0, cy), cursor, "its outline is the cursor's color")
        // Outside the cursor's cell not one pixel differs: no dimming, no badge.
        var differing = 0
        for y in 0..<height {
            for x in 0..<width where !(x < m.cellWidth && y >= m.cellHeight && y < 2 * m.cellHeight) {
                if pixel(solid, x, y) != pixel(fenced, x, y) { differing += 1 }
            }
        }
        XCTAssertEqual(differing, 0)
        XCTAssertEqual(again, solid, "and the pane is exactly as before once it is current")
    }

    // MARK: The host

    func testAFencedHostHoldsItsScreenAndHollowsItsCursor() {
        let (host, _) = makeHost()
        XCTAssertFalse(host.term.core.isCatchUpHeld)
        XCTAssertFalse(host.term.renderer.isFenced)
        host.streamFence(true, screen: true)
        XCTAssertTrue(host.term.core.isCatchUpHeld)
        XCTAssertTrue(host.term.renderer.isFenced)
        host.streamFence(false, screen: true)
        XCTAssertFalse(host.term.core.isCatchUpHeld)
        XCTAssertFalse(host.term.renderer.isFenced)
    }

    func testAPaneThatOpensAtItsOwnSizeShowsItsFirstScreenAtOnce() {
        let (host, stream) = makeHost(sizing: .mirror)
        // A start without a connection: the fence is up and nothing else happens.
        stream.start()
        XCTAssertTrue(host.isCatchingUp)
        XCTAssertTrue(host.term.core.isCatchUpHeld)
        // The size that follows the snapshot is the one a mirror pane shows: no reflow to hide.
        host.streamResized(cols: 80, rows: 24, owner: nil)
        XCTAssertFalse(host.term.core.isCatchUpHeld, "the screen is drawn")
        XCTAssertTrue(host.term.renderer.isFenced, "while input still waits")
        stream.stop()
        XCTAssertFalse(host.term.renderer.isFenced)
    }

    func testAFittedPaneWaitingForItsResizeKeepsHolding() {
        let (host, stream) = makeHost(sizing: .fit)
        stream.start()
        stream.setClaimPending(true)
        host.streamResized(cols: 80, rows: 24, owner: nil)
        XCTAssertTrue(host.term.core.isCatchUpHeld, "the reflow is still to come")
        stream.stop()
    }

    // MARK: Hazard 3: reports at stale coordinates

    func testReportsFromTheEngineAreDroppedWhileFenced() {
        let (host, stream) = makeHost()
        var notices: [TerminalStream.Notice] = []
        stream.onActionFailed = { notices.append($0) }
        let click = Array("\u{1b}[<0;10;5M".utf8)
        // Current: a report is queued like any input (no connection here, so it waits).
        host.engineSendReport(click)
        XCTAssertTrue(stream.hasPendingInput)
        stream.stop()
        stream.start()
        XCTAssertTrue(stream.isFenced)
        host.engineSendReport(click)
        XCTAssertFalse(stream.hasPendingInput, "not sent and not held")
        XCTAssertEqual(notices, [], "a dropped report says nothing")
        stream.stop()
    }

    func testATypedPathIsDroppedWhileFencedAndSaysSo() {
        let (host, stream) = makeHost()
        var notices: [TerminalStream.Notice] = []
        stream.onActionFailed = { notices.append($0) }
        stream.start()
        host.insertPath("~/Documents/report.txt ")
        XCTAssertFalse(stream.hasPendingInput)
        XCTAssertEqual(notices, [.stillReconnecting], "nothing had come: no screen yet")
        stream.stop()
    }

    // MARK: A fence that lasts

    func testAFenceThatLastsSaysReconnecting() {
        let (host, _) = makeHost()
        host.fenceStatusDelay = 0.05
        host.streamFence(true, screen: true)
        XCTAssertNil(host.statusChipText, "nothing shows for a short catch-up")
        let shown = expectation(description: "chip")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { shown.fulfill() }
        wait(for: [shown], timeout: 2)
        XCTAssertEqual(host.statusChipText, "Reconnecting…")
        host.streamFence(false, screen: true)
        XCTAssertNil(host.statusChipText, "gone with the fence")
    }

    func testAFenceOverAnEmptyPaneLeavesTheChipToTheOpening() {
        let (host, stream) = makeHost()
        host.fenceStatusDelay = 0.05
        stream.start()
        let waited = expectation(description: "wait")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { waited.fulfill() }
        wait(for: [waited], timeout: 2)
        XCTAssertNotEqual(host.statusChipText, "Reconnecting…", "an opening pane is not reconnecting because of its fence")
        stream.stop()
    }

    // MARK: What the fence dropped without a word, and how the rest is said

    func testAFocusReportDroppedBehindTheFenceGoesWhenItComesDown() {
        let (host, stream) = makeHost()
        // The program asks for focus reports.
        host.term.feed(text: "\u{1b}[?1004h")
        host.term.core.sync()
        stream.start()
        XCTAssertTrue(stream.isFenced)
        // The pane comes to the front while its stream catches up.
        bringToFront(host)
        XCTAssertTrue(host.term.programFocus.front)
        XCTAssertFalse(stream.hasPendingInput, "a report never leaves behind the fence")
        XCTAssertFalse(host.term.programFocus.said)
        // The fence comes down (no connection in this test: what is sent waits in the queue).
        stream.fence.reset()
        XCTAssertTrue(stream.hasPendingInput, "the program learns that its pane is in front")
        XCTAssertTrue(host.term.programFocus.said)
        stream.stop()
        leave(host)
    }

    func testAFocusLostDroppedBehindTheFenceGoesWhenItComesDown() {
        let (host, stream) = makeHost()
        host.term.feed(text: "\u{1b}[?1004h")
        host.term.core.sync()
        bringToFront(host)
        XCTAssertTrue(host.term.programFocus.said, "told while the stream was current")
        // Whatever waited goes with the stop; the stream starts again behind its fence.
        stream.stop()
        stream.start()
        XCTAssertTrue(stream.isFenced)
        // Another pane becomes the active one meanwhile.
        host.isActive = false
        XCTAssertFalse(stream.hasPendingInput)
        XCTAssertTrue(host.term.programFocus.said, "still owed")
        stream.fence.reset()
        XCTAssertTrue(stream.hasPendingInput, "the program learns that its pane left the front")
        XCTAssertFalse(host.term.programFocus.said)
        stream.stop()
        leave(host)
    }

    /// A report is counted as said when it is handed to the stream, not when it arrives, and
    /// one that never arrived is not known of. So a pane in front says so again each time its
    /// stream is current again.
    func testAPaneInFrontSaysSoAgainEachTimeTheFenceComesDown() {
        let (host, stream) = makeHost()
        host.term.feed(text: "\u{1b}[?1004h")
        host.term.core.sync()
        bringToFront(host)
        XCTAssertTrue(stream.hasPendingInput)
        XCTAssertTrue(host.term.programFocus.said)
        for round in 1...2 {
            // The report is lost with the queue.
            stream.stop()
            XCTAssertFalse(stream.hasPendingInput)
            stream.start()
            XCTAssertTrue(stream.isFenced)
            stream.fence.reset()
            XCTAssertTrue(stream.hasPendingInput, "said again, round \(round)")
        }
        stream.stop()
        leave(host)
    }

    func testAPaneThatIsNotInFrontSaysSoWhenTheFenceComesDown() {
        let (host, stream) = makeHost()
        host.term.feed(text: "\u{1b}[?1004h")
        host.term.core.sync()
        // Not in front. Whether the program knows is not known: an earlier report may have
        // been dropped with a parked stream's queue.
        stream.start()
        stream.fence.reset()
        XCTAssertTrue(stream.hasPendingInput)
        XCTAssertFalse(host.term.programFocus.said)
        stream.stop()
    }

    func testNoFocusReportForAProgramThatNeverAsked() {
        // In front or not, a fence that comes and goes says nothing.
        let (host, stream) = makeHost()
        XCTAssertFalse(host.isFrontPane)
        stream.start()
        stream.fence.reset()
        XCTAssertFalse(stream.hasPendingInput)
        let (other, plain) = makeHost()
        plain.start()
        bringToFront(other)
        plain.fence.reset()
        XCTAssertFalse(plain.hasPendingInput)
        stream.stop()
        plain.stop()
        leave(other)
    }

    func testWhatTheFenceDroppedIsSaidInTheNeutralStyle() {
        let (host, stream) = makeHost()
        Notice.shared.dismiss()
        stream.showsNotices(computer: "Desk", keymap: nil)
        stream.start()
        host.insertPath("~/notes.txt ")
        XCTAssertEqual(Notice.shared.message, Messages.stillReconnecting)
        XCTAssertEqual(Notice.shared.style, .neutral)
        Notice.shared.dismiss()
        stream.onActionFailed?(.actionRefused(action: "pane.clear", title: nil, code: "bad_request"))
        XCTAssertEqual(Notice.shared.style, .error, "a failure keeps its own style")
        Notice.shared.dismiss()
        stream.stop()
    }
}
