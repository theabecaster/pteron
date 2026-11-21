import Foundation
import GlanceModel
import RexKit

/// "Open in Browser" for a port: where it is offered, and what a tap that didn't open says.
/// Pure, so it is tested (docs/terminal.md, Ports).
///
/// The page opens in the iPhone's own browser at an address the computer's Beacon hands out for
/// that port and this phone. The UI never names how: a row that has such an address says
/// "In browser", and every failure is one calm line in plain words.
enum PortBrowser {
    /// A port a computer may hand out at all: plain web ports the program listens on at the
    /// computer's own loopback. The Beacon refuses the rest, so they are not offered.
    static func mayAsk(_ entry: PortEntry) -> Bool {
        guard entry.port >= 1024 || entry.port == 80 else { return false }
        let host = entry.dialHost.lowercased()
        return host == "localhost" || host == "::1" || LocalhostLink.isLoopbackV4(host)
    }

    /// The page as an in-app open may load it from the computer's address: plain http to the
    /// computer's loopback. A LAN address or https opens the old way.
    static func mayLoad(_ link: LocalhostLink) -> Bool {
        guard link.scheme == "http" else { return false }
        let host = link.dialHost.lowercased()
        return host == "localhost" || host == "::1" || LocalhostLink.isLoopbackV4(host)
    }

    /// What the row adds to its address line while its page is out in the browser.
    static let rowWords = "In browser"

    enum Problem: Error, Equatable {
        case offline
        /// The phone has no tailnet address now.
        case noAddress
        /// No Beacon answered, or not in time.
        case unanswered
        /// The Beacon's error, by its code.
        case refused(code: String, unknownAction: Bool)
        /// The answer held no address the app would open.
        case badAnswer
    }

    /// One line for a tap that opened nothing. `name`: `localhost:3000`. `computer`: its name
    /// in the sidebar.
    static func notice(_ problem: Problem, name: String, computer: String) -> String {
        switch problem {
        case .offline:
            return "\(computer) is offline. Try again when it's back."
        case .noAddress:
            return "Couldn't open \(name) in the browser: Tailscale is off on this iPhone."
        case .unanswered:
            return "Couldn't open \(name) in the browser: \(computer) didn't answer."
        case .badAnswer:
            return "Couldn't open \(name) in the browser. Try again in a moment."
        case .refused(let code, let unknownAction):
            if unknownAction { return "Couldn't open \(name) in the browser: \(Brand.beaconName) on \(computer) needs an update." }
            switch code {
            case "not_available":
                return "\(computer) can't open pages in this iPhone's browser. \(name) still opens here."
            case "not_registered":
                return "Couldn't open \(name) in the browser: this iPhone isn't set up with \(Brand.beaconName) on \(computer)."
            case "not_your_phone":
                return "Couldn't open \(name) in the browser: this iPhone and \(computer) aren't on the same Tailscale account."
            case "not_listening":
                return "Nothing is running on \(name) now."
            case "busy":
                return "\(computer) has too many pages open in the browser. Try again later."
            case "refused":
                return "\(name) doesn't open in a browser."
            case "failed":
                return "Couldn't open \(name) in the browser: \(computer) couldn't get it ready."
            default:
                return "Couldn't open \(name) in the browser. Try again in a moment."
            }
        }
    }
}

/// What Restart says. Pure, so it is tested.
enum PortRestartCopy {
    /// The confirmation's first line: exactly what will be typed.
    static func confirm(_ command: RestartCommand) -> String { "Restart: \(command.text)" }
    /// Its second line. It doesn't say the command is the one typed before: variables set in
    /// front of it and aliases can't be read back.
    static let detail = "Runs this command again in its pane."
    static let restarting = "Restarting…"
    static let failed = "Couldn't restart"

    /// One line for a Restart that ended early. `name`: the program. `address`: `localhost:3000`.
    static func notice(_ failure: PortRestart.Failure, name: String, address: String) -> String {
        switch failure {
        case .changed: "Couldn't restart \(name): what runs in its pane changed. Nothing was typed."
        case .paneNotReady: "Couldn't restart \(name): its pane didn't come up in time. Nothing was typed."
        case .notStopped: "Couldn't restart \(name): it couldn't be stopped from here. Nothing was typed."
        case .stillRunning: "\(name) didn't stop, so it wasn't started again."
        case .notTyped: "\(name) stopped, but its command wasn't sent. Start it again in its pane."
        case .noPort: "\(name) was started again, but nothing is running on \(address) yet."
        }
    }
}
