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

    var body: some View {
        SettingsList(theme: theme) {
            Section {
                ForEach(model.servers) { s in serverRow(s) }
                NavigationLink(value: SettingsPage.addServer) {
                    Label("Add Computer", systemImage: "plus")
                }
            } footer: {
                SettingsFooter("Run `rex server tailscale pair` on a computer running Rex, then scan the code it shows.", theme)
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

            if NavigationStyle.isAvailable {
            Section {
                Picker(Self.navigationLabel, selection: $p.navigation) {
                    ForEach(NavigationStyle.allCases) { Text($0.title).tag($0) }
                }
            } footer: {
                SettingsFooter("Sidebar lists computers, sessions and tabs at the side. Tabs puts the session's tabs in a strip above the pane, as in the Rex app.", theme)
            }
            .settingsRows(theme)
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .settingsBar(theme)
    }

    /// The Navigation row's title, which VoiceOver reads with the chosen style.
    static let navigationLabel = "Navigation"
}

/// Settings → Keyboard: the key bar's layout, with its keys and how they work under it.
struct KeyboardPage: View {
    @Environment(Prefs.self) private var prefs
    let theme: TermTheme

    var body: some View {
        @Bindable var p = prefs
        SettingsList(theme: theme) {
            Section {
                Picker("Layout", selection: $p.keyBarLayout) {
                    ForEach(KeyBarLayout.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                SettingsHeader("Key Bar", theme)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text((p.keyBar + KeyBarLayout.pinned).map(SettingsView.keyLabel).joined(separator: "  "))
                        .font(Font(RexFont.ui(12)))
                        .foregroundStyle(theme.chrome.secondary)
                        .accessibilityHidden(true)
                    SettingsFooter("⏎ stays at the end of the bar; hold it for a new line in an agent. Hold an arrow to repeat it. Drag ✥ to move through menus and history. Tap ctrl, alt or cmd for the next key; double-tap to lock it. cmd runs Rex's shortcuts: cmd then t opens a tab.", theme)
                }
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

/// Settings → About: the version, the setup guide again, and the licences.
struct AboutPage: View {
    @Environment(AppModel.self) private var model
    let theme: TermTheme

    var body: some View {
        SettingsList(theme: theme) {
            Section {
                LabeledContent("Version", value: SettingsView.version)
                // The first-run checklist again, for another computer or a second look.
                Button("Setup Guide") { model.openGuide() }
                NavigationLink(value: SettingsPage.acknowledgements) { Text("Acknowledgements") }
            }
            .settingsRows(theme)
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .settingsBar(theme)
    }
}
