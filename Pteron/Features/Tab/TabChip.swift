import Foundation
import RexKit

/// One tab of the session in the tab strip: what its chip shows, and what it offers. A value, so
/// the strip's view only draws it and the tests check it without a view.
///
/// The active chip is the title bar in small: the tab's title, the status of the pane on screen
/// and the waking mark, and its close button where the strip has room. Every other chip shows
/// its tab's status as its sidebar row does, a progress ring included.
struct TabChip: Identifiable, Equatable {
    /// At most this many pane icons, stacked as the Mac's tabs stack them.
    static let iconLimit = 3

    /// One pane of the tab: the agent it runs, or a shell. Drawn as the sidebar's tile is
    /// (`TabRowLabel.tile`): a circle for an agent, a rounded square for a shell.
    struct Icon: Equatable, Identifiable {
        /// The pane's id. An icon keeps it from place to place in the stack, so a change of
        /// active pane moves the icons rather than drawing new ones.
        var id: String
        var agent: AgentKind?
    }

    /// What a chip's menu offers.
    enum Action: Hashable, CaseIterable {
        case rename, close, closeOthers, moveLeft, moveRight
        /// Move to Session's row for that session (`moves`).
        case moveToSession(String)

        /// The menu's own rows; Move to Session's are the chip's `moves`.
        static var allCases: [Action] { [.rename, .close, .closeOthers, .moveLeft, .moveRight] }

        var title: String {
            switch self {
            case .rename: "Rename Tab…"
            case .close: "Close Tab"
            case .closeOthers: "Close Other Tabs"
            case .moveLeft: "Move Tab Backward"
            case .moveRight: "Move Tab Forward"
            case .moveToSession: MoveToSessionMenu.title
            }
        }

        var symbol: String {
            switch self {
            case .rename: "pencil"
            case .close: "xmark"
            case .closeOthers: "xmark.square"
            case .moveLeft: "arrow.left"
            case .moveRight: "arrow.right"
            case .moveToSession: MoveToSessionMenu.symbol
            }
        }

        /// Closing stops what runs there.
        var destructive: Bool { self == .close || self == .closeOthers }
    }

    /// The tab's id (Rex's window id).
    var id: String
    var title: String
    /// The tab on screen.
    var active: Bool
    /// Its place among the session's tabs, from 1, and how many there are.
    var position: Int
    var count: Int
    /// The panes' icons as a stack, front first (`stack`): the active pane's, then the panes
    /// after it in the tab's order. Decoration: they take no tap.
    var icons: [Icon]
    /// Panes beyond the icons.
    var morePanes: Int
    /// The status glyph: the shown pane's on the active chip, the tab's on any other.
    var badge: TabBadge
    /// The connection is being made again after a trip to the background: the active chip shows
    /// the waking mark, as the title bar does.
    var waking: Bool
    /// The chip carries its close button: the active chip, where the strip has the room.
    var showsClose: Bool
    /// The tab can move among the session's tabs (the server has `session.move_window`): the
    /// menu's Move rows, and a drag.
    var movable: Bool
    /// The sessions of the computer the tab can move to, in sidebar order: Move to Session's
    /// submenu. Empty where the computer can't move tabs between sessions.
    var moves: [SessionChoice]

    /// - Parameters:
    ///   - panes: every pane's agent, in the tab's order; nil for a shell.
    ///   - paneIDs: the panes' ids, in the same order. A pane without one is known by its place.
    ///   - front: the pane whose icon is in front: the pane on screen for the active chip, the
    ///     tab's own active pane for any other. Nil, or a pane the tab doesn't have: the first.
    ///   - status: the state the chip's glyph stands for: the shown pane's for the active chip,
    ///     the tab's top state for any other.
    ///   - progress: the progress bars of the tab's panes that report no agent status. The
    ///     active chip ignores them, as the title bar does.
    ///   - strip: the strip's layout, for the close button.
    init(id: String, title: String, active: Bool, position: Int, count: Int, panes: [AgentKind?],
         paneIDs: [String] = [], front: String? = nil, status: String?, progress: [TermProgress] = [], waking: Bool = false, movable: Bool = false,
         moves: [SessionChoice] = [], strip: StripLayout? = nil) {
        self.id = id
        self.title = title
        self.active = active
        self.position = position
        self.count = count
        let all = panes.enumerated().map { n, agent in
            Icon(id: n < paneIDs.count ? paneIDs[n] : "\(n)", agent: agent)
        }
        icons = Self.stack(all, front: front)
        morePanes = max(panes.count - Self.iconLimit, 0)
        badge = active ? .status(status) : TabBadge.of(status: status, progress: progress)
        self.waking = active && waking
        showsClose = active && (strip?.showsClose ?? false)
        self.movable = movable && count > 1
        self.moves = moves
    }

    /// The icons a chip stacks, front first: the `front` pane's, then the panes after it in the
    /// tab's order, round to the first, `iconLimit` at most. Round, so a step to the next pane
    /// brings the next icon forward and sends the front one to the back, as a deck turns.
    static func stack(_ panes: [Icon], front: String?) -> [Icon] {
        guard !panes.isEmpty else { return [] }
        let first = panes.firstIndex { $0.id == front } ?? 0
        return (0..<min(panes.count, iconLimit)).map { panes[(first + $0) % panes.count] }
    }

    /// The pane in front of the stack.
    var front: String? { icons.first?.id }

    /// What the stack's motion is scoped to: a new front pane moves the icons only while this
    /// stays the same. A tab switch makes one chip active and another not, and each shows its
    /// new front at once; a chip drawn for the first time has nothing to move from.
    struct StackScope: Equatable {
        var tab: String
        var active: Bool
    }

    var stackScope: StackScope { StackScope(tab: id, active: active) }

    /// The stack moves from `old` to `new`: the front pane changed on the same chip, in the same
    /// role. `PaneStack` draws by this rule.
    static func stackMoves(from old: TabChip, to new: TabChip) -> Bool {
        old.stackScope == new.stackScope && old.front != new.front
    }

    /// The chip's menu, top to bottom. Close Other Tabs needs another tab, and a tab moves only
    /// toward a side that has one.
    var menu: [Action] {
        var a: [Action] = [.rename]
        if movable {
            if position > 1 { a.append(.moveLeft) }
            if position < count { a.append(.moveRight) }
        }
        a.append(.close)
        if count > 1 { a.append(.closeOthers) }
        return a
    }

    /// One of VoiceOver's actions on the chip.
    struct SpokenAction: Identifiable {
        var action: Action
        var title: String
        var id: Action { action }
    }

    /// VoiceOver's actions: the menu's rows, then a Move to Session row for each session.
    var spokenActions: [SpokenAction] {
        menu.map { SpokenAction(action: $0, title: $0.title) }
            + moves.map { SpokenAction(action: .moveToSession($0.id), title: "Move to \($0.name)") }
    }

    /// What VoiceOver reads: "build, tab 2 of 5, Working".
    var spoken: String {
        var parts = [title, "tab \(position) of \(count)"]
        let status = Self.spoken(badge)
        if !status.isEmpty { parts.append(status) }
        return parts.joined(separator: ", ")
    }

    static func spoken(_ badge: TabBadge) -> String {
        switch badge {
        case .status(let state): BlockBadge.spoken(state)
        case .ring(let p): ProgressRing.spoken(p).capitalizedFirst
        }
    }
}

extension TabChip {
    /// The chip of `window` as the server has it now. Call it in the chip's own view, so a
    /// status or title change in one tab draws only that chip again.
    ///
    /// - Parameters:
    ///   - position: the tab's place among the session's tabs as the strip orders them, from 1.
    ///   - block: the pane on screen, for the active chip's status.
    @MainActor
    ///   - session: the tab's session, for Move to Session; nil leaves the submenu out.
    static func of(_ window: WindowInfo, position: Int, count: Int, server: ServerConnection, active: Bool,
                   block: String?, strip: StripLayout?, session: String? = nil) -> TabChip {
        let status = active ? block.flatMap { server.meta[$0]?.topStatus?.state } : server.windowStatus(window)?.state
        let blocks = window.allBlocks
        return TabChip(id: window.id, title: WindowTitle.of(window, server: server), active: active,
                       position: position, count: count,
                       panes: blocks.map { server.meta[$0.id]?.agentKind }, paneIDs: blocks.map(\.id),
                       front: active ? block : ActivePane.of(window, phone: nil),
                       status: status, progress: active ? [] : bars(window, server, status),
                       waking: server.waking,
                       movable: PaneArrange.isAvailable(.moveTab, target: nil, support: server.capabilities.paneSupport),
                       moves: session.map { SessionChoice.destinations(server, from: $0) } ?? [],
                       strip: strip)
    }

    /// The bars of the panes that report no agent status, read only when no agent status
    /// outranks them (`WindowStatusBadge`).
    @MainActor
    private static func bars(_ window: WindowInfo, _ server: ServerConnection, _ state: String?) -> [TermProgress] {
        if state == "blocked" || state == "error" || state == "working" { return [] }
        return window.allBlocks.compactMap { b in
            guard server.meta[b.id]?.statuses.isEmpty ?? true else { return nil }
            return server.progress.value(b.id)
        }
    }
}

/// The session chip at the strip's start: the session on screen, and the way to every other one.
struct SessionChip: Equatable {
    /// The session's name; "session" for one without a name, as the title bar says it.
    var name: String
    /// The machine's name, only when more than one is set up.
    var machine: String?
    /// Agents waiting for the user in this session: the chip's dot.
    var waiting: Int
    /// The name, or a glyph in a narrow strip (`StripLayout.session`).
    var form: StripLayout.SessionForm
    /// A session is on screen. Without one the chip says "Sessions".
    private(set) var hasSession = true

    /// Shown where no session is on screen.
    static func none(form: StripLayout.SessionForm = .name) -> SessionChip {
        var chip = SessionChip(name: "Sessions", machine: nil, waiting: 0, form: form)
        chip.hasSession = false
        return chip
    }

    static let hint = "Changes the session."

    /// What VoiceOver reads: "Session work, studio".
    var spoken: String {
        var s = hasSession ? "Session \(name)" : name
        if let machine { s += ", \(machine)" }
        if waiting > 0 { s += waiting == 1 ? ", 1 agent waiting" : ", \(waiting) agents waiting" }
        return s
    }

    init(name: String, machine: String?, waiting: Int, form: StripLayout.SessionForm = .name) {
        self.name = name.isEmpty ? "session" : name
        self.machine = machine
        self.waiting = waiting
        self.form = form
    }

    /// The chip of the session on screen. Reads only the session's name and the agent index.
    @MainActor
    static func of(_ sessionID: String, server: ServerConnection, servers: Int,
                   form: StripLayout.SessionForm = .name) -> SessionChip {
        SessionChip(name: server.views[sessionID]?.label ?? "", machine: servers > 1 ? server.config.name : nil,
                    waiting: server.agentKeys.filter { $0.sessionID == sessionID && $0.state == "blocked" }.count,
                    form: form)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
