import Foundation
import GhosttyVt
import QuartzCore

/// Pure scroll arithmetic, in device pixels and rows.
enum GhosttyScrollMath {
    /// Where a pixel position in the scrollable area puts the viewport.
    struct Resolved: Equatable {
        /// First visible row (`GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW` space).
        var row: Int
        /// How far that row is scrolled off the top, `0 ..< cellHeight`.
        var fraction: Int
        /// Overscroll (rubber band): negative past the top, positive past the bottom.
        var bounce: Int
        /// At or past the last position: the viewport follows the active area.
        var bottom: Bool
    }

    /// `px` is the distance from the top of the oldest row to the top of the view.
    static func resolve(px: Int, maxRow: Int, cellHeight: Int) -> Resolved {
        let cell = max(1, cellHeight), last = max(0, maxRow)
        if px <= 0 { return Resolved(row: 0, fraction: 0, bounce: px, bottom: last == 0) }
        let end = last * cell
        if px >= end { return Resolved(row: last, fraction: 0, bounce: px - end, bottom: true) }
        return Resolved(row: px / cell, fraction: px % cell, bounce: 0, bottom: false)
    }

    /// The row the viewport can scroll down to: the top of the active area.
    static func maxRow(total: Int, len: Int) -> Int { max(0, total - len) }

    /// Content height for a scroll view `viewHeight` pixels tall, so that its largest offset is
    /// exactly the last row position.
    static func contentHeight(total: Int, len: Int, cellHeight: Int, viewHeight: Int) -> Int {
        maxRow(total: total, len: len) * max(1, cellHeight) + max(0, viewHeight)
    }

    /// The viewport's position in pixels.
    static func position(offset: Int, fraction: Int, cellHeight: Int) -> Int {
        offset * max(1, cellHeight) + fraction
    }
}

/// The scroll position of one terminal, shared by the main thread (which owns the gesture) and
/// the render thread (which owns the terminal's viewport).
///
/// The main thread never takes the terminal lock to scroll. It leaves a request here and wakes
/// the renderer. `prepareFrame` applies it in the same critical section as the render state
/// update, so the row the viewport is on and the sub-row pixel offset always change together.
///
/// Two coordinate systems meet here. The render thread knows the truth: the viewport's pixel
/// position in the terminal's row space. The main thread has a scroll view offset, which goes
/// stale whenever the terminal moves by itself (output while following the bottom, rows pruned
/// from the top while scrolled up, a resize, a snapshot restore, someone else calling
/// `ghostty_terminal_scroll_viewport`). `rebase` is the running sum of those moves: truth =
/// main's offset + rebase. Each position request says which rebase it was computed with, so it
/// is read correctly even if the terminal moved after it was sent.
///
/// `@unchecked Sendable`: `lock` guards the block marked so. The render-side block is only
/// touched inside `GhosttyCore.lockFrame` (terminal and render state locks held), which only one
/// thread runs at a time.
final class GhosttyScrollState: @unchecked Sendable {
    enum Request: Equatable {
        /// A scroll view offset in pixels, and the rebase the sender had applied.
        case position(px: Int, rebaseSeen: Int)
        /// Rows, negative up.
        case lines(Int)
        /// Viewport heights, negative up.
        case pages(Int)
        /// Shell prompts (OSC 133), negative back.
        case prompts(Int)
        case top
        case bottom
    }

    /// What the last frame left on screen.
    struct Snapshot: Equatable, Sendable {
        var total = 0
        var offset = 0
        var len = 0
        /// The viewport follows the active area.
        var active = true
        var fraction = 0
        var bounce = 0
        var cellHeight = 1
        /// True position in pixels: `offset * cellHeight + fraction`.
        var position = 0
        var rebase = 0
        /// The newest request this frame had applied.
        var appliedSequence = 0
        /// The program gets one-finger drags (mouse tracking or alternate screen).
        var programScroll = false

        var maxRow: Int { GhosttyScrollMath.maxRow(total: total, len: len) }
    }

    /// Main-thread updates are at most this frequent. Output that only grows the content can
    /// arrive 120 times a second; nothing visible needs the scroll view resized that often.
    static let publishInterval: CFTimeInterval = 1.0 / 30

    // MARK: Guarded by `lock`

    private let lock = GhosttyLock()
    private var pending: Request?
    private var sequence = 0
    private var latest = Snapshot()
    private var sent = Snapshot()
    private var publishScheduled = false
    private var lastPublish: CFTimeInterval = 0
    private var publishHandler: (@MainActor @Sendable (Snapshot) -> Void)?

    // MARK: Render side (inside `lockFrame` only)

    private var position = 0
    private var fraction = 0
    private var bounce = 0
    private var rebase = 0
    private var cellHeight = 0
    private var appliedSequence = 0
    private var overscanGeneration = -1
    /// Pixels the grid is drawn shifted up this frame: sub-row offset plus rubber band.
    private(set) var renderFraction = 0
    private(set) var renderBounce = 0
    /// True if this frame's request moved the viewport to another row.
    private(set) var movedViewport = false
    /// Scroll calls made so far (tests and tuning).
    private(set) var viewportCalls = 0

    // MARK: Any thread

    /// Leaves a request for the next frame and returns its sequence number. Position requests
    /// replace each other; line and page requests add up. Doesn't ask for a frame: use
    /// `GhosttyCore.scrollViewport`.
    @discardableResult
    func request(_ r: Request) -> Int {
        lock.lock()
        switch (pending, r) {
        case (.lines(let a), .lines(let b)): pending = .lines(a + b)
        case (.pages(let a), .pages(let b)): pending = .pages(a + b)
        case (.prompts(let a), .prompts(let b)): pending = .prompts(a + b)
        default: pending = r
        }
        sequence &+= 1
        let s = sequence
        lock.unlock()
        return s
    }

    var hasPending: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending != nil
    }

    /// The last frame's scroll state.
    var snapshot: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// `handler` runs on the main thread, coalesced, when the scrollable area or the rebase changed.
    func setPublishHandler(_ handler: (@MainActor @Sendable (Snapshot) -> Void)?) {
        lock.lock()
        publishHandler = handler
        // Whoever listens now has seen nothing yet.
        sent = Snapshot()
        sent.total = -1
        lock.unlock()
    }

    // MARK: Render side

    /// Applies the pending request and requests overscan. Runs under the terminal lock and the
    /// render state lock, right before `ghostty_render_state_begin_update`, so the scroll
    /// position read here describes the same moment as the rows.
    func prepareFrame(terminal t: GhosttyTerminal, renderState: GhosttyRenderState, cellHeightPx: Int, generation: Int) {
        if generation != overscanGeneration {
            // Upstream's smooth-scroll recipe: one row below the viewport is enough to draw the
            // row that shows partly at the bottom edge while the grid is shifted up.
            var overscan = GhosttyRenderStateOverscan(above: 0, below: 1)
            ghostty_render_state_set(renderState, GHOSTTY_RENDER_STATE_OPT_OVERSCAN, &overscan)
            overscanGeneration = generation
        }
        let cell = max(1, cellHeightPx)
        if cell != cellHeight {
            cellHeight = cell
            fraction = 0
        }
        var (bar, active) = Self.read(t)
        if active { fraction = 0 }
        // Where the terminal is now. If that isn't where we left it, it moved by itself.
        var truth = GhosttyScrollMath.position(offset: active ? bar.maxRow : min(bar.offset, bar.maxRow),
                                               fraction: fraction, cellHeight: cell)
        rebase += truth - position
        position = truth

        lock.lock()
        let request = pending
        pending = nil
        let seq = sequence
        lock.unlock()

        movedViewport = false
        if let request {
            let before = (bar.offset, active)
            switch request {
            case .position(let px, let rebaseSeen):
                let r = GhosttyScrollMath.resolve(px: px + rebase - rebaseSeen, maxRow: bar.maxRow, cellHeight: cell)
                if r.bottom {
                    if !active { scroll(t, GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM) }
                } else if active || r.row != bar.offset {
                    scroll(t, GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW) { $0.row = r.row }
                }
                fraction = r.fraction
                bounce = r.bounce
            case .lines(let n):
                if n != 0 { scroll(t, GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA) { $0.delta = n } }
            case .pages(let n):
                if n != 0 { scroll(t, GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA) { $0.delta = n * max(1, bar.len) } }
            case .prompts(let n):
                if n != 0 { scroll(t, GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA_PROMPT) { $0.delta_prompt = n } }
            case .top:
                scroll(t, GHOSTTY_TERMINAL_SCROLL_VIEWPORT_TOP)
            case .bottom:
                scroll(t, GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM)
            }
            (bar, active) = Self.read(t)
            movedViewport = before != (bar.offset, active)
            if active { fraction = 0 }
            truth = GhosttyScrollMath.position(offset: active ? bar.maxRow : min(bar.offset, bar.maxRow),
                                               fraction: fraction, cellHeight: cell)
            if case .position = request {
                // The sender's offset already says this; nothing to rebase.
            } else {
                // A jump the scroll view knows nothing about: whole rows, no rubber band.
                fraction = active ? 0 : fraction
                bounce = 0
                rebase += truth - position
            }
            position = truth
            appliedSequence = seq
        }
        renderFraction = fraction
        renderBounce = bounce

        var tracking = false
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)

        var snap = Snapshot()
        snap.total = bar.total
        snap.offset = active ? bar.maxRow : bar.offset
        snap.len = bar.len
        snap.active = active
        snap.fraction = fraction
        snap.bounce = bounce
        snap.cellHeight = cell
        snap.position = position
        snap.rebase = rebase
        snap.appliedSequence = appliedSequence
        snap.programScroll = GhosttyScrollRouting.captures(mouseTracking: tracking,
                                                           alternateScreen: screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE)
        publish(snap)
    }

    /// The fraction can only show while a row below the viewport was captured.
    func clearRenderFraction() { renderFraction = 0 }

    private struct Bar {
        var total = 0, offset = 0, len = 0
        var maxRow: Int { GhosttyScrollMath.maxRow(total: total, len: len) }
    }

    private static func read(_ t: GhosttyTerminal) -> (Bar, Bool) {
        var raw = GhosttyTerminalScrollbar()
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &raw)
        var active = true
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &active)
        return (Bar(total: Int(raw.total), offset: Int(raw.offset), len: Int(raw.len)), active)
    }

    private func scroll(_ t: GhosttyTerminal, _ tag: GhosttyTerminalScrollViewportTag,
                        _ set: (inout GhosttyTerminalScrollViewportValue) -> Void = { _ in }) {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = tag
        set(&behavior.value)
        ghostty_terminal_scroll_viewport(t, behavior)
        viewportCalls &+= 1
    }

    /// Stores the frame's state and, if the main thread's picture of the scrollable area is now
    /// wrong, schedules one update for it. A position the main thread asked for itself is not
    /// news, so a fling costs the main thread nothing here.
    private func publish(_ snap: Snapshot) {
        lock.lock()
        latest = snap
        let news = snap.total != sent.total || snap.len != sent.len || snap.rebase != sent.rebase
            || snap.cellHeight != sent.cellHeight || snap.programScroll != sent.programScroll
        guard news, !publishScheduled, publishHandler != nil else {
            lock.unlock()
            return
        }
        publishScheduled = true
        let wait = Self.publishInterval - (CACurrentMediaTime() - lastPublish)
        lock.unlock()
        let deliver: @Sendable () -> Void = { [weak self] in
            MainActor.assumeIsolated { self?.deliver() }
        }
        if wait > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: deliver)
        } else {
            DispatchQueue.main.async(execute: deliver)
        }
    }

    @MainActor
    private func deliver() {
        lock.lock()
        publishScheduled = false
        lastPublish = CACurrentMediaTime()
        let snap = latest
        sent = snap
        let handler = publishHandler
        lock.unlock()
        handler?(snap)
    }
}

extension GhosttyCore {
    /// Scrolls the viewport on the next frame. Any thread; never waits for the terminal.
    @discardableResult
    func scrollViewport(_ request: GhosttyScrollState.Request) -> Int {
        let sequence = scroll.request(request)
        onDirty?()
        return sequence
    }

    /// Mouse tracking, alternate screen and alternate scroll (mode 1007), read together.
    func programScrollModes() -> (mouseTracking: Bool, alternateScreen: Bool, alternateScroll: Bool) {
        withTerminal { t in
            var tracking = false
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
            var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
            var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(1007, false), value: false)
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_MODE, &mode)
            return (tracking, screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE, mode.value)
        } ?? (false, false, false)
    }
}
