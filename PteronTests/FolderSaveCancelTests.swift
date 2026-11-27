import Foundation
import Testing
import RexKit
@testable import Pteron

/// A folder's Save or Share in the file browser, cancelled: the browser is free at once for the
/// next Save, while the cancelled one's task still ends (the fs block's close, which the server
/// answers only once it has walked the folder). Nothing of that task shows afterwards.
@MainActor
struct FolderSaveCancelTests {
    /// Stands in for `PaneFiles`' fs block: each transfer waits until the test lets it go on,
    /// as a slow `new_block` or a `block.close` held by the server's walk does.
    final class Blocks {
        var started: [String] = []
        private var waits: [CheckedContinuation<Bool, Never>] = []
        /// What each transfer's body threw, once it ran.
        var bodyErrors: [Error?] = []

        var run: (_ body: @escaping @MainActor (String, @escaping FsOpen) async throws -> Void) async throws -> Void {
            { [self] body in
                started.append("block:\(started.count)")
                // True: run the body, then end; false: end without it.
                guard await withCheckedContinuation({ waits.append($0) }) else { return }
                do {
                    try await body("block:fs") { _ in throw RexError.local("no data connection here") }
                    bodyErrors.append(nil)
                } catch {
                    bodyErrors.append(error)
                    throw error
                }
            }
        }

        var waiting: Int { waits.count }

        func letGo(runningBody: Bool) {
            waits.removeFirst().resume(returning: runningBody)
        }

        /// Ends every transfer still waiting, so no task is left behind.
        func finish() {
            while !waits.isEmpty { letGo(runningBody: false) }
        }
    }

    private func opener(_ notice: Notice, _ blocks: Blocks) -> FileOpener {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let o = FileOpener(control: control, sessionID: "session:s", blockID: "block:term", notice: notice)
        o.withFsBlock = blocks.run
        return o
    }

    private func eventually(seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(seconds) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func cancelFreesTheBrowserForTheNextSaveAtOnce() async {
        let notice = Notice(), blocks = Blocks()
        let o = opener(notice, blocks)
        o.exportFolder("/home/u/big", machine: "studio", to: .files, over: nil)
        #expect(notice.message == "Saving big · 0%")
        o.cancel()
        #expect(notice.message == "Didn't save big.")
        // The cancelled task is still out, and the next Save starts.
        o.exportFolder("/home/u/small", machine: "studio", to: .files, over: nil)
        // Its progress takes the place of the note at once.
        #expect(notice.message == "Saving small · 0%")
        #expect(await eventually { blocks.started.count == 2 })
        blocks.finish()
    }

    @Test func aFileSaveIsNotHeldBackByACancelledFolder() async {
        let notice = Notice(), blocks = Blocks()
        let o = opener(notice, blocks)
        o.exportFolder("/home/u/big", machine: "studio", to: .share, over: nil)
        #expect(await eventually { blocks.waiting == 1 })
        o.cancel()
        o.export("/home/u/notes.txt", machine: "studio", to: .files, over: nil)
        #expect(notice.message != "Wait for the file on its way to finish.")
        blocks.finish()
    }

    /// The cancelled transfer ends later, without its archive ("nothing arrived"): it says
    /// nothing, and the next Save's progress stays.
    @Test func theCancelledTasksLateEndShowsNothing() async {
        let notice = Notice(), blocks = Blocks()
        let o = opener(notice, blocks)
        o.exportFolder("/home/u/big", machine: "studio", to: .files, over: nil)
        o.cancel()
        o.exportFolder("/home/u/small", machine: "studio", to: .files, over: nil)
        #expect(await eventually { blocks.waiting == 2 })
        blocks.letGo(runningBody: false)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(notice.message == "Saving small · 0%")
        // The next Save is still the one under way: a second tap is still told to wait.
        o.exportFolder("/home/u/other", machine: "studio", to: .files, over: nil)
        #expect(notice.message == "Wait for the file on its way to finish.")
        #expect(blocks.started.count == 2)
        blocks.finish()
    }

    /// Cancelled while its fs block was still being made: once the block is there, nothing is
    /// asked of it, and the block is closed as always.
    @Test func aCancelBeforeTheBlockIsMadeAsksForNothing() async {
        let notice = Notice(), blocks = Blocks()
        let o = opener(notice, blocks)
        o.exportFolder("/home/u/big", machine: "studio", to: .files, over: nil)
        #expect(await eventually { blocks.waiting == 1 })
        o.cancel()
        blocks.letGo(runningBody: true)
        #expect(await eventually { blocks.bodyErrors.count == 1 })
        #expect(blocks.bodyErrors.first.flatMap { $0 as? FsDownloader.Failure } == .cancelled)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(notice.message == "Didn't save big.")
    }

    @Test func aSecondTapWhileTheFirstRunsWaits() async {
        let notice = Notice(), blocks = Blocks()
        let o = opener(notice, blocks)
        o.exportFolder("/home/u/big", machine: "studio", to: .files, over: nil)
        o.exportFolder("/home/u/big", machine: "studio", to: .files, over: nil)
        #expect(notice.message == "Wait for the file on its way to finish.")
        #expect(await eventually { blocks.waiting == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(blocks.started.count == 1)
        blocks.finish()
    }

    @Test func withdrawPutsAwayThatNoteOnlyAndShowsWhatItHeld() {
        let n = Notice()
        n.show("Didn't save big.", style: .neutral)
        n.showProgress("Saving small · 0%", fraction: 0) {}
        #expect(n.message == "Didn't save big.")
        n.withdraw("Didn't save other.")
        #expect(n.message == "Didn't save big.")
        n.withdraw("Didn't save big.")
        #expect(n.message == "Saving small · 0%")
        // Progress isn't a plain notice: withdraw leaves it.
        n.withdraw("Saving small · 0%")
        #expect(n.message == "Saving small · 0%")
    }
}
