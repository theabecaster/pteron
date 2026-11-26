import SwiftUI
import UIKit

enum SizingMode: String {
    case fit     // claim the pane and resize it to the phone while viewing
    case mirror  // keep the Mac's size; zoom and pan
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
    /// The key bar's middle capsule: its sections, keys and shortcut groups (`KeyBarSetup`).
    var keyBarSetup: KeyBarSetup {
        didSet {
            guard keyBarSetup != oldValue else { return }
            if let data = try? JSONEncoder().encode(keyBarSetup) { d.set(data, forKey: "keyBarSetup") }
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
    /// The system's Light or Dark Mode, which `PteronApp` reads each time the app becomes active.
    /// Views can't read it from the environment: the root forces the app's scheme to the theme's own.
    var systemScheme: ColorScheme

    // MARK: Fixed choices

    /// Panes always fit the phone. `-sizing mirror` (launch argument) keeps the Mac's size for one
    /// run, for checks that must not resize real panes.
    let sizing: SizingMode
    // The agent board has no switch: it always shows while the phone stands as a tent, after the
    // hinge has held for a second (`TentDetector`), comes back 60 s after the last touch
    // (`BoardPresence`), and keeps the screen awake except in Low Power Mode (`BoardAwake`).
    // Predicted echo has no setting. It runs only while a computer's smoothed write round trip
    // (α 1/8, from the writes typing already makes) is over 60 ms after 5 samples, or after two
    // writes of 250 ms within 10 s; it stops at 40 ms or less once nothing is pending
    // (`EchoGate`). It guesses single printable ASCII bytes and Backspace, classified from the
    // bytes sent, at a shell's prompt on the primary screen, never in an agent's pane, behind
    // the fence, while composing, selecting, finding or scrolled back (`EchoHostGate`). A line
    // is drawn only after proof that the program echoes: an OSC 133 B, or, without OSC 133, the
    // first key's own echo and then an input_mode read that shows a line editor (echo and canonical off,
    // a local shell in front; never over ssh). It uses mosh's epochs and acknowledgement rule:
    // an epoch starts only once all earlier input is answered and 50 ms have passed, and a key
    // confirms only from the screen after its own write's answer, in typing order
    // (`EchoPredictor`). Only contrary screen content removes a guess; a late echo never does,
    // and a guess unconfirmed 1.5 s after its write's answer is cleared silently. Over 80 ms
    // (back at 50 ms with nothing pending, mosh's values), or once a drawn guess waits 300 ms,
    // unconfirmed characters carry a solid underline in their own colour at 50% (100% with
    // Increase Contrast), removed per cell on confirmation, no animation.
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
    // isn't the active one cuts its title at 120 pt; a chip stacks at most 3 pane icons, the
    // active pane's in front, and moves them in a 0.25 s spring when that pane changes
    // (`TabChip.iconLimit`, `PaneStack`); the strip ends 3 pt short of book mode's crease.
    static let defaultDarkTheme = "github-dark-dimmed"
    static let defaultLightTheme = "github-light-default"
    static let defaultFontSize = 11.0
    static let fontSizes = 7.0...20.0

    /// A text size as the pinch and the font shortcuts store it: in `fontSizes`, to the half point.
    static func fontSize(_ s: Double) -> Double {
        min(max((s * 2).rounded() / 2, fontSizes.lowerBound), fontSizes.upperBound)
    }
    // The key bar's left capsule (⌘ for the palette, compose, attach where the pane's computer
    // takes files), its right one (the arrows, the hide key) and Return, pinned at the end of the
    // middle capsule, are always there; Settings arranges only the middle (`KeyBarSetup`).
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


    /// Tests pass `UserDefaults(suiteName:)` to stay isolated.
    init(defaults: UserDefaults = .standard) {
        let d = defaults
        self.d = d
        Self.migrate(d)
        darkThemeID = d.string(forKey: "themeID") ?? Self.defaultDarkTheme
        lightThemeID = d.string(forKey: "lightThemeID") ?? Self.defaultLightTheme
        fontSize = d.object(forKey: "fontSize") as? Double ?? Self.defaultFontSize
        keyBarSetup = d.data(forKey: "keyBarSetup").flatMap { try? JSONDecoder().decode(KeyBarSetup.self, from: $0) }?
            .normalized() ?? .standard
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
        migrateKeyBar(d)
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

    /// The key bar's layouts become a setup with the same keys (`KeyBarSetup.migrating`): a
    /// layout picked in Settings, a key list the removed editor saved, and on an install that
    /// already ran, the Agents layout it had by default. Only a fresh install starts on
    /// `KeyBarSetup.standard`. Runs once: the setup is saved and the old keys cleared.
    static func migrateKeyBar(_ d: UserDefaults) {
        defer {
            d.removeObject(forKey: "keyBarLayout")
            d.removeObject(forKey: "keyBar")
        }
        guard d.object(forKey: "keyBarSetup") == nil else { return }
        let keys: [String]?
        if let raw = d.string(forKey: "keyBarLayout") {
            keys = (KeyBarLayout(rawValue: raw) ?? .agents).keys
        } else if let saved = d.stringArray(forKey: "keyBar") {
            keys = KeyBarLayout.matching(stored: saved)?.keys ?? saved
        } else if ["servers", "hostURLs", "onboardingDone", "themeID", "fontSize"].contains(where: { d.object(forKey: $0) != nil }) {
            keys = KeyBarLayout.agents.keys
        } else {
            keys = nil
        }
        // A fresh install saves the standard setup too, so a later launch, which finds servers
        // by then, never takes it for an install from before the setup.
        let setup: KeyBarSetup = keys.map { KeyBarSetup.migrating($0) } ?? .standard
        guard let data = try? JSONEncoder().encode(setup) else { return }
        d.set(data, forKey: "keyBarSetup")
    }

    /// The terminal theme for the system's Light or Dark Mode.
    var theme: TermTheme { ThemeStore.theme(systemScheme == .light ? lightThemeID : darkThemeID) }

    /// The same as `theme`. Callers pass their view's color scheme, which the root forces to the
    /// theme's own, so it can't tell which mode the system is in.
    func theme(for _: ColorScheme) -> TermTheme { theme }
}
