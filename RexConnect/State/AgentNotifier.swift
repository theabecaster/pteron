import UIKit
import UserNotifications

/// Local notifications and the "agent is waiting" haptic. One instance, shared by every server,
/// so the throttle holds across servers.
@MainActor
final class AgentNotifier {
    /// Several agents often block at once (or one flaps between working and blocked); one buzz
    /// per this many seconds is enough to get attention.
    static let hapticInterval: TimeInterval = 3

    private var askedForAuthorization = false
    private var lastHaptic: Date?
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// Asks once per launch. iOS shows the prompt only the first time; later calls are cheap
    /// but needless.
    func requestAuthorizationIfNeeded() {
        guard !askedForAuthorization else { return }
        askedForAuthorization = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func post(title: String, body: String) {
        requestAuthorizationIfNeeded()
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
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
