import Foundation

/// A round-trip time added to a control connection's calls and to its terminal data sockets, to
/// measure on a fast network what a slow one costs (`RexControl.linkDelay`; the app sets it from
/// `-netDelay`, docs/debug-args.md). Zero, the default, adds nothing and wraps nothing.
///
/// It delays, it doesn't limit: messages keep the spacing they arrived with, each one a one-way
/// trip later. What it models:
///
/// - a call: one way before the request leaves, one way after the answer arrives;
/// - a new data socket: `socketOpenRoundTrips` from the moment it is opened before its first
///   message can leave (the server's data sockets are HTTP/1.1 over TLS 1.3 on a connection of
///   their own: TCP, TLS and the WebSocket upgrade, one round trip each), then one way per
///   message in either direction. A socket opened ahead of its first message has that much of
///   its opening behind it (`EarlySocket`);
/// - a ping: one round trip.
public struct LinkDelay: Sendable, Equatable {
    public var roundTrip: Duration

    public static let none = LinkDelay(roundTrip: .zero)
    /// TCP, TLS 1.3 and the WebSocket upgrade.
    public static let socketOpenRoundTrips = 3

    public init(roundTrip: Duration) { self.roundTrip = roundTrip }

    public var isZero: Bool { roundTrip <= .zero }
    var oneWay: Duration { roundTrip / 2 }
    var socketOpen: Duration { roundTrip * Self.socketOpenRoundTrips }
}

/// A data socket behind a `LinkDelay`.
///
/// Messages are read from the real socket as they arrive, each stamped with the time it is due
/// (arrival plus one way), so a burst stays a burst. At most `readAhead` wait here; past that the
/// real socket isn't read, as when the stream pauses its reads.
@MainActor
final class DelayedStreamSocket: StreamSocket {
    static let readAhead = 64

    private let inner: any StreamSocket
    private let delay: LinkDelay
    private let sleep: @MainActor (Duration) async -> Void
    /// The time; a test moves its own.
    private let now: @MainActor () -> ContinuousClock.Instant
    private var opened = false
    /// When the socket was made: its opening runs from here, whenever its first message comes.
    private let made: ContinuousClock.Instant
    private var arrived: [(Result<Data?, Error>, due: ContinuousClock.Instant)] = []
    private var waiter: CheckedContinuation<Void, Never>?
    private var pumping = false
    private var failed = false
    /// The pump, waiting for room.
    private var room: CheckedContinuation<Void, Never>?

    init(_ inner: any StreamSocket, delay: LinkDelay,
         sleep: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
         now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.inner = inner
        self.delay = delay
        self.now = now
        self.sleep = sleep
        made = now()
    }

    func send(_ data: Data) async throws {
        let first = !opened
        opened = true
        // What is left of the opening, for the first message, then its own way there.
        let opening = first ? max(.zero, delay.socketOpen - (now() - made)) : .zero
        await sleep(opening + delay.oneWay)
        try await inner.send(data)
    }

    func receive() async throws -> Data? {
        pump()
        while arrived.isEmpty {
            await withCheckedContinuation { waiter = $0 }
        }
        let (result, due) = arrived.removeFirst()
        room?.resume()
        room = nil
        let left = due - now()
        if left > .zero { await sleep(left) }
        return try result.get()
    }

    /// Reads the real socket until it fails, stamping each message.
    private func pump() {
        guard !pumping, !failed else { return }
        pumping = true
        Task { [weak self, inner, delay] in
            while true {
                let result: Result<Data?, Error>
                do { result = .success(try await inner.receive()) } catch { result = .failure(error) }
                guard let self else { return }
                self.arrived.append((result, self.now() + delay.oneWay))
                self.waiter?.resume()
                self.waiter = nil
                if case .failure = result {
                    self.failed = true
                    self.pumping = false
                    return
                }
                while self.arrived.count >= Self.readAhead {
                    await withCheckedContinuation { self.room = $0 }
                }
            }
        }
    }

    func close() { inner.close() }

    func ping() async throws {
        await sleep(delay.roundTrip)
        try await inner.ping()
    }

    func abort() { inner.abort() }

    var closeCode: Int { inner.closeCode }
}
