import Foundation

/// Rex's API is loosely typed, so messages stay dictionaries and are read with the accessors below.
public typealias JSONObject = [String: Any]

public extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String? { self[k] as? String }
    func int(_ k: String) -> Int? {
        if let i = self[k] as? Int { return i }
        if let d = self[k] as? Double { return Int(d) }
        if let n = self[k] as? NSNumber { return n.intValue }
        return nil
    }
    func dbl(_ k: String) -> Double? {
        if let d = self[k] as? Double { return d }
        if let n = self[k] as? NSNumber { return n.doubleValue }
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

public enum JSONCodec {
    public static func encode(_ obj: Any, pretty: Bool = false) -> String {
        String(decoding: data(obj, pretty: pretty), as: UTF8.self)
    }
    /// Keys are sorted, so the same object always encodes to the same bytes.
    public static func data(_ obj: Any, pretty: Bool = false) -> Data {
        var opts: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { opts.insert(.prettyPrinted) }
        return (try? JSONSerialization.data(withJSONObject: obj, options: opts)) ?? Data("{}".utf8)
    }
    public static func decode(_ s: String) -> JSONObject? { decode(Data(s.utf8)) }
    public static func decode(_ d: Data) -> JSONObject? {
        (try? JSONSerialization.jsonObject(with: d)) as? JSONObject
    }
}

/// A value fresh from `JSONSerialization`, carried from the socket's queue to the main actor.
/// `@unchecked` is safe because nothing mutates it after decoding: without `.mutableContainers`
/// JSONSerialization returns immutable containers, strings and numbers, and Swift collections
/// bridged from them copy on write.
struct DecodedJSON: @unchecked Sendable {
    let value: Any
    init(_ value: Any) { self.value = value }
}

/// An error from the server (`code`, `message`, HTTP-like `status`) or a local one (`code` "client").
public struct RexError: LocalizedError, Sendable {
    public let code: String
    public let message: String
    public let status: Int
    /// True when the request never left this client: there was no connection, or the socket
    /// refused the message. Sending it again can't make the server run it twice. False for an
    /// error the server answered with, and for a request that was sent and whose answer never
    /// came because the connection broke: the server may or may not have run that one.
    public var neverSent = false
    public var errorDescription: String? { "\(message) (\(code))" }

    public init(code: String, message: String, status: Int = 0) {
        self.code = code
        self.message = message
        self.status = status
    }

    public static func local(_ msg: String) -> RexError { RexError(code: "client", message: msg) }
    /// A local error for a request that never left this client (`neverSent`).
    public static func unsent(_ msg: String) -> RexError {
        var e = RexError(code: "client", message: msg)
        e.neverSent = true
        return e
    }
}
