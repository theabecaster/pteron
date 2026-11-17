import Foundation
import RexKit

/// The per-install id the helper uses to tell phones apart, and the Rex client label that carries it
/// (see the contract in docs/notifications.md).
enum PushIdentity {
    /// Rex caps client labels at 64 bytes.
    static let maxLabelBytes = 64

    /// 8 lowercase hex characters: the start of `identifierForVendor`, or of a random id when iOS
    /// gives none (it can, briefly, right after a device restart).
    static func deviceID(vendorID: UUID?) -> String {
        let hex = (vendorID ?? UUID()).uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(hex.prefix(8))
    }

    /// `"<device name> #<device id>"`, shortening the name (never the suffix) to fit 64 bytes.
    static func clientLabel(deviceName: String, deviceID: String) -> String {
        let suffix = " #" + deviceID
        return fitted(deviceName, bytes: maxLabelBytes - suffix.utf8.count) + suffix
    }

    /// The label of the short connection that reads who a computer is before it is added: the
    /// device name alone, within the 64 bytes. No device id, so the helper doesn't take it for
    /// this iPhone having the app open.
    static func previewLabel(deviceName: String) -> String {
        fitted(deviceName, bytes: maxLabelBytes)
    }

    /// The name cut to whole characters that fit `bytes` of UTF-8; "iPhone" when nothing is left.
    private static func fitted(_ deviceName: String, bytes: Int) -> String {
        var name = deviceName.trimmingCharacters(in: .whitespaces)
        while name.utf8.count > bytes { name.removeLast() }
        name = name.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "iPhone" : name
    }

    static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }
}

/// Which APNs environment issued this build's device token. It follows how the build was signed,
/// not Debug or Release: a Release build installed with a development profile still gets sandbox
/// tokens.
enum APNsEnvironment {
    static let sandbox = "sandbox"
    static let production = "production"

    /// - `isSimulator`: simulators only ever get sandbox tokens.
    /// - `profile`: `embedded.mobileprovision`. TestFlight and App Store builds have none, and they
    ///   are production.
    static func detect(profile: Data?, isSimulator: Bool) -> String {
        if isSimulator { return sandbox }
        guard let profile, let ent = entitlements(inProfile: profile) else { return production }
        if let aps = ent["aps-environment"] as? String { return aps == "development" ? sandbox : production }
        return (ent["get-task-allow"] as? Bool) == true ? sandbox : production
    }

    /// The profile is a signed CMS envelope around an XML plist; the plist sits in it as plain text.
    static func entitlements(inProfile data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil)
        return (plist as? [String: Any])?["Entitlements"] as? [String: Any]
    }

    static var current: String {
        #if targetEnvironment(simulator)
        let sim = true
        #else
        let sim = false
        #endif
        let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision").flatMap { try? Data(contentsOf: $0) }
        return detect(profile: profile, isSimulator: sim)
    }
}

/// Finds Rex DUO Helper among a server's clients.
enum RelayLookup {
    static let clientName = "rex-push-relay"
    /// How Rex says a client connected on the server's own machine (its socket, or the Windows
    /// equivalent). Rex asserts this; a client can't claim it.
    static let localKinds: Set<String> = ["peer", "windows_peer"]

    /// The last client named `rex-push-relay` that isn't `lost` and runs on the server's own
    /// machine (clients come in connection order). A relay that just restarted can linger as
    /// `lost` for a minute next to the new one. Anyone on the tailnet can connect under that name,
    /// so a client that came in another way is never taken for the helper.
    static func relayID(in clients: [JSONObject]) -> String? {
        clients.last { c in
            c.obj("info")?.str("name") == clientName && c.str("connection_state") != "lost"
                && localKinds.contains(c.obj("principal")?.str("kind") ?? "")
        }?.str("client_id")
    }
}

/// What a helper says about itself (`helper_status`): its version and whether it can and should
/// update.
struct HelperVersion: Equatable, Sendable {
    var version: String
    var latest: String?
    var updateAvailable: Bool
    /// False when the helper can't replace itself: a development build, a test run, an odd install.
    var canUpdate: Bool
    var updating: Bool
    var lastError: String?
    /// The running version is below the oldest one the release list still allows.
    var updateRequired: Bool
    /// Whether the helper holds a working registration for this phone. Nil from a helper that
    /// doesn't say.
    var registered: Bool?
    /// Mac: whether the helper may show its own notices on the computer: `allowed`, `denied` or
    /// `undetermined`. Nil elsewhere, and from a helper that doesn't say.
    var notices: String?
    /// Linux: whether the helper keeps running after logout. Nil elsewhere.
    var linger: Bool?
    /// When the release list the helper last accepted expires.
    var manifestExpiresAt: Date?

    init?(_ result: JSONObject) {
        guard let version = result.str("version"), !version.isEmpty else { return nil }
        self.version = version
        latest = result.str("latest_version")
        updateAvailable = result.bool("update_available") ?? false
        canUpdate = result.bool("can_update") ?? false
        updating = result.bool("updating") ?? false
        lastError = result.str("last_error")
        updateRequired = result.bool("update_required") ?? false
        registered = result.bool("registered")
        notices = result.str("notices")
        linger = result.bool("linger")
        manifestExpiresAt = result.str("manifest_expires_at").flatMap(HelperRelease.timestamp)
    }

    /// The one line Settings shows under the helper's name.
    var summary: String {
        if updating { return "Updating to \(latest ?? "the latest version")…" }
        if updateRequired { return "Version \(version) needs an update to keep working." }
        if updateAvailable, let latest { return "Version \(version). Version \(latest) is available." }
        // No check has come back yet: say only what is known.
        return latest == nil ? "Version \(version)." : "Version \(version), up to date."
    }

    /// Settings offers "Update" only when pressing it would do something.
    var offersUpdate: Bool { (updateAvailable || updateRequired) && canUpdate && !updating }

    /// A helper from before the gateway refuses a registration that has no APNs token with this.
    static func isLegacyRefusal(_ message: String) -> Bool {
        message.hasPrefix("token must be")
    }
}

/// Where a push points: a pane on one of the user's servers. Parsed from the payload the helper
/// sends (`server`, `session_id`, `window_id`, `block_id`).
struct PushRoute: Equatable, Sendable {
    var server: String
    var sessionID: String
    var windowID: String?
    var blockID: String?

    init(server: String, sessionID: String, windowID: String? = nil, blockID: String? = nil) {
        self.server = server
        self.sessionID = sessionID
        self.windowID = windowID
        self.blockID = blockID
    }

    init?(userInfo: [AnyHashable: Any]) {
        func text(_ k: String) -> String? {
            guard let s = userInfo[k] as? String, !s.isEmpty else { return nil }
            return s
        }
        guard let server = text("server"), let session = text("session_id") else { return nil }
        self.init(server: server, sessionID: session, windowID: text("window_id"), blockID: text("block_id"))
    }

    /// True when the push came from this server: its address as entered in the app, or the
    /// Tailscale name the server reported. Hosts compare without case, scheme or trailing dot.
    func matches(serverURL: String, hostName: String?) -> Bool {
        guard let want = Self.host(server) else { return false }
        if Self.host(serverURL) == want { return true }
        if let hostName, Self.host(hostName) == want { return true }
        return false
    }

    static func host(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        let withScheme = t.contains("://") ? t : "https://" + t
        guard var h = URLComponents(string: withScheme)?.host?.lowercased(), !h.isEmpty else { return nil }
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }
}
