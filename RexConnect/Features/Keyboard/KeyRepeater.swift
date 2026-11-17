import GameController
import UIKit

/// Time for `KeyRepeater`: the system's in the app, a hand-driven one in tests.
@MainActor
protocol KeyRepeatClock: AnyObject {
    var now: CFTimeInterval { get }
    /// Calls `fire` once, `delay` seconds from now. The returned closure cancels the call.
    func after(_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> @MainActor () -> Void
}

@MainActor
final class SystemKeyRepeatClock: KeyRepeatClock {
    var now: CFTimeInterval { CACurrentMediaTime() }

    func after(_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let timer = Timer(timeInterval: delay, repeats: false) { _ in MainActor.assumeIsolated { fire() } }
        // Common modes: a held key keeps repeating while a scroll view tracks.
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}

/// Repeats a held hardware key. iOS repeats only the keys its text system types; a key the app
/// handles itself (an arrow, Ctrl+D, a key binding) gets one `pressesBegan` and nothing more, so
/// the app repeats it, and must never go on after the key came up.
///
/// The key-up can go missing: the app is switched away from, a system alert takes the keyboard,
/// a Bluetooth keyboard drops out. The keys go to a real shell, so every way out is taken:
///
/// - `released(usage:)` from `pressesEnded` and `pressesCancelled`, and `stop()` from whoever
///   owns the repeater (resigning first responder, leaving the window, a closed pane);
/// - the app resigns active or enters the background, or a keyboard disconnects;
/// - `allowed` turns false (asked before every repeat: still first responder, in a window, active);
/// - the keyboard itself says the key is up (`GCKeyboard`, asked before every repeat). Its
///   answer counts once it has said "down" for this press: a keyboard that reports no key
///   states at all must not end every repeat at once;
/// - a hard limit: `Timing.longest` seconds while the keyboard confirms the key is down, and
///   `Timing.longestUnverified` when it can't be asked or never confirmed the press.
///
/// One key repeats at a time: a new press replaces the last.
@MainActor
final class KeyRepeater: NSObject {
    struct Timing: Equatable {
        /// Before the first repeat.
        var delay: TimeInterval = 0.4
        /// Between repeats.
        var interval: TimeInterval = 0.1
        /// The longest a key repeats while the keyboard confirms it is down.
        var longest: TimeInterval = 60
        /// The longest a key repeats when no keyboard confirms that it is down.
        var longestUnverified: TimeInterval = 10

        /// The delay and rate for keys sent to the program.
        static let program = Timing()
        /// Faster, for the app's own repeating commands (pane focus, resize).
        static let command = Timing(interval: 0.05)
    }

    private let clock: any KeyRepeatClock
    /// Whether the key with this HID usage is down; nil when no keyboard can say.
    private let keyIsDown: @MainActor (Int) -> Bool?

    private var cancel: (@MainActor () -> Void)?
    private var timing = Timing.program
    private var allowed: (@MainActor () -> Bool)?
    private var fire: (@MainActor () -> Void)?
    private var startedAt: CFTimeInterval = 0
    /// The keyboard has reported this press as down, so its "up" can be believed.
    private var confirmedDown = false
    /// The key that repeats now.
    private(set) var usage: Int?
    /// Repeats sent for the current key.
    private(set) var count = 0

    var isRepeating: Bool { usage != nil }

    init(clock: any KeyRepeatClock = SystemKeyRepeatClock(), notifications: NotificationCenter = .default,
         keyIsDown: @escaping @MainActor (Int) -> Bool? = KeyRepeater.keyboardSays) {
        self.clock = clock
        self.keyIsDown = keyIsDown
        super.init()
        let stops: [Notification.Name] = [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                                          .GCKeyboardDidDisconnect]
        for name in stops {
            notifications.addObserver(self, selector: #selector(mustStop), name: name, object: nil)
        }
    }

    /// The system's answer: the coalesced keyboard's button for the key.
    static func keyboardSays(_ usage: Int) -> Bool? {
        guard let input = GCKeyboard.coalesced?.keyboardInput,
              let button = input.button(forKeyCode: GCKeyCode(rawValue: usage)) else { return nil }
        return button.isPressed
    }

    /// Starts repeating `fire` for the key that just went down (the press itself is the caller's).
    /// `allowed` is asked before every repeat; false ends it.
    func start(usage: Int, timing: Timing = .program, while allowed: @escaping @MainActor () -> Bool,
               fire: @escaping @MainActor () -> Void) {
        stop()
        self.usage = usage
        self.timing = timing
        self.allowed = allowed
        self.fire = fire
        count = 0
        startedAt = clock.now
        confirmedDown = keyIsDown(usage) == true
        arm(after: timing.delay)
    }

    /// A key came up, or its press was cancelled.
    func released(usage: Int) {
        if self.usage == usage { stop() }
    }

    func stop() {
        cancel?()
        cancel = nil
        usage = nil
        allowed = nil
        fire = nil
    }

    @objc private func mustStop() { stop() }

    private func arm(after delay: TimeInterval) {
        cancel = clock.after(delay) { [weak self] in self?.tick() }
    }

    private func tick() {
        cancel = nil
        guard let usage, let allowed, let fire else { return }
        guard allowed() else { return stop() }
        let down = keyIsDown(usage)
        if down == true { confirmedDown = true }
        // Up, by a keyboard that had seen it down: the key-up event went missing.
        if down == false, confirmedDown { return stop() }
        let limit = down == true ? timing.longest : timing.longestUnverified
        guard clock.now - startedAt <= limit else { return stop() }
        count += 1
        fire()
        // `fire` may have stopped or restarted the repeater.
        if self.usage == usage, cancel == nil { arm(after: timing.interval) }
    }
}
