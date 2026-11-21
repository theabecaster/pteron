import Foundation
import GhosttyVt
import QuartzCore
import Synchronization

/// One match, in screen rows: row 0 is the oldest line the terminal keeps, the same row space as
/// the scrollbar's `total` and `offset`. Both ends are included.
struct FindSpan: Equatable, Sendable {
    var startRow: Int
    var startCol: Int
    var endRow: Int
    var endCol: Int
}

/// What a search pass found, as the renderer and the find bar read it.
struct FindResult: Equatable, Sendable {
    /// Bumped by every publish, so a reader sees a new result without comparing the lists.
    var serial = 0
    /// Find is open on this pane. A closed find publishes an empty result with `open` false.
    var open = false
    /// The needle searched for, as bytes (empty: none).
    var needle: [UInt8] = []
    var total = 0
    /// 0 is the newest match. Nil when nothing is selected.
    var selectedIndex: Int?
    var selected: FindSpan?
    /// Matches on the pages around the viewport, as of the last feed.
    var matches: [FindSpan] = []
    /// The search has caught up with the terminal as of its last feed.
    var complete = true
    /// The scrollback is at its line limit: older lines are gone (for "No matches in recent history").
    var historyFull = false
}

/// Find in one terminal's screen and scrollback, with libghostty-vt's search (`ghostty_search_*`).
///
/// Threads and locks:
/// - Every pass runs on one serial queue for the process (`queue`), never on the main thread.
/// - `searchLock` guards the search handle and every library call on it. Calls that read the
///   terminal (`new`, `free`, `feed`, `set(needle)`, `select_*`) also hold the core's `termLock`,
///   taken first: the order is `termLock → searchLock`. `tick` and `get` need only `searchLock`.
/// - `published` holds the last result. It is never held across a library call and takes no
///   other lock while held (a leaf). The render thread reads it under `stateLock`.
/// - `control` guards the wishes the main thread leaves for the next pass (open, needle, steps).
///   It is a leaf too.
///
/// Refreshes are coalesced to one per `refreshInterval` and run only while the pane is drawn
/// (`isVisible`); triggers while hidden only set `dirty`, and becoming visible runs one pass.
/// User actions (a new needle, a step, open, close) run at once and set the core's `findDirty`,
/// so a frame the program holds (mode 2026) shows them. A refresh caused by output does not:
/// it shows in the next frame the program lets through.
///
/// Memory: nothing exists until find first opens. The handle is freed when find closes.
///
/// `@unchecked Sendable`: `handle` and `applied` are guarded by `searchLock`; `buffer`, `serial`
/// and `publishedIncomplete` are only touched on `queue` (`serial` also inside `published`'s
/// lock); `core` is weak and set once. Everything else is in a `Mutex` or an atomic.
final class GhosttyFind: @unchecked Sendable {
    /// One queue for every pane's passes. A pass is bounded, so panes take turns.
    static let queue = DispatchQueue(label: "rex.ghostty.find", qos: .userInitiated)
    /// At most one output refresh per interval, as Ghostty's own search thread.
    static let refreshInterval: CFTimeInterval = 0.024
    /// Ticks run in chunks this long, with `searchLock` released between them.
    static let tickChunk: CFTimeInterval = 0.000_25
    /// Ticks per pass, then the queue yields to other panes.
    static let tickBudget: CFTimeInterval = 0.002
    /// Distinct pages converted per feed. Pages, not matches: practically never reached.
    static let conversionCap = 2048

    /// Weak: a pass queued when the pane goes away finds no core and does nothing (the core's
    /// teardown frees the handle).
    private weak var core: GhosttyCore?
    let searchLock = GhosttyLock()
    /// Guarded by `searchLock` (and `termLock` for calls that read the terminal).
    private var handle: GhosttySearch?
    /// The needle set on `handle`. Guarded by `searchLock`.
    private var applied: [UInt8]?
    /// Reused for `VIEWPORT_MATCHES`. Queue only.
    private var buffer: [GhosttySelection] = []
    /// When the last feed ran (`CACurrentMediaTime` as bits). Written on the queue, read anywhere.
    private let lastFeedBits = Atomic<UInt64>(0)
    private var lastFeed: CFTimeInterval {
        get { Double(bitPattern: lastFeedBits.load(ordering: .relaxed)) }
        set { lastFeedBits.store(newValue.bitPattern, ordering: .relaxed) }
    }
    private var serial = 0
    /// The last publish said the search wasn't caught up. Queue only.
    private var publishedIncomplete = false

    /// The last result. A leaf lock.
    let published = Mutex(FindResult())

    private struct Control {
        var open = false
        var needle: [UInt8] = []
        /// Steps asked for and not taken yet: positive toward older matches (next).
        var steps = 0
        /// A pass is queued.
        var scheduled = false
        /// The next pass is for the user: it sets `findDirty`.
        var userAct = false
    }
    private let control = Mutex(Control())
    /// Output, a viewport move or a resize happened since the last feed. Any thread.
    let dirty = Atomic<Bool>(false)
    /// Mirrors `control.open` for the hot path (`noteChanged`, called for every slice of output).
    private let isOpen = Atomic<Bool>(false)
    /// Whether the pane is drawn now. Set by the view; read on the queue.
    var isVisible: @Sendable () -> Bool {
        get { visibleCheck.withLock { $0 } }
        set { visibleCheck.withLock { $0 = newValue } }
    }
    private let visibleCheck = Mutex<@Sendable () -> Bool>({ true })
    /// Runs after a publish (the renderer's wake-up). Any thread.
    var onPublish: (@Sendable (_ user: Bool) -> Void)?
    /// Runs on the queue after a step selected a match: its rows, to scroll to.
    var onReveal: (@Sendable (_ top: Int, _ bottom: Int) -> Void)?
    /// Runs after every publish, for the find bar's count (the view hops to the main thread).
    var onUpdate: (@Sendable () -> Void)? {
        get { updateHandler.withLock { $0 } }
        set { updateHandler.withLock { $0 = newValue } }
    }
    private let updateHandler = Mutex<(@Sendable () -> Void)?>(nil)

    /// Counters for tests and the benchmark. Queue writes; any thread reads.
    let feeds = Atomic<Int>(0)
    let passes = Atomic<Int>(0)

    init(core: GhosttyCore) {
        self.core = core
    }

    // MARK: Main thread (or any thread): wishes for the next pass

    /// Opens find: the next pass makes the handle. Nothing is searched until a needle is set.
    func open() {
        let start = control.withLock { c -> Bool in
            c.open = true
            c.userAct = true
            return schedule(&c)
        }
        isOpen.store(true, ordering: .relaxed)
        if start { Self.queue.async { self.pass() } }
    }

    /// Closes find: the next pass frees the handle and publishes an empty result.
    func close() {
        let start = control.withLock { c -> Bool in
            c.open = false
            c.steps = 0
            // A reopen starts from nothing: the old needle never shows again, even for a frame.
            c.needle = []
            c.userAct = true
            return schedule(&c)
        }
        isOpen.store(false, ordering: .relaxed)
        if start { Self.queue.async { self.pass() } }
    }

    /// Searches for `needle` (already sanitized: `FindQuery.sanitize`). Empty clears it.
    func setNeedle(_ needle: [UInt8]) {
        let start = control.withLock { c -> Bool in
            guard c.needle != needle else { return false }
            c.needle = needle
            c.userAct = true
            return schedule(&c)
        }
        if start { Self.queue.async { self.pass() } }
    }

    /// Selects the next (older, `+1`) or previous (newer, `-1`) match and scrolls to it.
    func step(_ by: Int) {
        let start = control.withLock { c -> Bool in
            c.steps += by
            c.userAct = true
            return schedule(&c)
        }
        if start { Self.queue.async { self.pass() } }
    }

    /// Something on screen may have changed (output, a viewport move, a resize). Coalesced and
    /// throttled; one atomic load while find is closed. Any thread.
    func noteChanged() {
        guard isOpen.load(ordering: .relaxed) else { return }
        dirty.store(true, ordering: .relaxed)
        let start = control.withLock { c -> Bool in schedule(&c) }
        guard start else { return }
        let wait = lastFeedWait()
        if wait > 0 {
            Self.queue.asyncAfter(deadline: .now() + wait) { self.pass() }
        } else {
            Self.queue.async { self.pass() }
        }
    }

    /// The pane became visible (or hidden). A pane that missed output while hidden refreshes once.
    func visibilityChanged() {
        guard isOpen.load(ordering: .relaxed), dirty.load(ordering: .relaxed) else { return }
        noteChanged()
    }

    /// Right after a `.reveal` was applied: outside the throttle, at most once per rendered frame
    /// (the renderer calls it once per frame that applied one).
    func revealApplied() {
        guard isOpen.load(ordering: .relaxed) else { return }
        dirty.store(true, ordering: .relaxed)
        let start = control.withLock { c -> Bool in schedule(&c) }
        if start { Self.queue.async { self.pass() } }
    }

    var opened: Bool { isOpen.load(ordering: .relaxed) }

    /// True if a pass must be queued now. Under `control`.
    private func schedule(_ c: inout Control) -> Bool {
        guard !c.scheduled else { return false }
        c.scheduled = true
        return true
    }

    private func lastFeedWait() -> CFTimeInterval {
        lastFeed + Self.refreshInterval - CACurrentMediaTime()
    }

    // MARK: Terminal swap (feed queue, `termLock` held)

    /// The core is about to free the terminal the handle borrows (a snapshot restore). Called with
    /// `termLock` held. The next pass makes a new handle on the new terminal and sets the needle
    /// again; the selection starts over.
    func terminalWillSwap() {
        searchLock.lock()
        if let h = handle { ghostty_search_free(h) }
        handle = nil
        applied = nil
        searchLock.unlock()
        // Rows of the old terminal mean nothing on the new one.
        published.withLock { r in
            r.matches = []
            r.selected = nil
            r.selectedIndex = nil
            serial &+= 1
            r.serial = serial
        }
    }

    /// The terminal is gone (core teardown). Called with exclusive access.
    func freeHandle() {
        searchLock.lock()
        if let h = handle { ghostty_search_free(h) }
        handle = nil
        applied = nil
        searchLock.unlock()
    }

    /// Whether the handle exists (tests: nothing is allocated before find opens or after it closes).
    var hasHandle: Bool {
        searchLock.lock()
        defer { searchLock.unlock() }
        return handle != nil
    }

    // MARK: The pass (queue)

    private func pass() {
        dispatchPrecondition(condition: .onQueue(Self.queue))
        passes.add(1, ordering: .relaxed)
        let wish = control.withLock { c -> Control in
            let w = c
            c.scheduled = false
            c.steps = 0
            c.userAct = false
            return w
        }
        guard wish.open else {
            closePass(user: wish.userAct)
            return
        }
        // Hidden: only a user action is worth a feed. Output waits for the pane to show.
        if !isVisible(), wish.steps == 0, !wish.userAct {
            dirty.store(true, ordering: .relaxed)
            return
        }
        var status = tick()
        let wasDirty = dirty.exchange(false, ordering: .relaxed)
        // A search that caught up in its ticks still owes the bar its final count.
        let mustFeed = wasDirty || wish.userAct || wish.steps != 0 || status == GHOSTTY_SEARCH_STATUS_FEED_REQUIRED
            || (publishedIncomplete && status != GHOSTTY_SEARCH_STATUS_RUNNING)
            || CACurrentMediaTime() - lastFeed >= Self.refreshInterval
        var result: FindResult?
        var reveal: FindSpan?
        if mustFeed {
            (result, reveal, status) = feed(needle: wish.needle, steps: wish.steps)
        }
        if let result {
            publishedIncomplete = !result.complete
            publish(result, user: wish.userAct || wish.steps != 0)
        }
        if let reveal { onReveal?(reveal.startRow, reveal.endRow) }
        // More to do: the search isn't caught up, or output came during the pass.
        let more = status == GHOSTTY_SEARCH_STATUS_RUNNING || status == GHOSTTY_SEARCH_STATUS_FEED_REQUIRED
        if more || dirty.load(ordering: .relaxed) {
            let start = control.withLock { c -> Bool in schedule(&c) }
            guard start else { return }
            if more {
                Self.queue.async { self.pass() }
            } else {
                Self.queue.asyncAfter(deadline: .now() + max(0, lastFeed + Self.refreshInterval - CACurrentMediaTime())) { self.pass() }
            }
        }
    }

    /// Ticks in short chunks, releasing `searchLock` between them, for at most `tickBudget`.
    private func tick() -> GhosttySearchStatus {
        var status = GHOSTTY_SEARCH_STATUS_COMPLETE
        let start = CACurrentMediaTime()
        while true {
            searchLock.lock()
            guard let h = handle else {
                searchLock.unlock()
                return GHOSTTY_SEARCH_STATUS_FEED_REQUIRED
            }
            let chunkStart = CACurrentMediaTime()
            repeat {
                ghostty_search_tick(h, &status)
            } while status == GHOSTTY_SEARCH_STATUS_RUNNING && CACurrentMediaTime() - chunkStart < Self.tickChunk
            searchLock.unlock()
            if status != GHOSTTY_SEARCH_STATUS_RUNNING || CACurrentMediaTime() - start >= Self.tickBudget { return status }
        }
    }

    /// Takes the terminal, makes the handle if needed, sets the needle, feeds, takes the steps and
    /// reads the result, all in one critical section so the matches' grid references stay valid.
    private func feed(needle: [UInt8], steps: Int) -> (FindResult?, FindSpan?, GhosttySearchStatus) {
        guard let core else { return (nil, nil, GHOSTTY_SEARCH_STATUS_COMPLETE) }
        core.lockTerminal()
        searchLock.lock()
        defer {
            searchLock.unlock()
            core.termLock.unlock()
        }
        guard let t = core.terminal else { return (nil, nil, GHOSTTY_SEARCH_STATUS_COMPLETE) }
        if handle == nil {
            var h: GhosttySearch?
            guard ghostty_search_new(nil, &h, t) == GHOSTTY_SUCCESS, let h else { return (nil, nil, GHOSTTY_SEARCH_STATUS_COMPLETE) }
            // The renderer moves the viewport (`.reveal`), never the search.
            var none = GHOSTTY_SEARCH_SCROLL_NONE
            ghostty_search_set(h, GHOSTTY_SEARCH_OPT_SELECT_SCROLL, &none)
            handle = h
            applied = nil
        }
        guard let h = handle else { return (nil, nil, GHOSTTY_SEARCH_STATUS_COMPLETE) }
        if applied != needle {
            if needle.isEmpty {
                ghostty_search_set(h, GHOSTTY_SEARCH_OPT_NEEDLE, nil)
            } else {
                needle.withUnsafeBufferPointer { p in
                    var s = GhosttyString(ptr: p.baseAddress, len: p.count)
                    ghostty_search_set(h, GHOSTTY_SEARCH_OPT_NEEDLE, &s)
                }
            }
            applied = needle
        }
        ghostty_search_feed(h)
        feeds.add(1, ordering: .relaxed)
        lastFeed = CACurrentMediaTime()
        var reveal: FindSpan?
        if steps != 0, !needle.isEmpty {
            for _ in 0..<abs(steps) {
                if steps > 0 { ghostty_search_select_next(h) } else { ghostty_search_select_prev(h) }
            }
        }
        var status = GHOSTTY_SEARCH_STATUS_COMPLETE
        ghostty_search_get(h, GHOSTTY_SEARCH_DATA_STATUS, &status)
        var r = FindResult()
        r.open = true
        r.needle = needle
        r.complete = status == GHOSTTY_SEARCH_STATUS_COMPLETE
        var total = 0
        ghostty_search_get(h, GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &total)
        r.total = total
        var index = 0
        if ghostty_search_get(h, GHOSTTY_SEARCH_DATA_SELECTED_INDEX, &index) == GHOSTTY_SUCCESS { r.selectedIndex = index }
        var selected = GhosttySelection()
        if ghostty_search_get(h, GHOSTTY_SEARCH_DATA_SELECTED_MATCH, &selected) == GHOSTTY_SUCCESS {
            var cache = PageRows()
            r.selected = Self.span(selected, t, &cache)
            if steps != 0 { reveal = r.selected }
        }
        r.matches = viewportMatches(h, t)
        var rows = 0
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &rows)
        r.historyFull = rows >= GhosttyCore.scrollbackMaxLines
        return (r, reveal, status)
    }

    /// `VIEWPORT_MATCHES` as screen-row spans. The buffer grows to what the library asks for and
    /// is read again in the same critical section: no feed in between, so the references hold.
    private func viewportMatches(_ h: GhosttySearch, _ t: GhosttyTerminal) -> [FindSpan] {
        if buffer.isEmpty { buffer = [GhosttySelection](repeating: GhosttySelection(), count: 64) }
        var count = 0
        var rc = buffer.withUnsafeMutableBufferPointer { p -> GhosttyResult in
            var b = GhosttySelectionBuffer(ptr: p.baseAddress, cap: p.count, len: 0)
            let rc = ghostty_search_get(h, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &b)
            count = b.len
            return rc
        }
        if rc == GHOSTTY_OUT_OF_SPACE {
            buffer = [GhosttySelection](repeating: GhosttySelection(), count: max(count, buffer.count * 2))
            rc = buffer.withUnsafeMutableBufferPointer { p -> GhosttyResult in
                var b = GhosttySelectionBuffer(ptr: p.baseAddress, cap: p.count, len: 0)
                let rc = ghostty_search_get(h, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &b)
                count = b.len
                return rc
            }
        }
        guard rc == GHOSTTY_SUCCESS else { return [] }
        var cache = PageRows()
        var out: [FindSpan] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            guard cache.count < Self.conversionCap else { break }
            if let s = Self.span(buffer[i], t, &cache) { out.append(s) }
        }
        return out
    }

    /// The screen row of the first row of each page seen so far: one conversion per page, then
    /// `row = base + ref.y`. Rows in a page are consecutive screen rows.
    struct PageRows {
        private var base: [UnsafeMutableRawPointer: Int] = [:]
        var count: Int { base.count }

        mutating func row(_ ref: GhosttyGridRef, _ t: GhosttyTerminal) -> (row: Int, col: Int)? {
            guard let node = ref.node else { return nil }
            if let b = base[node] { return (b + Int(ref.y), Int(ref.x)) }
            var r = ref
            var point = GhosttyPointCoordinate()
            guard ghostty_terminal_point_from_grid_ref(t, &r, GHOSTTY_POINT_TAG_SCREEN, &point) == GHOSTTY_SUCCESS else { return nil }
            base[node] = Int(point.y) - Int(ref.y)
            return (Int(point.y), Int(point.x))
        }
    }

    static func span(_ s: GhosttySelection, _ t: GhosttyTerminal, _ cache: inout PageRows) -> FindSpan? {
        guard let a = cache.row(s.start, t), let b = cache.row(s.end, t) else { return nil }
        // Matches run forward, but don't depend on it.
        let (lo, hi) = (a.row, a.col) <= (b.row, b.col) ? (a, b) : (b, a)
        return FindSpan(startRow: lo.row, startCol: lo.col, endRow: hi.row, endCol: hi.col)
    }

    /// Closed: free the handle under the terminal lock and publish nothing found.
    private func closePass(user: Bool) {
        guard let core else { return }
        core.lockTerminal()
        searchLock.lock()
        if let h = handle { ghostty_search_free(h) }
        handle = nil
        applied = nil
        searchLock.unlock()
        core.termLock.unlock()
        buffer = []
        dirty.store(false, ordering: .relaxed)
        publish(FindResult(), user: user)
    }

    private func publish(_ result: FindResult, user: Bool) {
        var r = result
        published.withLock { p in
            serial &+= 1
            r.serial = serial
            p = r
        }
        onPublish?(user)
        onUpdate?()
    }
}

extension GhosttyCore {
    /// The pane's find, made on first use and kept (it holds no library memory while closed).
    func makeFind() -> GhosttyFind {
        findSlot.withLock { slot in
            if let f = slot { return f }
            let f = GhosttyFind(core: self)
            f.onPublish = { [weak self] user in
                guard let self else { return }
                if user { self.findDirty.store(true, ordering: .relaxed) }
                self.onDirty?()
            }
            f.onReveal = { [weak self] top, bottom in
                self?.scrollViewport(.reveal(top: top, bottom: bottom))
            }
            slot = f
            return f
        }
    }

    /// The pane's find, or nil if it never opened. Any thread.
    var find: GhosttyFind? { findSlot.withLock { $0 } }
}
