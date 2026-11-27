import RexKit
import XCTest
@testable import Pteron

/// A fitted pane keeps its claim through a short trip to the background, so a quick return
/// needs no resize and the program no redraw; a longer one gives the Mac its size back.
@MainActor
final class BackgroundGraceTests: XCTestCase {
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

    func testOnlyAnAnsweredClaimOnScreenIsKept() {
        XCTAssertTrue(BackgroundGrace.keeps(fitted: true, claimed: true, onItsWay: false, inWindow: true))
        XCTAssertFalse(BackgroundGrace.keeps(fitted: false, claimed: true, onItsWay: false, inWindow: true), "mirror, or another client has it")
        XCTAssertFalse(BackgroundGrace.keeps(fitted: true, claimed: false, onItsWay: false, inWindow: true), "nothing claimed")
        XCTAssertFalse(BackgroundGrace.keeps(fitted: true, claimed: true, onItsWay: true, inWindow: true),
                       "a claim on its way must not resize the pane for a phone that isn't looking")
        XCTAssertFalse(BackgroundGrace.keeps(fitted: true, claimed: true, onItsWay: false, inWindow: false), "parked")
    }

    func testTheGraceIsAParkedPanesGraceAndFitsInABackgroundTask() {
        XCTAssertEqual(BackgroundGrace.seconds, TerminalHost.LeaveTiming().claimGrace)
        XCTAssertLessThan(BackgroundGrace.seconds, 25, "the release leaves before iOS suspends the app")
    }

    // MARK: The host

    /// A fitted pane on screen that has claimed its size and caught up.
    private func pane(grace: TimeInterval) throws -> (host: TerminalHost, transport: FakeFitTransport) {
        let transport = FakeFitTransport()
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = TerminalStream(control: control, sessionID: "s", blockID: "b1")
        let claim = FitClaim(transport: transport, settle: {})
        let host = TerminalHost(stream: stream, sizing: .fit, fontSize: 12, theme: ThemeStore.fallback, claim: claim)
        host.hardwareKeyboard = { false }
        host.ownClientID = { [phone] in phone }
        host.clientGeneration = { 0 }
        host.leaveTiming.backgroundGrace = grace
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
        return (host, transport)
    }

    func testAQuickReturnSendsNothing() throws {
        let (host, transport) = try pane(grace: 30)
        let calls = transport.calls
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertTrue(host.keepsClaimInBackground)
        pause(0.2)
        XCTAssertEqual(transport.calls, calls, "the claim stays for the grace")
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        host.layoutIfNeeded()
        pause(0.2)
        XCTAssertFalse(host.keepsClaimInBackground)
        XCTAssertEqual(transport.calls, calls, "no take, no resize, no give back: the program has nothing to redraw")
        XCTAssertFalse(host.stream.isClaimPending)
    }

    func testAfterTheGraceTheMacGetsItsSizeBackAndTheReturnClaimsAgain() throws {
        let (host, transport) = try pane(grace: 0.1)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        XCTAssertFalse(transport.calls.contains("disown"), "not at once")
        XCTAssertTrue(eventually { transport.calls.contains("disown") }, "given back when the grace ends")
        XCTAssertFalse(host.keepsClaimInBackground)
        host.streamResized(cols: 211, rows: 57, owner: mac)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        host.layoutIfNeeded()
        XCTAssertTrue(eventually { transport.calls.filter { $0 == "own" }.count == 2 }, "taken again on the return")
        XCTAssertTrue(eventually { transport.calls.filter { $0.hasPrefix("resize") }.count == 2 })
        XCTAssertNil(host.statusChipText)
    }

    func testTheMacsTakeDuringTheGraceWinsAndIsNotFoughtOver() throws {
        let (host, transport) = try pane(grace: 30)
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        // Someone uses the Mac: its take makes it the owner at once, at its size.
        host.ownerChanged(BlockOwnerChange(blockID: "b1", owner: mac, previous: phone, reason: .take))
        host.streamResized(cols: 211, rows: 57, owner: mac)
        XCTAssertTrue(eventually { transport.calls.contains("disown") }, "the phone leaves the line")
        let calls = transport.calls
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        host.layoutIfNeeded()
        pause(0.3)
        XCTAssertEqual(transport.calls, calls, "never taken back by itself")
        XCTAssertNotNil(host.statusChipText, "the chip offers it")
    }
}
