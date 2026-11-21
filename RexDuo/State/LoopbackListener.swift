import Foundation
import Network
import RexKit

/// The phone's end of a forward: a TCP listener on IPv4 loopback only, so nothing off the phone
/// can reach it, with no Bonjour. It exists only while a browser is open and the app is in front.
@MainActor
protocol PortListener: AnyObject {
    /// The port it listens on, once `start` returned.
    var port: Int { get }
    /// Listens on `port`; on a free port instead when that one is taken or is 1024 or lower.
    /// Returns the port it got. `accept` gets each new connection, on the main actor.
    func start(preferring port: Int, accept: @escaping @MainActor (any TunnelLocal) -> Void) async throws -> Int
    func stop()
}

/// Network's listener, bound to 127.0.0.1.
@MainActor
final class LoopbackListener: PortListener {
    /// The queue every local connection runs on, off the main actor.
    nonisolated static let queue = DispatchQueue(label: "ports.loopback")

    private var listener: NWListener?
    private(set) var port = 0

    func start(preferring wanted: Int, accept: @escaping @MainActor (any TunnelLocal) -> Void) async throws -> Int {
        stop()
        if wanted > 1024, wanted <= 65535, let p = try? await listen(UInt16(wanted), accept: accept) { return p }
        return try await listen(0, accept: accept)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    /// What a listener asks for: 127.0.0.1 and the port, nothing wider, and no peer-to-peer.
    nonisolated static func parameters(port: UInt16) -> NWParameters {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = false
        return params
    }

    private func listen(_ port: UInt16, accept: @escaping @MainActor (any TunnelLocal) -> Void) async throws -> Int {
        let l = try NWListener(using: Self.parameters(port: port))
        l.newConnectionHandler = { c in
            let local = LoopbackConnection(c)
            Task { @MainActor in accept(local) }
        }
        let got: Int = try await withCheckedThrowingContinuation { done in
            let once = Once()
            l.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.first() { done.resume(returning: Int(l.port?.rawValue ?? 0)) }
                case .failed(let e), .waiting(let e):
                    if once.first() { done.resume(throwing: e) }
                    l.cancel()
                default:
                    break
                }
            }
            l.start(queue: Self.queue)
        }
        listener = l
        self.port = got
        return got
    }
}

/// True the first time only.
private final class Once: @unchecked Sendable {
    // `@unchecked`: `done` is only touched under `lock`.
    private let lock = NSLock()
    private var done = false
    func first() -> Bool { lock.withLock { defer { done = true }; return !done } }
}

/// One browser connection, as `TunnelRelay` reads and writes it. Network calls back on the
/// loopback queue; nothing here touches the main actor. Reads pull: one receive is out at a
/// time, only while a read waits, so a fast browser fills its socket, not the phone's memory.
final class LoopbackConnection: TunnelLocal, @unchecked Sendable {
    // `@unchecked`: every var is only touched under `lock`; the connection is Network's, which
    // is thread-safe.
    private let connection: NWConnection
    private let lock = NSLock()
    /// Received and not yet read: what came for a cancelled read, or what `rewind` put back.
    private var buffer: [Data] = []
    private var ended = false
    private var failure: Error?
    private var receiving = false
    private var waiter: (id: Int, done: CheckedContinuation<Data?, Error>)?
    private var nextWaiter = 0
    /// What the browser sent while nothing has come back yet, for one retry on a new block.
    private var sent: [Data] = []
    private var recording = true

    init(_ connection: NWConnection) {
        self.connection = connection
        connection.start(queue: LoopbackListener.queue)
    }

    /// The next bytes, or nil at the browser's end. A cancelled task's read throws and loses
    /// nothing: bytes that arrive for it wait for the next read.
    func read(max: Int) async throws -> Data? {
        let id = lock.withLock { () -> Int in
            nextWaiter += 1
            return nextWaiter
        }
        let data: Data? = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (done: CheckedContinuation<Data?, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    return done.resume(throwing: CancellationError())
                }
                if !buffer.isEmpty {
                    let d = buffer.removeFirst()
                    lock.unlock()
                    return done.resume(returning: d)
                }
                if let failure {
                    lock.unlock()
                    return done.resume(throwing: failure)
                }
                if ended {
                    lock.unlock()
                    return done.resume(returning: nil)
                }
                waiter = (id, done)
                let start = !receiving
                receiving = true
                lock.unlock()
                if start { receive(max: max) }
            }
        } onCancel: {
            let w = lock.withLock { () -> CheckedContinuation<Data?, Error>? in
                guard let w = waiter, w.id == id else { return nil }
                waiter = nil
                return w.done
            }
            w?.resume(throwing: CancellationError())
        }
        if let data { lock.withLock { if recording { sent.append(data) } } }
        return data
    }

    private func receive(max: Int) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: max) { [self] d, _, complete, error in
            lock.lock()
            receiving = false
            if let d, !d.isEmpty { buffer.append(d) }
            if let error { failure = error } else if complete { ended = true }
            guard let w = waiter else { return lock.unlock() }
            if !buffer.isEmpty {
                waiter = nil
                let next = buffer.removeFirst()
                lock.unlock()
                w.done.resume(returning: next)
            } else if let failure {
                waiter = nil
                lock.unlock()
                w.done.resume(throwing: failure)
            } else if ended {
                waiter = nil
                lock.unlock()
                w.done.resume(returning: nil)
            } else {
                receiving = true
                lock.unlock()
                receive(max: max)
            }
        }
    }

    func write(_ data: Data) async throws {
        lock.withLock {
            recording = false
            sent = []
        }
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            // A system callback resumes once only (`ResumeOnce`).
            let once = ResumeOnce(done)
            connection.send(content: data, completion: .contentProcessed { e in
                if let e { once.resume(throwing: e) } else { once.resume() }
            })
        }
    }

    func finishWriting() {
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
    }

    func close() { connection.cancel() }

    func reset() { connection.forceCancel() }

    /// Puts what the browser sent so far back in front, for a relay on a new block. False once
    /// anything came back: the request may have run then, and it is never sent twice.
    func rewind() -> Bool {
        lock.withLock {
            guard recording else { return false }
            buffer = sent + buffer
            sent = []
            return true
        }
    }
}
