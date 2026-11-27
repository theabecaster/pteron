import Foundation

/// How the palette orders rows. Pure, so it is tested; tests pin orderings, not the numbers.
enum GoToRanker {
    /// How much a match in each field counts.
    enum Weight {
        static let tab = 1.0
        static let session = 0.9
        static let pane = 0.7
        static let pwd = 0.7
        static let machine = 0.6
        static let shortID = 0.5
        static let command = 1.0
    }

    static let limit = 50
    /// Commands after the places in Go to Anything.
    static let commandsAfterPlaces = 5
    static let waitingShown = 3
    static let recentShown = 8

    static func titleWeight(_ kind: GoToItem.Kind) -> Double {
        switch kind {
        case .tab: Weight.tab
        case .session: Weight.session
        case .pane: Weight.pane
        case .command: Weight.command
        }
    }

    /// A match's raw score as a positive number a weight can scale.
    static func strength(_ raw: Double) -> Double { max(10, 100 + raw) }

    /// The score a short ID's prefix match gets: below any title field's.
    static let shortIDScore = 50 * Weight.shortID

    /// A query word that may be a short ID: 4 or more hex digits.
    static func mayBeShortID(_ word: String) -> Bool {
        word.count >= 4 && word.allSatisfy(\.isHexDigit)
    }

    /// The multiplier for an item: frecency up to +30%, a waiting agent +15%, the current tab
    /// −30%, an offline server −40%.
    static func boost(_ item: GoToItem, recent: Double) -> Double {
        var m = 1 + min(max(recent, 0), 0.3)
        if item.waiting { m += 0.15 }
        if item.current, item.kind != .command { m -= 0.3 }
        if item.offline { m -= 0.4 }
        return max(m, 0.05)
    }

    struct Scored: Sendable {
        var index: Int
        var score: Double
        var ranges: [Range<Int>] = []
        var shortID: String?
    }

    /// The rows for a typed query, best first. Ties keep the sidebar's order. In Go to Anything
    /// every place comes before every command, and at most five commands follow; a destructive
    /// command is never row 1 there. A digit query puts that tab of the target's session first.
    static func order(_ scored: [Scored], items: [GoToItem], scope: GoToScope, query: String) -> [Scored] {
        func sorted(_ list: [Scored]) -> [Scored] {
            list.sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                return items[a.index].order < items[b.index].order
            }
        }
        var out: [Scored]
        switch scope {
        case .anything:
            let places = sorted(scored.filter { items[$0.index].kind != .command })
            let commands = sorted(scored.filter { items[$0.index].kind == .command })
            out = Array(places.prefix(limit)) + Array(commands.prefix(commandsAfterPlaces))
        case .sessions, .commands, .moveTab:
            out = Array(sorted(scored).prefix(limit))
        }
        if let n = Int(query.trimmingCharacters(in: .whitespaces)), query.allSatisfy({ $0.isNumber || $0 == " " }),
           let i = out.firstIndex(where: { items[$0.index].tabPosition == n }) {
            out.insert(out.remove(at: i), at: 0)
        }
        if scope == .anything { out = keepingDestructiveOffTop(out) { items[$0.index].destructive } }
        return out
    }

    /// Row 1 is never destructive: the first other row moves up. All destructive: unchanged,
    /// and `selection` then selects nothing.
    static func keepingDestructiveOffTop<T>(_ rows: [T], destructive: (T) -> Bool) -> [T] {
        guard let first = rows.first, destructive(first),
              let i = rows.firstIndex(where: { !destructive($0) }) else { return rows }
        var out = rows
        out.insert(out.remove(at: i), at: 0)
        return out
    }

    /// The row selected after a search: the first that can run. In Go to Anything, never a
    /// destructive one, so Return can't close a pane by accident; then nothing is selected
    /// until an arrow key picks a row.
    static func selection<Row: GoToSelectable>(_ rows: [Row], scope: GoToScope) -> GoToItemID? {
        rows.first { !$0.isDimmed && !(scope == .anything && $0.destructive) }?.id
    }

    // MARK: Empty query

    struct Section: Equatable {
        var header: String?
        /// Indices into the items.
        var indices: [Int]
    }

    /// What shows before anything is typed.
    /// - Go to Anything: Waiting (up to 3, oldest first), then Recent (up to 8, the current tab
    ///   left out). With neither, every place in sidebar order.
    /// - Change Session: every session in sidebar order.
    /// - Commands: recent commands, then every command by category.
    ///
    /// Items are looked up only for the IDs it needs, in one pass: no table of every item is
    /// built on the main actor at open.
    static func empty(_ items: [GoToItem], scope: GoToScope, waiting: [GoToItemID], recents: [GoToRecent]) -> [Section] {
        let recentIDs = recents.compactMap(\.itemID)
        let commands = scope == .commands
        let wanted = Set(commands ? recentIDs : waiting + recentIDs)
        var found: [GoToItemID: Int] = [:]
        if !wanted.isEmpty, scope == .anything || scope == .commands {
            for (i, item) in items.enumerated() where (item.kind == .command) == commands && wanted.contains(item.id) {
                found[item.id] = i
            }
        }
        func sorted(_ keep: (GoToItem) -> Bool) -> [Int] {
            items.indices.filter { keep(items[$0]) }.sorted { items[$0].order < items[$1].order }
        }
        switch scope {
        case .anything:
            let w = Array(waiting.compactMap { found[$0] }.prefix(waitingShown))
            let r = Array(recentIDs.compactMap { id -> Int? in
                guard let i = found[id], !w.contains(i) else { return nil }
                return items[i].current && items[i].kind == .tab ? nil : i
            }.prefix(recentShown))
            var out: [Section] = []
            if !w.isEmpty { out.append(Section(header: "Waiting", indices: w)) }
            if !r.isEmpty { out.append(Section(header: "Recent", indices: r)) }
            if out.isEmpty { out.append(Section(header: nil, indices: Array(sorted { $0.kind != .command }.prefix(limit)))) }
            return out
        case .sessions, .moveTab:
            return [Section(header: nil, indices: sorted { scope.lists($0) })]
        case .commands:
            let recent = Array(recentIDs.compactMap { found[$0] }.prefix(recentShown))
            var out: [Section] = []
            if !recent.isEmpty { out.append(Section(header: "Recent", indices: recent)) }
            var categories: [String] = []
            var byCategory: [String: [Int]] = [:]
            for i in sorted({ $0.kind == .command }) where !recent.contains(i) {
                let k = items[i].category ?? "Actions"
                if byCategory[k] == nil { categories.append(k) }
                byCategory[k, default: []].append(i)
            }
            for k in categories { out.append(Section(header: k, indices: byCategory[k] ?? [])) }
            return out
        }
    }
}

/// A row the selection can land on.
protocol GoToSelectable {
    var id: GoToItemID { get }
    var isDimmed: Bool { get }
    var destructive: Bool { get }
}

extension GoToItem: GoToSelectable {
    var isDimmed: Bool { dimmed != nil }
}
