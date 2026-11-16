import UIKit

/// The copy-on-select flourish, as in the Rex Mac app: a soft wash lights the selection, a slanted
/// sheen sweeps across it, then everything fades. Pure Core Animation (render-server side), masked
/// to the selection's rectangles; the layers remove themselves when done.
@MainActor
enum SelectionShimmer {
    static let sweep: CFTimeInterval = 0.46
    static let total: CFTimeInterval = 0.72

    /// `rects` are in `layer`'s coordinates (one per selected line segment).
    static func play(on layer: CALayer, rects: [CGRect], dark: Bool) {
        let rects = rects.filter { $0.width > 0.5 && $0.height > 0.5 }
        guard var union = rects.first else { return }
        for r in rects.dropFirst() { union = union.union(r) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let container = CALayer()
        container.frame = union
        container.zPosition = 10
        container.allowsGroupOpacity = true
        let mask = CAShapeLayer()
        let path = CGMutablePath()
        for r in rects {
            path.addRoundedRect(in: r.offsetBy(dx: -union.minX, dy: -union.minY), cornerWidth: 2.5, cornerHeight: 2.5)
        }
        mask.path = path
        container.mask = mask

        // A brief wash over the whole selection.
        let wash = CALayer()
        wash.frame = container.bounds
        wash.backgroundColor = UIColor.white.withAlphaComponent(dark ? 0.14 : 0.30).cgColor
        wash.opacity = 0
        container.addSublayer(wash)

        let reduceMotion = UIAccessibility.isReduceMotionEnabled
        var band: CAGradientLayer?
        if !reduceMotion {
            // The sheen: a slanted light band, wider on wide selections, swept left to right.
            let g = CAGradientLayer()
            let w = min(max(union.width * 0.38, 56), 200)
            let peak = UIColor.white.withAlphaComponent(dark ? 0.55 : 0.85)
            g.colors = [UIColor.white.withAlphaComponent(0).cgColor, peak.cgColor, UIColor.white.withAlphaComponent(0).cgColor]
            g.locations = [0, 0.5, 1]
            // Mostly horizontal, tilted so the band leans like a glint.
            g.startPoint = CGPoint(x: 0, y: 0.32)
            g.endPoint = CGPoint(x: 1, y: 0.68)
            g.frame = CGRect(x: -w, y: 0, width: w, height: union.height)
            container.addSublayer(g)
            band = g
        }
        layer.addSublayer(container)
        CATransaction.commit()

        let now = CACurrentMediaTime()
        let duration = reduceMotion ? 0.4 : total

        let washAnim = CAKeyframeAnimation(keyPath: "opacity")
        washAnim.values = [0, 1, 1, 0]
        washAnim.keyTimes = [0, 0.14, 0.55, 1]
        washAnim.duration = duration
        washAnim.beginTime = now
        washAnim.fillMode = .both
        washAnim.isRemovedOnCompletion = false
        wash.add(washAnim, forKey: "wash")

        if let band {
            let move = CABasicAnimation(keyPath: "position.x")
            move.fromValue = -band.bounds.width / 2
            move.toValue = union.width + band.bounds.width / 2
            move.duration = sweep
            move.beginTime = now
            move.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            move.fillMode = .both
            move.isRemovedOnCompletion = false
            band.add(move, forKey: "sweep")
        }

        // A barely-there pulse, like the Mac's selection scale.
        if !reduceMotion {
            let pulse = CAKeyframeAnimation(keyPath: "transform.scale")
            pulse.values = [1, 1.012, 1]
            pulse.keyTimes = [0, 0.3, 1]
            pulse.duration = sweep
            pulse.beginTime = now
            container.add(pulse, forKey: "pulse")
        }

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = now + duration * 0.6
        fade.duration = duration * 0.4
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        container.add(fade, forKey: "fade")

        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            container.removeFromSuperlayer()
        }
    }
}
