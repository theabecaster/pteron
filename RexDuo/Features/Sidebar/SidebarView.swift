import SwiftUI
import RexKit

/// Rex's sidebar, in one of two modes like the Rex Mac app's: Sessions (machines, then sessions,
/// then each session's tabs) or Agents (every agent, the ones waiting for you first).
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @Environment(Prefs.self) private var prefs
    @Binding var mode: SidebarMode
    var onSelect: (Selection) -> Void

    var body: some View {
        let theme = prefs.theme(for: scheme)
        VStack(spacing: 0) {
            SidebarModeSwitch(mode: $mode, theme: theme)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 2)
            switch mode {
            case .sessions: SessionsList(theme: theme, onSelect: onSelect)
            case .agents: AgentsList(theme: theme, onSelect: onSelect)
            }
            bottomBar(theme)
        }
        .foregroundStyle(theme.fg)
        // Past this a machine's name no longer fits a 260 pt sidebar even on two lines, and single
        // words break mid-word. The levels keep their ratios up to here.
        .dynamicTypeSize(...DynamicTypeSize.accessibility2)
    }

    private func bottomBar(_ theme: TermTheme) -> some View {
        HStack(spacing: 4) {
            IconButton(symbol: "gearshape", label: "Settings") { model.showSettings = true }
            Spacer()
            Menu {
                ForEach(model.servers) { s in
                    Button("New Session on \(s.config.name)") {
                        Task {
                            if let id = await s.createSession(label: nil), let w = s.views[id]?.windows.first {
                                model.select(s, session: id, window: w.id)
                                onSelect(Selection(serverID: s.id, sessionID: id, windowID: w.id))
                            }
                        }
                    }
                }
            } label: {
                Image(systemName: "plus")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("New Session")
        }
        .font(.system(size: 17))
        .foregroundStyle(theme.chrome.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(theme.chrome.sidebar)
        .overlay(alignment: .top) { Rectangle().fill(theme.chrome.divider).frame(height: 1) }
    }
}

/// Sessions | Agents, at the sidebar's top. The Agents segment carries the waiting count, so a
/// waiting agent shows from Sessions mode too. It reads every block's status, so it is its own view:
/// a status change re-renders only this switch.
struct SidebarModeSwitch: View {
    @Environment(AppModel.self) private var model
    @Binding var mode: SidebarMode
    let theme: TermTheme
    @Namespace private var selection

    var body: some View {
        let waiting = model.servers.reduce(0) { $0 + $1.agents.count { $0.status?.state == "blocked" } }
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
            }
            if waiting > 0 {
                StatusPill(pill: AgentCounts.Pill(kind: .waiting, count: waiting), compact: true, theme: theme)
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
