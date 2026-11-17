import Metal
import QuartzCore
import UIKit
import Synchronization
import os
import simd

/// The launch splash's sticker peel: Rexie bends off the screen around a rolling cylinder, shows the
/// pale backing, catches the light on the curl and casts a soft shadow, then flies off. Drawn with
/// Metal because Core Animation can only fold flat layers. `LaunchSplashView` keeps its Core
/// Animation fold as the fallback when Metal fails or isn't ready in time.
enum StickerPeel {
    enum Outcome: Sendable {
        case ready(StickerPeelKit)
        case failed(String)
    }

    private struct State {
        var started = false
        var outcome: Outcome?
        var waiter: (@Sendable (Outcome) -> Void)?
    }

    /// The kit being built at launch, handed over once to the splash and then dropped. Launch-only,
    /// which is why this is static: the build starts before any view exists to own it.
    private static let state = Mutex(State())

    static let log = Logger(subsystem: "dev.abrahamgonzalez.rexduo", category: "launch")

    /// Starts compiling the shaders and uploading the art off the main thread. Call it as early in
    /// launch as possible; later calls do nothing.
    @MainActor static func prewarm() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let first = state.withLock { s in
            defer { s.started = true }
            return !s.started
        }
        guard first else { return }
        let kicked = CACurrentMediaTime()
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome: Outcome
            do {
                let kit = try StickerPeelKit()
                log.debug("""
                    peel kit: library+pipelines \(kit.compileTime * 1000, format: .fixed(precision: 1)) ms, \
                    whole kit \(kit.buildTime * 1000, format: .fixed(precision: 1)) ms, \
                    ready \((CACurrentMediaTime() - kicked) * 1000, format: .fixed(precision: 1)) ms after prewarm
                    """)
                outcome = .ready(kit)
                PerfProbe.active?.launchStep("kitReady")  // PERF
            } catch {
                log.error("peel kit failed: \(String(describing: error), privacy: .public)")
                outcome = .failed(String(describing: error))
            }
            let waiter = state.withLock { s -> (@Sendable (Outcome) -> Void)? in
                guard let w = s.waiter else { s.outcome = outcome; return nil }
                s.waiter = nil
                return w
            }
            waiter?(outcome)
        }
    }

    /// Hands the kit to its one user, now if it's built, else when it is (on any thread).
    static func take(_ handler: @escaping @Sendable (Outcome) -> Void) {
        let ready = state.withLock { s -> Outcome? in
            if let o = s.outcome {
                s.outcome = nil
                return o
            }
            guard s.started else { return .failed("not prewarmed") }
            s.waiter = handler
            return nil
        }
        if let ready { handler(ready) }
    }
}

struct StickerPeelError: Error, CustomStringConvertible {
    let description: String
}

/// What the peel needs that doesn't depend on the screen: device, compiled pipelines, the art
/// texture and the mesh's index buffer. Built once, off the main thread, as the app launches.
///
/// `@unchecked Sendable`: every property is a `let` set in `init`, and the kit then moves from the
/// build queue to the main thread to the render thread, one owner at a time. The texture and index
/// buffer are only read after `init` waits for their upload; the Metal device, queue, pipeline and
/// sampler objects are thread-safe.
final class StickerPeelKit: @unchecked Sendable {
    /// Vertices per side of the mesh: about 2.4 pt per cell over the 150 pt art, so a 22 pt curl
    /// spans a couple dozen cells.
    static let grid = 64
    static let sampleCount = 4

    let device: MTLDevice
    let queue: MTLCommandQueue
    let sticker: MTLRenderPipelineState
    let shadow: MTLRenderPipelineState
    let stickerDepth: MTLDepthStencilState
    let shadowDepth: MTLDepthStencilState
    let smooth: MTLSamplerState
    let exact: MTLSamplerState
    /// `LaunchRexie` at the screen's scale, premultiplied sRGB, with mipmaps for the shadow blur.
    let art: MTLTexture
    let artScale: CGFloat
    let indices: MTLBuffer
    let indexCount: Int
    /// Library compile plus both pipelines, and the whole build, in seconds.
    let compileTime: CFTimeInterval
    let buildTime: CFTimeInterval

    init() throws {
        let start = CACurrentMediaTime()
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw StickerPeelError(description: "no Metal device")
        }
        self.device = device
        self.queue = queue

        let library = try device.makeLibrary(source: stickerPeelShaderSource, options: nil)
        func pipeline(_ vertex: String, _ fragment: String) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.rasterSampleCount = Self.sampleCount
            d.depthAttachmentPixelFormat = .depth32Float
            let c = d.colorAttachments[0]!
            c.pixelFormat = .bgra8Unorm
            c.isBlendingEnabled = true
            c.sourceRGBBlendFactor = .one
            c.sourceAlphaBlendFactor = .one
            c.destinationRGBBlendFactor = .oneMinusSourceAlpha
            c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: d)
        }
        sticker = try pipeline("sticker_vertex", "sticker_fragment")
        shadow = try pipeline("shadow_vertex", "shadow_fragment")
        compileTime = CACurrentMediaTime() - start

        func depthState(_ compare: MTLCompareFunction, write: Bool) throws -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = compare
            d.isDepthWriteEnabled = write
            guard let s = device.makeDepthStencilState(descriptor: d) else {
                throw StickerPeelError(description: "no depth state")
            }
            return s
        }
        stickerDepth = try depthState(.less, write: true)
        // Drawn after the sticker, just above the screen: it falls on the stuck part, not under the lifted one.
        shadowDepth = try depthState(.less, write: false)

        func sampler(_ filter: MTLSamplerMinMagFilter, mip: MTLSamplerMipFilter) throws -> MTLSamplerState {
            let d = MTLSamplerDescriptor()
            d.minFilter = filter
            d.magFilter = filter
            d.mipFilter = mip
            d.sAddressMode = .clampToZero
            d.tAddressMode = .clampToZero
            guard let s = device.makeSamplerState(descriptor: d) else { throw StickerPeelError(description: "no sampler") }
            return s
        }
        smooth = try sampler(.linear, mip: .linear)
        exact = try sampler(.nearest, mip: .notMipmapped)

        (art, artScale) = try Self.loadArt(device: device, queue: queue)

        let n = Self.grid
        var idx: [UInt16] = []
        idx.reserveCapacity((n - 1) * (n - 1) * 6)
        for row in 0..<(n - 1) {
            for col in 0..<(n - 1) {
                let i = UInt16(row * n + col), right = i + 1, down = i + UInt16(n)
                // Clockwise on screen while flat, so the art side is the front face.
                idx += [i, right, down, right, down + 1, down]
            }
        }
        guard let ib = device.makeBuffer(bytes: idx, length: idx.count * 2, options: .storageModeShared) else {
            throw StickerPeelError(description: "no index buffer")
        }
        indices = ib
        indexCount = idx.count
        buildTime = CACurrentMediaTime() - start
    }

    /// Draws the art into a premultiplied BGRA sRGB bitmap ourselves, so alpha and color space are
    /// known, and generates mipmaps.
    private static func loadArt(device: MTLDevice, queue: MTLCommandQueue) throws -> (MTLTexture, CGFloat) {
        guard let img = UIImage(named: "LaunchRexie"), let cg = img.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw StickerPeelError(description: "no LaunchRexie")
        }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw StickerPeelError(description: "no bitmap context") }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: true)
        d.usage = .shaderRead
        d.storageMode = .shared
        guard let tex = device.makeTexture(descriptor: d) else { throw StickerPeelError(description: "no texture") }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: bytes, bytesPerRow: w * 4)
        guard let cb = queue.makeCommandBuffer(), let blit = cb.makeBlitCommandEncoder() else {
            throw StickerPeelError(description: "no blit")
        }
        blit.generateMipmaps(for: tex)
        blit.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        return (tex, img.scale)
    }
}

/// Mirrors `Uniforms` in StickerPeelShader.swift.
struct StickerPeelUniforms {
    var art: SIMD4<Float>
    var peel: SIMD4<Float>
    var curl: SIMD4<Float>
    var view: SIMD4<Float>
    var shade: SIMD4<Float>
    var rigid: simd_float4x4
}

/// The peel's choreography, in seconds after the transition starts. Pure math, no Metal.
struct StickerPeelTimeline: Sendable {
    static let peelEnd = 0.76
    static let flightStart = 0.62
    static let flightEnd = 1.00
    static let shadowFadeEnd = 0.92
    /// Eye distance in points, as the Core Animation fold's `m34`.
    static let eye: Float = 500

    let art: CGRect
    let size: CGSize
    /// Peel origin (the art's bottom-left corner, behind the tail) and direction (toward the top right).
    let origin: SIMD2<Float>
    let direction = simd_normalize(SIMD2<Float>(0.8, -0.6))
    /// Where the silhouette starts and ends along `direction`, measured from `origin`.
    let uMin: Float
    let uMax: Float
    /// How far the detached sticker travels: past the screen edge with room to spare.
    let flight: Float

    init(art: CGRect, size: CGSize, outline: CGPath) {
        self.art = art
        self.size = size
        let o = SIMD2<Float>(Float(art.minX), Float(art.maxY))
        origin = o
        let d = direction
        var lo = Float.greatestFiniteMagnitude, hi = -Float.greatestFiniteMagnitude
        outline.flattened(threshold: 0.2).applyWithBlock { el in
            let e = el.pointee
            guard e.type == .moveToPoint || e.type == .addLineToPoint else { return }
            let q = SIMD2<Float>(Float(art.minX + e.points[0].x), Float(art.minY + e.points[0].y))
            let u = simd_dot(q - o, d)
            lo = min(lo, u)
            hi = max(hi, u)
        }
        if lo > hi { lo = 0; hi = Float(art.width + art.height) }
        uMin = lo
        uMax = hi
        let c = SIMD2<Float>(Float(art.midX), Float(art.midY))
        let toX = d.x > 0 ? (Float(size.width) - c.x) / d.x : c.x / -d.x
        let toY = d.y < 0 ? c.y / -d.y : (Float(size.height) - c.y) / d.y
        flight = min(toX, toY) + Float(hypot(art.width, art.height)) * 1.4
    }

    /// Uniforms for time `t`; before 0 the sticker lies flat and untouched.
    func uniforms(at t: Double) -> StickerPeelUniforms {
        let d = direction
        let k = Self.cubicBezier(0.45, 0, 0.40, 1, min(max(t / Self.peelEnd, 0), 1))   // adhesion break, then a steady pull
        let prog = Float(k)
        // Start just before the silhouette (only clear texels lift) and end just past it.
        let p: Float = t < 0 ? -1e5 : uMin - 4 + prog * (uMax - uMin + 10)
        // A tight catch at the corner, rounder as more lifts. The loose part leaves the curl rising
        // steeply toward the viewer, as when fingers pull a sticker up, rather than lying back flat.
        let radius: Float = 8 + 16 * prog
        let phiMax: Float = (100 + 25 * prog) * .pi / 180

        let f = Float(Self.cubicBezier(0.4, 0, 1, 1, min(max((t - Self.flightStart) / (Self.flightEnd - Self.flightStart), 0), 1)))
        let pivot = SIMD3<Float>(Float(art.midX), Float(art.midY), 0)
        let move = SIMD3<Float>(d.x * flight * f, d.y * flight * f, 170 * f)
        let rigid = Self.translation(pivot + move) * Self.rotationZ(0.25 * f) * Self.translation(-pivot)
        let fade = 1 - min(max((t - Self.flightStart) / (Self.shadowFadeEnd - Self.flightStart), 0), 1)

        return StickerPeelUniforms(
            art: SIMD4(Float(art.minX), Float(art.minY), Float(art.width), Float(art.height)),
            peel: SIMD4(origin.x, origin.y, d.x, d.y),
            curl: SIMD4(p, radius, phiMax, Self.eye),
            view: SIMD4(Float(size.width / 2), Float(size.height / 2), Float(size.width), Float(size.height)),
            shade: SIMD4(0.42 * Float(fade), 0.55, 0, 0),
            rigid: rigid)
    }

    /// CSS-style cubic-bezier easing: y at x.
    static func cubicBezier(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, _ x: Double) -> Double {
        func bez(_ a: Double, _ b: Double, _ u: Double) -> Double {
            let v = 1 - u
            return 3 * v * v * u * a + 3 * v * u * u * b + u * u * u
        }
        var lo = 0.0, hi = 1.0
        for _ in 0..<30 {
            let mid = (lo + hi) / 2
            if bez(x1, x2, mid) < x { lo = mid } else { hi = mid }
        }
        return bez(y1, y2, (lo + hi) / 2)
    }

    private static func translation(_ v: SIMD3<Float>) -> simd_float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4(v, 1)
        return m
    }

    private static func rotationZ(_ a: Float) -> simd_float4x4 {
        simd_float4x4(SIMD4(cos(a), sin(a), 0, 0), SIMD4(-sin(a), cos(a), 0, 0), SIMD4(0, 0, 1, 0), SIMD4(0, 0, 0, 1))
    }
}

/// Frame timing for the launch log, per drawn frame: the display link's target presentation time
/// (gaps show skipped refreshes), CPU encode time, GPU time, and whether the GPU finished after the
/// frame was due on screen.
struct StickerPeelStats: Sendable {
    var targets: [CFTimeInterval] = []
    /// How long before its target each frame's callback ran: what the frame had left.
    var leads: [CFTimeInterval] = []
    var encode: [CFTimeInterval] = []
    var gpu: [CFTimeInterval] = []
    var late = 0
    /// First frame drawn and scheduled (off the main thread), and the swap transaction (main thread).
    var firstFrame: CFTimeInterval = 0
    var swap: CFTimeInterval = 0

    var summary: String {
        func ms(_ v: Double) -> String { String(format: "%.2f", v * 1000) }
        func pct(_ a: [Double], _ q: Double) -> Double {
            guard !a.isEmpty else { return 0 }
            let s = a.sorted()
            return s[min(s.count - 1, Int((Double(s.count - 1) * q).rounded()))]
        }
        let gaps = zip(targets.dropFirst(), targets).map { $0 - $1 }
        let hist = Dictionary(grouping: gaps) { String(format: "%.1f", $0 * 1000) }
            .sorted { $0.key < $1.key }.map { "\($0.key)ms x\($0.value.count)" }.joined(separator: ", ")
        return "frames \(targets.count); interval p50 \(ms(pct(gaps, 0.5))) p95 \(ms(pct(gaps, 0.95))) "
            + "max \(ms(gaps.max() ?? 0)) ms [\(hist)]; GPU done after due \(late); "
            + "CPU encode p50 \(ms(pct(encode, 0.5))) max \(ms(encode.max() ?? 0)) ms; "
            + "GPU p50 \(ms(pct(gpu, 0.5))) max \(ms(gpu.max() ?? 0)) ms; first frame \(ms(firstFrame)) ms off main, swap \(ms(swap)) ms on main"
    }
}

/// Draws the peel into a `CAMetalLayer` from its own thread, clocked by a `CAMetalDisplayLink`, so
/// main-thread work while the app connects can't stall it. `make` draws the first frame off the
/// main thread; the main thread presents it in the transaction that hides the static art
/// (`presentFirstFrame`), so the swap is atomic; `start()` then hands over to the render thread.
///
/// `@unchecked Sendable`: one thread at a time owns the Metal state: the builder in `make`, the
/// main thread until `start()`, the render thread after it. `cancelled` is atomic and `stats` sits
/// behind a mutex.
final class StickerPeelRenderer: NSObject, CAMetalDisplayLinkDelegate, @unchecked Sendable {
    let layer = CAMetalLayer()
    private var kit: StickerPeelKit?
    private let timeline: StickerPeelTimeline
    /// Transition start on `CACurrentMediaTime()`'s clock, the base of the Core Animation `beginTime`s.
    private let t0: CFTimeInterval
    /// Debug slow motion: 1 is normal speed.
    private let slow: Double
    private var msaa: MTLTexture?
    private var depth: MTLTexture?
    private var link: CAMetalDisplayLink?
    private var running = true
    private var encodeTimes: [CFTimeInterval] = []
    private var targets: [CFTimeInterval] = []
    private var leads: [CFTimeInterval] = []
    private var firstDrawable: CAMetalDrawable?
    private let cancelled = Atomic(false)
    private let stats = Mutex(StickerPeelStats())

    /// Seconds before the start from which the link draws (still) frames rather than none.
    /// Benchmark builds take `-peelLeadIn <seconds>`.
    static let leadIn: CFTimeInterval = {
        #if DEBUG || BENCH
        if let v = UserDefaults.standard.string(forKey: "peelLeadIn"), let d = Double(v) { return d }
        #endif
        return 0
    }()
    private let onFinish: @Sendable (StickerPeelStats) -> Void

    private init(kit: StickerPeelKit, timeline: StickerPeelTimeline, scale: CGFloat, t0: CFTimeInterval, slow: Double,
                 onFinish: @escaping @Sendable (StickerPeelStats) -> Void) {
        self.kit = kit
        self.timeline = timeline
        self.t0 = t0
        self.slow = slow
        self.onFinish = onFinish
        super.init()
        layer.device = kit.device
        layer.pixelFormat = .bgra8Unorm          // blend in gamma space, as the static launch screen does
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.isOpaque = false
        layer.framebufferOnly = true
        layer.contentsScale = scale
        layer.frame = CGRect(origin: .zero, size: timeline.size)
        layer.drawableSize = CGSize(width: (timeline.size.width * scale).rounded(), height: (timeline.size.height * scale).rounded())
        layer.maximumDrawableCount = 3
        encodeTimes.reserveCapacity(160)
        targets.reserveCapacity(160)
    }

    /// Builds a renderer whose untouched first frame is drawn and scheduled, ready to swap in. Off
    /// the main thread: the first GPU submission waits several milliseconds.
    static func make(kit: StickerPeelKit, timeline: StickerPeelTimeline, scale: CGFloat, t0: CFTimeInterval,
                     slow: Double, onFinish: @escaping @Sendable (StickerPeelStats) -> Void) throws -> StickerPeelRenderer {
        // The texture must be the static launch screen's own bitmap at 1:1, or the swap would show.
        guard abs(kit.artScale - scale) < 0.01, kit.art.width == Int((timeline.art.width * scale).rounded()),
              kit.art.height == Int((timeline.art.height * scale).rounded()) else {
            throw StickerPeelError(description: "art is not at the screen's scale")
        }
        // A thread without a run loop never commits an implicit transaction: commit the layer's setup.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = StickerPeelRenderer(kit: kit, timeline: timeline, scale: scale, t0: t0, slow: slow, onFinish: onFinish)
        r.layer.presentsWithTransaction = true
        CATransaction.commit()
        let begin = CACurrentMediaTime()
        guard let drawable = r.layer.nextDrawable(), let cb = r.encode(t: -1, into: drawable.texture) else {
            throw StickerPeelError(description: "no first frame")
        }
        cb.commit()
        cb.waitUntilScheduled()
        r.firstDrawable = drawable
        let spent = CACurrentMediaTime() - begin
        r.stats.withLock { $0.firstFrame = spent }
        return r
    }

    /// Shows the first frame with the caller's `CATransaction`. Main thread, before `start()`.
    func presentFirstFrame() {
        firstDrawable?.present()
        firstDrawable = nil
    }

    /// Main-thread time of the swap, for the launch log.
    func noteSwap(_ seconds: CFTimeInterval) {
        stats.withLock { $0.swap = seconds }
    }

    /// Hands the renderer to its own thread, which draws every later frame and then frees everything.
    /// Call after committing the transaction that presented the first frame.
    func start() {
        layer.presentsWithTransaction = false
        let thread = Thread { [self] in self.renderLoop() }
        thread.name = "StickerPeel"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops early (the splash went away). Any thread.
    func cancel() { cancelled.store(true, ordering: .relaxed) }

    private func renderLoop() {
        let link = CAMetalDisplayLink(metalLayer: layer)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        link.delegate = self
        link.add(to: .current, forMode: .default)
        self.link = link
        while running {
            _ = RunLoop.current.run(mode: .default, before: .distantFuture)
        }
        link.invalidate()
        self.link = nil
        msaa = nil
        depth = nil
        kit = nil
        let encode = encodeTimes, targets = self.targets, leads = self.leads
        // Let the last command buffers report their GPU time first.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { [self] in
            var s = self.stats.withLock { $0 }
            s.encode = encode
            s.targets = targets
            s.leads = leads
            self.onFinish(s)
        }
    }

    func metalDisplayLink(_ link: CAMetalDisplayLink, needsUpdate update: CAMetalDisplayLink.Update) {
        let t = (update.targetPresentationTimestamp - t0) / slow
        let done = cancelled.load(ordering: .relaxed) || t >= StickerPeelTimeline.flightEnd
        // Until the transition starts, the first frame (drawn on the main thread) is still right.
        // Within `leadIn` of the start, frames of the still sticker are drawn anyway.
        if t < 0 && !done && update.targetPresentationTimestamp < t0 - Self.leadIn { return }
        let begin = CACurrentMediaTime()
        leads.append(update.targetPresentationTimestamp - begin)
        // The last frame is empty: the sticker is off screen by then.
        guard let cb = encode(t: done ? .infinity : t, into: update.drawable.texture) else { return finish() }
        let due = update.targetPresentationTimestamp
        cb.addCompletedHandler { [self] cb in
            let gpu = cb.gpuEndTime - cb.gpuStartTime
            let late = cb.gpuEndTime > due
            self.stats.withLock {
                $0.gpu.append(gpu)
                if late { $0.late += 1 }
            }
        }
        cb.present(update.drawable)
        cb.commit()
        encodeTimes.append(CACurrentMediaTime() - begin)
        targets.append(due)
        if done { finish() }
    }

    private func finish() {
        running = false
        CFRunLoopStop(CFRunLoopGetCurrent())
    }

    /// One frame: the bent sticker, then its shadow. `t = .infinity` draws nothing (a clear frame).
    private func encode(t: Double, into target: MTLTexture) -> MTLCommandBuffer? {
        guard let kit, let cb = kit.queue.makeCommandBuffer() else { return nil }
        if msaa?.width != target.width || msaa?.height != target.height {
            msaa = makeTarget(kit, .bgra8Unorm, target)
            depth = makeTarget(kit, .depth32Float, target)
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = msaa
        pass.colorAttachments[0].resolveTexture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return nil }
        if t.isFinite {
            var u = timeline.uniforms(at: t)
            enc.setCullMode(.none)
            enc.setFrontFacing(.clockwise)
            enc.setVertexBytes(&u, length: MemoryLayout<StickerPeelUniforms>.stride, index: 0)
            enc.setFragmentBytes(&u, length: MemoryLayout<StickerPeelUniforms>.stride, index: 0)
            enc.setFragmentTexture(kit.art, index: 0)
            enc.setFragmentSamplerState(kit.smooth, index: 0)
            enc.setFragmentSamplerState(kit.exact, index: 1)
            enc.setRenderPipelineState(kit.sticker)
            enc.setDepthStencilState(kit.stickerDepth)
            enc.drawIndexedPrimitives(type: .triangle, indexCount: kit.indexCount, indexType: .uint16,
                                      indexBuffer: kit.indices, indexBufferOffset: 0)
            // Also drawn in the flat first frame, where it covers nothing, so its first use isn't mid-peel.
            if u.shade.x > 0 {
                enc.setRenderPipelineState(kit.shadow)
                enc.setDepthStencilState(kit.shadowDepth)
                enc.drawIndexedPrimitives(type: .triangle, indexCount: kit.indexCount, indexType: .uint16,
                                          indexBuffer: kit.indices, indexBufferOffset: 0)
            }
        }
        enc.endEncoding()
        return cb
    }

    /// Multisampled color and depth, never stored: tile memory only on Apple GPUs.
    private func makeTarget(_ kit: StickerPeelKit, _ format: MTLPixelFormat, _ like: MTLTexture) -> MTLTexture? {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: like.width, height: like.height, mipmapped: false)
        d.textureType = .type2DMultisample
        d.sampleCount = StickerPeelKit.sampleCount
        d.usage = .renderTarget
        #if targetEnvironment(simulator)
        d.storageMode = .private
        #else
        d.storageMode = .memoryless
        #endif
        return kit.device.makeTexture(descriptor: d)
    }
}
