import Foundation
import Network
import Testing
@testable import RexKit

/// A Rex server in this process: answers a hello with a welcome and each request from a table.
private final class FakeRex: @unchecked Sendable {
    // Everything runs on `queue`.
    private let queue = DispatchQueue(label: "test.identity.server")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var open = 0
    private var asked: [String] = []
    private let replies: [String: String]
    private let welcomes: Bool

    /// `replies`: method → payload JSON. A method not in it gets no answer.
    init(replies: [String: String], welcomes: Bool = true) throws {
        self.replies = replies
        self.welcomes = welcomes
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
            c.stateUpdateHandler = { [weak self] state in
                if case .cancelled = state { self?.open -= 1 }
                if case .failed = state { self?.open -= 1 }
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
    func stop() { queue.sync { listener.cancel(); for c in connections { c.cancel() } } }

    private func send(_ text: String, on c: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        c.send(content: Data(text.utf8), contentContext: ctx, completion: .idempotent)
    }

    private func receive(_ c: NWConnection) {
        c.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            if let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata,
               meta.opcode == .close {
                c.cancel()
                return
            }
            guard let data, let m = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                self.receive(c)
                return
            }
            if m["type"] as? String == "hello" {
                if self.welcomes {
                    self.send(#"{"type":"welcome","protocol":"rex.control.v1","limits":{"max_message_bytes":1048576},"client":{"id":"client:test","reconnect_token":"t"}}"#, on: c)
                }
            } else if let id = m["id"] as? String, let method = m["method"] as? String {
                self.asked.append(method)
                if let payload = self.replies[method] {
                    self.send(#"{"type":"response","id":"\#(id)","payload":\#(payload)}"#, on: c)
                }
            }
            self.receive(c)
        }
    }
}

@MainActor
struct ServerIdentityTests {
    private func object(_ json: String) -> JSONObject {
        (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? JSONObject ?? [:]
    }

    static let status = #"{"session_count":3,"tailscale":{"dns_name":"studio-rex.tail1234.ts.net","account":{"login_name":"abe@example.com"}}}"#
    static let version = #"{"rex_version":"0.1.0","platform":"darwin_arm64","api_revision":14}"#
    static let whoami = #"{"principal":{"kind":"tailscale","login_name":"Abe@Example.com","node":"iphone"},"account":"abe"}"#
    static let sessions = #"{"sessions":[{"session_id":"s1","label":"api"},{"session_id":"s2","label":"web"},{"session_id":"s3","label":""}]}"#
    static let clients = #"{"clients":[{"client_id":"c1","info":{"kind":"app","name":"Rex.app"}},{"client_id":"c2","info":{"name":"rex-push-relay"},"connection_state":"connected"}]}"#
    static let all = ["server.status": status, "server.version": version, "server.whoami": whoami,
                      "session.list": sessions, "client.list": clients]

    private func identity(status: String = status, version: String = version, whoami: String = whoami,
                          sessions: String = sessions, clients: String = clients) -> ServerIdentity {
        ServerIdentity(status: object(status), version: object(version), whoami: object(whoami),
                       sessions: object(sessions), clients: object(clients))
    }

    // MARK: Parsing

    @Test func readsTheFiveReplies() {
        let id = identity()
        #expect(id.platform == .mac)
        #expect(id.account == "abe")
        #expect(id.owner == "abe@example.com")
        #expect(id.viewer == "Abe@Example.com")
        #expect(id.sessionCount == 3)
        // An unnamed session counts but has no label to show.
        #expect(id.sessions == ["api", "web"])
        #expect(id.hasHelper)
    }

    @Test func tellsThePlatformFromRexsBuildTarget() {
        #expect(ServerIdentity.platform("darwin_arm64") == .mac)
        #expect(ServerIdentity.platform("Darwin_amd64") == .mac)
        #expect(ServerIdentity.platform("linux_amd64") == .linux)
        #expect(ServerIdentity.platform("windows_amd64") == .other)
        #expect(ServerIdentity.platform(nil) == .other)
    }

    @Test func emptyOrMalformedRepliesLeaveFieldsEmpty() {
        let id = identity(status: "{}", version: "[]", whoami: #"{"account":"  "}"#, sessions: #"{"sessions":null}"#, clients: "{}")
        #expect(id == ServerIdentity())
        // The list is the count when the status has none.
        #expect(identity(status: "{}").sessionCount == 3)
    }

    @Test func aHelperThatDroppedDoesNotCount() {
        let lost = #"{"clients":[{"client_id":"c2","info":{"name":"rex-push-relay"},"connection_state":"lost"}]}"#
        #expect(!identity(clients: lost).hasHelper)
        let both = #"{"clients":[{"info":{"name":"rex-push-relay"},"connection_state":"lost"},{"info":{"name":"rex-push-relay"}}]}"#
        #expect(identity(clients: both).hasHelper)
        #expect(!identity(clients: #"{"clients":[{"info":{"name":"rex"}}]}"#).hasHelper)
    }

    // MARK: Whose computer

    @Test func ownerAndViewerAreComparedWithoutCase() {
        #expect(!identity().belongsToSomeoneElse)
        let other = #"{"session_count":0,"tailscale":{"account":{"login_name":"sam@example.com"}}}"#
        #expect(identity(status: other).belongsToSomeoneElse)
    }

    @Test func anUnknownOwnerOrViewerIsNotAMismatch() {
        #expect(!identity(status: "{}").belongsToSomeoneElse)
        // Reached without a private-network login (a local address): nothing to compare.
        #expect(!identity(whoami: #"{"principal":{"kind":"peer"},"account":"abe"}"#).belongsToSomeoneElse)
    }

    // MARK: Over a connection

    private let me = ClientInfo(name: "test", version: "0", label: "test")

    @Test func fetchesOverOneConnectionAndClosesIt() async throws {
        let server = try FakeRex(replies: Self.all)
        let port = await server.start()
        defer { server.stop() }
        let id = await ServerPreview.fetch(address: "http://127.0.0.1:\(port)", client: me)
        #expect(id == identity())
        #expect(Set(server.methods) == ["server.status", "server.version", "server.whoami", "session.list", "client.list"])
        #expect(server.methods.count == 5)
        // Closed: nothing is left for the server to keep.
        for _ in 0..<200 where server.openConnections != 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(server.openConnections == 0)
    }

    @Test func aServerThatAnswersSomeCallsGivesWhatItAnswered() async throws {
        let server = try FakeRex(replies: ["server.version": #"{"platform":"linux_amd64"}"#, "session.list": Self.sessions])
        let port = await server.start()
        defer { server.stop() }
        let id = await ServerPreview.fetch(address: "http://127.0.0.1:\(port)", client: me, timeout: 0.5)
        #expect(id?.platform == .linux)
        #expect(id?.sessions == ["api", "web"])
        #expect(id?.account == nil)
    }

    @Test func noWelcomeInTimeGivesNothing() async throws {
        let server = try FakeRex(replies: Self.all, welcomes: false)
        let port = await server.start()
        defer { server.stop() }
        let started = Date()
        let id = await ServerPreview.fetch(address: "http://127.0.0.1:\(port)", client: me, timeout: 0.3)
        #expect(id == nil)
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func nothingListeningGivesNothing() async {
        #expect(await ServerPreview.fetch(address: "http://127.0.0.1:1", client: me, timeout: 1) == nil)
        #expect(await ServerPreview.fetch(address: "not an address", client: me, timeout: 1) == nil)
    }

    @Test func cancellingEndsTheFetch() async throws {
        let server = try FakeRex(replies: [:])
        let port = await server.start()
        defer { server.stop() }
        let started = Date()
        let task = Task { await ServerPreview.fetch(address: "http://127.0.0.1:\(port)", client: me, timeout: 30) }
        try await Task.sleep(nanoseconds: 200_000_000)
        task.cancel()
        #expect(await task.value == nil)
        #expect(Date().timeIntervalSince(started) < 5)
    }
}
