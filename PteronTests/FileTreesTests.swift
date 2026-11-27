import GlanceModel
import UniformTypeIdentifiers
import XCTest
import RexKit
@testable import Pteron

/// Folders and several items in one stream: which sends go through an fs block, where the
/// computer has one, the fs blocks' making, closing and sweep, and the paths written after.
@MainActor
final class FileTreesTests: XCTestCase {
    // MARK: Route

    func testASingleFileGoesAsBeforeAndTheRestAsOneArchive() {
        XCTAssertEqual(SendRoute.pick(count: 1, folders: false, largest: 5_000_000, trees: true), .files)
        XCTAssertEqual(SendRoute.pick(count: 2, folders: false, largest: 10, trees: true), .tree)
        XCTAssertEqual(SendRoute.pick(count: 1, folders: true, largest: 0, trees: true), .tree)
        XCTAssertEqual(SendRoute.pick(count: 1, folders: false, largest: FileUploader.maxFileSize + 1, trees: true), .tree)
        // Without an fs block everything goes as it always has.
        XCTAssertEqual(SendRoute.pick(count: 5, folders: true, largest: 0, trees: false), .files)
    }

    func testWhatSaysItemsWhenAFolderIsAmongThem() {
        XCTAssertEqual(SendTarget.what(["Logs"], folders: true), "Logs")
        XCTAssertEqual(SendTarget.what(["Logs", "a.txt"], folders: true), "2 items")
        XCTAssertEqual(SendTarget.what(["b.txt", "a.txt"]), "2 files")
    }

    func testAFolderIsReadAsOneOnlyWhereFoldersGo() {
        XCTAssertEqual(FileItemType.pick([.folder], fileBacked: true, folders: true), .folder)
        XCTAssertNil(FileItemType.pick([.folder], fileBacked: true, folders: false))
        XCTAssertEqual(FileItemType.pick([.png], fileBacked: true, folders: true), .png)
        XCTAssertTrue(DropRule.types(folders: true).contains(.folder))
        XCTAssertFalse(DropRule.types(folders: false).contains(.folder))
    }

    func testTheLandingFolderIsNewEachTime() {
        let a = FileSender.landingName(), b = FileSender.landingName()
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(a.hasPrefix("pteron-"))
        XCTAssertEqual(a.count, "pteron-".count + 12)
    }

    // MARK: Gating

    private func server(platform: String? = "darwin_arm64", fs: [String]? = ["upload_begin", "download_begin"],
                        host: String = "host-a") -> ServerConnection {
        let name = "FileTreesTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let prefs = Prefs(defaults: d)
        let model = AppModel(prefs: prefs, connect: false)
        let s = ServerConnection(config: ServerConfig(name: "studio", url: "http://127.0.0.1:1"), prefs: prefs,
                                 notifier: model.notifier, deviceID: "a1b2c3d4")
        s.platform = platform
        s.capabilities.status(instance: "i", hostID: "host-a")
        var creators: [JSONObject] = [["name": "com.superlogical.terminal", "host_id": "host-a",
                                       "flavors": [["flavor": "com.superlogical.terminal.shell"]]]]
        if let fs {
            creators.append(["name": FsBlock.creator, "host_id": host, "flavors": [["flavor": FsBlock.flavor]],
                             "api": ["methods": Dictionary(uniqueKeysWithValues: fs.map { ($0, [:] as JSONObject) })] as JSONObject])
        }
        s.capabilities.creatorsLoaded(["creators": creators], serial: s.capabilities.serial)
        return s
    }

    private let local = BlockInfo(["block_id": "block:1", "creator_name": "com.superlogical.terminal", "host_id": "host-a"])
    private let remote = BlockInfo(["block_id": "block:2", "creator_name": "com.superlogical.terminal", "host_id": "host-b"])

    func testFoldersGoWhereTheCreatorListNamesTheFsBlock() {
        let s = server()
        XCTAssertTrue(s.takesTrees("upload_begin", block: local))
        XCTAssertTrue(s.takesTrees("download_begin", block: local))
        // A pane on another host: the fs block would be made on the wrong computer.
        XCTAssertFalse(s.takesTrees("upload_begin", block: remote))
        XCTAssertFalse(s.takesTrees("upload_begin", block: nil))
    }

    func testOlderComputersAndWindowsKeepTodaysBehavior() {
        XCTAssertFalse(server(fs: nil).takesTrees("upload_begin", block: local), "no fs creator (revision 19 and older)")
        XCTAssertFalse(server(fs: ["download_begin"]).takesTrees("upload_begin", block: local))
        XCTAssertTrue(server(fs: ["download_begin"]).takesTrees("download_begin", block: local))
        XCTAssertFalse(server(fs: ["upload_begin"], host: "host-b").takesTrees("upload_begin", block: local), "fs on another host only")
        XCTAssertFalse(server(platform: "windows_amd64").takesTrees("upload_begin", block: local))
        XCTAssertFalse(server(platform: nil).takesTrees("upload_begin", block: local), "not known yet")
    }

    // MARK: The fs blocks

    private func keeper() -> (TreeBlocks, TunnelLedger) {
        let name = "FileTreesTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let ledger = TunnelLedger(defaults: d, key: "fsBlocks")
        return (TreeBlocks(tag: { "a1b2c3d4" }, ledger: ledger), ledger)
    }

    func testABlockIsMadeForTheTransferAndClosedAfter() async throws {
        let (k, ledger) = keeper()
        let fake = FakeTunnelServer()
        var inside: String?
        var rememberedDuring: [String] = []
        let v = try await k.with(fake, session: "session:1") { bid in
            inside = bid
            rememberedDuring = ledger.blocks(server: fake.id, session: "session:1")
            return 7
        }
        XCTAssertEqual(v, 7)
        XCTAssertEqual(inside, "block:t1")
        XCTAssertEqual(rememberedDuring, ["block:t1"])
        XCTAssertEqual(fake.calls, ["session.new_block session:1", "block.close block:t1"])
        XCTAssertEqual(fake.blocks.first?.str("flavor"), FsBlock.flavor)
        XCTAssertEqual(fake.blocks.first?.str("label"), "\(Brand.appName) #a1b2c3d4")
        XCTAssertEqual(ledger.blocks(server: fake.id, session: "session:1"), [])
        XCTAssertTrue(k.owns("block:t1", server: fake.id, session: "session:1"), "its late events change no view")
    }

    func testTheBlockClosesWhenTheTransferFails() async {
        let (k, ledger) = keeper()
        let fake = FakeTunnelServer()
        do {
            _ = try await k.with(fake, session: "session:1") { _ -> Int in throw FsUploader.Failure.lost("x") }
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? FsUploader.Failure, .lost("x"))
        }
        XCTAssertEqual(fake.calls.last, "block.close block:t1")
        XCTAssertEqual(ledger.blocks(server: fake.id, session: "session:1"), [])
    }

    func testAComputerWithoutTheFlavorSaysSoAndNothingIsLeft() async {
        let (k, ledger) = keeper()
        let fake = FakeTunnelServer()
        fake.newBlockError = RexError(code: "not_found", message: "no flavor", status: 404)
        do {
            _ = try await k.with(fake, session: "session:1") { _ in 1 }
            XCTFail("should throw")
        } catch {
            XCTAssertEqual((error as? RexError)?.code, "not_found")
        }
        XCTAssertEqual(ledger.sessions(server: fake.id), [])
    }

    func testTheSweepClosesOnlyThisPhonesLeftoverFsBlocks() async {
        let (k, ledger) = keeper()
        let fake = FakeTunnelServer()
        ledger.remember(server: fake.id, session: "session:1", block: "block:old")
        fake.blocks = [
            ["block_id": "block:old", "flavor": FsBlock.flavor, "label": "\(Brand.appName) #a1b2c3d4"],
            ["block_id": "block:other-phone", "flavor": FsBlock.flavor, "label": "\(Brand.appName) #99999999"],
            ["block_id": "block:tunnel", "flavor": "com.superlogical.tunnel.dial", "label": "\(Brand.appName) #a1b2c3d4"],
            ["block_id": "block:shell", "flavor": "com.superlogical.terminal.shell", "label": "shell"],
        ]
        k.serverSynced(fake)
        for _ in 0..<100 where ledger.sessions(server: fake.id) != [] { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(fake.calls.contains("inOrder block.close block:old"), "\(fake.calls)")
        XCTAssertFalse(fake.calls.contains { $0.contains("other-phone") || $0.contains("tunnel") || $0.contains("shell") && $0.contains("close") })
        XCTAssertEqual(ledger.sessions(server: fake.id), [])
    }

    // MARK: After the send

    private func pane(foreground: String?) -> (PaneFiles, () -> [String]) {
        let s = server()
        var meta = BlockMeta()
        meta.foreground = foreground
        s.meta["block:b"] = meta
        let files = PaneFiles(server: s, sessionID: "session:s", blockID: "block:b")
        final class Written { var texts: [String] = [] }
        let w = Written()
        files.insertText = { w.texts.append($0) }
        return (files, { w.texts })
    }

    func testAShellGetsThePathsEscapedAndNothingElse() {
        let (files, written) = pane(foreground: "zsh")
        files.insertSent(["/private/tmp/pteron-1/My Logs", "/private/tmp/pteron-1/a&b.txt"], done: "Sent 2 items to studio")
        XCTAssertEqual(written(), ["/private/tmp/pteron-1/My\\ Logs /private/tmp/pteron-1/a\\&b.txt "])
        XCTAssertEqual(Notice.shared.message, "Sent 2 items to studio")
    }

    func testAnAgentGetsThePathsAsTheyAre() {
        let (files, written) = pane(foreground: "claude")
        files.insertSent(["/private/tmp/pteron-1/My Logs"], done: "Sent My Logs to Claude")
        XCTAssertEqual(written(), ["/private/tmp/pteron-1/My Logs "])
    }

    func testBehindSshNothingIsTypedAndThePathCanBeCopied() {
        let (files, written) = pane(foreground: "ssh")
        files.insertSent(["/private/tmp/pteron-1/Logs"], done: "Sent Logs to studio")
        XCTAssertEqual(written(), [])
        XCTAssertEqual(Notice.shared.message, "Sent Logs to studio.")
        XCTAssertEqual(Notice.shared.actionTitle, "Copy Path")
    }
}
