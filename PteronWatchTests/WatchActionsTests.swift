import Foundation
import GlanceModel
import Testing
@testable import PteronWatch

/// The watch's actions: a confirmed action is sent once, a second tap sends nothing, and the
/// line under the agent says how it ended.
@MainActor
@Suite struct WatchActionsTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// What the session would be asked to send, with the answer the test gives.
    final class Sender: @unchecked Sendable {
        private let lock = NSLock()
        private var _sent: [WatchAction] = []
        private var waiting: [CheckedContinuation<WatchActionOutcome, Never>] = []

        var sent: [WatchAction] { lock.withLock { _sent } }

        func send(_ action: WatchAction) async -> WatchActionOutcome {
            await withCheckedContinuation { c in
                lock.withLock {
                    _sent.append(action)
                    waiting.append(c)
                }
            }
        }

        func answer(_ outcome: WatchActionOutcome) {
            let c = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }
            c?.resume(returning: outcome)
        }
    }

    private func row(_ scenario: String = "one") throws -> WatchScreen.Row {
        let snapshot = try #require(GlanceDemo.snapshot(scenario, now: Self.now))
        return try #require(WatchScreen(.snapshot(snapshot), now: Self.now).rows.first)
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    @Test func aConfirmedActionIsSentOnceWithTheWaitItAnswers() async throws {
        let sender = Sender()
        var ids = 0
        let actions = WatchActions(id: { ids += 1; return "tap-\(ids)" }) { await sender.send($0) }
        let row = try row()
        #expect(actions.state(row.id).phase == .idle)
        let task = Task { await actions.confirmed(.enter, row: row) }
        await settle()
        let target = try #require(row.target)
        #expect(sender.sent == [WatchAction(id: "tap-1", kind: .enter, target: target)])
        #expect(actions.state(row.id).line(for: row.target) == WatchText.sending)
        // A second confirmation while the first is on its way sends nothing.
        await actions.confirmed(.interrupt, row: row)
        #expect(sender.sent.count == 1)
        sender.answer(.sent)
        await task.value
        #expect(actions.state(row.id).line(for: row.target) == "Sent Enter")
        // The wait was answered: nothing more goes for it.
        await actions.confirmed(.enter, row: row)
        #expect(sender.sent.count == 1)
    }

    @Test func nothingIsSentAgainByItselfAfterAFailure() async throws {
        let sender = Sender()
        let actions = WatchActions { await sender.send($0) }
        let row = try row()
        let task = Task { await actions.confirmed(.interrupt, row: row) }
        await settle()
        sender.answer(.noPhone)
        await task.value
        #expect(actions.state(row.id).phase == .done(.interrupt, .noPhone))
        // However long it stays on screen: one message was sent, and no other follows.
        await settle()
        #expect(sender.sent.count == 1)
        // The person may tap again, which is a new action with a new id.
        let again = Task { await actions.confirmed(.interrupt, row: row) }
        await settle()
        #expect(sender.sent.count == 2 && sender.sent[0].id != sender.sent[1].id)
        sender.answer(.changed)
        await again.value
        #expect(actions.state(row.id).line(for: row.target) == WatchText.outcome(.changed, .interrupt))
    }

    @Test func aRowThatOffersNoActionSendsNothing() async throws {
        let sender = Sender()
        let actions = WatchActions { await sender.send($0) }
        let stale = try row("stale")
        #expect(stale.target == nil)
        await actions.confirmed(.enter, row: stale)
        #expect(sender.sent.isEmpty && actions.state(stale.id).phase == .idle)
    }

    @Test func eachAgentHasItsOwnState() async throws {
        let sender = Sender()
        let actions = WatchActions { await sender.send($0) }
        let snapshot = try #require(GlanceDemo.snapshot("several", now: Self.now))
        let rows = WatchScreen(.snapshot(snapshot), now: Self.now).rows
        let task = Task { await actions.confirmed(.enter, row: rows[0]) }
        await settle()
        #expect(actions.state(rows[0].id).phase == .sending(.enter))
        #expect(actions.state(rows[1].id).phase == .idle)
        sender.answer(.sent)
        await task.value
    }
}
