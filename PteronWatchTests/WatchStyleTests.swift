import Foundation
import GlanceModel
import GlanceUI
import SwiftUI
import Testing
@testable import PteronWatch

/// The watch app's motion and colors: Reduce Motion turns every movement into a fade or
/// nothing, the wrist down stops everything, and every text color reads at 4.5:1 or more.
@MainActor
@Suite struct WatchStyleTests {
    // MARK: Motion

    @Test func reduceMotionFadesAndTheWristDownStopsEverything() {
        #expect(WatchMotion(reduceMotion: false, wristDown: false) == .full)
        #expect(WatchMotion(reduceMotion: true, wristDown: false) == .fade)
        #expect(WatchMotion(reduceMotion: false, wristDown: true) == .still)
        #expect(WatchMotion(reduceMotion: true, wristDown: true) == .still)
    }

    @Test func withReduceMotionNothingMovesOrBreathes() {
        let m = WatchMotion.fade
        #expect(m.rise == 0 && !m.breathes)
        for part in [WatchArrival.Part.glide, .line, .ring, .words] {
            let s = m.start(part)
            #expect(s.x == 0 && s.y == 0 && s.tilt == 0 && s.scale == 1)
            #expect(m.arrival(part) != nil)
        }
        #expect(m.count == .opacity)
        // Fades, short.
        #expect(m.change != nil && m.entrance(3) != nil)
    }

    @Test func withTheWristDownThereIsNoAnimationAtAll() {
        let m = WatchMotion.still
        #expect(m.change == nil && m.count == .identity && !m.glows && !m.breathes && m.rise == 0)
        for i in 0..<10 { #expect(m.entrance(i) == nil) }
        for part in [WatchArrival.Part.glide, .line, .ring, .words] { #expect(m.arrival(part) == nil) }
    }

    @Test func fullMotionRisesGlidesSpringsAndBreathes() {
        let m = WatchMotion.full
        #expect(m.rise > 0 && m.breathes && m.glows && m.count == .numericText())
        #expect(m.start(.glide).x < 0 && m.start(.glide).tilt != 0 && m.start(.ring).scale < 1 && m.start(.words).y > 0)
        // The list's lines stop being staggered after the seventh.
        #expect(m.entrance(6) == m.entrance(20))
    }

    // MARK: Contrast

    private struct RGB { var r, g, b, a: Double }

    private func rgb(_ color: Color) -> RGB {
        let c = color.resolve(in: EnvironmentValues())
        return RGB(r: Double(c.red), g: Double(c.green), b: Double(c.blue), a: Double(c.opacity))
    }

    /// `top` drawn over the opaque `under`.
    private func over(_ top: RGB, _ under: RGB) -> RGB {
        RGB(r: top.r * top.a + under.r * (1 - top.a), g: top.g * top.a + under.g * (1 - top.a),
            b: top.b * top.a + under.b * (1 - top.a), a: 1)
    }

    private func luminance(_ c: RGB) -> Double {
        func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
    }

    private func contrast(_ text: Color, on ground: RGB) -> Double {
        let a = luminance(over(rgb(text), ground)), b = luminance(ground)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    @Test func everyTextColorReadsAtFourAndAHalfToOne() {
        let black = RGB(r: 0, g: 0, b: 0, a: 1)
        // The watch draws every snapshot in a dark theme: the default one unless a dark one was chosen.
        let palettes = Set(GlanceDemo.scenarios.compactMap { GlanceDemo.snapshot($0, now: Date()) }.map { WatchScreen.palette($0.palette).bg })
        #expect(palettes == [GlancePalette.standardDark.bg])
        let style = WatchStyle(.standardDark)
        let grounds: [(String, RGB)] = [
            ("black", black),
            ("platter", over(rgb(style.platter), black)),
            ("the ground's top", rgb(GlanceGlide.deep)),
        ]
        let texts: [(String, Color)] = [
            ("fg", style.fg), ("secondary", style.secondary), ("waiting", style.waiting),
            ("error", style.state(.error)), ("working", style.state(.working)), ("done", style.state(.done)),
        ]
        for (gName, ground) in grounds {
            for (tName, text) in texts {
                let ratio = contrast(text, on: ground)
                #expect(ratio >= 4.5, "\(tName) on \(gName): \(ratio)")
            }
        }
    }

    @Test func theHeadlineTakesItsStatesColorAndStaysQuietWhenOld() {
        let style = WatchStyle(.standardDark)
        func headline(_ scenario: String) -> Color {
            style.headline(WatchScreen(GlanceDemo.snapshot(scenario, now: Date()).map(GlanceReading.snapshot) ?? .missing, now: Date()))
        }
        #expect(headline("several") == style.waiting)
        #expect(headline("working") == style.state(.working))
        #expect(headline("quiet") == style.fg)
        // Old: dimmed in the foreground color, never the waiting color. A machine down: secondary.
        #expect(headline("old") == style.fg)
        #expect(headline("offline") == style.secondary)
    }
}
