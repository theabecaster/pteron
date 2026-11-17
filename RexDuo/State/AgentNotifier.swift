import UIKit

/// An agent started waiting for the user (OSC 7501 `blocked`), as seen by a live connection.
struct AgentAlert: Equatable, Identifiable {
    let id = UUID()
    var serverID: UUID
    var sessionID: String
    var windowID: String?
    var blockID: String
    /// "Claude has a question".
    var title: String
    /// Where it runs, and the agent's message if it sent one.
    var body: String
    var date: Date
}

/// In-app agent alerts and the "agent is waiting" haptic. One instance, shared by every server,
/// so the throttle holds across servers. The app shows no system notifications while it runs:
/// the toast in Features/Notifications reads `latest`. Pushes come from the Mac's helper when the
/// app is in the background.
@MainActor
@Observable
final class AgentNotifier {
    /// Several agents often block at once (or one flaps between working and blocked); one buzz
    /// per this many seconds is enough to get attention.
    static let hapticInterval: TimeInterval = 3

    /// The newest alert. Observers react to its `id` changing.
    private(set) var latest: AgentAlert?

    @ObservationIgnored private var lastHaptic: Date?
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    func post(_ alert: AgentAlert) {
        latest = alert
    }

    /// Buzzes unless it buzzed within `hapticInterval`.
    func waitingHaptic() {
        guard shouldBuzz() else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    /// True, and records the time, when a haptic may play now.
    func shouldBuzz() -> Bool {
        let t = now()
        if let last = lastHaptic, t.timeIntervalSince(last) < Self.hapticInterval { return false }
        lastHaptic = t
        return true
    }
}
