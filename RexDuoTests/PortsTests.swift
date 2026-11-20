import Foundation
import GlanceModel
import XCTest
import RexKit
@testable import RexDuo

/// Ports against a Rex server in this process (`FakeRexServer`): the gates at every revision,
/// which panes' ports are read and kept, the link router, and the metadata of new blocks.
@MainActor
final class PortsTests: XCTestCase {
    typealias Rig = ServerEventsTests.Rig
    nonisolated static let terminal = "com.superlogical.terminal"
    nonisolated static let ports = "com.superlogical.terminal.ports"

    /// The creator list: a terminal with `ports`, and a tunnel creator with the dial flavor.
    nonisolated static func creators(dial: Bool = true, host: String = "host-a") -> JSONObject {
        var list: [JSONObject] = [[
            "name": terminal, "host_id": host, "flavors": [["flavor": "\(terminal).shell"]],
            "api": ["events": ["ports_changed": [:]], "methods": ["write": [:], "ports": [:]]],
        ]]
        if dial {
            list.append(["name": "com.superlogical.tunnel", "host_id": host,
                         "flavors": [["flavor": "com.superlogical.tunnel.dial"], ["flavor": "com.superlogical.tunnel.listen"]]])
        }
        return ["creators": list]
    }

    nonisolated static func reply(_ ports: [Int], pid: Int = 7) -> JSONObject {
        ["status": "ok",
         "ports": ports.map { ["port": $0, "address": "127.0.0.1", "protocol": "tcp", "first_seen_at": "2026-11-20T00:00:00Z", "pid": pid] as JSONObject },
         "processes": [["pid": pid, "user_id": 501, "name": "node", "argv0": "node"] as JSONObject]]
    }

    private func rig(_ revision: Int?, dial: Bool = true) async throws -> Rig {
        let r = try await Rig(revision: revision, creators: .result(Self.creators(dial: dial)))
        r.fake.reply(Self.ports, Self.reply([5173]))
        return r
    }

    private func sendPorts(_ rig: Rig, block: String, _ ports: [Int], session: String = "session:1") {
        rig.fake.send(session: session, event: "block_event",
                      ["block_id": block, "creator_name": Self.terminal, "name": "ports_changed", "payload": Self.reply(ports)])
    }

    private func quiet(_ ms: Int = 500) async { try? await Task.sleep(for: .milliseconds(ms)) }

    // MARK: Gates

    func testTheGatesAtEveryRevision() async throws {
        let cases: [(String, Int?, Bool, ports: Bool, tunnels: Bool)] = [
            ("0", nil, true, false, false), ("13", 13, true, false, false), ("14", 14, true, false, true),
            ("16 with dial", 16, true, true, true), ("16 without dial", 16, false, true, false), ("18", 18, true, true, true),
        ]
        for (name, rev, dial, ports, tunnels) in cases {
            let r = try await rig(rev, dial: dial)
            await r.connect()
            XCTAssertEqual(r.server.portsAvailable, ports, name)
            XCTAssertEqual(r.server.tunnelsAvailable, tunnels, name)
            XCTAssertEqual(r.server.showsPorts(session: "session:1", block: "block:1a"), ports && tunnels, name)
            r.stop()
        }
    }

    func testOlderServersReadNoPortsAndDropTheEvent() async throws {
        for rev in [nil, 13, 14] as [Int?] {
            let r = try await rig(rev)
            await r.connect()
            r.server.watchPorts(session: "session:1", block: "block:1a")
            sendPorts(r, block: "block:1a", [3000])
            await quiet()
            XCTAssertEqual(r.fake.count(Self.ports), 0, "\(String(describing: rev))")
            XCTAssertNil(r.server.ports.value("block:1a"))
            XCTAssertTrue(r.server.ports.isEmpty)
            r.stop()
        }
    }

    func testAMissingMethodHidesPortsWithNoError() async throws {
        let r = try await rig(18)
        r.fake.reply(Self.ports, .error(code: "method_not_found", status: 404))
        await r.connect()
        r.server.watchPorts(session: "session:1", block: "block:1a")
        _ = await eventually { r.fake.count(Self.ports) == 1 }
        await quiet(200)
        XCTAssertFalse(r.server.portsAvailable)
        XCTAssertNil(r.server.ports.value("block:1a"))
        // An older server says `not_found` for a missing method: the same.
        let old = try await rig(16)
        old.fake.reply(Self.ports, .error(code: "not_found", status: 404))
        await old.connect()
        old.server.watchPorts(session: "session:1", block: "block:1a")
        _ = await eventually { !old.server.portsAvailable }
        XCTAssertFalse(old.server.portsAvailable)
        r.stop()
        old.stop()
    }

    func testMixedServersEachDecideAlone() async throws {
        let new = try await rig(18), old = try await rig(13)
        await new.connect()
        await old.connect()
        XCTAssertTrue(new.server.showsPorts(session: "session:1", block: "block:1a"))
        XCTAssertFalse(old.server.showsPorts(session: "session:1", block: "block:1a"))
        new.stop()
        old.stop()
    }

    func testLocalPanes() async throws {
        let r = try await rig(18)
        await r.connect()
        func b(_ host: String?) -> BlockInfo {
            var o: JSONObject = ["block_id": "b", "creator_name": Self.terminal]
            if let host { o["host_id"] = host }
            return BlockInfo(o)
        }
        XCTAssertTrue(r.server.isLocal(b("host-a")))
        XCTAssertTrue(r.server.isLocal(b(nil)), "a block that names no host is the server's")
        XCTAssertFalse(r.server.isLocal(b("host-b")), "a remote host")
        // A server without a state directory names no host: only blocks that name none are local.
        r.server.capabilities.status(instance: "instance-1", hostID: nil)
        XCTAssertTrue(r.server.isLocal(b(nil)))
        XCTAssertFalse(r.server.isLocal(b("host-a")))
        r.stop()
    }

    // MARK: Reading and following

    func testAPaneOnScreenReadsItsPortsOncePerConnection() async throws {
        let r = try await rig(18)
        await r.connect()
        XCTAssertEqual(r.fake.count(Self.ports), 0, "nothing until a pane is on screen")
        r.server.watchPorts(session: "session:1", block: "block:1a")
        let read = await eventually { r.server.ports.value("block:1a")?.webPorts.map(\.port) == [5173] }
        XCTAssertTrue(read)
        r.server.unwatchPorts("block:1a")
        XCTAssertNil(r.server.ports.value("block:1a"), "off screen: not kept")
        r.server.watchPorts(session: "session:1", block: "block:1a")
        _ = await eventually { r.fake.count(Self.ports) == 2 }
        // A resync reads nothing more on the same connection.
        r.fake.forget()
        await r.server.bootstrap()
        await quiet(300)
        XCTAssertEqual(r.fake.count(Self.ports), 0)
        XCTAssertNotNil(r.server.ports.value("block:1a"), "kept across a resync")
        r.stop()
    }

    func testOnlyPanesOnScreenDecodeTheirEvents() async throws {
        let r = try await rig(18)
        await r.connect()
        r.server.watchPorts(session: "session:1", block: "block:1a")
        _ = await eventually { r.server.ports.value("block:1a") != nil }
        sendPorts(r, block: "block:1a", [3000, 5173])
        sendPorts(r, block: "block:1b", [8080])
        let got = await eventually { r.server.ports.value("block:1a")?.entries.map(\.port) == [3000, 5173] }
        XCTAssertTrue(got)
        XCTAssertNil(r.server.ports.value("block:1b"), "an off-screen pane's event is dropped")
        XCTAssertNil(r.server.pendingPorts["block:1b"])
        XCTAssertFalse(r.server.ports.ids.contains("block:1b"), "and stores nothing")
        r.stop()
    }

    func testABurstOfEventsWritesOnceAndEqualListsWriteNothing() async throws {
        let r = try await rig(18)
        await r.connect()
        r.server.watchPorts(session: "session:1", block: "block:1a")
        _ = await eventually { r.server.ports.value("block:1a") != nil }
        let box = try XCTUnwrap(r.server.ports["block:1a"])
        let writes = WriteCount()
        writes.observe(box)
        for p in [3000, 3001, 3002] { sendPorts(r, block: "block:1a", [p]) }
        _ = await eventually { r.server.ports.value("block:1a")?.entries.map(\.port) == [3002] }
        await quiet(300)
        XCTAssertEqual(writes.n, 1, "coalesced in the flush")
        sendPorts(r, block: "block:1a", [3002])
        await quiet(300)
        XCTAssertEqual(writes.n, 1, "a rescan with the same ports writes nothing")
        r.stop()
    }

    func testADroppedPortsEventReadsTheListAgainForAPaneOnScreenOnly() async throws {
        let r = try await rig(18)
        await r.connect()
        r.server.watchPorts(session: "session:1", block: "block:1a")
        _ = await eventually { r.server.ports.value("block:1a") != nil }
        r.fake.forget()
        r.fake.reply(Self.ports, Self.reply([4000]))
        for b in ["block:1a", "block:1b"] {
            r.fake.send(event: "event_dropped", ["event_type": "block_event", "size": 2_000_000, "session_id": "session:1",
                                                 "block_id": b, "creator_name": Self.terminal, "block_event_name": "ports_changed"])
        }
        let read = await eventually { r.server.ports.value("block:1a")?.entries.map(\.port) == [4000] }
        XCTAssertTrue(read)
        await quiet()
        XCTAssertEqual(r.fake.calls(Self.ports).map { $0.str("block_id") }, ["block:1a"])
        XCTAssertEqual(r.fake.count("session.bootstrap"), 0, "never a full sync")
        r.stop()
    }

    func testANewConnectionDropsTheListsAndReadsThemAgain() async throws {
        let r = try await rig(18)
        await r.connect()
        r.server.watchPorts(session: "session:1", block: "block:1a")
        _ = await eventually { r.server.ports.value("block:1a") != nil }
        r.fake.dropAll()
        let back = await eventually(seconds: 8) { r.fake.count(Self.ports) == 2 && r.server.ports.value("block:1a") != nil }
        XCTAssertTrue(back, "read again once the server is back")
        r.stop()
    }

    func testAClosedPaneLosesItsList() async throws {
        let r = try await rig(18)
        await r.connect()
        r.server.watchPorts(session: "session:1", block: "block:1a")
        _ = await eventually { r.server.ports.value("block:1a") != nil }
        r.fake.send(session: "session:1", event: "block_closed", ["block_id": "block:1a"])
        _ = await eventually { r.server.ports.value("block:1a") == nil }
        XCTAssertNil(r.server.ports.value("block:1a"))
        r.stop()
    }

    // MARK: Links

    func testTheLinkRouter() async throws {
        let r = try await rig(18)
        await r.connect()
        r.server.watchPorts(session: "session:1", block: "block:1a")
        _ = await eventually { r.server.ports.value("block:1a") != nil }
        let p = PanePorts(server: r.server, sessionID: "session:1", blockID: "block:1a")
        func route(_ s: String, asked: Bool = false) -> PanePorts.Route { p.route(URL(string: s)!, asked: asked) }
        guard case .open(let listed) = route("http://localhost:5173/app?x=1") else { return XCTFail("a listed port opens at once") }
        XCTAssertEqual(listed.dialHost, "127.0.0.1", "where the program listens")
        XCTAssertEqual(listed.url(localPort: 5173)?.absoluteString, "http://localhost:5173/app?x=1")
        guard case .ask(let unlisted) = route("http://127.0.0.1:3000/") else { return XCTFail("an unlisted port asks") }
        XCTAssertEqual(unlisted.name, "localhost:3000")
        guard case .open = route("http://127.0.0.1:3000/", asked: true) else { return XCTFail("asked once is enough") }
        XCTAssertEqual(route("http://localhost:9229/json"), .refuse)
        XCTAssertEqual(route("http://[::1]:9222/"), .refuse)
        XCTAssertEqual(route("https://example.com/"), .elsewhere)
        XCTAssertEqual(route("http://192.168.1.2:5173/"), .elsewhere, "no LAN hosts")
        XCTAssertEqual(route("ftp://localhost:21/"), .elsewhere)

        // A remote pane, and a server without tunnels: links go where they always went.
        let remote = PanePorts(server: r.server, sessionID: "session:1", blockID: "block:nowhere")
        XCTAssertEqual(remote.route(URL(string: "http://localhost:5173/")!, asked: false), .elsewhere)
        r.stop()

        let old = try await rig(13)
        await old.connect()
        let q = PanePorts(server: old.server, sessionID: "session:1", blockID: "block:1a")
        XCTAssertEqual(q.route(URL(string: "http://localhost:5173/")!, asked: false), .elsewhere, "rev 13: Safari, as before")
        old.stop()

        let tunnelsOnly = try await rig(14)
        await tunnelsOnly.connect()
        let t = PanePorts(server: tunnelsOnly.server, sessionID: "session:1", blockID: "block:1a")
        guard case .ask = t.route(URL(string: "http://localhost:5173/")!, asked: false) else {
            return XCTFail("rev 14: through Rex, always asked, as no port list exists")
        }
        tunnelsOnly.stop()
    }

    func testOfflineALoopbackLinkNeverGoesToSafari() async throws {
        let r = try await rig(18)
        await r.connect()
        r.fake.close(code: 1001, reason: "bye")
        _ = await eventually { r.server.control.state != .connected }
        let p = PanePorts(server: r.server, sessionID: "session:1", blockID: "block:1a")
        var elsewhere = 0
        p.openElsewhere = { _ in elsewhere += 1 }
        XCTAssertEqual(p.route(URL(string: "http://localhost:5173/")!, asked: false), .offline)
        p.open(URL(string: "http://localhost:5173/")!, asked: false)
        XCTAssertEqual(elsewhere, 0)
        r.stop()
    }

    func testAQuestionIsAskedOnceAndCancelOpensNothing() async throws {
        let r = try await rig(18)
        await r.connect()
        let forward = PortForward(tag: { "a1b2c3d4" }, ledger: TunnelLedger(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                  makeListener: { StubListener() })
        r.server.forward = forward
        let p = PanePorts(server: r.server, sessionID: "session:1", blockID: "block:1a")
        var questions: [String] = []
        var presented: [URL] = []
        p.present = { presented.append($0) }
        p.ask = { q, answer in questions.append(q); answer(false) }
        p.open(URL(string: "http://localhost:3000/")!, asked: false)
        XCTAssertEqual(questions, ["Open localhost:3000 from Desk?"])
        await quiet(100)
        XCTAssertTrue(presented.isEmpty)
        XCTAssertNil(forward.forward)
        // A link the policy already asked about opens without a second question.
        p.open(URL(string: "http://localhost:3000/")!, asked: true)
        _ = await eventually { !presented.isEmpty }
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(presented.first?.absoluteString, "http://localhost:3000/")
        forward.close()
        r.stop()
    }

    // MARK: New blocks' metadata

    func testASlowViewStillLoadsANewPanesMetadataOnceWhenItLands() async throws {
        let r = try await rig(18)
        await r.connect()
        r.fake.forget()
        r.fake.delay("session.view", seconds: 0.6)
        r.fake.send(session: "session:1", event: "block_created", ["block_id": "block:1c"])
        r.setViewExtra("block:1c")
        await quiet(450)
        XCTAssertEqual(r.fake.count("\(Self.terminal).title"), 0, "not before the view has it")
        _ = await eventually { r.fake.count("\(Self.terminal).title") == 1 }
        await quiet(400)
        XCTAssertEqual(r.fake.calls("\(Self.terminal).title").map { $0.str("block_id") }, ["block:1c"], "once")
        r.stop()
    }

    func testAFastViewKeepsThe300msDelay() async throws {
        let r = try await rig(18)
        await r.connect()
        r.fake.forget()
        r.setViewExtra("block:1c")
        let start = Date()
        r.fake.send(session: "session:1", event: "block_created", ["block_id": "block:1c"])
        _ = await eventually { r.fake.count("\(Self.terminal).title") == 1 }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.28)
        r.stop()
    }

    func testADetachedBlockGetsNoTerminalCalls() async throws {
        let r = try await rig(18)
        await r.connect()
        r.fake.forget()
        r.fake.send(session: "session:1", event: "block_created", ["block_id": "block:tunnel"])
        await quiet(800)
        XCTAssertEqual(r.fake.count("session.view"), 1, "someone else's tunnel: one view read, as for any new block")
        for m in ["title", "process", "program_status"] { XCTAssertEqual(r.fake.count("\(Self.terminal).\(m)"), 0, m) }
        r.stop()
    }

    func testThisAppsTunnelEventsReadNoView() async throws {
        let r = try await rig(18)
        await r.connect()
        let server = FakeTunnelServer()
        let forward = PortForward(tag: { "a1b2c3d4" }, ledger: TunnelLedger(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                                  makeListener: { StubListener() })
        server.blocks = [["block_id": "block:mine", "flavor": PortForward.flavor, "label": tunnelLabelInTests]]
        TunnelLedgerProbe.remember(forward, server, "session:1", "block:mine")
        r.server.forward = forward
        await quiet(300)
        XCTAssertTrue(forward.owns("block:mine"))
        r.fake.forget()
        for type in ["block_owner_changed", "block_closed"] {
            r.fake.send(session: "session:1", event: type, ["block_id": "block:mine"])
        }
        await quiet()
        XCTAssertEqual(r.fake.count("session.view"), 0)
        r.stop()
    }
}

/// Puts a block in a forward's list of its own tunnels, the way a sweep does.
@MainActor
enum TunnelLedgerProbe {
    static func remember(_ forward: PortForward, _ server: FakeTunnelServer, _ session: String, _ block: String) {
        // A sync with a remembered block sweeps it: from then on the forward owns its events.
        forward.ledger.remember(server: server.id, session: session, block: block)
        forward.serverSynced(server)
    }
}

@MainActor
private func eventually(seconds: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    return condition()
}

/// Counts the writes to a box that its readers hear.
@MainActor
final class WriteCount {
    var n = 0

    func observe(_ box: BlockBox<PortList>) {
        withObservationTracking { _ = box.value } onChange: { [weak self] in
            Task { @MainActor in
                self?.n += 1
                self?.observe(box)
            }
        }
    }
}
