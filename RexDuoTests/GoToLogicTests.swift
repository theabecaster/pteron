import Foundation
import RexKit
import SwiftUI
import Testing
@testable import RexDuo

// The palette's pure parts: folding and matching, ranking, recents, questions, the panel's frame.

struct FuzzyMatchTests {
    private func score(_ q: String, _ t: String) -> (score: Double, ranges: [Range<Int>])? {
        var m = FuzzyMatcher()
        guard let word = FoldedText.query(q).first else { return nil }
        return m.score(word, in: FoldedText(t), ranges: true)
    }

    @Test func aWordStartBeatsTheMiddleOfAWord() throws {
        let start = try #require(score("gc", "git commit"))
        let middle = try #require(score("gc", "magic cat"))
        #expect(start.score > middle.score)
    }

    @Test func theFieldsStartBeatsLaterInIt() throws {
        let prefix = try #require(score("api", "api server"))
        let later = try #require(score("api", "the api server"))
        #expect(prefix.score > later.score)
    }

    @Test func noMatch() {
        #expect(score("xyz", "api") == nil)
        #expect(score("apix", "api") == nil)
    }

    @Test func rangesAreDisplayCharacters() throws {
        let m = try #require(score("cb", "Café Bar"))
        #expect(m.ranges == [0..<1, 5..<6])
    }

    @Test func anNFDTitleMatchesAnNFCQuery() throws {
        let m = try #require(score("café", "Cafe\u{301} Bar"))
        #expect(m.ranges == [0..<4])
    }

    @Test func anAccentedLetterIsNeverHalfMatched() throws {
        let m = try #require(score("e", "e\u{301}cole"))
        // One display character: the letter and its accent together.
        #expect(m.ranges == [0..<1])
        #expect(score("ecole", "École") != nil)
    }

    @Test func sharpS() {
        #expect(score("strasse", "Straße") != nil)
        #expect(score("ß", "Strasse") != nil)
    }

    @Test func turkishDottedI() {
        #expect(score("istanbul", "İstanbul") != nil)
    }

    @Test func fullWidthLetters() {
        #expect(score("rex", "ｒｅｘ") != nil)
        #expect(score("ｒｅｘ", "rex server") != nil)
    }

    @Test(arguments: ["Hello-World_x.Y", "api/server", "camelCaseName", "a b  c", "", "UPPER lower"])
    func theASCIIFastPathEqualsTheFullOne(_ s: String) {
        #expect(FoldedText(s) == FoldedText(s, ascii: false))
    }

    @Test func rangesMergeAndSkipRepeats() {
        #expect(FuzzyMatcher.ranges([0, 1, 1, 2, 5]) == [0..<3, 5..<6])
    }
}

struct GoToRankerTests {
    private func item(_ id: String, _ kind: GoToItem.Kind = .tab, order: Int, destructive: Bool = false,
                      dimmed: String? = nil, current: Bool = false, waiting: Bool = false, offline: Bool = false) -> GoToItem {
        GoToItem(id: kind == .command ? .command(id) : .other(id), kind: kind, title: id, subtitle: "", order: order,
                 offline: offline, waiting: waiting, current: current, destructive: destructive, dimmed: dimmed, symbol: "x")
    }

    @Test func placesComeBeforeEveryCommandAndAtMostFiveCommandsFollow() {
        var items = [item("tab", order: 1)]
        for i in 0..<8 { items.append(item("cmd\(i)", .command, order: 10 + i)) }
        let scored = items.indices.map { GoToRanker.Scored(index: $0, score: $0 == 0 ? 1 : 100) }
        let out = GoToRanker.order(scored, items: items, scope: .anything, query: "x")
        #expect(out.first?.index == 0)
        #expect(out.count == 6)
    }

    @Test func aDestructiveCommandIsNeverRowOne() {
        let items = [item("close", .command, order: 1, destructive: true), item("zoom", .command, order: 2)]
        let scored = [GoToRanker.Scored(index: 0, score: 100), GoToRanker.Scored(index: 1, score: 10)]
        let anything = GoToRanker.order(scored, items: items, scope: .anything, query: "c")
        #expect(anything.map(\.index) == [1, 0])
        // In the commands palette they rank as they score.
        let commands = GoToRanker.order(scored, items: items, scope: .commands, query: "c")
        #expect(commands.map(\.index) == [0, 1])
    }

    @Test func allDestructiveSelectsNothing() {
        let rows = [item("close", .command, order: 1, destructive: true), item("clear", .command, order: 2, destructive: true)]
        #expect(GoToRanker.selection(rows, scope: .anything) == nil)
        #expect(GoToRanker.selection(rows, scope: .commands) == .command("close"))
        let dimmed = [item("copy", .command, order: 1, dimmed: "Mac"), item("zoom", .command, order: 2)]
        #expect(GoToRanker.selection(dimmed, scope: .commands) == .command("zoom"))
    }

    @Test func boosts() {
        let plain = item("a", order: 1)
        #expect(GoToRanker.boost(plain, recent: 0) == 1)
        #expect(GoToRanker.boost(plain, recent: 0.9) == 1.3, "frecency gives at most 30%")
        #expect(GoToRanker.boost(item("a", order: 1, waiting: true), recent: 0) == 1.15)
        #expect(abs(GoToRanker.boost(item("a", order: 1, current: true), recent: 0) - 0.7) < 1e-9)
        #expect(abs(GoToRanker.boost(item("a", order: 1, offline: true), recent: 0) - 0.6) < 1e-9)
    }

    @Test func tiesKeepTheSidebarsOrder() {
        let items = [item("b", order: 2), item("a", order: 1), item("c", order: 3)]
        let scored = items.indices.map { GoToRanker.Scored(index: $0, score: 50) }
        #expect(GoToRanker.order(scored, items: items, scope: .anything, query: "x").map(\.index) == [1, 0, 2])
    }

    @Test func aDigitQueryPutsThatTabFirst() {
        var second = item("two", order: 2)
        second.tabPosition = 2
        let items = [item("one", order: 1), second]
        let scored = [GoToRanker.Scored(index: 0, score: 90), GoToRanker.Scored(index: 1, score: 10)]
        #expect(GoToRanker.order(scored, items: items, scope: .anything, query: "2").first?.index == 1)
    }

    @Test func theEmptyListShowsWaitingInItsOrderThenRecent() {
        let items = (1...6).map { item("t\($0)", order: $0) } + [item("cur", order: 9, current: true)]
        let waiting: [GoToItemID] = [.other("t5"), .other("t2"), .other("t4"), .other("t1")]
        let sections = GoToRanker.empty(items, scope: .anything, waiting: waiting, recents: [])
        #expect(sections.first?.header == "Waiting")
        #expect(sections.first?.indices.map { items[$0].id } == [.other("t5"), .other("t2"), .other("t4")], "oldest first, three at most")
    }

    @Test func theEmptyListWithNothingWaitingOrRecentListsThePlaces() {
        let items = [item("b", order: 2), item("a", order: 1), item("cmd", .command, order: 3)]
        let sections = GoToRanker.empty(items, scope: .anything, waiting: [], recents: [])
        #expect(sections == [GoToRanker.Section(header: nil, indices: [1, 0])])
    }

    @Test func recentLeavesOutTheCurrentTab() throws {
        let s = UUID()
        let cur = GoToItem(id: .tab(s, "s1", "w1"), kind: .tab, title: "cur", subtitle: "", order: 1, current: true, symbol: "x")
        let other = GoToItem(id: .tab(s, "s1", "w2"), kind: .tab, title: "other", subtitle: "", order: 2, symbol: "x")
        var recents = GoToRecents.record(.tab(s, "s1", "w1"), at: Date(), in: [])
        recents = GoToRecents.record(.tab(s, "s1", "w2"), at: Date(), in: recents)
        let sections = GoToRanker.empty([cur, other], scope: .anything, waiting: [], recents: recents)
        #expect(sections == [GoToRanker.Section(header: "Recent", indices: [1])])
    }

    @Test func theCommandsListGroupsByCategory() {
        var a = item("split", .command, order: 1); a.category = "Pane"
        var b = item("font", .command, order: 2); b.category = "View"
        var c = item("zoom", .command, order: 3); c.category = "Pane"
        let sections = GoToRanker.empty([a, b, c], scope: .commands, waiting: [], recents: [])
        #expect(sections.map(\.header) == ["Pane", "View"])
        #expect(sections.first?.indices == [0, 2])
    }

    @Test func shortIDsNeedFourHexDigits() {
        #expect(!GoToRanker.mayBeShortID("3f9"))
        #expect(GoToRanker.mayBeShortID("3f9a"))
        #expect(!GoToRanker.mayBeShortID("3f9z"))
    }
}

struct GoToSearcherTests {
    @Test func aShortIDMatchesOnlyFromFourHexDigitsAndBelowATitleHit() async {
        let s = UUID()
        let byID = GoToItem(id: .tab(s, "s", "w1"), kind: .tab, title: "logs", subtitle: "", shortIDs: ["beef12"], order: 1, symbol: "x")
        let byTitle = GoToItem(id: .tab(s, "s", "w2"), kind: .tab, title: "beef stew", subtitle: "", shortIDs: ["000000"], order: 2, symbol: "x")
        let searcher = GoToSearcher()
        await searcher.load([byID, byTitle])
        let hits = await searcher.search("beef", scope: .anything, boosts: [:])
        #expect(hits.map(\.id) == [byTitle.id, byID.id])
        #expect(hits.last?.shortID == "beef12")
        let short = await searcher.search("bee", scope: .anything, boosts: [:])
        #expect(short.map(\.id) == [byTitle.id], "three hex digits never match an ID")
    }

    @Test func everyWordMustMatchSomeField() async {
        let s = UUID()
        let tab = GoToItem(id: .tab(s, "s", "w"), kind: .tab, title: "api", subtitle: "",
                           fields: [.init(text: "studio", weight: 0.6)], order: 1, symbol: "x")
        let searcher = GoToSearcher()
        await searcher.load([tab])
        #expect(await searcher.search("studio api", scope: .anything, boosts: [:]).count == 1)
        #expect(await searcher.search("studio web", scope: .anything, boosts: [:]).isEmpty)
    }

    @Test func scopesFilterKinds() async {
        let s = UUID()
        let items = [GoToItem(id: .session(s, "a"), kind: .session, title: "alpha", subtitle: "", order: 1, symbol: "x"),
                     GoToItem(id: .tab(s, "a", "w"), kind: .tab, title: "alpha tab", subtitle: "", order: 2, symbol: "x"),
                     GoToItem(id: .command("app:x"), kind: .command, title: "Alpha Command", subtitle: "", order: 3, symbol: "x")]
        let searcher = GoToSearcher()
        await searcher.load(items)
        #expect(await searcher.search("alpha", scope: .sessions, boosts: [:]).map(\.id) == [items[0].id])
        #expect(await searcher.search("alpha", scope: .commands, boosts: [:]).map(\.id) == [items[2].id])
        #expect(await searcher.search("alpha", scope: .anything, boosts: [:]).last?.id == items[2].id)
    }
}

struct GoToRecentsTests {
    @Test func aPickMovesToTheFrontAndCounts() {
        let s = UUID()
        var list = GoToRecents.record(.tab(s, "a", "1"), at: Date(), in: [])
        list = GoToRecents.record(.tab(s, "a", "2"), at: Date(), in: list)
        list = GoToRecents.record(.tab(s, "a", "1"), at: Date(), in: list)
        #expect(list.map(\.itemID) == [.tab(s, "a", "1"), .tab(s, "a", "2")])
        #expect(list.first?.uses == 2)
    }

    @Test func atMostFifty() {
        var list: [GoToRecent] = []
        for i in 0..<60 { list = GoToRecents.record(.command("c\(i)"), at: Date(), in: list) }
        #expect(list.count == 50)
        #expect(list.first?.itemID == .command("c59"))
    }

    @Test func frecencyDecaysWithAHalfLifeOfThreeDays() {
        let now = Date()
        let e = GoToRecent(.command("x"), uses: 3, at: now.addingTimeInterval(-3 * 86_400))!
        let fresh = GoToRecent(.command("x"), uses: 3, at: now)!
        #expect(abs(GoToRecents.frecency(e, now: now) * 2 - GoToRecents.frecency(fresh, now: now)) < 1e-9)
        #expect(GoToRecents.boosts([fresh], now: now)[.command("x")] ?? 0 <= 0.3)
    }

    @Test func pruningDropsOnlyWhatAKnownServerLost() {
        let up = UUID(), down = UUID()
        var list = GoToRecents.record(.tab(up, "s", "gone"), at: Date(), in: [])
        list = GoToRecents.record(.tab(up, "s", "here"), at: Date(), in: list)
        list = GoToRecents.record(.tab(down, "s", "w"), at: Date(), in: list)
        list = GoToRecents.record(.command("app:x"), at: Date(), in: list)
        let pruned = GoToRecents.prune(list, synced: [up], present: [.tab(up, "s", "here")])
        #expect(pruned.compactMap(\.itemID) == [.command("app:x"), .tab(down, "s", "w"), .tab(up, "s", "here")])
    }

    @Test func entriesRoundTrip() throws {
        let s = UUID()
        let list = GoToRecents.record(.pane(s, "a", "w", "b"), at: Date(timeIntervalSince1970: 100), in: [])
        let back = try JSONDecoder().decode([GoToRecent].self, from: JSONEncoder().encode(list))
        #expect(back == list)
    }
}

struct PalettePromptTests {
    private let server = UUID()

    private func request(_ id: String = "call:1", action: String? = "dev_layout", kind: String = "input",
                         serial: Int = 2, at date: Date = Date(), extra: JSONObject = [:]) -> PromptRequest {
        var prompt: JSONObject = ["kind": kind, "title": "Branch"]
        for (k, v) in extra { prompt[k] = v }
        var p: JSONObject = ["call_id": id, "timeout_ms": 60_000, "prompt": prompt]
        if let action { p["action"] = action }
        return PromptRequest(p, receivedAt: date, connectionSerial: serial)!
    }

    @Test func aPromptBelongsToARunOnlyWhileItsCallWaitsAndWithinTenSeconds() {
        var o = PaletteOrigins()
        let t0 = Date()
        let id = o.started(server: server, serial: 2, action: "dev_layout", title: "Dev Layout", at: t0)
        #expect(o.owner(of: request(), server: server, now: t0.addingTimeInterval(9), boardShown: false)?.id == id)
        #expect(o.owner(of: request(), server: server, now: t0.addingTimeInterval(11), boardShown: false) == nil, "out of the window")
        #expect(o.owner(of: request(serial: 3), server: server, now: t0, boardShown: false) == nil, "another connection")
        #expect(o.owner(of: request(), server: UUID(), now: t0, boardShown: false) == nil, "another server")
        #expect(o.owner(of: request(action: "other"), server: server, now: t0, boardShown: false) == nil, "another action")
        #expect(o.owner(of: request(action: nil), server: server, now: t0, boardShown: false) == nil, "no action")
        #expect(o.owner(of: request(kind: "color_wheel"), server: server, now: t0, boardShown: false) == nil, "a kind from the future")
        #expect(o.owner(of: request(), server: server, now: t0, boardShown: true) == nil, "under the tent board")
        o.ended(id)
        #expect(o.owner(of: request(), server: server, now: t0, boardShown: false) == nil, "its call answered")
    }

    @Test func anAnswerRenewsTheWindow() {
        var o = PaletteOrigins()
        let t0 = Date()
        let id = o.started(server: server, serial: 2, action: "dev_layout", title: "Dev Layout", at: t0)
        o.answered(id)
        #expect(o.owner(of: request(), server: server, now: t0.addingTimeInterval(60), boardShown: false)?.id == id)
    }

    @Test func repliesHaveTheirShapes() {
        #expect(PalettePrompt.text("c", "main").obj("result")?.str("text") == "main")
        #expect(PalettePrompt.ids("c", ["a", "b"]).obj("result")?["ids"] as? [String] == ["a", "b"])
        #expect(PalettePrompt.ids("c", []).obj("result")?["ids"] as? [String] == [])
        #expect(PalettePrompt.cancel("c").obj("result")?.bool("cancelled") == true)
        #expect(PalettePrompt.cancel("c").str("call_id") == "c")
        #expect(PalettePrompt.cancel("c")["error"] == nil)
    }

    @Test func iconsFallBackToACircle() {
        #expect(PalettePrompt.symbol("branch") == "arrow.triangle.branch")
        #expect(PalettePrompt.symbol("a_future_icon") == "circle")
        #expect(PalettePrompt.symbol(nil) == "circle")
    }

    @Test func aPickReadsItsItems() throws {
        let r = request(kind: "pick", extra: [
            "multiple": true, "items": [["id": "a", "title": "main", "selected": true, "icon": "branch", "detail": "M"],
                                        ["id": "b", "title": "dev"], ["title": "no id"]] as [Any],
        ])
        let p = try #require(PalettePrompt(r, serverID: server, runID: 1, actionTitle: "Dev Layout"))
        guard case .pick(let items, let multiple, let other, let selected) = p.kind else { Issue.record("pick"); return }
        #expect(items.map(\.id) == ["a", "b"])
        #expect(items.first?.detail == "M" && items.first?.symbol == "arrow.triangle.branch")
        #expect(multiple && !other)
        #expect(selected == ["a"])
        #expect(p.deadline == r.receivedAt.addingTimeInterval(60))
        let single = try #require(PalettePrompt(request(kind: "pick", extra: ["allow_other": true, "items": [[String: Any]]()]),
                                                serverID: server, runID: 1, actionTitle: "x"))
        guard case .pick(_, false, true, _) = single.kind else { Issue.record("allow_other"); return }
    }

    @Test func promptsWaitTheirTurn() throws {
        let now = Date()
        func p(_ id: String, life: TimeInterval) -> PalettePrompt {
            var r = request(id)
            r.timeoutMS = Int(life * 1000)
            r.receivedAt = now
            return PalettePrompt(r, serverID: server, runID: 1, actionTitle: "x")!
        }
        var q = PromptQueue()
        let first = q.add(p("1", life: 60)), second = q.add(p("2", life: 1)), third = q.add(p("3", life: 60))
        #expect(first && !second && !third)
        let next = q.remove("1", now: now.addingTimeInterval(5))
        #expect(next?.callID == "3", "the one whose time ran out is skipped")
        let dropped = q.dropAll(server: server)
        #expect(dropped.map(\.callID) == ["3"])
        #expect(q.shown == nil)
    }
}

@MainActor
struct GoToPanelLayoutTests {
    private func frame(_ size: CGSize, narrow: Bool, division: Division? = nil, top: CGFloat? = 40,
                       keyboard: CGFloat? = nil, pad: CGFloat = 0) -> GoToPanelLayout.Frame {
        GoToPanelLayout.frame(size: size, safe: EdgeInsets(), top: top, narrow: narrow, division: division,
                              keyboardTop: { _, _ in keyboard }, keyboardPad: pad)
    }

    @Test func narrowIsFullWidthWithMargins() {
        let f = frame(CGSize(width: 390, height: 800), narrow: true)
        #expect(f.x == 8 && f.width == 374 && f.y == 48)
    }

    @Test func wideIsAtMost520Centered() {
        let f = frame(CGSize(width: 1000, height: 800), narrow: false)
        #expect(f.width == 520 && f.x == 240)
    }

    @Test func aVerticalCreaseKeepsItOnTheTabsPage() {
        let crease = Division(frame: CGRect(x: 490, y: 0, width: 20, height: 800), isActive: true)
        let f = frame(CGSize(width: 1000, height: 800), narrow: false, division: crease)
        #expect(f.x >= 510 + 12)
        #expect(f.x + f.width <= 1000)
    }

    @Test func tabletopKeepsItAboveTheCrease() {
        let crease = Division(frame: CGRect(x: 0, y: 400, width: 1000, height: 20), isActive: true)
        let f = frame(CGSize(width: 1000, height: 800), narrow: false, division: crease)
        #expect(f.y + f.maxHeight <= 400 - 12)
    }

    @Test func theKeyboardsTopBoundsTheHeight() {
        let f = frame(CGSize(width: 390, height: 800), narrow: true, keyboard: 500)
        #expect(f.y + f.maxHeight == 492)
        let padded = frame(CGSize(width: 390, height: 800), narrow: true, pad: 300)
        #expect(padded.y + padded.maxHeight == 492)
        let none = frame(CGSize(width: 390, height: 800), narrow: true, top: nil)
        #expect(none.y == 8)
    }
}

struct LuaActionTests {
    @Test func onlyLuaActionsCountAndRequiredArgumentsShow() {
        let r: JSONObject = ["actions": [
            ["name": "dev_layout", "kind": "lua", "title": "Dev Layout", "category": "Layouts"],
            ["name": "open_branch", "kind": "lua", "args": ["type": "object", "required": ["branch"]] as JSONObject],
            ["name": "maybe", "kind": "lua", "args": ["type": "object", "properties": ["x": [:]]] as JSONObject],
            ["name": "com.superlogical.terminal.write", "kind": "block"],
            ["name": "com.superlogical.terminal.clear", "kind": "block", "title": "Clear"],
            ["name": "future", "kind": "something_new"],
        ] as [Any]]
        let list = LuaAction.list(in: r)
        #expect(list.map(\.name) == ["dev_layout", "open_branch", "maybe"])
        #expect(list[0].title == "Dev Layout" && list[0].category == "Layouts")
        #expect(list[1].title == "Open Branch" && list[1].needsArguments && list[1].category == "Actions")
        #expect(!list[2].needsArguments)
        #expect(LuaAction.list(in: [:]).isEmpty)
    }
}
