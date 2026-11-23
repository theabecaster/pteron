import Foundation

/// When each computer's connection starts at launch. The computer whose tab the launch opens
/// goes first, at once and alone, so its welcome, its sync and its pane's stream don't share the
/// tunnel with every other computer's. The others start when it has settled (its first sync is
/// done, or its connection failed or went dormant) and at the latest a second after it, one at
/// a time.
///
/// With no tab to open (a first launch, or the computer viewed last is gone) nobody is waited
/// for: every computer starts at once, as before.
enum StartStagger {
    /// The longest the others wait for the first one.
    static let lead: Double = 1
    /// The pause between the others, placed anywhere in this range for each.
    static let gap: ClosedRange<Double> = 0.25...0.5

    struct Plan: Equatable {
        /// Started at once, in this order.
        var now: [UUID]
        /// Started once the first has settled, in this order.
        var later: [Turn]
    }

    struct Turn: Equatable {
        var id: UUID
        /// Seconds after the one before it; 0 for the first of them.
        var pause: Double
    }

    /// `servers`: as Settings lists them. `first`: the computer of the tab the launch opens.
    /// `unit`: a number from 0 to 1 for each pause.
    static func plan(servers: [UUID], first: UUID?, unit: () -> Double) -> Plan {
        guard let first, servers.contains(first), servers.count > 1 else { return Plan(now: servers, later: []) }
        var later: [Turn] = []
        for id in servers where id != first {
            let pause = gap.lowerBound + (gap.upperBound - gap.lowerBound) * min(max(unit(), 0), 1)
            later.append(Turn(id: id, pause: later.isEmpty ? 0 : pause))
        }
        return Plan(now: [first], later: later)
    }

    /// Whether the first computer has settled, so the others need not wait for it any more:
    /// its first sync is done, its connection failed, or it went dormant.
    static func settled(synced: Bool, failed: Bool, dormant: Bool) -> Bool { synced || failed || dormant }
}
