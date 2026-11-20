import Foundation
import XCTest
@testable import RexKit

/// A tunnel data connection that a test plays the server's side of.
final class FakeTunnelSocket: TunnelSocket, @unchecked Sendable {
    // `@unchecked`: every var is only touched under `lock`.
    private let lock = NSLock()
    private var inbox: [Result<Data?, Error>] = []
    private var waiter: CheckedContinuation<Data?, Error>?
    private(set) var sentMessages: [Data] = []
    private(set) var closedClean = false
    private(set) var aborted = false
    private(set) var pings = 0
    private var code = 0
    /// Each send waits this long, so a test can see backpressure.
    var sendDelay: Duration = .zero
    var inFlight = 0
    var maxInFlight = 0

    var sent: [Data] { lock.withLock { sentMessages } }
    var closeCode: Int { lock.withLock { code } }

    /// The server sends a message (empty: its end of data).
    func push(_ d: Data) { deliver(.success(d)) }
    /// The server closes with a status.
    func serverClose(_ status: Int) {
        lock.withLock { code = status }
        deliver(.failure(URLError(.networkConnectionLost)))
    }

    private func deliver(_ r: Result<Data?, Error>) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(with: r)
        } else {
            inbox.append(r)
            lock.unlock()
        }
    }

    func send(_ data: Data) async throws {
        lock.withLock {
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
        }
        if sendDelay > .zero { try? await Task.sleep(for: sendDelay) }
        lock.withLock {
            inFlight -= 1
            sentMessages.append(data)
        }
        if lock.withLock({ aborted }) { throw URLError(.cancelled) }
    }

    func receive() async throws -> Data? {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if !inbox.isEmpty {
                let r = inbox.removeFirst()
                lock.unlock()
                c.resume(with: r)
            } else {
                waiter = c
                lock.unlock()
            }
        }
    }

    func ping() async throws { lock.withLock { pings += 1 } }

    func close() {
        lock.withLock {
            closedClean = true
            code = 1000
        }
        deliver(.failure(URLError(.cancelled)))
    }

    func abort() {
        lock.withLock { aborted = true }
        deliver(.failure(URLError(.cancelled)))
    }
}

/// A browser connection a test plays.
final class FakeTunnelLocal: TunnelLocal, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Data?] = []
    private var waiter: CheckedContinuation<Data?, Error>?
    private(set) var written: [Data] = []
    private(set) var finished = false
    private(set) var closed = false
    private(set) var wasReset = false
    private var readSoFar: [Data] = []
    private var answered = false

    var writes: [Data] { lock.withLock { written } }
    var didFinish: Bool { lock.withLock { finished } }
    var didClose: Bool { lock.withLock { closed } }
    var didReset: Bool { lock.withLock { wasReset } }

    /// The browser sends bytes; nil is its end of data.
    func push(_ d: Data?) {
        lock.lock()
        if let w = waiter {
            waiter = nil
            lock.unlock()
            w.resume(returning: d)
        } else {
            inbox.append(d)
            lock.unlock()
        }
    }

    func read(max: Int) async throws -> Data? {
        // A cancelled read (the relay ended) loses nothing: it gives its turn up, as the real one does.
        let d: Data? = try await withTaskCancellationHandler { try await waitRead(max) } onCancel: {
            let w = lock.withLock { () -> CheckedContinuation<Data?, Error>? in
                defer { waiter = nil }
                return waiter
            }
            w?.resume(throwing: CancellationError())
        }
        if let d { lock.withLock { readSoFar.append(d) } }
        return d
    }

    private func waitRead(_ max: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if wasReset || Task.isCancelled { lock.unlock(); return c.resume(throwing: URLError(.cancelled)) }
            if !inbox.isEmpty {
                let d = inbox.removeFirst()
                lock.unlock()
                c.resume(returning: d.map { $0.prefix(max) })
            } else {
                waiter = c
                lock.unlock()
            }
        }
    }

    func write(_ data: Data) async throws { lock.withLock { written.append(data); answered = true } }
    func finishWriting() { lock.withLock { finished = true } }
    func close() { lock.withLock { closed = true } }

    func reset() {
        lock.lock()
        wasReset = true
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(throwing: URLError(.cancelled))
    }

    func rewind() -> Bool {
        lock.withLock {
            guard !answered else { return false }
            inbox = readSoFar.map { Optional($0) } + inbox
            readSoFar = []
            return true
        }
    }
}

final class TunnelRelayTests: XCTestCase {
    private func relay(_ s: FakeTunnelSocket, _ l: FakeTunnelLocal,
                       sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }) -> TunnelRelay {
        TunnelRelay(socket: s, local: l, sleep: sleep)
    }

    func testBytesGoBothWaysAndTheCleanEndClosesWith1000() async {
        let s = FakeTunnelSocket(), l = FakeTunnelLocal()
        let r = relay(s, l)
        async let end = r.run()
        l.push(Data("GET / HTTP/1.1\r\n\r\n".utf8))
        s.push(Data("HTTP/1.1 200 OK\r\n\r\nhi".utf8))
        // The browser ends, then the server: only then does the socket close.
        l.push(nil)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(s.closedClean, "the server's end hasn't come yet")
        s.push(Data())
        let e = await end
        XCTAssertEqual(e, .clean)
        XCTAssertEqual(s.sent, [Data("GET / HTTP/1.1\r\n\r\n".utf8), Data()], "one empty message at the browser's end")
        XCTAssertEqual(l.writes, [Data("HTTP/1.1 200 OK\r\n\r\nhi".utf8)])
        XCTAssertTrue(l.didFinish, "the server's empty message half-closes the browser's side")
        XCTAssertTrue(l.didClose)
        XCTAssertTrue(s.closedClean)
        XCTAssertFalse(l.didReset)
    }

    func testTheServerMayEndFirst() async {
        let s = FakeTunnelSocket(), l = FakeTunnelLocal()
        let r = relay(s, l)
        async let end = r.run()
        s.push(Data("x".utf8))
        s.push(Data())
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(l.didFinish)
        XCTAssertFalse(s.closedClean, "half-closed: the browser may still send")
        l.push(Data("late".utf8))
        l.push(nil)
        let e = await end
        XCTAssertEqual(e, .clean)
        XCTAssertEqual(s.sent, [Data("late".utf8), Data()])
    }

    func testChunksAreAtMost64KiBAndEachWaitsForTheSendBefore() async {
        let s = FakeTunnelSocket(), l = FakeTunnelLocal()
        s.sendDelay = .milliseconds(5)
        let r = relay(s, l)
        async let end = r.run()
        l.push(Data(count: 200_000))
        l.push(Data(count: 10))
        l.push(nil)
        s.push(Data())
        _ = await end
        XCTAssertTrue(s.sent.allSatisfy { $0.count <= TunnelRelay.chunk })
        XCTAssertEqual(s.sent.first?.count, 65_536)
        XCTAssertEqual(s.maxInFlight, 1, "the next read waits for the send")
    }

    func testARefusedTargetIs1001WithNoBytes() async {
        let s = FakeTunnelSocket(), l = FakeTunnelLocal()
        let r = relay(s, l)
        async let end = r.run()
        s.serverClose(1001)
        let e = await end
        XCTAssertEqual(e, .refused)
        XCTAssertTrue(l.didReset, "the browser sees a reset, not an empty page")
    }

    func testA1001AfterBytesIsALoss() {
        XCTAssertEqual(TunnelRelay.end(code: 1001, received: 10), .lost(code: 1001))
        XCTAssertEqual(TunnelRelay.end(code: 4000, received: 0), .blockClosed)
        XCTAssertEqual(TunnelRelay.end(code: 4006, received: 0), .ownerLost(beforeAnyByte: true))
        XCTAssertEqual(TunnelRelay.end(code: 4006, received: 3), .ownerLost(beforeAnyByte: false))
        XCTAssertEqual(TunnelRelay.end(code: 4321, received: 0), .lost(code: 4321), "an unknown status is a reset")
    }

    func testAClosedBlockResetsTheBrowser() async {
        let s = FakeTunnelSocket(), l = FakeTunnelLocal()
        let r = relay(s, l)
        async let end = r.run()
        s.push(Data("partial".utf8))
        try? await Task.sleep(for: .milliseconds(20))
        s.serverClose(4000)
        let e = await end
        XCTAssertEqual(e, .blockClosed)
        XCTAssertTrue(l.didReset)
    }

    func testOwnerLostBeforeAnyByteLeavesTheBrowserForARetry() async {
        let s = FakeTunnelSocket(), l = FakeTunnelLocal()
        let r = relay(s, l)
        async let end = r.run()
        l.push(Data("GET /".utf8))
        try? await Task.sleep(for: .milliseconds(20))
        s.serverClose(4006)
        let e = await end
        XCTAssertEqual(e, .ownerLost(beforeAnyByte: true))
        XCTAssertFalse(l.didReset, "the caller sends the request again on a new block")
        XCTAssertTrue(l.rewind())

        // The same request goes out again, whole, on the next relay.
        let s2 = FakeTunnelSocket()
        let r2 = relay(s2, l)
        async let end2 = r2.run()
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(s2.sent.first, Data("GET /".utf8))
        s2.push(Data("ok".utf8))
        l.push(nil)
        s2.push(Data())
        let e2 = await end2
        XCTAssertEqual(e2, .clean)
    }

    func testCancelResetsBoth() async {
        let s = FakeTunnelSocket(), l = FakeTunnelLocal()
        let r = relay(s, l)
        async let end = r.run()
        try? await Task.sleep(for: .milliseconds(20))
        r.cancel()
        let e = await end
        XCTAssertEqual(e, .cancelled)
        XCTAssertTrue(l.didReset)
        XCTAssertTrue(s.aborted)
        XCTAssertFalse(s.closedClean, "a cancel is a reset on the server, never a clean close")
    }

    func testPingsEvery25Seconds() async {
        let s = FakeTunnelSocket(), l = FakeTunnelLocal()
        let asked = AsyncStream<Duration>.makeStream()
        let clock = TickClock(asked: asked.continuation)
        let r = relay(s, l, sleep: { try await clock.sleep($0) })
        async let end = r.run()
        var it = asked.stream.makeAsyncIterator()
        for _ in 0..<3 {
            let d = await it.next()
            XCTAssertEqual(d, .seconds(25))
            clock.tick()
        }
        _ = await it.next()
        XCTAssertEqual(s.pings, 3)
        l.push(nil)
        s.push(Data())
        _ = await end
    }
}

/// A clock a test moves by hand: each sleep says how long it asked for, then waits for `tick`.
final class TickClock: @unchecked Sendable {
    // `@unchecked`: `waiter` and `pending` are only touched under `lock`.
    private let asked: AsyncStream<Duration>.Continuation
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var pending = 0

    init(asked: AsyncStream<Duration>.Continuation) { self.asked = asked }

    func tick() {
        let w = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            if let w = waiter { waiter = nil; return w }
            pending += 1
            return nil
        }
        w?.resume()
    }

    func sleep(_ d: Duration) async throws {
        asked.yield(d)
        await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                lock.lock()
                if pending > 0 || Task.isCancelled {
                    pending = max(0, pending - 1)
                    lock.unlock()
                    c.resume()
                } else {
                    waiter = c
                    lock.unlock()
                }
            }
        } onCancel: { self.tick() }
        try Task.checkCancellation()
    }
}
