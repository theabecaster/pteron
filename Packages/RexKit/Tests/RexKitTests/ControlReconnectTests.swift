import Network
import XCTest
@testable import RexKit

/// `RexControl` against a WebSocket server in this process: what it tells its observers when it
/// connects again, and how a call fails before and after it left.
@MainActor
final class ControlReconnectTests: XCTestCase {
    /// Answers a hello with a welcome and nothing else, so calls stay open until it drops them.
    final class Server: @unchecked Sendable {
        // Everything runs on `queue`.
        private let queue = DispatchQueue(label: "test.control.server")
        private let listener: NWListener
        private var connections: [NWConnection] = []
        private var requests = 0

        /// `answersPings: false` is a connection that is half open: it takes messages but never
        /// answers a ping.
        init(answersPings: Bool = true) throws {
            let ws = NWProtocolWebSocket.Options()
            ws.autoReplyPing = answersPings
            ws.setClientRequestHandler(queue) { protocols, _ in
                NWProtocolWebSocket.Response(status: .accept, subprotocol: protocols.first)
            }
            let params = NWParameters.tcp
            params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
            listener = try NWListener(using: params, on: .any)
            listener.newConnectionHandler = { [weak self] c in
                guard let self else { return }
                self.connections.append(c)
                c.start(queue: self.queue)
                self.receive(c)
            }
        }

        func start() async -> UInt16 {
            await withCheckedContinuation { done in
                listener.stateUpdateHandler = { [listener] state in
                    if case .ready = state {
                        listener.stateUpdateHandler = nil
                        done.resume(returning: listener.port?.rawValue ?? 0)
                    }
                }
                listener.start(queue: queue)
            }
        }

        private func receive(_ c: NWConnection) {
            c.receiveMessage { [weak self] data, _, _, error in
                guard let self, error == nil, let data else { return }
                let text = String(decoding: data, as: UTF8.self)
                if text.contains("\"hello\"") {
                    let welcome = #"{"type":"welcome","protocol":"rex.control.v1","limits":{"max_message_bytes":1048576},"client":{"id":"client:test","reconnect_token":"t"}}"#
                    let meta = NWProtocolWebSocket.Metadata(opcode: .text)
                    let ctx = NWConnection.ContentContext(identifier: "welcome", metadata: [meta])
                    c.send(content: Data(welcome.utf8), contentContext: ctx, completion: .idempotent)
                } else {
                    self.requests += 1
                }
                self.receive(c)
            }
        }

        var requestCount: Int { queue.sync { requests } }

        /// Cuts every connection, as a network that went away does.
        func dropAll() {
            queue.sync {
                for c in connections { c.cancel() }
                connections = []
            }
        }

        func stop() { queue.sync { listener.cancel(); for c in connections { c.cancel() } } }
    }

    /// A schedule with no jitter: the first retry comes after exactly 1 s, so a test that says
    /// "at once, not after the backoff" tells the two apart every run. With the app's schedule
    /// the first retry falls anywhere from 0 to 1 s.
    static func steady() -> ReconnectGovernor {
        var policy = ReconnectPolicy()
        policy.fullJitterFirst = false
        policy.jitter = 0
        return ReconnectGovernor(policy: policy)
    }

    func testObserversHearEveryConnectAndCallsFailByWhetherTheyLeft() async throws {
        let server = try Server()
        let port = await server.start()
        defer { server.stop() }
        let control = RexControl(address: "http://127.0.0.1:\(port)", client: ClientInfo(name: "test", version: "0", label: "test"),
                                 governor: Self.steady())
        defer { control.disconnect() }

        var connects = 0
        var once = 0
        control.observeConnected { connects += 1; return true }
        control.observeConnected { once += 1; return false }

        // Not connected yet: the call never leaves.
        do {
            try await control.call("session.list")
            XCTFail("a call without a connection must fail")
        } catch {
            XCTAssertEqual((error as? RexError)?.neverSent, true)
        }

        try await control.connect()
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(connects, 1)
        XCTAssertEqual(once, 1)

        // A call that is out when the connection breaks: sent, with no answer.
        let lost = Task { @MainActor () -> Error? in
            do { try await control.call("session.list"); return nil } catch { return error }
        }
        let arrived = await eventually { server.requestCount == 1 }
        XCTAssertTrue(arrived)
        server.dropAll()
        let error = await lost.value
        XCTAssertNotNil(error)
        XCTAssertEqual((error as? RexError)?.neverSent, false, "it left: sending it again could run it twice")
        XCTAssertNotEqual(control.state, .connected)

        // `RexControl` retries by itself (after 1 s); the observer hears when it is back.
        var back = false
        for _ in 0..<500 where !back {
            back = connects == 2
            if !back { try? await Task.sleep(for: .milliseconds(10)) }
        }
        XCTAssertEqual(connects, 2)
        XCTAssertEqual(once, 1, "an observer that returned false is gone")
        XCTAssertEqual(control.state, .connected)
    }

    private func waitFor(_ condition: @MainActor () -> Bool, seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }

    func testEveryConnectStartsTheEchoGateAgain() async throws {
        let server = try Server()
        let port = await server.start()
        defer { server.stop() }
        let control = RexControl(address: "http://127.0.0.1:\(port)", client: ClientInfo(name: "test", version: "0", label: "test"),
                                 governor: Self.steady())
        defer { control.disconnect() }
        let gate = EchoGate()
        gate.follow(control)
        var resets = 0
        _ = gate.watch(changed: { _ in }, reset: { resets += 1 })
        try await control.connect()
        XCTAssertEqual(resets, 1)
        // Samples of this connection turn predictions on.
        for i in 0..<8 { gate.sample(ms: 150, at: Double(i) * 0.2) }
        XCTAssertEqual(gate.level, .slow)
        // The connection drops and comes back: what was measured is of the old one.
        server.dropAll()
        let back = await waitFor({ resets == 2 }, seconds: 5)
        XCTAssertTrue(back)
        XCTAssertEqual(gate.level, .off)
        XCTAssertEqual(gate.roundTrip.samples, 0)
    }

    func testWakeKeepsALiveConnection() async throws {
        let server = try Server()
        let port = await server.start()
        defer { server.stop() }
        let control = RexControl(address: "http://127.0.0.1:\(port)", client: ClientInfo(name: "test", version: "0", label: "test"),
                                 governor: Self.steady())
        defer { control.disconnect() }
        var connects = 0
        control.observeConnected { connects += 1; return true }
        try await control.connect()

        control.wake()
        try? await Task.sleep(for: .seconds(RexControl.wakeTimeout + 0.5))
        XCTAssertEqual(control.state, .connected)
        XCTAssertEqual(connects, 1, "a connection that answers the ping is kept")
    }

    func testADropRightAfterWakeRetriesAtOnce() async throws {
        // A socket that died while the app was suspended answers no ping. One that answers
        // would be a live connection, and a pong that beat the drop to the phone (the server
        // replies to pings by itself, and on a busy machine it can do so before `dropAll`)
        // rightly sends the drop that follows it through the backoff.
        let server = try Server(answersPings: false)
        let port = await server.start()
        defer { server.stop() }
        let control = RexControl(address: "http://127.0.0.1:\(port)", client: ClientInfo(name: "test", version: "0", label: "test"),
                                 governor: Self.steady())
        defer { control.disconnect() }
        var connects = 0
        var waits: [Double] = []
        control.observeConnected { connects += 1; return true }
        control.onRetryScheduled = { waits.append($0) }
        try await control.connect()

        // The socket died while the app was suspended and fails as the app wakes.
        control.wake()
        server.dropAll()
        // 3 s only guards against a hang: the wait the drop was given is what tells "at once"
        // from "after the 1 s backoff", however long the machine takes to connect again.
        let back = await waitFor({ connects == 2 }, seconds: 3)
        XCTAssertTrue(back)
        XCTAssertEqual(waits.first, 0, "not after the 1 s backoff")
    }

    func testWakeDropsAConnectionThatDoesNotAnswer() async throws {
        let server = try Server(answersPings: false)
        let port = await server.start()
        defer { server.stop() }
        let control = RexControl(address: "http://127.0.0.1:\(port)", client: ClientInfo(name: "test", version: "0", label: "test"),
                                 governor: Self.steady())
        defer { control.disconnect() }
        var connects = 0
        var waits: [Double] = []
        control.observeConnected { connects += 1; return true }
        control.onRetryScheduled = { waits.append($0) }
        try await control.connect()

        control.wake()
        let back = await waitFor({ connects == 2 }, seconds: RexControl.wakeTimeout + 3)
        XCTAssertTrue(back, "no pong: the connection is made again")
        XCTAssertEqual(waits.first, 0, "at once, not after a backoff")
    }
}
