import Foundation

typealias JSONObject = [String: Any]

extension Dictionary where Key == String, Value == Any {
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
}

enum JSONCodec {
    static func encode(_ obj: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: []) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
    static func decode(_ s: String) -> JSONObject? {
        guard let d = s.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: d)) as? JSONObject
    }
    static func decode(_ d: Data) -> JSONObject? {
        (try? JSONSerialization.jsonObject(with: d)) as? JSONObject
    }
}

struct RexError: LocalizedError {
    let code: String
    let message: String
    let status: Int
    var errorDescription: String? { "\(message) (\(code))" }

    static func local(_ msg: String) -> RexError { RexError(code: "client", message: msg, status: 0) }
}
