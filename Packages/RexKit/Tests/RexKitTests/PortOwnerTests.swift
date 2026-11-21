import XCTest
@testable import RexKit

/// What a Beacon says of a port's process, and what Stop, Restart and Open in Browser make of
/// it (docs/terminal.md, Ports).
final class PortOwnerTests: XCTestCase {
    typealias Link = PortOwner.Link
    private let shells: Set<String> = ["sh", "bash", "zsh", "fish"]
    private func isShell(_ name: String) -> Bool { shells.contains(name) }

    /// `npm run dev` typed into zsh: node (4242) holds the port, under sh, under npm (4200),
    /// the leader of the group in front.
    private func wrapped(front: Int? = 4200, npm: [String]? = ["npm", "run", "dev"], npmCwd: String? = "/home/alex/app",
                         shellCwd: String? = "/home/alex/app", lossy: Bool = false, cut: Bool = false, members: Int? = 1) -> PortOwner {
        PortOwner(pid: 4242, pgid: 4200, ttyForegroundPGID: front, ancestry: [
            Link(pid: 4242, ppid: 4201, pgid: 4200, sid: 900, name: "node", argv: ["node", "/home/alex/app/node_modules/.bin/next", "dev"], cwd: "/home/alex/app"),
            Link(pid: 4201, ppid: 4200, pgid: 4200, sid: 900, name: "sh", argv: ["sh", "-c", "next dev"], cwd: "/home/alex/app"),
            Link(pid: 4200, ppid: 900, pgid: 4200, sid: 900, name: "npm", argv: npm, argvLossy: lossy, truncated: cut, cwd: npmCwd),
            Link(pid: 900, ppid: 850, pgid: 900, sid: 900, name: "zsh", argv: ["-zsh"], cwd: shellCwd),
            Link(pid: 850, ppid: 1, pgid: 850, sid: 850, name: "rex", argv: ["rex", "serve"], cwd: "/"),
        ], jobMembers: members)
    }

    private func command(_ o: PortOwner) -> String? {
        try? RestartCommand.make(o, isShell: isShell).get().text
    }

    private func refusal(_ o: PortOwner) -> RestartCommand.Refusal? {
        if case .failure(let r) = RestartCommand.make(o, isShell: isShell) { return r }
        return nil
    }

    // MARK: The reply

    func testAReplyIsReadAsBeaconWritesIt() throws {
        let reply: JSONObject = [
            "pid": 4242, "pgid": 4200, "tty_foreground_pgid": 4200, "foreground": true,
            "ancestry": [
                ["pid": 4242, "ppid": 4200, "pgid": 4200, "sid": 900, "group_leader": false, "session_leader": false, "name": "node",
                 "path": "/usr/bin/node", "argv": ["node", "server.js"], "argv_lossy": false, "truncated": false, "cwd": "/home/alex/app"] as JSONObject,
                ["pid": 4200, "ppid": 900, "pgid": 4200, "sid": 900, "group_leader": true, "session_leader": false, "name": "npm",
                 "path": "/usr/bin/npm", "argv": ["npm", "run", "dev", "", "it's"], "argv_lossy": false, "truncated": false, "cwd": "/home/alex/app"] as JSONObject,
                ["pid": 900, "ppid": 1, "pgid": 900, "sid": 900, "group_leader": true, "session_leader": true, "name": "zsh",
                 "path": "/bin/zsh", "argv": NSNull(), "argv_lossy": false, "truncated": false, "cwd": NSNull()] as JSONObject,
            ],
        ]
        let o = try XCTUnwrap(PortOwner(reply))
        XCTAssertEqual([o.pid, o.pgid, o.ttyForegroundPGID ?? 0], [4242, 4200, 4200])
        XCTAssertEqual(o.ancestry.map(\.pid), [4242, 4200, 900])
        XCTAssertEqual(o.ancestry[1].argv, ["npm", "run", "dev", "", "it's"])
        XCTAssertTrue(o.ancestry[1].groupLeader)
        XCTAssertNil(o.ancestry[2].argv)
        XCTAssertNil(o.ancestry[2].cwd)
        XCTAssertEqual(o.job?.leader.pid, 4200)
        XCTAssertEqual(o.job?.parent.pid, 900)
    }

    func testAReplyThatCantBeTrustedIsNoOwner() {
        let holder: JSONObject = ["pid": 10, "ppid": 9, "pgid": 10, "name": "node"]
        XCTAssertNotNil(PortOwner(["pid": 10, "pgid": 10, "ancestry": [holder]]))
        XCTAssertNil(PortOwner(["pgid": 10, "ancestry": [holder]]), "no holder")
        XCTAssertNil(PortOwner(["pid": 10, "pgid": 10, "ancestry": [JSONObject]()]), "no chain")
        XCTAssertNil(PortOwner(["pid": 11, "pgid": 10, "ancestry": [holder]]), "the chain starts at another process")
        XCTAssertNil(PortOwner(["pid": 10, "pgid": 10, "ancestry": [holder, ["pid": 5, "ppid": 1, "pgid": 5, "name": "zsh"] as JSONObject]]),
                     "a parent that isn't the child's parent")
        XCTAssertNil(PortOwner(["pid": 10, "pgid": 10, "ancestry": [holder, ["ppid": 1, "name": "zsh"] as JSONObject]]), "a link without ids")
    }

    func testArgumentsThatAreNotAllTextOrNotMarkedAreUnreadable() throws {
        let odd = try XCTUnwrap(PortOwner.Link(["pid": 10, "ppid": 9, "pgid": 10, "name": "tool", "argv": ["tool", 3] as [Any]]))
        XCTAssertNil(odd.argv)
        let bare = try XCTUnwrap(PortOwner.Link(["pid": 10, "ppid": 9, "pgid": 10, "name": "tool", "argv": ["tool"]]))
        XCTAssertEqual(bare.argv, ["tool"])
        XCTAssertTrue(bare.truncated && bare.argvLossy, "a reply that doesn't say the arguments are whole is taken as cut")
    }

    // MARK: Stop

    func testAnInterruptReachesAServerBehindItsWrapper() {
        let o = wrapped()
        XCTAssertTrue(o.interruptReaches(foregroundPID: 4200), "npm, the group's leader, is in front")
        XCTAssertTrue(o.interruptReaches(foregroundPID: 4242), "the holder itself")
        XCTAssertTrue(o.interruptReaches(foregroundPID: 4201), "a parent in the same group")
    }

    func testAnInterruptDoesNotReachAServerInTheBackgroundOrInAnotherPane() {
        // `npm run dev &`: the shell's own group is in front of the terminal.
        let background = wrapped(front: 900)
        XCTAssertFalse(background.interruptReaches(foregroundPID: 900))
        XCTAssertFalse(background.interruptReaches(foregroundPID: 4200), "whatever Rex names, the terminal's front group is another")
        let o = wrapped()
        XCTAssertFalse(o.interruptReaches(foregroundPID: 900), "the shell is a parent in another group")
        XCTAssertFalse(o.interruptReaches(foregroundPID: 850))
        XCTAssertFalse(o.interruptReaches(foregroundPID: 7777), "another pane's program")
        XCTAssertFalse(o.interruptReaches(foregroundPID: nil), "an unknown foreground is never a yes")
        XCTAssertFalse(o.interruptReaches(foregroundPID: 1))
    }

    func testWithoutATerminalsFrontGroupTheGroupStillDecides() {
        let o = wrapped(front: nil)
        XCTAssertTrue(o.interruptReaches(foregroundPID: 4200))
        XCTAssertFalse(o.interruptReaches(foregroundPID: 900))
    }

    func testAServerItsStarterMovedToAGroupOfItsOwnIsNotReached() {
        // A script (4100) in front started the server in a new group (4242).
        let o = PortOwner(pid: 4242, pgid: 4242, ttyForegroundPGID: 4100, ancestry: [
            Link(pid: 4242, ppid: 4100, pgid: 4242, name: "node"),
            Link(pid: 4100, ppid: 900, pgid: 4100, name: "bash"),
            Link(pid: 900, ppid: 1, pgid: 900, name: "zsh"),
        ])
        XCTAssertFalse(o.interruptReaches(foregroundPID: 4100))
        var unknown = o
        unknown.ttyForegroundPGID = nil
        XCTAssertFalse(unknown.interruptReaches(foregroundPID: 4100), "a parent in another group never counts")
    }

    // MARK: Restart's command

    func testTheCommandIsTheJobLeadersArgumentsNotTheHolders() {
        XCTAssertEqual(command(wrapped()), "npm run dev")
        let made = try? RestartCommand.make(wrapped(), isShell: isShell).get()
        XCTAssertEqual(made?.shellPID, 900)
        XCTAssertEqual(made?.leaderPID, 4200)
        XCTAssertEqual(made?.typed, "npm run dev\r")
    }

    func testEveryArgumentIsSpelledForAShell() {
        XCTAssertEqual(command(wrapped(npm: ["npm", "run", "dev", "--", "--name", "two words", "it's", "$HOME", "a;b", "#x", "*.js"])),
                       "npm run dev -- --name two\\ words it\\'s \\$HOME a\\;b \\#x \\*.js")
        XCTAssertEqual(command(wrapped(npm: ["tool", "~", "~/x y", "~user", "=ls"])), "tool \\~ \\~/x\\ y \\~user \\=ls",
                       "a literal tilde stays literal")
    }

    func testArgumentsThatCantBeTypedOnOneLineGiveNoCommand() {
        XCTAssertEqual(refusal(wrapped(npm: ["npm", "run", ""])), .unquotable, "an empty argument has no spelling here")
        XCTAssertEqual(refusal(wrapped(npm: ["npm", "a\nrm -rf x"])), .unquotable, "a line end")
        XCTAssertEqual(refusal(wrapped(npm: ["npm", "a\u{1b}[2J"])), .unquotable, "an escape sequence")
        XCTAssertEqual(refusal(wrapped(npm: ["PORT=4000", "npm"])), .unquotable, "a first word that would set a variable")
        XCTAssertEqual(refusal(wrapped(npm: ["npm", String(repeating: "x", count: 400)])), .tooLong)
    }

    func testArgumentsThatAreMissingCutOrNotTextGiveNoCommand() {
        XCTAssertEqual(refusal(wrapped(npm: nil)), .unreadable)
        XCTAssertEqual(refusal(wrapped(npm: [])), .unreadable)
        XCTAssertEqual(refusal(wrapped(cut: true)), .unreadable)
        XCTAssertEqual(refusal(wrapped(lossy: true)), .unreadable)
    }

    func testAJobThatRunsElsewhereThanItsShellGivesNoCommand() {
        XCTAssertEqual(refusal(wrapped(npmCwd: "/home/alex/other")), .elsewhere)
        XCTAssertEqual(refusal(wrapped(npmCwd: nil)), .elsewhere)
        XCTAssertEqual(refusal(wrapped(shellCwd: nil)), .elsewhere)
        XCTAssertEqual(command(wrapped(npmCwd: "/home/alex/app/")), "npm run dev", "a trailing slash is the same folder")
    }

    func testAJobNotStartedByAShellOrThatIsTheShellItselfGivesNoCommand() {
        // An agent started the server: its parent is no shell.
        var o = wrapped()
        o.ancestry[3].name = "claude"
        XCTAssertEqual(refusal(o), .notFromShell)
        // A subshell `(npm run dev)` leads the group as a copy of the shell.
        XCTAssertEqual(refusal(wrapped(npm: ["-zsh"])), .notFromShell)
        var copy = wrapped(npm: ["zsh", "-i"])
        copy.ancestry[3].argv = ["zsh", "-i"]
        XCTAssertEqual(refusal(copy), .notFromShell)
        // The holder leads its own group and nothing above it is in the chain.
        let alone = PortOwner(pid: 77, pgid: 77, ttyForegroundPGID: nil, ancestry: [Link(pid: 77, ppid: 1, pgid: 77, name: "postgres", argv: ["postgres"])], jobMembers: 1)
        XCTAssertEqual(refusal(alone), .noJob)
        // The group's leader has gone: the chain holds no leader.
        var orphan = wrapped()
        orphan.ancestry.remove(at: 2)
        orphan.ancestry[1].ppid = 900
        XCTAssertEqual(refusal(orphan), .noJob)
    }

    func testAServerRunDirectlyIsItsOwnJob() {
        let o = PortOwner(pid: 500, pgid: 500, ttyForegroundPGID: 500, ancestry: [
            Link(pid: 500, ppid: 90, pgid: 500, name: "python3", argv: ["python3", "-m", "http.server", "8765"], cwd: "/srv/site"),
            Link(pid: 90, ppid: 1, pgid: 90, name: "-bash", argv: ["-bash"], cwd: "/srv/site"),
        ], jobMembers: 1)
        XCTAssertEqual(command(o), "python3 -m http.server 8765")
    }

    func testAPipelineOrAJobOfUnknownSizeGivesNoCommand() {
        XCTAssertEqual(command(wrapped(members: 1)), "npm run dev")
        XCTAssertEqual(refusal(wrapped(members: 2)), .notOneCommand, "`npm run dev | tee log`: the arguments are only the first part")
        XCTAssertEqual(refusal(wrapped(members: 0)), .notOneCommand)
        XCTAssertEqual(refusal(wrapped(members: nil)), .notOneCommand, "the computer doesn't say")
        // The same from a reply: 1, 2, null and a field that isn't there (an older Beacon).
        func reply(_ members: Any?) -> JSONObject {
            var r: JSONObject = ["pid": 500, "pgid": 500, "tty_foreground_pgid": 500, "foreground": true, "ancestry": [
                ["pid": 500, "ppid": 90, "pgid": 500, "sid": 90, "group_leader": true, "session_leader": false, "name": "python3", "path": "",
                 "argv": ["python3", "-m", "http.server"], "argv_lossy": false, "truncated": false, "cwd": "/srv/site"] as JSONObject,
                ["pid": 90, "ppid": 1, "pgid": 90, "sid": 90, "group_leader": true, "session_leader": true, "name": "bash", "path": "",
                 "argv": ["-bash"], "argv_lossy": false, "truncated": false, "cwd": "/srv/site"] as JSONObject,
            ]]
            if let members { r["job_members"] = members }
            return r
        }
        XCTAssertEqual(PortOwner(reply(1))?.jobMembers, 1)
        XCTAssertEqual(PortOwner(reply(1)).flatMap(command), "python3 -m http.server")
        XCTAssertEqual(PortOwner(reply(2)).flatMap(refusal), .notOneCommand)
        XCTAssertNil(PortOwner(reply(NSNull()))?.jobMembers)
        XCTAssertEqual(PortOwner(reply(NSNull())).flatMap(refusal), .notOneCommand)
        XCTAssertEqual(PortOwner(reply(nil)).flatMap(refusal), .notOneCommand)
        XCTAssertNotNil(PortOwner(reply(nil)), "the rest of the answer still serves Stop")
    }

    // MARK: Restart's steps

    func testARestartGoesThroughItsStepsInOrder() {
        var r = PortRestart()
        XCTAssertNil(r.mayWrite)
        XCTAssertEqual(r.take(.confirmed), .revealing)
        XCTAssertEqual(r.take(.checked(same: true)), .revealing)
        XCTAssertNil(r.mayWrite, "nothing is typed before the pane shows")
        XCTAssertEqual(r.take(.paneReady(true)), .stopping)
        XCTAssertEqual(r.mayWrite, .interrupt)
        XCTAssertEqual(r.take(.stopped(true)), .waitingForShell)
        XCTAssertNil(r.mayWrite)
        XCTAssertEqual(r.take(.shellBack(true)), .typing)
        XCTAssertEqual(r.mayWrite, .command)
        XCTAssertEqual(r.take(.typed(true)), .waitingForPort)
        XCTAssertNil(r.mayWrite)
        XCTAssertTrue(r.holdsRow)
        XCTAssertEqual(r.take(.portBack(true)), .done)
        XCTAssertTrue(r.isOver)
        XCTAssertFalse(r.holdsRow)
    }

    func testEveryFailureEndsItAndNothingIsTypedAfter() {
        let runs: [([PortRestart.Event], PortRestart.Failure)] = [
            ([.confirmed, .checked(same: false)], .changed),
            ([.confirmed, .paneReady(false)], .paneNotReady),
            ([.confirmed, .paneReady(true), .stopped(false)], .notStopped),
            ([.confirmed, .paneReady(true), .stopped(true), .shellBack(false)], .stillRunning),
            ([.confirmed, .paneReady(true), .stopped(true), .shellBack(true), .typed(false)], .notTyped),
            ([.confirmed, .paneReady(true), .stopped(true), .shellBack(true), .typed(true), .portBack(false)], .noPort),
        ]
        for (events, failure) in runs {
            var r = PortRestart()
            for e in events { r.take(e) }
            XCTAssertEqual(r.step, .failed(failure))
            XCTAssertNil(r.mayWrite)
            // A late answer moves nothing.
            for late in [PortRestart.Event.confirmed, .paneReady(true), .stopped(true), .shellBack(true), .typed(true), .portBack(true)] {
                XCTAssertEqual(r.take(late), .failed(failure))
                XCTAssertNil(r.mayWrite)
            }
        }
    }

    func testAnEventOutOfOrderChangesNothing() {
        var r = PortRestart()
        XCTAssertEqual(r.take(.shellBack(true)), .confirming, "the command is never typed without the steps before it")
        XCTAssertEqual(r.take(.typed(true)), .confirming)
        r.take(.confirmed)
        XCTAssertEqual(r.take(.shellBack(true)), .revealing)
        XCTAssertEqual(r.take(.stopped(true)), .revealing, "no interrupt counts before the pane is ready")
        r.take(.paneReady(true))
        XCTAssertEqual(r.take(.shellBack(true)), .stopping, "the shell isn't taken as back before the interrupt left")
    }

    // MARK: Open in Browser

    func testAShareIsOnlyAPlainWebAddress() throws {
        let s = try XCTUnwrap(PortShare(["url": "http://desk.example.ts.net:3000", "ip_url": "http://100.64.0.7:3000", "port": 3000,
                                         "same_port": true, "idle_seconds": 1800, "waiting_seconds": 600]))
        XCTAssertEqual(s.url.absoluteString, "http://desk.example.ts.net:3000")
        XCTAssertEqual(s.idle, 1800)
        XCTAssertEqual(s.page("/admin?x=1#top")?.absoluteString, "http://desk.example.ts.net:3000/admin?x=1#top")
        XCTAssertEqual(s.page("")?.absoluteString, "http://desk.example.ts.net:3000/")
        XCTAssertNotNil(PortShare(["url": "http://[fd7a:115c:a1e0::7]:41000/"]))
        for bad in ["", "desk.example.ts.net:3000", "https://desk.example.ts.net:3000", "file:///etc/hosts", "http://desk.example.ts.net",
                    "http://user:pw@desk.example.ts.net:3000", "http://desk.example.ts.net:3000/path", "http://desk.example.ts.net:3000/?q=1",
                    "javascript:alert(1)", "http://:3000"] {
            XCTAssertNil(PortShare(["url": bad]), bad)
        }
        XCTAssertNil(PortShare(["ip_url": "http://100.64.0.7:3000"]))
    }

    func testTheAppStopsCountingOnAShareBeforeTheComputerEndsIt() throws {
        let asked = Date(timeIntervalSince1970: 1000)
        let s = try XCTUnwrap(PortShare(["url": "http://desk.example.ts.net:3000", "idle_seconds": 1800]))
        XCTAssertEqual(s.knownUntil(asked: asked), asked.addingTimeInterval(1740))
        let none = try XCTUnwrap(PortShare(["url": "http://desk.example.ts.net:3000"]))
        XCTAssertEqual(none.knownUntil(asked: asked), asked, "a reply that names no time is good for this one open only")
    }

    func testWhichAnswersTakeOpenInBrowserAway() {
        for code in ["not_supported", "not_registered", "not_your_phone"] {
            XCTAssertEqual(PortBeaconAnswer.share(code: code, unknownAction: false), .hide, code)
        }
        XCTAssertEqual(PortBeaconAnswer.share(code: "not_available", unknownAction: false), .hideUntilStatus,
                       "the computer said it could: it may say so again")
        for code in ["not_listening", "busy", "failed", "refused", "bad_request", "timeout", ""] {
            XCTAssertEqual(PortBeaconAnswer.share(code: code, unknownAction: false), .keep, code)
        }
        XCTAssertEqual(PortBeaconAnswer.share(code: "", unknownAction: true), .hide, "an older Beacon")
    }

    func testWhichAnswersMeanTheBeaconCantNameProcesses() {
        for code in ["not_supported", "not_registered", "refused"] {
            XCTAssertTrue(PortBeaconAnswer.ownerMissing(code: code, unknownAction: false), code)
        }
        for code in ["not_available", "bad_request", "timeout", ""] {
            XCTAssertFalse(PortBeaconAnswer.ownerMissing(code: code, unknownAction: false), code)
        }
        XCTAssertTrue(PortBeaconAnswer.ownerMissing(code: "", unknownAction: true))
    }

    // MARK: The phone's address

    func testThePhonesTailnetAddressIsReadFromItsTunnel() {
        let tail: UInt32 = 0x6440_0007  // 100.64.0.7
        let six: [UInt8] = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7]
        XCTAssertEqual(TailnetAddress.pick([.v4(interface: "en0", 0xC0A8_0114), .v6(six), .v4(interface: "utun4", tail)]), "100.64.0.7")
        XCTAssertEqual(TailnetAddress.pick([.v6(six)]), "fd7a:115c:a1e0:0:0:0:0:7")
        XCTAssertEqual(TailnetAddress.pick([.v4(interface: "utun4", 0x647F_FFFE)]), "100.127.255.254")
    }

    func testAPhoneWithoutATailnetAddressHasNone() {
        XCTAssertNil(TailnetAddress.pick([]))
        XCTAssertNil(TailnetAddress.pick([.v4(interface: "en0", 0xC0A8_0114), .v4(interface: "utun2", 0x0A00_0001)]))
        XCTAssertNil(TailnetAddress.pick([.v4(interface: "pdp_ip0", 0x6440_0007)]), "the same range from a cellular network is no tailnet")
        XCTAssertNil(TailnetAddress.pick([.v4(interface: "utun4", 0x6480_0001)]), "100.128.0.1 is outside the range")
        XCTAssertNil(TailnetAddress.pick([.v6([0xfd, 0x00, 0x11, 0x5c, 0xa1, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 7])]))
        XCTAssertNil(TailnetAddress.pick([.v6([0xfd, 0x7a])]))
    }
}
