import Foundation
import RexKit

/// What the palette searches.
enum GoToScope: Equatable, Sendable {
    /// `pane.go_to`: places first, then commands.
    case anything
    /// `session.switch`.
    case sessions
    /// `client.palette.toggle`.
    case commands

    /// The palette action that opens this scope, as the keymap names it.
    var action: String {
        switch self {
        case .anything: "pane.go_to"
        case .sessions: "session.switch"
        case .commands: "client.palette.toggle"
        }
    }

    var placeholder: String {
        switch self {
        case .anything: "Go to tab, pane or session"
        case .sessions: "Change session"
        case .commands: "Run a command"
        }
    }
}

/// One row, by what it stands for: kept across rebuilds and re-ranks, so a selection and a run
/// never follow a row index.
enum GoToItemID: Hashable, Sendable {
    case session(UUID, String)
    case tab(UUID, String, String)
    case pane(UUID, String, String, String)
    /// A command by its key (`GoToCommands`).
    case command(String)
    /// A row of a prompt, or another row that is no place and no command.
    case other(String)
}

/// The pane the palette was opened on: commands, Lua and block actions run against it.
struct GoToTarget: Equatable {
    var serverID: UUID
    var sessionID: String
    var windowID: String
    var blockID: String?
    /// The tab shows splits now (or is zoomed on the phone), so Zoom Pane applies.
    var canZoom = false
    /// Next and Previous Pane have somewhere to go (the tab's own rule, `WindowScreen.paneGroup`);
    /// nil: more than one page.
    var canSwitchPane: Bool? = nil
}

/// One row's searchable copy: raw strings and flags only, so it crosses to `GoToSearcher`.
struct GoToItem: Sendable, Identifiable {
    enum Kind: Sendable { case session, tab, pane, command }

    var id: GoToItemID
    var kind: Kind
    var title: String
    var subtitle: String
    /// Words to match besides the title, each with its weight (`GoToRanker.Weight`).
    var fields: [Field] = []
    /// The last six hex digits of the item's IDs, matched only for queries of 4+ hex digits.
    var shortIDs: [String] = []
    /// Its place in the sidebar's order (commands: their list order), for ties.
    var order: Int
    var offline = false
    var waiting = false
    /// The tab on screen when the palette opened (or a pane of it).
    var current = false
    /// Closes or clears: never row 1 in Go to Anything.
    var destructive = false
    /// Why the row can't run here; shown dimmed when set.
    var dimmed: String?
    var symbol: String
    /// The keymap's chord for the row's action, when one runs it.
    var keyLabel: String?
    /// A command's group, for the empty list in `.commands`.
    var category: String?
    /// A tab's place (from 1) in the target's session, for a digit query.
    var tabPosition: Int?

    struct Field: Sendable {
        var text: String
        var weight: Double
    }
}

/// What picking a row does. Kept on the main actor beside the items.
enum GoToRun {
    /// A tab, with the pane to show when one fits; a session's row opens its active tab.
    case place(Selection, block: String?)
    case command(RexCommand)
    /// The target pane's file browser, Insert Path, or a picker that sends a file or a photo.
    case files(FilesCommand)
    /// A Lua or block action. With `onTarget`, on the target pane; else on the server alone.
    case server(serverID: UUID, name: String, args: JSONObject?, title: String, onTarget: Bool)
    /// A port of a machine's Ports group (`PortRow.id`): its page opens in the app.
    case port(serverID: UUID, row: String)
    /// Shown, not runnable (`GoToItem.dimmed`).
    case none

    /// What a place's row runs, from its ID and the servers as they are now. Nil for a place
    /// that is gone, or an ID that isn't a place.
    @MainActor
    static func place(for id: GoToItemID, in model: AppModel) -> GoToRun? {
        switch id {
        case .session(let s, let sid):
            guard let w = model.server(s)?.views[sid]?.activeWindow else { return nil }
            return .place(Selection(serverID: s, sessionID: sid, windowID: w.id), block: nil)
        case .tab(let s, let sid, let wid):
            return .place(Selection(serverID: s, sessionID: sid, windowID: wid), block: nil)
        case .pane(let s, let sid, let wid, let bid):
            return .place(Selection(serverID: s, sessionID: sid, windowID: wid), block: bid)
        case .command, .other:
            return nil
        }
    }
}

/// The palette's raw copy of everything it lists, made on the main actor at open and at each
/// rebuild. It reads metadata, so it runs outside the rebuild's observation (`GoToModel`).
@MainActor
enum GoToSource {
    struct Copy {
        var items: [GoToItem] = []
        /// What the command rows run. A place runs from its ID (`GoToRun.place(for:)`), so the
        /// copy at open builds no table of every place.
        var runs: [GoToItemID: GoToRun] = [:]
        /// Servers that are online and synced: their recents can be pruned.
        var synced: Set<UUID> = []
        /// Servers still on their first connect: "studio is connecting".
        var connecting: [String] = []
    }

    /// The last path component of a working directory, `~` for home.
    static func shortPath(_ pwd: String?) -> String? {
        guard var p = pwd?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        if p.hasPrefix("file://"), let u = URL(string: p) { p = u.path }
        if p == "/" { return "/" }
        if p.hasSuffix("/") { p.removeLast() }
        let parts = p.split(separator: "/")
        if parts.count == 2, p.hasPrefix("/Users/") || p.hasPrefix("/home/") { return "~" }
        return parts.last.map(String.init)
    }

    /// The six last hex digits of an ID (`block:…3f9a2c`), lowercased.
    static func shortID(_ id: String) -> String {
        // Bytes, from the end: this runs for every row at open.
        var out: [UInt8] = []
        for b in id.utf8.reversed() {
            if b == UInt8(ascii: ":") || out.count == 6 { break }
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"): out.append(b)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): out.append(b + 32)
            default: continue
            }
        }
        return String(decoding: out.reversed(), as: UTF8.self)
    }

    /// A tab's title as the sidebar shows it (`WindowTitle.of`), from metadata read without
    /// making a box for every block.
    static func windowTitle(_ w: WindowInfo, focusedTitle: String?) -> String {
        if !(w.label.isEmpty || w.label.hasPrefix("Window ")) { return w.label }
        if let t = focusedTitle, !t.isEmpty { return WindowTitle.condense(t) }
        return w.block(w.focusedBlockID ?? "")?.label ?? "shell"
    }

    /// Every session, tab and pane (panes only in tabs with more than one) on every saved server.
    static func places(_ servers: [ServerConnection], target: GoToTarget?, waiting: Set<String>,
                       into copy: inout Copy, scope: GoToScope) {
        let several = servers.count > 1
        var order = 0
        for s in servers {
            let online = s.phase == .online
            if s.phase == .connecting { copy.connecting.append(s.config.name) }
            let machine = s.config.name
            let hidden = s.hiddenSessions()
            let views = s.views, pending = s.pendingOrder.tabs
            for e in s.orderedSessions where !hidden.contains(e.id) {
                let v = views[e.id]
                let label = (v?.label).flatMap { $0.isEmpty ? nil : $0 } ?? (e.label.isEmpty ? "session" : e.label)
                let sid = GoToItemID.session(s.id, e.id)
                // In the order the sidebar shows (`orderedWindowIDs`), read from one copy of the views.
                let ids = v?.windows.map(\.id) ?? []
                let windows = (pending[e.id].map { TabOrder.applied(ids, $0.order) } ?? ids).compactMap { v?.window($0) }
                order += 1
                var sub = [String]()
                if several { sub.append(machine) }
                sub.append(windows.count == 1 ? "1 tab" : "\(windows.count) tabs")
                if !online { sub.append("offline") }
                let waits = !waiting.isEmpty && windows.contains { $0.allBlocks.contains { waiting.contains($0.id) } }
                copy.items.append(GoToItem(
                    id: sid, kind: .session, title: label, subtitle: sub.joined(separator: " · "),
                    fields: [.init(text: machine, weight: GoToRanker.Weight.machine)],
                    shortIDs: [shortID(e.id)], order: order, offline: !online, waiting: waits,
                    current: target?.serverID == s.id && target?.sessionID == e.id, symbol: "rectangle.stack"))
                guard scope != .sessions else { continue }
                for (i, w) in windows.enumerated() {
                    let focused = w.focusedBlockID ?? w.orderedBlockIDs.first
                    let focusedMeta = focused.flatMap(s.currentMeta)
                    let title = windowTitle(w, focusedTitle: focusedMeta?.title)
                    let pwd = shortPath(focusedMeta?.pwd)
                    let tid = GoToItemID.tab(s.id, e.id, w.id)
                    order += 1
                    var sub = [String]()
                    if several { sub.append(machine) }
                    sub.append(label)
                    if let pwd { sub.append(pwd) }
                    if !online { sub.append("offline") }
                    let isCurrent = target?.serverID == s.id && target?.windowID == w.id
                    var fields = [GoToItem.Field(text: label, weight: GoToRanker.Weight.session),
                                  .init(text: machine, weight: GoToRanker.Weight.machine)]
                    if let pwd { fields.append(.init(text: pwd, weight: GoToRanker.Weight.pwd)) }
                    copy.items.append(GoToItem(
                        id: tid, kind: .tab, title: title, subtitle: sub.joined(separator: " · "), fields: fields,
                        shortIDs: [shortID(w.id)], order: order, offline: !online,
                        waiting: !waiting.isEmpty && w.allBlocks.contains { waiting.contains($0.id) }, current: isCurrent,
                        symbol: w.allBlocks.lazy.compactMap { s.currentMeta($0.id)?.agentKind }.first?.symbol ?? "terminal",
                        tabPosition: target?.serverID == s.id && target?.sessionID == e.id ? i + 1 : nil))
                    let panes = PaneScope.arrangeable(window: w)
                    guard panes.count > 1 else { continue }
                    for (p, bid) in panes.enumerated() {
                        let parts = s.paneNames.value(bid)
                        let name = PaneName.menu(w.block(bid), position: p + 1, parts: parts)
                        let m = s.currentMeta(bid)
                        let ppwd = shortPath(m?.pwd)
                        let pid = GoToItemID.pane(s.id, e.id, w.id, bid)
                        order += 1
                        var sub = [String]()
                        if several { sub.append(machine) }
                        sub.append(label)
                        sub.append(title)
                        if let ppwd { sub.append(ppwd) }
                        if !online { sub.append("offline") }
                        var fields = [GoToItem.Field(text: label, weight: GoToRanker.Weight.session * 0.8),
                                      .init(text: title, weight: GoToRanker.Weight.pane),
                                      .init(text: machine, weight: GoToRanker.Weight.machine)]
                        if let fg = m?.foreground, !fg.isEmpty { fields.append(.init(text: fg, weight: GoToRanker.Weight.pane)) }
                        if let ppwd { fields.append(.init(text: ppwd, weight: GoToRanker.Weight.pwd)) }
                        copy.items.append(GoToItem(
                            id: pid, kind: .pane, title: name, subtitle: sub.joined(separator: " · "), fields: fields,
                            shortIDs: [shortID(bid)], order: order, offline: !online, waiting: waiting.contains(bid),
                            current: isCurrent && target?.blockID == bid, symbol: PaneName.symbol(parts)))
                    }
                }
            }
            // A sessions-only copy lacks the tabs: it prunes nothing.
            if online, s.synced, scope != .sessions { copy.synced.insert(s.id) }
        }
    }
}
