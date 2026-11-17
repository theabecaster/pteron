import SwiftUI
import UIKit
import Darwin

extension View {
    /// Covers the app with the launch splash, then peels Rexie off the screen like a sticker and
    /// flies the app out of the Rexie-shaped hole it leaves (iris-out). Apply once, to the root view.
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
/// - `cover`: the background with a Rexie-shaped hole. A huge border frames `hole`, a bitmap of the
///   background with Rexie cut out, so it needs no mask or offscreen pass. Zooming only scales `cover`.
/// - `shadow`: a flat, path-only shadow on the "screen" under the folding cutout (fallback only).
/// - `piece`: the Rexie art, the same image as the static launch screen (`LaunchRexie`) on the same
///   pixel grid, so the first frame matches it exactly. `shade` darkens it as it tilts.
/// - the peel's `CAMetalLayer`, whose first frame is the same pixels as `piece`; the two swap in one
///   transaction.
///
/// Rexie peels off from the bottom-left corner and flies away, leaving the hole; the hole then grows
/// around a point deep inside Rexie's head until the app fills the screen. Without Metal in time, the
/// flat cutout folds forward about its bottom edge and drops past the viewer instead.
final class LaunchSplashView: UIView {
    private enum Metric {
        /// Point size of `LaunchRexie`; the art is the icon's "Rexie Neue Color" layer, 448 x 457 SVG units.
        static let size = CGSize(width: 150, height: 153)
        static let svg = CGSize(width: 448, height: 457)
        /// Centre and radius of the largest circle inside the silhouette (SVG units): the zoom pivot.
        /// Once that circle covers the screen, nothing of the cover is left on screen.
        static let pivot = CGPoint(x: 232, y: 184)
        static let pivotRadius: CGFloat = 140
        /// Hole bitmap pixels per point: sharp up to a few times zoom; past that the edges move fast.
        static let holeScale: CGFloat = 8
        static let holeMargin: CGFloat = 6
        static let perspective: CGFloat = 1 / 500
    }

    private let cover = CALayer()
    private let hole = CALayer()
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

    private struct Pending {
        let content: UIView?
        let completion: () -> Void
        let t0: CFTimeInterval
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

    /// Rexie's outline in points (origin at the art's top-left): the body plus the mouth that fills
    /// its notch, from the icon's "Rexie Neue Color" and "Mouth Neue" vectors.
    static let silhouette: CGPath = {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: x * Metric.size.width / Metric.svg.width, y: y * Metric.size.height / Metric.svg.height)
        }
        let b = CGMutablePath()
        b.move(to: p(165.10, 20.20))
        b.addCurve(to: p(209.05, 46.33), control1: p(177.76, 14.20), control2: p(199.03, 31.90))
        b.addCurve(to: p(219.03, 44.55), control1: p(212.34, 45.67), control2: p(215.67, 45.08))
        b.addCurve(to: p(423.81, 154.72), control1: p(320.02, 28.62), control2: p(411.70, 77.94))
        b.addCurve(to: p(297.37, 314.53), control1: p(434.49, 222.42), control2: p(379.71, 288.85))
        b.addLine(to: p(297.37, 314.56))
        b.addCurve(to: p(201.94, 328.17), control1: p(275.21, 320.53), control2: p(237.14, 326.79))
        b.addCurve(to: p(201.11, 333.46), control1: p(198.62, 328.30), control2: p(197.92, 332.55))
        b.addCurve(to: p(294.57, 345.42), control1: p(223.96, 340.02), control2: p(261.11, 347.29))
        b.addCurve(to: p(294.62, 345.72), control1: p(294.58, 345.52), control2: p(294.60, 345.62))
        b.addCurve(to: p(204.14, 428.36), control1: p(284.02, 387.43), control2: p(246.97, 421.60))
        b.addCurve(to: p(83.67, 358.60), control1: p(151.73, 436.63), control2: p(102.10, 406.43))
        b.addCurve(to: p(47.26, 331.22), control1: p(62.91, 351.82), control2: p(48.18, 342.99))
        b.addCurve(to: p(70.39, 290.35), control1: p(45.48, 308.60), control2: p(73.81, 312.04))
        b.addCurve(to: p(24.03, 249.37), control1: p(66.67, 266.77), control2: p(26.17, 276.57))
        b.addCurve(to: p(56.99, 202.23), control1: p(22.13, 225.19), control2: p(58.68, 229.32))
        b.addCurve(to: p(23.59, 149.63), control1: p(55.63, 180.35), control2: p(16.85, 172.79))
        b.addCurve(to: p(80.79, 124.23), control1: p(30.61, 125.53), control2: p(68.02, 142.32))
        b.addCurve(to: p(80.95, 67.54), control1: p(93.43, 106.33), control2: p(65.73, 83.54))
        b.addCurve(to: p(142.66, 70.35), control1: p(97.84, 49.78), control2: p(123.33, 80.99))
        b.addCurve(to: p(165.10, 20.20), control1: p(162.10, 59.64), control2: p(146.04, 29.24))
        b.closeSubpath()
        let m = CGMutablePath()
        m.move(to: p(296.68, 314.21))
        m.addLine(to: p(296.69, 314.25))
        m.addCurve(to: p(293.93, 345.55), control1: p(292.80, 324.22), control2: p(292.25, 334.81))
        m.addCurve(to: p(293.48, 347.28), control1: p(293.79, 346.13), control2: p(293.64, 346.70))
        m.addCurve(to: p(200.46, 335.20), control1: p(260.09, 349.07), control2: p(223.18, 341.78))
        m.addCurve(to: p(197.73, 331.13), control1: p(198.37, 334.60), control2: p(197.46, 332.81))
        m.addCurve(to: p(201.51, 327.92), control1: p(197.99, 329.46), control2: p(199.38, 328.00))
        m.addCurve(to: p(296.74, 314.19), control1: p(236.71, 326.53), control2: p(274.78, 320.18))
        m.addCurve(to: p(296.68, 314.21), control1: p(296.72, 314.19), control2: p(296.70, 314.20))
        m.closeSubpath()
        return b.union(m)
    }()

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

        shadow.shadowPath = Self.silhouette
        shadow.shadowColor = UIColor.black.cgColor
        shadow.shadowOpacity = 0.5
        shadow.shadowRadius = 8
        shadow.shadowOffset = CGSize(width: 0, height: 8)
        shadow.opacity = 0

        piece.anchorPoint = CGPoint(x: 0.5, y: 1)   // peels about its bottom edge
        piece.contentsGravity = .resize
        shade.contentsGravity = .resize
        shade.opacity = 0
        if let img = UIImage(named: "LaunchRexie") {
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
        // inscribed circle's centre, so the solid inside of Rexie is what ends up covering the screen.
        let border = hypot(bounds.width, bounds.height)
        let m = Metric.holeMargin
        let t = cover.transform
        cover.transform = CATransform3DIdentity
        cover.bounds = CGRect(x: 0, y: 0, width: art.width + 2 * (m + border), height: art.height + 2 * (m + border))
        cover.borderWidth = border
        hole.frame = CGRect(x: border - m, y: border - m, width: art.width + 4 * m, height: art.height + 4 * m)
        let pivot = pivotPoint(in: art)
        let local = CGPoint(x: border + m + pivot.x - art.minX, y: border + m + pivot.y - art.minY)
        cover.anchorPoint = CGPoint(x: local.x / cover.bounds.width, y: local.y / cover.bounds.height)
        cover.position = pivot
        cover.transform = t
        CATransaction.commit()
    }

    /// Where iOS draws `LaunchRexie` on the static launch screen: centered, on the pixel grid.
    private var artRect: CGRect {
        let s = max(traitCollection.displayScale, 1)
        let size = Metric.size
        let x = ((bounds.midX - size.width / 2) * s).rounded() / s
        let y = ((bounds.midY - size.height / 2) * s).rounded() / s
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    private func pivotPoint(in art: CGRect) -> CGPoint {
        CGPoint(x: art.minX + Metric.pivot.x * art.width / Metric.svg.width,
                y: art.minY + Metric.pivot.y * art.height / Metric.svg.height)
    }

    /// The background with Rexie cut out, drawn once (with `holeMargin * 2` of background around the
    /// art). The outline is stroked back in by 0.75 pt so the hole's anti-aliased edge stays under the
    /// art's edge on the first frame.
    private static func holeImage(color: UIColor) -> CGImage? {
        let m = Metric.holeMargin * 2
        let size = CGSize(width: Metric.size.width + 2 * m, height: Metric.size.height + 2 * m)
        let format = UIGraphicsImageRendererFormat()
        format.scale = Metric.holeScale
        format.opaque = false
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let cg = ctx.cgContext
            color.setFill()
            cg.fill(CGRect(origin: .zero, size: size))
            cg.translateBy(x: m, y: m)
            cg.addPath(silhouette)
            cg.setBlendMode(.clear)
            cg.fillPath()
            cg.setBlendMode(.normal)
            cg.addPath(silhouette)
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
        let timeline = StickerPeelTimeline(art: artRect, size: bounds.size, outline: Self.silhouette)
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
        PerfProbe.active?.launchPeelFrames(targets: stats.targets, encode: stats.encode, gpu: stats.gpu, late: stats.late)  // PERF
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
        //     0.00–0.76  Rexie peels from the bottom-left corner toward the top right, curling over itself
        //     0.62–1.00  the loose sticker flies off toward the top right; its shadow fades by 0.92
        //     0.62–1.40  hole grows around the pivot until the app fills the screen; app settles 1.2x -> 1.0x
        //   Core Animation fold (fallback):
        //     0.00–0.60  cutout folds forward about its bottom edge (top toward the viewer), darkening
        //     0.25–0.65  ...and drops past the bottom of the screen, leaving a Rexie-shaped hole
        //     0.45–1.30  hole grows as above
        let irisStart = (metal == nil ? 0.45 : StickerPeelTimeline.flightStart) * k
        let irisDuration = (metal == nil ? 0.85 : 0.78) * k
        if metal == nil { fold(t0: t0) }

        let art = artRect
        let pivot = pivotPoint(in: art)
        let corners = [CGPoint.zero, CGPoint(x: bounds.maxX, y: 0), CGPoint(x: 0, y: bounds.maxY),
                       CGPoint(x: bounds.maxX, y: bounds.maxY)]
        let reach = corners.map { hypot($0.x - pivot.x, $0.y - pivot.y) }.max() ?? 1
        let holeEnd = reach / (Metric.pivotRadius * art.width / Metric.svg.width) * 1.06

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
