import Foundation

/// Why a control connection failed, as plain values: the error URLSession reported (and the POSIX or
/// TLS code under it), the HTTP status of a refused WebSocket upgrade, and the close code. The app
/// sorts these into cases a person can act on; RexKit only records them.
public struct ConnectionFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public static let rexDomain = "RexControl"

    public var domain: String
    public var code: Int
    /// The error under it (`NSUnderlyingErrorKey`), e.g. POSIX 61 under a URL error.
    public var underlyingDomain: String?
    public var underlyingCode: Int?
    /// CFNetwork's stream error code (`_kCFStreamErrorCodeKey`): a POSIX errno or an SSL status.
    public var streamCode: Int?
    /// The HTTP status when the server answered the upgrade with something other than 101.
    public var httpStatus: Int?
    /// The WebSocket close code, when the server closed the socket.
    public var closeCode: Int?
    /// The reason the server gave with its close code, when it gave one.
    public var closeReason: String?
    public var message: String

    public init(domain: String, code: Int, message: String, underlyingDomain: String? = nil, underlyingCode: Int? = nil,
                streamCode: Int? = nil, httpStatus: Int? = nil, closeCode: Int? = nil, closeReason: String? = nil) {
        self.domain = domain
        self.code = code
        self.message = message
        self.underlyingDomain = underlyingDomain
        self.underlyingCode = underlyingCode
        self.streamCode = streamCode
        self.httpStatus = httpStatus
        self.closeCode = closeCode
        self.closeReason = closeReason
    }

    /// Records any error. `httpStatus`, `closeCode` and `closeReason` come from the socket task,
    /// not the error.
    public init(_ error: Error, httpStatus: Int? = nil, closeCode: Int? = nil, closeReason: String? = nil) {
        if let f = error as? ConnectionFailure {
            self = f
            if let httpStatus { self.httpStatus = httpStatus }
            if let closeCode { self.closeCode = closeCode }
            if let closeReason { self.closeReason = closeReason }
            return
        }
        if let r = error as? RexError {
            self.init(domain: Self.rexDomain, code: r.status, message: r.message, httpStatus: httpStatus,
                      closeCode: closeCode, closeReason: closeReason)
            return
        }
        let ns = error as NSError
        let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError
        let stream = ns.userInfo["_kCFStreamErrorCodeKey"] as? Int
        self.init(domain: ns.domain, code: ns.code, message: ns.localizedDescription,
                  underlyingDomain: under?.domain, underlyingCode: under?.code,
                  streamCode: stream, httpStatus: httpStatus, closeCode: closeCode, closeReason: closeReason)
    }

    /// Which side must be updated when the server and the client share no API revision.
    public enum RevisionRefusal: Equatable, Sendable {
        /// The server is too old for this client.
        case updateServer
        /// This client is too old for the server.
        case updateClient
        /// The reason doesn't say.
        case unclear
    }

    /// What every "no common API revision" reason starts with.
    public static let noCommonRevision = "no common API revision"

    /// Set when the server closed with 1008 because the two sides share no API revision. Trying
    /// again can't help until one of them is updated. The other 1008, `event backlog exceeded`,
    /// is an ordinary drop: nil here, and the connection is made again.
    public var revisionRefusal: RevisionRefusal? {
        guard closeCode == 1008, let reason = closeReason, reason.hasPrefix(Self.noCommonRevision) else { return nil }
        let r = reason.lowercased()
        if r.contains("update the server") { return .updateServer }
        if r.contains("update the client") { return .updateClient }
        return .unclear
    }

    /// No welcome in time.
    public static func timedOut() -> ConnectionFailure {
        ConnectionFailure(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, message: "No answer from the server in time.")
    }

    /// The configured address can't be turned into a WebSocket URL.
    public static func invalidAddress(_ address: String) -> ConnectionFailure {
        ConnectionFailure(domain: rexDomain, code: 1,
                          message: "“\(address)” isn't a server address. Use https://<name>.<tailnet>.ts.net.")
    }

    public var isInvalidAddress: Bool { domain == Self.rexDomain && code == 1 }

    /// The server's side answered: an HTTP status, a close code, or a refused port. The computer
    /// is on and in reach, whatever it said. False for a timeout, a lost connection or no route.
    public var peerAnswered: Bool {
        httpStatus != nil || closeCode != nil || posixCode == Int(ECONNREFUSED)
    }

    /// The POSIX errno behind the failure, wherever URLSession put it.
    public var posixCode: Int? {
        if domain == NSPOSIXErrorDomain { return code }
        if underlyingDomain == NSPOSIXErrorDomain { return underlyingCode }
        if let s = streamCode, s > 0 { return s }
        return nil
    }

    /// One short technical line: domain and code, the code under it, HTTP status and close code.
    public var detail: String {
        var parts = ["\(domain) \(code)"]
        if let d = underlyingDomain, let c = underlyingCode { parts.append("\(d) \(c)") }
        if let s = httpStatus { parts.append("HTTP \(s)") }
        if let c = closeCode { parts.append("close \(c)") }
        return parts.joined(separator: " · ")
    }

    public var description: String { "\(message) (\(detail))" }
}
