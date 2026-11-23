import Foundation
import Observation
import Synchronization
import Testing
import RexKit
@testable import Pteron

// Progress rings and notice toasts: the pure parts (plans: alerts, stage 1).

private let server = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let t0 = Date(timeIntervalSince1970: 1000)

private func waiting(_ block: String, at seconds: Double = 0, title: String = "Claude has a question") -> AgentAlert {
    AgentAlert(serverID: server, sessionID: "session:s", windowID: "window:w", blockID: block, title: title,
               body: "api › work", date: t0.addingTimeInterval(seconds))
}

private func notice(_ block: String, at seconds: Double = 0, text: String = "zz build done") -> AgentAlert {
    AgentAlert(serverID: server, sessionID: "session:s", windowID: "window:w", blockID: block, title: "work",
               body: "api › work — \(text)", date: t0.addingTimeInterval(seconds), kind: .notice)
}

private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

/// Set from an observation's `onChange`, which may run on any thread.
private final class Changed: Sendable {
    private let flag = Atomic(false)
    var value: Bool {
        get { flag.load(ordering: .sequentiallyConsistent) }
        set { flag.store(newValue, ordering: .sequentiallyConsistent) }
    }
}

// MARK: - Tab badge

struct TabBadgeTests {
    let build = TermProgress(state: .set, percent: 42)

    @Test func agentStatusThatNeedsOrHoldsAttentionOutranksARing() {
        for s in ["blocked", "error", "working"] {
            #expect(TabBadge.of(status: s, progress: [build]) == .status(s))
        }
    }

    @Test func aRingOutranksDoneAndIdle() {
        #expect(TabBadge.of(status: "done", progress: [build]) == .ring(build))
        #expect(TabBadge.of(status: "idle", progress: [build]) == .ring(build))
        #expect(TabBadge.of(status: nil, progress: [build]) == .ring(build))
    }

    @Test func withoutProgressItIsTodaysBadge() {
        for s in [nil, "idle", "done", "working", "blocked", "error"] {
            #expect(TabBadge.of(status: s, progress: []) == .status(s))
        }
    }

    @Test func ofSeveralBarsAnErrorThenTheLowestPercentThenIndeterminate() {
        let busy = TermProgress(state: .indeterminate)
        let low = TermProgress(state: .pause, percent: 10)
        let failed = TermProgress(state: .error, percent: 90)
        #expect(TabBadge.lowest([build, busy, low]) == low)
        #expect(TabBadge.lowest([build, busy, low, failed]) == failed)
        #expect(TabBadge.lowest([busy]) == busy)
        #expect(TabBadge.lowest([busy, build]) == build)
        #expect(TabBadge.lowest([]) == nil)
    }

    @Test func theRingSaysItsStateAndPercent() {
        #expect(ProgressRing.spoken(build) == "working, 42 percent")
        #expect(ProgressRing.spoken(TermProgress(state: .pause, percent: 5)) == "paused, 5 percent")
        #expect(ProgressRing.spoken(TermProgress(state: .error)) == "error")
    }
}

// MARK: - Block box table

@MainActor
struct BlockBoxTableTests {
    @Test func readingAMissingBlockReturnsNilAndAllocatesNothing() {
        let t = BlockBoxTable<Int>()
        #expect(t["block:a"] == nil)
        #expect(t.value("block:a") == nil)
        #expect(t.isEmpty && t.generation == 0)
    }

    @Test func theFirstValueMakesTheBoxAndEqualWritesWriteNothing() {
        let t = BlockBoxTable<Int>()
        t.set("block:a", nil)
        #expect(t.isEmpty, "nil never makes a box")
        t.set("block:a", 4)
        #expect(t.value("block:a") == 4 && t.generation == 1)
        let box = t["block:a"]
        let changed = Changed()
        withObservationTracking { _ = box?.value } onChange: { changed.value = true }
        t.set("block:a", 4)
        #expect(!changed.value, "an equal value doesn't touch the box")
        t.set("block:a", 5)
        #expect(changed.value)
        #expect(t.generation == 1, "the same box takes later values")
    }

    @Test func aReaderOfAMissingBlockHearsWhenItsBoxComes() {
        let t = BlockBoxTable<Int>()
        let changed = Changed()
        withObservationTracking { _ = t.value("block:a") } onChange: { changed.value = true }
        t.set("block:a", 1)
        #expect(changed.value)
    }

    @Test func aReaderOfOneBoxDoesNotHearAnother() {
        let t = BlockBoxTable<Int>()
        t.set("block:a", 1)
        t.set("block:b", 1)
        let changed = Changed()
        withObservationTracking { _ = t.value("block:a") } onChange: { changed.value = true }
        t.set("block:b", 2)
        #expect(!changed.value)
    }

    /// A reader holding a box without a value (a bar that was removed) must hear that box go,
    /// and then find the block's next box, as a view re-reading after a change does.
    @Test func aReaderOfARemovedEmptyBoxSeesTheNextOne() {
        let t = BlockBoxTable<Int>()
        t.set("block:a", 1)
        t.set("block:a", nil)
        let removed = Changed()
        withObservationTracking { _ = t.value("block:a") } onChange: { removed.value = true }
        t.remove("block:a")
        #expect(removed.value, "removing an empty box still tells its readers")
        let refilled = Changed()
        withObservationTracking { _ = t.value("block:a") } onChange: { refilled.value = true }
        t.set("block:a", 7)
        #expect(refilled.value)
        #expect(t.value("block:a") == 7)
    }

    @Test func removingABoxClearsItForWhoeverHoldsIt() {
        let t = BlockBoxTable<Int>()
        t.set("block:a", 1)
        t.set("block:b", 2)
        let box = t["block:a"]
        t.remove("block:a")
        #expect(box?.value == nil && t["block:a"] == nil)
        t.removeAll { $0 == "block:b" }
        #expect(t.isEmpty)
        t.set("block:c", 3)
        t.removeAll()
        #expect(t.isEmpty && t.setIDs.isEmpty)
    }
}

// MARK: - Notice copy and filter

struct AlertCopyTests {
    @Test func emptyNoticesAndPassedThroughProgressAreNotNotices() {
        #expect(!AlertCopy.isNotice(title: "", body: ""))
        #expect(!AlertCopy.isNotice(title: " ", body: "\u{07}\n"))
        #expect(!AlertCopy.isNotice(title: "", body: "4;1;40"))
        #expect(AlertCopy.isNotice(title: "", body: "zz probe"))
        #expect(AlertCopy.isNotice(title: "zz T", body: ""))
    }

    @Test func osc9HasNoTitleSoTheTabNamesIt() {
        #expect(AlertCopy.noticeTitle("", tab: "work") == "work")
        #expect(AlertCopy.noticeTitle("zz T", tab: "work") == "zz T")
    }

    @Test func theBodyAlwaysSaysWhereItCameFrom() {
        #expect(AlertCopy.noticeBody("zz B", place: "api › work") == "api › work — zz B")
        #expect(AlertCopy.noticeBody("", place: "api › work") == "api › work")
        #expect(AlertCopy.noticeBody("zz B", place: "") == "zz B")
    }

    @Test func controlCharactersAndDirectionOverridesGo() {
        #expect(AlertCopy.clean("zz\u{1b}[31m red\u{07}") == "zz [31m red")
        #expect(AlertCopy.clean("  zz\n\n  two\tlines  ") == "zz two lines")
        #expect(AlertCopy.clean("zz \u{202E}gnp.exe") == "zz gnp.exe")
        #expect(AlertCopy.clean("zz 👩‍💻 ok") == "zz 👩‍💻 ok", "a ZWJ sequence stays whole")
        let long = AlertCopy.clean(String(repeating: "z", count: 500))
        #expect(long.count == AlertCopy.maxText && long.hasSuffix("…"))
    }

    @Test func countsUnderANoticeToast() {
        #expect(AlertCopy.moreNotices(1) == "1 more notification")
        #expect(AlertCopy.moreNotices(3) == "3 more notifications")
        #expect(AlertCopy.moreNoticesShort(3) == "3 more")
    }
}

struct NoticeFilterTests {
    let now = ContinuousClock.now

    private func meta(title: String? = nil, foreground: String? = nil, statuses: [String: String] = [:]) -> BlockMeta {
        var m = BlockMeta()
        m.title = title
        m.foreground = foreground
        for (id, app) in statuses { m.statuses[id] = ProgramStatus(["state": "idle", "app": app]) }
        return m
    }

    @Test func anAgentByTitleForegroundOrStatusApp() {
        #expect(NoticeFilter.fromAgent(meta(title: "✳ Claude Code"), recordRemovedAt: nil, now: now))
        #expect(NoticeFilter.fromAgent(meta(foreground: "codex"), recordRemovedAt: nil, now: now))
        #expect(NoticeFilter.fromAgent(meta(statuses: ["s": "claude"]), recordRemovedAt: nil, now: now))
    }

    @Test func anyOSC7501RecordCounts() {
        #expect(NoticeFilter.fromAgent(meta(statuses: ["installer": "rexduo-setup"]), recordRemovedAt: nil, now: now))
    }

    @Test func aRecordRemovedLessThanTenSecondsAgoCounts() {
        let plain = meta(title: "zsh", foreground: "zsh")
        #expect(NoticeFilter.fromAgent(plain, recordRemovedAt: now - .seconds(9), now: now))
        #expect(!NoticeFilter.fromAgent(plain, recordRemovedAt: now - .seconds(11), now: now))
        #expect(!NoticeFilter.fromAgent(plain, recordRemovedAt: nil, now: now))
        #expect(!NoticeFilter.fromAgent(nil, recordRemovedAt: nil, now: now))
    }
}

// MARK: - Notifier

@MainActor
struct AgentNotifierQueueTests {
    @Test func noticesPostedInOneTurnAreAllDecidedInOrder() {
        let n = AgentNotifier()
        let before = n.noticeSerial
        n.postNotice(notice("block:a", text: "zz one"))
        n.postNotice(notice("block:b", text: "zz two"))
        #expect(n.noticeSerial != before)
        #expect(n.takeNotices().map(\.blockID) == ["block:a", "block:b"])
        #expect(n.takeNotices().isEmpty)
    }

    @Test func aNoisyPaneKeepsItsNewestFiveAndNeverPushesOutAnotherPanes() {
        let n = AgentNotifier()
        for i in 0..<3 { n.postNotice(notice("block:quiet", at: Double(i), text: "zz quiet \(i)")) }
        for i in 0..<100 { n.postNotice(notice("block:noisy", at: Double(10 + i), text: "zz noisy \(i)")) }
        let left = n.takeNotices()
        #expect(left.filter { $0.blockID == "block:quiet" }.count == 3)
        let noisy = left.filter { $0.blockID == "block:noisy" }
        #expect(noisy.count == AgentNotifier.perPaneLimit)
        #expect(noisy.last?.body.hasSuffix("zz noisy 99") == true, "the newest of the noisy pane stay")
    }

    @Test func pastTheLimitTheBusiestPaneGivesWay() {
        let n = AgentNotifier()
        for i in 0..<9 { n.postNotice(notice("block:\(i)", text: "zz 0")) }
        for p in 0..<9 { for k in 1..<5 { n.postNotice(notice("block:\(p)", text: "zz \(k)")) } }
        for i in 9..<19 { n.postNotice(notice("block:\(i)", text: "zz late")) }
        let left = n.takeNotices()
        #expect(left.count == AgentNotifier.noticeLimit)
        #expect(Set(left.map(\.blockID)).count == 19, "every pane keeps at least one notice")
    }

    @Test func theQueueKeepsTheNewestFifty() {
        let n = AgentNotifier()
        for i in 0..<60 { n.postNotice(notice("block:\(i)")) }
        let left = n.takeNotices()
        #expect(left.count == AgentNotifier.noticeLimit)
        #expect(left.first?.blockID == "block:10" && left.last?.blockID == "block:59")
    }

    @Test func waitingAlertsNeverEnterTheQueueAndCollapseToTheNewest() {
        let n = AgentNotifier()
        let serial = n.noticeSerial
        n.post(waiting("block:a"))
        n.post(waiting("block:b"))
        #expect(n.latest?.blockID == "block:b")
        #expect(n.noticeSerial == serial && n.takeNotices().isEmpty)
    }
}

// MARK: - Notices in the toast

struct NoticeToastTests {
    private var off: ToastPolicy.Context { .init() }

    @Test func aNoticeShowsWhenNothingElseDoes() {
        var s = ToastState()
        guard case .shown(let t) = s.considerNotice(notice("block:a"), context: off, now: at(0)) else {
            Issue.record("expected a toast"); return
        }
        #expect(t.alert.kind == .notice && t.others.isEmpty)
    }

    @Test func droppedInTheBackgroundRightAfterComingBackAndForAPaneOnScreen() {
        var s = ToastState()
        #expect(s.considerNotice(notice("block:a"), context: .init(appActive: false), now: at(0)) == .none)
        s.activeSince = at(10)
        #expect(s.considerNotice(notice("block:a"), context: off, now: at(11)) == .none)
        #expect(s.considerNotice(notice("block:a"), context: .init(visibleBlocks: ["block:a"]), now: at(13)) == .none)
        #expect(!s.noticesWaiting && s.toast == nil)
        #expect(ToastPolicy.decideNotice(notice("block:a"), context: off, toastShowing: false, activeSince: at(10),
                                         lastNoticeToast: nil, lastShown: nil, lastText: nil, now: at(11))
                == .suppress(.waking))
    }

    @Test func theSameTextFromTheSamePaneWithinThirtySecondsIsARepeat() {
        var s = ToastState()
        _ = s.considerNotice(notice("block:a"), context: off, now: at(0))
        s.toastEnded()
        #expect(s.considerNotice(notice("block:a"), context: off, now: at(20)) == .none)
        #expect(!s.noticesWaiting, "a repeat is dropped, not deferred")
        #expect(s.considerNotice(notice("block:a", text: "zz other"), context: off, now: at(21)) == .none)
        #expect(s.noticesWaiting, "other text waits out the gap and the cooldown")
    }

    @Test func aNoticeUnderAWaitingToastWaitsInTheSlotThenShowsWithCounts() {
        var s = ToastState()
        _ = s.considerWaiting(waiting("block:w"), context: off, now: at(0))
        #expect(s.considerNotice(notice("block:a", at: 1), context: off, now: at(1)) == .none)
        #expect(s.considerNotice(notice("block:b", at: 2), context: off, now: at(2)) == .none)
        #expect(s.toast?.alert.kind == .waiting && s.toast?.others.isEmpty == true, "the waiting toast doesn't count notices")
        #expect(s.releaseNotices(context: off, now: at(3)) == .none, "not while a toast is up")
        s.toastEnded()
        guard case .shown(let t) = s.releaseNotices(context: off, now: at(6)) else {
            Issue.record("expected the slot to show"); return
        }
        #expect(t.alert.blockID == "block:b" && t.others == ["block:a"])
        #expect(!s.noticesWaiting)
    }

    @Test func noticeToastsKeepTenSecondsApart() {
        var s = ToastState()
        _ = s.considerNotice(notice("block:a"), context: off, now: at(0))
        s.toastEnded()
        #expect(s.considerNotice(notice("block:b", at: 7), context: off, now: at(7)) == .none)
        #expect(s.releaseNotices(context: off, now: at(9)) == .none)
        guard case .shown(let t) = s.releaseNotices(context: off, now: at(10)) else {
            Issue.record("expected the slot after the gap"); return
        }
        #expect(t.alert.blockID == "block:b")
    }

    @Test func aPanesCooldownDefersItsNextNotice() {
        var s = ToastState()
        _ = s.considerNotice(notice("block:a"), context: off, now: at(0))
        s.toastEnded()
        #expect(s.considerNotice(notice("block:a", at: 15, text: "zz again"), context: off, now: at(15)) == .none)
        #expect(s.noticesWaiting, "inside the cooldown it waits, it isn't lost")
    }

    @Test func aWaitingAlertTakesTheToastAndTheNoticeWaitsAgain() {
        var s = ToastState()
        _ = s.considerNotice(notice("block:a"), context: off, now: at(0))
        guard case .shown(let t) = s.considerWaiting(waiting("block:w", at: 1), context: off, now: at(1)) else {
            Issue.record("a waiting alert outranks a notice"); return
        }
        #expect(t.alert.kind == .waiting && t.others.isEmpty)
        #expect(s.noticesWaiting && s.noticeSlot.map(\.blockID) == ["block:a"])
    }

    @Test func aNoticeNeverReplacesAWaitingToastOrJumpsAHeldWaitingAlert() {
        var s = ToastState()
        _ = s.considerWaiting(waiting("block:w"), context: .init(modalPresented: true), now: at(0))
        #expect(s.held.count == 1)
        _ = s.considerNotice(notice("block:a"), context: .init(modalPresented: true), now: at(0))
        #expect(s.releaseNotices(context: off, now: at(12)) == .none, "held waiting alerts go first")
        _ = s.takeHeld(stillWaiting: { _ in true }, now: at(12))
        #expect(s.releaseNotices(context: off, now: at(12)) != .none)
    }

    @Test func aSheetOrTheBoardHoldsNoticesAndOneToastCountsThemAfter() {
        var s = ToastState()
        let board = ToastPolicy.Context(boardShowing: true)
        for (i, b) in ["block:a", "block:b", "block:c"].enumerated() {
            #expect(s.considerNotice(notice(b, at: Double(i)), context: board, now: at(Double(i))) == .none)
        }
        _ = s.considerNotice(notice("block:d", at: 3), context: .init(modalPresented: true), now: at(3))
        #expect(s.heldNotices.count == 4 && s.toast == nil)
        #expect(s.releaseNotices(context: board, now: at(4)) == .none)
        guard case .shown(let t) = s.releaseNotices(context: off, now: at(30)) else {
            Issue.record("expected one toast"); return
        }
        #expect(t.alert.blockID == "block:d" && t.others == ["block:a", "block:b", "block:c"])
    }

    @Test func heldNoticesHaveNoAgeLimitButSkipPanesNowOnScreen() {
        var s = ToastState()
        _ = s.considerNotice(notice("block:a"), context: .init(boardShowing: true), now: at(0))
        _ = s.considerNotice(notice("block:b", at: 1), context: .init(boardShowing: true), now: at(1))
        guard case .shown(let t) = s.releaseNotices(context: .init(visibleBlocks: ["block:b"]), now: at(3600)) else {
            Issue.record("an hour later it still shows"); return
        }
        #expect(t.alert.blockID == "block:a" && t.others.isEmpty)
        var gone = ToastState()
        _ = gone.considerNotice(notice("block:a"), context: .init(boardShowing: true), now: at(0))
        #expect(gone.releaseNotices(context: .init(visibleBlocks: ["block:a"]), now: at(5)) == .none)
        #expect(!gone.noticesWaiting, "the user saw the pane: the notice is done")
    }

    @Test func aNoticeToastGoesBackToTheHoldWhenTheBoardComes() {
        var s = ToastState()
        _ = s.considerNotice(notice("block:a"), context: off, now: at(0))
        s.boardCame()
        #expect(s.toast == nil && s.heldNotices.map(\.blockID) == ["block:a"])
    }

    @Test func theScreenIsReadOnlyWhenTheStateAloneAllowsIt() {
        var s = ToastState()
        #expect(!s.noticesMayShow(now: at(0)), "nothing waits")
        _ = s.considerNotice(notice("block:a"), context: .init(), now: at(0))
        s.toastEnded()
        _ = s.considerNotice(notice("block:b", at: 1), context: .init(), now: at(1))
        #expect(s.noticesWaiting)
        #expect(!s.noticesMayShow(now: at(5)), "inside the gap")
        #expect(s.noticesMayShow(now: at(10)))
        s.activeSince = at(9)
        #expect(!s.noticesMayShow(now: at(10)), "inside the quiet after coming back")
        s.activeSince = nil
        _ = s.considerWaiting(waiting("block:w", at: 10), context: .init(modalPresented: true), now: at(10))
        #expect(!s.noticesMayShow(now: at(11)), "a held waiting alert goes first")
        _ = s.takeHeld(stillWaiting: { _ in false }, now: at(11))
        _ = s.considerWaiting(waiting("block:x", at: 11), context: .init(), now: at(11))
        #expect(!s.noticesMayShow(now: at(12)), "a toast is up")
        s.toastEnded()
        #expect(s.noticesMayShow(now: at(12)))
    }

    @Test func aWaitingToastStillGoesWhenTheBoardComes() {
        var s = ToastState()
        _ = s.considerWaiting(waiting("block:w"), context: off, now: at(0))
        s.boardCame()
        #expect(s.toast == nil && !s.noticesWaiting && s.held.isEmpty)
        #expect(s.considerWaiting(waiting("block:x"), context: .init(boardShowing: true), now: at(1)) == .none)
        #expect(s.held.isEmpty, "the board lists waiting agents, so they are dropped there")
    }
}

// MARK: - Waiting toasts keep today's sequence (S8)

/// The waiting-toast logic exactly as `AgentToasts` ran it before notices (main at 5afcc0d):
/// `consider`, `offerHeld`, the hide timer and the board's dismiss, with time passed in.
private struct MainToasts {
    var toast: AgentToast?
    var lastShown: [String: Date] = [:]
    var held: [AgentAlert] = []

    mutating func consider(_ a: AgentAlert, _ ctx: ToastPolicy.Context, now: Date) {
        switch ToastPolicy.decide(a, context: ctx, current: toast, lastShown: lastShown, now: now) {
        case .show(let t), .update(let t):
            toast = t
            lastShown[a.blockID] = now
        case .hold:
            held = ToastPolicy.hold(a, in: held)
        case .suppress:
            break
        }
    }

    mutating func offerHeld(stillWaiting: (AgentAlert) -> Bool, _ ctx: ToastPolicy.Context, now: Date) {
        let ready = held.filter { ToastPolicy.worthOfferingAgain($0, stillWaiting: stillWaiting($0), now: now) }
        held = []
        for a in ready { consider(a, ctx, now: now) }
    }
}

@MainActor
struct WaitingSequenceTests {
    /// What a viewer sees of a toast: which alert, which others. Toast ids are random per run.
    private struct Seen: Equatable {
        var alert: UUID?
        var others: Set<String>
        init(_ t: AgentToast?) { alert = t?.alert.id; others = t?.others ?? [] }
    }

    private enum Step {
        case post(AgentAlert, ToastPolicy.Context)
        case offerHeld(ToastPolicy.Context, stillWaiting: Bool)
        case hide
        case board
    }

    /// Plays steps on main's logic and on `ToastState`, and returns what each showed after each step.
    private func play(_ steps: [(Double, Step)]) -> (main: [Seen], now: [Seen], effects: [ToastState.Effect]) {
        var ref = MainToasts()
        var cur = ToastState()
        var a: [Seen] = [], b: [Seen] = [], effects: [ToastState.Effect] = []
        for (t, step) in steps {
            let now = at(t)
            switch step {
            case .post(let alert, let ctx):
                ref.consider(alert, ctx, now: now)
                effects.append(cur.considerWaiting(alert, context: ctx, now: now))
            case .offerHeld(let ctx, let still):
                ref.offerHeld(stillWaiting: { _ in still }, ctx, now: now)
                for alert in cur.takeHeld(stillWaiting: { _ in still }, now: now) {
                    effects.append(cur.considerWaiting(alert, context: ctx, now: now))
                }
            case .hide:
                ref.toast = nil
                cur.toastEnded()
            case .board:
                if ref.toast != nil { ref.toast = nil }
                cur.boardCame()
            }
            a.append(Seen(ref.toast))
            b.append(Seen(cur.toast))
            #expect(cur.lastShown == ref.lastShown && cur.held == ref.held)
            #expect(!cur.noticesWaiting, "waiting alerts never enter the notice slot")
        }
        return (a, b, effects)
    }

    @Test func oneAlertShowsAndGoes() {
        let a = waiting("block:a")
        let r = play([(0, .post(a, .init())), (6, .hide)])
        #expect(r.main == r.now)
        #expect(r.now == [Seen(AgentToast(id: UUID(), alert: a, others: [])), Seen(nil)])
        #expect(r.effects.count == 1 && { if case .shown = r.effects[0] { true } else { false } }())
    }

    @Test func twoInOneTurnShowOnlyTheNewest() {
        // The toast observes `latest`, which keeps only the newest post of a turn.
        let n = AgentNotifier()
        let first = waiting("block:a"), second = waiting("block:b")
        n.post(first)
        n.post(second)
        let r = play([(0, .post(n.latest!, .init())), (6, .hide)])
        #expect(r.main == r.now)
        #expect(r.now[0] == Seen(AgentToast(id: UUID(), alert: second, others: [])))
        #expect(r.now[1] == Seen(nil), "no follow-up toast for the first")
    }

    @Test func twoOneSecondApartUpdateOneToastInPlace() {
        let a = waiting("block:a"), b = waiting("block:b", at: 1)
        let r = play([(0, .post(a, .init())), (1, .post(b, .init())), (7, .hide)])
        #expect(r.main == r.now)
        #expect(r.now[1] == Seen(AgentToast(id: UUID(), alert: b, others: ["block:a"])))
        #expect(r.effects.count == 2 && { if case .updated = r.effects[1] { true } else { false } }())
        #expect(r.now[2] == Seen(nil), "no \"1 more\" toast after it")
    }

    @Test func duringTheBoardNothingShowsOrWaits() {
        let a = waiting("block:a")
        let r = play([(0, .post(a, .init(boardShowing: true))), (2, .offerHeld(.init(), stillWaiting: true))])
        #expect(r.main == r.now && r.now == [Seen(nil), Seen(nil)])
    }

    @Test func underASheetItWaitsAndShowsWhenTheSheetCloses() {
        let a = waiting("block:a")
        let r = play([(0, .post(a, .init(modalPresented: true))), (3, .offerHeld(.init(), stillWaiting: true))])
        #expect(r.main == r.now)
        #expect(r.now == [Seen(nil), Seen(AgentToast(id: UUID(), alert: a, others: []))])
    }

    /// Random waiting-only traffic: every step shows what main showed.
    @Test func randomWaitingTrafficMatchesMain() {
        var rng = SplitMix(seed: 0x5EED)
        for _ in 0..<400 {
            var steps: [(Double, Step)] = []
            var t = 0.0
            for _ in 0..<Int.random(in: 1...14, using: &rng) {
                t += [0, 0.5, 1, 3, 7, 31, 125].randomElement(using: &rng)!
                let ctx = ToastPolicy.Context(appActive: Int.random(in: 0..<8, using: &rng) > 0,
                                              visibleBlocks: Bool.random(using: &rng) ? ["block:a"] : [],
                                              modalPresented: Int.random(in: 0..<4, using: &rng) == 0,
                                              boardShowing: Int.random(in: 0..<6, using: &rng) == 0)
                switch Int.random(in: 0..<10, using: &rng) {
                case 0..<6:
                    let block = ["block:a", "block:b", "block:c"].randomElement(using: &rng)!
                    steps.append((t, .post(waiting(block, at: t), ctx)))
                case 6, 7: steps.append((t, .offerHeld(ctx, stillWaiting: Bool.random(using: &rng))))
                case 8: steps.append((t, .hide))
                default: steps.append((t, .board))
                }
            }
            let r = play(steps)
            #expect(r.main == r.now)
        }
    }
}

/// A seeded generator, so a failing random case replays.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
