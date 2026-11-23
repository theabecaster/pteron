import XCTest
@testable import RexKit

/// A control connection with no server behind it. Calls are recorded and answered at once, or
/// held until the test releases them; `disconnect()` fails the held ones as a lost connection
/// does; `connect()` tells the observers, as `RexControl` does after a reconnect.
@MainActor
final class FakeLink: StreamLink {
    struct Call {
        let method: String
        let payload: JSONObject
        /// The text of a `terminal.write`.
        var text: String? { payload.obj("args")?.str("data") }
    }

    enum SocketPlan {
        /// Answers the handshake with a WELCOME that keeps the stream this long for a resume.
        case welcome(keepMs: UInt32 = 60_000)
        case reject(UInt8)
        /// The socket fails as soon as it is used: no network.
        case fail
        /// Takes the handshake and answers nothing until the test does.
        case silent
    }

    private(set) var isConnected: Bool
    var clientID: String? = "client:test"
    /// The welcome started a new client where the old one was to be continued: set by a test.
    var clientGeneration = 0
    /// As `RexControl`'s: the sessions attached on this connection and who waits for one.
    let attachWaits = AttachWaits()
    /// False: the link knows nothing of attaches (`whenAttached` answers nil), as a link that
    /// leaves the protocol's default in place.
    var tracksAttaches = true
    private(set) var notes: [ConnectionEvent] = []

    func whenAttached(_ session: String, _ done: @escaping @MainActor (Bool) -> Void) -> Int? {
        tracksAttaches ? attachWaits.wait(for: session, done) : nil
    }

    func cancelAttachWait(_ id: Int) { attachWaits.cancel(id) }
    func note(_ event: ConnectionEvent) { notes.append(event) }
    private var observers: [@MainActor () -> Bool] = []
    /// Every call that reached the "server", in order.
    private(set) var calls: [Call] = []
    /// Methods whose calls wait for `release`.
    var held: Set<String> = []
    /// Errors for the next calls of a method, thrown instead of an answer.
    var failures: [String: [Error]] = [:]
    private var waiting: [(Call, CheckedContinuation<Void, Error>)] = []

    private(set) var sockets: [FakeSocket] = []
    /// What the next sockets do, in order; `defaultPlan` after that.
    var plans: [SocketPlan] = []
    var defaultPlan = SocketPlan.welcome()
    static let nonce: UInt64 = 77

    init(connected: Bool = true) { isConnected = connected }

    func observeConnected(_ body: @escaping @MainActor () -> Bool) { observers.append(body) }

    /// The control connection is connected (again).
    func connect() {
        isConnected = true
        observers = observers.filter { $0() }
    }

    /// The control connection is lost: calls still waiting fail the way `RexControl.failAll` does.
    func disconnect() {
        isConnected = false
        attachWaits.cancelAll()
        let w = waiting
        waiting = []
        for (_, c) in w { c.resume(throwing: RexError.local("connection lost")) }
    }

    func call(_ method: String, _ payload: JSONObject?) async throws -> JSONObject {
        guard isConnected else { throw RexError.unsent("not connected") }
        if var errors = failures[method], !errors.isEmpty {
            let e = errors.removeFirst()
            failures[method] = errors
            // A request the socket didn't take never reached the server.
            if (e as? RexError)?.neverSent != true { calls.append(Call(method: method, payload: payload ?? [:])) }
            throw e
        }
        let call = Call(method: method, payload: payload ?? [:])
        calls.append(call)
        return try await answer(to: call)
    }

    /// The answer to a call that reached the "server": at once, or when the test releases it.
    private func answer(to call: Call) async throws -> JSONObject {
        let method = call.method
        if held.contains(method) {
            try await withCheckedThrowingContinuation { waiting.append((call, $0)) }
        }
        if let reply = replies[method] { return reply }
        return method == "data.connect" ? ["ticket": "AAECAwQFBgcICQoLDA0ODw"] : [:]
    }

    /// False: `start` takes nothing, and every request goes through `call`, in a task.
    var startsNow = true
    /// Errors that the next `start`s answer with before they return. `RexControl` never answers
    /// inside the call; this is the harder case, where the request ends inside `pump`.
    var startFailures: [Error] = []
    /// How many requests `start` took: they were with the "server" in the caller's turn.
    private(set) var startedNow = 0

    /// As `RexControl.start`: the request is with the socket before this returns, and its
    /// answer comes from a task, in a later turn. That holds for a planned failure of the
    /// method (`failures`) too: the socket that did not take the message says so later, and so
    /// does the connection that broke after the send. Only what `call` would refuse before the
    /// send (no connection) is left to `call`.
    func start(_ method: String, _ payload: JSONObject?, answer: @escaping @MainActor (Result<JSONObject, Error>) -> Void) -> Bool {
        guard startsNow, isConnected else { return false }
        if !startFailures.isEmpty {
            startedNow += 1
            answer(.failure(startFailures.removeFirst()))
            return true
        }
        let call = Call(method: method, payload: payload ?? [:])
        startedNow += 1
        if var errors = failures[method], !errors.isEmpty {
            let e = errors.removeFirst()
            failures[method] = errors
            // A request the socket didn't take never reached the server.
            if (e as? RexError)?.neverSent != true { calls.append(call) }
            Task { answer(.failure(e)) }
            return true
        }
        calls.append(call)
        Task {
            do { answer(.success(try await self.answer(to: call))) } catch { answer(.failure(error)) }
        }
        return true
    }

    /// Answers for methods, instead of an empty object.
    var replies: [String: JSONObject] = [:]

    /// How the control connection answers a ping; at once by default.
    var onPing: (@MainActor () async throws -> Void)?

    func ping() async throws {
        guard isConnected else { throw RexError.unsent("not connected") }
        try await onPing?()
    }

    /// How a pacing ping ends; by default as `ping()` does.
    var onProbe: (@MainActor () async -> PaceSample)?

    func paceProbe() async -> PaceSample {
        if let onProbe { return await onProbe() }
        return (try? await ping()) != nil ? .answered : .none
    }

    /// Answers the oldest held call.
    func release() {
        guard !waiting.isEmpty else { return XCTFail("no call is waiting") }
        waiting.removeFirst().1.resume()
    }

    var waitingCount: Int { waiting.count }
    func count(_ method: String) -> Int { calls.filter { $0.method == method }.count }
    var methods: [String] { calls.map(\.method) }
    /// The texts of the `terminal.write` calls, in order.
    var written: [String] { calls.compactMap(\.text) }
    /// Writes as `w:<text>` and other calls by method, in order, without the stream's own start.
    var inputTrace: [String] {
        calls.compactMap { c in
            if let t = c.text { return "w:\(t)" }
            return c.method.hasPrefix("client.") ? c.method : nil
        }
    }

    /// Hears each socket as it opens, before it is used.
    var onOpen: ((FakeSocket) -> Void)?
    /// The subprotocol of each socket opened, in order.
    private(set) var subprotocols: [String] = []

    func openDataSocket(subprotocol: String) throws -> any StreamSocket {
        subprotocols.append(subprotocol)
        let plan = plans.isEmpty ? defaultPlan : plans.removeFirst()
        let s = FakeSocket(plan)
        sockets.append(s)
        onOpen?(s)
        return s
    }

    static func welcome(keepMs: UInt32 = 60_000) -> [UInt8] {
        var b: [UInt8] = [0x81] + [UInt8](repeating: 0xAB, count: 16) + [0, 0, 0]
        for k in 0..<4 { b.append(UInt8((keepMs >> (8 * UInt32(k))) & 0xff)) }
        for k in 0..<8 { b.append(UInt8((nonce >> (8 * UInt64(k))) & 0xff)) }
        return b
    }
}

@MainActor
final class FakeSocket: StreamSocket {
    private let plan: FakeLink.SocketPlan
    private(set) var sent: [[UInt8]] = []
    private(set) var closed = false
    private(set) var closeCode = 0
    /// How often the stream asked for a message (the handshake's answer included).
    private(set) var receives = 0
    private var inbox: [Result<Data?, Error>] = []
    private var waiter: CheckedContinuation<Data?, Error>?
    /// Hears every message after the handshake.
    var onSend: ((Data) -> Void)?

    init(_ plan: FakeLink.SocketPlan) { self.plan = plan }

    var isHello: Bool { sent.first?.first == 0x01 }
    var isResume: Bool { sent.first?.first == 0x02 }
    /// The byte count of a RESUME.
    var resumeCount: UInt64? {
        guard isResume, let m = sent.first, m.count == 25 else { return nil }
        return m[17...].reversed().reduce(0) { $0 << 8 | UInt64($1) }
    }

    func send(_ data: Data) async throws {
        if case .fail = plan { throw URLError(.notConnectedToInternet) }
        sent.append([UInt8](data))
        // Only the handshake is answered; a file's bytes after it are not.
        guard sent.count == 1 else { return onSend?(data) ?? () }
        switch plan {
        case .welcome(let keep): deliver(.success(Data(FakeLink.welcome(keepMs: keep))))
        case .reject(let reason): deliver(.success(Data([0x82, reason])))
        case .fail, .silent: break
        }
    }

    func receive() async throws -> Data? {
        receives += 1
        if !inbox.isEmpty { return try inbox.removeFirst().get() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func close() {
        closed = true
        endPongs()
        deliver(.failure(URLError(.cancelled)))
    }

    enum PingPlan {
        case answer, fail, silent
        /// The ping goes through `awaitPong()` to a task that calls its handler as URLSession
        /// has: with `first`, then, when `twice`, again at once with an error, and once more with
        /// an error when the socket ends.
        case urlSession(first: TwicePongTask.Answer, twice: Bool)
    }
    /// How the socket answers a ping.
    var pingPlan = PingPlan.answer
    private(set) var pings = 0
    private(set) var aborted = false
    private var pongTasks: [TwicePongTask] = []

    func ping() async throws {
        pings += 1
        switch pingPlan {
        case .answer: return
        case .fail:
            // A dead connection fails the waiting receive too.
            deliver(.failure(URLError(.networkConnectionLost)))
            throw URLError(.networkConnectionLost)
        case .silent:
            // A half-open connection: no answer, ever.
            try await Task.sleep(for: .seconds(3600))
        case .urlSession(let first, let twice):
            let task = TwicePongTask(first, twice: twice)
            pongTasks.append(task)
            try await task.awaitPong()
        }
    }

    func abort() {
        aborted = true
        endPongs()
        deliver(.failure(URLError(.cancelled)))
    }

    /// The socket ended: URLSession calls each pong handler (again) with an error.
    private func endPongs() {
        for t in pongTasks { t.callAgain(URLError(.cancelled)) }
    }

    private func deliver(_ r: Result<Data?, Error>) {
        if let w = waiter {
            waiter = nil
            w.resume(with: r)
        } else {
            inbox.append(r)
        }
    }

    /// The server sends stream bytes (or, on a silent socket, its handshake answer).
    func push(_ bytes: [UInt8]) { deliver(.success(Data(bytes))) }

    /// The connection drops, or the server closes it with `code`.
    func drop(code: Int = 0) {
        closeCode = code
        endPongs()
        deliver(.failure(URLError(.networkConnectionLost)))
    }
}

/// A WebSocket task's ping as URLSession has answered it: the handler can be called more than
/// once, the later calls with an error, on URLSession's queue. Build 2611201727 crashed on it.
final class TwicePongTask: PongSending, @unchecked Sendable {
    // `@unchecked`: `handler` is only touched on `queue`.
    enum Answer { case pong, fail, never }
    private let first: Answer
    private let twice: Bool
    private let queue = DispatchQueue(label: "test.twice-pong")
    private var handler: (@Sendable (Error?) -> Void)?

    init(_ first: Answer, twice: Bool) {
        self.first = first
        self.twice = twice
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void) {
        queue.async { [self] in
            handler = pongReceiveHandler
            switch first {
            case .pong: pongReceiveHandler(nil)
            case .fail: pongReceiveHandler(URLError(.networkConnectionLost))
            case .never: break
            }
            if twice { pongReceiveHandler(URLError(.networkConnectionLost)) }
        }
    }

    /// Calls the handler again, as URLSession does when the task ends.
    func callAgain(_ error: Error) {
        queue.async { [self] in handler?(error) }
    }
}

/// Waits until `condition` holds; false after two seconds.
@MainActor
func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<2000 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

/// Lets everything that is ready to run finish, to check that nothing more happens.
@MainActor
func settle() async {
    for _ in 0..<5 {
        try? await Task.sleep(for: .milliseconds(10))
        for _ in 0..<20 { await Task.yield() }
    }
}

/// The waits a stream asked for. They are recorded and skipped, except those in `real`.
@MainActor
final class SleepLog {
    private(set) var asked: [Duration] = []
    /// Runs after a wait is recorded.
    var onSleep: ((Duration) -> Void)?
    /// Waits that really pass: by default the hold after a key-bound action (`actionHold`), which
    /// would otherwise let typing overtake every action at once, and the fence's two limits (how
    /// long held keys live, and its cap), which would otherwise end every fence at once.
    var real: Set<Duration> = [.milliseconds(1500), .seconds(1), .milliseconds(300)]
    /// Waits that do not pass until the test says so (`release`): a test whose outcome must not
    /// depend on how fast the machine is holds the wait that would race it.
    var held: Set<Duration> = []
    private var parked: [(Duration, CheckedContinuation<Void, Never>)] = []

    /// Every held wait of `d` passes now.
    func release(_ d: Duration) {
        let due = parked.filter { $0.0 == d }
        parked.removeAll { $0.0 == d }
        for (_, c) in due { c.resume() }
    }

    func attach(to stream: TerminalStream) {
        // The stream keeps the log alive.
        stream.sleep = { d in
            self.asked.append(d)
            self.onSleep?(d)
            if self.held.contains(d) {
                await withCheckedContinuation { self.parked.append((d, $0)) }
            } else if self.real.contains(d) {
                try? await Task.sleep(for: d)
            } else {
                await Task.yield()
            }
        }
    }

    /// The pauses between fresh starts (seconds); the short ones are other waits.
    var backoffs: [Duration] { asked.filter { $0 >= .seconds(3) } }
}

@MainActor
func makeStream(link: FakeLink, sink: TerminalSink) -> (TerminalStream, SleepLog) {
    let control = RexControl(address: "http://127.0.0.1:9", client: ClientInfo(name: "test", version: "0", label: "test"))
    let s = TerminalStream(control: control, link: link, sessionID: "session:test", blockID: "block:test")
    s.sink = sink
    let log = SleepLog()
    log.attach(to: s)
    return (s, log)
}

/// Bytes as the server puts them on a terminal data socket.
@MainActor
enum Wire {
    /// The smallest whole snapshot: the envelope, READY and FINISH.
    static let snapshot: [UInt8] = Snapshots.envelope + Snapshots.record(tag: 5) + Snapshots.record(tag: 6)

    static func message(_ json: String) -> [UInt8] {
        Array("\u{1b}_rex1;\(FakeLink.nonce);\(json)\u{1b}\\".utf8)
    }

    static func resize(cols: Int = 80, rows: Int = 24, owner: String = "client:mac") -> [UInt8] {
        message("{\"type\":\"resize\",\"cols\":\(cols),\"rows\":\(rows),\"owner\":\"\(owner)\"}")
    }

    /// What starts every fresh stream: the snapshot, then the server's size.
    static let opening: [UInt8] = snapshot + resize()
}

/// Gives a started stream its snapshot and waits until its fence is down: the screen is current.
@MainActor
func catchUp(_ stream: TerminalStream, _ link: FakeLink) async {
    let has = await eventually { !link.sockets.isEmpty }
    XCTAssertTrue(has, "no data socket")
    link.sockets.last?.push(Wire.opening)
    let down = await eventually { !stream.isFenced }
    XCTAssertTrue(down, "the fence stayed up")
}
