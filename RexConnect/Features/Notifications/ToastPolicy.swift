import Foundation

/// The one in-app toast on screen: the newest waiting agent, plus the other waiting agents folded
/// into it while it showed.
struct AgentToast: Equatable, Identifiable {
    /// Stays the same while the toast updates in place, so it doesn't animate in again.
    let id: UUID
    var alert: AgentAlert
    /// Other blocks that alerted while this toast was up.
    var others: Set<String>
}

/// When an agent alert becomes a toast. Pure, so it's tested without a screen.
///
/// - Only while the app is in front (the Mac's helper pushes otherwise) and only for a pane the
///   user isn't looking at.
/// - Never more than one toast: a new alert updates the one on screen and counts the rest.
/// - A sheet or alert over the app holds the toast until it closes.
/// - The same pane toasts at most once per `cooldown`, so an agent that flaps between working and
///   waiting doesn't nag.
enum ToastPolicy {
    struct Context: Equatable {
        var appActive = true
        /// Blocks whose terminal is on screen now.
        var visibleBlocks: Set<String> = []
        /// A sheet, cover or alert hides the app's own screen.
        var modalPresented = false
    }

    enum Reason: Equatable { case background, looking, recentlyShown }

    enum Decision: Equatable {
        case show(AgentToast)
        case update(AgentToast)
        /// Hold it until the modal closes, then decide again.
        case hold
        case suppress(Reason)
    }

    static let cooldown: TimeInterval = 30
    /// How long a toast stays up; an update restarts it.
    static let lifetime: TimeInterval = 6
    /// A held alert older than this is dropped.
    static let holdLimit: TimeInterval = 120

    static func decide(_ a: AgentAlert, context c: Context, current: AgentToast?,
                       lastShown: [String: Date], now: Date) -> Decision {
        guard c.appActive else { return .suppress(.background) }
        if c.visibleBlocks.contains(a.blockID) { return .suppress(.looking) }
        if c.modalPresented { return .hold }
        if var t = current {
            if t.alert.blockID != a.blockID { t.others.insert(t.alert.blockID) }
            t.others.remove(a.blockID)
            t.alert = a
            return .update(t)
        }
        if let last = lastShown[a.blockID], now.timeIntervalSince(last) < cooldown { return .suppress(.recentlyShown) }
        return .show(AgentToast(id: UUID(), alert: a, others: []))
    }

    /// A held alert is offered again only while it's recent and the agent still waits.
    static func worthOfferingAgain(_ a: AgentAlert, stillWaiting: Bool, now: Date) -> Bool {
        stillWaiting && now.timeIntervalSince(a.date) < holdLimit
    }

    /// Held alerts, newest per block, oldest first.
    static func hold(_ a: AgentAlert, in held: [AgentAlert]) -> [AgentAlert] {
        held.filter { $0.blockID != a.blockID } + [a]
    }
}
