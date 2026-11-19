import Foundation

/// What a "Jump to Waiting" link does next, decided from plain values: wait for the servers, open
/// the agent that has waited longest, or do nothing. `AppModel.openWaiting` feeds it the servers
/// and the clock and carries out the step; nothing here touches a server or the screen.
///
/// The link can arrive on a cold launch, before any server has said which agents wait, so the
/// decision can't be made at once as the waiting pill's is:
///
/// - **When to jump.** Once every server either knows its agents' states or shows a connection
///   problem. Once one server knows of a waiting agent, the others get `capAfterFirst` more and
///   then the jump goes without them.
/// - **When to stop waiting.** After `cap`, with no jump: the app is just open.
/// - **When to give up.** Only on the person's own move: the tab on screen is neither the one
///   that was there when the link arrived nor the one `autoSelect()` put there. A cold launch
///   landing on the last tab by itself is not the person's move, so it doesn't cancel the jump.
/// - **Which agent.** The one waiting longest; ties go by server order, then by block order.
///   Agents first seen after the link arrived all tie: after a cold launch their first-seen times
///   say only which server synced first.
struct OpenWaiting {
    /// The longest a link waits for the servers, in seconds.
    static let cap: TimeInterval = 10
    /// Once a waiting agent is known, how long the servers still syncing get.
    static let capAfterFirst: TimeInterval = 2

    /// One server, as the decision sees it.
    struct Server: Equatable {
        /// Its agents' states have been read and are current, so `waiting` is the whole truth.
        var known: Bool
        /// It shows a connection problem: nothing more comes from it soon.
        var problem: Bool
        /// Its waiting agents in block order. Ignored unless `known`.
        var waiting: [Waiter] = []
    }

    struct Waiter: Equatable {
        var block: String
        /// When this wait began, as far as the phone knows. Nil when it hasn't been noted yet.
        var since: Date?
    }

    /// The agent to open: its server's place in the list given to `step`, and its block.
    struct Target: Equatable {
        var server: Int
        var block: String
    }

    enum Step: Equatable {
        /// Ask again shortly.
        case wait
        case open(Target)
        /// The wait is over and nothing is opened. No notice, no haptic: the app is just open.
        case nothing(Why)
    }

    enum Why: Equatable {
        case noServers, noneWaiting, timedOut, personMoved
        /// A newer link took over (set by the caller, never by `step`).
        case replaced
    }

    /// When the link arrived, on the caller's monotonic clock.
    let began: TimeInterval
    /// When the link arrived, as a date: agents first seen later than this tie.
    let arrived: Date
    /// The tab on screen when the link arrived.
    let before: Selection?
    /// When a waiting agent was first known, on the caller's clock.
    private var firstKnown: TimeInterval?

    init(began: TimeInterval, arrived: Date, before: Selection?) {
        self.began = began
        self.arrived = arrived
        self.before = before
    }

    /// `servers` in the app's order; `selection` is the tab on screen now and `autoSelected` the
    /// one `AppModel.autoSelect()` put there since the link arrived, nil if it put none.
    mutating func step(servers: [Server], now: TimeInterval, selection: Selection?, autoSelected: Selection?) -> Step {
        if selection != before, selection != autoSelected { return .nothing(.personMoved) }
        if servers.isEmpty { return .nothing(.noServers) }
        let target = Self.oldest(servers, arrived: arrived)
        if servers.allSatisfy({ $0.known || $0.problem }) {
            return target.map(Step.open) ?? .nothing(.noneWaiting)
        }
        if let target {
            let first = firstKnown ?? now
            firstKnown = first
            if now - first >= Self.capAfterFirst { return .open(target) }
        }
        if now - began >= Self.cap { return .nothing(.timedOut) }
        return .wait
    }

    /// The agent waiting longest among the servers that know their agents.
    static func oldest(_ servers: [Server], arrived: Date) -> Target? {
        var best: (since: Date, target: Target)?
        // Server order, then block order: a later one replaces the best only when strictly older.
        for (i, server) in servers.enumerated() where server.known {
            for w in server.waiting {
                let since = min(w.since ?? arrived, arrived)
                if best == nil || since < best!.since { best = (since, Target(server: i, block: w.block)) }
            }
        }
        return best?.target
    }

    /// Time for the wait: a monotonic `now` in seconds and a sleep. Tests pass their own.
    struct Clock: Sendable {
        var now: @MainActor @Sendable () -> TimeInterval
        var sleep: @MainActor @Sendable (TimeInterval) async -> Void

        static let system = Clock(
            now: { ProcessInfo.processInfo.systemUptime },
            sleep: { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) })
    }
}
