import CryptoKit
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
    private var background: BackgroundTask?
    private var cutOff = false
    private var shownPercent = -1

    /// From the moment a send is asked for (its cellular question included) until it ends, so a
    /// second one is turned away with a word instead of lost.
    private var claimed = false

    var busy: Bool { claimed || uploader != nil }

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

    func cancel() { uploader?.cancel() }

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
            Notice.shared.show("Couldn't read \(name) on this iPhone.", action: retry)
        case .lost:
            Notice.shared.show("Couldn't send \(what). \(Messages.notSent(computer()))", action: retry)
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
