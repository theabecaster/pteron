import Testing
@testable import RexDuo

/// What a popover's row asked for runs when the popover has gone, and after the cap at the
/// latest (`DismissalWait`). No test waits on a clock: the sleep is the test's own, and the cap
/// runs out when the test says so.
@MainActor
@Suite struct DismissalWaitTests {
    /// A sleep that ends when the test opens it.
    @MainActor
    private final class Gate {
        private(set) var asked: [Duration] = []
        private var sleepers: [CheckedContinuation<Void, Never>] = []

        func sleep(_ time: Duration) async {
            asked.append(time)
            await withCheckedContinuation { sleepers.append($0) }
        }

        /// The time asked for has passed.
        func open() {
            let all = sleepers
            sleepers = []
            all.forEach { $0.resume() }
        }
    }

    private final class Ran {
        var log: [String] = []
    }

    private func rig() -> (DismissalWait, Gate, Ran) {
        let gate = Gate()
        return (DismissalWait(sleep: { await gate.sleep($0) }), gate, Ran())
    }

    /// Lets the wait's timer reach its sleep.
    private func started(_ gate: Gate) async throws {
        for _ in 0..<100 where gate.asked.isEmpty { await Task.yield() }
        try #require(gate.asked.count == 1, "the timer sleeps once")
    }

    @Test func theActionRunsWhenThePopoverHasGone() async throws {
        let (wait, gate, ran) = rig()
        wait.hold { ran.log.append("settings") }
        #expect(ran.log.isEmpty && wait.isWaiting, "not before the dismissal")
        try await started(gate)
        #expect(ran.log.isEmpty)

        wait.dismissed()
        #expect(ran.log == ["settings"])
        #expect(!wait.isWaiting && wait.timer == nil)
        // The cap running out later, and a second report, run nothing again.
        gate.open()
        for _ in 0..<10 { await Task.yield() }
        wait.dismissed()
        #expect(ran.log == ["settings"])
    }

    /// No dismissal is ever reported: the row still runs when the cap runs out, once.
    @Test func theCapRunsItWhenNoDismissalComes() async throws {
        let (wait, gate, ran) = rig()
        wait.hold { ran.log.append("agents") }
        try await started(gate)
        let timer = try #require(wait.timer)
        #expect(ran.log.isEmpty)

        gate.open()
        await timer.value
        #expect(ran.log == ["agents"])
        #expect(!wait.isWaiting && wait.timer == nil)
        // A dismissal that comes late runs nothing again.
        wait.dismissed()
        #expect(ran.log == ["agents"])
    }

    /// The cap is a second, and it is all the timer asks for.
    @Test func theCapIsOneSecond() async throws {
        #expect(DismissalWait.cap == .seconds(1))
        let (wait, gate, _) = rig()
        wait.hold {}
        try await started(gate)
        #expect(gate.asked == [.seconds(1)])

        let short = Gate()
        let other = DismissalWait(cap: .milliseconds(200), sleep: { await short.sleep($0) })
        other.hold {}
        try await started(short)
        #expect(short.asked == [.milliseconds(200)])
        wait.dismissed()
        other.dismissed()
        gate.open()
        short.open()
    }

    /// A popover closed with nothing asked reports its dismissal too: that runs nothing, and
    /// doesn't let a row held later through before its own dismissal.
    @Test func aDismissalWithNothingHeldCountsForNothing() async throws {
        let (wait, gate, ran) = rig()
        wait.dismissed()
        #expect(!wait.isWaiting && wait.timer == nil)
        #expect(gate.asked.isEmpty, "nothing held, no timer")

        wait.hold { ran.log.append("rename") }
        try await started(gate)
        #expect(ran.log.isEmpty)
        wait.dismissed()
        #expect(ran.log == ["rename"])
        gate.open()
    }

    /// The view that held the wait is torn down with the popover and no dismissal is reported:
    /// the timer keeps the wait alive until the cap, and the row still runs.
    @Test func aWaitNobodyHoldsStillRunsItsRowAtTheCap() async throws {
        let gate = Gate(), ran = Ran()
        weak var gone: DismissalWait?
        var timer: Task<Void, Never>?
        do {
            let wait = DismissalWait(sleep: { await gate.sleep($0) })
            wait.hold { ran.log.append("settings") }
            gone = wait
            timer = wait.timer
        }
        try await started(gate)
        #expect(gone != nil, "the timer holds it")
        #expect(ran.log.isEmpty)
        gate.open()
        await timer?.value
        #expect(ran.log == ["settings"])
        timer = nil
        for _ in 0..<10 { await Task.yield() }
        #expect(gone == nil, "and lets it go after the cap")
    }

    /// Two rows held before the dismissal run in their order, under one cap; a row held after
    /// one ran gets a cap of its own.
    @Test func whatIsHeldRunsInOrderUnderOneCap() async throws {
        let (wait, gate, ran) = rig()
        wait.hold { ran.log.append("first") }
        wait.hold { ran.log.append("second") }
        try await started(gate)
        #expect(gate.asked.count == 1)
        let timer = try #require(wait.timer)
        gate.open()
        await timer.value
        #expect(ran.log == ["first", "second"])

        wait.hold { ran.log.append("third") }
        for _ in 0..<100 where gate.asked.count < 2 { await Task.yield() }
        #expect(gate.asked.count == 2)
        wait.dismissed()
        #expect(ran.log == ["first", "second", "third"])
        gate.open()
    }

    /// An action that holds another while it runs (a row that opens something with rows of its
    /// own) doesn't run that one in the same turn.
    @Test func anActionHeldWhileRunningWaitsForItsOwnDismissal() async throws {
        let (wait, gate, ran) = rig()
        wait.hold {
            ran.log.append("outer")
            wait.hold { ran.log.append("inner") }
        }
        try await started(gate)
        wait.dismissed()
        #expect(ran.log == ["outer"])
        #expect(wait.isWaiting)
        wait.dismissed()
        #expect(ran.log == ["outer", "inner"])
        // The inner row's timer may not have reached its sleep yet: let it, then end it.
        for _ in 0..<100 where gate.asked.count < 2 { await Task.yield() }
        gate.open()
    }
}
