import Foundation

/// One place or command picked from the palette, remembered for its ranking and the Recent list.
struct GoToRecent: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case session, tab, pane, command }

    var kind: Kind
    var serverID: UUID?
    var sessionID: String?
    var windowID: String?
    var blockID: String?
    /// A command's key (`GoToItemID.command`).
    var action: String?
    var uses: Int
    var lastUsed: Date

    /// The item this entry stands for.
    var itemID: GoToItemID? {
        switch kind {
        case .session:
            guard let serverID, let sessionID else { return nil }
            return .session(serverID, sessionID)
        case .tab:
            guard let serverID, let sessionID, let windowID else { return nil }
            return .tab(serverID, sessionID, windowID)
        case .pane:
            guard let serverID, let sessionID, let windowID, let blockID else { return nil }
            return .pane(serverID, sessionID, windowID, blockID)
        case .command:
            return action.map { .command($0) }
        }
    }

    init?(_ id: GoToItemID, uses: Int = 1, at date: Date) {
        self.uses = uses
        lastUsed = date
        switch id {
        case .session(let s, let sid):
            kind = .session; serverID = s; sessionID = sid
        case .tab(let s, let sid, let wid):
            kind = .tab; serverID = s; sessionID = sid; windowID = wid
        case .pane(let s, let sid, let wid, let bid):
            kind = .pane; serverID = s; sessionID = sid; windowID = wid; blockID = bid
        case .command(let key):
            kind = .command; action = key
        case .other:
            return nil
        }
    }
}

/// The palette's memory: at most 50 entries, newest first. Pure, so it is tested; `Prefs`
/// keeps it (`goToRecents`), as saved state, not a setting.
enum GoToRecents {
    static let limit = 50
    /// A pick's weight halves every three days.
    static let halfLife: TimeInterval = 3 * 86_400

    /// `list` with `id` picked at `date`: its uses counted, moved to the front.
    static func record(_ id: GoToItemID, at date: Date, in list: [GoToRecent]) -> [GoToRecent] {
        var out = list
        var uses = 1
        if let i = out.firstIndex(where: { $0.itemID == id }) {
            uses = out[i].uses + 1
            out.remove(at: i)
        }
        guard let entry = GoToRecent(id, uses: uses, at: date) else { return list }
        out.insert(entry, at: 0)
        if out.count > limit { out.removeLast(out.count - limit) }
        return out
    }

    static func remove(_ id: GoToItemID, from list: [GoToRecent]) -> [GoToRecent] {
        list.filter { $0.itemID != id }
    }

    /// Drops the places a server no longer has. Only servers in `synced` (online, synced) are
    /// pruned: a server that is down keeps its entries for when it is back. Commands stay.
    static func prune(_ list: [GoToRecent], synced: Set<UUID>, present: Set<GoToItemID>) -> [GoToRecent] {
        list.filter { e in
            guard e.kind != .command, let server = e.serverID, synced.contains(server) else { return true }
            return e.itemID.map(present.contains) ?? false
        }
    }

    /// `log2(1 + uses) × 0.5^(age / 3 days)`.
    static func frecency(_ e: GoToRecent, now: Date) -> Double {
        let age = max(now.timeIntervalSince(e.lastUsed), 0)
        return log2(1 + Double(e.uses)) * pow(0.5, age / halfLife)
    }

    /// Each item's ranking boost, up to +30%.
    static func boosts(_ list: [GoToRecent], now: Date) -> [GoToItemID: Double] {
        var out: [GoToItemID: Double] = [:]
        for e in list {
            guard let id = e.itemID else { continue }
            out[id] = min(0.3, 0.1 * frecency(e, now: now))
        }
        return out
    }
}
