import Foundation
import Testing
@testable import RexDuo

/// When the phone counts as standing in tent: the hold, the hysteresis and what ends it.
struct TentDetectorTests {
    private let t0 = Date(timeIntervalSince1970: 1000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }
    private func reading(_ angle: Double?, division: Bool = false, fills: Bool = true) -> TentDetector.Reading {
        .init(hasDivision: division, fillsScreen: fills, angle: angle)
    }

    /// A detector already in tent.
    private func inTent() -> TentDetector {
        var d = TentDetector()
        _ = d.update(reading(90), now: at(0))
        _ = d.update(reading(90), now: at(1))
        return d
    }

    @Test func entersAfterTheAngleHeldForASecond() {
        var d = TentDetector()
        #expect(d.update(reading(90), now: at(0)) == at(1))
        #expect(!d.inTent)
        // An update inside the hold changes nothing and keeps the same deadline.
        #expect(d.update(reading(95), now: at(0.5)) == at(1))
        #expect(!d.inTent)
        #expect(d.update(reading(95), now: at(1)) == nil)
        #expect(d.inTent)
    }

    @Test func theHoldEndsOnItsDeadlineWithoutASecondHingeUpdate() {
        var d = TentDetector()
        let deadline = d.update(reading(120), now: at(0))
        // The caller comes back at the deadline with the same reading.
        #expect(d.update(reading(120), now: deadline!) == nil)
        #expect(d.inTent)
    }

    @Test func aReadingOutsideTheRangeRestartsTheHold() {
        var d = TentDetector()
        _ = d.update(reading(90), now: at(0))
        #expect(d.update(reading(10), now: at(0.6)) == nil)
        #expect(d.update(reading(90), now: at(0.8)) == at(1.8))
        _ = d.update(reading(90), now: at(1.2))
        #expect(!d.inTent, "0.4 s since it qualified again")
        _ = d.update(reading(90), now: at(1.8))
        #expect(d.inTent)
    }

    @Test func entryBoundsAre20And160() {
        for (angle, enters) in [(19.9, false), (20.0, true), (160.0, true), (160.1, false), (180.0, false)] {
            var d = TentDetector()
            _ = d.update(reading(angle), now: at(0))
            _ = d.update(reading(angle), now: at(2))
            #expect(d.inTent == enters, "\(angle)")
        }
    }

    @Test func neverEntersWithoutAHingeOrAtZero() {
        for angle in [nil, 0, -5, Double.nan, Double.infinity] as [Double?] {
            var d = TentDetector()
            #expect(d.update(reading(angle), now: at(0)) == nil)
            _ = d.update(reading(angle), now: at(5))
            #expect(!d.inTent)
        }
    }

    @Test func neverEntersWithAFoldInTheWindowOrInAWindowThatDoesNotFillItsScreen() {
        var d = TentDetector()
        #expect(d.update(reading(90, division: true), now: at(0)) == nil)
        _ = d.update(reading(90, division: true), now: at(5))
        #expect(!d.inTent, "the inner screen, an inactive fold included")
        #expect(d.update(reading(90, fills: false), now: at(6)) == nil)
        _ = d.update(reading(90, fills: false), now: at(9))
        #expect(!d.inTent, "Split View on the inner screen has no fold in its window")
        // The window fills the screen from now: the hold starts here.
        #expect(d.update(reading(90), now: at(10)) == at(11))
    }

    @Test func inTentTheBandBetween15And20Stays() {
        var d = inTent()
        _ = d.update(reading(17), now: at(2))
        #expect(d.inTent)
        _ = d.update(reading(15), now: at(3))
        #expect(d.inTent)
        // From outside, the same angle doesn't enter.
        var out = TentDetector()
        _ = out.update(reading(17), now: at(0))
        _ = out.update(reading(17), now: at(5))
        #expect(!out.inTent)
    }

    @Test func inTentAbove160Stays() {
        var d = inTent()
        _ = d.update(reading(175), now: at(2))
        #expect(d.inTent, "opening ends tent when the fold appears in the window, not at an angle")
    }

    @Test func leavesAtOnceUnder15() {
        var d = inTent()
        #expect(d.update(reading(14.9), now: at(2)) == nil)
        #expect(!d.inTent)
    }

    @Test func leavesAtOnceWithoutAHinge() {
        var d = inTent()
        _ = d.update(reading(nil), now: at(2))
        #expect(!d.inTent)
    }

    @Test func leavesAtOnceWhenAFoldAppears() {
        var d = inTent()
        _ = d.update(reading(120, division: true), now: at(2))
        #expect(!d.inTent)
    }

    @Test func afterLeavingTheHoldStartsOver() {
        var d = inTent()
        _ = d.update(reading(5), now: at(2))
        #expect(d.update(reading(90), now: at(2.1)) == at(3.1))
        _ = d.update(reading(90), now: at(3))
        #expect(!d.inTent)
        _ = d.update(reading(90), now: at(3.1))
        #expect(d.inTent)
    }

    @Test func aWindowThatStopsFillingItsScreenDoesNotEndTent() {
        var d = inTent()
        _ = d.update(reading(90, fills: false), now: at(2))
        #expect(d.inTent, "the window's size is asked only on the way in")
    }

    #if DEBUG
    /// Under `-simulateDuo` the posture says itself whether it could be a tent.
    @Test func simulatedPosturesAnswerForThemselves() {
        let enters = ["folded": true, "foldedLandscape": true, "foldedLandscapeBarLeft": true, "iPhone": true,
                      "iPhoneLandscape": true, "iPhoneLandscapeIslandLeft": true, "proMaxLandscape": true,
                      "halfWindow": false, "halfWindowBarLeft": false, "unfolded": false, "unfoldedPortrait": false,
                      "book": false, "tabletop": false]
        #expect(Set(enters.keys) == Set(DuoSimulation.postures.map(\.name)))
        for (name, expected) in enters {
            guard let sim = DuoSimulation.named(name) else { Issue.record("no posture \(name)"); continue }
            var d = TentDetector()
            let r = reading(90, division: sim.rootDivision != nil, fills: sim.fillsScreen)
            _ = d.update(r, now: at(0))
            _ = d.update(r, now: at(2))
            #expect(d.inTent == expected, "\(name)")
        }
    }
    #endif

    @Test func fillsScreenWithinAPoint() {
        let screen = CGSize(width: 466, height: 678)
        #expect(HingeProbeRef.fills(window: screen, screen: screen))
        #expect(HingeProbeRef.fills(window: CGSize(width: 465.5, height: 678.6), screen: screen))
        #expect(!HingeProbeRef.fills(window: CGSize(width: 475, height: 669), screen: CGSize(width: 951, height: 669)))
        #expect(!HingeProbeRef.fills(window: CGSize(width: 466, height: 676), screen: screen))
    }
}
