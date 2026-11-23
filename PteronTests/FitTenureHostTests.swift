import RexKit
import XCTest
@testable import Pteron

/// A fitted pane whose size passed to another client: taken back when that was only because
/// the phone's connection dropped, the chip when the other client asked for it.
@MainActor
final class FitTenureHostTests: XCTestCase {
    private static let lostText = "Resized on another screen · tap to fit this one"
    private let phone = "client:phone"
    private let mac = "client:mac"
    private var window: UIWindow!

    override func setUp() async throws {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        window.isHidden = false
    }

    override func tearDown() async throws {
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

    /// One pane: its host, its claim and the calls the claim made.
    private struct Pane {
        let host: TerminalHost
        let claim: FitClaim
        let transport: FakeFitTransport
        let pool: TerminalHostPool
        /// The lines the pane wrote into the connection log.
        let lines: Lines
    }

    @MainActor
    private final class Lines {
        var all: [String] = []
    }

    /// A fitted pane on screen that has claimed its size as `client:phone`, with the resize's
    /// echo seen. `current`: its stream has caught up; otherwise it is still behind its fence.
    private func pane(current: Bool = true, gate: FakeAttachGate? = nil) throws -> Pane {
        // Every pane that leaves the screen parks, and keeps its claim for the grace.
        let pool = TerminalHostPool()
        pool.power = { (lowPower: true, hot: false) }
        let transport = FakeFitTransport()
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = TerminalStream(control: control, sessionID: "s", blockID: "b1")
        // With a gate the calls wait for the session's attach, as the pane's own transport does.
        let claim = FitClaim(transport: gate.map { g in AttachGatedFitTransport(transport) { await g.mayCall() } } ?? transport, settle: {})
        let host = TerminalHost(stream: stream, sizing: .fit, fontSize: 12, theme: ThemeStore.fallback, claim: claim)
        host.leaveTiming = TerminalHost.LeaveTiming(settle: 0.02, claimGrace: 5)
        host.hardwareKeyboard = { false }
        host.fitCheckDelay = 0.1
        host.ownClientID = { [phone] in phone }
        host.clientGeneration = { 0 }
        let lines = Lines()
        host.note = { lines.all.append($0.summary) }
        pool.add(host, for: TerminalHostPool.Key(server: UUID(), session: "s", block: "b1"))
        host.frame = window.bounds
        window.addSubview(host)
        host.layoutIfNeeded()
        XCTAssertTrue(eventually { transport.calls.count == 2 }, "own and resize")
        let size = try XCTUnwrap(host.claimWanted)
        host.streamResized(cols: size.cols, rows: size.rows, owner: phone)
        XCTAssertTrue(eventually { !host.stream.isClaimPending })
        if current {
            host.streamSnapshot("$ ")
            pause(0.1)
            // Ends the stream's fence as a stream that caught up does; the host stays started.
            host.stream.stop()
            XCTAssertFalse(host.isCatchingUp)
        }
        return Pane(host: host, claim: claim, transport: transport, pool: pool, lines: lines)
    }

    private func takes(_ p: Pane) -> Int { p.transport.calls.filter { $0 == "own" }.count }
    private func resizes(_ p: Pane) -> Int { p.transport.calls.filter { $0.hasPrefix("resize") }.count }
    private func disowns(_ p: Pane) -> Int { p.transport.calls.filter { $0 == "disown" }.count }

    /// The stream carries the phone's resize: the pane has the size the phone asked for.
    private func echo(_ p: Pane, as client: String? = nil) throws {
        let size = try XCTUnwrap(p.host.claimWanted)
        p.host.streamResized(cols: size.cols, rows: size.rows, owner: client ?? phone)
    }

    private func change(_ reason: BlockOwnerChange.Reason, owner: String?, previous: String?) -> BlockOwnerChange {
        BlockOwnerChange(blockID: "b1", owner: owner, previous: previous, reason: reason)
    }

    /// The phone's connection dropped and came back inside the server's keep time: the same
    /// client goes on. It hears nothing of what happened to its pane meanwhile.
    private func dropAndReturnContinued(_ p: Pane) {
        p.host.controlCameBack()
    }

    /// The phone was away longer than the server keeps a client, or its socket was closed:
    /// it is back as a new client.
    private func dropAndReturnAsANewClient(_ p: Pane) {
        p.host.ownClientID = { "client:phone-2" }
        p.host.clientGeneration = { 1 }
        p.host.controlCameBack()
    }

    // MARK: The owner's report

    func testAPaneThatPassedToTheMacWhenThePhonesClientEndedIsTakenBackWithNoChip() throws {
        // The phone's client ended (its socket closed, or it was away too long), the Mac app
        // was next in line and the pane took its size. No event says what became of the pane;
        // the phone is back as a new client and finds the Mac's size.
        let p = try pane()
        let mine = try XCTUnwrap(p.host.claimWanted)
        dropAndReturnAsANewClient(p)
        p.host.streamResized(cols: 211, rows: 57, owner: mac)
        XCTAssertNil(p.host.statusChipText, "no chip: nobody asked for the pane")
        XCTAssertTrue(eventually { self.takes(p) == 2 && self.resizes(p) == 2 }, "one take, one resize")
        XCTAssertEqual(p.transport.calls.last, "resize \(mine.cols)x\(mine.rows)")
        try echo(p, as: "client:phone-2")
        XCTAssertTrue(eventually { !p.host.stream.isClaimPending })
        pause(0.3)
        XCTAssertNil(p.host.statusChipText)
        XCTAssertEqual(disowns(p), 0, "the phone never left the line")
        XCTAssertEqual(p.transport.calls.count, 4, "and nothing more")
        XCTAssertTrue(p.host.term.frame.width <= p.host.bounds.width + 1, "drawn at the size that fits")
        XCTAssertTrue(p.lines.all.contains("pane fit taken back"))
        XCTAssertFalse(p.lines.all.contains { $0.hasPrefix("pane fit lost") })
        p.host.removeFromSuperview()
    }

    func testATakeBackAskedBeforeTheNewClientsAttachWaitsAndKeepsThePane() throws {
        // Back as a new client. The app's bootstrap is answered and its attach is on its way:
        // a take that left now was answered with a plain bad request, read as a no, and the
        // pane stayed at the Mac's size with the chip up and its last rows under the keyboard.
        let gate = FakeAttachGate(attached: true)
        let p = try pane(gate: gate)
        let mine = try XCTUnwrap(p.host.claimWanted)
        gate.newClient()
        dropAndReturnAsANewClient(p)
        p.host.streamResized(cols: 211, rows: 57, owner: mac)
        pause(0.4)
        XCTAssertEqual(p.transport.calls.count, 2, "nothing leaves before the attach: \(p.transport.calls)")
        XCTAssertEqual(gate.waiting, 1)
        XCTAssertNil(p.host.statusChipText, "no chip while it waits")
        gate.attach()
        XCTAssertTrue(eventually { self.takes(p) == 2 && self.resizes(p) == 2 }, "one take, one resize")
        XCTAssertEqual(p.transport.calls.last, "resize \(mine.cols)x\(mine.rows)")
        try echo(p, as: "client:phone-2")
        XCTAssertTrue(eventually { !p.host.stream.isClaimPending })
        pause(0.3)
        XCTAssertNil(p.host.statusChipText, "the pane is the phone's again, without a word")
        XCTAssertTrue(p.host.fitted)
        XCTAssertEqual(disowns(p), 0)
        XCTAssertEqual(p.transport.calls.count, 4, "and nothing more")
        XCTAssertTrue(p.lines.all.contains("pane fit taken back"))
        XCTAssertFalse(p.lines.all.contains { $0.hasPrefix("pane fit lost") })
        p.host.removeFromSuperview()
    }

    func testAPaneTheServerGaveBackToAContinuedClientNeedsNothing() throws {
        // A drop with no close frame, back inside the server's keep time: the server gave the
        // pane back at the phone's size, and the stream replays the time away.
        let p = try pane()
        let mine = try XCTUnwrap(p.host.claimWanted)
        dropAndReturnContinued(p)
        p.host.streamResized(cols: 211, rows: 57, owner: mac)
        XCTAssertNil(p.host.statusChipText, "the Mac's size from the time away is history")
        p.host.streamResized(cols: mine.cols, rows: mine.rows, owner: phone)
        pause(0.4)
        XCTAssertNil(p.host.statusChipText)
        XCTAssertEqual(p.transport.calls.count, 2, "nothing sent: no take, no resize, no disown")
        XCTAssertTrue(p.host.term.frame.width <= p.host.bounds.width + 1)
        XCTAssertFalse(p.lines.all.contains { $0.hasPrefix("pane fit") })
        // The tenure goes on: the Mac's size after that is the Mac.
        p.host.streamResized(cols: 211, rows: 57, owner: mac)
        XCTAssertEqual(p.host.statusChipText, Self.lostText)
        p.host.removeFromSuperview()
    }

    func testATakeBackHappensOncePerDrop() throws {
        let p = try pane()
        dropAndReturnAsANewClient(p)
        p.host.streamResized(cols: 211, rows: 57, owner: mac)
        XCTAssertTrue(eventually { self.takes(p) == 2 && self.resizes(p) == 2 })
        try echo(p, as: "client:phone-2")
        XCTAssertTrue(eventually { !p.host.stream.isClaimPending })
        pause(0.3)
        XCTAssertNil(p.host.statusChipText)
        // The Mac's size again, on a connection that has not dropped since: that is the Mac.
        p.host.streamResized(cols: 211, rows: 57, owner: mac)
        XCTAssertEqual(p.host.statusChipText, Self.lostText)
        pause(0.3)
        XCTAssertEqual(takes(p), 2, "no second take back")
        p.host.removeFromSuperview()
    }

    // MARK: H-10: no fight with a client that asked for the pane

    func testATakeByAnotherClientShowsTheChipAndIsNotTakenBack() throws {
        let p = try pane()
        p.host.ownerChanged(change(.take, owner: mac, previous: phone))
        p.host.streamResized(cols: 211, rows: 57, owner: mac)
        XCTAssertEqual(p.host.statusChipText, Self.lostText)
        XCTAssertTrue(eventually { self.disowns(p) == 1 }, "the phone leaves the line")
        pause(0.3)
        XCTAssertEqual(takes(p), 1, "never taken back by itself")
        XCTAssertEqual(resizes(p), 1)
        XCTAssertTrue(p.lines.all.contains("pane owner reason=take previous=phone owner=other"))
        XCTAssertTrue(p.lines.all.contains("pane fit lost how=resize"))
        p.host.removeFromSuperview()
    }

    func testATakeAtTheSameSizeShowsTheChipToo() throws {
        let p = try pane()
        p.host.ownerChanged(change(.take, owner: mac, previous: phone))
        XCTAssertTrue(eventually(1) { p.host.statusChipText == Self.lostText }, "the event alone says who has the pane")
        XCTAssertEqual(takes(p), 1)
        p.host.removeFromSuperview()
    }

    func testATakeBackThatDoesNotHoldShowsTheChip() throws {
        // The take was answered and the server kept the other client's size: somebody has it.
        let p = try pane()
        dropAndReturnAsANewClient(p)
        p.host.streamResized(cols: 211, rows: 57, owner: mac)
        XCTAssertTrue(eventually { self.takes(p) == 2 && self.resizes(p) == 2 })
        XCTAssertTrue(eventually(1) { p.host.statusChipText == Self.lostText })
        pause(0.3)
        XCTAssertEqual(takes(p), 2, "one take back, then no fight")
        p.host.removeFromSuperview()
    }

    func testATakeHeardAfterTheReturnIsNotTakenBack() throws {
        // Back as a new client, and then somebody at the Mac takes the pane.
        let p = try pane()
        dropAndReturnAsANewClient(p)
        p.host.ownerChanged(change(.take, owner: mac, previous: "client:phone"))
        p.host.streamResized(cols: 211, rows: 57, owner: mac)
        XCTAssertEqual(p.host.statusChipText, Self.lostText)
        pause(0.3)
        XCTAssertEqual(takes(p), 1)
        p.host.removeFromSuperview()
    }

    func testAPaneTheServerDidNotGiveBackWasTakenWhileThePhoneWasAway() throws {
        // The same client goes on, and the pane is not back at the phone's size once the
        // stream has caught up: its owner changed again while the phone was away, which only
        // a client's own call does.
        let p = try pane()
        dropAndReturnContinued(p)
        p.host.streamResized(cols: 211, rows: 57, owner: mac)
        XCTAssertNil(p.host.statusChipText, "the phone's own size may still follow")
        XCTAssertTrue(eventually(1) { p.host.statusChipText == Self.lostText }, "it did not")
        XCTAssertEqual(takes(p), 1, "not taken back")
        p.host.removeFromSuperview()
    }

    // MARK: H-11: a pane that left the screen or the app is not taken back

    func testAPaneThatLeftTheScreenIsNotTakenBack() throws {
        let p = try pane()
        p.host.removeFromSuperview()
        XCTAssertTrue(eventually { p.host.isParked }, "off screen, inside the claim's grace")
        dropAndReturnAsANewClient(p)
        p.host.streamResized(cols: 211, rows: 57, owner: mac)
        pause(0.3)
        XCTAssertEqual(takes(p), 1, "nothing is taken for a pane nobody sees")
        XCTAssertEqual(resizes(p), 1)
        XCTAssertFalse(p.lines.all.contains("pane fit taken back"))
        XCTAssertFalse(p.lines.all.contains { $0.hasPrefix("pane owner") }, "a pane off screen writes no line")
    }

    func testAPaneOfAnAppInTheBackgroundIsNotTakenBack() throws {
        let p = try pane()
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertTrue(eventually { self.disowns(p) == 1 }, "given back as the app leaves, as before")
        dropAndReturnAsANewClient(p)
        p.host.streamResized(cols: 211, rows: 57, owner: mac)
        pause(0.3)
        XCTAssertEqual(takes(p), 1)
        XCTAssertEqual(resizes(p), 1)
        XCTAssertFalse(p.lines.all.contains("pane fit taken back"))
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        p.host.removeFromSuperview()
    }

    func testAPaneUnderTheAgentBoardIsNotTakenBack() throws {
        let p = try pane()
        p.host.setCovered(true)
        dropAndReturnAsANewClient(p)
        p.host.streamResized(cols: 211, rows: 57, owner: mac)
        pause(0.3)
        XCTAssertEqual(takes(p), 1)
        XCTAssertFalse(p.lines.all.contains("pane fit taken back"))
        p.host.setCovered(false)
        p.host.removeFromSuperview()
    }

    // MARK: H-12: nothing is asked of a computer that is away

    func testNothingIsSentWhileTheConnectionIsDown() throws {
        let p = try pane()
        var down = true
        p.host.controlDown = { down }
        // The data socket outlived the control connection and shows the Mac's size.
        p.host.streamResized(cols: 211, rows: 57, owner: mac)
        pause(0.5)
        XCTAssertEqual(p.transport.calls.count, 2, "no take, no resize, no disown")
        XCTAssertNil(p.host.statusChipText, "and no chip: nothing is known")
        // Back as a new client: one take back, at the look the welcome asks for.
        down = false
        dropAndReturnAsANewClient(p)
        XCTAssertTrue(eventually { self.takes(p) == 2 && self.resizes(p) == 2 })
        try echo(p, as: "client:phone-2")
        pause(0.3)
        XCTAssertEqual(p.transport.calls.count, 4, "one take and one resize, not one per look")
        XCTAssertNil(p.host.statusChipText)
        p.host.removeFromSuperview()
    }

    func testATakeBackTheConnectionLosesIsAskedOnceWhenItIsBack() throws {
        let p = try pane()
        p.transport.answers = ["own": [.offline]]
        dropAndReturnAsANewClient(p)
        p.host.streamResized(cols: 211, rows: 57, owner: mac)
        XCTAssertTrue(eventually { p.transport.waitsForConnection })
        let calls = p.transport.calls.count
        pause(0.5)
        XCTAssertEqual(p.transport.calls.count, calls, "no attempt of its own: it waits for the connection")
        XCTAssertEqual(takes(p), 2)
        p.transport.connect()
        XCTAssertTrue(eventually { self.takes(p) == 3 && self.resizes(p) == 2 })
        try echo(p, as: "client:phone-2")
        pause(0.3)
        XCTAssertNil(p.host.statusChipText)
        XCTAssertEqual(p.transport.calls.count, 5, "the lost take, then one take and one resize")
        p.host.removeFromSuperview()
    }

    // MARK: A resize that was left out counts as our echo seen

    func testAfterAResizeThatWasLeftOutAnotherClientsSizeBehindTheFenceIsATake() throws {
        // The server had the size, so the claim sent no resize and no echo of one will come.
        // A size another client sets while the stream still catches up is that client's take:
        // the chip, and no resize sent after all.
        let p = try pane(current: false)
        let mine = try XCTUnwrap(p.host.claimWanted)
        p.claim.reported = { (mine.cols, mine.rows) }
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertTrue(eventually { self.disowns(p) == 1 })
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        p.host.layoutIfNeeded()
        XCTAssertTrue(eventually { self.takes(p) == 2 && !p.host.stream.isClaimPending }, "the take alone was the claim")
        XCTAssertEqual(resizes(p), 1, "the resize was left out")
        XCTAssertTrue(p.host.isCatchingUp)
        p.claim.reported = { (211, 57) }
        p.host.streamResized(cols: 211, rows: 57, owner: mac)
        XCTAssertEqual(p.host.statusChipText, Self.lostText, "at once, not at a later look")
        pause(0.3)
        XCTAssertEqual(resizes(p), 1, "no resize after all")
        XCTAssertEqual(takes(p), 2)
        p.host.removeFromSuperview()
    }

    func testAfterAResizeThatWasLeftOutTheSizeTheTakeBroughtIsStillSizedAgain() throws {
        // The take gave the pane a size the server had kept for the phone: its own, so no chip,
        // and the resize goes after all.
        let p = try pane(current: false)
        let mine = try XCTUnwrap(p.host.claimWanted)
        p.claim.reported = { (mine.cols, mine.rows) }
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertTrue(eventually { self.disowns(p) == 1 })
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        p.host.layoutIfNeeded()
        XCTAssertTrue(eventually { self.takes(p) == 2 && !p.host.stream.isClaimPending })
        p.claim.reported = { (70, 20) }
        p.host.streamResized(cols: 70, rows: 20, owner: phone)
        XCTAssertNil(p.host.statusChipText)
        XCTAssertTrue(eventually { self.resizes(p) == 2 }, "sent after all")
        p.host.removeFromSuperview()
    }

    // MARK: The connection log

    func testOwnerChangesOfAPaneOnScreenAreWrittenWithTheirReason() throws {
        let p = try pane()
        p.host.ownerChanged(change(.lost, owner: mac, previous: phone))
        p.host.ownerChanged(change(.restore, owner: phone, previous: mac))
        p.host.ownerChanged(change(.disconnect, owner: nil, previous: mac))
        XCTAssertNil(p.host.statusChipText, "a pane that passes on with no wish behind it shows no chip")
        XCTAssertEqual(p.lines.all, ["pane owner reason=lost previous=phone owner=other",
                                     "pane owner reason=restore previous=other owner=phone",
                                     "pane owner reason=disconnect previous=other owner=none"])
        p.host.removeFromSuperview()
    }

    func testThePanesOfAComputerHearOnlyTheirOwnBlock() {
        let changes = OwnerChanges()
        let heard = Lines()
        changes.observe(block: "b1") { heard.all.append("one \($0.reason)"); return $0.reason != .disown }
        changes.observe(block: "b2") { heard.all.append("two \($0.reason)"); return true }
        changes.send(BlockOwnerChange(blockID: "b1", owner: mac, previous: nil, reason: .take))
        changes.send(BlockOwnerChange(blockID: "b3", owner: mac, previous: nil, reason: .take))
        XCTAssertEqual(heard.all, ["one take"])
        XCTAssertEqual(changes.count(block: "b1"), 1)
        // An observer that says it is done is told that once and then forgotten.
        changes.send(BlockOwnerChange(blockID: "b1", owner: nil, previous: mac, reason: .disown))
        XCTAssertEqual(changes.count(block: "b1"), 0)
        changes.forget(block: "b2")
        changes.send(BlockOwnerChange(blockID: "b2", owner: mac, previous: nil, reason: .take))
        XCTAssertEqual(heard.all, ["one take", "one disown"])
    }
}
