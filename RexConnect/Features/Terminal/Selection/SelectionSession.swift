import CoreGraphics
import Foundation

/// One of the two ends of a selection, in reading order.
enum SelectionHandle: Equatable {
    case start, end
}

/// What a selection gesture feels like. `SystemSelectionFeedback` maps each to a generator.
enum SelectionHaptic: Equatable {
    /// The long press became a selection: text is highlighted now.
    case start
    /// A handle was grabbed, or a long press landed where there is no word yet.
    case grab
    /// The moving end of the selection crossed into another row.
    case tick
    /// The selection was copied to the clipboard (in step with the shimmer).
    case copy
}

/// The selection gesture as a state machine: long press, drag, lift, handle adjustment, clear.
/// It decides what happens and when (haptics, loupe, handles, copy-on-select, edit menu) and
/// touches nothing itself, so tests drive it with plain values. `TerminalSelectionController`
/// feeds it events and performs the effects it returns.
///
/// Effects are an option set, not an array: a drag event allocates nothing.
struct SelectionSession: Equatable {
    enum Phase: Equatable {
        /// No selection UI. (A selection made elsewhere, such as ⌘A, may still exist.)
        case idle
        /// A long press is down and may be dragging.
        case pressing
        /// A selection stands with its handles, after the finger lifted.
        case selected
        /// A handle is being dragged.
        case adjusting(SelectionHandle)
    }

    struct Effects: OptionSet, Equatable {
        let rawValue: Int
        /// Wake the Taptic Engine: feedback is likely within a second or two.
        static let prepare = Effects(rawValue: 1 << 0)
        static let hapticStart = Effects(rawValue: 1 << 1)
        static let hapticGrab = Effects(rawValue: 1 << 2)
        static let hapticTick = Effects(rawValue: 1 << 3)
        /// Copy-on-select: clipboard, the copy haptic and the shimmer, together.
        static let copy = Effects(rawValue: 1 << 4)
        static let showLoupe = Effects(rawValue: 1 << 5)
        static let moveLoupe = Effects(rawValue: 1 << 6)
        static let hideLoupe = Effects(rawValue: 1 << 7)
        /// Show the handles, or move them to where the selection's ends are now.
        static let showHandles = Effects(rawValue: 1 << 8)
        static let hideHandles = Effects(rawValue: 1 << 9)
        static let showMenu = Effects(rawValue: 1 << 10)
        static let hideMenu = Effects(rawValue: 1 << 11)
    }

    /// Row ticks closer together than this are dropped: a fast drag or an edge autoscroll would
    /// otherwise buzz.
    static let tickInterval: TimeInterval = 0.06

    private(set) var phase = Phase.idle
    /// The press under way has highlighted something.
    private var highlighted = false
    /// The handle drag under way has moved its end.
    private var adjusted = false
    private var lastCell: TerminalGridCell?
    private var lastTick = -TimeInterval.infinity

    /// True while a finger owns the selection: nothing else may scroll, swipe or pinch.
    var isTracking: Bool {
        switch phase {
        case .pressing, .adjusting: true
        case .idle, .selected: false
        }
    }

    // MARK: Long press

    /// A finger touched the pane. A long press may follow in under half a second.
    func touchDown() -> Effects { .prepare }

    /// The long press was recognized. `selected`: the engine found a word under it.
    mutating func pressBegan(selected: Bool, cell: TerminalGridCell?) -> Effects {
        phase = .pressing
        highlighted = selected
        lastCell = cell
        // Ticks and the copy confirmation come next: keep the engine awake for them.
        return [.hideMenu, .hideHandles, .showLoupe, selected ? .hapticStart : .hapticGrab, .prepare]
    }

    /// The finger moved, or the view scrolled under it. `selected`: there is a selection now.
    mutating func pressMoved(selected: Bool, cell: TerminalGridCell?, now: TimeInterval) -> Effects {
        guard phase == .pressing else { return [] }
        var effects: Effects = .moveLoupe
        if selected, !highlighted {
            // A press on blank space: the first cell the drag covers is where highlighting starts.
            highlighted = true
            effects.formUnion([.hapticStart, .prepare])
        } else if selected {
            effects.formUnion(tick(to: cell, now: now))
        }
        lastCell = cell ?? lastCell
        return effects
    }

    /// The finger lifted. With a selection: copy it, show its handles and the menu. Without:
    /// the menu alone (Paste).
    mutating func pressEnded(selected: Bool) -> Effects {
        guard phase == .pressing else { return [] }
        phase = selected ? .selected : .idle
        highlighted = false
        return selected ? [.hideLoupe, .copy, .showHandles, .showMenu] : [.hideLoupe, .hideHandles, .showMenu]
    }

    /// The system took the touch away. Whatever is selected stays, uncopied.
    mutating func pressCancelled(selected: Bool) -> Effects {
        guard phase == .pressing else { return [] }
        phase = selected ? .selected : .idle
        highlighted = false
        return selected ? [.hideLoupe, .showHandles] : [.hideLoupe, .hideHandles]
    }

    // MARK: Handles

    /// A finger landed on a handle.
    mutating func handleGrabbed(_ handle: SelectionHandle, cell: TerminalGridCell?) -> Effects {
        guard phase == .selected else { return [] }
        phase = .adjusting(handle)
        adjusted = false
        lastCell = cell
        return [.hideMenu, .hapticGrab, .showLoupe, .prepare]
    }

    /// The handle moved to `cell`, or the view scrolled under it.
    mutating func handleMoved(cell: TerminalGridCell?, now: TimeInterval) -> Effects {
        guard case .adjusting = phase else { return [] }
        var effects: Effects = [.moveLoupe, .showHandles]
        if let cell, let last = lastCell, cell != last { adjusted = true }
        effects.formUnion(tick(to: cell, now: now))
        lastCell = cell ?? lastCell
        return effects
    }

    /// The handle was let go. An adjustment that changed the selection copies it again; a grab
    /// that moved nothing doesn't.
    mutating func handleReleased(selected: Bool) -> Effects {
        guard case .adjusting = phase else { return [] }
        phase = selected ? .selected : .idle
        guard selected else { return [.hideLoupe, .hideHandles] }
        var effects: Effects = [.hideLoupe, .showHandles, .showMenu]
        if adjusted { effects.insert(.copy) }
        return effects
    }

    mutating func handleCancelled(selected: Bool) -> Effects {
        guard case .adjusting = phase else { return [] }
        phase = selected ? .selected : .idle
        return selected ? [.hideLoupe, .showHandles] : [.hideLoupe, .hideHandles]
    }

    // MARK: Taps and commands

    /// A double tap (word) or triple tap (line) made a selection, or found nothing to select.
    mutating func tapSelected(_ selected: Bool) -> Effects {
        phase = selected ? .selected : .idle
        return selected ? [.copy, .showHandles, .showMenu] : [.hideHandles, .hideMenu]
    }

    /// Select All. Nothing is copied until the user says so: it can be the whole scrollback.
    mutating func selectedAll(_ selected: Bool, showsMenu: Bool) -> Effects {
        phase = selected ? .selected : .idle
        guard selected else { return [.hideHandles, .hideMenu] }
        return showsMenu ? [.showHandles, .showMenu] : [.showHandles]
    }

    /// The selection is gone: a tap elsewhere, Copy from the menu, a paste, or the terminal
    /// dropped it (a reset).
    mutating func cleared() -> Effects {
        guard phase != .idle else { return [] }
        phase = .idle
        highlighted = false
        return [.hideLoupe, .hideHandles, .hideMenu]
    }

    // MARK: Ticks

    /// One tick when the moving end enters another row, at most one per `tickInterval`.
    private mutating func tick(to cell: TerminalGridCell?, now: TimeInterval) -> Effects {
        guard let cell, let last = lastCell, cell.row != last.row, now - lastTick >= Self.tickInterval else { return [] }
        lastTick = now
        // A generator sleeps again after it fires: wake it for the next row.
        return [.hapticTick, .prepare]
    }
}

/// Counts taps that follow each other closely in time and place: 1, 2, 3, then 1 again.
struct SelectionTapCounter: Equatable {
    static let interval: TimeInterval = 0.35
    static let distance: CGFloat = 28

    private var count = 0
    private var lastTime = -TimeInterval.infinity
    private var lastPoint = CGPoint.zero

    /// True if a tap at `point` now would be the second or third of a run.
    func continues(at point: CGPoint, now: TimeInterval) -> Bool {
        let near = abs(point.x - lastPoint.x) <= Self.distance && abs(point.y - lastPoint.y) <= Self.distance
        return now - lastTime <= Self.interval && near && count >= 1 && count < 3
    }

    mutating func tap(at point: CGPoint, now: TimeInterval) -> Int {
        count = continues(at: point, now: now) ? count + 1 : 1
        lastTime = now
        lastPoint = point
        return count
    }

    mutating func reset() { self = SelectionTapCounter() }
}

/// The rules that need no view: where a drag counts as at an edge, and when a tap shows Paste.
enum SelectionRules {
    /// A finger this close to the top or bottom of the visible terminal scrolls it, a line per
    /// `autoscrollInterval`, for as long as it stays there.
    static let edgeZone: CGFloat = 18
    static let autoscrollInterval: TimeInterval = 0.06

    /// -1 at the top edge of `visible`, 1 at the bottom edge, else 0.
    static func edge(of point: CGPoint, in visible: CGRect) -> Int {
        if point.y < visible.minY + edgeZone { return -1 }
        if point.y > visible.maxY - edgeZone { return 1 }
        return 0
    }

    /// SwiftTerm's rule for the cursor's menu: a tap within 3 columns and 1 row of the cursor,
    /// on a focused terminal, that cleared no selection and isn't a click for the program.
    static func tapShowsPaste(tap: TerminalGridCell?, cursor: TerminalGridCell?, focused: Bool, clearedSelection: Bool,
                              tapsGoToProgram: Bool, menuVisible: Bool) -> Bool {
        guard focused, !clearedSelection, !tapsGoToProgram, !menuVisible, let tap, let cursor else { return false }
        return abs(tap.col - cursor.col) < 4 && abs(tap.row - cursor.row) < 2
    }
}
