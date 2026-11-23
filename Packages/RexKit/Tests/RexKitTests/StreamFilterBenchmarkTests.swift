import XCTest
@testable import RexKit

/// Filter throughput on about 10 MB of terminal-like output in 64 KiB chunks (the server's largest
/// message): a real snapshot, the resize message, then colored lines with a Rex message now and
/// then. The numbers are from a debug build; they compare the filters, not the shipped speed.
final class StreamFilterBenchmarkTests: XCTestCase {
    static let nonce: UInt64 = 0x1234_5678_9ABC_DEF0
    static let streamBytes = 10 << 20

    static let stream: [Data] = {
        let fx = try! StreamFixture.load("scroll")
        let marker = "\u{1b}_rex1;\(nonce);"
        var bytes = Array(fx.bytes[0..<fx.framedSnapshotLength])
        bytes.reserveCapacity(streamBytes + 4096)
        bytes += Array("\(marker){\"type\":\"resize\",\"cols\":80,\"rows\":24,\"owner\":null}\u{1b}\\".utf8)
        var line = 0
        while bytes.count < streamBytes {
            line += 1
            // About one escape sequence per 25 bytes, like `ls --color` or a build log.
            bytes += Array("\u{1b}[38;5;\(line % 256)m\(line)\u{1b}[0m  drwxr-xr-x  12 user  staff   384 Nov 16 14:0\(line % 10) \u{1b}[1;34mdir-\(line)\u{1b}[0m\r\n".utf8)
            if line % 2000 == 0 {
                bytes += Array("\(marker){\"type\":\"resize\",\"cols\":\(80 + line % 7),\"rows\":24,\"owner\":null}\u{1b}\\".utf8)
            }
        }
        var out: [Data] = []
        var at = 0
        while at < bytes.count {
            let end = min(at + 65_536, bytes.count)
            out.append(Data(bytes[at..<end]))
            at = end
        }
        return out
    }()

    static var total: Int { stream.reduce(0) { $0 + $1.count } }

    struct Totals: Equatable { var output = 0, messages = 0, snapshot = 0 }

    static func runNew(collect: Bool) -> Totals {
        var f = APCFilter(nonce: nonce, passesSnapshot: collect)
        var t = Totals()
        for c in stream {
            f.process(c, snapshot: { if case .bytes(let b) = $0 { t.snapshot += b.count }; return true }, output: { t.output += $0.count }, message: { _ in t.messages += 1 })
        }
        return t
    }

    static func runLegacy() -> Totals {
        var f = LegacyAPCFilter(nonce: nonce)
        var t = Totals()
        for c in stream {
            f.process(c, output: { t.output += $0.count }, message: { _ in t.messages += 1 })
        }
        return t
    }

    func testThroughputCollectionOff() {
        _ = Self.stream
        measure { _ = Self.runNew(collect: false) }
    }

    func testThroughputCollectionOn() {
        _ = Self.stream
        measure { _ = Self.runNew(collect: true) }
    }

    func testThroughputBeforeTheChange() {
        _ = Self.stream
        measure { _ = Self.runLegacy() }
    }

    /// The filter gives what the one it replaced gave, with collection off and on.
    func testTheFilterGivesWhatTheOldOneGave() throws {
        let legacy = Self.runLegacy()
        let off = Self.runNew(collect: false)
        let on = Self.runNew(collect: true)
        XCTAssertEqual(off, legacy)
        XCTAssertEqual(on.output, legacy.output)
        XCTAssertEqual(on.messages, legacy.messages)
        XCTAssertEqual(on.snapshot, try StreamFixture.load("scroll").framedSnapshotLength)
        XCTAssertGreaterThan(legacy.messages, 10)
    }

    /// The path with collection off must not be slower than the filter it replaced.
    ///
    /// A measurement, so it belongs to the benchmark and not to the unit suite, where a busy
    /// machine failed it: `scripts/bench/filter.sh` runs it, with the budget from
    /// `scripts/bench/budgets.mjs` (`filter`). Without the benchmark's variable it is skipped.
    func testCollectionOffIsAsFastAsBefore() throws {
        guard let ratio = ProcessInfo.processInfo.environment["PTERON_BENCH_FILTER_RATIO"].flatMap(Double.init) else {
            throw XCTSkip("measured by scripts/bench/filter.sh")
        }

        func best(_ body: () -> Void) -> Double {
            var b = Double.infinity
            for _ in 0..<15 {
                let t0 = CFAbsoluteTimeGetCurrent()
                body()
                b = min(b, CFAbsoluteTimeGetCurrent() - t0)
            }
            return b
        }
        // Interleaved, best of 15 each, twice: noise shows up as a difference between the rounds.
        var tLegacy = Double.infinity, tOff = Double.infinity, tOn = Double.infinity
        for _ in 0..<2 {
            tLegacy = min(tLegacy, best { _ = Self.runLegacy() })
            tOff = min(tOff, best { _ = Self.runNew(collect: false) })
            tOn = min(tOn, best { _ = Self.runNew(collect: true) })
        }
        let mb = Double(Self.total) / 1_048_576
        print(String(format: "APCFilter throughput on %.1f MB: before %.0f MB/s, collection off %.0f MB/s, collection on %.0f MB/s",
                     mb, mb / tLegacy, mb / tOff, mb / tOn))
        print(String(format: "APCFilter ratio to before: collection off %.2f, collection on %.2f, budget %.2f",
                     tOff / tLegacy, tOn / tLegacy, ratio))
        XCTAssertLessThan(tOff, tLegacy * ratio, "collection off is slower than the old filter")
        XCTAssertLessThan(tOn, tLegacy * ratio, "collection on is slower than the old filter")
    }
}
