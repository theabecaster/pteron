import SwiftUI
import UIKit

/// The offline screen's backdrop: TV static as if the signal were barely getting through. Grain,
/// scanlines, a slow rolling band and, now and then, a torn line with a red and cyan fringe, all in
/// the theme's colors.
///
/// Everything runs as Core Animation on the render server: one pre-rendered noise texture, shifted by
/// a discrete `contentsRect` animation, plus a few layers on looping keyframes. Nothing runs on the
/// main thread per frame, the view never takes touches, and the animations are removed while it's
/// off screen. With Reduce Motion the grain and scanlines hold still.
struct SignalStatic: UIViewRepresentable {
    enum Level: Equatable {
        /// Waiting between retries.
        case idle
        /// The user asked to try again: the static rises.
        case searching
        /// Connected again: the static settles before the app takes over.
        case locked
    }

    var theme: TermTheme
    var level: Level = .idle

    func makeUIView(context: Context) -> SignalStaticView { SignalStaticView() }

    func updateUIView(_ v: SignalStaticView, context: Context) {
        v.configure(SignalStaticView.Palette(theme), level: level)
    }
}

final class SignalStaticView: UIView {
    struct Palette: Equatable {
        var grain: UIColor
        var chromaA: UIColor
        var chromaB: UIColor
        var dark: Bool

        init(_ t: TermTheme) {
            grain = t.uiFG
            chromaA = UIColor(hex: t.ansi[safe: 1] ?? "#f47067")
            chromaB = UIColor(hex: t.ansi[safe: 6] ?? "#39c5cf")
            dark = t.isDark
        }
    }

    /// Noise texture side, in pixels. One texel draws as `grain` points.
    private static let side = 512
    private static let grain: CGFloat = 2
    /// Frames of grain per second, and how many distinct offsets one loop steps through.
    private static let fps: Double = 14
    private static let frames = 24

    private let noise = CALayer()
    private let scan = CALayer()
    private let roll = CAGradientLayer()
    private let tears = [CALayer(), CALayer()]
    private let fringes = [(CALayer(), CALayer()), (CALayer(), CALayer())]

    private var palette: Palette?
    private var level: SignalStatic.Level = .idle
    private var builtFor: CGSize = .zero
    private var reduceMotion = UIAccessibility.isReduceMotionEnabled

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        clipsToBounds = true
        for l in [noise, scan, roll] { layer.addSublayer(l) }
        noise.magnificationFilter = .nearest
        noise.minificationFilter = .nearest
        for (i, t) in tears.enumerated() {
            t.magnificationFilter = .nearest
            t.opacity = 0
            t.addSublayer(fringes[i].0)
            t.addSublayer(fringes[i].1)
            layer.addSublayer(t)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(motionChanged),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ p: Palette, level: SignalStatic.Level) {
        if p != palette {
            palette = p
            applyPalette(p)
        }
        if level != self.level {
            self.level = level
            applyLevel(animated: window != nil)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != builtFor, bounds.width > 0, bounds.height > 0 else { return }
        builtFor = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        noise.frame = bounds
        scan.frame = bounds
        roll.frame = CGRect(x: 0, y: -160, width: bounds.width, height: 160)
        for (i, t) in tears.enumerated() {
            let h: CGFloat = i == 0 ? 10 : 4
            t.frame = CGRect(x: 0, y: 0, width: bounds.width, height: h)
            fringes[i].0.frame = CGRect(x: -3, y: 0, width: bounds.width, height: h * 0.5)
            fringes[i].1.frame = CGRect(x: 3, y: h * 0.5, width: bounds.width, height: h * 0.5)
        }
        CATransaction.commit()
        restartAnimations()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Off screen: nothing to animate.
        restartAnimations()
    }

    @objc private func motionChanged() {
        reduceMotion = UIAccessibility.isReduceMotionEnabled
        restartAnimations()
    }

    // MARK: Look

    private func applyPalette(_ p: Palette) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let maxAlpha: CGFloat = p.dark ? 0.26 : 0.20
        let side = Self.side
        let color = p.grain
        // About 1 MB of random bytes: made off the main thread, then handed to the layer.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let img = Self.noiseImage(color: color, maxAlpha: maxAlpha, side: side)
            DispatchQueue.main.async {
                guard let self, self.palette == p else { return }
                self.noise.contents = img
                for t in self.tears { t.contents = img }
            }
        }
        scan.backgroundColor = Self.scanlinePattern(dark: p.dark).map { UIColor(patternImage: $0).cgColor }
        scan.opacity = 1
        let band = p.grain.withAlphaComponent(p.dark ? 0.07 : 0.05).cgColor
        roll.colors = [p.grain.withAlphaComponent(0).cgColor, band, p.grain.withAlphaComponent(0).cgColor]
        for (a, b) in fringes {
            a.backgroundColor = p.chromaA.withAlphaComponent(p.dark ? 0.45 : 0.35).cgColor
            b.backgroundColor = p.chromaB.withAlphaComponent(p.dark ? 0.45 : 0.35).cgColor
            a.compositingFilter = p.dark ? "screenBlendMode" : "multiplyBlendMode"
            b.compositingFilter = p.dark ? "screenBlendMode" : "multiplyBlendMode"
        }
        CATransaction.commit()
        applyLevel(animated: false)
    }

    private func applyLevel(animated: Bool) {
        let target: Float
        switch level {
        case .idle: target = 0.8
        case .searching: target = 1
        case .locked: target = 0.2
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 0.35 : 0)
        CATransaction.setDisableActions(!animated)
        layer.opacity = target
        CATransaction.commit()
    }

    // MARK: Motion

    private func restartAnimations() {
        for l in [noise, roll] + tears { l.removeAllAnimations() }
        guard bounds.width > 0 else { return }
        let window = grainWindow()
        noise.contentsRect = window.size == .zero ? CGRect(x: 0, y: 0, width: 1, height: 1) : window
        guard self.window != nil, !reduceMotion else { return }

        var rng = SplitMix(seed: 0x5EED)
        // Grain: jump to a new random window into the texture each frame. Discrete, so the GPU just
        // samples a different region; no new pixels are made.
        let jump = CAKeyframeAnimation(keyPath: "contentsRect")
        jump.values = (0..<Self.frames).map { _ in NSValue(cgRect: randomWindow(window.size, &rng)) }
        jump.calculationMode = .discrete
        jump.duration = Double(Self.frames) / Self.fps
        jump.repeatCount = .infinity
        noise.add(jump, forKey: "grain")

        // A faint band rolls down the screen, like a misaligned vertical hold.
        let r = CABasicAnimation(keyPath: "position.y")
        r.fromValue = -80
        r.toValue = bounds.height + 80
        r.duration = 7
        r.repeatCount = .infinity
        roll.add(r, forKey: "roll")

        // Tears: a torn strip of grain flashes sideways for a few frames. Two layers on different
        // periods, three events each, so the pattern doesn't read as a loop.
        let periods: [Double] = [9.7, 6.1]
        for (i, t) in tears.enumerated() {
            t.contentsRect = randomWindow(CGSize(width: window.width, height: window.height * t.bounds.height / max(bounds.height, 1)), &rng)
            var times: [NSNumber] = [0]
            var opacity: [Float] = [0]
            var x: [CGFloat] = [bounds.midX]
            var y: [CGFloat] = [bounds.midY]
            let events = 3
            for e in 0..<events {
                let start = (Double(e) + 0.3 + rng.unit() * 0.5) / Double(events)
                let yy = bounds.height * CGFloat(0.12 + rng.unit() * 0.76)
                let shift = CGFloat(10 + rng.unit() * 22) * (rng.unit() < 0.5 ? -1 : 1)
                let step = 0.07 / periods[i]
                times += [start, start + step, start + 2 * step, start + 3 * step].map { NSNumber(value: min($0, 0.999)) }
                opacity += [0.9, 0.6, 0.85, 0]
                x += [bounds.midX + shift, bounds.midX - shift * 0.5, bounds.midX + shift * 0.3, bounds.midX]
                y += [yy, yy + 3, yy - 2, yy]
            }
            times.append(1)
            opacity.append(0)
            x.append(bounds.midX)
            y.append(bounds.midY)

            func track(_ key: String, _ values: [Any]) -> CAKeyframeAnimation {
                let a = CAKeyframeAnimation(keyPath: key)
                a.values = values
                a.keyTimes = times
                a.calculationMode = .discrete
                return a
            }
            let g = CAAnimationGroup()
            g.animations = [track("opacity", opacity), track("position.x", x), track("position.y", y)]
            g.duration = periods[i]
            g.repeatCount = .infinity
            t.add(g, forKey: "tear")
        }
    }

    /// The part of the texture one screen of grain shows, in unit coordinates.
    private func grainWindow() -> CGRect {
        let w = min(bounds.width / Self.grain / CGFloat(Self.side), 1)
        let h = min(bounds.height / Self.grain / CGFloat(Self.side), 1)
        return CGRect(x: 0, y: 0, width: w, height: h)
    }

    private func randomWindow(_ size: CGSize, _ rng: inout SplitMix) -> CGRect {
        CGRect(x: CGFloat(rng.unit()) * (1 - size.width), y: CGFloat(rng.unit()) * (1 - size.height),
               width: size.width, height: size.height)
    }

    // MARK: Textures

    /// Premultiplied grain in one color: mostly faint, a few bright specks.
    nonisolated private static func noiseImage(color: UIColor, maxAlpha: CGFloat, side: Int) -> CGImage? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        var rng = SplitMix(seed: 0xC0FFEE)
        bytes.withUnsafeMutableBufferPointer { px in
            for i in 0..<(side * side) {
                let u = rng.unit()
                let alpha = CGFloat(u * u * u) * maxAlpha
                px[i * 4 + 0] = UInt8(b * alpha * 255)
                px[i * 4 + 1] = UInt8(g * alpha * 255)
                px[i * 4 + 2] = UInt8(r * alpha * 255)
                px[i * 4 + 3] = UInt8(alpha * 255)
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                       space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// A 1 × 3 pt tile: one dim line every three points.
    private static func scanlinePattern(dark: Bool) -> UIImage? {
        let f = UIGraphicsImageRendererFormat()
        f.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 1, height: 3), format: f).image { ctx in
            (dark ? UIColor.black.withAlphaComponent(0.28) : UIColor.black.withAlphaComponent(0.06)).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }
    }
}

/// Seeded and cheap: the same grain every launch, no system RNG in a tight loop.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

// MARK: - Glyph

/// The screen's symbol, with a red and a cyan ghost that slip out of register now and then, as if
/// the picture were losing sync. The symbol itself never moves. Core Animation only; still with
/// Reduce Motion.
struct GlitchGlyph: UIViewRepresentable {
    var symbol: String
    var theme: TermTheme
    var size: CGFloat = 44

    func makeUIView(context: Context) -> GlitchGlyphView { GlitchGlyphView() }

    func updateUIView(_ v: GlitchGlyphView, context: Context) {
        v.configure(symbol: symbol, color: theme.uiFG.withAlphaComponent(0.85),
                    chromaA: UIColor(hex: theme.ansi[safe: 1] ?? "#f47067"),
                    chromaB: UIColor(hex: theme.ansi[safe: 6] ?? "#39c5cf"), size: size)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: GlitchGlyphView, context: Context) -> CGSize? {
        CGSize(width: size * 1.6, height: size * 1.25)
    }
}

final class GlitchGlyphView: UIView {
    private let main = CALayer()
    private let ghostA = CALayer()
    private let ghostB = CALayer()
    private var key = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for l in [ghostA, ghostB, main] {
            l.contentsGravity = .resizeAspect
            layer.addSublayer(l)
        }
        ghostA.opacity = 0
        ghostB.opacity = 0
        NotificationCenter.default.addObserver(self, selector: #selector(restart),
                                               name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(symbol: String, color: UIColor, chromaA: UIColor, chromaB: UIColor, size: CGFloat) {
        let k = "\(symbol)|\(color)|\(chromaA)|\(chromaB)|\(size)|\(traitCollection.displayScale)"
        guard k != key else { return }
        key = k
        let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: .light)
        func img(_ c: UIColor) -> CGImage? {
            UIImage(systemName: symbol, withConfiguration: cfg)?.withTintColor(c, renderingMode: .alwaysOriginal)
                .pngData().flatMap { UIImage(data: $0, scale: traitCollection.displayScale)?.cgImage }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        main.contents = img(color)
        ghostA.contents = img(chromaA)
        ghostB.contents = img(chromaB)
        for l in [main, ghostA, ghostB] { l.contentsScale = traitCollection.displayScale }
        CATransaction.commit()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for l in [main, ghostA, ghostB] { l.frame = bounds }
        CATransaction.commit()
        restart()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restart()
    }

    @objc private func restart() {
        for l in [ghostA, ghostB] { l.removeAllAnimations() }
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        // Two slips per loop: quick, a few frames each.
        let period = 4.3
        let times: [NSNumber] = [0, 0.40, 0.41, 0.43, 0.45, 0.80, 0.81, 0.83, 1].map { NSNumber(value: $0) }
        for (l, dir) in [(ghostA, -1.0), (ghostB, 1.0)] {
            let o = CAKeyframeAnimation(keyPath: "opacity")
            o.values = [0, 0, 0.8, 0.5, 0, 0, 0.7, 0, 0]
            let x = CAKeyframeAnimation(keyPath: "transform.translation.x")
            x.values = [0, 0, 3 * dir, -2 * dir, 0, 0, 2 * dir, 0, 0]
            for a in [o, x] { a.keyTimes = times; a.calculationMode = .discrete }
            let g = CAAnimationGroup()
            g.animations = [o, x]
            g.duration = period
            g.repeatCount = .infinity
            l.add(g, forKey: "slip")
        }
    }
}
