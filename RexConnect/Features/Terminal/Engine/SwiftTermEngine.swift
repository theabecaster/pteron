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
    /// Sees each hardware key press before SwiftTerm does; true consumes it (a key binding ran).
    var keyHook: ((UIKey) -> Bool)?
    weak var engineDelegate: (any TerminalEngineDelegate)? {
        didSet { if grid.cols > 0 { engineDelegate?.engineGridChanged(cols: grid.cols, rows: grid.rows) } }
    }

    /// The grid SwiftTerm has now; reported by `sizeChanged`.
    private var grid: (cols: Int, rows: Int) = (0, 0)
    private var fontSize: CGFloat = 0
    private var selectAnchor: Position?
    /// The far end of a drag selection (nil: a long press that selected one word).
    private var selectHead: Position?
    /// What is selected now, when Rex Connect selected it (SwiftTerm keeps its own bounds private).
    private var selection: SelRange?

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

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard let hook = keyHook else { return super.pressesBegan(presses, with: event) }
        let rest = presses.filter { p in p.key.map { !hook($0) } ?? true }
        // SwiftTerm's pressesEnded isn't overridable; it ignores releases of keys it never saw.
        if !rest.isEmpty { super.pressesBegan(rest, with: event) }
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

    func feed(buffer: UnsafeBufferPointer<UInt8>) { feed(byteArray: ArraySlice(buffer)) }

    /// PERF (PerfProbe): SwiftTerm's own counters. `frames` are frames prepared, `renders` frames drawn
    /// (handed to the GPU with Metal).
    var perfCounters: (frames: Int, renders: Int) {
        let d = diagnostics
        return (d.frames, d.renders)
    }

    /// GPU rendering keeps scrolling and heavy output at the display rate; CoreGraphics is the fallback.
    func enableGPU() { try? setUseMetal(true) }

    // MARK: Selection

    /// SwiftTerm's own long press (a menu with "Select"), for the host to retarget.
    /// Match the exact class: UIScrollView's indicator-drag recognizer is a long-press subclass.
    var selectionPressRecognizer: UILongPressGestureRecognizer? {
        gestureRecognizers?.first(where: { type(of: $0) == UILongPressGestureRecognizer.self }) as? UILongPressGestureRecognizer
    }

    /// SwiftTerm's own selection pan, which it adds while a selection exists. It would turn the next
    /// scroll into a selection change (or arrow keys).
    func isBuiltInSelectionPan(_ pan: UIPanGestureRecognizer) -> Bool {
        pan.view === self && pan !== panGestureRecognizer && !pan.allowedTouchTypes.isEmpty && pan.maximumNumberOfTouches > 1
    }

    func beginSelection(at p: CGPoint, word: Bool) {
        let a = cell(at: p)
        selectAnchor = a
        selectHead = nil
        if word, let w = wordRange(at: a) {
            setSelection(w)
        } else {
            clearSelectedRange()
        }
    }

    func extendSelection(to p: CGPoint, autoscroll: Bool) {
        guard let a = selectAnchor else { return }
        var p = p
        // Scrolling moves the content under the finger: the point moves with the offset.
        if autoscroll { p.y += self.autoscroll(p) }
        let h = cell(at: p)
        if h == a, selectHead == nil { return }
        selectHead = h
        let forward = h.row > a.row || (h.row == a.row && h.col >= a.col)
        let (s, e) = forward ? (a, h) : (h, a)
        setSelection(SelRange(start: s, end: Position(col: e.col + 1, row: e.row)))
    }

    func endSelectionDrag() {
        selectAnchor = nil
        selectHead = nil
    }

    func clearSelectedRange() {
        selection = nil
        if hasActiveSelection { clearSelection() }
    }

    var selectedText: String? { getSelection() }

    func selectAllText() { selectAll(nil) }

    /// A selection: `start` included, `end` excluded (SwiftTerm draws and copies it that way).
    private struct SelRange {
        var start: Position
        var end: Position
    }

    private func setSelection(_ r: SelRange) {
        selection = r
        // SwiftTerm counts the end as excluded, except that an end in the last column takes it in.
        let last = max(grid.cols - 1, 0)
        let end = r.end.col > last ? Position(col: last, row: r.end.row) : r.end
        setSelectionRange(start: r.start, end: end)
    }

    /// Scrolls a line when a selection drag reaches the top or bottom edge. Returns how far.
    private func autoscroll(_ p: CGPoint) -> CGFloat {
        let ch = cellSize.height
        var off = contentOffset
        let maxY = max(0, contentSize.height - bounds.height)
        if p.y < off.y + ch * 0.5 {
            off.y = max(0, off.y - ch)
        } else if p.y > off.y + bounds.height - ch * 0.5 {
            off.y = min(maxY, off.y + ch)
        } else {
            return 0
        }
        let dy = off.y - contentOffset.y
        if off != contentOffset { contentOffset = off }
        return dy
    }

    /// The word (or path, URL, …: anything between spaces and brackets) on the cell at `p`.
    private func wordRange(at p: Position) -> SelRange? {
        let cols = max(grid.cols, 1)
        // SwiftTerm doesn't expose the buffer; read the line through a selection of it.
        setSelectionRange(start: Position(col: 0, row: p.row), end: Position(col: cols - 1, row: p.row))
        let line = Array(getSelection() ?? "")
        clearSelection()
        let breaks = Set(" \t\"'`()[]{}<>|;,│")
        guard p.col < line.count, !breaks.contains(line[p.col]) else { return nil }
        var s = p.col, e = p.col + 1
        while s > 0, !breaks.contains(line[s - 1]) { s -= 1 }
        while e < line.count, !breaks.contains(line[e]) { e += 1 }
        // Trailing punctuation reads as sentence, not word.
        while e - 1 > s, ".:!?".contains(line[e - 1]) { e -= 1 }
        return SelRange(start: Position(col: s, row: p.row), end: Position(col: e, row: p.row))
    }

    var selectionRects: [CGRect] {
        guard let r = selection else { return [] }
        let c = cellSize
        let cols = max(grid.cols, 1)
        let s = r.start, e = r.end
        func rect(_ row: Int, _ from: Int, _ to: Int) -> CGRect {
            CGRect(x: CGFloat(from) * c.width, y: CGFloat(row) * c.height, width: CGFloat(to - from) * c.width, height: c.height)
        }
        let endCol = min(e.col, cols)
        if s.row == e.row { return [rect(s.row, s.col, endCol)] }
        var out = [rect(s.row, s.col, cols)]
        if e.row - s.row > 1 {
            out.append(CGRect(x: 0, y: CGFloat(s.row + 1) * c.height, width: CGFloat(cols) * c.width,
                              height: CGFloat(e.row - s.row - 1) * c.height))
        }
        if endCol > 0 { out.append(rect(e.row, 0, endCol)) }
        return out
    }

    // MARK: Scrolling

    var scrollPanRecognizer: UIPanGestureRecognizer? { panGestureRecognizer }

    func scrollPage(up: Bool) { if up { pageUp() } else { pageDown() } }

    func scrollToPrompt(next: Bool) {
        if let r = next ? nextSemanticPromptRow() : previousSemanticPromptRow() { scrollTo(row: r) }
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
