import SwiftUI

/// The sidebar's rows in Sessions mode, flattened: each machine, then (unless folded) its sessions,
/// then (unless folded) each session's tabs, then its Ports group while a program in one of its
/// panes listens on a port. Pure, so it is tested; the view looks the ids up.
///
/// Every row's id stays the same for the life of its item, so `List` turns a fold into removals and
/// a reopen into inserts, and animates only those rows.
enum SidebarOutline {
    struct Machine: Equatable {
        var id: UUID
        var sessions: [Session]
        /// Connected and synced with no sessions: a "No sessions" row shows under it.
        var empty = false
        /// A program in one of its panes listens on a port: the Ports group shows.
        var hasPorts = false
        /// The ids of the group's rows (`PortRow.id`). Left empty while the group is folded:
        /// its header needs only `hasPorts`.
        var ports: [String] = []
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
            /// A machine's Ports group, after its sessions, and one port in it.
            case portsHeader(UUID)
            case port(UUID, id: String)
        }
        var kind: Kind
        /// The first machine: no divider above it.
        var first = false
        /// The session's last tab.
        var last = false
        /// Its place among its siblings: a session in its machine, a tab in its session. Folding
        /// lets the lower rows go first.
        var index = 0

        var id: String {
            switch kind {
            case .machine(let m): "m:\(m.uuidString)"
            case .session(let m, let s): "s:\(m.uuidString):\(s)"
            case .tab(let m, _, let w): "t:\(m.uuidString):\(w)"
            case .empty(let m): "e:\(m.uuidString)"
            case .portsHeader(let m): "pg:\(m.uuidString)"
            case .port(let m, let p): "p:\(m.uuidString):\(p)"
            }
        }
    }

    /// `target` with at most `adding` of the rows not in `shown`: the first ones, in order. The rest
    /// wait for the next step, so opening a big group builds a few cells per frame.
    static func stepped(_ target: [Row], shown: Set<String>, adding: Int) -> [Row] {
        var left = adding
        return target.filter { row in
            if shown.contains(row.id) { return true }
            guard left > 0 else { return false }
            left -= 1
            return true
        }
    }

    static func rows(_ machines: [Machine], collapsed: Set<String>) -> [Row] {
        var out: [Row] = []
        for (i, m) in machines.enumerated() {
            out.append(Row(kind: .machine(m.id), first: i == 0))
            guard !collapsed.contains(SidebarCollapse.machine(m.id)) else { continue }
            if m.empty, m.sessions.isEmpty { out.append(Row(kind: .empty(m.id))) }
            for (k, s) in m.sessions.enumerated() {
                out.append(Row(kind: .session(m.id, s.id), index: k))
                guard !collapsed.contains(SidebarCollapse.session(m.id, s.id)) else { continue }
                for (j, w) in s.windowIDs.enumerated() {
                    out.append(Row(kind: .tab(m.id, session: s.id, window: w), last: j == s.windowIDs.count - 1, index: j))
                }
            }
            guard m.hasPorts else { continue }
            out.append(Row(kind: .portsHeader(m.id), index: m.sessions.count))
            guard !collapsed.contains(SidebarCollapse.ports(m.id)) else { continue }
            for (j, p) in m.ports.enumerated() {
                out.append(Row(kind: .port(m.id, id: p), last: j == m.ports.count - 1, index: j))
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
    /// A machine's Ports group.
    static func ports(_ id: UUID) -> String { "p:\(id.uuidString)" }

    /// Folds `key` if it is open, opens it if it is folded.
    static func toggled(_ keys: Set<String>, _ key: String) -> Set<String> {
        keys.contains(key) ? keys.subtracting([key]) : keys.union([key])
    }

    /// The keys with the selected tab's session and machine open, so the tab on screen always has a
    /// row in the sidebar (after a tap, Jump to Waiting, a push, a toast or a new session).
    static func revealing(_ keys: Set<String>, _ selection: Selection) -> Set<String> {
        keys.subtracting([machine(selection.serverID), session(selection.serverID, selection.sessionID)])
    }

    /// The fold's spring: rows unfurl and the rows below move on it (`SidebarMotion`). A big
    /// reveal adds a few rows per frame (`SidebarReveal`), so no frame builds a screenful.
    static let animation = Animation.spring(duration: 0.32, bounce: 0.12)

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
