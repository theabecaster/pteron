import XCTest
@testable import RexKit

/// The pane's cell size in pixels, as its program is told it (`TerminalStream.cellPixels`): the
/// app maps SGR-Pixels mouse reports (mode 1016) into it.
@MainActor
final class StreamCellPixelsTests: XCTestCase {
    private final class Sink: TerminalSink {
        var statuses: [TerminalStream.Status] = []
        /// The stream's cell size each time it said a size.
        var sizes: [CellPixels?] = []
        weak var stream: TerminalStream?

        func streamReset(cols: Int, rows: Int) {}
        func streamSnapshot(_ text: String) {}
        func streamGhosttySnapshot(_ part: GhosttySnapshotPart) -> Bool { true }
        func streamFeed(_ bytes: UnsafeBufferPointer<UInt8>) {}
        func streamResized(cols: Int, rows: Int, owner: String?) { sizes.append(stream?.cellPixels) }
        func streamTheme(_ theme: JSONObject) {}
        func streamExited(code: Int?) {}
        func streamStatus(_ status: TerminalStream.Status) { statuses.append(status) }
    }

    private var logs: [SleepLog] = []

    override func tearDown() async throws {
        for log in logs { log.release(.seconds(1)) }
        logs = []
    }

    private func stream(_ link: FakeLink) -> (TerminalStream, Sink) {
        let sink = Sink()
        let (s, log) = makeStream(link: link, sink: sink)
        sink.stream = s
        logs.append(log)
        return (s, sink)
    }

    private func resize(cols: Int = 80, rows: Int = 24, cell: (Int, Int)?) -> [UInt8] {
        let px = cell.map { ",\"cell_width_px\":\($0.0),\"cell_height_px\":\($0.1)" } ?? ""
        return Wire.message("{\"type\":\"resize\",\"cols\":\(cols),\"rows\":\(rows)\(px),\"owner\":\"client:mac\"}")
    }

    func testACellSizeNeedsBothSidesAboveZero() {
        XCTAssertEqual(CellPixels(width: 8, height: 16).map { [$0.width, $0.height] }, [8, 16])
        XCTAssertNil(CellPixels(width: nil, height: nil), "an older server says nothing")
        XCTAssertNil(CellPixels(width: 0, height: 0), "0 is a size the server doesn't know")
        XCTAssertNil(CellPixels(width: 8, height: 0))
        XCTAssertNil(CellPixels(width: nil, height: 16))
        XCTAssertNil(CellPixels(width: -8, height: 16))
        XCTAssertEqual(CellPixels(["cell_width_px": 8, "cell_height_px": 16] as JSONObject), CellPixels(width: 8, height: 16))
        XCTAssertNil(CellPixels(["columns": 80, "rows": 24] as JSONObject))
    }

    /// H-F3c: a later size replaces an earlier one, so a resize on the server or a new font there
    /// never leaves an old cell size behind. H-F3e: a resize without the fields (an older server),
    /// or with 0 (a size the server doesn't know), leaves none.
    func testEveryResizeReplacesTheCellSize() async {
        let link = FakeLink()
        let (s, sink) = stream(link)
        s.start()
        await catchUp(s, link)
        XCTAssertNil(s.cellPixels, "the opening resize said none")
        let socket = link.sockets.last!
        let steps: [((Int, Int)?, CellPixels?)] = [
            ((8, 16), CellPixels(width: 8, height: 16)),
            ((10, 20), CellPixels(width: 10, height: 20)),
            (nil, nil),
            ((9, 18), CellPixels(width: 9, height: 18)),
            ((0, 0), nil),
        ]
        for (i, (cell, want)) in steps.enumerated() {
            socket.push(resize(cols: 80 + i, cell: cell))
            let seen = await eventually { sink.sizes.count == i + 2 }
            XCTAssertTrue(seen, "resize \(i)")
            XCTAssertEqual(s.cellPixels, want, "resize \(i)")
            XCTAssertEqual(sink.sizes.last ?? nil, want, "known when the sink hears the size")
        }
    }

    /// The path without a snapshot reads the size with `terminal.size`.
    func testTerminalSizeCarriesTheCellSize() async {
        for (answer, want) in [((8, 16) as (Int, Int)?, CellPixels(width: 8, height: 16)), (nil, nil)] {
            let link = FakeLink()
            var reply: JSONObject = ["columns": 80, "rows": 24, "owner": NSNull()]
            if let answer {
                reply["cell_width_px"] = answer.0
                reply["cell_height_px"] = answer.1
            }
            link.replies["com.superlogical.terminal.size"] = reply
            let (s, sink) = stream(link)
            s.snapshotRestoreFailed()
            s.start()
            let live = await eventually { sink.statuses.last == .live }
            XCTAssertTrue(live)
            XCTAssertEqual(sink.sizes.first ?? nil, want)
            XCTAssertEqual(s.cellPixels, want)
            s.stop()
        }
    }
}
