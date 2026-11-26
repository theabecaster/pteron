import Foundation
import Network
import Testing
@testable import RexKit

/// A Rex server in this process: answers a hello with a welcome and each request from a table.
/// A test waits for what the server saw (`receivedCalls`, `noneOpen`), never for a time.
private final class FakeRex: @unchecked Sendable {
    // Everything runs on `queue`.
    private let queue = DispatchQueue(label: "test.identity.server")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var open = 0
    private var asked: [String] = []
    private var live: Set<ObjectIdentifier> = []
    private var endings: [String] = []
    private var helloLabels: [String] = []
    private var waits: [(ready: @Sendable () -> Bool, done: CheckedContinuation<Void, Never>)] = []
    private let replies: [String: String]
    private let welcomes: Bool
    private let hangUpAfter: Int?

    /// `replies`: method → payload JSON. A method not in it gets no answer. `hangUpAfter`: after
    /// that many calls the server closes the connection, which ends whatever is still waiting.
    init(replies: [String: String], welcomes: Bool = true, hangUpAfter: Int? = nil) throws {
        self.replies = replies
        self.welcomes = welcomes
        self.hangUpAfter = hangUpAfter
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.setClientRequestHandler(queue) { protocols, _ in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: protocols.first)
        }
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params, on: .any)
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            self.connections.append(c)
            self.open += 1
            let id = ObjectIdentifier(c)
            self.live.insert(id)
            c.stateUpdateHandler = { [weak self] state in
                switch state {
                // Counted once: a connection that fails is then also cancelled.
                case .cancelled, .failed:
                    if self?.live.remove(id) != nil { self?.open -= 1 }
                    self?.changed()
                default: break
                }
            }
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

    var methods: [String] { queue.sync { asked } }
    var openConnections: Int { queue.sync { open } }
    /// How the client ended each connection, as the server saw it: "close frame 1000", "end of
    /// stream" (its side closed with no close frame), or the error.
    var ends: [String] { queue.sync { endings } }
    /// Hellos from the client with this label: one per attempt it made. Counted by label, so a
    /// connection that isn't that client's (another test's, or one URLSession opened and dropped
    /// without a hello) is not counted.
    func hellos(from label: String) -> Int { queue.sync { helloLabels.filter { $0 == label }.count } }
    func stop() { queue.sync { listener.cancel(); for c in connections { c.cancel() } } }

    /// Returns once the server has received `n` calls.
    func receivedCalls(_ n: Int) async { await until { self.asked.count >= n } }
    /// Returns once no connection is open: every one made has ended.
    func noneOpen() async { await until { self.open == 0 } }

    /// Returns once `ready`, read on `queue`, holds: checked now and after every change.
    private func until(_ ready: @escaping @Sendable () -> Bool) async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            queue.async {
                if ready() { done.resume() } else { self.waits.append((ready, done)) }
            }
        }
    }

    private func changed() {
        waits.removeAll { w in
            guard w.ready() else { return false }
            w.done.resume()
            return true
        }
    }

    private func send(_ text: String, on c: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        c.send(content: Data(text.utf8), contentContext: ctx, completion: .idempotent)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               meta.opcode == .close {
                if case .protocolCode(let code) = meta.closeCode {
                    self.endings.append("close frame \(code.rawValue)")
                } else {
                    self.endings.append("close frame \(meta.closeCode)")
                }
                // Answer with a close frame, as the protocol asks, then hang up.
                let reply = NWProtocolWebSocket.Metadata(opcode: .close)
                reply.closeCode = meta.closeCode
                let ctx = NWConnection.ContentContext(identifier: "close", metadata: [reply])
                c.send(content: nil, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
                return
            }
            // The client's side of the socket is gone without a close frame. A server closes its
            // side too: an NWConnection stays `ready` after the peer's end of file until then.
            if error != nil || (data == nil && context == nil) {
                // ENODATA is how the WebSocket protocol reports a stream that ended with no close frame.
                if error == nil || error == .posix(.ENODATA) {
                    self.endings.append("end of stream")
                } else {
                    self.endings.append("error \(error.map { "\($0)" } ?? "")")
                }
                c.cancel()
                return
            }
            guard let data, let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                self.receive(c)
                return
            }
            if m["type"] as? String == "hello" {
                self.helloLabels.append(((m["client"] as? [String: Any])?["label"] as? String) ?? "")
                self.changed()
                if self.welcomes {
                    self.send(#"{"type":"welcome","protocol":"rex.control.v1","limits":{"max_message_bytes":1048576},"client":{"id":"client:test","reconnect_token":"t"}}"#, on: c)
                }
            } else if let id = m["id"] as? String, let method = m["method"] as? String {
                self.asked.append(method)
                if let payload = self.replies[method] {
                    self.send(#"{"type":"response","id":"\#(id)","payload":\#(payload)}"#, on: c)
                }
                self.changed()
                if self.asked.count == self.hangUpAfter {
                    // After the replies, which go out first on the same connection.
                    let close = NWProtocolWebSocket.Metadata(opcode: .close)
                    close.closeCode = .protocolCode(.goingAway)
                    let ctx = NWConnection.ContentContext(identifier: "close", metadata: [close])
                    c.send(content: nil, contentContext: ctx, isComplete: true, completion: .contentProcessed { _ in c.cancel() })
                    return
                }
            }
            self.receive(c)
        }
    }
}

// A test that waits for an event the server never sees fails at this limit instead of hanging.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ServerIdentityTests {
    private func object(_ json: String) -> JSONObject {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? JSONObject ?? [:]
    }

    static let status = #"{"session_count":3,"tailscale":{"dns_name":"studio-rex.tail1234.ts.net","account":{"login_name":"alex@example.com"}}}"#
    static let version = #"{"rex_version":"0.1.0","platform":"darwin_arm64","api_revision":14}"#
    static let whoami = #"{"principal":{"kind":"tailscale","login_name":"Alex@Example.com","node":"iphone"},"account":"alex"}"#
    static let sessions = #"{"sessions":[{"session_id":"s1","label":"api"},{"session_id":"s2","label":"web"},{"session_id":"s3","label":""}]}"#
    static let clients = #"{"clients":[{"client_id":"c1","info":{"kind":"app","name":"Rex.app"}},{"client_id":"c2","info":{"name":"rex-push-relay"},"connection_state":"connected"}]}"#
    static let all = ["server.status": status, "server.version": version, "server.whoami": whoami,
                      "session.list": sessions, "client.list": clients]

    /// A nil argument is a call that got no reply.
    private func identity(status: String? = status, version: String? = version, whoami: String? = whoami,
                          sessions: String? = sessions, clients: String? = clients) -> ServerIdentity {
        ServerIdentity(status: status.map(object), version: version.map(object), whoami: whoami.map(object),
                       sessions: sessions.map(object), clients: clients.map(object))
    }

    // MARK: Parsing

    @Test func readsTheFiveReplies() {
        let id = identity()
        #expect(id.platform == .mac)
        #expect(id.account == "alex")
        #expect(id.owner == "alex@example.com")
        #expect(id.viewer == "Alex@Example.com")
        #expect(id.sessionCount == 3)
        // An unnamed session counts but has no label to show.
        #expect(id.sessions == ["api", "web"])
        #expect(id.hasHelper == true)
    }

    @Test func tellsThePlatformFromRexsBuildTarget() {
        #expect(ServerIdentity.platform("darwin_arm64") == .mac)
        #expect(ServerIdentity.platform("Darwin_amd64") == .mac)
        #expect(ServerIdentity.platform("linux_amd64") == .linux)
        #expect(ServerIdentity.platform("windows_amd64") == .other)
    }

    @Test func aCallWithNoReplyLeavesItsFieldsUnknownNotEmpty() {
        // Nothing answered: nothing is known, and nothing reads as "none" or "no".
        let none = identity(status: nil, version: nil, whoami: nil, sessions: nil, clients: nil)
        #expect(none == ServerIdentity())
        #expect(none.sessionCount == nil && none.hasHelper == nil && none.platform == nil)

        // The client list failed: whether a helper is there is unknown, not "no".
        #expect(identity(clients: nil).hasHelper == nil)
        // The session list failed: the status still has the count, with no names.
        let counted = identity(sessions: nil)
        #expect(counted.sessionCount == 3 && counted.sessions.isEmpty)
        // Both failed: unknown, not zero.
        #expect(identity(status: nil, sessions: nil).sessionCount == nil)
    }

    @Test func aReplyWithoutTheFieldLeavesItUnknown() {
        let id = identity(status: "{}", version: "[]", whoami: #"{"account":"  "}"#, sessions: #"{"sessions":null}"#, clients: "{}")
        #expect(id == ServerIdentity())
        // The list is the count when the status has none.
        #expect(identity(status: "{}").sessionCount == 3)
    }

    @Test func aServerThatSaysSoHasNoSessionsAndNoHelper() {
        let id = identity(status: #"{"session_count":0}"#, sessions: #"{"sessions":[]}"#, clients: #"{"clients":[]}"#)
        #expect(id.sessionCount == 0)
        #expect(id.hasHelper == false)
    }

    @Test func aHelperThatDroppedDoesNotCount() {
        let lost = #"{"clients":[{"client_id":"c2","info":{"name":"rex-push-relay"},"connection_state":"lost"}]}"#
        #expect(identity(clients: lost).hasHelper == false)
        let both = #"{"clients":[{"info":{"name":"rex-push-relay"},"connection_state":"lost"},{"info":{"name":"rex-push-relay"}}]}"#
        #expect(identity(clients: both).hasHelper == true)
        #expect(identity(clients: #"{"clients":[{"info":{"name":"rex"}}]}"#).hasHelper == false)
    }

    // MARK: Whose computer

    @Test func ownerAndViewerAreComparedWithoutCase() {
        #expect(!identity().belongsToSomeoneElse)
        let other = #"{"session_count":0,"tailscale":{"account":{"login_name":"sam@example.com"}}}"#
        #expect(identity(status: other).belongsToSomeoneElse)
    }

    @Test func anUnknownOwnerOrViewerIsNotAMismatch() {
        let other = #"{"tailscale":{"account":{"login_name":"sam@example.com"}}}"#
        #expect(!identity(status: "{}").belongsToSomeoneElse)
        #expect(!identity(status: other, whoami: nil).belongsToSomeoneElse)
        // Reached without a private-network login (a local connection): nothing to compare.
        #expect(!identity(status: other, whoami: #"{"principal":{"kind":"peer","login_name":"alex@example.com"},"account":"alex"}"#).belongsToSomeoneElse)
    }

    @Test func machinesAndNamesThatAreNotLoginsAreNotCompared() {
        // A tagged server has no owner; a tagged device isn't a person.
        let tagged = #"{"tailscale":{"account":{"login_name":"sam@example.com"},"tags":["tag:rex"]}}"#
        #expect(identity(status: tagged).owner == nil)
        #expect(!identity(status: tagged).belongsToSomeoneElse)
        let runner = #"{"principal":{"kind":"tailscale","login_name":"ci@example.com","tags":["tag:ci"]},"account":"alex"}"#
        #expect(identity(whoami: runner).viewer == nil)
        // Not account logins: a tag as a name, a device name, a placeholder.
        for name in ["tagged-devices", "tag:server", "iphone194", "alex@", "@example.com", "a b@example.com", ""] {
            #expect(ServerIdentity.login(name) == nil, "\(name)")
            let status = #"{"tailscale":{"account":{"login_name":"\#(name)"}}}"#
            #expect(!identity(status: status).belongsToSomeoneElse, "\(name)")
        }
        #expect(ServerIdentity.login(" alex@example.com ") == "alex@example.com")
    }

    @Test func onlyTwoKnownEqualLoginsAreConfirmedOwn() {
        // The same account, in another case.
        #expect(identity().isConfirmedOwn)
        let other = #"{"tailscale":{"account":{"login_name":"sam@example.com"}}}"#
        #expect(!identity(status: other).isConfirmedOwn)
        // Unknown owner, unknown viewer, a local connection: not confirmed, and not someone else's.
        #expect(!identity(status: "{}").isConfirmedOwn)
        #expect(!identity(whoami: nil).isConfirmedOwn)
        #expect(!identity(whoami: #"{"principal":{"kind":"peer","login_name":"alex@example.com"},"account":"alex"}"#).isConfirmedOwn)
        // A tagged server has no owner, and a tagged device isn't a person.
        let tagged = #"{"tailscale":{"account":{"login_name":"alex@example.com"},"tags":["tag:rex"]}}"#
        #expect(!identity(status: tagged).isConfirmedOwn)
        let runner = #"{"principal":{"kind":"tailscale","login_name":"alex@example.com","tags":["tag:ci"]},"account":"alex"}"#
        #expect(!identity(whoami: runner).isConfirmedOwn)
        // A name that isn't an account login is never a match, even with itself.
        let device = #"{"tailscale":{"account":{"login_name":"tagged-devices"}}}"#
        let same = #"{"principal":{"kind":"tailscale","login_name":"tagged-devices"},"account":"alex"}"#
        #expect(!identity(status: device, whoami: same).isConfirmedOwn)
        #expect(!ServerIdentity().isConfirmedOwn)
    }

    // MARK: Over a connection

    /// A client with a label of its own, so the server counts only this test's attempts.
    private func client() -> ClientInfo {
        ClientInfo(name: "test", version: "0", label: "test-\(UUID().uuidString.prefix(8))")
    }

    @Test func fetchesOverOneConnectionAndClosesIt() async throws {
        let server = try FakeRex(replies: Self.all)
        let port = await server.start()
        defer { server.stop() }
        let me = client()
        let id = await ServerPreview.fetch(address: "http://127.0.0.1:\(port)", client: me)
        #expect(id == identity())
        #expect(Set(server.methods) == ["server.status", "server.version", "server.whoami", "session.list", "client.list"])
        #expect(server.methods.count == 5)
        // Closed: nothing is left for the server to keep.
        await server.noneOpen()
        #expect(server.hellos(from: me.label) == 1)
        // Ended by the client as a WebSocket ends: a close frame, then the end of the stream, and
        // never a reset. URLSession sends the frame on a Mac or a phone, but on GitHub's virtual
        // Macs it almost never does, whatever the client waits for, and the stream just ends.
        // That the client asks for the close frame is tested at the socket (`ControlTimingTests`).
        #expect(server.ends == ["close frame 1000"] || server.ends == ["end of stream"], "the server saw: \(server.ends)")
    }

    @Test func aServerThatAnswersSomeCallsGivesWhatItAnswered() async throws {
        // The server hangs up after the five calls, which ends the three it didn't answer.
        let server = try FakeRex(replies: ["server.version": #"{"platform":"linux_amd64"}"#, "session.list": Self.sessions],
                                 hangUpAfter: 5)
        let port = await server.start()
        defer { server.stop() }
        let id = await ServerPreview.fetch(address: "http://127.0.0.1:\(port)", client: client(), timeout: 30)
        #expect(id?.platform == .linux)
        #expect(id?.sessions == ["api", "web"])
        #expect(id?.sessionCount == 3)
        // The calls that got no answer are unknown, not "no helper" or "nobody".
        #expect(id?.account == nil)
        #expect(id?.hasHelper == nil)
    }

    @Test func noWelcomeInTimeGivesNothing() async throws {
        let server = try FakeRex(replies: Self.all, welcomes: false)
        let port = await server.start()
        defer { server.stop() }
        let me = client()
        let started = Date()
        let id = await ServerPreview.fetch(address: "http://127.0.0.1:\(port)", client: me, timeout: 0.3)
        #expect(id == nil)
        // Ended by the fetch's timeout: without it, only the connection's own welcome deadline
        // would end the attempt.
        #expect(Date().timeIntervalSince(started) < ReconnectPolicy.standard.connectDeadline(expensive: false))
        await server.noneOpen()
        // At most one attempt: none if the timeout came before the hello on a slow machine. That
        // a disconnect never tries again is tested on a clock the test moves (`ControlTimingTests`).
        #expect(server.hellos(from: me.label) <= 1)
    }

    @Test func nothingListeningGivesNothing() async {
        #expect(await ServerPreview.fetch(address: "http://127.0.0.1:1", client: client(), timeout: 1) == nil)
        #expect(await ServerPreview.fetch(address: "not an address", client: client(), timeout: 1) == nil)
    }

    @Test func cancellingEndsTheFetch() async throws {
        let server = try FakeRex(replies: [:])
        let port = await server.start()
        defer { server.stop() }
        let me = client()
        let started = Date()
        let task = Task { await ServerPreview.fetch(address: "http://127.0.0.1:\(port)", client: me, timeout: 30) }
        // Cancelled once the five calls wait for answers that never come.
        await server.receivedCalls(5)
        task.cancel()
        #expect(await task.value == nil)
        // Ended by the cancel, not by the timeout.
        #expect(Date().timeIntervalSince(started) < 30)
        // Cancelled means closed, after one attempt.
        await server.noneOpen()
        #expect(server.hellos(from: me.label) == 1)
    }
}
