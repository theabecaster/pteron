import Foundation
import XCTest
@testable import RexKit
@testable import RexDuo

/// A machine's ports: their names, their rows, where they show, and Stop's rule (docs/terminal.md, Ports).
final class PortsPlaceLogicTests: XCTestCase {
    private func entry(_ port: Int = 3000, process: String? = nil, pid: Int? = 7, program: String? = nil, folder: String? = nil) -> PortEntry {
        PortEntry(port: port, dialHost: "127.0.0.1", process: process, pid: pid, program: program, folder: folder)
    }

    // MARK: Names

    func testKnownProgramsGetTheNamePeopleKnow() {
        let cases: [(String?, String?, String)] = [
            ("next-server (v15.1.0)", "node", "Next.js"), ("next", "node", "Next.js"), ("vite.js", "node", "Vite"),
            ("bun", "bun", "Bun"), ("server.js", "node", "Node"), ("Python", "Python", "Python"),
            ("app.py", "python3.12", "Python"), ("python3.9", "python3.9", "Python"), ("rails", "ruby", "Rails"),
            ("puma", "ruby", "Rails"), ("storybook", "node", "Storybook"), ("manage.py", "python3", "Django"),
            ("myserver", "myserver", "myserver"), ("caddy", "caddy", "Caddy"),
        ]
        for (process, program, want) in cases {
            XCTAssertEqual(PortNames.program(entry(process: process, program: program)), want, "\(process ?? "nil")")
        }
        XCTAssertNil(PortNames.program(entry(process: nil, pid: nil)), "no process known")
    }

    func testTheTitleIsTheProgramThenItsFolder() {
        XCTAssertEqual(PortNames.title(entry(process: "next", program: "node", folder: "/work/anchor")), "Next.js · anchor")
        XCTAssertEqual(PortNames.title(entry(process: "Python", folder: "/private/tmp")), "Python · tmp")
        XCTAssertEqual(PortNames.title(entry(process: "vite.js", folder: "/home/dev")), "Vite · ~")
        XCTAssertEqual(PortNames.title(entry(process: "vite.js", folder: nil)), "Vite")
        XCTAssertEqual(PortNames.title(entry(8765, process: nil, pid: nil)), "Port 8765")
    }

    // MARK: Rows

    func testRowsFollowThePanesOrderAndHoldOnlyWebPorts() {
        let lists: [String: PortList] = [
            "b2": PortList(entries: [entry(5173), entry(9229), entry(5432)]),
            "b1": PortList(entries: [entry(3000)]),
            "b3": PortList(),
        ]
        let rows = PortRows.rows(panes: [("s1", "b1"), ("s1", "b3"), ("s2", "b2"), ("s2", "b4")]) { lists[$0] }
        XCTAssertEqual(rows.map(\.id), ["b1:3000", "b2:5173"], "debugger and database ports are no rows")
        XCTAssertEqual(rows.map(\.sessionID), ["s1", "s2"])
        // An agent's own port is no dev server; the server it started is.
        let agent: [String: PortList] = ["b1": PortList(entries: [entry(58486, process: "claude", program: "node"), entry(3000, process: "next", program: "node")])]
        XCTAssertEqual(PortRows.rows(panes: [("s1", "b1")]) { agent[$0] }.map(\.id), ["b1:3000"])
    }

    // MARK: The sidebar (hazard 7)

    func testPortsAddNoRowToTheSidebar() {
        let a = UUID(), b = UUID()
        let s = SidebarOutline.Session(id: "s1", windowIDs: ["w1"])
        let machines = [SidebarOutline.Machine(id: a, sessions: [s]), SidebarOutline.Machine(id: b, sessions: [s])]
        // The outline has no place for ports: they open from the machine's header.
        XCTAssertEqual(SidebarOutline.rows(machines, collapsed: []).map(\.id), [
            "m:\(a.uuidString)", "s:\(a.uuidString):s1", "t:\(a.uuidString):w1",
            "m:\(b.uuidString)", "s:\(b.uuidString):s1", "t:\(b.uuidString):w1",
        ])
        // The fold the Ports group once saved goes on the next prune; the others stay.
        let kept = SidebarCollapse.pruned(["p:\(a.uuidString)", SidebarCollapse.machine(a)], servers: [a, b], live: [a: ["s1"]])
        XCTAssertEqual(kept, [SidebarCollapse.machine(a)])
    }

    func testTheSpokenPortsButtonNamesItsMachine() {
        XCTAssertEqual(MachinePortsButton.spoken(2, machine: "desk"), "Ports on desk, 2 open")
    }

    // MARK: Stop's rule (hazards 1 and 3)

    func testStopIsOnlyForTheForegroundProcessItself() {
        let e = entry(pid: 7)
        XCTAssertEqual(PortStop.verdict(entry: e, foregroundPID: 7, agent: false), .allowed)
        XCTAssertEqual(PortStop.verdict(entry: e, foregroundPID: 99, agent: false), .notForeground, "a background job, or its parent in front")
        XCTAssertEqual(PortStop.verdict(entry: e, foregroundPID: nil, agent: false), .notForeground, "an unknown foreground is never a yes")
        XCTAssertEqual(PortStop.verdict(entry: e, foregroundPID: 7, agent: true), .agent)
        XCTAssertEqual(PortStop.verdict(entry: entry(pid: nil), foregroundPID: 7, agent: false), .unknownProcess)
        XCTAssertEqual(PortStop.verdict(entry: nil, foregroundPID: 7, agent: false), .gone)
        XCTAssertEqual(PortStop.verdict(entry: entry(pid: 8), expected: 7, foregroundPID: 8, agent: false), .gone,
                       "another process took the port since the tap")
    }

    func testTheForegroundOfAProcessReply() {
        let python = PortStop.foreground(["foreground": ["pid": 7, "name": "Python"] as JSONObject])
        XCTAssertEqual(python.pid, 7)
        XCTAssertFalse(python.agent)
        XCTAssertTrue(PortStop.foreground(["foreground": ["pid": 9, "name": "node", "argv0": "claude"] as JSONObject]).agent)
        XCTAssertNil(PortStop.foreground([:]).pid)
    }
}

/// A machine's ports against a Rex server in this process (`FakeRexServer`).
@MainActor
final class PortsPlaceServerTests: XCTestCase {
    typealias Rig = ServerEventsTests.Rig
    nonisolated static let terminal = "com.superlogical.terminal"
    nonisolated static let process = "com.superlogical.terminal.process"
    nonisolated static let write = "com.superlogical.terminal.write"

    /// A server whose panes run `node` (process 7) in front, listening on 5173, with no agent.
    private func rig(_ revision: Int? = 18, dial: Bool = true, foreground: JSONObject = ["pid": 7, "name": "node"]) async throws -> Rig {
        let r = try await Rig(revision: revision, creators: .result(PortsTests.creators(dial: dial)))
        r.fake.reply(PortsTests.ports, PortsTests.reply([5173]))
        r.fake.reply("\(Self.terminal).program_status", ["records": [JSONObject]()])
        r.fake.reply(Self.process, ["foreground": foreground])
        r.fake.reply(Self.write, [:])
        return r
    }

    @MainActor
    private final class Said {
        var texts: [String] = []
        var actions: [String?] = []
    }

    /// With a clock, every wait of a Stop is on it: its look after `stillAfter` comes when the
    /// test fires it.
    private func actions(_ said: Said, clock: HeldClock? = nil, only: String? = nil) -> PortActions {
        var parts = PortActions.Parts()
        if let clock {
            parts.sleep = { await clock.sleep($0) }
            addTeardownBlock { clock.end() }
            // A length no other wait of a Stop has, so the test fires this one and no other.
            parts.stillAfter = 7
        }
        parts.only = { only }
        parts.notify = { text, action in
            said.texts.append(text)
            said.actions.append(action?.title)
        }
        return PortActions(model: nil, parts: parts)
    }

    private func sendPorts(_ rig: Rig, block: String, _ ports: [Int], pid: Int = 7) {
        rig.fake.send(session: "session:1", event: "block_event",
                      ["block_id": block, "creator_name": Self.terminal, "name": "ports_changed", "payload": PortsTests.reply(ports, pid: pid)])
    }

    private func quiet(_ ms: Int = 400) async { try? await Task.sleep(for: .milliseconds(ms)) }

    private func ready(_ r: Rig) async throws -> PortRow {
        await r.connect()
        let listed = await eventually(seconds: 20) { r.server.portRows.count == 4 && r.server.meta["block:1a"]?.foregroundPID == 7 }
        XCTAssertTrue(listed)
        return try XCTUnwrap(r.server.portRows.first { $0.blockID == "block:1a" })
    }

    // MARK: Rows

    func testThePortRowsFollowEveryLocalPaneInSidebarOrder() async throws {
        let r = try await rig()
        await r.connect()
        let listed = await eventually { r.server.portRows.count == 4 }
        XCTAssertTrue(listed)
        XCTAssertEqual(r.server.portRows.map(\.id), ["block:1a:5173", "block:1b:5173", "block:2a:5173", "block:2b:5173"])
        XCTAssertEqual(r.server.portRows.first?.entry.pid, 7)
        // A port that closes takes its row; one that opens in a pane off screen adds one.
        sendPorts(r, block: "block:1a", [])
        sendPorts(r, block: "block:2b", [5173, 8765])
        let changed = await eventually { r.server.portRows.map(\.id) == ["block:1b:5173", "block:2a:5173", "block:2b:5173", "block:2b:8765"] }
        XCTAssertTrue(changed)
        // A closed pane takes its rows.
        r.fake.send(session: "session:1", event: "block_closed", ["block_id": "block:1b"])
        let closed = await eventually { !r.server.portRows.contains { $0.blockID == "block:1b" } }
        XCTAssertTrue(closed)
        r.stop()
    }

    func testEqualListsWriteNoRows() async throws {
        let r = try await rig()
        await r.connect()
        _ = await eventually { r.server.portRows.count == 4 }
        let writes = Said()
        withObservationTracking { _ = r.server.portRows } onChange: {
            Task { @MainActor in writes.texts.append("changed") }
        }
        for _ in 0..<5 { sendPorts(r, block: "block:1a", [5173]) }
        await quiet()
        XCTAssertEqual(writes.texts, [], "a rescan with the same ports changes nothing the sidebar reads")
        r.stop()
    }

    func testAPortThatChangesHandsChangesItsRowAndNotTheList() async throws {
        let r = try await rig()
        await r.connect()
        _ = await eventually { r.server.portRowIDs.count == 4 }
        let list = Said(), other = Said()
        withObservationTracking { _ = r.server.portRowIDs } onChange: { Task { @MainActor in list.texts.append("list") } }
        withObservationTracking { _ = r.server.portRow("block:2a:5173") } onChange: { Task { @MainActor in other.texts.append("row") } }
        // Another process takes the port in one pane: the same rows, one of them changed.
        sendPorts(r, block: "block:1a", [5173], pid: 70)
        let changed = await eventually { r.server.portRow("block:1a:5173")?.entry.pid == 70 }
        XCTAssertTrue(changed)
        await quiet(200)
        XCTAssertEqual(list.texts, [], "the list reads only the rows' ids, which didn't change")
        XCTAssertEqual(other.texts, [], "and another pane's row reads only its own pane")
        XCTAssertTrue(r.server.hasPortRows)
        // A row that comes is the list's business.
        sendPorts(r, block: "block:1a", [5173, 8080], pid: 70)
        _ = await eventually { r.server.portRowIDs.count == 5 }
        await quiet(100)
        XCTAssertEqual(list.texts, ["list"])
        XCTAssertEqual(other.texts, [])
        r.stop()
    }

    /// The machine's ports button (`MachinePortsButton`) reads its count through `PortsSeen`:
    /// a port that changes hands redraws nothing, one that comes or goes redraws the button, and
    /// a hidden sidebar's button reads nothing at all.
    func testThePortsButtonRedrawsOnlyWhenARowComesOrGoes() async throws {
        let r = try await rig()
        await r.connect()
        _ = await eventually { r.server.portRowIDs.count == 4 }
        let seen = PortsSeen()
        let shown = Said(), hidden = Said()
        var count = 0
        withObservationTracking { count = seen.count(r.server, shown: true) } onChange: { Task { @MainActor in shown.texts.append("shown") } }
        XCTAssertEqual(count, 4)
        withObservationTracking { count = seen.count(r.server, shown: false) } onChange: { Task { @MainActor in hidden.texts.append("hidden") } }
        XCTAssertEqual(count, 4, "hidden: the count as last read")
        // Another process takes a port: the same rows.
        sendPorts(r, block: "block:1a", [5173], pid: 70)
        _ = await eventually { r.server.portRow("block:1a:5173")?.entry.pid == 70 }
        await quiet(200)
        XCTAssertEqual(shown.texts, [], "a port that changes hands doesn't redraw the button")
        // A port comes.
        sendPorts(r, block: "block:1a", [5173, 8080], pid: 70)
        _ = await eventually { r.server.portRowIDs.count == 5 }
        await quiet(100)
        XCTAssertEqual(shown.texts, ["shown"], "one that comes does")
        XCTAssertEqual(hidden.texts, [], "a hidden sidebar's button is told of nothing")
        XCTAssertEqual(seen.count(r.server, shown: false), 4)
        XCTAssertEqual(seen.count(r.server, shown: true), 5, "shown again, it reads the count as it is now")
        r.stop()
    }

    /// No port: the button shows nothing, and reads only whether there is one.
    func testWithoutPortsTheButtonShowsNothingAndWaitsForTheFirst() async throws {
        let r = try await rig()
        r.fake.reply(PortsTests.ports, PortsTests.reply([]))
        await r.connect()
        let synced = await eventually { r.server.synced && r.server.views.count == 2 }
        XCTAssertTrue(synced)
        await quiet()
        let seen = PortsSeen(), told = Said()
        var count = -1
        withObservationTracking { count = seen.count(r.server, shown: true) } onChange: { Task { @MainActor in told.texts.append("told") } }
        XCTAssertEqual(count, 0)
        XCTAssertFalse(r.server.hasPortRows)
        sendPorts(r, block: "block:2a", [3000])
        _ = await eventually { r.server.hasPortRows }
        await quiet(100)
        XCTAssertEqual(told.texts, ["told"])
        XCTAssertEqual(seen.count(r.server, shown: true), 1)
        r.stop()
    }

    /// Tab mode's session popover: the machine heading's ports button shows only with ports,
    /// opens the machine's ports in a sheet, and stays, dimmed, for a down machine's last ports.
    func testTheSessionPopoverOpensTheMachinesPorts() async throws {
        let r = try await rig()
        await r.connect()
        _ = await eventually { r.server.portRowIDs.count == 4 }
        let model = AppModel(prefs: r.server.prefs, connect: false)
        model.servers = [r.server]
        func heading() -> SessionPopover.Machine? {
            for row in SessionPopover(model).rows { if case .machine(let m) = row { return m } }
            return nil
        }
        XCTAssertEqual(heading()?.portCount, 4)
        XCTAssertEqual(heading()?.ports, .ports(r.server.id))
        XCTAssertTrue(SessionPopover.Action.ports(r.server.id).presents, "it waits for the popover to close")
        StripRoutes(model: model, dialogs: SidebarActions(), open: { _ in }).run(.ports(r.server.id))
        XCTAssertEqual(model.portsShown, r.server.id)
        XCTAssertTrue(model.helperSetup.sheetIsUp())
        model.portsShown = nil
        // Under Settings it stays shut.
        model.showSettings = true
        model.showPorts(r.server.id)
        XCTAssertNil(model.portsShown)
        model.showSettings = false
        // Down, the last known ports stay, dimmed.
        r.server.phase = .offline(ConnectionProblem(kind: .notAnswering, detail: "test"))
        XCTAssertEqual(heading()?.portCount, 4)
        XCTAssertTrue(heading()?.status.isDown == true)
        // The last port goes: no button.
        r.server.phase = .online
        for b in ["block:1a", "block:1b", "block:2a", "block:2b"] { sendPorts(r, block: b, []) }
        let gone = await eventually { !r.server.hasPortRows }
        XCTAssertTrue(gone)
        XCTAssertNil(heading()?.ports)
        XCTAssertEqual(heading()?.portCount, 0)
        r.stop()
    }

    func testANewPanesPortsThatComeBeforeItsViewAreKept() async throws {
        let r = try await rig()
        await r.connect()
        _ = await eventually { r.server.portRows.count == 4 }
        r.setViewExtra("block:1c")
        r.fake.delay("session.view", seconds: 0.5)
        r.fake.send(session: "session:1", event: "block_created", ["block_id": "block:1c"])
        sendPorts(r, block: "block:1c", [7000])
        let kept = await eventually { r.server.ports.value("block:1c")?.entries.map(\.port) == [7000] }
        XCTAssertTrue(kept)
        XCTAssertTrue(r.server.portRows.contains { $0.id == "block:1c:7000" })
        r.stop()
    }

    // MARK: Old servers (hazard 10)

    func testAServerWithoutPortsOrTunnelsHasNoGroup() async throws {
        for (rev, dial) in [(nil, true), (13, true), (14, true), (16, false)] as [(Int?, Bool)] {
            let r = try await rig(rev, dial: dial)
            await r.connect()
            sendPorts(r, block: "block:1a", [3000])
            await quiet()
            XCTAssertEqual(r.server.portRows, [], "\(String(describing: rev)) dial \(dial)")
            XCTAssertEqual(r.fake.count(PortsTests.ports), 0, "and reads nothing")
            r.stop()
        }
    }

    func testAMissingPortsMethodTakesTheGroupAway() async throws {
        let r = try await rig()
        r.fake.reply(PortsTests.ports, .error(code: "method_not_found", status: 404))
        await r.connect()
        _ = await eventually { !r.server.portsAvailable }
        XCTAssertEqual(r.server.portRows, [])
        r.stop()
    }

    // MARK: Stop (hazards 1, 2 and 3)

    func testStopTypesOneInterruptForTheForegroundProcess() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let said = Said(), ports = actions(said)
        XCTAssertTrue(ports.offersStop(r.server, row))
        let outcome = await ports.stopNow(r.server, row)
        XCTAssertEqual(outcome, .sent)
        let writes = r.fake.calls(Self.write)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.str("block_id"), "block:1a")
        XCTAssertEqual(writes.first?.obj("args")?.str("data"), "\u{3}", "Ctrl-C and nothing else")
        XCTAssertEqual(ports.status(r.server, row), .stopping)
        XCTAssertFalse(ports.offersStop(r.server, row), "no second Stop while the first is on its way")
        XCTAssertEqual(said.texts, [], "a Stop that worked says nothing")
        r.stop()
    }

    func testStopIsNotOfferedForABackgroundJobAndTypesNothing() async throws {
        // The shell (process 99) is in front; the server (process 7) is a background job.
        let r = try await rig(foreground: ["pid": 99, "name": "zsh"])
        await r.connect()
        _ = await eventually { r.server.portRows.count == 4 && r.server.meta["block:1a"]?.foregroundPID == 99 }
        let row = try XCTUnwrap(r.server.portRows.first)
        let said = Said(), ports = actions(said)
        XCTAssertFalse(ports.offersStop(r.server, row))
        let outcome = await ports.stopNow(r.server, row)
        XCTAssertEqual(outcome, .refused(.notForeground))
        XCTAssertEqual(r.fake.count(Self.write), 0)
        XCTAssertNil(ports.status(r.server, row))
        r.stop()
    }

    func testStopChecksTheForegroundAgainRightBeforeItTypes() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let said = Said(), ports = actions(said)
        XCTAssertTrue(ports.offersStop(r.server, row), "the row still shows Stop")
        // Since the last event the pane's foreground became something else.
        r.fake.reply(Self.process, ["foreground": ["pid": 4242, "name": "vim"] as JSONObject])
        let outcome = await ports.stopNow(r.server, row)
        XCTAssertEqual(outcome, .refused(.notForeground))
        XCTAssertEqual(r.fake.count(Self.write), 0, "nothing is typed into the other program")
        XCTAssertEqual(said.texts.count, 1)
        XCTAssertTrue(said.texts[0].hasPrefix("Couldn't stop Node"))
        XCTAssertEqual(said.actions, ["Show Pane"])
        XCTAssertNil(ports.status(r.server, row))
        r.stop()
    }

    func testStopNeverInterruptsAnAgent() async throws {
        let r = try await rig(foreground: ["pid": 7, "name": "node", "argv0": "claude"])
        await r.connect()
        _ = await eventually { r.server.portRows.count == 4 && r.server.meta["block:1a"]?.foregroundPID == 7 }
        let row = try XCTUnwrap(r.server.portRows.first)
        let said = Said(), ports = actions(said)
        XCTAssertFalse(ports.offersStop(r.server, row))
        let outcome = await ports.stopNow(r.server, row)
        XCTAssertEqual(outcome, .refused(.agent))
        XCTAssertEqual(r.fake.count(Self.write), 0)
        r.stop()
    }

    func testAnAgentThatReportsAStatusIsNeverInterruptedEither() async throws {
        let r = try await rig()
        r.fake.reply("\(Self.terminal).program_status", ["records": [["id": "x", "app": "claude", "state": "working"] as JSONObject]])
        await r.connect()
        _ = await eventually { r.server.portRows.count == 4 && r.server.meta["block:1a"]?.agentKind != nil }
        let row = try XCTUnwrap(r.server.portRows.first)
        let said = Said(), ports = actions(said)
        XCTAssertFalse(ports.offersStop(r.server, row))
        let outcome = await ports.stopNow(r.server, row)
        XCTAssertEqual(outcome, .refused(.agent))
        XCTAssertEqual(r.fake.count(Self.write), 0)
        r.stop()
    }

    func testAPortThatAnotherProcessTookIsNotStopped() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let said = Said(), ports = actions(said)
        sendPorts(r, block: "block:1a", [5173], pid: 8)
        _ = await eventually { r.server.ports.value("block:1a")?.entry(5173)?.pid == 8 }
        let outcome = await ports.stopNow(r.server, row)
        XCTAssertEqual(outcome, .gone)
        XCTAssertEqual(r.fake.count(Self.write), 0)
        XCTAssertEqual(said.texts, [], "the program it was for is gone: nothing to say")
        r.stop()
    }

    func testASecondTapWhileStoppingTypesNothing() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let said = Said(), ports = actions(said)
        r.fake.delay(Self.process, seconds: 0.3)
        async let first = ports.stopNow(r.server, row)
        try? await Task.sleep(for: .milliseconds(50))
        let second = await ports.stopNow(r.server, row)
        let one = await first
        XCTAssertEqual(second, .busy)
        XCTAssertEqual(one, .sent)
        XCTAssertEqual(r.fake.count(Self.write), 1)
        r.stop()
    }

    func testAnInterruptThatDidntLeaveIsACleanFailure() async throws {
        // What a pane's input queue answers when it can't send now (no connection, or a pane
        // still catching up): nothing was typed, and the row is as it was.
        let r = try await rig()
        let row = try await ready(r)
        let said = Said(), ports = actions(said)
        var asked = 0
        ports.parts.write = { _, _, _, _, may in
            asked += may() ? 1 : 0
            return .unsent
        }
        let outcome = await ports.stopNow(r.server, row)
        XCTAssertEqual(outcome, .unsent)
        XCTAssertEqual(asked, 1, "the last look passed; the queue didn't send")
        XCTAssertEqual(r.fake.count(Self.write), 0)
        XCTAssertNil(ports.status(r.server, row), "no Stopping… left behind")
        XCTAssertTrue(ports.offersStop(r.server, row), "Stop is there to tap again")
        XCTAssertEqual(said.texts.count, 1)
        XCTAssertTrue(said.texts[0].contains("Nothing was sent"))
        r.stop()
    }

    func testStopWhileThePaneIsCatchingUpTypesNothingAndSaysSo() async throws {
        // A pane on screen whose stream is behind its catch-up fence (it just came back, or its
        // connection dropped): its queue sends nothing, now or later.
        let r = try await rig()
        let row = try await ready(r)
        let said = Said(), ports = actions(said)
        let stream = TerminalStream(control: r.server.control, sessionID: "session:1", blockID: "block:1a")
        stream.start()
        defer { stream.stop() }
        XCTAssertTrue(stream.isFenced, "this world serves no data socket: the fence stays up")
        XCTAssertTrue(r.server.control.stream(block: "block:1a") === stream)
        let outcome = await ports.stopNow(r.server, row)
        XCTAssertEqual(outcome, .unsent)
        await quiet(300)
        XCTAssertEqual(r.fake.count(Self.write), 0, "nothing was typed, and nothing is typed later")
        XCTAssertNil(ports.status(r.server, row), "no Stopping… left behind")
        XCTAssertTrue(ports.offersStop(r.server, row), "Stop is there to tap again")
        XCTAssertEqual(said.texts.count, 1)
        XCTAssertTrue(said.texts[0].hasPrefix("Couldn't stop Node") && said.texts[0].contains("Nothing was sent"))
        XCTAssertEqual(said.actions, ["Show Pane"])
        // Caught up: the same Stop goes through the pane's queue, once.
        stream.fence.reset()
        let again = await ports.stopNow(r.server, row)
        XCTAssertEqual(again, .sent)
        XCTAssertEqual(r.fake.calls(Self.write).compactMap { $0.obj("args")?.str("data") }, ["\u{3}"])
        r.stop()
    }

    func testStopForAParkedPaneGoesAsOneCall() async throws {
        // A parked pane has no running stream: nothing is queued for it, so the interrupt is
        // one call on the server's connection, as for any pane off screen.
        let r = try await rig()
        let row = try await ready(r)
        let said = Said(), ports = actions(said)
        let stream = TerminalStream(control: r.server.control, sessionID: "session:1", blockID: "block:1a")
        stream.start()
        stream.park()
        defer { stream.stop() }
        XCTAssertNil(r.server.control.stream(block: "block:1a"))
        let outcome = await ports.stopNow(r.server, row)
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(r.fake.count(Self.write), 1)
        XCTAssertEqual(said.texts, [])
        r.stop()
    }

    func testTheLastLookRefusesWhenTheForegroundChangedWhileTheInterruptWaited() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let said = Said(), ports = actions(said)
        var allowed: Bool?
        ports.parts.write = { server, _, bid, _, may in
            // The Ctrl-C waited in the pane's queue; meanwhile an event named another foreground.
            server.handleBlockEvent(sessionID: "session:1", ["block_id": bid, "name": "process_changed",
                                                              "payload": ["foreground": ["pid": 555, "name": "vim"] as JSONObject] as JSONObject])
            allowed = may()
            return .unsent
        }
        _ = await ports.stopNow(r.server, row)
        XCTAssertEqual(allowed, false)
        r.stop()
    }

    func testAProgramThatKeepsItsPortIsMarkedStillRunningAndStopCanBeTappedAgain() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let said = Said(), clock = HeldClock(), ports = actions(said, clock: clock)
        _ = await ports.stopNow(r.server, row)
        XCTAssertEqual(ports.status(r.server, row), .stopping)
        let waited = await clock.fireWhenWaiting(ports.parts.stillAfter)
        XCTAssertTrue(waited)
        let still = await eventually { ports.status(r.server, row) == .stillRunning }
        XCTAssertTrue(still)
        XCTAssertEqual(r.fake.count(Self.write), 1, "never a second interrupt by itself")
        XCTAssertTrue(ports.offersStop(r.server, row))
        _ = await ports.stopNow(r.server, row)
        XCTAssertEqual(r.fake.count(Self.write), 2, "one more, for the second tap")
        XCTAssertEqual(said.texts, [])
        r.stop()
    }

    func testAPortThatWentTakesItsMarkWithIt() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let said = Said(), clock = HeldClock(), ports = actions(said, clock: clock)
        _ = await ports.stopNow(r.server, row)
        sendPorts(r, block: "block:1a", [])
        let gone = await eventually { !r.server.portRows.contains { $0.id == row.id } }
        XCTAssertTrue(gone, "the row goes when the server says the port is gone")
        // The look after the Ctrl-C finds the port gone and takes the mark away.
        XCTAssertEqual(ports.status(r.server, row), .stopping)
        let waited = await clock.fireWhenWaiting(ports.parts.stillAfter)
        XCTAssertTrue(waited)
        let cleared = await eventually { ports.status(r.server, row) == nil }
        XCTAssertTrue(cleared)
        // The same port again, held by a new process: a fresh row, with no mark from before.
        sendPorts(r, block: "block:1a", [5173], pid: 70)
        _ = await eventually { r.server.portRows.contains { $0.id == row.id } }
        let again = try XCTUnwrap(r.server.portRows.first { $0.id == row.id })
        XCTAssertNil(ports.status(r.server, again))
        r.stop()
    }

    func testOfflineStopTypesNothingAndSaysWhy() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let said = Said(), ports = actions(said)
        r.server.stop()
        XCTAssertFalse(ports.offersStop(r.server, row))
        let outcome = await ports.stopNow(r.server, row)
        XCTAssertEqual(outcome, .offline)
        XCTAssertEqual(said.texts.count, 1)
        XCTAssertEqual(r.fake.count(Self.write), 0)
        r.fake.stop()
    }

    func testATestLaunchTypesOnlyIntoItsOwnSession() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let said = Said(), ports = actions(said, only: "zz-other")
        r.fake.forget()
        let outcome = await ports.stopNow(r.server, row)
        XCTAssertEqual(outcome, .refused(.notForeground))
        XCTAssertEqual(r.fake.count(Self.process), 0)
        XCTAssertEqual(r.fake.count(Self.write), 0)
        r.stop()
    }

    // MARK: Link

    func testCopyLinkCopiesTheLocalhostAddress() async throws {
        let r = try await rig()
        let row = try await ready(r)
        var copied: [String] = []
        var parts = PortActions.Parts()
        parts.copy = { copied.append($0) }
        PortActions(model: nil, parts: parts).copyLink(r.server, row)
        XCTAssertEqual(copied, ["http://localhost:5173"])
        r.stop()
    }

    // MARK: The palette

    func testThePaletteListsEveryPortOfAConnectedMachine() async throws {
        let r = try await rig()
        _ = try await ready(r)
        var copy = GoToSource.Copy()
        GoToCommands.add([r.server], target: nil, waitingCount: 0, into: &copy)
        let rows = copy.items.filter { $0.category == "Ports" }
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.first?.title, "Open localhost:5173 · Node")
        XCTAssertEqual(rows.first?.subtitle, "Ports")
        let id = try XCTUnwrap(rows.first?.id)
        guard case .port(let server, let row)? = copy.runs[id] else { return XCTFail("a port row opens its port") }
        XCTAssertEqual(server, r.server.id)
        XCTAssertEqual(row, "block:1a:5173")
        r.stop()
    }
}

@MainActor
private func eventually(seconds: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
