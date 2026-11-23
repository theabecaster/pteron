import GameController
import XCTest
@testable import Pteron

/// A clock the test moves by hand.
@MainActor
final class ManualKeyRepeatClock: KeyRepeatClock {
    private(set) var now: CFTimeInterval = 100
    private var pending: [(at: CFTimeInterval, id: Int, fire: @MainActor () -> Void)] = []
    private var lastID = 0

    /// Calls waiting to fire.
    var scheduled: Int { pending.count }

    func after(_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        lastID += 1
        let id = lastID
        pending.append((now + delay, id, fire))
        return { [weak self] in self?.pending.removeAll { $0.id == id } }
    }

    /// Moves time on, firing what comes due in order.
    func advance(_ seconds: TimeInterval) {
        let end = now + seconds
        while let next = pending.filter({ $0.at <= end + 1e-9 }).min(by: { $0.at < $1.at }) {
            pending.removeAll { $0.id == next.id }
            now = max(now, next.at)
            next.fire()
        }
        now = end
    }
}

@MainActor
private final class SendSpy: TerminalEngineDelegate {
    var sent: [[UInt8]] = []
    func engineGridChanged(cols: Int, rows: Int) {}
    func engineSend(_ bytes: [UInt8]) { sent.append(bytes) }
}

/// A held hardware key must never go on repeating once it is up, whatever happened to the
/// key-up event.
@MainActor
final class KeyRepeaterTests: XCTestCase {
    private let clock = ManualKeyRepeatClock()
    private let center = NotificationCenter()
    private var keyDown: Bool? = true
    private var allowed = true
    private var fired = 0

    private func makeRepeater() -> KeyRepeater {
        KeyRepeater(clock: clock, notifications: center, keyIsDown: { [unowned self] _ in self.keyDown })
    }

    private func start(_ r: KeyRepeater, usage: Int = 82, timing: KeyRepeater.Timing = .program) {
        r.start(usage: usage, timing: timing, while: { [unowned self] in self.allowed }) { [unowned self] in self.fired += 1 }
    }

    func testRepeatsAfterTheDelayAtTheRate() {
        let r = makeRepeater()
        start(r)
        clock.advance(0.39)
        XCTAssertEqual(fired, 0, "nothing before the delay")
        clock.advance(0.02)
        XCTAssertEqual(fired, 1)
        clock.advance(0.6)
        XCTAssertEqual(fired, 7, "0.4 s, then every 0.1 s")
        XCTAssertEqual(r.count, 7)
        XCTAssertTrue(r.isRepeating)

        // The app's own commands repeat faster.
        r.stop()
        fired = 0
        start(r, timing: .command)
        clock.advance(1.0)
        XCTAssertEqual(fired, 13, "0.4 s, then every 0.05 s")
    }

    func testTheKeyComingUpEndsIt() {
        let r = makeRepeater()
        start(r, usage: 82)
        clock.advance(0.5)
        r.released(usage: 81)
        XCTAssertTrue(r.isRepeating, "another key's release is not this key's")
        r.released(usage: 82)
        XCTAssertFalse(r.isRepeating)
        let before = fired
        clock.advance(5)
        XCTAssertEqual(fired, before)
        XCTAssertEqual(clock.scheduled, 0, "no timer is left behind")
    }

    func testOnlyTheLatestKeyRepeats() {
        let r = makeRepeater()
        var first = 0, second = 0
        r.start(usage: 80, while: { true }) { first += 1 }
        clock.advance(0.5)
        r.start(usage: 79, while: { true }) { second += 1 }
        clock.advance(0.6)
        XCTAssertEqual(first, 2)
        XCTAssertEqual(second, 3)
        XCTAssertEqual(r.usage, 79)
        XCTAssertEqual(clock.scheduled, 1)
    }

    func testAMissedKeyUpEndsItWhenTheKeyboardSaysTheKeyIsUp() {
        let r = makeRepeater()
        start(r)
        clock.advance(0.65)
        XCTAssertEqual(fired, 3)
        // The release never arrived (an app switch, a system alert): the keyboard still knows.
        keyDown = false
        clock.advance(10)
        XCTAssertEqual(fired, 3)
        XCTAssertFalse(r.isRepeating)
        XCTAssertEqual(clock.scheduled, 0)
    }

    func testAKeyboardThatNeverReportedThePressCannotEndTheRepeatButTheShortLimitDoes() {
        // Some keyboards report no key states: "up" from the start means nothing.
        keyDown = false
        let r = makeRepeater()
        start(r)
        clock.advance(1.05)
        XCTAssertEqual(fired, 7, "the key repeats")
        clock.advance(600)
        XCTAssertFalse(r.isRepeating)
        XCTAssertLessThanOrEqual(fired, Int(KeyRepeater.Timing.program.longestUnverified / KeyRepeater.Timing.program.interval))

        // The report arrives a moment after the press: from then on its "up" counts.
        fired = 0
        start(r)
        clock.advance(0.45)
        keyDown = true
        clock.advance(0.2)
        keyDown = false
        clock.advance(30)
        XCTAssertEqual(fired, 3)
        XCTAssertFalse(r.isRepeating)
    }

    func testItEndsWhenItIsNoLongerAllowed() {
        let r = makeRepeater()
        start(r)
        clock.advance(0.65)
        allowed = false  // lost first responder, left the window, the pane is no longer active
        clock.advance(10)
        XCTAssertEqual(fired, 3)
        XCTAssertFalse(r.isRepeating)
    }

    func testLeavingTheForegroundOrLosingAKeyboardEndsIt() {
        let names: [Notification.Name] = [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                                          .GCKeyboardDidDisconnect]
        for name in names {
            let r = makeRepeater()
            fired = 0
            start(r)
            clock.advance(0.65)
            center.post(name: name, object: nil)
            XCTAssertFalse(r.isRepeating, name.rawValue)
            clock.advance(10)
            XCTAssertEqual(fired, 3, name.rawValue)
        }
    }

    func testAKeyNeverRepeatsPastTheLimit() {
        // The keyboard keeps saying the key is down (a stuck report): the limit still ends it.
        let r = makeRepeater()
        start(r)
        clock.advance(600)
        XCTAssertFalse(r.isRepeating)
        XCTAssertLessThanOrEqual(fired, Int(KeyRepeater.Timing.program.longest / KeyRepeater.Timing.program.interval))
        XCTAssertGreaterThan(fired, 500, "a long hold is still served")
        XCTAssertEqual(clock.scheduled, 0)

        // No keyboard to ask: a much shorter limit.
        keyDown = nil
        fired = 0
        start(r)
        clock.advance(600)
        XCTAssertFalse(r.isRepeating)
        XCTAssertLessThanOrEqual(fired, Int(KeyRepeater.Timing.program.longestUnverified / KeyRepeater.Timing.program.interval))
        XCTAssertGreaterThan(fired, 50)
    }

    // MARK: The engine

    private func makeView(in window: UIWindow) throws -> (GhosttyTerminalView, SendSpy) {
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        let view = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: 12, cols: 40, rows: 10)
        let spy = SendSpy()
        view.engineDelegate = spy
        view.inputState.keyRepeat = makeRepeater()
        window.addSubview(view)
        window.isHidden = false
        try XCTSkipUnless(view.becomeFirstResponder(), "the test host gave no first responder")
        return (view, spy)
    }

    private func press(_ view: GhosttyTerminalView, _ spelling: String) -> Int {
        let p = GhosttyInputProbe.press(spelling)!
        XCTAssertTrue(view.hardwareKeyDown(usage: p.usage, flags: p.flags, characters: p.characters,
                                           charactersIgnoringModifiers: p.ignoringModifiers))
        return p.usage
    }

    func testCtrlDHeldInTheEngineStopsWithoutAKeyUp() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        defer { window.isHidden = true }
        let (view, spy) = try makeView(in: window)
        _ = press(view, "ctrl+d")
        XCTAssertEqual(spy.sent, [[0x04]])
        clock.advance(0.65)
        XCTAssertEqual(spy.sent.count, 4, "the press and three repeats")
        // No pressesEnded ever comes; the key is up.
        keyDown = false
        clock.advance(120)
        XCTAssertEqual(spy.sent.count, 4)
        XCTAssertFalse(view.inputState.keyRepeat.isRepeating)
    }

    func testTheEngineStopsRepeatingOnKeyUpResignAndWindowLoss() throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        defer { window.isHidden = true }
        let (view, spy) = try makeView(in: window)

        let tab = press(view, "tab")
        clock.advance(0.45)
        view.hardwareKeyUp(usage: tab)
        var count = spy.sent.count
        clock.advance(30)
        XCTAssertEqual(spy.sent.count, count, "key up")

        _ = press(view, "up")
        clock.advance(0.45)
        XCTAssertTrue(view.resignFirstResponder())
        count = spy.sent.count
        clock.advance(30)
        XCTAssertEqual(spy.sent.count, count, "resigned first responder")
        XCTAssertFalse(view.inputState.keyRepeat.isRepeating)

        XCTAssertTrue(view.becomeFirstResponder())
        _ = press(view, "down")
        clock.advance(0.45)
        view.removeFromSuperview()
        count = spy.sent.count
        clock.advance(30)
        XCTAssertEqual(spy.sent.count, count, "left its window")

        window.addSubview(view)
        XCTAssertTrue(view.becomeFirstResponder())
        _ = press(view, "left")
        clock.advance(0.45)
        center.post(name: UIApplication.willResignActiveNotification, object: nil)
        count = spy.sent.count
        clock.advance(30)
        XCTAssertEqual(spy.sent.count, count, "the app resigned active")

        // The host's way to stop it (the pane is no longer the active one).
        _ = press(view, "right")
        clock.advance(0.45)
        view.stopKeyRepeat()
        count = spy.sent.count
        clock.advance(30)
        XCTAssertEqual(spy.sent.count, count, "stopped by the host")
    }
}
