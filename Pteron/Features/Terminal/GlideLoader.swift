import UIKit

/// When the loader shows and how it moves.
struct GlideLoaderTiming: Equatable {
    /// A pane that has its first frame sooner never shows the loader.
    var delay: CFTimeInterval = 0.4
    var fadeIn: CFTimeInterval = 0.18
    /// The cross-fade out when the pane's first frame is there.
    var fadeOut: CFTimeInterval = 0.15
    /// One trip of the stroke along the outline.
    var loop: CFTimeInterval = 1.2
    /// Reduce Motion: one half of the still mark's slow breath.
    var breath: CFTimeInterval = 1.8
}

/// Glide, small, while a pane that has nothing to draw yet waits for its first screen: a cold
/// open, or a fresh start with no old screen to keep. Never over a screen: a pane that comes
/// back from the park, or opens within `timing.delay`, shows none.
///
/// Its motion is its own, not the launch's peel or fold: Glide's outline, faint, with a soft
/// stroke that glides along it once per loop. The body itself never turns or moves. With
/// Reduce Motion the mark holds still and breathes slowly.
///
/// Core Animation runs all of it in the render server: the delay, the fade and the loop are
/// animations added once, so the main thread does nothing per frame, and a pane that opens fast
/// pays for one view that was never visible.
final class GlideLoader: UIView {
    /// The mark's width in points; its height follows the art.
    nonisolated static let width: CGFloat = 44
    nonisolated static let markSize = CGSize(width: width, height: (width * LaunchArt.size.height / LaunchArt.size.width).rounded())

    /// One animation of the loader, as its layer gets it. Tests read these.
    struct Motion: Equatable {
        var layer: String
        var keyPath: String
        /// Seconds after the loader was made.
        var begin: CFTimeInterval
        var duration: CFTimeInterval
        var repeats: Bool
    }

    /// Everything that moves in a loader.
    static func motions(still: Bool, timing: GlideLoaderTiming) -> [Motion] {
        var m = [Motion(layer: "loader", keyPath: "opacity", begin: timing.delay, duration: timing.fadeIn, repeats: false)]
        if still {
            m.append(Motion(layer: "mark", keyPath: "opacity", begin: timing.delay, duration: timing.breath, repeats: true))
        } else {
            m.append(Motion(layer: "glide", keyPath: "strokeEnd", begin: timing.delay, duration: timing.loop, repeats: true))
            m.append(Motion(layer: "glide", keyPath: "strokeStart", begin: timing.delay, duration: timing.loop, repeats: true))
        }
        return m
    }

    private nonisolated static let scale = CGAffineTransform(scaleX: markSize.width / LaunchArt.size.width, y: markSize.height / LaunchArt.size.height)

    /// The outline in the mark's own points: `LaunchArt.silhouette`, scaled to `markSize`.
    static let outline: CGPath = {
        var t = scale
        return LaunchArt.silhouette.copy(using: &t) ?? LaunchArt.silhouette
    }()

    /// Glide's eye: the second subpath of Brand/glyph.svg, scaled as the outline is.
    static let eye: CGPath = {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { LaunchArt.point(x, y).applying(scale) }
        let e = CGMutablePath()
        e.move(to: p(632.95, 407.69))
        e.addCurve(to: p(661.16, 392.87), control1: p(644.14, 407.48), control2: p(654.46, 401.73))
        e.addCurve(to: p(670.05, 360.28), control1: p(668.14, 383.63), control2: p(671.01, 371.73))
        e.addCurve(to: p(657.41, 330.37), control1: p(669.14, 349.32), control2: p(664.76, 338.60))
        e.addCurve(to: p(627.05, 316.31), control1: p(649.73, 321.78), control2: p(638.73, 316.09))
        e.addCurve(to: p(598.84, 331.13), control1: p(615.86, 316.52), control2: p(605.54, 322.27))
        e.addCurve(to: p(589.95, 363.72), control1: p(591.86, 340.37), control2: p(588.99, 352.27))
        e.addCurve(to: p(602.59, 393.63), control1: p(590.86, 374.68), control2: p(595.24, 385.40))
        e.addCurve(to: p(632.95, 407.69), control1: p(610.27, 402.22), control2: p(621.27, 407.91))
        e.closeSubpath()
        return e
    }()

    let still: Bool
    let timing: GlideLoaderTiming
    private let mark = CALayer()
    private let body = CAShapeLayer()
    private let eyeLayer = CAShapeLayer()
    private let glide = CAShapeLayer()
    private(set) var leaving = false

    /// `tint`: the theme's text color; everything is drawn in it, at a few strengths.
    init(tint: UIColor, still: Bool, timing: GlideLoaderTiming = GlideLoaderTiming()) {
        self.still = still
        self.timing = timing
        super.init(frame: CGRect(origin: .zero, size: Self.markSize))
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        mark.frame = bounds
        layer.addSublayer(mark)
        for shape in [body, eyeLayer, glide] {
            shape.frame = mark.bounds
            shape.contentsScale = UIScreen.main.scale
            mark.addSublayer(shape)
        }
        body.path = Self.outline
        body.lineWidth = 1
        body.lineJoin = .round
        eyeLayer.path = Self.eye
        glide.path = Self.outline
        glide.fillColor = nil
        glide.lineWidth = 1.75
        glide.lineCap = .round
        glide.lineJoin = .round
        // The stroke's soft edge.
        glide.shadowOffset = .zero
        glide.shadowRadius = 2.5
        glide.shadowOpacity = 0.55
        glide.isHidden = still
        apply(tint: tint)
        start(at: CACurrentMediaTime())
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(tint: UIColor) {
        body.fillColor = tint.withAlphaComponent(0.07).cgColor
        body.strokeColor = tint.withAlphaComponent(still ? 0.55 : 0.24).cgColor
        eyeLayer.fillColor = tint.withAlphaComponent(still ? 0.55 : 0.4).cgColor
        glide.strokeColor = tint.withAlphaComponent(0.92).cgColor
        glide.shadowColor = tint.cgColor
    }

    /// The animations' keys by layer, for tests: what `motions` promises is what was added.
    var addedMotions: [String: [String]] {
        ["loader": layer.animationKeys() ?? [], "mark": mark.animationKeys() ?? [], "glide": glide.animationKeys() ?? []]
    }

    private func start(at now: CFTimeInterval) {
        // The model value stays 0, so the loader is invisible until its delay has passed.
        layer.opacity = 0
        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = 0
        show.toValue = 1
        show.beginTime = now + timing.delay
        show.duration = timing.fadeIn
        show.timingFunction = CAMediaTimingFunction(name: .easeOut)
        show.fillMode = .forwards
        show.isRemovedOnCompletion = false
        layer.add(show, forKey: "show")

        let ease = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.25, 1)
        if still {
            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 1
            breathe.toValue = 0.45
            breathe.beginTime = now + timing.delay
            breathe.duration = timing.breath
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            mark.add(breathe, forKey: "opacity")
            return
        }
        // The stroke runs ahead and its tail follows: it grows out of the start, glides along
        // the outline and closes on itself, then starts again.
        glide.strokeStart = 0
        glide.strokeEnd = 0
        let head = CAKeyframeAnimation(keyPath: "strokeEnd")
        head.values = [0, 1, 1]
        head.keyTimes = [0, 0.72, 1]
        head.timingFunctions = [ease, CAMediaTimingFunction(name: .linear)]
        let tail = CAKeyframeAnimation(keyPath: "strokeStart")
        tail.values = [0, 0, 1]
        tail.keyTimes = [0, 0.26, 1]
        tail.timingFunctions = [CAMediaTimingFunction(name: .linear), ease]
        for a in [head, tail] {
            a.beginTime = now + timing.delay
            a.duration = timing.loop
            a.repeatCount = .infinity
            glide.add(a, forKey: a.keyPath)
        }
    }

    /// The pane's first frame is there: fades out from whatever it shows now and removes
    /// itself. A loader that never became visible goes at once.
    func dismiss() {
        guard !leaving else { return }
        leaving = true
        let shown = layer.presentation()?.opacity ?? 0
        layer.removeAnimation(forKey: "show")
        layer.opacity = 0
        guard shown > 0.01 else { return removeFromSuperview() }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.removeFromSuperview() }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = shown
        fade.toValue = 0
        fade.duration = timing.fadeOut
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        layer.add(fade, forKey: "hide")
        CATransaction.commit()
    }

    /// Holds the loader in one moment of its loop, with no animation left, for a still picture:
    /// fully faded in, the stroke between `strokeStart` and `strokeEnd` of the outline.
    func pose(strokeStart: CGFloat, strokeEnd: CGFloat) {
        for l in [layer, mark, glide] { l.removeAllAnimations() }
        layer.opacity = 1
        glide.strokeStart = strokeStart
        glide.strokeEnd = strokeEnd
    }
}
