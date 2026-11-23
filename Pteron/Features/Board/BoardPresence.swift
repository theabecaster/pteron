import Foundation

/// Whether the agent board is on screen while the phone stands as a tent. Pure, with the time
/// passed in, so it is tested.
///
/// - Entering tent shows the board. A sheet over the app makes it wait until the sheet is gone.
/// - A tile, the sidebar, Settings, a tab opened from a push or an app shortcut puts the board
///   away (`dismissed`), and the tab under it shows.
/// - Still in tent, the board comes back after `returnAfter` seconds with no touch and no key.
///   A keyboard on screen or a sheet counts as use.
/// - Leaving tent removes it.
struct BoardPresence: Equatable {
    static let standardReturn: TimeInterval = 60
    /// How often a board that waits for a sheet to go looks again.
    static let recheck: TimeInterval = 1

    var returnAfter = BoardPresence.standardReturn
    private(set) var inTent = false
    private(set) var shown = false
    /// Tent began under a sheet: the board shows as soon as the sheet is gone.
    private var waiting = false
    /// The last use of the app while the board was away.
    private var lastUse = Date.distantPast
    private var checkAt: Date?

    /// When `tick` should run next. Nil when nothing is pending.
    var deadline: Date? {
        guard inTent, !shown else { return nil }
        return waiting ? checkAt : lastUse.addingTimeInterval(returnAfter)
    }

    /// The phone went into or out of tent. `modal`: a sheet, cover or alert is over the app.
    mutating func tent(_ on: Bool, modal: Bool, now: Date) {
        guard on != inTent else { return }
        inTent = on
        waiting = on && modal
        shown = on && !modal
        checkAt = waiting ? now.addingTimeInterval(Self.recheck) : nil
    }

    /// The user left the board for the app. It returns after `returnAfter` without use.
    mutating func dismissed(now: Date) {
        guard inTent, shown || waiting else { return }
        shown = false
        waiting = false
        lastUse = now
    }

    /// A touch or a key while the board is away.
    mutating func activity(now: Date) {
        guard inTent, !shown, !waiting else { return }
        lastUse = now
    }

    /// Call at `deadline`. `busy`: the keyboard is up or a sheet is over the app.
    mutating func tick(now: Date, busy: Bool, modal: Bool) {
        guard inTent, !shown else { return }
        if waiting {
            if modal {
                checkAt = now.addingTimeInterval(Self.recheck)
            } else {
                waiting = false
                shown = true
            }
            return
        }
        if busy || modal {
            lastUse = now
        } else if now.timeIntervalSince(lastUse) >= returnAfter {
            shown = true
        }
    }
}

/// Whether the board keeps the screen awake: only while it shows, in the active app, and not in
/// Low Power Mode.
enum BoardAwake {
    static func keepsAwake(shown: Bool, lowPower: Bool, active: Bool) -> Bool {
        shown && active && !lowPower
    }
}
