import Foundation

/// What a pane knew when a finger went down on it. Read at touch time, so that nothing the tap
/// itself sets off (the keyboard coming up, a selection going away) changes what the tap means.
struct TerminalTapFacts: Equatable {
    /// The touch is on a selection handle.
    var onHandle = false
    /// 1 for a tap by itself, 2 and 3 for the next taps of a double or triple tap.
    var tapCount = 1
    /// The terminal had the keyboard and showed it (or its key bar).
    var keyboardUp = true
    /// Text was selected.
    var hadSelection = false
    /// Shift on a hardware keyboard: the tap is kept away from the program.
    var shift = false
    /// The edit menu (Copy, Paste) was on screen.
    var menuVisible = false
    /// The finger came down on scrollback that was moving or had just stopped
    /// (`TerminalScrollTouch`): the touch stops or ends a scroll.
    var stopsScroll = false
}

/// The one thing a single-finger tap on a pane does.
enum TerminalTapOutcome: Equatable {
    /// The handle's own press handles it.
    case handle
    /// A double tap selects the word, a triple tap the line.
    case select(line: Bool)
    /// The pane gets the keyboard and nothing else happens (a selection goes too).
    case focus(clearsSelection: Bool)
    /// The selection goes.
    case dismissSelection
    /// The engine used it: it opened the link under it or moved the shell's cursor on its prompt.
    /// The keyboard stays as it was.
    case engineUsed
    /// A mouse click for the program.
    case programClick
    /// Paste is offered at the cursor.
    case pasteMenu
    /// Nothing but closing a menu that was up.
    case nothing

    /// The only tap the program ever hears about.
    var isForProgram: Bool { self == .programClick }
}

/// The order of everything a tap can mean. A tap means the first of these that applies, and
/// only that:
///
/// 1. On a selection handle: the handle's.
/// 1a. The touch stopped a scroll: nothing. Someone reading catches a flick with a tap, and that
///    tap must not raise the keyboard, open a link, show Paste or click in the program.
/// 2. The second or third tap of a run: select the word or the line. (The first tap already did
///    what a single tap does.)
/// 3. The keyboard was not up on this pane: a link under the finger opens (`opensLink`) and the
///    keyboard stays down; anywhere else the pane is focused. Never a click, a prompt move or a
///    menu, so the tap that brings the keyboard can't also press a button in a program. A tap
///    that clears a selection or holds Shift only focuses.
/// 4. Text was selected: clear the selection.
/// 5. Shift is held: nothing.
/// 6. The engine's own use: a link under the finger opens, a tap on the shell's prompt moves
///    its cursor (Ghostty/GhosttyTap.swift has the order inside this step).
/// 7. The program tracks the mouse: a click.
/// 8. By the cursor, no menu up: the Paste menu.
/// 9. Nothing.
///
/// The questions that cost a terminal lock, or do something, are asked only when the tap gets
/// that far: `opensLink` and `engineUses` (which also perform what they find), `tracksMouse`,
/// `nearCursor`.
enum TerminalTapDecision {
    static func outcome(_ facts: TerminalTapFacts, opensLink: () -> Bool, engineUses: () -> Bool,
                        tracksMouse: () -> Bool, nearCursor: () -> Bool) -> TerminalTapOutcome {
        if facts.onHandle { return .handle }
        if facts.stopsScroll { return .nothing }
        if facts.tapCount == 2 { return .select(line: false) }
        if facts.tapCount >= 3 { return .select(line: true) }
        if !facts.keyboardUp {
            if !facts.hadSelection, !facts.shift, opensLink() { return .engineUsed }
            return .focus(clearsSelection: facts.hadSelection)
        }
        if facts.hadSelection { return .dismissSelection }
        if facts.shift { return .nothing }
        if engineUses() { return .engineUsed }
        if tracksMouse() { return .programClick }
        if !facts.menuVisible, nearCursor() { return .pasteMenu }
        return .nothing
    }
}

/// Touch rules that keep reading undisturbed: a tap that catches a scroll, and a drag that is
/// only a little sideways.
enum TerminalScrollTouch {
    /// How long after the scrollback last moved under a finger or by its own momentum a new touch
    /// still counts as catching it. Short, so a tap on a link just scrolled into view still opens.
    static let settle: CFTimeInterval = 0.15

    /// True when a touch at `now` stops or ends a scroll: the scrollback is still moving
    /// (`moving`), or it moved less than `settle` ago (`lastMoved`, the time of its last
    /// user-driven move).
    static func stopsScroll(now: CFTimeInterval, moving: Bool, lastMoved: CFTimeInterval?) -> Bool {
        if moving { return true }
        guard let lastMoved else { return false }
        return now - lastMoved < settle
    }

    /// How much more sideways than up or down a drag must be to swipe panes (or pan the canvas)
    /// instead of scrolling: about 27° from horizontal. A thumb's reading flick arcs, and a looser
    /// ratio turned some of them into pane swipes.
    static let horizontalRatio: CGFloat = 2

    static func isHorizontal(dx: CGFloat, dy: CGFloat) -> Bool {
        abs(dx) > abs(dy) * horizontalRatio
    }
}
