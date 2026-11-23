import Metal
import Synchronization
import XCTest
@testable import Pteron

func ghosttyFixture(_ name: String) throws -> [UInt8] {
    let url = try XCTUnwrap(Bundle(for: GhosttyCoreTests.self).url(forResource: name, withExtension: "bin"))
    return [UInt8](try Data(contentsOf: url))
}

/// A flag and a counter other threads can set.
final class GhosttyTestFlag: Sendable {
    private let value = Atomic<Int>(0)
    var isSet: Bool { value.load(ordering: .relaxed) > 0 }
    var count: Int { value.load(ordering: .relaxed) }
    func set() { value.store(1, ordering: .relaxed) }
    func add() { value.add(1, ordering: .relaxed) }
}

final class GhosttyCoreTests: XCTestCase {
    private func feed(_ core: GhosttyCore, _ text: String) {
        core.feed(Array(text.utf8))
        core.sync()
    }

    /// Parks the feed queue until `gate` is signalled. Returns once it is parked, so what is fed
    /// next is queued, not taken.
    private func holdQueue(of core: GhosttyCore, until gate: DispatchSemaphore) {
        let parked = DispatchSemaphore(value: 0)
        core.enqueue {
            parked.signal()
            gate.wait()
        }
        parked.wait()
    }

    func testFeedGivesRowTextAndCursor() {
        let core = GhosttyCore(cols: 40, rows: 5)
        feed(core, "hello\r\n\u{1b}[1;32mworld\u{1b}[0m!")
        XCTAssertEqual(core.rowText(0), "hello")
        XCTAssertEqual(core.rowText(1), "world!")
        XCTAssertEqual(core.cursorPosition.x, 6)
        XCTAssertEqual(core.cursorPosition.y, 1)
        XCTAssertEqual(core.gridSize.cols, 40)
        XCTAssertEqual(core.gridSize.rows, 5)
    }

    func testBytesSplitAnywhereParseTheSame() {
        let core = GhosttyCore(cols: 40, rows: 5)
        let bytes = Array("a\u{1b}[31mé日\u{1b}[0mz".utf8)
        for b in bytes { core.feed([b]) }
        core.sync()
        XCTAssertEqual(core.rowText(0), "aé日z")
    }

    func testResizeReflows() {
        let core = GhosttyCore(cols: 20, rows: 6)
        feed(core, String(repeating: "x", count: 30) + "\r\nend")
        XCTAssertEqual(core.rowText(0).count, 20)
        XCTAssertEqual(core.rowText(1).count, 10)
        XCTAssertEqual(core.rowText(2), "end")
        core.resize(cols: 40, rows: 6, cellWidthPx: 8, cellHeightPx: 16)
        core.sync()
        XCTAssertEqual(core.gridSize.cols, 40)
        XCTAssertEqual(core.rowText(0).count, 30)
        XCTAssertEqual(core.rowText(1), "end")
    }

    func testScrollbackIsKeptBeyondTheDefaultLimit() {
        let core = GhosttyCore(cols: 80, rows: 24)
        var text = ""
        for i in 1...5000 { text += "line \(i)\r\n" }
        feed(core, text)
        // The library's default (10,000 bytes, one page) would keep only a few hundred rows.
        XCTAssertGreaterThan(core.scrollbackRows, 4000)
        XCTAssertEqual(core.rowText(22), "line 5000")
    }

    func testSnapshotRestoreThenLiveBytes() throws {
        let capture = try ghosttyFixture("ghostty-history")
        XCTAssertTrue(GhosttyCore.isSnapshot(capture))
        let core = GhosttyCore(cols: 80, rows: 24)
        feed(core, "this is replaced by the snapshot")
        // The completion runs on the feed queue.
        let consumed = Mutex<Int?>(nil)
        core.restore(snapshot: capture, trailing: { GhosttyDemo.stripRexMessages($0) }) { used in
            consumed.withLock { $0 = used }
        }
        core.sync()
        let used = try XCTUnwrap(consumed.withLock { $0 })
        // The snapshot ends exactly where Rex's first control message starts.
        XCTAssertEqual(Array(capture[used..<(used + 7)]), Array("\u{1b}_rex1;".utf8))
        XCTAssertEqual(core.gridSize.cols, 80)
        XCTAssertEqual(core.gridSize.rows, 24)
        // History from the server's `seq 1 2000`, restored into scrollback.
        XCTAssertGreaterThan(core.scrollbackRows, 1900)
        let screen = (0..<24).map { core.rowText($0) }
        XCTAssertFalse(screen.contains { $0.contains("replaced by the snapshot") })
        XCTAssertTrue(screen.contains("2000"), "\(screen)")
        // Live bytes after the snapshot.
        XCTAssertTrue(screen.contains("hello-1b"), "\(screen)")
    }

    func testSnapshotThenSeqOutput() throws {
        let capture = try ghosttyFixture("ghostty-seq2000")
        let core = GhosttyCore(cols: 80, rows: 24)
        core.restore(snapshot: capture, trailing: { GhosttyDemo.stripRexMessages($0) }) { _ in }
        core.sync()
        let screen = (0..<24).map { core.rowText($0) }
        XCTAssertTrue(screen.contains("1999") && screen.contains("2000"), "\(screen)")
        XCTAssertGreaterThan(core.scrollbackRows, 1900)
    }

    /// Resizing to the old local grid and back would cut an alternate screen.
    func testRestoredTerminalKeepsTheSnapshotGrid() throws {
        let capture = try ghosttyFixture("ghostty-history")
        let core = GhosttyCore(cols: 60, rows: 10)
        core.restore(snapshot: capture) { _ in }
        core.sync()
        XCTAssertEqual(core.gridSize.cols, 80)
        XCTAssertEqual(core.gridSize.rows, 24)
    }

    func testBadSnapshotFailsAndKeepsTheTerminal() throws {
        var capture = try ghosttyFixture("ghostty-history")
        capture[40] ^= 0xff // breaks a record CRC
        let core = GhosttyCore(cols: 40, rows: 5)
        feed(core, "still here")
        let result = Mutex<Int?>(-1)
        core.restore(snapshot: capture) { used in result.withLock { $0 = used } }
        core.sync()
        XCTAssertNil(result.withLock { $0 })
        XCTAssertEqual(core.rowText(0), "still here")
        XCTAssertFalse(GhosttyCore.isSnapshot(Array("plain text".utf8)))
    }

    /// What comes after the snapshot in the same buffer is parsed with the restore, so nothing
    /// that was fed later can get in front of it. (Bytes fed from a completion handler could:
    /// they were queued behind work already taken off the queue.)
    func testBytesBehindTheSnapshotAreParsedBeforeAnythingFedLater() throws {
        let source = GhosttyCore(cols: 40, rows: 5)
        feed(source, "restored>")
        let snapshot = try XCTUnwrap(source.encodeSnapshot())
        XCTAssertTrue(GhosttyCore.isSnapshot(snapshot))
        let core = GhosttyCore(cols: 40, rows: 5)
        // Everything below is queued before any of it runs.
        let gate = DispatchSemaphore(value: 0)
        holdQueue(of: core, until: gate)
        let seen = Mutex<[UInt8]>([])
        core.restore(snapshot: snapshot + Array("FIRST".utf8), trailing: { rest in
            seen.withLock { $0 = Array(rest) }
            return Array(rest) + Array("-first".utf8)
        }, completion: { XCTAssertEqual($0, snapshot.count) })
        core.feed(Array(" then second".utf8))
        core.resize(cols: 60, rows: 5, cellWidthPx: 8, cellHeightPx: 16)
        core.feed(Array(" then third".utf8))
        gate.signal()
        core.sync()
        XCTAssertEqual(seen.withLock { $0 }, Array("FIRST".utf8))
        XCTAssertEqual(core.rowText(0), "restored>FIRST-first then second then third")
        XCTAssertEqual(core.gridSize.cols, 60)
        XCTAssertEqual(core.backlogBytes, 0)
        // A snapshot that fails parses nothing of the buffer.
        var broken = snapshot
        broken[40] ^= 0xff
        core.restore(snapshot: broken + Array("NEVER".utf8), trailing: { Array($0) }) { XCTAssertNil($0) }
        core.sync()
        XCTAssertEqual(core.rowText(0), "restored>FIRST-first then second then third")
    }

    // MARK: Synchronized output across a restore

    /// A snapshot taken while the program held the screen (mode 2026) restores held: what the
    /// program writes until it releases the screen is not shown piece by piece.
    func testASnapshotTakenInsideASynchronizedUpdateRestoresHeld() throws {
        let source = GhosttyCore(cols: 30, rows: 4)
        feed(source, "old\u{1b}[?2026h\r\u{1b}[Khalf")
        let snapshot = try XCTUnwrap(source.encodeSnapshot())
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)

        let core = GhosttyCore(cols: 30, rows: 4)
        core.resize(cols: 30, rows: 4, cellWidthPx: 8, cellHeightPx: 16)
        core.restore(snapshot: snapshot) { XCTAssertNotNil($0) }
        core.sync()
        let frame = GhosttyFrameBuilder(atlas: atlas)
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rows[0].glyphs.count, 4, "the snapshot's screen, which is all there is to show")
        feed(core, " and the rest")
        _ = frame.update(core: core)
        XCTAssertEqual(frame.rows[0].glyphs.count, 4, "the program still holds the screen")
        XCTAssertEqual(core.rowText(0), "half and the rest", "the terminal itself has moved on")
        feed(core, "\u{1b}[?2026l")
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rows[0].glyphs.count, 14, "released by the program's own reset")
        // The next hold works as ever.
        feed(core, "\u{1b}[?2026h\r\u{1b}[Knext")
        _ = frame.update(core: core)
        XCTAssertEqual(frame.rows[0].glyphs.count, 14)
        feed(core, "\u{1b}[?2026l")
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rows[0].glyphs.count, 4)

        // A program that never releases it: the time limit runs from the restore.
        let stuck = GhosttyCore(cols: 30, rows: 4)
        stuck.restore(snapshot: snapshot) { _ in }
        stuck.sync()
        let other = GhosttyFrameBuilder(atlas: atlas)
        XCTAssertTrue(other.update(core: stuck))
        feed(stuck, " more")
        _ = other.update(core: stuck)
        XCTAssertEqual(other.rows[0].glyphs.count, 4)
        XCTAssertTrue(other.update(core: stuck, now: CACurrentMediaTime() + GhosttyCore.renderHoldTimeout + 0.1))
        XCTAssertEqual(other.rows[0].glyphs.count, 8)

        // A snapshot outside a synchronized update restores free.
        let free = GhosttyCore(cols: 30, rows: 4)
        feed(source, "\u{1b}[?2026l")
        free.restore(snapshot: try XCTUnwrap(source.encodeSnapshot())) { _ in }
        free.sync()
        let third = GhosttyFrameBuilder(atlas: atlas)
        XCTAssertTrue(third.update(core: free))
        feed(free, "!")
        XCTAssertTrue(third.update(core: free))
        XCTAssertEqual(third.rows[0].glyphs.count, 5)
    }

    // MARK: Restores under a selection

    /// The core owns the reference a selection drag is anchored with, and a restore frees it
    /// with the terminal it points into.
    func testARestoreFreesTheTrackedReferencesOfTheOldTerminal() throws {
        let core = GhosttyCore(cols: 40, rows: 5)
        feed(core, "hello world")
        let one = GhosttySelectionAnchor(core: core), two = GhosttySelectionAnchor(core: core)
        core.beginSelection(col: 7, row: 0, word: false, anchor: two)
        XCTAssertTrue(core.beginSelection(col: 0, row: 0, word: true, anchor: one))
        XCTAssertTrue(core.hasSelection)
        XCTAssertEqual(core.withTerminal { _ in core.trackedRefs.count }, 2)
        core.restore(snapshot: try XCTUnwrap(core.encodeSnapshot())) { XCTAssertNotNil($0) }
        core.sync()
        XCTAssertEqual(core.withTerminal { _ in core.trackedRefs.count }, 0)
        XCTAssertFalse(core.hasSelection, "the selection went with the old terminal")
        XCTAssertNil(core.selectionExtent)
        XCTAssertEqual(core.extendSelection(col: 3, row: 0, anchor: one, keepOnAnchor: false), .noAnchor)
        XCTAssertFalse(core.hasSelection)
        // The anchors are usable again on the new terminal.
        XCTAssertTrue(core.beginSelection(col: 0, row: 0, word: true, anchor: one))
        XCTAssertEqual(core.selectedText, "hello")
        core.endSelection(anchor: one)
        core.endSelection(anchor: two)
        XCTAssertEqual(core.withTerminal { _ in core.trackedRefs.count }, 0)
    }

    /// Snapshots land on the feed queue while the main thread drags a selection and a render
    /// thread draws. Nothing may read a reference into a terminal that is being freed.
    func testRestoresWhileSelectingAndDrawing() throws {
        let source = GhosttyCore(cols: 40, rows: 10)
        feed(source, (1...200).map { "line \($0) alpha beta gamma\r\n" }.joined())
        let snapshot = try XCTUnwrap(source.encodeSnapshot())
        let before = GhosttyCore.liveTerminals.load(ordering: .relaxed)
        let core = GhosttyCore(cols: 40, rows: 10)
        feed(core, "some words to start with\r\nand a second line")

        let stop = GhosttyTestFlag()
        // The render thread: every frame takes the terminal lock, then the render state.
        let drawn = GhosttyTestFlag()
        let frames = GhosttyTestFlag()
        Thread.detachNewThread {
            let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
            let renderer = GhosttyRenderer(core: core, atlas: atlas)
            var target: MTLTexture?
            if let device = GhosttyMetal.shared?.device {
                let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 40 * atlas.metrics.cellWidth,
                                                                 height: 10 * atlas.metrics.cellHeight, mipmapped: false)
                d.usage = [.renderTarget, .shaderRead]
                target = device.makeTexture(descriptor: d)
            }
            while !stop.isSet {
                if let target { renderer.renderOffscreen(into: target) } else { _ = renderer.frame.update(core: core) }
                frames.set()
            }
            drawn.set()
        }
        // The first frame compiles the shaders and builds the atlas, which can take longer than
        // all the restores: without this wait they could finish before anything was drawn.
        while !frames.isSet { usleep(1000) }
        // The stream: a snapshot, then live bytes, again and again.
        let restores = 400
        let fed = GhosttyTestFlag()
        Thread.detachNewThread {
            for i in 0..<restores {
                core.restore(snapshot: snapshot, trailing: { _ in Array("after \(i)\r\n".utf8) }) { _ in }
                core.feed(Array("live \(i) one two three\r\n".utf8))
                if i % 4 == 3 { core.sync() }
            }
            core.sync()
            fed.set()
        }
        // The main thread: a drag that never ends.
        let anchor = GhosttySelectionAnchor(core: core)
        var rounds = 0, extended = 0
        while !fed.isSet {
            core.beginSelection(col: rounds % 30, row: rounds % 10, word: rounds % 2 == 0, anchor: anchor)
            for step in 0..<4 {
                if case .extended = core.extendSelection(col: (rounds * 7 + step) % 40, row: (rounds * 3 + step) % 10,
                                                         anchor: anchor, keepOnAnchor: false) { extended += 1 }
                _ = core.selectionExtent
                _ = core.selectedText
            }
            if rounds % 3 == 0 { _ = core.beginSelectionAdjust(movingStart: rounds % 2 == 0, anchor: anchor) }
            if rounds % 5 == 0 { core.endSelection(anchor: anchor) }
            if rounds % 7 == 0 { core.clearSelection() }
            rounds += 1
        }
        stop.set()
        // Polled, not waited for: the main thread must not block on a thread of lower priority.
        while !drawn.isSet { usleep(1000) }
        XCTAssertGreaterThan(rounds, 50)
        XCTAssertGreaterThan(extended, 0, "the drag did select between restores")
        XCTAssertTrue(frames.isSet)

        // After the last restore there is no selection and no anchor.
        core.beginSelection(col: 0, row: 0, word: true, anchor: anchor)
        core.restore(snapshot: snapshot) { _ in }
        core.sync()
        XCTAssertFalse(core.hasSelection)
        XCTAssertNil(core.selectedText)
        XCTAssertEqual(core.extendSelection(col: 5, row: 5, anchor: anchor, keepOnAnchor: false), .noAnchor)
        XCTAssertEqual(core.withTerminal { _ in core.trackedRefs.count }, 0)
        XCTAssertLessThanOrEqual(GhosttyCore.liveTerminals.load(ordering: .relaxed), before + 1, "every replaced terminal was freed")
    }

    // MARK: Backlog

    /// A source that outruns the parser is told so, and told again when the parser has caught up.
    func testABacklogAboveTheMarkSignalsAndClears() {
        let core = GhosttyCore(cols: 80, rows: 24)
        let changes = GhosttyTestFlag()
        core.onBackpressureChange = { changes.add() }
        let gate = DispatchSemaphore(value: 0)
        holdQueue(of: core, until: gate)
        let chunk = [UInt8](repeating: 0x61, count: 256 * 1024)
        var fed = 0
        while fed <= GhosttyCore.backlogHighWater {
            XCTAssertFalse(core.isBackedUp)
            core.feed(chunk)
            fed += chunk.count
        }
        XCTAssertTrue(core.isBackedUp)
        XCTAssertEqual(core.backlogBytes, fed)
        XCTAssertEqual(changes.count, 1)
        core.feed(chunk)
        fed += chunk.count
        XCTAssertEqual(changes.count, 1, "told once, not per chunk")
        gate.signal()
        core.sync()
        XCTAssertFalse(core.isBackedUp)
        XCTAssertEqual(core.backlogBytes, 0)
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(core.droppedBytes, 0)
        XCTAssertEqual(core.bytesParsed, fed)
    }

    /// The safety valve for a source that never pauses: past the limit the unparsed backlog is
    /// dropped, the newest output is kept, and queued operations still run.
    func testABacklogPastTheLimitIsDroppedAndTheNewestOutputKept() {
        let core = GhosttyCore(cols: 80, rows: 24)
        let drops = GhosttyTestFlag()
        core.onOutputDropped = { drops.add() }
        let gate = DispatchSemaphore(value: 0)
        holdQueue(of: core, until: gate)
        core.feed(Array("lost line\r\n".utf8))
        core.resize(cols: 100, rows: 24, cellWidthPx: 8, cellHeightPx: 16)
        let chunk = [UInt8](repeating: 0x78, count: 4 * 1024 * 1024)
        var fed = 11
        while fed + chunk.count <= GhosttyCore.backlogLimit {
            core.feed(chunk)
            fed += chunk.count
        }
        XCTAssertEqual(core.droppedBytes, 0)
        XCTAssertEqual(core.backlogBytes, fed)
        let last = Array("\r\u{1b}[2Kkept: the newest output".utf8)
        core.feed(chunk)
        XCTAssertEqual(core.droppedBytes, fed)
        XCTAssertEqual(drops.count, 1)
        XCTAssertEqual(core.backlogBytes, chunk.count + 1, "the new bytes and the CAN before them")
        core.feed(last)
        gate.signal()
        core.sync()
        XCTAssertEqual(core.bytesParsed, chunk.count + 1 + last.count)
        XCTAssertEqual(core.backlogBytes, 0)
        XCTAssertFalse(core.isBackedUp)
        XCTAssertEqual(core.gridSize.cols, 100, "the resize queued before the drop still ran")
        XCTAssertEqual(core.rowText(core.cursorPosition.y), "kept: the newest output")
    }

    /// A drop also takes back the bytes the feed queue had already taken and not yet parsed, and
    /// every byte is accounted for: parsed or dropped.
    func testADropWhileTheQueueIsWritingLeavesOutTheRest() {
        let core = GhosttyCore(cols: 80, rows: 24)
        // Hold the terminal, so the feed queue stops inside the first batch.
        core.lockTerminal()
        let chunk = [UInt8](repeating: 0x78, count: 4 * 1024 * 1024)
        var fed = 0
        core.feed(chunk)
        fed += chunk.count
        usleep(100_000)
        while core.droppedBytes == 0 {
            core.feed(chunk)
            fed += chunk.count
        }
        let end = Array("\r\u{1b}[2Kend".utf8)
        core.feed(end)
        fed += end.count
        core.termLock.unlock()
        core.sync()
        // One CAN byte was added at the drop.
        XCTAssertEqual(core.bytesParsed + core.droppedBytes, fed + 1)
        XCTAssertLessThanOrEqual(core.bytesParsed, 2 * chunk.count + 8, "what the queue had taken and not yet parsed was left out")
        XCTAssertEqual(core.backlogBytes, 0)
        XCTAssertFalse(core.isBackedUp)
        XCTAssertEqual(core.rowText(core.cursorPosition.y), "end")
    }

    func testResetClearsTheScreen() {
        let core = GhosttyCore(cols: 40, rows: 5)
        feed(core, "abc")
        core.reset()
        core.sync()
        XCTAssertEqual(core.rowText(0), "")
        feed(core, "x\u{1b}c\u{1b}[3Jy")
        XCTAssertEqual(core.rowText(0), "y")
    }

    func testTerminalsAreFreedOnTeardown() throws {
        let capture = try ghosttyFixture("ghostty-history")
        let before = GhosttyCore.liveTerminals.load(ordering: .relaxed)
        weak var weakCore: GhosttyCore?
        autoreleasepool {
            let core = GhosttyCore(cols: 80, rows: 24)
            weakCore = core
            core.feed(Array("hello".utf8))
            core.restore(snapshot: capture) { _ in }
            core.sync()
            XCTAssertEqual(GhosttyCore.liveTerminals.load(ordering: .relaxed), before + 1)
        }
        // The feed queue may still hold the last block for a moment.
        let deadline = Date().addingTimeInterval(2)
        while (weakCore != nil || GhosttyCore.liveTerminals.load(ordering: .relaxed) != before) && Date() < deadline { usleep(10_000) }
        XCTAssertNil(weakCore)
        XCTAssertEqual(GhosttyCore.liveTerminals.load(ordering: .relaxed), before)
    }

    func testParseThroughput() {
        var chunk = ""
        for i in 0..<2000 {
            chunk += "\u{1b}[3\(i % 8)m\(i)\u{1b}[0m  drwxr-xr-x  12 user  staff   384 Nov 16 14:20 some-file-name-\(i).swift\r\n"
        }
        let bytes = Array(chunk.utf8)
        let total = 32 * 1024 * 1024
        let core = GhosttyCore(cols: 80, rows: 24)
        let start = CFAbsoluteTimeGetCurrent()
        var fed = 0
        while fed < total {
            core.feed(bytes)
            fed += bytes.count
        }
        core.sync()
        let seconds = CFAbsoluteTimeGetCurrent() - start
        XCTAssertEqual(core.bytesParsed, fed)
        XCTAssertEqual(core.rowText(22).suffix(10), "1999.swift")
        let rate = Double(fed) / 1_048_576 / seconds
        print(String(format: "PERF parse: %.0f MB in %.3f s = %.0f MB/s", Double(fed) / 1_048_576, seconds, rate))
        XCTAssertGreaterThan(rate, 20)
    }
}
