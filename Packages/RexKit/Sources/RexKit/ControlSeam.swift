import Foundation

/// Time as `RexControl` reads it: the retry backoff, the welcome and wake deadlines and the
/// keepalive. `SystemControlClock` is the real one; tests pass a clock they move by hand, so a
/// backoff of 15 s is checked without waiting for it.
@MainActor
protocol ControlClock: AnyObject {
    var now: Date { get }
    /// Returns after `seconds`, or at once when the task is cancelled; the caller checks which.
    func sleep(seconds: Double) async
    /// Calls `body` every `interval` seconds until the returned timer is cancelled.
    func every(_ interval: TimeInterval, _ body: @escaping @MainActor () -> Void) -> any ControlTimer
}

/// A repeating timer of a `ControlClock`.
@MainActor
protocol ControlTimer: AnyObject {
    func cancel()
}

/// The system's time: `Task.sleep` and a `Timer` on the main run loop.
@MainActor
final class SystemControlClock: ControlClock {
    var now: Date { Date() }

    func sleep(seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func every(_ interval: TimeInterval, _ body: @escaping @MainActor () -> Void) -> any ControlTimer {
        RunLoopTimer(Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in body() }
        })
    }

    private final class RunLoopTimer: ControlTimer {
        private let timer: Timer
        init(_ timer: Timer) { self.timer = timer }
        func cancel() { timer.invalidate() }
    }
}

/// What `RexControl` needs of its WebSocket. The requirements are `URLSessionWebSocketTask`'s own
/// methods, so the real socket is that task as it is; tests pass a socket whose every callback
/// they call themselves, in any order and at any time.
protocol ControlSocket: PongSending, Sendable {
    var maximumMessageSize: Int { get set }
    var state: URLSessionTask.State { get }
    /// The answer to the upgrade request, once there is one.
    var response: URLResponse? { get }
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
    var closeReason: Data? { get }

    func resume()
    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable ((any Error)?) -> Void)
    func receive(completionHandler: @escaping @Sendable (Result<URLSessionWebSocketTask.Message, any Error>) -> Void)
    /// Drops the connection with no close frame.
    func cancel()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
}

extension URLSessionWebSocketTask: ControlSocket {}

/// Makes the socket of one connection attempt, not yet resumed.
typealias ControlSocketFactory = @MainActor (_ url: URL, _ protocols: [String]) -> any ControlSocket
