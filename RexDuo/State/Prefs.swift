import SwiftUI

enum SizingMode: String, CaseIterable, Identifiable {
    case fit     // claim the pane and resize it to the phone while viewing
    case mirror  // keep the Mac's size; zoom and pan
    var id: String { rawValue }
    var title: String { self == .fit ? "Fit to phone" : "Mirror Mac size" }
    var detail: String {
        self == .fit
            ? "While you view a pane, Rex Duo owns it and resizes it to fit this screen. Leaving the pane hands it back to the Mac."
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

struct ServerConfig: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: String
}

/// User preferences. Stored in UserDefaults.
@MainActor
@Observable
final class Prefs {
    static let shared = Prefs()
    private let d = UserDefaults.standard

    var themeID: String { didSet { d.set(themeID, forKey: "themeID") } }
    var lightThemeID: String { didSet { d.set(lightThemeID, forKey: "lightThemeID") } }
    var followSystemAppearance: Bool { didSet { d.set(followSystemAppearance, forKey: "followSystem") } }
    var fontSize: Double { didSet { d.set(fontSize, forKey: "fontSize") } }
    var sizing: SizingMode { didSet { d.set(sizing.rawValue, forKey: "sizing") } }
    var wideLayout: WideLayout { didSet { d.set(wideLayout.rawValue, forKey: "wideLayout") } }
    var keyBar: [String] { didSet { d.set(keyBar, forKey: "keyBar") } }
    var haptics: Bool { didSet { d.set(haptics, forKey: "haptics") } }
    var showAgentStatus: Bool { didSet { d.set(showAgentStatus, forKey: "showAgentStatus") } }
    var notifyOnBlocked: Bool { didSet { d.set(notifyOnBlocked, forKey: "notifyOnBlocked") } }
    var sidebarTextSize: Double { didSet { d.set(sidebarTextSize, forKey: "sidebarTextSize") } }
    var servers: [ServerConfig] {
        didSet { if let data = try? JSONEncoder().encode(servers) { d.set(data, forKey: "servers") } }
    }
    var hostURLs: [String: String] { didSet { d.set(hostURLs, forKey: "hostURLs") } }

    static let defaultKeyBar = ["esc", "tab", "ctrl", "alt", "left", "up", "down", "right", "|", "~", "/", "-", "ctrl-c", "paste"]
    static let allKeys = ["esc", "tab", "ctrl", "alt", "left", "up", "down", "right", "home", "end", "pgup", "pgdn",
                          "|", "~", "/", "\\", "-", "_", "`", "*", "$", "&", ";", ":", "\"", "'", "<", ">",
                          "[", "]", "{", "}", "(", ")", "ctrl-c", "ctrl-d", "ctrl-z", "ctrl-r", "ctrl-l", "shift-tab",
                          "enter", "paste", "f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12"]

    private init() {
        themeID = d.string(forKey: "themeID") ?? "github-dark-dimmed"
        lightThemeID = d.string(forKey: "lightThemeID") ?? "github-light-default"
        followSystemAppearance = d.object(forKey: "followSystem") as? Bool ?? false
        fontSize = d.object(forKey: "fontSize") as? Double ?? 11
        sizing = SizingMode(rawValue: d.string(forKey: "sizing") ?? "") ?? .fit
        wideLayout = WideLayout(rawValue: d.string(forKey: "wideLayout") ?? "") ?? .auto
        keyBar = d.stringArray(forKey: "keyBar") ?? Prefs.defaultKeyBar
        haptics = d.object(forKey: "haptics") as? Bool ?? true
        showAgentStatus = d.object(forKey: "showAgentStatus") as? Bool ?? true
        notifyOnBlocked = d.object(forKey: "notifyOnBlocked") as? Bool ?? true
        sidebarTextSize = d.object(forKey: "sidebarTextSize") as? Double ?? 14
        hostURLs = d.dictionary(forKey: "hostURLs") as? [String: String] ?? [:]
        if let data = d.data(forKey: "servers"), let s = try? JSONDecoder().decode([ServerConfig].self, from: data), !s.isEmpty {
            servers = s
        } else {
            servers = [ServerConfig(name: "This Mac", url: "https://macbook-pro-rex.tail8657d0.ts.net")]
        }
    }
}
