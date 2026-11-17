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
        if ClipboardChoice.offersPasteImage(hasImage: board.hasImages, canSend: true) {
            items.append(UIAction(title: "Paste Image", image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in
                self?.pasteImage()
            })
        }
        items.append(UIAction(title: "Photos", image: UIImage(systemName: "photo")) { [weak self] _ in
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
        let files = b.types.contains(UTType.fileURL.identifier)
        return ClipboardChoice.paste(hasText: b.hasStrings && !files, hasImage: b.hasImages, hasFiles: files,
                                     canSend: supported == true)
    }

    /// Sends what the clipboard holds as files: copied files, or else an image.
    func pasteFiles() {
        send(providers: UIPasteboard.general.itemProviders, unnamed: "Pasted Image", empty: "Nothing on the clipboard to send.")
    }

    func pasteImage() { pasteFiles() }

    /// Sends the items of a paste or a drop as one batch, prepared as picked photos are.
    func send(providers: [NSItemProvider], unnamed: String, empty: String) {
        let original = sendOriginals
        let prepare = picker.prepare
        Task { @MainActor in
            var files: [StagedFile] = []
            for p in providers {
                if let f = await Self.load(p, unnamed: unnamed) { files.append(await Task.detached { prepare(f, original) }.value) }
            }
            if files.isEmpty { Notice.shared.show(empty) } else { self.send(files) }
        }
    }

    /// An item as a staged file: a file keeps its name; an image without one gets a readable one
    /// ("Pasted Image 2026-11-17 17.31.png").
    static func load(_ p: NSItemProvider, unnamed: String) async -> StagedFile? {
        let types = p.registeredContentTypes
        let type = types.first { $0.conforms(to: .image) && !$0.conforms(to: .url) }
            ?? types.first { $0.conforms(to: .data) && !$0.conforms(to: .url) && !$0.conforms(to: .text) }
            ?? types.first { $0.conforms(to: .content) && !$0.conforms(to: .url) }
        guard let type else { return nil }
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
