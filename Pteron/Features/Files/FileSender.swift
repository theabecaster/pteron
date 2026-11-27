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
    private var uploader: FileUploader?
    private var treeUploader: FsUploader?
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

    var busy: Bool { claimed || uploader != nil || treeUploader != nil }

    init(control: RexControl, sessionID: String, blockID: String) {
        self.control = control
        self.sessionID = sessionID
        self.blockID = blockID
    }

    /// Sends `files` as one batch. Above `SendTarget.expensiveLimit` on an expensive network it asks
    /// first, over `view`. The copies are removed when the send ends, except after a failure that
    /// offers Retry.
    func send(_ files: [StagedFile], over view: UIView?) {
        guard !files.isEmpty else { return }
        guard !busy else {
            FileStaging.discard(files)
            Notice.shared.show("Wait for the files on their way to finish.")
            return
        }
        if let big = files.first(where: { $0.size > FileUploader.maxFileSize }) {
            FileStaging.discard(files)
            Notice.shared.show(SendTarget.tooLarge(big.name))
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
        treeUploader?.cancel()
        planCancelled?.set()
        if claimed, treeUploader == nil { treeCancelPending = true }
    }

    /// Cancel came while a tree's fs block was being made, before its uploader existed.
    private var treeCancelPending = false

    private func start(_ files: [StagedFile], over view: UIView?) {
        guard uploader == nil else { return FileStaging.discard(files) }
        let names = files.map(\.name)
        let to = target()
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
        Notice.shared.showProgress(SendTarget.progress(names, to: to, fraction: 0), fraction: 0, cancel: cancel)
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
                Notice.shared.show(SendTarget.done(names, to: to), style: .neutral)
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
        Notice.shared.showProgress(SendTarget.progress(names, to: to, fraction: fraction), fraction: fraction, cancel: cancel)
    }

    private func failed(_ f: FileUploader.Failure, files: [StagedFile], to: String, over view: UIView?) {
        let what = SendTarget.what(files.map(\.name))
        let retry = Notice.Action(title: "Try Again") { [weak self, weak view] in self?.send(files, over: view) }
        switch f {
        case .cancelled where cutOff:
            Notice.shared.show("Sending \(what) stopped in the background.", action: retry)
        case .cancelled:
            FileStaging.discard(files)
            Notice.shared.show("Didn't send \(what).", style: .neutral)
        case .unsupported:
            FileStaging.discard(files)
            Notice.shared.show(Messages.updateRex(computer(), to: "send files"))
        case .unconfirmed:
            FileStaging.discard(files)
            Notice.shared.show("Sent \(what), but \(to) didn't confirm it. \(Messages.sentUnknown)")
        case .tooLarge:
            FileStaging.discard(files)
            Notice.shared.show(SendTarget.tooLarge(what))
        case .brokeRule:
            Notice.shared.show("Couldn't send \(what): it changed while it was read.", action: retry)
        case .refused:
            Notice.shared.show("\(Messages.capitalized(computer())) refused \(what).", action: retry)
        case .unreadable(let name):
            Notice.shared.show("Couldn't read \(name) on this \(DeviceWord.current).", action: retry)
        case .lost:
            Notice.shared.show("Couldn't send \(what). \(Messages.notSent(computer()))", action: retry)
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
            if busy { Notice.shared.show("Wait for the files on their way to finish.") }
            return
        }
        claimed = true
        let names = items.map(\.name)
        let folders = items.contains(where: \.isFolder)
        let what = SendTarget.what(names, folders: folders)
        let landing = Self.landingName()
        let flag = CancelFlag()
        planCancelled = flag
        Notice.shared.showProgress("Preparing \(what)…", fraction: 0) { flag.set() }
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
                    Notice.shared.show("Didn't send \(what).", style: .neutral)
                case .unreadable(let name)?:
                    let retry = Notice.Action(title: "Try Again") { [weak self, weak view] in
                        self?.sendTree(items, over: view, onSent: onSent)
                    }
                    Notice.shared.show("Couldn't read \(name) on this \(DeviceWord.current).", action: retry)
                default:
                    Outgoing.release(items)
                    Notice.shared.show("Nothing in \(what) can be sent.")
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
                        Notice.shared.dismiss()
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
        cutOff = false
        treeCancelPending = false
        shownPercent = -1
        background = BackgroundTask(name: "Send files") { [weak self] in
            guard let self else { return }
            self.cutOff = true
            self.cancel()
        }
        let cancel: @MainActor () -> Void = { [weak self] in self?.cancel() }
        Notice.shared.showProgress(Self.treeProgress(what, to: to, fraction: 0), fraction: 0, cancel: cancel)
        let control = self.control, sessionID = self.sessionID
        Task { @MainActor in
            defer {
                self.treeUploader = nil
                self.claimed = false
                self.endBackground()
            }
            var dest: String?
            do {
                try await withFsBlock { blockID, open in
                    let up = FsUploader(control: control, sessionID: sessionID, blockID: blockID, open: open)
                    self.treeUploader = up
                    if self.cutOff || self.treeCancelPending { up.cancel() }
                    dest = try await up.send(plan, to: ServerConnection.treeLanding) { sent, total in
                        self.treeProgress(what, to: to, sent: sent, total: total, cancel: cancel)
                    }
                }
                Outgoing.release(items)
                let base = (dest ?? ServerConnection.treeLanding) + "/" + landing + "/"
                var done = SendTarget.done([what], to: to)
                if plan.skipped > 0 { done += plan.skipped == 1 ? ", without 1 link" : ", without \(plan.skipped) links" }
                UIAccessibility.post(notification: .announcement, argument: done)
                onSent(items.map { base + $0.name }, done)
            } catch {
                self.treeFailed(error, items: items, what: what, to: to, over: view, onSent: onSent)
            }
        }
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
        Notice.shared.showProgress(Self.treeProgress(what, to: to, fraction: fraction), fraction: fraction, cancel: cancel)
    }

    private func treeFailed(_ error: Error, items: [Outgoing], what: String, to: String, over view: UIView?,
                            onSent: @escaping @MainActor ([String], String) -> Void) {
        let retry = Notice.Action(title: "Try Again") { [weak self, weak view] in self?.sendTree(items, over: view, onSent: onSent) }
        let computer = Messages.capitalized(self.computer())
        guard let f = error as? FsUploader.Failure else {
            // The fs block couldn't be made: the connection, or a server that changed.
            if (error as? RexError)?.code == "not_found" || (error as? RexError)?.code == "method_not_found" {
                Outgoing.release(items)
                return Notice.shared.show(Messages.updateRex(self.computer(), to: "send folders"))
            }
            return Notice.shared.show("Couldn't send \(what). \(Messages.notSent(self.computer()))", action: retry)
        }
        switch f {
        case .cancelled where cutOff:
            Notice.shared.show("Sending \(what) stopped in the background.", action: retry)
        case .cancelled:
            Outgoing.release(items)
            Notice.shared.show("Didn't send \(what).", style: .neutral)
        case .noRoom:
            Outgoing.release(items)
            Notice.shared.show("\(computer) doesn't have room for \(what).")
        case .unconfirmed:
            Outgoing.release(items)
            Notice.shared.show("Sent \(what), but \(to) didn't confirm it. \(Messages.sentUnknown)")
        case .changed(let name):
            Notice.shared.show("Couldn't send \(what): \(name) changed while it was read.", action: retry)
        case .unreadable(let name):
            Notice.shared.show("Couldn't read \(name) on this \(DeviceWord.current).", action: retry)
        case .refused, .brokeRule:
            Notice.shared.show("\(computer) refused \(what).", action: retry)
        case .lost:
            Notice.shared.show("Couldn't send \(what). \(Messages.notSent(self.computer()))", action: retry)
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
