import Foundation
import RexKit
import XCTest
@testable import RexDuo

/// The palette with servers behind it: what it lists, how it keeps its selection across a
/// rebuild, what rebuilds it, the keyboard hold and hand-back, its keys, and every API revision
/// it meets (questions from the phone's own runs included).
@MainActor
final class GoToModelTests: XCTestCase {
    private var models: [AppModel] = []

    private func model() -> AppModel {
        let suite = "goto-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let m = AppModel(prefs: Prefs(defaults: d), connect: false)
        m.firstSeenWaiting = { [:] }
        models.append(m)
        return m
    }

    private func server(_ m: AppModel, _ name: String = "desk") -> ServerConnection {
        let s = ServerConnection(config: ServerConfig(name: name, url: "https://\(name)-rex.tail1234.ts.net"),
                                 prefs: m.prefs, notifier: m.notifier, deviceID: "a1b2c3d4")
        m.servers.append(s)
        m.palette.attach(s)
        return s
    }

    private static func block(_ id: String) -> JSONObject {
        ["block_id": id, "creator_name": "com.superlogical.terminal", "flavor": "com.superlogical.terminal.shell",
         "host_id": "host-a", "label": "shell"]
    }

    /// Sessions of tabs of blocks; a tab with two blocks is split.
    private func load(_ s: ServerConnection, _ sessions: [(String, [(String, [String])])], online: Bool = true) {
        s.sessions = sessions.map { SessionEntry(id: $0.0, label: $0.0) }
        var views: [String: SessionView] = [:]
        for (sid, tabs) in sessions {
            let windows = tabs.map { wid, blocks -> JSONObject in
                var layout: JSONObject = ["rect": [0, 0, 1, 1], "block_id": blocks[0]]
                if blocks.count == 2 {
                    layout = ["rect": [0, 0, 1, 1], "split": [
                        "split_id": "split:\(wid)", "direction": "horizontal", "ratio": 0.5,
                        "before": ["block_id": blocks[0], "rect": [0, 0, 0.5, 1]],
                        "after": ["block_id": blocks[1], "rect": [0.5, 0, 0.5, 1]],
                    ] as JSONObject]
                }
                return ["window_id": wid, "label": wid, "focused_block_id": blocks[0],
                        "layers": [["kind": "tiled", "layer_id": "l", "bounds": [0, 0, 1, 1],
                                    "blocks": blocks.map(Self.block), "layout": layout] as JSONObject]]
            }
            views[sid] = SessionView(["revision": 1, "session_id": sid, "label": sid, "active_window_id": tabs[0].0,
                                      "windows": windows])
        }
        s.views = views
        s.phase = online ? .online : .offline(ConnectionProblem(kind: .notAnswering, detail: "test"))
        s.synced = true
    }

    private func copy(_ m: AppModel, target: GoToTarget? = nil) -> GoToSource.Copy {
        var c = GoToSource.Copy()
        GoToSource.places(m.servers, target: target, waiting: [], into: &c, scope: .anything)
        GoToCommands.add(m.servers, target: target, waitingCount: 0, into: &c)
        return c
    }

    private func eventually(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func wait(_ ms: UInt64) async { try? await Task.sleep(nanoseconds: ms * 1_000_000) }

    // MARK: What it lists

    func testOnlyTabsWithSeveralPanesListTheirPanes() {
        let m = model()
        let s = server(m)
        load(s, [("api", [("w1", ["b1"]), ("w2", ["b2", "b3"])])])
        let ids = copy(m).items.map(\.id)
        XCTAssertTrue(ids.contains(.session(s.id, "api")))
        XCTAssertTrue(ids.contains(.tab(s.id, "api", "w1")))
        XCTAssertFalse(ids.contains(.pane(s.id, "api", "w1", "b1")), "a one-pane tab's row covers its pane")
        XCTAssertTrue(ids.contains(.pane(s.id, "api", "w2", "b2")))
        XCTAssertTrue(ids.contains(.pane(s.id, "api", "w2", "b3")))
    }

    func testAnOfflineServerStaysListedAndSaysSo() throws {
        let m = model()
        let s = server(m)
        load(s, [("api", [("w1", ["b1"])])], online: false)
        let tab = try XCTUnwrap(copy(m).items.first { $0.id == .tab(s.id, "api", "w1") })
        XCTAssertTrue(tab.offline)
        XCTAssertTrue(tab.subtitle.hasSuffix("offline"))
        XCTAssertTrue(copy(m).synced.isEmpty, "a down server's recents are kept")
    }

    func testHelperSessionsAreLeftOut() {
        let m = model()
        let s = server(m)
        load(s, [("api", [("w1", ["b1"])]), ("helper", [("w9", ["b9"])])])
        s.hiddenSessions = { ["helper"] }
        XCTAssertFalse(copy(m).items.contains { $0.id == .session(s.id, "helper") })
    }

    func testTwoServersAreToldApartByTheMachine() throws {
        let m = model()
        let a = server(m, "studio"), b = server(m, "laptop")
        load(a, [("api", [("w1", ["b1"])])])
        load(b, [("api", [("w1", ["b1"])])])
        let c = copy(m)
        let sa = try XCTUnwrap(c.items.first { $0.id == .tab(a.id, "api", "w1") })
        let sb = try XCTUnwrap(c.items.first { $0.id == .tab(b.id, "api", "w1") })
        XCTAssertTrue(sa.subtitle.hasPrefix("studio"))
        XCTAssertTrue(sb.subtitle.hasPrefix("laptop"))
    }

    func testWithNoTabNoPaneCommandShows() {
        let m = model()
        let s = server(m)
        load(s, [("api", [("w1", ["b1", "b2"])])])
        let titles = copy(m).items.filter { $0.kind == .command }.map(\.title)
        XCTAssertTrue(titles.contains("Settings…"))
        XCTAssertFalse(titles.contains("Close Pane"))
        XCTAssertFalse(titles.contains("Split Pane Right"))
        XCTAssertFalse(titles.contains { $0 == "Go to Anything…" || $0 == "Change Session…" || $0 == "Command Palette…" })
    }

    func testCommandRowsFollowThePaneMenusGate() {
        let m = model()
        let s = server(m)
        load(s, [("api", [("w1", ["b1", "b2"]), ("w2", ["b3"])])])
        let t = GoToTarget(serverID: s.id, sessionID: "api", windowID: "w1", blockID: "b1", canZoom: true)
        // Revision 0: the pane menu hides Arrange's commands, and so does the palette.
        var titles = copy(m, target: t).items.filter { $0.kind == .command }.map(\.title)
        XCTAssertTrue(titles.contains("Close Pane"))
        XCTAssertTrue(titles.contains("Zoom Pane"))
        XCTAssertFalse(titles.contains("Balance Splits"))
        XCTAssertFalse(titles.contains("Close Other Panes"))
        XCTAssertFalse(titles.contains("Move Pane to Tab…"))
        s.capabilities.connected(serial: 1, revision: 18, serverRevision: 18, features: [])
        titles = copy(m, target: t).items.filter { $0.kind == .command }.map(\.title)
        XCTAssertTrue(titles.contains("Balance Splits"))
        XCTAssertTrue(titles.contains("Close Other Panes"))
        XCTAssertTrue(titles.contains("Move Pane to Tab…"))
        // A server that turned out to lack a method: the row goes again.
        s.capabilities.record(method: "session.resize_pane", host: nil, .absent, serial: 1)
        titles = copy(m, target: t).items.filter { $0.kind == .command }.map(\.title)
        XCTAssertFalse(titles.contains("Balance Splits"))
    }

    func testFilesCommandsShowOnlyWhereThePanesHostHasTheirMethod() {
        let m = model()
        let s = server(m)
        load(s, [("api", [("w1", ["b1", "b2"])])])
        let t = GoToTarget(serverID: s.id, sessionID: "api", windowID: "w1", blockID: "b1")
        let all = FilesCommand.allCases.map(\.title)
        func rows(_ target: GoToTarget?) -> [GoToItem] { copy(m, target: target).items.filter { all.contains($0.title) } }
        // Nothing known about the host: no row, exactly as before.
        XCTAssertTrue(rows(t).isEmpty)
        var meta = BlockMeta()
        meta.foreground = "zsh"
        s.meta["b1"] = meta
        // Only list_dir: the browse rows.
        s.capabilities.record(method: FileMethod.listDir.full, host: "host-a", .present, serial: s.capabilities.serial)
        XCTAssertEqual(rows(t).map(\.title), ["Browse Files…", "Insert Path…"])
        // And uploads: the two pickers too.
        s.capabilities.record(method: FileMethod.upload.full, host: "host-a", .present, serial: s.capabilities.serial)
        let four = rows(t)
        XCTAssertEqual(four.map(\.title), ["Browse Files…", "Insert Path…", "Insert File…", "Insert Photo…"])
        XCTAssertTrue(four.allSatisfy { $0.kind == .command && $0.category == "Pane" && $0.dimmed == nil && !$0.destructive })
        XCTAssertTrue(four.allSatisfy { $0.keyLabel == nil }, "no key unless the keymap binds one")
        let c = copy(m, target: t)
        for (item, command) in zip(four, FilesCommand.allCases) {
            XCTAssertEqual(item.id, .command(GoToCommands.appKey(command.action)))
            guard case .files(let run)? = c.runs[item.id] else { return XCTFail(item.title) }
            XCTAssertEqual(run, command)
        }
        // A key bound in the keymap shows on its row.
        s.keymap.apply([KeyBinding(chord: KeyChord(spelling: "ctrl+cmd+i")!, action: "pane.insert_path", args: nil)] + KeyDefaults.resolved)
        XCTAssertEqual(rows(t).first { $0.title == "Insert Path…" }?.keyLabel, "⌃⌘I")
        // A pane running ssh keeps Browse and loses Insert Path.
        meta.foreground = "ssh"
        s.meta["b1"] = meta
        XCTAssertEqual(rows(t).map(\.title), ["Browse Files…", "Insert File…", "Insert Photo…"])
        // Another host of the same server answers for itself; no tab, no rows; offline, no rows.
        XCTAssertFalse(s.offers(.browse, host: "host-b", block: "b1"))
        XCTAssertTrue(rows(nil).isEmpty)
        s.phase = .offline(ConnectionProblem(kind: .notAnswering, detail: "test"))
        XCTAssertTrue(rows(t).isEmpty)
    }

    /// The files rows have words besides their titles: each of them finds Insert Photo… and
    /// Browse Files…, and a word no row has still finds nothing.
    func testFilesCommandsAreFoundByTheirSynonyms() async {
        let m = model()
        let s = server(m)
        load(s, [("api", [("w1", ["b1"])])])
        var meta = BlockMeta()
        meta.foreground = "zsh"
        s.meta["b1"] = meta
        for method in [FileMethod.listDir, .upload] {
            s.capabilities.record(method: method.full, host: "host-a", .present, serial: s.capabilities.serial)
        }
        let t = GoToTarget(serverID: s.id, sessionID: "api", windowID: "w1", blockID: "b1")
        let items = copy(m, target: t).items
        let searcher = GoToSearcher()
        await searcher.load(items)
        for word in ["image", "photo", "picture", "screenshot", "attach", "upload", "file", "send"] {
            let titles = await searcher.search(word, scope: .commands, boosts: [:]).map { items[$0.index].title }
            XCTAssertTrue(titles.contains("Insert Photo…"), word)
            XCTAssertTrue(titles.contains("Browse Files…"), word)
        }
        let none = await searcher.search("zebra", scope: .commands, boosts: [:])
        XCTAssertTrue(none.isEmpty)
    }

    func testBlockActionsShowOnlyWhereTheCreatorListsThem() {
        let m = model()
        let s = server(m)
        load(s, [("api", [("w1", ["b1"])])])
        let t = GoToTarget(serverID: s.id, sessionID: "api", windowID: "w1", blockID: "b1")
        func titles() -> [String] { copy(m, target: t).items.filter { $0.kind == .command }.map(\.title) }
        XCTAssertFalse(titles().contains("Clear Terminal"), "an unknown creator list hides them")
        s.capabilities.connected(serial: 1, revision: 18, serverRevision: 18, features: [])
        s.capabilities.status(instance: "i", hostID: "host-a")
        s.capabilities.creatorsLoaded(["creators": [["name": "com.superlogical.terminal", "host_id": "host-a",
                                                     "api": ["methods": ["clear": [:], "write": [:]]]] as JSONObject]],
                                      serial: 1)
        XCTAssertTrue(titles().contains("Clear Terminal"))
        XCTAssertFalse(titles().contains("Reset Terminal"))
        XCTAssertEqual(copy(m, target: t).items.first { $0.title == "Clear Terminal" }?.destructive, true)
    }

    func testCopyModeShowsDimmedOnlyWhereTheKeymapBindsIt() throws {
        let m = model()
        let s = server(m)
        load(s, [("api", [("w1", ["b1"])])])
        XCTAssertFalse(copy(m).items.contains { $0.title.hasPrefix("Copy Mode") })
        s.keymap.apply([KeyBinding(chord: KeyChord(spelling: "shift+cmd+c")!, action: "pane.copy_mode.enter", args: nil)] + KeyDefaults.resolved)
        let row = try XCTUnwrap(copy(m).items.first { $0.title == "Copy Mode" })
        XCTAssertEqual(row.dimmed, GoToCommands.copyModeNote)
    }

    // MARK: Open, select, rebuild

    private func open(_ m: AppModel, _ scope: GoToScope = .anything, target: GoToTarget? = nil) throws -> GoToModel {
        m.palette.open(scope, target: target)
        let s = try XCTUnwrap(m.goTo)
        s.throttle = .milliseconds(30)
        return s
    }

    func testTheEmptyQueryShowsRowsAtOnce() throws {
        let m = model()
        load(server(m), [("api", [("w1", ["b1"]), ("w2", ["b2"])])])
        let s = try open(m)
        XCTAssertFalse(s.rows.isEmpty, "no wait for the index")
        m.palette.close()
        XCTAssertNil(m.goTo)
    }

    func testATypedQueryFindsTheTab() async throws {
        let m = model()
        let srv = server(m)
        load(srv, [("api", [("w1", ["b1"]), ("logs", ["b2"])])])
        let s = try open(m)
        s.setQuery("logs")
        let found = await eventually { s.rows.first?.id == .tab(srv.id, "api", "logs") }
        XCTAssertTrue(found)
        XCTAssertEqual(s.selected, .tab(srv.id, "api", "logs"))
    }

    func testARebuildBetweenTheArrowAndReturnRunsTheSelectedItem() async throws {
        let m = model()
        let srv = server(m)
        load(srv, [("b", [("w1", ["b1"]), ("w2", ["b2"])])])
        let s = try open(m)
        s.move(by: 1)
        let picked = try XCTUnwrap(s.selected)
        // A new session lands in front: every row below it moves down one.
        load(srv, [("a", [("w9", ["b9"])]), ("b", [("w1", ["b1"]), ("w2", ["b2"])])])
        let rebuilt = await eventually { s.rebuilds > 0 && s.rows.first?.id == .session(srv.id, "a") }
        XCTAssertTrue(rebuilt)
        XCTAssertEqual(s.selected, picked, "the selection stays on its item")
        s.runSelected()
        guard case .tab(_, let sid, let wid) = picked else { return XCTFail("a tab was selected: \(picked)") }
        XCTAssertEqual(m.openRequest?.selection, Selection(serverID: srv.id, sessionID: sid, windowID: wid))
        XCTAssertNil(m.goTo)
    }

    func testATitleChangeDoesntRebuild() async throws {
        let m = model()
        let srv = server(m)
        load(srv, [("api", [("w1", ["b1"])])])
        let s = try open(m)
        var meta = BlockMeta()
        meta.title = "vim"
        srv.meta["b1"] = meta
        meta.pwd = "/tmp"
        srv.meta["b1"] = meta
        await wait(150)
        XCTAssertEqual(s.rebuilds, 0)
    }

    func testABurstOfAgentChangesRebuildsAtMostOncePerThrottle() async throws {
        let m = model()
        let srv = server(m)
        load(srv, [("api", [("w1", ["b1"]), ("w2", ["b2"])])])
        let s = try open(m)
        s.throttle = .milliseconds(250)
        for i in 0..<6 {
            var meta = BlockMeta()
            meta.statuses = ["claude": ProgramStatus(["id": "claude", "app": "claude", "state": i % 2 == 0 ? "blocked" : "working"])]
            srv.meta[i % 2 == 0 ? "b1" : "b2"] = meta
            await wait(30)
        }
        await wait(300)
        XCTAssertLessThanOrEqual(s.rebuilds, 2)
        XCTAssertGreaterThanOrEqual(s.rebuilds, 1)
    }

    func testAChevronGoesToCommandsAndBackspaceComesBack() throws {
        let m = model()
        load(server(m), [("api", [("w1", ["b1"])])])
        let s = try open(m)
        s.setQuery(">")
        XCTAssertEqual(s.scope, .commands)
        XCTAssertEqual(s.query, "")
        s.backspaceOnEmpty()
        XCTAssertEqual(s.scope, .anything)
        // Without the chevron, backspace leaves the commands palette alone.
        m.palette.keyPressed(.commands)
        s.backspaceOnEmpty()
        XCTAssertEqual(s.scope, .commands)
    }

    func testThePaletteKeysSwitchAndClose() throws {
        let m = model()
        load(server(m), [("api", [("w1", ["b1"])])])
        let s = try open(m, .anything)
        s.setQuery("ap")
        m.palette.keyPressed(.sessions)
        XCTAssertEqual(s.scope, .sessions)
        XCTAssertEqual(s.query, "ap", "the text stays")
        m.palette.keyPressed(.sessions)
        XCTAssertNil(m.goTo, "the same key closes it")
    }

    func testTheTentBoardClosesItAndItDoesntOpenUnderIt() throws {
        let m = model()
        load(server(m), [("api", [("w1", ["b1"])])])
        _ = try open(m)
        m.boardShown = true
        m.palette.boardShown()
        XCTAssertNil(m.goTo)
        m.palette.open(.anything, target: nil)
        XCTAssertNil(m.goTo)
    }

    func testAPlaceThatClosedSaysSoAndLeavesTheRecents() throws {
        let m = model()
        let srv = server(m)
        load(srv, [("api", [("w1", ["b1"]), ("w2", ["b2"])])])
        let id = GoToItemID.tab(srv.id, "api", "w2")
        m.prefs.goToRecents = GoToRecents.record(id, at: Date(), in: [])
        let s = try open(m)
        load(srv, [("api", [("w1", ["b1"])])])
        s.run(id)
        XCTAssertNil(m.goTo)
        XCTAssertEqual(Notice.shared.message, "That tab closed.")
        XCTAssertTrue(m.prefs.goToRecents.isEmpty)
        Notice.shared.dismiss()
    }

    func testAPickIsRemembered() throws {
        let m = model()
        let srv = server(m)
        load(srv, [("api", [("w1", ["b1"]), ("w2", ["b2"])])])
        let s = try open(m)
        s.run(.tab(srv.id, "api", "w2"))
        XCTAssertEqual(m.prefs.goToRecents.first?.itemID, .tab(srv.id, "api", "w2"))
    }

    // MARK: The keyboard hold

    func testEveryWayItClosesEndsTheHoldAndAppliesTheLastValue() async throws {
        let m = model()
        load(server(m), [("api", [("w1", ["b1"])])])
        let hold = m.palette.padHold
        var applied: [CGFloat] = []
        hold.apply[.pad] = { applied.append($0) }
        let closes: [(String, () -> Void)] = [
            ("Esc", { m.goTo?.dismiss() }),
            ("a run", { m.palette.run(.command(GoToCommands.appKey("client.settings"))) }),
            ("the tent board", { m.palette.boardShown() }),
            ("a palette key", { m.palette.keyPressed(.anything) }),
        ]
        for (name, close) in closes {
            applied = []
            _ = try open(m)
            XCTAssertTrue(hold.active, name)
            XCTAssertTrue(hold.offer(.pad, 300), "a new value waits aside while open (\(name))")
            close()
            XCTAssertNil(m.goTo, name)
            let ended = await eventually(1) { !hold.active }
            XCTAssertTrue(ended, name)
            XCTAssertEqual(applied, [300], name)
            XCTAssertFalse(hold.offer(.pad, 0), "no hold once closed (\(name))")
        }
    }

    func testAWidthChangeEndsTheHoldAtOnce() throws {
        let m = model()
        let hold = m.palette.padHold
        var applied: [CGFloat] = []
        hold.apply[.pad] = { applied.append($0) }
        _ = try open(m)
        _ = hold.offer(.pad, 120)
        hold.endNow()
        XCTAssertFalse(hold.active)
        XCTAssertEqual(applied, [120])
        XCTAssertNotNil(m.goTo, "the palette stays; only the hold ends")
        m.palette.close()
    }

    func testTheHoldEndsAtTheFirstKeyboardChangeAfterTheHandBack() async throws {
        let m = model()
        let hold = m.palette.padHold
        var applied: [CGFloat] = []
        hold.apply[.pad] = { applied.append($0) }
        _ = try open(m)
        _ = hold.offer(.pad, 44)
        m.palette.close()
        XCTAssertTrue(hold.active, "it waits for the keyboard")
        _ = hold.offer(.pad, 336)
        let ended = await eventually(0.2) { !hold.active }
        XCTAssertTrue(ended, "well before the 300 ms")
        XCTAssertEqual(applied, [336])
    }

    func testFindsHoldIsDeferredWhileThePaletteIsOpen() throws {
        let m = model()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try XCTSkipUnless(GoToCenter.keyWindow() === window, "no key window in the test host")
        _ = try open(m)
        XCTAssertTrue(FitHoldDeferral.isSet(in: window))
        m.palette.close()
        XCTAssertFalse(FitHoldDeferral.isSet(in: window))
    }

    // MARK: Hand-back, with real hosts

    private func hostRig() throws -> (window: UIWindow, pool: TerminalHostPool, a: TerminalHost, b: TerminalHost,
                                      keyA: TerminalHostPool.Key, keyB: TerminalHostPool.Key) {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        try XCTSkipUnless(UIApplication.shared.applicationState == .active, "the test host is not in the foreground")
        let pool = TerminalHostPool()
        func host() -> TerminalHost {
            let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
            let h = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: "b"), sizing: .mirror,
                                 fontSize: 12, theme: ThemeStore.fallback)
            h.hardwareKeyboard = { false }
            h.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
            window.rootViewController?.view.addSubview(h)
            return h
        }
        let a = host(), b = host()
        let server = UUID()
        let keyA = TerminalHostPool.Key(server: server, session: "s", block: "a")
        let keyB = TerminalHostPool.Key(server: server, session: "s", block: "b")
        pool.add(a, for: keyA)
        pool.add(b, for: keyB)
        return (window, pool, a, b, keyA, keyB)
    }

    private func settle() async {
        for _ in 0..<4 { await withCheckedContinuation { c in DispatchQueue.main.async { c.resume() } } }
    }

    /// Opens the palette on pane A and puts its field in the window, as the overlay does.
    private func openOnA(_ m: AppModel, _ r: (window: UIWindow, pool: TerminalHostPool, a: TerminalHost, b: TerminalHost,
                                              keyA: TerminalHostPool.Key, keyB: TerminalHostPool.Key)) -> PaletteField {
        m.palette.pool = r.pool
        m.palette.open(.anything, target: GoToTarget(serverID: r.keyA.server, sessionID: "s", windowID: "w", blockID: "a"))
        let field = PaletteField(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        field.focusOnAppear = false
        m.goTo?.field = field
        r.window.rootViewController?.view.addSubview(field)
        _ = field.becomeFirstResponder()
        return field
    }

    func testTheKeyboardComesBackAsItWas() async throws {
        for quiet in [false, true] {
            let m = model()
            let r = try hostRig()
            r.a.isActive = true
            r.a.retakeKeyboard(quiet ? .quiet : .shown)
            await settle()
            try XCTSkipUnless(r.a.term.isFirstResponder, "the test host gave no first responder")
            let field = openOnA(m, r)
            XCTAssertTrue(field.isFirstResponder)
            XCTAssertFalse(r.a.term.isFirstResponder)
            m.palette.close()
            await settle()
            XCTAssertTrue(r.a.term.isFirstResponder, "quiet \(quiet)")
            XCTAssertEqual(r.a.keyboardQuiet, quiet)
            XCTAssertFalse(field.isFirstResponder)
            r.window.isHidden = true
        }
    }

    func testAKeyboardThatWasDownStaysDown() async throws {
        let m = model()
        let r = try hostRig()
        r.a.isActive = true
        await settle()
        if r.a.term.isFirstResponder { _ = r.a.term.resignFirstResponder() }
        let field = openOnA(m, r)
        m.palette.close()
        await settle()
        XCTAssertFalse(r.a.term.isFirstResponder)
        XCTAssertFalse(field.isFirstResponder)
        r.window.isHidden = true
    }

    func testAPickOfAnotherPaneGivesItTheKeyboardOnce() async throws {
        let m = model()
        let r = try hostRig()
        r.a.isActive = true
        r.a.retakeKeyboard(.shown)
        await settle()
        try XCTSkipUnless(r.a.term.isFirstResponder, "the test host gave no first responder")
        _ = openOnA(m, r)
        m.palette.close(.other(r.keyB))
        // The new pane becomes the active one, as the tab switch makes it.
        r.a.isActive = false
        r.b.isActive = true
        await settle()
        XCTAssertTrue(r.b.term.isFirstResponder)
        XCTAssertFalse(r.a.term.isFirstResponder)
        XCTAssertFalse(r.b.keyboardQuiet)
        // Owed once: the next time A becomes active it doesn't take one unasked.
        _ = r.b.term.resignFirstResponder()
        r.b.isActive = false
        r.a.isActive = true
        await settle()
        XCTAssertFalse(r.a.term.isFirstResponder)
        r.window.isHidden = true
    }

    func testAnOwedKeyboardRunsOut() async throws {
        let pool = TerminalHostPool()
        let key = TerminalHostPool.Key(server: UUID(), session: "s", block: "b")
        var settled = 0
        pool.onOwedSettled = { settled += 1 }
        pool.owe(key, quiet: false)
        XCTAssertNil(pool.takeOwed(TerminalHostPool.Key(server: UUID(), session: "s", block: "x")), "another pane's")
        let expired = await eventually(3) { settled == 1 }
        XCTAssertTrue(expired)
        XCTAssertNil(pool.takeOwed(key))
    }

    // MARK: Keys

    private func keymap(_ list: [(String, String, JSONObject?)]) -> KeymapStore {
        let k = KeymapStore(control: RexControl(address: "", client: ClientInfo(name: "t", version: "0", label: "t")))
        let top = list.reversed().map { KeyBinding(chord: KeyChord(spelling: $0.0)!, action: $0.1, args: $0.2) }
        k.apply(top + KeyDefaults.resolved)
        return k
    }

    func testEachPaletteActionHasItsScope() {
        XCTAssertEqual(command(AppAction.resolve("pane.go_to", nil)), .goTo(.anything))
        XCTAssertEqual(command(AppAction.resolve("session.switch", nil)), .goTo(.sessions))
        XCTAssertEqual(command(AppAction.resolve("client.palette.toggle", nil)), .goTo(.commands))
        XCTAssertEqual(command(AppAction.resolve("client.tab.overview", nil)), .tabOverview)
    }

    private func command(_ a: AppAction?) -> RexCommand? {
        if case .command(let c)? = a { return c }
        return nil
    }

    func testTheUsersInitLuaKeysWin() throws {
        // This user's init.lua: cmd+k clears, shift+cmd+k changes session.
        let k = keymap([("cmd+k", "com.superlogical.terminal.clear", nil), ("shift+cmd+k", "session.switch", nil)])
        guard case .server(let name, _)? = k.resolve([KeyChord(spelling: "cmd+k")!])?.1 else { return XCTFail("cmd+k") }
        XCTAssertEqual(name, "com.superlogical.terminal.clear")
        XCTAssertEqual(command(k.resolve([KeyChord(spelling: "shift+cmd+k")!])?.1), .goTo(.sessions))
        XCTAssertEqual(command(k.resolve([KeyChord(spelling: "cmd+p")!])?.1), .goTo(.anything))
        XCTAssertEqual(command(k.resolve([KeyChord(spelling: "shift+cmd+p")!])?.1), .goTo(.commands))
        XCTAssertEqual(command(k.resolve([KeyChord(spelling: "shift+cmd+\\")!])?.1), .tabOverview)
        XCTAssertEqual(KeyLabel.for(action: "pane.go_to", in: k), "⌘P")
        XCTAssertEqual(KeyLabel.for(action: "session.switch", in: k), "⇧⌘K")
    }

    func testCopyModeAndMuteNeverReachTheServer() {
        for name in ["pane.copy_mode.enter", "pane.copy_mode.search", "client.tab.mute"] {
            XCTAssertNil(AppAction.resolve(name, nil), name)
        }
    }

    func testThePaletteFieldsKeys() {
        let f = PaletteField(frame: .zero)
        XCTAssertEqual(f.keyCommands?.count, 4)
        XCTAssertTrue(f.keyCommands?.allSatisfy { $0.modifierFlags.isEmpty && $0.wantsPriorityOverSystemBehavior } ?? false)
        XCTAssertEqual(f.autocorrectionType, .no)
        XCTAssertEqual(f.autocapitalizationType, .none)
        XCTAssertEqual(f.smartQuotesType, .no)
        XCTAssertEqual(f.smartDashesType, .no)
        XCTAssertEqual(f.spellCheckingType, .no)
        XCTAssertEqual(f.returnKeyType, .go)
        var returned = 0
        f.onReturn = { returned += 1 }
        XCTAssertFalse(f.textFieldShouldReturn(f))
        XCTAssertEqual(returned, 1)
        var backspaced = 0
        f.onBackspaceEmpty = { backspaced += 1 }
        f.deleteBackward()
        XCTAssertEqual(backspaced, 1)
    }

    func testThePaletteFieldsKeysGoQuietWhileComposing() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 100))
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let f = PaletteField(frame: CGRect(x: 0, y: 0, width: 200, height: 30))
        f.focusOnAppear = false
        window.addSubview(f)
        _ = f.becomeFirstResponder()
        f.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0))
        try XCTSkipUnless(f.markedTextRange != nil, "no marked text in the test host")
        XCTAssertEqual(f.keyCommands?.count, 0)
        f.unmarkText()
        XCTAssertEqual(f.keyCommands?.count, 4)
    }

    func testTheHoldCmdListShowsThePaletteKeys() {
        let titles = AppShortcuts.list(KeyDefaults.resolved).map(\.title)
        XCTAssertTrue(titles.contains("Go to Anything…"))
        XCTAssertTrue(titles.contains("Change Session…"))
        XCTAssertTrue(titles.contains("Command Palette…"))
        XCTAssertTrue(titles.contains("Show All Tabs"))
    }

    // MARK: Against a server, at every revision

    @MainActor
    final class Rig {
        let fake: FakeRexServer
        let server: ServerConnection
        let model: AppModel

        init(revision: Int?, keymap: FakeRexServer.Reply) async throws {
            fake = try FakeRexServer(revision: revision, serverRevision: revision)
            let address = await fake.start()
            let name = "GoToRig-\(UUID().uuidString)"
            let d = UserDefaults(suiteName: name)!
            d.removePersistentDomain(forName: name)
            let prefs = Prefs(defaults: d)
            model = AppModel(prefs: prefs, connect: false)
            server = ServerConnection(config: ServerConfig(name: "Desk", url: address), prefs: prefs,
                                      notifier: model.notifier, deviceID: "a1b2c3d4")
            model.servers = [server]
            model.palette.attach(server)
            fake.onRequest { r in
                switch r.method {
                case "session.attach", "session.view":
                    return .result(["view": ServerEventsTests.view(r.payload.str("session_id") ?? "")])
                case "session.bootstrap":
                    return .result(ServerEventsTests.bootstrap(["session:1"]))
                case "session.list":
                    return .result(["sessions": [["session_id": "session:1", "label": "zz-1"]]])
                default:
                    return nil
                }
            }
            fake.reply("client.keymap", keymap)
            fake.reply("client.reply", [:])
            fake.reply("hosts.list", ["hosts": [JSONObject]()])
            fake.reply("server.version", ["platform": "darwin_arm64"])
            fake.reply("server.whoami", [:])
            fake.reply("block_creator.list", ServerEventsTests.creators())
        }

        func connect() async {
            server.start()
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, !(server.synced && fake.count("client.keymap") >= 1) {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        func stop() {
            server.stop()
            fake.stop()
        }
    }

    static let configured: JSONObject = [
        "bindings": [["keys": ["cmd+p"], "action": "pane.go_to"] as JSONObject],
        "config": ["hash": "h", "instance_id": "i"] as JSONObject,
        "actions": [["name": "dev_layout", "kind": "lua", "title": "Dev Layout", "category": "Layouts"] as JSONObject],
    ]

    /// A server from before `server_actions`: it lists everything, block methods included.
    static let all: JSONObject = [
        "bindings": [JSONObject](),
        "config": ["hash": "h", "instance_id": "i"] as JSONObject,
        "actions": [["name": "dev_layout", "kind": "lua", "title": "Dev Layout"] as JSONObject,
                    ["name": "com.superlogical.terminal.write", "kind": "block"] as JSONObject,
                    ["name": "com.superlogical.terminal.clear", "kind": "block", "title": "Clear"] as JSONObject],
    ]

    func testLuaRowsAtEveryRevision() async throws {
        for revision in [nil, 13, 16, 18] as [Int?] {
            for reply in [Self.configured, Self.all] {
                let rig = try await Rig(revision: revision, keymap: .result(reply))
                await rig.connect()
                XCTAssertEqual(rig.fake.calls("client.keymap").last?.str("server_actions"), "configured")
                XCTAssertEqual(rig.server.keymap.luaActions.map(\.name), ["dev_layout"], "revision \(String(describing: revision))")
                var c = GoToSource.Copy()
                GoToCommands.add(rig.model.servers, target: nil, waitingCount: 0, into: &c)
                XCTAssertTrue(c.items.contains { $0.title == "Dev Layout" && $0.kind == .command })
                // The palette opens on any of them, and nothing is asked for at open.
                rig.fake.forget()
                rig.model.palette.open(.anything, target: nil)
                XCTAssertNotNil(rig.model.goTo)
                rig.model.palette.close()
                try? await Task.sleep(nanoseconds: 50_000_000)
                XCTAssertEqual(rig.fake.requests.count, 0, "opening asks the server nothing")
                rig.stop()
            }
        }
    }

    func testAKeymapThatFailsGivesNoLuaRows() async throws {
        let rig = try await Rig(revision: 18, keymap: .error(code: "method_not_found", status: 404))
        await rig.connect()
        XCTAssertTrue(rig.server.keymap.luaActions.isEmpty)
        var c = GoToSource.Copy()
        GoToCommands.add(rig.model.servers, target: nil, waitingCount: 0, into: &c)
        XCTAssertFalse(c.items.contains { $0.id == .command("lua:\(rig.server.id.uuidString):dev_layout") })
        XCTAssertTrue(c.items.contains { $0.title == "Settings…" }, "the app's commands still show")
        rig.stop()
    }

    func testARunWithNoPaneSaysPaletteAndFailsLikeAKey() async throws {
        let rig = try await Rig(revision: 18, keymap: .result(Self.configured))
        await rig.connect()
        rig.fake.reply("client.action", .error(code: "method_not_found", status: 404))
        Notice.shared.dismiss()
        rig.model.palette.open(.commands, target: nil)
        rig.model.goTo?.run(.command("lua:\(rig.server.id.uuidString):dev_layout"))
        let failed = await eventually { Notice.shared.message?.hasPrefix("Couldn't run Dev Layout.") == true }
        XCTAssertTrue(failed)
        let call = rig.fake.calls("client.action").last
        XCTAssertEqual(call?.str("origin"), "palette")
        XCTAssertNil(call?["session_id"])
        Notice.shared.dismiss()
        rig.stop()
    }

    private func prompt(_ id: String, kind: String = "input", action: String? = "dev_layout", extra: JSONObject = [:]) -> JSONObject {
        var q: JSONObject = ["kind": kind, "title": "Branch"]
        for (k, v) in extra { q[k] = v }
        var p: JSONObject = ["call_id": id, "timeout_ms": 120_000, "prompt": q]
        if let action { p["action"] = action }
        return p
    }

    func testAQuestionFromThePhonesOwnRunShowsAndCancelEndsIt() async throws {
        let rig = try await Rig(revision: 18, keymap: .result(Self.configured))
        await rig.connect()
        let ended = rig.model.palette.keyRun(rig.server, action: "dev_layout", title: "Dev Layout")
        rig.fake.forget()
        rig.fake.send(event: "client_prompt_requested", prompt("call:mine"))
        let shown = await eventually { rig.model.goTo?.prompt?.callID == "call:mine" }
        XCTAssertTrue(shown)
        XCTAssertEqual(rig.model.goTo?.prompt?.actionTitle, "Dev Layout")
        // Others are declined at once: no action, another action, an unknown kind.
        rig.fake.send(event: "client_prompt_requested", prompt("call:noaction", action: nil))
        rig.fake.send(event: "client_prompt_requested", prompt("call:other", action: "other"))
        rig.fake.send(event: "client_prompt_requested", prompt("call:future", kind: "color_wheel"))
        let declined = await eventually { rig.fake.count("client.reply") == 3 }
        XCTAssertTrue(declined)
        XCTAssertEqual(Set(rig.fake.calls("client.reply").compactMap { $0.str("call_id") }), ["call:noaction", "call:other", "call:future"])
        XCTAssertTrue(rig.fake.calls("client.reply").allSatisfy { $0.obj("error")?.str("code") == "not_supported" })
        rig.model.goTo?.dismiss()
        let cancelled = await eventually { rig.fake.calls("client.reply").contains { $0.str("call_id") == "call:mine" } }
        XCTAssertTrue(cancelled)
        XCTAssertEqual(rig.fake.calls("client.reply").first { $0.str("call_id") == "call:mine" }?.obj("result")?.bool("cancelled"), true)
        let closed = await eventually { rig.model.goTo == nil }
        XCTAssertTrue(closed)
        ended(true)
        rig.stop()
    }

    func testAnswersHaveTheirShapesAndABadRequestKeepsItOpen() async throws {
        let rig = try await Rig(revision: 18, keymap: .result(Self.configured))
        await rig.connect()
        _ = rig.model.palette.keyRun(rig.server, action: "dev_layout", title: "Dev Layout")
        rig.fake.forget()
        rig.fake.reply("client.reply", .error(code: "bad_request", status: 400))
        rig.fake.send(event: "client_prompt_requested", prompt("call:1", extra: ["value": "mai"]))
        _ = await eventually { rig.model.goTo?.prompt != nil }
        let s = try XCTUnwrap(rig.model.goTo)
        XCTAssertEqual(s.query, "mai")
        s.setQuery("main")
        s.submit()
        _ = await eventually { rig.fake.count("client.reply") == 1 }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rig.fake.calls("client.reply").first?.obj("result")?.str("text"), "main")
        XCTAssertNotNil(rig.model.goTo?.prompt, "Rex refused the answer: it stays")
        XCTAssertEqual(Notice.shared.message, "Rex didn't accept that answer. Check it and answer again.")
        rig.fake.reply("client.reply", [:])
        s.submit()
        let closed = await eventually { rig.model.goTo == nil }
        XCTAssertTrue(closed)
        Notice.shared.dismiss()

        // A pick of several: every checked item, in the items' order.
        rig.fake.forget()
        rig.fake.send(event: "client_prompt_requested", prompt("call:2", kind: "pick", extra: [
            "multiple": true, "items": [["id": "a", "title": "alpha"], ["id": "b", "title": "beta", "selected": true]] as [Any]]))
        _ = await eventually { rig.model.goTo?.prompt?.callID == "call:2" }
        let p = try XCTUnwrap(rig.model.goTo)
        p.run(.other("item:a"))
        p.confirm()
        _ = await eventually { rig.fake.count("client.reply") == 1 }
        XCTAssertEqual(rig.fake.calls("client.reply").first?.obj("result")?["ids"] as? [String], ["a", "b"])

        // A single pick with typed text of its own.
        _ = await eventually { rig.model.goTo == nil }
        rig.fake.forget()
        rig.fake.send(event: "client_prompt_requested", prompt("call:3", kind: "pick", extra: [
            "allow_other": true, "items": [["id": "a", "title": "alpha"]] as [Any]]))
        _ = await eventually { rig.model.goTo?.prompt?.callID == "call:3" }
        let o = try XCTUnwrap(rig.model.goTo)
        o.setQuery("zeta")
        XCTAssertEqual(o.rows.first?.title, "Use “zeta”")
        o.submit()
        _ = await eventually { rig.fake.count("client.reply") == 1 }
        XCTAssertEqual(rig.fake.calls("client.reply").first?.obj("result")?.str("text"), "zeta")
        rig.stop()
    }

    func testAQuestionEndedElsewhereOrOnAnOldConnectionClosesWithoutAReply() async throws {
        let rig = try await Rig(revision: 18, keymap: .result(Self.configured))
        await rig.connect()
        _ = rig.model.palette.keyRun(rig.server, action: "dev_layout", title: "Dev Layout")
        rig.fake.forget()
        rig.fake.send(event: "client_prompt_requested", prompt("call:1"))
        _ = await eventually { rig.model.goTo?.prompt != nil }
        rig.fake.send(event: "client_prompt_ended", ["call_id": "call:1", "reason": "answered"])
        let ended = await eventually { rig.model.goTo == nil }
        XCTAssertTrue(ended)

        _ = rig.model.palette.keyRun(rig.server, action: "dev_layout", title: "Dev Layout")
        rig.fake.send(event: "client_prompt_requested", prompt("call:2"))
        _ = await eventually { rig.model.goTo?.prompt?.callID == "call:2" }
        rig.fake.dropAll()
        let gone = await eventually(8) { rig.model.goTo == nil }
        XCTAssertTrue(gone, "a new connection closes the old one's question")
        XCTAssertEqual(rig.fake.count("client.reply"), 0)
        rig.stop()
    }

    func testTheReplyDoesntWaitBehindTheRunsAction() async throws {
        let rig = try await Rig(revision: 18, keymap: .result(Self.configured))
        await rig.connect()
        rig.fake.reply("client.action", .none)
        let stream = TerminalStream(control: rig.server.control, sessionID: "session:1", blockID: "block:1a")
        let ended = rig.model.palette.keyRun(rig.server, action: "dev_layout", title: "Dev Layout")
        stream.perform(action: "dev_layout", args: nil, origin: .palette, title: "Dev Layout", ended: ended) { _ in }
        _ = await eventually { rig.fake.count("client.action") == 1 }
        rig.fake.send(event: "client_prompt_requested", prompt("call:1"))
        _ = await eventually { rig.model.goTo?.prompt != nil }
        rig.model.goTo?.setQuery("main")
        rig.model.goTo?.submit()
        let replied = await eventually { rig.fake.count("client.reply") == 1 }
        XCTAssertTrue(replied, "the reply left while client.action waited")
        stream.stop()
        rig.stop()
    }

    func testBelowRevision17EveryQuestionIsDeclined() async throws {
        for revision in [nil, 13, 16] as [Int?] {
            let rig = try await Rig(revision: revision, keymap: .result(Self.configured))
            await rig.connect()
            _ = rig.model.palette.keyRun(rig.server, action: "dev_layout", title: "Dev Layout")
            rig.fake.forget()
            rig.fake.send(event: "client_prompt_requested", prompt("call:1"))
            let declined = await eventually { rig.fake.count("client.reply") == 1 }
            XCTAssertTrue(declined, "revision \(String(describing: revision))")
            XCTAssertNil(rig.model.goTo)
            rig.stop()
        }
    }

    func testUnderTheTentBoardAQuestionIsDeclined() async throws {
        let rig = try await Rig(revision: 18, keymap: .result(Self.configured))
        await rig.connect()
        _ = rig.model.palette.keyRun(rig.server, action: "dev_layout", title: "Dev Layout")
        rig.model.boardShown = true
        rig.fake.forget()
        rig.fake.send(event: "client_prompt_requested", prompt("call:1"))
        let declined = await eventually { rig.fake.count("client.reply") == 1 }
        XCTAssertTrue(declined)
        XCTAssertEqual(rig.fake.calls("client.reply").first?.obj("error")?.str("code"), "not_supported")
        rig.stop()
    }
}
