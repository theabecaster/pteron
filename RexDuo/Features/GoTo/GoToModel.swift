import Observation
import RexKit
import SwiftUI

/// One opening of the palette: its scope and target, the query, the rows and the selection, or
/// a question on screen. Made by `GoToCenter.open`, gone at `close`.
///
/// The rows come from a copy of the servers' state taken at open (`GoToSource`), searched off
/// the main actor (`GoToSearcher`). While it is open, a change to the servers' sessions, tabs,
/// phases or agents rebuilds the copy, at most every 250 ms; a title or directory change doesn't.
@MainActor
@Observable
final class GoToModel {
    /// One row as drawn: a snapshot, so a row redraws only when its own content changes.
    struct Row: Identifiable, Equatable, GoToSelectable {
        enum Badge: Equatable {
            case window(UUID, String, String)
            case block(UUID, String)
        }

        var id: GoToItemID
        /// A quiet header above this row (empty query only).
        var header: String?
        var title: String
        /// Matched characters of the title, as character offsets.
        var ranges: [Range<Int>] = []
        var subtitle: String
        var symbol: String
        var keyLabel: String?
        var dimmed = false
        var destructive = false
        var badge: Badge?
        /// A question's item that can be checked (`multiple`): whether it is.
        var checked: Bool?
        /// A question item's text for the row's far end.
        var detail: String?
        /// What VoiceOver says first: Tab, Pane, Session, Command.
        var kind: String

        var isDimmed: Bool { dimmed }
    }

    private(set) var scope: GoToScope
    let target: GoToTarget?
    /// Where the panel's top goes, in global coordinates: 8 pt below the title bar as it was at
    /// open. Nil: below the status bar.
    let anchor: CGFloat?
    /// The field's committed text (never marked text being composed).
    private(set) var query = ""
    /// Bumped when the field must show `fieldText` (a scope switch by `>`, a question's value).
    private(set) var fieldVersion = 0
    private(set) var fieldText = ""
    private(set) var rows: [Row] = []
    var selected: GoToItemID?
    private(set) var prompt: PalettePrompt?
    /// A question's checked items (`multiple`).
    var checked: Set<String> = []
    /// One quiet line under the rows: no servers, or a server still connecting.
    private(set) var note: String?
    /// The keyboard's frame (screen coordinates), for the panel's height.
    var keyboardFrame: CGRect = .null
    /// Counts rebuilds, for tests.
    @ObservationIgnored private(set) var rebuilds = 0

    @ObservationIgnored private(set) var runs: [GoToItemID: GoToRun] = [:]
    @ObservationIgnored private var items: [GoToItem] = []
    @ObservationIgnored private let searcher = GoToSearcher()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var rebuildPending = false
    @ObservationIgnored private(set) var closed = false
    /// The query went to `.commands` by its leading `>`; Backspace on empty goes back.
    @ObservationIgnored private(set) var byChevron = false
    @ObservationIgnored private weak var center: GoToCenter?
    @ObservationIgnored weak var field: PaletteField?
    /// How long the rebuild after a change waits; tests shorten it.
    @ObservationIgnored var throttle: Duration = .milliseconds(250)

    init(scope: GoToScope, target: GoToTarget?, center: GoToCenter?, anchor: CGFloat?) {
        self.scope = scope
        self.target = target
        self.center = center
        self.anchor = anchor
    }

    private var model: AppModel? { center?.model }

    // MARK: Lifetime

    /// Copies what it lists, shows the empty query's rows at once, and builds the index off
    /// the main actor. A query typed meanwhile waits for the index.
    func start() {
        rebuild(first: true)
    }

    /// Closed: nothing more runs.
    func finish() { closed = true }

    private func rebuild(first: Bool = false) {
        guard !closed, let model else { return }
        if !first { rebuilds += 1 }
        var copy = GoToSource.Copy()
        let waitingItems = Waiting.all(model.servers)
        GoToSource.places(model.servers, target: target, waiting: Set(waitingItems.map(\.id)), into: &copy, scope: .anything)
        GoToCommands.add(model.servers, target: target, waitingCount: waitingItems.count,
                         navigation: model.prefs.navigation, into: &copy)
        items = copy.items
        runs = copy.runs
        // A waiting agent's row: its pane's, where its tab lists panes, else its tab's.
        waiting = waitingItems.map { w in
            let k = w.key
            let split = w.server.views[k.sessionID]?.window(k.windowID).map { PaneScope.arrangeable(window: $0).count > 1 } ?? false
            return split ? .pane(w.server.id, k.sessionID, k.windowID, k.blockID) : .tab(w.server.id, k.sessionID, k.windowID)
        }
        if model.servers.isEmpty {
            note = Messages.noComputers
        } else if !copy.connecting.isEmpty {
            note = copy.connecting.map { "\($0) is connecting" }.joined(separator: ", ")
        } else {
            note = nil
        }
        let snapshot = items, before = loading
        loading = Task { [searcher] in
            await before?.value
            await searcher.load(snapshot)
        }
        if first { prune(synced: copy.synced) }
        refresh()
        track()
    }

    @ObservationIgnored private var waiting: [GoToItemID] = []
    /// The index being built; a search waits for it.
    @ObservationIgnored private var loading: Task<Void, Never>?

    /// Drops recents a connected server no longer has, once the index can say which it has.
    private func prune(synced: Set<UUID>) {
        guard let model, !synced.isEmpty else { return }
        let ids = model.prefs.goToRecents.compactMap(\.itemID)
        let index = loading
        Task { [weak self, searcher] in
            await index?.value
            let present = await searcher.present(ids)
            guard let self, let model = self.model else { return }
            let pruned = GoToRecents.prune(model.prefs.goToRecents, synced: synced, present: present)
            if pruned != model.prefs.goToRecents { model.prefs.goToRecents = pruned }
        }
    }

    /// Watches only what changes the list: servers, their phase, sessions, tabs, agents and ports.
    /// Titles and directories live in the metadata boxes, which the copy reads outside this.
    private func track() {
        guard let model else { return }
        withObservationTracking {
            for s in model.servers {
                _ = s.phase
                _ = s.sessions
                _ = s.views
                _ = s.agentKeys
                _ = s.portRows
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.changed() }
        }
    }

    /// A throttle, not a debounce: the first change schedules the rebuild, later ones ride it.
    private func changed() {
        guard !closed, !rebuildPending else { return }
        rebuildPending = true
        Task { [weak self, throttle] in
            try? await Task.sleep(for: throttle)
            guard let self else { return }
            self.rebuildPending = false
            self.rebuild()
        }
    }

    // MARK: Query and scope

    /// The field's committed text changed.
    func setQuery(_ text: String) {
        guard prompt == nil else {
            query = text
            promptRows()
            return
        }
        if scope == .anything, text.hasPrefix(">") {
            byChevron = true
            scope = .commands
            let rest = String(text.dropFirst())
            setField(rest)
            query = rest
            refresh()
            return
        }
        query = text
        refresh()
    }

    /// Backspace in an empty field: out of `.commands` when `>` took it there.
    func backspaceOnEmpty() {
        guard prompt == nil, byChevron, scope == .commands else { return }
        byChevron = false
        scope = .anything
        refresh()
    }

    /// Another palette key while open: the scope changes, the text stays.
    func switchScope(_ s: GoToScope) {
        guard s != scope else { return }
        byChevron = false
        scope = s
        refresh()
    }

    /// The clear button: an empty field, the same scope.
    func clear() {
        setField("")
        setQuery("")
    }

    private func setField(_ text: String) {
        fieldText = text
        fieldVersion += 1
    }

    /// Recomputes the rows for the query and scope: at once for an empty query, through the
    /// searcher otherwise. A result a newer query overtook is dropped.
    private func refresh() {
        generation += 1
        let gen = generation
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            apply(emptyRows())
            return
        }
        let boosts = GoToRecents.boosts(model?.prefs.goToRecents ?? [], now: Date())
        let scope = scope, index = loading
        Task { [weak self, searcher] in
            await index?.value
            let hits = await searcher.search(q, scope: scope, boosts: boosts)
            guard let self, !self.closed, gen == self.generation else { return }
            self.apply(hits.compactMap { self.row($0) })
        }
    }

    private func emptyRows() -> [Row] {
        let sections = GoToRanker.empty(items, scope: scope, waiting: waiting, recents: model?.prefs.goToRecents ?? [])
        var out: [Row] = []
        for s in sections {
            for (i, index) in s.indices.enumerated() {
                guard var r = row(GoToHit(id: items[index].id, index: index, ranges: [], shortID: nil)) else { continue }
                if i == 0 { r.header = s.header }
                out.append(r)
            }
        }
        return out
    }

    private func row(_ hit: GoToHit) -> Row? {
        // An answer from before a rebuild names an index the items no longer have.
        guard items.indices.contains(hit.index), items[hit.index].id == hit.id else { return nil }
        let item = items[hit.index]
        var sub = item.subtitle
        if let id = hit.shortID { sub += " · id \(id)" }
        let badge: Row.Badge? = switch item.id {
        case .tab(let s, let sid, let wid): .window(s, sid, wid)
        case .pane(let s, _, _, let bid): .block(s, bid)
        default: nil
        }
        let kind = switch item.kind {
        case .session: "Session"
        case .tab: "Tab"
        case .pane: "Pane"
        case .command: "Command"
        }
        return Row(id: item.id, title: item.title, ranges: hit.ranges, subtitle: item.dimmed ?? sub, symbol: item.symbol,
                   keyLabel: item.keyLabel, dimmed: item.dimmed != nil, destructive: item.destructive, badge: badge,
                   kind: kind)
    }

    /// New rows: the selection stays on its item while it is still listed.
    private func apply(_ new: [Row]) {
        if new != rows { rows = new }
        if let selected, new.contains(where: { $0.id == selected }) { return }
        let picked = prompt == nil ? GoToRanker.selection(new, scope: scope) : new.first?.id
        if selected != picked { selected = picked }
    }

    // MARK: Moving and running

    /// ↑ ↓: the next row up or down; no wrap.
    func move(by d: Int) {
        guard !rows.isEmpty else { return }
        guard let cur = selected, let i = rows.firstIndex(where: { $0.id == cur }) else {
            selected = d > 0 ? rows.first?.id : rows.last?.id
            return
        }
        let j = min(max(i + d, 0), rows.count - 1)
        if j != i { selected = rows[j].id }
    }

    /// Return: runs the selected row, by its id, never by its place.
    func runSelected() {
        guard let id = selected else { return }
        run(id)
    }

    func run(_ id: GoToItemID) {
        if prompt != nil { pick(id); return }
        guard let r = rows.first(where: { $0.id == id }), !r.dimmed else { return }
        center?.run(id)
    }

    /// Esc, a tap outside, the Cancel button.
    func dismiss() {
        if prompt != nil { center?.cancelPrompt() } else { center?.close() }
    }

    // MARK: A question

    func showPrompt(_ p: PalettePrompt) {
        prompt = p
        byChevron = false
        checked = []
        if case .pick(_, true, _, let selected) = p.kind { checked = selected }
        if case .input(_, let value) = p.kind {
            setField(value ?? "")
            query = value ?? ""
        } else {
            setField("")
            query = ""
        }
        selected = nil
        promptRows()
    }

    /// A pick's items as rows, filtered by the field; `allow_other` adds "Use “…”" first.
    private func promptRows() {
        guard let p = prompt else { return }
        guard case .pick(let items, let multiple, let allowOther, _) = p.kind else {
            if !rows.isEmpty { rows = [] }
            return
        }
        let q = query.trimmingCharacters(in: .whitespaces)
        var out: [Row] = []
        if allowOther, !q.isEmpty {
            out.append(Row(id: .other("use-other"), title: "Use “\(q)”", subtitle: "", symbol: "text.cursor", kind: "Answer"))
        }
        var matcher = FuzzyMatcher()
        let words = FoldedText.query(q)
        var scored: [(Row, Double, Int)] = []
        for (i, item) in items.enumerated() {
            var score = 0.0
            var ranges: [Range<Int>] = []
            if !words.isEmpty {
                let t = FoldedText(item.title)
                var ok = true
                for w in words {
                    guard let m = matcher.score(w, in: t, ranges: true) else { ok = false; break }
                    score += m.score
                    ranges += m.ranges
                }
                guard ok else { continue }
            }
            let row = Row(id: .other("item:" + item.id), title: item.title,
                          ranges: FuzzyMatcher.ranges(ranges.sorted { $0.lowerBound < $1.lowerBound }.flatMap { Array($0) }),
                          subtitle: item.subtitle ?? "", symbol: item.symbol,
                          checked: multiple ? checked.contains(item.id) : nil, detail: item.detail, kind: "Choice")
            scored.append((row, score, i))
        }
        if !words.isEmpty { scored.sort { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 } }
        out += scored.map(\.0)
        if out != rows { rows = out }
        if let selected, out.contains(where: { $0.id == selected }) { return }
        selected = out.first?.id
    }

    /// A tap or Return on a question's row.
    private func pick(_ id: GoToItemID) {
        guard let p = prompt, case .other(let raw) = id else { return }
        if raw == "use-other" {
            center?.answer(PalettePrompt.text(p.callID, query))
            return
        }
        guard raw.hasPrefix("item:") else { return }
        let item = String(raw.dropFirst(5))
        guard case .pick(_, let multiple, _, _) = p.kind else { return }
        if multiple {
            if checked.contains(item) { checked.remove(item) } else { checked.insert(item) }
            promptRows()
        } else {
            center?.answer(PalettePrompt.ids(p.callID, [item]))
        }
    }

    /// Return in the field.
    func submit() {
        guard let p = prompt else { runSelected(); return }
        switch p.kind {
        case .input:
            center?.answer(PalettePrompt.text(p.callID, query))
        case .pick(let items, let multiple, _, _):
            if multiple {
                // In the items' order, every checked one; none is an answer too.
                center?.answer(PalettePrompt.ids(p.callID, items.map(\.id).filter(checked.contains)))
            } else if let s = selected {
                pick(s)
            }
        }
    }

    /// The confirm button: what Return does, and for `multiple` the checked items.
    func confirm() { submit() }
}
