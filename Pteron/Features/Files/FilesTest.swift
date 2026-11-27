#if DEBUG
import UIKit
import UniformTypeIdentifiers
import RexKit

/// `-filesTest '<step>;<step>…'` (Debug builds, testing): drives file sending in the active pane
/// once it is live, where the simulator can't tap through a picker. Steps run a second apart:
///
/// - `keyboard`: show the software keyboard and its key bar, even with a hardware keyboard.
/// - `menu`: open the attach menu. `reveal`: scroll the key bar to the attach key.
/// - `send:<path>|<path>`: send these files (paths on the Mac running the simulator) as one batch,
///   prepared as Photos prepares them. `sendAsIs:` sends them untouched, as Files does.
/// - `sendTree:<path>|<path>`: send these files and folders where they are, as the Files picker
///   gives them where the computer takes folders (`SendRoute`: several items or a folder go as one
///   archive through an fs block).
/// - `paste:<path>`: put this image on the clipboard alone, then Paste.
/// - `open:<text>`: open what `<text>` names, as the edit menu's Open does for a selection.
/// - `cancel`: cancel the send on its way, as the notice's Cancel does.
/// - `browse`, `insert`: open the file browser in that mode, in the folder the pane's program is in;
///   `browseAt:<path>` opens it at a folder. With the browser up: `go:<path>` opens a folder by
///   path, `enter:<name>` a folder of the one on screen, `up` its parent, `filter:<text>` types in
///   the filter, `hidden` shows hidden files, `tap:<name>` taps a row (preview, or insert in
///   insert mode), `insertPath:<name>` is the row menu's Insert Path, `insertHere` the bottom
///   button, `share:<name>` and `save:<name>` the row menu's Share… and Save to Files…,
///   `shareFolder:<name>` and `saveFolder:<name>` the same on a folder,
///   `select:<n>` moves the keyboard's row down n times, `refresh` lists again, `done` closes.
/// - `lose:<method>`: record that the pane's host lacks `upload_begin`, `download_begin` or
///   `list_dir`, as a call's `method_not_found` does, to see what a server without it shows.
/// - `run:<command>`: a keymap action as a bound key runs it (`pane.insert_path`,
///   `pane.go_to_directory`, `pane.insert_file`, `pane.insert_photo`).
/// - `wait:<seconds>`: pause.
///
/// Use only with a throwaway `zz-` session: the files land on its computer and their paths are typed.
@MainActor
enum FilesTest {
    private static var ran = false

    static func run(on host: TerminalHost) {
        guard !ran, let script = UserDefaults.standard.string(forKey: "filesTest") else { return }
        ran = true
        let steps = script.split(separator: ";").map(String.init)
        Task { @MainActor [weak host] in
            try? await Task.sleep(for: .seconds(2))
            for step in steps {
                guard let host else { return }
                await perform(step, on: host)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func perform(_ step: String, on host: TerminalHost) async {
        let (verb, arg) = step.firstIndex(of: ":").map { (String(step[..<$0]), String(step[step.index(after: $0)...])) } ?? (step, "")
        NSLog("FILES_TEST %@", step)
        switch verb {
        case "keyboard":
            host.hardwareKeyboard = { false }
            host.focusKeyboard()
        case "menu", "reveal":
            host.openAttachMenu(open: verb == "menu")
        case "send", "sendAsIs":
            let asIs = verb == "sendAsIs"
            let files = arg.split(separator: "|").compactMap { path -> ImagePrep.Result? in
                let url = URL(fileURLWithPath: String(path))
                guard let f = try? FileStaging.stage(copying: url, as: url.lastPathComponent) else { return nil }
                return asIs ? .ready(f) : ImagePrep.prepare(f)
            }
            host.files?.send(files)
        case "sendTree":
            let items = arg.split(separator: "|").map { path -> Outgoing in
                let url = URL(fileURLWithPath: String(path))
                let folder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                return Outgoing(url: url, name: url.lastPathComponent, isFolder: folder, owned: false, scoped: false)
            }
            host.files?.send(items, staged: [])
        case "paste":
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: arg)) else { return }
            let type = UTType(filenameExtension: (arg as NSString).pathExtension) ?? .png
            UIPasteboard.general.items = [[type.identifier: data]]
            host.pasteFromClipboard()
        case "open":
            host.files?.open(selection: arg)
        case "cancel":
            host.files?.cancel()
        case "browse", "insert":
            host.files?.browse(verb == "insert" ? .insert : .browse)
        case "browseAt":
            host.files?.browse(.browse, at: arg)
        case "lose":
            guard let files = host.files, let method = FileMethod(rawValue: arg) else { return }
            let block = files.server.views[files.sessionID]?.windowContaining(block: files.blockID)?.block(files.blockID)
            files.server.capabilities.record(method: method.full, host: block?.hostID, .absent, serial: files.server.connectionSerial)
        case "run":
            if let c = FilesCommand.forAction(arg) { host.files?.run(c) }
        case "go", "enter", "up", "filter", "hidden", "tap", "insertPath", "insertHere", "share", "save", "shareFolder", "saveFolder",
             "select", "refresh", "done":
            guard let b = host.files?.browserModel else { return NSLog("FILES_TEST no browser for %@", step) }
            let folder = b.current
            let entry = folder.rows.first { $0.name == arg }
            switch verb {
            case "go": b.go(to: arg)
            case "enter": if let entry { b.open(entry, in: folder) }
            case "up": b.goUp()
            case "filter": folder.query = arg
            case "hidden": b.showHidden.toggle()
            case "tap": if let entry { b.activate(entry, in: folder) }
            case "insertPath": if let entry { b.onInsert(b.path(of: entry, in: folder)) }
            case "insertHere": b.onInsert(folder.path)
            case "share": if let entry { b.onShare(b.path(of: entry, in: folder)) }
            case "save": if let entry { b.onSave(b.path(of: entry, in: folder)) }
            case "shareFolder": if let entry { b.onShareFolder(b.path(of: entry, in: folder)) }
            case "saveFolder": if let entry { b.onSaveFolder(b.path(of: entry, in: folder)) }
            case "select": for _ in 0..<(Int(arg) ?? 1) { folder.move(1) }
            case "refresh": await b.refresh()
            default: b.onClose()
            }
            NSLog("FILES_TEST browser %@ rows=%ld phase=%@", folder.path, folder.rows.count, String(describing: folder.phase))
        case "wait":
            try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
        default:
            NSLog("FILES_TEST unknown step %@", step)
        }
    }
}

/// `-filesListDelay <seconds>` (Debug builds, testing): every folder listing of the file browser
/// waits this long first, to see the browser while it loads.
@MainActor
final class DelayedFolders: DirSource {
    private let source: any DirSource
    private let delay: Double

    init(_ source: any DirSource, delay: Double) {
        self.source = source
        self.delay = delay
    }

    /// `source`, or `source` behind the delay the launch argument asks for.
    static func wrap(_ source: any DirSource) -> any DirSource {
        let delay = UserDefaults.standard.double(forKey: "filesListDelay")
        return delay > 0 ? DelayedFolders(source, delay: delay) : source
    }

    func list(path: String, prefix: String, limit: Int) async throws -> DirPage {
        try? await Task.sleep(for: .seconds(delay))
        return try await source.list(path: path, prefix: prefix, limit: limit)
    }
}
#endif
