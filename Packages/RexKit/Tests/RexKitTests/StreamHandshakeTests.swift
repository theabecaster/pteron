import XCTest
@testable import RexKit

/// The wait of a handshake's deadline, ended by hand: a test says when the deadline passes.
@MainActor
final class DeadlineGate {
    /// Every deadline asked for, in order.
    private(set) var asked: [Duration] = []
    private var waiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var nextID = 0

    var sleep: @MainActor (Duration) async -> Void {
        { [self] d in
            asked.append(d)
            nextID += 1
            let id = nextID
            await withTaskCancellationHandler {
                await withCheckedContinuation { waiters[id] = $0 }
            } onCancel: {
                // As `Task.sleep`: a cancelled wait ends at once.
                Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume() }
            }
        }
    }

    /// Deadlines that still wait.
    var waiting: Int { waiters.count }

    /// Every deadline that still waits passes now.
    func pass() {
        let w = waiters
        waiters = [:]
        for (_, c) in w { c.resume() }
    }
}

/// A data socket's handshake does not wait for ever: a terminal stream's RESUME and HELLO, a
/// file's socket, and a tunnel's. What follows a RESUME that got no answer: the token is kept,
/// the fence stays up, and the control connection says whether the host is there.
@MainActor
final class StreamHandshakeTests: XCTestCase {
    typealias Sink = StreamSnapshotHandoffTests.Sink

    private var streams: [TerminalStream] = []

    private struct Rig {
        let stream: TerminalStream
        let control: RexControl
        let sink: Sink
        let log: SleepLog
        let gate: DeadlineGate
    }

    private func rig(_ link: FakeLink, cellular: Bool = false) -> Rig {
        let control = RexControl(address: "http://127.0.0.1:9", client: ClientInfo(name: "test", version: "0", label: "test"))
        if cellular { control.pathChanged(satisfied: true, expensive: true, interfaceChanged: false) }
        let stream = TerminalStream(control: control, link: link, sessionID: "session:test", blockID: "block:test")
        let sink = Sink()
        stream.sink = sink
        let log = SleepLog()
        log.attach(to: stream)
        let gate = DeadlineGate()
        stream.handshakeSleep = gate.sleep
        streams.append(stream)
        return Rig(stream: stream, control: control, sink: sink, log: log, gate: gate)
    }

    /// A stream that is live with its screen current, then its data socket drops and the RESUME
    /// that follows gets no answer.
    private func silentResume(_ link: FakeLink, cellular: Bool = false) async -> Rig {
        let r = rig(link, cellular: cellular)
        r.stream.start()
        await catchUp(r.stream, link)
        link.sockets[0].push([1, 2, 3, 4, 5])
        await settle()
        link.plans = [.silent]
        link.sockets[0].drop()
        let resuming = await eventually { link.sockets.count == 2 && link.sockets[1].isResume }
        XCTAssertTrue(resuming)
        XCTAssertTrue(r.stream.isFenced)
        return r
    }

    // MARK: A RESUME that never answers

    func testAResumeThatNeverAnswersIsAbortedAtTheDeadlineKeepsItsTokenAndWaitsForTheControlConnection() async {
        let link = FakeLink()
        // The control connection's answer to the check that follows is held by the test.
        var answer: CheckedContinuation<Void, Never>?
        link.onPing = { await withCheckedContinuation { answer = $0 } }
        let r = await silentResume(link)
        XCTAssertEqual(r.gate.asked, [.seconds(10), .seconds(10)], "one deadline per handshake, the connect deadline")
        XCTAssertEqual(r.gate.waiting, 1, "the first handshake's ended with its welcome")

        r.gate.pass()
        let asked = await eventually { answer != nil }
        XCTAssertTrue(asked, "the control connection is asked whether the host is there")
        XCTAssertTrue(link.sockets[1].aborted, "dropped with no close frame")
        XCTAssertFalse(link.sockets[1].closed, "no status 1000: the server keeps the stream")
        await settle()
        XCTAssertEqual(link.sockets.count, 2, "the stream asks the host for nothing by itself")
        XCTAssertTrue(r.stream.waitingForControl)
        XCTAssertTrue(r.stream.isFenced, "the fence stays up")
        XCTAssertEqual(link.written, [])
        XCTAssertEqual(r.sink.statuses.last, .reconnecting)
        XCTAssertEqual(link.count("data.connect"), 1)

        // Typed while the stream is away: held, not sent. (Held keys live a second in the app;
        // here they live long enough for a slow test machine.)
        r.log.real.insert(.seconds(30))
        r.stream.fence.timing.heldLife = .seconds(30)
        XCTAssertTrue(r.stream.send(text: "x"))
        await settle()
        XCTAssertEqual(link.written, [])

        // The control connection answers: the host is there. One more RESUME, with the token
        // and the byte count kept, after the pause that follows a failed start.
        answer?.resume()
        let live = await eventually { r.sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(link.sockets.count, 3)
        XCTAssertTrue(link.sockets[2].isResume)
        XCTAssertEqual(link.sockets[2].resumeCount, link.sockets[1].resumeCount)
        XCTAssertEqual(Array(link.sockets[2].sent[0][1...16]), Array(link.sockets[1].sent[0][1...16]), "the same token")
        XCTAssertEqual(link.count("data.connect"), 1, "no ticket: not a fresh start")
        XCTAssertEqual(r.log.backoffs.filter { $0 != .seconds(30) }, [.seconds(3)])
        XCTAssertFalse(r.stream.waitingForControl)

        // The stream is back with only the bytes it missed, so the screen is exact: the held
        // key goes out, once.
        let sent = await eventually { link.written == ["x"] }
        XCTAssertTrue(sent)
        await settle()
        XCTAssertEqual(link.written, ["x"], "never sent again")
        XCTAssertFalse(r.stream.isFenced)
    }

    func testWithNoPongFromTheControlConnectionTheStreamWaitsForItsWelcome() async {
        let link = FakeLink()
        link.onPing = { throw URLError(.networkConnectionLost) }
        let r = await silentResume(link)
        r.gate.pass()
        let aborted = await eventually { link.sockets[1].aborted }
        XCTAssertTrue(aborted)
        await settle()
        XCTAssertEqual(link.sockets.count, 2)
        XCTAssertTrue(r.stream.waitingForControl)
        XCTAssertEqual(r.log.backoffs, [], "no timer of the stream's own runs")

        // The host is dropped and comes back: its welcome resumes the stream.
        link.disconnect()
        link.connect()
        let live = await eventually { r.sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(link.sockets.count, 3)
        XCTAssertTrue(link.sockets[2].isResume)
        XCTAssertEqual(link.count("data.connect"), 1)
    }

    func testAnAnswerJustBeforeTheDeadlineEndsIt() async {
        let link = FakeLink()
        let r = await silentResume(link)
        link.sockets[1].push(FakeLink.welcome())
        let live = await eventually { r.sink.statuses.last == .live }
        XCTAssertTrue(live)
        let ended = await eventually { r.gate.waiting == 0 }
        XCTAssertTrue(ended, "the deadline's wait is cancelled with the first answer")
        r.gate.pass()
        await settle()
        XCTAssertFalse(link.sockets[1].aborted)
        XCTAssertFalse(link.sockets[1].closed)
        XCTAssertEqual(link.sockets.count, 2)
        XCTAssertEqual(r.sink.statuses.last, .live)
    }

    func testADeadlineOfAnEarlierStartDoesNothingToTheNextOne() async {
        let link = FakeLink()
        let r = await silentResume(link)
        // The stream starts over while the RESUME waits: its handshake belongs to the past.
        link.plans = [.silent]
        r.stream.restart()
        let fresh = await eventually { link.sockets.count == 3 && link.sockets[2].isHello }
        XCTAssertTrue(fresh)
        XCTAssertTrue(link.sockets[1].closed, "restart ends the old socket itself")
        let one = await eventually { r.gate.waiting == 1 }
        XCTAssertTrue(one, "the old deadline is gone, the new handshake has its own")
        XCTAssertFalse(link.sockets[2].closed)
        XCTAssertFalse(link.sockets[2].aborted)
        link.sockets[2].push(FakeLink.welcome())
        let live = await eventually { r.sink.statuses.last == .live }
        XCTAssertTrue(live)
        r.gate.pass()
        await settle()
        XCTAssertFalse(link.sockets[2].closed)
        XCTAssertFalse(link.sockets[2].aborted)
        XCTAssertEqual(r.sink.statuses.last, .live)
    }

    func testAStoppedStreamsDeadlineDoesNothing() async {
        let link = FakeLink()
        let r = await silentResume(link)
        r.stream.stop()
        await settle()
        r.gate.pass()
        await settle()
        XCTAssertEqual(link.sockets.count, 2)
        XCTAssertFalse(link.sockets[1].aborted)
        XCTAssertEqual(r.gate.waiting, 0)
    }

    // MARK: The background

    func testInTheBackgroundAHandshakeIsGivenUpNothingFiresAndTheReturnMakesAFreshOne() async {
        let link = FakeLink()
        let r = await silentResume(link)
        r.control.enteredBackground()
        let aborted = await eventually { link.sockets[1].aborted }
        XCTAssertTrue(aborted, "given up as the deadline would: no close frame, the token kept")
        XCTAssertFalse(link.sockets[1].closed)
        await settle()
        XCTAssertEqual(r.gate.waiting, 0, "no deadline waits in the background")
        r.gate.pass()
        await settle()
        XCTAssertEqual(link.sockets.count, 2, "and nothing opens there")
        XCTAssertTrue(r.stream.waitingForControl)
        XCTAssertTrue(r.stream.isFenced)
        XCTAssertEqual(r.log.backoffs, [])

        // Back, and the control connection is there again: one RESUME, with a deadline of its own.
        let before = r.gate.asked.count
        r.control.wake()
        link.connect()
        let live = await eventually { r.sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(link.sockets.count, 3)
        XCTAssertTrue(link.sockets[2].isResume)
        XCTAssertEqual(link.sockets[2].resumeCount, link.sockets[1].resumeCount)
        XCTAssertEqual(r.gate.asked.count, before + 1)
        XCTAssertEqual(link.count("data.connect"), 1)
    }

    // MARK: The numbers

    func testOnCellularTheDeadlineIsFifteenSeconds() async {
        let link = FakeLink()
        let r = await silentResume(link, cellular: true)
        XCTAssertEqual(r.gate.asked, [.seconds(15), .seconds(15)])
        XCTAssertEqual(ReconnectPolicy.standard.connectDeadline, 10)
        XCTAssertEqual(ReconnectPolicy.standard.connectDeadlineExpensive, 15)
    }

    // MARK: A HELLO that never answers

    func testAHelloThatNeverAnswersIsClosedAndIsAFailedStartLikeAnyOther() async {
        let link = FakeLink()
        link.plans = [.silent]
        let r = rig(link)
        r.stream.start()
        let opened = await eventually { link.sockets.count == 1 && link.sockets[0].isHello }
        XCTAssertTrue(opened)
        r.gate.pass()
        let again = await eventually { link.sockets.count == 2 }
        XCTAssertTrue(again)
        XCTAssertTrue(link.sockets[0].closed, "status 1000 ends a stream the server may have opened for it")
        XCTAssertFalse(link.sockets[0].aborted)
        XCTAssertEqual(r.log.backoffs, [.seconds(3)], "the pause after a failed start")
        XCTAssertTrue(link.sockets[1].isHello)
        XCTAssertEqual(link.count("data.connect"), 2)
        XCTAssertTrue(r.sink.statuses.contains { if case .failed = $0 { return true } else { return false } })
    }

    // MARK: A file's socket

    func testAnUploadWhoseHandshakeGetsNoAnswerIsLostAtTheDeadlineNotLeftWaiting() async {
        let link = FakeLink()
        link.replies["com.superlogical.terminal.upload_begin"] = ["ticket": "AAECAwQFBgcICQoLDA0ODw", "expires_in_ms": 60000]
        link.defaultPlan = .silent
        let uploader = FileUploader(link: link, sessionID: "session:s", blockID: "block:b")
        uploader.sleep = { _ in await Task.yield() }
        let gate = DeadlineGate()
        uploader.handshakeSleep = gate.sleep
        let data = Data([1, 2, 3])
        let task = Task { @MainActor () -> FileUploader.Failure? in
            do {
                try await uploader.send([FileUploader.Item(name: "a", size: 3) { DataSource(data) }], progress: { _, _ in })
                return nil
            } catch {
                return error as? FileUploader.Failure
            }
        }
        // Each try waits for its answer; the deadline ends each, and the batch is given up
        // at the limit of tries, as for any lost connection.
        for _ in 0...FileUploader.retryLimit {
            let waiting = await eventually { gate.waiting > 0 }
            XCTAssertTrue(waiting)
            gate.pass()
            await settle()
        }
        let failure = await task.value
        guard case .lost = failure else { return XCTFail("\(String(describing: failure))") }
        XCTAssertEqual(link.sockets.count, FileUploader.retryLimit + 1)
        XCTAssertTrue(link.sockets.allSatisfy(\.aborted))
        XCTAssertEqual(gate.asked.first, .seconds(10))
    }

    func testADownloadWhoseHandshakeGetsNoAnswerIsLostAtTheDeadline() async {
        let link = FakeLink()
        link.replies["com.superlogical.terminal.download_begin"] = [
            "ticket": "AAECAwQFBgcICQoLDA0ODw", "path": "/tmp/a", "name": "a", "size": 3,
        ]
        link.defaultPlan = .silent
        let d = FileDownloader(link: link, sessionID: "session:s", blockID: "block:b")
        let gate = DeadlineGate()
        d.handshakeSleep = gate.sleep
        let task = Task { @MainActor () -> FileDownloader.Failure? in
            do {
                _ = try await d.download(path: "a", limit: 100, write: { _ in }, progress: { _, _ in })
                return nil
            } catch {
                return error as? FileDownloader.Failure
            }
        }
        let waiting = await eventually { gate.waiting == 1 }
        XCTAssertTrue(waiting)
        gate.pass()
        let failure = await task.value
        guard case .lost = failure else { return XCTFail("\(String(describing: failure))") }
        XCTAssertTrue(link.sockets[0].aborted)
        XCTAssertEqual(gate.asked, [.seconds(10)])
    }

    // MARK: A tunnel's connection

    /// On real sockets: the server takes the connection and never answers the HELLO.
    func testATunnelConnectionWithNoWelcomeEndsAtItsDeadline() async throws {
        let server = try FakeRexServer()
        let address = await server.start()
        defer { server.stop() }
        let base = try XCTUnwrap(RexControl.webSocketBase(for: address))
        let session = TunnelSession(base: base, handshakeDeadline: { 0.4 }, gate: { true })
        defer { session.invalidate() }
        let began = ContinuousClock.now
        do {
            _ = try await session.open(ticket: "AAECAwQFBgcICQoLDA0ODw")
            XCTFail("a connection with no welcome opened")
        } catch {
            let took = ContinuousClock.now - began
            XCTAssertGreaterThanOrEqual(took, .milliseconds(350))
            XCTAssertLessThan(took, .seconds(8), "ended by the deadline, long before any system timeout")
        }
    }

    // MARK: A dead host's file socket (spec test 8)

    /// The control socket dies with no answer: a file's data socket to the same host, open and
    /// waiting, is dropped with it, as a terminal's and a tunnel's are.
    func testADeadControlSocketDropsAFilesDataSocketToo() async throws {
        let server = try FakeRexServer()
        let address = await server.start()
        defer { server.stop() }
        let real = RexControl(address: address, client: ClientInfo(name: "test", version: "0", label: "test"))
        try await real.connect()
        let socket = try real.openDataSocket(subprotocol: BytesStream.subprotocol)
        XCTAssertEqual(real.dataSocketsOpened, 1)
        // Nothing answers a file's HELLO here, so the socket waits.
        let waiting = Task { @MainActor () -> Bool in
            do {
                try await socket.send(Data([0x01]))
                _ = try await socket.receive()
                return false
            } catch {
                return true
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        real.dropForTesting(unreachable: true)
        let ended = expectation(description: "the file's socket ended")
        Task {
            let failed = await waiting.value
            XCTAssertTrue(failed)
            ended.fulfill()
        }
        await fulfillment(of: [ended], timeout: 3)
        real.disconnect()
    }
}
