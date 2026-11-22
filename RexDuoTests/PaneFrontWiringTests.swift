import RexKit
import SwiftUI
import XCTest
@testable import RexDuo

/// The palette's part of the front pane rule, through SwiftUI: `PaneHostView` tells its host
/// that the palette lies over it when the app's model opens one, and that it is gone when the
/// model closes it.
@MainActor
final class PaneFrontWiringTests: XCTestCase {
    private var window: UIWindow!
    private var prefs: Prefs!
    private var panesBefore = 0

    override func setUp() async throws {
        panesBefore = GhosttyRenderThread.shared.paneCount
        let suite = "pane-front-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        prefs = Prefs(defaults: defaults)
        // The keyboard stays down: nothing here needs it.
        UserDefaults.standard.set("none", forKey: "focus")
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 382, height: 700))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "focus")
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        prefs = nil
        var turns = 0
        while GhosttyRenderThread.shared.paneCount > panesBefore, turns < 1500 {
            turns += 1
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func wait(_ what: String, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    func testThePaletteOpeningAndClosingReachesThePane() async {
        let model = AppModel(prefs: prefs, connect: false)
        let server = ServerConnection(config: ServerConfig(name: "desk", url: "https://desk-rex.tail1234.ts.net"),
                                      prefs: prefs, notifier: model.notifier, deviceID: "a1b2c3d4")
        model.servers.append(server)
        let pool = TerminalHostPool()
        let host = TerminalHost(stream: TerminalStream(control: server.control, sessionID: "work", blockID: "b0"),
                                sizing: .mirror, fontSize: CGFloat(prefs.fontSize), theme: ThemeStore.fallback)
        pool.add(host, for: TerminalHostPool.Key(server: server.id, session: "work", block: "b0"))
        let pane = PaneView(server: server, sessionID: "work", blockID: "b0", active: true, onFocus: {})
        window.rootViewController = UIHostingController(rootView: pane.environment(model).environment(prefs).environment(pool))
        window.makeKeyAndVisible()
        await wait("the pane to take its host") { host.window != nil && host.isActive }
        host.appActiveChanged(true)
        XCTAssertFalse(host.underPalette)
        XCTAssertTrue(host.isFrontPane)

        // The palette opens (`GoToCenter.open` sets the model's palette).
        model.goTo = GoToModel(scope: .anything, target: nil, center: nil, anchor: nil)
        await wait("the pane to hear of the palette") { host.underPalette }
        XCTAssertFalse(host.isFrontPane, "under the palette no pane is the front pane")
        XCTAssertFalse(host.term.programFocus.front)

        model.goTo = nil
        await wait("the pane to hear that the palette is gone") { !host.underPalette }
        XCTAssertTrue(host.isFrontPane)
        XCTAssertTrue(host.term.programFocus.front)

        window.rootViewController = nil
        host.evict()
    }
}
