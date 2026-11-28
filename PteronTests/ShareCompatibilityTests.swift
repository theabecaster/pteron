import RexKit
import XCTest
@testable import Pteron

/// Share against a Rex server in this process at the revisions the app meets (docs/rex-protocol.md,
/// API revisions): All Output shows and reads at each, hides where the creator list lacks its two
/// methods, and a reconnect mid-read stops the read and leaves a Retry that reads again.
@MainActor
final class ShareCompatibilityTests: XCTestCase {
    typealias Rig = ServerEventsTests.Rig
    private static let terminal = ServerEventsTests.terminal

    override func tearDown() async throws {
        Notice.shared.dismiss()
        try await super.tearDown()
    }

    private static func creators(methods: [String]) -> JSONObject {
        var m: JSONObject = [:]
        for name in methods { m[name] = [:] as JSONObject }
        return ["creators": [[
            "name": terminal, "host_id": "host-a", "flavors": [["flavor": "\(terminal).shell"]],
            "api": ["events": ["bell": [:]] as JSONObject, "methods": m] as JSONObject,
        ] as JSONObject]]
    }

    private static let withShare = creators(methods: ["write", "format", "blob_read"])

    /// The two calls of a two-part output; older servers send no `eof`.
    private func script(_ rig: Rig, eof: Bool) {
        var first: JSONObject = ["content": "abc", "id": 4, "total": 6]
        var rest: JSONObject = ["id": 4, "data": "def", "total": 6]
        if eof {
            first["eof"] = false
            rest["eof"] = true
        }
        rig.fake.reply(OutputReader.format, first)
        rig.fake.reply(OutputReader.blobRead, rest)
    }

    func testEveryRevisionSharesAndReadsAllOutput() async throws {
        let cases: [(String, Int?, FakeRexServer.Reply, Bool)] = [
            ("0", nil, .error(code: "method_not_found", status: 404), false),
            ("13", 13, .error(code: "not_found", status: 404), false),
            ("16", 16, .result(Self.withShare), true),
            ("18", 18, .result(Self.withShare), true),
        ]
        for (name, revision, creators, eof) in cases {
            let rig = try await Rig(revision: revision, creators: creators)
            script(rig, eof: eof)
            await rig.connect()
            XCTAssertTrue(rig.server.sharesAllOutput(session: "session:1", block: "block:1a"), name)
            let reader = OutputReader()
            var out = ""
            reader.write = { out += $0 }
            try await rig.server.formatChunks("session:1", "block:1a", form: .text, reader: reader)
            XCTAssertEqual(out, "abcdef", name)
            let args = rig.fake.requests.first { $0.method == OutputReader.format }?.payload.obj("args")
            XCTAssertEqual(args?.str("format"), "text", name)
            XCTAssertEqual(rig.fake.count(OutputReader.blobRead), 1, name)
            rig.stop()
        }
    }

    func testACreatorListWithoutTheMethodsHidesOnlyAllOutput() async throws {
        for methods in [["write", "blob_read"], ["write", "format"], ["write"]] {
            let rig = try await Rig(revision: 18, creators: .result(Self.creators(methods: methods)))
            await rig.connect()
            XCTAssertFalse(rig.server.sharesAllOutput(session: "session:1", block: "block:1a"), "\(methods)")
            XCTAssertEqual(rig.fake.count(OutputReader.format), 0, "no probe call")
            rig.stop()
        }
    }

    func testAReconnectMidReadStopsTheReadAndRetryReadsAgain() async throws {
        for (revision, eof) in [(13, false), (18, true)] {
            let rig = try await Rig(revision: revision, creators: .result(Self.withShare))
            script(rig, eof: eof)
            await rig.connect()
            let serial = rig.server.connectionSerial
            rig.fake.delay(OutputReader.blobRead, seconds: 2)
            let pane = PaneShare(server: rig.server, sessionID: "session:1", blockID: "block:1a")
            let share = OutputShare(pane: pane, styled: false, anchor: .titleBar)
            var presented = false
            share.present = { _, folder in
                presented = true
                if let folder { FileStaging.remove(folder) }
            }
            share.start()
            _ = await eventually { rig.fake.count(OutputReader.blobRead) == 1 }
            let folder = try XCTUnwrap(share.folder)
            rig.fake.dropAll()
            await share.task?.value
            XCTAssertFalse(presented, "revision \(revision): no partial file is shared")
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
            XCTAssertFalse(Notice.shared.jobRunning)
            XCTAssertEqual(Notice.shared.message, "Couldn't read the output.")
            XCTAssertEqual(Notice.shared.actionTitle, "Try Again")

            // Retry: a fresh `format` on the new connection.
            _ = await eventually(8) { rig.server.connectionSerial > serial && rig.server.phase == .online }
            await rig.settle(keymapLoads: 2)
            rig.fake.delay(OutputReader.blobRead, seconds: 0)
            let formats = rig.fake.count(OutputReader.format)
            Notice.shared.runAction()
            _ = await eventually(5) { rig.fake.count(OutputReader.format) == formats + 1 && rig.fake.count(OutputReader.blobRead) >= 2 }
            XCTAssertEqual(rig.fake.count(OutputReader.format), formats + 1, "revision \(revision)")
            _ = await eventually { !Notice.shared.jobRunning }
            XCTAssertFalse(Notice.shared.jobRunning)
            rig.stop()
        }
    }

    func testADropWithTypedInputOnItsWayEndsTheReadPromptly() async throws {
        let rig = try await Rig(revision: 18, creators: .result(Self.withShare))
        script(rig, eof: true)
        await rig.connect()
        rig.fake.delay("com.superlogical.terminal.write", seconds: 30)
        let stream = TerminalStream(control: rig.server.control, sessionID: "session:1", blockID: "block:1a")
        stream.send(text: "x")
        XCTAssertTrue(rig.server.control.inputActivity.busy)
        let reader = OutputReader()
        var failure: OutputReadFailure?
        let task = Task { @MainActor in
            do { try await rig.server.formatChunks("session:1", "block:1a", form: .text, reader: reader) } catch { failure = error as? OutputReadFailure }
        }
        _ = await eventually(0.5) { false }
        XCTAssertEqual(rig.fake.count(OutputReader.format), 0, "the read waits for the keystroke")
        let dropped = Date()
        rig.fake.dropAll()
        await task.value
        XCTAssertLessThan(Date().timeIntervalSince(dropped), 3)
        XCTAssertEqual(failure, .connection)
        stream.stop()
        rig.stop()
    }

    /// The notice change share brought, seen from a file send: its progress no longer replaces a
    /// plain notice that is up. It shows once that notice hides, and the send ends as before.
    func testAFileSendsProgressWaitsForAPlainNotice() async throws {
        let rig = try await Rig(revision: 18, creators: .result(Self.withShare))
        await rig.connect()
        let notice = Notice.shared
        let plain = notice.plainSeconds
        notice.plainSeconds = 0.4
        defer { notice.plainSeconds = plain }
        // The server has no uploads (`method_not_found`), and says so a second late.
        rig.fake.delay("com.superlogical.terminal.upload_begin", seconds: 1.2)
        let staged = try FileStaging.stage(data: Data("zz".utf8), as: "zz.txt")
        let sender = FileSender(control: rig.server.control, sessionID: "session:1", blockID: "block:1a")
        notice.show("Moved the pane.", style: .neutral)
        sender.send([staged], over: nil)
        _ = await eventually { rig.fake.count("com.superlogical.terminal.upload_begin") == 1 }
        XCTAssertEqual(notice.message, "Moved the pane.", "the plain notice stays up")
        XCTAssertNil(notice.progress)
        _ = await eventually { notice.progress != nil }
        XCTAssertEqual(notice.message?.hasPrefix("Sending zz.txt"), true, notice.message ?? "")
        XCTAssertEqual(notice.actionTitle, "Cancel")
        _ = await eventually(4) { !sender.busy }
        XCTAssertEqual(notice.message, "Update Rex on this computer to send files.")
        XCTAssertNil(notice.progress)
        rig.stop()
    }

    private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }
}
