import Foundation

/// `config.json` in the state directory. Every field is optional.
///
/// ```json
/// {
///   "servers": ["https://macbook-pro-rex.tail8657d0.ts.net"],
///   "label": "rex-push-relay",
///   "apns": {"key_path": "~/.appstoreconnect/private_keys/AuthKey_5G2D4URHAC.p8",
///            "key_id": "5G2D4URHAC", "team_id": "R2PVQ496X7", "topic": "dev.abrahamgonzalez.rexduo"},
///   "debounce_seconds": 30,
///   "rate_limit_burst": 10,
///   "rate_limit_per_minute": 10
/// }
/// ```
public struct RelayConfig: Codable, Sendable {
    public struct APNs: Codable, Sendable {
        public var keyPath: String?
        public var keyID: String?
        public var teamID: String?
        public var topic: String?
        enum CodingKeys: String, CodingKey {
            case keyPath = "key_path", keyID = "key_id", teamID = "team_id", topic
        }
        public init() {}
    }

    public static let defaultServer = "https://macbook-pro-rex.tail8657d0.ts.net"
    public static let defaultTeamID = "R2PVQ496X7"
    public static let defaultTopic = "dev.abrahamgonzalez.rexduo"

    public var servers: [String]?
    public var label: String?
    public var apns: APNs?
    public var debounceSeconds: Double?
    public var rateLimitBurst: Double?
    public var rateLimitPerMinute: Double?

    enum CodingKeys: String, CodingKey {
        case servers, label, apns
        case debounceSeconds = "debounce_seconds"
        case rateLimitBurst = "rate_limit_burst"
        case rateLimitPerMinute = "rate_limit_per_minute"
    }

    public init() {}

    public static func load(_ url: URL) throws -> RelayConfig {
        guard FileManager.default.fileExists(atPath: url.path) else { return RelayConfig() }
        return try JSONDecoder().decode(RelayConfig.self, from: Data(contentsOf: url))
    }

    public var serverURLs: [URL] {
        (servers?.isEmpty == false ? servers! : [Self.defaultServer]).compactMap(URL.init(string:))
    }
    public var teamID: String { apns?.teamID ?? Self.defaultTeamID }
    public var topic: String { apns?.topic ?? Self.defaultTopic }

    public static var defaultStateDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/rex-push-relay", isDirectory: true)
    }
}
