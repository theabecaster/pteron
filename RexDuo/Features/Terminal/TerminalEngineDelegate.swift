import Foundation

/// What the terminal view (`GhosttyTerminalView`) tells whoever shows it: `TerminalHost` in the
/// app, a spy in the engine's tests.
@MainActor
protocol TerminalEngineDelegate: AnyObject {
    /// The local grid changed: synchronously from `setGrid`, or after a snapshot was restored.
    func engineGridChanged(cols: Int, rows: Int)
    /// Bytes for the program that the user typed: keys and pastes.
    func engineSend(_ bytes: [UInt8])
    /// Bytes for the program that describe a place or a state of the screen: mouse and wheel
    /// reports, a focus report, the keys of a tap or a drag. They are right only for the screen
    /// they were made on (`TerminalStream.send(report:)`).
    func engineSendReport(_ bytes: [UInt8])
}

extension TerminalEngineDelegate {
    func engineSendReport(_ bytes: [UInt8]) { engineSend(bytes) }
}

extension Notification.Name {
    /// Posted by the terminal view (object: the view) after a typed key used up its one-shot ctrl / alt flag.
    static let terminalEngineControlModifierReset = Notification.Name("RexTerminalEngineControlModifierReset")
    static let terminalEngineMetaModifierReset = Notification.Name("RexTerminalEngineMetaModifierReset")
}
