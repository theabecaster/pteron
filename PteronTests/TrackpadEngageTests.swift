import CoreGraphics
import Testing
import UIKit
@testable import Pteron

/// When the trackpad key (✥) takes a drag, and when a held arrow stops repeating
/// (`TrackpadEngage`, `RepeatSlop`).
struct TrackpadEngageTests {
    private let down = CGPoint(x: 30, y: 21)

    private func touch() -> TrackpadEngage { TrackpadEngage(start: down, at: 100) }

    @Test func aQuickSidewaysSwipePassesToTheScroll() {
        var e = touch()
        let r14 = e.move(to: CGPoint(x: 36, y: 22), at: 100.03)
        #expect(!r14, "within the slop: still waiting")
        #expect(e.state == .waiting)
        let r17 = e.move(to: CGPoint(x: 45, y: 23), at: 100.06)
        #expect(!r17)
        #expect(e.state == .passed)
        #expect(!e.engaged)
        // Neither a later hold nor a turn up or down takes it back.
        let r22 = e.hold(at: 100.5)
        #expect(!r22)
        let r24 = e.move(to: CGPoint(x: 45, y: 80), at: 100.6)
        #expect(!r24)
        #expect(e.state == .passed)
    }

    @Test func aStillHoldEngagesWhereTheFingerRests() {
        var e = touch()
        let r31 = e.hold(at: 100.29)
        #expect(!r31, "not before 0.3 s")
        let r33 = e.move(to: CGPoint(x: 34, y: 24), at: 100.2)
        #expect(!r33)
        let r35 = e.hold(at: 100.3)
        #expect(r35)
        #expect(e.state == .engaged(anchor: CGPoint(x: 34, y: 24)), "steps count from the engage point")
        let r38 = e.hold(at: 100.5)
        #expect(!r38, "engages once")
    }

    @Test func aHoldWhoseTimerIsLateEngagesOnTheNextMove() {
        var e = touch()
        let r44 = e.move(to: CGPoint(x: 32, y: 22), at: 100.31)
        #expect(r44)
        #expect(e.state == .engaged(anchor: CGPoint(x: 32, y: 22)))
    }

    @Test func aFingerThatWanderedPastTheSlopNeverHolds() {
        var e = touch()
        _ = e.move(to: CGPoint(x: 30, y: 33), at: 100.1)  // 12 pt down: vertical, engaged
        #expect(e.engaged)
        var s = touch()
        _ = s.move(to: CGPoint(x: 42, y: 21), at: 100.1)  // 12 pt sideways: passed
        let r55 = s.hold(at: 100.3)
        #expect(!r55)
    }

    @Test func aVerticalDragEngagesAtOnceFromTheTouchDown() {
        var e = touch()
        let r61 = e.move(to: CGPoint(x: 33, y: 33), at: 100.02)
        #expect(r61, "11 pt down, 3 across")
        #expect(e.state == .engaged(anchor: down), "steps count from where the finger went down")
        var up = touch()
        let r65 = up.move(to: CGPoint(x: 26, y: 9), at: 100.02)
        #expect(r65)
        #expect(up.engaged)
    }

    @Test func aDiagonalIsSideways() {
        // |dy| must be more than 1.5 × |dx|.
        var e = touch()
        _ = e.move(to: CGPoint(x: 37, y: 31.5), at: 100.02)  // dx 7, dy 10.5: exactly 1.5×
        #expect(e.state == .passed)
        var v = touch()
        _ = v.move(to: CGPoint(x: 36, y: 31.5), at: 100.02)  // dx 6, dy 10.5
        #expect(v.engaged)
    }

    @Test func repeatKeepsWithinTheSlopAndOnTheKey() {
        let a = CGPoint(x: 22, y: 21)
        #expect(RepeatSlop.keepsRepeating(from: a, to: CGPoint(x: 28, y: 28), highlighted: true), "a rolling thumb: 9.2 pt")
        #expect(RepeatSlop.keepsRepeating(from: a, to: CGPoint(x: 32, y: 21), highlighted: true), "10 pt exactly")
        #expect(!RepeatSlop.keepsRepeating(from: a, to: CGPoint(x: 33, y: 21), highlighted: true), "11 pt: a swipe")
        #expect(!RepeatSlop.keepsRepeating(from: a, to: a, highlighted: false), "off the key's highlight")
    }
}

/// The scroll takes a swipe from the trackpad key until the key has the drag, and the bar's keys
/// keep their order.
@MainActor
struct TrackpadScrollTests {
    @Test func theScrollCancelsTheTrackpadOnlyBeforeItEngages() {
        let scroll = KeyScroll()
        let pad = KeyCap(key: "arrows", kind: .trackpad)
        #expect(scroll.touchesShouldCancel(in: pad), "no touch yet")
        pad.engage = TrackpadEngage(start: .zero, at: 0)
        #expect(scroll.touchesShouldCancel(in: pad), "waiting: a sideways swipe scrolls")
        _ = pad.engage?.move(to: CGPoint(x: 0, y: 12), at: 0.05)
        #expect(!scroll.touchesShouldCancel(in: pad), "engaged: the key keeps the drag")
        pad.engage = TrackpadEngage(start: .zero, at: 0)
        _ = pad.engage?.move(to: CGPoint(x: 12, y: 0), at: 0.05)
        #expect(scroll.touchesShouldCancel(in: pad), "passed")
        for (key, kind) in [("up", KeyCap.Kind.repeating), ("esc", .normal), ("ctrl", .modifier)] {
            #expect(scroll.touchesShouldCancel(in: KeyCap(key: key, kind: kind)), "\(key)")
        }
    }

    @Test func theBarsKeysAreTheSetupsItemsAndTheArrowsHaveTheirOwnCapsule() {
        let bar = KeyBar()
        let items = Prefs.shared.keyBarSetup.items
        #expect(bar.caps.count == items.count)
        for (cap, item) in zip(bar.caps, items) {
            switch item {
            case .key(let k): #expect(cap.key == k)
            case .shortcut: #expect(cap.key == "shortcut")
            case .group: #expect(cap.key == "group")
            }
        }
        #expect(bar.rightCaps.first?.key == "arrows", "✥ is the right capsule's first key")
        #expect(!bar.caps.contains { $0.key == "arrows" || $0.key == "enter" || $0.key == "attach" })
    }

    @Test func inItsOwnCapsuleTheTrackpadTakesADragInAnyDirection() {
        var e = TrackpadEngage(start: .zero, at: 0, anyDirection: true)
        let still = e.move(to: CGPoint(x: 6, y: 0), at: 0.02)
        #expect(!still, "within the slop: still waiting")
        let sideways = e.move(to: CGPoint(x: 14, y: 0), at: 0.05)
        #expect(sideways, "sideways engages at once")
        #expect(e.engaged)
        var held = TrackpadEngage(start: .zero, at: 0, anyDirection: true)
        let hold = held.hold(at: TrackpadEngage.holdDelay)
        #expect(hold, "a still hold still engages")
        // Among scrolling keys a sideways swipe still passes to the scroll.
        var scrolling = TrackpadEngage(start: .zero, at: 0)
        let swiped = scrolling.move(to: CGPoint(x: 14, y: 0), at: 0.05)
        #expect(!swiped)
        #expect(scrolling.state == .passed)
    }
}
