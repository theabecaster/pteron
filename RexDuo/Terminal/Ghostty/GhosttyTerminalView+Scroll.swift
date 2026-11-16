import UIKit

// PHASE 2 (scroll + mouse): nothing yet. Chunk 2b fills this file: native scrolling, scrollbar,
// wheel and arrow drags, tap click. Hooks that already exist:
// - `core.scrollbar` / `core.viewportActive`: read in the same critical section as each frame's
//   render state update (take `core.stateLock`, or read them from `core.frameSync`).
// - `core.withTerminal { ghostty_terminal_scroll_viewport($0, ...) }`, then `core.onDirty?()`.
// - `renderer.setScrollOffset(_:)`: shifts the grid up by a fraction of a row, in pixels. Pair
//   it with GHOSTTY_RENDER_STATE_OPT_OVERSCAN (below = 1) on `core.renderState`.
// - `metalView` hosts the CAMetalLayer, so a UIScrollView can sit beside or above it.
extension GhosttyTerminalView {}
