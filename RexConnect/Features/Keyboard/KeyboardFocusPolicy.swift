import UIKit

/// Decides when a pane's terminal takes the keyboard (first responder) without a tap.
///
/// With a hardware keyboard the active pane holds the keyboard, as on a Mac: keys go to the pane on
/// screen. Without one, a pane takes the keyboard only to keep what it had: across a fold or unfold
/// (the pane's view moves to a new place), and from another pane when the active pane changes.
/// A text field, a sheet and a keyboard the user put away are never overridden.
enum KeyboardFocusPolicy {
    /// Who has the keyboard now.
    enum Holder: Equatable {
        case nobody
        /// Another pane's terminal.
        case terminal
        /// A text field or text view (Settings, a rename field, search).
        case textInput
        /// Something that types nothing (a SwiftUI hosting view, a view controller).
        case other
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
        guard s.paneActive, s.inWindow, s.appActive, !s.holdsKeyboard, !s.sheetUp, !s.userHidKeyboard else { return false }
        switch s.holder {
        case .textInput: return false
        // The keyboard follows the active pane, hardware or not.
        case .terminal: return true
        case .nobody, .other: return s.hardwareKeyboard || s.hadKeyboard
        }
    }

    /// App-wide shortcuts from the app's menu (`AppShortcutCommands`) run only when no terminal can
    /// take the key: never under a sheet, and never while a text field is being edited (⌘W in a
    /// rename field must not close a pane).
    static func runsAppShortcut(holder: Holder, sheetUp: Bool) -> Bool {
        !sheetUp && holder != .textInput
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

    /// Classifies the app's first responder, seen from the pane whose engine view is `own`.
    @MainActor
    static func holder(_ responder: UIResponder?, own: UIView?) -> Holder {
        guard let responder else { return .nobody }
        if responder === own { return .nobody }
        // An engine view may decline unknown actions, so a focused terminal can report its host.
        if responder is any TerminalEngineView || responder is TerminalHost { return .terminal }
        if responder is any UIKeyInput { return .textInput }
        return .other
    }

    /// A sheet, an alert or a menu is presented over the window's root.
    @MainActor
    static func sheetUp(in window: UIWindow?) -> Bool {
        window?.rootViewController?.presentedViewController != nil
    }
}
