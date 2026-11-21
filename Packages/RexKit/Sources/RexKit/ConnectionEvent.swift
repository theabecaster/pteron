import Foundation

/// One line of the connection log: something that happened to a server's control connection, to
/// the phone's network or to the app, and when.
///
/// An event is numbers only. It has no text field, so it cannot hold a host name, an address, a
/// URL, a computer's label, a session or pane name, terminal content or a token: a server is a
/// salted hash (`ConnectionJournal.tag`), and a failure is a kind and its error codes, never its
/// message (`Cause.of`). Every event is `ConnectionEvent.size` bytes in the file.
public struct ConnectionEvent: Equatable, Sendable {
    public enum Kind: UInt8, Sendable, CaseIterable {
        /// The app's process started. `value`: the build number.
        case launch = 1
        /// The scene changed phase. `flags`: a `Scene`.
        case scene
        /// The phone's network path changed. `flags`: a `Network`.
        case network
        /// An attempt began: a socket was opened to the server. `flags`: the `AttemptTrigger`
        /// that asked for it, 0 when unknown.
        case connecting
        /// The server's welcome arrived. `value`: milliseconds since the attempt began.
        case connected
        /// The attempt or the connection ended. `cause`, `code` and `value` say how.
        case closed
        /// The next attempt was set. `value`: milliseconds from now, 0 for at once.
        case retry
        /// The app ended the connection itself: the server was removed or stopped.
        case stopped
        /// The server gave no answer time after time and retries stopped. The next `connecting`
        /// says what asked for the attempt that follows; a `connected` ends it.
        case dormant
        /// The tunnel breaker opened or closed (an event of the app). `flags`: 1 open, 0 closed.
        case breaker
        /// A TCP connection to Tailscale's own service on this phone was tried, as the breaker
        /// opened (an event of the app). `flags`: 1 it connected, 0 it did not. `value`:
        /// milliseconds it took. For the log only: nothing on screen depends on it.
        case probe
    }

    /// Why a connection ended, as far as the error's codes say.
    public enum Cause: UInt8, Sendable, CaseIterable {
        case none = 0
        /// No answer in time: the system's timeout, or the app's own deadline for a welcome or a pong.
        case timeout
        /// The connection was lost with no more detail.
        case lost
        /// The other side reset the connection.
        case reset
        /// The address answered and refused the connection.
        case refused
        /// No route to the host or the network.
        case unreachable
        /// The name didn't resolve.
        case dns
        /// TLS failed.
        case tls
        /// The upgrade was answered with an HTTP status. `code`: the status.
        case http
        /// The server turned the client away: HTTP 401, 403 or 407, or a certificate it asked for.
        case auth
        /// The server closed the socket. `code`: the close code.
        case closed
        /// The server closed with a policy code. `code`: the close code.
        case policy
        /// The server closed because the two sides share no API revision.
        case revision
        /// The phone has no network, or may not use it.
        case noInternet
        case cancelled
        /// The configured address isn't a server address.
        case badAddress
        /// A failure the app made itself.
        case local
        /// Anything else. `code`: the error's code.
        case other
    }

    public enum Scene: UInt8, Sendable {
        case inactive = 1
        case active
        case background
    }

    /// What the phone's network path looks like: four yes-or-no facts and nothing else.
    public struct Network: OptionSet, Sendable, Equatable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        /// The system has a usable path.
        public static let satisfied = Network(rawValue: 1)
        /// The path is cellular or a hotspot.
        public static let expensive = Network(rawValue: 2)
        /// Low Data Mode.
        public static let constrained = Network(rawValue: 4)
        /// An interface that is up holds an address in the tailnet's ranges.
        public static let tailnet = Network(rawValue: 8)

        public init(satisfied: Bool, expensive: Bool, constrained: Bool, tailnet: Bool) {
            var n: Network = []
            if satisfied { n.insert(.satisfied) }
            if expensive { n.insert(.expensive) }
            if constrained { n.insert(.constrained) }
            if tailnet { n.insert(.tailnet) }
            self = n
        }
    }

    /// Milliseconds since 1970. Set by the log.
    public var time: Int64 = 0
    /// The server's tag, 0 for an event of the app or the phone. Set by the log.
    public var server: UInt64 = 0
    public var kind: Kind
    public var cause: Cause = .none
    public var flags: UInt8 = 0
    /// The number behind `cause`: an HTTP status, a close code or an error code.
    public var code: Int32 = 0
    /// See `Kind`. For `closed`: the POSIX or TLS code under the error, 0 for none.
    public var value: Int64 = 0

    public init(kind: Kind) { self.kind = kind }

    // MARK: Making one

    public static func launch(build: Int64) -> ConnectionEvent {
        var e = ConnectionEvent(kind: .launch)
        e.value = build
        return e
    }

    public static func scene(_ scene: Scene) -> ConnectionEvent {
        var e = ConnectionEvent(kind: .scene)
        e.flags = scene.rawValue
        return e
    }

    public static func network(_ network: Network) -> ConnectionEvent {
        var e = ConnectionEvent(kind: .network)
        e.flags = network.rawValue
        return e
    }

    public static let connecting = ConnectionEvent(kind: .connecting)
    public static let stopped = ConnectionEvent(kind: .stopped)
    public static let dormant = ConnectionEvent(kind: .dormant)

    public static func breaker(open: Bool) -> ConnectionEvent {
        var e = ConnectionEvent(kind: .breaker)
        e.flags = open ? 1 : 0
        return e
    }

    public static func tunnelProbe(reachable: Bool, milliseconds: Int64) -> ConnectionEvent {
        var e = ConnectionEvent(kind: .probe)
        e.flags = reachable ? 1 : 0
        e.value = max(0, milliseconds)
        return e
    }

    public static func connecting(by trigger: AttemptTrigger) -> ConnectionEvent {
        var e = ConnectionEvent(kind: .connecting)
        e.flags = trigger.rawValue
        return e
    }

    public static func connected(afterMilliseconds ms: Int64) -> ConnectionEvent {
        var e = ConnectionEvent(kind: .connected)
        e.value = ms
        return e
    }

    /// The failure's kind and codes. Its message, its domain and the server's close reason are
    /// left behind: they may name the server.
    public static func closed(_ failure: ConnectionFailure) -> ConnectionEvent {
        var e = ConnectionEvent(kind: .closed)
        let c = Cause.of(failure)
        e.cause = c.cause
        e.code = Int32(clamping: c.code)
        e.value = Int64(c.under)
        return e
    }

    public static func retry(after seconds: Double) -> ConnectionEvent {
        var e = ConnectionEvent(kind: .retry)
        e.value = Int64((max(0, min(seconds, 86400)) * 1000).rounded())
        return e
    }

    // MARK: Bytes

    /// The size of an event in the file.
    public static let size = 32

    /// Little-endian: time (8), server (8), value (8), code (4), kind, cause, flags, and a check
    /// byte that is the XOR of the other 31 with `0xA5`.
    func encoded() -> [UInt8] {
        var b = [UInt8]()
        b.reserveCapacity(Self.size)
        Self.put(UInt64(bitPattern: time), into: &b)
        Self.put(server, into: &b)
        Self.put(UInt64(bitPattern: value), into: &b)
        let c = UInt32(bitPattern: code)
        for i in 0..<4 { b.append(UInt8(truncatingIfNeeded: c >> (8 * UInt32(i)))) }
        b.append(kind.rawValue)
        b.append(cause.rawValue)
        b.append(flags)
        b.append(Self.check(b))
        return b
    }

    /// Nil when the bytes are not an event: a wrong length, a wrong check byte, or a kind or
    /// cause this build doesn't know.
    init?(bytes: ArraySlice<UInt8>) {
        guard bytes.count == Self.size else { return nil }
        let at = bytes.startIndex
        guard bytes[at..<(at + 31)].reduce(0xA5, ^) == bytes[at + 31],
              let kind = Kind(rawValue: bytes[at + 28]), let cause = Cause(rawValue: bytes[at + 29]) else { return nil }
        self.kind = kind
        self.cause = cause
        time = Int64(bitPattern: Self.take(bytes, at))
        server = Self.take(bytes, at + 8)
        value = Int64(bitPattern: Self.take(bytes, at + 16))
        var c: UInt32 = 0
        for i in 0..<4 { c |= UInt32(bytes[at + 24 + i]) << (8 * UInt32(i)) }
        code = Int32(bitPattern: c)
        flags = bytes[at + 30]
    }

    init?(bytes: [UInt8]) { self.init(bytes: bytes[...]) }

    static func put(_ v: UInt64, into b: inout [UInt8]) {
        for i in 0..<8 { b.append(UInt8(truncatingIfNeeded: v >> (8 * UInt64(i)))) }
    }

    /// The little-endian number in the eight bytes from `at`.
    static func take(_ b: ArraySlice<UInt8>, _ at: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[at + i]) << (8 * UInt64(i)) }
        return v
    }

    private static func check(_ b: [UInt8]) -> UInt8 { b.reduce(0xA5, ^) }

    // MARK: Text

    /// The event without its time and server, for the exported file: words and numbers.
    public var summary: String {
        switch kind {
        case .launch: return "launch build=\(value)"
        case .scene:
            let name: String
            switch Scene(rawValue: flags) {
            case .inactive: name = "inactive"
            case .active: name = "active"
            case .background: name = "background"
            case nil: name = "\(flags)"
            }
            return "scene \(name)"
        case .network:
            let n = Network(rawValue: flags)
            func yn(_ f: Network) -> String { n.contains(f) ? "yes" : "no" }
            return "network satisfied=\(yn(.satisfied)) expensive=\(yn(.expensive)) constrained=\(yn(.constrained)) tailnet=\(yn(.tailnet))"
        case .connecting:
            guard let by = AttemptTrigger(rawValue: flags) else { return "connecting" }
            return "connecting by=\(by)"
        case .connected: return "connected after=\(value)ms"
        case .closed:
            var s = "closed \(cause)"
            if code != 0 { s += " code=\(code)" }
            if value != 0 { s += " under=\(value)" }
            return s
        case .retry: return "retry in=\(value)ms"
        case .stopped: return "stopped"
        case .dormant: return "dormant"
        case .breaker: return flags == 1 ? "breaker open" : "breaker closed"
        case .probe: return "probe tailscale reachable=\(flags == 1 ? "yes" : "no") after=\(value)ms"
        }
    }
}

extension ConnectionEvent.Cause {
    /// Sorts a failure by its codes alone. `code` is the number that says most (the HTTP status,
    /// the close code, else the error's code) and `under` the POSIX or TLS code beneath it.
    public static func of(_ f: ConnectionFailure) -> (cause: ConnectionEvent.Cause, code: Int, under: Int32) {
        let under = Int32(clamping: f.posixCode ?? f.streamCode ?? f.underlyingCode ?? 0)
        if f.isInvalidAddress { return (.badAddress, 0, 0) }
        if f.revisionRefusal != nil { return (.revision, f.closeCode ?? 0, under) }
        if let s = f.httpStatus { return ([401, 403, 407].contains(s) ? .auth : .http, s, under) }
        if let c = f.closeCode { return ([1008, 4001, 4003, 4401, 4403].contains(c) ? .policy : .closed, c, under) }
        let tls = (-9899 ... -9800).contains(f.streamCode ?? 0) || (-9899 ... -9800).contains(f.underlyingCode ?? 0)
        if f.domain == NSURLErrorDomain {
            switch f.code {
            case NSURLErrorTimedOut: return (.timeout, f.code, under)
            case NSURLErrorNetworkConnectionLost:
                return (f.posixCode == Int(ECONNRESET) ? .reset : .lost, f.code, under)
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return (.dns, f.code, under)
            case NSURLErrorNotConnectedToInternet, NSURLErrorInternationalRoamingOff,
                 NSURLErrorCallIsActive, NSURLErrorDataNotAllowed:
                return (.noInternet, f.code, under)
            case NSURLErrorCannotConnectToHost:
                switch f.posixCode.map(Int32.init(clamping:)) {
                case ECONNREFUSED: return (.refused, f.code, under)
                case ETIMEDOUT: return (.timeout, f.code, under)
                default: return (.unreachable, f.code, under)
                }
            case NSURLErrorUserAuthenticationRequired, NSURLErrorUserCancelledAuthentication,
                 NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
                return (.auth, f.code, under)
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorAppTransportSecurityRequiresSecureConnection:
                return (.tls, f.code, under)
            case NSURLErrorCancelled: return (.cancelled, f.code, under)
            default: break
            }
        }
        if tls { return (.tls, f.code, under) }
        if let p = f.posixCode {
            switch Int32(clamping: p) {
            case ECONNREFUSED: return (.refused, f.code, under)
            case ETIMEDOUT: return (.timeout, f.code, under)
            case ECONNRESET: return (.reset, f.code, under)
            case EPIPE, ENOTCONN, ECONNABORTED: return (.lost, f.code, under)
            case EHOSTUNREACH, ENETUNREACH: return (.unreachable, f.code, under)
            case ENETDOWN: return (.noInternet, f.code, under)
            default: break
            }
        }
        if f.domain == ConnectionFailure.rexDomain { return (.local, f.code, under) }
        return (.other, f.code, under)
    }
}
