import CryptoKit
import GlanceModel
import UIKit
import RexKit

/// Sends files to one pane, one batch at a time, and keeps the user told: a progress notice with
/// Cancel while it runs, then what happened. The server types the paths into the pane once the whole
/// batch has arrived; this side never sends keys for it. Text typed while a batch is on its way
/// reaches the pane first, so the notice tells the user to wait.
@MainActor
final class FileSender {
    private let control: RexControl
    let sessionID: String
    let blockID: String
    /// Where the send goes, in words ("Claude", "studio"), read when it starts.
    var target: () -> String = { "this computer" }
    /// The pane's computer by name, for what Rex there can't do.
    var computer: () -> String = { "this computer" }
    private let notice: Notice
    private var uploader: FileUploader?
    /// The tree send under way (its block may still be being made).
    private var treeRun: TreeRun?
    /// What the last Cancel of a tree send said. The next send takes its place, so its progress
    /// shows at once.
    private var cancelNote: String?
    /// A tree's walk is under way; Cancel sets this.
    private var planCancelled: CancelFlag?
    /// Runs an fs transfer: makes the session's fs block, hands `body` its ID and a way to open
    /// data connections, and closes the block after. Nil where the pane's computer has none.
    var withFsBlock: ((_ body: @escaping @MainActor (String, @escaping FsOpen) async throws -> Void) async throws -> Void)?
    private var background: BackgroundTask?
    private var cutOff = false
    private var shownPercent = -1

    /// From the moment a send is asked for (its cellular question included) until it ends, so a
    /// second one is turned away with a word instead of lost.
    private var claimed = false

    var busy: Bool { claimed || uploader != nil || treeRun != nil }

    /// One send through an fs block. Its Cancel frees the sender at once: the next send can
    /// start while this one's task still ends (the start's answer, the fs block's close, each a
    /// round trip, and the close is what stops a server still putting the archive in place).
    /// Whatever that task does after the Cancel shows nothing and types nothing.
    private final class TreeRun {
        let what: String
        var uploader: FsUploader?
        var background: BackgroundTask?
        var retry: Notice.Action?
        var cancelled = false
        /// Out of background time: what it holds is kept for Try Again.
        var cutOff = false

        init(what: String) { self.what = what }
    }

    init(control: RexControl, sessionID: String, blockID: String, notice: Notice = .shared) {
        self.control = control
        self.sessionID = sessionID
        self.blockID = blockID
        self.notice = notice
    }

    /// Sends `files` as one batch. Above `SendTarget.expensiveLimit` on an expensive network it asks
    /// first, over `view`. The copies are removed when the send ends, except after a failure that
    /// offers Retry.
    func send(_ files: [StagedFile], over view: UIView?) {
        guard !files.isEmpty else { return }
        guard !busy else {
            FileStaging.discard(files)
            self.notice.show("Wait for the files on their way to finish.")
            return
        }
        if let big = files.first(where: { $0.size > FileUploader.maxFileSize }) {
            FileStaging.discard(files)
            self.notice.show(SendTarget.tooLarge(big.name))
            return
        }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        claimed = true
        Task { @MainActor in
            if total > SendTarget.expensiveLimit, await FileStaging.networkIsExpensive(), let view {
                TerminalPrompt.ask(over: view, title: "Send \(SendTarget.size(total)) on cellular?",
                                   message: "\(SendTarget.what(files.map(\.name))) for \(self.target()).",
                                   confirm: "Send") { yes in
                    if yes {
                        self.start(files, over: view)
                    } else {
                        self.claimed = false
                        FileStaging.discard(files)
                    }
                }
            } else {
                self.start(files, over: view)
            }
        }
    }

    func cancel() {
        uploader?.cancel()
        planCancelled?.set()
        if let run = treeRun { cancel(run) }
    }

    /// Ends a tree send for the user now: it says so at once, and the next send can start. A run
    /// that is no longer the one under way is left alone.
    private func cancel(_ run: TreeRun, cutOff: Bool = false) {
        guard treeRun === run else { return }
        treeRun = nil
        claimed = false
        run.cancelled = true
        run.cutOff = cutOff
        run.uploader?.cancel()
        if cutOff {
            notice.show("Sending \(run.what) stopped in the background.", action: run.retry)
        } else {
            let note = "Didn't send \(run.what)."
            cancelNote = note
            notice.show(note, style: .neutral)
        }
    }

    /// A new send starts: the note of the last one's Cancel makes way for its progress.
    private func clearCancelNote() {
        if let note = cancelNote { notice.withdraw(note) }
        cancelNote = nil
    }

    private func start(_ files: [StagedFile], over view: UIView?) {
        guard uploader == nil else { return FileStaging.discard(files) }
        let names = files.map(\.name)
        let to = target()
        clearCancelNote()
        let up = FileUploader(control: control, sessionID: sessionID, blockID: blockID)
        uploader = up
        cutOff = false
        shownPercent = -1
        background = BackgroundTask(name: "Send files") { [weak self] in
            // Out of background time: stop cleanly instead of being killed mid-file.
            guard let self else { return }
            self.cutOff = true
            self.uploader?.cancel()
        }
        let items = files.map { f in
            FileUploader.Item(name: f.name, size: f.size) { [url = f.url] in try FileSource(url: url) }
        }
        let cancel: @MainActor () -> Void = { [weak self] in self?.cancel() }
        self.notice.showProgress(SendTarget.progress(names, to: to, fraction: 0), fraction: 0, cancel: cancel)
        #if DEBUG
        Self.logDigests(files)
        #endif
        Task { @MainActor in
            defer {
                self.uploader = nil
                self.claimed = false
                self.endBackground()
            }
            do {
                try await up.send(items, progress: { sent, total in
                    self.progress(names, to: to, sent: sent, total: total, cancel: cancel)
                })
                FileStaging.discard(files)
                self.notice.show(SendTarget.done(names, to: to), style: .neutral)
                UIAccessibility.post(notification: .announcement, argument: SendTarget.done(names, to: to))
            } catch let f as FileUploader.Failure {
                self.failed(f, files: files, to: to, over: view)
            } catch {
                self.failed(.lost(error.localizedDescription), files: files, to: to, over: view)
            }
        }
    }

    private func progress(_ names: [String], to: String, sent: Int64, total: Int64, cancel: @escaping @MainActor () -> Void) {
        let fraction = total > 0 ? Double(sent) / Double(total) : 1
        let pct = Int(fraction * 100)
        guard pct != shownPercent else { return }
        shownPercent = pct
        self.notice.showProgress(SendTarget.progress(names, to: to, fraction: fraction), fraction: fraction, cancel: cancel)
    }

    private func failed(_ f: FileUploader.Failure, files: [StagedFile], to: String, over view: UIView?) {
        let what = SendTarget.what(files.map(\.name))
        let retry = Notice.Action(title: "Try Again") { [weak self, weak view] in self?.send(files, over: view) }
        switch f {
        case .cancelled where cutOff:
            self.notice.show("Sending \(what) stopped in the background.", action: retry)
        case .cancelled:
            FileStaging.discard(files)
            self.notice.show("Didn't send \(what).", style: .neutral)
        case .unsupported:
            FileStaging.discard(files)
            self.notice.show(Messages.updateRex(computer(), to: "send files"))
        case .unconfirmed:
            FileStaging.discard(files)
            self.notice.show("Sent \(what), but \(to) didn't confirm it. \(Messages.sentUnknown)")
        case .tooLarge:
            FileStaging.discard(files)
            self.notice.show(SendTarget.tooLarge(what))
        case .brokeRule:
            self.notice.show("Couldn't send \(what): it changed while it was read.", action: retry)
        case .refused:
            self.notice.show("\(Messages.capitalized(computer())) refused \(what).", action: retry)
        case .unreadable(let name):
            self.notice.show("Couldn't read \(name) on this \(DeviceWord.current).", action: retry)
        case .lost:
            self.notice.show("Couldn't send \(what). \(Messages.notSent(computer()))", action: retry)
        }
    }

    // MARK: Trees

    /// Sends `items` (files and folders) as one archive through an fs block, into a new folder
    /// under `/tmp` on the pane's computer, so nothing there is ever replaced. The walk that
    /// counts what goes runs off the main actor, with Cancel; then it asks first on an expensive
    /// network as `send` does. `onSent` gets the absolute paths of the items there and what
    /// went; it says so to the user. What the items hold is released when the send ends, except
    /// after a failure that offers Try Again.
    func sendTree(_ items: [Outgoing], over view: UIView?,
                  onSent: @escaping @MainActor (_ paths: [String], _ done: String) -> Void) {
        guard !items.isEmpty else { return }
        guard !busy, let withFsBlock else {
            Outgoing.release(items)
            if busy { self.notice.show("Wait for the files on their way to finish.") }
            return
        }
        claimed = true
        let names = items.map(\.name)
        let folders = items.contains(where: \.isFolder)
        let what = SendTarget.what(names, folders: folders)
        let landing = Self.landingName()
        let flag = CancelFlag()
        planCancelled = flag
        clearCancelNote()
        self.notice.showProgress("Preparing \(what)…", fraction: 0) { flag.set() }
        Task { @MainActor in
            let plan: TarPlan
            do {
                plan = try await Self.plan(items, inside: landing, cancelled: flag)
                if flag.isSet { throw TarPlan.Failure.cancelled }
            } catch {
                self.planCancelled = nil
                self.claimed = false
                switch error as? TarPlan.Failure {
                case .cancelled?:
                    Outgoing.release(items)
                    self.notice.show("Didn't send \(what).", style: .neutral)
                case .unreadable(let name)?:
                    // The notice holds this for a few seconds only.
                    let retry = Notice.Action(title: "Try Again") { self.sendTree(items, over: view, onSent: onSent) }
                    self.notice.show("Couldn't read \(name) on this \(DeviceWord.current).", action: retry)
                default:
                    Outgoing.release(items)
                    self.notice.show("Nothing in \(what) can be sent.")
                }
                return
            }
            self.planCancelled = nil
            let start: @MainActor () -> Void = {
                self.startTree(items, plan: plan, landing: landing, what: what, withFsBlock: withFsBlock, over: view, onSent: onSent)
            }
            if plan.archiveSize > SendTarget.expensiveLimit, await FileStaging.networkIsExpensive(), let view {
                TerminalPrompt.ask(over: view, title: "Send \(SendTarget.size(plan.size)) on cellular?",
                                   message: "\(what) for \(self.target()).", confirm: "Send") { yes in
                    if yes {
                        start()
                    } else {
                        self.claimed = false
                        self.notice.dismiss()
                        Outgoing.release(items)
                    }
                }
            } else {
                start()
            }
        }
    }

    /// `<app>-<12 hex>`: the new folder the items go into.
    nonisolated static func landingName() -> String {
        let hex = (0..<6).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        return Brand.appName.lowercased() + "-" + hex
    }

    /// Walks the items off the main actor. An item from a file provider is read through a file
    /// coordinator first, which brings a folder that is only in the cloud onto this device.
    nonisolated private static func plan(_ items: [Outgoing], inside landing: String, cancelled: CancelFlag) async throws -> TarPlan {
        try await Task.detached(priority: .userInitiated) {
            for item in items where item.scoped {
                var error: NSError?
                NSFileCoordinator().coordinate(readingItemAt: item.url, options: [], error: &error) { _ in }
            }
            return try TarPlan.build(items.map { TarPlan.Root(url: $0.url, name: $0.name) }, inside: landing,
                                     cancelled: { cancelled.isSet })
        }.value
    }

    private func startTree(_ items: [Outgoing], plan: TarPlan, landing: String, what: String,
                           withFsBlock: @escaping (_ body: @escaping @MainActor (String, @escaping FsOpen) async throws -> Void) async throws -> Void,
                           over view: UIView?, onSent: @escaping @MainActor ([String], String) -> Void) {
        let to = target()
        let run = TreeRun(what: what)
        treeRun = run
        shownPercent = -1
        run.retry = Notice.Action(title: "Try Again") { [weak self, weak view] in self?.sendTree(items, over: view, onSent: onSent) }
        // Out of background time: stop cleanly instead of being killed mid-file.
        run.background = BackgroundTask(name: "Send files") { [weak self] in self?.cancel(run, cutOff: true) }
        let cancel: @MainActor () -> Void = { [weak self] in self?.cancel() }
        self.notice.showProgress(Self.treeProgress(what, to: to, fraction: 0), fraction: 0, cancel: cancel)
        let control = self.control, sessionID = self.sessionID
        Task { @MainActor in
            defer {
                if self.treeRun === run {
                    self.treeRun = nil
                    self.claimed = false
                }
                run.background?.end()
            }
            var dest: String?
            do {
                try await withFsBlock { blockID, open in
                    if run.cancelled { throw FsUploader.Failure.cancelled }
                    let up = FsUploader(control: control, sessionID: sessionID, blockID: blockID, open: open)
                    run.uploader = up
                    dest = try await up.send(plan, to: ServerConnection.treeLanding) { sent, total in
                        guard !run.cancelled else { return }
                        self.treeProgress(what, to: to, sent: sent, total: total, cancel: cancel)
                    }
                }
                // Cancelled while the fs block closed: the server may have put the items in
                // place, but no path is typed and nothing is said.
                if run.cancelled { return Self.ended(run, items) }
                Outgoing.release(items)
                let base = (dest ?? ServerConnection.treeLanding) + "/" + landing + "/"
                var done = SendTarget.done([what], to: to)
                if plan.skipped > 0 { done += plan.skipped == 1 ? ", without 1 link" : ", without \(plan.skipped) links" }
                UIAccessibility.post(notification: .announcement, argument: done)
                onSent(items.map { base + $0.name }, done)
            } catch {
                // The Cancel said so already.
                if run.cancelled { return Self.ended(run, items) }
                self.treeFailed(error, items: items, what: what, to: to, over: view, onSent: onSent)
            }
        }
    }

    /// A cancelled tree send's task is over: what it holds goes, unless Try Again needs it.
    private static func ended(_ run: TreeRun, _ items: [Outgoing]) {
        if !run.cutOff { Outgoing.release(items) }
    }

    nonisolated static func treeProgress(_ what: String, to target: String, fraction: Double) -> String {
        let pct = Int((min(max(fraction, 0), 1) * 100).rounded(.down))
        return "Sending \(what) to \(target) · \(pct)%"
    }

    private func treeProgress(_ what: String, to: String, sent: Int64, total: Int64, cancel: @escaping @MainActor () -> Void) {
        let fraction = total > 0 ? Double(sent) / Double(total) : 1
        let pct = Int(fraction * 100)
        guard pct != shownPercent else { return }
        shownPercent = pct
        self.notice.showProgress(Self.treeProgress(what, to: to, fraction: fraction), fraction: fraction, cancel: cancel)
    }

    private func treeFailed(_ error: Error, items: [Outgoing], what: String, to: String, over view: UIView?,
                            onSent: @escaping @MainActor ([String], String) -> Void) {
        let retry = Notice.Action(title: "Try Again") { [weak self, weak view] in self?.sendTree(items, over: view, onSent: onSent) }
        let computer = Messages.capitalized(self.computer())
        guard let f = error as? FsUploader.Failure else {
            // The fs block couldn't be made: the connection, or a server that changed.
            if (error as? RexError)?.code == "not_found" || (error as? RexError)?.code == "method_not_found" {
                Outgoing.release(items)
                return self.notice.show(Messages.updateRex(self.computer(), to: "send folders"))
            }
            return self.notice.show("Couldn't send \(what). \(Messages.notSent(self.computer()))", action: retry)
        }
        switch f {
        case .cancelled:
            // Only `cancel(run)` cancels an fs upload, and it has said so.
            Outgoing.release(items)
        case .noRoom:
            Outgoing.release(items)
            self.notice.show("\(computer) doesn't have room for \(what).")
        case .unconfirmed:
            Outgoing.release(items)
            self.notice.show("Sent \(what), but \(to) didn't confirm it. \(Messages.sentUnknown)")
        case .changed(let name):
            self.notice.show("Couldn't send \(what): \(name) changed while it was read.", action: retry)
        case .unreadable(let name):
            self.notice.show("Couldn't read \(name) on this \(DeviceWord.current).", action: retry)
        case .refused, .brokeRule:
            self.notice.show("\(computer) refused \(what).", action: retry)
        case .lost:
            self.notice.show("Couldn't send \(what). \(Messages.notSent(self.computer()))", action: retry)
        }
    }

    #if DEBUG
    /// Each file's SHA-256 in the system log (`FILES_SENT`), to check what landed on the computer
    /// against what left: `xcrun simctl spawn <id> log show --last 5m --predicate 'eventMessage CONTAINS "FILES_SENT"'`.
    private static func logDigests(_ files: [StagedFile]) {
        Task.detached(priority: .utility) {
            for f in files {
                guard let data = try? Data(contentsOf: f.url, options: .mappedIfSafe) else { continue }
                let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                NSLog("FILES_SENT %@ %lld %@", f.name, f.size, hex)
            }
        }
    }
    #endif

    private func endBackground() {
        background?.end()
        background = nil
    }
}

/// A yes/no set from any thread: Cancel during a walk off the main actor.
final class CancelFlag: @unchecked Sendable {
    // Safe: the flag is only read and written under the lock.
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
