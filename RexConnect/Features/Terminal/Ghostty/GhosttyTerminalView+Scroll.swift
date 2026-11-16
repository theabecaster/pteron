import UIKit
import GhosttyVt

// Scrolling and mouse reporting (chunk 2b). The work is in three places:
// - `GhosttyScroller` (main thread): a transparent UIScrollView over the Metal view for native
//   scroll physics, plus the recognizers for wheel drags, clicks and pointer motion.
// - `GhosttyScrollState` (`core.scroll`): the hand-over between the main thread and the render
//   thread. The render thread moves the terminal's viewport in the same critical section as the
//   render state update.
// - `GhosttyMouseReporter`: libghostty-vt's mouse and key encoders.
extension GhosttyTerminalView {
    /// Builds the scroller as soon as the view is used. (`scroller` is lazy because the stored
    /// property block in GhosttyTerminalView.swift can't reach `self` earlier.)
    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        if superview != nil { _ = scroller }
    }

    /// The pans on this view itself (the host's pointer-drag selection) ask `panGate` like the
    /// scroll surface's pans do (`GhosttyScroller.shouldBegin`).
    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        // UIKit also asks the touched view about its ancestors' recognizers; gate only our own.
        if g.view === self, let pan = g as? UIPanGestureRecognizer, let gate = panGate, !gate(pan) { return false }
        return super.gestureRecognizerShouldBegin(g)
    }

    // MARK: Seam

    /// The scroll view's own pan: one finger for scrollback, two while the program takes
    /// one-finger drags. The host limits it to direct touches; trackpad and wheel scrolls still
    /// reach it.
    var scrollPanRecognizer: UIPanGestureRecognizer? { scroller.surface.panGestureRecognizer }

    /// Scrolls the scrollback a page. On an alternate screen there is none, so the program gets
    /// Page Up or Page Down instead (SwiftTerm's rule). The screen and the key's bytes come from
    /// the input mirror, so a key press never waits for the terminal lock.
    func scrollPage(up: Bool) {
        if core.input.modes.alternateScreen {
            scroller.sendKeys(core.input.encode(GhosttyInputKey(up ? GHOSTTY_KEY_PAGE_UP : GHOSTTY_KEY_PAGE_DOWN)))
        } else {
            scroller.jump(.pages(up ? -1 : 1))
        }
    }

    /// Scrolls to the next or previous shell prompt, with libghostty-vt's own prompt scroll
    /// (`GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA_PROMPT`). Needs OSC 133 marks; without a
    /// matching prompt it does nothing.
    func scrollToPrompt(next: Bool) {
        scroller.jump(.prompts(next ? 1 : -1))
    }

    // MARK: For input (chunk 2a)

    /// Called after typed or pasted bytes went to the program: a scrolled-up view jumps back to
    /// the bottom, as in SwiftTerm. Output alone never moves a scrolled-up view.
    func scrollToBottomForInput() { scroller.scrollToBottomForInput() }

    // MARK: For selection (chunk 2c)

    /// The scroll position of the last drawn frame: rows in total, the first visible row
    /// (`offset`, the row space of `GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW`), visible rows, and
    /// the sub-row pixel offset.
    var scrollSnapshot: GhosttyScrollState.Snapshot { core.scroll.snapshot }

    /// The viewport cell under a point in this view's coordinates (what `location(in:)` gives),
    /// for `GHOSTTY_POINT_TAG_VIEWPORT`. Counts the part of a row scrolled past. Clamped to the grid.
    func viewportCell(at p: CGPoint) -> (col: Int, row: Int) {
        let s = core.scroll.snapshot, m = atlas.metrics
        let x = p.x * displayScale, y = p.y * displayScale + CGFloat(s.fraction + s.bounce)
        let col = Int((x / CGFloat(max(1, m.cellWidth))).rounded(.down))
        let row = Int((y / CGFloat(max(1, m.cellHeight))).rounded(.down))
        return (min(max(col, 0), max(cols - 1, 0)), min(max(row, 0), max(rows - 1, 0)))
    }

    /// The row in the whole scrollable area (scrollback included, 0 is the oldest) that viewport
    /// row `row` shows now.
    func scrollbackRow(ofViewportRow row: Int) -> Int { core.scroll.snapshot.offset + row }

    /// Where cells `columns` of viewport row `row` are drawn, in this view's coordinates.
    func viewportRect(row: Int, columns: Range<Int>) -> CGRect {
        let s = core.scroll.snapshot, m = atlas.metrics
        let top = CGFloat(row * m.cellHeight - s.fraction - s.bounce) / displayScale
        return CGRect(x: CGFloat(columns.lowerBound * m.cellWidth) / displayScale, y: top,
                      width: CGFloat(columns.count * m.cellWidth) / displayScale, height: CGFloat(m.cellHeight) / displayScale)
    }

    /// Scrolls by `lines` rows (negative is up) on the next frame.
    func scrollLines(_ lines: Int) {
        if lines != 0 { scroller.jump(.lines(lines)) }
    }

    /// For a selection drag: scrolls one line when `p` is within half a cell of the top or
    /// bottom edge and there is somewhere to go. Returns the lines asked for (-1, 0 or 1). The
    /// viewport moves with the next frame, so convert the point again after it.
    @discardableResult
    func autoscrollSelection(at p: CGPoint) -> Int {
        let s = core.scroll.snapshot
        let edge = cellSize.height * 0.5
        var lines = 0
        if p.y < edge, s.offset > 0 {
            lines = -1
        } else if p.y > bounds.height - edge, !s.active {
            lines = 1
        }
        scrollLines(lines)
        return lines
    }
}
