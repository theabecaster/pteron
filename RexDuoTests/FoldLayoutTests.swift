import RexKit
import SwiftUI
import XCTest
@testable import RexDuo

/// The room the keyboard takes in `FoldLayoutTests`, set by the test.
@MainActor @Observable
final class FoldKeyboard {
    var room: CGFloat = 0
}

/// A fold, an unfold or a rotation under a fitted pane, in tab mode and sidebar mode, with the
/// keyboard down and up: the window changes size under the tab as it does on the iPhone Duo, and
/// the tab is laid out as the root lays it out (narrow or wide from the window's width, the
/// keyboard's room taken from the bottom). Each change sends one resize, to the grid of the pane
/// with the keyboard down; the grid then fills the pane with no row cut and no row's worth of
/// room left; and the keyboard coming or going around a fold sends nothing more.
@MainActor
final class FoldLayoutTests: XCTestCase {
    private var window: UIWindow!
    private var prefs: Prefs!

    /// Narrow and tall, then wide and short: the folded Duo and the phone on its side, so the
    /// rows differ and a height kept from the other posture would show.
    private let folded = CGSize(width: 382, height: 700)
    private let unfolded = CGSize(width: 900, height: 420)

    private final class Transport: FitClaimTransport {
        var resizes: [(cols: Int, rows: Int)] = []
        func own() async -> FitClaimAnswer { .done }
        func resize(cols: Int, rows: Int) async -> FitClaimAnswer {
            resizes.append((cols, rows))
            return .done
        }
        func disown() async {}
        func whenConnected(_ body: @escaping @MainActor () -> Void) {}
    }

    /// The root's part that matters here: the tab, in the mode the window's width gives it, with
    /// the keyboard's room padded off its bottom and handed down, as `RootView` does.
    private struct Root: View {
        let server: ServerConnection
        let keyboard: FoldKeyboard
        var body: some View {
            GeometryReader { geo in
                let arr = Arrangement.decide(size: geo.size, division: nil)
                WindowScreen(server: server, sessionID: "work", windowID: "w0", mode: arr.inline ? .wide() : .narrow,
                             sidebarVisible: .constant(false))
                    .safeAreaPadding(.bottom, keyboard.room)
                    .environment(\.keyboardRoom, keyboard.room)
            }
        }
    }

    override func setUp() async throws {
        let suite = "fold-layout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        prefs = Prefs(defaults: defaults)
        // The keyboard comes and goes only as the test says.
        UserDefaults.standard.set("none", forKey: "focus")
        window = UIWindow(frame: CGRect(origin: .zero, size: folded))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "focus")
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        prefs = nil
    }

    #if DEBUG
    /// One session with one tab of one pane, which runs an agent (from its foreground program).
    private func model() -> (AppModel, ServerConnection) {
        let model = AppModel(prefs: prefs, connect: false)
        let s = ServerConnection(config: ServerConfig(name: "desk", url: "https://desk-rex.tail1234.ts.net"),
                                 prefs: prefs, notifier: model.notifier, deviceID: "a1b2c3d4")
        model.servers.append(s)
        let window: JSONObject = ["window_id": "w0", "label": "api", "focused_block_id": "b0",
                                  "layers": [["kind": "tiled", "layer_id": "l", "bounds": [0, 0, 1, 1],
                                              "blocks": [["block_id": "b0", "creator_name": "com.superlogical.terminal",
                                                          "label": "shell"] as JSONObject],
                                              "layout": ["rect": [0, 0, 1, 1], "block_id": "b0"] as JSONObject] as JSONObject]]
        s.sessions = [SessionEntry(id: "work", label: "work")]
        s.views = ["work": SessionView(["revision": 1, "session_id": "work", "label": "work", "active_window_id": "w0",
                                        "windows": [window]])]
        var meta = BlockMeta()
        meta.foreground = "claude"
        s.meta["b0"] = meta
        s.phase = .online
        s.synced = true
        s.agentsWereRead()
        return (model, s)
    }

    private func wait(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private func resize(to size: CGSize) async {
        window.frame = CGRect(origin: .zero, size: size)
        window.layoutIfNeeded()
        // The layout settles and the claim's 120 ms settle runs out, with room to spare.
        await wait(0.6)
    }

    /// The server's echo of the newest resize, as the stream brings it.
    private func echo(_ host: TerminalHost, _ transport: Transport) throws {
        let last = try XCTUnwrap(transport.resizes.last)
        host.streamResized(cols: last.cols, rows: last.rows, owner: nil)
        host.layoutIfNeeded()
    }

    /// The grid fills the pane: no row cut at its bottom, less than a row left under it, and
    /// nothing shifted for a keyboard that isn't there.
    private func assertFills(_ host: TerminalHost, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        let cell = host.term.cellSize.height
        let grid = CGFloat(host.term.rows) * cell
        XCTAssertLessThanOrEqual(grid, host.bounds.height + 1, "\(what): no row cut", file: file, line: line)
        XCTAssertLessThan(host.bounds.height - grid, cell, "\(what): no band of a row under the grid", file: file, line: line)
        XCTAssertEqual(host.term.scroller.cover, 0, "\(what): nothing covered", file: file, line: line)
    }

    private func fits(_ host: TerminalHost) -> (cols: Int, rows: Int) {
        TerminalLayout.fitGrid(in: host.bounds.size, cell: host.term.cellSize)
    }

    private func run(_ navigation: NavigationStyle) async throws {
        prefs.navigation = navigation
        let (model, s) = model()
        let pool = TerminalHostPool()
        let transport = Transport()
        let host = TerminalHost(stream: TerminalStream(control: s.control, sessionID: "work", blockID: "b0"), sizing: .fit,
                                fontSize: CGFloat(prefs.fontSize), theme: ThemeStore.fallback, claim: FitClaim(transport: transport))
        pool.add(host, for: TerminalHostPool.Key(server: s.id, session: "work", block: "b0"))
        let keyboard = FoldKeyboard()
        window.rootViewController = UIHostingController(rootView: Root(server: s, keyboard: keyboard)
            .environment(model).environment(prefs).environment(pool))
        window.makeKeyAndVisible()
        await wait(0.6)

        // Folded: one resize, to the pane.
        XCTAssertEqual(transport.resizes.count, 1)
        let foldedGrid = try XCTUnwrap(transport.resizes.last)
        XCTAssertTrue(foldedGrid == fits(host))
        try echo(host, transport)
        assertFills(host, "folded")

        // Unfold: one resize, to the wide pane.
        await resize(to: unfolded)
        XCTAssertEqual(transport.resizes.count, 2, "one resize for the unfold")
        let unfoldedGrid = try XCTUnwrap(transport.resizes.last)
        XCTAssertTrue(unfoldedGrid == fits(host))
        XCTAssertNotEqual(unfoldedGrid.rows, foldedGrid.rows, "the postures have their own rows")
        try echo(host, transport)
        assertFills(host, "unfolded")

        // The keyboard covers the pane: no resize.
        keyboard.room = 250
        await wait(0.6)
        XCTAssertEqual(transport.resizes.count, 2, "the keyboard covers the pane, it doesn't resize it")

        // Folded with the keyboard up: one resize, to the folded pane with the keyboard down, not
        // to the unfolded height kept from before the keyboard showed.
        await resize(to: folded)
        XCTAssertEqual(transport.resizes.count, 3, "one resize for the fold")
        let foldedAgain = try XCTUnwrap(transport.resizes.last)
        XCTAssertTrue(foldedAgain == foldedGrid, "the folded pane's grid, keyboard or not")
        try echo(host, transport)

        // The keyboard goes down: nothing to send.
        keyboard.room = 0
        await wait(0.6)
        XCTAssertEqual(transport.resizes.count, 3, "the keyboard going down after the fold sends nothing")
        assertFills(host, "folded, keyboard down")

        // Unfold with the keyboard up, then down: one resize in all.
        keyboard.room = 250
        await wait(0.6)
        await resize(to: unfolded)
        keyboard.room = 0
        await wait(0.6)
        XCTAssertEqual(transport.resizes.count, 4)
        XCTAssertTrue(try XCTUnwrap(transport.resizes.last) == unfoldedGrid)
        try echo(host, transport)
        assertFills(host, "unfolded again")

        // The tab's chip, whatever the posture: one pane, one icon, its agent's.
        let w = try XCTUnwrap(s.views["work"]?.window("w0"))
        let chip = TabChip.of(w, position: 1, count: 1, server: s, active: true, block: "b0", strip: nil)
        XCTAssertEqual(chip.icons, [TabChip.Icon(id: "b0", agent: .claude)])

        // The terminal goes, so no pane is left on the render thread for the next test.
        window.rootViewController = nil
        host.stop()
        host.removeFromSuperview()
        await wait(0.2)
    }

    func testAFoldResizesThePaneOnceInTabMode() async throws {
        try await run(.tabs)
    }

    func testAFoldResizesThePaneOnceInSidebarMode() async throws {
        try await run(.sidebar)
    }
    #endif
}
