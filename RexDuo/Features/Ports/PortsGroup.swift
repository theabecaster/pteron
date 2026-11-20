import RexKit
import SwiftUI

/// The header of a machine's Ports group in the sidebar: it folds like a session. The group
/// shows only while a program in one of the machine's panes listens on a port
/// (docs/sidebar.md, Ports). Folded it shows no count, so nothing runs for a port that comes
/// or goes while it is folded.
struct PortsHeaderRow: View, Equatable {
    let serverID: UUID
    let collapsed: Bool
    let topGap: CGFloat
    let dim: Bool
    let theme: TermTheme
    @Environment(Prefs.self) private var prefs

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.serverID == b.serverID && a.collapsed == b.collapsed && a.topGap == b.topGap
            && a.dim == b.dim && a.theme.id == b.theme.id
    }

    var body: some View {
        let id = serverID
        let toggle = { toggleFold(SidebarCollapse.ports(id), prefs) }
        Button(action: toggle) {
            HStack(spacing: 0) {
                Text("Ports")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(theme.chrome.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Chevron(open: !collapsed, theme: theme)
            }
            .padding(.leading, SidebarMetrics.sessionLeading)
            .padding(.trailing, SidebarMetrics.pad)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(interactions: .activate)
        .onKeyPress(.return) { toggle(); return .handled }
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .padding(.top, topGap)
        .opacity(dim ? 0.45 : 1)
    }
}

extension EnvironmentValues {
    /// False while the sidebar is hidden (a closed drawer, a closed inline sidebar). The Ports
    /// group then reads no port state, so a port that comes, goes or changes hands runs no view.
    @Entry var sidebarShown = true
}

/// What the Ports group last read, kept for while the sidebar is hidden. Not observed: writing
/// it from a body re-renders nothing.
@MainActor
final class PortsSeen {
    var has: [UUID: Bool] = [:]
    var ids: [UUID: [String]] = [:]
    var row: PortRow?

    /// The machine's rows as the list may read them now: fresh while the sidebar shows and the
    /// group is open; else whether there are any (shown, folded); else what was read last.
    func rows(_ server: ServerConnection, shown: Bool, open: Bool) -> (has: Bool, ids: [String]) {
        guard shown else { return (has[server.id] ?? false, open ? (ids[server.id] ?? []) : []) }
        let any = server.hasPortRows
        has[server.id] = any
        guard open else { return (any, []) }
        let now = server.portRowIDs
        ids[server.id] = now
        return (any, now)
    }
}

/// One port of the Ports group: what runs and where, with `localhost:3000` under it. A tap opens
/// its page in the app; the menu and the swipe copy its link, show its pane and stop its program.
///
/// It reads the port, its pane's foreground process and its Stop state in its own body, so a
/// change to one port re-renders this row alone.
struct PortRowView: View {
    let server: ServerConnection
    /// `PortRow.id`, and the row's id in the sidebar's outline (for the swipe).
    let rowID: String
    let outlineID: String
    let dim: Bool
    let theme: TermTheme
    let swipe: SwipeState
    @Environment(AppModel.self) private var model
    @Environment(\.sidebarShown) private var sidebarShown
    @State private var seen = PortsSeen()
    @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        #if DEBUG
        let _ = RenderCount.bump(.portRows)
        #endif
        // Hidden, the row is what it was: it reads nothing until the sidebar shows again.
        let row = sidebarShown ? model.ports.row(server, id: rowID) : seen.row
        let _ = sidebarShown ? (seen.row = row) : ()
        if let row {
            content(row, live: sidebarShown)
        }
    }

    @ViewBuilder
    private func content(_ row: PortRow, live: Bool) -> some View {
        let ports = model.ports, server = server
        let status = live ? ports.status(server, row) : nil
        let canStop = live && !dim && ports.offersStop(server, row)
        let open = { ports.open(server, row) }
        let copy = { ports.copyLink(server, row) }
        let show = { _ = ports.showPane(server, row) }
        let stop = { ports.stop(server, row) }
        Button(action: open) { label(row, status) }
            .buttonStyle(.plain)
            .focusable(interactions: .activate)
            .onKeyPress(.return) { open(); return .handled }
            .contextMenu {
                Button(action: copy) { Label("Copy Link", systemImage: "link") }
                Button(action: show) { Label("Show Pane", systemImage: "terminal") }
                if canStop {
                    Button(role: .destructive, action: stop) { Label("Stop", systemImage: "stop.circle") }
                }
            }
            .opacity(dim ? 0.45 : 1)
            .modifier(SidebarStackRow(theme: theme))
            .modifier(SidebarSwipe(id: outlineID, leading: [
                SwipeAction(title: "Show Pane", symbol: "terminal", tint: theme.accent, action: show),
            ], trailing: (canStop ? [SwipeAction(title: "Stop", symbol: "stop.circle", tint: theme.chrome.error, action: stop)] : []) + [
                SwipeAction(title: "Copy Link", symbol: "link", tint: theme.chrome.secondary, action: copy),
            ], state: swipe))
    }

    private func label(_ row: PortRow, _ status: PortActions.Status?) -> some View {
        let title = PortNames.title(row.entry)
        let state = Self.words(status)
        return HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(theme.chrome.secondary.opacity(0.9))
                Image(systemName: "globe")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.bg)
            }
            .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.system(size: 14 * scale))
                    .foregroundStyle(theme.fg.opacity(0.8))
                    .lineLimit(SidebarMetrics.lines(typeSize))
                // The state follows the address on its line, so a narrow sidebar cuts the state
                // and never the address.
                Text([row.entry.name, state].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(theme.chrome.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .padding(.leading, SidebarMetrics.tabLeading)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([title, row.entry.name, state].compactMap { $0 }.joined(separator: ", "))
    }

    /// What the row says after a Stop.
    static func words(_ status: PortActions.Status?) -> String? {
        switch status {
        case .stopping: "Stopping…"
        case .stillRunning: "Still running"
        case nil: nil
        }
    }
}
