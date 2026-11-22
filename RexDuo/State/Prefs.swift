import SwiftUI
import UIKit

enum SizingMode: String {
    case fit     // claim the pane and resize it to the phone while viewing
    case mirror  // keep the Mac's size; zoom and pan
}

/// The key bar's layouts. "arrows" is the drag-to-move trackpad key.
enum KeyBarLayout: String, CaseIterable, Identifiable {
    case agents, shell, vim

    /// Keys that never scroll, in every layout: they sit at the end of the keys' capsule, next to
    /// the hide key. Return runs a shell's line and sends an agent's message, so it never scrolls
    /// out of reach, and stays last. Attach sits before it, so sending a photo or a file is always
    /// in sight; it shows only where the pane's host takes files, as it always has. No layout's
    /// `keys` lists them.
    static let pinned = ["attach", "enter"]

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
            return ["esc", "shift-tab", "tab", "/", "arrows", "up", "down", "ctrl-c", "1", "2", "3", "ctrl", "cmd",
                    "paste"]
        case .shell:
            return ["esc", "tab", "shift-tab", "ctrl", "alt", "cmd", "arrows", "up", "down", "left", "right", "ctrl-r",
                    "ctrl-c", "|", "~", "/", "-", "paste"]
        case .vim:
            return ["esc", ":", "ctrl", "cmd", "arrows", "/", "ctrl-d", "ctrl-u", "ctrl-r", "ctrl-w", "pgup", "pgdn",
                    "$", "~", "paste"]
        }
    }

    /// The keys the removed key bar editor saved for this layout (before the attach and cmd keys).
    /// `Prefs.migrate` matches a stored key list against them.
    var storedKeys: [String] {
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

    /// The layout a key list saved by the removed editor stands for, nil for an edited one. A list
    /// saved as `keys` were before Return and attach were pinned has them among it: they are left out.
    static func matching(stored keys: [String]) -> KeyBarLayout? {
        let scrolling = keys.filter { !pinned.contains($0) }
        return allCases.first { $0.storedKeys == keys || $0.keys == scrolling }
    }
}

/// How the app moves between sessions and tabs: the sidebar beside or over the tab, or the tabs
/// in a strip above it, as the Rex Mac app's horizontal tabs.
enum NavigationStyle: String, CaseIterable, Identifiable {
    case sidebar, tabs

    var id: String { rawValue }
    var title: String {
        switch self {
        case .sidebar: return "Sidebar"
        case .tabs: return "Tabs"
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
    /// `studio.tail1234.ts.net` is "studio". Rex names its tailnet address `<computer>-rex`, so
    /// that ending goes too. An IP address stays whole.
    static func name(for url: URL) -> String {
        guard let host = url.host(), !host.isEmpty else { return "Rex" }
        if host.contains(":") || host.allSatisfy({ $0.isNumber || $0 == "." }) { return host }
        let label = host.split(separator: ".").first.map(String.init) ?? host
        let suffix = "-rex"
        return label.count > suffix.count && label.lowercased().hasSuffix(suffix) ? String(label.dropLast(suffix.count)) : label
    }
}

/// User preferences. Stored in UserDefaults.
///
/// Settings shows only what a user would want to change and would understand: servers, a theme for
/// Light and for Dark Mode, text size, the navigation style, the key bar layout and notifications. Everything else is
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
    /// The sidebar, or tabs above the pane. Sidebar until the user picks Tabs.
    var navigation: NavigationStyle { didSet { d.set(navigation.rawValue, forKey: "navigation") } }
    /// The master switch: push notifications through Beacon. Off until the user turns
    /// them on, and kept as chosen while iOS has notifications turned off.
    var pushEnabled: Bool { didSet { d.set(pushEnabled, forKey: "pushEnabled") } }
    var servers: [ServerConfig] {
        didSet {
            if let data = try? JSONEncoder().encode(servers) { d.set(data, forKey: "servers") }
            // A computer added any way at all (pairing, an address, a link) ends the first run.
            if !servers.isEmpty, !onboardingDone { onboardingDone = true }
        }
    }

    // MARK: Remembered state

    /// The first-run guide was left, or is not needed: an install that has a server, or had one
    /// (set before the first frame when an update finds servers). Setup Guide opens it again.
    var onboardingDone: Bool { didSet { d.set(onboardingDone, forKey: "onboardingDone") } }

    /// Servers whose "Get notifications from <Name>?" page was answered with Skip. Pairing never
    /// asks again for them; Settings → Notifications still has Install.
    var helperOfferSkipped: Set<UUID> {
        didSet { d.set(helperOfferSkipped.map(\.uuidString).sorted(), forKey: "helperOfferSkipped") }
    }
    /// Servers whose notifications the user turned off. A server that is not here is on, so a
    /// newly added one starts on. Kept while the master switch is off and while iOS has
    /// notifications turned off, so each computer comes back as it was.
    var notificationsOff: Set<UUID> {
        didSet { d.set(notificationsOff.map(\.uuidString).sorted(), forKey: "notificationsOff") }
    }
    /// Servers where this phone registered with a helper at least once. It tells a computer
    /// whose helper is not running from one that never had a helper. Remove Beacon clears it.
    var helperSeen: Set<UUID> {
        didSet { d.set(helperSeen.map(\.uuidString).sorted(), forKey: "helperSeen") }
    }
    /// Servers that were turned off and whose helper has not confirmed yet that it holds this
    /// phone's notifications back. Each is told now, or the next time it is connected.
    var helpersToTell: Set<UUID> {
        didSet { d.set(helpersToTell.map(\.uuidString).sorted(), forKey: "helpersToTell") }
    }
    /// The sidebar's width per posture, keyed by `SidebarWidth.key`.
    var sidebarWidths: [String: Double] { didSet { d.set(sidebarWidths, forKey: "sidebarWidths") } }
    /// Sidebar groups the user folded (`SidebarCollapse` keys). Everything else is open.
    var sidebarCollapsed: Set<String> { didSet { d.set(sidebarCollapsed.sorted(), forKey: "sidebarCollapsed") } }
    /// Sessions or Agents, as the Mac's sidebar keeps its mode. `-sidebarMode agents` overrides it
    /// for one run.
    var sidebarMode: SidebarMode { didSet { d.set(sidebarMode.rawValue, forKey: "sidebarMode") } }
    /// What the palette opened and ran lately, newest first (`GoToRecents`): its ranking and its
    /// Recent list.
    var goToRecents: [GoToRecent] {
        didSet { d.set(try? JSONEncoder().encode(goToRecents), forKey: "goToRecents") }
    }
    /// The tab open when the app last ran.
    var lastSelection: Selection? {
        didSet { d.set(lastSelection.flatMap { try? JSONEncoder().encode($0) }, forKey: "lastSelection") }
    }
    /// The tabs viewed lately, newest first (`TabHistory`): where the app goes when the tab on
    /// screen closes. Nothing draws it, so a change re-renders nothing.
    @ObservationIgnored var recentTabs: [Selection] {
        didSet { d.set(try? JSONEncoder().encode(recentTabs), forKey: "recentTabs") }
    }
    /// "Show Hidden Files" in the file browser. Not saved: each run starts with them hidden.
    @ObservationIgnored var showHiddenFiles = false
    /// The paths last inserted with Insert Path, newest first, per server and host
    /// (`PathRecents`): the browser's "Recent" in insert mode.
    @ObservationIgnored var pathRecents: [String: [String]] { didSet { d.set(pathRecents, forKey: "pathRecents") } }
    /// The system's Light or Dark Mode, which `RexDuoApp` reads each time the app becomes active.
    /// Views can't read it from the environment: the root forces the app's scheme to the theme's own.
    var systemScheme: ColorScheme

    // MARK: Fixed choices

    /// Panes always fit the phone. `-sizing mirror` (launch argument) keeps the Mac's size for one
    /// run, for checks that must not resize real panes.
    let sizing: SizingMode
    // The agent board has no switch: it always shows while the phone stands as a tent, after the
    // hinge has held for a second (`TentDetector`), comes back 60 s after the last touch
    // (`BoardPresence`), and keeps the screen awake except in Low Power Mode (`BoardAwake`).
    // Find has no settings: tints from the theme's yellows, the current match's text black or
    // white by contrast, refreshes at most every 24 ms, needles under 3 characters searched after
    // 300 ms, at most 1 KB of needle, 2,048 pages converted per refresh (`GhosttyFind`,
    // `FindQuery`), and the hand-over in `FindHandover.shipped`.
    // The widgets have no settings either: one widget, configured by its size; they take the two
    // themes chosen here; the snapshot is written within 0.5 s for a new waiting agent and 2 s
    // for anything else, reloaded at most once in 10 s and restamped every 15 min
    // (`WriteThrottle`); it reads as current for 2 min and dims after an hour (`GlanceFreshness`).
    // The watch app has no settings on either device and is always on: it only shows; a change in
    // who waits goes to the watch at once and then at most every 30 s, anything else at most
    // every 60 s, with the same 15 min restamp (`WatchDelivery`); it uses the Dark Mode theme
    // when that is a dark theme, else the default one (`WatchScreen.palette`); and its
    // background task for a delivery stays 10 s at most (`WatchDrain`).
    // The palette has no settings: its keys are the keymap's; at most 50 rows, 5 commands after
    // the places, 3 waiting and 8 recent ones; recents weigh up to +30% and halve every 3 days
    // (`GoToRanker`, `GoToRecents`); a run's notice after 1.5 s for at most 6 s, and questions
    // only from the phone's own runs within 10 s (`GoToCenter`, `PaletteOrigins`).
    // The file browser has no settings: it opens in the folder the pane's program is in; hidden
    // files are hidden until "Show Hidden Files", which lasts until the app quits; folders come
    // first and names sort as in Finder; one call lists at most 2,000 entries and a filter asks
    // the server 250 ms after the last key only while a listing is cut short (`DirLister.limit`,
    // `FolderModel.searchDelay`); the last 8 inserted paths are kept per server and host
    // (`PathRecents.limit`); a file without an extension previews as text up to 1 MB
    // (`TextHint`). Insert Path writes a path relative to the program's folder, else `~/…`, else
    // absolute, escaped for a shell and as it is elsewhere, and never a line end (`PathInsert`).
    // Sending has no settings: the attach menu is Paste Image (when the clipboard has one),
    // Photos, Camera and Files, then the computer's files. A photo, a paste and a drop always
    // lose their location and other metadata, and HEIC and other formats agents can't read
    // become JPEG; a screenshot or a PNG stays PNG at full size up to 3,000 px, a photo becomes
    // JPEG at 0.85 with its long side at most 2,048 px, and a prepared image weighs at most about
    // 5 MB (`ImagePrep`). Videos and files picked in Files go as they are.
    // The tab strip has no settings beyond `navigation`: what it shows follows its width
    // (`StripLayout`). Parts a finger taps are 44 pt wide or more and chips sit 6 pt apart; the
    // strip is compact where its full form would leave the chips under 144 pt; a chip that
    // isn't the active one cuts its title at 120 pt and shows at most 3 pane icons
    // (`TabChip.iconLimit`); the strip ends 3 pt short of book mode's crease.
    static let defaultDarkTheme = "github-dark-dimmed"
    static let defaultLightTheme = "github-light-default"
    static let defaultFontSize = 11.0
    static let fontSizes = 7.0...20.0

    /// A text size as the pinch and the font shortcuts store it: in `fontSizes`, to the half point.
    static func fontSize(_ s: Double) -> Double {
        min(max((s * 2).rounded() / 2, fontSizes.lowerBound), fontSizes.upperBound)
    }
    static let defaultKeyBar = KeyBarLayout.agents
    // Every layout pins Return, with the attach key before it where the pane's host takes files
    // (`KeyBarLayout.pinned`); no setting moves them.
    // Also decided for the user, where they're used: a tab shows its splits whenever every pane stays
    // legible (`WindowScreen.splitsFit`); agent status always shows in the sidebar; haptics follow
    // iOS's System Haptics; in-app banners for waiting agents are always on; sidebar text follows
    // Dynamic Type.
    // The first-run guide has no settings: it shows once, to an install with no server, until Not
    // Now or a computer is added; its checklist starts on Mac; it has no timers, badges or sounds.
    // Progress rings and notice toasts have no switch either: rings apply at most every 0.5 s and
    // go 15 s after the last report (`ServerConnection.progressFlush`, `progressStale`); a notice
    // waits 1 s for an agent status and counts a pane as an agent's 10 s after its last record
    // (`noticeWait`, `NoticeFilter.agentMemory`); notice toasts keep 10 s apart, 30 s per pane,
    // drop repeats within 30 s and stay quiet 2 s after the app comes back (`ToastPolicy`); at
    // most 5 notices per pane and 50 in all queue (`AgentNotifier.perPaneLimit`, `noticeLimit`).

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
        navigation = d.string(forKey: "navigation").flatMap(NavigationStyle.init(rawValue:)) ?? .sidebar
        pushEnabled = d.bool(forKey: "pushEnabled")
        helperOfferSkipped = Set((d.stringArray(forKey: "helperOfferSkipped") ?? []).compactMap(UUID.init(uuidString:)))
        func ids(_ key: String) -> Set<UUID> { Set((d.stringArray(forKey: key) ?? []).compactMap(UUID.init(uuidString:))) }
        notificationsOff = ids("notificationsOff")
        helperSeen = ids("helperSeen")
        helpersToTell = ids("helpersToTell")
        sidebarWidths = d.dictionary(forKey: "sidebarWidths") as? [String: Double] ?? [:]
        sidebarCollapsed = Set(d.stringArray(forKey: "sidebarCollapsed") ?? [])
        pathRecents = d.dictionary(forKey: "pathRecents") as? [String: [String]] ?? [:]
        sidebarMode = d.string(forKey: "sidebarMode").flatMap(SidebarMode.init(rawValue:)) ?? .sessions
        lastSelection = d.data(forKey: "lastSelection").flatMap { try? JSONDecoder().decode(Selection.self, from: $0) }
        recentTabs = d.data(forKey: "recentTabs").flatMap { try? JSONDecoder().decode([Selection].self, from: $0) } ?? []
        goToRecents = d.data(forKey: "goToRecents").flatMap { try? JSONDecoder().decode([GoToRecent].self, from: $0) } ?? []
        systemScheme = UITraitCollection.current.userInterfaceStyle == .light ? .light : .dark
        // Only the launch argument is left: `migrate` cleared the saved setting.
        sizing = d.string(forKey: "sizing") == SizingMode.mirror.rawValue ? .mirror : .fit
        // A fresh install has no servers and opens on pairing. In a simulator, `-servers` adds some
        // for one run (docs/debug-args.md).
        servers = d.data(forKey: "servers").flatMap { try? JSONDecoder().decode([ServerConfig].self, from: $0) } ?? []
        // An update that finds servers never shows the first-run guide, and never will.
        onboardingDone = d.bool(forKey: "onboardingDone")
        if !onboardingDone, !servers.isEmpty {
            onboardingDone = true
            d.set(true, forKey: "onboardingDone")
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
            d.set((KeyBarLayout.matching(stored: keys) ?? defaultKeyBar).rawValue, forKey: "keyBarLayout")
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
