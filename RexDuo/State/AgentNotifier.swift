import UIKit

/// Something in a pane wants the user, as seen by a live connection: an agent started waiting
/// (OSC 7501 `blocked`), or a program sent a desktop notification (OSC 9 / 777).
struct AgentAlert: Equatable, Identifiable {
    enum Kind: Equatable {
        /// An agent waits for the user. Outranks a notice.
        case waiting
        /// A program's desktop notification.
        case notice
    }

    let id = UUID()
    var serverID: UUID
    var sessionID: String
    var windowID: String?
    var blockID: String
    /// "Claude has a question", or a notice's title.
    var title: String
    /// Where it runs, and the agent's or program's message if it sent one.
    var body: String
    var date: Date
    var kind: Kind = .waiting
}

/// In-app alerts and the "agent is waiting" haptic. One instance, shared by every server, so the
/// throttle holds across servers. The app shows no system notifications while it runs: the toast
/// in Features/Notifications reads `latest` for waiting agents and drains `notices`. Pushes come
/// from the Mac's helper when the app is in the background.
@MainActor
@Observable
final class AgentNotifier {
    /// Several agents often block at once (or one flaps between working and blocked); one buzz
    /// per this many seconds is enough to get attention.
    static let hapticInterval: TimeInterval = 3
    /// Notices waiting to be decided, at most; past it the oldest of the pane with the most goes.
    static let noticeLimit = 50
    /// One pane's notices waiting to be decided, at most; past it that pane's oldest goes, so a
    /// noisy pane never pushes out another pane's notices.
    static let perPaneLimit = 5

    /// The newest waiting alert. Observers react to its `id` changing, so alerts posted in one
    /// turn of the main actor collapse to the newest.
    private(set) var latest: AgentAlert?
    /// Changes with each notice posted. Observers drain `takeNotices()` on a change, so every
    /// notice is decided, in order, however many came in one turn.
    private(set) var noticeSerial = 0

    @ObservationIgnored private var notices: [AgentAlert] = []
    @ObservationIgnored private var lastHaptic: Date?
    @ObservationIgnored private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// A waiting agent. Notices go through `postNotice`.
    func post(_ alert: AgentAlert) {
        latest = alert
    }

    /// A program's notice, queued for the toast. No haptic: only waiting agents buzz.
    func postNotice(_ alert: AgentAlert) {
        if notices.lazy.filter({ $0.blockID == alert.blockID }).count >= Self.perPaneLimit,
           let oldest = notices.firstIndex(where: { $0.blockID == alert.blockID }) {
            notices.remove(at: oldest)
        }
        notices.append(alert)
        if notices.count > Self.noticeLimit {
            // The oldest notice of the panes with the most queued: with one each, the oldest.
            let counts = Dictionary(notices.map { ($0.blockID, 1) }, uniquingKeysWith: +)
            if let most = counts.values.max(),
               let oldest = notices.firstIndex(where: { counts[$0.blockID] == most }) {
                notices.remove(at: oldest)
            }
        }
        noticeSerial &+= 1
    }

    /// The queued notices, oldest first, and an empty queue.
    func takeNotices() -> [AgentAlert] {
        defer { notices = [] }
        return notices
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
