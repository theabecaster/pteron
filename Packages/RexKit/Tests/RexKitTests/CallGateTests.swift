import XCTest
@testable import RexKit

/// A sync's reads through `CallGate`: at most four under way, in the order asked, the first
/// asked first, and nothing stuck when calls fail.
@MainActor
final class CallGateTests: XCTestCase {
    /// Calls that end when the test says so.
    @MainActor private final class Calls {
        var started: [Int] = []
        private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
        func call(_ n: Int) async {
            started.append(n)
            await withCheckedContinuation { waiting[n] = $0 }
        }
        func answer(_ n: Int) { waiting.removeValue(forKey: n)?.resume() }
        var open: [Int] { waiting.keys.sorted() }
    }

    private func turn() async { for _ in 0..<30 { await Task.yield() } }

    func testTheLimitIsFourAndIsThePolicys() {
        XCTAssertEqual(ReconnectPolicy.standard.syncCalls, 4)
        XCTAssertEqual(CallGate().limit, 4)
        XCTAssertEqual(CallGate(limit: 0).limit, 1, "never a gate that lets nothing through")
    }

    func testAtMostFourAreUnderWayAndTheyStartInTheOrderGivenTheFirstFirst() async {
        let gate = CallGate(), calls = Calls()
        let all = Task { @MainActor in await gate.each(Array(0..<10)) { await calls.call($0) } }
        await turn()
        XCTAssertEqual(calls.started, [0, 1, 2, 3], "the first four, the visible one first")
        XCTAssertEqual(gate.inFlight, 4)
        // Answers come in any order: each lets the next one in the list start.
        calls.answer(2)
        await turn()
        XCTAssertEqual(calls.started, [0, 1, 2, 3, 4])
        calls.answer(0)
        calls.answer(4)
        await turn()
        XCTAssertEqual(calls.started, [0, 1, 2, 3, 4, 5, 6])
        while !calls.open.isEmpty {
            XCTAssertLessThanOrEqual(calls.open.count, 4)
            calls.answer(calls.open[0])
            await turn()
        }
        await all.value
        XCTAssertEqual(calls.started, Array(0..<10))
        XCTAssertEqual(gate.peak, 4)
        XCTAssertEqual(gate.inFlight, 0)
    }

    func testCallsFromElsewhereShareTheSameFour() async {
        let gate = CallGate(), calls = Calls()
        // One read outside the list is under way (the creators' list of a sync).
        let other = Task { @MainActor in await gate.run { await calls.call(100) } }
        await turn()
        let all = Task { @MainActor in await gate.each(Array(0..<6)) { await calls.call($0) } }
        await turn()
        XCTAssertEqual(calls.started, [100, 0, 1, 2])
        // A single read asked for now waits behind the list's next one, not ahead of it.
        let late = Task { @MainActor in await gate.run { await calls.call(200) } }
        await turn()
        calls.answer(100)
        await turn()
        XCTAssertEqual(calls.started, [100, 0, 1, 2, 3])
        for n in [0, 1, 2, 3] { calls.answer(n) }
        await turn()
        XCTAssertEqual(Set(calls.started), [100, 0, 1, 2, 3, 200, 4, 5])
        XCTAssertEqual(calls.started[5], 200, "in the order asked")
        for n in calls.open { calls.answer(n) }
        await turn()
        _ = await (other.value, all.value, late.value)
        XCTAssertEqual(gate.peak, 4)
        XCTAssertEqual(gate.inFlight, 0)
    }

    func testACallThatThrowsGivesItsPlaceBack() async {
        struct Lost: Error {}
        let gate = CallGate(limit: 1)
        do {
            try await gate.run { throw Lost() }
            XCTFail("it throws")
        } catch {}
        XCTAssertEqual(gate.inFlight, 0)
        let ran = await gate.run { true }
        XCTAssertTrue(ran)
    }

    func testAnEmptyListAndAListShorterThanTheLimitReturn() async {
        let gate = CallGate()
        await gate.each([Int]()) { _ in XCTFail("nothing to run") }
        var ran: [Int] = []
        await gate.each([1, 2]) { ran.append($0) }
        XCTAssertEqual(ran.sorted(), [1, 2])
        XCTAssertEqual(gate.inFlight, 0)
    }

    func testACallForTheUserNeverWaitsAndTakesAPlaceFromTheSync() async {
        let gate = CallGate(limit: 2), calls = Calls()
        let sync = Task { @MainActor in await gate.each(Array(0..<4)) { await calls.call($0) } }
        await turn()
        XCTAssertEqual(calls.started, [0, 1])
        // Both places are taken and two reads wait: the user's call starts all the same.
        let mine = Task { @MainActor in await gate.run(priority: .user) { await calls.call(100) } }
        await turn()
        XCTAssertEqual(calls.started, [0, 1, 100])
        XCTAssertEqual(gate.userInFlight, 1)
        XCTAssertEqual(gate.inFlight, 2)
        // A sync read ends: its place is the user's now, so no other read starts.
        calls.answer(0)
        await turn()
        XCTAssertEqual(calls.started, [0, 1, 100])
        XCTAssertEqual(gate.inFlight, 1)
        // The user's call ends: the sync has its two places again.
        calls.answer(100)
        await turn()
        XCTAssertEqual(calls.started, [0, 1, 100, 2])
        XCTAssertEqual(gate.userInFlight, 0)
        while !calls.open.isEmpty {
            calls.answer(calls.open[0])
            await turn()
        }
        _ = await (sync.value, mine.value)
        XCTAssertEqual(calls.started, [0, 1, 100, 2, 3])
        XCTAssertEqual(gate.peak, 2, "the sync never had more than its limit")
        XCTAssertEqual(gate.inFlight, 0)
    }

    func testACallForTheUserOnAnIdleGateHoldsBackOneSyncRead() async {
        let gate = CallGate(limit: 1), calls = Calls()
        let mine = Task { @MainActor in await gate.run(priority: .user) { await calls.call(100) } }
        await turn()
        let sync = Task { @MainActor in await gate.run { await calls.call(0) } }
        await turn()
        XCTAssertEqual(calls.started, [100], "the sync yields to it")
        calls.answer(100)
        await turn()
        XCTAssertEqual(calls.started, [100, 0])
        calls.answer(0)
        _ = await (mine.value, sync.value)
        XCTAssertEqual(gate.inFlight, 0)
    }

    func testQuietSinceAMarkMeansNoSyncReadSharedTheTime() async {
        let gate = CallGate(), calls = Calls()
        let idle = gate.mark
        XCTAssertNotNil(idle)
        XCTAssertTrue(gate.quiet(since: idle))
        // A call for the user is no sync.
        let mine = Task { @MainActor in await gate.run(priority: .user) { await calls.call(100) } }
        await turn()
        XCTAssertFalse(gate.syncBusy)
        XCTAssertTrue(gate.quiet(since: idle))
        calls.answer(100)
        await mine.value
        // A sync read under way: no mark, and the earlier mark is no longer quiet.
        let read = Task { @MainActor in await gate.run { await calls.call(0) } }
        await turn()
        XCTAssertTrue(gate.syncBusy)
        XCTAssertNil(gate.mark)
        XCTAssertFalse(gate.quiet(since: idle))
        XCTAssertFalse(gate.quiet(since: nil))
        calls.answer(0)
        await read.value
        // It has ended, but it ran since the mark.
        XCTAssertFalse(gate.quiet(since: idle))
        XCTAssertTrue(gate.quiet(since: gate.mark))
    }
}
