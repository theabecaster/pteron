import Foundation

/// Every number and rule of reconnecting, in one place. `RexControl` keeps one host's state and
/// `ReconnectGovernor` what the hosts share; both ask this type and decide nothing themselves, so
/// a change of strategy is a change here and in `ReconnectPolicyTests`.
///
/// The reason for the numbers: a phone's VPN keeps a packet for a computer that is off until its
/// handshake gives up, about 90 s, from one small pool shared by every computer, and each new
/// packet starts that time over. So a host that doesn't answer is asked at most every 2 minutes
/// after its second attempt, hosts that are down share a budget, and several hosts timing out
/// together are taken for the tunnel being down, not the hosts.
///
/// Pure values: no clock and no state. The caller says how things stand and gets a decision.
public struct ReconnectPolicy: Sendable, Equatable {
    // MARK: Schedule

    /// The wait before each next attempt, in seconds, by the number of waits taken in a row; the
    /// last one repeats.
    public var waits: [Double] = [1, 10, 120, 300]
    /// The first wait is anywhere from 0 to its length.
    public var fullJitterFirst = true
    /// Every other wait is shorter or longer by up to this share of itself.
    public var jitter: Double = 0.2
    /// No wait from the third on is shorter than this, jitter or not, and no trigger brings an
    /// attempt nearer than this to the one before it once a host has had two.
    public var floor: Double = 120
    /// Attempts of an episode that the floor doesn't hold back: the first and the second.
    public var attemptsBeforeFloor = 2
    /// A connection that drops right after the app came back is made again at once, once.
    public var retriesAtOnceAfterWake = true

    // MARK: Dormant, stopped

    /// Failures in a row with no answer from the server's side after which a host is dormant.
    public var dormantAfter = 5
    /// A dormant host is tried once per this many seconds, in the foreground, within the budget.
    public var dormantInterval: Double = 600

    // MARK: The budget hosts share

    /// At most `budgetAttempts` attempts per `budgetWindow` seconds across all hosts that are
    /// not up, and at most `maxInFlight` of them under way at once. A host's first attempt of an
    /// episode and an attempt the user asked for are outside it.
    public var budgetAttempts = 2
    public var budgetWindow: Double = 100
    public var maxInFlight = 2
    /// Hosts that wait for the budget go this many seconds apart, the selected one first.
    public var budgetSpacing: Double = 0.5

    // MARK: The tunnel breaker

    /// This many hosts failing with no answer within `breakerWindow` seconds open the breaker:
    /// one test host is tried on its schedule and the others are held.
    public var breakerHosts = 2
    public var breakerWindow: Double = 30
    /// After the test host's welcome the held hosts start one at a time, this far apart.
    public var breakerResumeSpacing: Double = 0.5

    // MARK: Deadlines

    /// How long an attempt waits for the welcome.
    public var connectDeadline: Double = 10
    public var connectDeadlineExpensive: Double = 15
    /// How long a ping waits for its pong before the connection counts as dead.
    public var pongDeadline: Double = 10
    public var pongDeadlineExpensive: Double = 20
    /// The pong wait of the ping sent when the app returns to the foreground.
    public var wakePongDeadline: Double = 2.5
    public var wakePongDeadlineExpensive: Double = 5
    /// A ping goes out when nothing came in for this long.
    public var idlePing: Double = 30
    /// A request with nothing at all coming back for this long sends a ping at once.
    public var activityTimeout: Double = 5
    public var activityTimeoutExpensive: Double = 10

    // MARK: Background

    /// Whether anything is tried, pinged or waiting to be tried in the background.
    public var worksInBackground = false

    public init() {}

    /// The values in use.
    public static let standard = ReconnectPolicy()

    // MARK: Decisions

    /// The wait number `step` (from 1). `unit`: a number from 0 to 1 that places the wait within
    /// its jitter; 0.5 is the middle.
    public func delay(step: Int, unit: Double = 0.5) -> Double {
        let n = max(step, 1), u = min(max(unit, 0), 1)
        let plain = waits.isEmpty ? floor : waits[min(n, waits.count) - 1]
        if n == 1, fullJitterFirst { return plain * u }
        let jittered = plain * (1 + jitter * (2 * u - 1))
        return n > attemptsBeforeFloor ? max(floor, jittered) : max(0, jittered)
    }

    public func connectDeadline(expensive: Bool) -> Double { expensive ? connectDeadlineExpensive : connectDeadline }
    public func pongDeadline(expensive: Bool) -> Double { expensive ? pongDeadlineExpensive : pongDeadline }
    public func wakePongDeadline(expensive: Bool) -> Double { expensive ? wakePongDeadlineExpensive : wakePongDeadline }
    public func activityTimeout(expensive: Bool) -> Double { expensive ? activityTimeoutExpensive : activityTimeout }

    public enum FailureKind: Equatable, Sendable {
        /// No answer from the server's side: a timeout, no route, a name that doesn't resolve, a
        /// connection that was lost. The kind that must not be repeated quickly, and the only
        /// one that counts toward dormant and toward the breaker.
        case silent
        /// The server's side answered and the next try may work: a refused port, a 5xx, an
        /// ordinary close. The normal schedule, and never dormant.
        case answered
        /// Trying again can't help until something is changed: not allowed, a 4xx, no common
        /// API revision, TLS. Retries stop; only the user asks again.
        case final
    }

    public func kind(of f: ConnectionFailure) -> FailureKind {
        let cause = ConnectionEvent.Cause.of(f)
        switch cause.cause {
        case .auth, .tls, .revision, .badAddress: return .final
        case .http: return (400...499).contains(cause.code) ? .final : .answered
        case .policy: return [4001, 4003, 4401, 4403].contains(cause.code) ? .final : .answered
        case .refused, .closed: return .answered
        default: return f.peerAnswered ? .answered : .silent
        }
    }

    public enum Kick: Equatable, Sendable {
        case ignore
        /// One attempt now, outside the budget.
        case now
        /// One attempt now if the budget has room.
        case budgeted
        /// Not yet: set the wait to end in that many seconds, if none ends sooner.
        case after(Double)
    }

    /// What a request for an attempt gets on a host that is wanted and not connected.
    /// `attempts`: attempts made in this episode. `sinceLastAttempt`: seconds since the last one
    /// began, nil for none.
    public func kick(_ trigger: AttemptTrigger, connecting: Bool, dormant: Bool, stopped: Bool, held: Bool,
                     selected: Bool, suspended: Bool, pathSatisfied: Bool, attempts: Int,
                     sinceLastAttempt: Double?) -> Kick {
        if suspended, !worksInBackground { return .ignore }
        // One attempt per host at a time, whoever asks.
        if connecting { return .ignore }
        // The user is always let through: the breaker, the budget, the floor and the path
        // monitor don't stand in the way of a tap.
        if trigger == .user { return .now }
        // The breaker let this host go.
        if trigger == .peer { return stopped ? .ignore : .now }
        if stopped || held || !pathSatisfied { return .ignore }
        // The floor: from the third attempt on, never nearer than `floor` to the one before. A
        // network change keeps it from the first.
        let floored = trigger == .network || attempts >= attemptsBeforeFloor
        let left = floored ? max(0, floor - (sinceLastAttempt ?? floor)) : 0
        switch trigger {
        case .network:
            return left > 0 ? .ignore : .budgeted
        case .foreground:
            if dormant {
                // Dormant hosts are left alone at the return, except the selected one: their
                // turn stays where it was, and is never nearer than the floor to the return, so
                // coming back to the app does not by itself send a packet to a host that is off.
                guard selected else { return .after(max(floor, dormantInterval - (sinceLastAttempt ?? dormantInterval))) }
            }
            return left > 0 ? .after(left) : .budgeted
        default:
            return .ignore
        }
    }
}

/// The attempts that hosts which are down may make together: a count within a moving window and
/// a count under way. Pure; `ReconnectGovernor` keeps one.
struct AttemptBudget: Equatable {
    /// When each counted attempt began, in seconds on the caller's clock.
    private(set) var began: [Double] = []

    /// Nil: there is room, and the attempt is counted from `now`. Else the seconds until there is.
    mutating func take(now: Double, inFlight: Int, policy: ReconnectPolicy) -> Double? {
        began.removeAll { now - $0 >= policy.budgetWindow }
        if began.count >= policy.budgetAttempts, let oldest = began.first {
            return max(0.001, policy.budgetWindow - (now - oldest))
        }
        // Full only until one of those under way ends, which is at most a deadline away.
        if inFlight >= policy.maxInFlight { return policy.budgetSpacing }
        began.append(now)
        return nil
    }
}

/// Whether the tunnel, and not the hosts, looks down: several hosts failing with no answer close
/// together. Pure; `ReconnectGovernor` keeps one. Hosts are numbers the caller gives.
struct TunnelBreaker: Equatable {
    private(set) var silent: [Int: Double] = [:]
    /// The one host that is tried while the breaker is open; nil while it is closed.
    private(set) var testHost: Int?
    var isOpen: Bool { testHost != nil }

    /// A host failed with no answer. `pick` chooses the test host among those that are down,
    /// when this opens the breaker. True when it opened now.
    mutating func failedSilently(_ host: Int, now: Double, policy: ReconnectPolicy, pick: () -> Int?) -> Bool {
        silent = silent.filter { now - $0.value < policy.breakerWindow }
        silent[host] = now
        guard !isOpen, silent.count >= policy.breakerHosts, let test = pick() else { return false }
        testHost = test
        return true
    }

    /// Whether the host may be tried on its schedule.
    func allows(_ host: Int) -> Bool { testHost == nil || testHost == host }

    /// A host got its welcome: the tunnel works. True when that closed an open breaker.
    mutating func welcomed(_ host: Int) -> Bool {
        silent[host] = nil
        guard isOpen else { return false }
        testHost = nil
        silent = [:]
        return true
    }

    /// The test host failed again: another host takes its place, if `pick` names one, so a
    /// computer that is really off can't keep the others held for good. Returns the new one.
    mutating func retest(pick: () -> Int?) -> Int? {
        guard isOpen, let next = pick() else { return nil }
        testHost = next
        return next
    }

    /// A host is gone (removed or stopped). If it was the test host, `pick` names another.
    mutating func removed(_ host: Int, pick: () -> Int?) {
        silent[host] = nil
        if testHost == host { testHost = pick() }
    }
}
