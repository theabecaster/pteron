import Foundation

/// Whether the phone's way to its computers, and not the computers, looks down, and when the
/// app may say so. The tunnel breaker (`ReconnectGovernor`) is the signal; this type adds the
/// rules of saying it: every computer must be silent, at least two of them, the phone must have
/// a network, and it must have lasted a while with the app in front.
///
/// It is said only while the breaker is open. The breaker opens with no computer connected and
/// closes on any welcome or answer, so those ends are the breaker's; the checks here for a
/// computer that is up or has answered hold whatever the breaker does. It also closes when the
/// last computer that was still being tried goes dormant: from then on each computer is
/// away by itself, and its own problem is what the app says, not this.
///
/// Pure: the caller says how things stand and what time it is.
public struct TunnelSuspicion: Equatable, Sendable {
    /// How one wanted host looks now.
    public enum Host: Equatable, Sendable {
        /// Its connection is up.
        case up
        /// It is down and its last failure got no answer: a timeout, a lost connection, no
        /// route, a name that did not resolve.
        case unanswered
        /// It is down and its last failure was an answer: a refused port, an HTTP status, a
        /// close. The way to it works.
        case answered
        /// It says nothing about the way to it: retries are stopped (not allowed in, TLS, no
        /// common revision), or nothing has failed yet.
        case unknown
    }

    /// This many hosts must be silent.
    public static let hostsNeeded = 2
    /// The app says nothing until the suspicion has held this long with the app in front.
    public static let showAfter: Double = 10

    /// The tunnel is suspected: the breaker is open, the phone has a network, at least
    /// `hostsNeeded` hosts are silent and none shows that the way works (one that is up, or one
    /// that answered).
    public static func suspected(breakerOpen: Bool, pathSatisfied: Bool, hosts: [Host]) -> Bool {
        guard breakerOpen, pathSatisfied else { return false }
        guard !hosts.contains(.up), !hosts.contains(.answered) else { return false }
        return hosts.filter { $0 == .unanswered }.count >= hostsNeeded
    }

    /// Whether a host's own offline message gives way to the tunnel's while it shows. Only a
    /// host that is silent: one that refused, answered over HTTP, failed TLS or turned the
    /// phone away keeps what it says.
    public static func covers(_ host: Host) -> Bool { host == .unanswered }

    /// The app says it now.
    public private(set) var shows = false
    /// When the suspicion began to hold with the app in front.
    private var since: Double?

    public init() {}

    /// Call when anything that `suspected` reads may have changed, when the app comes to the
    /// front or leaves it, and when the wait this returned has passed. `now`: seconds on a clock
    /// that never jumps. Returns the seconds until `shows` can turn true, nil when nothing waits.
    ///
    /// It turns true only after `showAfter` seconds of unbroken suspicion in the foreground, and
    /// false at once when the suspicion ends or the app leaves the front; the count then starts
    /// over.
    public mutating func update(suspected: Bool, foreground: Bool, now: Double) -> Double? {
        guard suspected, foreground else {
            shows = false
            since = nil
            return nil
        }
        let began = since ?? now
        since = began
        let left = Self.showAfter - (now - began)
        guard left > 0 else {
            shows = true
            return nil
        }
        return left
    }
}
