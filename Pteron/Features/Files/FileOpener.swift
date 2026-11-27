import CryptoKit
import QuickLook
import UIKit
import RexKit

/// Whether selected text names a file, and which. Selection is the gesture: nothing guesses a path
/// under the finger. The text is taken as a terminal shows a path: a shell's backslash escapes
/// (`probe\ three.bin`) and quotes are undone, a compiler's `:line:column` is dropped, and a path
/// the terminal wrapped onto the next row is joined.
enum PathGuess {
    static let maxLength = 1024
    static let maxRows = 4

    /// Whether a selection is small enough to be read as a path: a few rows, about `maxLength`
    /// characters, all in view. Checked from its extent, before its text is extracted.
    static func isSmall(rows: Int, cols: Int, startCol: Int, endCol: Int, clipped: Bool) -> Bool {
        guard !clipped, rows >= 1, rows <= maxRows else { return false }
        let cells = rows == 1 ? endCol - startCol + 1 : (cols - startCol) + (rows - 2) * cols + endCol + 1
        return cells <= maxLength
    }

    static func path(in selection: String) -> String? {
        var s = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.utf8.count <= maxLength else { return nil }
        // A path wrapped over rows: the rows join with nothing between them. Text over several
        // rows with spaces in it is prose, not a path.
        if s.contains("\n") {
            let rows = s.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            guard rows.allSatisfy({ !$0.contains(" ") }) else { return nil }
            s = rows.joined()
        }
        guard !s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return nil }
        // Quotes around it.
        for q in ["'", "\"", "`"] where s.count >= 2 && s.hasPrefix(q) && s.hasSuffix(q) {
            s = String(s.dropFirst().dropLast())
        }
        s = unescaped(s)
        // Trailing punctuation from a sentence, then `:12` or `:12:5`.
        while let last = s.last, ",;)]}>".contains(last) || (last == "." && !s.hasSuffix("..")) || last == ":" {
            s.removeLast()
        }
        s = s.replacingOccurrences(of: #"(:\d+){1,2}$"#, with: "", options: .regularExpression)
        guard !s.isEmpty, !s.contains("://"), !s.hasPrefix("-") else { return nil }
        if s.hasPrefix("/") || s.hasPrefix("~/") || s.hasPrefix("./") || s.hasPrefix("../") { return s }
        if s.contains(" ") { return nil }
        if s.contains("@") && !s.contains("/") { return nil }  // an email address
        if s.contains("/") { return s }
        // A bare name with an extension: README.md, photo.jpg.
        let ext = (s as NSString).pathExtension
        guard !ext.isEmpty, ext.count <= 8, ext.allSatisfy({ $0.isLetter || $0.isNumber }),
              ext.contains(where: \.isLetter), (s as NSString).deletingPathExtension.count >= 1 else { return nil }
        return s
    }

    /// Undoes a shell's backslash escapes: `a\ b` is `a b`.
    static func unescaped(_ s: String) -> String {
        var out = ""
        var escape = false
        for ch in s {
            if escape { out.append(ch); escape = false } else if ch == "\\" { escape = true } else { out.append(ch) }
        }
        if escape { out.append("\\") }
        return out
    }

    /// The failure in plain words.
    static func message(_ f: FileDownloader.Failure, path: String, machine: String) -> String {
        let name = (path as NSString).lastPathComponent.isEmpty ? path : (path as NSString).lastPathComponent
        switch f {
        case .notFound: return "There's no \(name) on \(machine)."
        case .folder: return "\(name) is a folder."
        case .notAFile: return "\(name) isn't a file that can be opened."
        case .noPermission: return "Rex on \(machine) isn't allowed to read \(name)."
        case .tooBig(let size): return "\(name) is too big to open here (\(SendTarget.size(size)); up to \(SendTarget.size(FileOpener.limit)))."
        case .unsupported: return Messages.updateRex(machine, to: "open files")
        case .refused: return "\(Messages.capitalized(machine)) refused \(name)."
        case .saveFailed: return "Couldn't save \(name) on this \(DeviceWord.current). Free up space, then try again."
        case .lost: return "Couldn't open \(name). \(Messages.notSent(machine))"
        case .cancelled: return "Didn't open \(name)."
        }
    }
}

/// Opens a file the terminal names: downloads it from the pane's computer into the app's temporary
/// folder, with progress and Cancel, then shows it in Quick Look, which offers Share and Save to
/// Files. The copy lives only as long as Quick Look shows it: it is deleted when Quick Look goes,
/// and whatever is left when the pane closes. Launch clears the folder too.
///
/// The file browser also sends a file straight to the share sheet or to Save to Files
/// (`export`), by the same download; that copy goes when the sheet or the picker does.
@MainActor
final class FileOpener: NSObject, QLPreviewControllerDataSource, @preconcurrency QLPreviewControllerDelegate,
    UIDocumentPickerDelegate {
    nonisolated static let limit: Int64 = 100_000_000

    /// Where a downloaded file goes.
    enum Destination: Equatable {
        /// Quick Look. `textHint`: a file with no extension that reads as text is shown as text.
        case preview(textHint: Bool)
        case share
        /// Save to Files.
        case files

        /// The notice's verb while it downloads.
        var verb: String {
            switch self {
            case .preview: return "Opening"
            case .share: return "Getting"
            case .files: return "Saving"
            }
        }
    }

    private let control: RexControl
    private let sessionID: String
    private let blockID: String
    private let notice: Notice
    private var downloader: FileDownloader?
    /// The folder download under way (its block may still be being made).
    private var folderRun: FolderRun?
    /// What the last Cancel of a folder download said. The next download takes its place, so its
    /// progress shows at once.
    private var cancelNote: String?
    /// Runs an fs transfer (`FileSender.withFsBlock`). Nil where the pane's computer has none.
    var withFsBlock: ((_ body: @escaping @MainActor (String, @escaping FsOpen) async throws -> Void) async throws -> Void)?
    /// The folder the export picker or the share sheet holds, removed when it is done.
    private var exportingFolder: URL?
    /// The copy Quick Look shows, and the name its title carries.
    private var showing: PreviewFile?
    /// The copy the share sheet or Save to Files holds.
    private var exporting: URL?
    /// The system's Share or Save sheet on its way in. The download's notice stays up until it is
    /// in, so the wait while it loads isn't blank; a Cancel meanwhile takes it back.
    private var arriving: Arriving?

    private final class Arriving {
        let sheet: UIViewController
        let discard: @MainActor () -> Void
        var cancelled = false

        init(sheet: UIViewController, discard: @escaping @MainActor () -> Void) {
            self.sheet = sheet
            self.discard = discard
        }
    }
    /// One folder download. Its Cancel frees the browser at once: the next download can start
    /// while this one's task still ends, as the fs block's close waits for the server, which
    /// answers it only once it has walked the folder. Whatever that task does after the Cancel
    /// shows nothing and hands nothing on.
    private final class FolderRun {
        let name: String
        var downloader: FsDownloader?
        var cancelled = false

        init(name: String) { self.name = name }
    }
    /// The path named a folder. True when the folder was shown instead (the file browser).
    var onFolder: ((String) -> Bool)?

    init(control: RexControl, sessionID: String, blockID: String, notice: Notice = .shared) {
        self.control = control
        self.sessionID = sessionID
        self.blockID = blockID
        self.notice = notice
    }

    /// A download's notice: "Saving name · 23%", in whole percents rounded down, so 100% shows
    /// only once all of it is here. No size yet reads 0%.
    nonisolated static func progress(_ verb: String, _ name: String, got: Int64, size: Int64) -> (text: String, fraction: Double) {
        let f = size > 0 ? min(max(Double(got) / Double(size), 0), 1) : 0
        return ("\(verb) \(name) · \(Int(f * 100))%", f)
    }

    func cancel() {
        downloader?.cancel()
        if let run = folderRun { cancel(run) }
        arriving?.cancelled = true
    }

    /// Ends a folder download for the browser now: it says so at once, and the next download can
    /// start. A run that is no longer the one under way is left alone.
    private func cancel(_ run: FolderRun) {
        guard folderRun === run else { return }
        folderRun = nil
        run.cancelled = true
        run.downloader?.cancel()
        let note = "Didn't save \(run.name)."
        cancelNote = note
        notice.show(note, style: .neutral)
    }

    /// A new download starts: the note of the last one's Cancel makes way for its progress.
    private func clearCancelNote() {
        if let note = cancelNote { notice.withdraw(note) }
        cancelNote = nil
    }

    /// Presents the system's Share or Save sheet over `top`. The progress that says `progress`
    /// stays until the sheet is in, then goes. A Cancel while it comes in takes it back and
    /// `discard`s the copy.
    private func present(_ sheet: UIViewController, over top: UIViewController, progress: String,
                         discard: @escaping @MainActor () -> Void) {
        let a = Arriving(sheet: sheet, discard: discard)
        arriving = a
        let notice = self.notice
        top.present(sheet, animated: true) { [weak self] in
            if self?.arriving === a { self?.arriving = nil }
            if a.cancelled {
                sheet.dismiss(animated: true)
                a.discard()
            } else {
                notice.dismissProgress(progress)
            }
        }
        // The Save sheet loads out of process, so it may take a while to come in. One that never
        // came (UIKit refused it) leaves no notice up.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.arriving === a, sheet.presentingViewController == nil else { return }
            self.arriving = nil
            notice.dismissProgress(progress)
            a.discard()
        }
    }

    /// The pane closed: stop a download and delete the copy, unless Quick Look still shows it (it
    /// goes when Quick Look does).
    func close() {
        cancel()
    }

    func open(_ path: String, machine: String, over view: UIView?, textHint: Bool = false) {
        fetch(path, machine: machine, to: .preview(textHint: textHint), over: view)
    }

    /// Downloads `path` and hands it to the share sheet or to Save to Files, under its own name.
    func export(_ path: String, machine: String, to destination: Destination, over view: UIView?) {
        fetch(path, machine: machine, to: destination, over: view)
    }

    private func fetch(_ path: String, machine: String, to destination: Destination, over view: UIView?) {
        guard downloader == nil, folderRun == nil else { return notice.show("Wait for the file on its way to finish.") }
        clearCancelNote()
        let notice = self.notice
        let d = FileDownloader(control: control, sessionID: sessionID, blockID: blockID)
        downloader = d
        let name = (path as NSString).lastPathComponent
        let cancel: @MainActor () -> Void = { [weak self] in self?.cancel() }
        Task { @MainActor in
            let file = Incoming(name: name)
            do {
                let outcome = try await d.download(path: path, limit: Self.limit, write: { data in
                    try file.write(data)
                }, progress: { got, size in
                    let p = Self.progress(destination.verb, name, got: got, size: size)
                    notice.showProgress(p.text, fraction: p.fraction, cancel: cancel)
                })
                self.downloader = nil
                file.close()
                guard case .downloaded(let info) = outcome else { return }
                let url = try file.url ?? Self.empty(named: info.name)
                switch destination {
                case .preview(let hint):
                    notice.dismiss()
                    await self.show(url, textHint: hint, over: view)
                case .share, .files:
                    // The notice stays, at 100%, until the system's sheet is in.
                    let done = Self.progress(destination.verb, name, got: 1, size: 1)
                    notice.showProgress(done.text, fraction: done.fraction, cancel: cancel)
                    self.hand(url, to: destination, over: view, progress: done.text)
                }
            } catch {
                self.downloader = nil
                file.close()
                if let url = file.url { Self.delete(url) }
                let f = error as? FileDownloader.Failure ?? .lost(error.localizedDescription)
                // A folder is something to browse, where the pane's computer lists folders.
                if f == .folder, destination == .preview(textHint: false), self.onFolder?(path) == true { return }
                let retry = Notice.Action(title: "Try Again") { self.fetch(path, machine: machine, to: destination, over: view) }
                switch f {
                case .cancelled: notice.show(PathGuess.message(f, path: path, machine: machine), style: .neutral)
                case .lost: notice.show(PathGuess.message(f, path: path, machine: machine), action: retry)
                default: notice.show(PathGuess.message(f, path: path, machine: machine))
                }
            }
        }
    }

    // MARK: Folders

    /// Downloads the folder at `path` through an fs block, writing it into the app's temporary
    /// folder as it arrives, then hands it to Save to Files (moved, not copied, so a large
    /// folder needs its room once) or the share sheet. A download that fails leaves nothing.
    func exportFolder(_ path: String, machine: String, to destination: Destination, over view: UIView?) {
        guard downloader == nil, folderRun == nil else { return notice.show("Wait for the file on its way to finish.") }
        guard let withFsBlock else { return notice.show(Messages.updateRex(machine, to: "save folders")) }
        let name = (path as NSString).lastPathComponent
        let run = FolderRun(name: name)
        folderRun = run
        clearCancelNote()
        let notice = self.notice
        let cancel: @MainActor () -> Void = { [weak self] in self?.cancel() }
        let start = Self.progress(destination.verb, name, got: 0, size: 0)
        notice.showProgress(start.text, fraction: start.fraction, cancel: cancel)
        let control = self.control, sessionID = self.sessionID
        let background = BackgroundTask(name: "Save folder") { [weak self] in self?.cancel(run) }
        Task { @MainActor in
            defer {
                if self.folderRun === run { self.folderRun = nil }
                background.end()
            }
            var staging: URL?
            do {
                let root = try FileStaging.folder(in: FileStaging.incoming)
                staging = root
                var result: FsDownloader.Result?
                // Progress hops to the main actor on its own; once the download is over or
                // cancelled, a late one must not put the notice back.
                let over = OverFlag()
                defer { over.set = true }
                try await withFsBlock { blockID, open in
                    if run.cancelled { throw FsDownloader.Failure.cancelled }
                    let d = FsDownloader(control: control, sessionID: sessionID, blockID: blockID, open: open)
                    run.downloader = d
                    result = try await d.download([path], into: root, hasRoom: { Self.hasRoom(for: $0) }) { got, size in
                        guard !over.set, !run.cancelled else { return }
                        let p = Self.progress(destination.verb, name, got: got, size: size)
                        notice.showProgress(p.text, fraction: p.fraction, cancel: cancel)
                    }
                }
                over.set = true
                // Cancelled while the fs block closed: the copy goes, and no sheet comes.
                if run.cancelled { return FileStaging.remove(root) }
                guard let result, let top = result.tops.first else { throw FsDownloader.Failure.lost("nothing arrived") }
                #if DEBUG
                // `FILES_FOLDER <copy>`: where the folder is until it is saved, to check it against the computer's.
                NSLog("FILES_FOLDER %@ entries=%ld skipped=%ld", root.appendingPathComponent(top).path, result.info.entries, result.skipped)
                #endif
                // The notice stays, at 100%, until the system's sheet is in; a note about links
                // left out takes its place.
                let done = Self.progress(destination.verb, name, got: 1, size: 1)
                notice.showProgress(done.text, fraction: done.fraction, cancel: cancel)
                if result.skipped > 0 {
                    let n = result.skipped
                    notice.show(n == 1 ? "\(name) came without its 1 link." : "\(name) came without its \(n) links.", style: .neutral)
                }
                self.folderRun = nil
                self.handFolder(root.appendingPathComponent(top, isDirectory: true), staging: root, to: destination, over: view,
                                progress: done.text)
            } catch {
                if let staging { FileStaging.remove(staging) }
                // The Cancel said so already.
                if run.cancelled { return }
                let retry = Notice.Action(title: "Try Again") { self.exportFolder(path, machine: machine, to: destination, over: view) }
                switch error as? FsDownloader.Failure {
                case .cancelled?: notice.show("Didn't save \(name).", style: .neutral)
                case .notFound?: notice.show("There's no \(name) on \(machine).")
                case .noPermission?: notice.show("Rex on \(machine) isn't allowed to read \(name).")
                case .noRoom(let size)?:
                    notice.show("This \(DeviceWord.current) doesn't have room for \(name) (\(SendTarget.size(size))).")
                case .unsafe?: notice.show("Couldn't save \(name): it holds a name that isn't safe to save.")
                case .saveFailed?: notice.show("Couldn't save \(name) on this \(DeviceWord.current). Free up space, then try again.")
                case .refused?: notice.show("\(Messages.capitalized(machine)) refused \(name).", action: retry)
                case .lost?, nil:
                    if (error as? RexError)?.code == "not_found" || (error as? RexError)?.code == "method_not_found" {
                        return notice.show(Messages.updateRex(machine, to: "save folders"))
                    }
                    notice.show("Couldn't save \(name). \(Messages.notSent(machine))", action: retry)
                }
            }
        }
    }

    /// Room for `size` bytes, and 200 MB to spare, in the app's temporary folder.
    nonisolated static func hasRoom(for size: Int64) -> Bool {
        let values = try? FileManager.default.temporaryDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let free = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return free >= size + 200_000_000
    }

    private func handFolder(_ folder: URL, staging: URL, to destination: Destination, over view: UIView?, progress: String) {
        guard let top = Self.top(over: view) else {
            notice.dismissProgress(progress)
            return FileStaging.remove(staging)
        }
        if let old = exportingFolder { FileStaging.remove(old) }
        exportingFolder = staging
        if destination == .share {
            let sheet = UIActivityViewController(activityItems: [folder], applicationActivities: nil)
            sheet.completionWithItemsHandler = { [weak self] _, _, _, _ in
                Task { @MainActor in self?.folderExported(staging) }
            }
            sheet.popoverPresentationController?.sourceView = top.view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            sheet.popoverPresentationController?.permittedArrowDirections = []
            present(sheet, over: top, progress: progress) { [weak self] in self?.folderExported(staging) }
        } else {
            let picker = UIDocumentPickerViewController(forExporting: [folder], asCopy: false)
            picker.delegate = self
            present(picker, over: top, progress: progress) { [weak self] in self?.folderExported(staging) }
        }
    }

    private func folderExported(_ staging: URL) {
        FileStaging.remove(staging)
        if exportingFolder == staging { exportingFolder = nil }
    }

    /// An empty file arrives with no bytes, so nothing was written for it.
    private static func empty(named name: String) throws -> URL {
        let url = try FileStaging.folder(in: FileStaging.incoming).appendingPathComponent(UploadName.sanitize(name))
        FileManager.default.createFile(atPath: url.path, contents: Data())
        return url
    }

    /// Deletes a copy with its folder.
    private static func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    private static func top(over view: UIView?) -> UIViewController? {
        guard var top = view?.window?.rootViewController else { return nil }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        return top
    }

    private func show(_ url: URL, textHint: Bool, over view: UIView?) async {
        #if DEBUG
        // `FILES_OPENED <name> <bytes> <sha256>` in the system log, to check against the computer's copy.
        if let data = try? Data(contentsOf: url) {
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            NSLog("FILES_OPENED %@ %ld %@", url.lastPathComponent, data.count, hex)
        }
        #endif
        // A name without an extension gives Quick Look nothing to go by: text is shown as text,
        // from a copy named `.txt`, under the file's own name.
        var shown = url
        if textHint, let hinted = await Task.detached(operation: { TextHint.renamed(url) }).value { shown = hinted }
        guard let top = Self.top(over: view) else { return Self.delete(shown) }
        if let old = showing { Self.delete(old.url) }
        showing = PreviewFile(url: shown, title: url.lastPathComponent)
        let preview = QLPreviewController()
        preview.dataSource = self
        preview.delegate = self
        top.present(preview, animated: true)
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
        showing ?? PreviewFile(url: URL(fileURLWithPath: "/dev/null"), title: "")
    }

    /// Quick Look went (after a Share or a Save to Files, if any): the copy goes too.
    func previewControllerDidDismiss(_ controller: QLPreviewController) {
        if let old = showing { Self.delete(old.url) }
        showing = nil
    }

    // MARK: Share and Save to Files

    private func hand(_ url: URL, to destination: Destination, over view: UIView?, progress: String) {
        guard let top = Self.top(over: view) else {
            notice.dismissProgress(progress)
            return Self.delete(url)
        }
        if let old = exporting { Self.delete(old) }
        exporting = url
        if destination == .share {
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            sheet.completionWithItemsHandler = { [weak self] _, _, _, _ in
                Task { @MainActor in self?.exported(url) }
            }
            // On a wide window the sheet is a popover: it points at the middle of what it is over.
            sheet.popoverPresentationController?.sourceView = top.view
            sheet.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 1, height: 1)
            sheet.popoverPresentationController?.permittedArrowDirections = []
            present(sheet, over: top, progress: progress) { [weak self] in self?.exported(url) }
        } else {
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            picker.delegate = self
            present(picker, over: top, progress: progress) { [weak self] in self?.exported(url) }
        }
    }

    private func exported(_ url: URL) {
        Self.delete(url)
        if exporting == url { exporting = nil }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = exporting { exported(url) }
        if let f = exportingFolder { folderExported(f) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if let url = exporting { exported(url) }
        if let f = exportingFolder { folderExported(f) }
    }
}

/// What Quick Look shows: the copy, under the file's own name.
private final class PreviewFile: NSObject, QLPreviewItem {
    let url: URL
    let title: String

    init(url: URL, title: String) {
        self.url = url
        self.title = title
    }

    var previewItemURL: URL? { url }
    var previewItemTitle: String? { title }
}

/// A download's file, made at its first bytes. Written only on the download's writer queue, one
/// write at a time; `url` is read after the download finished, which waits for that queue.
private final class Incoming: @unchecked Sendable {
    let name: String
    private(set) var url: URL?
    private var handle: FileHandle?

    init(name: String) { self.name = name }

    func write(_ data: Data) throws {
        if handle == nil {
            let url = try FileStaging.folder(in: FileStaging.incoming).appendingPathComponent(UploadName.sanitize(name))
            FileManager.default.createFile(atPath: url.path, contents: nil)
            self.url = url
            handle = try FileHandle(forWritingTo: url)
        }
        try handle?.write(contentsOf: data)
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}

/// Set once a folder download is over, read by its late progress.
@MainActor
private final class OverFlag {
    var set = false
}
