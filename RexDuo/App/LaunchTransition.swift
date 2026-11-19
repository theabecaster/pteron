import SwiftUI
import UIKit
import Darwin

extension View {
    /// Covers the app with the launch splash, then peels Glide off the screen like a sticker and
    /// flies the app out of the Glide-shaped hole it leaves (iris-out). Apply once, to the root view.
    /// The first call, during the app's first body, starts compiling the peel's shaders.
    func launchTransition() -> some View {
        StickerPeel.prewarm()
        return modifier(LaunchTransition())
    }
}

struct LaunchTransition: ViewModifier {
    @State private var finished = false

    func body(content: Content) -> some View {
        content.background {
            if !finished {
                LaunchSplashAnchor { finished = true }
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Zero-size view whose only job is to find the window on the first frame. The splash itself lives
/// on the window, above the SwiftUI root, so the root can be scaled without scaling the splash.
private struct LaunchSplashAnchor: UIViewRepresentable {
    var onFinish: () -> Void

    func makeUIView(context: Context) -> AnchorView {
        let v = AnchorView()
        v.onFinish = onFinish
        return v
    }

    func updateUIView(_ uiView: AnchorView, context: Context) {}

    final class AnchorView: UIView {
        var onFinish: (() -> Void)?
        private var started = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, !started else { return }
            started = true
            let splash = LaunchSplashView(frame: window.bounds)
            window.addSubview(splash)
            splash.layoutIfNeeded()
            let finish = onFinish
            // Schedule once the first frame is committed, so the clock starts from what is on screen.
            DispatchQueue.main.async { [weak window] in
                splash.run(content: window?.rootViewController?.view) { finish?() }
            }
        }
    }
}

/// UIKit splash. Everything but the sticker runs in the render server (Core Animation); the sticker
/// draws with Metal on its own thread (`StickerPeelRenderer`). Neither waits on the main thread
/// while the app connects underneath.
///
/// Layers (bottom to top):
/// - `cover`: the background with a Glide-shaped hole. A huge border frames `hole`, a bitmap of the
///   background with Glide cut out, so it needs no mask or offscreen pass. Zooming only scales `cover`.
///   `depth` lies on the hole: the shadow and lit edge that make it read as a hole whatever the app
///   shows through it (`LaunchHoleDepth`). It appears with the peel and lifts as the hole opens.
/// - `shadow`: a flat, path-only shadow on the "screen" under the folding cutout (fallback only).
/// - `piece`: the Glide art, the same image as the static launch screen (`LaunchArt`) on the same
///   pixel grid, so the first frame matches it exactly. `shade` darkens it as it tilts.
/// - the peel's `CAMetalLayer`, whose first frame is the same pixels as `piece`; the two swap in one
///   transaction.
///
/// Glide peels off from the bottom-left corner and flies away, leaving the hole; the hole then grows
/// around a point deep inside Glide's head until the app fills the screen. Without Metal in time, the
/// flat cutout folds forward about its bottom edge and drops past the viewer instead.
final class LaunchSplashView: UIView {
    enum Metric {
        /// Hole bitmap pixels per point: sharp up to a few times zoom; past that the edges move fast.
        static let holeScale: CGFloat = 8
        static let holeMargin: CGFloat = 6
        static let perspective: CGFloat = 1 / 500
    }

    private let cover = CALayer()
    private let hole = CALayer()
    private let depth = CALayer()
    private let shadow = CALayer()
    private let piece = CALayer()
    private let shade = CALayer()

    /// Minimum time from process start to the transition, so the splash never lingers.
    static let minimumSplash: CFTimeInterval = 0.6
    /// Minimum time after our first frame: iOS cross-fades from the launch screen to the app's first
    /// frame, and starting inside that fade shows both at once.
    static let handoff: CFTimeInterval = 0.3
    /// The Metal kit must arrive this long before the start, or the Core Animation fold runs.
    static let metalLead: CFTimeInterval = 0.1
    /// How long the hole takes to open, after the Metal peel and after the fold. The hole has
    /// further to grow than the art before it had (its pivot circle is smaller), so it takes a
    /// little longer, which keeps the opening's pace frame by frame close to what it was.
    static let metalIris: CFTimeInterval = 0.80
    static let foldIris: CFTimeInterval = 0.87

    private struct Pending {
        let content: UIView?
        let completion: () -> Void
        let t0: CFTimeInterval
    }

    /// Carries an immutable Core Graphics object (a finished `CGPath`, a `CGImage`) to another
    /// thread. `@unchecked Sendable` because those are safe to read from any thread once made.
    private struct Shared<Value>: @unchecked Sendable {
        let value: Value
        init(_ value: Value) { self.value = value }
    }

    /// Set between `run` and the choice of peel.
    private var pending: Pending?
    /// The Metal peel while it runs.
    private var peel: StickerPeelRenderer?

    /// Debug-build launch arguments: `-launchPeel fold` forces the Core Animation fold,
    /// `-launchSlow 5` plays the transition five times slower, `-launchHold 2` waits 2 s longer first.
    private enum Debug {
        #if DEBUG
        static var foldOnly: Bool { UserDefaults.standard.string(forKey: "launchPeel") == "fold" }
        static var slow: Double { max(UserDefaults.standard.double(forKey: "launchSlow"), 1) }
        static var hold: Double { max(UserDefaults.standard.double(forKey: "launchHold"), 0) }
        #else
        static let foldOnly = false
        static let slow = 1.0
        static let hold = 0.0
        #endif
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .clear
        accessibilityElementsHidden = true

        var perspective = CATransform3DIdentity
        perspective.m34 = -Metric.perspective
        layer.sublayerTransform = perspective

        let bg = UIColor(named: "LaunchBackground") ?? UIColor(red: 0x22 / 255, green: 0x27 / 255, blue: 0x2e / 255, alpha: 1)
        cover.borderColor = bg.cgColor
        hole.contents = Self.holeImage(color: bg)
        hole.contentsGravity = .resize
        cover.addSublayer(hole)
        // Hidden until the peel starts, so the first frame is the static launch screen to the pixel.
        depth.contentsGravity = .resize
        depth.opacity = 0
        cover.addSublayer(depth)
        // Drawn off the main thread: it isn't needed before the peel, a few hundred ms from now.
        let outline = Shared(LaunchArt.silhouette)
        let size = LaunchArt.size, margin = Metric.holeMargin * 2, scale = Metric.holeScale
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let drawn = Shared(LaunchHoleDepth.image(silhouette: outline.value, size: size, margin: margin, scale: scale))
            DispatchQueue.main.async { self?.depth.contents = drawn.value }
        }

        shadow.shadowPath = LaunchArt.silhouette
        shadow.shadowColor = UIColor.black.cgColor
        shadow.shadowOpacity = 0.5
        shadow.shadowRadius = 8
        shadow.shadowOffset = CGSize(width: 0, height: 8)
        shadow.opacity = 0

        piece.anchorPoint = CGPoint(x: 0.5, y: 1)   // peels about its bottom edge
        piece.contentsGravity = .resize
        shade.contentsGravity = .resize
        shade.opacity = 0
        if let img = UIImage(named: LaunchArt.assetName) {
            piece.contents = img.cgImage
            piece.contentsScale = img.scale
            shade.contents = Self.silhouetteImage(of: img)
            shade.contentsScale = img.scale
        }
        piece.addSublayer(shade)

        layer.addSublayer(cover)
        layer.addSublayer(shadow)
        layer.addSublayer(piece)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let art = artRect
        // bounds + position, not frame: frame would fold in the transforms once they run.
        piece.bounds = CGRect(origin: .zero, size: art.size)
        piece.position = CGPoint(x: art.midX, y: art.maxY)
        shade.frame = piece.bounds
        shadow.bounds = piece.bounds
        shadow.position = CGPoint(x: art.midX, y: art.midY)

        // The hole bitmap sits inside a border wide enough to reach past the screen corners at any
        // scale; the border overlaps the bitmap's edge so no seam shows. Scaling pivots on the
        // inscribed circle's centre, so the solid inside of Glide is what ends up covering the screen.
        let border = hypot(bounds.width, bounds.height)
        let m = Metric.holeMargin
        let t = cover.transform
        cover.transform = CATransform3DIdentity
        cover.bounds = CGRect(x: 0, y: 0, width: art.width + 2 * (m + border), height: art.height + 2 * (m + border))
        cover.borderWidth = border
        hole.frame = CGRect(x: border - m, y: border - m, width: art.width + 4 * m, height: art.height + 4 * m)
        depth.frame = hole.frame
        let pivot = pivotPoint(in: art)
        let local = CGPoint(x: border + m + pivot.x - art.minX, y: border + m + pivot.y - art.minY)
        cover.anchorPoint = CGPoint(x: local.x / cover.bounds.width, y: local.y / cover.bounds.height)
        cover.position = pivot
        cover.transform = t
        CATransaction.commit()
    }

    /// Where iOS draws the launch art on the static launch screen: centered, on the pixel grid.
    private var artRect: CGRect {
        let s = max(traitCollection.displayScale, 1)
        let size = LaunchArt.size
        let x = ((bounds.midX - size.width / 2) * s).rounded() / s
        let y = ((bounds.midY - size.height / 2) * s).rounded() / s
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func pivotPoint(in art: CGRect) -> CGPoint {
        let p = LaunchArt.point(LaunchArt.pivot.x, LaunchArt.pivot.y)
        return CGPoint(x: art.minX + p.x, y: art.minY + p.y)
    }

    /// The background with Glide cut out, drawn once (with `holeMargin * 2` of background around the
    /// art). The outline is stroked back in by 0.75 pt so the hole's anti-aliased edge stays under the
    /// art's edge on the first frame.
    private static func holeImage(color: UIColor) -> CGImage? {
        let m = Metric.holeMargin * 2
        let size = CGSize(width: LaunchArt.size.width + 2 * m, height: LaunchArt.size.height + 2 * m)
        let format = UIGraphicsImageRendererFormat()
        format.scale = Metric.holeScale
        format.opaque = false
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            color.setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            cg.translateBy(x: m, y: m)
            cg.addPath(LaunchArt.silhouette)
            cg.setBlendMode(.clear)
            cg.fillPath()
            cg.setBlendMode(.normal)
            cg.addPath(LaunchArt.silhouette)
            color.setStroke()
            cg.setLineWidth(1.5)
            cg.strokePath()
        }.cgImage
    }

    /// Black where the art is opaque: the overlay that darkens the cutout as it tilts away from the light.
    private static func silhouetteImage(of img: UIImage) -> CGImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = img.scale
        format.opaque = false
        return UIGraphicsImageRenderer(size: img.size, format: format).image { ctx in
            img.draw(at: .zero)
            let cg = ctx.cgContext
            cg.setBlendMode(.sourceIn)
            cg.setFillColor(UIColor.black.cgColor)
            cg.fill(CGRect(origin: .zero, size: img.size))
        }.cgImage
    }

    /// Schedules the whole transition up front, then removes itself. The sticker peel draws with
    /// Metal when its kit is ready a little before the start; otherwise Core Animation folds the
    /// cutout. Everything else (iris, app zoom) runs on Core Animation's clock either way.
    func run(content: UIView?, completion: @escaping () -> Void) {
        let elapsed = Self.processUptime() ?? 0
        let delay = max(Self.minimumSplash - elapsed, Self.handoff) + Debug.hold
        let t0 = CACurrentMediaTime() + delay
        PerfProbe.active?.launchStep("splash")  // PERF

        if UIAccessibility.isReduceMotionEnabled {
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                PerfProbe.active?.launchStep("done")  // PERF
                self?.removeFromSuperview()
                completion()
            }
            layer.add(anim("opacity", from: 1, to: 0, start: t0, duration: 0.3, .easeInEaseOut), forKey: "fade")
            layer.opacity = 0
            CATransaction.commit()
            return
        }

        pending = Pending(content: content, completion: completion, t0: t0)
        if Debug.foldOnly {
            begin(with: nil)
            return
        }
        // Once the kit is built, draw the renderer's first frame off the main thread, then decide.
        let timeline = StickerPeelTimeline(art: artRect, size: bounds.size, outline: LaunchArt.silhouette)
        let scale = traitCollection.displayScale, slow = Debug.slow
        let finished: @Sendable (StickerPeelStats) -> Void = { [weak self] stats in
            Task { @MainActor in self?.peelFinished(stats) }
        }
        StickerPeel.take { [weak self] outcome in
            DispatchQueue.global(qos: .userInteractive).async {
                let made: Result<StickerPeelRenderer, StickerPeelError>
                switch outcome {
                case .ready(let kit):
                    do {
                        made = .success(try StickerPeelRenderer.make(kit: kit, timeline: timeline, scale: scale, t0: t0,
                                                                     slow: slow, onFinish: finished))
                    } catch {
                        made = .failure(error as? StickerPeelError ?? StickerPeelError(description: "\(error)"))
                    }
                case .failed(let why):
                    made = .failure(StickerPeelError(description: why))
                }
                Task { @MainActor in self?.begin(with: made) }
            }
        }
        let wait = max(t0 - Self.metalLead - CACurrentMediaTime(), 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.begin(with: nil) }
    }

    /// Picks the peel once: Metal if its renderer arrived in time, else the Core Animation fold.
    private func begin(with made: Result<StickerPeelRenderer, StickerPeelError>?) {
        if case .success? = made { PerfProbe.active?.launchStep("rendererReady") }  // PERF
        guard let p = pending else { return }   // already decided; a late renderer is simply dropped
        pending = nil
        let now = CACurrentMediaTime()
        var renderer: StickerPeelRenderer?
        switch made {
        case .success(let r)? where now < p.t0 - Self.metalLead / 2:
            renderer = r
            PerfProbe.active?.launchPeel("metal")  // PERF
        case .failure(let e)?:
            StickerPeel.log.debug("peel: Core Animation fold (\(e.description, privacy: .public))")
            PerfProbe.active?.launchPeel("fold (\(e.description))")  // PERF
        default:
            StickerPeel.log.debug("peel: Core Animation fold (Metal not ready in time, or forced)")
            PerfProbe.active?.launchPeel(made == nil ? "fold (Metal not ready in time)" : "fold (renderer too close to the start)")  // PERF
        }
        PerfProbe.active?.launchStep("decided", at: now)  // PERF
        // A main thread blocked past the start would skip the beginning: start a beat later instead.
        animate(t0: max(p.t0, now + 0.03), renderer: renderer, content: p.content, completion: p.completion)
    }

    private func peelFinished(_ stats: StickerPeelStats) {
        StickerPeel.log.debug("peel: \(stats.summary, privacy: .public)")
        PerfProbe.active?.launchPeelFrames(targets: stats.targets, leads: stats.leads, encode: stats.encode, gpu: stats.gpu,
                                           late: stats.late)  // PERF
        peel?.layer.removeFromSuperlayer()
        peel = nil
    }

    private func animate(t0: CFTimeInterval, renderer: StickerPeelRenderer?, content: UIView?,
                         completion: @escaping () -> Void) {
        let k = Debug.slow
        PerfProbe.active?.launchStep("start", at: t0)  // PERF
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            PerfProbe.active?.launchStep("done")  // PERF
            self?.peel?.cancel()
            self?.removeFromSuperview()
            completion()
        }

        // Metal: swap the static art for the renderer's identical first frame in this transaction,
        // then let the render thread take over.
        let metal = renderer
        let swapStart = CACurrentMediaTime()
        if let metal {
            layer.insertSublayer(metal.layer, above: piece)
            metal.presentFirstFrame()
            piece.isHidden = true
            shadow.isHidden = true
        }

        // Timeline (seconds after t0):
        //   Metal peel (StickerPeelTimeline):
        //     0.00–0.76  Glide peels from the bottom-left corner toward the top right, curling over itself
        //     0.62–1.00  the loose sticker flies off toward the top right; its shadow fades by 0.92
        //     0.62–1.42  hole grows around the pivot until the app fills the screen; app settles 1.2x -> 1.0x
        //   Core Animation fold (fallback):
        //     0.00–0.60  cutout folds forward about its bottom edge (top toward the viewer), darkening
        //     0.25–0.65  ...and drops past the bottom of the screen, leaving a Glide-shaped hole
        //     0.45–1.32  hole grows as above
        let irisStart = (metal == nil ? 0.45 : StickerPeelTimeline.flightStart) * k
        let irisDuration = (metal == nil ? Self.foldIris : Self.metalIris) * k
        if metal == nil { fold(t0: t0) }

        let art = artRect
        let pivot = pivotPoint(in: art)
        // The smallest scale at which the hole has cleared the whole screen, and a little more.
        let holeEnd = LaunchClearing.scale(pivot: pivot, in: bounds, extent: LaunchArt.extent.map { $0 * LaunchArt.pointsPerUnit })

        // Zooming reads as constant speed when the scale moves evenly in log space, so the keyframes ease
        // the exponent (smoothstep): the hole opens gently, rushes through the screen edges, then lands.
        let iris = CAKeyframeAnimation(keyPath: "transform.scale")
        let steps = 48
        let span = log(holeEnd)
        iris.values = (0...steps).map { i -> CGFloat in
            let u = CGFloat(i) / CGFloat(steps)
            return exp(span * u * u * (3 - 2 * u))
        }
        iris.calculationMode = .linear
        iris.beginTime = t0 + irisStart
        iris.duration = irisDuration
        iris.fillMode = .backwards
        cover.add(iris, forKey: "iris")
        cover.transform = CATransform3DMakeScale(holeEnd, holeEnd, 1)
        // The bitmap edge softens at large scale; by then it is leaving the screen, so fade the last bit.
        cover.add(anim("opacity", from: 1, to: 0, start: t0 + irisStart + irisDuration * 0.85,
                       duration: irisDuration * 0.15, .linear), forKey: "fade")
        cover.opacity = 0

        // The hole's depth: in as the sticker starts to lift, there for the whole peel, then lifting
        // while the hole opens, so the app comes up into the light and nothing of it is left by the
        // time the edge is large and soft.
        let depthEnd = irisStart + irisDuration * 0.45
        let shade = CAKeyframeAnimation(keyPath: "opacity")
        shade.values = [0, 1, 1, 0]
        shade.keyTimes = [0, NSNumber(value: 0.05 * k / depthEnd), NSNumber(value: irisStart / depthEnd), 1]
        shade.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .linear),
                                 CAMediaTimingFunction(name: .easeIn)]
        shade.beginTime = t0
        shade.duration = depthEnd
        shade.fillMode = .backwards
        depth.add(shade, forKey: "depth")
        CATransaction.commit()
        metal?.noteSwap(CACurrentMediaTime() - swapStart)

        if let content {
            CATransaction.begin()
            let zoom = CASpringAnimation(perceptualDuration: irisDuration, bounce: 0)
            zoom.keyPath = "transform.scale"
            zoom.fromValue = 1.2
            zoom.toValue = 1.0
            zoom.beginTime = t0 + irisStart
            zoom.duration = zoom.settlingDuration
            zoom.fillMode = .backwards
            content.layer.add(zoom, forKey: "launchZoom")
            CATransaction.commit()
        }

        metal?.start()
        peel = metal
    }

    /// The fallback peel: the flat cutout folds forward on its bottom edge like a hinged flap (top
    /// toward the viewer), then falls off the bottom of the screen whole, still tipping (no fade).
    private func fold(t0: CFTimeInterval) {
        let k = Debug.slow
        let peel = 0.60 * k, dropStart = 0.25 * k, dropDuration = 0.40 * k
        let art = artRect
        // Negative x-rotation brings the top edge toward the viewer.
        let folded = -CGFloat.pi * 0.2, tilt = -CGFloat.pi * 0.36, lift: CGFloat = 150
        let tip = CAKeyframeAnimation(keyPath: "transform.rotation.x")
        tip.values = [0, folded, tilt]
        tip.keyTimes = [0, 0.5, 1]
        tip.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.5, 0, 0.75, 0.6), CAMediaTimingFunction(name: .linear)]
        tip.beginTime = t0
        tip.duration = peel
        tip.fillMode = .backwards
        piece.add(tip, forKey: "tip")
        let fall = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.9, 0.55)
        let drop = bounds.maxY - art.maxY + art.height * 2
        // Lifting toward the camera is what makes it grow as it falls past the viewer. The top edge
        // peaks at lift + height * sin(-tilt), about 270 pt, well short of the 500 pt eye distance.
        piece.add(anim("transform.translation.z", from: 0, to: lift, start: t0, duration: peel,
                       CAMediaTimingFunction(controlPoints: 0.4, 0, 0.8, 0.6)), forKey: "lift")
        piece.add(anim("transform.translation.y", from: 0, to: drop, start: t0 + dropStart, duration: dropDuration, fall),
                  forKey: "drop")
        piece.transform = CATransform3DRotate(CATransform3DMakeTranslation(0, drop, lift), tilt, 1, 0, 0)
        shade.add(anim("opacity", from: 0, to: 0.5, start: t0, duration: peel, .easeIn), forKey: "shade")
        shade.opacity = 0.5

        // Its shadow on the screen: appears as the top lifts, slides down with it, then thins out.
        let shadowLife = CAKeyframeAnimation(keyPath: "opacity")
        shadowLife.values = [0, 1, 0]
        shadowLife.keyTimes = [0, 0.4, 1]
        shadowLife.beginTime = t0
        shadowLife.duration = 0.5 * k
        shadowLife.fillMode = .backwards
        shadow.add(shadowLife, forKey: "life")
        shadow.add(anim("transform.translation.y", from: 0, to: art.height * 0.5, start: t0, duration: 0.5 * k, .easeIn),
                   forKey: "slide")
        shadow.transform = CATransform3DMakeTranslation(0, art.height * 0.5, 0)
    }

    private func anim(_ key: String, from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: CFTimeInterval,
                      _ timing: CAMediaTimingFunctionName) -> CABasicAnimation {
        anim(key, from: from, to: to, start: start, duration: duration, CAMediaTimingFunction(name: timing))
    }

    private func anim(_ key: String, from: CGFloat, to: CGFloat, start: CFTimeInterval, duration: CFTimeInterval,
                      _ timing: CAMediaTimingFunction) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: key)
        a.fromValue = from
        a.toValue = to
        a.beginTime = start
        a.duration = duration
        a.timingFunction = timing
        a.fillMode = .backwards
        return a
    }

    /// Seconds since this process started (the user's tap, roughly).
    nonisolated static func processUptime() -> CFTimeInterval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        let start = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
        let elapsed = Date().timeIntervalSince1970 - start
        return elapsed >= 0 && elapsed < 60 ? elapsed : nil
    }
}
