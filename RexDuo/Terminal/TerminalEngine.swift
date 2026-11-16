import UIKit
import SwiftTerm

/// Which library parses and draws terminal output.
enum TerminalEngineKind: String, CaseIterable, Identifiable {
    case ghostty, swiftTerm
    var id: String { rawValue }
    var title: String { self == .ghostty ? "Ghostty" : "SwiftTerm" }
    var detail: String {
        self == .ghostty
            ? "libghostty-vt with a Metal renderer. Restores Rex's Ghostty snapshot directly and parses off the main thread."
            : "SwiftTerm with its Metal renderer. Seeds the screen from terminal.format."
    }

    /// The engine new panes use. Stored in UserDefaults ("terminalEngine"); Ghostty by default on this branch.
    /// Launch argument `-terminalEngine swiftTerm` overrides it for a run.
    static var current: TerminalEngineKind {
        get { TerminalEngineKind(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .ghostty }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: .terminalEngineChanged, object: nil)
        }
    }
    private static let key = "terminalEngine"
}

extension Notification.Name {
    static let terminalEngineChanged = Notification.Name("RexTerminalEngineChanged")
}

/// What the key bar needs from a terminal. SwiftTerm's view already has all of it.
@MainActor
protocol TerminalKeyTarget: AnyObject {
    /// One-shot ctrl / alt for the next key typed on the system keyboard. Cleared after use, with
    /// `.terminalViewControlModifierReset` / `.terminalViewMetaModifierReset` posted (object: the view).
    var controlModifier: Bool { get set }
    var metaModifier: Bool { get set }
    func sendKeyUp()
    func sendKeyDown()
    func sendKeyLeft()
    func sendKeyRight()
    func sendKeyHome()
    func sendKeyEnd()
    func send(data: ArraySlice<UInt8>)
}

extension SwiftTerm.TerminalView: TerminalKeyTarget {}

/// The host's side of an engine: output the engine produces.
@MainActor
protocol TerminalEngineDelegate: AnyObject {
    /// The local grid changed (synchronously, from `setGrid`).
    func engineGridChanged(cols: Int, rows: Int)
    /// Bytes for the program: typed keys, mouse reports, pastes.
    func engineSend(_ bytes: [UInt8])
}

/// The seam between TerminalHost and the library that draws the terminal.
/// The view itself is the engine: TerminalHost lays it out, zooms it and makes it first responder.
@MainActor
protocol TerminalEngineView: UIView, TerminalKeyTarget {
    var engineKind: TerminalEngineKind { get }
    /// Asked before any of this view's pans begins (scroll, wheel/arrow drag, selection).
    var panGate: ((UIPanGestureRecognizer) -> Bool)? { get set }
    /// Asked before the view's own single tap (focus / mouse click) fires.
    var tapGate: (() -> Bool)? { get set }
    var inputView: UIView? { get set }
    var inputAccessoryView: UIView? { get set }
    var keyboardAppearance: UIKeyboardAppearance { get set }

    // Output
    /// True when `feed` hands bytes to another thread: no main-thread pacing needed.
    var parsesOffMainThread: Bool { get }
    /// True when changing the font loses terminal modes, so the host should redraw from the server.
    var fontChangeResetsModes: Bool { get }
    func feed(byteArray: ArraySlice<UInt8>)
    func feed(text: String)
    /// Restores a `GHOSTSNP` snapshot. Returns false if this engine can't; `failed` runs on the
    /// main thread if decoding fails later.
    func restoreSnapshot(_ bytes: [UInt8], failed: @escaping @MainActor () -> Void) -> Bool

    // Geometry
    /// One cell in points at the current font.
    var cellSize: CGSize { get }
    /// Sizes the local grid. Never soft-resets modes the program set. Reports through the delegate.
    func setGrid(cols: Int, rows: Int, force: Bool)
    func setFont(size: CGFloat)
    func apply(theme: TermTheme)
    /// Turns on GPU rendering where it's optional (once the view is in a window).
    func enableGPU()

    // Selection (long press)
    var hasActiveSelection: Bool { get }
    /// The press that selects; the host retargets it. Nil if the engine has none.
    var selectionPressRecognizer: UILongPressGestureRecognizer? { get }
    func beginSelection(at p: CGPoint)
    func extendSelection(to p: CGPoint)
    func endSelection(at p: CGPoint)

    // Input
    func send(txt: String)
    func pasteText(_ s: String)
}
