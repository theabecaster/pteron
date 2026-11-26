import SwiftUI
import RexKit

/// Rex's sidebar, in one of two modes like the Rex Mac app's: Sessions (machines, then sessions,
/// then each session's tabs) or Agents (every agent, the ones waiting for you first).
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(Prefs.self) private var prefs
    @Environment(\.windowControls) private var windowControls
    @Binding var mode: SidebarMode
    var onSelect: (Selection) -> Void
    /// Where Sessions mode was scrolled to, so a trip to Agents mode and back keeps it.
    @State private var sessionsScrollY: CGFloat = 0

    var body: some View {
        let theme = prefs.theme(for: scheme)
        VStack(spacing: 0) {
            SidebarModeSwitch(mode: $mode, theme: theme)
                .padding(.horizontal, 10)
                // Clear of the window controls in a window's corner (`WindowControls`).
                .padding(.leading, windowControls.width)
                .padding(.top, 6)
                .padding(.bottom, 2)
            switch mode {
            case .sessions: SessionsList(theme: theme, scrollY: $sessionsScrollY, onSelect: onSelect)
            case .agents: AgentsList(theme: theme, onSelect: onSelect)
            }
            bottomBar(theme)
        }
        .foregroundStyle(theme.fg)
    }

    private func bottomBar(_ theme: TermTheme) -> some View {
        HStack(spacing: 4) {
            IconButton(symbol: "gearshape", label: "Settings") { model.showSettings = true }
            Spacer()
            // Only computers that are connected can make one; with one such computer, + makes it there.
            let targets = NewSession.targets(model.servers)
            if targets.count == 1, let s = targets.first {
                Button { newSession(on: s) } label: { plus }
                    .accessibilityLabel("New Session on \(s.config.name)")
            } else {
                Menu {
                    ForEach(targets) { s in
                        Button("New Session on \(s.config.name)") { newSession(on: s) }
                    }
                } label: { plus }
                .disabled(targets.isEmpty)
                .accessibilityLabel("New Session")
            }
        }
        .font(.system(size: 17))
        .foregroundStyle(theme.chrome.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(theme.chrome.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(theme.chrome.divider).frame(height: 1) }
    }

    private var plus: some View {
        Image(systemName: "plus")
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    private func newSession(on s: ServerConnection) {
        Task {
            guard let sel = NewSession.opened(s, id: await s.createSession(label: nil)) else { return }
            model.select(s, session: sel.sessionID, window: sel.windowID)
            onSelect(sel)
        }
    }
}

/// New Session, wherever it is offered: on a connected computer, and the new session's first tab
/// goes on screen.
@MainActor
enum NewSession {
    /// The computers the + menu offers: the connected ones.
    static func targets(_ servers: [ServerConnection]) -> [ServerConnection] {
        servers.filter { $0.phase == .online }
    }

    /// The tab to show for a session `server` just made, once its view is in.
    static func opened(_ server: ServerConnection, id: String?) -> Selection? {
        guard let id, let w = server.views[id]?.windows.first else { return nil }
        return Selection(serverID: server.id, sessionID: id, windowID: w.id)
    }
}

extension ServerConnection {
    /// Reconnect is offered only while the computer is down and no attempt the user asked for is
    /// running: on a connected one it would only drop a working connection.
    var offersReconnect: Bool { phase.problem != nil && !retrying }
}

/// Sessions | Agents, at the sidebar's top. The Agents segment carries the waiting count, so a
/// waiting agent shows from Sessions mode too. The count comes from `AppModel.waitingAgentIDs`, the
/// same set `WaitingWatcher` reads, so it re-renders only when an agent starts or stops waiting.
struct SidebarModeSwitch: View {
    @Environment(AppModel.self) private var model
    @Binding var mode: SidebarMode
    let theme: TermTheme
    @Namespace private var selection

    var body: some View {
        let waiting = model.waitingAgentIDs.count
        HStack(spacing: 2) {
            ForEach(SidebarMode.allCases) { m in
                Button {
                    guard mode != m else { return }
                    Haptic.selection()
                    withAnimation(.snappy(duration: 0.2)) { mode = m }
                } label: {
                    segment(m, waiting: m == .agents ? waiting : 0)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(m == .agents && waiting > 0 ? "\(m.title), \(waiting) waiting" : m.title)
                .accessibilityAddTraits(mode == m ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10).fill(theme.fg.opacity(0.06)))
    }

    private func segment(_ m: SidebarMode, waiting: Int) -> some View {
        let on = mode == m
        return HStack(spacing: 5) {
            // The word, or where it doesn't fit, the mode's symbol. The waiting count always shows.
            ViewThatFits(in: .horizontal) {
                Text(m.title).font(.footnote.weight(.semibold)).lineLimit(1).fixedSize()
                Image(systemName: m.symbol).font(.footnote.weight(.semibold))
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
            }
            if waiting > 0 {
                // Stops where the other pills stop, so both segments keep their room.
                StatusPill(pill: AgentCounts.Pill(kind: .waiting, count: waiting), compact: true, theme: theme)
                    .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    .layoutPriority(1)
            }
        }
        .foregroundStyle(on ? theme.fg : theme.chrome.secondary)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 32)
        .background {
            if on {
                RoundedRectangle(cornerRadius: 7)
                    .fill(theme.chrome.rowSelected)
                    .matchedGeometryEffect(id: "segment", in: selection)
            }
        }
        .frame(minHeight: 38)
        .contentShape(Rectangle())
    }
}
