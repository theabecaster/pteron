import UIKit
import GhosttyVt

/// The terminal view: libghostty-vt for terminal state, drawn by our Metal renderer.
/// `TerminalHost` lays it out, zooms it and makes it first responder.
///
/// This file is the output side: feeding, snapshot restore, grid, font, theme, cursor and the
/// drawable's lifetime. Input, scrolling and selection live in the `+Input`, `+Scroll` and
/// `+Selection` extension files.
final class GhosttyTerminalView: UIView {
    /// Hosts the CAMetalLayer. The scroll surface (`GhosttyScroller`) lies over it.
    final class MetalView: UIView {
        override class var layerClass: AnyClass { CAMetalLayer.self }
        // swiftlint:disable:next force_cast
        var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    }

    /// Held weakly. Setting it reports the current grid once.
    weak var engineDelegate: (any TerminalEngineDelegate)? {
        didSet { engineDelegate?.engineGridChanged(cols: cols, rows: rows) }
    }

    // MARK: State shared with the phase 2 extensions

    let core: GhosttyCore
    let renderer: GhosttyRenderer
    let metalView = MetalView()
    private(set) var atlas: GhosttyGlyphAtlas
    private(set) var fontSize: CGFloat
    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var theme: TermTheme?
    private(set) var displayScale: CGFloat

    // Input: stored state for GhosttyTerminalView+Input.swift and GhosttyInputText.swift, which
    // hold the first-responder overrides and the UIKeyInput / UITextInput conformance.
    /// Asked before any of this view's pans begins (scroll, wheel or arrow drag).
    var panGate: ((UIPanGestureRecognizer) -> Bool)?
    /// Asked before the view's own single tap (a mouse click for the program) fires.
    var tapGate: (() -> Bool)?
    /// Sees each hardware key press before it is encoded; true means a key binding ran and the
    /// key must not reach the program.
    var keyHook: ((UIKey) -> Bool)?
    /// Called when the view becomes (true) or stops being (false) first responder.
    var keyboardFocusHook: ((Bool) -> Void)?
    /// One-shot ctrl / alt for the next key typed on the system keyboard (the key bar sets
    /// them). Cleared after use, with `.terminalEngineControlModifierReset` /
    /// `.terminalEngineMetaModifierReset` posted (object: this view).
    var controlModifier = false
    var metaModifier = false
    /// The key bar's ⌘ is on: the next key typed on the system keyboard is not typed. It goes to
    /// `commandKeyHook` (the key bar, which runs it through the keymap) as the text it would have
    /// typed, DEL for Delete. The key bar clears the flag.
    var commandModifier = false
    var commandKeyHook: ((String) -> Void)?
    var keyboardAppearance: UIKeyboardAppearance = .dark
    let inputState = GhosttyInputState()
    weak var inputDelegate: (any UITextInputDelegate)?
    var markedTextStyle: [NSAttributedString.Key: Any]?
    private(set) lazy var tokenizer: any UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)
    private var storedInputView: UIView?
    private var storedInputAccessoryView: UIView?
    override var inputView: UIView? {
        get { storedInputView }
        set { storedInputView = newValue }
    }
    override var inputAccessoryView: UIView? {
        get { storedInputAccessoryView }
        set {
            storedInputAccessoryView = newValue
            inputAccessoryHook?()
        }
    }
    /// Called after `inputAccessoryView` is set.
    var inputAccessoryHook: (() -> Void)?
    // END input

    // Selection: stored state for GhosttyTerminalView+Selection.swift.
    var selectionState = GhosttySelectionState()
    /// The fixed end of the drag under way.
    lazy var selectionAnchor = GhosttySelectionAnchor(core: core)
    /// The long press the host retargets. No target of its own.
    lazy var selectionPress: UILongPressGestureRecognizer = {
        let press = UILongPressGestureRecognizer()
        addGestureRecognizer(press)
        return press
    }()
    // END selection

    // Scroll: stored state for GhosttyTerminalView+Scroll.swift. Created on first use
    // (`didMoveToSuperview`, or any scroll member).
    lazy var scroller = GhosttyScroller(view: self)

    /// Called when the program enters (true) or leaves (false) the alternate screen.
    var alternateScreenHook: ((Bool) -> Void)?
    /// Called once for a drag that goes into the scrollback while the keyboard covers the view.
    var readingHook: (() -> Void)?
    /// Called with where the view is in the scrollback: when the render thread's news arrives
    /// (at most 30 times a second) and on every scroll step.
    var scrollPlaceHook: ((GhosttyScrollPlace) -> Void)?
    // END scroll

    // Taps: links and prompt clicks (GhosttyTap.swift).
    let taps = GhosttyTapState()
    // END taps

    // Find: stored state for GhosttyTerminalView+Find.swift.
    /// Called on the main thread with the newest result after a search pass published one.
    var findHook: ((FindResult) -> Void)?
    /// A hop to the main thread for `findHook` is queued.
    let findUpdatePending = GhosttyFlag()
    // END find

    private var registered = false
    /// Counts `setGrid` calls; a restore remembers the count it was queued at.
    private var gridEpoch = 0
    /// Whether the pane has the keyboard, and what the program was last told about it
    /// (`sayFocus`).
    var focusNow = false
    var focusSaid = false
    private var restoreEpoch = -1
    private var inForeground = true
    /// Something opaque lies over the pane (the agent board): nothing is drawn and no key is
    /// taken, as for a pane off screen. Parsing goes on, so the screen is current when the cover
    /// goes. False unless the host says otherwise.
    var covered = false {
        didSet { if covered != oldValue { updateVisibility() } }
    }

    /// Drawables per pane's layer. Benchmark builds take `-drawables 2` to compare.
    nonisolated static let drawableCount: Int = {
        #if DEBUG || BENCH
        let n = UserDefaults.standard.integer(forKey: "drawables")
        if n == 2 || n == 3 { return n }
        #endif
        return 3
    }()

    init(frame: CGRect, fontSize: CGFloat, cols: Int = 80, rows: Int = 24) {
        self.fontSize = fontSize
        self.cols = cols
        self.rows = rows
        displayScale = UIScreen.main.scale
        atlas = GhosttyGlyphAtlas.shared(pointSize: fontSize, scale: displayScale)
        core = GhosttyCore(cols: cols, rows: rows)
        renderer = GhosttyRenderer(core: core, atlas: atlas)
        super.init(frame: frame)

        isOpaque = true
        metalView.isUserInteractionEnabled = false
        let layer = metalView.metalLayer
        layer.device = GhosttyMetal.systemDevice
        layer.pixelFormat = GhosttyMetal.pixelFormat
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.contentsScale = displayScale
        layer.maximumDrawableCount = Self.drawableCount
        // `nextDrawable` runs on the render thread every pane shares. With the timeout it comes
        // back with nil after a second when no drawable is free; without it, it never would.
        // The renderer then leaves the pane alone for a while (`GhosttyRenderer.drawableRetryAt`).
        layer.allowsNextDrawableTimeout = true
        addSubview(metalView)

        let renderer = renderer
        core.onDirty = { [weak renderer] in
            guard let renderer else { return }
            renderer.needsFrame.store(true, ordering: .relaxed)
            // Off screen or in the background nothing is drawn: don't start the display link for
            // every chunk of output. `setVisible(true)` asks for the frame that was skipped.
            if renderer.isVisible.load(ordering: .relaxed) { GhosttyRenderThread.shared.wake() }
        }
        renderer.setLayer(layer)
        core.resize(cols: cols, rows: rows, cellWidthPx: atlas.metrics.cellWidth, cellHeightPx: atlas.metrics.cellHeight)

        NotificationCenter.default.addObserver(self, selector: #selector(appDidBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
        // Predicted echo's underline at full alpha with Increase Contrast.
        renderer.setIncreaseContrast(UIAccessibility.isDarkerSystemColorsEnabled)
        NotificationCenter.default.addObserver(self, selector: #selector(contrastChanged),
                                               name: UIAccessibility.darkerSystemColorsStatusDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func contrastChanged() { renderer.setIncreaseContrast(UIAccessibility.isDarkerSystemColorsEnabled) }

    /// The one teardown: the host keeps a pane's view while the pane may come back on screen
    /// (`TerminalHostPool`) and lets go of it when the pane is closed.
    ///
    /// What can outlive the view, and for how long:
    /// - The render thread holds the renderer (and through it the core) until its `remove`
    ///   block has run. A pass that is drawing this pane right now finishes its frame; after
    ///   `retire` no other pass asks the layer for a drawable.
    /// - Blocks on the feed queue hold the core until they have run: bytes still to parse and a
    ///   restore under way finish, then the core frees its terminal there.
    /// - The compression steps and the hold timer hold the core weakly and stop by themselves.
    /// Nothing holds the view: the core's handlers capture the renderer or the scroller weakly.
    deinit {
        renderer.retire()
        if registered { GhosttyRenderThread.shared.remove(renderer) }
    }

    // MARK: Output

    /// The hot path for live output. The buffer is only valid during the call; the core copies
    /// it once and parses on its own queue.
    func feed(buffer: UnsafeBufferPointer<UInt8>) {
        core.feed(UnsafeRawBufferPointer(buffer))
    }

    /// Calls `done` on the main thread once everything fed so far has been parsed.
    func whenParsed(_ done: @escaping @MainActor () -> Void) {
        core.enqueue { DispatchQueue.main.async { done() } }
    }

    /// The pane's stream is catching up (true) or current again: the cursor is hollow
    /// meanwhile, and `hold` keeps the screen on show until then (`GhosttyCore.setCatchUpHold`).
    func setCatchingUp(_ on: Bool, hold: Bool) {
        renderer.setFenced(on)
        core.setCatchUpHold(on && hold)
    }

    func feed(text: String) {
        var t = text
        t.withUTF8 { core.feed(UnsafeRawBufferPointer($0)) }
    }

    /// Restores a `GHOSTSNP` snapshot. False if `bytes` is none; `failed` runs on the main
    /// thread if decoding fails later.
    func restoreSnapshot(_ bytes: [UInt8], failed: @escaping @MainActor () -> Void) -> Bool {
        restoreSnapshot(bytes, trailing: nil, failed: failed)
    }

    /// Like `restoreSnapshot(_:failed:)`, for bytes that go on after the snapshot (a capture of
    /// a stream): once the snapshot is restored, `trailing` gets the bytes behind it and what it
    /// returns is parsed before anything fed later (`GhosttyCore.restore`).
    func restoreSnapshot(_ bytes: [UInt8], trailing: (@Sendable (ArraySlice<UInt8>) -> [UInt8])?,
                         failed: @escaping @MainActor () -> Void) -> Bool {
        guard GhosttyCore.isSnapshot(bytes) else { return false }
        restoreEpoch = gridEpoch
        core.restore(snapshot: bytes, trailing: trailing) { [weak self, core] used in
            if used != nil {
                PerfProbe.active?.ghosttyRestored(core)  // PERF: the restored terminal is in place
                DispatchQueue.main.async { [weak self] in self?.terminalRestored() }
            } else {
                DispatchQueue.main.async { failed() }
            }
        }
        return true
    }

    /// A snapshot replaced the terminal.
    private func terminalRestored() {
        // The selection went with the old terminal: forget it here too, so the host's next
        // question (`hasActiveSelection`, `selectionRects`) is answered "none" without a lock.
        // A drag still under way stays a drag, with nothing to extend. Not if the user has
        // already selected on the new terminal.
        if !core.hasSelection {
            selectionState.active = false
            selectionState.fromGesture = false
            selectionState.moved = false
            selectionState.autoscrollRequest = nil
        }
        // The restored terminal has the snapshot's grid.
        adoptCoreGrid()
    }

    /// Takes over the grid a snapshot restore gave the terminal, unless a later `setGrid` is
    /// already queued behind it (then that one wins and the two agree again).
    private func adoptCoreGrid() {
        guard gridEpoch == restoreEpoch else { return }
        let g = core.gridSize
        guard g.cols != cols || g.rows != rows else { return }
        cols = g.cols
        rows = g.rows
        engineDelegate?.engineGridChanged(cols: cols, rows: rows)
    }

    // MARK: Geometry

    /// One cell in points at the current font.
    var cellSize: CGSize { atlas.metrics.cellSizePoints }

    /// Sizes the local grid. Never resets modes the program set. Reports through the delegate.
    func setGrid(cols: Int, rows: Int, force: Bool) {
        let c = max(1, cols), r = max(1, rows)
        guard force || c != self.cols || r != self.rows else { return }
        self.cols = c
        self.rows = r
        gridEpoch &+= 1
        core.resize(cols: c, rows: r, cellWidthPx: atlas.metrics.cellWidth, cellHeightPx: atlas.metrics.cellHeight)
        engineDelegate?.engineGridChanged(cols: c, rows: r)
    }

    func setFont(size: CGFloat) {
        guard size != fontSize else { return }
        fontSize = size
        reloadAtlas()
    }

    private func reloadAtlas() {
        atlas = GhosttyGlyphAtlas.shared(pointSize: fontSize, scale: displayScale)
        renderer.setAtlas(atlas)
        // Same grid, new cell pixel size. Terminal modes are untouched.
        core.resize(cols: cols, rows: rows, cellWidthPx: atlas.metrics.cellWidth, cellHeightPx: atlas.metrics.cellHeight)
    }

    func apply(theme t: TermTheme) {
        theme = t
        backgroundColor = t.uiBG
        metalView.backgroundColor = t.uiBG
        keyboardAppearance = t.isDark ? .dark : .light
        core.setColors(GhosttyThemeColors(
            foreground: Self.rgb(t.foreground), background: Self.rgb(t.background), cursor: Self.rgb(t.cursor),
            ansi: (0..<16).map { Self.rgb(t.ansi[safe: $0] ?? t.foreground) }))
        // A 55% wash, as TermTheme.uiSelection is.
        let s = Self.rgb(t.selectionBackground)
        renderer.setSelectionColor(GhosttyRowBuilder.pack(UInt8((s >> 16) & 0xff), UInt8((s >> 8) & 0xff), UInt8(s & 0xff), 140))
        renderer.setFindColors(Self.findColors(t))
    }

    /// Find's tints from the theme: ANSI yellow for every match, bright yellow for the current one.
    static func findColors(_ t: TermTheme) -> GhosttyFindHighlights.Colors {
        .theme(yellow: rgb(t.ansi[safe: 3] ?? t.foreground), brightYellow: rgb(t.ansi[safe: 11] ?? t.foreground))
    }

    static func rgb(_ hex: String) -> UInt32 {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        if s.count == 3 {
            let r = (v >> 8) & 0xf, g = (v >> 4) & 0xf, b = v & 0xf
            return UInt32(r * 17) << 16 | UInt32(g * 17) << 8 | UInt32(b * 17)
        }
        return UInt32(v & 0xff_ffff)
    }

    // MARK: Drawable lifetime

    override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
        updateDrawable()
    }

    private func updateDrawable() {
        // Off screen without drawables: a layout there (a resize from the server) makes none.
        guard !drawablesReleased else { return }
        let w = Int((bounds.width * displayScale).rounded()), h = Int((bounds.height * displayScale).rounded())
        guard w > 0, h > 0 else {
            // A layer with no area shows no drawable, so none would come back to its pool: the
            // renderer must not ask for one (it draws nothing at size zero).
            renderer.setDrawableSize(width: 0, height: 0)
            return
        }
        let size = CGSize(width: w, height: h)
        if metalView.metalLayer.drawableSize != size { metalView.metalLayer.drawableSize = size }
        renderer.setDrawableSize(width: w, height: h)
    }

    /// The pane is parked: its layer gives its drawables back (three of the pane's size in
    /// pixels) and nothing is drawn until `restoreDrawables()`.
    func releaseDrawables() {
        drawablesReleased = true
        renderer.setDrawableSize(width: 0, height: 0)
        metalView.metalLayer.drawableSize = CGSize(width: 1, height: 1)
    }

    /// The layer's drawable size in pixels, for tests.
    var metalLayerDrawableSize: CGSize { metalView.metalLayer.drawableSize }

    /// The parked pane is back: drawables at the view's size again, made as the first frame asks.
    func restoreDrawables() {
        drawablesReleased = false
        updateDrawable()
    }
    private var drawablesReleased = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let scale = window?.screen.scale, scale != displayScale {
            displayScale = scale
            metalView.metalLayer.contentsScale = scale
            reloadAtlas()
            updateDrawable()
        }
        updateVisibility()
    }

    @objc private func appDidBackground() {
        inForeground = false
        updateVisibility()
    }

    @objc private func appWillForeground() {
        inForeground = true
        updateVisibility()
    }

    /// Draw only on screen, in the foreground and uncovered. Parsing continues either way.
    private func updateVisibility() {
        let visible = window != nil && inForeground && !covered
        if visible && !registered {
            registered = true
            GhosttyRenderThread.shared.add(renderer)
        }
        renderer.setVisible(visible)
        // A find that missed output while hidden refreshes once.
        if visible { core.find?.visibilityChanged() }
    }
}
