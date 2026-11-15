import UIKit
import SwiftTerm

/// A UIKit view that shows one Rex terminal block with SwiftTerm.
/// Fit mode: claims the block and resizes it to this view. Mirror mode: keeps the server's size, zoom/pan.
@MainActor
final class TerminalHost: UIView, TerminalSink, TerminalViewDelegate, UIScrollViewDelegate {
    let stream: TerminalStream
    let term: SwiftTerm.TerminalView
    private let zoomer = UIScrollView()
    private let statusLabel = UILabel()
    private let keyBar: KeyBar

    var sizing: SizingMode
    var fontSize: CGFloat
    var theme: TermTheme
    var isActive = false
    var onFocus: (() -> Void)?
    var onTitle: ((String) -> Void)?

    private var claimedSize: (Int, Int)?
    private var claimTask: Task<Void, Never>?
    private var started = false
    private var lastBounds: CGSize = .zero
    private var serverSize: (Int, Int) = (80, 24)
    private var typedTest = false
    private var lostOwnership = false

    init(stream: TerminalStream, sizing: SizingMode, fontSize: CGFloat, theme: TermTheme) {
        self.stream = stream
        self.sizing = sizing
        self.fontSize = fontSize
        self.theme = theme
        let f = RexFont.all(fontSize)
        term = SwiftTerm.TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), font: f.0)
        keyBar = KeyBar()
        super.init(frame: .zero)
        term.setFonts(normal: f.0, bold: f.1, italic: f.2, boldItalic: f.3)
        term.terminalDelegate = self
        term.optionAsMetaKey = true
        term.keyboardAppearance = theme.isDark ? .dark : .light
        keyBar.terminal = term
        keyBar.onPaste = { [weak self] in
            if let s = UIPasteboard.general.string { self?.paste(s) }
        }
        keyBar.onHideKeyboard = { [weak self] in _ = self?.term.resignFirstResponder() }
        term.inputAccessoryView = keyBar

        zoomer.delegate = self
        zoomer.showsHorizontalScrollIndicator = false
        zoomer.bouncesZoom = true
        zoomer.contentInsetAdjustmentBehavior = .never
        addSubview(zoomer)
        zoomer.addSubview(term)

        statusLabel.font = RexFont.ui(11)
        statusLabel.textAlignment = .center
        statusLabel.layer.cornerRadius = 8
        statusLabel.layer.masksToBounds = true
        statusLabel.isHidden = true
        statusLabel.isUserInteractionEnabled = true
        statusLabel.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(statusTapped)))
        addSubview(statusLabel)

        clipsToBounds = true
        applyTheme(theme)
        stream.sink = self

        NotificationCenter.default.addObserver(self, selector: #selector(didBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped() { onFocus?() }

    /// Hand fitted panes back to the Mac while the app is in the background.
    @objc private func didBackground() {
        guard claimedSize != nil else { return }
        claimTask?.cancel()
        claimedSize = nil
        let s = stream
        Task { await s.release() }
    }

    @objc private func willForeground() {
        guard window != nil, sizing == .fit, !lostOwnership else { return }
        lastBounds = .zero
        setNeedsLayout()
    }

    /// Tapping the "another device has this pane" chip takes the pane back.
    @objc private func statusTapped() {
        guard sizing == .fit, lostOwnership else { return }
        lostOwnership = false
        hideStatus()
        claimedSize = nil
        lastBounds = .zero
        setNeedsLayout()
    }

    func focusKeyboard() { _ = term.becomeFirstResponder() }

    func applyTheme(_ t: TermTheme) {
        theme = t
        backgroundColor = t.uiBG
        zoomer.backgroundColor = t.uiBG
        term.nativeBackgroundColor = t.uiBG
        term.nativeForegroundColor = t.uiFG
        term.caretColor = t.uiCursor
        term.selectedTextBackgroundColor = t.uiSelection
        term.keyboardAppearance = t.isDark ? .dark : .light
        let colors: [SwiftTerm.Color] = (0..<16).map { i in
            let c = UIColor(hex: t.ansi[safe: i] ?? t.foreground)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            c.getRed(&r, green: &g, blue: &b, alpha: &a)
            return SwiftTerm.Color(red: UInt16(r * 65535), green: UInt16(g * 65535), blue: UInt16(b * 65535))
        }
        term.installColors(colors)
        statusLabel.backgroundColor = t.uiFG.withAlphaComponent(0.15)
        statusLabel.textColor = t.uiFG
        keyBar.apply(theme: t)
    }

    func setFontSize(_ s: CGFloat) {
        guard abs(s - fontSize) > 0.01 else { return }
        fontSize = s
        let f = RexFont.all(s)
        term.setFonts(normal: f.0, bold: f.1, italic: f.2, boldItalic: f.3)
        lastBounds = .zero
        setNeedsLayout()
    }

    func setSizing(_ m: SizingMode) {
        guard m != sizing else { return }
        sizing = m
        if m == .mirror {
            claimTask?.cancel()
            claimedSize = nil
            Task { await stream.release() }
        }
        lastBounds = .zero
        setNeedsLayout()
    }

    // MARK: Lifecycle

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            stop()
        }
    }

    func stop() {
        claimTask?.cancel()
        stream.stop()
        if claimedSize != nil {
            claimedSize = nil
            let s = stream
            Task { await s.release() }
        }
        started = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        zoomer.frame = bounds
        let w = min(bounds.width - 24, 280)
        statusLabel.frame = CGRect(x: (bounds.width - w) / 2, y: 10, width: w, height: 26)
        guard bounds.width > 20, bounds.height > 20 else { return }
        guard bounds.size != lastBounds else { return }
        lastBounds = bounds.size
        layoutTerminal()
    }

    private func layoutTerminal() {
        switch sizing {
        case .fit:
            let (c, r) = fitGrid()
            if let cl = claimedSize, cl == (c, r), started { return }
            requestClaim(cols: c, rows: r)
        case .mirror:
            layoutGrid(serverSize.0, serverSize.1)
            if !started { started = true; stream.start() }
        }
    }

    /// Largest grid that fits the view at the chosen font; sets the terminal to it.
    private func fitGrid() -> (Int, Int) {
        let font = RexFont.ui(fontSize)
        let cellW = ("W" as NSString).size(withAttributes: [.font: font]).width
        var c = max(Int(floor(bounds.width / max(cellW, 1))) + 1, 12)
        var r = max(Int(floor(bounds.height / max(ceil(font.lineHeight), 1))) + 1, 4)
        term.resize(cols: c, rows: r)
        var opt = term.getOptimalFrameSize()
        while opt.width > bounds.width, c > 12 { c -= 1; term.resize(cols: c, rows: r); opt = term.getOptimalFrameSize() }
        while opt.height > bounds.height, r > 4 { r -= 1; term.resize(cols: c, rows: r); opt = term.getOptimalFrameSize() }
        zoomer.minimumZoomScale = 1
        zoomer.maximumZoomScale = 1
        zoomer.zoomScale = 1
        term.frame = CGRect(x: 0, y: 0, width: ceil(opt.width) + 0.5, height: ceil(opt.height) + 0.5)
        zoomer.contentSize = bounds.size
        return (c, r)
    }

    /// Shows a fixed server grid, zoomed to fit the width; pinch and pan to read.
    private func layoutGrid(_ cols: Int, _ rows: Int) {
        term.resize(cols: cols, rows: rows)
        let opt = term.getOptimalFrameSize()
        let size = CGSize(width: ceil(opt.width) + 0.5, height: ceil(opt.height) + 0.5)
        zoomer.zoomScale = 1
        term.frame = CGRect(origin: .zero, size: size)
        zoomer.contentSize = size
        let fitW = bounds.width / size.width
        let fitH = bounds.height / size.height
        zoomer.minimumZoomScale = min(fitW, fitH, 1)
        zoomer.maximumZoomScale = max(2, fitW)
        zoomer.zoomScale = min(fitW, 1)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { term }

    private func requestClaim(cols: Int, rows: Int) {
        if let c = claimedSize, c == (cols, rows), started { return }
        claimTask?.cancel()
        claimTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)  // settle (fold/rotate animations)
            guard let self, !Task.isCancelled else { return }
            await self.stream.claimAndResize(cols: cols, rows: rows)
            guard !Task.isCancelled else { return }
            self.claimedSize = (cols, rows)
            if self.started { self.stream.restart() } else { self.started = true; self.stream.start() }
        }
    }

    // MARK: TerminalSink

    func streamReset(cols: Int, rows: Int) {
        serverSize = (cols, rows)
        // RIS + clear scrollback, then match the server's grid.
        term.feed(text: "\u{1b}c\u{1b}[3J")
        applyServerGrid(cols, rows)
    }

    func streamFeed(_ bytes: [UInt8]) {
        term.feed(byteArray: bytes[...])
    }

    func streamResized(cols: Int, rows: Int, owner: String?) {
        let changed = serverSize != (cols, rows)
        serverSize = (cols, rows)
        guard changed else { return }
        applyServerGrid(cols, rows)
        if sizing == .fit, let c = claimedSize, c != (cols, rows), owner != stream.control.clientID {
            // Another client (the Mac, or another phone) resized it. Don't fight over it; offer to take it back.
            claimedSize = nil
            lostOwnership = true
            showStatus("Resized elsewhere · tap to fit here")
        }
    }

    private func applyServerGrid(_ cols: Int, _ rows: Int) {
        if sizing == .fit, let c = claimedSize, c == (cols, rows) {
            if term.getOptimalFrameSize().width < 1 { _ = fitGrid() }
            return
        }
        layoutGrid(cols, rows)
    }

    func streamTheme(_ theme: JSONObject) {}

    func streamExited(code: Int?) {
        showStatus("Program exited\(code.map { " (\($0))" } ?? "")")
    }

    func streamStatus(_ status: TerminalStream.Status) {
        switch status {
        case .live:
            if !lostOwnership { hideStatus() }
            if isActive, let t = UserDefaults.standard.string(forKey: "typeTest"), !typedTest {
                typedTest = true
                term.send(txt: t.replacingOccurrences(of: "\\n", with: "\r"))
            }
        case .connecting: showStatus("Connecting…")
        case .reconnecting: showStatus("Reconnecting…")
        case .ended(let m): showStatus(m)
        case .failed(let m): showStatus(m)
        }
    }

    private func showStatus(_ s: String) {
        statusLabel.text = "  \(s)  "
        statusLabel.isHidden = false
    }

    private func hideStatus() { statusLabel.isHidden = true }

    // MARK: TerminalViewDelegate

    nonisolated func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}

    nonisolated func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        Task { @MainActor in
            self.stream.send(bytes)
            self.keyBar.consumedModifiers()
        }
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

    func paste(_ s: String) {
        // Goes through SwiftTerm so it's bracketed when the program asked for bracketed paste.
        term.pasteText(s)
    }

    func sendKey(_ bytes: [UInt8]) { stream.send(bytes) }
}
