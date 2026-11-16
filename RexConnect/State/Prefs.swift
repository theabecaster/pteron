import SwiftUI

enum SizingMode: String, CaseIterable, Identifiable {
    case fit     // claim the pane and resize it to the phone while viewing
    case mirror  // keep the Mac's size; zoom and pan
    var id: String { rawValue }
    var title: String { self == .fit ? "Fit to phone" : "Mirror Mac size" }
    var detail: String {
        self == .fit
            ? "While you view a pane, Rex Connect owns it and resizes it to fit this screen. Leaving the pane hands it back to the Mac."
            : "Panes keep the size the Mac gave them. Pinch to zoom, drag to pan."
    }
}

enum WideLayout: String, CaseIterable, Identifiable {
    case auto, splits, single
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .splits: return "Always show splits"
        case .single: return "One pane at a time"
        }
    }
}

/// Ready-made key bar layouts. "arrows" is the drag-to-move trackpad key.
enum KeyBarPreset: String, CaseIterable, Identifiable {
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
    /// The preset this exact layout matches, if any.
    static func matching(_ keys: [String]) -> KeyBarPreset? { allCases.first { $0.keys == keys } }
}

struct ServerConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: String
}

/// User preferences. Stored in UserDefaults.
///
/// SwiftUI views read the app's instance from the environment (`@Environment(Prefs.self)`) and
/// state types get it in `init`. `shared` is that same instance, for the few places SwiftUI
/// doesn't reach: the UIKit key bar and terminal host, and the static `Haptic` helper.
@MainActor
@Observable
final class Prefs {
    static let shared = Prefs()
    @ObservationIgnored private let d: UserDefaults

    var themeID: String { didSet { d.set(themeID, forKey: "themeID") } }
    var lightThemeID: String { didSet { d.set(lightThemeID, forKey: "lightThemeID") } }
    var followSystemAppearance: Bool { didSet { d.set(followSystemAppearance, forKey: "followSystem") } }
    var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize") } }
    var sizing: SizingMode { didSet { d.set(sizing.rawValue, forKey: "sizing") } }
    var wideLayout: WideLayout { didSet { d.set(wideLayout.rawValue, forKey: "wideLayout") } }
    /// The engine panes are made with. Changing it recreates the open panes (see PaneView).
    var terminalEngine: TerminalEngineKind {
        didSet { if terminalEngine != oldValue { TerminalEngineKind.current = terminalEngine } }
    }
    var keyBar: [String] {
        didSet {
            d.set(keyBar, forKey: "keyBar")
            NotificationCenter.default.post(name: .keyBarChanged, object: nil)
        }
    }
    var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
    var showAgentStatus: Bool { didSet { d.set(showAgentStatus, forKey: "showAgentStatus") } }
    var notifyOnBlocked: Bool { didSet { d.set(notifyOnBlocked, forKey: "notifyOnBlocked") } }
    var sidebarTextSize: Double { didSet { d.set(sidebarTextSize, forKey: "sidebarTextSize") } }
    var servers: [ServerConfig] {
        didSet { if let data = try? JSONEncoder().encode(servers) { d.set(data, forKey: "servers") } }
    }
    var hostURLs: [String: String] { didSet { d.set(hostURLs, forKey: "hostURLs") } }

    /// Fresh installs start with the Agents layout.
    static var defaultKeyBar: [String] { KeyBarPreset.agents.keys }
    static let allKeys = ["esc", "tab", "shift-tab", "enter", "ctrl", "alt", "arrows", "left", "up", "down", "right",
                          "home", "end", "pgup", "pgdn", "paste",
                          "ctrl-c", "ctrl-d", "ctrl-z", "ctrl-r", "ctrl-l", "ctrl-a", "ctrl-e", "ctrl-u", "ctrl-w", "ctrl-o",
                          "1", "2", "3", "y", "n",
                          "|", "~", "/", "\\", "-", "_", "`", "*", "$", "&", ";", ":", "\"", "'", "<", ">",
                          "[", "]", "{", "}", "(", ")",
                          "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12"]

    /// Tests pass `UserDefaults(suiteName:)` to stay isolated.
    init(defaults: UserDefaults = .standard) {
        let d = defaults
        self.d = d
        themeID = d.string(forKey: "themeID") ?? "github-dark-dimmed"
        lightThemeID = d.string(forKey: "lightThemeID") ?? "github-light-default"
        followSystemAppearance = d.object(forKey: "followSystem") as? Bool ?? false
        fontSize = d.object(forKey: "fontSize") as? Double ?? 11
        sizing = SizingMode(rawValue: d.string(forKey: "sizing") ?? "") ?? .fit
        wideLayout = WideLayout(rawValue: d.string(forKey: "wideLayout") ?? "") ?? .auto
        terminalEngine = TerminalEngineKind.current
        keyBar = d.stringArray(forKey: "keyBar") ?? Prefs.defaultKeyBar
        haptics = d.object(forKey: "haptics") as? Bool ?? true
        showAgentStatus = d.object(forKey: "showAgentStatus") as? Bool ?? true
        notifyOnBlocked = d.object(forKey: "notifyOnBlocked") as? Bool ?? true
        sidebarTextSize = d.object(forKey: "sidebarTextSize") as? Double ?? 14
        hostURLs = d.dictionary(forKey: "hostURLs") as? [String: String] ?? [:]
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

    /// The terminal theme for the system appearance: the light theme only when following the
    /// system and it's light.
    func theme(for scheme: ColorScheme) -> TermTheme {
        if followSystemAppearance && scheme == .light { return ThemeStore.theme(lightThemeID) }
        return ThemeStore.theme(themeID)
    }
}
