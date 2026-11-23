import Foundation
import Observation
import RexKit

/// Where folder listings come from: `DirLister` for a pane, a stand-in in tests.
@MainActor
protocol DirSource: AnyObject {
    func list(path: String, prefix: String, limit: Int) async throws -> DirPage
}

extension DirLister: DirSource {}

/// One folder on screen: its listing, the rows that show, and what went wrong. It keeps its
/// listing for as long as the browser is open, so going back shows it at once.
///
/// The main actor only swaps arrays in: the reply is read, sorted and filtered on other threads,
/// and a result that a newer request overtook is dropped.
@MainActor
@Observable
final class FolderModel {
    enum Problem: Equatable {
        /// The server may not read the folder.
        case denied
        /// It doesn't exist, or isn't a folder.
        case gone
        /// A status this build doesn't know.
        case unreadable
        /// The connection was lost; asked again when it is back.
        case lost
        /// The server has no `list_dir` (any more).
        case unsupported
        case refused(String)
    }

    enum Phase: Equatable {
        case loading
        case listed
        case failed(Problem)
    }

    /// A filter waits this long before it asks the server, while the listing is cut short.
    static let searchDelay: Duration = .milliseconds(250)

    /// The path asked for: absolute, `~`, relative to the pane's program, or empty for its
    /// working directory.
    private(set) var asked: String
    /// The folder as the server names it, once it has answered.
    private(set) var path: String
    private(set) var home = ""
    private(set) var phase = Phase.loading
    /// The entries on screen, in order.
    private(set) var rows: [DirEntry] = []
    /// The listing was cut short, and how many entries came.
    private(set) var truncated = false
    private(set) var received = 0
    /// The row the keyboard is on; nil until an arrow key is used.
    var selection: Int?

    var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    var showHidden = false {
        didSet { if showHidden != oldValue { refilter() } }
    }

    @ObservationIgnored private let source: any DirSource
    @ObservationIgnored private let limit: Int
    /// The folder's own listing, and the server's answer to the filter while that is cut short.
    @ObservationIgnored private var listing: DirListing?
    @ObservationIgnored private var found: (prefix: String, listing: DirListing)?
    /// Counts loads and filters; a result carries the count it was started under.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var search: Task<Void, Never>?
    @ObservationIgnored private(set) var loads = 0

    init(asked: String, source: any DirSource, showHidden: Bool = false, limit: Int = DirLister.limit) {
        self.asked = asked
        self.path = asked
        self.source = source
        self.limit = limit
        self.showHidden = showHidden
    }

    /// Lists the folder. A listing already on screen stays until the new one is in.
    func load() async {
        generation += 1
        let mine = generation
        loads += 1
        if listing == nil { phase = .loading }
        do {
            let page = try await source.list(path: asked, prefix: "", limit: limit)
            let built = await Task.detached(priority: .userInitiated) { DirListing(page) }.value
            guard mine == generation else { return }
            apply(built)
        } catch {
            guard mine == generation else { return }
            fail(error as? DirFailure ?? .lost(error.localizedDescription))
        }
    }

    /// Lists another folder in this one's place: a start folder that can't be read gives way to
    /// the home folder.
    func load(instead path: String) async {
        asked = path
        listing = nil
        await load()
    }

    private func apply(_ built: DirListing) {
        if !built.path.isEmpty { path = built.path }
        home = built.home
        switch built.status {
        case .ok:
            listing = built
            found = nil
            truncated = built.truncated
            received = built.items.count
            phase = .listed
            refilter()
        case .denied: drop(.denied)
        case .missing, .notDir: drop(.gone)
        case .other: drop(.unreadable)
        }
    }

    /// The folder can't be shown: nothing of it stays on screen.
    private func drop(_ problem: Problem) {
        listing = nil
        found = nil
        rows = []
        selection = nil
        truncated = false
        phase = .failed(problem)
    }

    private func fail(_ failure: DirFailure) {
        switch failure {
        // What is on screen stays, to read: the browser shows it as it is, with a line above.
        case .unsupported: phase = .failed(.unsupported)
        case .lost: phase = .failed(.lost)
        case .refused(let m): if listing == nil { phase = .failed(.refused(m)) }
        }
    }

    /// Whether the folder was read and holds nothing that shows.
    var isEmpty: Bool { phase == .listed && rows.isEmpty }

    /// Whether a listing is on screen, also behind a later failure (lost connection, lost support).
    var hasListing: Bool { listing != nil }

    private func queryChanged() {
        search?.cancel()
        search = nil
        refilter()
        // The folder's own listing is cut short: names past the cut are only on the server.
        guard listing?.truncated == true, !query.isEmpty, !DirPath.isPath(query) else { return }
        let prefix = query
        search = Task { [weak self] in
            try? await Task.sleep(for: Self.searchDelay)
            guard !Task.isCancelled, let self, self.query == prefix else { return }
            guard let page = try? await self.source.list(path: self.path, prefix: prefix, limit: self.limit) else { return }
            guard page.status == .ok else { return }
            let built = await Task.detached(priority: .userInitiated) { DirListing(page) }.value
            guard !Task.isCancelled, self.query == prefix else { return }
            self.found = (prefix, built)
            self.refilter()
        }
    }

    /// Filters off the main actor and swaps the rows in. The newest filter wins.
    private func refilter() {
        guard let listing else { return }
        generation += 1
        let mine = generation
        let q = query, hidden = showHidden
        // The server's answer to this filter holds every match by prefix; the folder's own listing
        // holds the matches inside a name. Both show, once each.
        let extra = found.flatMap { $0.prefix == q ? $0.listing : nil }
        Task { [weak self] in
            let rows = await Task.detached(priority: .userInitiated) { () -> [DirEntry] in
                let own = listing.visible(showHidden: hidden, query: q)
                guard let extra else { return own }
                let more = extra.visible(showHidden: hidden, query: q)
                let seen = Set(own.map(\.name))
                return (own + more.filter { !seen.contains($0.name) }).sorted(by: DirListing.inOrder)
            }.value
            guard let self, mine == self.generation else { return }
            if rows != self.rows { self.rows = rows }
            if let s = self.selection, s >= rows.count { self.selection = rows.isEmpty ? nil : rows.count - 1 }
        }
    }

    /// Moves the keyboard's row by `delta`; the first press lands on the first row.
    func move(_ delta: Int) {
        guard !rows.isEmpty else { return }
        guard let s = selection else { selection = delta < 0 ? rows.count - 1 : 0; return }
        selection = min(max(s + delta, 0), rows.count - 1)
    }

    var selected: DirEntry? {
        guard let s = selection, rows.indices.contains(s) else { return nil }
        return rows[s]
    }
}

/// The file browser of one pane: its folders, its mode and what it may do right now.
@MainActor
@Observable
final class BrowserModel {
    enum Mode: Equatable { case browse, insert }

    /// What the pane and its server allow at this moment. Read each time the browser draws, so a
    /// reconnect to a server without the methods, or the pane closing, shows at once.
    struct Facts: Equatable {
        /// Folders can be listed. False: the listing on screen is read-only.
        var canList = true
        /// Files can be fetched: Preview, Share and Save.
        var canFetch = true
        var insert = PathInsert.Decision.ask(program: nil)
        var paneOpen = true
        var online = true
    }

    let mode: Mode
    /// The pane's computer, as the app names it ("studio").
    let machine: String
    /// The computer's display name, when it has one; nil where `machine` is only a stand-in.
    let computer: String?
    /// The server runs macOS: a folder it may not read can be allowed in System Settings.
    let mac: Bool
    let root: FolderModel
    /// The folders opened from the first one, in order (the navigation stack).
    var stack: [String] = []
    /// The working directory of the pane's program, which relative paths start from.
    private(set) var cwd: String?
    private(set) var recents: [String]
    var showHidden: Bool {
        didSet {
            guard showHidden != oldValue else { return }
            for f in folders.values { f.showHidden = showHidden }
            root.showHidden = showHidden
            onShowHidden(showHidden)
        }
    }

    @ObservationIgnored let facts: @MainActor () -> Facts
    @ObservationIgnored var onShowHidden: (Bool) -> Void = { _ in }
    @ObservationIgnored var onPreview: (String) -> Void = { _ in }
    @ObservationIgnored var onShare: (String) -> Void = { _ in }
    @ObservationIgnored var onSave: (String) -> Void = { _ in }
    @ObservationIgnored var onCopy: (String) -> Void = { _ in }
    /// Insert this path and close.
    @ObservationIgnored var onInsert: (String) -> Void = { _ in }
    @ObservationIgnored var onClose: () -> Void = {}

    @ObservationIgnored private let source: any DirSource
    @ObservationIgnored private var folders: [String: FolderModel] = [:]

    /// `start`: the folder to open; empty for the working directory of the pane's program.
    init(mode: Mode, machine: String, computer: String? = nil, mac: Bool = false, start: String = "", source: any DirSource, recents: [String] = [],
         showHidden: Bool = false, facts: @escaping @MainActor () -> Facts) {
        self.mode = mode
        self.machine = machine
        self.computer = computer
        self.mac = mac
        self.source = source
        self.recents = recents
        self.showHidden = showHidden
        self.facts = facts
        root = FolderModel(asked: start, source: source, showHidden: showHidden)
    }

    /// Lists the first folder. The working directory is read with it: it is the first folder
    /// when the browser starts there, and one more small call when it starts somewhere else. A
    /// working directory that can't be listed (or a pane whose program has gone) starts at home.
    func start() async {
        if root.asked.isEmpty {
            await root.load()
            if !root.path.isEmpty { cwd = root.path }
            if case .failed(let p) = root.phase, p == .denied || p == .gone || p == .unreadable { await root.load(instead: "~") }
        } else {
            async let first: Void = root.load()
            if let page = try? await source.list(path: "", prefix: "", limit: 1), !page.path.isEmpty { cwd = page.path }
            await first
        }
    }

    func folder(for path: String) -> FolderModel {
        if let f = folders[path] { return f }
        let f = FolderModel(asked: path, source: source, showHidden: showHidden)
        folders[path] = f
        return f
    }

    /// The folder on screen.
    var current: FolderModel { stack.last.map(folder(for:)) ?? root }

    func go(to path: String) { stack.append(path) }

    /// Opens a folder entry of `folder`. A link is opened by its name under the folder it is in,
    /// so the title keeps the way the user walked.
    func open(_ entry: DirEntry, in folder: FolderModel) {
        guard !entry.isFile else { return }
        go(to: DirPath.join(folder.path, entry.name))
    }

    func path(of entry: DirEntry, in folder: FolderModel) -> String { DirPath.join(folder.path, entry.name) }

    /// Whether a tap on an entry does something now: a folder opens while folders can be listed,
    /// a file inserts in insert mode where Insert is offered, and previews in browse mode where
    /// files can be fetched. Nothing does once the pane has closed.
    func isLive(_ entry: DirEntry, _ facts: Facts) -> Bool {
        guard facts.paneOpen else { return false }
        if !entry.isFile { return facts.canList }
        return mode == .insert ? facts.insert.offered : facts.canFetch
    }

    /// A tap on an entry, or Return on it.
    func activate(_ entry: DirEntry, in folder: FolderModel) {
        guard isLive(entry, facts()) else { return }
        if !entry.isFile {
            open(entry, in: folder)
        } else if mode == .insert {
            onInsert(path(of: entry, in: folder))
        } else {
            onPreview(path(of: entry, in: folder))
        }
    }

    /// The folder above the one on screen: back when that is where the user came from.
    func goUp() {
        guard let parent = DirPath.parent(current.path) else { return }
        let below = stack.dropLast().last.map { folder(for: $0).path } ?? root.path
        if !stack.isEmpty, below == parent { stack.removeLast() } else { go(to: parent) }
    }

    /// Lists the folder on screen again: pull to refresh, Retry, the app coming back.
    func refresh() async { await current.load() }

    /// The connection is back, or the server changed under the browser: list again if a folder
    /// was waiting for that, and only where listing is (still) there.
    func reconnected() async {
        guard facts().canList else { return }
        if case .failed(let p) = current.phase, p == .lost || p == .unsupported { await current.load() }
    }
}
