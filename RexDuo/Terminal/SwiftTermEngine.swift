import UIKit
import SwiftTerm

extension SwiftTerm.TerminalView: TerminalKeyTarget {}

/// The SwiftTerm engine: SwiftTerm's view behind `TerminalEngineView`.
///
/// SwiftTerm already routes a one-finger vertical drag: local scrollback on the main screen,
/// wheel reports to a mouse-tracking program, arrow keys on an alternate screen without mouse
/// tracking (Alternate Scroll Mode). The gates only keep horizontal flicks and the mirror-mode
/// canvas pan out of its way.
final class RexTerminalView: SwiftTerm.TerminalView, TerminalEngineView, TerminalViewDelegate {
    static let scrollbackLines = 10_000

    /// Asked before any of this view's pans begins (scroll, wheel/arrow drag, selection).
    var panGate: ((UIPanGestureRecognizer) -> Bool)?
    /// Asked before SwiftTerm's own single tap fires.
    var tapGate: (() -> Bool)?
    weak var engineDelegate: (any TerminalEngineDelegate)? {
        didSet { if grid.cols > 0 { engineDelegate?.engineGridChanged(cols: grid.cols, rows: grid.rows) } }
    }

    /// The grid SwiftTerm has now; reported by `sizeChanged`.
    private var grid: (cols: Int, rows: Int) = (0, 0)
    private var fontSize: CGFloat = 0
    private var selectAnchor: Position?

    convenience init(fontSize: CGFloat, theme: TermTheme) {
        let f = RexFont.all(fontSize)
        self.init(frame: CGRect(x: 0, y: 0, width: 320, height: 240), font: f.0)
        self.fontSize = fontSize
        terminalDelegate = self
        setFonts(normal: f.0, bold: f.1, italic: f.2, boldItalic: f.3)
        changeScrollback(Self.scrollbackLines)
        optionAsMetaKey = true
        keyboardAppearance = theme.isDark ? .dark : .light
        // The key bar listens for the engine-neutral names.
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(controlModifierWasReset), name: .terminalViewControlModifierReset, object: self)
        nc.addObserver(self, selector: #selector(metaModifierWasReset), name: .terminalViewMetaModifierReset, object: self)
    }

    @objc private func controlModifierWasReset() {
        NotificationCenter.default.post(name: .terminalEngineControlModifierReset, object: self)
    }

    @objc private func metaModifierWasReset() {
        NotificationCenter.default.post(name: .terminalEngineMetaModifierReset, object: self)
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        // UIKit also asks the touched view about its ancestors' recognizers; gate only our own.
        if g.view === self {
            if let p = g as? UIPanGestureRecognizer, let gate = panGate, !gate(p) { return false }
            if let t = g as? UITapGestureRecognizer, t.numberOfTapsRequired == 1, let gate = tapGate, !gate() { return false }
        }
        return super.gestureRecognizerShouldBegin(g)
    }

    // MARK: TerminalEngineView

    var engineKind: TerminalEngineKind { .swiftTerm }
    var parsesOffMainThread: Bool { false }
    /// `setFonts` resizes to the frame and soft-resets.
    var fontChangeResetsModes: Bool { true }

    func restoreSnapshot(_ bytes: [UInt8], failed: @escaping @MainActor () -> Void) -> Bool { false }

    var cellSize: CGSize {
        let opt = getOptimalFrameSize()
        let (c, r) = grid
        guard c > 0, r > 0, opt.width > 0, opt.height > 0 else {
            let font = RexFont.ui(fontSize)
            return CGSize(width: ("W" as NSString).size(withAttributes: [.font: font]).width, height: ceil(font.lineHeight))
        }
        return CGSize(width: opt.width / CGFloat(c), height: opt.height / CGFloat(r))
    }

    /// Sizes SwiftTerm to a grid without its `resize`, which soft-resets modes the program set.
    func setGrid(cols: Int, rows: Int, force: Bool) {
        guard force || grid != (cols, rows) else { return }
        let cell = cellSize
        var b = bounds
        b.size = CGSize(width: CGFloat(cols) * cell.width + 0.5, height: CGFloat(rows) * cell.height + 0.5)
        bounds = b
        setNeedsLayout()
        layoutIfNeeded()  // SwiftTerm resizes in layoutSubviews; do it now, at this point of the stream
    }

    func setFont(size: CGFloat) {
        fontSize = size
        let f = RexFont.all(size)
        setFonts(normal: f.0, bold: f.1, italic: f.2, boldItalic: f.3)
    }

    func apply(theme t: TermTheme) {
        nativeBackgroundColor = t.uiBG
        nativeForegroundColor = t.uiFG
        caretColor = t.uiCursor
        selectedTextBackgroundColor = t.uiSelection
        keyboardAppearance = t.isDark ? .dark : .light
        // Native scroll indicators that stay visible on both light and dark themes.
        indicatorStyle = t.isDark ? .white : .black
        let colors: [SwiftTerm.Color] = (0..<16).map { i in
            let c = UIColor(hex: t.ansi[safe: i] ?? t.foreground)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return SwiftTerm.Color(red: UInt16(r * 65535), green: UInt16(g * 65535), blue: UInt16(b * 65535))
        }
        installColors(colors)
    }

    /// GPU rendering keeps scrolling and heavy output at the display rate; CoreGraphics is the fallback.
    func enableGPU() { try? setUseMetal(true) }

    // MARK: Selection

    /// SwiftTerm's own long press only shows a menu with "Select", and raises the keyboard.
    /// Match the exact class: UIScrollView's indicator-drag recognizer is a long-press subclass.
    var selectionPressRecognizer: UILongPressGestureRecognizer? {
        gestureRecognizers?.first(where: { type(of: $0) == UILongPressGestureRecognizer.self }) as? UILongPressGestureRecognizer
    }

    func beginSelection(at p: CGPoint) {
        selectAnchor = cell(at: p)
        showStandardContextMenu(at: p)      // focuses and records the press position
        UIMenuController.shared.hideMenu()  // not that menu: the selection's own, with Copy
        select(nil)                         // selects the word there and shows Copy
    }

    func extendSelection(to p: CGPoint) {
        guard let a = selectAnchor else { return }
        let h = cell(at: p)
        if h.row != a.row || h.col != a.col {
            let forward = h.row > a.row || (h.row == a.row && h.col >= a.col)
            setSelectionRange(start: forward ? a : h, end: forward ? h : a)
        }
    }

    func endSelection(at p: CGPoint) {
        if let a = selectAnchor, cell(at: p) != a {
            showStandardContextMenu(at: p)
        }
        selectAnchor = nil
    }

    /// Buffer cell (scrollback included) under a point in this view.
    private func cell(at p: CGPoint) -> Position {
        let c = cellSize
        return Position(col: max(0, min(Int(p.x / c.width), max(grid.cols - 1, 0))), row: max(0, Int(p.y / c.height)))
    }

    // MARK: TerminalViewDelegate

    nonisolated func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        // SwiftTerm calls this synchronously on the main thread from resize/layout.
        MainActor.assumeIsolated {
            self.grid = (newCols, newRows)
            self.engineDelegate?.engineGridChanged(cols: newCols, rows: newRows)
        }
    }

    nonisolated func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

    nonisolated func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        Task { @MainActor in self.engineDelegate?.engineSend(bytes) }
    }

    nonisolated func scrolled(source: SwiftTerm.TerminalView, position: Double) {}

    nonisolated func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

    nonisolated func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) {
            Task { @MainActor in UIPasteboard.general.string = s }
        }
    }

    nonisolated func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) {
        if let u = URL(string: link) {
            Task { @MainActor in UIApplication.shared.open(u) }
        }
    }
}
