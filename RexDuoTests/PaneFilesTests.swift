import Synchronization
import UIKit
import UniformTypeIdentifiers
import XCTest
import RexKit
@testable import RexDuo

/// A pane's files against a Rex server in this process: which file methods its host has (from
/// the creator list, else one probe per method), what shows for each mix, and what Insert writes.
@MainActor
final class PaneFilesTests: XCTestCase {
    typealias Rig = ServerEventsTests.Rig
    nonisolated static let terminal = ServerEventsTests.terminal
    nonisolated static let upload = FileMethod.upload.full
    nonisolated static let download = FileMethod.download.full
    nonisolated static let list = FileMethod.listDir.full

    nonisolated static func creators(_ methods: [String]?, host: String = "host-a", api: Bool = true) -> FakeRexServer.Reply {
        var creator: JSONObject = ["name": terminal, "host_id": host, "flavors": [["flavor": "\(terminal).shell"]]]
        if api {
            var a: JSONObject = ["events": ["bell": [:] as JSONObject]]
            if let methods { a["methods"] = Dictionary(uniqueKeysWithValues: methods.map { ($0, [:] as JSONObject) }) }
            creator["api"] = a
        }
        return .result(["creators": [creator]])
    }

    /// Waits until `condition` holds, checking it every 10 ms up to `seconds` worth of checks. The
    /// limit counts checks, not the clock: a run the system stalls for a while waits longer
    /// instead of giving up before the work it waits for had a chance to run.
    private func eventually(seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
        for _ in 0..<Int(seconds * 100) {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    /// A connected rig with session 1 in view, and the files of its first pane. It waits for the
    /// first sync and the creator list itself (`Rig.settle` goes on after five seconds on the
    /// clock, finished or not), so a test starts from a pane whose server is known.
    private func pane(revision: Int? = 18, creators: FakeRexServer.Reply,
                      script: ((Rig) -> Void)? = nil) async throws -> (Rig, PaneFiles) {
        let rig = try await Rig(revision: revision, creators: creators)
        script?(rig)
        await rig.connect()
        await rig.server.attach("session:1")
        let server = rig.server
        let ready = await eventually(seconds: 10) {
            server.phase == .online && server.synced && server.creatorsTask == nil && server.capabilities.creators != .unknown
                && server.blockInfo(session: "session:1", block: "block:1a") != nil
        }
        XCTAssertTrue(ready, "the sync and the creator list finished: \(server.phase), \(server.capabilities.creators)")
        let files = PaneFiles(server: server, sessionID: "session:1", blockID: "block:1a")
        return (rig, files)
    }

    /// Each group's titles; a submenu's rows follow it, marked "▸ ". The rows must be plain:
    /// no subtitle and no on/off state anywhere in the menu.
    private func titles(_ menu: UIMenu, file: StaticString = #filePath, line: UInt = #line) -> [[String]] {
        menu.children.map { group in
            ((group as? UIMenu)?.children ?? [group]).flatMap { e -> [String] in
                if let sub = e as? UIMenu { return [Self.machineless(sub.title)] + sub.children.map { "▸ " + $0.title } }
                let action = e as? UIAction
                XCTAssertEqual(action?.subtitle ?? "", "", e.title, file: file, line: line)
                XCTAssertEqual(action?.state, .off, e.title, file: file, line: line)
                return [e.title]
            }
        }
    }

    private func titles(_ sections: [PaneFiles.Section]) -> [[String]] {
        sections.map { s in s.rows.flatMap { [Self.machineless($0.title)] + ($0.children ?? []).map { "▸ " + $0.title } } }
    }

    /// "Files on studio" as "Files on …": the rig's machine name is not what these tests check.
    private static func machineless(_ title: String) -> String {
        title.hasPrefix("Files on ") && title.count > 9 ? "Files on …" : title
    }

    private static let computerRows = ["Files on …", "▸ Browse Files…", "▸ Insert Path…"]

    private func stripPasteRow(_ t: [[String]]) -> [[String]] {
        t.map { $0.filter { !$0.hasPrefix("Paste ") && $0 != "Camera" } }
    }

    // MARK: Support

    func testTheCreatorListAnswersWithNoCallAtEveryRevision() async throws {
        for revision in [nil, 13, 16, 18] as [Int?] {
            let (rig, files) = try await pane(revision: revision, creators: Self.creators(["write", "upload_begin", "download_begin", "list_dir"]))
            defer { rig.stop() }
            files.checkSupport()
            XCTAssertEqual(files.support, FileSupport(upload: true, download: true, listDir: true), "\(revision ?? 0)")
            XCTAssertTrue(files.showsAttachKey)
            XCTAssertTrue(files.canOpen)
            for m in [Self.upload, Self.download, Self.list] { XCTAssertEqual(rig.fake.count(m), 0, "\(m) at \(revision ?? 0)") }
            XCTAssertEqual(stripPasteRow(titles(files.menu())), [["Insert Photo…", "Insert File…"], Self.computerRows])
        }
    }

    func testACreatorWithoutAMethodHidesOnlyWhatNeedsIt() async throws {
        let (rig, files) = try await pane(creators: Self.creators(["write", "upload_begin", "download_begin"]))
        defer { rig.stop() }
        files.checkSupport()
        XCTAssertEqual(files.support, FileSupport(upload: true, download: true, listDir: false))
        XCTAssertEqual(rig.fake.count(Self.list), 0, "the list says it is missing: no call")
        XCTAssertEqual(stripPasteRow(titles(files.menu())), [["Insert Photo…", "Insert File…"]], "only the sending rows")
        XCTAssertFalse(files.offers(.browse))
        XCTAssertFalse(files.offers(.insertPath))
        XCTAssertTrue(files.offers(.insertFile) && files.offers(.insertPhoto))
        XCTAssertFalse(files.browse(.browse), "no browser without list_dir")
    }

    func testAHostWithOnlyListDirShowsTheKeyWithOnlyTheBrowseRows() async throws {
        let (rig, files) = try await pane(creators: Self.creators(["write", "list_dir"]))
        defer { rig.stop() }
        files.checkSupport()
        XCTAssertEqual(files.support, FileSupport(upload: false, download: false, listDir: true))
        XCTAssertTrue(files.showsAttachKey)
        XCTAssertEqual(titles(files.menu()), [Self.computerRows], "no Photos, Camera, Files or Paste")
        XCTAssertFalse(files.canOpen)
        XCTAssertNil(files.openablePath(in: "notes.txt"))
        XCTAssertFalse(DropRule.accepts(fromThisApp: false, canSend: files.support.upload == true, hasFiles: true))
        XCTAssertFalse(files.offers(.insertFile) || files.offers(.insertPhoto))
        // A send that got here anyway is turned away before any call.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pane-files-\(UUID().uuidString).txt")
        try Data("x".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        files.send([try FileStaging.stage(copying: url, as: "a.txt")])
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rig.fake.count(Self.upload), 0)
        Notice.shared.dismiss()
    }

    func testNeitherMethodHidesTheKey() async throws {
        let (rig, files) = try await pane(creators: Self.creators(["write"]))
        defer { rig.stop() }
        files.checkSupport()
        XCTAssertEqual(files.support, FileSupport(upload: false, download: false, listDir: false))
        XCTAssertFalse(files.showsAttachKey)
        XCTAssertTrue(titles(files.menu()).isEmpty)
        for c in FilesCommand.allCases { XCTAssertFalse(files.offers(c), c.rawValue) }
        XCTAssertFalse(AttachMenuItem.shows(files), "no Attach in the pane menu either")
        XCTAssertNil(files.pasteFileTitle, "nor Paste Image in the edit menu")
    }

    /// One flat list: Paste Image first while the clipboard holds an image, Camera only where the
    /// device has one, and nothing to switch.
    func testTheMenuIsOneShortListWithPasteFirst() async throws {
        let (rig, files) = try await pane(creators: Self.creators(["write", "upload_begin", "download_begin", "list_dir"]))
        defer { rig.stop() }
        files.checkSupport()
        let board = UIPasteboard.general
        let saved = board.items
        defer { board.items = saved }
        let camera = AttachPicker.cameraAvailable ? ["Camera"] : []
        board.items = [[UTType.png.identifier: UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }]]
        XCTAssertEqual(titles(files.menu()), [["Paste Image", "Insert Photo…"] + camera + ["Insert File…"], Self.computerRows])
        board.items = []
        XCTAssertEqual(titles(files.menu()), [["Insert Photo…"] + camera + ["Insert File…"], Self.computerRows], "no clipboard image: no Paste row")
        XCTAssertFalse(titles(files.menu()).joined().contains("Send Original"))
    }

    /// The pane menu's Attach shows exactly where the attach key does, with the key's rows.
    func testThePaneMenusAttachFollowsTheKey() async throws {
        for methods in [["write", "upload_begin", "download_begin", "list_dir"], ["write", "list_dir"], ["write"]] {
            let (rig, files) = try await pane(creators: Self.creators(methods))
            defer { rig.stop() }
            files.checkSupport()
            XCTAssertEqual(AttachMenuItem.shows(files), files.showsAttachKey, "\(methods)")
            XCTAssertEqual(titles(files.sections()), titles(files.menu()), "\(methods)")
        }
        XCTAssertFalse(AttachMenuItem.shows(nil), "no host on screen: no row")
    }

    // MARK: A send that waits for the pane to be current

    private func stagedFile(_ name: String = "notes.txt") -> StagedFile {
        StagedFile(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name),
                   name: name, size: 3)
    }

    /// A pane that takes files, whose stream never says it is current.
    private func waitingPane() async throws -> (Rig, PaneFiles, () -> Void) {
        let (rig, files) = try await pane(creators: Self.creators(["write", "upload_begin", "download_begin", "list_dir"]))
        files.checkSupport()
        var wake: [CheckedContinuation<Void, Never>] = []
        files.whenCurrent = { _ in }
        files.sleep = { _ in await withCheckedContinuation { wake.append($0) } }
        Notice.shared.dismiss()
        return (rig, files, { wake.forEach { $0.resume() }; wake = [] })
    }

    /// A paste or a drop is prepared as a photo is, always (no switch), and never on the main
    /// thread, where a large photo's decode would stall the terminal.
    func testAPasteIsPreparedOffTheMainThread() async throws {
        let (rig, files, wake) = try await waitingPane()
        defer { rig.stop(); wake(); Notice.shared.dismiss() }
        final class Seen: @unchecked Sendable {  // written by the one prepare call, read after it
            let lock = NSLock()
            var onMain: [Bool] = []
        }
        let seen = Seen()
        files.prepare = { f in
            seen.lock.withLock { seen.onMain.append(Thread.isMainThread) }
            return .ready(f)
        }
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { _ in }
        files.send(providers: [NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)],
                   unnamed: "Pasted Image", empty: "Nothing on the clipboard to send.")
        let prepared = await eventually { !seen.lock.withLock { seen.onMain }.isEmpty }
        XCTAssertTrue(prepared)
        XCTAssertEqual(seen.lock.withLock { seen.onMain }, [false])
        files.close()
    }

    func testASendWaitingForAPaneThatLeavesSaysNotSent() async throws {
        let (rig, files, wake) = try await waitingPane()
        defer { rig.stop(); wake() }
        files.send([stagedFile()])
        XCTAssertNil(Notice.shared.message, "it waits")
        files.close()
        XCTAssertEqual(Notice.shared.message, "Didn't send notes.txt: the pane was still reconnecting. Try again in a moment.")
        XCTAssertEqual(Notice.shared.style, .neutral)
        XCTAssertEqual(Notice.shared.actionTitle, "Try Again")
        Notice.shared.dismiss()
        files.close()
        XCTAssertNil(Notice.shared.message, "said once")
    }

    func testASendThatWaitsTooLongSaysNotSent() async throws {
        let (rig, files, wake) = try await waitingPane()
        defer { rig.stop() }
        XCTAssertEqual(files.currentWait, .seconds(10))
        files.send([stagedFile("a.png")])
        await Task.yield()
        XCTAssertNil(Notice.shared.message)
        wake()
        let said = await eventually { Notice.shared.message == PaneFiles.notSentText(["a.png"]) }
        XCTAssertTrue(said)
        Notice.shared.dismiss()
    }

    func testASendThatWentIsNotCalledLateAfterTheWait() async throws {
        let (rig, files, wake) = try await waitingPane()
        defer { rig.stop() }
        var current: (@MainActor () -> Void)?
        files.whenCurrent = { current = $0 }
        files.send([stagedFile()])
        current?()
        wake()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotEqual(Notice.shared.message, PaneFiles.notSentText(["notes.txt"]))
        files.cancel()
        Notice.shared.dismiss()
    }

    /// A creator for another host says nothing about this pane's: each method is asked, once.
    func testWithoutAnAnswerEachMethodIsProbedOnItsOwn() async throws {
        let cases: [(missing: Set<String>, expect: FileSupport)] = [
            ([], FileSupport(upload: true, download: true, listDir: true)),
            ([Self.upload], FileSupport(upload: false, download: true, listDir: true)),
            ([Self.download], FileSupport(upload: true, download: false, listDir: true)),
            ([Self.list], FileSupport(upload: true, download: true, listDir: false)),
            ([Self.upload, Self.download, Self.list], FileSupport(upload: false, download: false, listDir: false)),
        ]
        for c in cases {
            let (rig, files) = try await pane(creators: Self.creators(["write", "list_dir"], host: "host-b")) { rig in
                for m in [Self.upload, Self.download] {
                    rig.fake.reply(m, .error(code: c.missing.contains(m) ? "method_not_found" : "bad_request", status: 400))
                }
                if c.missing.contains(Self.list) {
                    rig.fake.reply(Self.list, .error(code: "method_not_found", status: 404))
                } else {
                    rig.fake.reply(Self.list, ["path": "/", "home": "/home/dev", "status": "ok", "entries": [["name": "etc"]], "truncated": true])
                }
            }
            defer { rig.stop() }
            XCTAssertEqual(files.support, FileSupport(), "nobody knows yet")
            XCTAssertFalse(files.showsAttachKey)
            XCTAssertEqual(files.checkSupport(), Set(FileMethod.allCases), "\(c.missing): each method is asked")
            let answered = await eventually { files.support == c.expect }
            XCTAssertTrue(answered, "\(c.missing): \(files.support)")
            // Every method has its answer, so its one call came and went; asking again sends nothing.
            XCTAssertEqual(files.checkSupport(), [], "\(c.missing): answered methods are not asked again")
            for m in [Self.upload, Self.download, Self.list] { XCTAssertEqual(rig.fake.count(m), 1, m) }
            let args = rig.fake.calls(Self.list).first?.obj("args") ?? [:]
            XCTAssertEqual(args.str("path"), "/")
            XCTAssertEqual(args.int("limit"), 1)
        }
    }

    func testACreatorWithNoMethodsListedIsAskedToo() async throws {
        for creators in [Self.creators(nil), Self.creators(nil, api: false), FakeRexServer.Reply.error(code: "method_not_found", status: 404)] {
            let (rig, files) = try await pane(creators: creators) { rig in
                rig.fake.reply(Self.upload, .error(code: "bad_request", status: 400))
                rig.fake.reply(Self.download, .error(code: "bad_request", status: 400))
                rig.fake.reply(Self.list, ["path": "/", "home": "", "status": "ok", "entries": NSNull(), "truncated": false])
            }
            defer { rig.stop() }
            files.checkSupport()
            let answered = await eventually { files.support == FileSupport(upload: true, download: true, listDir: true) }
            XCTAssertTrue(answered, "\(files.support)")
        }
    }

    /// A server older than `method_not_found` answers `not_found` for a missing method, as it does
    /// for a block that has gone: no answer, so nothing shows, and it is not asked again at once.
    func testNotFoundIsNoAnswerAndIsNotAskedAgainWithinTheMinute() async throws {
        let (rig, files) = try await pane(revision: nil, creators: .error(code: "not_found", status: 404)) { rig in
            for m in [Self.upload, Self.download, Self.list] { rig.fake.reply(m, .error(code: "not_found", status: 404)) }
        }
        defer { rig.stop() }
        files.checkSupport()
        let asked = await eventually { rig.fake.count(Self.upload) == 1 && rig.fake.count(Self.list) == 1 && rig.fake.count(Self.download) == 1 }
        XCTAssertTrue(asked)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(files.support, FileSupport())
        XCTAssertFalse(files.showsAttachKey, "the key is hidden where nothing is known to work")
        for _ in 0..<3 { files.checkSupport() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(rig.fake.count(Self.upload), 1)
        XCTAssertFalse(rig.server.capabilities.shouldProbe(method: Self.upload, host: "host-a"))
        XCTAssertTrue(rig.server.capabilities.shouldProbe(method: Self.upload, host: "host-a", now: Date().addingTimeInterval(61)))
    }

    func testSupportChangesAreToldAndFollowAReconnectToAnotherServer() async throws {
        let (rig, files) = try await pane(creators: Self.creators(["write", "upload_begin", "download_begin", "list_dir"]))
        defer { rig.stop() }
        var told = 0
        files.onSupportChanged = { told += 1 }
        XCTAssertEqual(files.support.listDir, true)
        // The server restarts as a version without list_dir.
        rig.fake.reply("block_creator.list", Self.creators(["write", "upload_begin", "download_begin"]))
        rig.setInstance("instance-2")
        rig.fake.dropAll()
        let gone = await eventually(seconds: 8) { files.support.listDir == false }
        XCTAssertTrue(gone)
        XCTAssertEqual(files.support.upload, true, "uploads keep their answer")
        XCTAssertGreaterThan(told, 0)
        XCTAssertEqual(rig.fake.count(Self.list), 0, "nothing is sent to a server without the method")
        // And comes back with it.
        rig.fake.reply("block_creator.list", Self.creators(["write", "upload_begin", "download_begin", "list_dir"]))
        rig.setInstance("instance-3")
        rig.fake.dropAll()
        let back = await eventually(seconds: 8) { files.support.listDir == true }
        XCTAssertTrue(back)
    }

    /// Two hosts behind one server answer for themselves: a remote host with an older Rex hides
    /// the browse rows for its panes only.
    func testEachHostOfOneServerHasItsOwnAnswer() {
        let (files, _, _) = offlinePane(foreground: "zsh", support: [])
        let server = files.server
        func creator(_ host: String, _ methods: [String]) -> JSONObject {
            ["name": Self.terminal, "host_id": host, "flavors": [["flavor": "\(Self.terminal).shell"]],
             "api": ["methods": Dictionary(uniqueKeysWithValues: methods.map { ($0, [:] as JSONObject) })] as JSONObject]
        }
        server.capabilities.creatorsLoaded(["creators": [creator("host-a", ["upload_begin", "download_begin", "list_dir"]),
                                                         creator("host-b", ["upload_begin", "download_begin"])]],
                                           serial: server.capabilities.serial)
        XCTAssertEqual(server.fileSupport(host: "host-a"), FileSupport(upload: true, download: true, listDir: true))
        XCTAssertEqual(server.fileSupport(host: "host-b"), FileSupport(upload: true, download: true, listDir: false))
        XCTAssertEqual(server.fileSupport(host: "host-c"), FileSupport(), "a host the list doesn't name is asked")
        // A call's own answer on this connection outranks the list.
        server.capabilities.record(method: Self.list, host: "host-a", .absent, serial: server.capabilities.serial)
        XCTAssertEqual(server.has(.listDir, host: "host-a"), false)
        XCTAssertEqual(server.has(.upload, host: "host-a"), true)
    }

    // MARK: Insert

    /// A pane on a server that is not connected, with the answers a test wants recorded by hand.
    private func offlinePane(foreground: String?, bracketed: Bool = false,
                             support: [FileMethod] = FileMethod.allCases) -> (PaneFiles, Prefs, () -> [String]) {
        let name = "PaneFilesTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let prefs = Prefs(defaults: d)
        let model = AppModel(prefs: prefs, connect: false)
        let server = ServerConnection(config: ServerConfig(name: "studio", url: "http://127.0.0.1:1"), prefs: prefs,
                                      notifier: model.notifier, deviceID: "a1b2c3d4")
        for m in support { server.capabilities.record(method: m.full, host: nil, .present, serial: server.capabilities.serial) }
        var meta = BlockMeta()
        meta.foreground = foreground
        server.meta["block:b"] = meta
        let files = PaneFiles(server: server, sessionID: "session:s", blockID: "block:b")
        final class Written { var texts: [String] = [] }
        let written = Written()
        files.insertText = { written.texts.append($0) }
        files.bracketedPaste = { bracketed }
        return (files, prefs, { written.texts })
    }

    func testAShellGetsTheEscapedRelativePathAndASpaceAndNoLineEnd() {
        let (files, prefs, written) = offlinePane(foreground: "zsh")
        files.insert(path: "/home/dev/project/my file.txt", cwd: "/home/dev/project", home: "/home/dev")
        files.insert(path: "/home/dev/project/-x", cwd: "/home/dev/project", home: "/home/dev")
        files.insert(path: "/home/dev/notes/a&b", cwd: "/home/dev/project", home: "/home/dev")
        files.insert(path: "/etc/hosts", cwd: "/home/dev/project", home: "/home/dev")
        XCTAssertEqual(written(), ["my\\ file.txt ", "./-x ", "~/notes/a\\&b ", "/etc/hosts "])
        XCTAssertEqual(prefs.pathRecents.values.first, ["/etc/hosts", "/home/dev/notes/a&b", "/home/dev/project/-x", "/home/dev/project/my file.txt"])
    }

    func testAnAgentAndAnEditorGetThePathAsItIs() {
        let (agent, _, a) = offlinePane(foreground: "claude")
        agent.insert(path: "/home/dev/project/my file.txt", cwd: "/home/dev/project", home: "/home/dev")
        XCTAssertEqual(a(), ["my file.txt "])
        let (editor, _, e) = offlinePane(foreground: "vim", bracketed: true)
        editor.insert(path: "/home/dev/project/my file.txt", cwd: "/home/dev/project", home: "/home/dev")
        XCTAssertEqual(e(), ["my file.txt "])
    }

    func testAProgramThatDidntAskForTextIsAskedAboutFirst() {
        let (files, prefs, written) = offlinePane(foreground: "htop")
        var asked: [(String, String)] = []
        var answer: (@MainActor (Bool) -> Void)?
        files.confirmInsert = { title, text, a in
            asked.append((title, text))
            answer = a
        }
        files.insert(path: "/home/dev/project/src/kernel.c", cwd: "/home/dev/project", home: "/home/dev")
        XCTAssertEqual(asked.first?.0, "htop isn't taking text. Insert anyway?")
        XCTAssertEqual(asked.first?.1, "src/kernel.c ")
        XCTAssertEqual(written(), [], "nothing is written before the answer")
        answer?(false)
        XCTAssertEqual(written(), [])
        XCTAssertTrue(prefs.pathRecents.isEmpty)
        files.insert(path: "/home/dev/project/src/kernel.c", cwd: "/home/dev/project", home: "/home/dev")
        answer?(true)
        XCTAssertEqual(written(), ["src/kernel.c "])
        // No foreground known: asked too.
        let (unknown, _, w) = offlinePane(foreground: nil)
        var count = 0
        unknown.confirmInsert = { _, _, _ in count += 1 }
        unknown.insert(path: "/x", cwd: nil, home: "")
        XCTAssertEqual(count, 1)
        XCTAssertEqual(w(), [])
    }

    func testNothingIsWrittenWhereInsertIsNotOffered() {
        for program in ["ssh", "tmux", "mosh-client", "docker", "distrobox-enter"] {
            let (files, _, written) = offlinePane(foreground: program, bracketed: true)
            XCTAssertFalse(files.offers(.insertPath), program)
            XCTAssertTrue(files.offers(.browse), program)
            files.insert(path: "/home/dev/a", cwd: nil, home: "")
            files.run(.insertPath)
            XCTAssertEqual(written(), [], program)
            XCTAssertNil(files.browser, program)
        }
        // No list_dir on the host: no insert by any route.
        let (files, _, written) = offlinePane(foreground: "zsh", support: [.upload, .download])
        files.insert(path: "/home/dev/a", cwd: nil, home: "")
        XCTAssertEqual(written(), [])
    }

    func testANameWithAControlCharacterIsNotWritten() {
        let (files, prefs, written) = offlinePane(foreground: "zsh")
        files.insert(path: "/home/dev/project/a\nrm -rf b", cwd: "/home/dev/project", home: "/home/dev")
        files.insert(path: "/home/dev/project/a\u{1B}[201~b", cwd: "/home/dev/project", home: "/home/dev")
        XCTAssertEqual(written(), [])
        XCTAssertTrue(prefs.pathRecents.isEmpty)
        Notice.shared.dismiss()
    }

    func testRecentPathsKeepEightPerServerAndHostAndForgetRemovedServers() {
        let a = UUID(), b = UUID()
        let ka = PathRecents.key(server: a, host: "host-a"), kb = PathRecents.key(server: b, host: nil)
        var all: [String: [String]] = [:]
        for i in 0..<10 { all = PathRecents.adding("/p/\(i)", key: ka, to: all, servers: [a, b]) }
        XCTAssertEqual(all[ka]?.count, 8)
        XCTAssertEqual(all[ka]?.first, "/p/9")
        all = PathRecents.adding("/p/5", key: ka, to: all, servers: [a, b])
        XCTAssertEqual(all[ka]?.prefix(2), ["/p/5", "/p/9"])
        XCTAssertEqual(all[ka]?.count, 8, "a path is listed once")
        all = PathRecents.adding("/q", key: kb, to: all, servers: [a, b])
        XCTAssertEqual(all[kb], ["/q"])
        XCTAssertNotEqual(ka, PathRecents.key(server: a, host: nil), "hosts of one server keep their own")
        all = PathRecents.adding("/r", key: kb, to: all, servers: [b])
        XCTAssertNil(all[ka], "a removed server's paths go")
        XCTAssertEqual(all[kb], ["/r", "/q"])
    }

    // MARK: Commands and keys

    func testTheFourActionsResolveToThePanesFilesWithTheMacsTitlesAndNoDefaultKeys() {
        let expect: [(String, FilesCommand, String)] = [
            ("pane.go_to_directory", .browse, "Go to Directory…"), ("pane.insert_path", .insertPath, "Insert Path…"),
            ("pane.insert_file", .insertFile, "Insert File…"), ("pane.insert_photo", .insertPhoto, "Insert Photo…"),
        ]
        for (name, command, title) in expect {
            guard case .files(let c)? = AppAction.resolve(name, nil) else { return XCTFail(name) }
            XCTAssertEqual(c, command)
            XCTAssertEqual(command.action, name)
            XCTAssertEqual(KeyActions.byName[name]?.title, title)
            XCTAssertEqual(KeyActions.byName[name]?.repeats, false)
            XCTAssertNil(KeyLabel.for(action: name, in: KeyDefaults.resolved), "no key unless the user binds one")
            XCTAssertFalse(KeyDefaults.layer.contains { $0.1 == name })
            // Bound in the user's keymap, it has a label and shows in the shortcut list of the pane.
            let bound = [KeyBinding(chord: KeyChord(spelling: "ctrl+cmd+i")!, action: name, args: nil)] + KeyDefaults.resolved
            XCTAssertEqual(KeyLabel.for(action: name, in: bound), "⌃⌘I")
            // Not an app command: the app's menu doesn't carry it, and the find field drops it.
            XCTAssertFalse(AppShortcuts.list(bound, panes: .none).contains { $0.title == title })
            XCTAssertFalse(FindKeys.keepsWhileEditing(action: .files(command), chord: KeyChord(spelling: "ctrl+cmd+i")!))
        }
        XCTAssertEqual(FilesCommand.browse.title, "Browse Files…")
        XCTAssertEqual(FilesCommand.allCases.map(\.needs), [.listDir, .listDir, .upload, .upload])
        XCTAssertNil(FilesCommand.forAction("pane.copy"))
    }

    func testACommandDoesNothingWhereThePanesHostLacksItsMethod() {
        let (files, _, written) = offlinePane(foreground: "zsh", support: [])
        for c in FilesCommand.allCases {
            XCTAssertFalse(files.offers(c))
            files.run(c)
        }
        XCTAssertNil(files.browser)
        XCTAssertEqual(written(), [])
    }

    // MARK: Text hint

    func testAFileWithoutAnExtensionThatReadsAsTextIsPreviewedAsText() {
        let text = Data("all: build\n\tswift build\n".utf8)
        XCTAssertTrue(TextHint.applies(name: "Makefile", size: Int64(text.count), head: text))
        XCTAssertTrue(TextHint.applies(name: "LICENSE", size: 1_000_000, head: text))
        XCTAssertFalse(TextHint.applies(name: "LICENSE", size: 1_000_001, head: text), "over 1 MB keeps its name")
        XCTAssertFalse(TextHint.applies(name: "notes.md", size: 10, head: text), "an extension already says what it is")
        XCTAssertFalse(TextHint.applies(name: "blob", size: 4, head: Data([0x61, 0x00, 0x62, 0x63])), "a NUL is not text")
        XCTAssertFalse(TextHint.applies(name: "blob", size: 3, head: Data([0xFF, 0xFE, 0x41])))
        XCTAssertFalse(TextHint.applies(name: "empty", size: 0, head: Data()))
        // A character cut in two by the end of the head.
        var head = Data(repeating: 0x61, count: TextHint.headBytes - 2)
        head.append(contentsOf: [0xE2, 0x82])  // the first two bytes of "€"
        XCTAssertEqual(head.count, TextHint.headBytes)
        XCTAssertTrue(TextHint.applies(name: "README", size: 10_000, head: head))
        XCTAssertFalse(TextHint.applies(name: "README", size: Int64(head.count), head: head), "a whole file that ends inside a character is not text")
        var bad = Data(repeating: 0x61, count: TextHint.headBytes - 4)
        bad.append(contentsOf: [0xFF, 0x61, 0x61, 0x61])
        XCTAssertFalse(TextHint.applies(name: "README", size: 10_000, head: bad))
    }

    func testTheHintRenamesTheCopyOnly() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let make = dir.appendingPathComponent("Makefile")
        try Data("all:\n".utf8).write(to: make)
        XCTAssertEqual(TextHint.renamed(make)?.lastPathComponent, "Makefile.txt")
        XCTAssertFalse(FileManager.default.fileExists(atPath: make.path))
        let binary = dir.appendingPathComponent("tool")
        try Data([0, 1, 2, 3]).write(to: binary)
        XCTAssertNil(TextHint.renamed(binary))
        XCTAssertTrue(FileManager.default.fileExists(atPath: binary.path))
    }
}

/// The browser's sheet over a real pane view: it gives the keyboard back to whoever held it.
@MainActor
final class BrowserKeyboardTests: XCTestCase {
    private var window: UIWindow!
    private var hardware = true
    private var keep: [AnyObject] = []
    private var terminalsBefore = 0

    override func setUp() async throws {
        terminalsBefore = GhosttyCore.liveTerminals.load(ordering: .relaxed)
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        try XCTSkipUnless(UIApplication.shared.applicationState == .active, "the test host is not in the foreground")
    }

    override func tearDown() async throws {
        if window.rootViewController?.presentedViewController != nil {
            await withCheckedContinuation { c in window.rootViewController?.dismiss(animated: false) { c.resume() } }
        }
        UIResponder.rexCurrentFirstResponder()?.resignFirstResponder()
        let scratch = UITextField()
        window.addSubview(scratch)
        scratch.becomeFirstResponder()
        scratch.resignFirstResponder()
        scratch.removeFromSuperview()
        for v in window.rootViewController?.view.subviews ?? [] {
            (v as? TerminalHost)?.stop()
            v.removeFromSuperview()
        }
        keep = []
        window.isHidden = true
        window = nil
        let gone = await eventually(3) { GhosttyRenderThread.shared.paneCount == 0 }
        XCTAssertTrue(gone, "LEAKCHECK \(name): \(GhosttyRenderThread.shared.paneCount) panes left")
        // And their engines, which a sheet that just went can hold a moment longer: a test that
        // counts live terminals must not see one of these go.
        let before = terminalsBefore
        let freed = await eventually(5) { GhosttyCore.liveTerminals.load(ordering: .relaxed) <= before }
        XCTAssertTrue(freed, "LEAKCHECK \(name): \(GhosttyCore.liveTerminals.load(ordering: .relaxed) - before) terminals left")
    }

    private func eventually(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func makeHost() -> (TerminalHost, PaneFiles) {
        let name = "BrowserKeyboardTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let prefs = Prefs(defaults: d)
        let model = AppModel(prefs: prefs, connect: false)
        let server = ServerConnection(config: ServerConfig(name: "studio", url: "http://127.0.0.1:1"), prefs: prefs,
                                      notifier: model.notifier, deviceID: "a1b2c3d4")
        server.capabilities.record(method: FileMethod.listDir.full, host: nil, .present, serial: server.capabilities.serial)
        var meta = BlockMeta()
        meta.foreground = "zsh"
        server.meta["block:b"] = meta
        let host = TerminalHost(stream: TerminalStream(control: server.control, sessionID: "session:s", blockID: "block:b"),
                                sizing: .mirror, fontSize: 12, theme: ThemeStore.fallback, claim: nil)
        host.hardwareKeyboard = { [unowned self] in self.hardware }
        host.keymap = KeymapStore(control: server.control)
        host.frame = CGRect(x: 0, y: 0, width: 360, height: 500)
        window.rootViewController?.view.addSubview(host)
        let files = PaneFiles(server: server, sessionID: "session:s", blockID: "block:b")
        host.files = files
        host.isActive = true
        keep.append(model)
        return (host, files)
    }

    /// Opens the browser, lets the sheet settle, closes it as Done does, and waits until it is gone.
    private func openAndClose(_ files: PaneFiles, _ mode: BrowserModel.Mode = .browse, insert: String? = nil) async throws {
        XCTAssertTrue(files.browse(mode))
        let up = await eventually { self.window.rootViewController?.presentedViewController != nil && files.browserModel != nil }
        XCTAssertTrue(up)
        try? await Task.sleep(nanoseconds: 700_000_000)
        if let insert { files.browserModel?.onInsert(insert) } else { files.browserModel?.onClose() }
        let gone = await eventually(5) { files.browser == nil && self.window.rootViewController?.presentedViewController == nil }
        XCTAssertTrue(gone, "the sheet went")
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    func testTheKeyboardGoesBackToTheTerminalThatShowedIt() async throws {
        hardware = false
        let (host, files) = makeHost()
        host.focusKeyboard()
        try XCTSkipUnless(host.term.isFirstResponder, "the test host gave no first responder")
        XCTAssertEqual(KeyboardRecord.capture(host), .shown)
        try await openAndClose(files)
        let back = await eventually { KeyboardRecord.capture(host) == .shown }
        XCTAssertTrue(back, "\(KeyboardRecord.capture(host))")
    }

    func testAQuietKeyboardComesBackQuiet() async throws {
        hardware = true
        let (host, files) = makeHost()
        host.focusKeyboard()
        try XCTSkipUnless(host.term.isFirstResponder, "the test host gave no first responder")
        host.setKeyboardQuiet(true)
        XCTAssertEqual(KeyboardRecord.capture(host), .quiet)
        try await openAndClose(files)
        let back = await eventually { KeyboardRecord.capture(host) == .quiet }
        XCTAssertTrue(back, "\(KeyboardRecord.capture(host))")
    }

    func testAPaneWithNoKeyboardGetsNone() async throws {
        hardware = false
        let (host, files) = makeHost()
        XCTAssertEqual(KeyboardRecord.capture(host), .none)
        try await openAndClose(files)
        XCTAssertEqual(KeyboardRecord.capture(host), .none)
        XCTAssertFalse(host.term.isFirstResponder)
    }

    func testTheFindFieldGetsTheKeyboardBack() async throws {
        hardware = false
        let (host, files) = makeHost()
        host.focusKeyboard()
        try XCTSkipUnless(host.term.isFirstResponder, "the test host gave no first responder")
        host.openFind(text: "", focus: true)
        let held = await eventually { host.findFieldHoldingKeyboard != nil }
        try XCTSkipUnless(held, "the find field took no keyboard here")
        let before = KeyboardRecord.capture(host)
        guard case .ownFindField = before else { return XCTFail("\(before)") }
        try await openAndClose(files)
        let back = await eventually { KeyboardRecord.capture(host) == before }
        XCTAssertTrue(back, "\(KeyboardRecord.capture(host)) for \(before)")
        XCTAssertTrue(host.findOpen)
        host.closeFind()
    }

    /// Once the cover's own hand-back has run, the browser's is a no-op: the responder that holds
    /// the keyboard is not asked again, so the keyboard moves once.
    func testTheHandBackAfterTheCoversIsANoOp() async throws {
        hardware = false
        let (host, _) = makeHost()
        host.focusKeyboard()
        try XCTSkipUnless(host.term.isFirstResponder, "the test host gave no first responder")
        var changes = 0
        let watch = NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { changes += 1 }
        }
        defer { NotificationCenter.default.removeObserver(watch) }
        let record = KeyboardRecord.capture(host)
        host.coverChanged(covered: true)
        host.coverChanged(covered: false)
        let back = await eventually { host.term.isFirstResponder }
        XCTAssertTrue(back)
        try? await Task.sleep(nanoseconds: 300_000_000)
        let afterCover = changes
        host.retakeKeyboard(record)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(changes, afterCover, "no second keyboard move")
        XCTAssertEqual(KeyboardRecord.capture(host), record)
    }

    /// The edit menu: Paste Image right after Paste, only with an image on the clipboard and a
    /// host that takes uploads; beside text too, where Paste still pastes the text.
    func testTheEditMenuOffersPasteImageOnlyWithAnImageAndUploads() {
        let (host, files) = makeHost()
        let board = UIPasteboard.general
        defer { board.items = [] }
        func pasteRows() -> [String] {
            let menu = host.editMenuInteraction(UIEditMenuInteraction(delegate: nil),
                                                menuFor: UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero),
                                                suggestedActions: [])
            return (menu?.children.compactMap { ($0 as? UIAction)?.title } ?? []).filter { $0.hasPrefix("Paste") }
        }
        let png = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4)).pngData { $0.fill(CGRect(x: 0, y: 0, width: 4, height: 4)) }
        board.items = [["public.png": png]]
        XCTAssertEqual(pasteRows(), [], "a host without uploads: neither row, as before")
        files.server.capabilities.record(method: FileMethod.upload.full, host: nil, .present, serial: files.server.capabilities.serial)
        XCTAssertEqual(pasteRows(), ["Paste", "Paste Image"])
        board.items = [["public.png": png, "public.utf8-plain-text": "https://example.com/a.png"]]
        XCTAssertEqual(pasteRows(), ["Paste", "Paste Image"])
        XCTAssertEqual(files.pasteChoice, .text, "Paste keeps pasting the text")
        board.items = [["public.utf8-plain-text": "hello"]]
        XCTAssertEqual(pasteRows(), ["Paste"])
    }

    func testInsertModeWritesThePathIntoThePaneAfterTheSheetGoes() async throws {
        hardware = true
        let (host, files) = makeHost()
        var written: [String] = []
        files.insertText = { written.append($0) }
        host.focusKeyboard()
        try await openAndClose(files, .insert, insert: "/srv/data/my file.txt")
        let done = await eventually { !written.isEmpty }
        XCTAssertTrue(done)
        XCTAssertEqual(written, ["/srv/data/my\\ file.txt "])
    }
}
