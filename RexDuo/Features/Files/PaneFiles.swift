import UIKit
import UniformTypeIdentifiers
import RexKit

/// Files for one pane: the attach menu, Paste of an image or a file, and the send. Everything sent
/// lands on the pane's computer and its path is typed into the pane, so every send starts from an
/// explicit action and the menu says where it goes.
@MainActor
final class PaneFiles {
    let server: ServerConnection
    let sessionID: String
    let blockID: String
    /// The pane's view: pickers and questions show over it.
    weak var view: UIView?
    /// Called when it is known whether the server takes files.
    var onSupportChanged: (() -> Void)?

    private let sender: FileSender
    private let opener: FileOpener
    private let picker = AttachPicker()
    private var drop: PaneDrop?
    private var probing = false

    init(server: ServerConnection, sessionID: String, blockID: String) {
        self.server = server
        self.sessionID = sessionID
        self.blockID = blockID
        sender = FileSender(control: server.control, sessionID: sessionID, blockID: blockID)
        opener = FileOpener(control: server.control, sessionID: sessionID, blockID: blockID)
        sender.target = { [weak self] in self?.target ?? "this computer" }
        picker.onPicked = { [weak self] files in self?.send(files) }
        picker.prepare = { ImagePrep.prepare($0, original: $1) }
    }

    // MARK: Support

    /// Whether the server takes files, for this connection; nil until asked (`checkSupport`).
    var supported: Bool? {
        guard let s = server.fileSupport, s.serial == server.connectionSerial else { return nil }
        return s.supported
    }

    /// Asks the server once per connection. An answer that couldn't be had is asked again later.
    func checkSupport() {
        guard supported == nil, !probing, server.phase == .online else { return }
        probing = true
        let serial = server.connectionSerial
        Task { @MainActor in
            defer { self.probing = false }
            guard let ok = await FileUploader.probeSupport(control: self.server.control, sessionID: self.sessionID,
                                                           blockID: self.blockID) else { return }
            guard serial == self.server.connectionSerial else { return }
            self.server.fileSupport = (serial, ok)
            self.onSupportChanged?()
        }
    }

    // MARK: Destination

    /// The agent working in the pane, else the pane's computer.
    var target: String {
        SendTarget.name(agent: server.meta[blockID]?.agentKind, machine: machine)
    }

    private var machineName: String { machine ?? "this computer" }

    private var machine: String? {
        let block = server.views[sessionID]?.windowContaining(block: blockID)?.block(blockID)
        if let host = block?.hostID, let label = server.hosts.first(where: { $0.id == host })?.label { return label }
        return server.config.name
    }

    // MARK: Menu

    /// The attach menu, built when it opens so its title and Paste Image are current.
    func menu() -> UIMenu {
        let board = UIPasteboard.general
        var items: [UIMenuElement] = []
        if ClipboardChoice.offersPasteImage(hasImage: board.hasImages || Self.hasFiles(board), canSend: true) {
            let title = Self.hasFiles(board) ? "Paste File" : "Paste Image"
            items.append(UIAction(title: title, image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.pasteFiles()
            })
        }
        items.append(UIAction(title: "Photos", subtitle: "Without location. Videos are sent as they are.",
                              image: UIImage(systemName: "photo")) { [weak self] _ in
            guard let self, let view = self.view else { return }
            self.picker.pickPhotos(over: view, original: self.sendOriginals)
        })
        if AttachPicker.cameraAvailable {
            items.append(UIAction(title: "Camera", image: UIImage(systemName: "camera")) { [weak self] _ in
                guard let self, let view = self.view else { return }
                self.picker.takePhoto(over: view, original: self.sendOriginals)
            })
        }
        items.append(UIAction(title: "Files", image: UIImage(systemName: "folder")) { [weak self] _ in
            guard let self, let view = self.view else { return }
            self.picker.pickFiles(over: view)
        })
        let original = UIAction(title: "Send Original", subtitle: "Photos as they are, with their location",
                                image: UIImage(systemName: "photo.badge.checkmark"),
                                state: sendOriginals ? .on : .off) { [weak self] _ in
            self?.sendOriginals.toggle()
        }
        let main = UIMenu(title: SendTarget.menuTitle(target), options: .displayInline, children: items)
        return UIMenu(children: [main, UIMenu(options: .displayInline, children: [original])])
    }

    /// "Send Original": photos go untouched. Lasts until the app quits, like a picker's own choice.
    private var sendOriginals: Bool {
        get { Prefs.shared.sendOriginalPhotos }
        set { Prefs.shared.sendOriginalPhotos = newValue }
    }

    // MARK: Paste

    /// What Paste does now. Text always pastes as text; only a clipboard without text sends.
    var pasteChoice: ClipboardChoice {
        let b = UIPasteboard.general
        return ClipboardChoice.paste(hasText: b.hasStrings, hasImage: b.hasImages, hasFiles: Self.hasFiles(b),
                                     canSend: supported == true)
    }

    static func hasFiles(_ b: UIPasteboard) -> Bool { b.types.contains(UTType.fileURL.identifier) }

    /// Sends what the clipboard holds as files: copied files, or else an image.
    func pasteFiles() {
        send(providers: UIPasteboard.general.itemProviders, unnamed: "Pasted Image", empty: "Nothing on the clipboard to send.")
    }

    /// Sends the items of a paste or a drop as one batch, prepared as picked photos are.
    func send(providers: [NSItemProvider], unnamed: String, empty: String) {
        let original = sendOriginals
        let prepare = picker.prepare
        Task { @MainActor in
            var files: [ImagePrep.Result] = []
            for p in providers {
                if let f = await Self.load(p, unnamed: unnamed) { files.append(await Task.detached { prepare(f, original) }.value) }
            }
            if files.isEmpty { Notice.shared.show(empty) } else { self.send(files) }
        }
    }

    /// An item as a staged file: a file keeps its name; an image without one gets a readable one
    /// ("Pasted Image 2026-11-17 17.31.png").
    static func load(_ p: NSItemProvider, unnamed: String) async -> StagedFile? {
        guard let type = FileItemType.pick(p.registeredContentTypes,
                                           fileBacked: p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)) else { return nil }
        let suggested = p.suggestedName
        return await withCheckedContinuation { (c: CheckedContinuation<StagedFile?, Never>) in
            _ = p.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                guard let url else { return c.resume(returning: nil) }
                let ext = url.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "bin") : url.pathExtension
                let name = suggested.map { $0.lowercased().hasSuffix("." + ext.lowercased()) ? $0 : $0 + "." + ext }
                    ?? UploadName.stamped(unnamed, at: Date(), ext: ext)
                c.resume(returning: try? FileStaging.stage(copying: url, as: name))
            }
        }
    }

    // MARK: Open

    /// The pane let go of its stream (closed, or long off screen): stop a download and drop its copy.
    func close() { opener.close() }

    /// The path selected text names, where the server can send files; the edit menu offers Open for it.
    func openablePath(in selection: String) -> String? {
        guard supported == true else { return nil }
        return PathGuess.path(in: selection)
    }

    /// Opens the file `selection` names, from the pane's computer, in Quick Look.
    func open(selection: String) {
        guard let path = openablePath(in: selection) else { return }
        opener.open(path, machine: machineName, over: view)
    }

    /// Lets files from other apps be dropped on `view`, the pane.
    func installDrop(on view: UIView) {
        guard drop == nil else { return }
        drop = PaneDrop(files: self, view: view)
    }

    // MARK: Send

    /// Sends prepared files. An image whose location couldn't be removed goes only if the user
    /// says so; without a yes it is left out.
    func send(_ results: [ImagePrep.Result]) {
        let ready = results.compactMap { if case .ready(let f) = $0 { f } else { nil } }
        let kept = results.compactMap { if case .locationKept(let f) = $0 { f } else { nil } }
        guard !kept.isEmpty else { return send(ready) }
        guard let view else {
            FileStaging.discard(kept)
            return send(ready)
        }
        let what = kept.count == 1 ? kept[0].name : "\(kept.count) images"
        TerminalPrompt.ask(over: view, title: "Couldn't remove location. Send original?",
                           message: "\(what) would go with its location and other details.",
                           confirm: "Send Original") { [weak self] yes in
            if !yes { FileStaging.discard(kept) }
            let files = yes ? results.map(\.file) : ready
            if !files.isEmpty { self?.send(files) }
        }
    }

    func send(_ files: [StagedFile]) {
        guard supported == true else {
            FileStaging.discard(files)
            Notice.shared.show("This computer's Rex can't take files. Update Rex there.")
            return
        }
        sender.send(files, over: view)
    }

    func cancel() { sender.cancel() }
}
