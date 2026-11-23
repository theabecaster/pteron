import Foundation
import GlanceModel
import Network
import XCTest
import RexKit
@testable import Pteron

/// A server as `PortForward` sees it, played by the test: its calls are recorded, and each data
/// connection is a socket the test can answer.
@MainActor
final class FakeTunnelServer: TunnelServer {
    let id = UUID()
    var tunnelsAvailable = true
    var synced = true
    var tunnelClientID: String? = "client:1"
    var tunnelConnected = true
    var tunnelName = "Desk"
    /// Every call, in order: `method block_id-or-session`.
    var calls: [String] = []
    /// Answers `session.list_blocks`.
    var blocks: [JSONObject] = []
    var listError: RexError?
    var newBlockError: RexError?
    var closeError: [String: RexError] = [:]
    var nextBlock = 0
    var missing = 0
    /// The data connections opened, newest last.
    var sockets: [StubSocket] = []
    /// What each new socket does once the relay starts.
    var onSocket: (StubSocket) -> Void = { _ in }

    func tunnelCall(_ method: String, _ payload: JSONObject) async throws -> JSONObject {
        calls.append("\(method) \(payload.str("block_id") ?? payload.str("session_id") ?? "")")
        switch method {
        case "session.list_blocks":
            if let listError { throw listError }
            return ["blocks": blocks]
        case "session.new_block":
            if let newBlockError { throw newBlockError }
            nextBlock += 1
            let id = "block:t\(nextBlock)"
            blocks.append(["block_id": id, "flavor": payload.str("flavor") ?? "", "label": payload.str("label") ?? "",
                           "placement": "detached"])
            return ["block_id": id, "revision": 1]
        case "data.connect":
            return ["ticket": "AAAAAAAAAAAAAAAAAAAAAA"]
        default:
            return [:]
        }
    }

    func tunnelCallsInOrder(_ list: [(method: String, payload: JSONObject)]) async -> [Result<JSONObject, Error>] {
        let ids = list.map { $0.payload.str("block_id") ?? "" }
        calls.append("inOrder \(list.map(\.method).joined(separator: ",")) \(ids.joined(separator: ","))")
        return ids.map { id in
            if let e = closeError[id] { return .failure(e) }
            blocks.removeAll { $0.str("block_id") == id }
            return .success([:])
        }
    }

    func openTunnel(ticket: String, in session: TunnelSession?) async throws -> any TunnelSocket {
        let s = StubSocket()
        sockets.append(s)
        onSocket(s)
        return s
    }

    func makeTunnelSession() -> TunnelSession? { nil }
    func tunnelsMissing() { missing += 1 }
}

/// A data connection that answers with a close status, or with bytes and a clean end.
final class StubSocket: TunnelSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [Result<Data?, Error>] = []
    private var waiter: CheckedContinuation<Data?, Error>?
    private var code = 0
    private var wasAborted = false
    private var sendFails = false
    private(set) var sentData: [Data] = []
    var sent: [Data] { lock.withLock { sentData } }
    var closeCode: Int { lock.withLock { code } }
    var aborted: Bool { lock.withLock { wasAborted } }

    func push(_ d: Data) { deliver(.success(d)) }
    func serverClose(_ c: Int) {
        lock.withLock { code = c }
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

    /// The server closes while a send is on its way: the send fails first, and the receive only
    /// once the relay lets the socket go.
    func closeUnderSend(_ c: Int) { lock.withLock { code = c; sendFails = true } }

    func send(_ data: Data) async throws {
        try lock.withLock {
            if sendFails { throw URLError(.networkConnectionLost) }
            sentData.append(data)
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
    func ping() async throws {}
    func close() { lock.withLock { code = 1000 }; deliver(.failure(URLError(.cancelled))) }
    func abort() {
        lock.withLock { wasAborted = true }
        deliver(.failure(URLError(.cancelled)))
    }
}

/// A browser connection: one request, then its end.
final class StubLocal: TunnelLocal, @unchecked Sendable {
    private let lock = NSLock()
    private var toRead: [Data?]
    private var readSoFar: [Data] = []
    private var answered = false
    private var waiter: CheckedContinuation<Data?, Error>?
    private(set) var resetCount = 0
    private(set) var written: [Data] = []
    var resets: Int { lock.withLock { resetCount } }
    var writes: [Data] { lock.withLock { written } }

    init(_ request: String = "GET / HTTP/1.1\r\n\r\n", end: Bool = true) {
        toRead = [Data(request.utf8)] + (end ? [nil] : [])
    }

    /// A cancelled read throws, as the real one does (`TunnelLocal.read`), so a relay always ends.
    func read(max: Int) async throws -> Data? {
        let d: Data? = try await withTaskCancellationHandler { try await waitRead() } onCancel: {
            let w = lock.withLock { () -> CheckedContinuation<Data?, Error>? in
                defer { waiter = nil }
                return waiter
            }
            w?.resume(throwing: CancellationError())
        }
        if let d { lock.withLock { readSoFar.append(d) } }
        return d
    }

    private func waitRead() async throws -> Data? {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if resetCount > 0 || Task.isCancelled { lock.unlock(); return c.resume(throwing: URLError(.cancelled)) }
            if !toRead.isEmpty {
                let d = toRead.removeFirst()
                lock.unlock()
                c.resume(returning: d)
            } else {
                waiter = c
                lock.unlock()
            }
        }
    }
    func write(_ data: Data) async throws { lock.withLock { written.append(data); answered = true } }
    func finishWriting() {}
    func close() {}
    func reset() {
        lock.lock()
        resetCount += 1
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(throwing: URLError(.cancelled))
    }
    func rewind() -> Bool {
        lock.withLock {
            guard !answered else { return false }
            toRead = readSoFar.map { Optional($0) } + toRead + [nil]
            readSoFar = []
            return true
        }
    }
}

/// A listener the test hands connections to.
@MainActor
final class StubListener: PortListener {
    var port = 0
    var accept: (@MainActor (any TunnelLocal) -> Void)?
    var starts: [Int] = []
    var stops = 0
    var taken: Set<Int> = []

    func start(preferring port: Int, accept: @escaping @MainActor (any TunnelLocal) -> Void) async throws -> Int {
        starts.append(port)
        self.accept = accept
        self.port = (port > 1024 && !taken.contains(port)) ? port : 49_999
        return self.port
    }

    func stop() {
        stops += 1
        accept = nil
    }
}

/// This phone's label in these tests.
let tunnelLabelInTests = "\(Brand.appName) #a1b2c3d4"

@MainActor
final class PortForwardTests: XCTestCase {
    private var listener: StubListener!
    private var ledger: TunnelLedger!
    private var tasks: [String] = []
    private var ended = 0
    private var notices: [String] = []

    private func forward() -> PortForward {
        let name = "PortForwardTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        ledger = TunnelLedger(defaults: d)
        let l = StubListener()
        listener = l
        let f = PortForward(tag: { "a1b2c3d4" }, ledger: ledger, makeListener: { l })
        f.beginBackground = { [unowned self] name in
            tasks.append(name)
            return { self.ended += 1 }
        }
        f.notify = { [unowned self] in notices.append($0) }
        return f
    }

    private let target = PortForward.Target(sessionID: "session:1", port: 5173, dialHost: "127.0.0.1")

    /// A connection that gets a page back and ends cleanly.
    private func answer(_ s: StubSocket) {
        s.push(Data("HTTP/1.1 200 OK\r\n\r\nhi".utf8))
        s.push(Data())
    }

    func testTheLabelCarriesTheAppAndTheTag() {
        let f = forward()
        XCTAssertEqual(f.label, "\(Brand.appName) #a1b2c3d4")
    }

    func testTheOpenedPortIsTheOneListenedOnWhenFreeAndAbove1024() async throws {
        let f = forward()
        let server = FakeTunnelServer()
        let port = try await f.open(target, on: server)
        XCTAssertEqual(port, 5173)
        XCTAssertEqual(listener.starts, [5173], "only the opened port is asked for")
        f.close()
        let f2 = forward()
        listener.taken = [5173]
        let other = try await f2.open(target, on: server)
        XCTAssertEqual(other, 49_999, "taken: a free port")
        let low = try await f2.open(PortForward.Target(sessionID: "session:1", port: 80, dialHost: "127.0.0.1"), on: server)
        XCTAssertEqual(low, 49_999, "80 is never bound")
    }

    func testABlockIsMadeOnTheFirstConnectionAfterASweepAndUsedAfterThat() async throws {
        let f = forward()
        let server = FakeTunnelServer()
        server.onSocket = answer
        _ = try await f.open(target, on: server)
        XCTAssertTrue(server.calls.isEmpty, "nothing on the computer until the browser connects")
        let a = StubLocal(), b = StubLocal()
        listener.accept?(a)
        await settle { server.calls.filter { $0.hasPrefix("data.connect") }.count == 1 }
        listener.accept?(b)
        await settle { server.calls.filter { $0.hasPrefix("data.connect") }.count == 2 }
        XCTAssertEqual(server.calls.filter { $0.hasPrefix("session.") }, ["session.list_blocks session:1", "session.new_block session:1"],
                       "one sweep and one block for both connections")
        XCTAssertTrue(f.owns("block:t1"))
        XCTAssertEqual(ledger.blocks(server: server.id, session: "session:1"), ["block:t1"], "remembered until closed")
        XCTAssertTrue(ledger.sessions(server: server.id) == ["session:1"])
    }

    func testTheSweepClosesOnlyThisPhonesTagOutsideTheLiveMapWhateverItsOwner() async throws {
        let f = forward()
        let server = FakeTunnelServer()
        server.blocks = [
            ["block_id": "block:old", "flavor": PortForward.flavor, "label": tunnelLabelInTests, "owner": "client:9"],
            ["block_id": "block:other", "flavor": PortForward.flavor, "label": "\(Brand.appName) #ffffffff"],
            ["block_id": "block:cli", "flavor": PortForward.flavor, "label": "dial"],
            ["block_id": "block:shell", "flavor": "com.superlogical.terminal.shell", "label": tunnelLabelInTests],
        ]
        ledger.remember(server: server.id, session: "session:1", block: "block:old")
        f.serverSynced(server)
        await settle { server.calls.contains { $0.hasPrefix("inOrder") } }
        XCTAssertEqual(server.calls, ["session.list_blocks session:1", "inOrder block.close block:old"])
        XCTAssertTrue(ledger.sessions(server: server.id).isEmpty, "closed and forgotten")
    }

    func testNoSweepWithoutRememberedBlocksOrAMark() async {
        let f = forward()
        let server = FakeTunnelServer()
        f.serverSynced(server)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(server.calls.isEmpty, "a sync costs nothing while ports go unused")
    }

    func testAMarkLeftByAKillTriggersTheSweep() async {
        let f = forward()
        let server = FakeTunnelServer()
        ledger.mark(server: server.id, session: "session:2")
        server.blocks = [["block_id": "block:x", "flavor": PortForward.flavor, "label": tunnelLabelInTests]]
        f.serverSynced(server)
        await settle { server.calls.count == 2 }
        XCTAssertEqual(server.calls, ["session.list_blocks session:2", "inOrder block.close block:x"])
        XCTAssertTrue(ledger.sessions(server: server.id).isEmpty)
    }

    func testTheSweepForgetsWhatIsGone() async {
        let f = forward()
        let server = FakeTunnelServer()
        ledger.remember(server: server.id, session: "session:1", block: "block:gone")
        ledger.remember(server: server.id, session: "session:2", block: "block:a")
        ledger.remember(server: server.id, session: "session:3", block: "block:b")
        server.blocks = [["block_id": "block:a", "flavor": PortForward.flavor, "label": tunnelLabelInTests],
                         ["block_id": "block:b", "flavor": PortForward.flavor, "label": tunnelLabelInTests]]
        server.closeError = ["block:a": RexError(code: "not_found", message: "", status: 404),
                             "block:b": RexError(code: "internal", message: "", status: 500)]
        f.serverSynced(server)
        // Each session is listed, then this phone's blocks in it are closed. The fake lists the
        // same blocks for every session, and a failed close leaves them listed.
        await settle { server.calls.count == 6 }
        XCTAssertEqual(server.calls, [
            "session.list_blocks session:1", "inOrder block.close,block.close block:a,block:b",
            "session.list_blocks session:2", "inOrder block.close,block.close block:a,block:b",
            "session.list_blocks session:3", "inOrder block.close,block.close block:a,block:b",
        ])
        XCTAssertEqual(ledger.blocks(server: server.id, session: "session:1"), [], "no longer listed")
        XCTAssertEqual(ledger.blocks(server: server.id, session: "session:2"), [], "not_found")
        XCTAssertEqual(ledger.blocks(server: server.id, session: "session:3"), ["block:b"], "any other failure: next time")

        server.listError = RexError(code: "session_not_found", message: "", status: 404)
        f.serverSynced(server)
        await settle { self.ledger.sessions(server: server.id).isEmpty }
        XCTAssertTrue(ledger.sessions(server: server.id).isEmpty, "a gone session forgets all its entries")
    }

    func testTheSweepWaitsForABlockBeingMade() async throws {
        let f = forward()
        let server = FakeTunnelServer()
        server.onSocket = answer
        _ = try await f.open(target, on: server)
        listener.accept?(StubLocal())
        f.serverSynced(server)
        await settle { server.calls.filter { $0.hasPrefix("session.list_blocks") }.count == 1 && server.calls.contains { $0.hasPrefix("data.connect") } }
        try? await Task.sleep(for: .milliseconds(100))
        let session = server.calls.filter { $0.hasPrefix("session.") || $0.hasPrefix("inOrder") }
        XCTAssertEqual(session.first, "session.list_blocks session:1")
        XCTAssertEqual(session.dropFirst().first, "session.new_block session:1", "the block is made right after its own sweep")
        XCTAssertFalse(server.calls.contains { $0.hasPrefix("inOrder") }, "the live block is never swept")
    }

    func testAClientIDChangeGivesAFreshBlock() async throws {
        let f = forward()
        let server = FakeTunnelServer()
        server.onSocket = answer
        _ = try await f.open(target, on: server)
        listener.accept?(StubLocal())
        await settle { f.forward?.block != nil }
        // A long drop: the connection is made again as another client.
        server.tunnelClientID = "client:2"
        f.serverSynced(server)
        await settle { server.calls.contains { $0.hasPrefix("inOrder") } }
        XCTAssertNil(f.forward?.block, "the old block is dropped from the live map")
        XCTAssertTrue(server.calls.contains("inOrder block.close block:t1"), "and the sweep closes it")
        listener.accept?(StubLocal())
        await settle { server.calls.contains("session.new_block session:1") && server.nextBlock == 2 }
        XCTAssertEqual(f.forward?.block?.id, "block:t2")
        XCTAssertEqual(f.forward?.block?.clientID, "client:2")
    }

    func testA4006BeforeAnyByteRetriesOnceOnANewBlock() async throws {
        let f = forward()
        let server = FakeTunnelServer()
        var n = 0
        server.onSocket = { s in
            n += 1
            if n == 1 { s.serverClose(4006) } else { s.push(Data("ok".utf8)); s.push(Data()) }
        }
        _ = try await f.open(target, on: server)
        let local = StubLocal()
        listener.accept?(local)
        await settle { local.writes == [Data("ok".utf8)] }
        XCTAssertEqual(server.nextBlock, 2, "a new block for the retry")
        XCTAssertEqual(server.sockets.last?.sent.first, Data("GET / HTTP/1.1\r\n\r\n".utf8), "the request goes once more, whole")
        XCTAssertEqual(local.resets, 0)

        // A second 4006 isn't retried again.
        n = 0
        server.onSocket = { s in s.serverClose(4006) }
        let again = StubLocal()
        listener.accept?(again)
        await settle { again.resets == 1 }
        XCTAssertEqual(server.nextBlock, 3, "one retry on a new block, then the browser gets a reset")
    }

    func testA4006WhileTheRequestGoesUpRetriesOnANewBlock() async throws {
        let f = forward()
        let server = FakeTunnelServer()
        var n = 0
        server.onSocket = { s in
            n += 1
            if n == 1 { s.closeUnderSend(4006) } else { s.push(Data("ok".utf8)); s.push(Data()) }
        }
        _ = try await f.open(target, on: server)
        let local = StubLocal()
        listener.accept?(local)
        await settle { local.writes == [Data("ok".utf8)] }
        XCTAssertEqual(server.sockets.first?.sent, [], "the first send failed")
        XCTAssertEqual(server.nextBlock, 2, "a new block for the retry")
        XCTAssertEqual(server.sockets.last?.sent.first, Data("GET / HTTP/1.1\r\n\r\n".utf8), "the request goes once more, whole")
        XCTAssertEqual(local.resets, 0)
    }

    func testConnectionsWaitForTheSyncUpTo30Seconds() async throws {
        let f = forward()
        f.syncedWait = .milliseconds(200)
        let server = FakeTunnelServer()
        server.onSocket = answer
        server.synced = false
        _ = try await f.open(target, on: server)
        let a = StubLocal(), b = StubLocal()
        listener.accept?(a)
        listener.accept?(b)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(f.forward?.syncWaiters.count, 2)
        XCTAssertTrue(server.calls.isEmpty)
        server.synced = true
        f.serverSynced(server)
        await settle { server.calls.filter { $0.hasPrefix("data.connect") }.count == 2 }
        XCTAssertEqual(a.resets + b.resets, 0)

        server.synced = false
        let late = StubLocal()
        listener.accept?(late)
        await settle(2) { late.resets == 1 }
        XCTAssertEqual(late.resets, 1, "past the cap the browser's connection is reset")
        XCTAssertEqual(f.forward?.syncWaiters.count, 0)
    }

    func testAtMost16ConnectionsRunAtOnce() async throws {
        let f = forward()
        let server = FakeTunnelServer()
        _ = try await f.open(target, on: server)
        // The server never answers: every relay stays open.
        let locals = (0..<20).map { _ in StubLocal(end: false) }
        for l in locals { listener.accept?(l) }
        await settle { server.calls.filter { $0.hasPrefix("data.connect") }.count == 16 }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(server.calls.filter { $0.hasPrefix("data.connect") }.count, 16)
        XCTAssertEqual(f.forward?.waiting.count, 4)
        // One ends: the next waiting one gets its slot.
        server.sockets[0].push(Data())
        server.sockets[0].serverClose(4000)
        await settle { server.calls.filter { $0.hasPrefix("data.connect") }.count == 17 }
        f.close()
    }

    func testTheBackgroundTaskBeginsAtOnceAndTheBlockClosesBeforeTheSockets() async throws {
        let f = forward()
        let server = FakeTunnelServer()
        _ = try await f.open(target, on: server)
        let open = StubLocal(end: false)
        listener.accept?(open)
        await settle { server.sockets.count == 1 }
        f.enteredBackground()
        XCTAssertEqual(tasks, ["ports_background"], "begun in the same turn")
        XCTAssertEqual(listener.stops, 0)
        await settle { self.ended == 1 }
        XCTAssertEqual(server.calls.last, "inOrder block.close block:t1")
        XCTAssertEqual(listener.stops, 1)
        XCTAssertGreaterThanOrEqual(open.resets, 1)
        XCTAssertNil(f.forward?.block)
        XCTAssertFalse(f.forward?.listening ?? true)

        // Back in front with the browser up: the same port again, and a new block when needed.
        f.becameActive()
        await settle { self.listener.starts.count == 2 }
        XCTAssertEqual(listener.starts, [5173, 5173])
    }

    func testClosingTheBrowserClosesItsBlockAndForgetsIt() async throws {
        let f = forward()
        let server = FakeTunnelServer()
        server.onSocket = answer
        _ = try await f.open(target, on: server)
        listener.accept?(StubLocal())
        await settle { f.forward?.block != nil }
        f.close()
        XCTAssertEqual(tasks, ["ports_close"])
        await settle { self.ended == 1 }
        XCTAssertNil(f.forward)
        XCTAssertEqual(server.calls.last, "inOrder block.close block:t1")
        XCTAssertTrue(ledger.sessions(server: server.id).isEmpty)
        XCTAssertTrue(f.owns("block:t1"), "its block_closed still changes no view")
    }

    func testARefusedBlockShowsOneNoticePerBrowser() async throws {
        let f = forward()
        let server = FakeTunnelServer()
        server.newBlockError = RexError(code: "conflict", message: "full", status: 409)
        _ = try await f.open(target, on: server)
        let a = StubLocal(), b = StubLocal()
        listener.accept?(a)
        listener.accept?(b)
        await settle { a.resets == 1 && b.resets == 1 }
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(ledger.sessions(server: server.id).isEmpty, "the mark is cleared")

        server.newBlockError = RexError(code: "not_found", message: "no creator", status: 404)
        _ = try await f.open(target, on: server)
        let c = StubLocal()
        listener.accept?(c)
        await settle { c.resets == 1 }
        XCTAssertEqual(server.missing, 1, "the flavor is marked missing for this server")
    }

    /// A block request that never reached the server (the connection dropped) used to fail
    /// silently: the page just didn't load. It says so now, once per browser.
    func testAnUnsentBlockRequestShowsOneNoticePerBrowser() async throws {
        for error in [RexError.unsent("not connected"), RexError.local("connection lost")] {
            notices = []
            let f = forward()
            let server = FakeTunnelServer()
            server.newBlockError = error
            _ = try await f.open(target, on: server)
            let a = StubLocal(), b = StubLocal()
            listener.accept?(a)
            listener.accept?(b)
            await settle { a.resets == 1 && b.resets == 1 }
            XCTAssertEqual(notices, ["Couldn't open localhost:5173. \(Messages.notSent("Desk"))"], "\(error)")
            XCTAssertEqual(server.missing, 0, "the server still makes tunnels")
            f.close()
        }
    }

    func testAGateThatClosesStopsTheListenerWithOneNotice() async throws {
        let f = forward()
        let server = FakeTunnelServer()
        _ = try await f.open(target, on: server)
        server.tunnelsAvailable = false
        f.serverSynced(server)
        f.serverSynced(server)
        XCTAssertEqual(listener.stops, 1)
        XCTAssertEqual(notices.count, 1)
        let late = StubLocal()
        listener.accept?(late)
        XCTAssertTrue(server.calls.isEmpty, "never a block on a server without the flavor")

        // The gate opens again: the phone listens on the same port, quietly.
        server.tunnelsAvailable = true
        f.serverSynced(server)
        await settle { self.listener.starts.count == 2 }
        XCTAssertEqual(listener.starts, [5173, 5173])
        XCTAssertEqual(notices.count, 1)
    }

    /// A page that asks while its computer is down (backing off, dormant or held): the phone's
    /// listener takes the request and dials nothing, so no socket and no call goes to it.
    func testAPageRequestWhileTheComputerIsDownDialsNothing() async throws {
        let f = forward()
        let server = FakeTunnelServer()
        server.onSocket = answer
        _ = try await f.open(target, on: server)
        server.tunnelConnected = false
        let locals = (0..<20).map { _ in StubLocal() }
        for local in locals { listener.accept?(local) }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(server.calls.isEmpty, "no call to a computer that is down")
        XCTAssertTrue(server.sockets.isEmpty, "and no data connection")

        // The control connection is back: the next request dials as usual.
        server.tunnelConnected = true
        listener.accept?(StubLocal())
        await settle { server.calls.filter { $0.hasPrefix("data.connect") }.count == 1 }
        XCTAssertEqual(server.sockets.count, 1)
    }

    /// The app's part of the hour test (`DownHostSocketCountTests` in RexKit holds the control
    /// connection, the panes and the file transfer): a live forward whose page asks once a
    /// minute for two hours while its computer is down. `tunnelConnected` is the computer's gate
    /// (no welcome, the background, or no verdict yet after it): no call and no data connection.
    func testAForwardDialsNothingThroughTwoHoursOfRequestsToAComputerThatIsDown() async throws {
        let f = forward()
        let server = FakeTunnelServer()
        server.onSocket = answer
        _ = try await f.open(target, on: server)
        listener.accept?(StubLocal())
        await settle { server.sockets.count == 1 }
        let calls = server.calls.count
        server.tunnelConnected = false
        for _ in 0..<120 {
            listener.accept?(StubLocal())
            await Task.yield()
        }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(server.calls.count, calls, "no call to a computer that is down")
        XCTAssertEqual(server.sockets.count, 1, "and no data connection")
    }

    func testARemovedServerClosesItsBlocksWhenConnectedElseForgetsThem() async {
        let f = forward()
        let server = FakeTunnelServer()
        ledger.remember(server: server.id, session: "session:1", block: "block:a")
        server.blocks = [["block_id": "block:a", "flavor": PortForward.flavor, "label": tunnelLabelInTests]]
        f.serverRemoved(server)
        await settle { self.ledger.sessions(server: server.id).isEmpty }
        XCTAssertTrue(server.calls.contains("inOrder block.close block:a"))

        let offline = FakeTunnelServer()
        offline.tunnelConnected = false
        ledger.remember(server: offline.id, session: "session:1", block: "block:b")
        f.serverRemoved(offline)
        XCTAssertTrue(ledger.sessions(server: offline.id).isEmpty)
        XCTAssertTrue(offline.calls.isEmpty)
    }

    // MARK: Tag

    func testTheTagIsMadeOnceAndKeptOnThisDeviceOnly() {
        let box = KeychainBox()
        let item = KeychainItem(service: "test.ports", account: "tag", keychain: box.calls)
        let tag = TunnelTag.load(item)
        XCTAssertTrue(TunnelTag.valid(tag))
        XCTAssertEqual(TunnelTag.load(item), tag, "read back, not made again")
        let added = box.added.last ?? [:]
        XCTAssertEqual(added[kSecAttrSynchronizable as String] as? Bool, false, "never in iCloud Keychain")
        XCTAssertEqual(added[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    func testAKeychainThatCantBeReadIsLeftAlone() {
        let box = KeychainBox()
        box.readStatus = errSecInteractionNotAllowed
        let item = KeychainItem(service: "test.ports", account: "tag", keychain: box.calls)
        XCTAssertTrue(TunnelTag.valid(TunnelTag.load(item)))
        XCTAssertTrue(box.added.isEmpty)
    }

    // MARK: Listener

    func testTheListenerIsBoundToIPv4LoopbackOnly() async throws {
        let p = LoopbackListener.parameters(port: 0)
        guard case .hostPort(let host, _) = p.requiredLocalEndpoint else { return XCTFail("no endpoint") }
        XCTAssertEqual(host, .ipv4(.loopback))
        XCTAssertFalse(p.includePeerToPeer)

        let l = LoopbackListener()
        let accepted = Accepted()
        let started = await within("the listener starts") {
            try? await l.start(preferring: 0) { local in
                accepted.locals.append(local)
                local.close()
            }
        }
        defer { l.stop() }
        guard let port = started ?? nil else { return XCTFail("no listener") }
        XCTAssertGreaterThan(port, 1024)
        let c = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        c.start(queue: .main)
        await settle { accepted.locals.count == 1 }
        c.cancel()
        XCTAssertEqual(accepted.locals.count, 1)
    }

    func testA4006BeforeAnyByteEndsTheRelayAndKeepsTheBrowsersConnection() async throws {
        // The app's own connection, its read waiting on the browser when the 4006 comes: the
        // relay ends, lets the socket go, and the browser's connection carries the retry.
        let l = LoopbackListener()
        let accepted = Accepted()
        let started = await within("the listener starts") {
            try? await l.start(preferring: 0) { accepted.locals.append($0) }
        }
        defer { l.stop() }
        guard let port = started ?? nil else { return XCTFail("no listener") }
        let browser = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        browser.start(queue: .main)
        defer { browser.cancel() }
        await settle { !accepted.locals.isEmpty }
        guard let local = accepted.locals.first else { return XCTFail("no connection") }
        defer { local.close() }
        let request = Data("GET / HTTP/1.1\r\n\r\n".utf8)
        browser.send(content: request, completion: .contentProcessed { _ in })

        let s = StubSocket()
        let relay = TunnelRelay(socket: s, local: local)
        let run = Task { await relay.run() }
        await settle { s.sent.reduce(Data(), +) == request }
        s.serverClose(4006)
        let end = await within("the relay's end") { await run.value }
        if end == nil { relay.cancel() }
        XCTAssertEqual(end, .ownerLost(beforeAnyByte: true))
        XCTAssertTrue(s.aborted, "the read that waited on the browser ended, and the socket is let go")

        XCTAssertTrue(local.rewind())
        let again = await within("the request reads again") { try? await local.read(max: TunnelRelay.chunk) }
        XCTAssertEqual(again ?? nil, s.sent.first, "the request, from the start")
        await within("the answer goes") { try? await local.write(Data("ok".utf8)) }
        let reply = await within("the answer reaches the browser") { () -> Data? in
            await withCheckedContinuation { c in
                browser.receive(minimumIncompleteLength: 1, maximumLength: 64) { d, _, _, _ in c.resume(returning: d) }
            }
        }
        XCTAssertEqual(reply ?? nil, Data("ok".utf8), "never reset: the browser's connection is still up")
    }

    // MARK: Helpers

    /// What `work` gives, or nil and a failure once `timeout` passes, so a wait for an event that
    /// never comes fails the test instead of hanging the run. Work still waiting then is
    /// cancelled and left behind.
    @discardableResult
    private func within<T: Sendable>(_ what: String, timeout: TimeInterval = 5,
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

    /// Waits until `condition` holds, and fails the test if it still doesn't after `seconds`.
    private func settle(_ seconds: Double = 3, file: StaticString = #filePath, line: UInt = #line,
                        _ condition: @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < end else { return XCTFail("still not settled after \(seconds) s", file: file, line: line) }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// What a listener accepted, for a test.
@MainActor
private final class Accepted {
    var locals: [any TunnelLocal] = []
}

/// The Keychain, in memory.
final class KeychainBox: @unchecked Sendable {
    private let lock = NSLock()
    private var store: Data?
    var readStatus: OSStatus = errSecSuccess
    private(set) var addedItems: [[String: Any]] = []
    var added: [[String: Any]] { lock.withLock { addedItems } }

    var calls: KeychainCalls {
        KeychainCalls(
            copy: { _ in self.lock.withLock { self.readStatus != errSecSuccess ? (self.readStatus, nil) : (self.store == nil ? errSecItemNotFound : errSecSuccess, self.store) } },
            add: { q in self.lock.withLock { self.addedItems.append(q); self.store = q[kSecValueData as String] as? Data }; return errSecSuccess },
            update: { _, _ in self.lock.withLock { self.store == nil ? errSecItemNotFound : errSecSuccess } },
            delete: { _ in errSecSuccess })
    }
}
