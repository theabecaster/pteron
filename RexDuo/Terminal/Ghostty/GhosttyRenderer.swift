import Foundation
import GhosttyVt
import Metal
import QuartzCore
import Synchronization

/// The device, queue and pipelines every pane shares.
final class GhosttyMetal {
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

    /// Uploads whatever the atlas rasterized since the last frame.
    func sync(_ atlas: GhosttyGlyphAtlas, device: MTLDevice) {
        mask = sync(atlas.maskPage, texture: mask, seen: &maskSize, format: .r8Unorm, device: device)
        color = sync(atlas.colorPage, texture: color, seen: &colorSize, format: .bgra8Unorm, device: device)
    }

    private func sync(_ page: GhosttyAtlasPage, texture: MTLTexture?, seen: inout Int, format: MTLPixelFormat,
                      device: MTLDevice) -> MTLTexture? {
        var texture = texture
        var from = page.dirtyMinY, to = page.dirtyMaxY
        if texture == nil || seen != page.sizeGeneration {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: page.width, height: page.height, mipmapped: false)
            d.usage = .shaderRead
            texture = device.makeTexture(descriptor: d)
            seen = page.sizeGeneration
            from = 0
            to = page.height
        }
        if let texture, from < to {
            texture.replace(region: MTLRegionMake2D(0, from, page.width, to - from), mipmapLevel: 0,
                            withBytes: page.pixels + from * page.bytesPerRow, bytesPerRow: page.bytesPerRow)
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
}

/// Draws one pane. Configuration comes from the main thread; everything else runs on the render thread.
final class GhosttyRenderer: @unchecked Sendable {
    let core: GhosttyCore
    /// Render thread only.
    let frame: GhosttyFrameBuilder
    /// Set when there is something new to draw. Any thread.
    let needsFrame = Atomic<Bool>(false)

    /// Counters for tests and tuning. Render thread writes.
    private(set) var framesDrawn = 0
    private(set) var lastBuildSeconds: CFTimeInterval = 0
    private(set) var lastEncodeSeconds: CFTimeInterval = 0

    // Configuration. Guarded by `configLock`.
    private let configLock = GhosttyLock()
    private var layer: CAMetalLayer?
    private var drawableSize: SIMD2<Int32> = .zero
    private var visible = false
    private var focused = true
    private var pendingAtlas: GhosttyGlyphAtlas?
    private var pendingSelection: UInt32?
    private var scrollOffset: Float = 0
    private var redraw = true

    // Render thread state.
    private var buffers: [Buffers] = []
    private var bufferIndex = 0
    private let inFlight = DispatchSemaphore(value: 3)
    private(set) var blinkOn = true
    private var drawnCursor = GhosttyCursorState()

    private final class Buffers {
        var rects: MTLBuffer?
        var glyphs: MTLBuffer?
    }

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

    func setLayer(_ l: CAMetalLayer?) { configure { layer = l } }
    func setDrawableSize(width: Int, height: Int) { configure { drawableSize = SIMD2(Int32(width), Int32(height)) } }
    /// False while the view is off-window or the app is in the background: no Metal work at all.
    func setVisible(_ v: Bool) { configure { visible = v } }
    /// An unfocused pane shows a hollow cursor, like Ghostty.
    func setFocused(_ f: Bool) { configure { focused = f } }
    func setAtlas(_ a: GhosttyGlyphAtlas) { configure { pendingAtlas = a } }
    func setSelectionColor(_ c: UInt32) { configure { pendingSelection = c } }
    /// How far the grid is shifted up, in pixels, for smooth scrolling. Phase 2.
    func setScrollOffset(_ px: Float) { configure { scrollOffset = px } }

    // MARK: Cursor blink (render thread)

    /// True while this pane shows a cursor that should blink.
    var wantsBlink: Bool {
        configLock.lock()
        defer { configLock.unlock() }
        return visible && focused && frame.cursor.visible && frame.cursor.blinking
    }

    func toggleBlink() {
        blinkOn.toggle()
        needsFrame.store(true, ordering: .relaxed)
    }

    // MARK: Drawing (render thread)

    /// Draws a frame if anything changed. Returns false if it should be tried again on the next tick.
    func render(now: CFTimeInterval) -> Bool {
        configLock.lock()
        let layer = layer, size = drawableSize, visible = visible
        configLock.unlock()
        guard visible, let layer, size.x > 0, size.y > 0, let metal = GhosttyMetal.shared else { return true }
        guard prepare(now: now) else { return true }
        guard inFlight.wait(timeout: .now()) == .success else { return false }
        guard let drawable = layer.nextDrawable() else {
            inFlight.signal()
            markRedraw()
            return false
        }
        let start = CACurrentMediaTime()
        guard let commands = encode(metal: metal, target: drawable.texture, origin: SIMD2(0, 0)) else {
            inFlight.signal()
            return true
        }
        commands.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        commands.present(drawable)
        commands.commit()
        lastEncodeSeconds = CACurrentMediaTime() - start
        framesDrawn += 1
        return true
    }

    /// Draws the current state into `target` and waits for the GPU. For tests and benchmarks.
    @discardableResult
    func renderOffscreen(into target: MTLTexture, now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        guard let metal = GhosttyMetal.shared else { return false }
        markRedraw()
        _ = prepare(now: now)
        let start = CACurrentMediaTime()
        guard let commands = encode(metal: metal, target: target, origin: SIMD2(0, 0)) else { return false }
        commands.commit()
        lastEncodeSeconds = CACurrentMediaTime() - start
        commands.waitUntilCompleted()
        framesDrawn += 1
        return true
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
        let atlas = pendingAtlas, selection = pendingSelection
        pendingAtlas = nil
        pendingSelection = nil
        configLock.unlock()
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
        let focused = focused
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
        var countA = 0, countB = 0, glyphCount = 0
        for row in rows {
            countA += row.backgrounds.count + row.underlines.count
            countB += row.overlays.count
            glyphCount += row.glyphs.count + row.underGlyphs.count
        }
        let stride = MemoryLayout<GhosttyRectInstance>.stride
        let glyphStride = MemoryLayout<GhosttyGlyphInstance>.stride
        let set = buffers[bufferIndex]
        bufferIndex = (bufferIndex + 1) % buffers.count
        let rectBytes = (countA + countB + 8) * stride
        if (set.rects?.length ?? 0) < rectBytes {
            set.rects = metal.device.makeBuffer(length: max(4096, rectBytes * 2), options: .storageModeShared)
        }
        if (set.glyphs?.length ?? 0) < max(1, glyphCount) * glyphStride {
            set.glyphs = metal.device.makeBuffer(length: max(16384, glyphCount * glyphStride * 2), options: .storageModeShared)
        }
        guard let rectBuffer = set.rects, let glyphBuffer = set.glyphs else { return nil }

        let rects = rectBuffer.contents().bindMemory(to: GhosttyRectInstance.self, capacity: countA + countB + 8)
        var n = 0
        for row in rows where row.backgrounds.count > 0 {
            (rects + n).update(from: row.backgrounds.base, count: row.backgrounds.count)
            n += row.backgrounds.count
        }
        var cursorCell = SIMD2<UInt32>(0xffff, 0xffff)
        let cursorWidth = m.cellWidth * (cursor.wide ? 2 : 1)
        let isBlock = cursor.visible && cursor.style == GHOSTTY_CURSOR_STYLE_BLOCK.rawValue
        if isBlock {
            rects[n] = GhosttyRectInstance(x: Int16(clamping: cursor.x * m.cellWidth), y: 0, w: UInt16(clamping: cursorWidth),
                                           h: UInt16(clamping: m.cellHeight), color: cursor.color, row: UInt16(clamping: cursor.y))
            n += 1
            cursorCell = SIMD2(UInt32(cursor.x), UInt32(cursor.y))
        }
        for row in rows where row.underlines.count > 0 {
            (rects + n).update(from: row.underlines.base, count: row.underlines.count)
            n += row.underlines.count
        }
        let firstB = n
        for row in rows where row.overlays.count > 0 {
            (rects + n).update(from: row.overlays.base, count: row.overlays.count)
            n += row.overlays.count
        }
        if cursor.visible && !isBlock {
            let x = Int16(clamping: cursor.x * m.cellWidth), y = UInt16(clamping: cursor.y)
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
                rects[n + 3] = GhosttyRectInstance(x: x + Int16(clamping: cursorWidth - t), y: 0, w: tt, h: h, color: cursor.color, row: y)
                n += 4
            }
        }
        let totalRects = n

        let glyphs = glyphBuffer.contents().bindMemory(to: GhosttyGlyphInstance.self, capacity: max(1, glyphCount))
        var g = 0
        for row in rows where row.underGlyphs.count > 0 {
            (glyphs + g).update(from: row.underGlyphs.base, count: row.underGlyphs.count)
            g += row.underGlyphs.count
        }
        for row in rows where row.glyphs.count > 0 {
            (glyphs + g).update(from: row.glyphs.base, count: row.glyphs.count)
            g += row.glyphs.count
        }

        let textures: GhosttyAtlasTextures
        if let existing = atlas.rendererResources as? GhosttyAtlasTextures {
            textures = existing
        } else {
            textures = GhosttyAtlasTextures()
            atlas.rendererResources = textures
        }
        textures.sync(atlas, device: metal.device)

        configLock.lock()
        let scroll = scrollOffset
        configLock.unlock()
        let bg = frame.background
        func channel(_ c: UInt32, _ shift: UInt32) -> Float { Float((c >> shift) & 0xff) / 255 }
        var uniforms = GhosttyUniforms(
            viewport: SIMD2(Float(target.width), Float(target.height)),
            cell: SIMD2(Float(m.cellWidth), Float(m.cellHeight)),
            origin: SIMD2(origin.x, origin.y - scroll),
            cursorCell: cursorCell,
            // Ghostty's default: the character under a block cursor takes the background color.
            cursorText: SIMD4(channel(bg, 0), channel(bg, 8), channel(bg, 16), 1))

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: Double(channel(bg, 0)), green: Double(channel(bg, 8)),
                                                            blue: Double(channel(bg, 16)), alpha: 1)
        guard let commands = metal.queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<GhosttyUniforms>.stride, index: 1)
        if firstB > 0 {
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
/// The link runs only while some pane has something to draw. When a tick finds nothing dirty it
/// pauses the link, and the next `wake()` resumes it, so idle panes cost nothing. The thread
/// itself exits when the last pane is removed.
final class GhosttyRenderThread: NSObject, @unchecked Sendable {
    static let shared = GhosttyRenderThread()
    /// Cursor blink period, as in Ghostty.
    static let blinkInterval: TimeInterval = 0.6

    /// Display link callbacks so far. An idle app must not increase this.
    let ticks = Atomic<Int>(0)
    /// True while the thread exists.
    let alive = Atomic<Bool>(false)

    private let lifecycle = NSLock()
    private var paneCount = 0
    private var runLoop: CFRunLoop?
    private let linkRunning = Atomic<Bool>(false)

    // Render thread only.
    private var panes: [GhosttyRenderer] = []
    private var link: CADisplayLink?
    private var blinkTimer: Timer?

    func add(_ renderer: GhosttyRenderer) {
        lifecycle.lock()
        paneCount += 1
        if runLoop == nil { start() }
        let loop = runLoop
        lifecycle.unlock()
        perform(on: loop) { [self] in
            panes.append(renderer)
            renderer.needsFrame.store(true, ordering: .relaxed)
            resumeLink()
        }
    }

    func remove(_ renderer: GhosttyRenderer) {
        lifecycle.lock()
        paneCount -= 1
        let loop = runLoop
        let last = paneCount == 0
        if last { runLoop = nil }
        lifecycle.unlock()
        perform(on: loop) { [self] in
            panes.removeAll { $0 === renderer }
            if last { stop() }
        }
    }

    /// Asks for a tick. Cheap when the link is already running. Any thread.
    func wake() {
        guard !linkRunning.load(ordering: .relaxed) else { return }
        lifecycle.lock()
        let loop = runLoop
        lifecycle.unlock()
        perform(on: loop) { [self] in resumeLink() }
    }

    private func perform(on loop: CFRunLoop?, _ block: @escaping () -> Void) {
        guard let loop else { return }
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, block)
        CFRunLoopWakeUp(loop)
    }

    /// Called with `lifecycle` held.
    private func start() {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            runLoop = CFRunLoopGetCurrent()
            let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.isPaused = true
            link.add(to: .current, forMode: .common)
            self.link = link
            alive.store(true, ordering: .relaxed)
            ready.signal()
            CFRunLoopRun()
            alive.store(false, ordering: .relaxed)
        }
        thread.name = "rex.ghostty.render"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    /// Render thread.
    private func stop() {
        link?.invalidate()
        link = nil
        blinkTimer?.invalidate()
        blinkTimer = nil
        linkRunning.store(false, ordering: .relaxed)
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    private func resumeLink() {
        guard let link else { return }
        linkRunning.store(true, ordering: .relaxed)
        link.isPaused = false
    }

    @objc private func tick(_ link: CADisplayLink) {
        ticks.add(1, ordering: .relaxed)
        let now = CACurrentMediaTime()
        var retry = false
        for pane in panes where pane.needsFrame.exchange(false, ordering: .relaxed) {
            if !pane.render(now: now) {
                pane.needsFrame.store(true, ordering: .relaxed)
                retry = true
            }
        }
        updateBlinkTimer()
        if !retry {
            // Nothing left to draw: stop ticking. Re-check afterwards so a wake that raced us isn't lost.
            link.isPaused = true
            linkRunning.store(false, ordering: .relaxed)
            if panes.contains(where: { $0.needsFrame.load(ordering: .relaxed) }) { resumeLink() }
        }
    }

    /// The blink timer exists only while some visible, focused pane has a blinking cursor.
    private func updateBlinkTimer() {
        let wanted = panes.contains { $0.wantsBlink }
        if wanted, blinkTimer == nil {
            let timer = Timer(timeInterval: Self.blinkInterval, repeats: true) { [weak self] _ in self?.blink() }
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
        if any { resumeLink() } else { updateBlinkTimer() }
    }
}
