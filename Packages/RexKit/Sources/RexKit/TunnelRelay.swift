import Foundation

// A dial tunnel (`com.superlogical.tunnel.dial`, a detached block made with `session.new_block`)
// connects to a host and port on the computer. Each TCP connection through it is its own data
// connection: `data.connect` with a fresh `data_ref_id` `conn:<uuid>` and subprotocol
// `rex.data.bytes.v1`, then the usual HELLO and WELCOME (`DataFrame`), and the server dials the
// target. What a probe of a Rex server (preview.20 and .21, macOS and Linux) showed:
//
// - After the WELCOME the bytes go both ways as binary messages. The client sends at most
//   64 KiB per message; a larger one closes the stream with 1009.
// - End of data is one empty message, each way (a TCP half-close). The clean end: both sides
//   sent theirs, then the client closes with 1000. Any other close by the client resets the
//   target's connection, and a dropped data socket can't be resumed.
// - A target that refuses or can't be resolved: the WELCOME, then close 1001 with no bytes.
//   That is the only signal.
// - 4000: the tunnel block was closed. 4006: this client isn't the block's owner (or sent data
//   after its own end).

/// The tunnel's data connection, as the relay uses it. `TunnelSession` makes the real one.
public protocol TunnelSocket: AnyObject, Sendable {
    func send(_ data: Data) async throws
    /// The next binary message, or nil for a text message. Throws once the socket closes.
    func receive() async throws -> Data?
    func ping() async throws
    /// Closes with 1000: the clean end.
    func close()
    /// Drops the connection: the server resets the target's connection.
    func abort()
    /// The server's close status, or 0.
    var closeCode: Int { get }
}

/// The phone's side: one TCP connection a browser made to the app's loopback listener.
public protocol TunnelLocal: AnyObject, Sendable {
    /// Up to `max` bytes; nil at the end of the browser's data. Throws when the connection fails.
    /// Must also throw, and lose nothing, when its task is cancelled: after a 4006 before any
    /// byte the relay keeps the browser's connection up for a retry, so cancelling is the only
    /// thing that ends a read still waiting on the browser, and `run` returns only after it.
    func read(max: Int) async throws -> Data?
    func write(_ data: Data) async throws
    /// Ends the data towards the browser (a TCP half-close).
    func finishWriting()
    /// Both directions are done: close.
    func close()
    /// Something failed: reset the browser's connection, so it sees a broken one and not a page
    /// that ended early.
    func reset()
    /// Makes the next reads return what the browser sent so far again, for a new relay. False
    /// once anything was written back, so a request that may have run is never sent twice.
    func rewind() -> Bool
}

/// Copies bytes between a browser's connection and a tunnel's data connection until both sides
/// have ended, or something fails. Runs off the main actor: after `data.connect` nothing here
/// touches it.
public final class TunnelRelay: @unchecked Sendable {
    public enum End: Equatable, Sendable {
        /// Both sides ended their data, and the socket closed with 1000.
        case clean
        /// The computer couldn't connect to the target (1001 with no bytes).
        case refused
        /// The tunnel's block was closed (4000).
        case blockClosed
        /// The server says this client doesn't own the block (4006). `beforeAnyByte`: nothing
        /// came back, so the request can go again on a new block.
        case ownerLost(beforeAnyByte: Bool)
        /// The data connection broke with this close status (0 for none).
        case lost(code: Int)
        /// The browser's side failed, or `cancel()`.
        case cancelled
    }

    /// Bytes per message and per read: the server takes at most this much in one message.
    public static let chunk = 65_536
    /// Keeps an idle stream (a dev server's reload socket) alive through middleboxes.
    public static let pingEvery: Duration = .seconds(25)

    public static let closedBlock = 4000
    public static let notOwner = 4006
    public static let goingAway = 1001

    private let socket: any TunnelSocket
    private let local: any TunnelLocal
    private let sleep: @Sendable (Duration) async throws -> Void
    private let lock = NSLock()
    private var localDone = false
    private var remoteDone = false
    private var received = 0
    private var finished = false
    private var cancelled = false

    /// `sleep` stands in for the clock in tests; it must throw when its task is cancelled.
    public init(socket: any TunnelSocket, local: any TunnelLocal,
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.socket = socket
        self.local = local
        self.sleep = sleep
    }

    /// Relays until the end, and says how it ended. Both connections are closed or reset by then.
    public func run() async -> End {
        await withTaskGroup(of: Void.self) { g in
            g.addTask { await self.pumpUp() }
            g.addTask { await self.pingLoop() }
            let end = await pumpDown()
            g.cancelAll()
            return end
        }
    }

    /// Resets both sides.
    public func cancel() {
        lock.withLock { cancelled = true }
        local.reset()
        socket.abort()
    }

    private func pumpUp() async {
        while true {
            // Nil or empty: the browser's end, one empty message.
            let d: Data
            do {
                d = try await local.read(max: Self.chunk) ?? Data()
            } catch {
                // The browser reset its connection (or `run` ended): the other pump resets it.
                if lock.withLock({ finished }) { return }
                lock.withLock { cancelled = true }
                socket.abort()
                return
            }
            do {
                try await socket.send(d)
            } catch {
                // The socket failed, a 4006 say, perhaps before its receive saw it. Not the
                // browser: the other pump says how it ended from the close status, as when idle.
                if !lock.withLock({ finished }) { socket.abort() }
                return
            }
            if d.isEmpty {
                if mark(local: true) { finishClean() }
                return
            }
        }
    }

    private func pumpDown() async -> End {
        do {
            while true {
                guard let d = try await socket.receive() else { continue }
                if d.isEmpty {
                    local.finishWriting()
                    if mark(local: false) { finishClean() }
                    continue
                }
                lock.withLock { received += d.count }
                try await local.write(d)
            }
        } catch {
            let (clean, gone, got) = lock.withLock { (finished, cancelled, received) }
            if clean { return .clean }
            if gone {
                local.reset()
                return .cancelled
            }
            let end = Self.end(code: socket.closeCode, received: got)
            // Nothing came back: the caller may send the browser's bytes again on a new block
            // (`TunnelLocal.rewind`), so the browser's connection stays up for that. The read
            // still waiting on it ends with `run`'s `cancelAll`, and then aborts the socket.
            if end != .ownerLost(beforeAnyByte: true) { local.reset() }
            return end
        }
    }

    private func pingLoop() async {
        while !Task.isCancelled {
            do { try await sleep(Self.pingEvery) } catch { return }
            try? await socket.ping()
        }
    }

    /// Records one side's end; true when both have ended.
    private func mark(local isLocal: Bool) -> Bool {
        lock.withLock {
            if isLocal { localDone = true } else { remoteDone = true }
            return localDone && remoteDone
        }
    }

    private func finishClean() {
        lock.withLock { finished = true }
        local.close()
        socket.close()
    }

    /// What a close status means, given how many bytes came back first.
    static func end(code: Int, received: Int) -> End {
        switch code {
        case goingAway where received == 0: return .refused
        case closedBlock: return .blockClosed
        case notOwner: return .ownerLost(beforeAnyByte: received == 0)
        default: return .lost(code: code)
        }
    }
}

/// The URLSession that carries one browser's tunnel connections: its own, so its connections
/// and delegate queue are off the main actor and go away with the browser (`invalidate`).
public final class TunnelSession: @unchecked Sendable {
    /// One per open slot: the browser's connections run at most this many at once.
    public static let slots = 16

    private let session: URLSession
    private let base: URL

    /// `base` is the server's `wss://` origin (`RexControl.wsBase`).
    public init(base: URL) {
        self.base = base
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = 20
        cfg.httpMaximumConnectionsPerHost = Self.slots
        let queue = OperationQueue()
        queue.name = "tunnel"
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: cfg, delegate: nil, delegateQueue: queue)
    }

    /// A data connection that has had its handshake: HELLO with the ticket, then the WELCOME.
    public func open(ticket: String) async throws -> any TunnelSocket {
        guard let hello = DataFrame.ticketHello(ticket) else { throw RexError.local("bad ticket") }
        let task = session.webSocketTask(with: base.appendingPathComponent("api/data"), protocols: [BytesStream.subprotocol])
        task.maximumMessageSize = 1 << 20
        task.resume()
        let socket = URLSessionTunnelSocket(task)
        do {
            try await socket.send(Data(hello))
            guard let answer = try await socket.receive() else { throw RexError.local("bad welcome") }
            _ = try DataFrame.welcome([UInt8](answer))
        } catch {
            socket.abort()
            throw error
        }
        return socket
    }

    /// Cancels every connection and frees the session.
    public func invalidate() { session.invalidateAndCancel() }
}

final class URLSessionTunnelSocket: TunnelSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(_ task: URLSessionWebSocketTask) { self.task = task }

    func send(_ data: Data) async throws { try await task.send(.data(data)) }

    func receive() async throws -> Data? {
        switch try await task.receive() {
        case .data(let d): return d
        default: return nil
        }
    }

    func ping() async throws {
        let task = self.task
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            task.sendPing { err in
                if let err { c.resume(throwing: err) } else { c.resume() }
            }
        }
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }

    func abort() { task.cancel() }

    var closeCode: Int { task.closeCode == .invalid ? 0 : task.closeCode.rawValue }
}
