import Foundation
import os

public typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func int(_ k: String) -> Int? {
        if let i = self[k] as? Int { return i }
        if let n = self[k] as? NSNumber { return n.intValue }
        return nil
    }
    func bool(_ k: String) -> Bool? { self[k] as? Bool }
    func obj(_ k: String) -> JSONObject? { self[k] as? JSONObject }
    func arr(_ k: String) -> [JSONObject] { (self[k] as? [Any])?.compactMap { $0 as? JSONObject } ?? [] }
    /// A string field that is present and not blank, trimmed.
    func text(_ k: String) -> String? {
        guard let s = self[k] as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

enum JSONCodec {
    static func encode(_ obj: Any, pretty: Bool = false) -> String {
        String(decoding: data(obj, pretty: pretty), as: UTF8.self)
    }
    static func data(_ obj: Any, pretty: Bool = false) -> Data {
        var opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { opts.insert(.prettyPrinted) }
        return (try? JSONSerialization.data(withJSONObject: obj, options: opts)) ?? Data("{}".utf8)
    }
    static func decode(_ s: String) -> JSONObject? { decode(Data(s.utf8)) }
    static func decode(_ d: Data) -> JSONObject? {
        (try? JSONSerialization.jsonObject(with: d)) as? JSONObject
    }
}

public struct RexError: LocalizedError {
    public let code: String
    public let message: String
    public var errorDescription: String? { "\(message) (\(code))" }
    static func local(_ msg: String) -> RexError { RexError(code: "client", message: msg) }
}

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
