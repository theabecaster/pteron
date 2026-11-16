import Foundation
import os

/// Logs to the unified log (subsystem `dev.abrahamgonzalez.rexconnect.helper`) and, with a
/// timestamp, to stdout. Read the app's log with
/// `log show --last 1h --predicate 'subsystem == "dev.abrahamgonzalez.rexconnect.helper"'`.
public enum Log {
    nonisolated(unsafe) public static var verbose = false
    private static let logger = Logger(subsystem: "dev.abrahamgonzalez.rexconnect.helper", category: "relay")
    nonisolated(unsafe) private static let fmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = .current
        return f
    }()
    public static func info(_ s: String) { emit(s) }
    public static func debug(_ s: String) { if verbose { emit(s) } }
    private static func emit(_ s: String) {
        logger.notice("\(s, privacy: .public)")
        print("\(fmt.string(from: Date())) \(s)")
        fflush(stdout)
    }
}
