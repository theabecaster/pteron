import RexKit
import XCTest
@testable import RexDuo

/// Records the fit-mode calls in order and lets a test decide when each one returns.
@MainActor
final class FakeFitTransport: FitClaimTransport {
    /// Every call as it starts (`own`, `resize 80x24`, `disown`) and as it returns (`… done`).
    private(set) var log: [String] = []
    /// Calls of these kinds wait until `finish` lets them return.
    var held: Set<String> = []
    private var waiting: [(kind: String, go: CheckedContinuation<Void, Never>)] = []
    private(set) var inFlight = 0
    /// The most calls ever in flight at once: more than 1 means two calls overlapped.
    private(set) var mostInFlight = 0

    /// The calls that started, without the returns.
    var calls: [String] { log.filter { !$0.hasSuffix(" done") } }
    var waitingKinds: [String] { waiting.map(\.kind) }

    /// The answers the next calls of a kind get, in order; `done` once they run out.
    var answers: [String: [FitClaimAnswer]] = [:]
    /// Waiting for the control connection (`whenConnected`).
    private var connectWaiters: [@MainActor () -> Void] = []
    var waitsForConnection: Bool { !connectWaiters.isEmpty }

    @discardableResult
    private func call(_ kind: String, _ entry: String) async -> FitClaimAnswer {
        log.append(entry)
        inFlight += 1
        mostInFlight = max(mostInFlight, inFlight)
        if held.contains(kind) {
            await withCheckedContinuation { waiting.append((kind, $0)) }
        } else {
            await Task.yield()
        }
        inFlight -= 1
        log.append(entry + " done")
        guard var queued = answers[kind], !queued.isEmpty else { return .done }
        let answer = queued.removeFirst()
        answers[kind] = queued
        return answer
    }

    func own() async -> FitClaimAnswer { await call("own", "own") }
    func resize(cols: Int, rows: Int) async -> FitClaimAnswer { await call("resize", "resize \(cols)x\(rows)") }
    func disown() async { await call("disown", "disown") }
    func whenConnected(_ body: @escaping @MainActor () -> Void) { connectWaiters.append(body) }

    /// The control connection is back.
    func connect() {
        let all = connectWaiters
        connectWaiters = []
        for body in all { body() }
    }

    /// Lets the oldest waiting call of this kind return.
    func finish(_ kind: String) {
        guard let i = waiting.firstIndex(where: { $0.kind == kind }) else { return }
        waiting.remove(at: i).go.resume()
    }

    func finishAll() {
        let all = waiting
        waiting = []
        for w in all { w.go.resume() }
    }
}

/// Lets every task that is ready on the main actor run.
@MainActor
func settleMainActor(turns: Int = 40) async {
    for _ in 0..<turns { await Task.yield() }
}

/// Fit mode's claim: the Mac's pane must never be resized by a phone that isn't showing it.
@MainActor
final class FitClaimTests: XCTestCase {
    private let transport = FakeFitTransport()
    private var claimed: [String] = []
    private var refused = 0

    private func makeClaim(settle: @escaping @MainActor () async -> Void = {}) -> FitClaim {
        let claim = FitClaim(transport: transport, settle: settle, notYetPause: {})
        claim.onClaimed = { [unowned self] cols, rows in self.claimed.append("\(cols)x\(rows)") }
        claim.onRefused = { [unowned self] in self.refused += 1 }
        return claim
    }

    // MARK: Answers: nothing counts as claimed that the server didn't answer

    func testAClaimWhoseTakeTheConnectionLostIsNotAnsweredAndGoesOnWithATakeWhenItIsBack() async {
        // Back from the App Store: the socket died while the app was away, the take failed, and
        // the claim answered "ours" all the same; the pane stayed at the Mac's width.
        transport.answers = ["own": [.offline]]
        let claim = makeClaim()
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own"], "no resize on a connection that is gone")
        XCTAssertEqual(claimed, [], "not answered: the server never said yes")
        XCTAssertTrue(transport.waitsForConnection)
        transport.connect()
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "own", "resize 80x24"])
        XCTAssertEqual(claimed, ["80x24"])
    }

    func testAResizeTheConnectionLostIsSentAgainAfterATake() async {
        transport.answers = ["resize": [.offline]]
        let claim = makeClaim()
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 80x24"])
        XCTAssertEqual(claimed, [])
        transport.connect()
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 80x24", "own", "resize 80x24"],
                       "the pane may have passed to another client while this one was away")
        XCTAssertEqual(claimed, ["80x24"])
    }

    func testAReleaseWhileWaitingForTheConnectionSendsNoResize() async {
        transport.answers = ["own": [.offline]]
        let claim = makeClaim()
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        claim.release()
        await settleMainActor()
        transport.connect()
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "disown"], "a take that may have landed is given back, and nothing resized")
        XCTAssertEqual(claimed, [])
    }

    func testAReassertTakesThePaneAgainAndSendsTheSizeInPlace() async {
        let claim = makeClaim()
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        // The pane came back on screen, or the app came back: another client may have it.
        claim.request(cols: 80, rows: 24, reassert: true)
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 80x24", "own", "resize 80x24"])
        XCTAssertEqual(claimed, ["80x24", "80x24"])
        // A refit of a pane that stayed on screen resizes under the claim it has.
        claim.request(cols: 60, rows: 24)
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 80x24", "own", "resize 80x24", "resize 60x24"])
    }

    func testAReassertSupersededWhileItSettlesStillTakesFirst() async {
        var waiting: [CheckedContinuation<Void, Never>] = []
        let claim = makeClaim(settle: { await withCheckedContinuation { waiting.append($0) } })
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        waiting.removeFirst().resume()
        await settleMainActor()
        // Back on screen, and the keyboard moves before the layout settled.
        claim.request(cols: 80, rows: 24, reassert: true)
        claim.request(cols: 60, rows: 24)
        await settleMainActor()
        for c in waiting { c.resume() }
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 80x24", "own", "resize 60x24"])
    }

    func testARefusedTakeEndsTheClaimSaysSoAndResizesNothing() async {
        transport.answers = ["own": [.refused]]
        let claim = makeClaim()
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        XCTAssertEqual(refused, 1)
        XCTAssertEqual(claimed, [])
        XCTAssertFalse(claim.isClaiming)
        XCTAssertEqual(transport.calls, ["own", "disown"], "never a resize after a no")
    }

    func testARefusedResizeEndsTheClaimAndGivesThePaneBack() async {
        transport.answers = ["resize": [.refused]]
        let claim = makeClaim()
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        XCTAssertEqual(refused, 1)
        XCTAssertEqual(claimed, [])
        XCTAssertEqual(transport.calls, ["own", "resize 80x24", "disown"])
    }

    func testAServerFromBeforeOwnershipIsResizedOnly() async {
        transport.answers = ["own": [.unsupported]]
        let claim = makeClaim()
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 80x24"])
        XCTAssertEqual(claimed, ["80x24"])
        claim.request(cols: 80, rows: 24, reassert: true)
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 80x24", "resize 80x24"], "not asked again")
        XCTAssertEqual(refused, 0)
    }

    func testASessionNotAttachedYetIsAskedAgainThenGivenUp() async {
        transport.answers = ["own": [.notYet, .notYet]]
        let claim = makeClaim()
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "own", "own", "resize 80x24"])
        XCTAssertEqual(claimed, ["80x24"])

        let other = FakeFitTransport()
        other.answers = ["own": Array(repeating: .notYet, count: FitClaim.notYetLimit + 1)]
        let late = FitClaim(transport: other, settle: {}, notYetPause: {})
        var gaveUp = false
        late.onRefused = { gaveUp = true }
        late.request(cols: 80, rows: 24)
        await settleMainActor(turns: 200)
        XCTAssertTrue(gaveUp)
        XCTAssertEqual(other.calls.filter { $0 == "own" }.count, FitClaim.notYetLimit + 1)
        XCTAssertFalse(other.calls.contains { $0.hasPrefix("resize") })
    }

    func testAnErrorSaysWhatItMeansForTheClaim() {
        XCTAssertEqual(FitClaimAnswer(RexError.unsent("not connected")), .offline)
        XCTAssertEqual(FitClaimAnswer(RexError.local("connection lost")), .offline)
        XCTAssertEqual(FitClaimAnswer(RexError(code: "method_not_found", message: "")), .unsupported)
        XCTAssertEqual(FitClaimAnswer(RexError(code: "not_found", message: "")), .unsupported)
        XCTAssertEqual(FitClaimAnswer(RexError(code: "conflict", message: "stream is not attached")), .notYet)
        XCTAssertEqual(FitClaimAnswer(RexError(code: "forbidden", message: "")), .refused)
    }

    func testAClaimOwnsThenResizesThenAnswers() async {
        let claim = makeClaim()
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        XCTAssertEqual(transport.log, ["own", "own done", "resize 80x24", "resize 80x24 done"])
        XCTAssertEqual(claimed, ["80x24"])
        XCTAssertTrue(claim.isClaiming)
    }

    func testAReleaseDuringOwnSkipsTheResizeAndDisownsOnlyAfterOwnReturned() async {
        transport.held = ["own"]
        let claim = makeClaim()
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        XCTAssertEqual(transport.log, ["own"])

        claim.release()  // the app went to the background, or the pane closed
        await settleMainActor()
        XCTAssertEqual(transport.log, ["own"], "a disown that overtook the own would leave the pane claimed")

        transport.finish("own")
        await settleMainActor()
        XCTAssertEqual(transport.log, ["own", "own done", "disown", "disown done"])
        XCTAssertEqual(claimed, [], "a cancelled claim sends no resize and reports no size")
    }

    func testAReleaseDuringTheResizeIsFollowedByADisownAndNoAnswer() async {
        transport.held = ["resize"]
        let claim = makeClaim()
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 80x24"])
        claim.release()
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 80x24"])
        transport.finish("resize")
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 80x24", "disown"])
        XCTAssertEqual(claimed, [])
        XCTAssertFalse(claim.isClaiming)
    }

    func testAReleaseBeforeTheLayoutSettledSendsNothingAtAll() async {
        // `didBackground` with nothing claimed yet: the request still settling must die.
        var settled: CheckedContinuation<Void, Never>?
        let claim = makeClaim(settle: { await withCheckedContinuation { settled = $0 } })
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        claim.release()
        settled?.resume()
        await settleMainActor()
        XCTAssertEqual(transport.log, [])
        XCTAssertEqual(claimed, [])
    }

    func testOnlyTheNewestRequestSurvivesTheSettleDelay() async {
        var waiting: [CheckedContinuation<Void, Never>] = []
        let claim = makeClaim(settle: { await withCheckedContinuation { waiting.append($0) } })
        claim.request(cols: 80, rows: 24)
        claim.request(cols: 60, rows: 30)
        claim.request(cols: 50, rows: 40)
        await settleMainActor()
        // Out of order, as timers may fire.
        for c in waiting.reversed() { c.resume() }
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 50x40"])
        XCTAssertEqual(claimed, ["50x40"])
    }

    func testANewSizeDuringAResizeIsOneMoreResizeAndOneOwn() async {
        transport.held = ["resize"]
        let claim = makeClaim()
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        claim.request(cols: 60, rows: 30)
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 80x24"], "one call at a time")
        transport.finish("resize")
        await settleMainActor()
        transport.finish("resize")
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 80x24", "resize 60x30"])
        XCTAssertEqual(claimed, ["60x30"], "the size that was replaced is never reported")
    }

    func testNoResizeEverFollowsARelease() async {
        let claim = makeClaim()
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        claim.release()
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 80x24", "disown"])
        claim.release()
        await settleMainActor()
        XCTAssertEqual(transport.calls.count, 3, "nothing owned, nothing to give back")

        // Back in the foreground: a whole new claim.
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 80x24", "disown", "own", "resize 80x24"])
        XCTAssertEqual(claimed, ["80x24", "80x24"])
    }

    func testTheSameSizeAgainSendsNothingButStillAnswers() async {
        let claim = makeClaim()
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        claim.request(cols: 80, rows: 24)  // the host asks again to redraw from the server
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 80x24"])
        XCTAssertEqual(claimed, ["80x24", "80x24"])
    }

    // MARK: A size the server already has (`FitResize`)

    /// A claim at 60x30 that the server has answered, as a full-screen program's pane has with
    /// the keyboard up.
    private func claimInPlace() async -> FitClaim {
        let claim = makeClaim()
        claim.request(cols: 60, rows: 30)
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 60x30"])
        return claim
    }

    func testAReturnAtTheSizeTheServerReportsTakesThePaneAndSendsNoResize() async {
        // Every return to a fitted full-screen pane sent the size it had again: one resize per
        // visit, and the pane's fence waited for it.
        let claim = await claimInPlace()
        claim.reported = { (60, 30) }
        claim.request(cols: 60, rows: 30, reassert: true)
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 60x30", "own"], "the take, and no resize")
        XCTAssertEqual(claimed, ["60x30", "60x30"], "the request is still answered")
    }

    func testASizeAnotherClientSetIsResizedBackOnTheReturn() async {
        let claim = await claimInPlace()
        claim.reported = { (211, 57) }  // the Mac resized the pane meanwhile
        claim.request(cols: 60, rows: 30, reassert: true)
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 60x30", "own", "resize 60x30"])
    }

    func testAKeyboardThatChangedWhileThePaneWasAwayIsResizedFor() async {
        // Left with the keyboard up (30 rows), back with it down: the grid that fits is another.
        let claim = await claimInPlace()
        claim.reported = { (60, 30) }
        claim.request(cols: 60, rows: 53, reassert: true)
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 60x30", "own", "resize 60x53"])
    }

    func testAFoldOrARotationIsResizedFor() async {
        let claim = await claimInPlace()
        claim.reported = { (60, 30) }
        claim.request(cols: 120, rows: 40)  // the pane stayed on screen and got another shape
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 60x30", "resize 120x40"])
    }

    func testAnotherFontSizeIsResizedFor() async {
        let claim = await claimInPlace()
        claim.reported = { (60, 30) }
        claim.request(cols: 50, rows: 25)  // bigger cells: fewer fit
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 60x30", "resize 50x25"])
    }

    func testWithNoWordFromTheServerTheResizeIsSent() async {
        // A parked pane's stream is down as it comes back: it may have missed a resize.
        let claim = await claimInPlace()
        claim.reported = { nil }
        claim.request(cols: 60, rows: 30, reassert: true)
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 60x30", "own", "resize 60x30"])
    }

    func testAResizeLeftOutIsSentAfterAllWhenTheServerSaysAnotherSize() async {
        let claim = await claimInPlace()
        claim.reported = { (60, 30) }
        claim.request(cols: 60, rows: 30, reassert: true)
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 60x30", "own"])
        // The size it reports again changes nothing.
        XCTAssertFalse(claim.serverReported(cols: 60, rows: 30))
        // The take gave the pane a size the server had kept: the pane must end at the one wanted.
        claim.reported = { (211, 57) }
        XCTAssertTrue(claim.serverReported(cols: 211, rows: 57))
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 60x30", "own", "resize 60x30"])
        XCTAssertEqual(claimed, ["60x30", "60x30", "60x30"])
        // After a resize that was sent, a report is the host's to judge, not the claim's.
        XCTAssertFalse(claim.serverReported(cols: 211, rows: 57))
        await settleMainActor()
        XCTAssertEqual(transport.calls.count, 4)
    }

    func testAResizeGoesOutUnlessTheServersLatestWordIsTheTarget() {
        XCTAssertFalse(FitResize.sends(target: (60, 30), reported: (60, 30)))
        XCTAssertTrue(FitResize.sends(target: (60, 30), reported: (60, 53)), "rows differ")
        XCTAssertTrue(FitResize.sends(target: (60, 30), reported: (80, 30)), "columns differ")
        XCTAssertTrue(FitResize.sends(target: (60, 30), reported: nil), "no word")
        XCTAssertNil(FitResize.reported((60, 30), said: false, live: true), "a fresh stream has not said its size yet")
        XCTAssertNil(FitResize.reported((60, 30), said: true, live: false), "a stream that is down may have missed a resize")
        XCTAssertTrue(FitResize.reported((60, 30), said: true, live: true).map { $0 == (60, 30) } ?? false)
        XCTAssertTrue(FitResize.sendsAfterAll(target: (60, 30), reported: (211, 57), leftOut: true))
        XCTAssertFalse(FitResize.sendsAfterAll(target: (60, 30), reported: (60, 30), leftOut: true))
        XCTAssertFalse(FitResize.sendsAfterAll(target: (60, 30), reported: (211, 57), leftOut: false))
    }

    func testAPaneOffScreenStartsNothingNew() async {
        // A size in place stays while a fold moves the pane.
        let claim = makeClaim()
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        claim.request(cols: 40, rows: 10)
        claim.pause()
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 80x24"], "the request that was settling is dropped")
        XCTAssertTrue(claim.isClaiming)

        // A first claim that hasn't resized yet is given up.
        let other = FakeFitTransport()
        other.held = ["own"]
        let fresh = FitClaim(transport: other, settle: {})
        fresh.request(cols: 80, rows: 24)
        await settleMainActor()
        fresh.pause()
        other.finish("own")
        await settleMainActor()
        XCTAssertEqual(other.calls, ["own", "disown"])
    }

    func testAPaneAnotherClientTookLeavesTheLineAndIsTakenAgainOnATap() async {
        let claim = makeClaim()
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        claim.lost()
        await settleMainActor()
        // A disown from a client that isn't the owner changes nothing for the owner; it only
        // keeps the pane from passing back to this phone when the owner gives it up.
        XCTAssertEqual(transport.calls, ["own", "resize 80x24", "disown"])
        // "Tap to fit here": owned again.
        claim.request(cols: 80, rows: 24, reassert: true)
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 80x24", "disown", "own", "resize 80x24"])
    }

    /// Requests, releases and pauses at every point of calls that return in any order: the
    /// calls never overlap, a disown never starts before the own it undoes has returned, no
    /// resize starts after the last release, and a claim that ends released ends disowned.
    func testAdversarialTimingKeepsTheCallsInOrder() async {
        var generator = SystemRandomNumberGenerator()
        for round in 0..<60 {
            let transport = FakeFitTransport()
            transport.held = ["own", "resize", "disown"]
            let claim = FitClaim(transport: transport, settle: { await Task.yield() })
            var events: [String] = []
            for _ in 0..<Int.random(in: 4...14, using: &generator) {
                switch Int.random(in: 0..<6, using: &generator) {
                case 0, 1:
                    let cols = Int.random(in: 20...22, using: &generator)
                    claim.request(cols: cols, rows: 10)
                    events.append("request \(cols)")
                case 2:
                    claim.release()
                    events.append("release@\(transport.calls.count)")
                case 3:
                    claim.pause()
                    events.append("pause")
                default:
                    if let kind = transport.waitingKinds.randomElement(using: &generator) { transport.finish(kind) }
                    events.append("finish")
                }
                await settleMainActor(turns: Int.random(in: 0...6, using: &generator))
            }
            claim.release()
            let callsAtRelease = transport.calls.count
            for _ in 0..<12 {
                transport.finishAll()
                await settleMainActor()
            }

            let context = "round \(round): \(events) -> \(transport.log)"
            XCTAssertEqual(transport.mostInFlight <= 1, true, "calls overlapped. " + context)
            XCTAssertFalse(transport.calls.dropFirst(callsAtRelease).contains { $0.hasPrefix("resize") },
                           "a resize started after the last release. " + context)
            // Own and disown alternate, starting with own and ending disowned.
            let ownership = transport.calls.filter { $0 == "own" || $0 == "disown" }
            for (i, call) in ownership.enumerated() { XCTAssertEqual(call, i % 2 == 0 ? "own" : "disown", context) }
            XCTAssertEqual(ownership.count % 2, 0, "left owned. " + context)
            // Every resize happens while owned.
            var owned = false
            for call in transport.calls {
                if call == "own" { owned = true } else if call == "disown" { owned = false } else { XCTAssertTrue(owned, context) }
            }
            XCTAssertFalse(claim.isClaiming)
        }
    }

    // MARK: The host

    private func makeHost(sizing: SizingMode = .fit) -> (TerminalHost, UIWindow) {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = TerminalStream(control: control, sessionID: "s", blockID: "b")
        let host = TerminalHost(stream: stream, sizing: sizing, fontSize: 12, theme: ThemeStore.fallback,
                                claim: FitClaim(transport: transport, settle: {}))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        host.frame = window.bounds
        window.addSubview(host)
        window.isHidden = false
        host.layoutIfNeeded()
        return (host, window)
    }

    func testTheHostClaimsTheGridThatFitsAndBackgroundingDuringTheClaimSendsNoResize() async {
        // The claim never completes in this test, so the host never starts its stream.
        transport.held = ["own", "resize"]
        let (host, window) = makeHost()
        defer { window.isHidden = true }
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own"])

        // Nothing is claimed yet (`claimedSize` is nil): the background must still stop the claim.
        NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        transport.finish("own")
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "disown"])
        XCTAssertFalse(transport.calls.contains { $0.hasPrefix("resize") })
        host.removeFromSuperview()
        host.stop()
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        transport.finishAll()
    }

    func testStoppingOrLeavingTheScreenDuringAClaimSendsNoResize() async {
        for leave in ["stop", "window"] {
            let transport = FakeFitTransport()
            transport.held = ["own", "resize"]
            let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
            let host = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: "b"), sizing: .fit,
                                    fontSize: 12, theme: ThemeStore.fallback,
                                    claim: FitClaim(transport: transport, settle: {}))
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
            host.frame = window.bounds
            window.addSubview(host)
            window.isHidden = false
            host.layoutIfNeeded()
            await settleMainActor()
            XCTAssertEqual(transport.calls, ["own"], leave)

            if leave == "stop" {
                // Off screen first, as the pool does: a host in a window lays out and claims again.
                host.removeFromSuperview()
                host.stop()
            } else {
                host.removeFromSuperview()  // the pane was swiped away or closed
            }
            transport.finish("own")
            await settleMainActor()
            XCTAssertEqual(transport.calls, ["own", "disown"], leave)
            host.stop()
            window.isHidden = true
        }
    }
}

/// A snapshot is collected without doubling storage, capped for a phone, and freed when unused.
final class SnapshotBufferTests: XCTestCase {
    private func append(_ buffer: inout SnapshotBuffer, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBufferPointer { buffer.append($0) }
    }

    func testThePartsComeBackAsOneArrayInOrder() {
        var buffer = SnapshotBuffer(limit: 1 << 20, blockSize: 1000)
        var want: [UInt8] = []
        for i in 0..<37 {
            let part = [UInt8](repeating: UInt8(i), count: 1 + i * 53)
            want += part
            XCTAssertTrue(append(&buffer, part))
        }
        XCTAssertEqual(buffer.count, want.count)
        XCTAssertEqual(buffer.take(), want)
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.capacity, 0, "nothing is kept after the hand-over")
        XCTAssertEqual(buffer.take(), [])
    }

    func testStorageNeverGrowsFarPastWhatItHolds() {
        // Appending in small chunks to 4 MiB: an array that doubles would hold up to 8 MiB,
        // and 12 MiB while it moves. Blocks stay within one block of the content.
        var buffer = SnapshotBuffer()
        let chunk = [UInt8](repeating: 7, count: 1800)
        var most = 0
        while buffer.count < 4 << 20 {
            XCTAssertTrue(append(&buffer, chunk))
            most = max(most, buffer.capacity - buffer.count)
        }
        XCTAssertLessThanOrEqual(most, SnapshotBuffer.blockSize + 64 << 10)
        let total = buffer.count
        XCTAssertEqual(buffer.take().count, total)
    }

    func testASmallSnapshotIsHandedOverWithoutACopy() {
        var buffer = SnapshotBuffer()
        XCTAssertTrue(append(&buffer, Array("GHOSTSNP".utf8)))
        XCTAssertLessThanOrEqual(buffer.capacity, 64 << 10, "a small snapshot doesn't reserve a whole block")
        XCTAssertEqual(buffer.take(), Array("GHOSTSNP".utf8))
    }

    func testPastTheLimitItRefusesAndFreesWhatItHeld() {
        var buffer = SnapshotBuffer(limit: 10_000, blockSize: 4096)
        XCTAssertTrue(append(&buffer, [UInt8](repeating: 1, count: 9000)))
        XCTAssertFalse(append(&buffer, [UInt8](repeating: 1, count: 1001)))
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.capacity, 0)
        // The limit for a phone is far below the stream filter's.
        XCTAssertLessThanOrEqual(SnapshotBuffer.limit, 16 << 20)
        XCTAssertLessThanOrEqual(SnapshotBuffer.limit, APCFilter.defaultSnapshotLimit)
    }

    func testResetFreesAPartialSnapshot() {
        var buffer = SnapshotBuffer()
        XCTAssertTrue(append(&buffer, [UInt8](repeating: 1, count: 600_000)))
        XCTAssertGreaterThan(buffer.capacity, 0)
        buffer.reset()
        XCTAssertEqual(buffer.capacity, 0)
        XCTAssertEqual(buffer.count, 0)
    }
}
