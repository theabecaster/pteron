import Foundation
import GlanceModel
import XCTest
import RexKit
@testable import Pteron

/// `ServerConnection` against a Rex server in this process (`FakeRexServer`), played at the API
/// revisions the app meets: what it reads when it connects, what it reads again for a dropped
/// event, how it answers a prompt, and what a refused connection shows.
@MainActor
final class ServerEventsTests: XCTestCase {
    nonisolated static let terminal = "com.superlogical.terminal"

    /// One fake server and the connection to it.
    @MainActor
    final class Rig {
        let fake: FakeRexServer
        let server: ServerConnection
        private let model: AppModel
        /// What `session.list` and the bootstrap name; the fake reads it on its own queue.
        private let listed = Listed()

        final class Listed: @unchecked Sendable {
            // `@unchecked`: `ids` is only touched under `lock`.
            private let lock = NSLock()
            private var ids = ["session:1", "session:2"]
            private var process = "instance-1"
            private var more: [String] = []
            /// Blocks added to session 1's view, newest last.
            var extra: [String] {
                get { lock.withLock { more } }
                set { lock.withLock { more = newValue } }
            }
            var value: [String] {
                get { lock.withLock { ids } }
                set { lock.withLock { ids = newValue } }
            }
            var instance: String {
                get { lock.withLock { process } }
                set { lock.withLock { process = newValue } }
            }
        }

        init(revision: Int?, serverRevision: Int? = nil, creators: FakeRexServer.Reply? = nil) async throws {
            fake = try FakeRexServer(revision: revision, serverRevision: serverRevision ?? revision)
            let address = await fake.start()
            let name = "ServerEventsTests-\(UUID().uuidString)"
            let d = UserDefaults(suiteName: name)!
            d.removePersistentDomain(forName: name)
            let prefs = Prefs(defaults: d)
            model = AppModel(prefs: prefs, connect: false)
            // A schedule with no jitter. The app's first retry falls anywhere from 0 to 1 s: near
            // 0 the connection is back before a test that dropped it sees it down. Here the
            // first retry comes after exactly 1 s.
            var policy = ReconnectPolicy()
            policy.fullJitterFirst = false
            policy.jitter = 0
            server = ServerConnection(config: ServerConfig(name: "Desk", url: address), prefs: prefs,
                                      notifier: model.notifier, deviceID: "a1b2c3d4",
                                      governor: ReconnectGovernor(policy: policy))
            script(creators: creators ?? .result(ServerEventsTests.creators()))
        }

        private func script(creators: FakeRexServer.Reply) {
            let listed = listed
            fake.onRequest { r in
                switch r.method {
                case "session.attach", "session.view":
                    let sid = r.payload.str("session_id") ?? ""
                    return .result(["view": ServerEventsTests.view(sid, extra: sid == "session:1" ? listed.extra : [])])
                case "session.bootstrap":
                    return .result(ServerEventsTests.bootstrap(listed.value, instance: listed.instance))
                case "session.list":
                    return .result(["sessions": listed.value.map { ["session_id": $0, "label": "label \($0)"] }])
                default:
                    return nil
                }
            }
            fake.reply("\(ServerEventsTests.terminal).program_status", ["records": [["id": "claude", "app": "claude", "state": "working"] as JSONObject]])
            fake.reply("\(ServerEventsTests.terminal).title", ["title": "zsh"])
            fake.reply("\(ServerEventsTests.terminal).process", ["foreground": ["name": "zsh"] as JSONObject])
            fake.reply("hosts.list", ["hosts": [["id": "host-a", "label": "desk", "endpoints": [String]()] as JSONObject]])
            fake.reply("server.version", ["platform": "darwin_arm64"])
            fake.reply("server.whoami", [:])
            fake.reply("client.keymap", ["bindings": [JSONObject](), "config": ["hash": "h", "instance_id": "instance-1"] as JSONObject])
            fake.reply("client.reply", [:])
            fake.reply("block_creator.list", creators)
        }

        func setSessions(_ ids: [String]) { listed.value = ids }
        /// Places another pane in session 1's first tab, in a newer view.
        func setViewExtra(_ block: String) { listed.extra.append(block) }
        /// The server process the next bootstrap names (`instance_id`).
        func setInstance(_ id: String) { listed.instance = id }

        /// Connects and waits until the sync has made its last call.
        func connect() async {
            server.start()
            await settle()
        }

        /// Waits for a sync to finish (the keymap is its last read) and the creator list to land.
        func settle(keymapLoads: Int = 1) async {
            _ = await eventually { self.fake.count("client.keymap") >= keymapLoads && self.server.synced && self.server.creatorsTask == nil }
        }

        func stop() {
            server.stop()
            fake.stop()
        }
    }

    nonisolated static func view(_ sid: String, extra: [String] = []) -> JSONObject {
        let n = sid.split(separator: ":").last.map(String.init) ?? "0"
        func block(_ id: String) -> JSONObject {
            ["block_id": id, "creator_name": terminal, "flavor": "\(terminal).shell", "host_id": "host-a", "label": "shell"]
        }
        return [
            "session_id": sid, "label": "label \(sid)", "revision": 3 + extra.count, "active_window_id": "window:\(n)",
            "windows": [[
                "window_id": "window:\(n)", "label": "tab", "focused_block_id": "block:\(n)a",
                "layers": [[
                    "kind": "tiled", "layer_id": "layer:\(n)", "bounds": [0, 0, 1, 1],
                    "blocks": [block("block:\(n)a"), block("block:\(n)b")] + extra.map(block),
                    "layout": ["rect": [0, 0, 1, 1], "split": [
                        "split_id": "split:\(n)", "direction": "horizontal", "ratio": 0.5,
                        "before": ["block_id": "block:\(n)a", "rect": [0, 0, 0.5, 1]],
                        "after": ["block_id": "block:\(n)b", "rect": [0.5, 0, 0.5, 1]],
                    ] as JSONObject] as JSONObject,
                ] as JSONObject],
            ] as JSONObject],
        ]
    }

    nonisolated static func bootstrap(_ sessions: [String], instance: String = "instance-1") -> JSONObject {
        ["client_id": "client:test",
         "server_status": ["instance_id": instance, "host_id": "host-a",
                           "tailscale": ["dns_name": "desk.example.ts.net"] as JSONObject] as JSONObject,
         "attach_all": ["sessions": sessions.map { ["session_id": $0, "label": "label \($0)"] }] as JSONObject]
    }

    nonisolated static func creators() -> JSONObject {
        ["creators": [[
            "name": terminal, "host_id": "host-a", "flavors": [["flavor": "\(terminal).shell"]],
            "api": ["events": ["bell": [:], "progress_report": [:]], "methods": ["write": [:], "list_dir": [:], "ports": [:]]],
        ] as JSONObject]]
    }

    /// Everything the screen is drawn from, as text.
    private func snapshot(_ s: ServerConnection) -> String {
        var lines = ["phase \(s.phase) synced \(s.synced) hosts \(s.hosts) hostName \(s.hostName ?? "-") platform \(s.platform ?? "-")"]
        for e in s.sessions {
            lines.append("session \(e.id) \(e.label)")
            guard let v = s.views[e.id] else { continue }
            for w in v.windows {
                lines.append("  window \(w.id) \(w.label) focus \(w.focusedBlockID ?? "-") order \(w.orderedBlockIDs) splits \(w.layout?.splits.map { "\($0.direction) \($0.ratio)" } ?? [])")
                for b in w.allBlocks {
                    let m = s.meta[b.id]
                    lines.append("    block \(b.id) \(b.label) title \(m?.title ?? "-") fg \(m?.foreground ?? "-") status \(m?.topStatus?.state ?? "-") agent \(m?.agentKind?.rawValue ?? "-")")
                }
            }
        }
        lines.append("agents \(s.currentAgentKeys().map { "\($0.blockID):\($0.state ?? "-")" })")
        return lines.joined(separator: "\n")
    }

    // MARK: Revisions

    /// Servers at revisions 0, 13, 16 and 18, and one that answers `method_not_found` for
    /// everything newer than 13, give the same sessions, tabs, panes, statuses and agents.
    func testEveryServerRevisionGivesTheSameModel() async throws {
        var baseline: String?
        var baselineMethods: Set<String>?
        let cases: [(String, Int?, FakeRexServer.Reply?)] = [
            ("13", 13, nil), ("0", nil, nil), ("16", 16, nil), ("18", 18, nil),
            ("18 without the creator list", 18, .error(code: "method_not_found", status: 404)),
            ("0 answering not_found", nil, .error(code: "not_found", status: 404)),
        ]
        for (name, revision, creators) in cases {
            let rig = try await Rig(revision: revision, creators: creators)
            await rig.connect()
            XCTAssertEqual(rig.server.phase, .online, name)
            XCTAssertEqual(rig.server.capabilities.revision, revision ?? 0, name)
            XCTAssertEqual(rig.fake.lastHello?.int("api_revision"), 18)
            XCTAssertNil(rig.fake.lastHello?["api_min_revision"])
            let snap = snapshot(rig.server)
            let methods = Set(rig.fake.requests.map(\.method))
            if let baseline {
                XCTAssertEqual(snap, baseline, "revision \(name) must show what revision 13 shows")
                XCTAssertEqual(methods, baselineMethods, "revision \(name) must make the calls revision 13 makes")
            } else {
                baseline = snap
                baselineMethods = methods
                XCTAssertTrue(snap.contains("status working agent claude"), snap)
                XCTAssertTrue(snap.contains("order [\"block:1a\", \"block:1b\"]"), snap)
            }
            XCTAssertNil(rig.server.lastError, name)
            rig.stop()
        }
    }

    // MARK: Capabilities

    /// `agentsCurrent` is what a "Jump to Waiting" link waits for: true once the states have
    /// been read, false again while a trip to the background or a resync leaves them unknown.
    func testAgentStatesAreCurrentOnlyAfterAFullRead() async throws {
        let rig = try await Rig(revision: 18)
        defer { rig.stop() }
        XCTAssertFalse(rig.server.agentsCurrent)
        await rig.connect()
        XCTAssertTrue(rig.server.agentsCurrent)
        XCTAssertEqual(rig.server.currentAgentKeys().first?.state, "working")

        rig.server.enteredBackground()
        XCTAssertFalse(rig.server.agentsCurrent)
        rig.server.resume(fromBackground: true)
        XCTAssertFalse(rig.server.agentsCurrent)
        await rig.settle(keymapLoads: 2)
        XCTAssertTrue(rig.server.agentsCurrent)

        rig.server.scheduleResync(after: 0)
        XCTAssertFalse(rig.server.agentsCurrent)
        await rig.settle(keymapLoads: 3)
        XCTAssertTrue(rig.server.agentsCurrent)

        rig.server.stop()
        XCTAssertFalse(rig.server.agentsCurrent)
    }

    func testCapabilitiesFollowTheServer() async throws {
        let rig = try await Rig(revision: 18)
        defer { rig.stop() }
        await rig.connect()
        let caps = rig.server.capabilities
        XCTAssertEqual(caps.revision, 18)
        XCTAssertTrue(caps.supports(15))
        XCTAssertEqual(caps.hostID, "host-a")
        XCTAssertEqual(caps.method("list_dir", creator: Self.terminal, host: "host-a"), .present)
        XCTAssertEqual(caps.event("progress_report", creator: Self.terminal, host: "host-a"), .present)
        XCTAssertEqual(caps.method("list_dir", creator: Self.terminal, host: "host-b"), .absent)
        XCTAssertEqual(rig.fake.count("block_creator.list"), 1, "once per sync")
        caps.record(method: "list_dir", host: "host-a", .present, serial: rig.server.connectionSerial)
        XCTAssertEqual(caps.probe(method: "list_dir", host: "host-a"), true)

        // The server is downgraded under the app: a new welcome at 13, and an older creator list.
        rig.fake.play(revision: 13, serverRevision: 13)
        rig.fake.reply("block_creator.list", ["creators": [["name": Self.terminal, "host_id": "host-a",
                                                           "api": ["methods": ["write": [:]], "events": ["bell": [:]]]] as JSONObject]])
        rig.fake.dropAll()
        _ = await eventually { rig.server.connectionSerial == 2 }
        await rig.settle(keymapLoads: 2)
        XCTAssertEqual(caps.revision, 13)
        XCTAssertFalse(caps.supports(15), "what needs revision 15 hides")
        XCTAssertNil(caps.probe(method: "list_dir", host: "host-a"), "a probe's answer belongs to its connection")
        XCTAssertEqual(caps.method("list_dir", creator: Self.terminal, host: "host-a"), .absent)
        XCTAssertEqual(caps.event("progress_report", creator: Self.terminal, host: "host-a"), .absent)
        do {
            try await rig.server.control.blockCall("\(Self.terminal).ports", session: "session:1", block: "block:1a")
            XCTFail("ports needs revision 15")
        } catch {
            XCTAssertEqual((error as? RexError)?.code, "revision_too_low")
        }
        XCTAssertEqual(rig.fake.count("\(Self.terminal).ports"), 0)

        // And updated again: it shows again, with no restart of the app.
        rig.fake.play(revision: 18, serverRevision: 18)
        rig.fake.reply("block_creator.list", Self.creators())
        rig.fake.dropAll()
        _ = await eventually { rig.server.connectionSerial == 3 }
        await rig.settle(keymapLoads: 3)
        XCTAssertTrue(caps.supports(15))
        XCTAssertEqual(caps.method("list_dir", creator: Self.terminal, host: "host-a"), .present)
    }

    /// The list is about 70 KB: one read per server process and revision, whatever else syncs.
    func testAResyncAndAReconnectToTheSameServerDoNotReadTheCreatorsAgain() async throws {
        let rig = try await Rig(revision: 18)
        defer { rig.stop() }
        await rig.connect()
        XCTAssertEqual(rig.fake.count("block_creator.list"), 1)

        // A resync: back in the foreground, pull to refresh, a gap in the events.
        await rig.server.bootstrap()
        rig.server.scheduleResync(after: 0)
        await rig.settle(keymapLoads: 3)
        XCTAssertEqual(rig.fake.count("session.bootstrap"), 3)
        XCTAssertEqual(rig.fake.count("block_creator.list"), 1, "a resync reads no creators")

        // The connection drops and comes back to the same server process at the same revision.
        rig.fake.dropAll()
        _ = await eventually { rig.server.connectionSerial == 2 }
        await rig.settle(keymapLoads: 4)
        XCTAssertEqual(rig.fake.count("session.bootstrap"), 4)
        XCTAssertEqual(rig.fake.count("block_creator.list"), 1, "nor does a reconnect to the same server")
        XCTAssertEqual(rig.server.capabilities.method("list_dir", creator: Self.terminal, host: "host-a"), .present)

        // The server restarted (another instance_id): it may be another version.
        rig.setInstance("instance-2")
        rig.fake.dropAll()
        _ = await eventually { rig.server.connectionSerial == 3 }
        await rig.settle(keymapLoads: 5)
        XCTAssertEqual(rig.fake.count("block_creator.list"), 2, "another server process is read once")
        await rig.server.bootstrap()
        XCTAssertEqual(rig.fake.count("block_creator.list"), 2)
    }

    /// A read that fails must not take away what is known: entry points would blink.
    func testAFailedCreatorReadKeepsTheKnownList() async throws {
        let rig = try await Rig(revision: 18)
        defer { rig.stop() }
        await rig.connect()
        XCTAssertEqual(rig.server.capabilities.method("list_dir", creator: Self.terminal, host: "host-a"), .present)

        // The server answers the re-read with an error.
        rig.fake.reply("block_creator.list", .error(code: "internal", status: 500))
        rig.fake.send(session: "session:1", event: "creator_changed")
        _ = await eventually { rig.fake.count("block_creator.list") == 2 && rig.server.creatorsTask == nil }
        XCTAssertEqual(rig.server.capabilities.method("list_dir", creator: Self.terminal, host: "host-a"), .present)

        // The connection dies under a re-read (as a wake with a dead socket does).
        rig.fake.reply("block_creator.list", .none)
        rig.fake.send(session: "session:1", event: "creator_changed")
        _ = await eventually { rig.fake.count("block_creator.list") == 3 }
        rig.fake.reply("block_creator.list", Self.creators())
        rig.fake.dropAll()
        _ = await eventually { rig.server.control.state != .connected }
        XCTAssertEqual(rig.server.capabilities.method("list_dir", creator: Self.terminal, host: "host-a"), .present,
                       "a read the connection dropped under changes nothing")
        // The lost read is made up for by the next sync.
        _ = await eventually { rig.server.connectionSerial == 2 && rig.fake.count("block_creator.list") == 4 }
        XCTAssertEqual(rig.fake.count("block_creator.list"), 4)
        XCTAssertEqual(rig.server.capabilities.method("list_dir", creator: Self.terminal, host: "host-a"), .present)
    }

    func testCreatorsAreReadAgainWhenTheServerSaysTheyChanged() async throws {
        let rig = try await Rig(revision: 18)
        defer { rig.stop() }
        await rig.connect()
        rig.fake.forget()

        rig.fake.reply("block_creator.list", ["creators": [JSONObject]()])
        rig.fake.send(session: "session:1", event: "creator_changed")
        let again = await eventually { rig.fake.count("block_creator.list") == 1 && rig.server.capabilities.catalog?.creators.isEmpty == true }
        XCTAssertTrue(again, "creator_changed reads the list again")

        rig.fake.reply("block_creator.list", Self.creators())
        rig.fake.send(event: "hosts_changed", ["hash": "x"])
        let hosts = await eventually {
            rig.fake.count("block_creator.list") == 2 && rig.fake.count("hosts.list") == 1
                && rig.server.capabilities.catalog?.creators.count == 1
        }
        XCTAssertTrue(hosts, "a changed host list brings other creators")
        XCTAssertEqual(rig.fake.count("session.bootstrap"), 0)
    }

    // MARK: Dropped events

    private func drop(_ rig: Rig, _ type: String, session: String? = nil, block: String? = nil, name: String? = nil) {
        var p: JSONObject = ["event_type": type, "size": 2_000_000]
        if let session { p["session_id"] = session }
        if let block { p["block_id"] = block; p["creator_name"] = Self.terminal }
        if let name { p["block_event_name"] = name }
        rig.fake.send(event: "event_dropped", p)
    }

    /// Long enough for a resync (0.25 s) or a view read (0.08 s) that shouldn't happen to happen.
    private func quiet() async { try? await Task.sleep(for: .milliseconds(600)) }

    func testADroppedBlockEventReadsThatBlocksMetadataAndDoesNotBootstrap() async throws {
        let rig = try await Rig(revision: 18)
        defer { rig.stop() }
        await rig.connect()
        XCTAssertEqual(rig.server.meta["block:1a"]?.topStatus?.state, "working")
        rig.fake.forget()
        var handled: [String] = []
        rig.server.router.on(blockEvent: "program_status_changed") { sid, bid in handled.append("\(sid ?? "-") \(bid)") }
        rig.server.router.on(blockEvent: "progress_report") { _, _ in handled.append("wrong handler") }

        // The status the dropped event carried: the agent now waits.
        rig.fake.reply("\(Self.terminal).program_status", ["records": [["id": "claude", "app": "claude", "state": "blocked", "kind": "question"] as JSONObject]])
        drop(rig, "block_event", session: "session:1", block: "block:1a", name: "program_status_changed")
        let read = await eventually { rig.server.meta["block:1a"]?.topStatus?.state == "blocked" }
        XCTAssertTrue(read, "the status is read back")
        await quiet()
        XCTAssertEqual(handled, ["session:1 block:1a"], "the handler registered for that event name runs, once")
        for m in ["program_status", "title", "process"] {
            let calls = rig.fake.calls("\(Self.terminal).\(m)")
            XCTAssertEqual(calls.count, 1, m)
            XCTAssertEqual(calls.first?.str("block_id"), "block:1a")
        }
        XCTAssertEqual(rig.fake.count("session.bootstrap"), 0, "never a full sync")
        XCTAssertEqual(rig.fake.count("session.view"), 0)
        XCTAssertEqual(rig.fake.count("session.attach"), 0)
        XCTAssertEqual(rig.server.meta["block:1b"]?.topStatus?.state, "working", "other panes are left alone")
    }

    func testADroppedBlockEventWithoutASessionFindsItInTheViews() async throws {
        let rig = try await Rig(revision: 18)
        defer { rig.stop() }
        await rig.connect()
        rig.fake.forget()
        drop(rig, "block_event", block: "block:2b", name: "title_changed")
        let read = await eventually { rig.fake.count("\(Self.terminal).title") == 1 }
        XCTAssertTrue(read)
        XCTAssertEqual(rig.fake.calls("\(Self.terminal).title").first?.str("session_id"), "session:2")
        await quiet()
        XCTAssertEqual(rig.fake.count("session.bootstrap"), 0)
    }

    func testADroppedSessionEventReadsThatSessionsViewOnce() async throws {
        let rig = try await Rig(revision: 18)
        defer { rig.stop() }
        await rig.connect()
        rig.fake.forget()
        for type in ["session_view_changed", "window_created", "block_closed"] { drop(rig, type, session: "session:2") }
        // Wrapped in a session_event, the wrapper names the session.
        rig.fake.send(session: "session:2", event: "event_dropped", ["event_type": "window_closed", "size": 1])
        let read = await eventually { rig.fake.count("session.view") == 1 }
        XCTAssertTrue(read)
        await quiet()
        XCTAssertEqual(rig.fake.calls("session.view").map { $0.str("session_id") }, ["session:2"], "a burst is one read")
        XCTAssertEqual(rig.fake.count("session.bootstrap"), 0)
        XCTAssertEqual(rig.fake.count("\(Self.terminal).program_status"), 0)
    }

    func testDroppedSessionListEventsReadTheListOnce() async throws {
        let rig = try await Rig(revision: 18)
        defer { rig.stop() }
        await rig.connect()
        rig.fake.forget()
        // Session 1 was destroyed, 3 was created and now comes first.
        rig.setSessions(["session:3", "session:2"])
        drop(rig, "session_destroyed", session: "session:1")
        drop(rig, "session_created")
        drop(rig, "session_moved")
        let read = await eventually { rig.server.sessions.map(\.id) == ["session:3", "session:2"] && rig.server.views["session:3"] != nil }
        XCTAssertTrue(read, "\(rig.server.sessions)")
        await quiet()
        XCTAssertNil(rig.server.views["session:1"])
        XCTAssertEqual(rig.fake.count("session.list"), 1, "a burst is one read")
        XCTAssertEqual(rig.fake.calls("session.attach").map { $0.str("session_id") }, ["session:3"], "only the new session is attached")
        XCTAssertEqual(rig.fake.count("session.bootstrap"), 0)
    }

    func testDroppedServerWideEventsReadTheirOwnState() async throws {
        let rig = try await Rig(revision: 18)
        defer { rig.stop() }
        await rig.connect()
        rig.fake.forget()

        drop(rig, "hosts_changed")
        let hosts = await eventually { rig.fake.count("hosts.list") == 1 && rig.fake.count("block_creator.list") == 1 }
        XCTAssertTrue(hosts)

        drop(rig, "keymap_changed")
        let keymap = await eventually { rig.fake.count("client.keymap") == 1 }
        XCTAssertTrue(keymap)

        drop(rig, "creator_changed", session: "session:1")
        let creators = await eventually { rig.fake.count("block_creator.list") == 2 }
        XCTAssertTrue(creators)

        await quiet()
        XCTAssertEqual(Set(rig.fake.requests.map(\.method)), ["hosts.list", "block_creator.list", "client.keymap"])
    }

    func testDroppedEventsAddressedToThisClientAreIgnored() async throws {
        let rig = try await Rig(revision: 18)
        defer { rig.stop() }
        await rig.connect()
        rig.fake.forget()
        for type in ["client_prompt_requested", "client_call_requested", "client_perform_requested", "client_prompt_ended",
                     "client_performed", "tailscale_status_changed"] {
            drop(rig, type)
        }
        drop(rig, "client_script_events_dropped", session: "session:1")
        await quiet()
        XCTAssertEqual(rig.fake.requests.map(\.method), [], "nothing to read, and nothing to answer")
        XCTAssertEqual(rig.server.phase, .online)
    }

    /// A dropped `client_joined`, `client_left` or `client_changed` may have been the push
    /// helper coming, going or changing: the registrar looks for it again.
    func testDroppedClientEventsMakeThePushRegistrarLookForItsHelperAgain() async throws {
        let rig = try await Rig(revision: 18)
        defer { rig.stop() }
        let world = PushWorld()
        world.helpers.add(rig.server.id, name: "Desk")
        world.defaults.set(PushWorld.token, forKey: "pushToken.last")
        world.prefs.pushEnabled = true
        let phone = NotificationChoiceTests.Phone()
        let push = PushRegistrar(prefs: world.prefs, deviceID: "abcd1234", environment: "sandbox", defaults: world.defaults,
                                 parts: world.parts, system: phone.system)
        rig.server.push = push
        await rig.connect()
        await push.refresh()
        await world.eventually { world.helpers[rig.server.id].secret != nil }
        await world.quiet()

        // Nothing the registrar follows: it asks the helper nothing.
        var asked = world.helpers[rig.server.id].calls.count
        drop(rig, "client_performed")
        drop(rig, "client_prompt_requested")
        await quiet()
        XCTAssertEqual(world.helpers[rig.server.id].calls.count, asked)

        for type in ["client_changed", "client_joined", "client_left"] {
            asked = world.helpers[rig.server.id].calls.count
            drop(rig, type)
            await world.eventually { world.helpers[rig.server.id].calls.count > asked }
            XCTAssertGreaterThan(world.helpers[rig.server.id].calls.count, asked, "\(type): the helper is looked at again")
            await world.quiet()
        }
        XCTAssertEqual(rig.fake.count("session.bootstrap"), 1, "and never a full sync")
    }

    func testABurstOfDroppedBlockEventsIsOneReadPerBlock() async throws {
        let rig = try await Rig(revision: 18)
        defer { rig.stop() }
        await rig.connect()
        rig.fake.forget()
        for name in ["program_status_changed", "title_changed", "program_status_changed", "process_changed", "progress_report"] {
            drop(rig, "block_event", session: "session:1", block: "block:1a", name: name)
        }
        drop(rig, "block_event", session: "session:2", block: "block:2b", name: "program_status_changed")
        drop(rig, "block_event", block: "block:2b", name: "title_changed")
        let read = await eventually { rig.fake.count("\(Self.terminal).program_status") == 2 }
        XCTAssertTrue(read)
        await quiet()
        for m in ["program_status", "title", "process"] {
            XCTAssertEqual(rig.fake.calls("\(Self.terminal).\(m)").compactMap { $0.str("block_id") }.sorted(), ["block:1a", "block:2b"],
                           "\(m): seven drops, one read for each of the two blocks")
        }
        XCTAssertEqual(rig.fake.count("session.bootstrap"), 0)
    }

    /// The read for a dropped event is out when a newer status arrives live. The read's answer
    /// is the older one and must not replace it; what no live event touched is still taken.
    func testALiveStatusThatArrivesDuringTheReadWins() async throws {
        let rig = try await Rig(revision: 18)
        defer { rig.stop() }
        await rig.connect()
        XCTAssertEqual(rig.server.meta["block:1a"]?.topStatus?.state, "working")
        rig.fake.forget()

        rig.fake.delay("\(Self.terminal).program_status", seconds: 0.5)
        rig.fake.delay("\(Self.terminal).title", seconds: 0.5)
        rig.fake.reply("\(Self.terminal).title", ["title": "read title"])
        drop(rig, "block_event", session: "session:1", block: "block:1a", name: "program_status_changed")
        let out = await eventually { rig.fake.count("\(Self.terminal).program_status") == 1 }
        XCTAssertTrue(out, "the read has left")

        // Newer than what the read will answer (still "working").
        rig.fake.send(session: "session:1", event: "block_event", [
            "block_id": "block:1a", "name": "program_status_changed",
            "payload": ["id": "claude", "record": ["id": "claude", "app": "claude", "state": "done"] as JSONObject] as JSONObject,
        ])
        let done = await eventually { rig.server.meta["block:1a"]?.topStatus?.state == "done" && rig.server.meta["block:1a"]?.title == "read title" }
        XCTAssertTrue(done, "the live status shows, and the title comes from the read")
        try? await Task.sleep(for: .milliseconds(1500))
        XCTAssertEqual(rig.server.meta["block:1a"]?.topStatus?.state, "done", "the read's older answer never replaced it")
        XCTAssertEqual(rig.fake.count("\(Self.terminal).program_status"), 1)
    }

    func testOnlyAnUnknownDroppedTypeReadsEverythingOnce() async throws {
        let rig = try await Rig(revision: 18)
        defer { rig.stop() }
        await rig.connect()
        rig.fake.forget()
        drop(rig, "an_event_from_the_future")
        drop(rig, "another_one")
        let synced = await eventually { rig.fake.count("session.bootstrap") == 1 && rig.fake.count("client.keymap") == 1 }
        XCTAssertTrue(synced)
        await quiet()
        XCTAssertEqual(rig.fake.count("session.bootstrap"), 1, "one full sync for the burst")
    }

    func testAnUnknownLiveEventIsIgnored() async throws {
        let rig = try await Rig(revision: 18)
        defer { rig.stop() }
        await rig.connect()
        rig.fake.forget()
        let before = snapshot(rig.server)
        rig.fake.send(event: "an_event_from_the_future", ["anything": [1, 2, 3]])
        rig.fake.send(session: "session:1", event: "a_session_event_from_the_future", ["x": 1])
        rig.fake.send(session: "session:1", event: "block_event",
                      ["block_id": "block:1a", "name": "a_block_event_from_the_future", "payload": ["y": 2] as JSONObject])
        rig.fake.send(event: "client_prompt_ended", ["call_id": "call:none", "reason": "a_future_reason"])
        await quiet()
        XCTAssertEqual(rig.fake.requests.map(\.method), [])
        XCTAssertEqual(snapshot(rig.server), before)
        XCTAssertEqual(rig.server.phase, .online)
    }

    // MARK: Prompts

    private func prompt(_ id: String, kind: String = "input", action: String? = "dev_layout") -> JSONObject {
        var p: JSONObject = ["call_id": id, "timeout_ms": 120_000, "prompt": ["kind": kind, "title": "Branch name"] as JSONObject]
        if let action { p["action"] = action }
        return p
    }

    /// With nobody registered, every prompt is declined, at any revision: a server shouldn't
    /// send one below 17, but one that does must not be left waiting on this app.
    func testEveryPromptIsDeclinedAtEveryRevision() async throws {
        for revision in [nil, 13, 16, 17, 18] as [Int?] {
            let rig = try await Rig(revision: revision)
            await rig.connect()
            rig.fake.forget()
            rig.fake.send(event: "client_prompt_requested", prompt("call:1"))
            rig.fake.send(event: "client_prompt_requested", prompt("call:2", kind: "pick", action: nil))
            let declined = await eventually { rig.fake.count("client.reply") == 2 }
            XCTAssertTrue(declined, "revision \(String(describing: revision))")
            let replies = rig.fake.calls("client.reply")
            XCTAssertEqual(replies.map { $0.str("call_id") }, ["call:1", "call:2"])
            for r in replies {
                XCTAssertEqual(r.obj("error")?.str("code"), "not_supported")
                XCTAssertNil(r["result"])
            }
            XCTAssertEqual(Set(rig.fake.requests.map(\.method)), ["client.reply"], "and nothing else is read")
            rig.stop()
        }
    }

    /// The decline is on its way before the event's handler returns: this test never lets the
    /// main actor run another turn between the event and the check.
    func testAPromptIsDeclinedWithinTheTurnItArrivesIn() async throws {
        let rig = try await Rig(revision: 18)
        defer { rig.stop() }
        await rig.connect()
        rig.fake.forget()
        rig.server.handle(event: ["type": "client_prompt_requested", "payload": prompt("call:now")])
        // No await from here: only the socket's own queue can deliver it.
        holdTheMainActor(seconds: 3) { rig.fake.count("client.reply") > 0 }
        XCTAssertEqual(rig.fake.calls("client.reply").first?.str("call_id"), "call:now")
        XCTAssertEqual(rig.fake.calls("client.reply").first?.obj("error")?.str("code"), "not_supported")
    }

    func testARegisteredHandlerTakesAPromptAndTheRestAreDeclined() async throws {
        let rig = try await Rig(revision: 18)
        defer { rig.stop() }
        await rig.connect()
        rig.fake.forget()
        var seen: [PromptRequest] = []
        var ended: [String] = []
        rig.server.prompts.onPrompt = { p in
            seen.append(p)
            return p.action == "mine"
        }
        rig.server.prompts.onPromptEnded = { id, reason in ended.append("\(id) \(reason)") }

        rig.fake.send(event: "client_prompt_requested", prompt("call:mine", action: "mine"))
        rig.fake.send(event: "client_prompt_requested", prompt("call:other", action: "other"))
        rig.fake.send(event: "client_prompt_requested", prompt("call:future", kind: "color_wheel", action: "mine"))
        rig.fake.send(event: "client_prompt_requested", ["timeout_ms": 5])
        rig.fake.send(event: "client_prompt_ended", ["call_id": "call:mine", "reason": "answered"])
        let done = await eventually { rig.fake.count("client.reply") == 2 && ended.count == 1 }
        XCTAssertTrue(done)
        await quiet()
        XCTAssertEqual(rig.fake.calls("client.reply").map { $0.str("call_id") }, ["call:other", "call:future"],
                       "the taken prompt gets no decline; a kind this build can't show always does")
        XCTAssertEqual(seen.map(\.callID), ["call:mine", "call:other"], "the handler never sees an unknown kind")
        XCTAssertEqual(seen.first?.connectionSerial, rig.server.connectionSerial)
        XCTAssertEqual(seen.first?.timeoutMS, 120_000)
        XCTAssertEqual(ended, ["call:mine answered"])
    }

    // MARK: Close 1008

    func testAServerThatRefusesTheRevisionShowsWhichSideToUpdateAndStops() async throws {
        let cases: [(String, ConnectionProblem.Kind, String)] = [
            ("no common API revision: server speaks 0 to 5, client needs 13 to 18; update the server", .updateServer, "Update Rex on Desk"),
            ("no common API revision: server speaks 19 to 24, client needs 0 to 18; update the client", .updateApp, "Update \(Brand.appName)"),
            ("no common API revision: nothing in common", .notAllowed, "Desk didn't let this iPhone in"),
        ]
        for (reason, kind, title) in cases {
            let rig = try await Rig(revision: 18)
            rig.fake.refuse(code: 1008, reason: reason)
            rig.server.start()
            let shown = await eventually { rig.server.phase.problem != nil }
            XCTAssertTrue(shown)
            XCTAssertEqual(rig.server.phase.problem?.kind, kind, reason)
            XCTAssertEqual(OfflineCopy.of(kind, server: "Desk", address: "").title, title)
            XCTAssertTrue(rig.server.control.retryStopped)
            try? await Task.sleep(for: .milliseconds(2500))
            XCTAssertEqual(rig.fake.helloCount, 1, "no retry until the user asks: \(reason)")

            // A change of network doesn't start it again either.
            rig.server.networkChanged()
            try? await Task.sleep(for: .milliseconds(300))
            XCTAssertEqual(rig.fake.helloCount, 1)

            // Try Again, after Rex was updated: it connects.
            rig.fake.acceptAgain()
            rig.server.retryNow()
            let back = await eventually { rig.server.phase == .online }
            XCTAssertTrue(back, reason)
            XCTAssertEqual(rig.fake.helloCount, 2)
            rig.stop()
        }
    }

    func testEventBacklogExceededReconnectsAndReadsEverythingAgain() async throws {
        let rig = try await Rig(revision: 18)
        defer { rig.stop() }
        await rig.connect()
        XCTAssertEqual(rig.fake.count("session.bootstrap"), 1)

        rig.fake.close(code: 1008, reason: "event backlog exceeded")
        let back = await eventually(seconds: 8) { rig.server.connectionSerial == 2 && rig.fake.count("session.bootstrap") == 2 }
        XCTAssertTrue(back, "the phone fell behind: it connects again by itself, as for any drop")
        await rig.settle(keymapLoads: 2)
        XCTAssertEqual(rig.server.phase, .online)
        XCTAssertFalse(rig.server.control.retryStopped)
        XCTAssertEqual(rig.fake.helloCount, 2)
    }

    func testTheUpdateProblemsAreDecisiveAndWorded() {
        func failure(_ reason: String?) -> ConnectionFailure {
            ConnectionFailure(domain: NSPOSIXErrorDomain, code: 57, message: "closed", closeCode: 1008, closeReason: reason)
        }
        let net = NetworkSnapshot(reachable: true, onPrivateNetwork: true)
        XCTAssertEqual(ConnectionProblem.classify(failure("no common API revision: a; update the server"), network: net).kind, .updateServer)
        XCTAssertEqual(ConnectionProblem.classify(failure("no common API revision: a; update the client"), network: net).kind, .updateApp)
        // Today's reading of 1008 for everything else.
        XCTAssertEqual(ConnectionProblem.classify(failure("event backlog exceeded"), network: net).kind, .notAllowed)
        XCTAssertEqual(ConnectionProblem.classify(failure(nil), network: net).kind, .notAllowed)
        XCTAssertTrue(ConnectionProblem.Kind.updateServer.isDecisive && ConnectionProblem.Kind.updateApp.isDecisive)
        XCTAssertEqual(OfflineCopy.of(.updateServer, server: "Studio", address: "").title, "Update Rex on Studio")
        XCTAssertEqual(OfflineCopy.short(.updateServer), "Update Rex")
        XCTAssertEqual(OfflineCopy.short(.updateApp), "Update \(Brand.appName)")
        XCTAssertNil(OfflineAction.secondary(for: .updateServer))
    }

    // MARK: A sync's reads: all at once on Wi-Fi, four at a time on cellular

    private static let metaReads = ["program_status", "title", "process"]

    /// Reads of status, title and process the fake has seen.
    private func metaCount(_ rig: Rig) -> Int {
        Self.metaReads.reduce(0) { $0 + rig.fake.count("\(Self.terminal).\($1)") }
    }

    /// Eight sessions of two panes, connected on Wi-Fi, with every read slow enough to overlap.
    private func eightSessions() async throws -> Rig {
        let rig = try await Rig(revision: 18)
        rig.setSessions((1...8).map { "session:\($0)" })
        rig.server.shownSession = { "session:6" }
        for m in Self.metaReads { rig.fake.delay("\(Self.terminal).\(m)", seconds: 0.03) }
        rig.fake.delay("session.attach", seconds: 0.03)
        await rig.connect()
        // The sync of the connect is over, however long it took: a sync asked for while one
        // is under way only marks that one to run again, and reads nothing itself.
        _ = await eventually(seconds: 60) { !rig.server.syncing }
        return rig
    }

    /// The phone moves to cellular, as `NetworkWatch` tells the connection.
    private func cellular(_ rig: Rig, _ on: Bool = true) {
        rig.server.control.pathChanged(satisfied: true, expensive: on, interfaceChanged: false)
    }

    /// On Wi-Fi a sync is as it always was: 8 attaches in one turn, then 48 reads in one turn,
    /// and nothing goes through the gate.
    func testOnWiFiASyncGoesThroughNoGate() async throws {
        let rig = try await eightSessions()
        defer { rig.stop() }
        XCTAssertFalse(rig.server.gatesSync)
        XCTAssertEqual(rig.server.syncCalls.total, 0, "no read waited a turn")
        XCTAssertEqual(rig.server.syncCalls.peak, 0)
        XCTAssertEqual(rig.fake.count("session.attach"), 8)
        XCTAssertEqual(metaCount(rig), 48)
        XCTAssertEqual(rig.server.views.count, 8)
    }

    /// On cellular at most four are under way, the session on screen first, and every read is
    /// still made.
    func testOnCellularASyncKeepsAtMostFourReadsUnderWayAndReadsTheSessionOnScreenFirst() async throws {
        let rig = try await eightSessions()
        defer { rig.stop() }
        cellular(rig)
        XCTAssertTrue(rig.server.gatesSync)
        rig.fake.forget()
        await rig.server.bootstrap()
        XCTAssertEqual(rig.server.syncCalls.limit, 4)
        XCTAssertEqual(rig.server.syncCalls.peak, 4, "four at a time, never more")
        XCTAssertEqual(rig.server.syncCalls.total, 8 + 48)
        XCTAssertEqual(rig.server.syncCalls.inFlight, 0)
        XCTAssertEqual(rig.fake.count("session.attach"), 8)
        XCTAssertEqual(metaCount(rig), 48)
        XCTAssertEqual(rig.fake.calls("session.attach").first?.str("session_id"), "session:6")
        let firstRead = rig.fake.requests.first { $0.method.hasPrefix(Self.terminal) }
        XCTAssertEqual(firstRead?.payload.str("session_id"), "session:6", "its panes' reads come first too")
        XCTAssertEqual(rig.server.views.count, 8)
    }

    /// The path changes while reads wait their turn: the batch goes on as it began, and none
    /// is left waiting.
    func testAChangeOfPathInTheMiddleOfASyncStrandsNoRead() async throws {
        let rig = try await eightSessions()
        defer { rig.stop() }
        cellular(rig)
        rig.fake.forget()
        let server = rig.server
        let sync = Task { @MainActor in await server.bootstrap() }
        _ = await eventually { self.metaCount(rig) >= 6 }
        XCTAssertLessThan(metaCount(rig), 48, "reads still wait")
        cellular(rig, false)
        await sync.value
        XCTAssertEqual(metaCount(rig), 48, "every one was made")
        XCTAssertEqual(rig.server.syncCalls.inFlight, 0)
        XCTAssertEqual(rig.server.syncCalls.peak, 4)
        // And back on cellular in the middle of a Wi-Fi sync: that one is not gated either way.
        rig.fake.forget()
        let wifi = Task { @MainActor in await server.bootstrap() }
        _ = await eventually { rig.fake.count("session.attach") >= 1 }
        cellular(rig)
        await wifi.value
        XCTAssertEqual(rig.fake.count("session.attach"), 8)
        XCTAssertEqual(rig.server.syncCalls.inFlight, 0)
    }

    /// The connection drops while reads wait their turn: they are not sent on the next
    /// connection, whose own sync reads everything again.
    func testReadsThatWaitedOnALostConnectionAreNotSentOnTheNextOne() async throws {
        let rig = try await eightSessions()
        defer { rig.stop() }
        cellular(rig)
        rig.fake.forget()
        let server = rig.server
        let sync = Task { @MainActor in await server.bootstrap() }
        _ = await eventually { self.metaCount(rig) >= 4 }
        let before = metaCount(rig)
        XCTAssertLessThan(before, 24, "most reads still wait")
        rig.fake.dropAll()
        await sync.value
        _ = await eventually(seconds: 8) { server.connectionSerial == 2 && server.control.state == .connected }
        // Until every sync that followed is done.
        var last = -1
        _ = await eventually(seconds: 10) {
            let now = self.metaCount(rig) + rig.fake.count("client.keymap")
            defer { last = now }
            return now == last && server.syncCalls.inFlight == 0 && server.synced
        }
        try? await Task.sleep(for: .milliseconds(300))
        // Each sync on the new connection makes 8 attaches and 48 reads of its own.
        let syncs = (rig.fake.count("session.attach") - 8) / 8
        XCTAssertGreaterThanOrEqual(syncs, 1)
        XCTAssertLessThanOrEqual(metaCount(rig), before + 4 + 48 * syncs,
                                 "the lost sync's waiting reads were dropped, not sent")
    }

    func testTheSessionOnScreenComesFirstAndTheRestKeepTheirOrder() {
        let items = [("a", 1), ("b", 2), ("c", 3), ("b", 4)]
        XCTAssertEqual(ServerConnection.shownFirst(items, shown: "b") { $0.0 }.map(\.1), [2, 4, 1, 3])
        XCTAssertEqual(ServerConnection.shownFirst(items, shown: nil) { $0.0 }.map(\.1), [1, 2, 3, 4])
        XCTAssertEqual(ServerConnection.shownFirst(items, shown: "gone") { $0.0 }.map(\.1), [1, 2, 3, 4])
    }
}

/// `ServerCapabilities` by itself: what a reconnect keeps and drops, and the probe slots.
@MainActor
final class ServerCapabilitiesTests: XCTestCase {
    private let terminal = "com.superlogical.terminal"
    private var list: JSONObject { ServerEventsTests.creators() }

    func testStartsUnknown() {
        let c = ServerCapabilities()
        XCTAssertEqual(c.revision, 0)
        XCTAssertFalse(c.supports(1))
        XCTAssertTrue(c.supports(0))
        XCTAssertEqual(c.creators, .unknown)
        XCTAssertEqual(c.method("write", creator: terminal, host: nil), .unknown)
        XCTAssertFalse(c.hasFlavor("\(terminal).shell", host: nil), "unknown shows nothing new")
        XCTAssertNil(c.probe(method: "list_dir", host: nil))
    }

    func testAReconnectAtTheSameRevisionKeepsTheListAndDropsTheProbes() {
        let c = ServerCapabilities()
        c.connected(serial: 1, revision: 18, serverRevision: 18, features: [])
        c.status(instance: "i1", hostID: "host-a")
        c.creatorsLoaded(list, serial: 1)
        c.record(method: "list_dir", host: "host-a", .present, serial: 1)
        XCTAssertEqual(c.probe(method: "list_dir", host: "host-a"), true)

        c.connected(serial: 2, revision: 18, serverRevision: 18, features: [])
        XCTAssertEqual(c.method("list_dir", creator: terminal, host: "host-a"), .present, "the list stays, so nothing blinks on a wake")
        XCTAssertNil(c.probe(method: "list_dir", host: "host-a"))
        c.status(instance: "i1", hostID: "host-a")
        XCTAssertNotEqual(c.creators, .unknown)

        // The list read on the old connection arrives late: ignored.
        c.creatorsLoaded(["creators": [JSONObject]()], serial: 1)
        XCTAssertEqual(c.method("list_dir", creator: terminal, host: "host-a"), .present)
        c.record(method: "list_dir", host: "host-a", .absent, serial: 1)
        XCTAssertNil(c.probe(method: "list_dir", host: "host-a"), "so is a probe's late answer")
    }

    func testAnotherRevisionOrAnotherServerProcessDropsTheList() {
        let c = ServerCapabilities()
        c.connected(serial: 1, revision: 18, serverRevision: 18, features: [])
        c.status(instance: "i1", hostID: "host-a")
        c.creatorsLoaded(list, serial: 1)

        c.connected(serial: 2, revision: 13, serverRevision: 13, features: [])
        XCTAssertEqual(c.creators, .unknown, "another revision: the old list says nothing")

        c.creatorsLoaded(list, serial: 2)
        c.connected(serial: 3, revision: 13, serverRevision: 13, features: [])
        XCTAssertNotEqual(c.creators, .unknown)
        c.status(instance: "i2", hostID: "host-a")
        XCTAssertEqual(c.creators, .unknown, "the server restarted, perhaps as another version")
    }

    func testAFailedReadNeverTakesAwayAKnownList() {
        let c = ServerCapabilities()
        c.connected(serial: 1, revision: 18, serverRevision: 18, features: [])
        c.status(instance: "i1", hostID: "host-a")
        c.creatorsLoaded(list, serial: 1)
        XCTAssertFalse(c.needsCreatorRead)

        c.creatorsLoaded(nil, serial: 1)
        XCTAssertEqual(c.method("list_dir", creator: terminal, host: "host-a"), .present, "known stays known")
        XCTAssertNotEqual(c.creators, .failed)
        XCTAssertTrue(c.needsCreatorRead, "and the next sync asks again")

        c.creatorsLoaded(list, serial: 1)
        XCTAssertFalse(c.needsCreatorRead)
        c.creatorReadLost()
        XCTAssertEqual(c.method("list_dir", creator: terminal, host: "host-a"), .present)
        XCTAssertTrue(c.needsCreatorRead)
    }

    func testTheListIsReadOncePerServerProcessAndRevision() {
        let c = ServerCapabilities()
        XCTAssertTrue(c.needsCreatorRead)
        c.connected(serial: 1, revision: 18, serverRevision: 18, features: [])
        c.status(instance: "i1", hostID: "host-a")
        XCTAssertTrue(c.needsCreatorRead)
        c.creatorsLoaded(list, serial: 1)
        XCTAssertFalse(c.needsCreatorRead)

        // A resync, then a reconnect to the same process at the same revision.
        c.status(instance: "i1", hostID: "host-a")
        XCTAssertFalse(c.needsCreatorRead)
        c.connected(serial: 2, revision: 18, serverRevision: 18, features: [])
        c.status(instance: "i1", hostID: "host-a")
        XCTAssertFalse(c.needsCreatorRead)

        // Another revision, then another process.
        c.connected(serial: 3, revision: 13, serverRevision: 13, features: [])
        c.status(instance: "i1", hostID: "host-a")
        XCTAssertTrue(c.needsCreatorRead)
        c.creatorsLoaded(list, serial: 3)
        XCTAssertFalse(c.needsCreatorRead)
        c.connected(serial: 4, revision: 13, serverRevision: 13, features: [])
        c.status(instance: "i2", hostID: "host-a")
        XCTAssertTrue(c.needsCreatorRead)

        // A server too old for the list: its error is the answer, and is not asked for again.
        c.creatorsLoaded(nil, serial: 4)
        XCTAssertEqual(c.creators, .failed)
        XCTAssertFalse(c.needsCreatorRead)
        c.status(instance: "i2", hostID: "host-a")
        XCTAssertFalse(c.needsCreatorRead)
    }

    /// A server that names no process may be another one after any reconnect.
    func testAServerWithoutAnInstanceIsReadOncePerConnection() {
        let c = ServerCapabilities()
        c.connected(serial: 1, revision: 0, serverRevision: 0, features: [])
        c.status(instance: nil, hostID: nil)
        c.creatorsLoaded(list, serial: 1)
        XCTAssertFalse(c.needsCreatorRead)
        c.status(instance: nil, hostID: nil)
        XCTAssertFalse(c.needsCreatorRead, "a resync on the same connection reads nothing")
        c.connected(serial: 2, revision: 0, serverRevision: 0, features: [])
        c.status(instance: nil, hostID: nil)
        XCTAssertTrue(c.needsCreatorRead)
        XCTAssertNotEqual(c.creators, .unknown, "the last list shows until the new one is in")
    }

    func testAFailedReadIsFailedNotAbsent() {
        let c = ServerCapabilities()
        c.connected(serial: 1, revision: 0, serverRevision: 0, features: [])
        c.creatorsLoaded(nil, serial: 1)
        XCTAssertEqual(c.creators, .failed)
        XCTAssertEqual(c.method("upload_begin", creator: terminal, host: nil), .unknown, "the feature probes as it does today")
        XCTAssertEqual(c.event("progress_report", creator: terminal, host: nil), .unknown)
        c.connected(serial: 2, revision: 0, serverRevision: 0, features: [])
        XCTAssertEqual(c.creators, .unknown)
    }

    func testProbeAnswersAndTheRetryRule() {
        let c = ServerCapabilities()
        c.connected(serial: 1, revision: 18, serverRevision: 18, features: [])
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertTrue(c.shouldProbe(method: "list_dir", host: "h", now: t0))

        // No answer either way: ask once more, but not for a minute.
        let timeout = RexError(code: "timeout", message: "", status: 504)
        c.record(method: "list_dir", host: "h", error: timeout, targetExists: true, serial: 1, now: t0)
        XCTAssertNil(c.probe(method: "list_dir", host: "h"))
        XCTAssertFalse(c.shouldProbe(method: "list_dir", host: "h", now: t0.addingTimeInterval(59)))
        XCTAssertTrue(c.shouldProbe(method: "list_dir", host: "h", now: t0.addingTimeInterval(60)))
        XCTAssertTrue(c.shouldProbe(method: "list_dir", host: "other", now: t0), "each host has its own slot")

        // The second try has no answer either: that was the last one on this connection.
        let t1 = t0.addingTimeInterval(61)
        c.record(method: "list_dir", host: "h", error: timeout, targetExists: true, serial: 1, now: t1)
        XCTAssertFalse(c.shouldProbe(method: "list_dir", host: "h", now: t1.addingTimeInterval(60)))
        XCTAssertFalse(c.shouldProbe(method: "list_dir", host: "h", now: t1.addingTimeInterval(86_400)), "never a third time")
        XCTAssertTrue(c.shouldProbe(method: "list_dir", host: "other", now: t1), "another host is not held back by it")

        // A new connection starts over.
        c.connected(serial: 2, revision: 18, serverRevision: 18, features: [])
        XCTAssertTrue(c.shouldProbe(method: "list_dir", host: "h", now: t1))
        c.connected(serial: 1, revision: 18, serverRevision: 18, features: [])

        c.record(method: "list_dir", host: "h", error: RexError(code: "method_not_found", message: "", status: 404), targetExists: false, serial: 1)
        XCTAssertEqual(c.probe(method: "list_dir", host: "h"), false)
        XCTAssertFalse(c.shouldProbe(method: "list_dir", host: "h", now: t0.addingTimeInterval(600)))

        // A server from before `method_not_found` says `not_found`: absent only when the target exists.
        c.record(method: "a", host: nil, error: RexError(code: "not_found", message: "", status: 404), targetExists: true, serial: 1)
        XCTAssertEqual(c.probe(method: "a", host: nil), false)
        c.record(method: "b", host: nil, error: RexError(code: "not_found", message: "", status: 404), targetExists: false, serial: 1)
        XCTAssertNil(c.probe(method: "b", host: nil))
        c.record(method: "c", host: nil, error: RexError(code: "revision_too_low", message: "", status: 400), targetExists: false, serial: 1)
        XCTAssertEqual(c.probe(method: "c", host: nil), false)
        c.record(method: "d", host: nil, error: nil, targetExists: true, serial: 1)
        XCTAssertEqual(c.probe(method: "d", host: nil), true)
        c.record(method: "e", host: nil, error: URLError(.timedOut), targetExists: true, serial: 1)
        XCTAssertNil(c.probe(method: "e", host: nil))
    }

    func testEntryPointsThatReadItHearAChange() {
        let c = ServerCapabilities()
        c.connected(serial: 1, revision: 18, serverRevision: 18, features: [])
        let fired = expectation(description: "observed")
        withObservationTracking { _ = c.supports(15) } onChange: { fired.fulfill() }
        c.connected(serial: 2, revision: 13, serverRevision: 13, features: [])
        wait(for: [fired], timeout: 1)

        // The same answer again writes nothing, so nothing redraws.
        let quiet = expectation(description: "not observed")
        quiet.isInverted = true
        withObservationTracking { _ = c.supports(15); _ = c.creators; _ = c.features } onChange: { quiet.fulfill() }
        c.connected(serial: 3, revision: 13, serverRevision: 13, features: [])
        c.status(instance: nil, hostID: nil)
        wait(for: [quiet], timeout: 0.2)
    }
}

/// Waits without giving up the main actor, so nothing queued on it can run meanwhile.
@MainActor
private func holdTheMainActor(seconds: Double, until done: () -> Bool) {
    let end = Date().addingTimeInterval(seconds)
    while !done(), Date() < end { usleep(5000) }
}

@MainActor
private func eventually(seconds: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    return condition()
}
