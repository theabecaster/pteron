import UIKit

/// What makes the hole Rexie leaves read as a hole, whatever shows through it. The app's canvas is
/// often the splash's own colour, and then a bare cutout is invisible. So the splash is treated as a
/// sheet with some thickness lying over the app, lit from the top left like the sticker:
///
/// - the sheet shades what is under it: a soft shadow inside the hole, deepest under the top-left
///   edges, and a little dimming all over, which lifts as the app comes up through the hole;
/// - the cut edge catches the light: a thin rim just inside the outline, brightest on the far side.
///
/// The shadow gives the depth; the rim is the guarantee. It is light laid over the content, never
/// darker than its own strength, so it stands off the splash colour whatever is behind it
/// (`rimContrast`, tested against every theme). All of it is one bitmap drawn once, a sublayer of
/// the cover, so it scales with the hole and costs one more opaque-free layer for a second.
enum LaunchHoleDepth {
    /// The splash strokes its outline back in by this much (`LaunchSplashView.holeImage`), so the
    /// opening that shows the app starts this far inside Rexie's silhouette.
    static let lip: CGFloat = 0.75

    /// Dimming over the whole opening: the app sits below the sheet, out of the light.
    static let ambient: CGFloat = 0.20
    /// The sheet's shadow on the app, cast down and right, away from the light.
    static let shadowAlpha: CGFloat = 0.55
    static let shadowBlur: CGFloat = 7
    static let shadowOffset = CGSize(width: 2.5, height: 3.5)

    /// The rim's width in points, and its strength on the edges facing away from the light (top
    /// left, the weakest) and toward it (bottom right).
    static let rimWidth: CGFloat = 0.7
    static let rimNear: CGFloat = 0.34
    static let rimFar: CGFloat = 0.62

    /// The least the rim must stand off the splash colour, as a WCAG contrast ratio. 1.0 is no
    /// difference; neighbouring greys in the app's own chrome sit around 1.2.
    static let minimumContrast = 1.8

    // MARK: Colour

    struct RGB: Equatable {
        var r, g, b: Double

        init(r: Double, g: Double, b: Double) {
            self.r = r
            self.g = g
            self.b = b
        }

        init(_ color: UIColor) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            self.init(r: Double(r), g: Double(g), b: Double(b))
        }

        static let black = RGB(r: 0, g: 0, b: 0)
        static let white = RGB(r: 1, g: 1, b: 1)

        /// `top` at `alpha` over this colour, as the compositor blends it (in sRGB values).
        func under(_ top: RGB, alpha: Double) -> RGB {
            RGB(r: r + (top.r - r) * alpha, g: g + (top.g - g) * alpha, b: b + (top.b - b) * alpha)
        }

        /// WCAG relative luminance.
        var luminance: Double {
            func linear(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }

        /// WCAG contrast ratio, 1 to 21.
        func contrast(with other: RGB) -> Double {
            let hi = max(luminance, other.luminance), lo = min(luminance, other.luminance)
            return (hi + 0.05) / (lo + 0.05)
        }
    }

    /// What the app's `content` colour looks like in the opening away from the edges, under the
    /// ambient dimming.
    static func dimmed(_ content: RGB) -> RGB { content.under(.black, alpha: Double(ambient)) }

    /// The rim's colour where it is weakest, over `content` at the foot of the shadow.
    static func rim(over content: RGB) -> RGB {
        content.under(.black, alpha: Double(ambient)).under(.black, alpha: Double(shadowAlpha))
            .under(.white, alpha: Double(rimNear))
    }

    /// How far the weakest part of the rim stands off the splash `cover`, with `content` behind it.
    static func rimContrast(cover: RGB, content: RGB) -> Double {
        rim(over: content).contrast(with: cover)
    }

    // MARK: Drawing

    /// The part of the silhouette the app shows through: the outline less the lip.
    static func opening(in silhouette: CGPath) -> CGPath {
        let edge = silhouette.copy(strokingWithWidth: lip * 2, lineCap: .round, lineJoin: .round, miterLimit: 1)
        return silhouette.subtracting(edge)
    }

    /// The depth bitmap: transparent outside the opening, so it never touches the splash itself.
    /// `margin` of clear space surrounds the art, as in the hole bitmap it lies on. Safe off the
    /// main thread.
    static func image(silhouette: CGPath, size: CGSize, margin: CGFloat, scale: CGFloat) -> CGImage? {
        let full = CGSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        format.preferredRange = .standard
        let opening = opening(in: silhouette)
        return UIGraphicsImageRenderer(size: full, format: format).image { ctx in
            let cg = ctx.cgContext
            cg.translateBy(x: margin, y: margin)
            cg.addPath(opening)
            cg.clip()

            cg.setFillColor(UIColor.black.withAlphaComponent(ambient).cgColor)
            cg.fill(CGRect(origin: .zero, size: size).insetBy(dx: -margin, dy: -margin))

            // The sheet around the opening, filled only so that it casts its shadow into it.
            cg.saveGState()
            cg.setShadow(offset: shadowOffset, blur: shadowBlur, color: UIColor.black.withAlphaComponent(shadowAlpha).cgColor)
            cg.addRect(CGRect(origin: .zero, size: size).insetBy(dx: -margin * 4, dy: -margin * 4))
            cg.addPath(opening)
            cg.setFillColor(UIColor.black.cgColor)
            cg.fillPath(using: .evenOdd)
            cg.restoreGState()

            // The lit edge: the inner half of a stroke along the opening, stronger down and right.
            cg.saveGState()
            cg.addPath(opening.copy(strokingWithWidth: rimWidth * 2, lineCap: .round, lineJoin: .round, miterLimit: 1))
            cg.clip()
            let colors = [UIColor.white.withAlphaComponent(rimNear).cgColor, UIColor.white.withAlphaComponent(rimFar).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]) {
                cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height),
                                      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            cg.restoreGState()
        }.cgImage
    }
}
