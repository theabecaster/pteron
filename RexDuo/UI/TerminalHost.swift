import UIKit
import SwiftTerm

/// SwiftTerm's view with hooks that let TerminalHost arbitrate gestures.
///
/// SwiftTerm already routes a one-finger vertical drag: local scrollback on the main screen,
/// wheel reports to a mouse-tracking program, arrow keys on an alternate screen without mouse
/// tracking (Alternate Scroll Mode). The hooks only keep horizontal flicks and the mirror-mode
/// canvas pan out of its way.
final class RexTerminalView: SwiftTerm.TerminalView {
    /// Asked before any of this view's pans begins (scroll, wheel/arrow drag, selection).
    var panGate: ((UIPanGestureRecognizer) -> Bool)?
    /// Asked before SwiftTerm's own single tap fires.
    var tapGate: (() -> Bool)?

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        // UIKit also asks the touched view about its ancestors' recognizers; gate only our own.
        if g.view === self {
            if let p = g as? UIPanGestureRecognizer, let gate = panGate, !gate(p) { return false }
            if let t = g as? UITapGestureRecognizer, t.numberOfTapsRequired == 1, let gate = tapGate, !gate() { return false }
        }
        return super.gestureRecognizerShouldBegin(g)
    }
}

/// The scroll view that zooms and pans the terminal in mirror mode.
final class ZoomScrollView: UIScrollView {
    var panGate: ((UIPanGestureRecognizer) -> Bool)?

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === panGestureRecognizer, let gate = panGate, !gate(panGestureRecognizer) { return false }
        return super.gestureRecognizerShouldBegin(g)
    }
}

/// A UIKit view that shows one Rex terminal block with SwiftTerm.
/// Fit mode: claims the block and resizes it to this view. Mirror mode: keeps the server's size, zoom/pan.
///
/// The local grid always follows the server: it changes only when the stream says the server's
/// size changed, at that point in the stream. Fit mode asks the server for the size that fits and
/// keeps the stream open; the program redraws itself.
@MainActor
final class TerminalHost: UIView, TerminalSink, TerminalViewDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    static let fontRange: ClosedRange<CGFloat> = 7...20

    let stream: TerminalStream
    let term: RexTerminalView
    private let zoomer = ZoomScrollView()
    private let statusLabel = UILabel()
    private let keyBar: KeyBar

    var sizing: SizingMode
    var fontSize: CGFloat
    var theme: TermTheme
    var isActive = false
    var onFocus: (() -> Void)?
    var onTitle: ((String) -> Void)?
    /// Horizontal swipe: +1 = next pane, -1 = previous pane.
    var onSwipe: ((Int) -> Void)?

    private var claimedSize: (Int, Int)?
    private var claimTask: Task<Void, Never>?
    private var resyncTask: Task<Void, Never>?
    private var started = false
    private var lastBounds: CGSize = .zero
    private var serverSize: (Int, Int) = (80, 24)
    /// The grid SwiftTerm has now; reported by `sizeChanged`.
    private var localGrid: (Int, Int) = (0, 0)
    private var typedTest = false
    private var lostOwnership = false
    /// A font change soft-reset SwiftTerm (modes lost); redraw from the server once sized.
    private var needsResync = false

    private var tapGR: UITapGestureRecognizer!
    private var swipeGR: UIPanGestureRecognizer!
    private var pinchGR: UIPinchGestureRecognizer!
    private var pinchBase: CGFloat = 0
    /// Our tap already focused the keyboard; skip SwiftTerm's delayed single tap for the same touch.
    private var swallowSingleTap = false
    /// Long-press focused the terminal for the edit menu without raising the keyboard.
    private var quietInput = false
    private var selectAnchor: Position?

    // Output pacing: heavy output is parsed in slices, a frame's budget at a time.
    static let directFeedLimit = 8 * 1024
    static let feedSlice = 16 * 1024
    static let frameBudget: CFTimeInterval = 0.004
    static let frameBudgetBehind: CFTimeInterval = 0.010
    static let backlogCatchUp = 2 << 20
    private var output: [UInt8] = []
    private var outputLink: CADisplayLink?

    /// Background longer than this re-reads the screen on return.
    static let staleAfterBackground: CFTimeInterval = 30
    private var backgroundedAt: CFTimeInterval?
    private var metalTried = false
    /// Transient states (connecting, reconnecting) show only if they last this long.
    static let statusDelay: TimeInterval = 1.0
    private var statusWork: DispatchWorkItem?
    private static let lostText = "Resized elsewhere · tap to fit here"

    init(stream: TerminalStream, sizing: SizingMode, fontSize: CGFloat, theme: TermTheme) {
        self.stream = stream
        self.sizing = sizing
        self.fontSize = fontSize
        self.theme = theme
        let f = RexFont.all(fontSize)
        term = RexTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), font: f.0)
        keyBar = KeyBar()
        super.init(frame: .zero)
        term.terminalDelegate = self
        term.setFonts(normal: f.0, bold: f.1, italic: f.2, boldItalic: f.3)
        term.changeScrollback(10_000)
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
        zoomer.scrollsToTop = false
        addSubview(zoomer)
        zoomer.addSubview(term)

        statusLabel.font = RexFont.ui(11)
        statusLabel.textAlignment = .center
        statusLabel.layer.cornerRadius = 11
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
        setupGestures()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Gestures

    private var fitted: Bool { sizing == .fit && !lostOwnership }

    private func setupGestures() {
        // Gates, not failure requirements: a pan that waits for another to fail starts late and
        // loses most of the drag. Each pan decides at once whether the motion is its own.
        zoomer.panGate = { [weak self] pan in self?.canvasPanShouldBegin(pan) ?? true }
        term.panGate = { [weak self] pan in self?.termPanShouldBegin(pan) ?? true }
        term.tapGate = { [weak self] in
            guard let self, self.swallowSingleTap else { return true }
            self.swallowSingleTap = false
            return false
        }

        // Long press selects the word under the finger and offers Copy (SwiftTerm's own long press
        // only shows a menu with "Select", and raises the keyboard).
        // Match the exact class: UIScrollView's indicator-drag recognizer is a long-press subclass.
        let lp = term.gestureRecognizers?.first(where: { type(of: $0) == UILongPressGestureRecognizer.self }) as? UILongPressGestureRecognizer
        if let lp {
            lp.removeTarget(nil, action: nil)
            lp.addTarget(self, action: #selector(longPressed(_:)))
            lp.minimumPressDuration = 0.45
        }

        tapGR = UITapGestureRecognizer(target: self, action: #selector(tapped))
        tapGR.cancelsTouchesInView = false
        tapGR.delegate = self
        if let lp { tapGR.require(toFail: lp) }  // releasing a long press is not a tap
        addGestureRecognizer(tapGR)

        swipeGR = UIPanGestureRecognizer(target: self, action: #selector(swiped(_:)))
        swipeGR.maximumNumberOfTouches = 1
        swipeGR.delegate = self
        addGestureRecognizer(swipeGR)

        pinchGR = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinchGR.delegate = self
        addGestureRecognizer(pinchGR)
    }

    /// Mostly-horizontal motion of a pan that is about to begin.
    private func isHorizontal(_ pan: UIPanGestureRecognizer) -> Bool {
        var d = pan.translation(in: self)
        if abs(d.x) + abs(d.y) < 1 { d = pan.velocity(in: self) }
        return abs(d.x) > abs(d.y) * 1.2
    }

    private var canvasOverflowsX: Bool { zoomer.contentSize.width > zoomer.bounds.width + 1 }
    private var canvasOverflowsY: Bool { zoomer.contentSize.height > zoomer.bounds.height + 1 }

    private func canvasPanShouldBegin(_ pan: UIPanGestureRecognizer) -> Bool {
        guard !fitted, !term.hasActiveSelection else { return false }
        return isHorizontal(pan) ? canvasOverflowsX : canvasOverflowsY
    }

    private func termPanShouldBegin(_ pan: UIPanGestureRecognizer) -> Bool {
        // Leave trackpad scrolls, multi-finger drags and selection drags to SwiftTerm.
        if pan.allowedTouchTypes.isEmpty || pan.numberOfTouches > 1 || term.hasActiveSelection { return true }
        let horizontal = isHorizontal(pan)
        // Mirror mode: the zoomed canvas pans first when it has room to in that direction.
        if !fitted, horizontal ? canvasOverflowsX : canvasOverflowsY { return false }
        // A horizontal flick is a pane swipe (or the canvas pan), never a terminal scroll.
        return !horizontal
    }

    private func swipeShouldBegin(_ pan: UIPanGestureRecognizer) -> Bool {
        guard onSwipe != nil, !term.hasActiveSelection, isHorizontal(pan) else { return false }
        if !fitted && canvasOverflowsX { return false }
        // Leave the screen's left edge to the system's swipe back.
        if let w = window {
            let start = pan.location(in: w).x - pan.translation(in: w).x
            if start < 24 { return false }
        }
        return true
    }

    override func gestureRecognizerShouldBegin(_ g: UIGestureRecognizer) -> Bool {
        if g === swipeGR { return swipeShouldBegin(swipeGR) }
        if g === pinchGR { return fitted && !term.hasActiveSelection }
        return true
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // The focus tap observes; it must never cancel SwiftTerm's taps, selection or our swipe.
        g === tapGR || other === tapGR
    }

    /// Tap: focus this pane and raise the keyboard on the first tap.
    @objc private func tapped() {
        onFocus?()
        restoreInputViews()
        if !term.isFirstResponder {
            // SwiftTerm would wait for its double-tap timeout, and with a mouse-tracking program it
            // would send a click instead of focusing. Focus now and skip its tap for this touch.
            swallowSingleTap = true
            _ = term.becomeFirstResponder()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in self?.swallowSingleTap = false }
        }
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        let p = g.location(in: term)
        switch g.state {
        case .began:
            onFocus?()
            if !term.isFirstResponder {
                // The edit menu needs first responder; don't let that raise the keyboard and resize.
                quietInput = true
                term.inputView = UIView(frame: .zero)
                term.inputAccessoryView = nil
            }
            selectAnchor = cell(at: p)
            term.showStandardContextMenu(at: p)  // focuses and records the press position
            UIMenuController.shared.hideMenu()    // not that menu: the selection's own, with Copy
            term.select(nil)                      // selects the word there and shows Copy
        case .changed:
            guard let a = selectAnchor else { return }
            let h = cell(at: p)
            if h.row != a.row || h.col != a.col {
                let forward = h.row > a.row || (h.row == a.row && h.col >= a.col)
                term.setSelectionRange(start: forward ? a : h, end: forward ? h : a)
            }
        case .ended:
            if let a = selectAnchor, cell(at: p) != a {
                term.showStandardContextMenu(at: p)
            }
            selectAnchor = nil
        default:
            selectAnchor = nil
        }
    }

    /// Buffer cell (scrollback included) under a point in the terminal view.
    private func cell(at p: CGPoint) -> Position {
        let c = cellSize()
        return Position(col: max(0, min(Int(p.x / c.width), max(localGrid.0 - 1, 0))), row: max(0, Int(p.y / c.height)))
    }

    private func restoreInputViews() {
        guard quietInput else { return }
        quietInput = false
        term.inputView = nil
        term.inputAccessoryView = keyBar
        if term.isFirstResponder { term.reloadInputViews() }
    }

    @objc private func swiped(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        switch g.state {
        case .changed:
            zoomer.transform = CGAffineTransform(translationX: t.x * 0.3, y: 0)
        case .ended:
            let v = g.velocity(in: self)
            let far = abs(t.x) > 60
            let flick = abs(v.x) > 450 && abs(t.x) > 16 && (v.x < 0) == (t.x < 0)
            springBack()
            if far || flick { onSwipe?(t.x < 0 ? 1 : -1) }
        default:
            springBack()
        }
    }

    private func springBack() {
        guard zoomer.transform != .identity else { return }
        UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            self.zoomer.transform = .identity
        }
    }

    /// Pinch: live preview by scaling, then one font change (and one resize claim) at the end.
    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchBase = fontSize
        case .changed:
            let k = clampFont(pinchBase * g.scale) / fontSize
            let p = g.location(in: self)
            let d = CGPoint(x: p.x - bounds.midX, y: p.y - bounds.midY)
            zoomer.transform = CGAffineTransform(translationX: d.x, y: d.y).scaledBy(x: k, y: k).translatedBy(x: -d.x, y: -d.y)
        case .ended:
            zoomer.transform = .identity
            zoomer.frame = bounds
            let s = (clampFont(pinchBase * g.scale) * 2).rounded() / 2
            if abs(s - fontSize) > 0.01 {
                setFontSize(s)
                Prefs.shared.fontSize = Double(s)
            }
        default:
            zoomer.transform = .identity
            zoomer.frame = bounds
        }
    }

    private func clampFont(_ s: CGFloat) -> CGFloat { min(max(s, Self.fontRange.lowerBound), Self.fontRange.upperBound) }

    // MARK: App state

    /// Hand fitted panes back to the Mac while the app is in the background.
    @objc private func didBackground() {
        backgroundedAt = CACurrentMediaTime()
        guard claimedSize != nil else { return }
        claimTask?.cancel()
        claimedSize = nil
        let s = stream
        Task { await s.release() }
    }

    @objc private func willForeground() {
        // After a long suspension the socket is likely dead and the server may have dropped the
        // stream; read the real screen again rather than show a stale one.
        if let t = backgroundedAt, CACurrentMediaTime() - t > Self.staleAfterBackground, started, window != nil {
            stream.restart()
        }
        backgroundedAt = nil
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

    func focusKeyboard() {
        restoreInputViews()
        _ = term.becomeFirstResponder()
    }

    func applyTheme(_ t: TermTheme) {
        theme = t
        backgroundColor = t.uiBG
        zoomer.backgroundColor = t.uiBG
        term.nativeBackgroundColor = t.uiBG
        term.nativeForegroundColor = t.uiFG
        term.caretColor = t.uiCursor
        term.selectedTextBackgroundColor = t.uiSelection
        term.keyboardAppearance = t.isDark ? .dark : .light
        // Native scroll indicators that stay visible on both light and dark themes.
        term.indicatorStyle = t.isDark ? .white : .black
        zoomer.indicatorStyle = term.indicatorStyle
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
        // SwiftTerm resizes to its frame and soft-resets here. Put the server's grid back at the new
        // cell size, then redraw from the server once the new size is settled.
        term.setFonts(normal: f.0, bold: f.1, italic: f.2, boldItalic: f.3)
        applyLocalGrid(serverSize.0, serverSize.1, force: true)
        positionTerm()
        if started {
            needsResync = true
            if !fitted { scheduleResync() }
        }
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
        } else {
            // GPU rendering keeps scrolling and heavy output at the display rate; CoreGraphics is the fallback.
            if !metalTried { metalTried = true; try? term.setUseMetal(true) }
            yieldContentSwipeBack()
        }
    }

    /// iOS 26 swipes back from anywhere in the content. Over the terminal a horizontal flick
    /// switches panes instead; the screen-edge swipe back still works.
    private func yieldContentSwipeBack() {
        guard #available(iOS 26.0, *) else { return }
        var r: UIResponder? = next
        while let cur = r {
            if let nav = cur as? UINavigationController {
                nav.interactiveContentPopGestureRecognizer?.require(toFail: swipeGR)
                return
            }
            if let vc = cur as? UIViewController, let nav = vc.navigationController {
                nav.interactiveContentPopGestureRecognizer?.require(toFail: swipeGR)
                return
            }
            r = cur.next
        }
    }


    func stop() {
        claimTask?.cancel()
        resyncTask?.cancel()
        outputLink?.invalidate()
        outputLink = nil
        output = []
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
        if zoomer.transform == .identity { zoomer.frame = bounds }
        if !statusLabel.isHidden { layoutStatus() }
        guard bounds.width > 20, bounds.height > 20 else { return }
        guard bounds.size != lastBounds else { return }
        lastBounds = bounds.size
        layoutTerminal()
    }

    private func layoutTerminal() {
        positionTerm()
        switch sizing {
        case .fit:
            guard !lostOwnership else { return }
            let want = fitGrid()
            if started, !needsResync, let c = claimedSize, c == want, serverSize == want { return }
            requestClaim(cols: want.0, rows: want.1)
        case .mirror:
            if !started { started = true; stream.start() }
        }
    }

    /// One cell's size in points at the current font.
    private func cellSize() -> CGSize {
        let opt = term.getOptimalFrameSize()
        let (c, r) = localGrid
        guard c > 0, r > 0, opt.width > 0, opt.height > 0 else {
            let font = RexFont.ui(fontSize)
            return CGSize(width: ("W" as NSString).size(withAttributes: [.font: font]).width, height: ceil(font.lineHeight))
        }
        return CGSize(width: opt.width / CGFloat(c), height: opt.height / CGFloat(r))
    }

    /// Largest grid that fits the view at the current font.
    private func fitGrid() -> (Int, Int) {
        let cell = cellSize()
        let c = max(Int((bounds.width + 0.01) / max(cell.width, 1)), 12)
        let r = max(Int((bounds.height + 0.01) / max(cell.height, 1)), 4)
        return (c, r)
    }

    /// Sizes SwiftTerm to a grid without its `resize`, which soft-resets modes the program set.
    private func applyLocalGrid(_ cols: Int, _ rows: Int, force: Bool = false) {
        guard force || localGrid != (cols, rows) else { return }
        let cell = cellSize()
        var b = term.bounds
        b.size = CGSize(width: CGFloat(cols) * cell.width + 0.5, height: CGFloat(rows) * cell.height + 0.5)
        term.bounds = b
        term.setNeedsLayout()
        term.layoutIfNeeded()  // SwiftTerm resizes in layoutSubviews; do it now, at this point of the stream
    }

    /// Places the terminal for the current grid. Fit: 1:1, bottom rows kept in view while the server
    /// catches up with a smaller size (keyboard opening). Mirror: zoomed to fit the width.
    private func positionTerm() {
        guard bounds.width > 1, bounds.height > 1 else { return }
        let cell = cellSize()
        let size = CGSize(width: ceil(CGFloat(localGrid.0) * cell.width) + 0.5,
                          height: ceil(CGFloat(localGrid.1) * cell.height) + 0.5)
        if fitted {
            zoomer.minimumZoomScale = 1
            zoomer.maximumZoomScale = 1
            zoomer.zoomScale = 1
            term.frame = CGRect(x: 0, y: min(0, bounds.height - size.height), width: size.width, height: size.height)
            zoomer.contentSize = bounds.size
            zoomer.contentOffset = .zero
        } else {
            zoomer.minimumZoomScale = min(zoomer.minimumZoomScale, 1)
            zoomer.maximumZoomScale = max(zoomer.maximumZoomScale, 1)
            zoomer.zoomScale = 1
            term.frame = CGRect(origin: .zero, size: size)
            zoomer.contentSize = size
            let fitW = bounds.width / size.width
            let fitH = bounds.height / size.height
            zoomer.minimumZoomScale = min(fitW, fitH, 1)
            zoomer.maximumZoomScale = max(2, fitW)
            zoomer.zoomScale = min(fitW, 1)
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { term }

    private func requestClaim(cols: Int, rows: Int) {
        claimTask?.cancel()
        claimTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)  // settle (fold/rotate/keyboard animations)
            guard let self, !Task.isCancelled else { return }
            await self.stream.claimAndResize(cols: cols, rows: rows)
            guard !Task.isCancelled else { return }
            self.claimedSize = (cols, rows)
            if !self.started {
                self.started = true
                self.needsResync = false
                self.stream.start()
            } else if self.needsResync {
                self.scheduleResync()
            }
            // Otherwise the stream carries the resize and the program's redraw; nothing to reload.
        }
    }

    /// Redraws from the server once the program has had a moment to redraw at the new size.
    private func scheduleResync() {
        resyncTask?.cancel()
        resyncTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled, self.needsResync else { return }
            self.needsResync = false
            self.stream.resync()
        }
    }

    // MARK: TerminalSink

    func streamReset(cols: Int, rows: Int) {
        // Output still queued predates the snapshot that follows; drop it.
        output.removeAll(keepingCapacity: true)
        outputLink?.isPaused = true
        // RIS + clear scrollback, then match the server's grid.
        term.feed(text: "\u{1b}c\u{1b}[3J")
        serverSize = (cols, rows)
        applyLocalGrid(cols, rows)
        positionTerm()
    }

    func streamSnapshot(_ text: String) {
        // One parse, one frame: the restored screen appears at once instead of scrolling in.
        term.feed(text: text)
    }

    func streamFeed(_ bytes: UnsafeBufferPointer<UInt8>) {
        // Light output (echo, prompts) goes straight in for the lowest latency.
        if output.isEmpty, bytes.count <= Self.directFeedLimit {
            feed(ArraySlice(bytes))
            return
        }
        // Heavy output is parsed in per-frame slices so scrolling and typing stay smooth.
        output.append(contentsOf: bytes)
        startOutputLink()
    }

    /// Parses queued output: a frame's budget from the display link, or all of it before a resize.
    private func drainOutput(all: Bool) {
        guard !output.isEmpty else { outputLink?.isPaused = true; return }
        let start = CACurrentMediaTime()
        // Fall behind a little to keep 120 Hz; catch up harder when far behind.
        let budget = output.count > Self.backlogCatchUp ? Self.frameBudgetBehind : Self.frameBudget
        var done = 0
        while done < output.count {
            let end = min(done + Self.feedSlice, output.count)
            feed(output[done..<end])
            done = end
            if !all, CACurrentMediaTime() - start > budget { break }
        }
        if done == output.count {
            output.removeAll(keepingCapacity: output.capacity <= 1 << 20)
            outputLink?.isPaused = true
        } else {
            output.removeSubrange(0..<done)
        }
    }

    private func feed(_ bytes: ArraySlice<UInt8>) {
        term.feed(byteArray: bytes)
    }

    private func startOutputLink() {
        if outputLink == nil {
            let link = CADisplayLink(target: WeakTarget(self), selector: #selector(WeakTarget.tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            outputLink = link
        }
        outputLink?.isPaused = false
    }

    /// Display-link target that doesn't keep the host alive.
    private final class WeakTarget: NSObject {
        weak var host: TerminalHost?
        init(_ host: TerminalHost) { self.host = host }
        @objc func tick(_ link: CADisplayLink) {
            MainActor.assumeIsolated { host?.drainOutput(all: false) }
        }
    }

    func streamResized(cols: Int, rows: Int, owner: String?) {
        // Output before the resize belongs to the old size.
        drainOutput(all: true)
        serverSize = (cols, rows)
        let wasFitted = fitted
        if sizing == .fit, let c = claimedSize, c != (cols, rows), owner != stream.control.clientID {
            // Another client (the Mac, or another phone) resized it. Don't fight over it; offer to take it back.
            claimedSize = nil
            lostOwnership = true
            showStatus(Self.lostText)
        }
        guard localGrid != (cols, rows) || wasFitted != fitted else { return }
        applyLocalGrid(cols, rows)
        positionTerm()
    }

    func streamTheme(_ theme: JSONObject) {}

    func streamExited(code: Int?) {
        showStatus("Program exited\(code.map { " (\($0))" } ?? "")")
    }

    func streamStatus(_ status: TerminalStream.Status) {
        switch status {
        case .live:
            if lostOwnership { showStatus(Self.lostText) } else { hideStatus() }
            if isActive, let t = UserDefaults.standard.string(forKey: "typeTest"), !typedTest {
                typedTest = true
                term.send(txt: t.replacingOccurrences(of: "\\n", with: "\r"))
            }
        case .connecting: showStatus("Connecting…", after: Self.statusDelay)
        // A failure retries on its own; to the user it is still reconnecting.
        case .reconnecting, .failed: showStatus("Reconnecting…", after: Self.statusDelay)
        case .ended(let m): showStatus(m)
        }
    }

    /// One small chip at the top. Transient states wait `after` seconds, so brief blips never show.
    private func showStatus(_ s: String, after delay: TimeInterval = 0) {
        statusWork?.cancel()
        statusWork = nil
        guard delay > 0 else { applyStatus(s); return }
        guard statusLabel.isHidden else { applyStatus(s); return }  // already showing: just update
        let w = DispatchWorkItem { [weak self] in self?.applyStatus(s) }
        statusWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    private func applyStatus(_ s: String) {
        statusLabel.text = s
        let wasHidden = statusLabel.isHidden
        statusLabel.isHidden = false
        layoutStatus()
        if wasHidden {
            statusLabel.alpha = 0
            UIView.animate(withDuration: 0.2) { self.statusLabel.alpha = 1 }
        }
    }

    private func hideStatus() {
        statusWork?.cancel()
        statusWork = nil
        statusLabel.isHidden = true
    }

    private func layoutStatus() {
        let fit = statusLabel.sizeThatFits(CGSize(width: bounds.width - 24, height: 22))
        let w = min(fit.width + 20, bounds.width - 24)
        statusLabel.frame = CGRect(x: (bounds.width - w) / 2, y: 8, width: w, height: 22)
        statusLabel.layer.cornerRadius = 11
    }

    // MARK: TerminalViewDelegate

    nonisolated func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        // SwiftTerm calls this synchronously on the main thread from resize/layout.
        MainActor.assumeIsolated { self.localGrid = (newCols, newRows) }
    }

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
