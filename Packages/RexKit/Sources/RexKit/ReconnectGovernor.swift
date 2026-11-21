import Foundation

/// What the hosts' control connections share when they reconnect: the budget of attempts for
/// hosts that are down, the tunnel breaker, and which host is selected. One per app; every
/// `RexControl` of a saved server is given the same one, and asks it before each attempt.
/// A `RexControl` made without one gets its own, and is then alone in it.
///
/// It keeps no timer: a host that must wait is told how long, and a held host is told when to go.
///
/// The tunnel breaker's states and what moves it (each line is a test in
/// `ReconnectGovernorTests`):
///
/// | State  | What happens                                             | Then                          |
/// |--------|----------------------------------------------------------|-------------------------------|
/// | closed | 2 hosts or more fail with no answer within 30 s, each    | open; the first host in order |
/// |        | one connected until then or on its first two attempts,   | is the test host, the others  |
/// |        | AND no host is connected                                 | are held                      |
/// | closed | a host that was backing off or dormant times out again   | closed (no news)              |
/// | closed | hosts fail while another host is connected               | closed (the tunnel works)     |
/// | open   | any host gets its welcome                                | closed; the held hosts go     |
/// |        |                                                          | 0.5 s apart, each when its    |
/// |        |                                                          | floor and the budget allow    |
/// | open   | any host's side answers (refused, 401, another HTTP      | closed, the same way          |
/// |        | status, a close code, a TLS failure)                     |                               |
/// | open   | the test host fails again with no answer                 | open; the next host in order  |
/// |        |                                                          | has the turn, on its own      |
/// |        |                                                          | schedule, floor and budget    |
/// | open   | the test host is removed, or its retries stop            | open; the next host has the   |
/// |        |                                                          | turn (closed if none is left) |
/// | open   | a held host is removed                                   | open                          |
/// | open   | the user taps a held host                                | open; that host is tried once |
/// |        |                                                          | and held again if it fails    |
/// | open   | the app returns and the selected host is held            | open; it has the turn         |
/// | open   | the route changes                                        | open; the test host's attempt |
/// |        |                                                          | comes forward if its floor    |
/// |        |                                                          | allows, the held stay held    |
/// | open   | `connect()` of a host that is new                        | open; it is held              |
///
/// The order of the turns: the host that was connected last; if that one is dormant, the
/// selected one; then the others by their last welcome. Dormant hosts take turns only when no
/// other host is down, a whole dormant interval apart. A dead host therefore never keeps healthy
/// ones held: its turn ends with its attempt.
@MainActor
public final class ReconnectGovernor {
    public let policy: ReconnectPolicy
    private var budget = AttemptBudget()
    private var breaker = TunnelBreaker()
    private var hosts: [Int: Weak] = [:]
    private var nextID = 0
    /// Hosts that were refused only because `maxInFlight` attempts were under way: each is told
    /// when one of those ends (`RexControl.slotFreed`), so none of them keeps a timer to ask again.
    private var queued: Set<Int> = []
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
        queued.remove(id)
        breaker.forget(id)
        if breaker.testHost == id { passTurn(from: id) }
        wakeQueued()
    }

    /// The host's retries stopped (a failure that trying again can't fix): it takes no turn.
    func stopped(_ id: Int) {
        if breaker.testHost == id { passTurn(from: id) }
    }

    enum Grant: Equatable {
        case go
        /// Not now: ask again in that many seconds.
        case wait(Double)
        /// The breaker holds this host until its turn, or until a host answers.
        case held
        /// Not now, and no need to ask again on a timer: `maxInFlight` attempts are under way,
        /// and the host is told when one of them ends (`RexControl.slotFreed`).
        case queued
    }

    /// Attempts under way on hosts other than `id`: read from the hosts themselves, so nothing
    /// that was granted and forgotten can keep a slot.
    private func underWay(besides id: Int) -> Int {
        hosts.filter { $0.key != id && $0.value.control?.isAttempting == true }.count
    }

    /// An attempt ended: the hosts that waited for room ask again, the selected one first.
    private func wakeQueued() {
        guard !queued.isEmpty else { return }
        let waiting = queued.sorted { rank($0) < rank($1) }
        queued = []
        for id in waiting { hosts[id]?.control?.slotFreed() }
    }

    /// Asked before an attempt on the schedule, `connect()`'s included. `exempt`: the host's
    /// first attempt of an episode, which the budget doesn't count.
    func request(_ id: Int, exempt: Bool, now: Double) -> Grant {
        // A test host that went away without a word must not keep the others held.
        if let test = breaker.testHost, hosts[test]?.control == nil { passTurn(from: test) }
        guard breaker.allows(id) else { return .held }
        if !exempt {
            // Room among the attempts under way first: a host that waits for that is told when
            // there is some, and takes nothing from the window meanwhile.
            if underWay(besides: id) >= policy.maxInFlight {
                queued.insert(id)
                return .queued
            }
            if let wait = budget.take(id, now: now, policy: policy) {
                // Those that wait go one after another: the selected host, then the last one good.
                return .wait(wait + Double(rank(id)) * policy.budgetSpacing)
            }
        }
        return .go
    }

    /// Asked before an attempt the user asked for: outside the budget and the breaker, but
    /// never more than `maxInFlight` attempts under way at once. The count is of the hosts that
    /// are connecting now, not of what was granted, so nothing forgotten can block a tap.
    func requestTap(_ id: Int) -> Grant {
        if underWay(besides: id) >= policy.maxInFlight {
            queued.insert(id)
            return .queued
        }
        return .go
    }

    /// What a failed attempt, or a connection that dropped, says about the tunnel.
    enum Outcome: Equatable {
        /// Nothing came back. `evidence`: that is news (`ReconnectPolicy.isTunnelEvidence`), not
        /// a host that was already away timing out again.
        case silent(evidence: Bool)
        /// The server's side answered, whatever it said: the tunnel works.
        case answered
        /// Nothing can be told: the phone had no network, or the app gave the attempt up.
        case unknown
    }

    /// The attempt ended without a welcome, or the connection dropped.
    func failed(_ id: Int, _ outcome: Outcome, now: Double) {
        defer { wakeQueued() }
        switch outcome {
        case .unknown:
            return
        case .answered:
            if breaker.answered(id) { release(after: id) }
        case .silent(let evidence):
            if breaker.testHost == id {
                // The test host is still silent: the next host in order takes the turn.
                passTurn(from: id)
                return
            }
            guard evidence, !breaker.isOpen else { return }
            // Never while a host is connected: that one shows the tunnel works.
            let anyUp = hosts.contains { $0.value.control?.state == .connected }
            guard breaker.failedSilently(id, now: now, policy: policy, mayOpen: !anyUp, order: { self.order() }) else { return }
            onBreaker?(true)
            for (other, host) in hosts where other != breaker.testHost { host.control?.heldByBreaker() }
        }
    }

    /// The host got its welcome. Its attempts were not to a host that is down: the budget gets
    /// them back, so the hosts that follow it don't wait for them.
    func welcomed(_ id: Int) {
        defer { wakeQueued() }
        budget.forget(id)
        if breaker.answered(id) { release(after: id) }
    }

    /// Whether a host other than `id` is connected: the tunnel works.
    func tunnelWorks(besides id: Int) -> Bool {
        hosts.contains { $0.key != id && $0.value.control?.state == .connected }
    }

    /// The selected host is the one the user came back to: if the breaker holds it, it takes
    /// the turn. Nothing is tried by this; its schedule and the policy decide when.
    func giveTurnToSelected(_ id: Int) {
        guard selected == id, let was = breaker.testHost, was != id, breaker.give(id) else { return }
        hosts[was]?.control?.heldByBreaker()
        hosts[id]?.control?.becameTestHost()
    }

    /// The host a pull to refresh tries: one, not every host that is down. The selected one if
    /// it is down, else the breaker's test host, else the likeliest to answer.
    public func refreshTarget() -> RexControl? {
        if let s = selected, let c = hosts[s]?.control, c.wantsAttempts { return c }
        if let t = breaker.testHost, let c = hosts[t]?.control { return c }
        return order().first.flatMap { hosts[$0]?.control }
    }

    /// The test host can't be the one any more: the next in order takes the turn. With no host
    /// left to try, the breaker closes.
    private func passTurn(from id: Int) {
        guard breaker.isOpen else { return }
        guard let next = breaker.nextTurn(order: order()) else {
            release(after: nil)
            return
        }
        guard next != id else { return }
        hosts[id]?.control?.heldByBreaker()
        hosts[next]?.control?.becameTestHost()
    }

    /// The breaker closed: the held hosts go one at a time, in order.
    private func release(after id: Int?) {
        onBreaker?(false)
        let held = hosts.compactMap { $0.value.control }.filter { $0.governorID != id && $0.isHeld }
            .sorted { rank($0.governorID) < rank($1.governorID) }
        for (i, control) in held.enumerated() {
            control.releasedByBreaker(after: Double(i + 1) * policy.breakerResumeSpacing)
        }
    }

    /// The hosts that are down, in the order they take the turn: the likeliest to answer first.
    /// The one that was connected last; if that one is dormant, the selected one; then the rest
    /// by their last welcome. Dormant hosts (off for a while already) take turns only when no
    /// other host is down: one of them holding the turn for its ten minutes would keep the
    /// others held.
    private func order() -> [Int] {
        let down = hosts.compactMap { $0.value.control }.filter { $0.wantsAttempts }
        let awake = down.filter { !$0.dormant }
        func recent(_ a: RexControl, _ b: RexControl) -> Bool {
            let x = a.lastGood ?? .distantPast, y = b.lastGood ?? .distantPast
            if x != y { return x > y }
            if (a.governorID == selected) != (b.governorID == selected) { return a.governorID == selected }
            return a.governorID < b.governorID
        }
        var list = (awake.isEmpty ? down : awake).sorted(by: recent)
        if let last = down.sorted(by: recent).first, last.dormant,
           let i = list.firstIndex(where: { $0.governorID == selected }) {
            list.insert(list.remove(at: i), at: 0)
        }
        return list.map(\.governorID)
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
