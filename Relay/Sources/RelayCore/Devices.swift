import Foundation
import RexKit

/// One phone that asked for pushes.
public struct Device: Codable, Equatable, Sendable {
    public var token: String            // APNs device token, lowercase hex
    public var environment: String      // sandbox | production
    public var deviceName: String?
    /// Short id the app also puts at the end of its Rex client label ("… #<id>"), for "app is open" checks.
    public var deviceID: String?
    /// Tailscale device name the registration came from (fallback "app is open" match).
    public var tailscaleNode: String?
    public var registeredAt: Date
    public var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case token, environment
        case deviceName = "device_name"
        case deviceID = "device_id"
        case tailscaleNode = "tailscale_node"
        case registeredAt = "registered_at"
        case updatedAt = "updated_at"
    }

    public init(token: String, environment: String, deviceName: String? = nil, deviceID: String? = nil,
                tailscaleNode: String? = nil, registeredAt: Date = Date(), updatedAt: Date = Date()) {
        self.token = token
        self.environment = environment
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.tailscaleNode = tailscaleNode
        self.registeredAt = registeredAt
        self.updatedAt = updatedAt
    }

    public static func isValidToken(_ t: String) -> Bool {
        (32...200).contains(t.count) && t.count % 2 == 0 && t.allSatisfy(\.isHexDigit)
    }

    public static func isValidDeviceID(_ s: String) -> Bool {
        (4...16).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

/// devices.json: the registered phones, keyed by token.
@MainActor
public final class DeviceStore {
    public let url: URL
    public private(set) var devices: [Device] = []

    public init(url: URL) {
        self.url = url
        load()
    }

    private static let coder: (JSONEncoder, JSONDecoder) = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (e, d)
    }()

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        do {
            devices = try Self.coder.1.decode([Device].self, from: data)
        } catch {
            Log.info("could not read \(url.path): \(error.localizedDescription)")
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.coder.0.encode(devices).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            Log.info("could not write \(url.path): \(error.localizedDescription)")
        }
    }

    /// Adds or updates a device. A device id that moves to a new token replaces the old entry
    /// (the app reinstalled or APNs rotated the token).
    @discardableResult
    public func register(_ d: Device) -> Device {
        var d = d
        d.token = d.token.lowercased()
        if let old = devices.first(where: { $0.token == d.token }) { d.registeredAt = old.registeredAt }
        devices.removeAll { $0.token == d.token || (d.deviceID != nil && $0.deviceID == d.deviceID) }
        devices.append(d)
        save()
        return d
    }

    @discardableResult
    public func remove(token: String) -> Bool {
        let n = devices.count
        devices.removeAll { $0.token == token.lowercased() }
        guard devices.count != n else { return false }
        save()
        return true
    }
}

/// A connected client, as `client.list` reports it.
public struct ClientSnapshot: Sendable, Equatable {
    public var clientID: String
    public var kind: String?
    public var platform: String?
    public var name: String?
    public var label: String?
    public var connectionState: String?
    public var tailscaleNode: String?

    public init(clientID: String, kind: String? = nil, platform: String? = nil, name: String? = nil,
                label: String? = nil, connectionState: String? = nil, tailscaleNode: String? = nil) {
        self.clientID = clientID
        self.kind = kind
        self.platform = platform
        self.name = name
        self.label = label
        self.connectionState = connectionState
        self.tailscaleNode = tailscaleNode
    }

    public init?(_ c: JSONObject) {
        guard let id = c.str("client_id") else { return nil }
        let info = c.obj("info") ?? [:]
        let p = c.obj("principal") ?? [:]
        self.init(clientID: id, kind: info.str("kind"), platform: info.str("platform"), name: info.str("name"),
                  label: info.str("label"), connectionState: c.str("connection_state"),
                  tailscaleNode: p.str("kind") == "tailscale" ? p.text("node") : nil)
    }
}

/// "Is Rex Connect open on this phone right now?"
public enum Presence {
    /// The device id at the end of a label: "Abe's iPhone #a1b2c3d4" → "a1b2c3d4".
    public static func deviceID(fromLabel label: String?) -> String? {
        guard let label, let hash = label.lastIndex(of: "#") else { return nil }
        let id = String(label[label.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
        return Device.isValidDeviceID(id) ? id.lowercased() : nil
    }

    /// True if an iOS app client from this device is connected and hasn't said it's in the background.
    /// A client matches by the "#<device_id>" at the end of its label. Only a registration that
    /// sent no device_id falls back to matching an unlabeled client by Tailscale device name,
    /// because several apps (e.g. simulators on one Mac) can share a node.
    public static func isAppOpen(_ d: Device, clients: [ClientSnapshot], backgrounded: Set<String>) -> Bool {
        clients.contains { c in
            guard c.kind == "app", c.platform == "ios", c.connectionState != "lost",
                  !backgrounded.contains(c.clientID) else { return false }
            let labelID = deviceID(fromLabel: c.label)
            if let want = d.deviceID?.lowercased() { return labelID == want }
            if labelID == nil, let node = d.tailscaleNode, let cn = c.tailscaleNode { return node == cn }
            return false
        }
    }
}
