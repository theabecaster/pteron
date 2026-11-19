import Foundation

/// A link that opens the app: what a control hands the system, and what the app reads back in
/// `onOpenURL`. Links only navigate. None types, resizes or changes anything on a server beyond
/// what a tapped notification for the same pane does.
///
/// | URL | Effect |
/// |---|---|
/// | `rexduo://open` | brings the app forward, nothing else |
/// | `rexduo://waiting` | opens the agent that has waited longest |
/// | any other `rexduo:` URL | `open` |
///
/// A URL of another scheme is no link at all (`init` returns nil), so nothing a web page or
/// another app passes in under `http:`, `javascript:` or `file:` is ever acted on.
public enum DeepLink: String, Equatable, Sendable, CaseIterable {
    case open
    case waiting

    public static let scheme = "rexduo"

    /// The link a URL stands for. Nil unless the scheme is `rexduo`. Within the scheme, only an
    /// exact host (not a percent-encoded spelling of it) with no path, user, password or port
    /// names a link; everything else is `open`, the link with no effect. A query and a fragment are ignored: no link here takes parameters.
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
