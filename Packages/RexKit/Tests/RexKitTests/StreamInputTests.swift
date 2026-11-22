import XCTest
@testable import RexKit

/// Typed input and key-bound actions: one queue, in order, each sent at most once after it left.
@MainActor
final class StreamInputTests: XCTestCase {
    typealias Sink = StreamSnapshotHandoffTests.Sink
    private static let write = "com.superlogical.terminal.write"

    private var notices: [TerminalStream.Notice] = []
    private var streams: [TerminalStream] = []

    private func stream(_ link: FakeLink) -> (TerminalStream, SleepLog) {
        let (s, log) = makeStream(link: link, sink: Sink())
        s.onActionFailed = { [weak self] in self?.notices.append($0) }
        streams.append(s)
        return (s, log)
    }

    /// A yes or no that a test changes after a closure has it.
    @MainActor
    private final class Flag {
        var on = true
    }

    private func action(_ s: TerminalStream, _ name: String = "pane.clear") {
        s.perform(action: name, args: nil) { _ in }
    }

    func testTextTypedDuringAWriteGoesOutTogetherAfterIt() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.held = [Self.write]
        s.send(text: "a")
        s.send(text: "b")
        s.send(text: "c")
        _ = await eventually { link.waitingCount == 1 }
        XCTAssertEqual(link.written, ["a"])
        link.release()
        _ = await eventually { link.written.count == 2 }
        XCTAssertEqual(link.written, ["a", "bc"])
    }

    func testTextActionTextKeepTheirOrderWithAWriteInFlight() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.held = [Self.write, "client.action", "client.key"]
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        // All of this is asked for while the first write is out.
        s.send(text: "b")
        action(s)
        s.send(text: "c")
        s.forward(key: ["key": "F5"])
        s.send(text: "d")
        s.send(text: "e")
        var expected = ["w:a"]
        for next in ["w:b", "client.action", "w:c", "client.key", "w:de"] {
            await settle()
            XCTAssertEqual(link.inputTrace, expected, "nothing overtakes the request that is out")
            link.release()
            expected.append(next)
            let sent = await eventually { link.inputTrace.count == expected.count }
            XCTAssertTrue(sent)
        }
        XCTAssertEqual(link.inputTrace, ["w:a", "w:b", "client.action", "w:c", "client.key", "w:de"])
        link.release()
        XCTAssertEqual(notices, [])
    }

    func testTextActionTextWaitOfflineAndGoOutInOrder() async {
        let link = FakeLink(connected: false)
        let (s, _) = stream(link)
        s.send(text: "a")
        action(s)
        s.send(text: "b")
        s.forward(key: ["key": "F5"])
        await settle()
        XCTAssertEqual(link.calls.count, 0, "nothing is tried, and nothing is lost, without a connection")
        XCTAssertEqual(notices, [])
        link.connect()
        _ = await eventually { link.inputTrace.count == 4 }
        XCTAssertEqual(link.inputTrace, ["w:a", "client.action", "w:b", "client.key"])
        XCTAssertEqual(notices, [])
    }

    func testAnActionThatNeverLeftRunsWhenTheConnectionReturns() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.failures["client.action"] = [RexError.unsent("not connected")]
        var ran = 0
        s.perform(action: "pane.clear", args: nil) { _ in ran += 1 }
        s.send(text: "x")
        _ = await eventually { link.inputTrace == ["client.action", "w:x"] }
        XCTAssertEqual(link.inputTrace, ["client.action", "w:x"])
        XCTAssertEqual(ran, 1)
        XCTAssertEqual(notices, [])
    }

    func testWriteThatNeverLeftIsSentAgainExactlyOnce() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        // The socket refuses the message: the server never saw it.
        link.failures[Self.write] = [RexError.unsent("socket is not connected")]
        s.send(text: "rm x\r")
        s.send(text: "ls\r")
        _ = await eventually { !link.written.isEmpty }
        await settle()
        XCTAssertEqual(link.written.joined(), "rm x\rls\r")
        XCTAssertEqual(notices, [])
    }

    func testWriteWhoseAnswerWasLostIsNotSentAgain() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.held = [Self.write]
        s.send(text: "rm x\r")
        _ = await eventually { link.waitingCount == 1 }
        // Typed behind it, on the assumption that it arrived.
        s.send(text: "ls\r")
        action(s)
        // The request is out, and the connection breaks before the answer.
        link.held = []
        link.disconnect()
        _ = await eventually { !self.notices.isEmpty }
        XCTAssertEqual(notices, [.inputLost])
        link.connect()
        await settle()
        XCTAssertEqual(link.inputTrace, ["w:rm x\r"], "the server may have run it: it must not run twice")
        // What is typed from here on goes out as usual.
        s.send(text: "y")
        _ = await eventually { link.written.count == 2 }
        XCTAssertEqual(link.inputTrace, ["w:rm x\r", "w:y"])
        XCTAssertEqual(notices.count, 1)
    }

    func testActionWhoseAnswerWasLostIsNotRunAgain() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.held = ["client.action"]
        action(s, "dev_layout")
        s.send(text: "x")
        _ = await eventually { link.waitingCount == 1 }
        link.held = []
        link.disconnect()
        _ = await eventually { !self.notices.isEmpty }
        XCTAssertEqual(notices, [.actionLost(action: "dev_layout", title: nil)])
        link.connect()
        await settle()
        XCTAssertEqual(link.inputTrace, ["client.action"])
    }

    func testWriteTheServerRefusedIsDroppedAndTheNextGoesOn() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.failures[Self.write] = [RexError(code: "not_found", message: "block not found", status: 404)]
        link.held = [Self.write]
        s.send(text: "a")
        s.send(text: "b")
        _ = await eventually { link.waitingCount == 1 }
        XCTAssertEqual(link.written, ["a", "b"])
        XCTAssertEqual(notices, [])
        link.release()
    }

    func testRefusedActionTellsTheUser() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.failures["client.action"] = [RexError(code: "not_found", message: "no such action", status: 404)]
        action(s, "nope")
        s.send(text: "a")
        _ = await eventually { link.written == ["a"] }
        XCTAssertEqual(notices, [.actionRefused(action: "nope", title: nil, code: "not_found")])
    }

    func testSlowActionHoldsTypingOnlySoLong() async {
        let link = FakeLink()
        let (s, log) = stream(link)
        s.actionHold = .milliseconds(20)
        log.real = [.milliseconds(20)]
        link.held = ["client.action"]
        action(s)
        s.send(text: "a")
        await Task.yield()
        XCTAssertEqual(link.inputTrace, ["client.action"])
        let typed = await eventually { link.written == ["a"] }
        XCTAssertTrue(typed)
        XCTAssertEqual(link.waitingCount, 1, "the action is still running")
        link.release()
        await settle()
        XCTAssertEqual(link.inputTrace, ["client.action", "w:a"])
    }

    // MARK: stop() and restart()

    func testStopDropsQueuedInput() async {
        let link = FakeLink(connected: false)
        let (s, _) = stream(link)
        s.start()
        s.send(text: "typed offline")
        action(s)
        s.stop()
        XCTAssertFalse(s.send(text: "typed into a closed pane"))
        link.connect()
        await settle()
        XCTAssertEqual(link.calls.count, 0)
        // Opened again later: only what is typed now goes out.
        s.start()
        _ = await eventually { link.count("data.connect") == 1 }
        await catchUp(s, link)
        XCTAssertTrue(s.send(text: "x"))
        _ = await eventually { !link.written.isEmpty }
        await settle()
        XCTAssertEqual(link.inputTrace, ["w:x"])
    }

    func testStopDuringAWriteKeepsNothingOfIt() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.held = [Self.write]
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        s.send(text: "b")
        s.stop()
        link.held = []
        // The write that was out fails as never sent: after `stop()` it is not queued again.
        link.disconnect()
        link.connect()
        s.start()
        await catchUp(s, link)
        s.send(text: "c")
        _ = await eventually { link.written.count == 2 }
        await settle()
        XCTAssertEqual(link.written, ["a", "c"])
        XCTAssertEqual(notices, [])
    }

    func testRestartDropsQueuedInputWithItsNewSnapshot() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        s.start()
        await catchUp(s, link)
        // Typed at a current screen, with no connection to send it on.
        link.disconnect()
        s.send(text: "a")
        s.restart()
        link.connect()
        _ = await eventually { link.sockets.count == 2 }
        // The fresh stream's snapshot replaces the screen "a" was typed at.
        await catchUp(s, link)
        await settle()
        XCTAssertEqual(link.written, [])
        XCTAssertEqual(notices, [.paneChanged])
    }

    // MARK: Bytes

    func testOnlyValidUTF8IsSent() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.held = [Self.write]
        XCTAssertTrue(s.send(text: "é"))
        _ = await eventually { link.waitingCount == 1 }
        // An X10 mouse report at column 129: the column byte, 0xA1, is not UTF-8. Typed loosely
        // it would arrive as U+FFFD, three other bytes.
        XCTAssertFalse(s.send([0x1b, 0x5b, 0x4d, 0x20, 0xA1, 0x21]))
        // The same click as an SGR report, and as a UTF-8 (1005) report, are plain UTF-8.
        XCTAssertTrue(s.send(Array("\u{1b}[<0;129;1M".utf8)))
        XCTAssertTrue(s.send([0x1b, 0x5b, 0x4d, 0x20, 0xC2, 0xA1, 0x21]))
        XCTAssertTrue(s.send([]))
        link.release()
        _ = await eventually { link.written.count == 2 }
        XCTAssertEqual(link.written, ["é", "\u{1b}[<0;129;1M\u{1b}[M \u{a1}!"])
        XCTAssertEqual(link.written.joined().unicodeScalars.contains("\u{fffd}"), false)
        link.release()
    }

    // MARK: Pending input, for a long read on the same connection

    func testPendingInputCoversAWriteInFlightAndWhatWaitsBehindIt() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        let activity = s.control.inputActivity
        XCTAssertFalse(s.hasPendingInput)
        XCTAssertFalse(activity.busy)
        link.held = [Self.write]
        s.send(text: "a")
        s.send(text: "b")
        XCTAssertTrue(s.hasPendingInput)
        XCTAssertTrue(activity.busy)
        var idle = false
        let waiter = Task { @MainActor in
            await activity.idle()
            idle = true
        }
        _ = await eventually { link.waitingCount == 1 }
        link.release()
        _ = await eventually { link.waitingCount == 1 }
        await settle()
        XCTAssertFalse(idle, "the queued write is still on its way")
        XCTAssertTrue(s.hasPendingInput)
        link.release()
        _ = await eventually { idle }
        await waiter.value
        XCTAssertTrue(idle)
        XCTAssertFalse(s.hasPendingInput)
        XCTAssertFalse(activity.busy)
    }

    func testIdleReturnsAtOnceWithNothingOnItsWayAndOnCancel() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        await s.control.inputActivity.idle()
        link.held = [Self.write]
        s.send(text: "a")
        let waiter = Task { @MainActor in await s.control.inputActivity.idle() }
        await settle()
        waiter.cancel()
        await waiter.value
        XCTAssertTrue(s.hasPendingInput, "a cancelled wait changes nothing")
        link.release()
    }

    func testStopDropsQueuedInputFromPending() async {
        let link = FakeLink(connected: false)
        let (s, _) = stream(link)
        s.send(text: "a")
        XCTAssertTrue(s.control.inputActivity.busy)
        s.stop()
        XCTAssertFalse(s.hasPendingInput)
        XCTAssertFalse(s.control.inputActivity.busy)
    }

    func testIdleReturnsWhenTheConnectionDropsWithInputQueued() async {
        let activity = InputActivity()
        let stream = NSObject()
        activity.set(stream, pending: true)
        var returned = false
        let waiter = Task { @MainActor in
            await activity.idle()
            returned = true
        }
        await settle()
        XCTAssertFalse(returned, "connected, it waits for the input")
        activity.connection(false)
        _ = await eventually { returned }
        XCTAssertTrue(returned, "input waits for the next connection: the read stops now")
        await waiter.value
        XCTAssertTrue(activity.busy, "the input still counts")
        await activity.idle()  // down: at once
        activity.connection(true)
        let again = Task { @MainActor in await activity.idle() }
        await settle()
        activity.set(stream, pending: false)
        await again.value
        XCTAssertFalse(activity.busy)
    }

    func testStopTakesAWriteInFlightOutOfPending() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.held = [Self.write]
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        XCTAssertTrue(s.control.inputActivity.busy)
        s.stop()
        XCTAssertFalse(s.hasPendingInput)
        XCTAssertFalse(s.control.inputActivity.busy)
        link.release()
        await settle()
        XCTAssertFalse(s.control.inputActivity.busy)
    }

    // MARK: Picked from the palette

    private func palette(_ s: TerminalStream, _ name: String = "dev_layout", ended: (@MainActor (Bool) -> Void)? = nil) {
        s.perform(action: name, args: nil, origin: .palette, title: "Dev Layout", ended: ended) { _ in }
    }

    func testAPalettePickSaysSoAndKeepsItsPlaceBehindKeys() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.held = [Self.write]
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        var ended: [Bool] = []
        palette(s) { ended.append($0) }
        s.send(text: "b")
        await settle()
        XCTAssertEqual(link.inputTrace, ["w:a"], "it waits behind the keys typed before it")
        link.held = []
        link.release()
        _ = await eventually { link.inputTrace.count == 3 }
        XCTAssertEqual(link.inputTrace, ["w:a", "client.action", "w:b"])
        let call = link.calls.first { $0.method == "client.action" }
        XCTAssertEqual(call?.payload.str("origin"), "palette")
        XCTAssertEqual(call?.payload.str("action"), "dev_layout")
        XCTAssertEqual(ended, [true])
        XCTAssertEqual(notices, [])
    }

    func testAKeyStillSaysKey() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        action(s, "dev_layout")
        _ = await eventually { link.count("client.action") == 1 }
        XCTAssertEqual(link.calls.first { $0.method == "client.action" }?.payload.str("origin"), "key")
    }

    func testAPalettePickWithoutAConnectionFailsAtOnceAndNeverRunsLater() async {
        let link = FakeLink(connected: false)
        let (s, _) = stream(link)
        var ended: [Bool] = []
        palette(s) { ended.append($0) }
        XCTAssertEqual(notices, [.actionNotSent(action: "dev_layout", title: "Dev Layout")], "at once, in the same turn")
        XCTAssertEqual(ended, [false])
        link.connect()
        await settle()
        XCTAssertEqual(link.count("client.action"), 0)
    }

    func testAPalettePickThatNeverLeftIsDroppedNotQueued() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.failures["client.action"] = [RexError.unsent("not connected")]
        var ended: [Bool] = []
        palette(s) { ended.append($0) }
        s.send(text: "x")
        _ = await eventually { link.written == ["x"] }
        await settle()
        XCTAssertEqual(link.inputTrace, ["w:x"], "never sent later")
        XCTAssertEqual(notices, [.actionNotSent(action: "dev_layout", title: "Dev Layout")])
        XCTAssertEqual(ended, [false])
    }

    func testARefusedPalettePickNamesItsTitle() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.failures["client.action"] = [RexError(code: "not_found", message: "no such action", status: 404)]
        palette(s)
        _ = await eventually { !self.notices.isEmpty }
        XCTAssertEqual(notices, [.actionRefused(action: "dev_layout", title: "Dev Layout", code: "not_found")])
    }

    func testAPalettePickWhoseAnswerWasLostEndsQuietly() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.held = ["client.action"]
        var ended: [Bool] = []
        palette(s) { ended.append($0) }
        _ = await eventually { link.waitingCount == 1 }
        link.held = []
        link.disconnect()
        _ = await eventually { !ended.isEmpty }
        XCTAssertEqual(ended, [false])
        link.connect()
        await settle()
        XCTAssertEqual(link.inputTrace, ["client.action"], "never sent again")
        XCTAssertEqual(notices, [])
    }

    func testAStreamThatGoesWithoutStopTakesItsInputOut() async {
        let link = FakeLink(connected: false)
        var made: TerminalStream? = makeStream(link: link, sink: Sink()).0
        let activity = made!.control.inputActivity
        let control = made!.control
        made!.send(text: "a")
        XCTAssertTrue(activity.busy)
        var returned = false
        let waiter = Task { @MainActor in
            await activity.idle()
            returned = true
        }
        await settle()
        XCTAssertFalse(returned)
        made = nil
        _ = await eventually { returned }
        XCTAssertTrue(returned)
        XCTAssertFalse(activity.busy)
        await waiter.value
        _ = control
    }

    // MARK: Input that goes once or not at all

    func testSendOnceTypesTheTextOnceAndSaysSo() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        var ended: [TerminalStream.Delivery] = []
        s.sendOnce(text: "\r") { ended.append($0) }
        _ = await eventually { !ended.isEmpty }
        await settle()
        XCTAssertEqual(link.written, ["\r"])
        XCTAssertEqual(ended, [.delivered])
        XCTAssertEqual(notices, [])
    }

    func testSendOnceWaitsItsTurnBehindWhatWasTyped() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.held = [Self.write]
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        var ended: [TerminalStream.Delivery] = []
        s.sendOnce(text: "\r") { ended.append($0) }
        s.send(text: "b")
        await settle()
        XCTAssertEqual(link.inputTrace, ["w:a"], "nothing overtakes the request that is out")
        for _ in 0..<3 {
            link.release()
            await settle()
        }
        XCTAssertEqual(link.inputTrace, ["w:a", "w:\r", "w:b"])
        XCTAssertEqual(ended, [.delivered])
    }

    /// Input that waits before it writes does so as the request in flight: what is typed
    /// meanwhile stays behind it, and it is asked how long only when its turn has come.
    func testSendOnceThatHoldsKeepsLaterKeysBehindIt() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.held = [Self.write]
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        var asked = 0
        var ended: [TerminalStream.Delivery] = []
        XCTAssertTrue(s.sendOnce(text: "C", hold: { asked += 1; return .milliseconds(30) }) { ended.append($0) })
        s.send(text: "b")
        await settle()
        XCTAssertEqual(asked, 0, "not before its turn")
        for _ in 0..<3 {
            _ = await eventually { link.waitingCount == 1 }
            link.release()
        }
        _ = await eventually { link.inputTrace.count == 3 }
        XCTAssertEqual(link.inputTrace, ["w:a", "w:C", "w:b"])
        XCTAssertEqual(asked, 1)
        XCTAssertEqual(ended, [.delivered])
    }

    func testSendOnceThatIsNoLongerWantedAtItsTurnIsDropped() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        let wanted = Flag()
        var ended: [TerminalStream.Delivery] = []
        link.held = [Self.write]
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        s.sendOnce(text: "C", still: { wanted.on }) { ended.append($0) }
        s.send(text: "b")
        wanted.on = false
        for _ in 0..<2 {
            _ = await eventually { link.waitingCount == 1 }
            link.release()
        }
        _ = await eventually { link.inputTrace.count == 2 }
        XCTAssertEqual(link.inputTrace, ["w:a", "w:b"])
        XCTAssertEqual(ended, [.unsent])
        XCTAssertEqual(notices, [])
    }

    /// A report sent as a write of its own is joined with nothing typed around it, and says
    /// when it leaves.
    func testAReportOfItsOwnIsNeverJoinedWithWhatIsTypedAroundIt() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.held = [Self.write]
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        var left = 0
        s.send(text: "b")
        XCTAssertTrue(s.send(report: Array("\u{1b}[I".utf8)) { left += 1 })
        XCTAssertTrue(s.send(report: Array("\u{1b}[<0;1;1M".utf8)))
        s.send(text: "c")
        await settle()
        XCTAssertEqual(left, 0, "still queued")
        for _ in 0..<4 {
            _ = await eventually { link.waitingCount == 1 }
            link.release()
        }
        _ = await eventually { link.inputTrace.count == 4 }
        XCTAssertEqual(link.inputTrace, ["w:a", "w:b", "w:\u{1b}[I", "w:\u{1b}[<0;1;1Mc"])
        XCTAssertEqual(left, 1)
        XCTAssertEqual(notices, [])
    }

    func testAReportOfItsOwnIsDroppedBehindTheFence() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        s.restart()
        XCTAssertTrue(s.isFenced)
        var left = 0
        XCTAssertFalse(s.send(report: Array("\u{1b}[I".utf8)) { left += 1 })
        await settle()
        XCTAssertEqual(left, 0)
    }

    func testSendOnceWithoutAConnectionIsDroppedAndNeverSentLater() async {
        let link = FakeLink(connected: false)
        let (s, _) = stream(link)
        var ended: [TerminalStream.Delivery] = []
        s.sendOnce(text: "\r") { ended.append($0) }
        XCTAssertEqual(ended, [.unsent])
        link.connect()
        await settle()
        XCTAssertEqual(link.written, [])
        XCTAssertFalse(s.hasPendingInput)
    }

    func testSendOnceThatWaitedTooLongIsDroppedNotSentLate() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.held = [Self.write]
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        var ended: [TerminalStream.Delivery] = []
        s.sendOnce(text: "\r", within: .milliseconds(20)) { ended.append($0) }
        try? await Task.sleep(for: .milliseconds(60))
        link.release()
        _ = await eventually { !ended.isEmpty }
        await settle()
        XCTAssertEqual(link.written, ["a"], "what it answered may be gone: it is not typed late")
        XCTAssertEqual(ended, [.unsent])
        XCTAssertEqual(notices, [])
    }

    func testSendOnceWhoseAnswerWasLostIsNeverSentAgain() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.held = [Self.write]
        var ended: [TerminalStream.Delivery] = []
        s.sendOnce(text: "\u{3}") { ended.append($0) }
        _ = await eventually { link.waitingCount == 1 }
        s.send(text: "typed behind it")
        link.disconnect()
        _ = await eventually { !ended.isEmpty }
        XCTAssertEqual(ended, [.unknown])
        link.connect()
        await settle()
        XCTAssertEqual(link.written, ["\u{3}"], "sent once, and what was typed behind it went with it")
        XCTAssertEqual(notices, [], "the phone shows nothing for an answer that came from elsewhere")
    }

    func testSendOnceRefusedByTheServerIsDropped() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.failures[Self.write] = [RexError(code: "block_not_found", message: "no such block", status: 404)]
        var ended: [TerminalStream.Delivery] = []
        s.sendOnce(text: "\r") { ended.append($0) }
        _ = await eventually { !ended.isEmpty }
        await settle()
        XCTAssertEqual(ended, [.refused])
        XCTAssertEqual(link.count(Self.write), 1)
    }

    func testStopTellsQueuedOnceInputThatItNeverLeft() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.held = [Self.write]
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        var ended: [TerminalStream.Delivery] = []
        s.sendOnce(text: "\r") { ended.append($0) }
        s.stop()
        XCTAssertEqual(ended, [.unsent])
        link.release()
        await settle()
        XCTAssertEqual(link.written, ["a"])
    }

    func testTheControlFindsARunningStreamByItsBlock() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        XCTAssertNil(s.control.stream(block: s.blockID), "not before it starts")
        s.start()
        XCTAssertTrue(s.control.stream(block: s.blockID) === s)
        XCTAssertNil(s.control.stream(block: "block:other"))
        s.stop()
        XCTAssertNil(s.control.stream(block: s.blockID))
    }

    // MARK: A typed key leaves in the turn it is typed (`StreamLink.start`)

    func testTextTypedWithNothingOutIsWithTheSocketBeforeSendReturns() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.held = [Self.write]
        s.send(text: "a")
        XCTAssertEqual(link.written, ["a"], "no task, no turn of the main actor between the key and its request")
        XCTAssertEqual(link.startedNow, 1)
        XCTAssertTrue(s.hasPendingInput, "in flight from before the hand-off")
        _ = await eventually { link.waitingCount == 1 }
        link.release()
        let idle = await eventually { !s.hasPendingInput }
        XCTAssertTrue(idle)
        XCTAssertEqual(link.written, ["a"])
    }

    /// A busy queue is as it was: what is typed behind a request waits for its answer, goes
    /// out in a task, in order, and nothing overtakes. The next key typed at an idle queue
    /// leaves in its own turn again.
    func testABurstBehindARequestKeepsItsOrderAndLeavesFromATask() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        link.held = [Self.write, "client.action"]
        s.send(text: "a")
        s.send(text: "b")
        action(s)
        s.send(text: "c")
        s.send(text: "d")
        XCTAssertEqual(link.inputTrace, ["w:a"], "only the first is out")
        XCTAssertEqual(link.startedNow, 1)
        var expected = ["w:a"]
        for next in ["w:b", "client.action", "w:cd"] {
            await settle()
            XCTAssertEqual(link.inputTrace, expected, "nothing overtakes the request that is out")
            link.release()
            expected.append(next)
            let sent = await eventually { link.inputTrace.count == expected.count }
            XCTAssertTrue(sent)
        }
        XCTAssertEqual(link.inputTrace, ["w:a", "w:b", "client.action", "w:cd"])
        XCTAssertEqual(link.startedNow, 1, "what waited went out from a task")
        link.release()
        let idle = await eventually { !s.hasPendingInput }
        XCTAssertTrue(idle)
        link.held = []
        s.send(text: "e")
        XCTAssertEqual(link.inputTrace.last, "w:e")
        XCTAssertEqual(link.startedNow, 2)
        XCTAssertEqual(notices, [])
    }

    /// A link whose `start` answers with a failure before it returns: `finished` runs inside
    /// `pump`. The request that never left is sent again once, the refused one is dropped,
    /// the lost one tells the user, and after each the queue is free for the next key.
    func testAStartThatFailsBeforeItReturnsSendsNothingTwiceAndLeavesNothingInFlight() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        // Never left: it stays first and goes out once, with what was typed behind it.
        link.startFailures = [RexError.unsent("socket is not connected")]
        s.send(text: "a")
        XCTAssertEqual(link.written, [], "the failed start sent nothing")
        s.send(text: "b")
        let sent = await eventually { !link.written.isEmpty && !s.hasPendingInput }
        XCTAssertTrue(sent)
        await settle()
        XCTAssertEqual(link.written.joined(), "ab")
        XCTAssertEqual(notices, [])

        // Refused: dropped, and the next key leaves at once.
        link.startFailures = [RexError(code: "not_found", message: "block not found", status: 404)]
        s.send(text: "c")
        XCTAssertFalse(s.hasPendingInput, "nothing is left in flight")
        s.send(text: "d")
        XCTAssertEqual(link.written.joined(), "abd")
        _ = await eventually { !s.hasPendingInput }
        XCTAssertEqual(notices, [])

        // The connection broke after the send: dropped, never sent again, and the user is told.
        link.startFailures = [RexError.local("connection lost")]
        s.send(text: "e")
        XCTAssertFalse(s.hasPendingInput)
        XCTAssertEqual(notices, [.inputLost])
        s.send(text: "f")
        let done = await eventually { !s.hasPendingInput }
        XCTAssertTrue(done)
        await settle()
        XCTAssertEqual(link.written.joined(), "abdf", "no request left twice")
    }

    func testALinkThatCannotStartNowSendsFromATaskAsBefore() async {
        let link = FakeLink()
        link.startsNow = false
        let (s, _) = stream(link)
        s.send(text: "a")
        s.send(text: "b")
        XCTAssertEqual(link.written, [])
        let sent = await eventually { link.written.joined() == "ab" && !s.hasPendingInput }
        XCTAssertTrue(sent)
        XCTAssertEqual(link.startedNow, 0)
    }

    /// Input that goes once runs in a task, as before, in its place: behind the key typed
    /// before it, and ahead of the key typed after it.
    func testSendOnceKeepsItsPlaceAroundKeysThatLeaveAtOnce() async {
        let link = FakeLink()
        let (s, _) = stream(link)
        var ended: [TerminalStream.Delivery] = []
        s.sendOnce(text: "\r") { ended.append($0) }
        XCTAssertEqual(link.written, [], "its request starts in a task")
        s.send(text: "a")
        XCTAssertEqual(link.written, [], "and a key typed behind it waits for it")
        let first = await eventually { link.inputTrace == ["w:\r", "w:a"] && !s.hasPendingInput }
        XCTAssertTrue(first)
        XCTAssertEqual(ended, [.delivered])

        link.held = [Self.write]
        s.send(text: "b")
        s.sendOnce(text: "y") { ended.append($0) }
        XCTAssertEqual(link.inputTrace, ["w:\r", "w:a", "w:b"])
        for _ in 0..<2 {
            await settle()
            link.release()
        }
        let second = await eventually { ended.count == 2 }
        XCTAssertTrue(second)
        XCTAssertEqual(link.inputTrace, ["w:\r", "w:a", "w:b", "w:y"])
        XCTAssertEqual(ended, [.delivered, .delivered])
        XCTAssertEqual(link.startedNow, 1, "only the key typed at an idle queue left in its own turn")
    }

    /// The click path (`TerminalHost.engineSendClick`: `sendOnce` with a hold) with keys that
    /// leave in their own turn. A click at an idle queue is in flight while it holds, so a key
    /// typed meanwhile starts nothing and stays behind it; the click is told once that it was
    /// delivered. A click behind a key that left in its own turn still waits for its turn
    /// before it is asked how long to hold.
    func testAHeldClickKeepsKeysBehindItThoughAKeyLeavesInItsOwnTurn() async {
        let link = FakeLink()
        let (s, log) = stream(link)
        let hold = Duration.milliseconds(30)
        log.held = [hold]
        var asked = 0
        var ended: [TerminalStream.Delivery] = []
        XCTAssertTrue(s.sendOnce(text: "C", hold: { asked += 1; return hold }) { ended.append($0) })
        let holding = await eventually { asked == 1 }
        XCTAssertTrue(holding, "its turn came at once: nothing was out")
        s.send(text: "a")
        s.send(text: "b")
        await settle()
        XCTAssertEqual(link.inputTrace, [], "the click holds, and the keys typed meanwhile wait behind it")
        XCTAssertEqual(link.startedNow, 0, "a key behind a request in flight starts nothing in its own turn")
        XCTAssertEqual(ended, [])
        log.release(hold)
        let sent = await eventually { link.inputTrace.count == 2 && !s.hasPendingInput }
        XCTAssertTrue(sent)
        XCTAssertEqual(link.inputTrace, ["w:C", "w:ab"])
        XCTAssertEqual(ended, [.delivered], "told once")

        // Behind a key that left in its own turn: the click waits for that key's answer.
        link.held = [Self.write]
        s.send(text: "c")
        XCTAssertEqual(link.inputTrace.last, "w:c")
        XCTAssertEqual(link.startedNow, 1)
        XCTAssertTrue(s.sendOnce(text: "D", hold: { asked += 1; return hold }) { ended.append($0) })
        s.send(text: "e")
        await settle()
        XCTAssertEqual(asked, 1, "not asked before its turn")
        link.release()
        let turn = await eventually { asked == 2 }
        XCTAssertTrue(turn)
        await settle()
        XCTAssertEqual(link.inputTrace, ["w:C", "w:ab", "w:c"], "holding at its turn")
        log.release(hold)
        for _ in 0..<2 {
            _ = await eventually { link.waitingCount == 1 }
            link.release()
        }
        let done = await eventually { !s.hasPendingInput }
        XCTAssertTrue(done)
        XCTAssertEqual(link.inputTrace, ["w:C", "w:ab", "w:c", "w:D", "w:e"])
        XCTAssertEqual(ended, [.delivered, .delivered])
        XCTAssertEqual(link.startedNow, 1)
        XCTAssertEqual(notices, [])
    }
}
