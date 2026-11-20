import XCTest
@testable import RexKit

/// The simulated round trip (`LinkDelay`, `DelayedStreamSocket`): what it adds, and that it
/// delays without reordering or losing anything.
@MainActor
final class LinkDelayTests: XCTestCase {
    /// The waits a delayed socket asked for, skipped.
    private final class Waits {
        var asked: [Duration] = []
    }

    private func socket(_ plan: FakeLink.SocketPlan = .welcome(), roundTrip: Duration = .milliseconds(100))
        -> (DelayedStreamSocket, FakeSocket, Waits) {
        let inner = FakeSocket(plan)
        let waits = Waits()
        let s = DelayedStreamSocket(inner, delay: LinkDelay(roundTrip: roundTrip)) { d in
            waits.asked.append(d)
            await Task.yield()
        }
        return (s, inner, waits)
    }

    func testNoDelayIsZero() {
        XCTAssertTrue(LinkDelay.none.isZero)
        XCTAssertFalse(LinkDelay(roundTrip: .milliseconds(1)).isZero)
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
        // Real waits here: each message is due one way after it arrived, so ten that arrived
        // together take about one trip, not ten.
        let inner = FakeSocket(.silent)
        let s = DelayedStreamSocket(inner, delay: LinkDelay(roundTrip: .milliseconds(60)))
        for i in 0..<10 { inner.push([UInt8(i)]) }
        let start = ContinuousClock.now
        for _ in 0..<10 { _ = try await s.receive() }
        let took = ContinuousClock.now - start
        XCTAssertGreaterThanOrEqual(took, .milliseconds(25))
        XCTAssertLessThan(took, .milliseconds(150))
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
