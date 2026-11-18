import XCTest
@testable import RexKit

/// Who restarts a stream, and how often: `RexControl` owns the retries of the control connection,
/// and the stream makes one start when it is told the connection is back.
@MainActor
final class StreamReconnectTests: XCTestCase {
    typealias Sink = StreamSnapshotHandoffTests.Sink

    /// Nothing else owns a stream: its tasks hold it weakly, as in the app.
    private var streams: [TerminalStream] = []

    private func makeStream(link: FakeLink, sink: Sink) -> (TerminalStream, SleepLog) {
        let made = RexKitTests.makeStream(link: link, sink: sink)
        streams.append(made.0)
        return made
    }

    private func liveStream(_ link: FakeLink) async -> (TerminalStream, Sink, SleepLog) {
        let sink = Sink()
        let (stream, log) = makeStream(link: link, sink: sink)
        stream.start()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        return (stream, sink, log)
    }

    /// The network is gone: the data socket drops, the control connection is lost, and the one
    /// RESUME fails. Ends with the stream waiting for the control connection.
    private func loseNetwork(_ link: FakeLink, _ stream: TerminalStream) async {
        link.disconnect()
        link.plans = [.fail]
        link.sockets.last?.drop()
        let waiting = await eventually { stream.waitingForControl }
        XCTAssertTrue(waiting)
    }

    func testStartOpensOneStream() async {
        let link = FakeLink()
        let (_, sink, _) = await liveStream(link)
        XCTAssertEqual(link.methods, ["data.connect"])
        XCTAssertEqual(link.sockets.count, 1)
        XCTAssertTrue(link.sockets[0].isHello)
        XCTAssertEqual(sink.statuses, [.connecting, .live])
    }

    func testOutageWaitsForTheControlConnectionThenResumesOnce() async {
        let link = FakeLink()
        let (stream, sink, log) = await liveStream(link)
        link.sockets[0].push([1, 2, 3, 4, 5])
        await settle()

        await loseNetwork(link, stream)
        // Offline: the failed RESUME, and then nothing. No ticket is asked for and nothing retries.
        await settle()
        XCTAssertEqual(link.count("data.connect"), 1)
        XCTAssertEqual(link.sockets.count, 2)
        XCTAssertEqual(sink.statuses.last, .reconnecting)
        XCTAssertFalse(sink.statuses.contains { if case .failed = $0 { return true } else { return false } })
        XCTAssertEqual(log.backoffs, [])

        // The control connection is back, within the time the server keeps the stream.
        link.connect()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        await settle()
        XCTAssertEqual(link.sockets.count, 3)
        XCTAssertTrue(link.sockets[2].isResume)
        XCTAssertEqual(link.sockets[2].resumeCount, 5)
        XCTAssertEqual(link.count("data.connect"), 1, "a resume needs no ticket")
        XCTAssertFalse(stream.waitingForControl)
    }

    // MARK: Back in the foreground

    func testWakeKeepsASocketThatAnswers() async {
        let link = FakeLink()
        let (stream, sink, _) = await liveStream(link)
        stream.wake()
        await settle()
        XCTAssertEqual(link.sockets[0].pings, 1)
        XCTAssertFalse(link.sockets[0].aborted)
        XCTAssertEqual(link.sockets.count, 1)
        XCTAssertEqual(sink.statuses, [.connecting, .live])
    }

    func testWakeResumesASocketThatDoesNotAnswer() async {
        let link = FakeLink()
        let (stream, sink, log) = await liveStream(link)
        link.sockets[0].push([1, 2, 3])
        await settle()
        // Half open after a suspension: the ping goes unanswered and the stream must not freeze.
        link.sockets[0].pingPlan = .silent
        link.disconnect()
        stream.wake()
        let resumed = await eventually { link.sockets.count == 2 && sink.statuses.last == .live }
        XCTAssertTrue(resumed)
        XCTAssertTrue(log.asked.contains(.milliseconds(2500)), "it waited out the ping")
        XCTAssertTrue(link.sockets[0].aborted)
        XCTAssertFalse(link.sockets[0].closed, "no status 1000, which would end the stream on the server")
        XCTAssertTrue(link.sockets[1].isResume)
        XCTAssertEqual(link.sockets[1].resumeCount, 3)
        XCTAssertEqual(link.count("data.connect"), 1, "a resume needs neither a ticket nor the control connection")
    }

    func testWakeResumesASocketWhosePingFails() async {
        let link = FakeLink()
        let (stream, sink, _) = await liveStream(link)
        link.sockets[0].pingPlan = .fail
        stream.wake()
        let resumed = await eventually { link.sockets.count == 2 && sink.statuses.last == .live }
        XCTAssertTrue(resumed)
        XCTAssertTrue(link.sockets[1].isResume)
        await settle()
        XCTAssertEqual(link.sockets.count, 2, "one drop, one resume")
    }

    func testATicketRefusedUntilTheSessionIsAttachedAgainIsRetriedSoon() async {
        let link = FakeLink()
        let (stream, sink, log) = await liveStream(link)
        await loseNetwork(link, stream)
        // Back, but the resync hasn't attached the session yet; the old stream can't be resumed.
        let notAttached = RexError(code: "conflict", message: "stream is not attached to session", status: 409)
        link.failures["data.connect"] = [notAttached, notAttached]
        link.plans = [.reject(0x03)]
        link.connect()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(log.asked.filter { $0 == TerminalStream.attachRetryDelay }.count, 2)
        XCTAssertEqual(log.backoffs, [], "not the 3 s backoff")
        XCTAssertFalse(sink.statuses.contains { if case .failed = $0 { return true } else { return false } })
    }

    func testATicketThatStaysRefusedFallsBackToTheBackoff() async {
        let link = FakeLink()
        let (stream, _, log) = await liveStream(link)
        await loseNetwork(link, stream)
        let notAttached = RexError(code: "conflict", message: "stream is not attached to session", status: 409)
        link.failures["data.connect"] = Array(repeating: notAttached, count: TerminalStream.attachRetryLimit + 1)
        link.plans = [.reject(0x03)]
        link.connect()
        let backedOff = await eventually { log.backoffs.count == 1 }
        XCTAssertTrue(backedOff)
        XCTAssertEqual(log.asked.filter { $0 == TerminalStream.attachRetryDelay }.count, TerminalStream.attachRetryLimit)
    }

    func testWakeDoesNothingForAStoppedStream() async {
        let link = FakeLink()
        let (stream, _, _) = await liveStream(link)
        stream.stop()
        stream.wake()
        await settle()
        XCTAssertEqual(link.sockets[0].pings, 0)
        XCTAssertEqual(link.sockets.count, 1)
    }

    func testRefusedResumeAfterTheOutageMakesOneFreshStart() async {
        let link = FakeLink()
        let (stream, sink, _) = await liveStream(link)
        await loseNetwork(link, stream)
        link.plans = [.reject(0x01)]
        link.connect()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        await settle()
        // HELLO, failed RESUME, refused RESUME, HELLO.
        XCTAssertEqual(link.sockets.map(\.isHello), [true, false, false, true])
        XCTAssertEqual(link.count("data.connect"), 2)
    }

    func testOutageLongerThanTheServerKeepsTheStreamStartsFresh() async {
        let link = FakeLink()
        link.defaultPlan = .welcome(keepMs: 0)
        let (stream, sink, _) = await liveStream(link)
        link.disconnect()
        link.sockets[0].drop()
        let waiting = await eventually { stream.waitingForControl }
        XCTAssertTrue(waiting)
        await settle()
        XCTAssertEqual(link.sockets.count, 1, "no RESUME for a stream the server no longer keeps")
        link.connect()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        await settle()
        XCTAssertEqual(link.sockets.map(\.isHello), [true, true])
        XCTAssertEqual(link.count("data.connect"), 2)
    }

    func testServerDroppedStreamIsNotResumed() async {
        let link = FakeLink()
        let (_, sink, _) = await liveStream(link)
        link.sockets[0].drop(code: 1013)
        let live = await eventually { link.sockets.count == 2 && sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertTrue(link.sockets[1].isHello)
        XCTAssertEqual(link.count("data.connect"), 2)
    }

    func testClosedPaneEndsTheStream() async {
        let link = FakeLink()
        let (_, sink, _) = await liveStream(link)
        link.sockets[0].drop(code: 4000)
        let ended = await eventually { sink.statuses.last == .ended("pane closed") }
        XCTAssertTrue(ended)
        link.connect()
        await settle()
        XCTAssertEqual(link.sockets.count, 1)
        XCTAssertEqual(link.count("data.connect"), 1)
    }

    func testDataSocketDropWithTheControlConnectionUpResumes() async {
        let link = FakeLink()
        let (_, sink, log) = await liveStream(link)
        link.sockets[0].drop()
        let live = await eventually { link.sockets.count == 2 && sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertTrue(link.sockets[1].isResume)
        XCTAssertEqual(log.asked, [.milliseconds(400)])
        XCTAssertEqual(sink.statuses, [.connecting, .live, .reconnecting, .live])
    }

    func testStartWithoutAControlConnectionWaitsAndCallsNothing() async {
        // Before and after a snapshot failed (the stream then reads `terminal.format` first).
        for snapshots in [true, false] {
            let link = FakeLink(connected: false)
            let sink = Sink()
            let (stream, log) = makeStream(link: link, sink: sink)
            if !snapshots { stream.snapshotRestoreFailed() }
            stream.start()
            let waiting = await eventually { stream.waitingForControl }
            XCTAssertTrue(waiting)
            await settle()
            XCTAssertEqual(link.calls.count, 0)
            XCTAssertEqual(link.sockets.count, 0)
            XCTAssertEqual(log.asked, [])
            link.connect()
            let live = await eventually { sink.statuses.last == .live }
            XCTAssertTrue(live)
            await settle()
            XCTAssertEqual(link.count("data.connect"), 1)
            XCTAssertEqual(link.sockets.count, 1)
            if snapshots {
                XCTAssertEqual(link.methods, ["data.connect"])
                XCTAssertEqual(sink.calls, [])
            } else {
                XCTAssertEqual(link.methods, ["com.superlogical.terminal.size", "com.superlogical.terminal.format", "data.connect"])
                XCTAssertEqual(sink.calls, [.reset(80, 24), .resized(80, 24, nil), .snapshot(0)])
            }
        }
    }

    func testStopWhileWaitingStartsNothingWhenTheConnectionReturns() async {
        let link = FakeLink()
        let (stream, sink, _) = await liveStream(link)
        await loseNetwork(link, stream)
        let sockets = link.sockets.count
        stream.stop()
        XCTAssertFalse(stream.waitingForControl)
        link.connect()
        await settle()
        XCTAssertEqual(link.sockets.count, sockets)
        XCTAssertEqual(link.count("data.connect"), 1)
        XCTAssertNotEqual(sink.statuses.last, .live)

        // A later start works as usual.
        stream.start()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(link.count("data.connect"), 2)
        XCTAssertTrue(link.sockets.last!.isHello)
    }

    func testRestartWhileWaitingMakesOneFreshStartWhenTheConnectionReturns() async {
        let link = FakeLink()
        let (stream, sink, _) = await liveStream(link)
        await loseNetwork(link, stream)
        stream.restart()
        stream.restart()
        let waiting = await eventually { stream.waitingForControl }
        XCTAssertTrue(waiting)
        await settle()
        XCTAssertEqual(link.count("data.connect"), 1)
        XCTAssertEqual(link.sockets.count, 2)
        link.connect()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        await settle()
        // `restart()` asked for the whole screen: no RESUME of the old stream.
        XCTAssertEqual(link.sockets.count, 3)
        XCTAssertTrue(link.sockets[2].isHello)
        XCTAssertEqual(link.count("data.connect"), 2)
    }

    func testSeveralConnectsWhileOneStartIsUnderWayMakeOneStart() async {
        let link = FakeLink(connected: false)
        let sink = Sink()
        let (stream, _) = makeStream(link: link, sink: sink)
        stream.start()
        _ = await eventually { stream.waitingForControl }
        link.held = ["data.connect"]
        link.connect()
        _ = await eventually { link.waitingCount == 1 }
        // The connection flaps and comes back twice more while the ticket is on its way.
        link.connect()
        link.connect()
        await settle()
        XCTAssertEqual(link.count("data.connect"), 1)
        link.release()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        await settle()
        XCTAssertEqual(link.count("data.connect"), 1)
        XCTAssertEqual(link.sockets.count, 1)
    }

    func testStartThatFailedOnTheOldConnectionIsRepeatedOnceOnTheNewOne() async {
        let link = FakeLink()
        let sink = Sink()
        let (stream, log) = makeStream(link: link, sink: sink)
        link.held = ["data.connect"]
        stream.start()
        _ = await eventually { link.waitingCount == 1 }
        // The connection breaks with the ticket request out, and is back before the stream has
        // seen the failure. The stream wasn't waiting, so the connect alone starts nothing.
        link.held = []
        link.disconnect()
        link.connect()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        await settle()
        XCTAssertEqual(link.count("data.connect"), 2)
        XCTAssertEqual(link.sockets.count, 1)
        XCTAssertEqual(log.backoffs, [])
    }

    func testResyncDoesNothingUntilTheStreamIsLive() async {
        let link = FakeLink()
        link.plans = [.silent]
        let sink = Sink()
        let (stream, _) = makeStream(link: link, sink: sink)
        stream.start()
        _ = await eventually { link.sockets.first?.isHello == true }
        // The handshake is out. A resync now would close it and ask for a second ticket.
        stream.resync()
        await settle()
        XCTAssertEqual(link.count("data.connect"), 1)
        XCTAssertFalse(link.sockets[0].closed)
        link.sockets[0].push(FakeLink.welcome())
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        stream.resync()
        let again = await eventually { link.count("data.connect") == 2 && sink.statuses.last == .live }
        XCTAssertTrue(again)
        XCTAssertTrue(link.sockets[0].closed)
    }

    // MARK: Failures with the control connection up

    func testBusyTerminalBacksOffAndStopsSpendingTickets() async {
        let link = FakeLink()
        link.defaultPlan = .reject(TerminalStream.busyReason)
        let sink = Sink()
        let (stream, log) = makeStream(link: link, sink: sink)
        log.onSleep = { _ in if log.backoffs.count == 4 { stream.stop() } }
        stream.start()
        _ = await eventually { log.backoffs.count == 4 }
        await settle()
        XCTAssertEqual(log.backoffs, [.seconds(3), .seconds(6), .seconds(12), .seconds(24)])
        // The first start asks again while the old socket's close may still be on its way; the
        // starts after a failure ask once each.
        XCTAssertEqual(link.count("data.connect"), TerminalStream.busyRetryLimit + 1 + 3)
        XCTAssertEqual(log.asked.filter { $0 < .seconds(1) }.count, TerminalStream.busyRetryLimit)
        XCTAssertTrue(sink.statuses.contains { if case .failed = $0 { return true } else { return false } })
    }

    func testRetryDelayIsCappedAndStartsOverAfterAWelcome() async {
        XCTAssertEqual((1...8).map { TerminalStream.retryDelay(afterFailures: $0) },
                       [3, 6, 12, 24, 30, 30, 30, 30].map { Duration.seconds($0) })

        let link = FakeLink()
        link.plans = [.reject(0x06), .reject(0x06), .welcome(), .reject(0x06)]
        let sink = Sink()
        let (stream, log) = makeStream(link: link, sink: sink)
        stream.start()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(log.backoffs, [.seconds(3), .seconds(6)])
        // Live again, then the server takes the stream away and refuses the next start.
        link.defaultPlan = .welcome()
        link.sockets.last?.drop(code: 1013)
        let liveAgain = await eventually { link.sockets.count == 5 && sink.statuses.last == .live }
        XCTAssertTrue(liveAgain)
        XCTAssertEqual(log.backoffs, [.seconds(3), .seconds(6), .seconds(3)])
    }

    func testFailedStartDuringAnOutageWaitsInsteadOfBackingOff() async {
        let link = FakeLink()
        link.plans = [.reject(0x06)]
        let sink = Sink()
        let (stream, log) = makeStream(link: link, sink: sink)
        // The control connection is lost while the stream waits out its pause: it must not try
        // again on its own, only when the connection is back.
        log.onSleep = { d in if d >= .seconds(3) { link.disconnect() } }
        stream.start()
        let waiting = await eventually { stream.waitingForControl }
        XCTAssertTrue(waiting)
        await settle()
        XCTAssertEqual(link.count("data.connect"), 1)
        XCTAssertEqual(log.backoffs, [.seconds(3)])
        link.connect()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        await settle()
        XCTAssertEqual(link.count("data.connect"), 2)
    }
}
