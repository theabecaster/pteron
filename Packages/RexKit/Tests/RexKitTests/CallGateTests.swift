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
}
