import RexKit
import XCTest
@testable import Pteron

/// What `RexControl.mayCall(attachedTo:)` does for one session, moved by the test: a call waits
/// for the attach, a wait ends with the attach, a cancel or the cap, and after a cap the next
/// call goes.
@MainActor
final class FakeAttachGate {
    private(set) var attached: Bool
    /// A wait ran to its cap: the next call is not held back.
    private(set) var unseen = false
    var connected = true
    private var waiters: [CheckedContinuation<Bool, Never>] = []
    /// How often a call had to wait.
    private(set) var waits = 0

    init(attached: Bool = false) { self.attached = attached }

    var waiting: Int { waiters.count }

    func mayCall() async -> Bool {
        guard connected, !attached, !unseen else { return true }
        waits += 1
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func end(_ answer: Bool) {
        let all = waiters
        waiters = []
        for w in all { w.resume(returning: answer) }
    }

    /// The server answered the session's attach.
    func attach() {
        attached = true
        unseen = false
        end(true)
    }

    /// A reconnect started a new client: attached to nothing.
    func newClient() {
        attached = false
        unseen = false
    }

    /// The connection dropped, or the app went to the background.
    func cancel() { end(false) }

    /// The wait's cap passed.
    func cap() {
        guard !waiters.isEmpty else { return }
        unseen = true
        end(false)
    }
}

/// Fit mode's calls wait for the session's attach: a take that left between the app's bootstrap
/// and its attach was refused for good, and the pane stayed at another size with the chip up.
@MainActor
final class AttachGatedFitTests: XCTestCase {
    private let inner = FakeFitTransport()
    private var claimed: [String] = []
    private var refused = 0

    private func makeClaim(_ gate: FakeAttachGate) -> FitClaim {
        let claim = FitClaim(transport: AttachGatedFitTransport(inner) { await gate.mayCall() }, settle: {}, notYetPause: {})
        claim.onClaimed = { [unowned self] cols, rows in self.claimed.append("\(cols)x\(rows)") }
        claim.onRefused = { [unowned self] in self.refused += 1 }
        return claim
    }

    func testATakeAskedBeforeTheAttachIsNotSentUntilTheAttachIsAnsweredThenOnce() async {
        let gate = FakeAttachGate()
        let claim = makeClaim(gate)
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        XCTAssertEqual(inner.calls, [], "nothing leaves before the attach")
        XCTAssertEqual(gate.waiting, 1)
        XCTAssertEqual(claimed, [])
        XCTAssertEqual(refused, 0)
        gate.attach()
        await settleMainActor()
        XCTAssertEqual(inner.calls, ["own", "resize 80x24"], "the take once, then its resize")
        XCTAssertEqual(claimed, ["80x24"])
        XCTAssertEqual(refused, 0)
    }

    func testASessionAlreadyAttachedTakesAtOnce() async {
        let gate = FakeAttachGate(attached: true)
        let claim = makeClaim(gate)
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        XCTAssertEqual(inner.calls, ["own", "resize 80x24"])
        XCTAssertEqual(gate.waits, 0, "no wait at all")
        XCTAssertEqual(claimed, ["80x24"])
    }

    func testAnAttachThatNeverComesEndsAtTheCapAndTheClaimGivesUpAtItsLimit() async {
        let gate = FakeAttachGate()
        // Asked after the cap, the server still says the session is not attached.
        inner.answers = ["own": Array(repeating: .notYet, count: FitClaim.notYetLimit + 1)]
        let claim = makeClaim(gate)
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        XCTAssertEqual(inner.calls, [])
        gate.cap()
        await settleMainActor(turns: 300)
        XCTAssertEqual(gate.waits, 1, "one wait: after the cap the calls go")
        XCTAssertEqual(inner.calls.filter { $0 == "own" }.count, FitClaim.notYetLimit, "asked again, up to the limit")
        XCTAssertFalse(inner.calls.contains { $0.hasPrefix("resize") })
        XCTAssertEqual(refused, 1, "given up, and said: the chip")
        XCTAssertEqual(claimed, [])
    }

    func testAnAttachTheConnectionNeverShowsStillEndsInATakeAfterTheCap() async {
        // An older server, or an attach by a call this connection doesn't read: the wait ends
        // at its cap, the claim asks again, and that take goes out. The pane is never left
        // unclaimed without a word.
        let gate = FakeAttachGate()
        let claim = makeClaim(gate)
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        XCTAssertEqual(inner.calls, [])
        gate.cap()
        await settleMainActor()
        XCTAssertEqual(inner.calls, ["own", "resize 80x24"])
        XCTAssertEqual(claimed, ["80x24"])
        XCTAssertEqual(refused, 0)
        XCTAssertFalse(gate.attached)
    }

    func testAWaitTheDropEndsIsAskedAgainOnTheNextConnection() async {
        let gate = FakeAttachGate()
        let claim = makeClaim(gate)
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        XCTAssertEqual(gate.waiting, 1)
        // The connection drops (or the app goes to the background): the wait ends, and the
        // take the claim asks again fails unsent.
        gate.connected = false
        inner.answers = ["own": [.offline]]
        gate.cancel()
        await settleMainActor()
        XCTAssertEqual(inner.calls, ["own"], "asked again: not sent, the connection is gone")
        XCTAssertTrue(inner.waitsForConnection)
        XCTAssertEqual(refused, 0)
        // Back, as a new client: its attach is waited for.
        gate.newClient()
        gate.connected = true
        inner.connect()
        await settleMainActor()
        XCTAssertEqual(inner.calls, ["own"], "waiting for the new client's attach")
        XCTAssertEqual(gate.waiting, 1)
        gate.attach()
        await settleMainActor()
        XCTAssertEqual(inner.calls, ["own", "own", "resize 80x24"])
        XCTAssertEqual(claimed, ["80x24"])
        XCTAssertEqual(refused, 0)
    }

    func testARealRefusalAfterTheAttachStillEndsTheClaim() async {
        let gate = FakeAttachGate(attached: true)
        inner.answers = ["own": [.refused]]
        let claim = makeClaim(gate)
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        XCTAssertEqual(inner.calls, ["own", "disown"], "no resize, and what the take may have got is given back")
        XCTAssertEqual(refused, 1)
        XCTAssertEqual(claimed, [])
        XCTAssertEqual(gate.waits, 0)
    }

    func testAResizeWaitsForTheAttachToo() async {
        let gate = FakeAttachGate(attached: true)
        let claim = makeClaim(gate)
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        XCTAssertEqual(inner.calls, ["own", "resize 80x24"])
        // A new client, and the pane fits another grid before its attach is answered.
        gate.newClient()
        claim.request(cols: 60, rows: 30)
        await settleMainActor()
        XCTAssertEqual(inner.calls, ["own", "resize 80x24"], "the resize waits")
        XCTAssertEqual(gate.waiting, 1)
        gate.attach()
        await settleMainActor()
        XCTAssertEqual(inner.calls.last, "resize 60x30")
        XCTAssertEqual(inner.calls.filter { $0.hasPrefix("resize") }.count, 2)
        XCTAssertEqual(claimed.last, "60x30")
        XCTAssertEqual(refused, 0)
    }

    func testAClaimLetGoBeforeTheAttachIsHeldUntilTheWaitEndsAndDisownsOnlyIfAttached() async {
        // Connected, the session not attached yet: the disown waits at the gate, and the wait
        // (which has its cap) is all that holds a claim whose pane is gone.
        let gate = FakeAttachGate(attached: true)
        var claim: FitClaim? = makeClaim(gate)
        claim?.request(cols: 80, rows: 24)
        await settleMainActor()
        XCTAssertEqual(inner.calls, ["own", "resize 80x24"])
        gate.newClient()
        weak let gone = claim
        claim?.release()
        claim = nil
        await settleMainActor()
        XCTAssertEqual(gate.waiting, 1, "the disown waits for the attach")
        XCTAssertNotNil(gone, "held while it waits")
        gate.attach()
        await settleMainActor()
        XCTAssertEqual(inner.calls, ["own", "resize 80x24", "disown"])
        XCTAssertNil(gone)

        // The wait ends without the attach (the connection dropped, or the cap): nothing is
        // sent, then or later, and the claim goes.
        let other = FakeFitTransport()
        let closed = FakeAttachGate(attached: true)
        var second: FitClaim? = FitClaim(transport: AttachGatedFitTransport(other) { await closed.mayCall() }, settle: {}, notYetPause: {})
        second?.request(cols: 80, rows: 24)
        await settleMainActor()
        closed.newClient()
        weak let secondGone = second
        second?.release()
        second = nil
        await settleMainActor()
        XCTAssertNotNil(secondGone)
        closed.cancel()
        await settleMainActor()
        XCTAssertNil(secondGone)
        closed.attach()
        other.connect()
        await settleMainActor()
        XCTAssertEqual(other.calls, ["own", "resize 80x24"], "no disown, no take and no resize afterwards")
    }

    func testADisownWaitsForTheAttachAndIsNotSentWhenTheWaitEndsWithoutIt() async {
        let gate = FakeAttachGate(attached: true)
        let claim = makeClaim(gate)
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        gate.newClient()
        claim.release()
        await settleMainActor()
        XCTAssertFalse(inner.calls.contains("disown"), "the disown waits")
        XCTAssertEqual(gate.waiting, 1)
        gate.attach()
        await settleMainActor()
        XCTAssertEqual(inner.calls, ["own", "resize 80x24", "disown"])

        // The wait ends without the attach: nothing is sent, and nothing is asked again.
        let other = FakeFitTransport()
        let closed = FakeAttachGate(attached: true)
        let second = FitClaim(transport: AttachGatedFitTransport(other) { await closed.mayCall() }, settle: {}, notYetPause: {})
        second.request(cols: 80, rows: 24)
        await settleMainActor()
        closed.newClient()
        second.release()
        await settleMainActor()
        closed.cancel()
        await settleMainActor()
        XCTAssertEqual(other.calls, ["own", "resize 80x24"], "no disown for a client the server has not attached")
    }
}
