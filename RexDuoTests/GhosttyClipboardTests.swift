import XCTest
@testable import RexDuo

/// OSC 52: what a program copies reaches the pasteboard sink, and a query is never answered.
@MainActor
final class GhosttyClipboardTests: XCTestCase {
    private final class Sink: TerminalEngineDelegate {
        var sent: [[UInt8]] = []
        func engineGridChanged(cols: Int, rows: Int) {}
        func engineSend(_ bytes: [UInt8]) { sent.append(bytes) }
    }

    /// Texts handed to the sink, in order. Only touched on the main thread.
    private final class Pasteboard {
        var texts: [String] = []
    }

    private func make() -> (GhosttyCore, Pasteboard) {
        let core = GhosttyCore(cols: 40, rows: 10)
        let board = Pasteboard()
        core.clipboard.setSink { board.texts.append($0) }
        // Who may write is the host's to say (TerminalPromptTests); here every write may.
        core.clipboard.setGate { true }
        return (core, board)
    }

    /// Parses everything fed so far, then lets the hop to the main queue run.
    private func settle(_ core: GhosttyCore) {
        core.sync()
        let done = expectation(description: "main queue drained")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
    }

    private func base64(_ text: String) -> String { Data(text.utf8).base64EncodedString() }

    private func copy(_ text: String, to selection: String = "c", end: String = "\u{07}") -> String {
        "\u{1b}]52;\(selection);\(base64(text))\(end)"
    }

    func testACopyReachesThePasteboard() {
        let (core, board) = make()
        core.feed(Array(copy("hello").utf8))
        settle(core)
        XCTAssertEqual(board.texts, ["hello"])
    }

    func testEveryDestinationIsTheOnePasteboard() {
        for selection in ["c", "p", "s", "", "q", "0"] {
            let (core, board) = make()
            core.feed(Array(copy("to \(selection)", to: selection).utf8))
            settle(core)
            XCTAssertEqual(board.texts, ["to \(selection)"], "selection '\(selection)'")
        }
    }

    func testBothTerminatorsAndUnicode() {
        let (core, board) = make()
        core.feed(Array(copy("naïve 日本 🙂\nline 2", end: "\u{1b}\\").utf8))
        settle(core)
        XCTAssertEqual(board.texts, ["naïve 日本 🙂\nline 2"])
    }

    func testASequenceSplitAcrossChunks() {
        let (core, board) = make()
        let bytes = Array(copy("split in two").utf8)
        for cut in [1, 2, 5, 7, 12, bytes.count - 1] {
            core.feed(Array(bytes[..<cut]))
            core.feed(Array(bytes[cut...]))
        }
        settle(core)
        XCTAssertEqual(board.texts.last, "split in two")
        XCTAssertFalse(board.texts.contains { $0 != "split in two" })
    }

    func testABurstIsOneHopAndTheLastWriteWins() {
        let (core, board) = make()
        let before = core.clipboard.deliveries
        core.feed(Array((1...200).map { copy("copy \($0)") }.joined().utf8))
        settle(core)
        XCTAssertEqual(board.texts, ["copy 200"])
        XCTAssertEqual(core.clipboard.deliveries - before, 1)
    }

    func testAnEmptyWriteEmptiesThePasteboard() {
        let (core, board) = make()
        core.feed(Array("\u{1b}]52;c;\u{07}".utf8))
        settle(core)
        XCTAssertEqual(board.texts, [""])
    }

    func testWhatIsNotTextIsDropped() {
        let (core, board) = make()
        // Not base64, then base64 of bytes that are not UTF-8.
        core.feed(Array("\u{1b}]52;c;!!not base64!!\u{07}".utf8))
        core.feed(Array("\u{1b}]52;c;\(Data([0xff, 0xfe, 0xc3]).base64EncodedString())\u{07}".utf8))
        settle(core)
        XCTAssertEqual(board.texts, [])
    }

    func testALargeCopyArrivesWhole() {
        let (core, board) = make()
        let text = String(repeating: "0123456789abcdef", count: 64 * 1024)  // 1 MB
        core.feed(Array(copy(text).utf8))
        settle(core)
        XCTAssertEqual(board.texts.count, 1)
        XCTAssertEqual(board.texts.first?.utf8.count, text.utf8.count)
        XCTAssertTrue(board.texts.first == text)
    }

    func testAQueryIsNeverAnsweredAndCopiesNothing() {
        let view = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 300, height: 200), fontSize: 12, cols: 40, rows: 10)
        let sink = Sink()
        view.engineDelegate = sink
        let board = Pasteboard()
        view.core.clipboard.setSink { board.texts.append($0) }
        view.core.clipboard.setGate { true }
        // Queries with both terminators and every destination, then other things a terminal
        // answers (device attributes, status, a Kitty clipboard read): nothing may come back.
        view.feed(text: "\u{1b}]52;c;?\u{07}\u{1b}]52;p;?\u{1b}\\\u{1b}]52;;?\u{07}\u{1b}]52;s;?\u{07}")
        view.feed(text: "\u{1b}[c\u{1b}[5n\u{1b}[6n\u{1b}]5522;type=read;text/plain\u{1b}\\")
        settle(view.core)
        XCTAssertEqual(sink.sent, [])
        XCTAssertEqual(board.texts, [])
        // A copy after the queries still works: the parser is where it should be.
        view.feed(text: copy("after"))
        settle(view.core)
        XCTAssertEqual(board.texts, ["after"])
        XCTAssertEqual(sink.sent, [])
    }

    func testACopyDoesNotDisturbTheScreen() {
        let (core, board) = make()
        core.feed(Array("before\(copy("x"))after".utf8))
        settle(core)
        XCTAssertEqual(core.rowText(0), "beforeafter")
        XCTAssertEqual(board.texts, ["x"])
    }

    func testResetKeepsTheCallback() {
        let (core, board) = make()
        core.feed(Array("\u{1b}c".utf8))
        core.reset()
        core.feed(Array(copy("after reset").utf8))
        settle(core)
        XCTAssertEqual(board.texts, ["after reset"])
    }
}
