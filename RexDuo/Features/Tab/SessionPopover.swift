import Foundation

/// The session chip's popover, as rows: every machine with its sessions, the computers that
/// aren't added, and a footer of the places the sidebar otherwise leads to. One list, drawn in
/// one scroll view; a value, so the view only draws it and reports the row that was tapped.
struct SessionPopover: Equatable {
    /// What a tap on a row, a heading's button or a menu row asks for.
    enum Action: Equatable {
        /// Show this tab: a session's row opens the tab the session last had in front.
        case open(Selection)
        /// New Session on that machine.
        case newSession(UUID)
        case reconnect(UUID)
        /// Add a computer a server lists (`NotAddedSection.add`).
        case add(KnownHost)
        /// Rename Session… and Close Session…, with the session's name as it shows.
        case renameSession(UUID, session: String, name: String)
        case closeSession(UUID, session: String, name: String)
        /// Go to Anything, the Agents sheet (`AppModel.showAgents()`) and Settings.
        case goTo, agents, settings
        /// Back to the sidebar: sets the one setting, `Prefs.navigation`.
        case useSidebar

        /// The action puts up a sheet, an alert or the palette. Those wait until the popover
        /// has closed: a sheet can't open over it, and the palette's field wants the keyboard.
        var presents: Bool {
            switch self {
            case .add, .renameSession, .closeSession, .goTo, .agents, .settings: true
            case .open, .newSession, .reconnect, .useSidebar: false
            }
        }
    }

    /// A machine's connection, as its heading says it.
    enum Status: Equatable {
        case connected
        /// Being connected again after a trip to the background (`ServerConnection.waking`).
        case waking
        case connecting
        /// Down, with the short reason (`OfflineCopy.short`). `retrying` while an attempt the
        /// user asked for is under way.
        case down(String, retrying: Bool = false)

        var spoken: String {
            switch self {
            case .connected: "Connected"
            case .waking: "Reconnecting"
            case .connecting: "Connecting"
            case .down(let why, _): why
            }
        }
    }

    struct Machine: Identifiable, Equatable {
        var id: UUID
        var name: String
        /// What the server was built for, for its glyph (`MachineGlyph.symbol`).
        var platform: String?
        var status: Status
        /// The heading's "+": New Session there. Only while the machine is connected.
        var newSession: Action?
        /// The heading's Reconnect. Only while the machine is down and no attempt is under way.
        var reconnect: Action?
    }

    struct Session: Identifiable, Equatable {
        /// The session's id on its machine.
        var session: String
        var machine: UUID
        var name: String
        /// The session on screen.
        var current: Bool
        /// Agents waiting for the user there: the row's dot.
        var waiting: Int
        /// Last known from a machine that is down: it opens read-only.
        var dim: Bool
        /// The tap. Nil for a session whose tabs aren't known.
        var open: Action?
        /// The row's context menu: Rename Session… and Close Session… on the current session,
        /// nothing on any other.
        var menu: [Action]

        var id: String { "\(machine.uuidString):\(session)" }
    }

    struct Footer: Identifiable, Equatable {
        var action: Action
        var title: String
        var symbol: String
        /// Agents: how many wait for the user. Zero shows nothing.
        var count = 0

        var id: String { title }
    }

    enum Row: Identifiable, Equatable {
        case machine(Machine)
        case session(Session)
        /// A connected machine without sessions: "No sessions".
        case empty(UUID)
        /// "Not added", above the computers that aren't.
        case notAdded
        case host(KnownHost)
        /// The first footer row is set apart from the list above it.
        case footer(Footer)

        var id: String {
            switch self {
            case .machine(let m): "m:\(m.id.uuidString)"
            case .session(let s): "s:\(s.id)"
            case .empty(let m): "e:\(m.uuidString)"
            case .notAdded: "not-added"
            case .host(let h): "h:\(h.id)"
            case .footer(let f): "f:\(f.id)"
            }
        }

        /// What a tap on the row does. Headings and "No sessions" take no tap.
        var action: Action? {
            switch self {
            case .session(let s): s.open
            case .host(let h): .add(h)
            case .footer(let f): f.action
            case .machine, .empty, .notAdded: nil
            }
        }
    }

    /// One machine as the app knows it now.
    struct Source: Equatable {
        struct Session: Equatable {
            var id: String
            var name: String
            /// The tab the session has in front; nil while its tabs aren't known.
            var tab: String?
            var waiting = 0
        }

        var id: UUID
        var name: String
        var platform: String?
        var status: Status
        /// Connected and synced: no sessions means there are none.
        var synced = true
        var sessions: [Session]
    }

    /// Machines and their sessions in the sidebar's order, then the computers that aren't
    /// added, then the footer.
    var rows: [Row]

    /// The footer's first row, which is set apart from the list above it.
    var firstFooterID: String? {
        rows.first { if case .footer = $0 { true } else { false } }?.id
    }

    /// - Parameters:
    ///   - current: the tab on screen.
    ///   - waiting: every agent waiting for the user, on any machine: the Agents row's count.
    init(machines: [Source], hosts: [KnownHost] = [], current: Selection?, waiting: Int = 0) {
        var rows: [Row] = []
        for m in machines {
            let up = m.status == .connected || m.status == .waking
            var down = false, retrying = false
            if case .down(_, let r) = m.status { (down, retrying) = (true, r) }
            rows.append(.machine(Machine(id: m.id, name: m.name, platform: m.platform, status: m.status,
                                         newSession: up ? .newSession(m.id) : nil,
                                         reconnect: down && !retrying ? .reconnect(m.id) : nil)))
            if up, m.synced, m.sessions.isEmpty { rows.append(.empty(m.id)) }
            for s in m.sessions {
                let name = s.name.isEmpty ? "session" : s.name
                let isCurrent = current?.serverID == m.id && current?.sessionID == s.id
                rows.append(.session(Session(
                    session: s.id, machine: m.id, name: name, current: isCurrent, waiting: s.waiting, dim: down,
                    open: s.tab.map { .open(Selection(serverID: m.id, sessionID: s.id, windowID: $0)) },
                    menu: isCurrent && !down ? [.renameSession(m.id, session: s.id, name: name),
                                                .closeSession(m.id, session: s.id, name: name)] : [])))
            }
        }
        if !hosts.isEmpty {
            rows.append(.notAdded)
            rows += hosts.map { .host($0) }
        }
        rows += Self.footer(waiting: waiting).map { .footer($0) }
        self.rows = rows
    }

    /// The footer, top to bottom: what the sidebar's top, its Agents mode and its gear lead to,
    /// then the way back to the sidebar.
    static func footer(waiting: Int) -> [Footer] {
        [Footer(action: .goTo, title: TabAction.goTo.title, symbol: TabAction.goTo.symbol),
         Footer(action: .agents, title: "Agents", symbol: SidebarMode.agents.symbol, count: waiting),
         Footer(action: .settings, title: "Settings", symbol: "gearshape"),
         Footer(action: .useSidebar, title: "Use Sidebar", symbol: "sidebar.left")]
    }

    /// A menu row's title.
    static func title(_ action: Action) -> String? {
        switch action {
        case .renameSession: "Rename Session…"
        case .closeSession: "Close Session…"
        case .newSession: "New Session"
        case .reconnect: "Reconnect"
        case .add: "Add"
        default: nil
        }
    }
}

extension SessionPopover {
    /// The popover for the servers as they are now. A down machine keeps its last known
    /// sessions, as the sidebar does.
    @MainActor
    init(_ model: AppModel) {
        let machines = model.servers.map { s in
            Source(id: s.id, name: s.config.name, platform: s.platform, status: Self.status(s),
                   synced: s.synced,
                   sessions: s.orderedSessions.map { e in
                       Source.Session(id: e.id, name: e.label, tab: s.views[e.id]?.activeWindow?.id,
                                      waiting: s.agentKeys.filter { $0.sessionID == e.id && $0.state == "blocked" }.count)
                   })
        }
        self.init(machines: machines, hosts: KnownHost.unsaved(model.servers.map { ($0.config, $0.hosts) }),
                  current: model.selection, waiting: model.waitingAgentIDs.count)
    }

    @MainActor
    static func status(_ s: ServerConnection) -> Status {
        switch s.phase {
        case .online: s.waking ? .waking : .connected
        case .idle, .connecting: .connecting
        case .offline(let p): .down(OfflineCopy.short(p.kind), retrying: s.retrying)
        }
    }
}
