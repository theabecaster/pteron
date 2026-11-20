import XCTest
@testable import RexKit

/// The catch-up fence: no input reaches a program state the user has not seen.
@MainActor
final class StreamFenceTests: XCTestCase {
    private static let write = "com.superlogical.terminal.write"

    /// A sink that records the fence and lets a test hold back "everything is parsed".
    @MainActor
    final class Sink: TerminalSink {
        var fence: [Bool] = []
        var screens: [Bool] = []
        var statuses: [TerminalStream.Status] = []
        var fed = 0
        /// When true, `streamWhenParsed` waits for `finishParsing()`.
        var parsesLate = false
        private var parsed: [@MainActor () -> Void] = []

        func streamReset(cols: Int, rows: Int) {}
        func streamSnapshot(_ text: String) {}
        func streamGhosttySnapshot(_ part: GhosttySnapshotPart) -> Bool { true }
        func streamFeed(_ bytes: UnsafeBufferPointer<UInt8>) { fed += bytes.count }
        func streamResized(cols: Int, rows: Int, owner: String?) {}
        func streamTheme(_ theme: JSONObject) {}
        func streamExited(code: Int?) {}
        func streamStatus(_ status: TerminalStream.Status) { statuses.append(status) }
        func streamFence(_ up: Bool, screen: Bool) {
            fence.append(up)
            screens.append(screen)
        }
        func streamWhenParsed(_ done: @escaping @MainActor () -> Void) {
            if parsesLate { parsed.append(done) } else { done() }
        }
        var waitingForParse: Int { parsed.count }
        /// Answers the oldest question only.
        func finishOldest() {
            guard !parsed.isEmpty else { return }
            parsed.removeFirst()()
        }
        func finishParsing() {
            let p = parsed
            parsed = []
            for done in p { done() }
        }
    }

    private var notices: [String] = []
    private var streams: [TerminalStream] = []

    private func stream(_ link: FakeLink) -> (TerminalStream, Sink, SleepLog) {
        let sink = Sink()
        let (s, log) = makeStream(link: link, sink: sink)
        s.onActionFailed = { [weak self] in self?.notices.append($0) }
        streams.append(s)
        return (s, sink, log)
    }

    /// A stream that is live with a current screen: its fence is down.
    private func current(_ link: FakeLink) async -> (TerminalStream, Sink, SleepLog) {
        let (s, sink, log) = stream(link)
        s.start()
        await catchUp(s, link)
        return (s, sink, log)
    }

    /// Drops the data socket; the RESUME's socket answers only when the test says so.
    private func dropAndWaitForResume(_ link: FakeLink, _ s: TerminalStream) async -> FakeSocket {
        let before = link.sockets.count
        link.plans = [.silent]
        link.sockets.last?.drop()
        let opened = await eventually { link.sockets.count == before + 1 && link.sockets.last?.sent.count == 1 }
        XCTAssertTrue(opened)
        XCTAssertTrue(link.sockets.last?.isResume == true)
        XCTAssertTrue(s.isFenced)
        return link.sockets.last!
    }

    private var message: String { TerminalStream.fenceDroppedMessage }

    // MARK: Up and down

    func testAColdStartIsFencedUntilItsSnapshotHasArrived() async {
        let link = FakeLink()
        let (s, sink, _) = stream(link)
        XCTAssertFalse(s.isFenced)
        s.start()
        XCTAssertTrue(s.isFenced)
        _ = await eventually { sink.statuses.last == .live }
        await settle()
        XCTAssertTrue(s.isFenced, "a WELCOME alone is not a screen")
        await catchUp(s, link)
        XCTAssertEqual(sink.fence, [true, false])
        XCTAssertEqual(sink.screens.first, false, "nothing to show when it went up")
    }

    func testADropRaisesTheFenceAndTheResumeLowersIt() async {
        let link = FakeLink()
        let (s, sink, _) = await current(link)
        let socket = await dropAndWaitForResume(link, s)
        socket.push(FakeLink.welcome())
        let down = await eventually { !s.isFenced }
        XCTAssertTrue(down)
        XCTAssertEqual(sink.fence, [true, false, true, false])
        XCTAssertEqual(sink.screens.last, true)
    }

    func testAWakeIsFencedUntilTheSocketAnswers() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        link.sockets[0].pingPlan = .answer
        s.wake()
        XCTAssertTrue(s.isFenced)
        s.send(text: "ls\r")
        let sent = await eventually { link.written == ["ls\r"] }
        XCTAssertTrue(sent, "an idle pane's keys arrive")
        XCTAssertFalse(s.isFenced)
        XCTAssertEqual(notices, [])
    }

    func testAWakeOnADeadSocketStaysFencedThroughTheResume() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        link.sockets[0].pingPlan = .fail
        link.plans = [.silent]
        s.wake()
        s.send(text: "x")
        let resumed = await eventually { link.sockets.count == 2 && link.sockets[1].sent.count == 1 }
        XCTAssertTrue(resumed)
        await settle()
        XCTAssertTrue(s.isFenced)
        XCTAssertEqual(link.written, [])
        link.sockets[1].push(FakeLink.welcome())
        let sent = await eventually { link.written == ["x"] }
        XCTAssertTrue(sent)
    }

    func testTheFenceWaitsForTheSinkToParseWhatItHas() async {
        let link = FakeLink()
        let (s, sink, _) = await current(link)
        sink.parsesLate = true
        let socket = await dropAndWaitForResume(link, s)
        socket.push(FakeLink.welcome())
        let asked = await eventually { sink.waitingForParse > 0 }
        XCTAssertTrue(asked)
        await settle()
        XCTAssertTrue(s.isFenced, "unparsed output is not on the screen yet")
        sink.finishParsing()
        let down = await eventually { !s.isFenced }
        XCTAssertTrue(down)
    }

    func testOutputWhileTheSinkParsesStartsTheQuietWaitOver() async {
        let link = FakeLink()
        let (s, sink, _) = await current(link)
        sink.parsesLate = true
        let socket = await dropAndWaitForResume(link, s)
        socket.push(FakeLink.welcome())
        _ = await eventually { sink.waitingForParse > 0 }
        socket.push(Array("more".utf8))
        // The new output asks again, once it has been quiet.
        let again = await eventually { sink.fed == 4 && sink.waitingForParse == 2 }
        XCTAssertTrue(again)
        // The answer to the question asked before the output lowers nothing.
        sink.finishOldest()
        await settle()
        XCTAssertTrue(s.isFenced, "the screen changed after the sink was asked")
        sink.finishParsing()
        let down = await eventually { !s.isFenced }
        XCTAssertTrue(down)
    }

    // MARK: Hazard 1: typing on a stale screen

    func testAZeroByteCatchUpSendsHeldKeysInOrderOnce() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        let socket = await dropAndWaitForResume(link, s)
        XCTAssertTrue(s.send(text: "g"))
        XCTAssertTrue(s.send(text: "it st"))
        XCTAssertTrue(s.send(text: "atus\r"))
        await settle()
        XCTAssertEqual(link.written, [], "nothing leaves behind the fence")
        socket.push(FakeLink.welcome())
        let sent = await eventually { !link.written.isEmpty }
        XCTAssertTrue(sent)
        await settle()
        XCTAssertEqual(link.written, ["git status\r"])
        XCTAssertEqual(notices, [])
    }

    func testBytesDuringTheFenceDropHeldKeysWithOneNotice() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        let socket = await dropAndWaitForResume(link, s)
        s.send(text: "y\r")
        socket.push(FakeLink.welcome())
        socket.push(Array("Overwrite? [y/N] ".utf8))
        let down = await eventually { !s.isFenced }
        XCTAssertTrue(down)
        s.send(text: "after")
        _ = await eventually { !link.written.isEmpty }
        await settle()
        XCTAssertEqual(link.written, ["after"], "only what was typed at the current screen")
        XCTAssertEqual(notices, [message])
    }

    func testAResizeDuringTheFenceDropsHeldKeys() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        let socket = await dropAndWaitForResume(link, s)
        s.send(text: "q")
        socket.push(FakeLink.welcome())
        socket.push(Wire.resize(cols: 100, rows: 30))
        let down = await eventually { !s.isFenced }
        XCTAssertTrue(down)
        await settle()
        XCTAssertEqual(link.written, [])
        XCTAssertEqual(notices, [message])
    }

    func testHeldKeysExpireAfterTheirLife() async {
        let link = FakeLink()
        let (s, _, log) = await current(link)
        s.fence.timing.heldLife = .milliseconds(30)
        log.real.insert(.milliseconds(30))
        let socket = await dropAndWaitForResume(link, s)
        s.send(text: "x")
        let told = await eventually { self.notices == [self.message] }
        XCTAssertTrue(told)
        XCTAssertTrue(s.isFenced, "the fence itself stays up")
        // The rest of the line must not arrive alone.
        s.send(text: "yz\r")
        socket.push(FakeLink.welcome())
        let down = await eventually { !s.isFenced }
        XCTAssertTrue(down)
        await settle()
        XCTAssertEqual(link.written, [])
        XCTAssertEqual(notices, [message])
    }

    func testAColdOpenDropsTypedKeys() async {
        let link = FakeLink()
        let (s, _, _) = stream(link)
        s.start()
        XCTAssertTrue(s.send(text: "rm -rf x\r"))
        await catchUp(s, link)
        await settle()
        XCTAssertEqual(link.written, [])
        XCTAssertEqual(notices, [message])
    }

    func testInputQueuedBeforeTheFenceGoesOnlyOverAnExactScreen() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        // Typed at a current screen, behind a write that is out.
        link.held = [Self.write]
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        s.send(text: "b")
        let socket = await dropAndWaitForResume(link, s)
        link.held = []
        link.release()
        await settle()
        XCTAssertEqual(link.written, ["a"], "b waits for the fence")
        socket.push(FakeLink.welcome())
        let sent = await eventually { link.written == ["a", "b"] }
        XCTAssertTrue(sent)
        XCTAssertEqual(notices, [])
    }

    func testInputQueuedBeforeTheFenceIsDroppedWhenTheScreenChanged() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        link.held = [Self.write]
        s.send(text: "a")
        _ = await eventually { link.waitingCount == 1 }
        s.send(text: "b")
        var ended: [Bool] = []
        s.perform(action: "pane.clear", args: nil, ended: { ended.append($0) }) { _ in }
        let socket = await dropAndWaitForResume(link, s)
        link.held = []
        link.release()
        socket.push(FakeLink.welcome())
        socket.push(Array("changed".utf8))
        let down = await eventually { !s.isFenced }
        XCTAssertTrue(down)
        await settle()
        XCTAssertEqual(link.inputTrace, ["w:a"])
        XCTAssertEqual(ended, [false])
        XCTAssertEqual(notices, [message])
    }

    // MARK: Hazard 2: keys encoded under stale modes

    func testAModeChangeDuringTheFenceDropsKeysEncodedBeforeIt() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        let socket = await dropAndWaitForResume(link, s)
        // An arrow key as the old screen's modes encode it.
        s.send(Array("\u{1b}[A".utf8))
        socket.push(FakeLink.welcome())
        // The program switched to application cursor keys meanwhile.
        socket.push(Array("\u{1b}[?1h".utf8))
        let down = await eventually { !s.isFenced }
        XCTAssertTrue(down)
        await settle()
        XCTAssertEqual(link.written, [])
        XCTAssertEqual(notices, [message])
    }

    // MARK: Hazard 3: reports at stale coordinates

    func testReportsAreDroppedWhileFencedNeverHeld() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        let click = Array("\u{1b}[<0;10;5M".utf8)
        XCTAssertTrue(s.send(report: click))
        _ = await eventually { link.written.count == 1 }
        let socket = await dropAndWaitForResume(link, s)
        XCTAssertFalse(s.send(report: click))
        XCTAssertEqual(s.fence.heldCount, 0)
        socket.push(FakeLink.welcome())
        let down = await eventually { !s.isFenced }
        XCTAssertTrue(down)
        await settle()
        XCTAssertEqual(link.written.count, 1, "the report from behind the fence never arrives")
        XCTAssertEqual(notices, [], "a dropped report says nothing")
    }

    // MARK: Hazard 4: server actions bound to keys

    func testKeyBoundActionsAndForwardedKeysAreDroppedWhileFenced() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        let socket = await dropAndWaitForResume(link, s)
        var ended: [Bool] = []
        s.perform(action: "pane.clear", args: nil, ended: { ended.append($0) }) { _ in }
        s.forward(key: ["key": "F5"])
        s.perform(action: "pane.close", args: nil, origin: .palette, title: "Close Pane", ended: { ended.append($0) }) { _ in }
        socket.push(FakeLink.welcome())
        let down = await eventually { !s.isFenced }
        XCTAssertTrue(down)
        await settle()
        XCTAssertEqual(link.inputTrace, [])
        XCTAssertEqual(ended, [false, false])
        XCTAssertEqual(notices, [message])
    }

    func testInputThatGoesOnceIsUnsentWhileFenced() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        _ = await dropAndWaitForResume(link, s)
        var got: [TerminalStream.Delivery] = []
        s.sendOnce(text: "\r") { got.append($0) }
        XCTAssertEqual(got, [.unsent])
        await settle()
        XCTAssertEqual(link.written, [])
    }

    // MARK: Fit claims

    func testAPendingClaimKeepsTheFenceUp() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        s.setClaimPending(true)
        let socket = await dropAndWaitForResume(link, s)
        socket.push(FakeLink.welcome())
        await settle()
        XCTAssertTrue(s.isFenced, "a resize is on its way")
        s.setClaimPending(false)
        let down = await eventually { !s.isFenced }
        XCTAssertTrue(down)
    }

    func testOurOwnResizeEchoedWaitsTheLongerQuiet() async {
        let link = FakeLink()
        let (s, _, log) = await current(link)
        s.setClaimPending(true)
        let socket = await dropAndWaitForResume(link, s)
        s.send(text: "k")
        socket.push(FakeLink.welcome())
        socket.push(Wire.resize(cols: 60, rows: 40, owner: "client:test"))
        await settle()
        s.setClaimPending(false)
        let down = await eventually { !s.isFenced }
        XCTAssertTrue(down)
        XCTAssertTrue(log.asked.contains(.milliseconds(60)))
        await settle()
        XCTAssertEqual(link.written, [], "a resize is a change, ours too")
        XCTAssertEqual(notices, [message])
    }

    // MARK: Hazard 9: a refused resume

    func testARefusedResumeStartsFreshAndKeepsTheFenceUp() async {
        let link = FakeLink()
        let (s, sink, _) = await current(link)
        link.plans = [.reject(0x01)]
        link.sockets[0].drop()
        _ = await eventually { s.isFenced }
        s.send(text: "typed at the old screen")
        let fresh = await eventually { link.sockets.count == 3 && link.sockets[2].isHello && sink.statuses.last == .live }
        XCTAssertTrue(fresh)
        await settle()
        XCTAssertTrue(s.isFenced, "up from the drop until the new snapshot")
        XCTAssertEqual(sink.fence, [true, false, true])
        await catchUp(s, link)
        await settle()
        XCTAssertEqual(link.written, [])
        XCTAssertEqual(notices, [message])
    }

    // MARK: Hazard 10: the fence can't stick

    func testABusyPaneComesDownAtTheCap() async {
        let link = FakeLink()
        let (s, _, log) = await current(link)
        s.fence.timing.cap = .milliseconds(80)
        log.real = [.milliseconds(80), .milliseconds(40)]
        let socket = await dropAndWaitForResume(link, s)
        socket.push(FakeLink.welcome())
        // Output every 10 ms: never 40 ms of quiet.
        let flood = Task { @MainActor in
            for _ in 0..<60 {
                socket.push(Array("y\n".utf8))
                try? await Task.sleep(for: .milliseconds(10))
            }
        }
        let start = ContinuousClock.now
        let down = await eventually { !s.isFenced }
        let took = ContinuousClock.now - start
        flood.cancel()
        XCTAssertTrue(down)
        XCTAssertLessThan(took, .milliseconds(500))
        XCTAssertGreaterThanOrEqual(took, .milliseconds(60))
    }

    func testAFlappingLinkEndsWithTheFenceDown() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        // Five drops in a row, each resumed, with a key typed in each gap.
        for i in 0..<5 {
            let socket = await dropAndWaitForResume(link, s)
            s.send(text: "\(i)")
            socket.push(FakeLink.welcome())
            let down = await eventually { !s.isFenced }
            XCTAssertTrue(down, "drop \(i)")
        }
        _ = await eventually { link.written.count == 5 }
        XCTAssertEqual(link.written, ["0", "1", "2", "3", "4"])
        XCTAssertEqual(notices, [])
    }

    func testADropBeforeTheResumeArrivesKeepsOneFence() async {
        let link = FakeLink()
        let (s, sink, _) = await current(link)
        let first = await dropAndWaitForResume(link, s)
        s.send(text: "a")
        // The RESUME's socket dies before its WELCOME: a fresh start follows.
        first.drop()
        let fresh = await eventually { link.sockets.count == 3 }
        XCTAssertTrue(fresh)
        XCTAssertEqual(sink.fence, [true, false, true], "still the same fence")
        await catchUp(s, link)
        await settle()
        XCTAssertEqual(link.written, [])
        XCTAssertEqual(notices, [message])
    }

    // MARK: Hazard 11: never annoying

    func testAtMostOneNoticePerFence() async {
        let link = FakeLink()
        let (s, sink, _) = await current(link)
        // The sink is slow to parse, so the fence stays up while the rest is typed.
        sink.parsesLate = true
        let socket = await dropAndWaitForResume(link, s)
        s.send(text: "a")
        socket.push(FakeLink.welcome())
        socket.push(Array("out".utf8))
        _ = await eventually { self.notices.count == 1 }
        XCTAssertTrue(s.isFenced)
        s.send(text: "b")
        s.perform(action: "pane.clear", args: nil) { _ in }
        s.forward(key: ["key": "F5"])
        s.noteFenceDrop()
        socket.push(Array("more".utf8))
        _ = await eventually { sink.fed == 7 }
        await settle()
        sink.parsesLate = false
        sink.finishParsing()
        let down = await eventually { !s.isFenced }
        XCTAssertTrue(down)
        await settle()
        XCTAssertEqual(notices, [message])
        XCTAssertEqual(link.inputTrace, [])
    }

    func testNoNoticeWhenNothingWasTyped() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        let socket = await dropAndWaitForResume(link, s)
        socket.push(FakeLink.welcome())
        socket.push(Array("a lot changed".utf8))
        socket.push(Wire.resize(cols: 90, rows: 20))
        let down = await eventually { !s.isFenced }
        XCTAssertTrue(down)
        await settle()
        XCTAssertEqual(notices, [])
    }

    func testEachFenceMayTellOnce() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        for _ in 0..<2 {
            let socket = await dropAndWaitForResume(link, s)
            s.send(text: "a")
            socket.push(FakeLink.welcome())
            socket.push(Array("out".utf8))
            let down = await eventually { !s.isFenced }
            XCTAssertTrue(down)
        }
        XCTAssertEqual(notices, [message, message])
    }

    // MARK: Around it

    func testWorkWaitsForTheCurrentScreen() async {
        let link = FakeLink()
        let (s, _, _) = await current(link)
        var ran = 0
        s.whenCurrent { ran += 1 }
        XCTAssertEqual(ran, 1, "at once when the fence is down")
        let socket = await dropAndWaitForResume(link, s)
        s.whenCurrent { ran += 1 }
        await settle()
        XCTAssertEqual(ran, 1)
        socket.push(FakeLink.welcome())
        let done = await eventually { ran == 2 }
        XCTAssertTrue(done)
    }

    func testStopDropsHeldKeysAndWaitingWorkAndSaysNothing() async {
        let link = FakeLink()
        let (s, sink, _) = await current(link)
        _ = await dropAndWaitForResume(link, s)
        var ran = false
        s.send(text: "a")
        s.whenCurrent { ran = true }
        s.stop()
        XCTAssertFalse(s.isFenced)
        XCTAssertEqual(sink.fence.last, false)
        await settle()
        XCTAssertFalse(ran)
        XCTAssertEqual(link.written, [])
        XCTAssertEqual(notices, [])
    }

    func testAClosedPaneDropsHeldKeysAndSaysSo() async {
        let link = FakeLink()
        let (s, sink, _) = await current(link)
        sink.parsesLate = true
        let socket = await dropAndWaitForResume(link, s)
        s.send(text: "a")
        socket.push(FakeLink.welcome())
        _ = await eventually { sink.statuses.last == .live }
        // Before the fence comes down, the server says the pane closed.
        socket.drop(code: 4000)
        _ = await eventually { sink.statuses.last == .ended("pane closed") }
        sink.finishParsing()
        await settle()
        XCTAssertEqual(link.written, [])
        XCTAssertEqual(notices, [message])
        XCTAssertFalse(s.isFenced)
    }
}
