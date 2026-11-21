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
/// VoiceOver actions open it in the iPhone's browser, copy its link, show its pane, and stop
/// or restart its program, each only where it applies.
///
/// It reads the port, its pane's foreground process and its state in its own body, so a change
/// to one port re-renders this row alone. The list builds its rows only while it is up, and a
/// row that shows has its port's process read once from the computer's Beacon
/// (`PortActions.learnOwner`), which is what Stop for a wrapped server, Restart and Open in
/// Browser go by. What it draws is `PortRowFace`.
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

    var body: some View {
        #if DEBUG
        let _ = RenderCount.bump(.portRows)
        #endif
        // The list builds its rows only while it is up, so a row always reads its port live.
        if let row = model.ports.row(server, id: rowID) {
            content(row)
                // Once per process: an answer already held asks nothing.
                .task(id: row.entry.pid) {
                    if !dim { model.ports.learnOwner(server, row) }
                }
        }
    }

    private func content(_ row: PortRow) -> some View {
        let ports = model.ports, server = server, close = close
        let offers = PortRowFace.Offers(browse: !dim && ports.offersBrowser(server, row),
                                        restart: !dim && ports.restartCommand(server, row) != nil,
                                        stop: !dim && ports.offersStop(server, row))
        // The page and the pane come up once the list has gone; Copy Link and Open in Browser
        // close it too. Stop and Restart leave it up, so the row can say how they go; a
        // Restart whose pane has to be shown first closes it, so the pane isn't under it.
        let acts = PortRowFace.Acts(
            open: { close { ports.open(server, row) } },
            browse: { close { ports.openInBrowser(server, row) } },
            copy: { close { ports.copyLink(server, row) } },
            show: {
                ports.dismissRestart(server, row)
                close { _ = ports.showPane(server, row) }
            },
            stop: { ports.stop(server, row) },
            restart: { ports.askRestart(server, row) },
            confirm: {
                if ports.paneShows(server, row) { ports.confirmRestart(server, row) } else { close { ports.confirmRestart(server, row) } }
            },
            cancel: { ports.dismissRestart(server, row) })
        return PortRowFace(row: row, note: ports.note(server, row), offers: offers, acts: acts, dim: dim, theme: theme, leading: leading)
    }

    /// What the row says after its address: a Stop's or a Restart's progress, or that its page
    /// is out in the iPhone's browser. Plain words; a Restart to confirm shows under the row.
    static func words(_ note: PortActions.Note?) -> String? {
        switch note {
        case .stopping: "Stopping…"
        case .stillRunning: "Still running"
        case .restarting: PortRestartCopy.restarting
        case .restartFailed: PortRestartCopy.failed
        case .inBrowser: PortBrowser.rowWords
        case .confirm, nil: nil
        }
    }
}

/// What a port's row draws, from values alone: the row, what it says, which of its actions
/// apply, and what each does. `PortRowView` fills it from the app's state; tests draw it in
/// every state without a server.
struct PortRowFace: View {
    struct Offers: Equatable {
        var browse = false
        var restart = false
        var stop = false
    }

    struct Acts {
        var open: () -> Void = {}
        var browse: () -> Void = {}
        var copy: () -> Void = {}
        var show: () -> Void = {}
        var stop: () -> Void = {}
        var restart: () -> Void = {}
        var confirm: () -> Void = {}
        var cancel: () -> Void = {}
    }

    let row: PortRow
    let note: PortActions.Note?
    let offers: Offers
    let acts: Acts
    let dim: Bool
    let theme: TermTheme
    var leading: CGFloat = 16
    @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1
    @Environment(\.dynamicTypeSize) private var typeSize

    /// Where the row's text starts: past the tile.
    private var textLeading: CGFloat { leading + 18 + 9 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: acts.open) { label }
                .buttonStyle(.plain)
                .focusable(interactions: .activate)
                .onKeyPress(.return) { acts.open(); return .handled }
                .contextMenu { PortRowMenu(offers: offers, acts: acts) }
                .modifier(RowAction(name: "Open in Browser", enabled: offers.browse, run: acts.browse))
                .accessibilityAction(named: "Copy Link", acts.copy)
                .accessibilityAction(named: "Show Pane", acts.show)
                .modifier(RowAction(name: "Restart", enabled: offers.restart, run: acts.restart))
                .modifier(StopAction(enabled: offers.stop, stop: acts.stop))
            // A Restart asks in the row itself, never in an alert: the command as it will be
            // typed, one line that says what happens, and one tap.
            if case .confirm(let command) = note {
                RestartQuestion(command: command, theme: theme, confirm: acts.confirm, cancel: acts.cancel)
                    .padding(.leading, textLeading)
                    .padding(.trailing, 16)
                    .padding(.bottom, 8)
            } else if note == .restartFailed {
                Button(action: acts.show) {
                    Text("Show Pane")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.accent)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, textLeading)
                .padding(.bottom, 4)
            }
        }
        .opacity(dim ? 0.45 : 1)
    }

    private var label: some View {
        let title = PortNames.title(row.entry)
        let state = PortRowView.words(note)
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
                // The state follows the address on its line, so a narrow list cuts the state
                // and never the address. At the accessibility sizes the line may wrap, as the
                // title does: one line there cuts the address itself.
                Text([row.entry.name, state].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(theme.chrome.tertiary)
                    .lineLimit(SidebarMetrics.lines(typeSize))
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
}

/// A port row's menu: each item only where it applies, Stop last.
struct PortRowMenu: View {
    let offers: PortRowFace.Offers
    let acts: PortRowFace.Acts

    var body: some View {
        if offers.browse {
            Button(action: acts.browse) { Label("Open in Browser", systemImage: "safari") }
        }
        Button(action: acts.copy) { Label("Copy Link", systemImage: "link") }
        Button(action: acts.show) { Label("Show Pane", systemImage: "terminal") }
        if offers.restart {
            Button(action: acts.restart) { Label("Restart", systemImage: "arrow.clockwise") }
        }
        if offers.stop {
            Button(role: .destructive, action: acts.stop) { Label("Stop", systemImage: "stop.circle") }
        }
    }
}

/// A Restart's question, in the row: "Restart: npm run dev" in the terminal's own kind of type,
/// what that does under it, and one tap. It never says the command is the one typed before.
struct RestartQuestion: View {
    let command: RestartCommand
    let theme: TermTheme
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(PortRestartCopy.confirm(command))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.fg.opacity(0.9))
                .lineLimit(4)
                .truncationMode(.middle)
            Text(PortRestartCopy.detail)
                .font(.caption2)
                .foregroundStyle(theme.chrome.tertiary)
            HStack(spacing: 20) {
                Button(action: confirm) {
                    Text("Restart")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.accent)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
                Button(action: cancel) {
                    Text("Cancel")
                        .font(.caption)
                        .foregroundStyle(theme.chrome.secondary)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// A row's action for VoiceOver, only where the menu offers it.
private struct RowAction: ViewModifier {
    let name: String
    let enabled: Bool
    let run: () -> Void

    func body(content: Content) -> some View {
        if enabled { content.accessibilityAction(named: name, run) } else { content }
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
