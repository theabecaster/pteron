import CryptoKit
import Foundation

/// APNs provider token: an ES256 JWT `{alg, kid}.{iss, iat}` signed with the .p8 key.
/// Apple accepts a token for up to an hour and rejects refreshes more often than every 20 minutes,
/// so it's reused and replaced after `lifetime` (50 minutes).
public struct APNsToken {
    public let keyID: String
    public let teamID: String
    public let lifetime: TimeInterval
    private let key: P256.Signing.PrivateKey
    private var cached: (token: String, issued: Date)?

    public init(key: P256.Signing.PrivateKey, keyID: String, teamID: String, lifetime: TimeInterval = 50 * 60) {
        self.key = key
        self.keyID = keyID
        self.teamID = teamID
        self.lifetime = lifetime
    }

    /// Reads an `AuthKey_XXXXXXXXXX.p8` file (PKCS#8 PEM).
    public init(p8Path: String, keyID: String, teamID: String) throws {
        let pem = try String(contentsOfFile: (p8Path as NSString).expandingTildeInPath, encoding: .utf8)
        self.init(key: try P256.Signing.PrivateKey(pemRepresentation: pem), keyID: keyID, teamID: teamID)
    }

    public mutating func current(now: Date = Date()) -> String {
        if let c = cached, now.timeIntervalSince(c.issued) < lifetime { return c.token }
        let t = Self.make(key: key, keyID: keyID, teamID: teamID, issuedAt: now)
        cached = (t, now)
        return t
    }

    public mutating func invalidate() { cached = nil }

    public static func make(key: P256.Signing.PrivateKey, keyID: String, teamID: String, issuedAt: Date) -> String {
        let header = JSONCodec.data(["alg": "ES256", "kid": keyID])
        let claims = JSONCodec.data(["iss": teamID, "iat": Int(issuedAt.timeIntervalSince1970)])
        let input = base64url(header) + "." + base64url(claims)
        // JWS ES256 wants the raw 64-byte r||s form, not DER.
        let sig = (try? key.signature(for: Data(input.utf8)).rawRepresentation) ?? Data()
        return input + "." + base64url(sig)
    }

    public static func base64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum SendResult: Equatable {
    case sent(apnsID: String?)
    /// The token is dead (410 Unregistered, BadDeviceToken, …): forget the device.
    case dropDevice(String)
    case failed(String)
}

public protocol PushSender: AnyObject {
    @MainActor func send(_ message: PushMessage, to device: Device) async -> SendResult
}

/// Sends over HTTP/2 to api(.sandbox).push.apple.com with token auth.
@MainActor
public final class APNsSender: PushSender {
    public let topic: String
    private var token: APNsToken
    private let session: URLSession

    public init(token: APNsToken, topic: String) {
        self.token = token
        self.topic = topic
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 20
        cfg.httpMaximumConnectionsPerHost = 1   // one long-lived HTTP/2 connection per host
        self.session = URLSession(configuration: cfg)
    }

    nonisolated public static func host(for environment: String) -> String {
        environment == "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
    }

    nonisolated public static func request(for m: PushMessage, device: Device, topic: String, jwt: String, now: Date = Date()) -> URLRequest {
        var r = URLRequest(url: URL(string: "https://\(host(for: device.environment))/3/device/\(device.token)")!)
        r.httpMethod = "POST"
        r.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        r.setValue(topic, forHTTPHeaderField: "apns-topic")
        r.setValue("alert", forHTTPHeaderField: "apns-push-type")
        r.setValue(String(m.priority), forHTTPHeaderField: "apns-priority")
        r.setValue(String(Int(now.timeIntervalSince1970) + 3600), forHTTPHeaderField: "apns-expiration")
        if let c = m.collapseID { r.setValue(c, forHTTPHeaderField: "apns-collapse-id") }
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.httpBody = m.payloadData
        return r
    }

    public func send(_ message: PushMessage, to device: Device) async -> SendResult {
        for attempt in 0..<2 {
            let req = Self.request(for: message, device: device, topic: topic, jwt: token.current())
            do {
                let (data, resp) = try await session.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                let apnsID = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "apns-id")
                if status == 200 { return .sent(apnsID: apnsID) }
                let reason = JSONCodec.decode(data)?.str("reason") ?? "HTTP \(status)"
                switch (status, reason) {
                case (410, _), (_, "BadDeviceToken"), (_, "Unregistered"):
                    return .dropDevice(reason)
                case (403, "ExpiredProviderToken") where attempt == 0:
                    token.invalidate()
                    continue
                default:
                    return .failed("\(status) \(reason)")
                }
            } catch {
                return .failed(error.localizedDescription)
            }
        }
        return .failed("provider token rejected")
    }
}

/// `--dry-run`: prints what would be sent.
@MainActor
public final class DryRunSender: PushSender {
    let topic: String
    public init(topic: String) { self.topic = topic }

    public func send(_ message: PushMessage, to device: Device) async -> SendResult {
        Log.info("DRY-RUN push → \(device.deviceName ?? "?") [\(device.environment)] \(Self.describe(message, topic: topic))")
        return .sent(apnsID: nil)
    }

    public static func describe(_ m: PushMessage, topic: String) -> String {
        var h = "topic=\(topic) priority=\(m.priority)"
        if let c = m.collapseID { h += " collapse-id=\(c)" }
        return "\(h) payload=\(JSONCodec.encode(m.payload))"
    }
}
