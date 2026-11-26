import Foundation
import RexKit

/// The messages the app says in more than one place, each worded once. A computer is named by
/// its name, never as "the server" or "the Mac"; a server's own error text, an error's
/// `localizedDescription` and an action's id never reach the user (`reason(_:computer:)`).
enum Messages {
    // MARK: Reaching a computer

    /// The computer doesn't answer: asleep, or Rex isn't running.
    static func asleep(_ name: String) -> String {
        "\(capitalized(name)) isn't answering. It may be asleep, or Rex isn't running there. Wake it or open Rex, then try again."
    }
    static let asleepShort = "Not answering"

    /// This iPhone's network can't reach the computer.
    static func outOfRange(_ name: String) -> String {
        "Can't reach \(name) from this network. Connect this \(DeviceWord.current) to the same network or VPN as \(name), then try again."
    }
    static let outOfRangeShort = "Out of range"

    /// This iPhone is on a tailnet, but not the one the computer's Tailscale name is on.
    static func otherTailscaleAccount(_ name: String) -> String {
        "Tailscale on this \(DeviceWord.current) is signed in to a different account than \(name)."
    }
    static let otherTailscaleAccountFix = "Sign in with the account you used in Rex."

    /// Known before anything was tried: the computer is offline.
    static func offline(_ name: String) -> String { "\(capitalized(name)) is offline. Try again when it's back." }

    // MARK: Sending

    /// It never left this iPhone: the connection dropped first.
    static func notSent(_ name: String) -> String { "Not sent: the connection to \(name) dropped. Try again when it's back." }

    /// It left, and the connection dropped before the answer: it may have run.
    static let sentUnknown = "The connection dropped while sending. Check the pane before trying again."

    /// The pane was still reconnecting, so nothing was sent.
    static let stillReconnecting = "Not sent: the pane was still reconnecting. Try again in a moment."

    /// The screen changed under input that was held, so nothing was sent.
    static let paneChanged = "The pane changed. Nothing was sent."

    /// The pane on screen closed.
    static let thisPaneClosed = "This pane closed."
    /// A pane that isn't on screen, or that the user acted on a moment ago, closed.
    static let paneClosed = "That pane closed."

    // MARK: Rex

    /// Rex on the computer lacks what this needs.
    static func rexTooOld(_ name: String) -> String { "Rex on \(name) is too old for this. Update Rex there." }
    /// The same, saying what it was for: "send files", "open files", "browse folders".
    static func updateRex(_ name: String, to what: String) -> String { "Update Rex on \(name) to \(what)." }

    /// The computer answered with an error.
    static func refused(_ name: String) -> String { "\(capitalized(name)) refused it." }
    /// What it acted on is no longer there.
    static let gone = "It's gone."

    // MARK: Lists

    /// Nothing paired yet, wherever a list of computers would be.
    static let noComputers = "No computers yet. Pair one in Settings."

    /// "1 computer", "3 computers".
    static func computers(_ n: Int) -> String { n == 1 ? "1 computer" : "\(n) computers" }

    // MARK: Errors

    /// Why a call to `name` failed, in words: by what happened, never by the error's own text.
    /// - Never sent: the connection dropped first.
    /// - Sent and the connection broke, or any error that isn't the server's: the connection dropped.
    /// - The thing is gone, Rex there is too old, or the server refused it.
    static func reason(_ error: Error, computer name: String) -> String {
        switch Failure(error) {
        case .notSent: notSent(name)
        case .dropped: "The connection to \(name) dropped."
        case .gone: gone
        case .tooOld: rexTooOld(name)
        case .refused: refused(name)
        }
    }

    /// "Couldn't close the tab. Desk refused it."
    static func couldNot(_ what: String, _ error: Error, computer name: String) -> String {
        "Couldn't \(what). \(reason(error, computer: name))"
    }

    /// What kind of failure an error is, read from its code alone.
    enum Failure: Equatable {
        case notSent, dropped, gone, tooOld, refused

        init(_ error: Error) {
            guard let e = error as? RexError else {
                self = .dropped
                return
            }
            if e.neverSent { self = .notSent; return }
            switch e.code {
            case "client": self = .dropped
            case "not_found", "session_not_found", "block_not_found", "window_not_found": self = .gone
            case "revision_too_low", "method_not_found", "not_supported": self = .tooOld
            default: self = .refused
            }
        }
    }

    // MARK: A pane's input and actions

    /// What a pane's stream reports, worded. `title` names an action as the palette does
    /// (`KeymapStore.title(forAction:)`), never by its id.
    static func stream(_ notice: TerminalStream.Notice, computer name: String, title: (String) -> String) -> String {
        switch notice {
        case .paneChanged: paneChanged
        case .stillReconnecting: stillReconnecting
        case .inputLost: sentUnknown
        case .actionNotSent(let action, let given):
            "Didn't run \(given ?? title(action)). \(notSent(name))"
        case .actionLost(let action, let given):
            "The connection dropped while running \(given ?? title(action)). Check the pane before trying again."
        case .actionRefused(let action, let given, let code):
            "Couldn't run \(given ?? title(action)). \(reason(RexError(code: code, message: ""), computer: name))"
        }
    }

    /// A palette pick that couldn't leave this iPhone.
    static func didNotRun(_ title: String, computer name: String) -> String { "Didn't run \(title). \(notSent(name))" }

    // Why an agent waits is worded once, for the app, the widgets and the watch alike:
    // `WatchScreen.words(why:)` and `WatchScreen.sentence(_:why:)` in GlanceModel.

    // MARK: Helpers

    /// A name at the start of a sentence.
    static func capitalized(_ name: String) -> String { name.prefix(1).uppercased() + name.dropFirst() }
}
