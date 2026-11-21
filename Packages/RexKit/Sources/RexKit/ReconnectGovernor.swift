import Foundation

/// What the hosts' control connections share when they reconnect: the budget of attempts for
/// hosts that are down, the tunnel breaker, and which host is selected. One per app; every
/// `RexControl` of a saved server is given the same one, and asks it before each attempt.
/// A `RexControl` made without one gets its own, and is then alone in it.
///
/// It keeps no timer: a host that must wait is told how long, and a held host is told when to go.
@MainActor
public final class ReconnectGovernor {
    public let policy: ReconnectPolicy
    private var budget = AttemptBudget()
    private var breaker = TunnelBreaker()
    private var hosts: [Int: Weak] = [:]
    private var nextID = 0
    /// Hosts with an attempt under way.
    private var inFlight: Set<Int> = []
    /// The host the user looks at: first in every order.
    private var selected: Int?
    /// Called when the breaker opens or closes: true while the tunnel looks down.
    public var onBreaker: ((Bool) -> Void)?

    private struct Weak {
        weak var control: RexControl?
    }

    public init(policy: ReconnectPolicy = .standard) { self.policy = policy }

    /// The tunnel looks down: only the test host is tried.
    public var breakerOpen: Bool { breaker.isOpen }

    /// The user selected this host's server, or none.
    public func select(_ control: RexControl?) { selected = control?.governorID }

    func isSelected(_ id: Int) -> Bool { selected == id }

    /// The breaker is open and this host is not the one that is tried.
    func holds(_ id: Int) -> Bool { !breaker.allows(id) }

    func register(_ control: RexControl) -> Int {
        nextID += 1
        hosts[nextID] = Weak(control: control)
        return nextID
    }

    /// The host is gone or stopped by the app.
    func remove(_ id: Int) {
        inFlight.remove(id)
        let was = breaker.isOpen
        breaker.removed(id) { self.pickTest(except: id) }
        if was, !breaker.isOpen { release(after: id) }
    }

    enum Grant: Equatable {
        case go
        /// Not now: ask again in that many seconds.
        case wait(Double)
        /// The breaker holds this host until the test host connects.
        case held
    }

    /// Asked before an attempt on the schedule. `exempt`: the host's first attempt of an
    /// episode, which the budget doesn't count.
    func request(_ id: Int, exempt: Bool, now: Double) -> Grant {
        guard breaker.allows(id) else { return .held }
        if !exempt, let wait = budget.take(now: now, inFlight: inFlight.count, policy: policy) {
            // Those that wait go one after another: the selected host, then the last one good.
            return .wait(wait + Double(rank(id)) * policy.budgetSpacing)
        }
        inFlight.insert(id)
        return .go
    }

    /// An attempt the user asked for, or one the breaker let go: outside the budget.
    func began(_ id: Int) { inFlight.insert(id) }

    /// The attempt ended without a welcome. `silent`: with no answer from the server's side.
    func failed(_ id: Int, silent: Bool, now: Double) {
        inFlight.remove(id)
        guard silent else { return }
        if breaker.testHost == id {
            // The test host is still silent: the next host in order takes its turn.
            if let next = breaker.retest(pick: { self.pickTest(except: id) }) {
                hosts[id]?.control?.heldByBreaker()
                hosts[next]?.control?.becameTestHost()
            }
            return
        }
        let opened = breaker.failedSilently(id, now: now, policy: policy) { self.pickTest(except: nil) }
        guard opened else { return }
        onBreaker?(true)
        for (other, host) in hosts where other != breaker.testHost { host.control?.heldByBreaker() }
    }

    /// The host got its welcome.
    func welcomed(_ id: Int) {
        inFlight.remove(id)
        if breaker.welcomed(id) { release(after: id) }
    }

    /// The breaker closed: the held hosts go one at a time, in order.
    private func release(after id: Int) {
        onBreaker?(false)
        let held = hosts.compactMap { $0.value.control }.filter { $0.governorID != id && $0.isHeld }
            .sorted { rank($0.governorID) < rank($1.governorID) }
        for (i, control) in held.enumerated() {
            control.releasedByBreaker(after: Double(i + 1) * policy.breakerResumeSpacing)
        }
    }

    /// The test host: the selected one if it is down, else the one that was good last. A host
    /// that is dormant (off for a while already) is taken only when there is no other.
    private func pickTest(except: Int?) -> Int? {
        let down = hosts.compactMap { $0.value.control }.filter { $0.governorID != except && $0.wantsAttempts }
        let awake = down.filter { !$0.dormant }
        let from = awake.isEmpty ? down : awake
        if let s = from.first(where: { $0.governorID == selected }) { return s.governorID }
        return from.max { ($0.lastGood ?? .distantPast) < ($1.lastGood ?? .distantPast) }?.governorID
    }

    /// The host's place among those that are down: 0 for the selected one, then by last good.
    private func rank(_ id: Int) -> Int {
        let down = hosts.compactMap { $0.value.control }.filter { $0.wantsAttempts }
            .sorted { a, b in
                if (a.governorID == selected) != (b.governorID == selected) { return a.governorID == selected }
                return (a.lastGood ?? .distantPast) > (b.lastGood ?? .distantPast)
            }
        return down.firstIndex { $0.governorID == id } ?? 0
    }
}
