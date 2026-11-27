import Foundation

/// A row the search kept: which item, the matched characters of its title, and a short ID it
/// matched by (shown in its subtitle).
struct GoToHit: Sendable, Equatable {
    var id: GoToItemID
    /// Its place in the items the search ran over.
    var index: Int
    var ranges: [Range<Int>]
    var shortID: String?
}

/// Folds and scores off the main actor. `load` builds the index once per copy (≤ 25 ms for 2k
/// items); each query then scores every item (≤ 4 ms for 2k, ≤ 20 ms for 10k). Calls run in
/// the order they were made, so a query asked right after a load waits for that index.
actor GoToSearcher {
    private struct Entry {
        var title: FoldedText
        var titleWeight: Double
        var fields: [(text: FoldedText, weight: Double)]
        var shortIDs: [String]
    }

    private var items: [GoToItem] = []
    private var index: [Entry] = []
    private var matcher = FuzzyMatcher()

    func load(_ items: [GoToItem]) {
        self.items = items
        index = items.map { item in
            Entry(title: FoldedText(item.title), titleWeight: GoToRanker.titleWeight(item.kind),
                  fields: item.fields.map { (FoldedText($0.text), $0.weight) }, shortIDs: item.shortIDs)
        }
    }

    /// Which of `ids` the items have.
    func present(_ ids: [GoToItemID]) -> Set<GoToItemID> {
        let wanted = Set(ids)
        guard !wanted.isEmpty else { return [] }
        return Set(items.lazy.map(\.id).filter(wanted.contains))
    }

    /// The rows for `query` in `scope`, best first. The caller drops an answer that a newer
    /// query overtook.
    func search(_ query: String, scope: GoToScope, boosts: [GoToItemID: Double]) -> [GoToHit] {
        let words = FoldedText.query(query)
        let raw = query.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard !words.isEmpty else { return [] }
        var scored: [GoToRanker.Scored] = []
        for (i, item) in items.enumerated() {
            guard scope.lists(item) else { continue }
            guard var s = score(i, words: words, raw: raw) else { continue }
            s.score *= GoToRanker.boost(item, recent: boosts[item.id] ?? 0)
            scored.append(s)
        }
        return GoToRanker.order(scored, items: items, scope: scope, query: query).map {
            GoToHit(id: items[$0.index].id, index: $0.index, ranges: $0.ranges, shortID: $0.shortID)
        }
    }

    /// Every query word must match some field; the item's score adds up each word's best.
    private func score(_ i: Int, words: [[UInt32]], raw: [String]) -> GoToRanker.Scored? {
        let e = index[i]
        var total = 0.0
        var ranges: [Range<Int>] = []
        var shortID: String?
        for (w, word) in words.enumerated() {
            var best = -1.0
            var bestRanges: [Range<Int>]?
            if let m = matcher.score(word, in: e.title, ranges: true) {
                best = GoToRanker.strength(m.score) * e.titleWeight
                bestRanges = m.ranges
            }
            for f in e.fields where FuzzyMatcher.contains(word, in: f.text) {
                // Fields first pass the cheap check: most items don't hold the word at all.
                guard let m = matcher.score(word, in: f.text) else { continue }
                let v = GoToRanker.strength(m.score) * f.weight
                if v > best { best = v; bestRanges = nil }
            }
            if w < raw.count, GoToRanker.mayBeShortID(raw[w]), let id = e.shortIDs.first(where: { $0.hasPrefix(raw[w]) }) {
                if GoToRanker.shortIDScore > best {
                    best = GoToRanker.shortIDScore
                    bestRanges = nil
                    shortID = id
                }
            }
            guard best >= 0 else { return nil }
            total += best
            if let bestRanges { ranges.append(contentsOf: bestRanges) }
        }
        let merged = FuzzyMatcher.ranges(ranges.sorted { $0.lowerBound < $1.lowerBound }.flatMap { Array($0) })
        return GoToRanker.Scored(index: i, score: total, ranges: merged, shortID: shortID)
    }
}
