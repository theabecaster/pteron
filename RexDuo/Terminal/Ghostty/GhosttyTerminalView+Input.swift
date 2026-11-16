import UIKit

// PHASE 2 (input): no-op stubs. Chunk 2a replaces this file: UIKeyInput, hardware keys through
// the key encoder, key bar modifiers, paste, marked text. Stored state for it lives in the
// "PHASE 2 (input)" block of GhosttyTerminalView.swift. Call `renderer.setFocused(_:)` from
// become/resignFirstResponder to switch between the solid and the hollow cursor.
extension GhosttyTerminalView {
    func sendKeyUp() {}
    func sendKeyDown() {}
    func sendKeyLeft() {}
    func sendKeyRight() {}
    func sendKeyHome() {}
    func sendKeyEnd() {}
    func send(data: ArraySlice<UInt8>) { engineDelegate?.engineSend(Array(data)) }
    func send(txt: String) { engineDelegate?.engineSend(Array(txt.utf8)) }
    func pasteText(_ s: String) {}
}
