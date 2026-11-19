import Foundation
import GhosttyVt
import Testing
@testable import RexDuo

/// Find with the real library, through the app's types (GhosttyCore+Find.swift).
@Suite(.serialized)
struct GhosttyFindTests {
    /// Waits on the find queue until `predicate` holds for the published result, or 5 s pass.
    @discardableResult
    private func wait(_ find: GhosttyFind, _ predicate: (FindResult) -> Bool) -> FindResult {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            GhosttyFind.queue.sync {}
            let r = find.published.withLock { $0 }
            if predicate(r) { return r }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return find.published.withLock { $0 }
    }

    private func core(lines: [String], cols: Int = 40, rows: Int = 10) -> GhosttyCore {
        let core = GhosttyCore(cols: cols, rows: rows)
        core.feed(Array(lines.joined(separator: "\r\n").utf8))
        core.sync()
        return core
    }

    private func needle(_ s: String) -> [UInt8] { Array(s.utf8) }

    @Test func nothingExistsUntilFindOpensAndTheHandleGoesWhenItCloses() {
        let c = core(lines: ["one error", "two"])
        #expect(c.find == nil)
        let find = c.makeFind()
        #expect(!find.hasHandle)
        find.open()
        find.setNeedle(needle("error"))
        let r = wait(find) { $0.total == 1 && $0.complete }
        #expect(r.total == 1)
        #expect(find.hasHandle)
        find.close()
        let closed = wait(find) { !$0.open }
        #expect(!closed.open)
        #expect(closed.matches.isEmpty)
        #expect(!find.hasHandle)
    }

    @Test func countsMatchesInScreenAndScrollbackAndStepsOlderThenWraps() {
        // 30 lines on a 10-row screen: 20 in the scrollback.
        let lines = (1...30).map { $0 % 10 == 0 ? "line \($0) error here" : "line \($0)" }
        let c = core(lines: lines)
        let find = c.makeFind()
        find.open()
        find.setNeedle(needle("error"))
        let r = wait(find) { $0.complete && $0.total == 3 }
        #expect(r.total == 3)
        #expect(r.selectedIndex == nil)
        // Next goes older: the newest first (line 30, the last row).
        find.step(1)
        let first = wait(find) { $0.selectedIndex == 0 }
        #expect(first.selectedIndex == 0)
        #expect(first.selected?.startRow == 29)
        #expect(first.selected?.startCol == 8)
        find.step(1)
        let second = wait(find) { $0.selectedIndex == 1 }
        #expect(second.selected?.startRow == 19)
        find.step(1)
        _ = wait(find) { $0.selectedIndex == 2 }
        // Past the oldest it wraps to the newest.
        find.step(1)
        let wrapped = wait(find) { $0.selectedIndex == 0 }
        #expect(wrapped.selected?.startRow == 29)
        // Previous goes newer, and wraps the other way.
        find.step(-1)
        let back = wait(find) { $0.selectedIndex == 2 }
        #expect(back.selected?.startRow == 9)
    }

    @Test func asciiLettersFoldCaseButOtherLettersDont() {
        let c = core(lines: ["An ERROR", "café", "CAFÉ"])
        let find = c.makeFind()
        find.open()
        find.setNeedle(needle("error"))
        #expect(wait(find) { $0.complete && $0.total == 1 }.total == 1)
        find.setNeedle(needle("é"))
        #expect(wait(find) { $0.complete && $0.needle == needle("é") }.total == 1)
        // A decomposed query normalized to the composed form matches composed output.
        find.setNeedle(FindQuery.sanitize("cafe\u{301}"))
        #expect(wait(find) { $0.complete && $0.needle == FindQuery.sanitize("cafe\u{301}") }.total == 1)
    }

    @Test func aMatchAcrossASoftWrapCoversTwoRows() {
        // 20 columns: "0123456789012345" then "needle" wraps after "need".
        let c = core(lines: ["0123456789012345needle"], cols: 20, rows: 5)
        let find = c.makeFind()
        find.open()
        find.setNeedle(needle("needle"))
        find.step(1)
        let r = wait(find) { $0.selected != nil }
        #expect(r.total == 1)
        #expect(r.selected == FindSpan(startRow: 0, startCol: 16, endRow: 1, endCol: 1))
        let ranges = GhosttyFindHighlights.ranges(r.selected!, viewTop: 0, rows: 5, cols: 20)
        #expect(ranges == [.init(row: 0, first: 16, last: 19), .init(row: 1, first: 0, last: 1)])
    }

    @Test func theAlternateScreenHasItsOwnResultsAndThePrimaryOnesComeBack() {
        let c = core(lines: ["error one", "error two"])
        let find = c.makeFind()
        find.open()
        find.setNeedle(needle("error"))
        #expect(wait(find) { $0.complete && $0.total == 2 }.total == 2)
        c.feed(Array("\u{1b}[?1049h\u{1b}[Hjust one error".utf8))
        #expect(wait(find) { $0.complete && $0.total == 1 }.total == 1)
        c.feed(Array("\u{1b}[?1049l".utf8))
        #expect(wait(find) { $0.complete && $0.total == 2 }.total == 2)
    }

    @Test func aRestoreRemakesTheHandleAndKeepsTheNeedle() throws {
        let c = core(lines: ["error a", "error b"])
        let find = c.makeFind()
        find.open()
        find.setNeedle(needle("error"))
        #expect(wait(find) { $0.complete && $0.total == 2 }.total == 2)
        let other = core(lines: ["error 1", "error 2", "error 3"])
        let snap = try #require(other.encodeSnapshot())
        let live = GhosttyCore.liveTerminals.load(ordering: .relaxed)
        c.restore(snapshot: snap) { _ in }
        c.sync()
        #expect(GhosttyCore.liveTerminals.load(ordering: .relaxed) == live)
        let r = wait(find) { $0.complete && $0.total == 3 }
        #expect(r.total == 3)
        #expect(r.needle == needle("error"))
    }

    @Test func prunedHistoryDropsTheSelectedMatch() {
        let c = core(lines: ["error first"] + (1...20).map { "filler \($0)" })
        let find = c.makeFind()
        find.open()
        find.setNeedle(needle("error"))
        find.step(1)
        #expect(wait(find) { $0.selected != nil }.total == 1)
        // A full reset clears the scrollback: the match is gone.
        c.reset()
        let r = wait(find) { $0.complete && $0.total == 0 }
        #expect(r.total == 0)
        #expect(r.selected == nil)
    }

    @Test func closingWhileAPassRunsAndFreeingTheCoreWithFindOpenAreClean() {
        let live = GhosttyCore.liveTerminals.load(ordering: .relaxed)
        do {
            let c = core(lines: (1...2000).map { "row \($0) error" })
            let find = c.makeFind()
            find.open()
            find.setNeedle(needle("e"))
            find.close()
            find.open()
            find.setNeedle(needle("error"))
            _ = wait(find) { $0.total > 0 }
        }
        GhosttyFind.queue.sync {}
        #expect(GhosttyCore.liveTerminals.load(ordering: .relaxed) == live)
    }

    @Test func perPageRowsEqualOneConversionPerMatch() {
        // Enough lines for several pages of history.
        let c = core(lines: (1...3000).map { "row \($0) error" }, cols: 30, rows: 10)
        c.withTerminal { t in
            var h: GhosttySearch?
            #expect(ghostty_search_new(nil, &h, t) == GHOSTTY_SUCCESS)
            defer { ghostty_search_free(h) }
            var s = GhosttyString(ptr: nil, len: 0)
            let n = Array("error".utf8)
            n.withUnsafeBufferPointer { p in
                s = GhosttyString(ptr: p.baseAddress, len: p.count)
                ghostty_search_set(h, GHOSTTY_SEARCH_OPT_NEEDLE, &s)
            }
            ghostty_search_run(h)
            var b = GhosttySelectionBuffer(ptr: nil, cap: 0, len: 0)
            _ = ghostty_search_get(h, GHOSTTY_SEARCH_DATA_MATCHES, &b)
            var all = [GhosttySelection](repeating: GhosttySelection(), count: b.len)
            all.withUnsafeMutableBufferPointer { p in
                b = GhosttySelectionBuffer(ptr: p.baseAddress, cap: p.count, len: 0)
                _ = ghostty_search_get(h, GHOSTTY_SEARCH_DATA_MATCHES, &b)
            }
            #expect(all.count == 3000)
            var cache = GhosttyFind.PageRows()
            var nodes = Set<UnsafeMutableRawPointer>()
            for m in all {
                var ref = m.start
                var p = GhosttyPointCoordinate()
                #expect(ghostty_terminal_point_from_grid_ref(t, &ref, GHOSTTY_POINT_TAG_SCREEN, &p) == GHOSTTY_SUCCESS)
                let fast = cache.row(m.start, t)
                #expect(fast?.row == Int(p.y))
                #expect(fast?.col == Int(p.x))
                if let node = m.start.node { nodes.insert(node) }
            }
            #expect(nodes.count > 1, "the fixture spans several pages")
            #expect(cache.count == nodes.count)
        }
    }

    @Test func searchingTenThousandLinesFinishes() {
        let c = core(lines: (1...10_000).map(String.init), cols: 40, rows: 20)
        let find = c.makeFind()
        let start = Date()
        find.open()
        find.setNeedle(needle("9999"))
        let r = wait(find) { $0.complete && $0.total >= 1 }
        #expect(r.total == 1)
        // Informational: printed, not asserted.
        print("FIND_TIMING 10k lines to complete: \(Int(Date().timeIntervalSince(start) * 1000)) ms")
    }
}
