import Testing
@testable import Pteron

/// The sidebar's agent count pills (`AgentCounts`): which show, in which order, and what they say.
struct AgentCountsTests {
    @Test func waitingComesBeforeWorkingAndHidesIdle() {
        let c = AgentCounts(states: ["working", "blocked", "idle", "blocked", "done", nil])
        #expect(c.pills.map(\.kind) == [.waiting, .working])
        #expect(c.pills.map(\.count) == [2, 1])
        #expect(c.pills.first?.words == "2 waiting")
    }

    @Test func idleCountsEveryAgentWhenNoneWaitsOrWorks() {
        let c = AgentCounts(states: ["idle", "done", "error"])
        #expect(c.pills == [AgentCounts.Pill(kind: .idle, count: 3)])
        #expect(c.pills[0].words == "3 idle")
    }

    @Test func noAgentsIsOnePill() {
        let c = AgentCounts(states: [])
        #expect(c.pills.map(\.kind) == [.none])
        #expect(c.pills[0].words == "none")
        #expect(c.pills[0].spoken == "No agents")
    }

    @Test func spokenFormIsAlwaysWords() {
        let c = AgentCounts(states: ["blocked"] + Array(repeating: "working", count: 12))
        #expect(c.pills.map(\.spoken) == ["1 agent waiting", "12 agents working"])
    }
}
