import XCTest
@testable import RexKit

/// When predicted echo is on: the write round trip's hysteresis (docs/terminal.md, Predicted echo).
@MainActor
final class EchoGateTests: XCTestCase {
    /// Feeds `ms` samples `every` seconds apart from `start`; returns the time after the last.
    @discardableResult
    private func feed(_ gate: EchoGate, _ ms: [Double], every: Double = 0.2, from start: Double = 0) -> Double {
        var t = start
        for m in ms {
            gate.sample(ms: m, at: t)
            t += every
        }
        return t
    }

    func testFastNeverActivates() {
        let gate = EchoGate()
        var changes = 0
        _ = gate.watch(changed: { _ in changes += 1 }, reset: {})
        var rng = SystemRandomNumberGenerator()
        var t = 0.0
        for i in 0..<10_000 {
            // Mostly 1...59 ms, a stretch held at 59, and isolated 249 ms spikes.
            let ms: Double = i % 97 == 0 ? 249 : (i > 4_000 && i < 5_000 ? 59 : Double(Int.random(in: 1...59, using: &rng)))
            gate.sample(ms: ms, at: t)
            t += 0.05
        }
        XCTAssertEqual(gate.level, .off)
        XCTAssertEqual(changes, 0, "no pane is ever told to attach an observer")
    }

    func testSingleSpikeStaysOff() {
        let gate = EchoGate()
        var t = 0.0
        for i in 0..<3_000 {
            // 20 ms steady, one 400 ms spike every 30 s (samples 0.1 s apart).
            gate.sample(ms: i % 300 == 150 ? 400 : 20, at: t)
            t += 0.1
            XCTAssertEqual(gate.level, .off)
        }
    }

    func testTwoGlitchesActivateAndTheCureNeedsSpacedSamples() {
        let gate = EchoGate()
        var t = feed(gate, [20, 20, 20, 20, 20])
        XCTAssertEqual(gate.level, .off)
        gate.sample(ms: 260, at: t); t += 1
        XCTAssertEqual(gate.level, .off, "one glitch is a spike")
        gate.sample(ms: 260, at: t); t += 0.2
        XCTAssertEqual(gate.level, .on, "two within 10 s turn it on")
        // A burst of fast answers 10 ms apart counts once per 150 ms.
        for _ in 0..<40 {
            gate.sample(ms: 15, at: t)
            t += 0.01
        }
        XCTAssertEqual(gate.level, .on, "the cure needs 10 samples at least 150 ms apart")
        t = feed(gate, [Double](repeating: 15, count: 10), every: 0.2, from: t + 0.2)
        XCTAssertEqual(gate.level, .off)
    }

    func testWarmup() {
        let gate = EchoGate()
        feed(gate, [100, 100, 100, 100])
        XCTAssertEqual(gate.level, .off, "4 slow samples are not enough")
        gate.sample(ms: 100, at: 1)
        XCTAssertEqual(gate.level, .slow, "the 5th turns it on; over 80 ms it is the slow look")
    }

    func testSlowHysteresis() {
        let gate = EchoGate()
        var t = feed(gate, [Double](repeating: 70, count: 8))
        XCTAssertEqual(gate.level, .on, "60 to 80 ms: unmarked")
        t = feed(gate, [Double](repeating: 120, count: 30), from: t)
        XCTAssertEqual(gate.level, .slow, "over 80 ms: underlined")
        t = feed(gate, [Double](repeating: 60, count: 40), from: t)
        XCTAssertEqual(gate.level, .slow, "back above 50 ms is not enough")
        t = feed(gate, [Double](repeating: 45, count: 40), from: t)
        XCTAssertEqual(gate.level, .on, "50 ms or less ends the underline")
        feed(gate, [Double](repeating: 30, count: 40), from: t)
        XCTAssertEqual(gate.level, .off, "40 ms or less ends predictions")

        // A pane's drawn guess waiting 300 ms marks the link slow; the level stays until the
        // round trip says otherwise.
        let other = EchoGate()
        feed(other, [Double](repeating: 70, count: 8))
        other.noteOverdue()
        XCTAssertEqual(other.level, .slow)

        // Downgrades wait for nothing pending in the pane.
        var pane = EchoPaneLevel()
        XCTAssertEqual(pane.want(.slow, pending: false), .slow)
        XCTAssertEqual(pane.want(.on, pending: true), .slow, "the look never changes mid-word")
        XCTAssertEqual(pane.settle(pending: true), .slow)
        XCTAssertEqual(pane.settle(pending: false), .on)
        XCTAssertEqual(pane.want(.off, pending: true), .on)
        XCTAssertEqual(pane.want(.slow, pending: true), .slow, "more shows at once")
        XCTAssertEqual(pane.want(.off, pending: false), .off)
    }

    func testNoFlapping() {
        let gate = EchoGate()
        var levels: [EchoLevel] = []
        _ = gate.watch(changed: { levels.append($0) }, reset: {})
        var t = 0.0
        // 45 and 65 ms alternating, a sample every 0.2 s for 10 minutes.
        for i in 0..<3_000 {
            gate.sample(ms: i % 2 == 0 ? 45 : 65, at: t)
            t += 0.2
        }
        XCTAssertLessThanOrEqual(levels.count, 1)
    }

    func testResetOnReconnect() {
        let gate = EchoGate()
        var resets = 0
        var levels: [EchoLevel] = []
        _ = gate.watch(changed: { levels.append($0) }, reset: { resets += 1 })
        feed(gate, [Double](repeating: 150, count: 8))
        XCTAssertEqual(gate.level, .slow)
        gate.reset()
        XCTAssertEqual(gate.level, .off)
        XCTAssertEqual(resets, 1, "every pane clears its guesses")
        XCTAssertEqual(levels.last, .off)
        XCTAssertEqual(gate.roundTrip.samples, 0, "samples cleared: the link is fast until it proves otherwise")
        feed(gate, [150, 150, 150, 150])
        XCTAssertEqual(gate.level, .off, "the warm-up starts again")
    }

    func testForcedLevel() {
        let gate = EchoGate(forced: .slow)
        XCTAssertEqual(gate.effective, .slow)
        feed(gate, [Double](repeating: 5, count: 20))
        XCTAssertEqual(gate.effective, .slow, "-predict always ignores the samples")
        gate.forced = .off
        feed(gate, [Double](repeating: 200, count: 20))
        XCTAssertEqual(gate.effective, .off, "-predict never too")
    }

    func testARouteChangeStartsTheGateAgain() {
        let control = RexControl(address: "http://127.0.0.1:9", client: ClientInfo(name: "test", version: "0", label: "test"))
        let gate = EchoGate()
        gate.follow(control)
        var resets = 0
        _ = gate.watch(changed: { _ in }, reset: { resets += 1 })
        func slow() {
            feed(gate, [Double](repeating: 150, count: 8))
            XCTAssertEqual(gate.level, .slow)
        }
        // The first report of the path the app started on, on Wi-Fi: no change.
        slow()
        control.pathChanged(satisfied: true, expensive: false, interfaceChanged: false)
        XCTAssertEqual(gate.level, .slow, "a report that changes nothing keeps the samples")
        XCTAssertEqual(resets, 0)
        // The route really changed and has settled (`RouteWatch`).
        control.pathChanged(satisfied: true, expensive: false, interfaceChanged: true)
        XCTAssertEqual(gate.level, .off)
        XCTAssertEqual(gate.roundTrip.samples, 0)
        XCTAssertEqual(resets, 1, "every pane clears its guesses")
        // From Wi-Fi to cellular, told before the route has settled.
        slow()
        control.pathChanged(satisfied: true, expensive: true, interfaceChanged: false)
        XCTAssertEqual(gate.level, .off)
        XCTAssertEqual(resets, 2)
        // The same path told again: nothing.
        slow()
        control.pathChanged(satisfied: true, expensive: true, interfaceChanged: false)
        XCTAssertEqual(gate.level, .slow)
        // No path: the samples are of a route that is gone only once another is there.
        control.pathChanged(satisfied: false, expensive: true, interfaceChanged: false)
        XCTAssertEqual(resets, 2)
        // And back to Wi-Fi.
        control.pathChanged(satisfied: true, expensive: false, interfaceChanged: false)
        XCTAssertEqual(gate.level, .off)
        XCTAssertEqual(resets, 3)
    }

    func testAGateThatIsGoneIsNoLongerTold() {
        let control = RexControl(address: "http://127.0.0.1:9", client: ClientInfo(name: "test", version: "0", label: "test"))
        var heard = 0
        control.observeRoute { heard += 1; return heard < 2 }
        control.pathChanged(satisfied: true, expensive: true, interfaceChanged: false)
        control.pathChanged(satisfied: true, expensive: false, interfaceChanged: false)
        control.pathChanged(satisfied: true, expensive: true, interfaceChanged: false)
        XCTAssertEqual(heard, 2, "an observer that answers false is dropped")
    }
}
