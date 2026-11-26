import UIKit

/// Decides when a pane's terminal takes the keyboard (first responder) without a tap.
///
/// With a hardware keyboard the active pane holds the keyboard, as on a Mac: keys go to the pane on
/// screen. Without one, a pane takes the keyboard only to keep what it had: across a fold or unfold
/// (the pane's view moves to a new place), and from another pane when the active pane changes.
/// A text field and a sheet are never overridden.
///
/// The invariant: at most one terminal is first responder, and it is the active pane's. A pane
/// that becomes active takes the keyboard from the pane that had it (`takesKeyboard`), and a pane
/// that is no longer active gives it up (`mustResign`).
///
/// Holding the keyboard and showing one are separate. After the key bar's hide key a pane shows
/// no software keyboard and no key bar until it is tapped, but it still becomes first responder
/// when the rules above say so, quietly (`takesQuietly`): otherwise a hardware keyboard would go
/// on typing into the pane that had the keyboard before.
enum KeyboardFocusPolicy {
    /// Who has the keyboard now.
    enum Holder: Equatable {
        case nobody
        /// Another pane's terminal.
        case terminal
        /// Another pane's find field. A pane takes the keyboard from it as from a terminal, and
        /// app shortcuts run from it (⌘W closes the pane, as on the Mac).
        case findField
        /// A field the app owns for one of its own surfaces (`AppFieldKind`), each with its own
        /// answer to `runsAppShortcut`.
        case appField(AppFieldKind)
        /// Another pane's compose field (`ComposeField`). A pane takes the keyboard from it as from
        /// a terminal; app shortcuts don't run from it, as from any text field.
        case composeField
        /// A text field or text view (Settings, a rename field).
        case textInput
        /// Something that types nothing (a SwiftUI hosting view, a view controller).
        case other
    }

    /// The app's own fields beside find's. Later surfaces (the palette, the file browser's
    /// search) add their kind here and their `runsAppShortcut` answer.
    enum AppFieldKind: Equatable {
        /// The palette's search field (`PaletteField`). No pane takes the keyboard from it, and
        /// no menu key runs while it edits: the palette's own keys reach it through
        /// `AppShortcutCommands`, which hands them to the palette first.
        case palette
    }

    struct Situation: Equatable {
        /// The pane is the tab's active pane.
        var paneActive = true
        var inWindow = true
        var appActive = true
        /// This pane's terminal already is first responder.
        var holdsKeyboard = false
        var hardwareKeyboard = false
        /// The pane had the keyboard when its view was moved (fold, unfold, a layout swap).
        var hadKeyboard = false
        /// The user put the keyboard away (the key bar's hide key); a tap brings it back.
        var userHidKeyboard = false
        /// A sheet or an alert covers the pane.
        var sheetUp = false
        var holder: Holder = .nobody
    }

    static func takesKeyboard(_ s: Situation) -> Bool {
        guard s.paneActive, s.inWindow, s.appActive, !s.holdsKeyboard, !s.sheetUp else { return false }
        switch s.holder {
        case .textInput: return false
        case .appField(let kind): switch kind { case .palette: return false }
        // The keyboard follows the active pane, hardware or not: no other pane may keep it,
        // in its terminal or in its find field.
        case .terminal, .findField, .composeField: return true
        // Free: a hardware keyboard always types into the active pane. Without one there is
        // only a software keyboard to bring back, and not after the user put it away.
        case .nobody, .other: return s.hardwareKeyboard || (s.hadKeyboard && !s.userHidKeyboard)
        }
    }

    /// A pane that takes the keyboard after the user put it away there takes it quietly: first
    /// responder, with no software keyboard and no key bar. A tap shows them again.
    static func takesQuietly(_ s: Situation) -> Bool { s.userHidKeyboard }

    /// A pane that is not the active one must not hold the keyboard.
    static func mustResign(paneActive: Bool, holdsKeyboard: Bool) -> Bool { holdsKeyboard && !paneActive }

    /// App-wide shortcuts from the app's menu (`AppShortcutCommands`) run only when no terminal can
    /// take the key: never under a sheet, and never while a text field is being edited (⌘W in a
    /// rename field must not close a pane).
    /// A find field passes: its find keys and the app's commands work there as on the Mac.
    static func runsAppShortcut(holder: Holder, sheetUp: Bool) -> Bool {
        guard !sheetUp else { return false }
        switch holder {
        case .textInput, .composeField: return false
        case .appField(let kind): switch kind { case .palette: return false }
        case .nobody, .terminal, .findField, .other: return true
        }
    }

    /// Limits how often a pane takes the keyboard back after its view was moved. Taking the keyboard
    /// changes the layout (the key bar or the keyboard shows), a layout change can move the pane's
    /// view, and UIKit takes the keyboard from a view it moves: without a limit, a layout that flips
    /// with the keyboard would take and lose it forever.
    struct RetakeLimiter {
        static let window: CFTimeInterval = 2
        static let most = 3
        private var times: [CFTimeInterval] = []

        /// True, and counted, when another retake is allowed at `now`.
        mutating func allows(at now: CFTimeInterval) -> Bool {
            times.removeAll { now - $0 > Self.window }
            guard times.count < Self.most else { return false }
            times.append(now)
            return true
        }
    }

    /// Classifies the app's first responder, seen from the pane whose engine view is `own` and
    /// whose find fields are `ownFields`: the pane's own views are nobody else's. Any other
    /// pane's find field is `.findField`.
    @MainActor
    static func holder(_ responder: UIResponder?, own: UIView?, ownFields: [UIView] = []) -> Holder {
        guard let responder else { return .nobody }
        if responder === own || ownFields.contains(where: { $0 === responder }) { return .nobody }
        if responder is FindField { return .findField }
        if responder is PaletteField { return .appField(.palette) }
        if responder is ComposeField { return .composeField }
        // The terminal view may decline unknown actions, so a focused terminal can report its host.
        if responder is GhosttyTerminalView || responder is TerminalHost { return .terminal }
        if responder is any UIKeyInput { return .textInput }
        return .other
    }

    /// A sheet, an alert or a menu is presented over the window's root. One on its way out
    /// no longer counts: the pane under it takes the keyboard back as it goes.
    @MainActor
    static func sheetUp(in window: UIWindow?) -> Bool {
        guard let presented = window?.rootViewController?.presentedViewController else { return false }
        return !presented.isBeingDismissed
    }
}
