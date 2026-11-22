import Foundation
import GhosttyVt
import Metal
import QuartzCore
import Synchronization

/// The device, queue and pipelines every pane shares.
final class GhosttyMetal: Sendable {
    /// Cheap. Safe to touch on the main thread.
    static let systemDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    /// Compiles the shaders on first use (tens of milliseconds), so first touch it off the main thread.
    static let shared: GhosttyMetal? = GhosttyMetal()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let rectPipeline: MTLRenderPipelineState
    let glyphPipeline: MTLRenderPipelineState
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private init?() {
        guard let device = Self.systemDevice, let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: GhosttyShaders.source, options: nil) else { return nil }
        func pipeline(_ vertex: String, _ fragment: String) -> MTLRenderPipelineState? {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            let a = d.colorAttachments[0]!
            a.pixelFormat = Self.pixelFormat
            // Premultiplied alpha.
            a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = .one
            a.sourceAlphaBlendFactor = .one
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha
            a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: d)
        }
        guard let rect = pipeline("ghosttyRectVertex", "ghosttyRectFragment"),
              let glyph = pipeline("ghosttyGlyphVertex", "ghosttyGlyphFragment") else { return nil }
        self.device = device
        self.queue = queue
        rectPipeline = rect
        glyphPipeline = glyph
    }
}

/// GPU copies of an atlas's two pages. Stored on the atlas, so panes that share a font share them.
private final class GhosttyAtlasTextures {
    var mask: MTLTexture?
    var color: MTLTexture?
    private var maskSize = -1
    private var colorSize = -1

    /// Uploads whatever the atlas rasterized since the last frame. With the atlas locked.
    func sync(_ atlas: GhosttyGlyphAtlas, device: MTLDevice) {
        mask = sync(atlas.maskPage, texture: mask, seen: &maskSize, format: .r8Unorm, device: device)
        color = sync(atlas.colorPage, texture: color, seen: &colorSize, format: .bgra8Unorm, device: device)
    }

    /// Only the box that changed goes up: a new glyph is a few hundred bytes, not the page. A
    /// new texture (first use, the page grew, or the page was wiped) takes the rows in use; the
    /// shader reads exact texels inside glyph boxes, so the rest is never looked at.
    ///
    /// A texture is only ever added to. After a wipe the page puts new glyphs where old ones
    /// were, and panes that share the atlas may have frames with the GPU that still read the
    /// old ones: those frames keep the old texture (a command buffer retains what it uses)
    /// and this one starts over.
    private func sync(_ page: GhosttyAtlasPage, texture: MTLTexture?, seen: inout Int, format: MTLPixelFormat,
                      device: MTLDevice) -> MTLTexture? {
        var texture = texture
        if texture == nil || seen != page.textureGeneration {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: page.width, height: page.height, mipmapped: false)
            d.usage = .shaderRead
            texture = device.makeTexture(descriptor: d)
            seen = page.textureGeneration
            page.markUsedDirty()
        }
        let x = page.dirtyMinX, y = page.dirtyMinY, w = page.dirtyMaxX - x, h = page.dirtyMaxY - y
        if let texture, w > 0, h > 0 {
            texture.replace(region: MTLRegionMake2D(x, y, w, h), mipmapLevel: 0,
                            withBytes: page.pixels + y * page.bytesPerRow + x * page.bytesPerPixel, bytesPerRow: page.bytesPerRow)
        }
        page.clearDirty()
        return texture
    }
}

/// Layout matches `GhosttyUniforms` in GhosttyShaders.metal.
private struct GhosttyUniforms {
    var viewport: SIMD2<Float>
    var cell: SIMD2<Float>
    var origin: SIMD2<Float>
    var cursorCell: SIMD2<UInt32>
    var cursorText: SIMD4<Float>
    /// The current find match's text color, and its rows: (row, first column, last column, 0).
    var matchText: SIMD4<Float> = .zero
    var matchSpans: (SIMD4<UInt32>, SIMD4<UInt32>, SIMD4<UInt32>, SIMD4<UInt32>) = (.zero, .zero, .zero, .zero)
    var matchCount: UInt32 = 0
}

/// Draws one pane. Configuration comes from the main thread; everything else runs on the render thread.
///
/// `@unchecked Sendable`: `configLock` guards the configuration block below. The frame builder, the
/// buffers and the counters are only touched on the render thread (or, in tests, on the one thread
/// that calls `renderOffscreen` for a renderer no thread draws). The atlas has a lock of its own,
/// taken for the row build and for the texture upload (`GhosttyGlyphAtlas`).
final class GhosttyRenderer: @unchecked Sendable {
    let core: GhosttyCore
    /// Render thread only.
    let frame: GhosttyFrameBuilder
    /// Set when there is something new to draw. Any thread.
    let needsFrame = Atomic<Bool>(false)
    /// Mirrors `visible`, for the feed queue: a pane that can't draw has no use for a tick.
    let isVisible = Atomic<Bool>(false)

    /// Frames drawn so far. Written on the render thread, read anywhere (tests, the demo's log).
    var framesDrawn: Int { frameCount.load(ordering: .relaxed) }
    private let frameCount = Atomic<Int>(0)
    /// Calls to `nextDrawable` that came back empty or late. Read anywhere.
    var drawableMisses: Int { misses.load(ordering: .relaxed) }
    private let misses = Atomic<Int>(0)
    /// Counters for tests and tuning. Render thread writes.
    private(set) var lastBuildSeconds: CFTimeInterval = 0
    private(set) var lastEncodeSeconds: CFTimeInterval = 0
    /// When the last frame was handed to the GPU. The render thread paces by it.
    private(set) var lastPresent: CFTimeInterval = 0

    // Configuration. Guarded by `configLock`.
    private let configLock = GhosttyLock()
    private var layer: CAMetalLayer?
    private var drawableSize: SIMD2<Int32> = .zero
    private var visible = false
    private var focused = true
    /// The pane's stream is catching up (`setFenced`).
    private var fenced = false
    private var pendingAtlas: GhosttyGlyphAtlas?
    private var pendingSelection: UInt32?
    private var pendingFindColors: GhosttyFindHighlights.Colors?
    private var pendingContrast: Bool?
    private var redraw = true
    /// The layer, its size or its visibility changed: what was learned about its drawables
    /// (`drawableRetryAt`) no longer holds.
    private var drawableChanged = false

    // Render thread state.
    private var buffers: [Buffers] = []
    /// The buffer set the next frame fills. It moves on only when a frame is committed: a set
    /// filled for a frame that never went to the GPU is filled again, and a set a committed
    /// frame reads comes round again three commits later, when that frame has finished:
    /// `inFlight` lets at most three be under way, and frames finish in the order committed.
    private var bufferIndex = 0
    /// One count per frame handed to the GPU and not finished. Taken in `render` before a
    /// drawable is asked for; given back by the command buffer's completion handler, or at once
    /// on every path that commits nothing.
    private let inFlight = DispatchSemaphore(value: 3)
    /// `nextDrawable` blocks while the layer has no free drawable, and every pane draws on this
    /// thread. A layer that showed none of its frames (clipped away, hidden by an ancestor) has
    /// none free. After a call that came back empty or late, the pane asks for no drawable
    /// until `drawableRetryAt`: the other panes go on drawing, and each further miss doubles
    /// the wait, up to `drawableBackoffLimit`.
    static let drawableBackoffStart: CFTimeInterval = 0.25
    static let drawableBackoffLimit: CFTimeInterval = 4
    /// A wait for a drawable longer than this counts as a miss. A healthy layer answers within
    /// a refresh or two.
    static let slowDrawable: CFTimeInterval = 0.1
    private(set) var drawableRetryAt: CFTimeInterval = 0
    private var drawableBackoff: CFTimeInterval = 0
    private(set) var blinkOn = true
    private var drawnCursor = GhosttyCursorState()

    private final class Buffers {
        var rects: MTLBuffer?
        var glyphs: MTLBuffer?
        /// The `frame.rowsVersion` whose row instances the buffers hold. -1: none.
        var rowsVersion = -1
        /// Find's tints. Made on the first match, freed at the first frame after find closed.
        var highlights: MTLBuffer?
        /// The `frame.highlightsVersion` the highlight buffer holds. -1: none.
        var highlightsVersion = -1
        /// Predicted echo: masks then underlines, and the guessed glyphs. Made on the first guess.
        var echoRects: MTLBuffer?
        var echoGlyphs: MTLBuffer?
        /// What the echo buffers hold. Nil: nothing yet, or a buffer was made again.
        var echoFill: EchoFill?
    }

    /// Any buffer set holds a highlight buffer (tests: none before the first match, none after
    /// find closed). Render thread, or a test's thread for a renderer no thread draws.
    var hasHighlightBuffers: Bool { buffers.contains { $0.highlights != nil } }

    /// What a buffer set's echo buffers were filled from: the frame's `echoVersion`, and the
    /// block cursor's cell and colour when a mask may sit under it (-1 and 0 otherwise).
    struct EchoFill: Equatable {
        var version: Int
        var cursorX: Int
        var cursorY: Int
        var cursorColor: UInt32
    }
    /// Any buffer set holds an echo buffer (tests: none without a guess, ever). Same threads as
    /// `hasHighlightBuffers`.
    var hasEchoBuffers: Bool { buffers.contains { $0.echoRects != nil || $0.echoGlyphs != nil } }
    /// How often a set's echo buffers were filled (tests: not on frames whose guesses did not
    /// change). Same threads.
    private(set) var echoFills = 0

    init(core: GhosttyCore, atlas: GhosttyGlyphAtlas) {
        self.core = core
        frame = GhosttyFrameBuilder(atlas: atlas)
        buffers = (0..<3).map { _ in Buffers() }
    }

    // MARK: Configuration (any thread)

    private func configure(_ change: () -> Void) {
        configLock.lock()
        change()
        redraw = true
        configLock.unlock()
        needsFrame.store(true, ordering: .relaxed)
        GhosttyRenderThread.shared.wake()
    }

    func setLayer(_ l: CAMetalLayer?) {
        configure {
            layer = l
            drawableChanged = true
        }
    }
    /// A size of zero stops drawing: a layer without area never shows a drawable.
    func setDrawableSize(width: Int, height: Int) {
        let size = SIMD2(Int32(width), Int32(height))
        configLock.lock()
        let same = drawableSize == size
        configLock.unlock()
        if same { return }
        configure {
            drawableSize = size
            drawableChanged = true
        }
    }
    /// False while the view is off-window or the app is in the background: no Metal work at all,
    /// and output doesn't wake the render thread (`isVisible`). Becoming visible draws a frame.
    func setVisible(_ v: Bool) {
        isVisible.store(v, ordering: .relaxed)
        configure {
            visible = v
            drawableChanged = true
        }
    }
    /// The view is going away: no pass may ask its layer for a drawable from now on. A frame
    /// being drawn at this moment is finished. Any thread.
    func retire() {
        isVisible.store(false, ordering: .relaxed)
        configLock.lock()
        visible = false
        layer = nil
        configLock.unlock()
    }
    /// An unfocused pane shows a hollow cursor, like Ghostty.
    func setFocused(_ f: Bool) {
        configLock.lock()
        let same = focused == f
        configLock.unlock()
        if !same { configure { focused = f } }
    }
    /// While the pane's stream catches up its cursor is hollow, as an unfocused pane's: what is
    /// typed now is not sent yet (`CatchUpFence`). Nothing else on the pane changes.
    func setFenced(_ f: Bool) {
        configLock.lock()
        let same = fenced == f
        configLock.unlock()
        if !same { configure { fenced = f } }
    }
    var isFenced: Bool {
        configLock.lock()
        defer { configLock.unlock() }
        return fenced
    }
    /// The pane draws the solid cursor (its view has the keyboard).
    var isFocused: Bool {
        configLock.lock()
        defer { configLock.unlock() }
        return focused
    }
    func setAtlas(_ a: GhosttyGlyphAtlas) { configure { pendingAtlas = a } }
    func setSelectionColor(_ c: UInt32) { configure { pendingSelection = c } }
    func setFindColors(_ c: GhosttyFindHighlights.Colors) { configure { pendingFindColors = c } }
    /// Increase Contrast: predicted echo's underline at full alpha instead of half.
    func setIncreaseContrast(_ on: Bool) { configure { pendingContrast = on } }

    // MARK: Cursor blink (render thread)

    /// True while this pane shows a cursor that should blink.
    var wantsBlink: Bool {
        configLock.lock()
        defer { configLock.unlock() }
        return visible && focused && !fenced && frame.cursor.visible && frame.cursor.blinking
    }

    func toggleBlink() {
        blinkOn.toggle()
        needsFrame.store(true, ordering: .relaxed)
    }

    // MARK: Drawing (render thread)

    /// What a call to `render` did.
    enum Outcome {
        /// Nothing new to draw, or the pane is hidden.
        case idle
        /// A frame was handed to the GPU.
        case presented
        /// Nothing was handed over (three frames are still with the GPU, or the frame could
        /// not be encoded). Try again on the next tick.
        case retry
        /// The layer gave no drawable in time. Try again at `drawableRetryAt`, not before.
        case blocked
    }

    /// Draws a frame if anything changed.
    func render(now: CFTimeInterval) -> Outcome {
        configLock.lock()
        let layer = layer, size = drawableSize, visible = visible
        if drawableChanged {
            drawableChanged = false
            drawableRetryAt = 0
            drawableBackoff = 0
        }
        configLock.unlock()
        // Hidden, or no area: nothing is built, and above all no drawable is asked for.
        guard visible, let layer, size.x > 0, size.y > 0, let metal = GhosttyMetal.shared else { return .idle }
        // Before any work: a pane that waits for its layer costs the others' passes nothing.
        guard now >= drawableRetryAt else { return .blocked }
        // On screen a frame never waits for CoreText: glyphs that need font fallback come a
        // frame or two later (`GhosttyRenderThread.glyphsReady`).
        frame.defersSlowGlyphs = true
        let drawn = prepare(now: now)
        // PERF: a frame that still lacks glyphs doesn't show the state it was built from, so it
        // decides no mark (the probe takes passes that began at or after a mark's time).
        let built = frame.rowsAwaitingGlyphs > 0 ? 0 : now
        guard drawn else {
            PerfProbe.active?.ghosttyPass(self, built: built, presented: false)  // PERF: nothing new to draw
            EchoProbe.active?.pass(core: core, built: built, presented: false)  // PERF
            return .idle
        }
        guard inFlight.wait(timeout: .now()) == .success else {
            markRedraw()
            return .retry
        }
        let asked = CACurrentMediaTime()
        let drawable = layer.nextDrawable()
        let start = CACurrentMediaTime()
        if drawable == nil || start - asked > Self.slowDrawable {
            misses.add(1, ordering: .relaxed)
            drawableBackoff = min(Self.drawableBackoffLimit, max(Self.drawableBackoffStart, drawableBackoff * 2))
            drawableRetryAt = start + drawableBackoff
        } else {
            drawableBackoff = 0
        }
        guard let drawable else {
            inFlight.signal()
            markRedraw()
            return .blocked
        }
        guard let commands = encode(metal: metal, target: drawable.texture, origin: SIMD2(0, 0)) else {
            // Nothing was drawn (the atlas was wiped under the rows, or Metal gave no buffer).
            // The drawable goes back to its layer unused.
            inFlight.signal()
            markRedraw()
            return .retry
        }
        commands.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        commands.present(drawable)
        commands.commit()
        advanceBuffers()
        lastPresent = CACurrentMediaTime()
        lastEncodeSeconds = lastPresent - start
        frameCount.add(1, ordering: .relaxed)
        PerfProbe.active?.ghosttyPass(self, built: built, presented: true)  // PERF: frame handed to the GPU
        EchoProbe.active?.pass(core: core, built: built, presented: true)  // PERF
        return .presented
    }

    /// Draws the current state into `target` and waits for the GPU. For tests and benchmarks.
    @discardableResult
    func renderOffscreen(into target: MTLTexture, now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        guard let metal = GhosttyMetal.shared else { return false }
        markRedraw()
        frame.defersSlowGlyphs = false
        _ = prepare(now: now)
        let start = CACurrentMediaTime()
        guard let commands = encode(metal: metal, target: target, origin: SIMD2(0, 0)) else { return false }
        commands.commit()
        advanceBuffers()
        lastEncodeSeconds = CACurrentMediaTime() - start
        commands.waitUntilCompleted()
        frameCount.add(1, ordering: .relaxed)
        return true
    }

    /// Test hook: builds and encodes the current state into `target` like `renderOffscreen`, but
    /// leaves the commit to the caller, who stands in for a GPU that has not run the frame yet.
    /// Call `offscreenCommitted()` after committing.
    func encodeOffscreen(into target: MTLTexture, now: CFTimeInterval = CACurrentMediaTime()) -> MTLCommandBuffer? {
        guard let metal = GhosttyMetal.shared else { return nil }
        markRedraw()
        frame.defersSlowGlyphs = false
        _ = prepare(now: now)
        return encode(metal: metal, target: target, origin: SIMD2(0, 0))
    }

    func offscreenCommitted() { advanceBuffers() }

    /// Which buffer set the next frame fills (for tests).
    var nextBufferIndex: Int { bufferIndex }

    /// A frame was committed with the current buffer set: the next frame takes the next one.
    private func advanceBuffers() {
        bufferIndex = (bufferIndex + 1) % buffers.count
    }

    private func markRedraw() {
        configLock.lock()
        redraw = true
        configLock.unlock()
    }

    /// Applies pending configuration and rebuilds rows. Returns true if a frame must be drawn.
    private func prepare(now: CFTimeInterval) -> Bool {
        configLock.lock()
        var mustDraw = redraw
        redraw = false
        let atlas = pendingAtlas, selection = pendingSelection, findColors = pendingFindColors, contrast = pendingContrast
        pendingAtlas = nil
        pendingSelection = nil
        pendingFindColors = nil
        pendingContrast = nil
        configLock.unlock()
        if let findColors { frame.findColors = findColors }
        if let contrast { frame.echoUnderlineAlpha = contrast ? 255 : 128 }
        if let atlas {
            frame.atlas = atlas
            frame.invalidate()
        }
        if let selection {
            frame.builder.selectionColor = selection
            frame.invalidate()
        }
        let start = CACurrentMediaTime()
        let previous = frame.cursor
        if frame.update(core: core, now: now) { mustDraw = true }
        lastBuildSeconds = CACurrentMediaTime() - start
        if frame.cursor != previous {
            // Show the cursor right after it moves, as terminals do.
            blinkOn = true
        }
        let cursor = effectiveCursor()
        if cursor != drawnCursor {
            configLock.lock()
            drawnCursor = cursor
            configLock.unlock()
            mustDraw = true
        }
        return mustDraw
    }

    /// Ghostty's order (`renderer/cursor.zig`): hidden by mode, hollow when unfocused, hidden in
    /// the off phase of a blink, else the style the program asked for.
    private func effectiveCursor() -> GhosttyCursorState {
        var c = frame.cursor
        guard c.visible else { return c }
        configLock.lock()
        let focused = focused && !fenced
        configLock.unlock()
        if !focused {
            c.style = GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW.rawValue
        } else if c.blinking && !blinkOn {
            c.visible = false
        }
        return c
    }

    private func encode(metal: GhosttyMetal, target: MTLTexture, origin: SIMD2<Float>) -> MTLCommandBuffer? {
        let atlas = frame.atlas
        let m = atlas.metrics
        let rows = frame.rows
        let cursor = effectiveCursor()

        // Rect pass A: backgrounds, block cursor, underlines. Pass B: overlays and thin cursors.
        // The block cursor always has its slot (an empty rect when there is none), so the rows'
        // instances sit at the same place whatever the cursor does.
        var backgroundCount = 0, underlineCount = 0, countB = 0, glyphCount = 0
        for row in rows {
            backgroundCount += row.backgrounds.count
            underlineCount += row.underlines.count
            countB += row.overlays.count
            glyphCount += row.glyphs.count + row.underGlyphs.count
        }
        let firstB = backgroundCount + 1 + underlineCount
        let stride = MemoryLayout<GhosttyRectInstance>.stride
        let glyphStride = MemoryLayout<GhosttyGlyphInstance>.stride
        // Not advanced here: only a commit uses the set up (`advanceBuffers`).
        let set = buffers[bufferIndex]
        let rectBytes = (firstB + countB + 8) * stride
        if (set.rects?.length ?? 0) < rectBytes {
            set.rects = metal.device.makeBuffer(length: max(4096, rectBytes * 2), options: .storageModeShared)
            set.rowsVersion = -1
        }
        if (set.glyphs?.length ?? 0) < max(1, glyphCount) * glyphStride {
            set.glyphs = metal.device.makeBuffer(length: max(16384, glyphCount * glyphStride * 2), options: .storageModeShared)
            set.rowsVersion = -1
        }
        guard let rectBuffer = set.rects, let glyphBuffer = set.glyphs else { return nil }

        // Find's tints: their own buffer per set, drawn between the backgrounds and the cursor
        // slot. With none the frame is drawn exactly as without find.
        let highlights = frame.highlights
        var highlightBuffer: MTLBuffer?
        if !highlights.isEmpty {
            let bytes = highlights.count * stride
            if (set.highlights?.length ?? 0) < bytes {
                set.highlights = metal.device.makeBuffer(length: max(1024, bytes * 2), options: .storageModeShared)
                set.highlightsVersion = -1
            }
            if let b = set.highlights, set.highlightsVersion != frame.highlightsVersion {
                highlights.withUnsafeBufferPointer { p in
                    b.contents().copyMemory(from: UnsafeRawPointer(p.baseAddress!), byteCount: bytes)
                }
                set.highlightsVersion = frame.highlightsVersion
            }
            highlightBuffer = set.highlights
        } else if !frame.findOpen, buffers.contains(where: { $0.highlights != nil }) {
            // Find closed: frames already with the GPU keep the buffers they use.
            for b in buffers {
                b.highlights = nil
                b.highlightsVersion = -1
            }
        }

        // A frame in which only the cursor or the scroll offset moved (a blink, a smooth scroll
        // between two rows) finds the rows' instances already in this buffer.
        let copyRows = set.rowsVersion != frame.rowsVersion
        set.rowsVersion = frame.rowsVersion
        let rects = rectBuffer.contents().bindMemory(to: GhosttyRectInstance.self, capacity: firstB + countB + 8)
        var n = 0
        if copyRows {
            for row in rows where row.backgrounds.count > 0 {
                (rects + n).update(from: row.backgrounds.base, count: row.backgrounds.count)
                n += row.backgrounds.count
            }
            n += 1
            for row in rows where row.underlines.count > 0 {
                (rects + n).update(from: row.underlines.base, count: row.underlines.count)
                n += row.underlines.count
            }
            for row in rows where row.overlays.count > 0 {
                (rects + n).update(from: row.overlays.base, count: row.overlays.count)
                n += row.overlays.count
            }
        }
        var cursorCell = SIMD2<UInt32>(0xffff, 0xffff)
        let cursorWidth = m.cellWidth * (cursor.wide ? 2 : 1)
        let isBlock = cursor.visible && cursor.style == GHOSTTY_CURSOR_STYLE_BLOCK.rawValue
        if isBlock {
            rects[backgroundCount] = GhosttyRectInstance(
                x: Int16(clamping: cursor.x * m.cellWidth), y: 0, w: UInt16(clamping: cursorWidth),
                h: UInt16(clamping: m.cellHeight), color: cursor.color, row: UInt16(clamping: cursor.y))
            cursorCell = SIMD2(UInt32(cursor.x), UInt32(cursor.y))
        } else {
            rects[backgroundCount] = GhosttyRectInstance(x: 0, y: 0, w: 0, h: 0, color: 0, row: 0)
        }
        n = firstB + countB
        if cursor.visible && !isBlock {
            let left = cursor.x * m.cellWidth
            let x = Int16(clamping: left), y = UInt16(clamping: cursor.y)
            let t = max(1, m.boxThickness)
            let w = UInt16(clamping: cursorWidth), h = UInt16(clamping: m.cellHeight)
            switch cursor.style {
            case GHOSTTY_CURSOR_STYLE_BAR.rawValue:
                rects[n] = GhosttyRectInstance(x: x, y: 0, w: UInt16(clamping: max(t, Int(m.scale.rounded()))), h: h, color: cursor.color, row: y)
                n += 1
            case GHOSTTY_CURSOR_STYLE_UNDERLINE.rawValue:
                rects[n] = GhosttyRectInstance(x: x, y: Int16(clamping: m.cellHeight - 2 * t), w: w, h: UInt16(clamping: 2 * t),
                                               color: cursor.color, row: y)
                n += 1
            default: // hollow block: four edges
                let tt = UInt16(clamping: t)
                rects[n] = GhosttyRectInstance(x: x, y: 0, w: w, h: tt, color: cursor.color, row: y)
                rects[n + 1] = GhosttyRectInstance(x: x, y: Int16(clamping: m.cellHeight - t), w: w, h: tt, color: cursor.color, row: y)
                rects[n + 2] = GhosttyRectInstance(x: x, y: 0, w: tt, h: h, color: cursor.color, row: y)
                // The sum is clamped, not its parts: on a very wide grid `x` is already at the limit.
                rects[n + 3] = GhosttyRectInstance(x: Int16(clamping: left + cursorWidth - t), y: 0, w: tt, h: h,
                                                   color: cursor.color, row: y)
                n += 4
            }
        }
        let totalRects = n

        let g = glyphCount
        if copyRows {
            let glyphs = glyphBuffer.contents().bindMemory(to: GhosttyGlyphInstance.self, capacity: max(1, glyphCount))
            var at = 0
            for row in rows where row.underGlyphs.count > 0 {
                (glyphs + at).update(from: row.underGlyphs.base, count: row.underGlyphs.count)
                at += row.underGlyphs.count
            }
            for row in rows where row.glyphs.count > 0 {
                (glyphs + at).update(from: row.glyphs.base, count: row.glyphs.count)
                at += row.glyphs.count
            }
        }

        atlas.lock()
        // The glyph worker filled the pages and wiped them after the rows were built: their
        // glyph positions are stale. The next pass rebuilds them.
        guard atlas.generation == frame.atlasGeneration else {
            atlas.unlock()
            return nil
        }
        let textures: GhosttyAtlasTextures
        if let existing = atlas.rendererResources as? GhosttyAtlasTextures {
            textures = existing
        } else {
            textures = GhosttyAtlasTextures()
            atlas.rendererResources = textures
        }
        textures.sync(atlas, device: metal.device)
        atlas.unlock()

        // Predicted echo: its own buffers, so the rows' buffers keep their version. A set is
        // filled only when it does not hold these instances already: `frame.echoVersion` counts
        // their changes, and a mask on the block cursor's cell takes the cursor's colour, so the
        // cursor's cell and colour are part of what a set holds. A frame whose guesses did not
        // change since this set's last fill copies nothing, and a frame without guesses does
        // nothing here but compare two counts with zero.
        let echoMasks = frame.echoMasks, echoLines = frame.echoLines, echoGlyphs = frame.echoGlyphs
        var echoRectBuffer: MTLBuffer?, echoGlyphBuffer: MTLBuffer?
        let echoRectCount = echoMasks.count + echoLines.count
        if echoRectCount > 0 || !echoGlyphs.isEmpty {
            let held = EchoFill(version: frame.echoVersion, cursorX: isBlock && !echoMasks.isEmpty ? cursor.x : -1,
                                cursorY: isBlock && !echoMasks.isEmpty ? cursor.y : -1,
                                cursorColor: isBlock && !echoMasks.isEmpty ? cursor.color : 0)
            let rectBytes = echoRectCount * stride, glyphBytes = echoGlyphs.count * glyphStride
            if echoRectCount > 0, (set.echoRects?.length ?? 0) < rectBytes {
                set.echoRects = metal.device.makeBuffer(length: max(1024, rectBytes * 2), options: .storageModeShared)
                set.echoFill = nil
            }
            if !echoGlyphs.isEmpty, (set.echoGlyphs?.length ?? 0) < glyphBytes {
                set.echoGlyphs = metal.device.makeBuffer(length: max(1024, glyphBytes * 2), options: .storageModeShared)
                set.echoFill = nil
            }
            if set.echoFill != held {
                if echoRectCount > 0, let b = set.echoRects {
                    let p = b.contents().bindMemory(to: GhosttyRectInstance.self, capacity: echoRectCount)
                    let cursorRow = UInt16(clamping: cursor.y), cursorX = cursor.x * m.cellWidth
                    for (i, r) in echoMasks.enumerated() {
                        var r = r
                        if isBlock, r.row == cursorRow, Int(r.x) == cursorX { r.color = cursor.color }
                        p[i] = r
                    }
                    for (i, r) in echoLines.enumerated() { p[echoMasks.count + i] = r }
                }
                if !echoGlyphs.isEmpty, let b = set.echoGlyphs {
                    echoGlyphs.withUnsafeBufferPointer { b.contents().copyMemory(from: UnsafeRawPointer($0.baseAddress!), byteCount: glyphBytes) }
                }
                set.echoFill = held
                echoFills += 1
            }
            if echoRectCount > 0 { echoRectBuffer = set.echoRects }
            if !echoGlyphs.isEmpty { echoGlyphBuffer = set.echoGlyphs }
        }

        // Smooth scrolling: the grid is shifted up by the part of a row scrolled past (the overscan
        // row fills the bottom edge), and by the rubber band past either end.
        let scroll = Float(frame.scrollOffset)
        let bg = frame.background
        func channel(_ c: UInt32, _ shift: UInt32) -> Float { Float((c >> shift) & 0xff) / 255 }
        var uniforms = GhosttyUniforms(
            viewport: SIMD2(Float(target.width), Float(target.height)),
            cell: SIMD2(Float(m.cellWidth), Float(m.cellHeight)),
            origin: SIMD2(origin.x, origin.y - scroll),
            cursorCell: cursorCell,
            // Ghostty's default: the character under a block cursor takes the background color.
            cursorText: SIMD4(channel(bg, 0), channel(bg, 8), channel(bg, 16), 1))
        if highlightBuffer != nil, !frame.matchSpans.isEmpty {
            let t = frame.findColors.currentText
            uniforms.matchText = SIMD4(Float((t >> 16) & 0xff) / 255, Float((t >> 8) & 0xff) / 255, Float(t & 0xff) / 255, 1)
            var spans = [SIMD4<UInt32>](repeating: .zero, count: GhosttyFindHighlights.maxSpans)
            for (i, r) in frame.matchSpans.prefix(GhosttyFindHighlights.maxSpans).enumerated() {
                spans[i] = SIMD4(UInt32(r.row), UInt32(r.first), UInt32(r.last), 0)
            }
            uniforms.matchSpans = (spans[0], spans[1], spans[2], spans[3])
            uniforms.matchCount = UInt32(min(frame.matchSpans.count, GhosttyFindHighlights.maxSpans))
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(channel(bg, 0)), green: Double(channel(bg, 8)),
                                                            blue: Double(channel(bg, 16)), alpha: 1)
        guard let commands = metal.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<GhosttyUniforms>.stride, index: 1)
        if let highlightBuffer {
            // Pass A in three draws on the rect buffer: backgrounds, find's tints (their own
            // buffer), then the cursor slot and underlines, so an opaque current match never
            // hides a block cursor or an underline inside it.
            encoder.setRenderPipelineState(metal.rectPipeline)
            if backgroundCount > 0 {
                encoder.setVertexBuffer(rectBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: backgroundCount)
            }
            encoder.setVertexBuffer(highlightBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: highlights.count)
            if firstB - backgroundCount > 1 || isBlock {
                encoder.setVertexBuffer(rectBuffer, offset: backgroundCount * stride, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: firstB - backgroundCount)
            }
        } else if firstB > 1 || isBlock {
            encoder.setRenderPipelineState(metal.rectPipeline)
            encoder.setVertexBuffer(rectBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: firstB)
        }
        if g > 0, let mask = textures.mask, let color = textures.color {
            encoder.setRenderPipelineState(metal.glyphPipeline)
            encoder.setVertexBuffer(glyphBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(mask, index: 0)
            encoder.setFragmentTexture(color, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: g)
        }
        // Predicted echo over the rows' glyphs: masks, guessed glyphs, underlines.
        if let echoRectBuffer, !echoMasks.isEmpty {
            encoder.setRenderPipelineState(metal.rectPipeline)
            encoder.setVertexBuffer(echoRectBuffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: echoMasks.count)
        }
        if let echoGlyphBuffer, let mask = textures.mask, let color = textures.color {
            encoder.setRenderPipelineState(metal.glyphPipeline)
            encoder.setVertexBuffer(echoGlyphBuffer, offset: 0, index: 0)
            encoder.setFragmentTexture(mask, index: 0)
            encoder.setFragmentTexture(color, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: echoGlyphs.count)
        }
        if let echoRectBuffer, !echoLines.isEmpty {
            encoder.setRenderPipelineState(metal.rectPipeline)
            encoder.setVertexBuffer(echoRectBuffer, offset: echoMasks.count * stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: echoLines.count)
        }
        if totalRects > firstB {
            encoder.setRenderPipelineState(metal.rectPipeline)
            encoder.setVertexBuffer(rectBuffer, offset: firstB * stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: totalRects - firstB)
        }
        encoder.endEncoding()
        return commands
    }
}

/// One thread and one display link for every Ghostty pane.
///
/// Pacing follows Ghostty's renderer thread (`renderer/Thread.zig`, `generic.zig`): a wake-up
/// updates and draws at once, and the display link only runs while there is something to draw.
///
/// - A pane that has not presented in the current display interval draws as soon as it is woken.
///   The frame reaches the screen at the next vsync, instead of waiting for the tick after it.
/// - A pane that already presented in this interval waits for the next tick, so a pane never
///   hands over more than one frame per refresh, however fast output arrives.
/// - The link keeps ticking for `idleGrace` after the last output frame, then pauses. An idle
///   pane schedules nothing: no ticks, no passes. The thread exits with the last pane.
final class GhosttyRenderThread: Sendable {
    static let shared = GhosttyRenderThread()
    /// Cursor blink period, as in Ghostty.
    static let blinkInterval: TimeInterval = 0.6
    /// How long the display link keeps running after the last frame drawn for output. Long
    /// enough to span the frames of a redraw loop, so the link isn't paused and resumed between
    /// them (the first callback after a resume can come late).
    static let idleGrace: TimeInterval = 0.1

    /// Display link callbacks so far. An idle app must not increase this.
    let ticks = Atomic<Int>(0)
    /// Times the thread looked for something to draw: ticks plus wake-ups. An idle app must not
    /// increase this either.
    let passes = Atomic<Int>(0)
    /// Frames drawn straight from a wake-up, without waiting for a tick.
    let immediateFrames = Atomic<Int>(0)
    /// True while the thread exists.
    let alive = Atomic<Bool>(false)

    private struct State {
        var paneCount = 0
        /// The thread panes are added to now. A thread that is shutting down is no longer here.
        var worker: Worker?
    }
    private let state = Mutex(State())

    func add(_ renderer: GhosttyRenderer) {
        let worker = state.withLock { s in
            s.paneCount += 1
            if let w = s.worker { return w }
            let w = Worker.start(owner: self)
            s.worker = w
            alive.store(true, ordering: .relaxed)
            return w
        }
        worker.perform { worker.add(renderer) }
    }

    func remove(_ renderer: GhosttyRenderer) {
        let (worker, last) = state.withLock { s in
            s.paneCount -= 1
            let last = s.paneCount == 0
            let w = s.worker
            if last { s.worker = nil }
            return (w, last)
        }
        guard let worker else { return }
        worker.perform { worker.remove(renderer, stop: last) }
    }

    /// Panes registered now (visible or not). Tests use it to check teardown.
    var paneCount: Int { state.withLock { $0.paneCount } }

    /// Asks for a pass over the panes. Set the pane's `needsFrame` first. Cheap when a pass is
    /// already on its way. Any thread.
    func wake() {
        state.withLock({ $0.worker })?.wake()
    }

    /// An atlas has glyphs that frames were drawn without, or its pages were wiped: every pane
    /// looks again. (A pane with nothing to add finds that out in its row build.) Any thread.
    func glyphsReady() {
        guard let worker = state.withLock({ $0.worker }) else { return }
        worker.perform { worker.redrawAll() }
    }

    /// A worker's thread is about to exit.
    fileprivate func workerExited() {
        state.withLock { s in
            // Unless panes came back meanwhile and started the next thread.
            if s.worker == nil { alive.store(false, ordering: .relaxed) }
        }
    }

    /// One run of the render thread: its run loop, display link, blink timer and panes.
    ///
    /// Each run has its own state, so a thread that is shutting down (last pane removed) and the
    /// thread started for the next pane never touch the same link or pane list.
    ///
    /// `@unchecked Sendable`: everything but `passQueued` is only touched on this worker's own
    /// thread (blocks performed on `loop`, the link and the timer). `loop` is written once,
    /// before `start` returns the worker.
    private final class Worker: NSObject, @unchecked Sendable {
        /// A pass is queued on the run loop and has not started. Any thread.
        private let passQueued = Atomic<Bool>(false)
        /// Until this time (`CACurrentMediaTime`, as bits) a wake-up needs no pass of its own:
        /// every pane has its frame for this display interval and the link is running, so the
        /// next tick draws what is new. Written on this thread, read on any.
        private let quietUntil = Atomic<UInt64>(0)
        private let owner: GhosttyRenderThread
        private var loop: CFRunLoop?

        // This worker's thread only.
        private var panes: [GhosttyRenderer] = []
        private var link: CADisplayLink?
        private var blinkTimer: Timer?
        /// Fires when the first pane that waits for its layer may ask for a drawable again.
        private var retryTimer: Timer?
        private var retryTime = CFTimeInterval.infinity
        private var linkRunning = false
        /// The vsync that began the display interval of the last tick, and the interval's length.
        /// Until the first tick after the link was resumed, `vsync` is when it was resumed.
        private var vsync: CFTimeInterval = 0
        private var period: CFTimeInterval = 1.0 / 60
        private var tickedSinceResume = false
        /// When output last gave a pane something to draw.
        private var lastOutput: CFTimeInterval = 0

        private init(owner: GhosttyRenderThread) { self.owner = owner }

        /// Starts a thread and waits until its run loop takes blocks.
        static func start(owner: GhosttyRenderThread) -> Worker {
            let worker = Worker(owner: owner)
            let ready = DispatchSemaphore(value: 0)
            let thread = Thread {
                worker.loop = CFRunLoopGetCurrent()
                let link = CADisplayLink(target: worker, selector: #selector(tick(_:)))
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
                link.isPaused = true
                link.add(to: .current, forMode: .common)
                worker.link = link
                ready.signal()
                CFRunLoopRun()
                owner.workerExited()
            }
            thread.name = "rex.ghostty.render"
            thread.qualityOfService = .userInteractive
            thread.start()
            ready.wait()
            return worker
        }

        /// Runs `block` on this worker's thread. Any thread.
        func perform(_ block: @escaping @Sendable () -> Void) {
            guard let loop else { return }
            CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, block)
            CFRunLoopWakeUp(loop)
        }

        /// Any thread. One queued pass serves every wake-up that comes before it starts.
        func wake() {
            guard CACurrentMediaTime() >= Double(bitPattern: quietUntil.load(ordering: .relaxed)),
                  !passQueued.exchange(true, ordering: .acquiring) else { return }
            perform { self.pass(tick: nil) }
        }

        func add(_ renderer: GhosttyRenderer) {
            panes.append(renderer)
            renderer.needsFrame.store(true, ordering: .relaxed)
            pass(tick: nil)
        }

        func redrawAll() {
            for pane in panes { pane.needsFrame.store(true, ordering: .relaxed) }
            pass(tick: nil)
        }

        func remove(_ renderer: GhosttyRenderer, stop: Bool) {
            panes.removeAll { $0 === renderer }
            guard stop else { return }
            link?.invalidate()
            link = nil
            blinkTimer?.invalidate()
            blinkTimer = nil
            retryTimer?.invalidate()
            retryTimer = nil
            retryTime = .infinity
            linkRunning = false
            CFRunLoopStop(CFRunLoopGetCurrent())
        }

        private func setLinkRunning(_ run: Bool) {
            guard let link, run != linkRunning else { return }
            linkRunning = run
            tickedSinceResume = false
            link.isPaused = !run
        }

        @objc private func tick(_ link: CADisplayLink) {
            owner.ticks.add(1, ordering: .relaxed)
            let length = link.targetTimestamp - link.timestamp
            pass(tick: (link.timestamp, length > 0 ? length : period))
        }

        /// Draws every pane that has something new and may present now. `tick` is the display
        /// interval of the link callback this runs in; nil for a pass a wake-up asked for.
        private func pass(tick: (start: CFTimeInterval, length: CFTimeInterval)?, blink: Bool = false) {
            // Cleared before the panes are read: a wake-up after this point queues the next pass.
            passQueued.store(false, ordering: .releasing)
            guard link != nil else { return }
            owner.passes.add(1, ordering: .relaxed)
            let now = CACurrentMediaTime()
            if let tick {
                vsync = tick.start
                period = tick.length
                tickedSinceResume = true
            }
            // When the display interval that `now` falls in began.
            let interval: CFTimeInterval
            if !linkRunning {
                // Nothing was presented for `idleGrace`: every pane may draw. A pane drawn in this
                // pass then waits for the first tick.
                interval = now
                vsync = now
            } else if tickedSinceResume {
                // Counted on from the last tick. (A late callback may be past its own interval.)
                interval = vsync + ((now - vsync) / period).rounded(.down) * period
            } else {
                interval = vsync
            }
            var waiting = false, drew = false
            // The earliest time a pane that waits for its layer may try again.
            var retryAt = CFTimeInterval.infinity
            // Before the panes are read, so a wake-up that finds it set is seen by this pass.
            quietUntil.store(0, ordering: .relaxed)
            for pane in panes where pane.needsFrame.load(ordering: .relaxed) {
                if pane.lastPresent >= interval {
                    // This interval already has a frame of this pane. The next tick draws.
                    waiting = true
                    continue
                }
                pane.needsFrame.store(false, ordering: .relaxed)
                switch pane.render(now: now) {
                case .presented:
                    drew = true
                    if tick == nil { owner.immediateFrames.add(1, ordering: .relaxed) }
                case .retry:
                    pane.needsFrame.store(true, ordering: .relaxed)
                    waiting = true
                case .blocked:
                    // Not `waiting`: the link doesn't tick for a pane whose layer gives nothing.
                    pane.needsFrame.store(true, ordering: .relaxed)
                    retryAt = min(retryAt, pane.drawableRetryAt)
                case .idle:
                    break
                }
            }
            scheduleRetry(at: retryAt, now: now)
            updateBlinkTimer()
            // A blink is one frame every 0.6 s: it needs no link.
            if drew && !blink { lastOutput = now }
            setLinkRunning(waiting || now - lastOutput < GhosttyRenderThread.idleGrace)
            if linkRunning, tickedSinceResume, panes.allSatisfy({ $0.lastPresent >= interval }) {
                quietUntil.store((interval + period).bitPattern, ordering: .relaxed)
            }
        }

        /// One timer for the panes that wait for their layer. None while no pane does.
        private func scheduleRetry(at time: CFTimeInterval, now: CFTimeInterval) {
            // Most passes change nothing here: no pane waits, or the same one still does.
            if time == retryTime, retryTimer != nil || time.isInfinite { return }
            retryTimer?.invalidate()
            retryTimer = nil
            retryTime = time
            guard time.isFinite else { return }
            let timer = Timer(timeInterval: max(0.001, time - now), repeats: false) { [weak self] _ in
                self?.retryTimer = nil
                self?.retryTime = .infinity
                self?.pass(tick: nil)
            }
            RunLoop.current.add(timer, forMode: .common)
            retryTimer = timer
        }

        /// The blink timer exists only while some visible, focused pane has a blinking cursor.
        private func updateBlinkTimer() {
            let wanted = panes.contains { $0.wantsBlink }
            if wanted, blinkTimer == nil {
                let timer = Timer(timeInterval: GhosttyRenderThread.blinkInterval, repeats: true) { [weak self] _ in self?.blink() }
                timer.tolerance = 0.05
                RunLoop.current.add(timer, forMode: .common)
                blinkTimer = timer
            } else if !wanted, blinkTimer != nil {
                blinkTimer?.invalidate()
                blinkTimer = nil
            }
        }

        private func blink() {
            var any = false
            for pane in panes where pane.wantsBlink || !pane.blinkOn {
                pane.toggleBlink()
                any = true
            }
            if any { pass(tick: nil, blink: true) } else { updateBlinkTimer() }
        }
    }
}
