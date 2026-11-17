import Foundation

/// What a Rex server says about its computer, for showing before the server is added: read from
/// `server.status`, `server.version`, `server.whoami`, `session.list` and `client.list`, which
/// change nothing on the server.
public struct ServerIdentity: Equatable, Sendable {
    public enum Platform: String, Equatable, Sendable { case mac, linux, other }

    public var platform: Platform
    /// The computer account Rex runs as (`server.whoami.account`).
    public var account: String?
    /// The login that owns the server on its private network.
    public var owner: String?
    /// The login the server identified this device as.
    public var viewer: String?
    public var sessionCount: Int
    /// Session labels, in the server's order.
    public var sessions: [String]
    /// A push helper is connected to the server.
    public var hasHelper: Bool

    public init(platform: Platform = .other, account: String? = nil, owner: String? = nil, viewer: String? = nil,
                sessionCount: Int = 0, sessions: [String] = [], hasHelper: Bool = false) {
        self.platform = platform
        self.account = account
        self.owner = owner
        self.viewer = viewer
        self.sessionCount = sessionCount
        self.sessions = sessions
        self.hasHelper = hasHelper
    }

    /// The name the helper gives in its hello. A helper that dropped lingers as `lost` for a minute.
    public static let helperName = "rex-push-relay"

    /// From the five replies. A missing or malformed reply leaves its fields empty.
    public init(status: JSONObject, version: JSONObject, whoami: JSONObject, sessions: JSONObject, clients: JSONObject) {
        let labels = sessions.arr("sessions").compactMap { $0.str("label") }.filter { !$0.isEmpty }
        self.init(
            platform: Self.platform(version.str("platform")),
            account: Self.text(whoami.str("account")),
            owner: Self.text(status.obj("tailscale")?.obj("account")?.str("login_name")),
            viewer: Self.text(whoami.obj("principal")?.str("login_name")),
            sessionCount: max(status.int("session_count") ?? 0, sessions.arr("sessions").count),
            sessions: labels,
            hasHelper: clients.arr("clients").contains {
                $0.obj("info")?.str("name") == Self.helperName && $0.str("connection_state") != "lost"
            })
    }

    /// `darwin_arm64` is a Mac, `linux_amd64` is Linux.
    static func platform(_ raw: String?) -> Platform {
        guard let os = raw?.lowercased() else { return .other }
        if os.hasPrefix("darwin") || os.hasPrefix("macos") { return .mac }
        if os.hasPrefix("linux") { return .linux }
        return .other
    }

    private static func text(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// The server belongs to someone other than the login this device connects as. False when
    /// either is unknown: nothing to compare.
    public var belongsToSomeoneElse: Bool {
        guard let owner, let viewer else { return false }
        return owner.caseInsensitiveCompare(viewer) != .orderedSame
    }
}

/// Reads a server's identity over one short control connection: hello, five read-only calls, a
/// clean close. The client attaches to nothing, so the server drops it the moment it closes.
@MainActor
public enum ServerPreview {
    /// Nil when the server didn't answer in `timeout`, or the calling task was cancelled. A server
    /// that answers some calls and not others gives what it answered.
    public static func fetch(address: String, client: ClientInfo, timeout: TimeInterval = 6) async -> ServerIdentity? {
        let control = RexControl(address: address, client: client)
        // Ends the connection, which fails whatever is still waiting on it, on timeout or cancel.
        let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            control.disconnect()
        }
        defer {
            deadline.cancel()
            control.disconnect()
        }
        return await withTaskCancellationHandler {
            do {
                try await control.connect()
                async let status = reply(control, "server.status")
                async let version = reply(control, "server.version")
                async let whoami = reply(control, "server.whoami")
                async let sessions = reply(control, "session.list")
                async let clients = reply(control, "client.list")
                let (st, ve, wh, se, cl) = await (status, version, whoami, sessions, clients)
                guard st != nil || ve != nil || wh != nil || se != nil || cl != nil, !Task.isCancelled else { return nil }
                return ServerIdentity(status: st?.value ?? [:], version: ve?.value ?? [:], whoami: wh?.value ?? [:],
                                      sessions: se?.value ?? [:], clients: cl?.value ?? [:])
            } catch {
                return nil
            }
        } onCancel: {
            Task { @MainActor in control.disconnect() }
        }
    }

    /// A reply crossing the `async let` boundary. `@unchecked Sendable` because JSONSerialization's
    /// values are immutable.
    private struct Reply: @unchecked Sendable { let value: JSONObject }

    private static func reply(_ control: RexControl, _ method: String) async -> Reply? {
        (try? await control.call(method)).map(Reply.init)
    }
}
