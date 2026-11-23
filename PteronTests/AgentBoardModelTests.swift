import Foundation
import Testing
import RexKit
@testable import Pteron

private let studio = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
private let laptop = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
private let t0 = Date(timeIntervalSince1970: 1000)

private func agent(_ id: String, _ state: String?, on server: UUID = studio, since: TimeInterval? = nil) -> BoardAgent {
    BoardAgent(server: server, sessionID: "session:s", windowID: "window:w", blockID: id, kind: .claude, name: "Claude",
               state: state, stateText: state ?? "Idle", progress: nil, message: nil, place: "api › tab",
               waitingSince: since.map { t0.addingTimeInterval($0) })
}

private func machine(_ agents: [BoardAgent], _ link: BoardMachine.Link = .live, id: UUID = studio, name: String = "Studio") -> BoardMachine {
    BoardMachine(id: id, name: name, link: link, agents: agents)
}

/// What the board says and in which order, for the machines and agents it is given.
struct AgentBoardModelTests {
    @Test func theHeadlineNamesTheMostUrgentState() {
        func head(_ states: [String?]) -> String {
            AgentBoard.make([machine(states.enumerated().map { agent("b\($0.offset)", $0.element) })]).headline
        }
        #expect(head(["blocked", "error", "working", "done", nil]) == "1 waiting")
        #expect(head(["blocked", "blocked", "working"]) == "2 waiting")
        #expect(head(["error", "working", "done"]) == "1 error")
        #expect(head(["error", "error", "done"]) == "2 errors")
        // One error and one done is not "All done".
        #expect(head(["error", "done"]) == "1 error")
        #expect(head(["working", "working", "working", "done", nil]) == "3 working")
        #expect(head(["working"]) == "1 working")
        #expect(head(["done", nil]) == "All done")
        #expect(head([nil, "idle"]) == "All quiet")
        #expect(head([]) == "All quiet")
    }

    @Test func urgencyAndGlowFollowTheHeadline() {
        func board(_ states: [String?]) -> AgentBoard {
            AgentBoard.make([machine(states.enumerated().map { agent("b\($0.offset)", $0.element) })])
        }
        #expect(board(["blocked", "error"]).urgency == .waiting)
        #expect(board(["blocked", "error"]).glow == .waiting)
        #expect(board(["error", "working"]).glow == .error)
        #expect(board(["working", "done"]).glow == .working)
        // No glow when all are done or idle.
        #expect(board(["done"]).urgency == .done)
        #expect(board(["done"]).glow == nil)
        #expect(board([nil]).glow == nil)
    }

    @Test func noMachines() {
        let b = AgentBoard.make([])
        #expect(b.headline == "No computers yet")
        #expect(b.urgency == .unpaired)
        #expect(b.subline.isEmpty)
        #expect(b.tiles.isEmpty)
        #expect(b.glow == nil)
    }

    @Test func tilesAreOrderedLikeTheAgentsModeAcrossMachines() {
        let b = AgentBoard.make([
            machine([agent("done", "done"), agent("work", "working"), agent("wait-new", "blocked", since: 50), agent("idle", nil)]),
            machine([agent("err", "error", on: laptop), agent("wait-old", "blocked", on: laptop, since: 10),
                     agent("work2", "working", on: laptop)], id: laptop, name: "Laptop"),
        ])
        // Waiting, the longest first, then error, working (the server's order), done. Idle has no tile.
        #expect(b.tiles.map(\.agent.blockID) == ["wait-old", "wait-new", "err", "work", "work2", "done"])
        #expect(b.idleCount == 1)
        #expect(b.headline == "2 waiting")
    }

    @Test func aWaitingAgentWithNoTimeComesAfterThoseWithOne() {
        let b = AgentBoard.make([machine([agent("unknown", "blocked"), agent("known", "blocked", since: 5)])])
        #expect(b.tiles.map(\.agent.blockID) == ["known", "unknown"])
    }

    @Test func theMachineNameShowsOnlyWhenTilesSpanMachines() {
        let one = AgentBoard.make([machine([agent("a", "working")]), machine([agent("i", nil, on: laptop)], id: laptop, name: "Laptop")])
        #expect(one.tiles.map(\.machineName) == [nil])
        let two = AgentBoard.make([machine([agent("a", "working")]),
                                   machine([agent("b", "done", on: laptop)], id: laptop, name: "Laptop")])
        #expect(two.tiles.map(\.machineName) == ["Studio", "Laptop"])
    }

    @Test func aDownMachineKeepsItsTilesDimmedAndIsNotCounted() {
        let b = AgentBoard.make([
            machine([agent("live-work", "working")]),
            machine([agent("old-wait", "blocked", on: laptop, since: 1), agent("old-idle", nil, on: laptop)], .stale, id: laptop, name: "Laptop"),
        ])
        // The stale agent waits, but nobody knows whether it still does.
        #expect(b.headline == "1 working")
        #expect(b.glow == .working)
        #expect(b.tiles.map(\.agent.blockID) == ["live-work", "old-wait"], "live tiles first, whatever the stale states")
        #expect(b.tiles.map(\.stale) == [false, true])
        #expect(b.idleCount == 1)
    }

    /// A quiet machine beside one that is down with a tile: "All quiet" would be read as the
    /// whole truth over a dimmed tile that last needed you.
    @Test func neverAllQuietOrAllDoneOverStaleTiles() {
        let down = machine([agent("old-wait", "blocked", on: laptop, since: 1)], .stale, id: laptop, name: "Laptop")
        let quiet = AgentBoard.make([machine([agent("idle", nil)]), down])
        #expect(quiet.headline == "Reconnecting…")
        #expect(quiet.urgency == .reconnecting)
        #expect(quiet.glow == nil)
        #expect(quiet.tiles.map(\.stale) == [true])
        // The headline says it already.
        #expect(quiet.subline == "1 of 2 computers connected")
        let done = AgentBoard.make([machine([agent("done", "done")]), down])
        #expect(done.headline == "Reconnecting…")
        #expect(done.tiles.map(\.agent.blockID) == ["done", "old-wait"])
        // A live state that is more urgent than quiet still leads.
        #expect(AgentBoard.make([machine([agent("w", "working")]), down]).headline == "1 working")
        // A down machine with only idle agents has no tile: the live ones are all there is to say.
        let idleDown = machine([agent("old-idle", nil, on: laptop)], .stale, id: laptop, name: "Laptop")
        #expect(AgentBoard.make([machine([agent("idle", nil)]), idleDown]).headline == "All quiet")
        #expect(AgentBoard.make([machine([agent("done", "done")]), idleDown]).headline == "All done")
    }

    @Test func withNoMachineConnectedTheBoardSaysSo() {
        let down = AgentBoard.make([machine([agent("a", "blocked", since: 1)], .stale)])
        #expect(down.headline == "Reconnecting…")
        #expect(down.urgency == .reconnecting)
        #expect(down.glow == nil)
        #expect(down.tiles.map(\.stale) == [true])
        #expect(down.subline == "Studio")
        let never = AgentBoard.make([machine([], .never)])
        #expect(never.headline == "Connecting…")
        #expect(never.urgency == .connecting)
        #expect(never.tiles.isEmpty)
    }

    @Test func theSublineNamesMachinesOrCountsThem() {
        func m(_ n: String, _ link: BoardMachine.Link) -> BoardMachine { BoardMachine(id: UUID(), name: n, link: link, agents: []) }
        #expect(AgentBoard.subline([m("Studio", .live)]) == "Studio")
        #expect(AgentBoard.subline([m("Studio", .live), m("Laptop", .live)]) == "Studio · Laptop")
        #expect(AgentBoard.subline([m("Studio", .live), m("Laptop", .live), m("Mini", .live)]) == "3 of 3 computers connected")
        // A machine that never connected this launch is counted and has no tiles.
        #expect(AgentBoard.subline([m("Studio", .live), m("Laptop", .never)]) == "1 of 2 computers connected")
        #expect(AgentBoard.subline([m("Studio", .live), m("Laptop", .stale)]) == "1 of 2 computers connected · Reconnecting…")
        #expect(AgentBoard.subline([m("Studio", .stale), m("Laptop", .stale)]) == "Studio · Laptop")
        #expect(AgentBoard.subline([m("A", .stale), m("B", .stale), m("C", .never)]) == "3 computers")
    }

    @Test func elapsedTimeInWords() {
        #expect(AgentBoard.elapsed(0) == nil)
        #expect(AgentBoard.elapsed(59) == nil)
        #expect(AgentBoard.elapsed(60) == "1m")
        #expect(AgentBoard.elapsed(12 * 60 + 30) == "12m")
        #expect(AgentBoard.elapsed(3600) == "1h")
        #expect(AgentBoard.elapsed(95 * 60) == "1h")
        #expect(AgentBoard.elapsed(49 * 3600) == "2d")
    }

    @Test func stateWordsAreTheAgentsModes() {
        func status(_ state: String, kind: String? = nil, progress: Int? = nil) -> ProgramStatus {
            var s = ProgramStatus([:])
            s.state = state
            s.waitingFor = kind
            s.progress = progress
            return s
        }
        #expect(AgentRowLabel.stateText(status("working")) == "Working")
        #expect(AgentRowLabel.stateText(status("working", progress: 62)) == "Working 62%")
        #expect(AgentRowLabel.stateText(status("blocked", kind: "permission")) == "Needs your permission")
        #expect(AgentRowLabel.stateText(status("blocked", kind: "question")) == "Has a question")
        #expect(AgentRowLabel.stateText(status("blocked", kind: "auth")) == "Needs your password")
        #expect(AgentRowLabel.stateText(status("blocked")) == "Waiting for you")
        #expect(AgentRowLabel.stateText(status("done")) == "Done")
        #expect(AgentRowLabel.stateText(status("error")) == "Error")
        #expect(AgentRowLabel.stateText(status("idle")) == "Idle")
        #expect(AgentRowLabel.stateText(nil) == "Idle")
    }
}

/// The board reorders its tiles at most once a second.
struct BoardOrderThrottleTests {
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    @Test func theFirstOrderIsTakenAsItIs() {
        var t = BoardOrderThrottle()
        let r = t.order(desired: ["a", "b", "c"], now: at(0))
        #expect(r.ids == ["a", "b", "c"])
        #expect(r.retryAt == nil)
    }

    @Test func aTileThatComesOrGoesShowsAtOnce() {
        var t = BoardOrderThrottle()
        _ = t.order(desired: ["a", "b", "c"], now: at(0))
        // A new one in the middle, one gone: the others keep their order, so nothing is held.
        let r = t.order(desired: ["a", "x", "c"], now: at(0.1))
        #expect(r.ids == ["a", "x", "c"])
        #expect(r.retryAt == nil)
    }

    @Test func aReorderIsTakenWhenASecondHasPassedSinceTheLast() {
        var t = BoardOrderThrottle()
        _ = t.order(desired: ["a", "b", "c"], now: at(0))
        let first = t.order(desired: ["c", "a", "b"], now: at(5))
        #expect(first.ids == ["c", "a", "b"])
        #expect(first.retryAt == nil)
        // Another one 0.3 s later is held: the order on screen stays, and it says when to ask again.
        let held = t.order(desired: ["b", "c", "a"], now: at(5.3))
        #expect(held.ids == ["c", "a", "b"])
        #expect(held.retryAt == at(6))
        let later = t.order(desired: ["b", "c", "a"], now: at(6))
        #expect(later.ids == ["b", "c", "a"])
        #expect(later.retryAt == nil)
    }

    @Test func whileHeldTilesStillComeAndGo() {
        var t = BoardOrderThrottle()
        _ = t.order(desired: ["a", "b", "c"], now: at(0))
        _ = t.order(desired: ["b", "a", "c"], now: at(5))
        let held = t.order(desired: ["n", "c", "b"], now: at(5.2))
        // `a` left, `n` is new and goes to the end until the reorder may happen.
        #expect(held.ids == ["b", "c", "n"])
        #expect(held.retryAt == at(6))
    }

    @Test func fastChurnReordersAtMostOnceASecond() {
        var t = BoardOrderThrottle()
        let orders = [["a", "b", "c"], ["b", "c", "a"], ["c", "a", "b"]]
        var shown = t.order(desired: orders[0], now: at(0)).ids
        var changes: [TimeInterval] = []
        for step in 1...40 {
            let now = Double(step) * 0.3
            let next = t.order(desired: orders[step % 3], now: at(now)).ids
            if next != shown { changes.append(now) }
            shown = next
        }
        #expect(changes.count >= 3)
        for (a, b) in zip(changes, changes.dropFirst()) { #expect(b - a >= 1 - 0.0001) }
    }

    /// Two changes inside one second share one retry time. The retry applies the second.
    @Test func theRetryAppliesTheNewestOrderNotTheOneThatSetTheTimer() {
        var t = BoardOrderThrottle()
        _ = t.order(desired: ["a", "b", "c"], now: at(0))
        _ = t.order(desired: ["b", "a", "c"], now: at(5))
        let first = t.order(desired: ["c", "b", "a"], now: at(5.2))
        #expect(first.retryAt == at(6))
        // A new tile and another order, still inside the second: the same retry time.
        let second = t.order(desired: ["n", "a", "c", "b"], now: at(5.6))
        #expect(second.retryAt == at(6))
        #expect(second.ids == ["b", "a", "c", "n"], "held: the new tile waits at the end")
        let due = t.retry(now: at(6))
        #expect(due.ids == ["n", "a", "c", "b"], "the newest order, with the new tile where it belongs")
        #expect(due.retryAt == nil)
    }

    @Test func aRetryThatComesEarlyAsksAgain() {
        var t = BoardOrderThrottle()
        _ = t.order(desired: ["a", "b"], now: at(0))
        _ = t.order(desired: ["b", "a"], now: at(5))
        _ = t.order(desired: ["a", "b"], now: at(5.5))
        let early = t.retry(now: at(5.99))
        #expect(early.ids == ["b", "a"])
        #expect(early.retryAt == at(6))
    }

    @Test func insertsDoNotUseUpTheReorder() {
        var t = BoardOrderThrottle()
        _ = t.order(desired: ["a", "b"], now: at(10))
        _ = t.order(desired: ["a", "b", "c"], now: at(10.1))
        // No reorder has happened yet, so this one goes through.
        #expect(t.order(desired: ["c", "a", "b"], now: at(10.2)).ids == ["c", "a", "b"])
    }
}
