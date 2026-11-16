import UIKit

// PHASE 2 (selection): no-op stubs. Chunk 2c replaces this file: long press word, drag, copy,
// edit menu. The renderer already draws whatever selection the terminal holds
// (GHOSTTY_TERMINAL_OPT_SELECTION) with the theme's selection color; use `core.withTerminal`
// to set it, then `core.onDirty?()` to draw.
extension GhosttyTerminalView {
    var hasActiveSelection: Bool { false }
    var selectionPressRecognizer: UILongPressGestureRecognizer? { nil }
    func beginSelection(at p: CGPoint) {}
    func extendSelection(to p: CGPoint) {}
    func endSelection(at p: CGPoint) {}
}
