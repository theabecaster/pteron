import RexKit
import XCTest
@testable import RexDuo

/// The host stops its stream reading the data socket while the engine has megabytes still to
/// parse, and lets it go on once the engine has caught up.
@MainActor
final class TerminalBackpressureTests: XCTestCase {
    /// Runs what is on the main queue now: the engine reports from the thread that crossed a
    /// mark, and the host acts on it a main-queue turn later.
    private func drainMain() {
        let ran = expectation(description: "main queue")
        DispatchQueue.main.async { ran.fulfill() }
        wait(for: [ran], timeout: 2)
    }

    func testABackedUpCorePausesItsStreamUntilItHasCaughtUp() {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = TerminalStream(control: control, sessionID: "s", blockID: "b")
        let host = TerminalHost(stream: stream, sizing: .mirror, fontSize: 12, theme: ThemeStore.fallback)
        let core = host.term.core
        XCTAssertFalse(stream.readingPaused)

        // Park the feed queue, so what the stream delivers piles up unparsed.
        let gate = DispatchSemaphore(value: 0), parked = DispatchSemaphore(value: 0)
        core.enqueue {
            parked.signal()
            gate.wait()
        }
        parked.wait()
        let chunk = [UInt8](repeating: 0x61, count: 256 * 1024)
        var fed = 0
        while fed <= GhosttyCore.backlogHighWater {
            XCTAssertFalse(core.isBackedUp)
            chunk.withUnsafeBufferPointer { host.streamFeed($0) }
            fed += chunk.count
            drainMain()
            XCTAssertEqual(stream.readingPaused, core.isBackedUp, "after \(fed) bytes")
        }
        XCTAssertTrue(core.isBackedUp)
        XCTAssertTrue(stream.readingPaused)

        // The parser catches up: below the low-water mark the stream reads again.
        gate.signal()
        core.sync()
        XCTAssertFalse(core.isBackedUp)
        drainMain()
        XCTAssertFalse(stream.readingPaused)
        XCTAssertEqual(core.bytesParsed, fed)
        XCTAssertEqual(core.droppedBytes, 0)
    }

    /// The signal can arrive late and out of order (it is sent from two threads): the host acts
    /// on the engine's state when it gets there, not on the event.
    func testALateSignalAppliesTheStateOfTheMoment() {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = TerminalStream(control: control, sessionID: "s", blockID: "b")
        let host = TerminalHost(stream: stream, sizing: .mirror, fontSize: 12, theme: ThemeStore.fallback)
        let core = host.term.core
        let chunk = [UInt8](repeating: 0x61, count: GhosttyCore.backlogHighWater + 1)
        // Backed up and caught up again before the main queue ran once.
        chunk.withUnsafeBufferPointer { host.streamFeed($0) }
        core.sync()
        XCTAssertFalse(core.isBackedUp)
        drainMain()
        XCTAssertFalse(stream.readingPaused)
    }
}
