import Foundation

/// What a Rex server says about its computer, for showing before the server is added: read from
/// `server.status`, `server.version`, `server.whoami`, `session.list` and `client.list`, which
/// change nothing on the server.
public struct ServerIdentity: Equatable, Sendable {
    public enum Platform: String, Equatable, Sendable { case mac, linux, other }

    // Every field is nil when the server didn't say: a call that failed or timed out is not an
    // answer, so nothing here may be shown as "none" or "no" unless the server said so.

    public var platform: Platform?
    /// The computer account Rex runs as (`server.whoami.account`).
    public var account: String?
    /// The account login that owns the server on its private network. Nil for a server with no
    /// single owner (a tagged machine) or a name that isn't an account login.
    public var owner: String?
    /// The account login the server identified this device as. Nil when the device wasn't
    /// identified by a login (a local connection, a tagged machine).
    public var viewer: String?
    public var sessionCount: Int?
    /// Session labels, in the server's order.
    public var sessions: [String]
    /// A push helper is connected to the server.
    public var hasHelper: Bool?

    public init(platform: Platform? = nil, account: String? = nil, owner: String? = nil, viewer: String? = nil,
                sessionCount: Int? = nil, sessions: [String] = [], hasHelper: Bool? = nil) {
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

    /// From the five replies; nil for a call that got no reply. A reply without the field asked
    /// for leaves it unknown too.
    public init(status: JSONObject?, version: JSONObject?, whoami: JSONObject?, sessions: JSONObject?, clients: JSONObject?) {
        let listed = sessions?["sessions"] is [Any] ? sessions?.arr("sessions") : nil
        let tailscale = status?.obj("tailscale")
        let principal = whoami?.obj("principal")
        self.init(
            platform: version?.str("platform").map(Self.platform),
            account: Self.text(whoami?.str("account")),
            // A tagged server has no owner.
            owner: Self.tags(tailscale).isEmpty ? Self.login(tailscale?.obj("account")?.str("login_name")) : nil,
            // Only a device a person signed in is compared with the owner.
            viewer: principal?.str("kind") == "tailscale" && Self.tags(principal).isEmpty
                ? Self.login(principal?.str("login_name")) : nil,
            sessionCount: listed.map { max($0.count, status?.int("session_count") ?? 0) } ?? status?.int("session_count"),
            sessions: (listed ?? []).compactMap { $0.str("label") }.filter { !$0.isEmpty },
            hasHelper: clients?["clients"] is [Any]
                ? clients?.arr("clients").contains {
                    $0.obj("info")?.str("name") == Self.helperName && $0.str("connection_state") != "lost"
                } : nil)
    }

    /// `darwin_arm64` is a Mac, `linux_amd64` is Linux.
    static func platform(_ raw: String) -> Platform {
        let os = raw.lowercased()
        if os.hasPrefix("darwin") || os.hasPrefix("macos") { return .mac }
        if os.hasPrefix("linux") { return .linux }
        return .other
    }

    private static func text(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func tags(_ o: JSONObject?) -> [String] {
        (o?["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
    }

    /// An account login, `name@domain`. Anything else (a device name, a tag, a placeholder) isn't
    /// one, and isn't compared.
    static func login(_ s: String?) -> String? {
        guard let t = text(s), !t.contains(where: \.isWhitespace) else { return nil }
        let parts = t.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return t
    }

    /// The server belongs to an account other than the one this device is signed in with. False
    /// when either is unknown: nothing to compare.
    public var belongsToSomeoneElse: Bool {
        guard let owner, let viewer else { return false }
        return owner.caseInsensitiveCompare(viewer) != .orderedSame
    }

    /// The server's owner and this device's login are both known and the same account, compared
    /// without case. False when either is unknown (a tagged server, a local connection, a name
    /// that isn't a login): unlike `belongsToSomeoneElse`, only a match counts.
    public var isConfirmedOwn: Bool {
        guard let owner, let viewer else { return false }
        return owner.caseInsensitiveCompare(viewer) == .orderedSame
    }
}

/// Reads a server's identity over one short control connection: hello, five read-only calls, a
/// clean close. The client attaches to nothing, so the server drops it the moment it closes.
@MainActor
public enum ServerPreview {
    /// Nil when the server didn't answer in `timeout`, or the calling task was cancelled. A server
    /// that answers some calls and not others gives what it answered, and the rest stays unknown.
    /// One attempt: a failure is not retried.
    public static func fetch(address: String, client: ClientInfo, timeout: TimeInterval = 6) async -> ServerIdentity? {
        let control = RexControl(address: address, client: client)
        // Ends the connection, which fails whatever is still waiting on it, on timeout or cancel.
        let deadline = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            control.disconnect()
        }
        defer {
            deadline.cancel()
            control.invalidate()
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
                return ServerIdentity(status: st?.value, version: ve?.value, whoami: wh?.value,
                                      sessions: se?.value, clients: cl?.value)
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
