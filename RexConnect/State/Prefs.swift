import SwiftUI
import UIKit

enum SizingMode: String {
    case fit     // claim the pane and resize it to the phone while viewing
    case mirror  // keep the Mac's size; zoom and pan
}

/// The key bar's layouts. "arrows" is the drag-to-move trackpad key.
enum KeyBarLayout: String, CaseIterable, Identifiable {
    case agents, shell, vim
    var id: String { rawValue }
    var title: String {
        switch self {
        case .agents: return "Agents"
        case .shell: return "Shell"
        case .vim: return "Vim"
        }
    }
    var keys: [String] {
        switch self {
        case .agents:
            return ["esc", "shift-tab", "tab", "arrows", "up", "down", "enter", "ctrl-c", "1", "2", "3", "ctrl", "paste"]
        case .shell:
            return ["esc", "tab", "ctrl", "alt", "arrows", "up", "down", "left", "right", "ctrl-r", "ctrl-c",
                    "|", "~", "/", "-", "paste"]
        case .vim:
            return ["esc", ":", "ctrl", "arrows", "/", "ctrl-d", "ctrl-u", "ctrl-r", "ctrl-w", "pgup", "pgdn",
                    "$", "~", "paste"]
        }
    }
}

struct ServerConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: String

    /// A server address as the user typed it, as a URL: https unless they wrote http://. Nil when
    /// there is no host.
    static func url(from typed: String) -> URL? {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.contains(" ") else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let u = URL(string: s), u.scheme == "https" || u.scheme == "http",
              let host = u.host(), !host.isEmpty else { return nil }
        return u
    }

    /// A name for a server added without one: the address's first label, so
    /// `studio.tail1234.ts.net` is "studio". An IP address stays whole.
    static func name(for url: URL) -> String {
        guard let host = url.host(), !host.isEmpty else { return "Rex" }
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) { return host }
        return host.split(separator: ".").first.map(String.init) ?? host
    }
}

/// User preferences. Stored in UserDefaults.
///
/// Settings shows only what a user would want to change and would understand: servers, a theme for
/// Light and for Dark Mode, text size, the key bar layout and notifications. Everything else is
/// decided under "Fixed choices" and isn't saved.
///
/// SwiftUI views read the app's instance from the environment (`@Environment(Prefs.self)`) and
/// state types get it in `init`. `shared` is that same instance, for the few places SwiftUI
/// doesn't reach: the UIKit key bar and terminal host.
@MainActor
@Observable
final class Prefs {
    static let shared = Prefs()
    @ObservationIgnored private let d: UserDefaults

    // MARK: Settings

    /// The theme in Dark Mode. Its key predates the light theme.
    var darkThemeID: String { didSet { d.set(darkThemeID, forKey: "themeID") } }
    var lightThemeID: String { didSet { d.set(lightThemeID, forKey: "lightThemeID") } }
    var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize") } }
    var keyBarLayout: KeyBarLayout {
        didSet {
            d.set(keyBarLayout.rawValue, forKey: "keyBarLayout")
            NotificationCenter.default.post(name: .keyBarChanged, object: nil)
        }
    }
    /// Push notifications through Rex Connect Helper. Off until the user turns them on.
    var pushEnabled: Bool { didSet { d.set(pushEnabled, forKey: "pushEnabled") } }
    var servers: [ServerConfig] {
        didSet { if let data = try? JSONEncoder().encode(servers) { d.set(data, forKey: "servers") } }
    }

    // MARK: Remembered state

    /// The user answered the "Get notified" card (Turn On or Not now); it never shows again.
    var pushPromptDismissed: Bool { didSet { d.set(pushPromptDismissed, forKey: "pushPromptDismissed") } }
    /// The sidebar's width per posture, keyed by `SidebarWidth.key`.
    var sidebarWidths: [String: Double] { didSet { d.set(sidebarWidths, forKey: "sidebarWidths") } }
    /// The tab open when the app last ran.
    var lastSelection: Selection? {
        didSet { d.set(lastSelection.flatMap { try? JSONEncoder().encode($0) }, forKey: "lastSelection") }
    }
    /// The system's Light or Dark Mode, which `RexConnectApp` reads each time the app becomes active.
    /// Views can't read it from the environment: the root forces the app's scheme to the theme's own.
    var systemScheme: ColorScheme

    // MARK: Fixed choices

    /// Panes always fit the phone. `-sizing mirror` (launch argument) keeps the Mac's size for one
    /// run, for checks that must not resize real panes.
    let sizing: SizingMode
    static let defaultDarkTheme = "github-dark-dimmed"
    static let defaultLightTheme = "github-light-default"
    static let defaultFontSize = 11.0
    static let fontSizes = 7.0...20.0
    static let defaultKeyBar = KeyBarLayout.agents
    // Also decided for the user, where they're used: a tab shows its splits whenever every pane stays
    // legible (`WindowScreen.splitsFit`); agent status always shows in the sidebar; haptics follow
    // iOS's System Haptics; in-app banners for waiting agents are always on; sidebar text follows
    // Dynamic Type.

    /// The key bar's keys.
    var keyBar: [String] { keyBarLayout.keys }

    /// Tests pass `UserDefaults(suiteName:)` to stay isolated.
    init(defaults: UserDefaults = .standard) {
        let d = defaults
        self.d = d
        Self.migrate(d)
        darkThemeID = d.string(forKey: "themeID") ?? Self.defaultDarkTheme
        lightThemeID = d.string(forKey: "lightThemeID") ?? Self.defaultLightTheme
        fontSize = d.object(forKey: "fontSize") as? Double ?? Self.defaultFontSize
        keyBarLayout = KeyBarLayout(rawValue: d.string(forKey: "keyBarLayout") ?? "") ?? Self.defaultKeyBar
        pushEnabled = d.bool(forKey: "pushEnabled")
        pushPromptDismissed = d.bool(forKey: "pushPromptDismissed")
        sidebarWidths = d.dictionary(forKey: "sidebarWidths") as? [String: Double] ?? [:]
        lastSelection = d.data(forKey: "lastSelection").flatMap { try? JSONDecoder().decode(Selection.self, from: $0) }
        systemScheme = UITraitCollection.current.userInterfaceStyle == .light ? .light : .dark
        // Only the launch argument is left: `migrate` cleared the saved setting.
        sizing = d.string(forKey: "sizing") == SizingMode.mirror.rawValue ? .mirror : .fit
        if let data = d.data(forKey: "servers"), let s = try? JSONDecoder().decode([ServerConfig].self, from: data), !s.isEmpty {
            servers = s
        } else {
            #if DEBUG
            // The developer's Mac, so a fresh simulator connects without setup. Release builds go
            // to other people and start empty.
            servers = [ServerConfig(name: "This Mac", url: "https://macbook-pro-rex.tail8657d0.ts.net")]
            #else
            servers = []
            #endif
        }
    }

    /// Carries removed settings over to what they mean now, then clears their keys.
    private static func migrate(_ d: UserDefaults) {
        // One theme in both modes stays one theme in both modes.
        if d.object(forKey: "followSystem") as? Bool == false, let dark = d.string(forKey: "themeID") {
            d.set(dark, forKey: "lightThemeID")
        }
        // An edited key bar becomes the layout it matches, or the default.
        if let keys = d.stringArray(forKey: "keyBar"), d.string(forKey: "keyBarLayout") == nil {
            d.set((KeyBarLayout.allCases.first { $0.keys == keys } ?? defaultKeyBar).rawValue, forKey: "keyBarLayout")
        }
        // Servers saved by host name join the server list, under the ids they had.
        if let hosts = d.dictionary(forKey: "hostURLs") as? [String: String], !hosts.isEmpty {
            var list = d.data(forKey: "servers").flatMap { try? JSONDecoder().decode([ServerConfig].self, from: $0) } ?? []
            for (name, url) in hosts.sorted(by: { $0.key < $1.key })
            where !url.isEmpty && !list.contains(where: { $0.name == name }) {
                list.append(ServerConfig(id: AppModel.stableID(name), name: name, url: url))
            }
            if let data = try? JSONEncoder().encode(list) { d.set(data, forKey: "servers") }
        }
        for key in ["followSystem", "keyBar", "hostURLs", "sizing", "wideLayout", "haptics", "showAgentStatus",
                    "notifyOnBlocked", "sidebarTextSize"] {
            d.removeObject(forKey: key)
        }
    }

    /// The terminal theme for the system's Light or Dark Mode.
    var theme: TermTheme { ThemeStore.theme(systemScheme == .light ? lightThemeID : darkThemeID) }

    /// The same as `theme`. Callers pass their view's color scheme, which the root forces to the
    /// theme's own, so it can't tell which mode the system is in.
    func theme(for _: ColorScheme) -> TermTheme { theme }
}
