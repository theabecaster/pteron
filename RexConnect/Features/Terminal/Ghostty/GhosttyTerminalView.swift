import UIKit
import GhosttyVt

/// The Ghostty engine's view: libghostty-vt for terminal state, drawn by our Metal renderer.
///
/// This file is the output side: feeding, snapshot restore, grid, font, theme, cursor and the
/// drawable's lifetime. Input, scrolling and selection live in the `+Input`, `+Scroll` and
/// `+Selection` extension files (phase 2).
final class GhosttyTerminalView: UIView, TerminalEngineView {
    /// Hosts the CAMetalLayer, so the terminal view itself stays free to become a scroll
    /// container in phase 2.
    final class MetalView: UIView {
        override class var layerClass: AnyClass { CAMetalLayer.self }
        // swiftlint:disable:next force_cast
        var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    }

    let engineKind = TerminalEngineKind.ghostty
    let parsesOffMainThread = true
    let fontChangeResetsModes = false

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

    // PHASE 2 (input): stored state for GhosttyTerminalView+Input.swift.
    var panGate: ((UIPanGestureRecognizer) -> Bool)?
    var tapGate: (() -> Bool)?
    /// PHASE 2 (input): never called yet. Offer each hardware key press to it before encoding;
    /// true means a key binding ran and the key must not reach the program.
    var keyHook: ((UIKey) -> Bool)?
    var controlModifier = false
    var metaModifier = false
    var keyboardAppearance: UIKeyboardAppearance = .dark
    private var storedInputView: UIView?
    private var storedInputAccessoryView: UIView?
    override var inputView: UIView? {
        get { storedInputView }
        set { storedInputView = newValue }
    }
    override var inputAccessoryView: UIView? {
        get { storedInputAccessoryView }
        set { storedInputAccessoryView = newValue }
    }
    // END PHASE 2

    // PHASE 2 (selection): stored state for GhosttyTerminalView+Selection.swift.
    var selectionState = GhosttySelectionState()
    /// The fixed end of the drag under way.
    lazy var selectionAnchor = GhosttySelectionAnchor(core: core)
    /// The long press the host retargets. No target of its own.
    lazy var selectionPress: UILongPressGestureRecognizer = {
        let press = UILongPressGestureRecognizer()
        addGestureRecognizer(press)
        return press
    }()
    // END PHASE 2 (selection)

    // PHASE 2 (scroll): stored state for GhosttyTerminalView+Scroll.swift. Created on first use
    // (`didMoveToSuperview`, or any scroll member).
    lazy var scroller = GhosttyScroller(view: self)
    // END PHASE 2 (scroll)

    private var registered = false
    /// Counts `setGrid` calls; a restore remembers the count it was queued at.
    private var gridEpoch = 0
    private var restoreEpoch = -1
    private var inForeground = true

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
        layer.maximumDrawableCount = 3
        addSubview(metalView)

        let renderer = renderer
        core.onDirty = { [weak renderer] in
            guard let renderer else { return }
            renderer.needsFrame.store(true, ordering: .relaxed)
            GhosttyRenderThread.shared.wake()
        }
        renderer.setLayer(layer)
        core.resize(cols: cols, rows: rows, cellWidthPx: atlas.metrics.cellWidth, cellHeightPx: atlas.metrics.cellHeight)

        NotificationCenter.default.addObserver(self, selector: #selector(appDidBackground),
                                               name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillForeground),
                                               name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if registered { GhosttyRenderThread.shared.remove(renderer) }
    }

    /// Stops drawing for good and lets the render thread go. Also happens on deinit.
    func shutdown() {
        guard registered else { return }
        registered = false
        renderer.setVisible(false)
        GhosttyRenderThread.shared.remove(renderer)
    }

    // MARK: Output

    func feed(byteArray: ArraySlice<UInt8>) {
        byteArray.withUnsafeBytes { core.feed($0) }
    }

    func feed(buffer: UnsafeBufferPointer<UInt8>) {
        core.feed(UnsafeRawBufferPointer(buffer))
    }

    func feed(text: String) {
        var t = text
        t.withUTF8 { core.feed(UnsafeRawBufferPointer($0)) }
    }

    func restoreSnapshot(_ bytes: [UInt8], failed: @escaping @MainActor () -> Void) -> Bool {
        restoreSnapshot(bytes, consumed: nil, failed: failed)
    }

    /// Like `restoreSnapshot(_:failed:)`. `consumed` runs on the feed queue, before anything fed
    /// later is parsed, with the number of bytes the snapshot took. Bytes after that belong to
    /// the stream and are the caller's to feed.
    func restoreSnapshot(_ bytes: [UInt8], consumed: (@Sendable (Int) -> Void)?, failed: @escaping @MainActor () -> Void) -> Bool {
        guard GhosttyCore.isSnapshot(bytes) else { return false }
        restoreEpoch = gridEpoch
        core.restore(snapshot: bytes) { [weak self] used in
            if let used {
                consumed?(used)
                // The restored terminal has the snapshot's grid.
                DispatchQueue.main.async { [weak self] in self?.adoptCoreGrid() }
            } else {
                DispatchQueue.main.async { failed() }
            }
        }
        return true
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

    var cellSize: CGSize { atlas.metrics.cellSizePoints }

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
        // The same 55% wash SwiftTerm draws (TermTheme.uiSelection).
        let s = Self.rgb(t.selectionBackground)
        renderer.setSelectionColor(GhosttyRowBuilder.pack(UInt8((s >> 16) & 0xff), UInt8((s >> 8) & 0xff), UInt8(s & 0xff), 140))
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

    /// Ghostty always draws with Metal. Nothing to turn on.
    func enableGPU() {}

    // MARK: Drawable lifetime

    override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
        updateDrawable()
    }

    private func updateDrawable() {
        let w = Int((bounds.width * displayScale).rounded()), h = Int((bounds.height * displayScale).rounded())
        guard w > 0, h > 0 else { return }
        let size = CGSize(width: w, height: h)
        if metalView.metalLayer.drawableSize != size { metalView.metalLayer.drawableSize = size }
        renderer.setDrawableSize(width: w, height: h)
    }

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

    /// Draw only on screen and in the foreground. Parsing continues either way.
    private func updateVisibility() {
        let visible = window != nil && inForeground
        if visible && !registered {
            registered = true
            GhosttyRenderThread.shared.add(renderer)
        }
        renderer.setVisible(visible)
    }
}
