import Foundation
import Testing
import RexKit
@testable import Pteron

/// A send through an fs block (folders, several items, photos, a drop), cancelled: the sender is
/// free at once for the next send, while the cancelled one's task still ends (the start's answer
/// and the fs block's close, each a round trip, and the close is what stops a server still
/// putting the archive in place). Nothing of that task shows or is typed afterwards.
@MainActor
struct FolderSendCancelTests {
    /// Stands in for `PaneFiles`' fs block: each transfer waits until the test lets it go on,
    /// as a slow `new_block` or `block.close` does.
    final class Blocks {
        var started: [String] = []
        private var waits: [CheckedContinuation<Bool, Never>] = []
        /// What each transfer's body threw, once it ran.
        var bodyErrors: [Error?] = []

        var run: (_ body: @escaping @MainActor (String, @escaping FsOpen) async throws -> Void) async throws -> Void {
            { [self] body in
                started.append("block:\(started.count)")
                // True: run the body, then end; false: end without it, as an upload that was
                // confirmed and whose block then closed.
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

    final class Sent {
        var paths: [[String]] = []
    }

    private func sender(_ notice: Notice, _ blocks: Blocks) -> FileSender {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let s = FileSender(control: control, sessionID: "session:s", blockID: "block:term", notice: notice)
        s.withFsBlock = blocks.run
        return s
    }

    /// A folder of one file on this device, as the Files picker gives it.
    private func folder(_ name: String) throws -> Outgoing {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("send-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("zz".utf8).write(to: url.appendingPathComponent("a.txt"))
        return Outgoing(url: url, name: name, isFolder: true, owned: false, scoped: false)
    }

    private func eventually(seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(seconds) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func sendTree(_ s: FileSender, _ item: Outgoing, _ sent: Sent) {
        s.sendTree([item], over: nil) { paths, _ in sent.paths.append(paths) }
    }

    @Test func cancelFreesTheSenderForTheNextSendAtOnce() async throws {
        let notice = Notice(), blocks = Blocks(), sent = Sent()
        let s = sender(notice, blocks)
        sendTree(s, try folder("big"), sent)
        #expect(await eventually { blocks.waiting == 1 })
        #expect(notice.message == "Sending big to this computer · 0%")
        s.cancel()
        #expect(notice.message == "Didn't send big.")
        #expect(!s.busy)
        // The cancelled task is still out, and the next send starts.
        sendTree(s, try folder("small"), sent)
        // Its progress takes the place of the note at once.
        #expect(notice.message == "Preparing small…")
        #expect(await eventually { blocks.started.count == 2 })
        #expect(notice.message == "Sending small to this computer · 0%")
        blocks.finish()
    }

    /// Cancel at 100%: the upload was confirmed, or the server finished, and the fs block's
    /// close was still out at the Cancel. That late end types no path and says nothing.
    @Test func aCancelWhileTheBlockClosesTypesNoPath() async throws {
        let notice = Notice(), blocks = Blocks(), sent = Sent()
        let s = sender(notice, blocks)
        sendTree(s, try folder("big"), sent)
        #expect(await eventually { blocks.waiting == 1 })
        s.cancel()
        blocks.letGo(runningBody: false)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sent.paths.isEmpty)
        #expect(notice.message == "Didn't send big.")
    }

    /// The cancelled send ends later while the next one runs: it says nothing and types
    /// nothing, and the next send's progress stays.
    @Test func theCancelledSendsLateEndShowsNothing() async throws {
        let notice = Notice(), blocks = Blocks(), sent = Sent()
        let s = sender(notice, blocks)
        sendTree(s, try folder("big"), sent)
        #expect(await eventually { blocks.waiting == 1 })
        s.cancel()
        sendTree(s, try folder("small"), sent)
        #expect(await eventually { blocks.waiting == 2 })
        blocks.letGo(runningBody: false)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sent.paths.isEmpty)
        #expect(notice.message == "Sending small to this computer · 0%")
        // The next send is still the one under way: another is still told to wait.
        sendTree(s, try folder("other"), sent)
        #expect(notice.message == "Wait for the files on their way to finish.")
        #expect(blocks.started.count == 2)
        blocks.finish()
    }

    /// Cancel at 0%, while the fs block is still being made: once the block is there, nothing
    /// is asked of it, and the block is closed as always.
    @Test func aCancelBeforeTheBlockIsMadeAsksForNothing() async throws {
        let notice = Notice(), blocks = Blocks(), sent = Sent()
        let s = sender(notice, blocks)
        sendTree(s, try folder("big"), sent)
        #expect(await eventually { blocks.waiting == 1 })
        s.cancel()
        blocks.letGo(runningBody: true)
        #expect(await eventually { blocks.bodyErrors.count == 1 })
        #expect(blocks.bodyErrors.first.flatMap { $0 as? FsUploader.Failure } == .cancelled)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(sent.paths.isEmpty)
        #expect(notice.message == "Didn't send big.")
    }

    /// A double tap on Cancel says it once and cancels nothing that came after.
    @Test func aSecondCancelChangesNothing() async throws {
        let notice = Notice(), blocks = Blocks(), sent = Sent()
        let s = sender(notice, blocks)
        sendTree(s, try folder("big"), sent)
        #expect(await eventually { blocks.waiting == 1 })
        s.cancel()
        s.cancel()
        #expect(notice.message == "Didn't send big.")
        sendTree(s, try folder("small"), sent)
        #expect(await eventually { blocks.started.count == 2 })
        #expect(s.busy)
        blocks.finish()
    }

    @Test func aFileSendIsNotHeldBackByACancelledTree() async throws {
        let notice = Notice(), blocks = Blocks(), sent = Sent()
        let s = sender(notice, blocks)
        sendTree(s, try folder("big"), sent)
        #expect(await eventually { blocks.waiting == 1 })
        s.cancel()
        let staged = try FileStaging.stage(data: Data("zz".utf8), as: "zz.txt")
        s.send([staged], over: nil)
        #expect(notice.message != "Wait for the files on their way to finish.")
        s.cancel()
        blocks.finish()
    }

    @Test func aSecondSendWhileTheFirstRunsWaits() async throws {
        let notice = Notice(), blocks = Blocks(), sent = Sent()
        let s = sender(notice, blocks)
        sendTree(s, try folder("big"), sent)
        sendTree(s, try folder("big"), sent)
        #expect(notice.message == "Wait for the files on their way to finish.")
        #expect(await eventually { blocks.waiting == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(blocks.started.count == 1)
        blocks.finish()
    }
}
