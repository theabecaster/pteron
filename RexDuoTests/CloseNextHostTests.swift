import RexKit
import SwiftUI
import XCTest
@testable import RexDuo

/// The root as the app draws it, while the tab on screen closes: the next tab takes its place
/// with no frame of the empty state in between, in sidebar mode and in tab mode.
@MainActor
final class CloseNextHostTests: XCTestCase {
    private var window: UIWindow!
    private var prefs: Prefs!
    private var panes = PaneBaseline()

    override func setUp() async throws {
        panes = PaneBaseline()
        let suite = "close-next-host-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        prefs = Prefs(defaults: defaults)
        // A pane on screen doesn't take the keyboard, which would draw the tab again later.
        UserDefaults.standard.set("none", forKey: "focus")
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 600))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "focus")
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        prefs = nil
        // The tabs hold no panes, so no terminal is left for the next class's leak checks.
        let cleared = await panes.cleared()
        XCTAssertTrue(cleared, "LEAKCHECK \(name): \(panes.left) panes left")
    }

    /// A tab with no pane: what draws in the tab's place is all these tests look at.
    private func view(_ sid: String, _ tabs: [String], revision: Int = 1) -> SessionView {
        CloseNextTests.view(sid, tabs, revision: revision, blocks: Dictionary(uniqueKeysWithValues: tabs.map { ($0, [String]()) }))
    }

    private func settle(_ turns: Int = 8) async {
        for _ in 0..<turns {
            window.layoutIfNeeded()
            await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } }
        }
    }

    private func model(_ sessions: [(String, [String])]) -> (AppModel, ServerConnection) {
        let model = AppModel(prefs: prefs, connect: false)
        let s = ServerConnection(config: ServerConfig(name: "desk", url: "https://desk-rex.tail1234.ts.net"),
                                 prefs: prefs, notifier: model.notifier, deviceID: "a1b2c3d4")
        model.servers.append(s)
        s.sessions = sessions.map { SessionEntry(id: $0.0, label: $0.0) }
        for (sid, tabs) in sessions { s.views[sid] = view(sid, tabs) }
        s.phase = .online
        s.synced = true
        s.agentsWereRead()
        return (model, s)
    }

    private func show(_ model: AppModel, width: CGFloat) async {
        window.frame = CGRect(x: 0, y: 0, width: width, height: 600)
        window.rootViewController = UIHostingController(rootView: RootView().environment(model).environment(prefs))
        window.makeKeyAndVisible()
        await settle()
    }

    private func check(_ navigation: NavigationStyle, width: CGFloat) async throws {
        prefs.navigation = navigation
        let (model, s) = model([("play", ["p1"]), ("work", ["w1", "w2"])])
        model.select(s, session: "play", window: "p1")
        model.select(s, session: "work", window: "w1")
        model.select(s, session: "work", window: "w2")
        await show(model, width: width)
        let empties = RenderCount.value(.emptyStates)

        // The tab's last pane closes: the tab viewed before it.
        s.views["work"] = view("work", ["w1"], revision: 2)
        await settle()
        XCTAssertEqual(model.selection, Selection(serverID: s.id, sessionID: "work", windowID: "w1"))

        // The session's last pane closes and Rex keeps it, empty: the session viewed before.
        s.views["work"] = view("work", [], revision: 3)
        await settle()
        XCTAssertEqual(model.selection, Selection(serverID: s.id, sessionID: "play", windowID: "p1"))
        XCTAssertEqual(RenderCount.value(.emptyStates), empties, "the empty state never drew")

        // With nothing left to show, it does.
        s.views["play"] = view("play", [], revision: 2)
        await settle()
        XCTAssertGreaterThan(RenderCount.value(.emptyStates), empties)
    }

    func testSidebarModeBesideTheTab() async throws { try await check(.sidebar, width: 800) }
    func testSidebarModeAsADrawer() async throws { try await check(.sidebar, width: 402) }
    func testTabMode() async throws { try await check(.tabs, width: 402) }
}
