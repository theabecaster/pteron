import SwiftUI

/// The sidebar's rows in Sessions mode, flattened: each machine, then (unless folded) its sessions,
/// then (unless folded) each session's tabs. Pure, so it is tested; the view looks the ids up.
///
/// Every row's id stays the same for the life of its item, so `List` turns a fold into removals and
/// a reopen into inserts, and animates only those rows.
enum SidebarOutline {
    struct Machine: Equatable {
        var id: UUID
        var sessions: [Session]
        /// Connected and synced with no sessions: a "No sessions" row shows under it.
        var empty = false
    }

    struct Session: Equatable {
        var id: String
        var windowIDs: [String]
    }

    struct Row: Identifiable, Equatable {
        enum Kind: Equatable {
            case machine(UUID)
            case session(UUID, String)
            case tab(UUID, session: String, window: String)
            /// A machine's "No sessions" row.
            case empty(UUID)
        }
        var kind: Kind
        /// The first machine: no divider above it.
        var first = false
        /// The session's last tab: its guide line stops short.
        var last = false

        var id: String {
            switch kind {
            case .machine(let m): "m:\(m.uuidString)"
            case .session(let m, let s): "s:\(m.uuidString):\(s)"
            case .tab(let m, _, let w): "t:\(m.uuidString):\(w)"
            case .empty(let m): "e:\(m.uuidString)"
            }
        }
    }

    static func rows(_ machines: [Machine], collapsed: Set<String>) -> [Row] {
        var out: [Row] = []
        for (i, m) in machines.enumerated() {
            out.append(Row(kind: .machine(m.id), first: i == 0))
            guard !collapsed.contains(SidebarCollapse.machine(m.id)) else { continue }
            if m.empty, m.sessions.isEmpty { out.append(Row(kind: .empty(m.id))) }
            for s in m.sessions {
                out.append(Row(kind: .session(m.id, s.id)))
                guard !collapsed.contains(SidebarCollapse.session(m.id, s.id)) else { continue }
                for (j, w) in s.windowIDs.enumerated() {
                    out.append(Row(kind: .tab(m.id, session: s.id, window: w), last: j == s.windowIDs.count - 1))
                }
            }
        }
        return out
    }
}

/// Which sidebar groups are folded, saved in `Prefs.sidebarCollapsed`. Everything starts open, so
/// only folded groups are stored.
enum SidebarCollapse {
    static func machine(_ id: UUID) -> String { "m:\(id.uuidString)" }
    static func session(_ server: UUID, _ session: String) -> String { "s:\(server.uuidString):\(session)" }

    /// Folds `key` if it is open, opens it if it is folded.
    static func toggled(_ keys: Set<String>, _ key: String) -> Set<String> {
        keys.contains(key) ? keys.subtracting([key]) : keys.union([key])
    }

    /// The keys with the selected tab's session and machine open, so the tab on screen always has a
    /// row in the sidebar (after a tap, Jump to Waiting, a push, a toast or a new session).
    static func revealing(_ keys: Set<String>, _ selection: Selection) -> Set<String> {
        keys.subtracting([machine(selection.serverID), session(selection.serverID, selection.sessionID)])
    }

    /// Every fold slides, however many rows it moves. A big fold costs one long frame either way:
    /// the list lays out the new rows' cells in the update itself (measured with
    /// `-sidebarFoldBench`), and switching at once only loses the slide.
    static let animation = Animation.snappy(duration: 0.25)

    /// The saved keys without those of removed servers, and of sessions that a connected, synced
    /// server no longer has. `live` holds only such servers: a down server keeps its keys, since its
    /// last known sessions stay listed.
    static func pruned(_ keys: Set<String>, servers: [UUID], live: [UUID: [String]]) -> Set<String> {
        let known = Set(servers.map(\.uuidString))
        let liveKeys = Set(live.flatMap { id, sessions in sessions.map { session(id, $0) } })
        return keys.filter { key in
            let parts = key.split(separator: ":", maxSplits: 2).map(String.init)
            guard parts.count >= 2, known.contains(parts[1]) else { return false }
            if parts[0] == "s", let id = UUID(uuidString: parts[1]), live[id] != nil {
                return liveKeys.contains(key)
            }
            return true
        }
    }
}

/// The Agents mode's order inside a machine: waiting (the longest waiting first), then error,
/// working, done and idle. Agents in the same state keep the server's order.
enum AgentOrder {
    static func rank(_ state: String?) -> Int {
        switch state {
        case "blocked": 0
        case "error": 1
        case "working": 2
        case "done": 3
        default: 4
        }
    }

    /// `since` is when each waiting agent started waiting, by block id.
    static func sorted<Row>(_ rows: [Row], state: (Row) -> String?, id: (Row) -> String,
                            since: [String: Date]) -> [Row] {
        rows.enumerated().sorted { a, b in
            let ra = rank(state(a.element)), rb = rank(state(b.element))
            if ra != rb { return ra < rb }
            if ra == 0 {
                let da = since[id(a.element)] ?? .distantFuture, db = since[id(b.element)] ?? .distantFuture
                if da != db { return da < db }
            }
            return a.offset < b.offset
        }
        .map(\.element)
    }
}
