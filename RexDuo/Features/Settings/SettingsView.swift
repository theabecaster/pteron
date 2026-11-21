import SwiftUI

/// The pages under Settings. The top level lists five, each with its current value; the rest sit
/// one level under one of them.
enum SettingsPage: String, Hashable, CaseIterable {
    case main
    case servers, appearance, keyboard, notifications, about
    case addServer, darkTheme, lightTheme, acknowledgements

    /// The top level's rows, in order.
    static let topLevel: [SettingsPage] = [.servers, .appearance, .keyboard, .notifications, .about]

    /// The top-level page this one opens from; nil for the top level and its own rows.
    var parent: SettingsPage? {
        switch self {
        case .addServer: .servers
        case .darkTheme, .lightTheme: .appearance
        case .acknowledgements: .about
        default: nil
        }
    }

    /// The navigation path that shows this page, so Back leads where a tap would have come from:
    /// Add Server goes back to Computers, a theme to Appearance.
    var path: [SettingsPage] {
        guard self != .main else { return [] }
        return (parent.map { [$0] } ?? []) + [self]
    }

    /// The page a launch opens at: `-settingsScroll` names a place on the Notifications page, so it
    /// opens that page when `-settings` asks for the top level.
    static func launch(page: SettingsPage?, anchor: String?) -> SettingsPage? {
        guard let page else { return nil }
        return anchor != nil && page == .main ? SettingsAnchor.page : page
    }

    /// `-settings <page>` (Debug builds): open Settings at that page at launch. The pages are
    /// `main`, `servers`, `appearance`, `keyboard`, `notifications`, `about`, `addServer`,
    /// `darkTheme`, `lightTheme` and `acknowledgements`.
    static var debugLaunch: SettingsPage? {
        #if DEBUG
        launch(page: UserDefaults.standard.string(forKey: "settings").flatMap(SettingsPage.init(rawValue:)),
               anchor: SettingsAnchor.debugLaunch)
        #else
        nil
        #endif
    }
}

/// Places on the Notifications page that `-settingsScroll` can bring into view.
enum SettingsAnchor {
    /// The page every anchor is on.
    static let page = SettingsPage.notifications
    static let notifications = "notifications"
    static func computer(_ index: Int) -> String { "notifications.\(index)" }
    static let end = "end"

    /// The row to scroll to for an anchor, and whether it goes to the bottom of the screen: `end`
    /// is the last computer's row, or the master switch's when no computer is listed.
    static func target(_ anchor: String, computers: Int) -> (id: String, bottom: Bool) {
        guard anchor == end else { return (anchor, false) }
        return (computers > 0 ? computer(computers - 1) : notifications, true)
    }

    /// `-settingsScroll notifications|notifications.<n>|end` (Debug builds): open the
    /// Notifications page scrolled to the master switch, to its n-th computer (from 0), or to the
    /// end of the page.
    static var debugLaunch: String? {
        #if DEBUG
        UserDefaults.standard.string(forKey: "settingsScroll")
        #else
        nil
        #endif
    }
}

/// What the top level shows beside each row.
enum SettingsSummary {
    static func servers(total: Int, connected: Int) -> String {
        if total == 0 { return "None" }
        return connected == total ? "\(total) connected" : "\(connected) of \(total) connected"
    }

    static func appearance(theme: String, fontSize: Double) -> String {
        "\(theme) · \(fontSize.formatted()) pt"
    }

    /// The same, as VoiceOver says it.
    static func appearanceSpoken(theme: String, fontSize: Double) -> String {
        "\(theme), \(fontSize.formatted()) points"
    }

    static func notifications(on: Bool) -> String { on ? "On" : "Off" }
}

/// Settings: only what a user would want to change. `Prefs` decides the rest.
/// Styled like the sidebar, from the theme's chrome; the controls are the standard ones.
/// The top level is one short list, one row per page with that page's current value; each page
/// is built only when it is opened.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @State private var path = SettingsPage.debugLaunch?.path ?? []

    var body: some View {
        @Bindable var p = prefs
        let theme = prefs.theme
        NavigationStack(path: $path) {
            SettingsTopLevel(theme: theme)
                .navigationDestination(for: SettingsPage.self) { page in
                    switch page {
                    case .main: EmptyView()
                    case .servers: ServersPage(theme: theme)
                    case .appearance: AppearancePage(theme: theme)
                    case .keyboard: KeyboardPage(theme: theme)
                    case .notifications: NotificationsPage(theme: theme)
                    case .about: AboutPage(theme: theme)
                    case .addServer: AddServerView(theme: theme)
                    case .darkTheme: ThemePicker(title: "Dark Theme", selection: $p.darkThemeID, dark: true, theme: theme)
                    case .lightTheme: ThemePicker(title: "Light Theme", selection: $p.lightThemeID, dark: false, theme: theme)
                    case .acknowledgements: AcknowledgementsView()
                    }
                }
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .settingsBar(theme)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
        }
        .tint(theme.accent)
        .preferredColorScheme(theme.isDark ? .dark : .light)
        .onAppear {
            if let page = model.settingsStart {
                model.settingsStart = nil
                path = page.path
            }
        }
    }

    static func keyLabel(_ k: String) -> String {
        let names = ["left": "←", "right": "→", "up": "↑", "down": "↓", "paste": "Paste", "attach": "Attach", "enter": "⏎",
                     "tab": "⇥", "shift-tab": "⇧⇥", "arrows": "✥"]
        return names[k] ?? KeyBar.titles[k] ?? k
    }

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? short : "\(short) (\(build))"
    }
}

/// The top level: one row per page, with what is set there. It reads only the values it shows.
struct SettingsTopLevel: View {
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs
    let theme: TermTheme

    var body: some View {
        let servers = model.servers
        let connected = servers.filter { $0.phase == .online }.count
        let current = prefs.theme
        SettingsList(theme: theme) {
            Section {
                row(.servers, "Computers", "desktopcomputer",
                    value: SettingsSummary.servers(total: servers.count, connected: connected))
                row(.appearance, "Appearance", "textformat.size",
                    value: SettingsSummary.appearance(theme: current.name, fontSize: prefs.fontSize),
                    spoken: SettingsSummary.appearanceSpoken(theme: current.name, fontSize: prefs.fontSize))
                row(.keyboard, "Keyboard", "keyboard", value: prefs.keyBarLayout.title)
                row(.notifications, "Notifications", "bell",
                    value: SettingsSummary.notifications(on: model.push.master.switchOn))
            }
            .settingsRows(theme)

            Section {
                row(.about, "About", "info.circle", value: nil)
            }
            .settingsRows(theme)
        }
    }

    private func row(_ page: SettingsPage, _ title: String, _ symbol: String, value: String?,
                     spoken: String? = nil) -> some View {
        NavigationLink(value: page) {
            LabeledContent {
                if let value { Text(value).lineLimit(1) }
            } label: {
                Label(title, systemImage: symbol)
            }
        }
        .accessibilityValue(spoken ?? value ?? "")
    }
}

/// The sidebar's status mark for a server: a dot when connected, a spinner while connecting.
struct ServerDot: View {
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
                        // The row says the status in words.
                        .accessibilityHidden(true)
                }
            }
        }
        .frame(width: 16)
    }
}

/// Add a server: scan its pairing code, or type its address. The name is optional.
struct AddServerView: View {
    let theme: TermTheme
    @Environment(AppModel.self) private var model
    @Environment(Prefs.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var name = ""
    @State private var showPairing = AddServerView.debugScan
    @FocusState private var addressFocused: Bool

    /// `-simulateScan <payload>` with `-settings addServer` (testing): scan from this page.
    private static var debugScan: Bool {
        #if DEBUG
        UserDefaults.standard.string(forKey: "simulateScan") != nil
        #else
        false
        #endif
    }

    var body: some View {
        let url = ServerConfig.url(from: address)
        SettingsList(theme: theme) {
            Section {
                Button { showPairing = true } label: {
                    Label("Pair via QR Code", systemImage: "qrcode.viewfinder")
                }
            } footer: {
                SettingsFooter("On your computer, run `rex server tailscale pair`, then scan the code it shows.", theme)
            }
            .settingsRows(theme)

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
                SettingsHeader("Or Enter Its Address", theme)
            } footer: {
                SettingsFooter("This iPhone needs to be on the same private network as the computer.", theme)
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
        .pairingCover(isPresented: $showPairing, model: model) { addressFocused = true }
    }

    private func add(_ url: URL) {
        let n = name.trimmingCharacters(in: .whitespaces)
        prefs.servers.append(ServerConfig(name: n.isEmpty ? ServerConfig.name(for: url) : n, url: url.absoluteString))
        model.rebuildServers()
        model.closeGuide()
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
    /// Keeps a Settings list from scrolling under the navigation bar. A list that touches the
    /// top of the safe area extends under the bar, and its rows and section headers then show
    /// through the clear bar, blurred, behind the title. One point of padding ends the list at
    /// the bar's lower edge; the page's colour fills the bar behind it, as it did before. An
    /// opaque bar (`toolbarBackground`) is not used: the bar then vanishes while a sheet is up
    /// over the page.
    func settingsBar(_ theme: TermTheme) -> some View {
        padding(.top, 1)
            .background(theme.chrome.sidebar.ignoresSafeArea())
    }

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
