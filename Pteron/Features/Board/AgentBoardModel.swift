import Foundation
import RexKit

/// One agent as the board shows it. Built from the same data as the sidebar's Agents mode.
struct BoardAgent: Equatable, Identifiable {
    var server: UUID
    var sessionID: String
    var windowID: String
    var blockID: String
    var kind: AgentKind?
    var name: String
    /// The raw state: `blocked`, `error`, `working`, `done`, anything else is idle.
    var state: String?
    /// The state in words, as the Agents mode says it.
    var stateText: String
    var progress: Int?
    var message: String?
    /// "session › tab".
    var place: String
    /// When it began to wait, as the app saw it. Only for a waiting agent.
    var waitingSince: Date?

    var id: String { "\(server.uuidString):\(blockID)" }
}

/// One machine and its agents, in the server's order.
struct BoardMachine: Equatable {
    enum Link: Equatable {
        /// Connected, with its sessions loaded: its agents' states are current.
        case live
        /// The connection is down. Its agents are the last known ones.
        case stale
        /// Not connected yet since launch: it has nothing to show.
        case never
    }

    var id: UUID
    var name: String
    var link: Link
    var agents: [BoardAgent]
}

/// What the agent board shows: one line that sums up the most urgent state, a line about the
/// machines, and a tile per agent that isn't idle. Pure, so it is tested.
///
/// Only connected machines count in the headline, the glow and the order's first part. A machine
/// whose connection is down keeps its last known tiles, marked stale and shown dimmed after the
/// live ones: a state that may be out of date is never shown as current. And while such tiles
/// show, the headline never says that all is quiet or done: it says "Reconnecting…".
struct AgentBoard: Equatable {
    enum Urgency: Equatable { case waiting, error, working, done, quiet, reconnecting, connecting, unpaired }

    struct Tile: Equatable, Identifiable {
        var agent: BoardAgent
        /// From a machine whose connection is down.
        var stale = false
        /// Set only when the tiles come from more than one machine.
        var machineName: String?
        var id: String { agent.id }
    }

    var headline: String
    var urgency: Urgency
    var subline: String
    /// Agents that aren't idle: waiting (the longest waiting first), error, working, done.
    var tiles: [Tile]
    var idleCount: Int
    /// The state the board's edges glow in. Nil when nobody waits, fails or works.
    var glow: Urgency?

    static func make(_ machines: [BoardMachine]) -> AgentBoard {
        guard !machines.isEmpty else {
            return AgentBoard(headline: "No computers yet", urgency: .unpaired, subline: "", tiles: [], idleCount: 0)
        }
        let live = machines.filter { $0.link == .live }
        let stale = machines.filter { $0.link == .stale }

        func tiles(_ group: [BoardMachine], stale: Bool) -> [Tile] {
            let all = group.flatMap { m in m.agents.map { Tile(agent: $0, stale: stale, machineName: m.name) } }
            let busy = all.filter { AgentOrder.rank($0.agent.state) < 4 }
            var since: [String: Date] = [:]
            for t in busy { since[t.id] = t.agent.waitingSince }
            return AgentOrder.sorted(busy, state: \.agent.state, id: \.id, since: since)
        }
        var shown = tiles(live, stale: false) + tiles(stale, stale: true)
        if Set(shown.map(\.agent.server)).count < 2 {
            for i in shown.indices { shown[i].machineName = nil }
        }

        let states = live.flatMap(\.agents).map { AgentOrder.rank($0.state) }
        func count(_ rank: Int) -> Int { states.filter { $0 == rank }.count }
        var headline: String
        var urgency: Urgency
        if live.isEmpty {
            (headline, urgency) = stale.isEmpty ? ("Connecting…", .connecting) : ("Reconnecting…", .reconnecting)
        } else if count(0) > 0 {
            (headline, urgency) = ("\(count(0)) waiting", .waiting)
        } else if count(1) > 0 {
            (headline, urgency) = (count(1) == 1 ? "1 error" : "\(count(1)) errors", .error)
        } else if count(2) > 0 {
            (headline, urgency) = ("\(count(2)) working", .working)
        } else if count(3) > 0 {
            (headline, urgency) = ("All done", .done)
        } else {
            (headline, urgency) = ("All quiet", .quiet)
        }
        // A machine that is down still has tiles on the board, last known. "All quiet" or
        // "All done" over a dimmed tile that needed you would be read as the whole truth.
        if urgency == .quiet || urgency == .done, shown.contains(where: \.stale) {
            (headline, urgency) = ("Reconnecting…", .reconnecting)
        }
        let idle = (live + stale).flatMap(\.agents).filter { AgentOrder.rank($0.state) == 4 }.count
        let glows = urgency == .waiting || urgency == .error || urgency == .working
        return AgentBoard(headline: headline, urgency: urgency, subline: subline(machines, reconnectingAbove: urgency == .reconnecting), tiles: shown,
                          idleCount: idle, glow: glows ? urgency : nil)
    }

    /// One machine: its name. Several: their names while all are connected and there are at most
    /// two, else how many are connected, and that the others are being reconnected. With none
    /// connected the headline says what the connection is doing, so this line only names them.
    /// Under a "Reconnecting…" headline it doesn't say it again.
    static func subline(_ machines: [BoardMachine], reconnectingAbove: Bool = false) -> String {
        let live = machines.filter { $0.link == .live }.count
        let anyStale = machines.contains { $0.link == .stale }
        if machines.count <= 2, live == machines.count || live == 0 {
            return machines.map(\.name).joined(separator: " · ")
        }
        if live == 0 { return Messages.computers(machines.count) }
        return "\(live) of \(machines.count) computers connected" + (anyStale && !reconnectingAbove ? " · Reconnecting…" : "")
    }

    /// How long an agent has waited, for its tile: "3m", "2h". Nil under a minute.
    static func elapsed(_ seconds: TimeInterval) -> String? {
        let minutes = Int(seconds / 60)
        guard minutes >= 1 else { return nil }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h" : "\(hours / 24)d"
    }
}

/// Keeps the board's tiles from jumping about when agents change state quickly: the order
/// changes at most once a second. Pure, with the time passed in.
///
/// A tile that comes or goes is shown at once and isn't a reorder. A real reorder inside the
/// second waits: the shown order stays (without tiles that left, new ones at the end) and
/// `retryAt` says when to ask again.
struct BoardOrderThrottle: Equatable {
    static let interval: TimeInterval = 1

    private var shown: [String] = []
    /// The newest order asked for, which `retry` applies.
    private var wanted: [String] = []
    private var lastReorder = Date.distantPast

    /// Call at `retryAt`: the newest order asked for, not the one that set the timer. Several
    /// changes inside one second share one `retryAt`.
    mutating func retry(now: Date) -> (ids: [String], retryAt: Date?) {
        order(desired: wanted, now: now)
    }

    mutating func order(desired: [String], now: Date) -> (ids: [String], retryAt: Date?) {
        wanted = desired
        let wanted = Set(desired), have = Set(shown)
        let kept = shown.filter { wanted.contains($0) }
        let reorders = kept != desired.filter { have.contains($0) }
        if !reorders {
            shown = desired
            return (desired, nil)
        }
        if now.timeIntervalSince(lastReorder) >= Self.interval {
            lastReorder = now
            shown = desired
            return (desired, nil)
        }
        shown = kept + desired.filter { !have.contains($0) }
        return (shown, lastReorder.addingTimeInterval(Self.interval))
    }
}
