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
        // The control connection is down: no socket is opened to the host, not even for a
        // RESUME. No ticket is asked for and nothing retries.
        await settle()
        XCTAssertEqual(link.count("data.connect"), 1)
        XCTAssertEqual(link.sockets.count, 1)
        XCTAssertEqual(sink.statuses.last, .reconnecting)
        XCTAssertFalse(sink.statuses.contains { if case .failed = $0 { return true } else { return false } })
        XCTAssertEqual(log.backoffs, [])

        // The control connection is back, within the time the server keeps the stream.
        link.connect()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        await settle()
        XCTAssertEqual(link.sockets.count, 2)
        XCTAssertTrue(link.sockets[1].isResume)
        XCTAssertEqual(link.sockets[1].resumeCount, 5)
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
        // The control connection is up, so the stream may open its RESUME.
        link.sockets[0].pingPlan = .silent
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

    // MARK: A client the server no longer has

    func testAfterANewClientTheStreamStartsFreshAndSpendsNoResume() async {
        let link = FakeLink()
        let (stream, sink, _) = await liveStream(link)
        link.sockets[0].push([1, 2, 3, 4, 5])
        await settle()
        await loseNetwork(link, stream)
        // The welcome of the new connection started a new client: the old one left the server,
        // and the server stopped the streams it had opened. A RESUME is certain to be refused.
        link.clientGeneration += 1
        link.connect()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        await settle()
        XCTAssertEqual(link.sockets.map(\.isHello), [true, true], "no socket was spent on a RESUME")
        XCTAssertEqual(link.count("data.connect"), 2, "one ticket for the one fresh start")
        XCTAssertEqual(link.notes, [.resumeSkipped])
    }

    func testAStreamWelcomedUnderTheNewClientIsResumedAsBefore() async {
        let link = FakeLink()
        link.clientGeneration = 4
        let (stream, sink, _) = await liveStream(link)
        await loseNetwork(link, stream)
        link.connect()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        await settle()
        XCTAssertEqual(link.sockets.map(\.isResume), [false, true], "the client went on: its stream is still there")
        XCTAssertEqual(link.count("data.connect"), 1)
        XCTAssertEqual(link.notes, [])
    }

    func testADataSocketDropUnderANewClientStartsFreshOnceItIsKnown() async {
        // The server closes a client's data sockets as the client leaves. That drop can come
        // before the new welcome: the RESUME it plans then waits its pause, and by then the
        // welcome has said the client is gone.
        let link = FakeLink()
        let (_, sink, log) = await liveStream(link)
        log.held = [.milliseconds(400)]
        link.sockets[0].drop()
        _ = await eventually { log.asked.contains(.milliseconds(400)) }
        link.clientGeneration += 1
        log.release(.milliseconds(400))
        let live = await eventually { sink.statuses.last == .live && link.sockets.count == 2 }
        XCTAssertTrue(live)
        XCTAssertEqual(link.sockets.map(\.isHello), [true, true])
    }

    // MARK: Waiting for the session's attach

    private var conflict: RexError { RexError(code: "conflict", message: "stream is not attached to session", status: 409) }

    /// Back on a new client, with the ticket refused once: the stream waits for the attach.
    private func waitingForAttach(_ link: FakeLink) async -> (TerminalStream, Sink, SleepLog) {
        let (stream, sink, log) = await liveStream(link)
        await loseNetwork(link, stream)
        // The cap does not pass by itself here, however slow the machine.
        log.held = [TerminalStream.attachWaitCap]
        link.clientGeneration += 1
        link.failures["data.connect"] = [conflict]
        link.connect()
        let waits = await eventually { link.attachWaits.waiting == 1 }
        XCTAssertTrue(waits)
        return (stream, sink, log)
    }

    func testARefusedTicketIsAskedAgainTheMomentTheSessionIsAttached() async {
        let link = FakeLink()
        let (_, sink, log) = await waitingForAttach(link)
        await settle()
        XCTAssertEqual(link.count("data.connect"), 2, "it asks nothing while it waits")
        XCTAssertEqual(link.sockets.count, 2, "the socket opened beside the refused ticket, kept (`EarlySocket`)")
        XCTAssertEqual(link.sockets[1].sent.count, 0)
        link.attachWaits.attach(["session:test"])
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(link.sockets.count, 2, "and used: no other opens")
        XCTAssertEqual(link.count("data.connect"), 3)
        XCTAssertFalse(log.asked.contains(TerminalStream.attachRetryDelay), "no timer was waited out")
        XCTAssertEqual(link.attachWaits.waiting, 0)
        XCTAssertEqual(link.notes, [.resumeSkipped, .ticketRefused(conflict: true, inARow: 1)])
        log.release(TerminalStream.attachWaitCap)
    }

    func testAnAttachThatNeverComesFallsBackToTheRetryAtTheCap() async {
        let link = FakeLink()
        let (_, sink, log) = await waitingForAttach(link)
        log.release(TerminalStream.attachWaitCap)
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        XCTAssertEqual(log.asked.filter { $0 == TerminalStream.attachRetryDelay }.count, 1, "today's retry")
        XCTAssertEqual(link.attachWaits.waiting, 0, "the wait is over, not left behind")
        XCTAssertEqual(link.count("data.connect"), 3)
    }

    func testARefusalWithTheSessionAttachedIsRetriedOnTheTimerAsBefore() async {
        for tracks in [true, false] {
            let link = FakeLink()
            link.tracksAttaches = tracks
            let (stream, sink, log) = await liveStream(link)
            await loseNetwork(link, stream)
            link.clientGeneration += 1
            // Attached, and refused all the same: there is nothing to wait for.
            link.attachWaits.attach(["session:test"])
            link.failures["data.connect"] = [conflict, conflict]
            link.connect()
            let live = await eventually { sink.statuses.last == .live }
            XCTAssertTrue(live, "\(tracks)")
            XCTAssertEqual(log.asked.filter { $0 == TerminalStream.attachRetryDelay }.count, 2, "\(tracks)")
            XCTAssertFalse(log.asked.contains(TerminalStream.attachWaitCap), "\(tracks)")
            XCTAssertEqual(link.attachWaits.waiting, 0)
        }
    }

    func testParkStopAndRestartEndTheWaitForTheAttach() async {
        for leave in ["park", "stop", "restart"] {
            let link = FakeLink()
            let (stream, sink, log) = await waitingForAttach(link)
            let asked = link.count("data.connect")
            switch leave {
            case "park": stream.park()
            case "stop": stream.stop()
            default: stream.restart()
            }
            XCTAssertEqual(link.attachWaits.waiting, 0, leave)
            // The attach and the cap come afterwards: neither starts anything for a stream
            // that has moved on.
            link.attachWaits.attach(["session:test"])
            log.release(TerminalStream.attachWaitCap)
            await settle()
            if leave == "restart" {
                let live = await eventually { sink.statuses.last == .live }
                XCTAssertTrue(live)
                XCTAssertEqual(link.count("data.connect"), asked + 1, "the restart's own start, once")
            } else {
                XCTAssertEqual(link.count("data.connect"), asked, leave)
                XCTAssertEqual(link.sockets.count, 2, leave)
                XCTAssertTrue(link.sockets[1].closed, "the socket kept for the wait is closed: \(leave)")
                XCTAssertEqual(link.sockets[1].sent.count, 0, leave)
            }
            stream.stop()
        }
    }

    func testALostConnectionEndsTheWaitAndNothingIsAskedUntilItIsBack() async {
        let link = FakeLink()
        let (stream, sink, log) = await waitingForAttach(link)
        let asked = link.count("data.connect")
        // The control connection goes again (or the app goes to the background: both end the
        // waits the same way, `AttachWaits.cancelAll`).
        link.disconnect()
        let waiting = await eventually { stream.waitingForControl }
        XCTAssertTrue(waiting)
        log.release(TerminalStream.attachWaitCap)
        await settle()
        XCTAssertEqual(link.attachWaits.waiting, 0)
        XCTAssertEqual(link.count("data.connect"), asked, "no ticket is asked of a connection that is gone")
        XCTAssertEqual(link.sockets.count, 2, "and no socket is opened: the one kept for the wait is all")
        XCTAssertTrue(link.sockets[1].closed, "and it is closed")
        XCTAssertEqual(log.backoffs, [])
        // Back: exactly one start.
        link.connect()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        await settle()
        XCTAssertEqual(link.count("data.connect"), asked + 1)
        XCTAssertEqual(link.sockets.count, 3)
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
        // HELLO, refused RESUME, HELLO.
        XCTAssertEqual(link.sockets.map(\.isHello), [true, false, true])
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
        // One pause before the one RESUME; the rest are the fence's short waits.
        XCTAssertEqual(log.asked.filter { $0 > .milliseconds(300) }, [.milliseconds(400)])
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
        XCTAssertEqual(link.sockets.count, 1)
        link.connect()
        let live = await eventually { sink.statuses.last == .live }
        XCTAssertTrue(live)
        await settle()
        // `restart()` asked for the whole screen: no RESUME of the old stream.
        XCTAssertEqual(link.sockets.count, 2)
        XCTAssertTrue(link.sockets[1].isHello)
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
        // The first start's socket, opened beside its ticket request, went with that request.
        XCTAssertEqual(link.sockets.count, 2)
        XCTAssertTrue(link.sockets[0].closed)
        XCTAssertEqual(link.sockets[0].sent.count, 0)
        XCTAssertTrue(link.sockets[1].isHello)
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
