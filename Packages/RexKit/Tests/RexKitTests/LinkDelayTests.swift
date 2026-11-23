import XCTest
@testable import RexKit

/// The simulated round trip (`LinkDelay`, `DelayedStreamSocket`): what it adds, and that it
/// delays without reordering or losing anything.
@MainActor
final class LinkDelayTests: XCTestCase {
    /// The waits a delayed socket asked for, skipped.
    private final class Waits {
        var asked: [Duration] = []
        /// The time the socket sees; it stands still unless a test moves it.
        var time = ContinuousClock.now
    }

    private func socket(_ plan: FakeLink.SocketPlan = .welcome(), roundTrip: Duration = .milliseconds(100))
        -> (DelayedStreamSocket, FakeSocket, Waits) {
        let inner = FakeSocket(plan)
        let waits = Waits()
        let s = DelayedStreamSocket(inner, delay: LinkDelay(roundTrip: roundTrip), sleep: { d in
            waits.asked.append(d)
            await Task.yield()
        }, now: { waits.time })
        return (s, inner, waits)
    }

    func testNoDelayIsZero() {
        XCTAssertTrue(LinkDelay.none.isZero)
        XCTAssertFalse(LinkDelay(roundTrip: .milliseconds(1)).isZero)
    }

    /// A socket opened ahead of its first message (`EarlySocket`) has that much of its opening
    /// behind it: the message waits for the rest, and never less than its own way there.
    func testAFirstMessageThatComesLaterWaitsOnlyForTheRestOfTheOpening() async throws {
        let (s, _, waits) = socket()
        waits.time += .milliseconds(200)
        try await s.send(Data([1]))
        XCTAssertEqual(waits.asked, [.milliseconds(150)], "100 ms of the opening left, then one way")

        let (late, _, lateWaits) = socket()
        lateWaits.time += .seconds(2)
        try await late.send(Data([1]))
        XCTAssertEqual(lateWaits.asked, [.milliseconds(50)], "open long since: one way")
    }

    func testTheFirstMessageWaitsForTheConnectionAndOneWay() async throws {
        let (s, inner, waits) = socket()
        try await s.send(Data([1]))
        // TCP, TLS and the upgrade, then the message's own trip.
        XCTAssertEqual(waits.asked, [.milliseconds(350)])
        try await s.send(Data([2]))
        XCTAssertEqual(waits.asked, [.milliseconds(350), .milliseconds(50)])
        XCTAssertEqual(inner.sent, [[1], [2]])
    }

    func testMessagesArriveInOrderEachOnce() async throws {
        let (s, inner, _) = socket(.silent)
        for i in 0..<200 { inner.push([UInt8(i)]) }
        var got: [UInt8] = []
        for _ in 0..<200 {
            let d = try await s.receive()
            got.append(d?.first ?? 255)
        }
        XCTAssertEqual(got, (0..<200).map { UInt8($0) })
    }

    func testABurstIsNotSpreadOut() async throws {
        // Each message is due one way after it arrived, so ten that arrived together take one
        // trip, not ten. The test's own clock: a wait moves it on by exactly what was asked.
        final class Time { var now = ContinuousClock.now }
        let time = Time(), waits = Waits()
        let inner = FakeSocket(.silent)
        let s = DelayedStreamSocket(inner, delay: LinkDelay(roundTrip: .milliseconds(60)), sleep: { d in
            waits.asked.append(d)
            time.now += d
            await Task.yield()
        }, now: { time.now })
        for i in 0..<10 { inner.push([UInt8(i)]) }
        // All ten are in and stamped before the first is taken.
        var got: [UInt8] = []
        let first = try await s.receive()
        got.append(first?.first ?? 255)
        for _ in 0..<50 { await Task.yield() }
        let start = time.now
        for _ in 1..<10 { got.append(try await s.receive()?.first ?? 255) }
        XCTAssertEqual(got, (0..<10).map { UInt8($0) })
        XCTAssertEqual(waits.asked.first, .milliseconds(30), "the first waits its one way")
        // The nine behind it arrived while it waited or just after: together under one more trip.
        XCTAssertLessThanOrEqual(time.now - start, .milliseconds(30))
        XCTAssertLessThanOrEqual(waits.asked.reduce(.zero, +), .milliseconds(60), "one trip, not ten")
    }

    func testAFailureComesAfterTheMessagesBeforeIt() async throws {
        let (s, inner, _) = socket(.silent)
        inner.push([7])
        inner.drop(code: 4000)
        let first = try await s.receive()
        XCTAssertEqual(first?.first, 7)
        do {
            _ = try await s.receive()
            XCTFail("the drop was lost")
        } catch {}
        XCTAssertEqual(s.closeCode, 4000)
    }

    func testItReadsAheadOnlySoFar() async throws {
        let (s, inner, _) = socket(.silent)
        for i in 0..<200 { inner.push([UInt8(i % 250)]) }
        _ = try await s.receive()
        await settle()
        // One taken, and no more than the read-ahead waiting; the rest is still the socket's.
        XCTAssertLessThanOrEqual(inner.receives, DelayedStreamSocket.readAhead + 2)
    }

    func testCloseAndAbortReachTheSocket() async {
        let (s, inner, _) = socket(.silent)
        s.abort()
        XCTAssertTrue(inner.aborted)
        s.close()
        XCTAssertTrue(inner.closed)
    }

    func testAPingTakesARoundTrip() async throws {
        let (s, inner, waits) = socket(.silent)
        try await s.ping()
        XCTAssertEqual(waits.asked, [.milliseconds(100)])
        XCTAssertEqual(inner.pings, 1)
    }
}
