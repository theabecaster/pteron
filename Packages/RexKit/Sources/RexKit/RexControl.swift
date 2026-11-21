import Foundation

/// Who this client is. Sent in the hello; Rex shows it in `rex client list`.
public struct ClientInfo: Sendable, Equatable {
    public var kind: String
    public var platform: String
    public var name: String
    public var version: String
    /// Shown next to the name. Rex caps labels at 64 bytes.
    public var label: String

    public init(kind: String = "app", platform: String = "ios", name: String, version: String, label: String) {
        self.kind = kind
        self.platform = platform
        self.name = name
        self.version = version
        self.label = label
    }
}

/// What asked for a connection attempt.
public enum AttemptTrigger: UInt8, Sendable, CaseIterable {
    /// `connect()`.
    case first = 1
    /// The backoff's wait ended.
    case backoff
    /// The user asked: Try Again, or opening the server or one of its sessions.
    case user
    /// The phone's network changed.
    case network
    /// The app came back to the foreground.
    case foreground
    /// Another server connected, so the network works.
    case peer
}

/// One control connection (`GET /api/control`, subprotocol `rex.control.v1`) to a Rex server.
/// Every method call and event goes through here. See the server's /llms.txt.
@MainActor
public final class RexControl {
    public enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(ConnectionFailure)
    }

    /// The newest API revision this client speaks. The hello sends it with no `api_min_revision`,
    /// so a server on any revision from 0 up to this one connects, and a newer server translates
    /// down to it.
    public nonisolated static let apiRevision = 18

    /// The server address as configured.
    public let address: String
    /// `wss://host` for the address; nil when the address is invalid (`connect()` then fails).
    public let wsBase: URL?
    public let client: ClientInfo
    public private(set) var state: State = .idle {
        didSet {
            inputActivity.connection(state == .connected)
            onStateChange?(state)
            if state == .connected, oldValue != .connected { notifyConnected() }
        }
    }
    public private(set) var clientID: String?
    public private(set) var maxMessageBytes = 65536
    /// The API revision this connection uses, from the latest welcome (`api_revision`; a server
    /// that leaves it out speaks revision 0). 0 before the first welcome.
    public private(set) var negotiatedRevision = 0
    /// The newest revision the server speaks (`api_server_revision`; left out means 0).
    public private(set) var serverRevision = 0
    /// Optional behaviors the server lists in its welcome. Names this build doesn't know are
    /// kept and never looked at.
    public private(set) var features: Set<String> = []
    /// Retries have stopped because trying again can't help until something is changed
    /// (`ReconnectPolicy.FailureKind.final`): the server turned the client away, answered with a
    /// 4xx, shares no API revision with it, or TLS failed. Only the user asks again (`kick()`).
    public private(set) var retryStopped = false
    /// The server gave no answer time after time (`ReconnectPolicy.dormantAfter`): a computer that
    /// is off or out of reach. It is tried once per `ReconnectPolicy.dormantInterval`, in the
    /// foreground only, and when the user asks. The welcome ends it.
    public private(set) var dormant = false
    /// The app is in the background (`enteredBackground` until `wake`): no attempt is made, no
    /// ping is sent and nothing waits to be tried.
    public private(set) var suspended = false
    /// The tunnel breaker holds this host (`ReconnectGovernor`): several hosts stopped answering
    /// together, so one of them is tried and this one waits for its welcome.
    public private(set) var isHeld = false
    /// When the last welcome arrived.
    public private(set) var lastGood: Date?

    /// Which of this connection's terminal streams have typed input on its way.
    public let inputActivity = InputActivity()
    /// Testing: a simulated round-trip time for calls and terminal data sockets (`LinkDelay`).
    public var linkDelay = LinkDelay.none

    public var onEvent: ((_ seq: Int, _ event: JSONObject) -> Void)?
    public var onStateChange: ((State) -> Void)?
    /// Called after a dropped connection is re-established (state must be re-read).
    public var onReconnected: ((_ resumed: Bool) -> Void)?

    private var task: (any ControlSocket)?
    /// Also used by `TerminalStream` for the data sockets, so both share one configuration.
    let session: URLSession
    /// Calls waiting for their answer, by request id.
    private var pending: [String: (Result<DecodedJSON, Error>) -> Void] = [:]
    private var nextID = 0
    private var reconnectToken: String?
    private var welcomeWaiter: CheckedContinuation<Void, Error>?
    private var pingTimer: (any ControlTimer)?
    /// Time and the socket of each attempt: the system's, or a test's (`ControlSeam.swift`).
    private let clock: any ControlClock
    private let makeSocket: ControlSocketFactory
    /// Called when the next attempt is set for `delay` seconds from now: 0 at once, else the
    /// backoff's step. For the connection log; nothing else depends on it.
    public var onRetryScheduled: ((_ delay: Double) -> Void)?
    /// Called as an attempt begins, with what asked for it. For the connection log.
    public var onAttempt: ((AttemptTrigger) -> Void)?
    /// Called when retries stop because the server doesn't answer (`dormant`).
    public var onDormant: (() -> Void)?
    /// Called when the control socket is given up as dead, before anything is retried. For what
    /// else holds sockets to the same host.
    public var onSocketDead: (() -> Void)?
    private var generation = 0
    private var wantConnected = false
    /// Backoff waits taken in this episode; the welcome sets it back to 0.
    private var steps = 0
    /// Failures in a row with no answer from the server's side.
    private var silentRun = 0
    /// Attempts made in this episode: since `connect()` or the last welcome.
    private var attempts = 0
    /// When the last attempt began.
    private var lastAttempt: Date?
    /// When the next attempt is due and what asks for it, kept while its wait is cancelled (the
    /// background, no network).
    private var nextAttemptAt: Date?
    private var nextTrigger = AttemptTrigger.backoff
    /// An attempt was let through and has not opened its socket yet.
    private var starting = false
    /// The phone has a network path, and whether it is cellular or a hotspot (`pathChanged`).
    private var pathSatisfied = true
    private var pathExpensive = false
    /// When anything last came in on the socket.
    private var lastInbound = Date.distantPast
    /// The ping that waits for its pong.
    private var pingOut: Int?
    private var pingSerial = 0
    private var watchdogArmed = false
    /// The rules of reconnecting; this class keeps one host's state and asks.
    public let policy: ReconnectPolicy
    /// What this host shares with the others: the budget and the tunnel breaker.
    public let governor: ReconnectGovernor
    private(set) var governorID = 0
    private let random: () -> Double
    private var retryTask: Task<Void, Never>?
    private var connectedObservers: [@MainActor () -> Bool] = []
    /// The terminal streams that run on this connection, by block. Weak: a stream that went
    /// without `stop()` is simply not found.
    private var streams: [String: WeakStream] = [:]
    private struct WeakStream {
        weak var stream: TerminalStream?
    }

    /// `address` is the server's HTTPS address, e.g. `https://mac.tailnet.ts.net`.
    /// `governor`: what the app's servers share when they reconnect; nil gives this connection
    /// one of its own (a connection made for one short job).
    public convenience init(address: String, client: ClientInfo, governor: ReconnectGovernor? = nil) {
        self.init(address: address, client: client, clock: SystemControlClock(), sockets: nil, governor: governor)
    }

    /// `clock` and `sockets` replace the system's time and URLSession's socket, for tests. Nil
    /// `sockets` makes each socket from this connection's URLSession. `random`: a number from 0
    /// to 1 for each wait's jitter.
    init(address: String, client: ClientInfo, clock: any ControlClock, sockets: ControlSocketFactory?,
         governor: ReconnectGovernor? = nil, random: @escaping () -> Double = { Double.random(in: 0..<1) }) {
        let governor = governor ?? ReconnectGovernor()
        self.governor = governor
        self.policy = governor.policy
        self.random = random
        self.address = address
        self.wsBase = Self.webSocketBase(for: address)
        self.client = client
        self.clock = clock
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 20
        let session = URLSession(configuration: cfg)
        self.session = session
        self.makeSocket = sockets ?? { url, protocols in session.webSocketTask(with: url, protocols: protocols) }
        governorID = governor.register(self)
    }

    /// The WebSocket origin (`wss://host[:port]`) for a server address, or nil if the address has
    /// no host or isn't http(s) or ws(s).
    public nonisolated static func webSocketBase(for address: String) -> URL? {
        guard var c = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = c.host, !host.isEmpty else { return nil }
        switch c.scheme?.lowercased() {
        case "https", "wss": c.scheme = "wss"
        case "http", "ws": c.scheme = "ws"
        default: return nil
        }
        c.path = ""
        c.query = nil
        c.fragment = nil
        return c.url
    }

    // MARK: Connection

    /// Connects, and keeps the connection while it's wanted: after any failure, the first one
    /// included, it tries again as `ReconnectPolicy` and the `ReconnectGovernor` allow, until
    /// `disconnect()`. Throws if this first attempt fails; `state` and `onReconnected` report the
    /// later ones.
    public func connect() async throws {
        guard wsBase != nil else {
            let f = ConnectionFailure.invalidAddress(address)
            state = .failed(f)
            throw f
        }
        wantConnected = true
        suspended = false
        try await openSocket(.first)
    }

    public func disconnect() {
        wantConnected = false
        cancelRetry()
        endEpisode()
        retryStopped = false
        nextAttemptAt = nil
        governor.remove(governorID)
        generation += 1
        pingTimer?.cancel()
        pingOut = nil
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        failAll(RexError.local("disconnected"))
        resumeWelcome(throwing: RexError.local("disconnected"))
        state = .idle
    }

    /// The longest `invalidate` waits for the socket to finish closing before it drops it.
    static let closeLimit: TimeInterval = 1.5

    /// Disconnects for good and releases the URLSession, which otherwise keeps its delegate queue
    /// and connection pool for the life of the process. For a connection made for one short job;
    /// the control must not be used again.
    public func invalidate() {
        let closing = task
        disconnect()
        // `disconnect` asked the socket to close with a close frame. The session must outlive
        // that: cancelling it at once drops the TCP connection under the frame, and the server
        // then sees a client that vanished instead of one that left. So wait for the socket task
        // itself to finish (the frame is out and the connection is down), and only then end the
        // session. The limit covers a server that stopped reading, and a socket cancelled before
        // it finished opening, whose connection would otherwise stay in the session's pool.
        let session = session
        session.finishTasksAndInvalidate()
        let deadline = Date().addingTimeInterval(Self.closeLimit)
        Task.detached { [weak closing] in
            while let state = closing?.state, state != .completed, Date() < deadline {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            session.invalidateAndCancel()
        }
    }

    /// Opens a socket and waits for the welcome. Every failure goes through `handleDrop`, which
    /// records it and plans the next attempt; the throw only tells the caller.
    private func openSocket(_ trigger: AttemptTrigger) async throws {
        guard let wsBase else { throw ConnectionFailure.invalidAddress(address) }
        retryStopped = false
        starting = false
        lastAttempt = clock.now
        attempts += 1
        nextAttemptAt = nil
        governor.began(governorID)
        onAttempt?(trigger)
        // An attempt still waiting for its welcome is superseded by this one.
        resumeWelcome(throwing: RexError.local("superseded"))
        task?.cancel()
        generation += 1
        let gen = generation
        state = .connecting
        #if DEBUG
        if unreachableForTesting != nil {
            let f = ConnectionFailure(URLError(.cannotConnectToHost))
            handleDrop(gen: gen, failure: f)
            throw f
        }
        #endif
        let url = wsBase.appendingPathComponent("api/control")
        let t = makeSocket(url, ["rex.control.v1"])
        t.maximumMessageSize = 8 * 1024 * 1024
        task = t
        t.resume()

        let helloText = JSONCodec.encode(Self.hello(client: client, reconnectToken: reconnectToken))
        let deadline = policy.connectDeadline(expensive: pathExpensive)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            welcomeWaiter = c
            receiveLoop(t, gen: gen)
            t.send(.string(helloText)) { err in
                guard let err else { return }
                Task { @MainActor in self.handleDrop(gen: gen, failure: self.failure(err, t)) }
            }
            // Welcome timeout.
            Task { @MainActor in
                await self.clock.sleep(seconds: deadline)
                if self.welcomeWaiter != nil, gen == self.generation { self.handleDrop(gen: gen, failure: .timedOut()) }
            }
        }
        startPings(gen: gen)
    }

    /// The hello: the newest revision this client speaks and no minimum, so the server picks the
    /// newest one both sides have.
    nonisolated static func hello(client: ClientInfo, reconnectToken: String?) -> JSONObject {
        var hello: JSONObject = [
            "type": "hello",
            "api_revision": apiRevision,
            "client": [
                "kind": client.kind,
                "platform": client.platform,
                "name": client.name,
                "version": client.version,
                "label": client.label,
            ] as JSONObject,
        ]
        if let reconnectToken { hello["reconnect_token"] = reconnectToken }
        return hello
    }

    private func resumeWelcome(throwing error: Error) {
        guard let w = welcomeWaiter else { return }
        welcomeWaiter = nil
        w.resume(throwing: error)
    }

    /// The failure plus what the socket task knows: the upgrade's HTTP status, the close code and
    /// the reason sent with it.
    private func failure(_ error: Error, _ t: (any ControlSocket)?) -> ConnectionFailure {
        let status = (t?.response as? HTTPURLResponse)?.statusCode
        let close = t.flatMap { $0.closeCode == .invalid ? nil : $0.closeCode.rawValue }
        let reason = close == nil ? nil : t?.closeReason.flatMap { String(data: $0, encoding: .utf8) }
        return ConnectionFailure(error, httpStatus: status == 101 ? nil : status, closeCode: close,
                                 closeReason: reason?.isEmpty == true ? nil : reason)
    }

    // MARK: Liveness

    /// The keepalive: every `idlePing` seconds, a ping if nothing came in for that long. A ping
    /// that fails or gets no pong by its deadline drops the connection.
    private func startPings(gen: Int) {
        pingTimer?.cancel()
        pingTimer = clock.every(policy.idlePing) { [weak self] in
            guard let self, gen == self.generation, self.task != nil else { return }
            guard self.clock.now.timeIntervalSince(self.lastInbound) >= self.policy.idlePing else { return }
            self.ping(deadline: self.policy.pongDeadline(expensive: self.pathExpensive))
        }
    }

    /// Sends a ping and takes the connection for dead when it fails or no pong comes within
    /// `deadline`. One ping waits at a time; `replacing` lets a new one take the place of one
    /// that waits (the return to the foreground, with its shorter deadline).
    private func ping(deadline: Double, replacing: Bool = false, onPong: (@MainActor () -> Void)? = nil) {
        guard let t = task, state == .connected, replacing || pingOut == nil else { return }
        guard !suspended || policy.worksInBackground else { return }
        let gen = generation
        pingSerial += 1
        let id = pingSerial
        pingOut = id
        t.sendPing { [weak self] err in
            Task { @MainActor in
                guard let self, self.pingOut == id else { return }
                self.pingOut = nil
                if let err {
                    self.handleDrop(gen: gen, failure: self.failure(err, t))
                } else {
                    self.lastInbound = self.clock.now
                    onPong?()
                }
            }
        }
        Task { @MainActor [weak self, clock] in
            await clock.sleep(seconds: deadline)
            guard let self, self.pingOut == id else { return }
            self.pingOut = nil
            self.handleDrop(gen: gen, failure: .timedOut())
        }
    }

    /// A request went out: if nothing at all comes back within `activityTimeout`, a ping goes at
    /// once instead of at the keepalive's turn. One wait at a time, however many requests.
    private func armWatchdog() {
        guard !watchdogArmed else { return }
        watchdogArmed = true
        let gen = generation, timeout = policy.activityTimeout(expensive: pathExpensive)
        Task { @MainActor [weak self, clock] in
            await clock.sleep(seconds: timeout)
            guard let self else { return }
            self.watchdogArmed = false
            guard gen == self.generation, self.state == .connected, !self.pending.isEmpty else { return }
            if self.clock.now.timeIntervalSince(self.lastInbound) >= timeout {
                self.ping(deadline: self.policy.pongDeadline(expensive: self.pathExpensive))
            } else {
                self.armWatchdog()
            }
        }
    }

    private func receiveLoop(_ t: any ControlSocket, gen: Int) {
        t.receive { [weak self] result in
            // Decode here, on URLSession's queue: a screen-read reply is up to ~1 MB and takes
            // milliseconds to parse. Order is kept because the next receive starts only after this
            // message is handled on the main actor.
            let parsed = result.map { msg -> DecodedJSON? in
                switch msg {
                case .string(let s): return JSONCodec.decode(s).map(DecodedJSON.init)
                case .data(let d): return JSONCodec.decode(d).map(DecodedJSON.init)
                @unknown default: return nil
                }
            }
            Task { @MainActor in
                guard let self, gen == self.generation else { return }
                switch parsed {
                case .success(let m):
                    self.lastInbound = self.clock.now
                    if let m = m?.value as? JSONObject { self.handle(m) }
                    self.receiveLoop(t, gen: gen)
                case .failure(let err):
                    self.handleDrop(gen: gen, failure: self.failure(err, t))
                }
            }
        }
    }

    // MARK: Retrying

    /// The one place a failed or dropped socket is handled: once per generation, so a socket that
    /// fails several ways at once counts once and backs off once.
    private func handleDrop(gen: Int, failure: ConnectionFailure) {
        guard gen == generation else { return }
        generation += 1
        pingTimer?.cancel()
        pingOut = nil
        let wasConnected = state == .connected
        task?.cancel()
        task = nil
        failAll(RexError.local("connection lost"))
        resumeWelcome(throwing: failure)
        state = .failed(failure)
        onSocketDead?()
        // While the phone has no network a failure says nothing about the host: it counts
        // toward nothing, and nothing is tried until a path is back.
        let kind = policy.kind(of: failure)
        let silent = pathSatisfied && kind == .silent
        if pathSatisfied { silentRun = silent ? silentRun + 1 : 0 }
        governor.failed(governorID, silent: silent, now: clock.now.timeIntervalSinceReferenceDate)
        guard wantConnected else { return }
        if governor.holds(governorID) { isHeld = true }
        // Trying again would be turned away the same way. Only that stops; an ordinary close,
        // 1008 `event backlog exceeded` included, is tried again.
        if kind == .final {
            retryStopped = true
            cancelRetry()
            return
        }
        if !dormant, silentRun >= policy.dormantAfter {
            dormant = true
            onDormant?()
        }
        if policy.retriesAtOnceAfterWake, wasConnected, clock.now < retryAtOnceUntil, mayRetry {
            retryAtOnceUntil = .distantPast
            plan(after: 0, .foreground)
            return
        }
        planNext()
    }

    /// Whether anything may be tried on a timer now.
    private var mayRetry: Bool {
        wantConnected && state != .connected && !retryStopped && !isHeld && pathSatisfied
            && (!suspended || policy.worksInBackground)
    }

    /// Sets the wait for the next attempt of the schedule: the next backoff step, or a dormant
    /// host's interval.
    private func planNext() {
        guard mayRetry else { cancelRetry(); return }
        if dormant {
            plan(after: policy.dormantInterval, .backoff)
        } else {
            steps += 1
            plan(after: policy.delay(step: steps, unit: random()), .backoff)
        }
    }

    private func plan(after delay: Double, _ trigger: AttemptTrigger) {
        retryTask?.cancel()
        nextAttemptAt = clock.now.addingTimeInterval(delay)
        nextTrigger = trigger
        onRetryScheduled?(delay)
        retryTask = Task { @MainActor [weak self, clock] in
            if delay > 0 { await clock.sleep(seconds: delay) }
            guard let self, !Task.isCancelled else { return }
            self.retryTask = nil
            await self.scheduled(trigger)
        }
    }

    /// Stops the wait. What it waited for stays known (`nextAttemptAt`), for `rearm`.
    private func cancelRetry() {
        retryTask?.cancel()
        retryTask = nil
    }

    /// Starts the wait again after it was cancelled (the background, no network, the breaker):
    /// for the time that was left of it, or for the next step if none was set.
    private func rearm() {
        guard retryTask == nil, task == nil, !starting, mayRetry else { return }
        if let at = nextAttemptAt {
            plan(after: max(0, at.timeIntervalSince(clock.now)), nextTrigger)
        } else {
            planNext()
        }
    }

    /// A wait ended, or a trigger asked within the budget: the governor says whether the attempt
    /// goes now, later, or not while the breaker is open.
    private func scheduled(_ trigger: AttemptTrigger) async {
        guard task == nil, !starting, mayRetry else { return }
        // The first attempt of an episode, and a host the breaker let go, are outside the budget.
        let exempt = attempts == 0 || trigger == .peer
        switch governor.request(governorID, exempt: exempt, now: clock.now.timeIntervalSinceReferenceDate) {
        case .go:
            starting = true
            await attempt(trigger)
        case .wait(let seconds):
            plan(after: seconds, trigger)
        case .held:
            isHeld = true
        }
    }

    private func attempt(_ trigger: AttemptTrigger) async {
        let hadToken = reconnectToken != nil
        do {
            try await openSocket(trigger)
            onReconnected?(hadToken)
        } catch {
            // Already handled: `handleDrop` recorded it and planned the next try, if any.
        }
    }

    /// The episode is over: the welcome arrived, or the connection is not wanted.
    private func endEpisode() {
        steps = 0
        silentRun = 0
        attempts = 0
        dormant = false
        isHeld = false
        starting = false
    }

    /// Asks for one attempt: the user asked (the default), the network changed, the app came
    /// back, or the breaker let this host go. Does nothing while connected or not wanted.
    /// `ReconnectPolicy.kick` decides what the request gets. A user's request is always let
    /// through, and does nothing while an attempt is under way; the others keep the floor and
    /// the budget. The backoff never starts over here: only a welcome does that.
    public func kick(_ trigger: AttemptTrigger = .user) {
        guard wantConnected, state != .connected else { return }
        let since = lastAttempt.map { clock.now.timeIntervalSince($0) }
        switch policy.kick(trigger, connecting: state == .connecting || starting, dormant: dormant,
                           stopped: retryStopped, held: isHeld, selected: governor.isSelected(governorID),
                           suspended: suspended, pathSatisfied: pathSatisfied, attempts: attempts,
                           sinceLastAttempt: since) {
        case .ignore:
            rearm()
        case .now:
            cancelRetry()
            isHeld = false
            starting = true
            Task { @MainActor in await self.attempt(trigger) }
        case .budgeted:
            cancelRetry()
            Task { @MainActor in await self.scheduled(trigger) }
        case .after(let left):
            // A wait that ends sooner is left to make the attempt.
            if retryTask != nil, let at = nextAttemptAt, at <= clock.now.addingTimeInterval(left) { return }
            plan(after: left, trigger)
        }
    }

    /// The app went to the background: nothing is tried or pinged there, and no wait stays
    /// armed. A connection that is up is left as it is. `wake()` ends it.
    public func enteredBackground() {
        suspended = true
        guard !policy.worksInBackground else { return }
        cancelRetry()
        pingTimer?.cancel()
        pingOut = nil
    }

    /// The phone's network path changed. No path: nothing is tried until one is back, and what
    /// fails meanwhile counts toward nothing. A path again, or another interface: a connection
    /// that is up is pinged and never torn down (a tailnet address stays the same across
    /// interfaces), and a host that is down gets one attempt if the floor allows.
    public func pathChanged(satisfied: Bool, expensive: Bool, interfaceChanged: Bool) {
        let was = pathSatisfied
        pathSatisfied = satisfied
        pathExpensive = expensive
        guard wantConnected else { return }
        guard satisfied else { cancelRetry(); return }
        guard interfaceChanged || !was else { return }
        if state == .connected {
            ping(deadline: policy.pongDeadline(expensive: expensive))
        } else {
            kick(.network)
        }
    }

    /// The breaker opened and this host is not the one that is tried.
    func heldByBreaker() {
        guard wantConnected, state != .connected, !retryStopped else { return }
        isHeld = true
        cancelRetry()
    }

    /// This host is now the one the breaker tries: its schedule goes on.
    func becameTestHost() {
        guard isHeld else { return }
        isHeld = false
        rearm()
    }

    /// The test host connected: this host goes after `delay` seconds.
    func releasedByBreaker(after delay: Double) {
        guard isHeld else { return }
        isHeld = false
        guard mayRetry else { return }
        plan(after: delay, .peer)
    }

    /// Whether this host is down and would be tried: what the governor orders and counts.
    var wantsAttempts: Bool { wantConnected && state != .connected && !retryStopped }

    /// How long `wake()` waits for a pong on Wi-Fi before it takes the connection for dead.
    public static let wakeTimeout: Double = ReconnectPolicy.standard.wakePongDeadline
    /// A drop before this time is retried at once, once: the app just came back (`wake()`).
    private var retryAtOnceUntil = Date.distantPast

    /// Back in the foreground. A connection that looks up may have died while the app was
    /// suspended, and calls on it would hang until they time out. So it is pinged: no pong within
    /// the wake deadline, or a failed ping, counts as a drop, and the next attempt starts at once
    /// instead of after the backoff. Not connected: `kick(.foreground)`, which the floor and the
    /// budget hold, and which leaves a dormant host alone unless it is the selected one.
    public func wake() {
        #if DEBUG
        if unreachableForTesting == false { unreachableForTesting = nil }
        #endif
        suspended = false
        guard wantConnected else { return }
        guard state == .connected, task != nil else { kick(.foreground); return }
        startPings(gen: generation)
        let deadline = policy.wakePongDeadline(expensive: pathExpensive)
        // The socket usually fails by itself moments after the app wakes; that drop retries at once too.
        retryAtOnceUntil = clock.now.addingTimeInterval(deadline + 0.5)
        ping(deadline: deadline, replacing: true) { [weak self] in self?.retryAtOnceUntil = .distantPast }
    }

    /// Pings the connection once and returns with the pong. Throws when not connected, or when
    /// the socket fails first. Nothing is dropped here: a slow answer is only slow.
    func ping() async throws {
        guard let t = task, state == .connected else { throw RexError.unsent("not connected") }
        try await t.awaitPong()  // only the handler's first call counts (`ResumeOnce`)
    }

    #if DEBUG
    /// Testing: attempts fail as an unreachable host's do until `wake()` (false), or always (true).
    private var unreachableForTesting: Bool?

    /// Testing (`-wakeTest`): loses the connection as iOS does a suspended app's sockets, and
    /// attempts fail until the app is back, as a suspended app makes none. With `unreachable`,
    /// they keep failing after it.
    public func dropForTesting(unreachable: Bool) {
        unreachableForTesting = unreachable
        guard task != nil else { return }
        handleDrop(gen: generation, failure: ConnectionFailure(URLError(.networkConnectionLost)))
    }
    #endif

    /// Calls `body` each time the connection becomes connected, the first time and after every
    /// reconnect, until it returns false. This connection is the only thing that retries; what
    /// depends on it (a `TerminalStream`) waits here instead of polling or retrying on its own.
    /// `body` runs as soon as `state` is `.connected`, before `onReconnected`.
    public func observeConnected(_ body: @escaping @MainActor () -> Bool) {
        connectedObservers.append(body)
    }

    private func notifyConnected() {
        // An observer added from inside a call is kept for the next time.
        let current = connectedObservers
        connectedObservers = []
        let kept = current.filter { $0() }
        connectedObservers = kept + connectedObservers
    }

    private func failAll(_ err: Error) {
        let p = pending
        pending.removeAll()
        for (_, c) in p { c(.failure(err)) }
    }

    private func handle(_ m: JSONObject) {
        guard let type = m.str("type") else { return }
        switch type {
        case "welcome":
            if let c = m.obj("client") {
                clientID = c.str("id")
                reconnectToken = c.str("reconnect_token")
            }
            if let lim = m.obj("limits"), let mx = lim.int("max_message_bytes") { maxMessageBytes = mx }
            // Every welcome, a resumed one included: the server may have been updated or
            // downgraded since the last. Set before `state`, whose observers read them.
            negotiatedRevision = m.int("api_revision") ?? 0
            serverRevision = m.int("api_server_revision") ?? 0
            features = Set((m["features"] as? [Any])?.compactMap { $0 as? String } ?? [])
            endEpisode()
            cancelRetry()
            nextAttemptAt = nil
            lastGood = clock.now
            lastInbound = clock.now
            governor.welcomed(governorID)
            state = .connected
            welcomeWaiter?.resume()
            welcomeWaiter = nil
        case "response":
            guard let id = m.str("id"), let c = pending.removeValue(forKey: id) else { return }
            if let e = m.obj("error") {
                c(.failure(RexError(code: e.str("code") ?? "internal", message: e.str("message") ?? "error", status: e.int("status") ?? 500)))
            } else {
                c(.success(DecodedJSON(m["payload"] ?? NSNull())))
            }
        case "event":
            onEvent?(m.int("seq") ?? 0, m.obj("payload") ?? [:])
        default:
            break
        }
    }

    // MARK: Streams

    func streamStarted(_ stream: TerminalStream) {
        streams[stream.blockID] = WeakStream(stream: stream)
    }

    func streamStopped(_ stream: TerminalStream) {
        if streams[stream.blockID]?.stream === stream { streams[stream.blockID] = nil }
    }

    /// The running stream of a block, whose queue every input to that pane goes through. Nil
    /// when no pane of this connection shows the block.
    public func stream(block: String) -> TerminalStream? {
        streams[block]?.stream
    }

    // MARK: Calls

    @discardableResult
    public func call(_ method: String, _ payload: JSONObject? = nil) async throws -> JSONObject {
        let any = try await callAny(method, payload)
        return any as? JSONObject ?? [:]
    }

    public func callAny(_ method: String, _ payload: JSONObject? = nil) async throws -> Any {
        let delay = linkDelay
        if !delay.isZero { try? await Task.sleep(for: delay.oneWay) }
        // `neverSent`: a caller that must not repeat a request (typed input) may send this one again.
        guard let t = task, state == .connected else { throw RexError.unsent("not connected") }
        // A method newer than this connection's revision: the answer is known, so don't ask.
        if let e = Self.tooNew(method, for: negotiatedRevision) { throw e }
        let reply = try await withCheckedThrowingContinuation { (c: CheckedContinuation<DecodedJSON, Error>) in
            send(method, payload, on: t) { c.resume(with: $0) }
        }
        if !delay.isZero { try? await Task.sleep(for: delay.oneWay) }
        return reply.value
    }

    /// Sends every request in `calls` in this one turn of the main actor, in order, then waits
    /// for all the answers, which come back in the same order whatever order they arrive in.
    ///
    /// The socket keeps the order of sends, and the server runs its ordered methods (`move_block`,
    /// `block.close`, `new_window`, …) in arrival order on a connection. Separate calls, `async
    /// let` or a task group promise no order, so a sequence that depends on it goes through here.
    /// One failing call doesn't stop the others: they have left already.
    public func callInOrder(_ calls: [(method: String, payload: JSONObject)]) async -> [Result<JSONObject, Error>] {
        guard !calls.isEmpty else { return [] }
        guard let t = task, state == .connected else {
            return calls.map { _ in .failure(RexError.unsent("not connected")) }
        }
        let revision = negotiatedRevision
        let replies = await withCheckedContinuation { (done: CheckedContinuation<[Result<DecodedJSON, Error>], Never>) in
            var results = [Result<DecodedJSON, Error>?](repeating: nil, count: calls.count)
            var left = calls.count
            func finish(_ i: Int, _ r: Result<DecodedJSON, Error>) {
                results[i] = r
                left -= 1
                if left == 0 { done.resume(returning: results.map { $0! }) }
            }
            for (i, c) in calls.enumerated() {
                if let e = Self.tooNew(c.method, for: revision) {
                    finish(i, .failure(e))
                } else {
                    send(c.method, c.payload, on: t) { finish(i, $0) }
                }
            }
        }
        return replies.map { r in r.map { $0.value as? JSONObject ?? [:] } }
    }

    /// `revision_too_low`, never sent, for a method this connection's revision doesn't have.
    private static func tooNew(_ method: String, for revision: Int) -> RexError? {
        let needs = RexAPI.minimum(for: method)
        guard revision < needs else { return nil }
        var e = RexError(code: "revision_too_low", message: "\(method) needs API revision \(needs).", status: 400)
        e.neverSent = true
        return e
    }

    /// Registers `answer` for a new request and hands the request to the socket, in this turn.
    private func send(_ method: String, _ payload: JSONObject?, on t: any ControlSocket,
                      answer: @escaping (Result<DecodedJSON, Error>) -> Void) {
        nextID += 1
        let id = String(nextID)
        var req: JSONObject = ["type": "request", "id": id, "method": method]
        if let payload { req["payload"] = payload }
        pending[id] = answer
        armWatchdog()
        t.send(.string(JSONCodec.encode(req))) { err in
            guard let err else { return }
            Task { @MainActor in
                // The socket didn't take the message, so the server never saw it. (A request
                // that was sent and then lost its connection fails in `failAll`.)
                if let c = self.pending.removeValue(forKey: id) {
                    c(.failure(RexError.unsent(err.localizedDescription)))
                }
            }
        }
    }

    /// Sends a request and doesn't wait for its answer, which is dropped when it comes. The
    /// message is handed to the socket before this returns, in the caller's turn of the main
    /// actor. For answers the server asked for (`client.reply`), where nothing can be done about
    /// a failure. Returns false when there is no connection to send on.
    @discardableResult
    public func post(_ method: String, _ payload: JSONObject) -> Bool {
        guard let t = task, state == .connected else { return false }
        nextID += 1
        let req: JSONObject = ["type": "request", "id": String(nextID), "method": method, "payload": payload]
        t.send(.string(JSONCodec.encode(req))) { _ in }
        return true
    }

    /// Calls a block method: payload is `{session_id, block_id, args}`.
    @discardableResult
    public func blockCall(_ method: String, session: String, block: String, args: JSONObject = [:]) async throws -> JSONObject {
        try await call(method, ["session_id": session, "block_id": block, "args": args])
    }
}
