import XCTest
@testable import RexKit

/// When the app may say that the way to the computers, and not a computer, is down: the rule
/// (`TunnelSuspicion`), the facts the hosts give it, and the probe's line in the log.
@MainActor
final class TunnelSuspicionTests: XCTestCase {
    private typealias Host = TunnelSuspicion.Host

    private func suspected(_ hosts: [TunnelSuspicion.Host], breaker: Bool = true, path: Bool = true) -> Bool {
        TunnelSuspicion.suspected(breakerOpen: breaker, pathSatisfied: path, hosts: hosts)
    }

    // MARK: All the computers, one computer, a refusal

    func testEveryComputerSilentIsTheTunnelAndOneComputerIsNot() {
        XCTAssertTrue(suspected([.unanswered, .unanswered]))
        XCTAssertTrue(suspected([.unanswered, .unanswered, .unanswered]))
        XCTAssertFalse(suspected([.unanswered]), "one computer that is off is that computer")
        XCTAssertFalse(suspected([.unanswered, .unknown]))
        XCTAssertFalse(suspected([]))
    }

    func testAComputerThatIsUpOrThatAnsweredShowsTheWayWorks() {
        XCTAssertFalse(suspected([.unanswered, .unanswered, .up]))
        XCTAssertFalse(suspected([.unanswered, .unanswered, .answered]), "a refusal came back through the tunnel")
        XCTAssertFalse(suspected([.answered, .answered]))
    }

    func testAComputerWhoseRetriesStoppedSaysNothingEitherWay() {
        XCTAssertTrue(suspected([.unanswered, .unanswered, .unknown]))
    }

    func testNotWithoutTheBreakerOrWithoutANetwork() {
        XCTAssertFalse(suspected([.unanswered, .unanswered], breaker: false))
        XCTAssertFalse(suspected([.unanswered, .unanswered], path: false), "no network is said as no network")
    }

    func testOnlyASilentComputersMessageGivesWay() {
        XCTAssertTrue(TunnelSuspicion.covers(.unanswered))
        for host in [Host.up, .answered, .unknown] { XCTAssertFalse(TunnelSuspicion.covers(host)) }
    }

    // MARK: How long, and only in front

    func testItShowsAfterTenSecondsInFrontAndNotBefore() {
        XCTAssertEqual(TunnelSuspicion.showAfter, 10)
        var s = TunnelSuspicion()
        XCTAssertEqual(s.update(suspected: true, foreground: true, now: 100), 10)
        XCTAssertFalse(s.shows)
        XCTAssertEqual(s.update(suspected: true, foreground: true, now: 104), 6, "asked again early: the count goes on")
        XCTAssertFalse(s.shows)
        XCTAssertNil(s.update(suspected: true, foreground: true, now: 110))
        XCTAssertTrue(s.shows)
        XCTAssertNil(s.update(suspected: true, foreground: true, now: 500))
        XCTAssertTrue(s.shows, "it stays while the suspicion holds")
    }

    func testItClearsAtOnceWhenTheSuspicionEnds() {
        var s = TunnelSuspicion()
        _ = s.update(suspected: true, foreground: true, now: 0)
        _ = s.update(suspected: true, foreground: true, now: 10)
        XCTAssertTrue(s.shows)
        XCTAssertNil(s.update(suspected: false, foreground: true, now: 10.01))
        XCTAssertFalse(s.shows, "a welcome: gone in the same moment")
        XCTAssertEqual(s.update(suspected: true, foreground: true, now: 11), 10, "and the count starts over")
    }

    func testASuspicionThatEndsBeforeTenSecondsNeverShows() {
        var s = TunnelSuspicion()
        _ = s.update(suspected: true, foreground: true, now: 0)
        _ = s.update(suspected: false, foreground: true, now: 9)
        XCTAssertNil(s.update(suspected: false, foreground: true, now: 30))
        XCTAssertFalse(s.shows)
    }

    func testTheBackgroundClearsItAndTheReturnCountsFromTheStart() {
        var s = TunnelSuspicion()
        _ = s.update(suspected: true, foreground: true, now: 0)
        XCTAssertNil(s.update(suspected: true, foreground: false, now: 5))
        XCTAssertNil(s.update(suspected: true, foreground: false, now: 600), "nothing waits in the background")
        XCTAssertFalse(s.shows)
        XCTAssertEqual(s.update(suspected: true, foreground: true, now: 700), 10)
        XCTAssertFalse(s.shows)
        _ = s.update(suspected: true, foreground: true, now: 710)
        XCTAssertTrue(s.shows)
        _ = s.update(suspected: true, foreground: false, now: 711)
        XCTAssertFalse(s.shows)
    }

    // MARK: What the hosts say

    private let refused = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotConnectToHost,
                                  userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))])

    @MainActor
    private final class Rig {
        let clock = FakeControlClock()
        let governor = ReconnectGovernor(policy: .standard)
        var controls: [RexControl] = []
        var sockets: [FakeControlSockets] = []

        init(hosts: Int) {
            clock.yields = 40
            for n in 0..<hosts {
                let s = FakeControlSockets()
                sockets.append(s)
                controls.append(RexControl(address: "https://host\(n).example.ts.net",
                                           client: ClientInfo(name: "test", version: "0", label: "test"),
                                           clock: clock, sockets: s.factory, governor: governor, random: { 0.5 }))
            }
        }

        func connectAll() async {
            for (c, s) in zip(controls, sockets) {
                Task { @MainActor in try? await c.connect() }
                await pump(40)
                s.last.welcome()
                await pump(40)
            }
        }

        var suspected: Bool {
            TunnelSuspicion.suspected(breakerOpen: governor.breakerOpen, pathSatisfied: true, hosts: governor.tunnelHosts)
        }

        func stop() async {
            for c in controls { c.disconnect() }
            await pump(40)
        }
    }

    func testHostsThatAllGoSilentTogetherAreSuspectedAndAWelcomeEndsItAtOnce() async {
        let rig = Rig(hosts: 3)
        await rig.connectAll()
        XCTAssertEqual(rig.governor.tunnelHosts, [.up, .up, .up])
        XCTAssertFalse(rig.suspected)

        rig.sockets[0].last.failReceive()
        await pump(40)
        XCTAssertEqual(rig.controls[0].tunnelFact, .unanswered)
        XCTAssertFalse(rig.suspected, "one host down: its own message")

        rig.sockets[1].last.failReceive()
        await pump(40)
        XCTAssertFalse(rig.governor.breakerOpen, "the third is still up: the way works")
        XCTAssertFalse(rig.suspected)

        rig.sockets[2].last.failReceive()
        await pump(40)
        XCTAssertTrue(rig.governor.breakerOpen)
        XCTAssertEqual(Set(rig.governor.tunnelHosts), [.unanswered])
        XCTAssertTrue(rig.suspected)

        // The host that is tried stays silent while its attempt runs.
        var waited = 0
        while !rig.controls.contains(where: { $0.state == .connecting }), waited < 400 {
            await rig.clock.advance(by: 1)
            waited += 1
        }
        let i = rig.controls.firstIndex { $0.state == .connecting }!
        XCTAssertEqual(rig.controls[i].tunnelFact, .unanswered)
        XCTAssertTrue(rig.suspected)

        rig.sockets[i].last.welcome()
        await pump(40)
        XCTAssertFalse(rig.governor.breakerOpen)
        XCTAssertFalse(rig.suspected, "in the turn of the welcome")
        await rig.stop()
    }

    /// The facts are as they are after a failure when its state change is told, and the breaker
    /// has closed when a welcome's is: whoever asks from `onStateChange` or `onBreaker` gets the
    /// answer of that moment, with no need to ask again a turn later.
    func testTheAnswerIsRightInTheTurnOfEachChange() async {
        let rig = Rig(hosts: 2)
        await rig.connectAll()
        var seen: [Bool] = []
        for c in rig.controls { c.onStateChange = { _ in seen.append(rig.suspected) } }
        rig.governor.onBreaker = { _ in seen.append(rig.suspected) }
        rig.sockets[0].last.failReceive()
        rig.sockets[1].last.failReceive()
        await pump(40)
        XCTAssertEqual(seen.last, true)
        XCTAssertTrue(seen.contains(true))
        var waited = 0
        while !rig.controls.contains(where: { $0.state == .connecting }), waited < 400 {
            await rig.clock.advance(by: 1)
            waited += 1
        }
        seen = []
        let i = rig.controls.firstIndex { $0.state == .connecting }!
        rig.sockets[i].last.welcome()
        await pump(40)
        XCTAssertFalse(seen.isEmpty)
        XCTAssertTrue(seen.allSatisfy { !$0 }, "from the breaker's closing on, no one is told it is suspected")
        await rig.stop()
    }

    /// Every computer stays away until each is dormant: the breaker closes with the last one,
    /// and the tunnel is no longer what is said. Each computer is asleep by itself from then on.
    func testWhenEveryHostHasGoneDormantTheTunnelIsNoLongerSuspected() async {
        let rig = Rig(hosts: 2)
        await rig.connectAll()
        rig.sockets[0].last.failReceive()
        rig.sockets[1].last.failReceive()
        await pump(40)
        XCTAssertTrue(rig.governor.breakerOpen)
        XCTAssertTrue(rig.suspected)

        var seconds = 0, suspectedWhileOpen = true
        while rig.governor.breakerOpen, seconds < 7200 {
            for (c, s) in zip(rig.controls, rig.sockets) where c.state == .connecting && s.last.isWaitingToReceive {
                s.last.failReceive()
            }
            await pump(40)
            if rig.governor.breakerOpen, !rig.suspected { suspectedWhileOpen = false }
            await rig.clock.advance(by: 1)
            seconds += 1
        }
        XCTAssertTrue(suspectedWhileOpen, "while the breaker is open and no one answers, it stays suspected")
        XCTAssertFalse(rig.governor.breakerOpen, "the last host that was tried went dormant")
        XCTAssertTrue(rig.controls.allSatisfy(\.dormant))
        XCTAssertEqual(rig.governor.tunnelHosts, [.unanswered, .unanswered], "still silent, both of them")
        XCTAssertFalse(rig.suspected, "but each is asleep by itself now")

        // A dormant host that times out again opens nothing.
        for _ in 0..<1300 {
            for (c, s) in zip(rig.controls, rig.sockets) where c.state == .connecting && s.last.isWaitingToReceive {
                s.last.failReceive()
            }
            await pump(40)
            XCTAssertFalse(rig.suspected)
            await rig.clock.advance(by: 1)
        }
        await rig.stop()
    }

    func testAHostThatAnswersEndsItAndAStoppedOneSaysNothing() async {
        let rig = Rig(hosts: 3)
        await rig.connectAll()
        rig.sockets[0].last.failReceive()
        rig.sockets[1].last.failReceive()
        rig.sockets[2].last.failReceive()
        await pump(40)
        XCTAssertTrue(rig.suspected)
        // The host that is tried is refused: an answer came back through the tunnel.
        var waited = 0
        while !rig.controls.contains(where: { $0.state == .connecting }), waited < 400 {
            await rig.clock.advance(by: 1)
            waited += 1
        }
        let i = rig.controls.firstIndex { $0.state == .connecting }!
        rig.sockets[i].last.failReceive(refused)
        await pump(40)
        XCTAssertEqual(rig.controls[i].tunnelFact, .answered)
        XCTAssertFalse(rig.governor.breakerOpen)
        XCTAssertFalse(rig.suspected, "a refusal is not the tunnel")
        XCTAssertFalse(TunnelSuspicion.covers(rig.controls[i].tunnelFact))

        // A TLS failure is an answer too.
        let tls = Rig(hosts: 2)
        await tls.connectAll()
        tls.sockets[0].last.failReceive()
        tls.sockets[1].last.failReceive(URLError(.secureConnectionFailed))
        await pump(40)
        XCTAssertEqual(tls.controls[1].tunnelFact, .answered)
        XCTAssertFalse(tls.suspected)

        // Turned away: retries stop, and it says nothing about the way.
        let denied = Rig(hosts: 3)
        await denied.connectAll()
        denied.sockets[2].last.response = HTTPURLResponse(url: URL(string: "https://host2.example.ts.net")!,
                                                          statusCode: 403, httpVersion: nil, headerFields: nil)
        denied.sockets[2].last.failReceive(URLError(.badServerResponse))
        await pump(40)
        XCTAssertTrue(denied.controls[2].retryStopped)
        XCTAssertEqual(denied.controls[2].tunnelFact, .unknown)
        denied.sockets[0].last.failReceive()
        denied.sockets[1].last.failReceive()
        await pump(40)
        XCTAssertTrue(denied.suspected)
        XCTAssertFalse(TunnelSuspicion.covers(denied.controls[2].tunnelFact), "its own message stays")
        await rig.stop()
        await tls.stop()
        await denied.stop()
    }

    func testAHostThatIsStoppedByTheAppIsLeftOut() async {
        let rig = Rig(hosts: 3)
        await rig.connectAll()
        rig.controls[2].disconnect()
        await pump(40)
        XCTAssertEqual(rig.governor.tunnelHosts, [.up, .up])
        rig.sockets[0].last.failReceive()
        rig.sockets[1].last.failReceive()
        await pump(40)
        XCTAssertTrue(rig.suspected)
        await rig.stop()
    }

    // MARK: The probe's line

    func testTheProbeIsOneLineOfNumbersInTheLog() throws {
        let yes = ConnectionEvent.tunnelProbe(reachable: true, milliseconds: 12)
        XCTAssertEqual(yes.kind, .probe)
        XCTAssertEqual(yes.summary, "probe tailscale reachable=yes after=12ms")
        XCTAssertEqual(ConnectionEvent.tunnelProbe(reachable: false, milliseconds: 3000).summary,
                       "probe tailscale reachable=no after=3000ms")
        let back = try XCTUnwrap(ConnectionEvent(bytes: yes.encoded()))
        XCTAssertEqual(back, yes)
        XCTAssertEqual(yes.encoded().count, ConnectionEvent.size)
    }

    func testTheProbesResultGoesToTheAppsRingAndComesBackFromTheFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clog-probe-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("connections.clog")
        let log = ConnectionLog(file: file)
        log.record(.breaker(open: true))
        log.record(.tunnelProbe(reachable: false, milliseconds: 3000))
        _ = await log.written()
        let text = await ConnectionLog(file: file).export(servers: [])
        XCTAssertTrue(text.contains("breaker open"), text)
        XCTAssertTrue(text.contains("probe tailscale reachable=no after=3000ms"), text)
    }
}
