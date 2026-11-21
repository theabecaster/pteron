import Foundation

/// A checked continuation that only the first call resumes, for a system callback that may come
/// more than once. Resuming a checked continuation twice is a fatal error, and URLSession has
/// called a WebSocket task's pong handler a second time, with an error, after the first call had
/// resumed: TestFlight build 2611201727 crashed that way on an iPhone, at Try Again after a
/// return from the background (`TerminalStream.wake` pings each pane's data socket).
public final class ResumeOnce<T: Sendable, E: Error>: @unchecked Sendable {
    // `@unchecked`: `continuation` is only read and cleared under `lock`, and a continuation
    // may be resumed from any thread.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, E>?

    public init(_ continuation: CheckedContinuation<T, E>) { self.continuation = continuation }

    public func resume(returning value: T) { take()?.resume(returning: value) }

    public func resume(throwing error: E) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<T, E>? {
        lock.withLock {
            defer { continuation = nil }
            return continuation
        }
    }
}

extension ResumeOnce where T == Void {
    public func resume() { resume(returning: ()) }
}

/// What a ping needs of a WebSocket task. `URLSessionWebSocketTask` is the real one; tests call
/// the handler as URLSession may.
protocol PongSending: AnyObject {
    func sendPing(pongReceiveHandler: @escaping @Sendable (Error?) -> Void)
}

extension URLSessionWebSocketTask: PongSending {}

extension PongSending {
    /// Returns at the pong; throws when the socket fails first. Only the handler's first call
    /// counts (`ResumeOnce`).
    func awaitPong() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            let once = ResumeOnce(c)
            sendPing { err in
                if let err { once.resume(throwing: err) } else { once.resume() }
            }
        }
    }
}
