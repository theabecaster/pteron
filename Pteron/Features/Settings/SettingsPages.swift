import SwiftUI

// The pages the top level of Settings opens. Each holds what was its section on the one long
// page before, unchanged, plus Appearance's Navigation row. A page title names the page, so a
// section header that would only repeat it is left out; Notifications keeps its own, as its
// screen was (docs/notifications.md).

/// Settings → Computers: the list, with swipe and long-press actions, and Add Computer.
struct ServersPage: View {
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs
    let theme: TermTheme

    static let footer = "Each computer runs Rex. " + PairingCopy.showCode + " Then scan the code."

    var body: some View {
        SettingsList(theme: theme) {
            Section {
                ForEach(model.servers) { s in serverRow(s) }
                NavigationLink(value: SettingsPage.addServer) {
                    Label("Add Computer", systemImage: "plus")
                }
            } footer: {
                SettingsFooter(Self.footer, theme)
                    .accessibilityLabel(PairingCopy.spoken(Self.footer))
            }
            .settingsRows(theme)
        }
        .navigationTitle("Computers")
        .navigationBarTitleDisplayMode(.inline)
        .settingsBar(theme)
    }

    private func serverRow(_ s: ServerConnection) -> some View {
        let saved = prefs.servers.contains { $0.id == s.config.id }
        let remove = {
            prefs.servers.removeAll { $0.id == s.config.id }
            model.rebuildServers()
        }
        return HStack(spacing: 10) {
            ServerDot(server: s, theme: theme)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.config.name).fontWeight(.medium).lineLimit(1)
                Text(URL(string: s.config.url)?.host() ?? s.config.url)
                    .font(.caption)
                    .foregroundStyle(theme.chrome.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            // One line; the name and address truncate first.
            Text(Self.status(s.phase))
                .font(.caption)
                .foregroundStyle(theme.chrome.secondary)
                .lineLimit(1)
                .fixedSize()
                .layoutPriority(1)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .swipeActions {
            if saved {
                Button(role: .destructive, action: remove) { Label("Remove", systemImage: "trash") }
            }
        }
        .contextMenu {
            if s.offersReconnect {
                Button { s.reconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
            }
            if saved {
                Button(role: .destructive, action: remove) { Label("Remove Computer", systemImage: "trash") }
            }
        }
    }

    private static func status(_ p: ServerConnection.Phase) -> String {
        switch p {
        case .online: return "Connected"
        case .connecting, .idle: return "Connecting…"
        case .offline(let p): return OfflineCopy.short(p.kind)
        }
    }
}

/// Settings → Appearance: the two themes, the text size with its preview, and the navigation.
struct AppearancePage: View {
    @Environment(Prefs.self) private var prefs
    let theme: TermTheme

    var body: some View {
        @Bindable var p = prefs
        SettingsList(theme: theme) {
            Section {
                NavigationLink(value: SettingsPage.darkTheme) {
                    LabeledContent("Dark Theme", value: ThemeStore.theme(p.darkThemeID).name)
                }
                NavigationLink(value: SettingsPage.lightTheme) {
                    LabeledContent("Light Theme", value: ThemeStore.theme(p.lightThemeID).name)
                }
                Stepper(value: $p.fontSize, in: Prefs.fontSizes, step: 1) {
                    LabeledContent("Text Size", value: "\(p.fontSize.formatted()) pt")
                }
                .accessibilityValue("\(p.fontSize.formatted()) points")
                Text("~/agents $ claude --resume")
                    .font(Font(RexFont.ui(p.fontSize)))
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(theme.bg))
                    .accessibilityHidden(true)
            } footer: {
                SettingsFooter("Follows Light and Dark Mode. Pinch any pane to change it too.", theme)
            }
            .settingsRows(theme)

            Section {
                Picker(Self.navigationLabel, selection: $p.navigation) {
                    ForEach(NavigationStyle.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                SettingsFooter("Sidebar lists computers, sessions and tabs at the side. Tabs puts the session's tabs in a strip above the pane, as in the Rex app.", theme)
            }
            .settingsRows(theme)
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .settingsBar(theme)
    }

    /// The Navigation row's title, which VoiceOver reads with the chosen style.
    static let navigationLabel = "Navigation"
}

/// Settings → Keyboard: the key bar's Layout and Shortcut Groups, and how the bar works.
struct KeyboardPage: View {
    @Environment(Prefs.self) private var prefs
    let theme: TermTheme

    static let footer = "⌘ opens the command palette. ✎ opens Compose, a text field for writing to the pane. "
        + "Tap ctrl, option or shift, then a key; double-tap to lock it. "
        + "⏎ stays at the end of the bar; hold it for a new line in an agent. "
        + "Drag ✥ to move through menus and history. Swipe the bar for more keys, "
        + "and tap a group's button to pick one of its shortcuts."

    var body: some View {
        let shown = prefs.keyBarSetup.groups.filter(\.shown).map(\.title)
        SettingsList(theme: theme) {
            Section {
                NavigationLink(value: SettingsPage.keyBarLayout) {
                    KeyBarPageRow(title: "Layout", subtitle: "Arrange and hide the built-in keys",
                                  symbol: "rectangle.on.rectangle", theme: theme)
                }
                NavigationLink(value: SettingsPage.shortcutGroups) {
                    KeyBarPageRow(title: "Shortcut Groups", subtitle: shown.isEmpty ? "None" : shown.joined(separator: ", "),
                                  symbol: "square.stack", theme: theme)
                }
            } header: {
                SettingsHeader("Key Bar", theme)
            } footer: {
                SettingsFooter(Self.footer, theme)
            }
            .settingsRows(theme)
        }
        .navigationTitle("Keyboard")
        .navigationBarTitleDisplayMode(.inline)
        .settingsBar(theme)
    }
}

/// Settings → Notifications: the section as it was on the long page, and the `-settingsScroll`
/// places on it.
struct NotificationsPage: View {
    @Environment(AppModel.self) private var model
    let theme: TermTheme

    var body: some View {
        ScrollViewReader { scroller in
            SettingsList(theme: theme) {
                NotificationSettingsSection(theme: theme)
            }
            .task {
                guard let anchor = SettingsAnchor.debugLaunch else { return }
                let push = model.push
                let target = SettingsAnchor.target(anchor, computers: push.master.showsComputers ? push.computers.count : 0)
                // The list lays itself out first, and the sheet arrives. A row the list has not
                // made yet can't be scrolled to, so the scroll is asked for a few times.
                for _ in 0..<6 {
                    try? await Task.sleep(nanoseconds: 400_000_000)
                    scroller.scrollTo(target.id, anchor: target.bottom ? .bottom : .top)
                }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .settingsBar(theme)
    }
}

/// Settings → About: the version, the setup guide again, the licences, and Send Diagnostics.
struct AboutPage: View {
    @Environment(AppModel.self) private var model
    let theme: TermTheme
    /// The file on its way to the share sheet.
    @State private var shared: DiagnosticsShare?
    /// The file is being written: a second tap makes no second one.
    @State private var preparing = false
    /// The task that writes the file, so leaving About ends it.
    @State private var writing: Task<Void, Never>?

    static let diagnosticsFooter = "Shares a text file of connection events and crash reports. "
        + "It has no computer names or addresses, and it stays on this \(DeviceWord.current) unless you share it."

    var body: some View {
        SettingsList(theme: theme) {
            Section {
                LabeledContent("Version", value: SettingsView.version)
                // The first-run checklist again, for another computer or a second look.
                Button("Setup Guide") { model.openGuide() }
                NavigationLink(value: SettingsPage.acknowledgements) { Text("Acknowledgements") }
            }
            .settingsRows(theme)
            // Evidence for a problem after the fact. Nothing is made or sent until this is tapped,
            // and then only the system's share sheet opens: the user picks where it goes.
            Section {
                Button("Send Diagnostics") { sendDiagnostics() }
                    .disabled(preparing)
            } footer: {
                SettingsFooter(Self.diagnosticsFooter, theme)
            }
            .settingsRows(theme)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .settingsBar(theme)
        .sheet(item: $shared, onDismiss: { ConnectionDiagnostics.clearShareFile() }) { file in
            // The share sheet can end by itself (sent, or cancelled inside it): the row is
            // ready again either way, and the file goes with the sheet.
            DiagnosticsShareSheet(file: file.url) { shared = nil }
                .presentationDetents([.medium, .large])
        }
        // Leaving About while the file is being written: nothing is shown later, and nothing stays.
        .onDisappear {
            writing?.cancel()
            writing = nil
            if shared == nil { ConnectionDiagnostics.clearShareFile() }
        }
    }

    private func sendDiagnostics() {
        guard !preparing, shared == nil else { return }
        preparing = true
        let log = model.connectionLog, servers = model.prefs.servers
        writing = Task {
            defer { preparing = false }
            // The reports are files: read, and the shared file written, off the main actor.
            let reports = await Task.detached(priority: .userInitiated) { DiagnosticReports.standard.all() }.value
            let text = await ConnectionDiagnostics.report(log: log, servers: servers, reports: reports,
                                                          version: SettingsView.version)
            let written = await Task.detached(priority: .userInitiated) { try? ConnectionDiagnostics.writeShareFile(text) }.value
            // About was left meanwhile: no sheet shows later, and no file stays.
            if Task.isCancelled {
                ConnectionDiagnostics.clearShareFile()
                return
            }
            guard let url = written else {
                Notice.shared.show("Couldn't write the diagnostics file.")
                return
            }
            shared = DiagnosticsShare(url: url)
        }
    }
}

/// The diagnostics file, for the sheet that shares it.
struct DiagnosticsShare: Identifiable {
    let id = UUID()
    let url: URL
}

/// The system's share sheet with the diagnostics file.
private struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let file: URL
    /// The share sheet is over, sent or not.
    let done: @MainActor () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in
            Task { @MainActor in done() }
        }
        return sheet
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
