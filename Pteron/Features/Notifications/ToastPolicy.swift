import Foundation

/// The one in-app toast on screen: the newest waiting agent, plus the other waiting agents folded
/// into it while it showed; or a program's notice, plus the other panes whose notices waited
/// for it.
struct AgentToast: Equatable, Identifiable {
    /// Stays the same while the toast updates in place, so it doesn't animate in again.
    let id: UUID
    var alert: AgentAlert
    /// Other blocks that alerted while this toast was up, or whose notices it stands for.
    var others: Set<String>
}

/// When an agent alert becomes a toast. Pure, so it's tested without a screen. Notices have
/// their own rules, below.
///
/// - Only while the app is in front (the Mac's helper pushes otherwise) and only for a pane the
///   user isn't looking at.
/// - Never more than one toast: a new alert updates the one on screen and counts the rest.
/// - A sheet or alert over the app holds the toast until it closes.
/// - No toast over the agent board, which lists every waiting agent itself.
/// - The same pane toasts at most once per `cooldown`, so an agent that flaps between working and
///   waiting doesn't nag.
enum ToastPolicy {
    struct Context: Equatable {
        var appActive = true
        /// Blocks whose terminal is on screen now.
        var visibleBlocks: Set<String> = []
        /// A sheet, cover or alert hides the app's own screen.
        var modalPresented = false
        /// The agent board covers the tab. It already shows who waits.
        var boardShowing = false
    }

    enum Reason: Equatable { case background, board, looking, recentlyShown }

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
        if c.boardShowing { return .suppress(.board) }
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

    // MARK: Notices
    //
    // A program's desktop notification (OSC 9 / 777) ranks below a waiting agent and never
    // updates a toast. One that can't show now waits in one slot, deferred, never dropped, and
    // the slot shows later as one toast that counts the rest. A sheet or the agent board holds
    // notices per pane; the board only drops waiting alerts, which it lists itself.

    /// At least this long between two notice toasts.
    static let noticeGap: TimeInterval = 10
    /// The same pane's notice toasts at most once per this long; inside it a notice waits in the
    /// slot.
    static let noticeCooldown: TimeInterval = 30
    /// The same text from the same pane within this long is a repeat, and dropped.
    static let noticeRepeat: TimeInterval = 30
    /// No notice toast this soon after the app comes to the front: what came while it was away
    /// was the helper's to push.
    static let quietAfterActive: TimeInterval = 2

    enum NoticeReason: Equatable { case background, waking, looking, repeated }

    enum NoticeDecision: Equatable {
        case show
        /// Wait in the slot: a toast is up, or the gap or the pane's cooldown hasn't passed.
        case slot
        /// Hold it while a sheet or the board covers the screen.
        case hold
        case suppress(NoticeReason)
    }

    /// The text a notice is compared by for repeats.
    static func noticeText(_ n: AgentAlert) -> String { n.title + "\n" + n.body }

    static func decideNotice(_ n: AgentAlert, context c: Context, toastShowing: Bool, activeSince: Date?,
                             lastNoticeToast: Date?, lastShown: Date?, lastText: (text: String, at: Date)?,
                             now: Date) -> NoticeDecision {
        guard c.appActive else { return .suppress(.background) }
        if let s = activeSince, now.timeIntervalSince(s) < quietAfterActive { return .suppress(.waking) }
        if c.visibleBlocks.contains(n.blockID) { return .suppress(.looking) }
        if let t = lastText, t.text == noticeText(n), now.timeIntervalSince(t.at) < noticeRepeat {
            return .suppress(.repeated)
        }
        if c.modalPresented || c.boardShowing { return .hold }
        if toastShowing { return .slot }
        if let t = lastNoticeToast, now.timeIntervalSince(t) < noticeGap { return .slot }
        if let t = lastShown, now.timeIntervalSince(t) < noticeCooldown { return .slot }
        return .show
    }

    /// Whether the waiting notices may show now: nothing covers the screen or shows, held
    /// waiting alerts went first, and the gap has passed.
    static func mayReleaseNotices(context c: Context, toastShowing: Bool, waitingHeld: Bool,
                                  activeSince: Date?, lastNoticeToast: Date?, now: Date) -> Bool {
        guard c.appActive, !c.modalPresented, !c.boardShowing, !toastShowing, !waitingHeld else { return false }
        return noticeTimingAllows(activeSince: activeSince, lastNoticeToast: lastNoticeToast, now: now)
    }

    /// The quiet after coming to the front and the gap since the last notice toast have passed.
    static func noticeTimingAllows(activeSince: Date?, lastNoticeToast: Date?, now: Date) -> Bool {
        if let s = activeSince, now.timeIntervalSince(s) < quietAfterActive { return false }
        if let t = lastNoticeToast, now.timeIntervalSince(t) < noticeGap { return false }
        return true
    }
}
