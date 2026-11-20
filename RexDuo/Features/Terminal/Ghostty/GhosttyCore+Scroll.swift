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

    /// How far the grid is drawn shifted up while the bottom `cover` pixels of the view are
    /// covered (the keyboard) and the viewport follows the active area: far enough that the last
    /// row with content sits above the cover, and no further. `contentRows` counts the screen's
    /// rows from the top through the last one with content or the cursor.
    static func pin(cover: Int, rows: Int, contentRows: Int, cellHeight: Int) -> Int {
        let blank = max(0, rows - contentRows)
        return min(max(cover - blank * max(1, cellHeight), 0), max(cover, 0))
    }

    /// Where to put the viewport so a find match shows (`GhosttyScrollState.Request.reveal`), or
    /// nil when it already does. `top` and `bottom` are the match's first and last screen rows;
    /// `viewTop` the first row the viewport shows (`maxRow` while it follows the active area),
    /// `len` its rows. The bottom `cover + findInset` pixels are hidden less the shift `bounce`
    /// the grid is drawn with; the top `bounce` pixels are off screen. A match that doesn't show
    /// gets its first row a third of the way down, or the bottom position (`maxRow`) when that is
    /// as far as the viewport goes.
    static func reveal(top: Int, bottom: Int, viewTop: Int, len: Int, cellHeight: Int, cover: Int, findInset: Int,
                       bounce: Int, maxRow: Int) -> Int? {
        let cell = max(1, cellHeight)
        let hidden = max(0, cover + findInset)
        // Row k of the viewport is drawn from `k * cell - bounce`; it shows if it is whole
        // between the top edge and the hidden band.
        let first = bounce > 0 ? (bounce + cell - 1) / cell : 0
        let lastEdge = len * cell + bounce - hidden
        let last = lastEdge / cell - 1
        let visible = max(1, last - first + 1)
        if top >= viewTop + first, bottom <= viewTop + last { return nil }
        return min(max(0, top - visible / 3), max(0, maxRow))
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
/// The cover. The view may be taller than what shows of it: the keyboard covers its bottom
/// `cover` pixels and the grid keeps its rows. The scroll view then has that much more room to
/// scroll past the last row position, and a position in that room draws the grid shifted up by
/// the difference (`bounce`, the same shift a rubber band at the bottom uses). While the
/// viewport follows the active area and the user has not scrolled the covered rows back into
/// view, the render thread holds that shift at the pin (`GhosttyScrollMath.pin`), so the row the
/// program writes on stays above the keyboard as the screen fills. A shift the user left short of
/// the pin holds while nothing is written, or while a finger or the scroll's momentum holds the
/// view (`setTouching`); output after that goes back to the pin, so the newest rows and the cursor
/// never stream on under the keyboard. Those moves count in `rebase` like any other move the
/// terminal makes by itself.
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
        /// Bring these screen rows (a find match) into view, if they aren't
        /// (`GhosttyScrollMath.reveal`).
        case reveal(top: Int, bottom: Int)
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
        /// The program is on the alternate screen.
        var alternateScreen = false
        /// At the bottom, the grid's shift stays at the pin as the screen fills (see "The cover").
        var following = true

        var maxRow: Int { GhosttyScrollMath.maxRow(total: total, len: len) }
    }

    /// Main-thread updates are at most this frequent. Output that only grows the content can
    /// arrive 120 times a second; nothing visible needs the scroll view resized that often.
    static let publishInterval: CFTimeInterval = 1.0 / 30

    // MARK: Guarded by `lock`

    private let lock = GhosttyLock()
    private var pending: Request?
    private var sequence = 0
    private var coverWanted = 0
    /// The cover the render side has taken over.
    private var coverTaken = 0
    /// Pixels the find bar covers at the view's bottom, apart from the keyboard's cover.
    private var findInsetWanted = 0
    private var findInsetTaken = 0
    private var touchingWanted = false
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
    /// Pixels of the view's bottom that the keyboard covers, as of this frame.
    private var cover = 0
    /// Pixels the find bar covers below that, as of this frame. The pin and the clamps count
    /// both (`covered`); what decides "reading" (the `.lines` path) counts the keyboard only.
    private var findInset = 0
    private var covered: Int { cover + findInset }
    /// The cover changed and `finishFrame` has not seen it yet.
    private var coverChanged = false
    /// The shift that keeps the last row with content above the cover (last frame's).
    private var pin = 0
    private var following = true
    /// A finger or the scroll's momentum holds the view, as of this frame.
    private var touching = false
    private var frameActive = true
    private var frameRows = 0
    /// This frame's request was a position from the scroll view: its shift is the user's.
    private var positioned = false
    /// This frame's request set the shift at the bottom (a position there, or lines through the
    /// covered rows). Whether the shift follows the screen again is decided against this
    /// frame's pin, in `finishFrame`: the last frame's is stale when the cover changed in this
    /// one, and a shift read against it stopped following for good.
    private var shiftedAtBottom = false
    private var frameSnapshot = Snapshot()
    /// Pixels the grid is drawn shifted up this frame: sub-row offset plus rubber band.
    private(set) var renderFraction = 0
    private(set) var renderBounce = 0
    /// True if this frame's request moved the viewport to another row.
    private(set) var movedViewport = false
    /// True if this frame applied a `.reveal`.
    private(set) var appliedReveal = false
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
        return pending != nil || coverWanted != coverTaken || findInsetWanted != findInsetTaken
    }

    /// How many pixels of the view's bottom are covered, from the next frame on. Doesn't ask for
    /// a frame.
    func setCover(px: Int) {
        lock.lock()
        coverWanted = max(0, px)
        lock.unlock()
    }

    /// A finger or the scroll's momentum holds the view: output leaves a shift short of the pin
    /// where it is until it lets go (see "The cover"). Doesn't ask for a frame.
    func setTouching(_ on: Bool) {
        lock.lock()
        touchingWanted = on
        lock.unlock()
    }

    /// How many pixels at the view's bottom the find bar covers, from the next frame on. Kept
    /// apart from the keyboard's cover. Doesn't ask for a frame.
    func setFindInset(px: Int) {
        lock.lock()
        findInsetWanted = max(0, px)
        lock.unlock()
    }

    /// The frame builder counts the screen's rows with content only while it matters.
    var needsContentRows: Bool { covered > 0 || coverChanged }

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
        let wanted = coverWanted
        coverTaken = wanted
        let insetWanted = findInsetWanted
        findInsetTaken = insetWanted
        touching = touchingWanted
        lock.unlock()
        if wanted != cover || insetWanted != findInset {
            cover = wanted
            findInset = insetWanted
            coverChanged = true
            if covered == 0 { pin = 0 }
        }

        movedViewport = false
        appliedReveal = false
        positioned = false
        shiftedAtBottom = false
        if let request {
            let before = (bar.offset, active)
            // What the scroll view's offset stands for: the row position plus the shift.
            let shown = position + bounce
            var keepsShift = false
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
                positioned = true
                // At the pin or past it the shift follows the screen again; short of it, the
                // user is looking at the covered rows and it stays where they left it until
                // output arrives with nothing holding the view (`finishFrame`, which also decides
                // again with this frame's pin).
                following = r.bottom && bounce >= pin - 1
                shiftedAtBottom = r.bottom
            case .lines(let n):
                if active, cover > 0, n > 0 || bounce > 0 {
                    // At the bottom, lines go through the covered rows first.
                    bounce = min(max(bounce + n * cell, 0), cover)
                    following = bounce >= pin - 1
                    shiftedAtBottom = true
                    keepsShift = true
                } else if n != 0 {
                    scroll(t, GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA) { $0.delta = n }
                }
            case .pages(let n):
                if n != 0 { scroll(t, GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA) { $0.delta = n * max(1, bar.len) } }
            case .prompts(let n):
                if n != 0 { scroll(t, GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA_PROMPT) { $0.delta_prompt = n } }
            case .top:
                scroll(t, GHOSTTY_TERMINAL_SCROLL_VIEWPORT_TOP)
            case .bottom:
                scroll(t, GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM)
            case .reveal(let top, let bottom):
                appliedReveal = true
                let viewTop = active ? bar.maxRow : min(bar.offset, bar.maxRow)
                if let row = GhosttyScrollMath.reveal(top: top, bottom: bottom, viewTop: viewTop, len: bar.len, cellHeight: cell,
                                                      cover: cover, findInset: findInset, bounce: bounce, maxRow: bar.maxRow) {
                    if row >= bar.maxRow {
                        if !active { scroll(t, GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM) }
                    } else {
                        scroll(t, GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW) { $0.row = row }
                    }
                } else {
                    // Already in view: nothing moves, the shift stays.
                    keepsShift = true
                }
            }
            (bar, active) = Self.read(t)
            movedViewport = before != (bar.offset, active)
            if active { fraction = 0 }
            truth = GhosttyScrollMath.position(offset: active ? bar.maxRow : min(bar.offset, bar.maxRow),
                                               fraction: fraction, cellHeight: cell)
            if case .position = request {
                // The sender's offset already says this; nothing to rebase.
            } else {
                // A jump the scroll view knows nothing about: whole rows, no rubber band. One
                // that ends at the bottom follows the screen (`finishFrame` sets the shift).
                fraction = active ? 0 : fraction
                if !keepsShift {
                    bounce = 0
                    if active { following = true }
                }
                rebase += truth + bounce - shown
            }
            position = truth
            appliedSequence = seq
        }
        renderFraction = fraction
        renderBounce = bounce
        frameActive = active
        frameRows = bar.len

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
        snap.alternateScreen = screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
        snap.following = following
        frameSnapshot = snap
        publish(snap)
    }

    /// The second half of a frame, once its rows are known: holds the shift at the pin while the
    /// viewport follows the screen, and keeps it inside a cover that became smaller. Runs where
    /// `prepareFrame` does (render side), before the frame builder reads `renderBounce`.
    /// `contentRows`: the screen's rows from the top through the last one with content or the
    /// cursor. `output`: the terminal changed since the last frame (its rows are dirty).
    func finishFrame(contentRows: Int, output: Bool) {
        guard covered > 0 || coverChanged else { return }
        let newCover = coverChanged
        coverChanged = false
        guard frameActive else { return }
        pin = GhosttyScrollMath.pin(cover: covered, rows: frameRows, contentRows: contentRows, cellHeight: cellHeight)
        var changed = false
        if shiftedAtBottom {
            // Decided against this frame's pin: the request was read with the last frame's.
            let follows = bounce >= pin - 1
            if follows != following {
                following = follows
                frameSnapshot.following = follows
                changed = true
            }
        } else if !following, output, !positioned, !touching {
            // Output below a shift the user left among the covered rows, now that nothing holds
            // the view: back to the pin, so what is written shows above the keyboard.
            following = true
            frameSnapshot.following = true
            changed = true
        }
        // A position holds the user's shift, unless the cover changed under it: then both apply,
        // and a view that follows goes to the new pin in this frame, not the next.
        let shift: Int
        if positioned, !(newCover && following) {
            shift = bounce
        } else {
            shift = following ? pin : min(bounce, covered)
        }
        if shift != bounce {
            rebase += shift - bounce
            bounce = shift
            renderBounce = shift
            frameSnapshot.bounce = shift
            frameSnapshot.rebase = rebase
            changed = true
        }
        if changed { publish(frameSnapshot) }
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
            || snap.alternateScreen != sent.alternateScreen
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
