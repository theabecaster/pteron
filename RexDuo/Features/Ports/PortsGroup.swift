import RexKit
import SwiftUI

extension EnvironmentValues {
    /// False while the sidebar is hidden (a closed drawer, a closed inline sidebar). A machine's
    /// ports button then reads no port state, so a port that comes, goes or changes hands runs
    /// no view.
    @Entry var sidebarShown = true
}

/// What a machine's ports button last read, kept for while the sidebar is hidden. Not observed:
/// writing it from a body re-renders nothing.
@MainActor
final class PortsSeen {
    var counts: [UUID: Int] = [:]

    /// How many ports the machine's button shows now: fresh while it is shown, else what was
    /// read last. With no ports it reads only `hasPortRows`, which changes with the first and the
    /// last port; with some, `portRowIDs`, which changes only when a row comes or goes.
    func count(_ server: ServerConnection, shown: Bool) -> Int {
        guard shown else { return counts[server.id] ?? 0 }
        let n = server.hasPortRows ? server.portRowIDs.count : 0
        counts[server.id] = n
        return n
    }
}

/// One port of a machine's ports list (`PortsList`): what runs and where, with `localhost:3000`
/// under it. A tap, or Return on a focused row, opens its page in the app; the menu and the
/// VoiceOver actions copy its link, show its pane and stop its program.
///
/// It reads the port, its pane's foreground process and its Stop state in its own body, so a
/// change to one port re-renders this row alone.
struct PortRowView: View {
    let server: ServerConnection
    /// `PortRow.id`.
    let rowID: String
    let dim: Bool
    let theme: TermTheme
    /// Where the tile starts.
    var leading: CGFloat = 16
    /// Closes the list's popover or sheet, then runs the action once it has gone (`PortsList`).
    var close: PortsList.Close = { $0() }
    @Environment(AppModel.self) private var model
    @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        #if DEBUG
        let _ = RenderCount.bump(.portRows)
        #endif
        // The list builds its rows only while it is up, so a row always reads its port live.
        if let row = model.ports.row(server, id: rowID) {
            content(row)
        }
    }

    @ViewBuilder
    private func content(_ row: PortRow) -> some View {
        let ports = model.ports, server = server
        let status = ports.status(server, row)
        let canStop = !dim && ports.offersStop(server, row)
        let close = close
        // The page and the pane come up once the list has gone; Copy Link closes it too. Stop
        // leaves it up, so the row can say "Stopping…".
        let open = { close { ports.open(server, row) } }
        let copy = { close { ports.copyLink(server, row) } }
        let show = { close { _ = ports.showPane(server, row) } }
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
            .accessibilityAction(named: "Copy Link", copy)
            .accessibilityAction(named: "Show Pane", show)
            .modifier(StopAction(enabled: canStop, stop: stop))
            .opacity(dim ? 0.45 : 1)
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
        .padding(.leading, leading)
        .padding(.trailing, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
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

/// Stop as a VoiceOver action, only where the menu offers it.
private struct StopAction: ViewModifier {
    let enabled: Bool
    let stop: () -> Void

    func body(content: Content) -> some View {
        if enabled { content.accessibilityAction(named: "Stop", stop) } else { content }
    }
}
