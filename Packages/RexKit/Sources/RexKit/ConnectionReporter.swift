import Foundation

/// Writes one server's control connection into the connection log: each change of
/// `RexControl.State` and each retry that is set. The owner of the `RexControl` passes them on;
/// this type only turns them into events.
@MainActor
public final class ConnectionReporter {
    private let log: ConnectionLog
    private let server: String
    private let uptime: () -> TimeInterval
    /// When the attempt under way began, on a clock that never jumps.
    private var began: TimeInterval?
    private var stopped = true

    /// `server`: the app's key for the server, which the log hashes and never stores.
    public init(log: ConnectionLog, server: String,
                uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.log = log
        self.server = server
        self.uptime = uptime
    }

    /// Every state `RexControl.onStateChange` reports, repeats included: two `connecting` in a
    /// row are an attempt that was replaced by another before it ended.
    public func changed(_ state: RexControl.State) {
        switch state {
        case .connecting:
            began = uptime()
            stopped = false
            log.record(.connecting, server: server)
        case .connected:
            let ms = began.map { Int64(((uptime() - $0) * 1000).rounded()) } ?? 0
            began = nil
            stopped = false
            log.record(.connected(afterMilliseconds: max(0, ms)), server: server)
        case .failed(let failure):
            began = nil
            stopped = false
            log.record(.closed(failure), server: server)
        case .idle:
            // A connection that was never started, or is stopped again, says it once.
            guard !stopped else { return }
            stopped = true
            began = nil
            log.record(.stopped, server: server)
        }
    }

    /// `RexControl.onRetryScheduled`.
    public func retryScheduled(after seconds: Double) {
        log.record(.retry(after: seconds), server: server)
    }
}
