import SwiftUI
import UIKit
import UniformTypeIdentifiers
import RexKit

/// What a pane's files offer by name: the attach menu's browse rows, the keymap's four actions
/// (`pane.go_to_directory`, `pane.insert_path`, `pane.insert_file`, `pane.insert_photo`) and
/// anything else that lists commands for a pane.
enum FilesCommand: String, CaseIterable, Sendable {
    case browse, insertPath, insertFile, insertPhoto

    /// The Rex action a key is bound to.
    var action: String {
        switch self {
        case .browse: return "pane.go_to_directory"
        case .insertPath: return "pane.insert_path"
        case .insertFile: return "pane.insert_file"
        case .insertPhoto: return "pane.insert_photo"
        }
    }

    static func forAction(_ name: String) -> FilesCommand? { allCases.first { $0.action == name } }

    /// As a menu names it.
    var title: String {
        switch self {
        case .browse: return "Browse Files…"
        case .insertPath: return "Insert Path…"
        case .insertFile: return "Insert File…"
        case .insertPhoto: return "Insert Photo…"
        }
    }

    var symbol: String {
        switch self {
        case .browse: return "folder"
        case .insertPath: return "text.insert"
        case .insertFile: return "doc"
        case .insertPhoto: return "photo"
        }
    }

    /// Words the palette also finds the row by, so "attach" or "screenshot" leads to sending one.
    var keywords: String { "image photo picture screenshot attach upload file send" }

    /// The file method the pane's host must have.
    var needs: FileMethod {
        switch self {
        case .browse, .insertPath: return .listDir
        case .insertFile, .insertPhoto: return .upload
        }
    }
}

/// The paths last inserted, newest first, per server and host.
enum PathRecents {
    static let limit = 8

    static func key(server: UUID, host: String?) -> String { server.uuidString + "|" + (host ?? "") }

    /// `path` at the front of its list, once; lists of servers that are no longer saved go.
    static func adding(_ path: String, key: String, to all: [String: [String]], servers: [UUID]) -> [String: [String]] {
        let kept = Set(servers.map(\.uuidString))
        var out = all.filter { kept.contains(String($0.key.prefix(36))) || $0.key == key }
        out[key] = Array(([path] + (out[key] ?? []).filter { $0 != path }).prefix(limit))
        return out
    }
}

/// Files for one pane: the attach menu, Paste of an image or a file, the send, the file browser
/// and Insert Path. Everything sent lands on the pane's computer and its path is typed into the
/// pane, so every send starts from an explicit action and the menu says where it goes.
@MainActor
final class PaneFiles {
    let server: ServerConnection
    let sessionID: String
    let blockID: String
    /// The pane's view: pickers, the browser and questions show over it.
    weak var view: UIView?
    /// Called when what the pane's host can do with files may have changed.
    var onSupportChanged: (() -> Void)?
    /// Writes text into the pane as a paste does (`TerminalHost.paste`).
    var insertText: ((String) -> Void)?
    /// Runs its argument once the pane's stream has caught up: at once when it is current.
    var whenCurrent: ((@escaping @MainActor () -> Void) -> Void)?
    /// How long a send waits for that before it is given up, and the wait itself (tests skip it).
    var currentWait: Duration = .seconds(10)
    var sleep: @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    /// The files waiting for the pane to be current.
    private var waiting: (id: Int, files: [StagedFile])?
    private var waitSerial = 0
    /// Whether the pane's program asked for bracketed paste.
    var bracketedPaste: () -> Bool = { false }
    /// Asks before an insert into a program that didn't ask for text. Nil: an alert. Tests put
    /// their own here.
    var confirmInsert: ((_ title: String, _ text: String, _ answer: @escaping @MainActor (Bool) -> Void) -> Void)?
    /// Who holds the pane's keyboard, and how to give it back (`KeyboardRecord`).
    var keyboard: (capture: () -> KeyboardRecord, retake: (KeyboardRecord) -> Void)?

    private let sender: FileSender
    private let opener: FileOpener
    private let lister: DirLister
    private let picker = AttachPicker()
    private var drop: PaneDrop?
    private var probing: Set<FileMethod> = []
    /// The creator list usually answers without a call: probes wait this long for it.
    static let creatorWait: Duration = .seconds(3)
    private var creatorWaitOver = false
    private var creatorWaitSerial = -1
    /// The browser, while it is up.
    private(set) weak var browser: UIViewController?
    private(set) weak var browserModel: BrowserModel?

    init(server: ServerConnection, sessionID: String, blockID: String) {
        self.server = server
        self.sessionID = sessionID
        self.blockID = blockID
        sender = FileSender(control: server.control, sessionID: sessionID, blockID: blockID)
        opener = FileOpener(control: server.control, sessionID: sessionID, blockID: blockID)
        lister = DirLister(control: server.control, sessionID: sessionID, blockID: blockID)
        sender.target = { [weak self] in self?.target ?? "this computer" }
        picker.onPicked = { [weak self] files in self?.send(files) }
        picker.prepare = { ImagePrep.prepare($0, original: $1) }
        opener.onFolder = { [weak self] path in self?.browse(.browse, at: path) ?? false }
        watchSupport()
    }

    // MARK: Support

    private var block: BlockInfo? { server.blockInfo(session: sessionID, block: blockID) }

    /// What the pane's host can do with files, each method on its own; nil while not known.
    var support: FileSupport { server.fileSupport(host: block?.hostID) }

    /// The attach key shows where there is something behind it: sending, or browsing.
    var showsAttachKey: Bool {
        let s = support
        return s.upload == true || s.listDir == true
    }

    /// Follows the server's capabilities, so the attach key and its rows come and go when the
    /// answer does (a creator list that arrives, a reconnect to another server version).
    private func watchSupport() {
        withObservationTracking {
            _ = support
            _ = server.phase
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.watchSupport()
                self.onSupportChanged?()
            }
        }
    }

    /// Asks the server for each method nobody has an answer for, each on its own. The creator
    /// list answers first when it can; a probe that gave no answer is asked again as
    /// `ServerCapabilities.shouldProbe` allows (once more per connection, a minute later).
    /// Returns the methods it started asking about now.
    @discardableResult
    func checkSupport() -> Set<FileMethod> {
        guard server.phase == .online, let block else { return [] }
        let host = block.hostID
        let caps = server.capabilities
        let serial = server.connectionSerial
        if case .unknown = caps.creators, !(creatorWaitOver && creatorWaitSerial == serial) {
            // The list is on its way. If it never comes, ask anyway.
            guard creatorWaitSerial != serial else { return [] }
            creatorWaitSerial = serial
            creatorWaitOver = false
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.creatorWait)
                guard let self, self.creatorWaitSerial == serial else { return }
                self.creatorWaitOver = true
                self.checkSupport()
            }
            return []
        }
        let remote = !server.isLocal(block)
        var asked: Set<FileMethod> = []
        for method in FileMethod.allCases where server.has(method, host: host) == nil && !probing.contains(method)
            && caps.shouldProbe(method: method.full, host: host) {
            probing.insert(method)
            asked.insert(method)
            Task { @MainActor in
                let answer = await FileProbe.ask(method, control: self.server.control, sessionID: self.sessionID,
                                                 blockID: self.blockID, remote: remote)
                self.probing.remove(method)
                self.server.capabilities.record(method: method.full, host: host, answer, serial: serial)
            }
        }
        return asked
    }

    // MARK: Destination

    /// The agent working in the pane, else the pane's computer.
    var target: String {
        SendTarget.name(agent: server.meta[blockID]?.agentKind, machine: machine)
    }

    private var machineName: String { machine ?? "this computer" }

    private var machine: String? {
        if let host = block?.hostID, let label = server.hosts.first(where: { $0.id == host })?.label { return label }
        return server.config.name
    }

    // MARK: Menu

    /// One row of the attach menu. The attach key draws the rows as a `UIMenu` (`menu()`), the
    /// pane menu's Attach as SwiftUI (`AttachMenuItem`): one list, so the two never differ.
    struct Row {
        var title: String
        var subtitle: String?
        var symbol: String
        /// A toggle's state; nil for a plain row.
        var on: Bool?
        var run: @MainActor () -> Void
    }

    struct Section {
        var title: String?
        var rows: [Row]
    }

    /// The attach menu's rows, read when it opens so its title and Paste Image are current. The
    /// rows for sending show where the host takes uploads, the browse rows where it lists folders.
    func sections() -> [Section] {
        var sections: [Section] = []
        if support.upload == true { sections.append(sendSection()) }
        let browse = [FilesCommand.browse, .insertPath].filter(offers).map { c in
            Row(title: c.title, symbol: c.symbol) { [weak self] in self?.run(c) }
        }
        if !browse.isEmpty { sections.append(Section(rows: browse)) }
        if support.upload == true {
            let original = Row(title: "Send Original", subtitle: "Photos as they are, with their location",
                               symbol: "photo.badge.checkmark", on: sendOriginals) { [weak self] in
                self?.sendOriginals.toggle()
            }
            sections.append(Section(rows: [original]))
        }
        return sections
    }

    /// The attach key's menu.
    func menu() -> UIMenu {
        UIMenu(children: sections().map { s in
            UIMenu(title: s.title ?? "", options: .displayInline, children: s.rows.map { r in
                UIAction(title: r.title, subtitle: r.subtitle, image: UIImage(systemName: r.symbol),
                         state: r.on.map { $0 ? .on : .off } ?? .off) { _ in r.run() }
            })
        })
    }

    private func sendSection() -> Section {
        var rows: [Row] = []
        if let title = pasteFileTitle {
            rows.append(Row(title: title, symbol: "doc.on.clipboard") { [weak self] in self?.pasteFiles() })
        }
        rows.append(Row(title: "Photos", subtitle: "Without location. Videos are sent as they are.", symbol: "photo") { [weak self] in
            self?.pickPhotos()
        })
        if AttachPicker.cameraAvailable {
            rows.append(Row(title: "Camera", symbol: "camera") { [weak self] in
                guard let self, let view = self.view else { return }
                self.picker.takePhoto(over: view, original: self.sendOriginals)
            })
        }
        rows.append(Row(title: "Files", symbol: "folder") { [weak self] in self?.pickFiles() })
        return Section(title: SendTarget.menuTitle(target), rows: rows)
    }

    /// "Paste Image" or "Paste File" where the clipboard holds one and the host takes uploads,
    /// else nil. It checks the clipboard's types only, which asks nothing of the user; the
    /// clipboard is read when the row is picked (`pasteFiles`).
    var pasteFileTitle: String? {
        let b = UIPasteboard.general
        return ClipboardChoice.pasteFileTitle(hasImage: b.hasImages, hasFiles: Self.hasFiles(b), canSend: support.upload == true)
    }

    /// The Photos picker, honoring Send Original. Its pick is sent to the pane.
    func pickPhotos() {
        guard support.upload == true, let view else { return }
        picker.pickPhotos(over: view, original: sendOriginals)
    }

    /// The Files picker. Its pick is sent to the pane as it is.
    func pickFiles() {
        guard support.upload == true, let view else { return }
        picker.pickFiles(over: view)
    }

    // MARK: Commands

    /// Whether a command applies to this pane now: its host has the method, and for Insert Path
    /// the pane's program is one a path can be written to.
    func offers(_ command: FilesCommand) -> Bool {
        server.offers(command, host: block?.hostID, block: blockID)
    }

    /// Runs a command, from the attach menu or a bound key. Nothing happens where it doesn't apply.
    func run(_ command: FilesCommand) {
        guard offers(command) else { return }
        switch command {
        case .browse: browse(.browse)
        case .insertPath: browse(.insert)
        case .insertFile: pickFiles()
        case .insertPhoto: pickPhotos()
        }
    }

    /// "Send Original": photos go untouched. Lasts until the app quits, like a picker's own choice.
    private var sendOriginals: Bool {
        get { server.prefs.sendOriginalPhotos }
        set { server.prefs.sendOriginalPhotos = newValue }
    }

    // MARK: Paste

    /// What Paste does now. Text always pastes as text; only a clipboard without text sends.
    var pasteChoice: ClipboardChoice {
        let b = UIPasteboard.general
        return ClipboardChoice.paste(hasText: b.hasStrings, hasImage: b.hasImages, hasFiles: Self.hasFiles(b),
                                     canSend: support.upload == true)
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
    func close() {
        opener.close()
        notSent()
    }

    /// Whether the pane's host can send files here: Open, Preview, Share and Save.
    var canOpen: Bool { support.download == true }

    /// The path selected text names, where the server can send files; the edit menu offers Open for it.
    func openablePath(in selection: String) -> String? {
        guard canOpen else { return nil }
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
        guard support.upload == true else {
            FileStaging.discard(files)
            Notice.shared.show("This computer's Rex can't take files. Update Rex there.")
            return
        }
        // The user picked files, not a place on the screen: they go once the pane is current.
        guard let whenCurrent else { return sender.send(files, over: view) }
        guard waiting == nil else {
            FileStaging.discard(files)
            Notice.shared.show("Wait for the files on their way to finish.")
            return
        }
        waitSerial += 1
        let id = waitSerial
        waiting = (id, files)
        whenCurrent { [weak self] in
            guard let self, self.waiting?.id == id else { return }
            self.waiting = nil
            self.sender.send(files, over: self.view)
        }
        guard waiting?.id == id else { return }
        // Not for ever: a pane that stays behind says so, and the user sends again when it is back.
        let wait = currentWait, sleep = self.sleep
        Task { @MainActor [weak self] in
            await sleep(wait)
            guard let self, self.waiting?.id == id else { return }
            self.notSent()
        }
    }

    /// The files that waited for the pane to be current don't go: the pane left the screen,
    /// closed, or stayed behind for `currentWait`. Said as any send that didn't happen, with Retry.
    private func notSent() {
        guard let (_, files) = waiting else { return }
        waiting = nil
        let retry = Notice.Action(title: "Retry") { [weak self] in
            if let self { self.send(files) } else { FileStaging.discard(files) }
        }
        Notice.shared.show(Self.notSentText(files.map(\.name)), style: .neutral, action: retry)
    }

    static func notSentText(_ names: [String]) -> String {
        "Not sent: \(SendTarget.what(names)). The pane was still reconnecting."
    }

    func cancel() { sender.cancel() }

    // MARK: Browse and insert

    /// What an insert into this pane would do now (`PathInsert.decide`).
    var insertDecision: PathInsert.Decision {
        PathInsert.decide(foreground: server.meta[blockID]?.foreground, bracketedPaste: bracketedPaste(),
                          windows: server.platform?.hasPrefix("windows") == true)
    }

    private var recentsKey: String { PathRecents.key(server: server.config.id, host: block?.hostID) }

    /// What the browser may do right now. It reads this each time it draws.
    private var browserFacts: BrowserModel.Facts {
        let s = support
        // Without `list_dir` the listing on screen is only to read: nothing in it is fetched or inserted.
        let lists = s.listDir == true
        return BrowserModel.Facts(canList: lists, canFetch: lists && s.download == true,
                                  insert: lists ? insertDecision : .unavailable,
                                  paneOpen: block != nil && server.meta[blockID]?.exited != true,
                                  online: server.phase == .online)
    }

    /// Shows the file browser over the pane, at `start` (empty: the folder the pane's program is
    /// in). It takes the keyboard as any sheet does and gives it back, when it goes, to whoever
    /// held it: the terminal shown or quiet, nobody, or the pane's find field. False when it
    /// can't show.
    @discardableResult
    func browse(_ mode: BrowserModel.Mode, at start: String = "") -> Bool {
        guard support.listDir == true, browser == nil, let view, var top = view.window?.rootViewController else { return false }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let prefs = server.prefs
        let record = keyboard?.capture()
        var source: any DirSource = lister
        #if DEBUG
        source = DelayedFolders.wrap(lister)  // `-filesListDelay` (testing, FilesTest.swift)
        #endif
        let model = BrowserModel(mode: mode, machine: machineName, computer: machine, mac: server.platform?.hasPrefix("darwin") == true,
                                 start: start, source: source, recents: prefs.pathRecents[recentsKey] ?? [],
                                 showHidden: prefs.showHiddenFiles) { [weak self] in
            self?.browserFacts ?? BrowserModel.Facts(canList: false, canFetch: false, paneOpen: false, online: false)
        }
        let sheet = BrowserSheet(rootView: PaneBrowser(model: model, prefs: prefs))
        sheet.modalPresentationStyle = .pageSheet
        sheet.sheetPresentationController?.detents = [.large()]
        var insert: String?
        model.onShowHidden = { prefs.showHiddenFiles = $0 }
        model.onCopy = { UIPasteboard.general.string = $0 }
        model.onPreview = { [weak self] path in
            guard let self else { return }
            self.opener.open(path, machine: self.machineName, over: self.view, textHint: true)
        }
        model.onShare = { [weak self] path in
            guard let self else { return }
            self.opener.export(path, machine: self.machineName, to: .share, over: self.view)
        }
        model.onSave = { [weak self] path in
            guard let self else { return }
            self.opener.export(path, machine: self.machineName, to: .files, over: self.view)
        }
        model.onClose = { [weak sheet] in sheet?.dismiss(animated: true) }
        model.onInsert = { [weak sheet] path in
            insert = path
            sheet?.dismiss(animated: true)
        }
        sheet.onGone = { [weak self, weak model] in
            guard let self else { return }
            if let record { self.keyboard?.retake(record) }
            if let path = insert { self.insert(path: path, cwd: model?.cwd, home: model?.current.home ?? "") }
        }
        browser = sheet
        browserModel = model
        top.present(sheet, animated: true)
        return true
    }

    /// Writes a path into the pane: in the form and quoting `PathInsert` gives for the pane's
    /// program as it is now, followed by a space, never by a line end. A program that didn't ask
    /// for text is asked about first.
    func insert(path: String, cwd: String?, home: String) {
        let decision = insertDecision
        guard decision.offered, support.listDir == true else { return }
        switch PathInsert.text(for: path, cwd: cwd, home: home, quoting: decision.quoting) {
        case .failure(let refusal):
            Notice.shared.show(refusal.message)
        case .success(let text):
            let write: @MainActor () -> Void = { [weak self] in
                guard let self else { return }
                self.insertText?(text)
                let prefs = self.server.prefs
                prefs.pathRecents = PathRecents.adding(path, key: self.recentsKey, to: prefs.pathRecents,
                                                       servers: prefs.servers.map(\.id))
            }
            if case .ask(let program) = decision {
                let title = PathInsert.question(program: program)
                let answer: @MainActor (Bool) -> Void = { yes in if yes { write() } }
                if let confirmInsert {
                    confirmInsert(title, text, answer)
                } else if let view {
                    TerminalPrompt.ask(over: view, title: title, message: text, confirm: "Insert", answer: answer)
                }
            } else {
                write()
            }
        }
    }
}

/// The browser's sheet. It says when it has gone, however it went: Done, a swipe down, an insert.
private final class BrowserSheet: UIHostingController<PaneBrowser> {
    var onGone: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || presentingViewController == nil else { return }
        let gone = onGone
        onGone = nil
        gone?()
    }
}
