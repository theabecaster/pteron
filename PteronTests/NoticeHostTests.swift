import Foundation
import Testing
@testable import Pteron

/// Where the notice draws: the app's screen, or the sheet on top that hosts it (the file browser),
/// so a download started from the sheet shows its progress and Cancel there, not under it.
@MainActor
struct NoticeHostTests {
    @Test func theAppsScreenDrawsWithNoSheet() {
        let n = Notice()
        #expect(n.draws(in: nil))
    }

    @Test func aHostingSheetDrawsInsteadOfTheScreenUnderIt() {
        let n = Notice()
        let sheet = n.claimHost()
        #expect(n.draws(in: sheet))
        #expect(!n.draws(in: nil))
    }

    @Test func theScreenDrawsAgainOnceTheSheetGoes() {
        let n = Notice()
        let sheet = n.claimHost()
        n.releaseHost(sheet)
        #expect(n.draws(in: nil))
        #expect(!n.draws(in: sheet))
    }

    /// A pushed folder hosts it before the folder it left lets go, and either may go first.
    @Test func theNewestHostDrawsWhateverOrderTheyGoIn() {
        let n = Notice()
        let first = n.claimHost()
        let second = n.claimHost()
        #expect(n.draws(in: second))
        #expect(!n.draws(in: first))
        n.releaseHost(first)
        #expect(n.draws(in: second))
        n.releaseHost(second)
        #expect(n.draws(in: nil))
    }

    @Test func releasingTwiceChangesNothing() {
        let n = Notice()
        let a = n.claimHost()
        let b = n.claimHost()
        n.releaseHost(a)
        n.releaseHost(a)
        #expect(n.draws(in: b))
    }

    /// A download's progress started on the sheet stays the same notice when the sheet goes: the
    /// screen draws it, with its Cancel, which still cancels.
    @Test func progressMovesWithTheHostAndKeepsItsCancel() {
        let n = Notice()
        let sheet = n.claimHost()
        var cancelled = false
        n.showProgress("Saving logs · 23%", fraction: 0.23) { cancelled = true }
        #expect(n.draws(in: sheet))
        #expect(n.message == "Saving logs · 23%")
        #expect(n.actionTitle == "Cancel")
        n.releaseHost(sheet)
        #expect(n.draws(in: nil))
        #expect(n.message == "Saving logs · 23%")
        n.runAction()
        #expect(cancelled)
        #expect(n.message == nil)
    }

    /// The system's Save or Share sheet comes once the progress is put away.
    @Test func dismissPutsTheProgressAway() {
        let n = Notice()
        _ = n.claimHost()
        n.showProgress("Getting logs · 99%", fraction: 0.99) {}
        n.dismiss()
        #expect(n.message == nil)
        #expect(n.progress == nil)
        #expect(n.actionTitle == nil)
    }

    /// The download is in and the system's sheet is coming: its progress goes once the sheet is
    /// in, and only it.
    @Test func dismissProgressPutsAwayThatProgressOnly() {
        let n = Notice()
        n.showProgress("Saving logs · 100%", fraction: 1) {}
        n.dismissProgress("Saving other · 100%")
        #expect(n.message == "Saving logs · 100%")
        n.dismissProgress("Saving logs · 100%")
        #expect(n.message == nil)
    }

    /// A note that came while the sheet was coming in (links left out) stays its full time, and
    /// the progress it held back doesn't come back after it.
    @Test func dismissProgressLeavesANoteThatCameSince() async {
        let n = Notice()
        n.plainSeconds = 0.2
        n.show("logs came without its 1 link.", style: .neutral)
        n.showProgress("Saving logs · 100%", fraction: 1) {}
        n.dismissProgress("Saving logs · 100%")
        #expect(n.message == "logs came without its 1 link.")
        try? await Task.sleep(for: .milliseconds(500))
        #expect(n.message == nil)
    }

    @Test func progressReadsInWholePercentsRoundedDown() {
        #expect(FileOpener.progress("Saving", "logs", got: 0, size: 0).text == "Saving logs · 0%")
        #expect(FileOpener.progress("Saving", "logs", got: 0, size: 0).fraction == 0)
        #expect(FileOpener.progress("Saving", "logs", got: 23, size: 100).text == "Saving logs · 23%")
        #expect(FileOpener.progress("Saving", "logs", got: 999, size: 1000).text == "Saving logs · 99%")
        #expect(FileOpener.progress("Getting", "logs", got: 1000, size: 1000).text == "Getting logs · 100%")
    }

    @Test func progressNeverPassesTheEnds() {
        let over = FileOpener.progress("Saving", "a", got: 2000, size: 1000)
        #expect(over.fraction == 1)
        #expect(over.text == "Saving a · 100%")
        let under = FileOpener.progress("Saving", "a", got: -5, size: 1000)
        #expect(under.fraction == 0)
        #expect(under.text == "Saving a · 0%")
    }
}
