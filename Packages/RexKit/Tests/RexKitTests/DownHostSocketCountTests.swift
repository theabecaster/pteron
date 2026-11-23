import XCTest
@testable import RexKit

/// Everything that could open a socket to a host, counted path by path, while the host is down
/// and while the app is in the background: the control connection, panes that were parked with a
/// RESUME token, a pane kept warm off screen, a port tunnel's dial for a page's request, the
/// Ports list's read, a folder listing, and a file's upload and download. Only the control
/// connection may ask a host that is down, on its schedule; the rest wait for its welcome, and
/// after the background for its verdict.
///
/// `PortForward` itself is the app's: `PortForwardTests` holds its side of this. Here its dial is
/// the same three steps it takes (the gate, the ticket, the socket).
@MainActor
final class DownHostSocketCountTests: XCTestCase {
    typealias Sink = StreamFenceTests.Sink

    /// One path's view of the control connection: connected when the real `RexControl` is, with
    /// every request that got past the connection's gate and every data socket asked for counted.
    /// A call is answered as a server would, so a path that is let through goes all the way.
    @MainActor
    final class PathLink: StreamLink {
        let control: RexControl
        private(set) var sockets: [FakeSocket] = []
        private(set) var callsReached = 0
        private(set) var callsRefused = 0

        init(_ control: RexControl) { self.control = control }

        var opened: Int { sockets.count }
        var isConnected: Bool { control.isConnected }
        var clientID: String? { control.clientID }
        // The real connection's count and waits, so that what a stream does with them is counted.
        var clientGeneration: Int { control.clientGeneration }
        func whenAttached(_ session: String, _ done: @escaping @MainActor (Bool) -> Void) -> Int? {
            control.whenAttached(session, done)
        }
        func cancelAttachWait(_ id: Int) { control.cancelAttachWait(id) }
        /// The next tickets are refused: the pane's session is not attached on this connection.
        var conflicts = 0
        func observeConnected(_ body: @escaping @MainActor () -> Bool) { control.observeConnected(body) }

        func call(_ method: String, _ payload: JSONObject?) async throws -> JSONObject {
            // As `RexControl.call`: unsent, before the socket, while there is no welcome.
            guard control.isConnected else {
                callsRefused += 1
                throw RexError.unsent("not connected")
            }
            callsReached += 1
            if method == "data.connect", conflicts > 0 {
                conflicts -= 1
                throw RexError(code: "conflict", message: "stream is not attached to session", status: 409)
            }
            return ["ticket": "AAECAwQFBgcICQoLDA0ODw", "size": 1]
        }

        func ping() async throws {
            guard control.isConnected else { throw RexError.unsent("not connected") }
        }

        func openDataSocket(subprotocol: String) throws -> any StreamSocket {
            // Two hours: the server keeps a stream for a RESUME all through the test.
            let s = FakeSocket(.welcome(keepMs: 7_200_000))
            sockets.append(s)
            return s
        }
    }

    private var clock: FakeControlClock!
    private var controlSockets: FakeControlSockets!
    private var control: RexControl!
    private var sinks: [Sink] = []
    private var logs: [SleepLog] = []

    override func setUp() async throws {
        clock = FakeControlClock()
        clock.yields = 40
        controlSockets = FakeControlSockets()
        control = RexControl(address: "https://desk.example.ts.net",
                             client: ClientInfo(name: "test", version: "0", label: "test"),
                             clock: clock, sockets: controlSockets.factory, random: { 0.5 })
        sinks = []
        logs = []
    }

    override func tearDown() async throws {
        control.disconnect()
        await pump()
        control = nil
    }

    private func connect() async {
        let control = control!
        Task { @MainActor in try? await control.connect() }
        await pump()
        controlSockets.last.welcome()
        await pump()
        XCTAssertEqual(control.state, .connected)
    }

    /// A pane's stream, started and caught up: it has its WELCOME, and so a RESUME token.
    private func livePane(_ link: PathLink, block: String) async -> TerminalStream {
        let s = TerminalStream(control: control, link: link, sessionID: "session:1", blockID: block)
        let sink = Sink()
        sinks.append(sink)
        s.sink = sink
        let log = SleepLog()
        log.attach(to: s)
        logs.append(log)
        let before = link.opened
        s.start()
        let has = await eventually { link.opened == before + 1 }
        XCTAssertTrue(has, "no data socket")
        link.sockets.last?.push(Wire.opening)
        let current = await eventually { !s.isFenced }
        XCTAssertTrue(current, "the fence stayed up")
        return s
    }

    /// A page asks the tunnel to dial, as `PortForward.serve` does: the computer's gate, then
    /// the ticket, then the gate again and the data socket.
    private func pageRequest(_ link: PathLink) async {
        func gate() -> Bool { control.state == .connected && !control.holdsData }
        guard gate() else { return }
        guard (try? await link.call("data.connect", ["session_id": "session:1", "block_id": "block:dial"])) != nil,
              gate() else { return }
        _ = try? link.openDataSocket(subprotocol: BytesStream.subprotocol)
    }

    private func transfer(_ link: PathLink) async {
        let up = FileUploader(link: link, sessionID: "session:1", blockID: "block:0")
        up.sleep = { _ in await Task.yield() }
        let item = FileUploader.Item(name: "a.txt", size: 1) { DataSource(Data([1])) }
        try? await up.send([item], progress: { _, _ in })
        let down = FileDownloader(link: link, sessionID: "session:1", blockID: "block:0")
        _ = try? await down.download(path: "/srv/a.txt", limit: 1 << 20, write: { _ in })
    }

    func testAHostDownForAnHourThenAnHourInTheBackgroundIsAskedByTheControlConnectionAlone() async {
        await connect()
        let parkedLink = PathLink(control), warmLink = PathLink(control), tunnelLink = PathLink(control)
        let portsLink = PathLink(control), filesLink = PathLink(control), dirLink = PathLink(control)

        // Three panes that left the screen (parked, each with its RESUME token) and one kept warm.
        var parked: [TerminalStream] = []
        for n in 0..<3 { parked.append(await livePane(parkedLink, block: "block:\(n)")) }
        let warm = await livePane(warmLink, block: "block:warm")
        for s in parked { s.park() }
        XCTAssertTrue(parked.allSatisfy(\.isParked))
        // A pane whose ticket was refused until its session is attached: it waits for the attach.
        let attachLink = PathLink(control)
        attachLink.conflicts = 1
        let waiting = TerminalStream(control: control, link: attachLink, sessionID: "session:2", blockID: "block:waiting")
        let waitingSink = Sink()
        sinks.append(waitingSink)
        waiting.sink = waitingSink
        let waitingLog = SleepLog()
        waitingLog.attach(to: waiting)
        // Its cap does not pass by itself: the wait ends by what happens to the connection.
        waitingLog.held = [TerminalStream.attachWaitCap]
        logs.append(waitingLog)
        waiting.start()
        let waits = await eventually { self.control.attachWaits.waiting == 1 }
        XCTAssertTrue(waits, "the pane waits for its session's attach")
        XCTAssertEqual(attachLink.callsReached, 1)
        // The socket it opened beside that ticket is kept for the wait (`EarlySocket`): the
        // computer was up then.
        XCTAssertEqual(attachLink.opened, 1)
        XCTAssertEqual(attachLink.sockets.last?.closed, false)
        // A page's request while the computer is up dials, so the count below means something.
        await pageRequest(tunnelLink)
        XCTAssertEqual(tunnelLink.opened, 1)

        // The computer goes off: the control connection and the warm pane's socket are lost.
        controlSockets.last.failReceive()
        warmLink.sockets.last?.drop()
        await settle()
        let up = (control: controlSockets.count, parked: parkedLink.opened, warm: warmLink.opened,
                  tunnel: tunnelLink.opened, tunnelCalls: tunnelLink.callsReached,
                  paneCalls: parkedLink.callsReached + warmLink.callsReached)
        XCTAssertEqual(up.parked, 3)
        XCTAssertEqual(control.attachWaits.waiting, 0, "the wait for the attach ended with the connection")
        let attachCalls = attachLink.callsReached
        XCTAssertEqual(attachLink.sockets.last?.closed, true, "and its socket was closed with it")
        XCTAssertEqual(up.warm, 1, "the warm pane's RESUME waits for the control connection")

        /// What the app does with the host, once a minute: each parked pane is shown, woken,
        /// typed into and set aside again; the warm pane is woken and typed into; a page asks
        /// the tunnel to dial; the Ports list and a folder are read; a file is sent and one
        /// fetched.
        func poke() async {
            for s in parked {
                s.unpark()
                await pump(20)
                s.wake()
                _ = s.send(text: "x")
                s.park()
            }
            warm.wake()
            _ = warm.send(text: "x")
            await pageRequest(tunnelLink)
            _ = try? await portsLink.call("com.superlogical.terminal.ports", ["session_id": "session:1", "block_id": "block:0"])
            _ = try? await DirLister(link: dirLink, sessionID: "session:1", blockID: "block:0").list(path: "~")
            await transfer(filesLink)
            // And a file through the real connection and its real `openDataSocket`.
            let real = FileUploader(control: control, sessionID: "session:1", blockID: "block:0")
            real.sleep = { _ in await Task.yield() }
            try? await real.send([FileUploader.Item(name: "a.txt", size: 1) { DataSource(Data([1])) }], progress: { _, _ in })
            XCTAssertThrowsError(try control.openDataSocket(subprotocol: BytesStream.subprotocol), "the gate is in the socket's own code")
            XCTAssertThrowsError(try control.openDataSocket(subprotocol: "rex.data.terminal.v1"))
            await pump(40)
        }

        func assertNoDataPathOpened(_ when: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(parkedLink.opened - up.parked, 0, "parked panes, \(when)", file: file, line: line)
            XCTAssertEqual(warmLink.opened - up.warm, 0, "the warm pane, \(when)", file: file, line: line)
            XCTAssertEqual(tunnelLink.opened - up.tunnel, 0, "the port tunnel, \(when)", file: file, line: line)
            XCTAssertEqual(portsLink.opened, 0, "the Ports list, \(when)", file: file, line: line)
            XCTAssertEqual(dirLink.opened, 0, "the folder listing, \(when)", file: file, line: line)
            XCTAssertEqual(filesLink.opened, 0, "the file transfer, \(when)", file: file, line: line)
            XCTAssertEqual(attachLink.opened - 1, 0, "the pane that waited for its attach, \(when)", file: file, line: line)
            XCTAssertEqual(attachLink.callsReached - attachCalls, 0, "and its ticket, \(when)", file: file, line: line)
            XCTAssertEqual(control.attachWaits.waiting, 0, "nothing waits for an attach, \(when)", file: file, line: line)
            XCTAssertEqual(control.dataSocketsOpened, 0, "the real `openDataSocket`, \(when)", file: file, line: line)
            // And no request got as far as a socket either.
            XCTAssertEqual(parkedLink.callsReached + warmLink.callsReached - up.paneCalls, 0, file: file, line: line)
            XCTAssertEqual(tunnelLink.callsReached - up.tunnelCalls, 0, file: file, line: line)
            XCTAssertEqual(portsLink.callsReached + dirLink.callsReached + filesLink.callsReached, 0, file: file, line: line)
        }

        // One hour in the foreground. The host never answers: every attempt runs into its deadline.
        for _ in 0..<60 {
            await poke()
            await clock.advance(by: 60)
        }
        // The schedule after a drop: 0.5, 20.5, 150.5, 460.5 and 770.5 s, each 10 s long; dormant
        // at 780.5 s, then 1390.5, 2000.5, 2610.5 and 3220.5 s.
        XCTAssertEqual(controlSockets.count - up.control, 9, "the control connection, on its schedule")
        XCTAssertTrue(control.dormant)
        assertNoDataPathOpened("in the foreground")
        XCTAssertGreaterThanOrEqual(portsLink.callsRefused, 60, "the reads were refused before the socket")
        XCTAssertGreaterThanOrEqual(filesLink.callsRefused, 60)

        // One hour in the background, with the same things asked: nothing at all, of any kind.
        control.enteredBackground()
        let front = controlSockets.count
        for _ in 0..<60 {
            await poke()
            await clock.advance(by: 60)
        }
        XCTAssertEqual(controlSockets.count - front, 0, "no control attempt in the background")
        XCTAssertEqual(clock.waiting, 0, "and nothing waits to make one")
        assertNoDataPathOpened("in the background")
        for s in parked + [warm, waiting] { s.stop() }
        waitingLog.release(TerminalStream.attachWaitCap)
    }

    /// The computer is up, and the app comes back from the background with sockets that died
    /// there. No data path opens a socket in the background, nor at the return before the
    /// control connection has its verdict: here the pong on the socket that was up.
    func testAtTheReturnDataPathsWaitForThePongOfTheControlConnection() async {
        await connect()
        let parkedLink = PathLink(control), warmLink = PathLink(control), tunnelLink = PathLink(control)
        let parked = await livePane(parkedLink, block: "block:0")
        let warm = await livePane(warmLink, block: "block:warm")
        parked.park()

        control.enteredBackground()
        warmLink.sockets.last?.drop()
        await settle()
        await pageRequest(tunnelLink)
        XCTAssertEqual(warmLink.opened, 1, "no RESUME in the background")
        XCTAssertEqual(tunnelLink.opened + tunnelLink.callsReached, 0, "no dial in the background")

        control.wake()
        warm.wake()
        parked.unpark()
        await pageRequest(tunnelLink)
        await settle()
        XCTAssertEqual(warmLink.opened, 1, "back, but the connection has not answered")
        XCTAssertEqual(parkedLink.opened, 1)
        XCTAssertEqual(tunnelLink.opened + tunnelLink.callsReached, 0)
        XCTAssertEqual(controlSockets.count, 1)

        controlSockets.last.answerPing()
        let back = await eventually { warmLink.opened == 2 && parkedLink.opened == 2 }
        XCTAssertTrue(back, "the pong lets them go")
        XCTAssertTrue(warmLink.sockets[1].isResume)
        XCTAssertTrue(parkedLink.sockets[1].isResume, "the parked pane kept its token")
        await pageRequest(tunnelLink)
        XCTAssertEqual(tunnelLink.opened, 1)
        for s in [parked, warm] { s.stop() }
    }

    /// The same return, but the control connection died in the background too: its ping gets no
    /// pong, it is made again, and the data paths go with its fresh welcome, not before.
    func testAtTheReturnWithNoPongDataPathsWaitForTheFreshWelcome() async {
        await connect()
        let parkedLink = PathLink(control), warmLink = PathLink(control), tunnelLink = PathLink(control)
        let parked = await livePane(parkedLink, block: "block:0")
        let warm = await livePane(warmLink, block: "block:warm")
        parked.park()
        control.enteredBackground()
        warmLink.sockets.last?.drop()
        await settle()

        control.wake()
        warm.wake()
        parked.unpark()
        await clock.advance(by: 2.5)
        await pageRequest(tunnelLink)
        await settle()
        XCTAssertEqual(controlSockets.count, 2, "no pong: the control connection is made again")
        XCTAssertEqual(warmLink.opened + parkedLink.opened, 2, "and nothing else is opened meanwhile")
        XCTAssertEqual(tunnelLink.opened + tunnelLink.callsReached, 0)

        controlSockets.last.welcome()
        let back = await eventually { warmLink.opened == 2 && parkedLink.opened == 2 }
        XCTAssertTrue(back, "the welcome lets them go")
        for s in [parked, warm] { s.stop() }
    }

    // MARK: A dead control socket takes the host's other sockets with it

    /// A missed pong: the control socket is dead, and the pane's data socket is dropped in the
    /// same moment, with no close frame, so its token stays good. The fence is up as after any
    /// drop, nothing is opened while the host is away, and the welcome brings the pane back
    /// with a RESUME.
    func testAMissedPongDropsTheHostsStreamsAndTheWelcomeResumesThem() async {
        await connect()
        let link = PathLink(control)
        let s = await livePane(link, block: "block:0")
        await clock.advance(by: 30)
        XCTAssertEqual(controlSockets.last.pings, 1)
        XCTAssertFalse(link.sockets[0].aborted)
        await clock.advance(by: 10)
        XCTAssertEqual(control.state, .failed(.timedOut()), "no pong")
        XCTAssertTrue(link.sockets[0].aborted, "the data socket went with it")
        XCTAssertFalse(link.sockets[0].closed, "with no status 1000: the server keeps the stream")
        await settle()
        XCTAssertTrue(s.isFenced)
        XCTAssertEqual(link.opened, 1, "nothing is opened to a host that is away")
        await clock.advance(by: 0.5)
        XCTAssertEqual(controlSockets.count, 2)
        controlSockets.last.welcome()
        let back = await eventually { link.opened == 2 }
        XCTAssertTrue(back)
        XCTAssertTrue(link.sockets[1].isResume, "only the missing bytes")
        s.stop()
    }

    /// A server that closes the control connection with an answer is there: the panes' sockets
    /// are left alone.
    func testAnAnsweredCloseLeavesTheStreamsAlone() async {
        await connect()
        let link = PathLink(control)
        let s = await livePane(link, block: "block:0")
        controlSockets.last.closeCode = .policyViolation
        controlSockets.last.closeReason = Data("event backlog exceeded".utf8)
        controlSockets.last.failReceive()
        await pump()
        XCTAssertNotEqual(control.state, .connected)
        XCTAssertFalse(link.sockets[0].aborted)
        s.stop()
    }

    /// The tunnel side of the same, on real sockets: a session made by the control connection
    /// asks the host's gate before every connection, and a connection that is open or opening
    /// is dropped when the control socket dies.
    func testADeadControlSocketDropsTunnelConnectionsAndTheGateRefusesNewOnes() async throws {
        let server = try FakeRexServer()
        let address = await server.start()
        let real = RexControl(address: address, client: ClientInfo(name: "test", version: "0", label: "test"))
        try await real.connect()
        let session = try XCTUnwrap(real.makeTunnelSession())
        // Nothing answers the tunnel's HELLO here, so the connection stays opening.
        let opening = Task { try await session.open(ticket: "AAECAwQFBgcICQoLDA0ODw") }
        try await Task.sleep(for: .milliseconds(200))
        real.dropForTesting(unreachable: true)
        let ended = expectation(description: "the opening connection ended")
        Task {
            _ = await opening.result
            ended.fulfill()
        }
        await fulfillment(of: [ended], timeout: 3)
        do {
            _ = try await session.open(ticket: "AAECAwQFBgcICQoLDA0ODw")
            XCTFail("the gate let a tunnel through to a host that is down")
        } catch {
            XCTAssertEqual((error as? RexError)?.neverSent, true, "refused before any socket")
        }
        session.invalidate()
        real.invalidate()
        server.stop()
    }

    // MARK: The return on cellular

    /// Back on cellular with a live pane whose socket died in the background and says nothing.
    /// The control connection's pong may take 5 s there. The stream has no deadline of its own
    /// any more: it drops nothing and opens nothing until the control connection has answered,
    /// then gives up its silent socket and resumes.
    func testOnCellularALiveStreamOpensNothingBeforeTheControlConnectionsVerdict() async {
        await connect()
        control.pathChanged(satisfied: true, expensive: true, interfaceChanged: false)
        let link = PathLink(control)
        let s = await livePane(link, block: "block:0")
        control.enteredBackground()
        link.sockets[0].pingPlan = .silent
        control.wake()
        s.wake()
        // 4 s: past the stream's old 2.5 s, inside the 5 s the control connection has here.
        await clock.advance(by: 4)
        await settle()
        XCTAssertEqual(control.state, .connected)
        XCTAssertFalse(link.sockets[0].aborted, "the stream waits for the control connection's verdict")
        XCTAssertEqual(link.opened, 1, "and opens nothing before it")
        controlSockets.last.answerPing()
        let back = await eventually { link.opened == 2 }
        XCTAssertTrue(back, "the host is there: the silent socket is given up and the stream resumes")
        XCTAssertTrue(link.sockets[0].aborted)
        XCTAssertTrue(link.sockets[1].isResume)
        s.stop()
    }

    /// The same return when the control connection gets no pong either: at its 5 s the host is
    /// taken for away, the pane's socket goes with it, and nothing is opened until the welcome.
    func testOnCellularWithNoPongTheStreamIsDroppedWithTheControlSocketAndWaits() async {
        await connect()
        control.pathChanged(satisfied: true, expensive: true, interfaceChanged: false)
        let link = PathLink(control)
        let s = await livePane(link, block: "block:0")
        control.enteredBackground()
        link.sockets[0].pingPlan = .silent
        control.wake()
        s.wake()
        await clock.advance(by: 5)
        await settle()
        XCTAssertTrue(link.sockets[0].aborted)
        XCTAssertEqual(link.opened, 1)
        XCTAssertEqual(controlSockets.count, 2, "the control connection is made again")
        controlSockets.last.welcome()
        let back = await eventually { link.opened == 2 }
        XCTAssertTrue(back)
        XCTAssertTrue(link.sockets[1].isResume)
        s.stop()
    }

    /// The gate is at the stream itself: with the control connection down, a stream asks for no
    /// data socket even when its start is forced.
    func testAStreamAsksForNoDataSocketWithoutTheWelcome() async {
        let link = PathLink(control)
        let s = TerminalStream(control: control, link: link, sessionID: "session:1", blockID: "block:0")
        let sink = Sink()
        s.sink = sink
        let log = SleepLog()
        log.attach(to: s)
        s.start()
        for _ in 0..<20 {
            s.restart()
            s.wake()
            await pump(40)
        }
        XCTAssertEqual(link.opened, 0)
        XCTAssertEqual(link.callsReached, 0)
        s.stop()
        withExtendedLifetime((sink, log)) {}
    }
}
