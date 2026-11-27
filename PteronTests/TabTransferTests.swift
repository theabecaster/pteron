import Foundation
import XCTest
import RexKit
@testable import Pteron

/// Move to Session (`session.transfer_window`, revision 22): the holds that keep a moving tab in
/// exactly one session, the moves found in the views, what each surface offers, and the call
/// against a Rex server in this process (`FakeRexServer`): the tab followed, the errors, the
/// gating below 22.
@MainActor
final class TabTransferTests: XCTestCase {
    typealias Store = PanesServerTests.Store

    private static func view(_ sid: String, revision: Int, _ windows: [JSONObject], active: String? = nil) -> SessionView {
        var v = SessionView(Store.view(sid, revision: revision, windows: windows))
        if let active { v.activeWindowID = active }
        return v
    }

    private static let w1 = Store.window("window:1", focused: "a", split: ("a", "b"))
    private static let w2 = Store.window("window:2", focused: "x", single: "x")
    private static let w3 = Store.window("window:3", focused: "y", single: "y")

    private func hold(answered: Bool, before: String? = nil, focus: Bool = false) -> TabTransfer {
        TabTransfer(window: WindowInfo(Self.w2), from: "session:1", to: "session:2", index: 1, before: before, focus: focus,
                    fromRevision: answered ? 4 : nil, toRevision: answered ? 8 : nil, token: 1)
    }

    private func ids(_ v: SessionView?) -> [String] { v?.windows.map(\.id) ?? [] }

    // MARK: The hold

    func testBeforeTheAnswerTheTabStaysWhenTheSourceViewComesFirst() {
        let views = ["session:1": Self.view("session:1", revision: 4, [Self.w1]),
                     "session:2": Self.view("session:2", revision: 7, [Self.w3])]
        let out = TabTransfer.reconcile(views, [hold(answered: false)])
        XCTAssertEqual(ids(out["session:1"]), ["window:1", "window:2"], "kept in its place until the destination shows it")
        XCTAssertEqual(ids(out["session:2"]), ["window:3"])
    }

    func testBeforeTheAnswerTheDestinationsViewMovesItInOneStep() {
        let views = ["session:1": Self.view("session:1", revision: 3, [Self.w1, Self.w2], active: "window:2"),
                     "session:2": Self.view("session:2", revision: 8, [Self.w2, Self.w3])]
        let out = TabTransfer.reconcile(views, [hold(answered: false)])
        XCTAssertEqual(ids(out["session:1"]), ["window:1"])
        XCTAssertNil(out["session:1"]?.activeWindowID, "the server's next view names the session's next tab")
        XCTAssertEqual(ids(out["session:2"]), ["window:2", "window:3"])
    }

    func testAfterTheAnswerOlderViewsShowTheMoveAtItsPlace() {
        let views = ["session:1": Self.view("session:1", revision: 3, [Self.w1, Self.w2]),
                     "session:2": Self.view("session:2", revision: 7, [Self.w3])]
        let out = TabTransfer.reconcile(views, [hold(answered: true, before: "window:3", focus: true)])
        XCTAssertEqual(ids(out["session:1"]), ["window:1"])
        XCTAssertEqual(ids(out["session:2"]), ["window:2", "window:3"])
        XCTAssertEqual(out["session:2"]?.activeWindowID, "window:2")
    }

    func testAfterTheAnswerItGoesLastAndKeepsTheActiveTabWithoutFocus() {
        let views = ["session:1": Self.view("session:1", revision: 3, [Self.w1, Self.w2]),
                     "session:2": Self.view("session:2", revision: 7, [Self.w3], active: "window:3")]
        let out = TabTransfer.reconcile(views, [hold(answered: true)])
        XCTAssertEqual(ids(out["session:2"]), ["window:3", "window:2"])
        XCTAssertEqual(out["session:2"]?.activeWindowID, "window:3")
    }

    func testAnEmptyDestinationMakesItActive() {
        let views = ["session:1": Self.view("session:1", revision: 3, [Self.w1, Self.w2]),
                     "session:2": Self.view("session:2", revision: 7, [])]
        let out = TabTransfer.reconcile(views, [hold(answered: true)])
        XCTAssertEqual(out["session:2"]?.activeWindowID, "window:2")
    }

    func testViewsAtTheAnswersRevisionsAreTheServersWordAndRelease() {
        let views = ["session:1": Self.view("session:1", revision: 4, [Self.w1]),
                     "session:2": Self.view("session:2", revision: 8, [Self.w3, Self.w2])]
        let h = hold(answered: true)
        let out = TabTransfer.reconcile(views, [h])
        XCTAssertEqual(ids(out["session:2"]), ["window:3", "window:2"], "unchanged: the server put it there")
        XCTAssertTrue(h.released(by: out))
        XCTAssertFalse(h.released(by: ["session:1": Self.view("session:1", revision: 4, [Self.w1]),
                                       "session:2": Self.view("session:2", revision: 7, [Self.w3])]))
        XCTAssertFalse(hold(answered: false).released(by: out), "never before the answer")
    }

    // MARK: Moves found in the views

    func testATabThatChangesSessionsInOneChangeIsAMove() {
        let old = ["session:1": Self.view("session:1", revision: 3, [Self.w1, Self.w2]),
                   "session:2": Self.view("session:2", revision: 7, [Self.w3])]
        let new = ["session:1": Self.view("session:1", revision: 4, [Self.w1]),
                   "session:2": Self.view("session:2", revision: 8, [Self.w3, Self.w2])]
        XCTAssertEqual(TabMoves.find(old: old, new: new, departed: [:]),
                       [TabMoves.Move(window: "window:2", from: "session:1", to: "session:2", blocks: ["x"])])
        XCTAssertEqual(TabMoves.departures(old: old, new: new), [:])
    }

    func testATabThatLeftFirstIsAMoveWhenItShowsUpElsewhere() {
        let a = ["session:1": Self.view("session:1", revision: 3, [Self.w1, Self.w2]),
                 "session:2": Self.view("session:2", revision: 7, [Self.w3])]
        let b = ["session:1": Self.view("session:1", revision: 4, [Self.w1]), "session:2": a["session:2"]!]
        let departed = TabMoves.departures(old: a, new: b)
        XCTAssertEqual(departed, ["window:2": "session:1"])
        XCTAssertEqual(TabMoves.find(old: a, new: b, departed: [:]), [])
        let c = ["session:1": b["session:1"]!, "session:2": Self.view("session:2", revision: 8, [Self.w3, Self.w2])]
        XCTAssertEqual(TabMoves.find(old: b, new: c, departed: departed).map(\.to), ["session:2"])
    }

    func testANewTabOrAReorderIsNoMove() {
        let old = ["session:1": Self.view("session:1", revision: 3, [Self.w1, Self.w2])]
        let reordered = ["session:1": Self.view("session:1", revision: 4, [Self.w2, Self.w1])]
        let added = ["session:1": Self.view("session:1", revision: 4, [Self.w1, Self.w2, Self.w3])]
        XCTAssertEqual(TabMoves.find(old: old, new: reordered, departed: [:]), [])
        XCTAssertEqual(TabMoves.find(old: old, new: added, departed: [:]), [])
        XCTAssertEqual(TabMoves.find(old: [:], new: added, departed: [:]), [], "a first sync moves nothing")
    }

    // MARK: The tab on screen while another client may be moving it

    func testTheTabOnScreenThatLeftEveryViewIsHeldWhereItWas() throws {
        let old = ["session:1": Self.view("session:1", revision: 3, [Self.w1, Self.w2]),
                   "session:2": Self.view("session:2", revision: 3, [Self.w3])]
        var new = old
        new["session:1"] = Self.view("session:1", revision: 4, [Self.w1])
        let h = try XCTUnwrap(LeavingTab.begins(shown: ("session:1", "window:2"), old: old, new: new))
        XCTAssertEqual(h.index, 1)
        XCTAssertEqual(h.apply(&new, server: ["session:1"]), .held)
        XCTAssertEqual(ids(new["session:1"]), ["window:1", "window:2"], "kept at its place")
        // A view of the destination shows it: one step, never in two sessions.
        new["session:2"] = Self.view("session:2", revision: 4, [Self.w3, Self.w2])
        XCTAssertEqual(h.apply(&new, server: ["session:2"]), .moved)
        XCTAssertEqual(ids(new["session:1"]), ["window:1"])
        XCTAssertEqual(ids(new["session:2"]), ["window:3", "window:2"])
    }

    func testTheHoldIsOverWhenItsSessionShowsItAgainOrIsGone() throws {
        let old = ["session:1": Self.view("session:1", revision: 3, [Self.w1, Self.w2])]
        var new = ["session:1": Self.view("session:1", revision: 4, [Self.w1])]
        let h = try XCTUnwrap(LeavingTab.begins(shown: ("session:1", "window:2"), old: old, new: new))
        XCTAssertEqual(h.apply(&new, server: ["session:1"]), .held)
        var back = new
        back["session:1"] = Self.view("session:1", revision: 5, [Self.w2, Self.w1])
        XCTAssertEqual(h.apply(&back, server: ["session:1"]), .over)
        XCTAssertEqual(ids(back["session:1"]), ["window:2", "window:1"], "the server's order")
        var gone: [String: SessionView] = [:]
        XCTAssertEqual(h.apply(&gone, server: []), .over)
        h.release(&new)
        XCTAssertEqual(ids(new["session:1"]), ["window:1"])
    }

    func testNoHoldForAPaneMovedToAnotherTabOrATabOffScreen() {
        let old = ["session:1": Self.view("session:1", revision: 3, [Self.w1, Self.w2])]
        // Move Pane to Tab took `x`, the tab's last pane, to `window:1`: CloseNext follows it.
        let paneMoved = Store.window("window:1", focused: "a", split: ("a", "x"))
        XCTAssertNil(LeavingTab.begins(shown: ("session:1", "window:2"), old: old,
                                       new: ["session:1": Self.view("session:1", revision: 4, [paneMoved])]))
        // Another tab left: the one on screen is still there.
        XCTAssertNil(LeavingTab.begins(shown: ("session:1", "window:1"), old: old,
                                       new: ["session:1": Self.view("session:1", revision: 4, [Self.w1])]))
        // The destination's view came first: a move, found as one (`TabMoves`).
        XCTAssertNil(LeavingTab.begins(shown: ("session:1", "window:2"), old: old,
                                       new: ["session:1": Self.view("session:1", revision: 4, [Self.w1]),
                                             "session:2": Self.view("session:2", revision: 4, [Self.w2])]))
    }

    // MARK: Gating, wording and places

    func testOnlyRevision22AndLaterMoveTabs() {
        XCTAssertFalse(PaneSupport(revision: 21).has(.transferTab))
        XCTAssertTrue(PaneSupport(revision: 22).has(.transferTab))
        XCTAssertTrue(PaneSupport(revision: 21).has(.moveTab), "the other commands keep revision 13")
        XCTAssertFalse(PaneSupport(revision: 24, absent: ["session.transfer_window"]).has(.transferTab))
        XCTAssertEqual(AppAction.resolve("client.tab.move_to_session", nil, panes: PaneSupport(revision: 21)).map { "\($0)" }, nil)
        if case .command(.moveTabToSession)? = AppAction.resolve("client.tab.move_to_session", nil, panes: PaneSupport(revision: 22)) {
        } else {
            XCTFail("revision 22 resolves Move Tab to Session…")
        }
    }

    func testTheNoticesSayWhatWentWrong() {
        XCTAssertEqual(TransferCopy.failure(RexError(code: "conflict", message: ""), to: "ops", computer: "Desk"),
                       "Couldn't move the tab. “ops” is full, or a pane in the tab is still starting.")
        XCTAssertEqual(TransferCopy.failure(RexError(code: "session_not_found", message: ""), to: "ops", computer: "Desk"),
                       "Couldn't move the tab. That session closed.")
        XCTAssertEqual(TransferCopy.failure(RexError(code: "not_found", message: ""), to: "ops", computer: "Desk"),
                       "Couldn't move the tab. That tab closed.")
    }

    func testRecentTabsAndNavigateBackFollowTheTab() {
        let s = UUID()
        let old = Selection(serverID: s, sessionID: "session:1", windowID: "window:2")
        let new = Selection(serverID: s, sessionID: "session:2", windowID: "window:2")
        let other = Selection(serverID: s, sessionID: "session:1", windowID: "window:1")
        XCTAssertEqual(TabHistory.moved(old, to: new, in: [other, old]), [other, new])
        XCTAssertEqual(TabHistory.moved(old, to: new, in: [new, old]), [new], "no entry twice")
        var h = NavHistory()
        h.visit(NavPlace(serverID: s, sessionID: "session:1", windowID: "window:2", blockID: "x"))
        h.visit(NavPlace(serverID: s, sessionID: "session:1", windowID: "window:1", blockID: "a"))
        h.moved(window: "window:2", server: s, from: "session:1", to: "session:2")
        XCTAssertEqual(h.back { _ in true }?.sessionID, "session:2")
    }

    func testThePalettesChooserListsTheComputersOtherSessionsOnly() {
        let s = UUID(), other = UUID()
        let scope = GoToScope.moveTab(server: s, from: "session:1")
        func item(_ id: GoToItemID, _ kind: GoToItem.Kind) -> GoToItem {
            GoToItem(id: id, kind: kind, title: "", subtitle: "", order: 0, symbol: "")
        }
        XCTAssertTrue(scope.lists(item(.session(s, "session:2"), .session)))
        XCTAssertFalse(scope.lists(item(.session(s, "session:1"), .session)), "not the tab's own session")
        XCTAssertFalse(scope.lists(item(.session(other, "session:2"), .session)), "not another computer's")
        XCTAssertFalse(scope.lists(item(.tab(s, "session:2", "window:3"), .tab)))
        XCTAssertFalse(scope.lists(item(.command("x"), .command)))
        XCTAssertEqual(scope.placeholder, "Move tab to session")
        XCTAssertEqual(KeyActions.byName["client.tab.move_to_session"]?.title, "Move Tab to Session…")
        XCTAssertNotNil(MacPalette.rank("client.tab.move_to_session"))
    }

    func testAChipOffersMoveToSessionOnlyWithSessionsToMoveTo() {
        let moves = [SessionChoice(id: "session:2", name: "ops")]
        let chip = TabChip(id: "window:2", title: "t", active: true, position: 2, count: 2, panes: [nil], status: nil,
                           movable: true, moves: moves)
        XCTAssertEqual(chip.moves, moves)
        XCTAssertEqual(chip.spokenActions.last?.title, "Move to ops")
        XCTAssertEqual(chip.spokenActions.last?.action, .moveToSession("session:2"))
        let none = TabChip(id: "window:2", title: "t", active: true, position: 2, count: 2, panes: [nil], status: nil, movable: true)
        XCTAssertFalse(none.spokenActions.contains { if case .moveToSession = $0.action { true } else { false } })
        XCTAssertFalse(TabChip.Action.allCases.contains(.moveToSession("session:2")))
    }

    // MARK: The sidebar drag

    private func frame(_ kind: SidebarOutline.Row.Kind, _ y: CGFloat) -> SidebarDrag.Frame {
        SidebarDrag.Frame(kind: kind, minY: y, maxY: y + 36)
    }

    func testALiftedTabDropsAmongAnotherSessionsTabsWhereTheComputerMovesTabs() {
        let s = UUID(), other = UUID()
        let frames: [String: SidebarDrag.Frame] = [
            "s1": frame(.session(s, "session:1"), 0),
            "t1": frame(.tab(s, session: "session:1", window: "window:1"), 36),
            "t2": frame(.tab(s, session: "session:1", window: "window:2"), 72),
            "s2": frame(.session(s, "session:2"), 120),
            "t3": frame(.tab(s, session: "session:2", window: "window:3"), 156),
            "s3": frame(.session(s, "session:3"), 204),
            "o1": frame(.session(other, "session:9"), 300),
        ]
        let tabs: [String: [String]] = ["session:1": ["window:1", "window:2"], "session:2": ["window:3"], "session:3": ["window:4"]]
        func orders(_ moves: Bool) -> SidebarDrag.Orders {
            SidebarDrag.Orders(sessions: { _ in ["session:1", "session:2", "session:3"] }, tabs: { tabs[$1] ?? [] },
                               transfers: { _ in moves })
        }
        let item = SidebarDrag.Item.tab(server: s, session: "session:1", window: "window:2")
        // Over session:2's tab, near its top: before it.
        let into = SidebarGaps.gap(for: item, at: 158, frames: frames, orders: orders(true))
        XCTAssertEqual(into?.session, "session:2")
        XCTAssertEqual(into?.index, 0)
        // Under a folded session's header: last there.
        let folded = SidebarGaps.gap(for: item, at: 238, frames: frames, orders: orders(true))
        XCTAssertEqual(folded?.session, "session:3")
        XCTAssertEqual(folded?.index, 1)
        // Without the method, the tab stays in its session.
        XCTAssertEqual(SidebarGaps.gap(for: item, at: 158, frames: frames, orders: orders(false))?.session, "session:1")
        // Over another computer's rows there is nowhere to drop.
        XCTAssertNil(SidebarGaps.gap(for: item, at: 310, frames: frames, orders: orders(true)))
        XCTAssertNil(SidebarGaps.gap(for: item, at: 310, frames: frames, orders: orders(false)))
    }

    // MARK: Against a server

    @MainActor
    final class Rig {
        let fake: FakeRexServer
        let server: ServerConnection
        let store = Store()
        let model: AppModel

        init(revision: Int = 24) async throws {
            fake = try FakeRexServer(revision: revision, serverRevision: revision)
            let address = await fake.start()
            let name = "TabTransferTests-\(UUID().uuidString)"
            let d = UserDefaults(suiteName: name)!
            d.removePersistentDomain(forName: name)
            let prefs = Prefs(defaults: d)
            model = AppModel(prefs: prefs, connect: false)
            server = ServerConnection(config: ServerConfig(name: "Desk", url: address), prefs: prefs,
                                      notifier: model.notifier, deviceID: "a1b2c3d4")
            let store = store
            fake.onRequest { r in
                switch r.method {
                case "session.attach", "session.view":
                    return .result(["view": store.view(r.payload.str("session_id") ?? "")])
                case "session.bootstrap":
                    return .result(["client_id": "client:test",
                                    "server_status": ["instance_id": "instance-1", "host_id": "host-a"] as JSONObject,
                                    "attach_all": ["sessions": store.sessions.map { ["session_id": $0, "label": "label \($0)"] }] as JSONObject])
                case "session.list":
                    return .result(["sessions": store.sessions.map { ["session_id": $0, "label": "label \($0)"] }])
                default:
                    return nil
                }
            }
            fake.reply("\(PanesServerTests.terminal).program_status", ["records": [JSONObject]()])
            fake.reply("\(PanesServerTests.terminal).title", ["title": "zsh"])
            fake.reply("\(PanesServerTests.terminal).process", ["foreground": ["name": "zsh"] as JSONObject])
            fake.reply("hosts.list", ["hosts": [JSONObject]()])
            fake.reply("server.version", ["platform": "darwin_arm64"])
            fake.reply("server.whoami", [:])
            fake.reply("client.keymap", ["bindings": [JSONObject](), "config": ["hash": "h", "instance_id": "instance-1"] as JSONObject])
            fake.reply("block_creator.list", ["creators": [JSONObject]()])
            model.servers = [server]
        }

        func connect() async {
            server.start()
            _ = await eventually { self.fake.count("client.keymap") >= 1 && self.server.synced && self.server.creatorsTask == nil }
            fake.forget()
        }

        func stop() {
            server.stop()
            fake.stop()
        }

        /// The server after the move: the tab in session 2, at the revisions the answer gives.
        func moveOnServer() {
            store.setView("session:1", Store.view("session:1", revision: 4, windows: [TabTransferTests.w1]))
            store.setView("session:2", Store.view("session:2", revision: 8, windows: [TabTransferTests.w3, TabTransferTests.w2]))
        }
    }

    override func setUp() async throws {
        Notice.shared.plainSeconds = 30
        Notice.shared.actionSeconds = 30
        Notice.shared.dismiss()
    }

    override func tearDown() async throws {
        Notice.shared.dismiss()
        Notice.shared.plainSeconds = 3.5
        Notice.shared.actionSeconds = 6.0
    }

    func testTheMoveIsOneCallAndTheTabOnScreenFollowsInOneStep() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        rig.fake.reply("session.transfer_window", ["revision": 4, "to_revision": 8])
        await rig.connect()
        rig.model.selection = Selection(serverID: rig.server.id, sessionID: "session:1", windowID: "window:2")
        var moves: [TabMoves.Move] = []
        let follow = rig.server.tabMoved
        rig.server.tabMoved = { s, m in moves.append(m); follow?(s, m) }
        var neverInNeither = true
        rig.server.viewsChanged = { s, _ in
            if s.views["session:1"]?.window("window:2") == nil, s.views["session:2"]?.window("window:2") == nil { neverInNeither = false }
        }

        let moved = await rig.server.transferTab("session:1", "window:2", to: "session:2", before: nil, focus: true)
        rig.moveOnServer()

        XCTAssertTrue(moved)
        let call = try XCTUnwrap(rig.fake.calls("session.transfer_window").first)
        XCTAssertEqual(call.str("session_id"), "session:1")
        XCTAssertEqual(call.str("window_id"), "window:2")
        XCTAssertEqual(call.str("to_session_id"), "session:2")
        XCTAssertEqual(call["focus"] as? Bool, true)
        XCTAssertNil(call["before_window_id"], "last: no place named")
        XCTAssertEqual(rig.fake.count("session.transfer_window"), 1)
        XCTAssertEqual(rig.server.views["session:2"]?.windows.map(\.id), ["window:3", "window:2"], "shown at once after the answer")
        XCTAssertNil(rig.server.views["session:1"]?.window("window:2"))
        XCTAssertEqual(moves, [TabMoves.Move(window: "window:2", from: "session:1", to: "session:2", blocks: ["x"])])
        XCTAssertEqual(rig.model.selection, Selection(serverID: rig.server.id, sessionID: "session:2", windowID: "window:2"))
        XCTAssertTrue(neverInNeither)
        // The server's own views agree and let the hold go; the move is not found twice.
        let released = await eventually { rig.server.transfers.isEmpty }
        XCTAssertTrue(released)
        XCTAssertEqual(moves.count, 1)
        XCTAssertNil(Notice.shared.message)
    }

    func testTheSourcesViewBeforeTheAnswerDoesNotCloseTheTabOnScreen() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        rig.fake.reply("session.transfer_window", ["revision": 4, "to_revision": 8])
        rig.fake.delay("session.transfer_window", seconds: 0.5)
        await rig.connect()
        let sel = Selection(serverID: rig.server.id, sessionID: "session:1", windowID: "window:2")
        rig.model.selection = sel

        let move = Task { await rig.server.transferTab("session:1", "window:2", to: "session:2", before: "window:3", focus: false) }
        _ = await eventually { rig.fake.count("session.transfer_window") == 1 }
        // The session it leaves says so before the answer comes.
        rig.server.apply(view: Self.view("session:1", revision: 4, [Self.w1]))
        XCTAssertEqual(rig.server.views["session:1"]?.windows.map(\.id), ["window:1", "window:2"])
        XCTAssertEqual(rig.model.selection, sel, "nothing moved off the tab")
        rig.moveOnServer()
        _ = await move.value
        XCTAssertEqual(rig.fake.calls("session.transfer_window").first?.str("before_window_id"), "window:3")
        XCTAssertEqual(rig.model.selection?.sessionID, "session:2")
    }

    func testARefusedMoveSaysWhyOnceAndTheTabStays() async throws {
        for (code, message) in [("conflict", "Couldn't move the tab. “label session:2” is full, or a pane in the tab is still starting."),
                                ("session_not_found", "Couldn't move the tab. That session closed."),
                                ("not_found", "Couldn't move the tab. That tab closed.")] {
            let rig = try await Rig()
            rig.fake.reply("session.transfer_window", .error(code: code, status: 409))
            await rig.connect()
            Notice.shared.dismiss()
            let sel = Selection(serverID: rig.server.id, sessionID: "session:1", windowID: "window:2")
            rig.model.selection = sel

            let moved = await rig.server.transferTab("session:1", "window:2", to: "session:2", before: nil, focus: true)

            XCTAssertFalse(moved, code)
            XCTAssertEqual(Notice.shared.message, message, code)
            XCTAssertEqual(rig.server.views["session:1"]?.windows.map(\.id), ["window:1", "window:2"], code)
            XCTAssertEqual(rig.model.selection, sel, code)
            XCTAssertTrue(rig.server.transfers.isEmpty, code)
            XCTAssertTrue(rig.server.transferring.isEmpty, code)
            XCTAssertTrue(rig.server.capabilities.paneSupport.has(.transferTab), "\(code) is no missing method")
            rig.stop()
        }
    }

    func testAPlaceThatClosedMeanwhileGoesLastInstead() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        rig.fake.reply("session.transfer_window", ["revision": 4, "to_revision": 8])
        await rig.connect()
        // `window:9` is in no view: the first call names it and is refused, the second goes last.
        let calls = Counter()
        rig.fake.onRequest { [store = rig.store] r in
            switch r.method {
            case "session.transfer_window":
                return calls.next() == 1 ? .error(code: "not_found", status: 404) : .result(["revision": 4, "to_revision": 8])
            case "session.attach", "session.view":
                return .result(["view": store.view(r.payload.str("session_id") ?? "")])
            default: return nil
            }
        }

        let moved = await rig.server.transferTab("session:1", "window:2", to: "session:2", before: "window:9", focus: false)

        XCTAssertTrue(moved)
        XCTAssertEqual(rig.fake.calls("session.transfer_window").map { $0.str("before_window_id") }, ["window:9", nil])
        XCTAssertNil(Notice.shared.message)
    }

    func testBelowRevision22NothingOffersOrSendsAMove() async throws {
        let rig = try await Rig(revision: 21)
        defer { rig.stop() }
        await rig.connect()

        XCTAssertFalse(rig.server.movesTabs)
        XCTAssertEqual(rig.server.moveDestinations(from: "session:1").map(\.id), [])
        XCTAssertEqual(SessionChoice.destinations(rig.server, from: "session:1"), [])
        let moved = await rig.server.transferTab("session:1", "window:2", to: "session:2", before: nil, focus: false)
        XCTAssertFalse(moved)
        XCTAssertEqual(rig.fake.count("session.transfer_window"), 0)
        let target = GoToTarget(serverID: rig.server.id, sessionID: "session:1", windowID: "window:2", blockID: "x")
        var copy = GoToSource.Copy()
        GoToCommands.add([rig.server], target: target, waitingCount: 0, into: &copy)
        XCTAssertFalse(copy.items.contains { $0.title == "Move Tab to Session…" })
    }

    func testFromRevision22ThePaletteAndTheMenusOfferTheOtherSessions() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        await rig.connect()

        XCTAssertEqual(SessionChoice.destinations(rig.server, from: "session:1"),
                       [SessionChoice(id: "session:2", name: "label session:2")])
        let target = GoToTarget(serverID: rig.server.id, sessionID: "session:1", windowID: "window:2", blockID: "x")
        var copy = GoToSource.Copy()
        GoToCommands.add([rig.server], target: target, waitingCount: 0, into: &copy)
        XCTAssertTrue(copy.items.contains { $0.title == "Move Tab to Session…" && $0.category == "Tab" })
    }

    func testOnlyTheTabOnScreenBecomesTheDestinationsActiveTab() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        rig.fake.reply("session.transfer_window", ["revision": 4, "to_revision": 8])
        await rig.connect()
        rig.model.selection = Selection(serverID: rig.server.id, sessionID: "session:1", windowID: "window:1")

        rig.model.moveTab(rig.server, session: "session:1", window: "window:2", to: "session:2")
        _ = await eventually { rig.fake.count("session.transfer_window") == 1 }
        XCTAssertEqual(rig.fake.calls("session.transfer_window").first?["focus"] as? Bool, false, "not on screen")
        XCTAssertEqual(rig.model.selection?.windowID, "window:1", "the tab on screen stays")

        rig.model.moveTab(rig.server, session: "session:1", window: "window:1", to: "session:2")
        _ = await eventually { rig.fake.count("session.transfer_window") == 2 }
        XCTAssertEqual(rig.fake.calls("session.transfer_window").last?["focus"] as? Bool, true, "on screen")
    }

    func testAnotherClientsMoveIsFollowedToo() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        await rig.connect()
        rig.model.selection = Selection(serverID: rig.server.id, sessionID: "session:1", windowID: "window:1")
        let recent = Selection(serverID: rig.server.id, sessionID: "session:1", windowID: "window:2")
        rig.model.selection = recent
        rig.model.selection = Selection(serverID: rig.server.id, sessionID: "session:1", windowID: "window:1")

        // The destination's view comes first, then the source's (`rex window move --to`).
        rig.server.apply(view: Self.view("session:2", revision: 8, [Self.w3, Self.w2]))
        rig.server.apply(view: Self.view("session:1", revision: 4, [Self.w1]))

        XCTAssertEqual(rig.model.recentTabs.first { $0.windowID == "window:2" }?.sessionID, "session:2")
        XCTAssertTrue(rig.model.openPane(rig.server, session: "session:1", window: "window:2", block: nil),
                      "a place named before the move opens the tab where it is")
        XCTAssertEqual(rig.model.openRequest?.selection.sessionID, "session:2")
    }

    // MARK: Another client moves the tab on screen (`rex window move --to`)

    /// The selections the app showed and whether a view ever had the tab in neither session,
    /// from every change of the views.
    private final class Watch {
        var shown: [Selection] = []
        var inNeither = false
    }

    private func watch(_ rig: Rig) -> Watch {
        let w = Watch()
        if let sel = rig.model.selection { w.shown = [sel] }
        let follow = rig.server.viewsChanged
        rig.server.viewsChanged = { [weak model = rig.model] s, old in
            follow?(s, old)
            if let sel = model?.selection, w.shown.last != sel { w.shown.append(sel) }
            if s.views["session:1"]?.window("window:2") == nil, s.views["session:2"]?.window("window:2") == nil { w.inNeither = true }
        }
        return w
    }

    private func onScreen(_ rig: Rig, _ sid: String = "session:1", _ wid: String = "window:2") -> Selection {
        Selection(serverID: rig.server.id, sessionID: sid, windowID: wid)
    }

    /// The source's events and view: `window:2` left session 1.
    private func sourceCloses(_ rig: Rig) {
        rig.store.setView("session:1", Store.view("session:1", revision: 4, windows: [Self.w1]))
        rig.fake.send(session: "session:1", event: "window_closed", ["window_id": "window:2"])
        rig.fake.send(session: "session:1", event: "block_closed", ["block_id": "x"])
    }

    /// The destination's events and view: `window:2` arrived in session 2.
    private func destinationOpens(_ rig: Rig) {
        rig.store.setView("session:2", Store.view("session:2", revision: 4, windows: [Self.w3, Self.w2]))
        rig.fake.send(session: "session:2", event: "block_created", ["block_id": "x"])
        rig.fake.send(session: "session:2", event: "window_created", ["window_id": "window:2", "label": ""])
    }

    func testAMoveWhoseSourceComesFirstIsFollowedWithNoClose() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        await rig.connect()
        rig.model.selection = onScreen(rig)
        let w = watch(rig)

        sourceCloses(rig)
        let held = await eventually { rig.server.views["session:1"]?.revision == 4 }
        XCTAssertTrue(held)
        XCTAssertNotNil(rig.server.leaving, "the source's view came first: the tab is held")
        XCTAssertEqual(rig.server.views["session:1"]?.windows.map(\.id), ["window:1", "window:2"], "the old frame stays")
        destinationOpens(rig)
        let followed = await eventually { rig.model.selection == self.onScreen(rig, "session:2") }

        XCTAssertTrue(followed)
        XCTAssertEqual(w.shown, [onScreen(rig), onScreen(rig, "session:2")], "never another tab, never the empty state")
        XCTAssertFalse(w.inNeither)
        XCTAssertNil(rig.server.views["session:1"]?.window("window:2"))
        XCTAssertNil(rig.server.leaving)
        XCTAssertTrue(rig.server.arrivals.isEmpty)
        XCTAssertNil(Notice.shared.message)
    }

    func testAMoveWhoseDestinationComesFirstIsFollowedWithNoClose() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        await rig.connect()
        rig.model.selection = onScreen(rig)
        let w = watch(rig)

        destinationOpens(rig)
        let followed = await eventually { rig.model.selection == self.onScreen(rig, "session:2") }
        XCTAssertTrue(followed)
        sourceCloses(rig)
        _ = await eventually { rig.server.views["session:1"]?.revision == 4 }
        try await Task.sleep(for: .milliseconds(Int(LeavingTab.wait * 1000) + 200))

        XCTAssertEqual(rig.model.selection, onScreen(rig, "session:2"))
        XCTAssertEqual(w.shown, [onScreen(rig), onScreen(rig, "session:2")])
        XCTAssertFalse(w.inNeither)
        XCTAssertNil(rig.server.leaving)
    }

    func testAWindowCreatedDuringTheWaitHoldsUntilItsSlowViewLands() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        await rig.connect()
        rig.model.selection = onScreen(rig)
        let w = watch(rig)

        sourceCloses(rig)
        _ = await eventually { rig.server.leaving != nil }
        // The destination's view takes longer than the wait: its `window_created` says to wait on.
        rig.fake.delay("session.view", seconds: LeavingTab.wait + 0.4)
        destinationOpens(rig)
        _ = await eventually { !rig.server.arrivals.isEmpty }
        XCTAssertEqual(rig.server.arrivals["window:2"]?.to, "session:2")
        let followed = await eventually { rig.model.selection == self.onScreen(rig, "session:2") }

        XCTAssertTrue(followed)
        XCTAssertEqual(w.shown, [onScreen(rig), onScreen(rig, "session:2")])
        XCTAssertFalse(w.inNeither)
    }

    func testARealCloseWaitsBrieflyThenMovesOff() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        await rig.connect()
        rig.model.selection = onScreen(rig)

        sourceCloses(rig)
        _ = await eventually { rig.server.leaving != nil }
        let start = Date()
        XCTAssertEqual(rig.model.selection, onScreen(rig), "nothing new during the wait")
        let closed = await eventually { rig.model.selection == self.onScreen(rig, "session:1", "window:1") }
        let took = Date().timeIntervalSince(start)

        XCTAssertTrue(closed)
        XCTAssertGreaterThan(took, LeavingTab.wait - 0.1)
        XCTAssertLessThan(took, LeavingTab.wait + 0.5, "a real close stays quick")
        XCTAssertNil(rig.server.views["session:1"]?.window("window:2"))
        XCTAssertNil(rig.server.leaving)
    }

    func testACreateAfterTheWaitMovesTheTabButNotTheScreen() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        await rig.connect()
        rig.model.selection = onScreen(rig)
        var moves: [TabMoves.Move] = []
        let follow = rig.server.tabMoved
        rig.server.tabMoved = { s, m in moves.append(m); follow?(s, m) }

        sourceCloses(rig)
        let closed = await eventually { rig.model.selection == self.onScreen(rig, "session:1", "window:1") }
        XCTAssertTrue(closed)
        destinationOpens(rig)
        let found = await eventually { !moves.isEmpty }

        XCTAssertTrue(found, "still found as a move, for the places that name the tab")
        XCTAssertEqual(moves.first?.to, "session:2")
        XCTAssertEqual(rig.model.selection, onScreen(rig, "session:1", "window:1"), "the screen doesn't jump back")
        XCTAssertEqual(rig.model.recentTabs.first { $0.windowID == "window:2" }?.sessionID, "session:2")
    }

    func testBelowRevision22ACloseMovesOffAtOnce() async throws {
        let rig = try await Rig(revision: 21)
        defer { rig.stop() }
        await rig.connect()
        rig.model.selection = onScreen(rig)
        var heldAtClose: Bool?
        let follow = rig.server.viewsChanged
        rig.server.viewsChanged = { s, old in
            follow?(s, old)
            if heldAtClose == nil, s.views["session:1"]?.revision == 4 { heldAtClose = rig.model.selection == self.onScreen(rig) }
        }

        sourceCloses(rig)
        let closed = await eventually { rig.model.selection == self.onScreen(rig, "session:1", "window:1") }

        XCTAssertTrue(closed)
        XCTAssertEqual(heldAtClose, false, "moved off in the turn the view landed")
        XCTAssertNil(rig.server.leaving)
    }
}

/// Counts calls on the fake's queue.
private final class Counter: @unchecked Sendable {
    // `@unchecked`: `n` is only touched under `lock`.
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

@MainActor
private func eventually(seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
