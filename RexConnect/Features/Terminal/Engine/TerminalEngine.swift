import UIKit

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

    /// The engine new panes use. Ghostty, unless UserDefaults ("terminalEngine") says otherwise.
    /// Launch argument `-terminalEngine swiftTerm` overrides it for a run.
    static var current: TerminalEngineKind {
        get { TerminalEngineKind(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .ghostty }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: .terminalEngineChanged, object: nil)
        }
    }
    private static let key = "terminalEngine"

    /// The engine a pane made for this kind really runs.
    var implemented: TerminalEngineKind {
        self
    }

    /// Makes the view for a new pane. Read `engineKind` on the result for what it really is.
    @MainActor
    func makeView(fontSize: CGFloat, theme: TermTheme) -> any TerminalEngineView {
        switch implemented {
        case .ghostty:
            let v = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: fontSize)
            v.apply(theme: theme)
            return v
        case .swiftTerm:
            return RexTerminalView(fontSize: fontSize, theme: theme)
        }
    }
}

extension Notification.Name {
    static let terminalEngineChanged = Notification.Name("RexTerminalEngineChanged")
    /// Posted by an engine view (object: the view) after a typed key used up its one-shot ctrl / alt flag.
    static let terminalEngineControlModifierReset = Notification.Name("RexTerminalEngineControlModifierReset")
    static let terminalEngineMetaModifierReset = Notification.Name("RexTerminalEngineMetaModifierReset")
}

/// What the key bar needs from a terminal.
@MainActor
protocol TerminalKeyTarget: AnyObject {
    /// One-shot ctrl / alt for the next key typed on the system keyboard. Cleared after use, with
    /// `.terminalEngineControlModifierReset` / `.terminalEngineMetaModifierReset` posted (object: the view).
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
    /// Held weakly. Setting it reports the current grid once, if the view has one.
    var engineDelegate: (any TerminalEngineDelegate)? { get set }
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
    /// True when a resize reflows lines exactly as the Rex server's terminal does, so a new width
    /// needs no redraw from the server.
    var reflowsLikeServer: Bool { get }
    func feed(byteArray: ArraySlice<UInt8>)
    /// The hot path for live output. The buffer is only valid during the call; an engine that
    /// parses elsewhere copies it once.
    func feed(buffer: UnsafeBufferPointer<UInt8>)
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

    // Selection. The host owns the gestures (long press, pointer drag), the clipboard, the shimmer
    // and the edit menu; the engine owns the selected range. Points are in this view's coordinates
    // (scrollback included, as `location(in:)` reports them).
    var hasActiveSelection: Bool { get }
    /// The press that selects; the host retargets it. Nil if the engine has none.
    var selectionPressRecognizer: UILongPressGestureRecognizer? { get }
    /// True for a pan of the engine's own that would change a selection. The host never lets it begin.
    func isBuiltInSelectionPan(_ pan: UIPanGestureRecognizer) -> Bool
    /// Starts a selection anchored at the cell under `p`. With `word`, selects the word there (or
    /// path, URL, …); otherwise, or when there is no word, clears the selection.
    func beginSelection(at p: CGPoint, word: Bool)
    /// Selects from the anchor to the cell under `p`, both included, in reading order. With
    /// `autoscroll`, first scrolls a line when `p` is at the top or bottom edge.
    func extendSelection(to p: CGPoint, autoscroll: Bool)
    /// The gesture is over: forget the anchor. The selection stays.
    func endSelectionDrag()
    /// Clears the selection, if any.
    func clearSelectedRange()
    /// The selected text, for copy.
    var selectedText: String? { get }
    /// One rectangle per selected line, in this view's coordinates (its layer's), for the
    /// copy-on-select shimmer and the edit menu's target. Empty unless the selection was made
    /// through `beginSelection` / `extendSelection`.
    var selectionRects: [CGRect] { get }
    func selectAllText()

    // Selection UI: handles, double and triple tap, the cursor's Paste menu (docs/selection.md).
    // Every member has a default in Selection/SelectionSeam.swift; an engine that implements
    // none of them keeps the long press, the loupe and the haptics.
    /// True when the host draws selection handles and handles double taps, triple taps and the
    /// tap near the cursor for this engine. False when the engine's view does that itself.
    var usesHostSelectionUI: Bool { get }
    /// Where the selection's first and last cells are drawn, or nil without a selection.
    var selectionEnds: TerminalSelectionEnds? { get }
    /// Changes whenever `selectionEnds` may have moved without a selection call (scrolling,
    /// output). Cheap: asked on every display frame while handles show.
    var selectionGeometryStamp: Int { get }
    /// Starts a drag that moves one end of the selection while the other stays; continue with
    /// `extendSelection` and finish with `endSelectionDrag`. False without a selection.
    func beginSelectionAdjust(movingStart: Bool) -> Bool
    /// Selects the line under `p` (a triple tap). False if there is nothing on it.
    func selectLine(at p: CGPoint) -> Bool
    /// The cell under `p`, with rows counted from the top of the scrollback, so a row keeps its
    /// number while the view scrolls. Nil if the engine can't say.
    func gridCell(at p: CGPoint) -> TerminalGridCell?
    /// The cursor's cell, in `gridCell(at:)`'s space.
    var cursorGridCell: TerminalGridCell? { get }
    /// The program tracks the mouse: a tap is a click for it.
    var sendsTapsToProgram: Bool { get }
    /// A single tap at `p`, asked before the host does anything else with it. True if the engine
    /// used it up: it opened the link under it or moved the shell's cursor on its prompt.
    /// `focused`: the view had the keyboard when the tap came. Default (Ghostty/GhosttyTap.swift): false.
    func tapOpensLinkOrMovesCursor(at p: CGPoint, focused: Bool, shift: Bool) -> Bool

    // Scrolling
    /// The engine's own one-finger scroll pan, if it has one; the host limits it to direct touches.
    var scrollPanRecognizer: UIPanGestureRecognizer? { get }
    /// Scrolls the scrollback a page.
    func scrollPage(up: Bool)
    /// Scrolls to the next or previous shell prompt (OSC 133 marks), if there is one.
    func scrollToPrompt(next: Bool)

    // Input
    /// Sees each hardware key press before the engine does; true consumes it (a key binding ran).
    var keyHook: ((UIKey) -> Bool)? { get set }
    func send(txt: String)
    func pasteText(_ s: String)
}
