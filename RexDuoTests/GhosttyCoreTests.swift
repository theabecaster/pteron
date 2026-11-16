import XCTest
@testable import RexDuo

func ghosttyFixture(_ name: String) throws -> [UInt8] {
    let url = try XCTUnwrap(Bundle(for: GhosttyCoreTests.self).url(forResource: name, withExtension: "bin"))
    return [UInt8](try Data(contentsOf: url))
}

final class GhosttyCoreTests: XCTestCase {
    private func feed(_ core: GhosttyCore, _ text: String) {
        core.feed(Array(text.utf8))
        core.sync()
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
        var consumed: Int?
        core.restore(snapshot: capture) { used in
            consumed = used
            if let used { core.feed(GhosttyDemo.stripRexMessages(capture[used...])) }
        }
        core.sync()
        core.sync()
        let used = try XCTUnwrap(consumed)
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
        core.restore(snapshot: capture) { used in
            if let used { core.feed(GhosttyDemo.stripRexMessages(capture[used...])) }
        }
        core.sync()
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
        var result: Int? = -1
        core.restore(snapshot: capture) { result = $0 }
        core.sync()
        XCTAssertNil(result)
        XCTAssertEqual(core.rowText(0), "still here")
        XCTAssertFalse(GhosttyCore.isSnapshot(Array("plain text".utf8)))
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
