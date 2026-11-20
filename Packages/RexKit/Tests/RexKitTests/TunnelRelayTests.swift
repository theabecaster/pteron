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
    private var sentWaiters: [(count: Int, done: CheckedContinuation<Void, Never>)] = []
    private var held: CheckedContinuation<Void, Error>?
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []
    /// Each send waits this long, so a test can see backpressure.
    var sendDelay: Duration = .zero
    /// Sends from this one on (0 is the first) wait for `releaseSend`, or end when their task
    /// is cancelled.
    var holdFrom = Int.max
    var inFlight = 0
    var maxInFlight = 0

    var sent: [Data] { lock.withLock { sentMessages } }
    var closeCode: Int { lock.withLock { code } }

    /// The server sends a message (empty: its end of data).
    func push(_ d: Data) { deliver(.success(d)) }
    /// The server closes with a status. `receiveFails` false: only a send sees it at first, and
    /// the receive fails once the relay lets the socket go.
    func serverClose(_ status: Int, receiveFails: Bool = true) {
        lock.withLock { code = status }
        if receiveFails { deliver(.failure(URLError(.networkConnectionLost))) }
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
        let hold = lock.withLock { () -> Bool in
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            return sentMessages.count >= holdFrom
        }
        if sendDelay > .zero { try? await Task.sleep(for: sendDelay) }
        do {
            if hold { try await waitHeld() }
            // A closed task's send fails, as URLSession's does: the message never goes.
            if lock.withLock({ code != 0 }) { throw URLError(.networkConnectionLost) }
        } catch {
            lock.withLock { inFlight -= 1 }
            throw error
        }
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            inFlight -= 1
            sentMessages.append(data)
            let n = sentMessages.count
            defer { sentWaiters.removeAll { $0.count <= n } }
            return sentWaiters.filter { $0.count <= n }.map(\.done)
        }
        ready.forEach { $0.resume() }
        if lock.withLock({ aborted }) { throw URLError(.cancelled) }
    }

    private func waitHeld() async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled { lock.unlock(); return c.resume(throwing: CancellationError()) }
                held = c
                let waiting = heldWaiters
                heldWaiters = []
                lock.unlock()
                waiting.forEach { $0.resume() }
            }
        } onCancel: {
            let c = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                defer { held = nil }
                return held
            }
            c?.resume(throwing: CancellationError())
        }
    }

    /// Returns once a send is held.
    func untilHeld() async {
        await withCheckedContinuation { c in
            lock.lock()
            if held != nil {
                lock.unlock()
                c.resume()
            } else {
                heldWaiters.append(c)
                lock.unlock()
            }
        }
    }

    /// Lets the held send go on.
    func releaseSend() {
        let c = lock.withLock { () -> CheckedContinuation<Void, Error>? in
            defer { held = nil }
            return held
        }
        c?.resume()
    }

    /// Returns once the relay has sent `count` messages.
    func untilSent(_ count: Int) async {
        await withCheckedContinuation { c in
            lock.lock()
            if sentMessages.count >= count {
                lock.unlock()
                c.resume()
            } else {
                sentWaiters.append((count, c))
                lock.unlock()
            }
        }
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
    private var waiter: (done: CheckedContinuation<Data?, Error>, max: Int)?
    private var readingWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var written: [Data] = []
    private(set) var finished = false
    private(set) var closed = false
    private(set) var wasReset = false
    private var readSoFar: [Data] = []
    private var readEnd = false
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
            let next = take(d, max: w.max)
            lock.unlock()
            w.done.resume(returning: next)
        } else {
            inbox.append(d)
            lock.unlock()
        }
    }

    /// Returns once a read waits with nothing left to read: the relay took all pushed so far.
    func untilReading() async {
        await withCheckedContinuation { c in
            lock.lock()
            if waiter != nil {
                lock.unlock()
                c.resume()
            } else {
                readingWaiters.append(c)
                lock.unlock()
            }
        }
    }

    /// At most `max` bytes of `d`, as a TCP read gives them; the rest waits in front for the
    /// next read. Call under `lock`.
    private func take(_ d: Data?, max: Int) -> Data? {
        guard let d, d.count > max else { return d }
        inbox.insert(Data(d.dropFirst(max)), at: 0)
        return Data(d.prefix(max))
    }

    func read(max: Int) async throws -> Data? {
        // A cancelled read (the relay ended) loses nothing: it gives its turn up, as the real one does.
        let d: Data? = try await withTaskCancellationHandler { try await waitRead(max) } onCancel: {
            let w = lock.withLock { () -> CheckedContinuation<Data?, Error>? in
                defer { waiter = nil }
                return waiter?.done
            }
            w?.resume(throwing: CancellationError())
        }
        lock.withLock { if let d { readSoFar.append(d) } else { readEnd = true } }
        return d
    }

    private func waitRead(_ max: Int) async throws -> Data? {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if wasReset || Task.isCancelled { lock.unlock(); return c.resume(throwing: URLError(.cancelled)) }
            if !inbox.isEmpty {
                let d = take(inbox.removeFirst(), max: max)
                lock.unlock()
                c.resume(returning: d)
            } else {
                waiter = (c, max)
                let reading = readingWaiters
                readingWaiters = []
                lock.unlock()
                reading.forEach { $0.resume() }
            }
        }
    }

    /// The browser's connection fails: the waiting read throws, and nothing is reset yet.
    func fail() {
        let w = lock.withLock { () -> CheckedContinuation<Data?, Error>? in
            defer { waiter = nil }
            return waiter?.done
        }
        w?.resume(throwing: URLError(.networkConnectionLost))
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
        w?.done.resume(throwing: URLError(.cancelled))
    }

    func rewind() -> Bool {
        lock.withLock {
            guard !answered else { return false }
            // The browser's end, once read, comes again too: the real connection stays ended.
            inbox = readSoFar.map { Optional($0) } + (readEnd ? [nil] : []) + inbox
            readSoFar = []
            readEnd = false
            return true
        }
    }
}

final class TunnelRelayTests: XCTestCase {
    private func relay(_ s: FakeTunnelSocket, _ l: FakeTunnelLocal,
                       sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in try await Task.sleep(for: .seconds(3600)) }) -> TunnelRelay {
        TunnelRelay(socket: s, local: l, sleep: sleep)
    }

    /// Runs the relay in a task of its own, not an `async let`: a relay that never ends would
    /// hang the test where the `async let` goes out of scope. `ended` waits for it.
    private func start(_ r: TunnelRelay) -> Task<TunnelRelay.End, Never> { Task { await r.run() } }

    /// How the relay ended, or nil and a failure after 5 s. A relay still running then is
    /// cancelled, so it ends too.
    private func ended(_ run: Task<TunnelRelay.End, Never>, _ r: TunnelRelay,
                       file: StaticString = #filePath, line: UInt = #line) async -> TunnelRelay.End? {
        let end = await within("the relay's end", file: file, line: line) { await run.value }
        if end == nil { r.cancel() }
        return end
    }

    func testBytesGoBothWaysAndTheCleanEndClosesWith1000() async {
        let s = FakeTunnelSocket(), l = FakeTunnelLocal()
        let r = relay(s, l)
        let run = start(r)
        l.push(Data("GET / HTTP/1.1\r\n\r\n".utf8))
        s.push(Data("HTTP/1.1 200 OK\r\n\r\nhi".utf8))
        // The browser ends, then the server: only then does the socket close.
        l.push(nil)
        await within("the browser's end goes") { await s.untilSent(2) }
        XCTAssertFalse(s.closedClean, "the server's end hasn't come yet")
        s.push(Data())
        let e = await ended(run, r)
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
        let run = start(r)
        s.push(Data("x".utf8))
        s.push(Data())
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(l.didFinish)
        XCTAssertFalse(s.closedClean, "half-closed: the browser may still send")
        l.push(Data("late".utf8))
        l.push(nil)
        let e = await ended(run, r)
        XCTAssertEqual(e, .clean)
        XCTAssertEqual(s.sent, [Data("late".utf8), Data()])
    }

    func testChunksAreAtMost64KiBAndEachWaitsForTheSendBefore() async {
        let s = FakeTunnelSocket(), l = FakeTunnelLocal()
        s.sendDelay = .milliseconds(5)
        // Pushed before the relay runs: its reads find the bytes waiting.
        l.push(Data(count: 200_000))
        let r = relay(s, l)
        let run = start(r)
        // Pushed while a read waits: the read is handed them directly.
        await within("a read waits") { await l.untilReading() }
        l.push(Data(count: 100_000))
        l.push(nil)
        s.push(Data())
        _ = await ended(run, r)
        XCTAssertEqual(s.sent.map(\.count), [65_536, 65_536, 65_536, 3_392, 65_536, 34_464, 0],
                       "every byte goes, in order, at most 64 KiB per message")
        XCTAssertEqual(s.maxInFlight, 1, "the next read waits for the send")
    }

    func testARefusedTargetIs1001WithNoBytes() async {
        let s = FakeTunnelSocket(), l = FakeTunnelLocal()
        let r = relay(s, l)
        let run = start(r)
        s.serverClose(1001)
        let e = await ended(run, r)
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
        let run = start(r)
        s.push(Data("partial".utf8))
        try? await Task.sleep(for: .milliseconds(20))
        s.serverClose(4000)
        let e = await ended(run, r)
        XCTAssertEqual(e, .blockClosed)
        XCTAssertTrue(l.didReset)
    }

    func testOwnerLostBeforeAnyByteLeavesTheBrowserForARetry() async {
        let s = FakeTunnelSocket(), l = FakeTunnelLocal()
        let r = relay(s, l)
        let run = start(r)
        l.push(Data("GET /".utf8))
        // A read waits with nothing left: the relay sent the request and waits on the browser.
        await within("a read waits") { await l.untilReading() }
        XCTAssertEqual(s.sent, [Data("GET /".utf8)])
        s.serverClose(4006)
        let e = await ended(run, r)
        XCTAssertEqual(e, .ownerLost(beforeAnyByte: true))
        XCTAssertFalse(l.didReset, "the caller sends the request again on a new block")
        XCTAssertTrue(s.aborted, "the read that waited ended, and the socket is let go")
        XCTAssertTrue(l.rewind())

        // The same request goes out again, whole, on the next relay.
        let s2 = FakeTunnelSocket()
        let r2 = relay(s2, l)
        let run2 = start(r2)
        await within("the request goes again") { await s2.untilSent(1) }
        XCTAssertEqual(s2.sent.first, Data("GET /".utf8))
        s2.push(Data("ok".utf8))
        l.push(nil)
        s2.push(Data())
        let e2 = await ended(run2, r2)
        XCTAssertEqual(e2, .clean)
        XCTAssertEqual(l.writes, [Data("ok".utf8)])
    }

    func testOwnerLostBeforeAnyByteEndsTheRelayWhereverTheBrowserIs() async {
        // Before the browser sent anything.
        do {
            let s = FakeTunnelSocket(), l = FakeTunnelLocal()
            let r = relay(s, l)
            let run = start(r)
            await within("a read waits") { await l.untilReading() }
            s.serverClose(4006)
            let e = await ended(run, r)
            XCTAssertEqual(e, .ownerLost(beforeAnyByte: true))
            XCTAssertFalse(l.didReset)
            XCTAssertTrue(s.aborted)
            XCTAssertFalse(s.closedClean)
        }
        // After the browser's end: no read is left, and the end comes again on the retry.
        do {
            let s = FakeTunnelSocket(), l = FakeTunnelLocal()
            let r = relay(s, l)
            let run = start(r)
            l.push(Data("GET /".utf8))
            l.push(nil)
            await within("the browser's end goes") { await s.untilSent(2) }
            s.serverClose(4006)
            let e = await ended(run, r)
            XCTAssertEqual(e, .ownerLost(beforeAnyByte: true))
            XCTAssertFalse(l.didReset)
            XCTAssertFalse(s.closedClean)
            XCTAssertTrue(l.rewind())

            let s2 = FakeTunnelSocket()
            let r2 = relay(s2, l)
            let run2 = start(r2)
            await within("the request and its end go again") { await s2.untilSent(2) }
            XCTAssertEqual(s2.sent, [Data("GET /".utf8), Data()])
            s2.push(Data())
            let e2 = await ended(run2, r2)
            XCTAssertEqual(e2, .clean)
        }
    }

    /// A request in two chunks: the first goes, and the server closes with `code` while the
    /// second is held in its send. `sendFailsFirst`: the send sees the close before the receive.
    private func closeMidSend(_ code: Int, sendFailsFirst: Bool,
                              file: StaticString = #filePath, line: UInt = #line)
        async -> (end: TunnelRelay.End?, socket: FakeTunnelSocket, local: FakeTunnelLocal) {
        let s = FakeTunnelSocket(), l = FakeTunnelLocal()
        s.holdFrom = 1
        let r = relay(s, l)
        let run = start(r)
        l.push(Data("GET / HTTP/1.1\r\n".utf8))
        await within("the first chunk goes", file: file, line: line) { await s.untilSent(1) }
        l.push(Data("Host: x\r\n\r\n".utf8))
        await within("the second chunk's send is held", file: file, line: line) { await s.untilHeld() }
        if sendFailsFirst {
            s.serverClose(code, receiveFails: false)
            s.releaseSend()
        } else {
            // The receive ends the relay, and its end cancels the held send.
            s.serverClose(code)
        }
        let e = await ended(run, r, file: file, line: line)
        return (e, s, l)
    }

    func testA4006WhileASendIsHeldRetriesWhicheverSideSeesItFirst() async {
        for sendFailsFirst in [true, false] {
            let (e, s, l) = await closeMidSend(4006, sendFailsFirst: sendFailsFirst)
            let side = sendFailsFirst ? "send first" : "receive first"
            XCTAssertEqual(e, .ownerLost(beforeAnyByte: true), side)
            XCTAssertFalse(l.didReset, "\(side): the caller sends the request again on a new block")
            XCTAssertTrue(s.aborted, side)
            XCTAssertFalse(s.closedClean, side)
            XCTAssertEqual(s.sent, [Data("GET / HTTP/1.1\r\n".utf8)], "\(side): the held chunk never went")
            XCTAssertTrue(l.rewind(), side)

            // Both chunks go again, in order: the one sent and the one that was in flight.
            let s2 = FakeTunnelSocket()
            let r2 = relay(s2, l)
            let run2 = start(r2)
            await within("the request goes again") { await s2.untilSent(2) }
            XCTAssertEqual(s2.sent, [Data("GET / HTTP/1.1\r\n".utf8), Data("Host: x\r\n\r\n".utf8)], side)
            l.push(nil)
            s2.push(Data())
            let e2 = await ended(run2, r2)
            XCTAssertEqual(e2, .clean, side)
            XCTAssertEqual(s2.sent.last, Data(), side)
        }
    }

    func testAnotherCloseWhileASendIsHeldResets() async {
        for sendFailsFirst in [true, false] {
            let (e, _, l) = await closeMidSend(4000, sendFailsFirst: sendFailsFirst)
            let side = sendFailsFirst ? "send first" : "receive first"
            XCTAssertEqual(e, .blockClosed, side)
            XCTAssertTrue(l.didReset, side)
        }
    }

    func testABrowserThatFailsResetsBoth() async {
        let s = FakeTunnelSocket(), l = FakeTunnelLocal()
        let r = relay(s, l)
        let run = start(r)
        l.push(Data("GET /".utf8))
        await within("a read waits") { await l.untilReading() }
        l.fail()
        let e = await ended(run, r)
        XCTAssertEqual(e, .cancelled)
        XCTAssertTrue(l.didReset)
        XCTAssertTrue(s.aborted)
        XCTAssertFalse(s.closedClean)
    }

    func testCancelResetsBoth() async {
        let s = FakeTunnelSocket(), l = FakeTunnelLocal()
        let r = relay(s, l)
        let run = start(r)
        try? await Task.sleep(for: .milliseconds(20))
        r.cancel()
        let e = await ended(run, r)
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
        let run = start(r)
        // Three sleeps pass, and the fourth is asked for: by then three pings went.
        let sleeps = await within("four sleeps") { () -> [Duration?] in
            var it = asked.stream.makeAsyncIterator()
            var got: [Duration?] = []
            for _ in 0..<3 {
                got.append(await it.next())
                clock.tick()
            }
            got.append(await it.next())
            return got
        }
        XCTAssertEqual(sleeps, Array(repeating: Duration?.some(.seconds(25)), count: 4))
        XCTAssertEqual(s.pings, 3)
        l.push(nil)
        s.push(Data())
        _ = await ended(run, r)
    }
}

extension XCTestCase {
    /// What `work` gives, or nil and a failure once `timeout` passes, so a test that waits on an
    /// event that never comes fails instead of hanging the run. Work still waiting then is
    /// cancelled and left behind.
    @discardableResult
    func within<T: Sendable>(_ what: String, timeout: TimeInterval = 5,
                             file: StaticString = #filePath, line: UInt = #line,
                             _ work: @escaping @Sendable () async -> T) async -> T? {
        let task = Task { await work() }
        let done = XCTestExpectation(description: what)
        Task {
            _ = await task.value
            done.fulfill()
        }
        guard await XCTWaiter().fulfillment(of: [done], timeout: timeout) == .completed else {
            task.cancel()
            XCTFail("\(what): nothing after \(timeout) s", file: file, line: line)
            return nil
        }
        return await task.value
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
