import Foundation
import GlanceModel
import XCTest
@testable import RexKit
@testable import RexDuo

/// What the Ports group does with a computer's Beacon: Open in Browser, Stop for a server behind
/// a wrapper, and Restart (docs/terminal.md, Ports). The rules themselves are tested in RexKit
/// (`PortOwnerTests`); these are the app's use of them.
final class PortsBeaconLogicTests: XCTestCase {
    private func entry(_ port: Int = 3000, pid: Int? = 7, dialHost: String = "127.0.0.1") -> PortEntry {
        PortEntry(port: port, dialHost: dialHost, process: "node", pid: pid, program: "node", folder: nil)
    }

    /// `npm run dev`: node (7) holds the port, npm (70) leads the group in front, zsh (60) started it.
    static func wrapped(front: Int? = 70, leader: String = "npm", argv: [String]? = ["npm", "run", "dev"], members: Int? = 1) -> PortOwner {
        PortOwner(pid: 7, pgid: 70, ttyForegroundPGID: front, ancestry: [
            PortOwner.Link(pid: 7, ppid: 70, pgid: 70, sid: 60, name: "node", argv: ["node", "server.js"], cwd: "/home/alex/app"),
            PortOwner.Link(pid: 70, ppid: 60, pgid: 70, sid: 60, name: leader, argv: argv, cwd: "/home/alex/app"),
            PortOwner.Link(pid: 60, ppid: 1, pgid: 60, sid: 60, name: "zsh", argv: ["-zsh"], cwd: "/home/alex/app"),
        ], jobMembers: members)
    }

    static func json(_ o: PortOwner) -> JSONObject {
        ["pid": o.pid, "pgid": o.pgid, "tty_foreground_pgid": o.ttyForegroundPGID as Any, "foreground": o.ttyForegroundPGID == o.pgid,
         "job_members": o.jobMembers as Any,
         "ancestry": o.ancestry.map { l in
             ["pid": l.pid, "ppid": l.ppid, "pgid": l.pgid, "sid": l.sid, "group_leader": l.groupLeader, "session_leader": l.sessionLeader,
              "name": l.name, "path": l.path, "argv": l.argv as Any, "argv_lossy": l.argvLossy, "truncated": l.truncated, "cwd": l.cwd as Any] as JSONObject
         }]
    }

    // MARK: Stop (hazards 1 and 3)

    func testWithoutAnOwnerStopIsWhatItWas() {
        XCTAssertEqual(PortStop.verdict(entry: entry(), foregroundPID: 7, agent: false, owner: nil), .allowed)
        XCTAssertEqual(PortStop.verdict(entry: entry(), foregroundPID: 70, agent: false, owner: nil), .notForeground)
    }

    func testAnOwnerAddsStopForAServerBehindItsWrapper() {
        let o = Self.wrapped()
        XCTAssertEqual(PortStop.verdict(entry: entry(), foregroundPID: 70, agent: false, owner: o), .allowed)
        XCTAssertEqual(PortStop.verdict(entry: entry(), foregroundPID: 60, agent: false, owner: o), .notForeground, "the shell is in front")
        XCTAssertEqual(PortStop.verdict(entry: entry(), foregroundPID: 70, agent: false, owner: Self.wrapped(front: 60)), .notForeground,
                       "a background job")
        XCTAssertEqual(PortStop.verdict(entry: entry(pid: 8), foregroundPID: 70, agent: false, owner: o), .notForeground,
                       "an owner of another process says nothing about this one")
        XCTAssertEqual(PortStop.verdict(entry: entry(pid: 8), expected: 7, foregroundPID: 70, agent: false, owner: o), .gone)
        XCTAssertEqual(PortStop.verdict(entry: nil, foregroundPID: 70, agent: false, owner: o), .gone)
    }

    func testAnInterruptNeverReachesAnAgentThroughAnOwner() {
        XCTAssertEqual(PortStop.verdict(entry: entry(), foregroundPID: 70, agent: true, owner: Self.wrapped()), .agent, "the pane reports an agent")
        XCTAssertEqual(PortStop.verdict(entry: entry(), foregroundPID: 70, agent: false, owner: Self.wrapped(leader: "claude")), .agent,
                       "an agent leads the group the interrupt goes to")
        XCTAssertEqual(PortStop.verdict(entry: entry(), foregroundPID: 70, agent: false,
                                        owner: Self.wrapped(leader: "node", argv: ["/usr/local/bin/codex", "run"])), .agent,
                       "an agent by the program it was started as")
    }

    // MARK: Restart's offer (hazard 2)

    func testRestartIsOfferedOnlyWhereStopIsAndTheCommandReadsWhole() {
        XCTAssertEqual(PortStop.restart(entry: entry(), foregroundPID: 70, agent: false, owner: Self.wrapped())?.text, "npm run dev")
        XCTAssertNil(PortStop.restart(entry: entry(), foregroundPID: 70, agent: false, owner: nil), "no Beacon, no Restart")
        XCTAssertNil(PortStop.restart(entry: entry(), foregroundPID: 60, agent: false, owner: Self.wrapped()), "the shell is in front")
        XCTAssertNil(PortStop.restart(entry: entry(), foregroundPID: 70, agent: true, owner: Self.wrapped()), "an agent is in the pane")
        XCTAssertNil(PortStop.restart(entry: entry(), foregroundPID: 70, agent: false, owner: Self.wrapped(leader: "claude")))
        XCTAssertNil(PortStop.restart(entry: entry(), foregroundPID: 70, agent: false, owner: Self.wrapped(argv: nil)), "arguments that can't be read")
        XCTAssertNil(PortStop.restart(entry: entry(pid: 8), foregroundPID: 70, agent: false, owner: Self.wrapped()), "another process holds the port")
        XCTAssertNil(PortStop.restart(entry: entry(), foregroundPID: 70, agent: false, owner: Self.wrapped(members: 2)), "a pipeline")
        XCTAssertNil(PortStop.restart(entry: entry(), foregroundPID: 70, agent: false, owner: Self.wrapped(members: nil)),
                     "a Beacon that doesn't say how many commands the job is")
        XCTAssertEqual(PortStop.verdict(entry: entry(), foregroundPID: 70, agent: false, owner: Self.wrapped(members: 2)), .allowed,
                       "Stop is for a pipeline too: the interrupt reaches all of it")
    }

    func testABeaconsStatusSaysWhetherItCanHandPagesOut() {
        XCTAssertEqual(HelperVersion(["version": "0.7.0", "share_possible": true])?.sharePossible, true)
        XCTAssertEqual(HelperVersion(["version": "0.7.0", "share_possible": false])?.sharePossible, false)
        XCTAssertEqual(HelperVersion(["version": "0.6.0"])?.sharePossible, false, "a status without the field is a no")
    }

    // MARK: Words

    func testNothingARowOrANoticeSaysIsATechnicalWord() {
        var lines = [PortBrowser.rowWords, PortRestartCopy.detail, PortRestartCopy.restarting, PortRestartCopy.failed,
                     PortRestartCopy.confirm(RestartCommand(text: "npm run dev", shellPID: 60, leaderPID: 70))]
        for code in ["not_available", "not_registered", "not_your_phone", "not_listening", "busy", "refused", "failed", "bad_request", "anything"] {
            lines.append(PortBrowser.notice(.refused(code: code, unknownAction: false), name: "localhost:3000", computer: "Desk"))
        }
        lines.append(PortBrowser.notice(.refused(code: "not_supported", unknownAction: true), name: "localhost:3000", computer: "Desk"))
        for p in [PortBrowser.Problem.offline, .noAddress, .unanswered, .badAnswer] {
            lines.append(PortBrowser.notice(p, name: "localhost:3000", computer: "Desk"))
        }
        for f in [PortRestart.Failure.changed, .paneNotReady, .notStopped, .stillRunning, .notTyped, .noPort] {
            lines.append(PortRestartCopy.notice(f, name: "Next.js", address: "localhost:3000"))
        }
        for line in lines {
            let l = line.lowercased()
            for word in ["share", "tunnel", "proxy", "argv", "tailnet", "pid", "process group", "signal", "ctrl", "interrupt", "server",
                         "machine", "phone_ip", "not_", "ts.net", " phone"] {
                XCTAssertFalse(l.contains(word), "\(word) in: \(line)")
            }
            XCTAssertFalse(line.isEmpty)
        }
        XCTAssertEqual(PortRestartCopy.confirm(RestartCommand(text: "npm run dev", shellPID: 60, leaderPID: 70)), "Restart: npm run dev")
        XCTAssertEqual(PortRestartCopy.detail, "Runs this command again in its pane.")
        XCTAssertEqual(PortBrowser.notice(.refused(code: "not_registered", unknownAction: false), name: "localhost:3000", computer: "Desk"),
                       "Couldn't open localhost:3000 in the browser: \(Brand.beaconName) on Desk doesn't know this iPhone yet. Set it up in Settings → Notifications.")
        XCTAssertEqual(PortBrowser.rowWords, "In browser")
        XCTAssertEqual(PortBrowser.notice(.refused(code: "not_listening", unknownAction: false), name: "localhost:3000", computer: "Desk"),
                       "Nothing is running on localhost:3000 now.")
    }

    func testWhichPortsAComputerHandsOut() {
        XCTAssertTrue(PortBrowser.mayAsk(entry(3000)))
        XCTAssertTrue(PortBrowser.mayAsk(entry(80)))
        XCTAssertTrue(PortBrowser.mayAsk(entry(3000, dialHost: "localhost")))
        XCTAssertTrue(PortBrowser.mayAsk(entry(3000, dialHost: "::1")))
        XCTAssertFalse(PortBrowser.mayAsk(entry(443)))
        XCTAssertFalse(PortBrowser.mayAsk(entry(3000, dialHost: "10.0.0.246")), "a server on a LAN address only")
        let lan = LocalhostLink(lan: URL(string: "http://10.0.0.246:3000/")!)!
        XCTAssertFalse(PortBrowser.mayLoad(lan))
        XCTAssertTrue(PortBrowser.mayLoad(LocalhostLink(URL(string: "http://localhost:3000/x")!)!))
        XCTAssertFalse(PortBrowser.mayLoad(LocalhostLink(URL(string: "https://localhost:3000/x")!)!))
    }

    // MARK: One origin (hazard 15)

    func testAPageLoadedFromTheComputersAddressShowsLocalhostAndCopiesTheAddressThatWorks() {
        var page = PreviewPage(load: URL(string: "http://desk.example.ts.net:3000/")!, shown: "localhost:3000")
        page.shared = true
        let here = URL(string: "http://desk.example.ts.net:3000/admin?x=1")!
        XCTAssertEqual(PreviewAddress.display(here, page), "localhost:3000", "the address underneath is never shown")
        XCTAssertEqual(PreviewAddress.editing(here, page), "localhost:3000/admin?x=1")
        XCTAssertEqual(PreviewAddress.errorTitle(here, page), "Couldn't load localhost:3000")
        XCTAssertEqual(PreviewAddress.link(here, page), "http://desk.example.ts.net:3000/admin?x=1")
        XCTAssertEqual(PreviewAddress.link(nil, page), "http://desk.example.ts.net:3000/")
        XCTAssertEqual(PreviewAddress.load("/other", page)?.absoluteString, "http://desk.example.ts.net:3000/other")
        XCTAssertEqual(PreviewAddress.ownRest(here, page), "/admin?x=1")
        XCTAssertNil(PreviewAddress.ownRest(URL(string: "https://example.com/")!, page), "another site has no page of the computer's")
        // Without one, as before.
        let local = PreviewPage(load: URL(string: "http://localhost:51000/")!, shown: "localhost:3000")
        XCTAssertEqual(PreviewAddress.link(URL(string: "http://localhost:51000/admin")!, local), "http://localhost:3000/admin")
    }

    @MainActor
    func testTheBrowsersMenuHasOpenInBrowserOnlyWhileItCanOpen() {
        @MainActor final class Told {
            var offered = false
            var opened: [String] = []
            var handed: String?
        }
        let told = Told()
        let outside = PreviewBrowser.Outside(offered: { told.offered }, open: { rest, _ in told.opened.append(rest) }, link: { _ in told.handed })
        let page = PreviewPage(load: URL(string: "http://localhost:51000/")!, shown: "localhost:3000")
        let plain = PreviewBrowser(page: page, onClose: {})
        XCTAssertFalse(plain.offersOutside, "no way out, no item")
        let browser = PreviewBrowser(page: page, outside: outside, onClose: {})
        XCTAssertFalse(browser.offersOutside, "hazard 12: no item while the computer can't hand the page out")
        told.offered = true
        XCTAssertTrue(browser.offersOutside)
        browser.openOutside()
        XCTAssertEqual(told.opened, ["/"])
        XCTAssertEqual(browser.linkText, "http://localhost:3000/")
        told.handed = "http://desk.example.ts.net:3000/"
        XCTAssertEqual(browser.linkText, "http://desk.example.ts.net:3000/", "Copy Link gives the address that works in the browser")
    }
}

/// The same against a Rex server in this process (`FakeRexServer`), with a Beacon the test plays.
@MainActor
final class PortsBeaconServerTests: XCTestCase {
    typealias Rig = ServerEventsTests.Rig
    nonisolated static let terminal = "com.superlogical.terminal"
    nonisolated static let process = "com.superlogical.terminal.process"
    nonisolated static let write = "com.superlogical.terminal.write"

    /// What the test's Beacon was asked and answers, and what the app did.
    @MainActor
    private final class World {
        var asked: [(action: String, args: JSONObject)] = []
        /// Nil: no Beacon holds this iPhone on the computer.
        var owner: Result<JSONObject, HelperFailure>? = .success(PortsBeaconLogicTests.json(PortsBeaconLogicTests.wrapped()))
        var share: Result<JSONObject, HelperFailure>? = .success(["url": "http://desk.example.ts.net:5173", "ip_url": "http://100.64.0.7:5173",
                                                                  "port": 5173, "same_port": true, "idle_seconds": 1800, "waiting_seconds": 600])
        var phone: String? = "100.64.0.9"
        var now = Date(timeIntervalSince1970: 1_000_000)
        var said: [String] = []
        var actions: [String?] = []
        var opened: [URL] = []
        var copied: [String] = []
        var typed: [String] = []
        var paneReady = true
        var paneWaiters: [@MainActor () -> Void] = []
        /// The Beacon's status, as the app last read it, and how many it has read.
        var possible = true
        var statuses = 1
        var revealed = 0
        var delivery = TerminalStream.Delivery.delivered
        /// Runs when the command was typed.
        var afterTyping: (@MainActor () -> Void)?

        func count(_ action: String) -> Int { asked.filter { $0.action == action }.count }

        /// The pane comes on screen over a current screen.
        func show() {
            paneReady = true
            let waiting = paneWaiters
            paneWaiters = []
            for body in waiting { body() }
        }
    }

    /// A server whose pane 1a runs `npm` (process 70) in front; `node` (process 7) holds 5173.
    func testAQuestionLeftForAProcessThatWentDoesNotHoldTheNextOnesRow() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        await learned(ports, r, row, w)
        ports.askRestart(r.server, row)
        // The program ends by itself and another takes the port, in front of the pane.
        sendPorts(r, [5173], pid: 8)
        sendForeground(r, pid: 8, name: "node")
        let changed = await eventually { r.server.portRow(row.id)?.entry.pid == 8 && r.server.meta["block:1a"]?.foregroundPID == 8 }
        XCTAssertTrue(changed)
        let next = try XCTUnwrap(r.server.portRow(row.id))
        XCTAssertNil(ports.note(r.server, next), "the question was the other process's")
        XCTAssertTrue(ports.offersStop(r.server, next), "and the row has its Stop")
        let step = await ports.restartNow(r.server, next)
        XCTAssertEqual(step, .confirming, "a tap that was on its way restarts nothing")
        XCTAssertEqual(w.typed, [])
        XCTAssertEqual(r.fake.calls(Self.write).count, 0)
        r.stop()
    }

    private func rig(foreground: JSONObject = ["pid": 70, "name": "npm"]) async throws -> Rig {
        let r = try await Rig(revision: 18, creators: .result(PortsTests.creators()))
        r.fake.reply(PortsTests.ports, PortsTests.reply([5173]))
        r.fake.reply("\(Self.terminal).program_status", ["records": [JSONObject]()])
        r.fake.reply(Self.process, ["foreground": foreground])
        r.fake.reply(Self.write, [:])
        return r
    }

    /// Waits run at a twentieth of their length.
    private func actions(_ w: World) -> PortActions {
        var parts = PortActions.Parts()
        parts.sleep = { try? await Task.sleep(nanoseconds: UInt64(max($0, 0) / 20 * 1_000_000_000)) }
        parts.failedFor = 2000
        parts.revealLimit = 40
        parts.only = { nil }
        parts.notify = { text, action in
            w.said.append(text)
            w.actions.append(action?.title)
        }
        parts.copy = { w.copied.append($0) }
        parts.openURL = { w.opened.append($0) }
        parts.phoneAddress = { w.phone }
        parts.now = { w.now }
        parts.beacon = { _, action, args, _ in
            w.asked.append((action, args))
            return action == "port_owner" ? w.owner : w.share
        }
        parts.uptime = { ProcessInfo.processInfo.systemUptime * 20 }
        parts.sharePossible = { _ in w.possible }
        parts.statusReads = { _ in w.statuses }
        parts.paneReady = { _, _ in w.paneReady }
        parts.whenPaneReady = { _, _, body in
            if w.paneReady { body() } else { w.paneWaiters.append(body) }
        }
        parts.reveal = { _, _ in
            w.revealed += 1
            return true
        }
        parts.type = { _, text, _, _, may in
            guard may(), w.delivery != .unsent else { return .unsent }
            w.typed.append(text)
            w.afterTyping?()
            return w.delivery
        }
        return PortActions(model: nil, parts: parts)
    }

    private func sendPorts(_ rig: Rig, _ ports: [Int], pid: Int = 7) {
        rig.fake.send(session: "session:1", event: "block_event",
                      ["block_id": "block:1a", "creator_name": Self.terminal, "name": "ports_changed", "payload": PortsTests.reply(ports, pid: pid)])
    }

    private func sendForeground(_ rig: Rig, pid: Int, name: String) {
        rig.fake.send(session: "session:1", event: "block_event",
                      ["block_id": "block:1a", "creator_name": Self.terminal, "name": "process_changed",
                       "payload": ["foreground": ["pid": pid, "name": name] as JSONObject] as JSONObject])
    }

    private func ready(_ r: Rig, foreground: Int = 70) async throws -> PortRow {
        await r.connect()
        let listed = await eventually(seconds: 20) { r.server.portRows.count == 4 && r.server.meta["block:1a"]?.foregroundPID == foreground }
        XCTAssertTrue(listed)
        return try XCTUnwrap(r.server.portRows.first { $0.blockID == "block:1a" })
    }

    /// The row showed: its owner is read.
    private func learned(_ ports: PortActions, _ r: Rig, _ row: PortRow, _ w: World) async {
        let before = w.count("port_owner")
        ports.learnOwner(r.server, row)
        _ = await eventually { w.count("port_owner") > before }
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func failure(_ code: String) -> Result<JSONObject, HelperFailure>? {
        .failure(HelperFailure(code: code, message: "said by the test"))
    }

    // MARK: Which computers have any of it (item 1, hazards 10 and 12)

    func testAComputerWithoutABeaconShowsNothingNewAndKeepsPlainStop() async throws {
        let r = try await rig(foreground: ["pid": 7, "name": "node"])
        let row = try await ready(r, foreground: 7)
        let w = World(), ports = actions(w)
        w.owner = nil
        w.share = nil
        ports.learnOwner(r.server, row)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(ports.offersBrowser(r.server, row))
        XCTAssertNil(ports.restartCommand(r.server, row))
        XCTAssertNil(ports.note(r.server, row))
        XCTAssertTrue(ports.offersStop(r.server, row), "Stop for the foreground process needs no Beacon")
        let outcome = await ports.stopNow(r.server, row)
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(r.fake.calls(Self.write).count, 1)
        r.stop()
    }

    func testAnOlderBeaconIsAskedOnceAConnectionAndShowsNothingNew() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        w.owner = failure("not_supported")
        await learned(ports, r, row, w)
        XCTAssertEqual(w.count("port_owner"), 1)
        for other in r.server.portRows { ports.learnOwner(r.server, other) }
        ports.learnOwner(r.server, row)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(w.count("port_owner"), 1, "the answer is kept for the connection: no row asks again")
        XCTAssertFalse(ports.offersBrowser(r.server, row))
        XCTAssertFalse(ports.offersStop(r.server, row))
        XCTAssertNil(ports.restartCommand(r.server, row))
        let outcome = await ports.stopNow(r.server, row)
        XCTAssertEqual(outcome, .refused(.notForeground), "Stop asks no Beacon that can't answer")
        XCTAssertEqual(w.count("port_owner"), 1)
        XCTAssertEqual(r.fake.calls(Self.write).count, 0)
        r.stop()
    }

    func testABeaconFromBeforeTheseActionsShowsNothingNewHoweverItSaysSo() async throws {
        // An older Beacon names the action it doesn't know in its message, with another code.
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        w.owner = .failure(HelperFailure(code: "bad_request", message: "unknown action: port_owner"))
        w.share = .failure(HelperFailure(code: "bad_request", message: "unknown action: port_share"))
        // Its status has no `share_possible` either.
        w.possible = HelperVersion(["version": "0.6.0"])?.sharePossible ?? true
        await learned(ports, r, row, w)
        XCTAssertFalse(ports.offersBrowser(r.server, row))
        XCTAssertFalse(ports.offersStop(r.server, row), "no Stop through a wrapper")
        XCTAssertNil(ports.restartCommand(r.server, row))
        XCTAssertNil(ports.note(r.server, row))
        ports.askRestart(r.server, row)
        XCTAssertNil(ports.note(r.server, row), "Restart can't even be asked for")
        ports.learnOwner(r.server, row)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(w.count("port_owner"), 1)
        XCTAssertEqual(w.count("port_share"), 0)
        XCTAssertEqual(w.said, [])
        r.stop()
    }

    func testAnOwnerIsReadOncePerProcess() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        await learned(ports, r, row, w)
        ports.learnOwner(r.server, row)
        ports.learnOwner(r.server, row)
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(w.count("port_owner"), 1)
        XCTAssertEqual(w.asked.first?.args.int("pid"), 7)
        XCTAssertEqual(w.count("port_share"), 0, "showing a row asks for no page")
        r.stop()
    }

    func testAPhoneWithoutATailnetAddressHasNoOpenInBrowser() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        w.phone = nil
        await learned(ports, r, row, w)
        XCTAssertFalse(ports.offersBrowser(r.server, row))
        XCTAssertTrue(ports.offersStop(r.server, row), "the rest doesn't need the address")
        let outcome = await ports.openInBrowserNow(r.server, row)
        XCTAssertEqual(outcome, .problem(.noAddress))
        XCTAssertEqual(w.count("port_share"), 0, "nothing is asked without an address to send")
        XCTAssertEqual(w.opened, [])
        r.stop()
    }

    func testOpenInBrowserGoesByTheBeaconsStatusAndNeverByATap() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        w.possible = false
        await learned(ports, r, row, w)
        XCTAssertFalse(ports.offersBrowser(r.server, row), "a computer that can't hand pages out never shows the item")
        XCTAssertTrue(ports.offersStop(r.server, row))
        XCTAssertEqual(w.count("port_share"), 0, "and nothing was asked to find that out")
        // The next status says it can.
        w.possible = true
        w.statuses += 1
        XCTAssertTrue(ports.offersBrowser(r.server, row))
        // It said it could, and then can't: one calm line, and the item is away until the
        // next status is read.
        w.share = failure("not_available")
        let outcome = await ports.openInBrowserNow(r.server, row)
        XCTAssertEqual(outcome, .problem(.refused(code: "not_available", unknownAction: false)))
        XCTAssertEqual(w.said.count, 1)
        XCTAssertEqual(w.said.first?.hasSuffix(" can't open pages in this iPhone's browser right now. localhost:5173 still opens here."), true)
        XCTAssertFalse(ports.offersBrowser(r.server, row))
        w.statuses += 1
        XCTAssertTrue(ports.offersBrowser(r.server, row), "a new status that still says yes brings it back")
        r.stop()
    }

    // MARK: Open in Browser (items 2 to 5)

    func testOpenInBrowserAsksForThePageAndOpensItsAddress() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        XCTAssertFalse(ports.offersBrowser(r.server, row), "not before the Beacon answered")
        await learned(ports, r, row, w)
        XCTAssertTrue(ports.offersBrowser(r.server, row))
        XCTAssertNil(ports.note(r.server, row))
        ports.copyLink(r.server, row)
        let outcome = await ports.openInBrowserNow(r.server, row)
        XCTAssertEqual(outcome, .opened(URL(string: "http://desk.example.ts.net:5173/")!))
        XCTAssertEqual(w.opened.map(\.absoluteString), ["http://desk.example.ts.net:5173/"])
        let ask = try XCTUnwrap(w.asked.last)
        XCTAssertEqual(ask.action, "port_share")
        XCTAssertEqual(ask.args.str("block"), "block:1a")
        XCTAssertEqual(ask.args.int("port"), 5173)
        XCTAssertEqual(ask.args.str("phone_ip"), "100.64.0.9")
        XCTAssertEqual(ports.note(r.server, row), .inBrowser)
        XCTAssertEqual(PortRowView.words(ports.note(r.server, row)), "In browser")
        ports.copyLink(r.server, row)
        XCTAssertEqual(w.copied, ["http://localhost:5173", "http://desk.example.ts.net:5173"], "the address that works, once there is one")
        XCTAssertEqual(w.said, [])
        r.stop()
    }

    func testOpeningAPageInTheAppNeverAsksForAnAddress() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        await learned(ports, r, row, w)
        let link = LocalhostLink(port: 5173, dialHost: "127.0.0.1")
        let none = await ports.existingShare(r.server, block: "block:1a", link)
        XCTAssertNil(none)
        XCTAssertEqual(w.count("port_share"), 0)
        // Once the page is out in the browser, the app loads the same site (hazard 15).
        _ = await ports.openInBrowserNow(r.server, row)
        let share = await ports.existingShare(r.server, block: "block:1a", link)
        XCTAssertEqual(share?.page("/admin")?.absoluteString, "http://desk.example.ts.net:5173/admin")
        XCTAssertEqual(w.count("port_share"), 2, "the one that exists is asked for again, which keeps it")
        let got4 = await ports.existingShare(r.server, block: "block:1a", LocalhostLink(lan: URL(string: "http://10.0.0.246:5173/")!)!)
        XCTAssertNil(got4,
                     "a LAN address opens the old way")
        let got3 = await ports.existingShare(r.server, block: "block:1a", LocalhostLink(port: 9999, dialHost: "127.0.0.1"))
        XCTAssertNil(got3, "an unlisted port")
        r.stop()
    }

    func testAnAddressThatEndedClearsTheRowAndTheNextTapAsksAgain() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        await learned(ports, r, row, w)
        _ = await ports.openInBrowserNow(r.server, row)
        XCTAssertEqual(ports.note(r.server, row), .inBrowser)
        // Unused for as long as the computer keeps it.
        w.now = w.now.addingTimeInterval(1800)
        XCTAssertNil(ports.note(r.server, row))
        XCTAssertNil(ports.shared(r.server, row))
        ports.copyLink(r.server, row)
        XCTAssertEqual(w.copied, ["http://localhost:5173"])
        let link = LocalhostLink(port: 5173, dialHost: "127.0.0.1")
        let got1 = await ports.existingShare(r.server, block: "block:1a", link)
        XCTAssertNil(got1)
        XCTAssertEqual(w.count("port_share"), 1, "the app's own open asks for none")
        _ = await ports.openInBrowserNow(r.server, row)
        XCTAssertEqual(w.count("port_share"), 2)
        XCTAssertEqual(ports.note(r.server, row), .inBrowser)
        // The computer ended it early: the app's next open finds out, and loads the old way.
        w.share = failure("not_listening")
        let got2 = await ports.existingShare(r.server, block: "block:1a", link)
        XCTAssertNil(got2)
        XCTAssertNil(ports.note(r.server, row))
        XCTAssertTrue(ports.offersBrowser(r.server, row), "the item stays: it may work the next time")
        XCTAssertEqual(w.said, [], "an open in the app says nothing about it")
        r.stop()
    }

    func testAnswersThatTakeOpenInBrowserAwayForTheComputer() async throws {
        for code in ["not_your_phone", "not_registered", "not_supported"] {
            let r = try await rig()
            let row = try await ready(r)
            let w = World(), ports = actions(w)
            await learned(ports, r, row, w)
            w.share = failure(code)
            let outcome = await ports.openInBrowserNow(r.server, row)
            XCTAssertEqual(outcome, .problem(.refused(code: code, unknownAction: code == "not_supported")), code)
            XCTAssertEqual(w.said.count, 1, "one calm line: \(code)")
            XCTAssertEqual(w.opened, [], code)
            XCTAssertFalse(ports.offersBrowser(r.server, row), code)
            for other in r.server.portRows { XCTAssertFalse(ports.offersBrowser(r.server, other), "the whole computer: \(code)") }
            w.statuses += 1
            XCTAssertFalse(ports.offersBrowser(r.server, row), "for the whole connection, whatever the next status says: \(code)")
            XCTAssertNil(ports.note(r.server, row), code)
            XCTAssertTrue(ports.offersStop(r.server, row), "Stop is another matter: \(code)")
            r.stop()
        }
    }

    func testAnswersThatKeepOpenInBrowser() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        await learned(ports, r, row, w)
        for code in ["not_listening", "busy", "failed", "refused", "bad_request"] {
            w.share = failure(code)
            let outcome = await ports.openInBrowserNow(r.server, row)
            XCTAssertEqual(outcome, .problem(.refused(code: code, unknownAction: false)), code)
            XCTAssertTrue(ports.offersBrowser(r.server, row), code)
        }
        XCTAssertEqual(w.said.first, "Nothing is running on localhost:5173 now.")
        XCTAssertEqual(w.said.count, 5)
        XCTAssertEqual(w.actions, [nil, nil, nil, nil, nil])
        XCTAssertEqual(w.opened, [])
        w.share = nil
        let silent = await ports.openInBrowserNow(r.server, row)
        XCTAssertEqual(silent, .problem(.unanswered))
        w.share = .success(["url": "javascript:alert(1)"])
        let bad = await ports.openInBrowserNow(r.server, row)
        XCTAssertEqual(bad, .problem(.badAnswer), "nothing but a plain web address is ever opened")
        XCTAssertEqual(w.opened, [])
        r.stop()
    }

    // MARK: Stop through a wrapper (item 6, hazards 1 and 3)

    func testStopReachesAServerBehindItsWrapperWithOneInterrupt() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        XCTAssertFalse(ports.offersStop(r.server, row), "from Rex alone, npm in front is not the port's process")
        await learned(ports, r, row, w)
        XCTAssertTrue(ports.offersStop(r.server, row))
        let outcome = await ports.stopNow(r.server, row)
        XCTAssertEqual(outcome, .sent)
        XCTAssertEqual(w.count("port_owner"), 2, "the owner is read again on the tap")
        let writes = r.fake.calls(Self.write)
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.obj("args")?.str("data"), "\u{3}", "Ctrl-C and nothing else")
        XCTAssertEqual(w.revealed, 0, "Stop shows no pane")
        XCTAssertEqual(w.said, [])
        r.stop()
    }

    func testStopTypesNothingWhenTheOwnerReadOnTheTapSaysOtherwise() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        await learned(ports, r, row, w)
        XCTAssertTrue(ports.offersStop(r.server, row))
        // Since the row showed, the job went to the background.
        w.owner = .success(PortsBeaconLogicTests.json(PortsBeaconLogicTests.wrapped(front: 60)))
        var outcome = await ports.stopNow(r.server, row)
        XCTAssertEqual(outcome, .refused(.notForeground))
        // Or an agent turned out to lead the group.
        w.owner = .success(PortsBeaconLogicTests.json(PortsBeaconLogicTests.wrapped(leader: "claude")))
        outcome = await ports.stopNow(r.server, row)
        XCTAssertEqual(outcome, .refused(.agent))
        // Or the Beacon no longer answers.
        w.owner = nil
        outcome = await ports.stopNow(r.server, row)
        XCTAssertEqual(outcome, .refused(.notForeground))
        XCTAssertEqual(r.fake.calls(Self.write).count, 0)
        XCTAssertEqual(w.actions, ["Show Pane", "Show Pane", "Show Pane"])
        r.stop()
    }

    // MARK: Restart (item 7, hazards 1 to 3)

    /// A server that a Ctrl-C stops: its port goes and the shell (60) comes back in front.
    private func stopsOnInterrupt(_ r: Rig) async {
        let stopped = await eventually { r.fake.calls(Self.write).count == 1 }
        XCTAssertTrue(stopped)
        r.fake.reply(Self.process, ["foreground": ["pid": 60, "name": "zsh"] as JSONObject])
        sendPorts(r, [])
        sendForeground(r, pid: 60, name: "zsh")
    }

    func testRestartAsksInTheRowAndTypesNothingUntilItsOneTap() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        XCTAssertNil(ports.restartCommand(r.server, row), "no Restart before the Beacon named the job")
        await learned(ports, r, row, w)
        XCTAssertEqual(ports.restartCommand(r.server, row)?.text, "npm run dev")
        ports.askRestart(r.server, row)
        guard case .confirm(let command)? = ports.note(r.server, row) else { return XCTFail("the row asks") }
        XCTAssertEqual(PortRestartCopy.confirm(command), "Restart: npm run dev")
        XCTAssertFalse(ports.offersStop(r.server, row))
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(r.fake.calls(Self.write).count, 0)
        XCTAssertEqual(w.typed, [])
        ports.dismissRestart(r.server, row)
        XCTAssertNil(ports.note(r.server, row))
        XCTAssertEqual(ports.restartCommand(r.server, row)?.text, "npm run dev", "Cancel leaves everything as it was")
        r.stop()
    }

    func testRestartStopsWaitsForTheShellAndTypesTheCommandOnce() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        await learned(ports, r, row, w)
        ports.askRestart(r.server, row)
        w.paneReady = false
        w.afterTyping = { [self] in sendPorts(r, [5173], pid: 8) }
        let run = Task { await ports.restartNow(r.server, row) }
        // The pane is shown first, and nothing is typed until it shows a current screen.
        let shown = await eventually { w.revealed == 1 }
        XCTAssertTrue(shown)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(r.fake.calls(Self.write).count, 0, "no Ctrl-C into a pane that isn't on screen")
        w.show()
        await stopsOnInterrupt(r)
        let step = await run.value
        XCTAssertEqual(step, .done)
        XCTAssertEqual(r.fake.calls(Self.write).first?.obj("args")?.str("data"), "\u{3}")
        XCTAssertEqual(r.fake.calls(Self.write).count, 1, "one Ctrl-C; the command went through the pane's own queue")
        XCTAssertEqual(w.typed, ["npm run dev\r"])
        XCTAssertEqual(w.said, [])
        XCTAssertNil(ports.note(r.server, row))
        XCTAssertTrue(r.server.portRowIDs.contains(row.id))
        r.stop()
    }

    func testTheRowKeepsItsPlaceAndSaysRestartingWhileItsPortIsAway() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        await learned(ports, r, row, w)
        ports.askRestart(r.server, row)
        let ids = r.server.portRowIDs
        let run = Task { await ports.restartNow(r.server, row) }
        await stopsOnInterrupt(r)
        let typed = await eventually { w.typed.count == 1 }
        XCTAssertTrue(typed)
        XCTAssertEqual(r.server.portRowIDs, ids, "no row moves while one restarts")
        XCTAssertEqual(ports.note(r.server, row), .restarting)
        XCTAssertEqual(PortRowView.words(.restarting), "Restarting…")
        // The port never comes back.
        let step = await run.value
        XCTAssertEqual(step, .failed(.noPort))
        XCTAssertEqual(ports.note(r.server, row), .restartFailed)
        XCTAssertEqual(w.actions, ["Show Pane"], "a failed Restart offers Show Pane and nothing else")
        XCTAssertEqual(w.typed.count, 1, "nothing is typed a second time")
        XCTAssertFalse(ports.offersStop(r.server, row))
        XCTAssertNil(ports.restartCommand(r.server, row), "no Restart to tap again")
        ports.dismissRestart(r.server, row)
        XCTAssertFalse(r.server.portRowIDs.contains(row.id), "the row follows its port again")
        r.stop()
    }

    func testRestartTypesNothingWhenTheCommandReadsDifferentlyNow() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        await learned(ports, r, row, w)
        ports.askRestart(r.server, row)
        // Another job took the port's process over since the row showed its command.
        w.owner = .success(PortsBeaconLogicTests.json(PortsBeaconLogicTests.wrapped(argv: ["npm", "run", "start"])))
        let step = await ports.restartNow(r.server, row)
        XCTAssertEqual(step, .failed(.changed))
        XCTAssertEqual(r.fake.calls(Self.write).count, 0, "not even the Ctrl-C")
        XCTAssertEqual(w.typed, [])
        XCTAssertEqual(w.revealed, 0)
        XCTAssertEqual(w.actions, ["Show Pane"])
        r.stop()
    }

    func testRestartTypesNothingWhenThePaneNeverShowsACurrentScreen() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        await learned(ports, r, row, w)
        ports.askRestart(r.server, row)
        w.paneReady = false
        let step = await ports.restartNow(r.server, row)
        XCTAssertEqual(step, .failed(.paneNotReady))
        XCTAssertEqual(w.revealed, 1)
        XCTAssertEqual(r.fake.calls(Self.write).count, 0)
        XCTAssertEqual(w.typed, [])
        r.stop()
    }

    func testRestartTypesNoCommandWhenTheProgramKeepsRunning() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        await learned(ports, r, row, w)
        ports.askRestart(r.server, row)
        // The Ctrl-C goes, and the server ignores it.
        let step = await ports.restartNow(r.server, row)
        XCTAssertEqual(step, .failed(.stillRunning))
        XCTAssertEqual(r.fake.calls(Self.write).count, 1)
        XCTAssertEqual(w.typed, [], "no command into a pane whose program still runs")
        r.stop()
    }

    func testRestartTypesNoCommandWhenSomethingElseTookTheForeground() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        await learned(ports, r, row, w)
        ports.askRestart(r.server, row)
        let run = Task { await ports.restartNow(r.server, row) }
        let stopped = await eventually { r.fake.calls(Self.write).count == 1 }
        XCTAssertTrue(stopped)
        // The port goes, and an editor is in front, not the shell.
        r.fake.reply(Self.process, ["foreground": ["pid": 91, "name": "vim"] as JSONObject])
        sendPorts(r, [])
        sendForeground(r, pid: 91, name: "vim")
        let step = await run.value
        XCTAssertEqual(step, .failed(.stillRunning))
        XCTAssertEqual(w.typed, [])
        r.stop()
    }

    func testACommandThatDidNotLeaveIsACleanFailureAndIsNeverTypedLater() async throws {
        let r = try await rig()
        let row = try await ready(r)
        let w = World(), ports = actions(w)
        await learned(ports, r, row, w)
        ports.askRestart(r.server, row)
        w.delivery = .unsent
        let run = Task { await ports.restartNow(r.server, row) }
        await stopsOnInterrupt(r)
        let step = await run.value
        XCTAssertEqual(step, .failed(.notTyped))
        w.delivery = .delivered
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(w.typed, [], "an unsent command stays unsent")
        XCTAssertEqual(w.said.count, 1)
        XCTAssertEqual(w.said.first?.hasSuffix(" stopped, but its command wasn't sent. Start it again in its pane."), true)
        XCTAssertEqual(w.actions, ["Show Pane"])
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
