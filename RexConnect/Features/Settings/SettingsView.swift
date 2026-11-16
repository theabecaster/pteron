import SwiftUI

/// The pages under Settings.
enum SettingsPage: String, Hashable {
    case main, addServer, darkTheme, lightTheme, acknowledgements

    /// `-settings main|addServer|darkTheme|lightTheme|acknowledgements` (Debug builds): open Settings at that page
    /// at launch.
    static var debugLaunch: SettingsPage? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "settings").flatMap(SettingsPage.init(rawValue:))
        #else
        nil
        #endif
    }
}

/// Settings: only what a user would want to change. `Prefs` decides the rest.
/// Styled like the sidebar, from the theme's chrome; the controls are the standard ones.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @State private var path = SettingsPage.debugLaunch.map { $0 == .main ? [] : [$0] } ?? []

    var body: some View {
        @Bindable var p = prefs
        let theme = prefs.theme
        NavigationStack(path: $path) {
            SettingsList(theme: theme) {
                Section {
                    ForEach(model.servers) { s in serverRow(s, theme) }
                    NavigationLink(value: SettingsPage.addServer) {
                        Label("Add Server", systemImage: "plus")
                    }
                } header: {
                    SettingsHeader("Servers", theme)
                } footer: {
                    SettingsFooter("A server is a Mac running Rex. Run `rex server tailscale enable` on it, then add the address it shows.", theme)
                }
                .settingsRows(theme)

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
                } header: {
                    SettingsHeader("Appearance", theme)
                } footer: {
                    SettingsFooter("Follows Light and Dark Mode. Pinch a pane to change the text size there.", theme)
                }
                .settingsRows(theme)

                Section {
                    Picker("Layout", selection: $p.keyBarLayout) {
                        ForEach(KeyBarLayout.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    SettingsHeader("Key Bar", theme)
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(p.keyBar.map(Self.keyLabel).joined(separator: "  "))
                            .font(Font(RexFont.ui(12)))
                            .foregroundStyle(theme.chrome.secondary)
                            .accessibilityHidden(true)
                        SettingsFooter("Hold an arrow to repeat it. Drag ✥ to move through menus and history. Tap ctrl or alt for the next key; double-tap to lock it.", theme)
                    }
                }
                .settingsRows(theme)

                NotificationSettingsSection(theme: theme)

                Section {
                    LabeledContent("Version", value: Self.version)
                    NavigationLink(value: SettingsPage.acknowledgements) { Text("Acknowledgements") }
                } header: {
                    SettingsHeader("About", theme)
                }
                .settingsRows(theme)
            }
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .main: EmptyView()
                case .addServer: AddServerView(theme: theme)
                case .darkTheme: ThemePicker(title: "Dark Theme", selection: $p.darkThemeID, dark: true, theme: theme)
                case .lightTheme: ThemePicker(title: "Light Theme", selection: $p.lightThemeID, dark: false, theme: theme)
                case .acknowledgements: AcknowledgementsView()
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .tint(theme.accent)
        .preferredColorScheme(theme.isDark ? .dark : .light)
    }

    private func serverRow(_ s: ServerConnection, _ theme: TermTheme) -> some View {
        let saved = prefs.servers.contains { $0.id == s.config.id }
        let remove = {
            prefs.servers.removeAll { $0.id == s.config.id }
            model.rebuildServers()
        }
        return HStack(spacing: 10) {
            ServerDot(server: s, theme: theme)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.config.name).fontWeight(.medium)
                Text(URL(string: s.config.url)?.host() ?? s.config.url)
                    .font(.caption)
                    .foregroundStyle(theme.chrome.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(Self.status(s.phase))
                .font(.caption)
                .foregroundStyle(theme.chrome.secondary)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .swipeActions {
            if saved {
                Button(role: .destructive, action: remove) { Label("Remove", systemImage: "trash") }
            }
        }
        .contextMenu {
            Button { s.reconnect() } label: { Label("Reconnect", systemImage: "arrow.clockwise") }
            if saved {
                Button(role: .destructive, action: remove) { Label("Remove Server", systemImage: "trash") }
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

    static func keyLabel(_ k: String) -> String {
        let names = ["left": "←", "right": "→", "up": "↑", "down": "↓", "paste": "Paste", "enter": "⏎",
                     "tab": "⇥", "shift-tab": "⇤", "arrows": "✥"]
        return names[k] ?? KeyBar.titles[k] ?? k
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }
}

/// The sidebar's status mark for a server: a dot when connected, a spinner while connecting.
private struct ServerDot: View {
    let server: ServerConnection
    let theme: TermTheme

    var body: some View {
        Group {
            switch server.phase {
            case .online: Circle().fill(theme.chrome.done).frame(width: 7, height: 7)
            case .connecting, .idle: ProgressView().controlSize(.mini)
            case .offline:
                if server.retrying {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(theme.chrome.tertiary)
                }
            }
        }
        .frame(width: 16)
    }
}

/// Add a server by its Tailscale address. The name is optional.
struct AddServerView: View {
    let theme: TermTheme
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        let url = ServerConfig.url(from: address)
        SettingsList(theme: theme) {
            Section {
                TextField("Address", text: $address, prompt: Text(verbatim: "studio.your-tailnet.ts.net"))
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textContentType(.URL)
                    .focused($addressFocused)
                    .submitLabel(.done)
                    .onSubmit { if let url { add(url) } }
                TextField("Name", text: $name, prompt: Text(url.map(ServerConfig.name) ?? "Name (optional)"))
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onSubmit { if let url { add(url) } }
            } header: {
                SettingsHeader("Address", theme)
            } footer: {
                SettingsFooter("On the Mac, run `rex server tailscale enable` and copy the address it shows. This iPhone needs Tailscale, signed in to the same account.", theme)
            }
            .settingsRows(theme)
        }
        .navigationTitle("Add Server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") { if let url { add(url) } }
                    .disabled(url == nil)
            }
        }
        .onAppear { addressFocused = true }
    }

    private func add(_ url: URL) {
        let n = name.trimmingCharacters(in: .whitespaces)
        prefs.servers.append(ServerConfig(name: n.isEmpty ? ServerConfig.name(for: url) : n, url: url.absoluteString))
        model.rebuildServers()
        dismiss()
    }
}

/// Every theme as a swatch, the mode's own themes first.
struct ThemePicker: View {
    let title: String
    @Binding var selection: String
    /// Picking for Dark Mode: dark themes come first.
    let dark: Bool
    let theme: TermTheme

    var body: some View {
        let own = ThemeStore.all.filter { $0.isDark == dark }
        let other = ThemeStore.all.filter { $0.isDark != dark }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                group(dark ? "Dark" : "Light", own)
                group(dark ? "Light" : "Dark", other)
            }
            .padding(16)
        }
        .background(theme.chrome.sidebar.ignoresSafeArea())
        .foregroundStyle(theme.fg)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func group(_ name: String, _ themes: [TermTheme]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsHeader(name, theme)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 12)], spacing: 12) {
                ForEach(themes) { swatch($0) }
            }
        }
    }

    private func swatch(_ t: TermTheme) -> some View {
        let on = selection == t.id
        return Button { selection = t.id } label: {
            VStack(alignment: .leading, spacing: 6) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 0) {
                        Text("~ ").foregroundStyle(t.ansiColor(2))
                        Text("git ").foregroundStyle(t.fg)
                        Text("status").foregroundStyle(t.ansiColor(4))
                    }
                    HStack(spacing: 3) {
                        ForEach(1..<7) { i in RoundedRectangle(cornerRadius: 2).fill(t.ansiColor(i)).frame(width: 12, height: 8) }
                    }
                }
                .font(Font(RexFont.ui(11)))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(t.bg))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(on ? theme.accent : theme.chrome.divider, lineWidth: on ? 2 : 1))
                HStack(spacing: 4) {
                    Text(t.name).font(.caption).lineLimit(1)
                    if on { Image(systemName: "checkmark").font(.caption2.weight(.bold)).foregroundStyle(theme.accent) }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(t.name)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: Styling

/// A settings list in the sidebar's look: the theme's chrome behind grouped rows of sidebar density.
struct SettingsList<Content: View>: View {
    let theme: TermTheme
    @ViewBuilder var content: Content

    var body: some View {
        List { content }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(theme.chrome.sidebar.ignoresSafeArea())
            .environment(\.defaultMinListRowHeight, 44)
            .listSectionSpacing(.compact)
            .font(.subheadline)
            .foregroundStyle(theme.fg)
    }
}

/// A section title in the sidebar's session-header style.
struct SettingsHeader: View {
    let text: String
    let theme: TermTheme
    init(_ text: String, _ theme: TermTheme) { self.text = text; self.theme = theme }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.chrome.secondary)
            .textCase(nil)
    }
}

struct SettingsFooter: View {
    let text: String
    let theme: TermTheme
    init(_ text: String, _ theme: TermTheme) { self.text = text; self.theme = theme }

    var body: some View {
        Text(LocalizedStringKey(text))
            .font(.caption)
            .foregroundStyle(theme.chrome.secondary)
    }
}

extension View {
    /// Row cards tinted from the theme, like the sidebar's agents row, with theme dividers.
    func settingsRows(_ theme: TermTheme) -> some View {
        listRowBackground(theme.fg.opacity(theme.isDark ? 0.06 : 0.05))
            .listRowSeparatorTint(theme.chrome.divider)
    }
}

/// The licences of the open source code linked into the app (`Resources/Acknowledgements.txt`).
/// Their terms require the notices to ship with the binary.
struct AcknowledgementsView: View {
    private let text = Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Acknowledgements")
        .navigationBarTitleDisplayMode(.inline)
    }
}
