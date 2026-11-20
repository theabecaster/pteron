import GlanceModel
import SwiftUI
import Testing
@testable import GlanceUI

/// Colors are compared as resolved values: two `Color`s built in different ways are not `==`
/// even when they draw the same.
@Suite struct GlancePaletteTests {
    private func resolved(_ c: Color, _ scheme: ColorScheme = .dark) -> Color.Resolved {
        var env = EnvironmentValues()
        env.colorScheme = scheme
        return c.resolve(in: env)
    }

    private func same(_ a: Color, _ b: Color, _ note: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
        for scheme in [ColorScheme.dark, .light] {
            let x = resolved(a, scheme), y = resolved(b, scheme)
            let close = abs(x.red - y.red) < 1e-4 && abs(x.green - y.green) < 1e-4 && abs(x.blue - y.blue) < 1e-4
                && abs(x.opacity - y.opacity) < 1e-4
            #expect(close, "\(note): \(x) vs \(y)", sourceLocation: sourceLocation)
        }
    }

    private func hex(_ s: String) -> Color {
        let c = GlancePalette.rgb(s)
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    @Test func hexIsRead() {
        #expect(GlancePalette.rgb("#ffffff") == (1, 1, 1))
        #expect(GlancePalette.rgb("000000") == (0, 0, 0))
        #expect(GlancePalette.rgb("#c69026").r == Double(0xc6) / 255)
        #expect(GlancePalette.rgb("#c69026").g == Double(0x90) / 255)
        #expect(GlancePalette.rgb("#c69026").b == Double(0x26) / 255)
        #expect(GlancePalette.rgb("#f80") == (1, Double(0x88) / 255, 0))
        #expect(GlancePalette.rgb("nonsense") == (0, 0, 0))
    }

    /// The chrome is the app's arithmetic, keyed on the theme's own appearance.
    @Test func theChromeFollowsTheThemesOwnAppearance() {
        for p in [GlancePalette.standardDark, .standardLight] {
            let c = GlanceColors(p)
            let toward: Color = p.isDark ? .black : .white
            same(c.canvas, hex(p.bg).mix(with: toward, by: p.isDark ? 0.28 : 0.08), "canvas \(p.appearance)")
            same(c.sidebar, hex(p.bg).mix(with: toward, by: p.isDark ? 0.18 : 0.04), "sidebar \(p.appearance)")
            same(c.secondary, hex(p.fg).opacity(0.55), "secondary")
            same(c.tertiary, hex(p.fg).opacity(0.35), "tertiary")
            same(c.blocked, hex(p.ansi[3])); same(c.error, hex(p.ansi[1]))
            same(c.working, hex(p.ansi[4])); same(c.done, hex(p.ansi[2]))
            #expect(c.scheme == (p.isDark ? .dark : .light))
        }
        // A dark canvas is darker than its background, a light one stays light.
        #expect(resolved(GlanceColors(.standardDark).canvas).red < resolved(hex("#22272e")).red)
        #expect(resolved(GlanceColors(.standardLight).canvas).red > 0.99)
    }

    /// Each slot draws the theme it holds, whichever mode it serves: a light theme in the dark
    /// slot is drawn light, and a dark theme in the light slot dark.
    @Test func aSlotDrawsItsThemeAsTheThemeIs() {
        let themes = [GlancePalette.standardDark, .standardLight]
        for dark in themes {
            for light in themes {
                let palette = GlanceSnapshot.Palette(dark: dark, light: light)
                for (system, held) in [(ColorScheme.dark, dark), (.light, light)] {
                    let c = GlanceColors.pick(palette, system: system)
                    #expect(c.palette == held)
                    #expect(c.scheme == (held.isDark ? .dark : .light))
                    same(c.canvas, GlanceColors(held).canvas)
                    same(c.fg, hex(held.fg))
                }
            }
        }
    }

    @Test func aPaletteKeepsSixAnsiColorsAndFallsBackToTheForeground() {
        let p = GlancePalette(appearance: "dark", bg: "#000000", fg: "#ffffff", accent: "#ff0000",
                              ansi: (0..<16).map { _ in "#111111" })
        #expect(p.ansi.count == 6)
        let short = GlancePalette(appearance: "light", bg: "#ffffff", fg: "#123456", accent: "#ff0000", ansi: ["#000000"])
        #expect(short.ansi(3) == "#123456" && !short.isDark)
        same(GlanceColors(short).blocked, hex("#123456"))
    }

    @Test func agentTintsByKind() {
        for p in [GlancePalette.standardDark, .standardLight] {
            let c = GlanceColors(p)
            same(AgentGlyph.tint(kind: "claude", c), hex("#d97757"))
            same(AgentGlyph.tint(kind: "codex", c), hex(p.fg))
            same(AgentGlyph.tint(kind: "gemini", c), hex(p.ansi[4]))
            for other in ["opencode", "amp", "aider", "cursor", "something-new"] { same(AgentGlyph.tint(kind: other, c), hex(p.ansi[5])) }
            same(AgentGlyph.tint(kind: nil, c), hex(p.fg).opacity(0.55))
        }
    }

    @Test func theRingBadgesAStateWithoutColor() {
        #expect(GlanceRingBadge.symbol("blocked") == "hand.raised.fill")
        #expect(GlanceRingBadge.symbol("done") == "checkmark")
        #expect(GlanceRingBadge.symbol("error") == "xmark")
        for quiet in ["working", "idle", nil] { #expect(GlanceRingBadge.symbol(quiet) == nil) }
    }
}
