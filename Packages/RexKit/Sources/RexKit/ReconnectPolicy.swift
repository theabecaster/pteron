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

    /// The wait before each attempt of an episode, in seconds, by the attempt's number; the last
    /// one repeats. The first is the wait after a connection dropped: an episode that begins
    /// with an attempt (`connect()`, the return to the foreground) has none before it, and its
    /// second attempt follows by the second wait.
    public var waits: [Double] = [1, 10, 120, 300]
    /// The first wait is anywhere from 0 to its length.
    public var fullJitterFirst = true
    /// Every other wait is shorter or longer by up to this share of itself.
    public var jitter: Double = 0.2
    /// From the third attempt of an episode on, no attempt starts sooner than this after the one
    /// before it STARTED: no wait is shorter, jitter or not, and nothing that asks for an attempt
    /// (the network, the return, the breaker letting a host go) brings one nearer. Only the user
    /// does (`userSpacing`).
    public var floor: Double = 120
    /// Attempts of an episode that the floor doesn't hold back: the first and the second.
    public var attemptsBeforeFloor = 2
    /// The user's taps give a host at most one attempt per this many seconds.
    public var userSpacing: Double = 10
    /// A connection that drops right after the app came back is made again at once, once.
    public var retriesAtOnceAfterWake = true
    /// A change of route while an attempt is under way gives that attempt a new socket, once:
    /// the one it has may be on a route that is gone, and would hold the host until its deadline.
    public var movesAttemptOnRouteChange = true

    // MARK: Dormant, stopped

    /// Failures in a row with no answer from the server's side after which a host is dormant.
    public var dormantAfter = 5
    /// A dormant host is tried once per this many seconds, in the foreground, within the budget.
    public var dormantInterval: Double = 600
    /// TLS failures in a row after which a host is stopped, if the tunnel otherwise works
    /// (another host is connected). Before that, and with no other host up, a TLS failure is
    /// tried again on the normal schedule: a tunnel that is half up fails the same way.
    public var tlsFinalAfter = 3

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
    /// one test host is tried on its schedule and the others are held. Only a failure that says
    /// something about the tunnel counts (`isTunnelEvidence`).
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

    // MARK: The network path

    /// A change of route counts once the path has been quiet for this long (`RouteWatch`).
    public var routeSettle: Double = 2

    // MARK: Background

    /// Whether anything is tried, pinged or waiting to be tried in the background.
    public var worksInBackground = false

    public init() {}

    /// The slowest link the app is built for, in bytes a second (64 kbit/s). One reply must
    /// arrive whole inside the watchdog's wait and the pong deadline together even at this
    /// rate, or a live host looks silent (`BlobChunks`).
    public var slowestRate: Double = 8 * 1024

    /// The values in use.
    public static let standard = ReconnectPolicy()

    // MARK: Decisions

    /// The wait before attempt number `step` (from 1) of an episode. `unit`: a number from 0 to
    /// 1 that places the wait within its jitter; 0.5 is the middle.
    public func delay(step: Int, unit: Double = 0.5) -> Double {
        let n = max(step, 1), u = min(max(unit, 0), 1)
        let plain = waits.isEmpty ? floor : waits[min(n, waits.count) - 1]
        if n == 1, fullJitterFirst { return plain * u }
        let jittered = plain * (1 + jitter * (2 * u - 1))
        return n > attemptsBeforeFloor ? max(floor, jittered) : max(0, jittered)
    }

    /// How long until the floor lets a host's next attempt start: 0 when it may start now.
    /// `attempts`: attempts made in this episode. `sinceLastAttempt`: seconds since the last one
    /// started, nil for none.
    public func untilFloor(attempts: Int, sinceLastAttempt: Double?) -> Double {
        guard attempts >= attemptsBeforeFloor, let since = sinceLastAttempt else { return 0 }
        // Under a millisecond is now: a wait that short would not move a clock.
        let left = floor - since
        return left > 0.001 ? left : 0
    }

    /// Whether a failure with no answer says something about the tunnel: the host was connected
    /// or was being tried for the first times in this episode. A host that was already backing
    /// off or dormant timing out once more says nothing new, so it never opens the breaker.
    /// `attempts`: attempts made in this episode, the failed one included; 0 for a connection
    /// that dropped.
    /// Whether a failure is TLS's.
    public func isTLS(_ f: ConnectionFailure) -> Bool { ConnectionEvent.Cause.of(f).cause == .tls }

    public func isTunnelEvidence(attempts: Int, dormant: Bool) -> Bool {
        !dormant && attempts <= attemptsBeforeFloor
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
        /// API revision, TLS time after time while other hosts answer. Retries stop; only the
        /// user asks again.
        case final
    }

    /// `tlsInARow`: TLS failures of this host right before this one. `tunnelWorks`: another host
    /// is connected.
    public func kind(of f: ConnectionFailure, tlsInARow: Int = 0, tunnelWorks: Bool = false) -> FailureKind {
        let cause = ConnectionEvent.Cause.of(f)
        switch cause.cause {
        case .tls: return tunnelWorks && tlsInARow + 1 >= tlsFinalAfter ? .final : .answered
        case .auth, .revision, .badAddress: return .final
        case .http: return (400...499).contains(cause.code) ? .final : .answered
        case .policy: return [4001, 4003, 4401, 4403].contains(cause.code) ? .final : .answered
        case .refused, .closed: return .answered
        default: return f.peerAnswered ? .answered : .silent
        }
    }

    public enum Kick: Equatable, Sendable {
        case ignore
        /// The user's attempt: now, outside the budget, the breaker and the floor, as soon as
        /// fewer than `maxInFlight` attempts are under way.
        case now
        /// One attempt now if the budget has room.
        case budgeted
        /// Not yet: set the wait to end in that many seconds, if none ends sooner.
        case after(Double)
        /// The attempt under way takes a new socket in place of the one it has. It stays the
        /// same attempt: what waits for its welcome goes on waiting.
        case move
    }

    /// What a request for an attempt gets on a host that is wanted and not connected.
    /// `attempts`: attempts made in this episode. `sinceLastAttempt`: seconds since the last one
    /// began, nil for none; `sinceLastUser` and `sinceLastNetwork`: the same for the last one the
    /// user and the network asked for. `dormantLeft`: what was left of a dormant host's wait when
    /// the app went to the background. `moved`: the attempt under way already took a new socket.
    public func kick(_ trigger: AttemptTrigger, connecting: Bool, dormant: Bool, stopped: Bool, held: Bool,
                     selected: Bool, suspended: Bool, pathSatisfied: Bool, attempts: Int,
                     sinceLastAttempt: Double?, sinceLastUser: Double? = nil,
                     sinceLastNetwork: Double? = nil, dormantLeft: Double? = nil, moved: Bool = false) -> Kick {
        if suspended, !worksInBackground { return .ignore }
        // One attempt per host at a time, whoever asks. A tap, the return and a host the breaker
        // let go leave it alone. A change of route moves it to a new socket, once, so a route
        // that keeps changing can neither keep a connect from ending nor open a socket per change.
        if connecting {
            return trigger == .network && movesAttemptOnRouteChange && pathSatisfied && !moved ? .move : .ignore
        }
        // The user is always let through: the breaker, the budget, the floor and the path
        // monitor don't stand in the way of a tap. Taps on one host are `userSpacing` apart.
        if trigger == .user {
            if let since = sinceLastUser, since < userSpacing { return .after(userSpacing - since) }
            return .now
        }
        if stopped || held || !pathSatisfied { return .ignore }
        // The floor: from the third attempt on, never nearer than `floor` to the start of the
        // one before. A network change keeps it from the first.
        let left = trigger == .network ? max(0, floor - (sinceLastAttempt ?? floor))
            : untilFloor(attempts: attempts, sinceLastAttempt: sinceLastAttempt)
        switch trigger {
        case .network:
            // A path that keeps changing brings a dormant host's turn forward once per
            // `dormantInterval`, so it is asked no more often than it would be anyway.
            if dormant, let since = sinceLastNetwork, since < dormantInterval { return .ignore }
            return left > 0 ? .ignore : .budgeted
        case .foreground:
            if dormant {
                // Dormant hosts are left alone at the return, except the selected one: coming
                // back to the app does not by itself send a packet to a host that is off. Their
                // wait goes on from where the background stopped it, so it counts time in the
                // foreground only: short visits add up to a turn, and no turn is nearer than
                // `dormantInterval` to the one before.
                guard selected else { return .after(dormantLeft ?? dormantInterval) }
            }
            return left > 0 ? .after(left) : .budgeted
        case .peer:
            // The breaker let this host go: its floor and the budget still hold.
            return left > 0 ? .after(left) : .budgeted
        default:
            return .ignore
        }
    }
}

/// The attempts that hosts which are down may make together within a moving window (the count
/// under way at once is the governor's, read from the hosts). Pure; `ReconnectGovernor` keeps one. Hosts are numbers the caller gives.
struct AttemptBudget: Equatable {
    /// Each counted attempt: its host and when it began, in seconds on the caller's clock.
    private(set) var began: [(host: Int, at: Double)] = []

    static func == (a: AttemptBudget, b: AttemptBudget) -> Bool {
        a.began.map(\.host) == b.began.map(\.host) && a.began.map(\.at) == b.began.map(\.at)
    }

    /// Nil: there is room, and the attempt is counted from `now`. Else the seconds until there is.
    mutating func take(_ host: Int, now: Double, policy: ReconnectPolicy) -> Double? {
        began.removeAll { now - $0.at >= policy.budgetWindow }
        if began.count >= policy.budgetAttempts, let oldest = began.first {
            return max(0.001, policy.budgetWindow - (now - oldest.at))
        }
        began.append((host, now))
        return nil
    }

    /// The host got its welcome: its attempts were not to a host that is down.
    mutating func forget(_ host: Int) {
        began.removeAll { $0.host == host }
    }
}

/// Whether the tunnel, and not the hosts, looks down: several hosts failing with no answer close
/// together. One host is tried while it is open, and the hosts take turns at being that one, so
/// a computer that is off can't keep the others held. Pure; `ReconnectGovernor` keeps one. Hosts
/// are numbers the caller gives.
struct TunnelBreaker: Equatable {
    private(set) var silent: [Int: Double] = [:]
    /// The one host that is tried while the breaker is open; nil while it is closed.
    private(set) var testHost: Int?
    /// The hosts that had their turn in this round.
    private(set) var tried: Set<Int> = []
    var isOpen: Bool { testHost != nil }

    /// A host failed with no answer, in a way that says something about the tunnel
    /// (`ReconnectPolicy.isTunnelEvidence`). `order`: the hosts that are down, the likeliest to
    /// answer first. True when this opened the breaker, with the first of them as the test host.
    /// `mayOpen`: no host is connected. With one that is, the tunnel works, whatever the others do.
    mutating func failedSilently(_ host: Int, now: Double, policy: ReconnectPolicy, mayOpen: Bool = true,
                                 order: () -> [Int]) -> Bool {
        silent = silent.filter { now - $0.value < policy.breakerWindow }
        silent[host] = now
        guard !isOpen, mayOpen, silent.count >= policy.breakerHosts, let test = order().first else { return false }
        testHost = test
        tried = []
        return true
    }

    /// Whether the host may be tried on its schedule.
    func allows(_ host: Int) -> Bool { testHost == nil || testHost == host }

    /// The tunnel works: a host got its welcome, or its side answered at all. True when that
    /// closed an open breaker.
    mutating func answered(_ host: Int) -> Bool {
        silent[host] = nil
        guard isOpen else { return false }
        testHost = nil
        tried = []
        silent = [:]
        return true
    }

    /// The test host can't be the one any more: it failed again with no answer, or it is gone.
    /// The next host in `order` that had no turn in this round takes its place; when all had
    /// one, a new round begins with the first. Returns the new test host: nil closes the breaker
    /// (no host is left to try).
    mutating func nextTurn(order: [Int]) -> Int? {
        guard let was = testHost else { return nil }
        tried.insert(was)
        if order.allSatisfy({ tried.contains($0) }) { tried = [] }
        testHost = order.first { !tried.contains($0) }
        if testHost == nil {
            tried = []
            silent = [:]
        }
        return testHost
    }

    /// The turn goes to `host` out of order (the selected one, at the return). False when the
    /// breaker is closed.
    mutating func give(_ host: Int) -> Bool {
        guard isOpen else { return false }
        testHost = host
        return true
    }

    /// A host is gone (removed or stopped by the app).
    mutating func forget(_ host: Int) {
        silent[host] = nil
        tried.remove(host)
    }
}
