import Foundation

/// What a dropped connection shows around a trip to the background. iOS suspends the app and its
/// sockets die, so coming back almost always finds the connection down for a moment while it is
/// made again. That moment is the app waking up, not a problem: the tab stays as it was, the
/// title bar's Glide breathes if it takes more than a second, and no offline screen shows.
///
/// - `enteredBackground` while online: from then on a drop is held, not shown.
/// - `enteredForeground`: drops stay held for `grace` more.
/// - A drop that comes with a clear answer ends the hold at once: no network on the phone, or a
///   decisive kind (not allowed, insecure, bad address), or the server refused the connection
///   (`answered`). Those are real, and the offline screen says so.
/// - `connected` ends it. So does `expire` once `grace` has passed, and the problem held last shows.
///
/// Times are seconds on any monotonic clock the caller picks.
struct ForegroundWake: Equatable {
    enum State: Equatable {
        /// Drops show as they always do.
        case awake
        /// In the background: drops are held until the app is back.
        case background
        /// Back in the foreground: drops are held until this time.
        case waking(until: TimeInterval)
    }

    enum Verdict: Equatable { case hold, show }

    /// How long after the return a drop stays held. The control connection's ping takes up to 2.5 s
    /// to call a half-open socket dead (`RexControl.wakeTimeout`), and a new one takes about a second
    /// over Tailscale, whose own tunnel is waking up too.
    static let grace: TimeInterval = 5
    /// The same on cellular or a hotspot, where that ping has 5 s and a new connection takes
    /// longer: with 5 s the hold ended while the check it waits for was still out.
    static let graceExpensive: TimeInterval = 8

    /// The hold for the path the phone is on.
    static func grace(expensive: Bool) -> TimeInterval { expensive ? graceExpensive : grace }

    private(set) var state = State.awake

    /// Whether a drop is held now.
    var holds: Bool { state != .awake }

    /// The app went to the background. Only a server that was online gets the hold: one already
    /// offline keeps its offline screen.
    mutating func enteredBackground(online: Bool) {
        if online { state = .background }
    }

    /// The app is back. Returns true when a hold began, so the caller starts its timer.
    /// `expensive`: the path is cellular or a hotspot now. The hold's length is set here, once;
    /// a change of path during it leaves it alone.
    mutating func enteredForeground(now: TimeInterval, expensive: Bool = false) -> Bool {
        guard state == .background else { return false }
        state = .waking(until: now + Self.grace(expensive: expensive))
        return true
    }

    /// The deadline, while waking.
    var deadline: TimeInterval? {
        if case .waking(let until) = state { return until }
        return nil
    }

    mutating func connected() {
        // Connecting again while still in the background (before suspension) keeps the hold for
        // the next drop.
        if case .waking = state { state = .awake }
    }

    /// A connection attempt failed or the connection dropped: hold it or show it.
    mutating func failure(_ kind: ConnectionProblem.Kind, answered: Bool, network: NetworkSnapshot,
                          now: TimeInterval) -> Verdict {
        switch state {
        case .awake:
            return .show
        case .background:
            // Nobody sees it; the return decides.
            return .hold
        case .waking(let until):
            if now >= until || Self.isClear(kind, answered: answered, network: network) {
                state = .awake
                return .show
            }
            return .hold
        }
    }

    /// The phone's network changed. Returns true when a hold must end now: there is no network,
    /// so waiting can't help.
    mutating func networkChanged(_ network: NetworkSnapshot) -> Bool {
        guard case .waking = state, !network.reachable else { return false }
        state = .awake
        return true
    }

    /// The timer fired. Returns true when the hold ended, so what is held shows.
    mutating func expire(now: TimeInterval) -> Bool {
        guard case .waking(let until) = state, now >= until else { return false }
        state = .awake
        return true
    }

    /// A failure that waiting won't fix.
    static func isClear(_ kind: ConnectionProblem.Kind, answered: Bool, network: NetworkSnapshot) -> Bool {
        !network.reachable || kind.isDecisive || answered
    }
}
