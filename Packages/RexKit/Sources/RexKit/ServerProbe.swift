import Foundation

/// Asks whether a Rex server answers at an address, without connecting to it: a plain
/// `GET /api/control`, which Rex answers with 426 (it wants the WebSocket upgrade). No hello is
/// sent, so the server never sees a client.
public enum ServerProbe {
    /// Nil when Rex answered; otherwise why not, in the form `RexControl` reports failures.
    /// Cancelling the calling task ends the request.
    public static func check(address: String, timeout: TimeInterval = 6) async -> ConnectionFailure? {
        await check(address: address, timeout: timeout, protocols: nil)
    }

    /// `protocols` replaces the network in tests.
    static func check(address: String, timeout: TimeInterval, protocols: [AnyClass]?) async -> ConnectionFailure? {
        guard let url = url(for: address) else { return .invalidAddress(address) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.waitsForConnectivity = false
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        if let protocols { cfg.protocolClasses = protocols }
        let session = URLSession(configuration: cfg)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (_, response) = try await session.data(for: request, delegate: NoRedirects())
            return failure(status: (response as? HTTPURLResponse)?.statusCode)
        } catch {
            return ConnectionFailure(error)
        }
    }

    /// `https://host[:port]/api/control` for a server address, or nil when the address has no host
    /// or isn't http(s).
    static func url(for address: String) -> URL? {
        guard var c = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = c.host, !host.isEmpty, let scheme = c.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        c.path = "/api/control"
        c.query = nil
        c.fragment = nil
        return c.url
    }

    /// What an HTTP answer to the probe means. 426 is Rex asking for the upgrade; anything else is
    /// a refusal or something that isn't Rex.
    public static func failure(status: Int?) -> ConnectionFailure? {
        if status == 426 { return nil }
        return ConnectionFailure(domain: NSURLErrorDomain, code: NSURLErrorBadServerResponse,
                                 message: "The address answered, but not as a Rex server.", httpStatus: status)
    }

    /// The answer must come from the address asked: a redirect is not followed, so its 3xx is the
    /// answer, and another host's 426 never counts.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }
}
