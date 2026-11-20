import Foundation

/// A link that opens the app: what a control hands the system, and what the app reads back in
/// `onOpenURL`. Links only navigate. None types, resizes or changes anything on a server beyond
/// what a tapped notification for the same pane does.
///
/// | URL | Effect |
/// |---|---|
/// | `rexduo://open` | brings the app forward, nothing else |
/// | `rexduo://waiting` | opens the agent that has waited longest |
/// | `rexduo://pair` | opens "Pair via QR Code", unless a sheet is up |
/// | `rexduo://pane?server=…&session=…&window=…&block=…` | opens that pane (`PaneLink`) |
/// | any other `rexduo:` URL | `open` |
///
/// A URL of another scheme is no link at all (`init` returns nil), so nothing a web page or
/// another app passes in under `http:`, `javascript:` or `file:` is ever acted on.
public enum DeepLink: String, Equatable, Sendable, CaseIterable {
    case open
    case waiting
    case pair

    public static let scheme = "rexduo"

    /// The link a URL stands for. Nil unless the scheme is `rexduo`. Within the scheme, only an
    /// exact host (not a percent-encoded spelling of it) with no path, user, password or port
    /// names a link; everything else is `open`, the link with no effect. A query and a fragment
    /// are ignored: no link here takes parameters (`PaneLink` reads its own).
    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty || parts.path == "/",
              let host = parts.encodedHost?.lowercased(), let link = DeepLink(rawValue: host) else {
            self = .open
            return
        }
        self = link
    }

    /// `rexduo://<link>`.
    public var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = rawValue
        // A scheme and a host from this file's own constants always make a URL.
        return parts.url ?? URL(fileURLWithPath: "/")
    }
}

/// The link a widget's row opens: one pane, named by the server's id in the app and Rex's ids.
/// The server id is a random UUID that only the app and its own extensions know (it is in the
/// App Group's snapshot and nowhere else), so another app or a web page can't make a link that
/// the app accepts. The app still opens only a pane it has loaded, or one the snapshot lists
/// as waiting (`OpenPaneLink`).
public struct PaneLink: Equatable, Sendable {
    public static let host = "pane"

    public var server: String
    public var session: String
    public var window: String
    public var block: String

    public init(server: String, session: String, window: String, block: String) {
        self.server = server
        self.session = session
        self.window = window
        self.block = block
    }

    /// Nil unless the URL is exactly `rexduo://pane?…` with all four values, each given once
    /// and not empty, and nothing else in the URL.
    public init?(_ url: URL) {
        guard url.scheme?.lowercased() == DeepLink.scheme,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.encodedHost?.lowercased() == Self.host,
              let items = parts.queryItems, items.count == 4 else { return nil }
        func value(_ name: String) -> String? {
            let found = items.filter { $0.name == name }
            guard found.count == 1, let v = found[0].value, !v.isEmpty, v.count <= Self.limit else { return nil }
            return v
        }
        guard let server = value("server"), let session = value("session"), let window = value("window"),
              let block = value("block") else { return nil }
        self.init(server: server, session: session, window: window, block: block)
    }

    /// The longest value a link may carry. Rex's ids and a UUID are far shorter.
    static let limit = 200

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = DeepLink.scheme
        parts.host = Self.host
        parts.queryItems = [URLQueryItem(name: "server", value: server), URLQueryItem(name: "session", value: session),
                            URLQueryItem(name: "window", value: window), URLQueryItem(name: "block", value: block)]
        return parts.url ?? DeepLink.open.url
    }
}
