import Foundation

/// A web address on the computer's own loopback (`http://localhost:5173/x`), which the phone can
/// only reach through Rex. Pure: what the link router and the browser need from a URL.
struct LocalhostLink: Equatable {
    var scheme: String
    /// How the browser names the host: `localhost` or `127.0.0.1`, never a port number of the
    /// computer's. `0.0.0.0`, `[::]`, any other 127/8 address and `[::1]` become `localhost`: the phone
    /// listens on IPv4 loopback only, and `localhost` reaches it there.
    var host: String
    /// Where the computer dials: `localhost` lets the computer pick IPv4 or IPv6.
    var dialHost: String
    var port: Int
    /// Path, query and fragment, as given.
    var rest: String

    init?(_ url: URL) {
        guard let (scheme, c, bare) = Self.parts(url) else { return nil }
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
        case "::":
            // `python3 -m http.server` prints `http://[::]:8000/`: listening on every address.
            host = "localhost"
            dialHost = "::1"
        default:
            guard Self.isLoopbackV4(bare) else { return nil }
            host = "localhost"
            dialHost = bare
        }
        guard let (port, rest) = Self.portAndRest(scheme, c) else { return nil }
        self.scheme = scheme
        self.port = port
        self.rest = rest
    }

    /// A web address on a private network address (`http://10.0.0.246:3000`, as `next dev` and
    /// Vite print beside `localhost`): 10/8, 172.16/12, 192.168/16, 169.254/16 or fd00::/8. The
    /// computer dials that address; the browser names it `localhost`, so the page's own
    /// requests come back to the phone's listener. Whether it is the pane's own computer is the
    /// router's question (`PanePorts`): only a port that pane listens on makes it so. Nil for any
    /// other host, loopback included.
    init?(lan url: URL) {
        guard let (scheme, c, bare) = Self.parts(url), Self.isPrivate(bare),
              let (port, rest) = Self.portAndRest(scheme, c) else { return nil }
        self.scheme = scheme
        host = "localhost"
        dialHost = bare
        self.port = port
        self.rest = rest
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
        v4(s)?.first == 127
    }

    /// A private network address: 10/8, 172.16/12, 192.168/16, 169.254/16 (IPv4), fd00::/8 (IPv6).
    static func isPrivate(_ s: String) -> Bool {
        if let a = v4(s) {
            return a[0] == 10 || (a[0] == 172 && (16...31).contains(a[1])) || (a[0] == 192 && a[1] == 168)
                || (a[0] == 169 && a[1] == 254)
        }
        // IPv6: hex groups and colons only (no zone, no embedded IPv4), the first group fdXX.
        let groups = s.split(separator: ":", omittingEmptySubsequences: false)
        guard s.contains("::") || groups.count == 8, groups.count >= 3, groups.count <= 8,
              groups.allSatisfy({ $0.count <= 4 && $0.allSatisfy(\.isHexDigit) }),
              let first = groups.first, first.count == 4 else { return false }
        return first.lowercased().hasPrefix("fd")
    }

    /// The four parts of a dotted IPv4 address, or nil.
    private static func v4(_ s: String) -> [Int]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isASCII), p.allSatisfy(\.isNumber), let n = Int(p), n <= 255 else { return nil }
            out.append(n)
        }
        return out
    }

    /// The scheme (http or https), the parsed address and its bare host, lowercased.
    private static func parts(_ url: URL) -> (String, URLComponents, String)? {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw = c.host?.lowercased(), !raw.isEmpty else { return nil }
        return (scheme, c, raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
    }

    private static func portAndRest(_ scheme: String, _ c: URLComponents) -> (Int, String)? {
        let port = c.port ?? (scheme == "https" ? 443 : 80)
        guard (1...65535).contains(port) else { return nil }
        var r = c.percentEncodedPath
        if let q = c.percentEncodedQuery { r += "?" + q }
        if let f = c.percentEncodedFragment { r += "#" + f }
        return (port, r)
    }
}
