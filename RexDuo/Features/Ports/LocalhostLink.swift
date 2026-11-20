import Foundation

/// A web address on the computer's own loopback (`http://localhost:5173/x`), which the phone can
/// only reach through Rex. Pure: what the link router and the browser need from a URL.
struct LocalhostLink: Equatable {
    var scheme: String
    /// How the browser names the host: `localhost` or `127.0.0.1`, never a port number of the
    /// computer's. `0.0.0.0`, any other 127/8 address and `[::1]` become `localhost`: the phone
    /// listens on IPv4 loopback only, and `localhost` reaches it there.
    var host: String
    /// Where the computer dials: `localhost` lets the computer pick IPv4 or IPv6.
    var dialHost: String
    var port: Int
    /// Path, query and fragment, as given.
    var rest: String

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = c.host?.lowercased(), !raw.isEmpty else { return nil }
        let bare = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        switch bare {
        case "localhost":
            host = "localhost"
            dialHost = "localhost"
        case "127.0.0.1":
            host = "127.0.0.1"
            dialHost = "127.0.0.1"
        case "::1":
            host = "localhost"
            dialHost = "::1"
        case "0.0.0.0":
            host = "localhost"
            dialHost = "127.0.0.1"
        default:
            guard Self.isLoopbackV4(bare) else { return nil }
            host = "localhost"
            dialHost = bare
        }
        self.scheme = scheme
        port = c.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { return nil }
        var r = c.percentEncodedPath
        if let q = c.percentEncodedQuery { r += "?" + q }
        if let f = c.percentEncodedFragment { r += "#" + f }
        rest = r
    }

    /// A menu open: plain http on `localhost`.
    init(port: Int, dialHost: String) {
        scheme = "http"
        host = "localhost"
        self.dialHost = dialHost
        self.port = port
        rest = "/"
    }

    /// The address the browser opens: the same page on the phone's listener.
    func url(localPort: Int) -> URL? {
        URL(string: "\(scheme)://\(host):\(localPort)\(rest.isEmpty ? "/" : rest)")
    }

    /// `localhost:5173`, as questions and notices name it.
    var name: String { "localhost:\(port)" }

    static func isLoopbackV4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { p in !p.isEmpty && p.count <= 3 && p.allSatisfy(\.isNumber) && Int(p)! <= 255 }
    }
}
