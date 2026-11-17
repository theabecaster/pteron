import Foundation

/// What the terminal view (`GhosttyTerminalView`) tells whoever shows it: `TerminalHost` in the
/// app, a spy in the engine's tests.
@MainActor
protocol TerminalEngineDelegate: AnyObject {
    /// The local grid changed: synchronously from `setGrid`, or after a snapshot was restored.
    func engineGridChanged(cols: Int, rows: Int)
    /// Bytes for the program: typed keys, mouse reports, pastes.
    func engineSend(_ bytes: [UInt8])
}

extension Notification.Name {
    /// Posted by the terminal view (object: the view) after a typed key used up its one-shot ctrl / alt flag.
    static let terminalEngineControlModifierReset = Notification.Name("RexTerminalEngineControlModifierReset")
    static let terminalEngineMetaModifierReset = Notification.Name("RexTerminalEngineMetaModifierReset")
}
