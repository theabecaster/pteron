import SwiftUI
import RexKit

/// "Arrange ▸" in the pane menu: Swap With, Move to Tab, Balance Splits and Close Other Panes…
/// for a tab with several panes. Its own view, so only it reads the server's support, the
/// session's tabs and the panes' names: a change there redraws this row, not the tab screen. The
/// names never come from a title (`PaneName`), so an agent's spinning title rebuilds nothing.
struct PaneMenuItems: View {
    let server: ServerConnection
    let sessionID: String
    let window: WindowInfo
    let block: String
    let onSwap: (String) -> Void
    let onMove: (String) -> Void
    let onMoveToNewTab: () -> Void
    let onBalance: () -> Void
    let onCloseOthers: () -> Void

    var body: some View {
        #if DEBUG
        let _ = RenderCount.bump(.paneMenuItems)
        #endif
        if let m = PaneMenuModel.make(server: server, sessionID: sessionID, window: window, block: block) {
            Menu {
                if !m.swap.isEmpty {
                    Section("Swap With") {
                        ForEach(m.swap) { r in Button { onSwap(r.id) } label: { row(r) } }
                    }
                }
                if !m.tabs.isEmpty || m.newTab {
                    Section("Move to Tab") {
                        ForEach(m.tabs) { r in Button { onMove(r.id) } label: { row(r) } }
                        if m.newTab {
                            Button(action: onMoveToNewTab) { Label("New Tab", systemImage: "plus.square") }
                        }
                    }
                }
                if m.balance {
                    Section {
                        Button(action: onBalance) { Label("Balance Splits", systemImage: "rectangle.split.3x1") }
                            .disabled(m.balanced)
                    }
                }
                if m.closeOthers {
                    Section {
                        Button(role: .destructive, action: onCloseOthers) {
                            Label("Close Other Panes…", systemImage: "xmark.square")
                        }
                    }
                }
            } label: {
                Label("Arrange", systemImage: "rectangle.3.group")
            }
        }
    }

    private func row(_ r: PaneMenuModel.Row) -> some View {
        Group {
            Label(r.name, systemImage: r.symbol)
            if let s = r.subtitle { Text(s) }
        }
    }
}

/// What Arrange lists for a pane, worked out from the layout, the server's support and the panes'
/// names. Nil when Arrange doesn't show.
@MainActor
struct PaneMenuModel: Equatable {
    struct Row: Identifiable, Equatable {
        var id: String
        var name: String
        var subtitle: String?
        var symbol: String
    }

    var swap: [Row] = []
    var tabs: [Row] = []
    var newTab = false
    var balance = false
    /// Every split is even already: Balance Splits shows, disabled.
    var balanced = false
    var closeOthers = false

    /// What the pane's server, session and names give. Reads only the server's support, the
    /// session's tabs and the name table, never a title.
    static func make(server: ServerConnection, sessionID: String, window: WindowInfo, block: String) -> PaneMenuModel? {
        let tabs = server.views[sessionID]?.windows ?? [window]
        return build(PaneTarget(window: window, block: block, tabs: tabs), support: server.capabilities.paneSupport) {
            server.paneNames.value($0)
        }
    }

    typealias Names = (String) -> PaneNameParts?

    static func build(_ t: PaneTarget, support: PaneSupport, names: Names = { _ in nil }) -> PaneMenuModel? {
        guard PaneArrange.showsArrange(t, support: support) else { return nil }
        var m = PaneMenuModel()
        if PaneArrange.isAvailable(.swap, target: t, support: support) {
            m.swap = paneRows(t.window, names: names).filter { $0.id != t.block }
        }
        if PaneArrange.isAvailable(.moveToTab, target: t, support: support) {
            let all = t.tabs.map(\.id)
            m.tabs = MoveAnchor.targets(from: t.window.id, in: t.tabs).map { w in
                tabRow(w, position: (all.firstIndex(of: w.id) ?? 0) + 1, names: names)
            }
        }
        m.newTab = PaneArrange.isAvailable(.moveToNewTab, target: t, support: support)
        if PaneArrange.isAvailable(.balance, target: t, support: support), let layout = t.window.layout {
            m.balance = true
            m.balanced = SplitBalance.ratios(layout).isEmpty
        }
        m.closeOthers = PaneArrange.isAvailable(.closeOthers, target: t, support: support)
        return m
    }

    /// A tab's tiled panes by name, in reading order. Two panes of the same name also say which
    /// pane they are.
    static func paneRows(_ w: WindowInfo, names: Names) -> [Row] {
        let ids = PaneScope.arrangeable(window: w)
        let rows = ids.enumerated().map { i, id in
            let parts = names(id)
            return Row(id: id, name: PaneName.menu(w.block(id), position: i + 1, parts: parts), symbol: PaneName.symbol(parts))
        }
        let names = Dictionary(grouping: rows, by: \.name)
        return rows.enumerated().map { i, r in
            var r = r
            if (names[r.name]?.count ?? 0) > 1, r.name != "Pane \(i + 1)" { r.subtitle = "Pane \(i + 1)" }
            return r
        }
    }

    static func tabRow(_ w: WindowInfo, position: Int, server: ServerConnection) -> Row {
        tabRow(w, position: position) { server.paneNames.value($0) }
    }

    /// Another tab: its own label, else "Tab N", with the name of the pane a moved pane goes beside.
    static func tabRow(_ w: WindowInfo, position: Int, names: Names) -> Row {
        let custom = !w.label.isEmpty && !w.label.hasPrefix("Window ")
        let anchor = MoveAnchor.pick(window: w)?.block
        let leaves = PaneScope.arrangeable(window: w)
        let parts = anchor.flatMap(names)
        let pane = anchor.map { PaneName.menu(w.block($0), position: (leaves.firstIndex(of: $0) ?? 0) + 1, parts: parts) }
        return Row(id: w.id, name: custom ? w.label : "Tab \(position)", subtitle: pane, symbol: PaneName.symbol(parts))
    }
}
