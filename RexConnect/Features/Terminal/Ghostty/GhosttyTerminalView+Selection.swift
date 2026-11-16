import UIKit

// PHASE 2 (selection): no-op stubs. Chunk 2c replaces this file: long press word, drag, copy,
// edit menu. The renderer already draws whatever selection the terminal holds
// (GHOSTTY_TERMINAL_OPT_SELECTION) with the theme's selection color; use `core.withTerminal`
// to set it, then `core.onDirty?()` to draw.
//
// TerminalHost owns the gestures, the clipboard, the shimmer and the edit menu, and drives these
// members (see `TerminalEngineView`); `RexTerminalView` in Engine/SwiftTermEngine.swift is the
// reference for what each one does.
extension GhosttyTerminalView {
    // PHASE 2: true while the terminal holds a selection.
    var hasActiveSelection: Bool { false }
    // PHASE 2: a UILongPressGestureRecognizer on this view; the host adds its own target to it.
    var selectionPressRecognizer: UILongPressGestureRecognizer? { nil }
    // PHASE 2: this view has no selection pan of its own; keep false unless one is added.
    func isBuiltInSelectionPan(_ pan: UIPanGestureRecognizer) -> Bool { false }
    // PHASE 2: anchor at the cell under `p`; with `word`, `ghostty_terminal_select_word`, else clear.
    func beginSelection(at p: CGPoint, word: Bool) {}
    // PHASE 2: select anchor...cell under `p` (both included); with `autoscroll`, scroll a line at the edges.
    func extendSelection(to p: CGPoint, autoscroll: Bool) {}
    // PHASE 2: forget the anchor; the selection stays.
    func endSelectionDrag() {}
    // PHASE 2: clear GHOSTTY_TERMINAL_OPT_SELECTION.
    func clearSelectedRange() {}
    // PHASE 2: the formatter's plain text for the selection.
    var selectedText: String? { nil }
    // PHASE 2: one rect per selected line, in this view's coordinates, for the shimmer and the menu.
    var selectionRects: [CGRect] { [] }
    // PHASE 2: select the whole screen and scrollback.
    func selectAllText() {}
}
