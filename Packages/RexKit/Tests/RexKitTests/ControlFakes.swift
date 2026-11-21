import Foundation
@testable import RexKit

/// A clock that only moves when a test moves it. Waits and timers end in the order they fall due.
@MainActor
final class FakeControlClock: ControlClock {
    private(set) var now = Date(timeIntervalSinceReferenceDate: 0)
    /// Every wait asked for, in seconds, in order.
    private(set) var asked: [Double] = []
    private var sleepers: [(id: Int, due: Date, wake: CheckedContinuation<Void, Never>)] = []
    private var timers: [FakeTimer] = []
    private var nextID = 0

    final class FakeTimer: ControlTimer {
        let interval: TimeInterval
        let body: @MainActor () -> Void
        var due: Date
        var cancelled = false

        init(interval: TimeInterval, due: Date, body: @escaping @MainActor () -> Void) {
            self.interval = interval
            self.due = due
            self.body = body
        }

        func cancel() { cancelled = true }
    }

    /// Timers that still run.
    var liveTimers: Int { timers.filter { !$0.cancelled }.count }
    /// Waits that have not ended.
    var waiting: Int { sleepers.count }

    func sleep(seconds: Double) async {
        asked.append(seconds)
        nextID += 1
        let id = nextID, due = now.addingTimeInterval(seconds)
        await withTaskCancellationHandler {
            await withCheckedContinuation { wake in
                sleepers.append((id, due, wake))
            }
        } onCancel: {
            // As `Task.sleep`: a cancelled wait ends at once.
            Task { @MainActor in self.end(id) }
        }
    }

    func every(_ interval: TimeInterval, _ body: @escaping @MainActor () -> Void) -> any ControlTimer {
        let t = FakeTimer(interval: interval, due: now.addingTimeInterval(interval), body: body)
        timers.append(t)
        return t
    }

    private func end(_ id: Int) {
        guard let i = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: i).wake.resume()
    }

    /// Moves the time on by `seconds`, ending each wait and firing each timer when it falls due,
    /// and letting what they start run before the next.
    func advance(by seconds: Double) async {
        let target = now.addingTimeInterval(seconds)
        await pump()
        while true {
            timers.removeAll { $0.cancelled }
            let nextSleep = sleepers.map(\.due).min()
            let nextTimer = timers.map(\.due).min()
            guard let due = [nextSleep, nextTimer].compactMap({ $0 }).min(), due <= target else { break }
            now = max(now, due)
            if let s = sleepers.first(where: { $0.due == due }) {
                end(s.id)
            } else if let t = timers.first(where: { $0.due == due }) {
                t.due = due.addingTimeInterval(t.interval)
                t.body()
            }
            await pump()
        }
        now = target
        await pump()
    }
}

/// Lets every task that is ready on the main actor run, and those they start. No time passes.
@MainActor
func pump() async {
    for _ in 0..<200 { await Task.yield() }
}

/// A control socket that does nothing by itself: a test answers each send, receive and ping, when
/// and as often as it likes. Used on the main actor only.
final class FakeControlSocket: ControlSocket, @unchecked Sendable {
    // `@unchecked`: the tests and `RexControl` touch it on the main actor only; no other thread
    // has it.
    var maximumMessageSize = 0
    var state: URLSessionTask.State = .suspended
    var response: URLResponse?
    var closeCode: URLSessionWebSocketTask.CloseCode = .invalid
    var closeReason: Data?

    private(set) var resumed = false
    /// Dropped with no close frame.
    private(set) var cancelled = false
    /// Closed with this code.
    private(set) var closedWith: URLSessionWebSocketTask.CloseCode?
    /// The text messages sent, in order.
    private(set) var sent: [String] = []
    private var sendHandlers: [@Sendable ((any Error)?) -> Void] = []
    private var receivers: [@Sendable (Result<URLSessionWebSocketTask.Message, any Error>) -> Void] = []
    private var pongs: [@Sendable ((any Error)?) -> Void] = []
    /// Every handler ever given, for a test that calls one again after its socket is gone.
    private var allReceivers: [@Sendable (Result<URLSessionWebSocketTask.Message, any Error>) -> Void] = []
    private var allPongs: [@Sendable ((any Error)?) -> Void] = []

    var pings: Int { allPongs.count }
    var isWaitingToReceive: Bool { !receivers.isEmpty }
    var sentHello: Bool { sent.contains { $0.contains("\"hello\"") } }

    func resume() { resumed = true; state = .running }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable ((any Error)?) -> Void) {
        if case .string(let s) = message { sent.append(s) }
        sendHandlers.append(completionHandler)
    }

    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, any Error>) -> Void) {
        receivers.append(completionHandler)
        allReceivers.append(completionHandler)
    }

    func sendPing(pongReceiveHandler: @escaping @Sendable ((any Error)?) -> Void) {
        pongs.append(pongReceiveHandler)
        allPongs.append(pongReceiveHandler)
    }

    func cancel() { cancelled = true; state = .completed }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        closedWith = closeCode
        state = .completed
    }

    // MARK: What the test makes happen

    /// The server's message arrives.
    func deliver(_ text: String) {
        guard !receivers.isEmpty else { return }
        receivers.removeFirst()(.success(.string(text)))
    }

    /// The welcome that answers a hello.
    func welcome(token: String = "t") {
        deliver(#"{"type":"welcome","protocol":"rex.control.v1","client":{"id":"client:test","reconnect_token":"\#(token)"}}"#)
    }

    /// The waiting receive fails, as when the connection is lost.
    func failReceive(_ error: any Error = URLError(.networkConnectionLost)) {
        guard !receivers.isEmpty else { return }
        receivers.removeFirst()(.failure(error))
    }

    /// The oldest unanswered ping gets its pong, or fails.
    func answerPing(_ error: (any Error)? = nil) {
        guard !pongs.isEmpty else { return }
        pongs.removeFirst()(error)
    }

    /// Calls every handler this socket was ever given once more, with a failure: what a socket
    /// that is long gone may still do.
    func callEverythingAgain(_ error: any Error = URLError(.networkConnectionLost)) {
        for r in allReceivers { r(.failure(error)) }
        for p in allPongs { p(error) }
        for s in sendHandlers { s(error) }
    }

    /// A message arrives on a receive handler that was already used.
    func deliverLate(_ text: String) {
        allReceivers.last?(.success(.string(text)))
    }
}

/// The sockets a `RexControl` under test asked for, in order.
@MainActor
final class FakeControlSockets {
    private(set) var all: [FakeControlSocket] = []
    var last: FakeControlSocket { all[all.count - 1] }
    var count: Int { all.count }

    var factory: ControlSocketFactory {
        { [self] _, _ in
            let s = FakeControlSocket()
            all.append(s)
            return s
        }
    }
}
