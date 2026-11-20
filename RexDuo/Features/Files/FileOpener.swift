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
        case .unsupported: return "This computer's Rex can't send files. Update Rex there."
        case .refused(let m): return "Couldn't open \(name): \(m)"
        case .lost: return "Couldn't open \(name): the connection was lost."
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
    private var downloader: FileDownloader?
    /// The copy Quick Look shows, and the name its title carries.
    private var showing: PreviewFile?
    /// The copy the share sheet or Save to Files holds.
    private var exporting: URL?
    /// The path named a folder. True when the folder was shown instead (the file browser).
    var onFolder: ((String) -> Bool)?

    init(control: RexControl, sessionID: String, blockID: String) {
        self.control = control
        self.sessionID = sessionID
        self.blockID = blockID
    }

    func cancel() { downloader?.cancel() }

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
        guard downloader == nil else { return Notice.shared.show("Wait for the file on its way to finish.") }
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
                    let f = size > 0 ? min(Double(got) / Double(size), 1) : 0
                    Notice.shared.showProgress("\(destination.verb) \(name) · \(Int(f * 100))%", fraction: f, cancel: cancel)
                })
                self.downloader = nil
                file.close()
                guard case .downloaded(let info) = outcome else { return }
                let url = try file.url ?? Self.empty(named: info.name)
                Notice.shared.dismiss()
                switch destination {
                case .preview(let hint): await self.show(url, textHint: hint, over: view)
                case .share, .files: self.hand(url, to: destination, over: view)
                }
            } catch {
                self.downloader = nil
                file.close()
                if let url = file.url { Self.delete(url) }
                let f = error as? FileDownloader.Failure ?? .lost(error.localizedDescription)
                // A folder is something to browse, where the pane's computer lists folders.
                if f == .folder, destination == .preview(textHint: false), self.onFolder?(path) == true { return }
                let retry = Notice.Action(title: "Retry") { self.fetch(path, machine: machine, to: destination, over: view) }
                switch f {
                case .cancelled: Notice.shared.show(PathGuess.message(f, path: path, machine: machine), style: .neutral)
                case .lost: Notice.shared.show(PathGuess.message(f, path: path, machine: machine), action: retry)
                default: Notice.shared.show(PathGuess.message(f, path: path, machine: machine))
                }
            }
        }
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

    private func hand(_ url: URL, to destination: Destination, over view: UIView?) {
        guard let top = Self.top(over: view) else { return Self.delete(url) }
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
            top.present(sheet, animated: true)
        } else {
            let picker = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            picker.delegate = self
            top.present(picker, animated: true)
        }
    }

    private func exported(_ url: URL) {
        Self.delete(url)
        if exporting == url { exporting = nil }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if let url = exporting { exported(url) }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if let url = exporting { exported(url) }
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
