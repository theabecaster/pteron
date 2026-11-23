import Foundation
import XCTest
import RexKit
@testable import Pteron

/// Probes answered by the test, one continuation per port.
@MainActor
final class ProbeScript {
    private(set) var asked: [Int] = []
    private var waiting: [Int: CheckedContinuation<PortProbe.Verdict, Never>] = [:]

    func probe(_ t: PortForward.Target) async -> PortProbe.Verdict {
        asked.append(t.port)
        return await withCheckedContinuation { waiting[t.port] = $0 }
    }

    func answer(_ port: Int, _ v: PortProbe.Verdict) {
        waiting.removeValue(forKey: port)?.resume(returning: v)
    }

    var running: [Int] { waiting.keys.sorted() }
}

/// A clock the test moves by hand.
@MainActor
final class ProbeClock {
    var now = 100.0
}

/// Which ports show once each is asked what it answers: the Ports list (the sidebar's popover and
/// tab mode's sheet both read `portRows`), its count and the pane menu's row agree, a new port
/// waits for its answer at most the hold, and the probes stay two at a time (docs/terminal.md,
/// Ports, "Which ports show").
@MainActor
final class PortProbeRowsTests: XCTestCase {
    typealias Rig = ServerEventsTests.Rig

    private func rig(_ script: ProbeScript, _ clock: ProbeClock) async throws -> Rig {
        let r = try await Rig(revision: 18, creators: .result(PortsTests.creators()))
        r.fake.reply(PortsTests.ports, PortsTests.reply([5173]))
        r.server.probePort = { await script.probe($0) }
        r.server.probeClock = { clock.now }
        r.server.probeOnly = { nil }
        return r
    }

    private func sendPorts(_ r: Rig, block: String, _ ports: [Int], pid: Int = 7) {
        r.fake.send(session: "session:1", event: "block_event",
                    ["block_id": block, "creator_name": PortsTests.terminal, "name": "ports_changed", "payload": PortsTests.reply(ports, pid: pid)])
    }

    /// The list, its count and the pane menu say the same thing.
    private func shown(_ r: Rig, _ block: String = "block:1a") -> (rows: [String], count: Int, menu: [Int]) {
        (r.server.portRows.map(\.id), r.server.hasPortRows ? r.server.portRowIDs.count : 0, r.server.shownPorts(block).map(\.port))
    }

    func testAWebSocketServerShowsNowhereAndAWebServerShowsEverywhere() async throws {
        let script = ProbeScript(), clock = ProbeClock()
        let r = try await rig(script, clock)
        defer { r.stop() }
        await r.connect()
        // The four panes list the same process's port: it is asked once.
        _ = await eventually { script.asked == [5173] && r.server.ports.value("block:2b") != nil }
        XCTAssertEqual(shown(r).rows, [], "held for its answer")
        XCTAssertEqual(shown(r).count, 0)
        XCTAssertEqual(shown(r).menu, [])
        script.answer(5173, .notWeb)
        await quiet()
        clock.now += 10
        r.server.refreshPortRows()
        XCTAssertEqual(shown(r).rows, [])
        XCTAssertEqual(shown(r).count, 0, "no number for a missing row")
        XCTAssertEqual(shown(r).menu, [])
        XCTAssertEqual(r.server.ports.value("block:1a")?.entry(5173)?.port, 5173, "the list itself keeps it, for tapped links")

        // Another process on that port in one pane is asked again, and shows when it is a web server.
        sendPorts(r, block: "block:1a", [5173], pid: 8)
        _ = await eventually { script.asked == [5173, 5173] }
        XCTAssertEqual(shown(r).menu, [], "held: no row was shown for that port")
        script.answer(5173, .web)
        _ = await eventually { !r.server.portRows.isEmpty }
        XCTAssertEqual(shown(r).rows, ["block:1a:5173"])
        XCTAssertEqual(shown(r).count, 1)
        XCTAssertEqual(shown(r).menu, [5173])
        XCTAssertEqual(shown(r, "block:1b").menu, [], "the other panes' process is still no web page")
        XCTAssertNotNil(r.server.portRow("block:1a:5173"))
        XCTAssertNil(r.server.portRow("block:1b:5173"))
    }

    func testANewPortShowsAfterTheHoldWhenItsAnswerIsSlow() async throws {
        let script = ProbeScript(), clock = ProbeClock()
        let r = try await rig(script, clock)
        defer { r.stop() }
        await r.connect()
        _ = await eventually { script.asked == [5173] && r.server.ports.value("block:2b") != nil }
        r.server.refreshPortRows()
        XCTAssertEqual(shown(r).count, 0)
        clock.now += PortProbeBook.hold - 0.1
        r.server.refreshPortRows()
        XCTAssertEqual(shown(r).count, 0)
        clock.now += 0.2
        r.server.refreshPortRows()
        XCTAssertEqual(shown(r).count, 4, "the hold is up: shown, unanswered")
        XCTAssertEqual(shown(r).rows.count, 4)
        XCTAssertEqual(shown(r).menu, [5173])
        // The answer agrees: nothing moves.
        script.answer(5173, .web)
        await quiet()
        XCTAssertEqual(shown(r).count, 4)
        XCTAssertEqual(script.asked, [5173], "never asked again")
    }

    func testUnknownShowsAndIsAskedAgainAtTheNextListing() async throws {
        let script = ProbeScript(), clock = ProbeClock()
        let r = try await rig(script, clock)
        defer { r.stop() }
        await r.connect()
        _ = await eventually { script.asked == [5173] && r.server.ports.value("block:2b") != nil }
        // Refused, or offline mid-probe: shown, as before the probe.
        script.answer(5173, .unknown)
        _ = await eventually { shown(r).count == 4 }
        XCTAssertEqual(shown(r).count, 4)
        r.server.refreshPortRows()
        XCTAssertEqual(script.asked, [5173], "nothing polls")
        sendPorts(r, block: "block:1a", [5173, 3000])
        _ = await eventually { script.asked.count == 3 }
        XCTAssertEqual(script.asked.sorted(), [3000, 5173, 5173], "the new listing asks the unknown port again, once")
        XCTAssertEqual(shown(r).menu, [5173], "still shown while it is asked again; the new port is held")
        script.answer(3000, .web)
        script.answer(5173, .notWeb)
        _ = await eventually { shown(r).count == 1 }
        XCTAssertEqual(shown(r).rows, ["block:1a:3000"])
    }

    func testAtMostTwoProbesRunAtOnce() async throws {
        let script = ProbeScript(), clock = ProbeClock()
        let r = try await rig(script, clock)
        defer { r.stop() }
        await r.connect()
        _ = await eventually { script.asked == [5173] && r.server.ports.value("block:2b") != nil }
        script.answer(5173, .web)
        sendPorts(r, block: "block:1a", [3000, 3001, 3002, 3003, 5173])
        _ = await eventually { script.asked.count == 3 }
        await quiet()
        XCTAssertEqual(script.running, [3000, 3001])
        script.answer(3000, .web)
        _ = await eventually { script.running == [3001, 3002] }
        XCTAssertEqual(script.running, [3001, 3002])
        script.answer(3001, .web)
        script.answer(3002, .notWeb)
        _ = await eventually { script.running == [3003] }
        script.answer(3003, .web)
        _ = await eventually { shown(r).menu == [3000, 3001, 3003, 5173] }
        XCTAssertEqual(shown(r).menu, [3000, 3001, 3003, 5173])
    }

    func testAnAnswerAfterItsPaneClosedChangesNothing() async throws {
        let script = ProbeScript(), clock = ProbeClock()
        let r = try await rig(script, clock)
        defer { r.stop() }
        await r.connect()
        _ = await eventually { script.asked == [5173] && r.server.ports.value("block:2b") != nil }
        script.answer(5173, .web)
        sendPorts(r, block: "block:1b", [8080], pid: 9)
        _ = await eventually { script.running == [8080] }
        r.server.forgetPorts("block:1b")
        script.answer(8080, .web)
        await quiet()
        XCTAssertFalse(r.server.portRows.contains { $0.entry.port == 8080 })
        XCTAssertNil(r.server.portProbes.verdict(PortProbeBook.Key(pid: 9, port: 8080, host: "127.0.0.1")))
        XCTAssertNil(r.server.portsHidden.value("block:1b"))
    }

    func testWithoutAProberEveryPortShowsAtOnce() async throws {
        let script = ProbeScript(), clock = ProbeClock()
        let r = try await rig(script, clock)
        defer { r.stop() }
        r.server.probePort = nil
        await r.connect()
        _ = await eventually { shown(r).count == 4 }
        XCTAssertEqual(shown(r).count, 4, "no probes: every port shows, as before")
        XCTAssertTrue(script.asked.isEmpty)
    }

    private func quiet(_ ms: Int = 300) async { try? await Task.sleep(for: .milliseconds(ms)) }

    private func eventually(seconds: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }
}

/// The probe's own tunnel: a block of its own, one request, then the block closes.
@MainActor
final class PortForwardProbeTests: XCTestCase {
    private func forward() -> PortForward {
        let f = PortForward(tag: { "a1b2c3d4" }, ledger: TunnelLedger(defaults: UserDefaults(suiteName: UUID().uuidString)!),
                            makeListener: { StubListener() })
        f.probeSleep = { _ in try await Task.sleep(for: .seconds(3600)) }
        return f
    }

    private let target = PortForward.Target(sessionID: "session:1", port: 10955, dialHost: "127.0.0.1")

    func testAProbeMakesItsOwnBlockAsksOnceAndClosesIt() async {
        let server = FakeTunnelServer()
        server.onSocket = { $0.push(Data("HTTP/1.1 426 Upgrade Required\r\nConnection: close\r\n\r\n".utf8)) }
        let f = forward()
        let v = await f.probe(target, on: server)
        XCTAssertEqual(v, .notWeb)
        XCTAssertEqual(server.calls, ["session.new_block session:1", "data.connect block:t1", "inOrder block.close block:t1"])
        XCTAssertEqual(server.sockets.first?.sent, [PortProbe.request(port: 10955)], "one request, nothing else")
        XCTAssertTrue(server.sockets.first?.aborted == true)
        XCTAssertTrue(f.owns("block:t1"), "its events change no view")
        XCTAssertTrue(f.ledger.sessions(server: server.id).isEmpty, "closed and forgotten")
        XCTAssertNil(f.forward, "no browser, no listener")
    }

    func testARefusedOrUnreachablePortIsUnknown() async {
        let server = FakeTunnelServer()
        server.onSocket = { $0.serverClose(1001) }
        let f = forward()
        let refused = await f.probe(target, on: server)
        XCTAssertEqual(refused, .unknown)
        XCTAssertEqual(server.calls.last, "inOrder block.close block:t1")

        server.calls = []
        server.tunnelConnected = false
        let offline = await f.probe(target, on: server)
        XCTAssertEqual(offline, .unknown)
        XCTAssertTrue(server.calls.isEmpty, "offline: nothing is asked")

        server.tunnelConnected = true
        let debugger = await f.probe(PortForward.Target(sessionID: "session:1", port: 9229, dialHost: "127.0.0.1"), on: server)
        XCTAssertEqual(debugger, .unknown)
        XCTAssertTrue(server.calls.isEmpty, "a debugger port is never dialed")

        server.newBlockError = RexError(code: "conflict", message: "full", status: 409)
        var notes: [String] = []
        f.notify = { notes.append($0) }
        let full = await f.probe(target, on: server)
        XCTAssertEqual(full, .unknown)
        XCTAssertTrue(notes.isEmpty, "a probe never shows a notice")
    }

    func testASweepDuringAProbeLeavesItsBlock() async {
        let server = FakeTunnelServer()
        let f = forward()
        server.onSocket = { socket in
            // A sync comes while the probe waits for its reply: the sweep runs, then the reply.
            f.serverSynced(server)
            Task { @MainActor in
                let end = Date().addingTimeInterval(5)
                while !server.calls.contains("session.list_blocks session:1"), Date() < end {
                    try? await Task.sleep(for: .milliseconds(10))
                }
                try? await Task.sleep(for: .milliseconds(50))
                socket.push(Data("HTTP/1.1 200 OK\r\n\r\n".utf8))
            }
        }
        let v = await f.probe(target, on: server)
        XCTAssertEqual(v, .web)
        XCTAssertTrue(server.calls.contains("session.list_blocks session:1"))
        XCTAssertEqual(server.calls.filter { $0.hasPrefix("inOrder") }, ["inOrder block.close block:t1"], "closed once, by the probe, after its reply")
        XCTAssertEqual(server.calls.last, "inOrder block.close block:t1")
    }
}
