import RexKit
import SwiftUI

/// A machine's ports, at the trailing end of its sidebar header: a globe and how many web ports
/// programs in its panes listen on (docs/sidebar.md, Ports). It shows only while there is one,
/// and adds no row. A tap opens the machine's ports in a popover (`PortsList`).
///
/// It reads the ports in its own body, so a port that comes or goes redraws this button alone,
/// and a port that changes hands redraws nothing here. While the sidebar is hidden it reads no
/// port state at all (`PortsSeen`).
struct MachinePortsButton: View {
    let server: ServerConnection
    let theme: TermTheme
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs
    @Environment(\.sidebarShown) private var sidebarShown
    @State private var seen = PortsSeen()
    @State private var open = false

    /// How long the popover takes to go, as the title menu waits.
    private static let closeTime: Duration = .milliseconds(350)

    var body: some View {
        #if DEBUG
        let _ = RenderCount.bump(.portButtons)
        #endif
        // Kept while its popover is up, so the last port going doesn't pull the popover away.
        let count = seen.count(server, shown: sidebarShown || open)
        if count > 0 || open {
            button(count)
        }
    }

    private func button(_ count: Int) -> some View {
        let dim = server.phase.problem != nil
        return Button {
            Haptic.tap()
            open = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "globe")
                    .font(.caption.weight(.semibold))
                Text("\(count)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
            }
            .foregroundStyle(theme.chrome.secondary)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 6)
            .frame(minWidth: 36, minHeight: 44)
            .contentShape(Rectangle())
            .opacity(dim ? 0.45 : 1)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(Self.spoken(count, machine: server.config.name))
        .accessibilityHint("Shows the pages you can open.")
        .popover(isPresented: $open, arrowEdge: .top) {
            PortsList(server: server, title: "Ports", theme: theme, close: close)
                .frame(width: 300)
                .frame(maxHeight: 420)
                .presentationCompactAdaptation(.popover)
                .modifier(PopoverSurface(fill: theme.chrome.sidebar))
                .environment(model)
                .environment(prefs)
        }
        #if DEBUG
        .onAppear { if PortsList.openAtLaunch() { open = true } }
        #endif
    }

    /// Closes the popover; what was tapped runs once it has gone, so a page or a pane comes up
    /// over the app and not over the popover.
    private var close: PortsList.Close {
        { action in
            open = false
            Task { @MainActor in
                try? await Task.sleep(for: Self.closeTime)
                action()
            }
        }
    }

    nonisolated static func spoken(_ count: Int, machine: String) -> String {
        "Ports on \(machine), \(count) open"
    }
}

/// A machine's ports, one row each (`PortRowView`): for the popover of its sidebar header and,
/// in tab mode, for the sheet the session popover's machine heading opens (`PortsSheet`). The
/// rows follow `ServerConnection.portRowIDs`, which changes only when a row comes or goes; each
/// row reads its own port. A down machine's last known ports stay, dimmed.
struct PortsList: View {
    /// Closes the popover or the sheet, then runs the action.
    typealias Close = @MainActor (@escaping @MainActor () -> Void) -> Void

    let server: ServerConnection
    let title: String
    let theme: TermTheme
    let close: Close

    var body: some View {
        let ids = server.portRowIDs
        let problem = server.phase.problem
        PortsListFrame(title: title, problem: problem.map { OfflineCopy.short($0.kind) }, isEmpty: ids.isEmpty, theme: theme) {
            ForEach(ids, id: \.self) { id in
                PortRowView(server: server, rowID: id, dim: problem != nil, theme: theme, close: close)
            }
        }
    }

    #if DEBUG
    private static var launched = false

    /// `-showPorts YES` (testing): the first ports button that shows opens its popover, once.
    static func openAtLaunch() -> Bool {
        guard !launched, UserDefaults.standard.bool(forKey: "showPorts") else { return false }
        launched = true
        return true
    }
    #endif
}

/// What a ports list draws around its rows: its title, why a down machine's ports are dimmed,
/// and the line for a list with none. `PortsList` fills it; tests draw it with rows of their own.
struct PortsListFrame<Rows: View>: View {
    let title: String
    var problem: String?
    let isEmpty: Bool
    let theme: TermTheme
    @ViewBuilder let rows: () -> Rows

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.chrome.secondary)
                    if let problem {
                        Text(problem)
                            .font(.caption2)
                            .foregroundStyle(theme.chrome.tertiary)
                    }
                }
                .lineLimit(1)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 4)
                rows()
                if isEmpty {
                    Text("Nothing listens on a port now.")
                        .font(.subheadline)
                        .foregroundStyle(theme.chrome.tertiary)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                }
            }
            .padding(.bottom, 6)
        }
        .scrollBounceBehavior(.basedOnSize)
        .foregroundStyle(theme.fg)
    }
}

/// A machine's ports in a sheet, for tab mode, where there is no sidebar header to open them
/// from: the session popover's machine heading does (`SessionPopover.Action.ports`). The same
/// list and rows; a page or a pane comes up once the sheet has gone (`DismissalWait`). Shown by
/// `AppModel.showPorts(_:)`.
struct PortsSheet: View {
    let server: ServerConnection
    /// Holds a row's action until the sheet has gone; whoever shows the sheet reports that.
    let wait: DismissalWait
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs

    var body: some View {
        let theme = prefs.theme
        let model = model
        PortsSheetFrame(theme: theme, done: { model.portsShown = nil }) {
            PortsList(server: server, title: server.config.name, theme: theme) { action in
                wait.hold(action)
                model.portsShown = nil
            }
        }
    }
}

/// The sheet around a ports list: its title, Done, and the theme. `PortsSheet` fills it.
struct PortsSheetFrame<List: View>: View {
    let theme: TermTheme
    let done: () -> Void
    @ViewBuilder let list: () -> List

    var body: some View {
        NavigationStack {
            list()
                .navigationTitle("Ports")
                .navigationBarTitleDisplayMode(.inline)
                .settingsBar(theme)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(theme.chrome.sidebar)
        }
        .presentationDetents([.medium, .large])
        .tint(theme.accent)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }
}
