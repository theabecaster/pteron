import Testing
import UIKit
@testable import RexDuo

/// The status chip reads the same over any output: its fill is opaque, so the contrast between
/// its text and its fill is the contrast over anything, and it holds WCAG AA in every theme.
struct StatusChipTests {
    private func components(_ c: UIColor) -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }

    /// WCAG 2 relative luminance.
    private func luminance(_ c: UIColor) -> Double {
        func lin(_ v: CGFloat) -> Double {
            let v = Double(v)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        let p = components(c)
        return 0.2126 * lin(p.r) + 0.7152 * lin(p.g) + 0.0722 * lin(p.b)
    }

    private func contrast(_ a: UIColor, _ b: UIColor) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    @Test func fillIsOpaque() {
        for theme in ThemeStore.all {
            #expect(components(StatusChipStyle(theme: theme).fill).a == 1, "\(theme.id)")
        }
    }

    @Test func textMeetsAAInEveryTheme() {
        #expect(ThemeStore.all.count > 1)
        for theme in ThemeStore.all {
            let chip = StatusChipStyle(theme: theme)
            #expect(contrast(chip.text, chip.fill) >= 4.5, "\(theme.id): \(contrast(chip.text, chip.fill))")
        }
    }

    /// On a plain background the chip looks as the text color at 15% over it did.
    @Test func fillIsTheOldTintOverTheBackground() {
        let theme = ThemeStore.fallback
        let fill = components(StatusChipStyle(theme: theme).fill)
        let bg = components(theme.uiBG), fg = components(theme.uiFG)
        #expect(abs(fill.r - (bg.r * 0.85 + fg.r * 0.15)) < 0.001)
        #expect(abs(fill.g - (bg.g * 0.85 + fg.g * 0.15)) < 0.001)
        #expect(abs(fill.b - (bg.b * 0.85 + fg.b * 0.15)) < 0.001)
    }
}
