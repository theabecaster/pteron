import Foundation
import GlanceModel
import Observation
import XCTest
import RexKit
@testable import Pteron

/// The pane commands against a Rex server in this process (`FakeRexServer`): what goes on the
/// wire and in which order, how the sidebar's held order is let go, which reads are dropped as
/// stale, and what a server without a method, or a reconnect, leaves.
@MainActor
final class PanesServerTests: XCTestCase {
    nonisolated static let terminal = "com.superlogical.terminal"

    /// What the fake server holds: the session order and each session's view. Read on its queue.
    final class Store: @unchecked Sendable {
        // `@unchecked`: everything is only touched under `lock`.
        private let lock = NSLock()
        private var order = ["session:1", "session:2"]
        private var views: [String: JSONObject] = [:]

        init() {
            views["session:1"] = Self.view("session:1", revision: 3, windows: [
                Self.window("window:1", focused: "a", split: ("a", "b")),
                Self.window("window:2", focused: "x", single: "x"),
            ])
            views["session:2"] = Self.view("session:2", revision: 3, windows: [Self.window("window:3", focused: "y", single: "y")])
        }

        var sessions: [String] {
            get { lock.withLock { order } }
            set { lock.withLock { order = newValue } }
        }

        func view(_ sid: String) -> JSONObject { lock.withLock { views[sid] ?? [:] } }
        func setView(_ sid: String, _ v: JSONObject) { lock.withLock { views[sid] = v } }

        nonisolated static func block(_ id: String) -> JSONObject {
            ["block_id": id, "creator_name": terminal, "flavor": "\(terminal).shell", "host_id": "host-a", "label": "shell"]
        }

        nonisolated static func window(_ id: String, focused: String, split: (String, String)? = nil, single: String? = nil) -> JSONObject {
            let layout: JSONObject
            let blocks: [JSONObject]
            if let (a, b) = split {
                layout = ["rect": [0, 0, 1, 1], "split": [
                    "split_id": "split:\(id)", "direction": "horizontal", "ratio": 0.3,
                    "before": ["block_id": a, "rect": [0, 0, 0.3, 1]],
                    "after": ["block_id": b, "rect": [0.3, 0, 0.7, 1]],
                ] as JSONObject]
                blocks = [block(a), block(b)]
            } else {
                let s = single ?? ""
                layout = ["block_id": s, "rect": [0, 0, 1, 1]]
                blocks = [block(s)]
            }
            return ["window_id": id, "label": "", "focused_block_id": focused,
                    "layers": [["kind": "tiled", "layer_id": "layer:\(id)", "bounds": [0, 0, 1, 1], "blocks": blocks, "layout": layout] as JSONObject]]
        }

        nonisolated static func view(_ sid: String, revision: Int, windows: [JSONObject]) -> JSONObject {
            ["session_id": sid, "label": "label \(sid)", "revision": revision, "active_window_id": windows.first?.str("window_id") ?? "",
             "windows": windows]
        }
    }

    /// A test's own answers, asked before the rig's. Read on the fake's queue.
    final class Hooks: @unchecked Sendable {
        // `@unchecked`: `body` is only touched under `lock`.
        private let lock = NSLock()
        private var body: (@Sendable (FakeRexServer.Request) -> FakeRexServer.Reply?)?
        func set(_ b: @escaping @Sendable (FakeRexServer.Request) -> FakeRexServer.Reply?) { lock.withLock { body = b } }
        func answer(_ r: FakeRexServer.Request) -> FakeRexServer.Reply? { lock.withLock { body }?(r) }
    }

    @MainActor
    final class Rig {
        let fake: FakeRexServer
        let server: ServerConnection
        let store = Store()
        let hooks = Hooks()
        private let model: AppModel

        init(revision: Int? = 18) async throws {
            fake = try FakeRexServer(revision: revision, serverRevision: revision)
            let address = await fake.start()
            let name = "PanesServerTests-\(UUID().uuidString)"
            let d = UserDefaults(suiteName: name)!
            d.removePersistentDomain(forName: name)
            let prefs = Prefs(defaults: d)
            model = AppModel(prefs: prefs, connect: false)
            server = ServerConnection(config: ServerConfig(name: "Desk", url: address), prefs: prefs,
                                      notifier: model.notifier, deviceID: "a1b2c3d4")
            let store = store, hooks = hooks
            fake.onRequest { r in
                if let a = hooks.answer(r) { return a }
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

        /// The methods the app sent since the last `forget`, without the metadata reads.
        var sent: [String] { fake.requests.map(\.method).filter { !$0.hasPrefix(PanesServerTests.terminal) } }
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

    // MARK: Move to New Tab

    func testMoveToNewTabSendsTheMoveTheCloseAndThePlaceInOrderWithNoPoll() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        rig.fake.reply("session.new_window", ["window_id": "window:9", "block_ids": ["block:p"], "revision": 4])
        rig.fake.reply("session.move_block", ["created_split_id": "split:9", "revision": 5])
        rig.fake.reply("block.close", [:])
        rig.fake.reply("session.move_window", ["revision": 6])
        await rig.connect()

        let tab = await rig.server.moveToNewTab("session:1", block: "a", source: "window:1")

        XCTAssertEqual(tab, "window:9")
        XCTAssertEqual(rig.sent, ["session.new_window", "session.move_block", "block.close", "session.move_window", "session.view"])
        let made = try XCTUnwrap(rig.fake.calls("session.new_window").first)
        XCTAssertNil(made["window_label"], "the new tab's title follows its pane")
        XCTAssertEqual(made["focus"] as? Bool, false)
        XCTAssertEqual(rig.fake.calls("session.move_block").first?.str("anchor_block_id"), "block:p")
        XCTAssertEqual(rig.fake.calls("block.close").first?.str("block_id"), "block:p")
        XCTAssertEqual(rig.fake.calls("session.move_window").first?.str("before_window_id"), "window:2", "right after its tab")
        XCTAssertEqual(rig.fake.count("session.view"), 1, "one immediate read, no polling")
    }

    func testMoveToNewTabFromTheLastTabNeedsNoPlace() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        rig.fake.reply("session.new_window", ["window_id": "window:9", "block_ids": ["block:p"], "revision": 4])
        rig.fake.reply("session.move_block", ["revision": 5])
        rig.fake.reply("block.close", [:])
        await rig.connect()

        _ = await rig.server.moveToNewTab("session:1", block: "x", source: "window:2")

        XCTAssertEqual(rig.sent, ["session.new_window", "session.move_block", "block.close", "session.view"])
    }

    func testAFailedMoveIsStillClosedAndOnlyItsErrorShows() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        rig.fake.reply("session.new_window", ["window_id": "window:9", "block_ids": ["block:p"], "revision": 4])
        rig.fake.reply("session.move_block", .error(code: "conflict", status: 409))
        rig.fake.reply("block.close", [:])
        // The close emptied the new tab, which closed it: the place finds no tab.
        rig.fake.reply("session.move_window", .error(code: "not_found", status: 404))
        await rig.connect()

        let tab = await rig.server.moveToNewTab("session:1", block: "a", source: "window:1")

        XCTAssertNil(tab)
        XCTAssertEqual(Array(rig.sent.prefix(4)), ["session.new_window", "session.move_block", "block.close", "session.move_window"])
        XCTAssertEqual(Notice.shared.message, "That tab can't take another pane.")
        XCTAssertTrue(rig.server.capabilities.paneSupport.has(.moveToNewTab), "a refusal is no missing method")
    }

    // MARK: Balance and Close Other Panes

    func testBalanceSendsEveryCallAtOnceThenReadsTheViewOnce() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        rig.fake.reply("session.resize_pane", ["revision": 9])
        rig.fake.delay("session.resize_pane", seconds: 0.4)
        await rig.connect()
        let changes = [SplitBalance.Change(direction: "horizontal", before: "a", after: "b", ratio: 0.5),
                       SplitBalance.Change(direction: "vertical", before: "c", after: "d", ratio: 0.5),
                       SplitBalance.Change(direction: "horizontal", before: "e", after: "f", ratio: 1.0 / 3)]

        let done = Task { await rig.server.balance("session:1", changes) }
        // All three are out before the first answer comes back.
        let together = await eventually(seconds: 0.3) { rig.fake.count("session.resize_pane") == 3 }
        XCTAssertTrue(together)
        await done.value
        _ = await eventually { rig.fake.count("session.view") >= 1 }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(rig.fake.count("session.view"), 1)
        XCTAssertNil(Notice.shared.message)
    }

    func testCloseOtherPanesClosesTheSnapshotInOrderAndAGonePaneIsFine() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        rig.hooks.set { r in
            guard r.method == "block.close" else { return nil }
            return r.payload.str("block_id") == "c" ? .error(code: "not_found", status: 404) : .result([:])
        }
        await rig.connect()

        await rig.server.closeBlocks("session:1", ["b", "c", "d"])

        XCTAssertEqual(rig.fake.calls("block.close").compactMap { $0.str("block_id") }, ["b", "c", "d"])
        _ = await eventually { rig.fake.count("session.view") == 1 }
        XCTAssertEqual(rig.fake.count("session.view"), 1)
        XCTAssertNil(Notice.shared.message)
    }

    // MARK: Held sidebar order

    func testATabOrderIsHeldUntilTheViewReachesTheNewestRevision() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        rig.fake.reply("session.move_window", ["revision": 7])
        await rig.connect()
        let move = try XCTUnwrap(TabOrder.before(["window:1", "window:2"], moving: "window:2", gap: 0))

        rig.server.dragTab("session:1", "window:2", move)
        XCTAssertEqual(rig.server.orderedWindowIDs("session:1"), ["window:2", "window:1"], "shows at once")
        _ = await eventually { rig.server.pendingOrder.tabs["session:1"]?.revision == 7 }
        // An older view doesn't let go.
        rig.server.apply(view: SessionView(Store.view("session:1", revision: 6, windows: [
            Store.window("window:1", focused: "a", split: ("a", "b")), Store.window("window:2", focused: "x", single: "x")])))
        XCTAssertEqual(rig.server.orderedWindowIDs("session:1"), ["window:2", "window:1"])
        rig.store.setView("session:1", Store.view("session:1", revision: 7, windows: [
            Store.window("window:2", focused: "x", single: "x"), Store.window("window:1", focused: "a", split: ("a", "b"))]))
        rig.fake.send(session: "session:1", event: "session_view_changed", ["revision": 7])
        let released = await eventually { rig.server.pendingOrder.isEmpty }
        XCTAssertTrue(released)
        XCTAssertEqual(rig.server.orderedWindowIDs("session:1"), ["window:2", "window:1"], "now the server's own order")
    }

    func testAnEarlierDragsRevisionDoesNotLetGo() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        let answers = Answers([5, 9])
        rig.hooks.set { r in r.method == "session.move_window" ? .result(["revision": answers.next()]) : nil }
        await rig.connect()
        let first = try XCTUnwrap(TabOrder.before(["window:1", "window:2"], moving: "window:2", gap: 0))
        rig.server.dragTab("session:1", "window:2", first)
        let second = try XCTUnwrap(TabOrder.before(first.order, moving: "window:2", gap: 2))
        rig.server.dragTab("session:1", "window:2", second)
        _ = await eventually { rig.server.pendingOrder.tabs["session:1"]?.revision != nil }
        XCTAssertEqual(rig.server.pendingOrder.tabs["session:1"]?.revision, 9, "the newest drag's revision")
        rig.server.apply(view: SessionView(Store.view("session:1", revision: 5, windows: [
            Store.window("window:2", focused: "x", single: "x"), Store.window("window:1", focused: "a", split: ("a", "b"))])))
        XCTAssertFalse(rig.server.pendingOrder.isEmpty)
        XCTAssertEqual(rig.server.orderedWindowIDs("session:1"), ["window:1", "window:2"])
    }

    func testAHoldLetsGoTwoSecondsAfterTheCallReturns() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        rig.fake.reply("session.move_window", ["revision": 50])
        rig.fake.delay("session.move_window", seconds: 0.5)
        await rig.connect()
        let move = try XCTUnwrap(TabOrder.before(["window:1", "window:2"], moving: "window:2", gap: 0))
        let start = Date()
        rig.server.dragTab("session:1", "window:2", move)
        let released = await eventually(seconds: 4) { rig.server.pendingOrder.isEmpty }
        XCTAssertTrue(released)
        // Counted from the return (0.5 s), not from the drop.
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 2.4)
        XCTAssertEqual(rig.server.orderedWindowIDs("session:1"), ["window:1", "window:2"])
    }

    func testAFailedCallLetsGoAtOnce() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        rig.fake.reply("session.move_window", .error(code: "not_found", status: 404))
        await rig.connect()
        let move = try XCTUnwrap(TabOrder.before(["window:1", "window:2"], moving: "window:2", gap: 0))
        rig.server.dragTab("session:1", "window:2", move)
        let released = await eventually(seconds: 1) { rig.server.pendingOrder.isEmpty }
        XCTAssertTrue(released)
        XCTAssertNil(Notice.shared.message, "a tab that is gone drops the hold silently")
    }

    func testASessionOrderIsHeldUntilTheListAgreesWithoutHiddenSessions() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        rig.store.sessions = ["session:1", "session:h", "session:2"]
        rig.server.hiddenSessions = { ["session:h"] }
        rig.hooks.set { [store = rig.store] r in
            guard r.method == "session.move" else { return nil }
            store.sessions = ["session:2", "session:h", "session:1"]
            return .result([:])
        }
        await rig.connect()
        XCTAssertEqual(rig.server.sessions.map(\.id), ["session:1", "session:2"])

        rig.server.dragSession("session:2", order: ["session:2", "session:1"])
        XCTAssertEqual(rig.server.orderedSessions.map(\.id), ["session:2", "session:1"])
        _ = await eventually { rig.fake.count("session.move") == 1 }
        XCTAssertEqual(rig.fake.calls("session.move").first?.str("before_session_id"), "session:1")
        rig.fake.send(event: "session_moved", ["session_id": "session:2"])
        let released = await eventually { rig.server.pendingOrder.sessions == nil }
        XCTAssertTrue(released)
        XCTAssertEqual(rig.server.sessions.map(\.id), ["session:2", "session:1"])
    }

    func testASecondSessionDragWaitsForTheFirstAndFindsItsNeighborThen() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        rig.store.sessions = ["session:1", "session:2", "session:3"]
        rig.store.setView("session:3", Store.view("session:3", revision: 1, windows: [Store.window("window:4", focused: "z", single: "z")]))
        rig.fake.reply("session.move", [:])
        rig.fake.delay("session.move", seconds: 0.4)
        await rig.connect()

        rig.server.dragSession("session:3", order: ["session:3", "session:1", "session:2"])
        rig.server.dragSession("session:2", order: ["session:3", "session:2", "session:1"])
        _ = await eventually { rig.fake.count("session.move") >= 1 }
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(rig.fake.count("session.move"), 1, "the second waits")
        _ = await eventually { rig.fake.count("session.move") == 2 }
        let calls = rig.fake.calls("session.move")
        XCTAssertEqual(calls.map { $0.str("session_id") }, ["session:3", "session:2"])
        XCTAssertEqual(calls.map { $0.str("before_session_id") }, ["session:1", "session:1"])
    }

    func testANewConnectionLetsGoOfEveryHold() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        rig.fake.reply("session.move_window", .none)
        await rig.connect()
        let move = try XCTUnwrap(TabOrder.before(["window:1", "window:2"], moving: "window:2", gap: 0))
        rig.server.dragTab("session:1", "window:2", move)
        _ = await eventually { rig.fake.count("session.move_window") == 1 }
        rig.fake.dropAll()
        let back = await eventually(seconds: 6) { rig.server.control.state == .connected && rig.server.pendingOrder.isEmpty }
        XCTAssertTrue(back)
        XCTAssertEqual(rig.fake.count("session.move_window"), 1, "never sent again")
    }

    // MARK: Session list reads

    func testAListReadThatASyncOvertookIsDropped() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        await rig.connect()
        rig.fake.delay("session.list", seconds: 0.4)
        rig.store.sessions = ["session:2", "session:1"]
        rig.fake.send(event: "session_moved", ["session_id": "session:2"])
        _ = await eventually { rig.fake.count("session.list") == 1 }
        // The server moves it back, and a full sync reads that before the list's answer lands.
        rig.store.sessions = ["session:1", "session:2"]
        await rig.server.bootstrap()
        XCTAssertEqual(rig.server.sessions.map(\.id), ["session:1", "session:2"])
        _ = await eventually { rig.server.sessionListTask == nil }
        XCTAssertEqual(rig.server.sessions.map(\.id), ["session:1", "session:2"], "the older list never lands last")
    }

    func testEventsDuringAReadAskForOneMore() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        await rig.connect()
        rig.fake.delay("session.list", seconds: 0.3)
        rig.store.sessions = ["session:2", "session:1"]
        // A burst is one read.
        for _ in 0..<4 { rig.fake.send(event: "session_moved", ["session_id": "session:2"]) }
        _ = await eventually { rig.fake.count("session.list") >= 1 }
        // Events while that read is out ask for one more, whatever their number.
        for _ in 0..<3 { rig.fake.send(event: "session_moved", ["session_id": "session:2"]) }
        _ = await eventually { rig.server.sessionListTask == nil }
        XCTAssertEqual(rig.fake.count("session.list"), 2, "one read, and one more for the events during it")
        XCTAssertEqual(rig.server.sessions.map(\.id), ["session:2", "session:1"])
    }

    func testADroppedSessionMoveRunsTheSameReadAndNoBootstrap() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        await rig.connect()
        rig.store.sessions = ["session:2", "session:1"]
        rig.fake.send(event: "event_dropped", ["event_type": "session_moved", "size": 1])
        _ = await eventually { rig.server.sessions.first?.id == "session:2" }
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(rig.fake.count("session.list"), 1)
        XCTAssertEqual(rig.fake.count("session.bootstrap"), 0)
    }

    // MARK: Support

    func testAMissingMethodHidesOnlyItsCommands() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        await rig.connect()
        XCTAssertTrue(PaneCommand.allCases.allSatisfy { rig.server.capabilities.paneSupport.has($0) })
        XCTAssertEqual(rig.server.keymap.panes, rig.server.capabilities.paneSupport)
        // The fake answers `method_not_found` for anything it wasn't told.
        await rig.server.swapBlocks("session:1", "a", "b")
        let s = rig.server.capabilities.paneSupport
        XCTAssertFalse(s.has(.swap))
        XCTAssertTrue(s.has(.balance) && s.has(.moveToTab) && s.has(.closeOthers) && s.has(.moveTab))
        XCTAssertEqual(rig.server.keymap.panes, s, "the keys follow at once")
        XCTAssertTrue(Notice.shared.message?.hasPrefix("Couldn't swap the panes.") == true, "one notice, the tap's")

        await rig.server.balance("session:1", [SplitBalance.Change(direction: "horizontal", before: "a", after: "b", ratio: 0.5)])
        XCTAssertFalse(rig.server.capabilities.paneSupport.has(.balance))
        XCTAssertTrue(rig.server.capabilities.paneSupport.has(.closeOthers))
    }

    func testAReconnectToAnOlderServerTakesTheCommandsAwayAndBack() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        await rig.connect()
        XCTAssertTrue(rig.server.keymap.panes.has(.balance))
        rig.fake.play(revision: nil)
        rig.fake.dropAll()
        let old = await eventually(seconds: 6) { rig.server.control.state == .connected && rig.server.capabilities.revision == 0 }
        XCTAssertTrue(old)
        XCTAssertFalse(PaneCommand.allCases.contains { rig.server.capabilities.paneSupport.has($0) })
        XCTAssertEqual(rig.server.keymap.panes.revision, 0)
        rig.fake.play(revision: 18, serverRevision: 18)
        rig.fake.dropAll()
        let back = await eventually(seconds: 6) { rig.server.control.state == .connected && rig.server.capabilities.revision == 18 }
        XCTAssertTrue(back)
        XCTAssertTrue(rig.server.keymap.panes.has(.balance))
    }

    func testAReconnectDuringClosesResendsNothing() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        rig.fake.reply("block.close", .none)
        await rig.connect()
        let closing = Task { await rig.server.closeBlocks("session:1", ["b"]) }
        _ = await eventually { rig.fake.count("block.close") == 1 }
        rig.fake.dropAll()
        await closing.value
        _ = await eventually(seconds: 6) { rig.server.control.state == .connected && rig.server.synced }
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(rig.fake.count("block.close"), 1)
    }

    // MARK: Names

    /// Arrange's contents read no title: an agent's spinner changes the title ten times a second,
    /// and neither the menu's model nor anything it observes changes with it.
    func testATitleThatSpinsChangesNothingTheMenuObserves() async throws {
        let rig = try await Rig()
        defer { rig.stop() }
        await rig.connect()
        let server = rig.server
        var m = server.meta["a"] ?? BlockMeta()
        m.foreground = "claude"
        m.title = "✳ Claude Code"
        server.meta["a"] = m
        let w = try XCTUnwrap(server.views["session:1"]?.window("window:1"))
        let before = PaneMenuModel.make(server: server, sessionID: "session:1", window: w, block: "b")
        XCTAssertEqual(before?.swap.first?.name, "Claude")

        let fired = Flag()
        withObservationTracking {
            _ = PaneMenuModel.make(server: server, sessionID: "session:1", window: w, block: "b")
        } onChange: { fired.set() }
        for glyph in ["✶", "✻", "✽", "✢", "✳"] {
            m.title = "\(glyph) Claude Code"
            server.meta["a"] = m
        }
        XCTAssertFalse(fired.value, "a title change re-runs nothing that builds the menu")
        XCTAssertEqual(PaneMenuModel.make(server: server, sessionID: "session:1", window: w, block: "b"), before)

        m.foreground = "vim"
        m.title = "vim"
        server.meta["a"] = m
        XCTAssertTrue(fired.value, "a new program is a new name")
    }
}

/// Answers handed out one by one to the fake server's queue.
private final class Answers: @unchecked Sendable {
    // `@unchecked`: `left` is only touched under `lock`.
    private let lock = NSLock()
    private var left: [Int]
    init(_ values: [Int]) { left = values }
    func next() -> Int { lock.withLock { left.isEmpty ? 0 : left.removeFirst() } }
}

private final class Flag: @unchecked Sendable {
    // `@unchecked`: `on` is only touched under `lock`.
    private let lock = NSLock()
    private var on = false
    func set() { lock.withLock { on = true } }
    var value: Bool { lock.withLock { on } }
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
