import XCTest
@testable import RexKit

/// `list_dir` and the probe for the file methods, against a fake link.
@MainActor
final class DirListerTests: XCTestCase {
    private static let method = "com.superlogical.terminal.list_dir"

    private func lister(_ link: FakeLink) -> DirLister { DirLister(link: link, sessionID: "session:s", blockID: "block:b") }

    func testAListingKeepsFilesLinksAndTheServersOrder() async throws {
        let link = FakeLink()
        link.replies[Self.method] = [
            "path": "/home/dev/project", "home": "/home/dev", "status": "ok", "truncated": false,
            "entries": [["name": "src"], ["name": "notes.txt", "file": true], ["name": "latest", "symlink": true],
                        ["name": "log", "file": true, "symlink": true], ["name": ""], ["size": 3]] as [JSONObject],
            "added_later": ["x": 1],
        ]
        let page = try await lister(link).list(path: "")
        XCTAssertEqual(page.path, "/home/dev/project")
        XCTAssertEqual(page.home, "/home/dev")
        XCTAssertEqual(page.status, .ok)
        XCTAssertFalse(page.truncated)
        XCTAssertEqual(page.entries, [DirEntry(name: "src"), DirEntry(name: "notes.txt", isFile: true),
                                      DirEntry(name: "latest", isSymlink: true),
                                      DirEntry(name: "log", isFile: true, isSymlink: true)])
    }

    func testTheRequestAsksForFilesWithThePathPrefixAndLimit() async throws {
        let link = FakeLink()
        _ = try await lister(link).list(path: "~/x", prefix: "re", limit: 50)
        _ = try await lister(link).list(path: "")
        let first = link.calls[0].payload
        XCTAssertEqual(first.str("session_id"), "session:s")
        XCTAssertEqual(first.str("block_id"), "block:b")
        let a = first.obj("args") ?? [:]
        XCTAssertEqual(a.str("path"), "~/x")
        XCTAssertEqual(a.str("prefix"), "re")
        XCTAssertEqual(a.int("limit"), 50)
        XCTAssertEqual(a.bool("files"), true)
        let b = link.calls[1].payload.obj("args") ?? [:]
        XCTAssertEqual(b.str("path"), "")
        XCTAssertNil(b["prefix"])
        XCTAssertEqual(b.int("limit"), 2000)
        XCTAssertEqual(Set(b.keys), ["path", "limit", "files"])
    }

    func testNullEntriesAreAnEmptyFolder() async throws {
        let link = FakeLink()
        link.replies[Self.method] = ["path": "/srv/empty", "home": "", "status": "ok", "entries": NSNull(), "truncated": false]
        let page = try await lister(link).list(path: "/srv/empty")
        XCTAssertEqual(page.entries, [])
        XCTAssertEqual(page.status, .ok)
        XCTAssertEqual(page.home, "")
    }

    func testAFolderThatCantBeReadKeepsItsPath() async throws {
        let link = FakeLink()
        for (word, status) in [("missing", DirPage.Status.missing), ("not_dir", .notDir), ("denied", .denied),
                               ("quarantined", .other("quarantined"))] {
            link.replies[Self.method] = ["path": "/srv/data", "home": "/home/dev", "status": word, "entries": NSNull(), "truncated": false]
            let page = try await lister(link).list(path: "data")
            XCTAssertEqual(page.status, status, word)
            XCTAssertEqual(page.path, "/srv/data", word)
            XCTAssertTrue(page.entries.isEmpty, word)
        }
    }

    func testTruncatedIsPassedOn() async throws {
        let link = FakeLink()
        link.replies[Self.method] = ["path": "/big", "status": "ok", "entries": [["name": "a"]] as [JSONObject], "truncated": true]
        let page = try await lister(link).list(path: "/big")
        XCTAssertTrue(page.truncated)
        XCTAssertEqual(page.home, "")
    }

    func testFailuresAreToldApart() async {
        let link = FakeLink()
        func failure(_ e: Error) async -> DirFailure? {
            link.failures[Self.method] = [e]
            do { _ = try await lister(link).list(path: ""); return nil } catch { return error as? DirFailure }
        }
        let missing = await failure(RexError(code: "method_not_found", message: "no", status: 404))
        XCTAssertEqual(missing, .unsupported)
        let low = await failure(RexError(code: "revision_too_low", message: "no", status: 400))
        XCTAssertEqual(low, .unsupported)
        let lost = await failure(RexError.local("connection lost"))
        XCTAssertEqual(lost, .lost("connection lost"))
        let unsent = await failure(RexError.unsent("not connected"))
        XCTAssertEqual(unsent, .lost("not connected"))
        let refused = await failure(RexError(code: "not_found", message: "no such block", status: 404))
        XCTAssertEqual(refused, .refused("no such block"))
    }

    func testALargeListingIsReadWhole() async throws {
        let link = FakeLink()
        let entries: [JSONObject] = (0..<10_000).map { ["name": "file-\($0).txt", "file": true] }
        link.replies[Self.method] = ["path": "/big", "status": "ok", "entries": entries, "truncated": true]
        let page = try await lister(link).list(path: "/big", limit: 10_000)
        XCTAssertEqual(page.entries.count, 10_000)
        XCTAssertEqual(page.entries.last?.name, "file-9999.txt")
    }

    // MARK: Probe

    private func ask(_ m: FileMethod, _ link: FakeLink, remote: Bool = false) async -> Presence {
        await FileProbe.ask(m, link: link, sessionID: "s", blockID: "b", remote: remote)
    }

    func testEachMethodIsAskedOnItsOwn() async {
        let link = FakeLink()
        let bad = RexError(code: "bad_request", message: "ref is not a UUID", status: 400)
        link.failures[FileMethod.upload.full] = [RexError(code: "method_not_found", message: "no", status: 404)]
        link.failures[FileMethod.download.full] = [bad]
        let upload = await ask(.upload, link)
        let download = await ask(.download, link)
        let list = await ask(.listDir, link)
        XCTAssertEqual(upload, .absent)
        XCTAssertEqual(download, .present)
        XCTAssertEqual(list, .present, "a missing upload says nothing about list_dir")
        XCTAssertEqual(link.methods, FileMethod.allCases.map(\.full))
        XCTAssertTrue(link.sockets.isEmpty, "a probe reserves nothing")
    }

    func testTheListProbeReadsOneEntryOfTheRoot() async {
        let link = FakeLink()
        _ = await ask(.listDir, link)
        let a = link.calls[0].payload.obj("args") ?? [:]
        XCTAssertEqual(a.str("path"), "/")
        XCTAssertEqual(a.int("limit"), 1)
        XCTAssertNil(a["files"])
    }

    func testWhatARefusalSays() {
        func p(_ code: String, remote: Bool) -> Presence {
            FileProbe.presence(after: RexError(code: code, message: "m", status: 400), remote: remote)
        }
        for remote in [false, true] {
            XCTAssertEqual(p("method_not_found", remote: remote), .absent)
            XCTAssertEqual(p("revision_too_low", remote: remote), .absent)
            XCTAssertEqual(p("bad_request", remote: remote), .present)
            XCTAssertEqual(p("not_found", remote: remote), .unknown, "an older server's missing method, or a block that went")
            XCTAssertEqual(FileProbe.presence(after: RexError.unsent("not connected"), remote: remote), .unknown)
            XCTAssertEqual(FileProbe.presence(after: RexError.local("connection lost"), remote: remote), .unknown)
            XCTAssertEqual(FileProbe.presence(after: CancellationError(), remote: remote), .unknown)
        }
        XCTAssertEqual(p("unavailable", remote: true), .unknown, "a remote host's unknown error is no answer")
        XCTAssertEqual(p("unavailable", remote: false), .present)
    }
}
