import Foundation
import Testing
@testable import Pteron

/// Navigate Back and Forward: a browser's history of the panes the phone showed (`NavHistory`).
struct NavHistoryTests {
    private let desk = UUID(), lab = UUID()

    private func place(_ server: UUID, _ window: String, _ block: String? = nil) -> NavPlace {
        NavPlace(serverID: server, sessionID: "s", windowID: window, blockID: block)
    }

    @Test func backAndForwardRetraceThePlacesShown() {
        var h = NavHistory()
        let a = place(desk, "w1", "b1"), b = place(desk, "w1", "b2"), c = place(lab, "w9", "b9")
        for p in [a, b, c] { h.visit(p) }
        #expect(h.back(where: { _ in true }) == b)
        #expect(h.back(where: { _ in true }) == a)
        #expect(h.back(where: { _ in true }) == nil, "nothing before the first place")
        #expect(h.current == a)
        #expect(h.forward(where: { _ in true }) == b)
        #expect(h.forward(where: { _ in true }) == c)
        #expect(h.forward(where: { _ in true }) == nil)
        #expect(h.current == c)
    }

    @Test func goingSomewhereNewDropsWhatLayForward() {
        var h = NavHistory()
        let a = place(desk, "w1"), b = place(desk, "w2"), c = place(desk, "w3")
        h.visit(a)
        h.visit(b)
        _ = h.back(where: { _ in true })
        h.visit(c)
        #expect(!h.canGoForward(where: { _ in true }))
        #expect(h.back(where: { _ in true }) == a)
    }

    @Test func theSamePlaceAgainIsNoStep() {
        var h = NavHistory()
        let a = place(desk, "w1", "b1")
        h.visit(a)
        h.visit(a)
        #expect(h.older.isEmpty)
        // Landing where Back went records nothing new and keeps the way forward.
        h.visit(place(desk, "w2"))
        let back = h.back(where: { _ in true })
        h.visit(back!)
        #expect(h.canGoForward(where: { _ in true }))
    }

    @Test func aPlaceThatClosedIsPassedOverAndDropped() {
        var h = NavHistory()
        let a = place(desk, "w1"), gone = place(desk, "w2"), c = place(desk, "w3")
        for p in [a, gone, c] { h.visit(p) }
        #expect(h.canGoBack(where: { $0 != gone }))
        #expect(h.back(where: { $0 != gone }) == a)
        #expect(h.newer == [c], "the closed tab is not kept to go forward to")
    }

    @Test func withNowhereToGoNothingChanges() {
        var h = NavHistory()
        let a = place(lab, "w1"), b = place(desk, "w2")
        h.visit(a)
        h.visit(b)
        // The lab computer's tabs aren't loaded: its places wait for it.
        #expect(!h.canGoBack(where: { $0.serverID != lab }))
        #expect(h.back(where: { $0.serverID != lab }) == nil)
        #expect(h.older == [a])
        #expect(h.current == b)
    }

    @Test func itKeepsTheLast64Places() {
        var h = NavHistory()
        for i in 0..<100 { h.visit(place(desk, "w\(i)")) }
        #expect(h.older.count == NavHistory.limit)
        #expect(h.older.first == place(desk, "w35"))
    }
}
