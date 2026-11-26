import Foundation
import Network
import RexKit

/// A Rex control server in this process, for tests: it answers a hello with the welcome of the
/// revision it plays, answers requests from a table, sends events and closes with a code and a
/// reason. The app's tests compile this file too (project.yml), so it uses RexKit's public API only.
final class FakeRexServer: @unchecked Sendable {
    // `@unchecked`: every stored property is read and written on `queue`.

    enum Reply {
        case result(JSONObject)
        case error(code: String, status: Int)
        /// No answer: the call stays open.
        case none
    }

    struct Request {
        var method: String
        var payload: JSONObject
    }

    private let queue = DispatchQueue(label: "test.fake-rex")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private var revision: Int?
    private var serverRevision: Int?
    private var features: [String]?
    private var refusal: (code: UInt16, reason: String)?
    private var replies: [String: Reply] = [:]
    private var fallback: Reply = .error(code: "method_not_found", status: 404)
    private var delays: [String: Double] = [:]
    private var handler: (@Sendable (Request) -> Reply?)?
    private var hellos: [JSONObject] = []
    private var helloBytes: [Int] = []
    private var received: [Request] = []
    private var seq = 0
    /// Every message read from a client, the undecodable ones too; whether a read is waiting;
    /// the error that ended the reads of a connection.
    private var frames = 0
    private var reading = 0
    private var readError: String?
    private var clients = 0

    /// `revision` is the welcome's `api_revision`; nil leaves the field out, as servers from
    /// before revisions do. `serverRevision` is `api_server_revision`, left out when nil.
    init(revision: Int? = 18, serverRevision: Int? = nil, features: [String]? = nil) throws {
        self.revision = revision
        self.serverRevision = serverRevision
        self.features = features
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.setClientRequestHandler(queue) { protocols, _ in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: protocols.first)
        }
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        // On the loopback address alone, where `start()` sends the client. A listener on every
        // address can be given a port that another program already holds on 127.0.0.1, and a
        // connection to 127.0.0.1 then reaches that program instead of this server.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] c in
            guard let self else { return }
            self.connections.append(c)
            c.start(queue: self.queue)
            self.receive(c)
        }
    }

    /// Starts listening and returns the address to connect to.
    func start() async -> String {
        let port: UInt16 = await withCheckedContinuation { done in
            listener.stateUpdateHandler = { [listener] state in
                if case .ready = state {
                    listener.stateUpdateHandler = nil
                    done.resume(returning: listener.port?.rawValue ?? 0)
                }
            }
            listener.start(queue: queue)
        }
        return "http://127.0.0.1:\(port)"
    }

    func stop() {
        queue.sync {
            listener.cancel()
            for c in connections { c.cancel() }
            connections = []
        }
    }

    // MARK: Script

    /// The revision the next welcome names: the server was updated or downgraded.
    func play(revision: Int?, serverRevision: Int? = nil) {
        queue.sync { self.revision = revision; self.serverRevision = serverRevision }
    }

    /// From now on a hello is answered with this close instead of a welcome. Nil welcomes again.
    func refuse(code: UInt16, reason: String) { queue.sync { refusal = (code, reason) } }
    func acceptAgain() { queue.sync { refusal = nil } }

    func reply(_ method: String, _ reply: Reply) { queue.sync { replies[method] = reply } }
    func reply(_ method: String, _ result: JSONObject) { reply(method, .result(result)) }
    /// Answers to this method leave that many seconds late. 0 answers at once again.
    func delay(_ method: String, seconds: Double) { queue.sync { delays[method] = seconds } }
    /// What a method without an entry gets. A real server says `method_not_found`.
    func replyOtherwise(_ reply: Reply) { queue.sync { fallback = reply } }
    /// Asked first for every request; nil falls through to the table.
    func onRequest(_ body: @escaping @Sendable (Request) -> Reply?) { queue.sync { handler = body } }

    /// Sends a top-level event to every connection.
    func send(event type: String, _ payload: JSONObject = [:]) {
        queue.sync {
            seq += 1
            let m: JSONObject = ["type": "event", "seq": seq, "payload": ["type": type, "payload": payload] as JSONObject]
            for c in connections { sendText(c, JSONCodec.encode(m)) }
        }
    }

    /// Sends an event wrapped in `session_event`.
    func send(session: String, event type: String, _ payload: JSONObject = [:]) {
        send(event: "session_event", ["session_id": session, "event": ["type": type, "payload": payload] as JSONObject])
    }

    /// Closes every connection with a close frame.
    func close(code: UInt16, reason: String) {
        queue.sync {
            for c in connections { sendClose(c, code: code, reason: reason) }
            connections = []
        }
    }

    /// Cuts every connection with no close frame, as a network that went away does.
    func dropAll() {
        queue.sync {
            for c in connections { c.cancel() }
            connections = []
        }
    }

    // MARK: What it saw

    var helloCount: Int { queue.sync { hellos.count } }
    var lastHello: JSONObject? { queue.sync { hellos.last } }
    var lastHelloBytes: Int { queue.sync { helloBytes.last ?? 0 } }
    var requests: [Request] { queue.sync { received } }
    /// The `seq` of the last event sent on the current connections.
    var eventSeq: Int { queue.sync { seq } }
    var connectionCount: Int { queue.sync { connections.count } }
    /// What the reads saw, for a failure's message.
    var reads: String { queue.sync { "frames \(frames) waiting \(reading) error \(readError ?? "-")" } }
    func count(_ method: String) -> Int { queue.sync { received.filter { $0.method == method }.count } }
    func calls(_ method: String) -> [JSONObject] { queue.sync { received.filter { $0.method == method }.map(\.payload) } }
    func forget() { queue.sync { received = [] } }

    // MARK: Socket

    private func receive(_ c: NWConnection) {
        reading += 1
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            self.reading -= 1
            self.frames += 1
            guard error == nil, let data else {
                self.readError = error.map { "\($0)" } ?? "no data"
                return
            }
            guard let m = JSONCodec.decode(data) else { self.receive(c); return }
            switch m.str("type") {
            case "hello":
                self.hellos.append(m)
                self.helloBytes.append(data.count)
                if let r = self.refusal {
                    self.sendClose(c, code: r.code, reason: r.reason)
                    self.connections.removeAll { $0 === c }
                    return
                }
                self.clients += 1
                self.seq = 0
                var w: JSONObject = [
                    "type": "welcome", "protocol": "rex.control.v1",
                    "limits": ["max_message_bytes": 1_048_576] as JSONObject,
                    "client": ["id": "client:test-\(self.clients)", "reconnect_token": "t\(self.clients)"] as JSONObject,
                ]
                if let r = self.revision { w["api_revision"] = r }
                if let r = self.serverRevision { w["api_server_revision"] = r }
                if let f = self.features { w["features"] = f }
                self.sendText(c, JSONCodec.encode(w))
            case "request":
                let req = Request(method: m.str("method") ?? "", payload: m.obj("payload") ?? [:])
                self.received.append(req)
                let reply = self.handler?(req) ?? self.replies[req.method] ?? self.fallback
                var out: JSONObject = ["type": "response", "id": m.str("id") ?? "", "seq": self.seq]
                switch reply {
                case .result(let r): out["payload"] = r
                case .error(let code, let status):
                    out["error"] = ["code": code, "message": "\(req.method): \(code)", "status": status] as JSONObject
                case .none: self.receive(c); return
                }
                let text = JSONCodec.encode(out)
                if let late = self.delays[req.method], late > 0 {
                    self.queue.asyncAfter(deadline: .now() + late) { self.sendText(c, text) }
                } else {
                    self.sendText(c, text)
                }
            default:
                break
            }
            self.receive(c)
        }
    }

    private func sendText(_ c: NWConnection, _ text: String) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        c.send(content: Data(text.utf8), contentContext: ctx, completion: .idempotent)
    }

    private func sendClose(_ c: NWConnection, code: UInt16, reason: String) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .close)
        meta.closeCode = (try? NWProtocolWebSocket.CloseCode(rawValue: code)) ?? .protocolCode(.policyViolation)
        let ctx = NWConnection.ContentContext(identifier: "close", metadata: [meta])
        c.send(content: Data(reason.utf8), contentContext: ctx, completion: .contentProcessed { _ in
            // The close frame is out; end the connection once the client has had it.
            self.queue.asyncAfter(deadline: .now() + 0.3) { c.cancel() }
        })
    }
}
