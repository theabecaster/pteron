import UIKit

/// The colors of a pane's status chip ("Reconnecting…", "Resized elsewhere · tap to fit here").
///
/// The chip is the theme's text on the theme's background leaned 15% toward the text: what the
/// text color at 15% over a plain background showed, now opaque. Terminal output under the chip
/// no longer shows through, so the text keeps the same contrast over busy or colored output and
/// a selection as over an empty line. A hairline rim of the text color marks the chip's edge where
/// the output under it is close to its fill. Flat colors: nothing under the chip is sampled or
/// blurred, so it costs the terminal no frames.
struct StatusChipStyle {
    /// How far the fill leans from the background toward the text.
    static let tint: CGFloat = 0.15
    /// The rim's opacity, drawn over the fill.
    static let rimAlpha: CGFloat = 0.25

    let fill: UIColor
    let text: UIColor
    let rim: UIColor

    init(theme: TermTheme) {
        text = theme.uiFG
        fill = Self.mix(theme.uiBG, theme.uiFG, by: Self.tint)
        rim = theme.uiFG.withAlphaComponent(Self.rimAlpha)
    }

    /// `a` moved `t` of the way to `b`, opaque, in sRGB as a layer composites.
    static func mix(_ a: UIColor, _ b: UIColor, by t: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: 1)
    }
}
