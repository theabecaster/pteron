import Foundation
@testable import RexDuo

/// The render thread counts the panes of the whole process, so a test checks that count against
/// what it found when it began: a pane of a test that ended a moment ago, or of one that runs
/// beside this one, is not this test's to answer for.
struct PaneBaseline {
    let before: Int

    init() { before = GhosttyRenderThread.shared.paneCount }

    /// A count taken once the panes of earlier tests are gone, waiting `seconds` at most for
    /// that. For a test that needs the count to be exact while it runs.
    static func afterQuiet(within seconds: TimeInterval = 5) async -> PaneBaseline {
        let end = Date().addingTimeInterval(seconds)
        while GhosttyRenderThread.shared.paneCount > 0, Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
        return PaneBaseline()
    }

    /// Panes registered now beyond those at the start.
    var left: Int { max(0, GhosttyRenderThread.shared.paneCount - before) }

    /// Waits until none is left, for `seconds` at most. True when none is.
    func cleared(within seconds: TimeInterval = 30) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while left > 0, Date() < end { try? await Task.sleep(nanoseconds: 10_000_000) }
        return left == 0
    }
}
