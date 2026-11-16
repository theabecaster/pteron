import SwiftUI
import UIKit
import Darwin

extension View {
    /// Covers the app with the launch splash, then turns the app icon into a hole and flies the app
    /// out of it (iris-out). Apply once, to the root view.
    func launchTransition() -> some View { modifier(LaunchTransition()) }
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
            splash.run(content: window.rootViewController?.view) { finish?() }
        }
    }
}

/// UIKit splash drawn with plain layers so the whole transition runs in the render server
/// (Core Animation), unaffected by main-thread work while the app connects underneath.
///
/// Layers (bottom to top): `cover` (the background with an icon-shaped hole, drawn as a huge rounded
/// border so it needs no mask or offscreen pass), `row` (Rexie + "for Rex"), `icon`. The icon and row
/// are crops of the static launch image (`LaunchSplash`), placed on the same pixel grid, so the first
/// frame matches the launch screen exactly.
final class LaunchSplashView: UIView {
    private enum Metric {
        static let icon: CGFloat = 128
        static let iconRadius: CGFloat = 128 * 0.2237
        static let row = CGSize(width: 264, height: 40)
        static let rowOffset: CGFloat = 112   // row center below screen center
        static let holeStart: CGFloat = 0.9   // hole hides under the icon until the icon shrinks to it
    }

    private let cover = CALayer()
    private let icon = CALayer()
    private let row = CALayer()
    private var border: CGFloat = 0

    /// Minimum time from process start to the transition, so the splash never lingers.
    static let minimumSplash: CFTimeInterval = 0.6

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundColor = .clear
        accessibilityElementsHidden = true

        let bg = UIColor(named: "LaunchBackground") ?? UIColor(red: 0x22 / 255, green: 0x27 / 255, blue: 0x2e / 255, alpha: 1)
        cover.borderColor = bg.cgColor
        cover.cornerCurve = .circular
        for (l, name) in [(icon, "SplashIcon"), (row, "SplashRow")] {
            if let img = UIImage(named: name) {
                l.contents = img.cgImage
                l.contentsScale = img.scale
            }
            l.contentsGravity = .resize
        }
        layer.addSublayer(cover)
        layer.addSublayer(row)
        layer.addSublayer(icon)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        // bounds + position, not frame: frame would fold in the icon's scale transform once it runs.
        place(icon, pixelRect(center: c, size: CGSize(width: Metric.icon, height: Metric.icon)))
        place(row, pixelRect(center: CGPoint(x: c.x, y: c.y + Metric.rowOffset), size: Metric.row))
        // The hole is the inside of a border this wide; its outer edge stays past the screen corners
        // even at the smallest hole scale.
        border = hypot(bounds.width, bounds.height)
        let side = Metric.icon + border * 2
        let t = cover.transform
        cover.transform = CATransform3DIdentity
        cover.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        cover.position = icon.position
        cover.borderWidth = border
        cover.cornerRadius = border + Metric.iconRadius
        cover.transform = CATransform3DEqualToTransform(t, CATransform3DIdentity)
            ? CATransform3DMakeScale(Metric.holeStart, Metric.holeStart, 1) : t
        CATransaction.commit()
    }

    private func place(_ l: CALayer, _ r: CGRect) {
        l.bounds = CGRect(origin: .zero, size: r.size)
        l.position = CGPoint(x: r.midX, y: r.midY)
    }

    private func pixelRect(center: CGPoint, size: CGSize) -> CGRect {
        let s = max(traitCollection.displayScale, 1)
        let x = ((center.x - size.width / 2) * s).rounded() / s
        let y = ((center.y - size.height / 2) * s).rounded() / s
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    /// Schedules the whole transition up front on Core Animation's clock, then removes itself.
    func run(content: UIView?, completion: @escaping () -> Void) {
        let elapsed = Self.processUptime() ?? 0
        let delay = max(Self.minimumSplash - elapsed, 0.12)
        let t0 = CACurrentMediaTime() + delay

        if UIAccessibility.isReduceMotionEnabled {
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                self?.removeFromSuperview()
                completion()
            }
            layer.add(anim("opacity", from: 1, to: 0, start: t0, duration: 0.3, .easeInEaseOut), forKey: "fade")
            layer.opacity = 0
            CATransaction.commit()
            return
        }

        // Timeline (seconds after t0):
        //   0.00–0.20  icon dips to the hole size; Rexie and the label drop away
        //   0.10–0.26  icon fades, leaving an icon-shaped hole onto the live app (at 1.2x)
        //   0.22–0.84  hole irises out past the screen corners; app settles 1.2x -> 1.0x
        let holeEnd = hypot(bounds.width, bounds.height) / (Metric.icon * 0.98) + 0.2
        let irisStart = 0.22, irisDuration = 0.62

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

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            self?.removeFromSuperview()
            completion()
        }

        let dip = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
        icon.add(anim("transform.scale", from: 1, to: Metric.holeStart, start: t0, duration: 0.2, dip), forKey: "dip")
        icon.add(anim("opacity", from: 1, to: 0, start: t0 + 0.1, duration: 0.16, .easeIn), forKey: "fade")
        icon.transform = CATransform3DMakeScale(Metric.holeStart, Metric.holeStart, 1)
        icon.opacity = 0

        row.add(anim("opacity", from: 1, to: 0, start: t0, duration: 0.18, .easeIn), forKey: "fade")
        row.add(anim("transform.translation.y", from: 0, to: 10, start: t0, duration: 0.2, .easeIn), forKey: "drop")
        row.opacity = 0

        // Zooming reads as constant speed when the scale moves evenly in log space, so the keyframes ease
        // the exponent (smoothstep): the hole opens gently, rushes through the screen edges, then lands.
        let iris = CAKeyframeAnimation(keyPath: "transform.scale")
        let steps = 48
        let span = log(holeEnd / Metric.holeStart)
        iris.values = (0...steps).map { i -> CGFloat in
            let u = CGFloat(i) / CGFloat(steps)
            return Metric.holeStart * exp(span * u * u * (3 - 2 * u))
        }
        iris.calculationMode = .linear
        iris.beginTime = t0 + irisStart
        iris.duration = irisDuration
        iris.fillMode = .backwards
        cover.add(iris, forKey: "iris")
        cover.transform = CATransform3DMakeScale(holeEnd, holeEnd, 1)
        CATransaction.commit()
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
    private static func processUptime() -> CFTimeInterval? {
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
