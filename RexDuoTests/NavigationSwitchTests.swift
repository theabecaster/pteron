import RexKit
import SwiftUI
import XCTest
@testable import RexDuo

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
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
    }

    override func tearDown() async throws {
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
