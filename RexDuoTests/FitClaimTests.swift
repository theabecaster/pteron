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

    private func call(_ kind: String, _ entry: String) async {
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
    }

    func own() async { await call("own", "own") }
    func resize(cols: Int, rows: Int) async { await call("resize", "resize \(cols)x\(rows)") }
    func disown() async { await call("disown", "disown") }

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

    private func makeClaim(settle: @escaping @MainActor () async -> Void = {}) -> FitClaim {
        let claim = FitClaim(transport: transport, settle: settle)
        claim.onClaimed = { [unowned self] cols, rows in self.claimed.append("\(cols)x\(rows)") }
        return claim
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

    func testAPaneAnotherClientTookIsNotGivenBack() async {
        let claim = makeClaim()
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        claim.lost()
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 80x24"], "not ours to disown")
        // "Tap to fit here": owned again.
        claim.request(cols: 80, rows: 24)
        await settleMainActor()
        XCTAssertEqual(transport.calls, ["own", "resize 80x24", "own", "resize 80x24"])
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
