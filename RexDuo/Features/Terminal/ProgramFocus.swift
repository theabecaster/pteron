import Foundation

// The focus a program is told about (mode 1004, `CSI I` and `CSI O`).
//
// A program in a pane has the focus while its pane is the front pane: the tab's active pane, on
// screen, in the app in front, with nothing lying over it. The software keyboard has no part in
// it: hiding the keyboard, a drag into the scrollback that puts it away, and a hardware
// keyboard's quiet hold all leave the program focused. Only the cursor's look (solid or hollow)
// follows the keyboard.

/// What decides whether a pane is the front pane.
struct PaneFront: Equatable {
    /// The tab's active pane.
    var active = false
    /// In a window, and not set aside (parked).
    var onScreen = false
    /// The app is the one in front.
    var appActive = false
    /// The agent board lies over the pane.
    var underBoard = false
    /// A sheet, an alert or a menu lies over the pane.
    var underSheet = false
    /// The palette lies over the pane.
    var underPalette = false

    var isFront: Bool {
        active && onScreen && appActive && !underBoard && !underSheet && !underPalette
    }
}

/// Which focus report is due, from whether the pane is in front and what the program was last
/// told. It makes no bytes and sends nothing: `GhosttyTerminalView.sayFocus` does.
struct ProgramFocus: Equatable {
    /// When a report is asked for.
    enum Moment {
        /// The pane came to the front or left it.
        case changed
        /// The stream is current again (its fence came down). A report made before may never
        /// have arrived (a parked stream drops what it had queued), so the pane says again
        /// where it is, in front or not.
        case current
        /// The program turned focus reports on. It has been told nothing yet, so a pane in
        /// front says so.
        case asked
    }

    /// The pane is the front pane.
    private(set) var front = false
    /// What the program was last told, or would have been had it asked.
    private(set) var said = false
    /// When the write of a report that the focus was gained last left; nil before the first.
    private(set) var gainedAt: Double?
    /// When such a report was handed on for sending and has not left yet; nil otherwise.
    private(set) var gainedHandedAt: Double?
    /// How many such reports were handed on.
    private(set) var gainedCount = 0

    /// How long after it is told that it gained the focus a program may take a press for the
    /// click that brought the focus, and drop it. Programs that do so use about 0.4 s.
    static let activationWindow = 0.45

    /// Returns whether it changed.
    mutating func set(front now: Bool) -> Bool {
        guard now != front else { return false }
        front = now
        return true
    }

    /// The report due at `moment`: true for focus gained, false for lost, nil for none.
    func due(at moment: Moment) -> Bool? {
        switch moment {
        case .changed:
            return front != said ? front : nil
        case .current:
            return front
        case .asked:
            // In front: said. Not in front: the program takes that for granted, unless it was
            // told otherwise.
            if front { return true }
            return said ? false : nil
        }
    }

    /// The report was handed on for sending, or the program asks for none.
    mutating func told(_ gained: Bool) { said = gained }

    /// A report that the focus was gained is handed on for sending at `time`.
    mutating func gainedHanded(at time: Double) {
        gainedHandedAt = time
        gainedCount += 1
    }

    /// It was not taken after all.
    mutating func gainedDropped() { gainedHandedAt = nil }

    /// Its write left at `time`: the program's window runs from here.
    mutating func gainedLeft(at time: Double) {
        gainedAt = time
        gainedHandedAt = nil
    }

    /// How long a report handed on counts as still on its way. One that never leaves (its
    /// stream stopped) is forgotten after this.
    static let handedLife = 4.0

    /// A click made at `now` must take its turn behind a report that the focus was gained:
    /// one is still on its way, or its window has not passed.
    func holdsClick(at now: Double) -> Bool {
        if let handed = gainedHandedAt, now - handed >= 0, now - handed < Self.handedLife { return true }
        return clickWait(at: now) > 0
    }

    /// How long a click whose turn comes at `now` waits before it is written, so that it is
    /// not the first thing after a report that the focus was gained: the rest of
    /// `activationWindow`, or 0.
    func clickWait(at now: Double) -> Double {
        guard let gainedAt else { return 0 }
        let left = Self.activationWindow - (now - gainedAt)
        return left > 0 && left <= Self.activationWindow ? left : 0
    }
}
