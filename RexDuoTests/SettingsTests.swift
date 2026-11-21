import SwiftUI
import Testing
import UIKit
@testable import RexDuo

/// Settings as short pages: where each way in lands, the `-settingsScroll` places, the values the
/// top level shows, how much room the top level takes, and the Navigation row.
@MainActor
@Suite(.serialized) struct SettingsTests {
    private func model(servers: Int = 0) throws -> AppModel {
        let suite = "settings-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
        let m = AppModel(prefs: Prefs(defaults: d), connect: false)
        for i in 0..<servers {
            m.servers.append(ServerConnection(config: ServerConfig(name: "Computer \(i)", url: "https://c\(i)-rex.tail1234.ts.net"),
                                              prefs: m.prefs, notifier: m.notifier, deviceID: "a1b2c3d4"))
        }
        return m
    }

    // MARK: The pages and their paths

    @Test func everyPageHasAPathUnderTheTopLevelRowItBelongsTo() {
        let expected: [SettingsPage: [SettingsPage]] = [
            .main: [],
            .servers: [.servers], .appearance: [.appearance], .keyboard: [.keyboard],
            .notifications: [.notifications], .about: [.about],
            .addServer: [.servers, .addServer],
            .darkTheme: [.appearance, .darkTheme], .lightTheme: [.appearance, .lightTheme],
            .acknowledgements: [.about, .acknowledgements],
        ]
        #expect(Set(expected.keys) == Set(SettingsPage.allCases), "every page is listed here")
        for page in SettingsPage.allCases {
            #expect(page.path == expected[page], "\(page)")
        }
        #expect(SettingsPage.topLevel == [.servers, .appearance, .keyboard, .notifications, .about])
        // Every page is reachable: on the top level, or under a row that is.
        for page in SettingsPage.allCases where page != .main {
            #expect(SettingsPage.topLevel.contains(page.path[0]), "\(page)")
        }
    }

    @Test func theLaunchArgumentsNameEveryPage() {
        for page in SettingsPage.allCases {
            #expect(SettingsPage(rawValue: page.rawValue) == page)
            #expect(SettingsPage.launch(page: page, anchor: nil) == page)
        }
        #expect(SettingsPage.launch(page: nil, anchor: "end") == nil, "-settingsScroll alone opens nothing")
    }

    @Test func theScrollAnchorsLandOnTheNotificationsPage() {
        // The old way to reach them, `-settings main -settingsScroll …`, opens their page.
        for anchor in [SettingsAnchor.notifications, SettingsAnchor.computer(2), SettingsAnchor.end] {
            #expect(SettingsPage.launch(page: .main, anchor: anchor) == .notifications)
            #expect(SettingsPage.launch(page: .notifications, anchor: anchor) == .notifications)
        }
        #expect(SettingsAnchor.page == .notifications)
        #expect(SettingsAnchor.target("notifications", computers: 3) == ("notifications", false))
        #expect(SettingsAnchor.target("notifications.1", computers: 3) == ("notifications.1", false))
        #expect(SettingsAnchor.target("end", computers: 3) == ("notifications.2", true))
        #expect(SettingsAnchor.target("end", computers: 0) == ("notifications", true))
    }

    @Test func openSettingsAtAPageStartsThere() throws {
        let m = try model()
        for page in SettingsPage.allCases {
            m.showSettings = false
            m.openSettings(at: page)
            #expect(m.showSettings && m.settingsStart == page)
        }
    }

    // MARK: The top level's values

    @Test func theTopLevelSaysWhatIsSet() {
        #expect(SettingsSummary.servers(total: 0, connected: 0) == "None")
        #expect(SettingsSummary.servers(total: 3, connected: 3) == "3 connected")
        #expect(SettingsSummary.servers(total: 3, connected: 1) == "1 of 3 connected")
        #expect(SettingsSummary.appearance(theme: "GitHub Dark Dimmed", fontSize: 11) == "GitHub Dark Dimmed · 11 pt")
        #expect(SettingsSummary.appearance(theme: "Nord", fontSize: 12.5) == "Nord · 12.5 pt")
        #expect(SettingsSummary.appearanceSpoken(theme: "Nord", fontSize: 11) == "Nord, 11 points")
        #expect(SettingsSummary.notifications(on: true) == "On")
        #expect(SettingsSummary.notifications(on: false) == "Off")
    }

    // MARK: The Navigation setting

    @Test func theNavigationRowWaitsForTabMode() {
        #expect(NavigationStyle.isAvailable == false)
    }

    @Test func navigationIsTheSidebarUntilTabsIsPicked() throws {
        let suite = "settings-nav-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
        #expect(Prefs(defaults: d).navigation == .sidebar)
        Prefs(defaults: d).navigation = .tabs
        #expect(d.string(forKey: "navigation") == "tabs")
        #expect(Prefs(defaults: d).navigation == .tabs)
        d.set("ribbon", forKey: "navigation")
        #expect(Prefs(defaults: d).navigation == .sidebar)
        #expect(NavigationStyle.allCases.map(\.title) == ["Sidebar", "Tabs"])
    }

    // MARK: Hosted in a window

    /// Each way in, opened for real: the stack holds the page's path, and the page on top has
    /// its title.
    @Test func everyWayInLandsOnItsPage() async throws {
        let titles: [SettingsPage: String] = [
            .main: "Settings", .servers: "Servers", .appearance: "Appearance", .keyboard: "Keyboard",
            .notifications: "Notifications", .about: "About", .addServer: "Add Server",
            .darkTheme: "Dark Theme", .lightTheme: "Light Theme", .acknowledgements: "Acknowledgements",
        ]
        for page in SettingsPage.allCases {
            let m = try model(servers: 2)
            m.openSettings(at: page)
            let window = Hosted.window(SettingsView().environment(m).environment(m.prefs))
            defer { window.isHidden = true }
            let nav = try await Hosted.eventually { Hosted.navigationController(in: window.rootViewController) }
            let landed = await Hosted.settle { nav.viewControllers.count == page.path.count + 1 }
            #expect(landed, "\(page): \(nav.viewControllers.count) pages")
            #expect(nav.topViewController?.navigationItem.title == titles[page], "\(page)")
            #expect(m.settingsStart == nil, "Settings took the start")
        }
    }

    /// The top level fits one screen, with nothing to scroll, on phone-sized windows at the
    /// default text size, and at AX3 on an iPhone 17 Pro's. The folded Duo at AX3 may scroll. Each
    /// case is a fixed window with a fixed safe area, so the simulator the tests run on doesn't
    /// change the numbers.
    @Test func theTopLevelFitsOneScreen() async throws {
        struct Screen { let name: String; let size: CGSize; let safeArea: EdgeInsets }
        // The sheet starts under the status bar and the card above it.
        let iPhone17Pro = Screen(name: "iPhone 17 Pro", size: CGSize(width: 402, height: 874 - 64),
                                 safeArea: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0))
        // The Duo's outer screen: the vertical bar's column on the right, nothing above.
        let folded = Screen(name: "folded Duo", size: CGSize(width: 466, height: 678),
                            safeArea: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84))
        let cases: [(Screen, UIContentSizeCategory)] = [
            (iPhone17Pro, .large), (iPhone17Pro, .accessibilityExtraLarge), (folded, .large),
        ]
        var needed: [CGFloat] = []
        for (screen, size) in cases {
            let m = try model(servers: 3)
            let window = Hosted.window(SettingsView().environment(m).environment(m.prefs), size: screen.size,
                                       category: size, safeArea: screen.safeArea)
            defer { window.isHidden = true }
            let list = try await Hosted.eventually { Hosted.views(UICollectionView.self, in: window).first { $0.contentSize.height > 0 } }
            _ = await Hosted.settle { false }
            let height = list.contentSize.height + list.adjustedContentInset.top + list.adjustedContentInset.bottom
            #expect(height <= list.bounds.height, "\(screen.name), \(size.rawValue): \(height) pt in \(list.bounds.height) pt")
            needed.append(height)
        }
        #expect(needed[1] > needed[0] + 100, "AX3 took effect: \(needed)")
    }

    /// VoiceOver reads the row as "Navigation" with the style picked.
    /// Runs once tab mode sets `NavigationStyle.isAvailable`; until then the row isn't shown.
    @Test(.enabled(if: NavigationStyle.isAvailable)) func theNavigationRowSpeaksItsNameAndValue() async throws {
        try #require(Hosted.setAccessibility(on: true), "the simulator's accessibility runtime")
        defer { _ = Hosted.setAccessibility(on: false) }
        let m = try model()
        m.prefs.navigation = .tabs
        let window = Hosted.window(NavigationStack { AppearancePage(theme: m.prefs.theme) }.environment(m).environment(m.prefs))
        defer { window.isHidden = true }
        // The row is one element, as VoiceOver lands on it: the name, then the style picked.
        let tabs = try await Hosted.eventually {
            Hosted.accessibilityElements(in: window).first { $0.accessibilityLabel?.hasPrefix("Navigation") == true }
        }
        #expect(tabs.accessibilityLabel == "Navigation, Tabs")
        m.prefs.navigation = .sidebar
        let sidebar = await Hosted.settle {
            Hosted.accessibilityElements(in: window).contains { $0.accessibilityLabel == "Navigation, Sidebar" }
        }
        #expect(sidebar, "it follows the setting")
    }
}
