import Foundation

/// The toast between alerts: what is on screen and what waits, with no timers and no screen, so a
/// sequence of alerts can be played in a test. `AgentToasts` keeps it in `@State`, reads the
/// screen into a `ToastPolicy.Context` and runs the timers.
///
/// Waiting agents follow the rules they always had (`ToastPolicy.decide`): the newest updates the
/// toast in place and counts the others, a sheet holds them, the board drops them. Notices only
/// ever take the toast when nothing shows, and give it up to a waiting agent.
struct ToastState: Equatable {
    struct NoticeText: Equatable {
        var text: String
        var at: Date
    }

    enum Effect: Equatable {
        case none
        /// A toast came up: announce it and start its lifetime.
        case shown(AgentToast)
        /// The toast on screen changed in place: restart its lifetime.
        case updated(AgentToast)
    }

    private(set) var toast: AgentToast?
    /// When each pane last toasted for a waiting agent.
    private(set) var lastShown: [String: Date] = [:]
    /// Waiting alerts held while a sheet covers the screen.
    private(set) var held: [AgentAlert] = []

    /// Notices that couldn't show yet, newest per pane, oldest first.
    private(set) var noticeSlot: [AgentAlert] = []
    /// Notices held while a sheet or the board covers the screen, newest per pane, oldest first.
    private(set) var heldNotices: [AgentAlert] = []
    /// The notices the toast on screen stands for, when it is a notice toast.
    private(set) var shownNotices: [AgentAlert] = []
    private(set) var lastNoticeToast: Date?
    /// When each pane last toasted for a notice.
    private(set) var noticeShown: [String: Date] = [:]
    /// Each pane's latest notice text, for repeats.
    private(set) var noticeTexts: [String: NoticeText] = [:]
    /// When the app last came to the front.
    var activeSince: Date?

    /// Notices wait to show.
    var noticesWaiting: Bool { !noticeSlot.isEmpty || !heldNotices.isEmpty }

    /// What this state alone says about showing the waiting notices now: some wait, no toast is
    /// up, no waiting alert is held, and the quiet and the gap have passed. Checked before the
    /// screen is read, so nothing walks UIKit while the answer is no anyway.
    func noticesMayShow(now: Date) -> Bool {
        noticesWaiting && toast == nil && held.isEmpty
            && ToastPolicy.noticeTimingAllows(activeSince: activeSince, lastNoticeToast: lastNoticeToast, now: now)
    }

    // MARK: Waiting agents

    /// A waiting agent's alert. A notice toast on screen gives way to it.
    mutating func considerWaiting(_ a: AgentAlert, context: ToastPolicy.Context, now: Date) -> Effect {
        let current = toast?.alert.kind == .waiting ? toast : nil
        switch ToastPolicy.decide(a, context: context, current: current, lastShown: lastShown, now: now) {
        case .show(let t):
            if toast != nil { returnShownNotices() }
            toast = t
            lastShown[a.blockID] = now
            return .shown(t)
        case .update(let t):
            toast = t
            lastShown[a.blockID] = now
            return .updated(t)
        case .hold:
            held = ToastPolicy.hold(a, in: held)
            return .none
        case .suppress:
            return .none
        }
    }

    /// The held waiting alerts still worth showing, oldest first; none stay held.
    mutating func takeHeld(stillWaiting: (AgentAlert) -> Bool, now: Date) -> [AgentAlert] {
        let ready = held.filter { ToastPolicy.worthOfferingAgain($0, stillWaiting: stillWaiting($0), now: now) }
        held = []
        return ready
    }

    // MARK: The toast on screen

    /// Its lifetime ran out, it was swiped away, or it was opened.
    mutating func toastEnded() {
        toast = nil
        shownNotices = []
    }

    /// The board came: a notice toast goes back to be held, a waiting toast goes (the board lists
    /// waiting agents itself).
    mutating func boardCame() {
        guard toast != nil else { return }
        heldNotices = Self.newestPerPane(shownNotices + heldNotices)
        toastEnded()
    }

    // MARK: Notices

    mutating func considerNotice(_ n: AgentAlert, context: ToastPolicy.Context, now: Date) -> Effect {
        let decision = ToastPolicy.decideNotice(
            n, context: context, toastShowing: toast != nil, activeSince: activeSince,
            lastNoticeToast: lastNoticeToast, lastShown: noticeShown[n.blockID],
            lastText: noticeTexts[n.blockID].map { ($0.text, $0.at) }, now: now)
        if decision != .suppress(.repeated), decision != .suppress(.background), decision != .suppress(.waking) {
            noticeTexts = noticeTexts.filter { now.timeIntervalSince($0.value.at) < ToastPolicy.noticeRepeat }
            noticeTexts[n.blockID] = NoticeText(text: ToastPolicy.noticeText(n), at: now)
        }
        switch decision {
        case .show:
            return showNotices([n], now: now)
        case .slot:
            noticeSlot = ToastPolicy.hold(n, in: noticeSlot)
        case .hold:
            heldNotices = ToastPolicy.hold(n, in: heldNotices)
        case .suppress:
            break
        }
        return .none
    }

    /// Shows the waiting notices as one toast when they may show, leaving out panes now on
    /// screen. Held notices have no age limit.
    mutating func releaseNotices(context c: ToastPolicy.Context, now: Date) -> Effect {
        guard noticesWaiting,
              ToastPolicy.mayReleaseNotices(context: c, toastShowing: toast != nil, waitingHeld: !held.isEmpty,
                                            activeSince: activeSince, lastNoticeToast: lastNoticeToast, now: now)
        else { return .none }
        var all = Self.newestPerPane(heldNotices + noticeSlot)
        heldNotices = []
        noticeSlot = []
        all.removeAll { c.visibleBlocks.contains($0.blockID) }
        guard !all.isEmpty else { return .none }
        return showNotices(all, now: now)
    }

    private mutating func showNotices(_ list: [AgentAlert], now: Date) -> Effect {
        guard let newest = list.last else { return .none }
        let others = Set(list.map(\.blockID)).subtracting([newest.blockID])
        let t = AgentToast(id: UUID(), alert: newest, others: others)
        toast = t
        shownNotices = list
        lastNoticeToast = now
        for n in list { noticeShown[n.blockID] = now }
        return .shown(t)
    }

    /// A waiting agent took the toast from notices: they wait their turn again.
    private mutating func returnShownNotices() {
        noticeSlot = Self.newestPerPane(shownNotices + noticeSlot)
        shownNotices = []
    }

    /// The newest notice of each pane, oldest first.
    static func newestPerPane(_ notices: [AgentAlert]) -> [AgentAlert] {
        var newest: [String: AgentAlert] = [:]
        for n in notices where newest[n.blockID].map({ $0.date <= n.date }) ?? true { newest[n.blockID] = n }
        return newest.values.sorted { $0.date < $1.date }
    }
}
