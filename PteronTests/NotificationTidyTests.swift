import Foundation
import Testing
@testable import Pteron

/// Which delivered notifications are removed once the app knows the agents' states, and when
/// the passes run.
@MainActor
struct NotificationTidyTests {
    private typealias Delivered = NotificationTidy.Delivered
    private typealias Server = NotificationTidy.Server

    private let address = "https://studio.example.ts.net"

    private func note(_ id: String, _ category: String = "AGENT_BLOCKED", block: String? = "block:a", server: String? = nil,
                      thread: String? = nil) -> Delivered {
        Delivered(identifier: id, category: category, threadID: thread ?? block ?? "", server: server ?? address, blockID: block)
    }

    private func studio(waiting: Set<String>?) -> Server { Server(url: address, hostName: nil, waiting: waiting) }

    // MARK: The rule

    @Test func aQuestionGoesOnlyWhenItsAgentNoLongerWaits() {
        let delivered = [note("a", block: "block:a"), note("b", block: "block:b")]
        #expect(NotificationTidy.stale(delivered, servers: [studio(waiting: ["block:a", "block:b"])]).isEmpty)
        #expect(NotificationTidy.stale(delivered, servers: [studio(waiting: ["block:a"])]) == ["b"])
        // A pane that is gone has no agent that waits.
        #expect(NotificationTidy.stale(delivered, servers: [studio(waiting: [])]) == ["a", "b"])
    }

    @Test func aQuestionWithActionsGoesAsAnyQuestionDoes() {
        let delivered = [note("a", "AGENT_BLOCKED_ACT", block: "block:a"), note("b", "AGENT_BLOCKED_ACT", block: "block:b")]
        #expect(NotificationTidy.stale(delivered, servers: [studio(waiting: ["block:a", "block:b"])]).isEmpty)
        #expect(NotificationTidy.stale(delivered, servers: [studio(waiting: ["block:a"])]) == ["b"])
        #expect(NotificationTidy.stale(delivered, servers: [studio(waiting: nil)]).isEmpty)
        #expect(NotificationTidy.agentCategories == ["AGENT_BLOCKED", "AGENT_BLOCKED_ACT", "AGENT_DONE"])
    }

    @Test func aFinishedGoesWhenItsAgentIsNotWaiting() {
        let delivered = [note("a", "AGENT_DONE", block: "block:a"), note("b", "AGENT_DONE", block: "block:b")]
        #expect(NotificationTidy.stale(delivered, servers: [studio(waiting: [])]) == ["a", "b"])
        // The agent asks again by now: what is in the list is about a pane that needs the person.
        #expect(NotificationTidy.stale(delivered, servers: [studio(waiting: ["block:b"])]) == ["a"])
    }

    @Test func aNoticeIsNeverRemoved() {
        let delivered = [note("n1", "NOTICE", block: "block:a"), note("n2", "NOTICE", block: "block:gone"),
                         note("n3", "NOTICE", block: "block:a", server: "https://removed.example.ts.net"),
                         note("n4", "", block: "block:a"), note("n5", "SOMETHING_LATER", block: "block:a")]
        #expect(NotificationTidy.stale(delivered, servers: [studio(waiting: [])]).isEmpty)
        #expect(NotificationTidy.stale(delivered, servers: []).isEmpty)
    }

    @Test func theTestNotificationIsNeverRemoved() {
        // As the helper sends it, and even under an agent category.
        let delivered = [note("t1", "NOTICE", block: nil, thread: PushTest.thread),
                         note("t2", "AGENT_DONE", block: "block:a", thread: PushTest.thread)]
        #expect(NotificationTidy.stale(delivered, servers: [studio(waiting: [])]).isEmpty)
        #expect(NotificationTidy.stale(delivered, servers: []).isEmpty)
    }

    @Test func aServerWhoseAgentsAreNotKnownKeepsEverything() {
        let delivered = [note("a"), note("b", "AGENT_DONE", block: "block:gone")]
        #expect(NotificationTidy.stale(delivered, servers: [studio(waiting: nil)]).isEmpty)
    }

    @Test func aServerThatLeftTheAppLosesItsAgentNotifications() {
        let gone = "https://removed.example.ts.net"
        let delivered = [note("a", server: gone), note("b", "AGENT_DONE", server: gone), note("c", block: "block:a")]
        #expect(NotificationTidy.stale(delivered, servers: [studio(waiting: ["block:a"])]) == ["a", "b"])
        #expect(NotificationTidy.stale(delivered, servers: []) == ["a", "b", "c"])
    }

    /// A server that is not connected has not said its name yet, so a push that names no
    /// server of the app may still be its own.
    @Test func noServerCountsAsGoneWhileOneOfTheAppsIsNotKnown() {
        let delivered = [note("a", server: "https://other-name.example.ts.net")]
        let unknown = Server(url: "https://den.example:8443", hostName: nil, waiting: nil)
        #expect(NotificationTidy.stale(delivered, servers: [studio(waiting: []), unknown]).isEmpty)
        // Once it is connected it has said its name, and the push is its own.
        let named = Server(url: "https://den.example:8443", hostName: "other-name.example.ts.net.", waiting: ["block:a"])
        #expect(NotificationTidy.stale(delivered, servers: [studio(waiting: []), named]).isEmpty)
        let answered = Server(url: "https://den.example:8443", hostName: "other-name.example.ts.net.", waiting: [])
        #expect(NotificationTidy.stale(delivered, servers: [studio(waiting: []), answered]) == ["a"])
    }

    @Test func thePaneComesFromThePayloadWhateverTheIdentifierIs() {
        // A collapse id (the pane's id without its prefix, and a record), one iOS made, and
        // one that looks like another pane's: only `block_id` says which pane it is.
        let delivered = [note("a-17", block: "block:a"), note("0C6E2F4A-1B7D-4E55-9A51-3B0C5D8E7F10", block: "block:a"),
                         note("b", block: "block:a"), note("a", block: "block:b")]
        #expect(NotificationTidy.stale(delivered, servers: [studio(waiting: ["block:b"])])
            == ["a-17", "0C6E2F4A-1B7D-4E55-9A51-3B0C5D8E7F10", "b"])
    }

    @Test func whatCannotBeToldStays() {
        let delivered = [note("no-pane", block: nil), note("empty-pane", block: ""),
                         Delivered(identifier: "no-server", category: "AGENT_BLOCKED", threadID: "block:a", server: nil, blockID: "block:a"),
                         Delivered(identifier: "bad-server", category: "AGENT_BLOCKED", threadID: "block:a", server: " ", blockID: "block:a")]
        #expect(NotificationTidy.stale(delivered, servers: [studio(waiting: [])]).isEmpty)
        #expect(NotificationTidy.stale(Array(delivered.suffix(2)), servers: []).isEmpty)
    }

    @Test func aServerIsFoundByItsAddressOrItsNameWithoutCase() {
        let delivered = [note("a", server: "https://Studio.Example.ts.net:8443/")]
        #expect(NotificationTidy.stale(delivered, servers: [studio(waiting: [])]) == ["a"])
        let byName = Server(url: "http://den.example:7777", hostName: "studio.example.ts.net", waiting: ["block:a"])
        #expect(NotificationTidy.stale(delivered, servers: [byName]).isEmpty)
    }

    // MARK: The pace

    @Test func aPassWaitsUntilASecondAfterTheLastOne() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(NotificationTidy.wait(at: t0, last: nil) == 0)
        #expect(NotificationTidy.wait(at: t0, last: t0) == 1)
        #expect(NotificationTidy.wait(at: t0.addingTimeInterval(0.25), last: t0) == 0.75)
        #expect(NotificationTidy.wait(at: t0.addingTimeInterval(5), last: t0) == 0)
        // A clock set back: one pause, never more.
        #expect(NotificationTidy.wait(at: t0.addingTimeInterval(-3600), last: t0) == 1)
    }

    // MARK: The tidier

    @MainActor
    private final class Center {
        var delivered: [Delivered] = []
        var reads = 0
        var removed: [[String]] = []

        var center: NotificationTidier.Center {
            NotificationTidier.Center(delivered: {
                self.reads += 1
                await Task.yield()
                return self.delivered
            }, remove: { ids in
                self.removed.append(ids)
                self.delivered.removeAll { ids.contains($0.identifier) }
            })
        }
    }

    @MainActor
    private struct Rig {
        var center: Center
        var clock: TestClock
        var tidier: NotificationTidier

        /// Waits for what a pass does, 30 s at most: a pass takes a few turns of the main
        /// actor, which a busy machine gives late.
        func until(_ done: () -> Bool) async {
            let end = Date().addingTimeInterval(30)
            while !done(), Date() < end { try? await Task.sleep(nanoseconds: 2_000_000) }
        }

        /// Long enough for a pass that was going to do more to have done it. Only for what
        /// must not happen.
        func settle() async {
            for _ in 0..<20 { await Task.yield() }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func rig(waiting: Set<String>? = []) -> Rig {
        let center = Center(), clock = TestClock()
        clock.passes = false
        let tidier = NotificationTidier(center: center.center, now: { clock.now }, sleep: { await clock.sleep($0) })
        let address = address
        tidier.servers = { [Server(url: address, hostName: nil, waiting: waiting)] }
        return Rig(center: center, clock: clock, tidier: tidier)
    }

    @Test func nothingIsReadOrRemovedBeforeTheAppIsInFront() async {
        let r = rig()
        r.center.delivered = [note("a")]
        r.tidier.request()
        await r.settle()
        #expect(r.center.reads == 0 && r.center.removed.isEmpty)
    }

    @Test func comingToTheFrontRemovesWhatNoLongerHolds() async {
        let r = rig(waiting: ["block:b"])
        r.center.delivered = [note("a", block: "block:a"), note("b", block: "block:b"), note("n", "NOTICE", block: "block:a")]
        r.tidier.becameActive()
        await r.until { !r.center.removed.isEmpty }
        #expect(r.center.removed == [["a"]])
        #expect(r.center.delivered.map(\.identifier) == ["b", "n"])
    }

    @Test func aPassWithNothingStaleRemovesNothing() async {
        let r = rig(waiting: ["block:a"])
        r.center.delivered = [note("a")]
        r.tidier.becameActive()
        await r.until { r.center.reads == 1 }
        await r.settle()
        #expect(r.center.reads == 1 && r.center.removed.isEmpty)
    }

    @Test func manyRequestsInOneSecondAreOneMorePass() async {
        let r = rig()
        r.tidier.becameActive()
        await r.until { r.center.reads == 1 }
        await r.settle()
        #expect(r.center.reads == 1)
        for _ in 0..<50 { r.tidier.request() }
        await r.until { !r.clock.sleeps.isEmpty }
        await r.settle()
        // Held until a second after the first pass.
        #expect(r.center.reads == 1 && r.clock.sleeps == [1])
        r.center.delivered = [note("a")]
        r.clock.advance(by: 1)
        await r.until { !r.center.removed.isEmpty }
        #expect(r.center.reads == 2 && r.center.removed == [["a"]])
        // Nothing was asked for since: no third pass.
        r.clock.advance(by: 10)
        await r.settle()
        #expect(r.center.reads == 2)
    }

    @Test func aRequestAfterAQuietSecondRunsAtOnce() async {
        let r = rig()
        r.tidier.becameActive()
        await r.until { r.center.reads == 1 }
        await r.settle()
        r.clock.advance(by: 3)
        r.tidier.request()
        await r.until { r.center.reads == 2 }
        #expect(r.center.reads == 2 && r.clock.sleeps.isEmpty)
    }

    @Test func nothingIsRemovedOnceTheAppLeftTheFront() async {
        let r = rig()
        r.tidier.becameActive()
        await r.until { r.center.reads == 1 }
        await r.settle()
        r.center.delivered = [note("a")]
        r.tidier.request()
        r.tidier.enteredBackground()
        r.clock.advance(by: 1)
        await r.settle()
        r.tidier.request()
        await r.settle()
        #expect(r.center.removed.isEmpty && r.center.reads == 1)
        // Back in front, it is removed.
        r.clock.advance(by: 5)
        r.tidier.becameActive()
        await r.until { !r.center.removed.isEmpty }
        #expect(r.center.removed == [["a"]])
    }
}
