import Foundation
import RexKit

/// What the phone knows about its own network: whether any path is up, and whether it appears to be
/// on a Tailscale network (nil when it can't tell).
struct NetworkSnapshot: Equatable, Sendable {
    var reachable: Bool
    var onPrivateNetwork: Bool?
    /// The interfaces the path can use, so a switch from Wi-Fi to cellular counts as a change.
    var route = ""
    /// The path is cellular or a hotspot (`NWPath.isExpensive`).
    var expensive = false

    static let unknown = NetworkSnapshot(reachable: true, onPrivateNetwork: nil)
}

/// Why a server can't be reached, sorted into the few cases a person can act on. `classify` turns
/// a raw `ConnectionFailure` into one; the offline screen and the sidebar word it.
struct ConnectionProblem: Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        /// The phone has no network at all, or cellular data is off for the app.
        case noInternet
        /// The private address doesn't resolve or answer, and the phone isn't on a tailnet.
        case offPrivateNetwork
        /// The phone is on a tailnet, but the server's name isn't on it.
        case hostNotFound
        /// The server's address answers with a refusal, a non-Rex reply, or not at all while the
        /// phone is on the tailnet: the Mac is asleep, or Rex isn't running.
        case notAnswering
        /// The server turned the device away (401/403, or a policy close).
        case notAllowed
        /// TLS failed: the certificate couldn't be verified, or the address isn't https.
        case insecure
        /// The server closed with "no common API revision" and named itself: its Rex is too old
        /// for this app. Retrying can't help until Rex is updated there.
        case updateServer
        /// The same close, naming the client: this app is too old for the server's Rex.
        case updateApp
        /// The configured address isn't a server address; retrying can't help.
        case badAddress
        case unknown

        /// Shown at once, without waiting for a second failure of the same kind.
        var isDecisive: Bool {
            switch self {
            case .noInternet, .notAllowed, .insecure, .badAddress, .updateServer, .updateApp: return true
            default: return false
            }
        }
    }

    var kind: Kind
    /// A short technical line (error domain, code, HTTP status) for the collapsed details.
    var detail: String

    // MARK: Classification

    static func classify(_ f: ConnectionFailure, network: NetworkSnapshot) -> ConnectionProblem {
        ConnectionProblem(kind: kind(of: f, network: network), detail: f.detail)
    }

    private static func kind(of f: ConnectionFailure, network: NetworkSnapshot) -> Kind {
        if f.isInvalidAddress { return .badAddress }
        if !network.reachable { return .noInternet }

        // The server answered over HTTP but didn't upgrade to Rex's socket.
        if let s = f.httpStatus {
            switch s {
            case 401, 403, 407: return .notAllowed
            case 404, 426, 500...599: return .notAnswering
            default: break
            }
        }
        // The two sides share no API revision. A reason that names neither side reads as before.
        switch f.revisionRefusal {
        case .updateServer: return .updateServer
        case .updateClient: return .updateApp
        case .unclear, nil: break
        }
        // Closed with a policy or auth code after the upgrade.
        if let c = f.closeCode, [1008, 4001, 4003, 4401, 4403].contains(c) { return .notAllowed }

        // Unreachable: off the tailnet, unless the phone is clearly on one.
        let unreachable: Kind = network.onPrivateNetwork == true ? .notAnswering : .offPrivateNetwork

        if f.domain == NSURLErrorDomain {
            switch f.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorInternationalRoamingOff,
                 NSURLErrorCallIsActive, NSURLErrorDataNotAllowed:
                return .noInternet
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return network.onPrivateNetwork == true ? .hostNotFound : .offPrivateNetwork
            case NSURLErrorTimedOut, NSURLErrorNetworkConnectionLost:
                return unreachable
            case NSURLErrorCannotConnectToHost:
                if let p = f.posixCode {
                    if p == Int(ECONNREFUSED) { return .notAnswering }
                    if [Int(EHOSTUNREACH), Int(ENETUNREACH), Int(ETIMEDOUT)].contains(p) { return unreachable }
                }
                return network.onPrivateNetwork == false ? .offPrivateNetwork : .notAnswering
            case NSURLErrorBadServerResponse, NSURLErrorZeroByteResource, NSURLErrorCannotParseResponse:
                return .notAnswering
            case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication,
                 NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
                return .notAllowed
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return .insecure
            default:
                break
            }
        }
        // Secure Transport / Network framework TLS status codes (errSSL…, -9800 to -9899).
        if (-9899 ... -9800).contains(f.streamCode ?? 0) || (-9899 ... -9800).contains(f.underlyingCode ?? 0) {
            return .insecure
        }
        if let p = f.posixCode {
            switch Int32(p) {
            case ECONNREFUSED: return .notAnswering
            case ENETDOWN: return .noInternet
            case EHOSTUNREACH, ENETUNREACH, ETIMEDOUT, ENOTCONN, ECONNRESET, EPIPE: return unreachable
            default: break
            }
        }
        return .unknown
    }
}

/// Hysteresis for the problem on screen. The same kind keeps what's shown (no re-render for a new
/// error string), a decisive kind replaces it at once, and any other kind must show up on two
/// failures in a row first, so alternating errors don't make the screen jump between messages.
struct ProblemGate: Equatable {
    private(set) var shown: ConnectionProblem?
    private var candidate: ConnectionProblem.Kind?
    /// Set when the network changed: the next problem is taken as is.
    private var fresh = false

    mutating func observe(_ p: ConnectionProblem) -> ConnectionProblem {
        guard let cur = shown else { return accept(p) }
        if p.kind == cur.kind { candidate = nil; fresh = false; return cur }
        if fresh || p.kind.isDecisive || candidate == p.kind { return accept(p) }
        candidate = p.kind
        return cur
    }

    /// The phone's network changed, so the old diagnosis may be stale.
    mutating func networkChanged() { fresh = true }

    mutating func reset() { self = ProblemGate() }

    private mutating func accept(_ p: ConnectionProblem) -> ConnectionProblem {
        shown = p
        candidate = nil
        fresh = false
        return p
    }
}
