import RexKit
import SwiftUI
import XCTest
@testable import Pteron

/// `Prefs.navigation` switched while the app runs: the sidebar goes and comes back, the tab on
/// screen stays the same view with the same panes, and the title bar and the tab strip trade
/// places. Drawn in a window, as the root draws them.
@MainActor
final class NavigationSwitchTests: XCTestCase {
    private var window: UIWindow!
    private var prefs: Prefs!

    override func setUp() async throws {
        let suite = "navigation-switch-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        prefs = Prefs(defaults: defaults)
        // `-focus none`: a pane on screen doesn't take the keyboard. Left to itself it does, and
        // the keyboard comes up some time later and draws the tab again, in either mode: these
        // tests count what a change of mode and a change of title draw, and nothing else.
        UserDefaults.standard.set("none", forKey: "focus")
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "focus")
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        prefs = nil
    }

    private func show(_ view: some View, width: CGFloat) {
        window.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
    }

    private func settle(_ turns: Int = 6) async {
        for _ in 0..<turns {
            window.layoutIfNeeded()
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        }
    }

    // MARK: The sidebar

    /// What the two sides of a `SidebarSplit` went through. Not observed: writing it draws nothing.
    private final class Log {
        var tabAppears = 0
        var tabStates = Set<UUID>()
        var tabWidth: CGFloat = 0
        var sidebarAppears = 0
        var sidebarDisappears = 0
        var sidebarWidth: CGFloat = 0
    }

    private struct TabProbe: View {
        let log: Log
        @State private var state = UUID()
        var body: some View {
            Color.blue
                .onAppear { log.tabAppears += 1; log.tabStates.insert(state) }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { log.tabWidth = $0; log.tabStates.insert(state) }
        }
    }

    /// The root's split, with its mode read from `Prefs` as `RootView` reads it.
    private struct Split: View {
        @Environment(Prefs.self) private var prefs
        let inline: Bool
        let log: Log
        @State private var open = true
        var body: some View {
            SidebarSplit(arrangement: Arrangement(inline: inline), theme: ThemeStore.fallback, navigation: prefs.navigation,
                         open: $open) {
                Color.red
                    .onAppear { log.sidebarAppears += 1 }
                    .onDisappear { log.sidebarDisappears += 1 }
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { log.sidebarWidth = $0 }
            } tab: {
                TabProbe(log: log)
            }
        }
    }

    /// Wide: the sidebar sits beside the tab, tab mode gives the tab its room, and the sidebar
    /// is back where it was afterwards. The tab is never rebuilt: one appearance, one state.
    func testTheInlineSidebarGoesAndComesBackAndTheTabStays() async {
        let log = Log()
        show(Split(inline: true, log: log).environment(prefs), width: 800)
        await settle()
        XCTAssertEqual(log.sidebarWidth, SidebarWidth.standard)
        XCTAssertEqual(log.tabWidth, 800 - SidebarWidth.standard - 1)
        XCTAssertEqual(log.sidebarAppears, 1)

        prefs.navigation = .tabs
        await settle()
        XCTAssertEqual(log.tabWidth, 800, "the tab has the whole width")
        XCTAssertEqual(log.sidebarDisappears, 1, "nothing of the sidebar is built in tab mode")

        prefs.navigation = .sidebar
        await settle()
        XCTAssertEqual(log.tabWidth, 800 - SidebarWidth.standard - 1)
        XCTAssertEqual(log.sidebarWidth, SidebarWidth.standard)
        XCTAssertEqual(log.sidebarAppears, 2)
        XCTAssertEqual(log.tabAppears, 1, "the tab was never rebuilt")
        XCTAssertEqual(log.tabStates.count, 1, "the tab kept its state")
    }

    /// Narrow: the drawer is over the tab, so the tab's size never changes with the mode, and
    /// tab mode has no drawer.
    func testTheDrawerGoesAndTheTabKeepsItsSize() async {
        let log = Log()
        show(Split(inline: false, log: log).environment(prefs), width: 402)
        await settle()
        XCTAssertEqual(log.tabWidth, 402)
        XCTAssertEqual(log.sidebarAppears, 1)

        prefs.navigation = .tabs
        await settle()
        XCTAssertEqual(log.tabWidth, 402)
        XCTAssertEqual(log.sidebarDisappears, 1)

        prefs.navigation = .sidebar
        await settle()
        XCTAssertEqual(log.tabWidth, 402)
        XCTAssertEqual(log.sidebarAppears, 2)
        XCTAssertEqual(log.tabAppears, 1)
        XCTAssertEqual(log.tabStates.count, 1)
    }

    // MARK: The tab

    #if DEBUG
    private func model() -> (AppModel, ServerConnection) {
        let model = AppModel(prefs: prefs, connect: false)
        let s = ServerConnection(config: ServerConfig(name: "desk", url: "https://desk-rex.tail1234.ts.net"),
                                 prefs: prefs, notifier: model.notifier, deviceID: "a1b2c3d4")
        model.servers.append(s)
        // Three tabs of one pane each; a "Window n" label shows the pane's title instead.
        let windows = ["api", "Window 2", "logs"].enumerated().map { n, label -> JSONObject in
            ["window_id": "w\(n)", "label": label, "focused_block_id": "b\(n)",
             "layers": [["kind": "tiled", "layer_id": "l", "bounds": [0, 0, 1, 1],
                         "blocks": [["block_id": "b\(n)", "creator_name": "com.superlogical.terminal", "label": "shell"] as JSONObject],
                         "layout": ["rect": [0, 0, 1, 1], "block_id": "b\(n)"] as JSONObject] as JSONObject]]
        }
        s.sessions = [SessionEntry(id: "work", label: "work")]
        s.views = ["work": SessionView(["revision": 1, "session_id": "work", "label": "work", "active_window_id": "w0",
                                        "windows": windows])]
        s.phase = .online
        s.synced = true
        s.agentsWereRead()
        return (model, s)
    }

    private func terminal(in view: UIView?) -> TerminalHost? {
        guard let view else { return nil }
        if let host = view as? TerminalHost { return host }
        for sub in view.subviews {
            if let host = terminal(in: sub) { return host }
        }
        return nil
    }

    /// The header is the title bar or the strip; the pane under it is the same terminal in the
    /// same view through both switches. Nothing of the strip is drawn in sidebar mode.
    func testTheStripTakesTheTitleBarsPlaceAndThePaneStays() async throws {
        let (model, s) = model()
        let pool = TerminalHostPool()
        let screen = WindowScreen(server: s, sessionID: "work", windowID: "w0", mode: .narrow, sidebarVisible: .constant(false))
        show(screen.environment(model).environment(prefs).environment(pool), width: 402)
        await settle()
        let key = TerminalHostPool.Key(server: s.id, session: "work", block: "b0")
        let host = try XCTUnwrap(terminal(in: window.rootViewController?.view))
        let container = try XCTUnwrap(host.superview)
        XCTAssertTrue(pool.host(for: key) === host)
        let hosts = pool.hostsChanged
        let strips = RenderCount.value(.tabStrips), chips = RenderCount.value(.tabChips)

        // Sidebar mode draws nothing of the strip, also when a tab's title changes.
        var meta = BlockMeta()
        meta.title = "vim"
        s.meta["b1"] = meta
        await settle()
        XCTAssertEqual(RenderCount.value(.tabStrips), strips)
        XCTAssertEqual(RenderCount.value(.tabChips), chips)

        prefs.navigation = .tabs
        await settle()
        XCTAssertGreaterThan(RenderCount.value(.tabStrips), strips, "the strip is in the title bar's place")
        XCTAssertGreaterThanOrEqual(RenderCount.value(.tabChips), chips + 3, "one chip per tab")
        XCTAssertTrue(terminal(in: window.rootViewController?.view) === host, "the pane's terminal is the same")
        XCTAssertTrue(host.superview === container, "and so is the view that holds it: the pane wasn't rebuilt")
        XCTAssertEqual(pool.hostsChanged, hosts, "no terminal came or went")

        prefs.navigation = .sidebar
        await settle()
        let after = RenderCount.value(.tabStrips)
        XCTAssertTrue(terminal(in: window.rootViewController?.view) === host)
        XCTAssertTrue(host.superview === container)
        XCTAssertEqual(pool.hostsChanged, hosts)
        meta.title = "top"
        s.meta["b1"] = meta
        await settle()
        XCTAssertEqual(RenderCount.value(.tabStrips), after, "the strip is gone again")
    }

    // MARK: The root

    /// The root as the app draws it, wide enough for the sidebar to sit beside the tab.
    private func showRoot(_ model: AppModel, width: CGFloat = 800) {
        show(RootView().environment(model).environment(prefs), width: width)
    }

    /// Where the pane's terminal starts in the window: past the sidebar when it sits beside the tab.
    private func paneMinX() throws -> CGFloat {
        let host = try XCTUnwrap(terminal(in: window.rootViewController?.view))
        return host.convert(host.bounds, to: window).minX
    }

    /// Sidebar, tabs, sidebar: nothing that happens in tab mode touches the sidebar. A tab
    /// shown, Toggle Sidebar and cmd+. leave it open beside the tab and in Sessions mode, and
    /// cmd+. opens the Agents sheet instead.
    func testTabModeLeavesTheSidebarAsItWas() async throws {
        let (model, s) = model()
        model.selection = Selection(serverID: s.id, sessionID: "work", windowID: "w0")
        showRoot(model)
        await settle(12)
        let beside = try paneMinX()
        XCTAssertGreaterThanOrEqual(beside, SidebarWidth.standard, "the sidebar sits beside the tab")
        XCTAssertEqual(prefs.sidebarMode, .sessions)

        prefs.navigation = .tabs
        await settle(12)
        XCTAssertLessThan(try paneMinX(), 40, "the tab has the window")
        model.perform(.toggleSidebar)
        await settle()
        model.perform(.toggleAgents)
        await settle()
        XCTAssertTrue(model.agentsShown, "cmd+. shows the agents in their sheet")
        model.agentsShown = false
        model.openRequest = OpenRequest(selection: Selection(serverID: s.id, sessionID: "work", windowID: "w2"))
        await settle(12)
        XCTAssertEqual(model.selection?.windowID, "w2")

        prefs.navigation = .sidebar
        await settle(12)
        XCTAssertEqual(try paneMinX(), beside, "the sidebar is back where it was")
        XCTAssertEqual(prefs.sidebarMode, .sessions, "and in the mode it had")
    }

    /// A sidebar that was hidden stays hidden through tab mode.
    func testAHiddenSidebarComesBackHidden() async throws {
        let (model, s) = model()
        model.selection = Selection(serverID: s.id, sessionID: "work", windowID: "w0")
        UserDefaults.standard.set("closed", forKey: "sidebar")
        defer { UserDefaults.standard.removeObject(forKey: "sidebar") }
        showRoot(model)
        await settle(12)
        let alone = try paneMinX()
        XCTAssertLessThan(alone, 40)

        prefs.navigation = .tabs
        await settle(12)
        model.perform(.toggleSidebar)
        await settle()
        prefs.navigation = .sidebar
        await settle(12)
        XCTAssertEqual(try paneMinX(), alone, "nothing opened it meanwhile")
    }

    /// In sidebar mode cmd+. is the sidebar's Agents mode, as it was: no sheet.
    func testSidebarModeKeepsItsAgentsMode() async throws {
        let (model, s) = model()
        model.selection = Selection(serverID: s.id, sessionID: "work", windowID: "w0")
        showRoot(model)
        await settle(12)
        model.perform(.toggleAgents)
        await settle()
        XCTAssertEqual(prefs.sidebarMode, .agents)
        XCTAssertFalse(model.agentsShown)
    }

    /// With no tab on screen tab mode still draws the strip, for its session chip; sidebar mode
    /// draws none.
    func testTheStripStaysWithNoTabOnScreen() async throws {
        let (model, _) = model()
        showRoot(model, width: 402)
        await settle(12)
        let before = RenderCount.value(.tabStrips)
        XCTAssertNil(terminal(in: window.rootViewController?.view), "no tab is on screen")
        prefs.navigation = .tabs
        await settle(12)
        XCTAssertGreaterThan(RenderCount.value(.tabStrips), before)
    }

    /// In a short window the bar steps aside while the keyboard is up, in tab mode as in sidebar
    /// mode, and the strip is back when the keyboard goes.
    func testTypingInAShortWindowHidesTheStripAndHidingTheKeyboardBringsItBack() async throws {
        let (model, s) = model()
        prefs.navigation = .tabs
        let screen = WindowScreen(server: s, sessionID: "work", windowID: "w0", mode: .narrow, sidebarVisible: .constant(false))
            .environment(\.verticalSizeClass, .compact)
        show(screen.environment(model).environment(prefs).environment(TerminalHostPool()), width: 600)
        await settle(12)
        func paneMinY() throws -> CGFloat {
            let host = try XCTUnwrap(terminal(in: window.rootViewController?.view))
            return host.convert(host.bounds, to: window).minY
        }
        let rest = try paneMinY()

        let screenBounds = try XCTUnwrap(window.windowScene?.screen).bounds
        let keyboard = CGRect(x: 0, y: screenBounds.maxY - 300, width: screenBounds.width, height: 300)
        NotificationCenter.default.post(name: UIResponder.keyboardWillChangeFrameNotification, object: window.windowScene?.screen,
                                        userInfo: [UIResponder.keyboardFrameEndUserInfoKey: keyboard])
        await settle(12)
        XCTAssertEqual(try paneMinY(), rest - 34, "the 34 pt strip gave its rows to the pane")

        NotificationCenter.default.post(name: UIResponder.keyboardWillHideNotification, object: nil)
        await settle(12)
        XCTAssertEqual(try paneMinY(), rest, "the strip is back")
    }

    /// A title change in one tab draws that tab's chip again, and neither the strip nor the
    /// other chips.
    func testATitleChangeDrawsOnlyItsChip() async throws {
        let (model, s) = model()
        prefs.navigation = .tabs
        let screen = WindowScreen(server: s, sessionID: "work", windowID: "w0", mode: .narrow, sidebarVisible: .constant(false))
        show(screen.environment(model).environment(prefs).environment(TerminalHostPool()), width: 402)
        await settle()
        let strips = RenderCount.value(.tabStrips), chips = RenderCount.value(.tabChips), screens = RenderCount.value(.windowScreens)
        XCTAssertGreaterThan(strips, 0)

        var meta = BlockMeta()
        meta.title = "vim"
        s.meta["b1"] = meta
        await settle()
        XCTAssertEqual(RenderCount.value(.tabChips), chips + 1, "only the chip of the tab whose title changed")
        XCTAssertEqual(RenderCount.value(.tabStrips), strips, "the strip itself wasn't drawn again")
        XCTAssertEqual(RenderCount.value(.windowScreens), screens, "nor the tab")
    }
    #endif
}
