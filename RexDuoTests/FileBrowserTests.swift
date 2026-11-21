import Foundation
import SwiftUI
import Testing
import RexKit
@testable import RexDuo

/// A stand-in for the pane's computer: folders by path, with what each call asked.
@MainActor
final class StandInFolders: DirSource {
    var pages: [String: DirPage] = [:]
    var failure: DirFailure?
    private(set) var asked: [(path: String, prefix: String, limit: Int)] = []
    /// Calls wait here until `release()` when set.
    var hold = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func list(path: String, prefix: String, limit: Int) async throws -> DirPage {
        asked.append((path, prefix, limit))
        if hold { await withCheckedContinuation { waiting.append($0) } }
        if let failure { throw failure }
        guard var page = pages[path] else { return DirPage(path: path, status: .missing) }
        if !prefix.isEmpty {
            page.entries = page.entries.filter { $0.name.lowercased().hasPrefix(prefix.lowercased()) }
            page.truncated = false
        } else if page.entries.count > limit {
            page.entries = Array(page.entries.prefix(limit))
            page.truncated = true
        }
        return page
    }

    func release() {
        let w = waiting
        waiting = []
        for c in w { c.resume() }
    }

    nonisolated static func many(_ count: Int) -> [DirEntry] {
        (0..<count).map { DirEntry(name: $0 % 10 == 0 ? "dir-\($0)" : "file-\($0).txt", isFile: $0 % 10 != 0) }
    }
}

@MainActor
private func settled(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

struct DirListingTests {
    private func listing(_ names: [(String, Bool)], home: String = "/home/dev") -> DirListing {
        DirListing(DirPage(path: "/home/dev/project", home: home, entries: names.map { DirEntry(name: $0.0, isFile: $0.1) }))
    }

    @Test func foldersComeFirstThenNamesAsFinderOrdersThem() {
        let l = listing([("file10.txt", true), ("b", false), ("file2.txt", true), ("A", false), ("File3.txt", true), (".git", false)])
        #expect(l.visible(showHidden: true, query: "").map(\.name) == [".git", "A", "b", "file2.txt", "File3.txt", "file10.txt"])
    }

    @Test func hiddenEntriesShowOnlyWhenAskedFor() {
        let l = listing([(".env", true), ("a.txt", true), (".cache", false), ("src", false)])
        #expect(l.visible(showHidden: false, query: "").map(\.name) == ["src", "a.txt"])
        #expect(l.visible(showHidden: true, query: "").map(\.name) == [".cache", "src", ".env", "a.txt"])
        // A filter that starts with a dot is asking for them.
        #expect(l.visible(showHidden: false, query: ".e").map(\.name) == [".env"])
        #expect(l.visible(showHidden: false, query: "c").map(\.name) == ["src"])
    }

    @Test func theFilterMatchesAnywhereWhateverTheCase() {
        let l = listing([("README.md", true), ("readme-old.txt", true), ("src", false), ("Thread.swift", true)])
        #expect(Set(l.visible(showHidden: false, query: "READ").map(\.name)) == ["README.md", "readme-old.txt", "Thread.swift"])
        #expect(l.visible(showHidden: false, query: "zzz").isEmpty)
        // A path in the field is somewhere to go, not a filter.
        #expect(l.visible(showHidden: false, query: "/etc").count == 4)
        #expect(l.visible(showHidden: false, query: "~/x").count == 4)
    }

    @Test func twoSpellingsOfOneNameKeepOneOrder() {
        let a = listing([("cafe\u{301}", true), ("caf\u{E9}", true)]).visible(showHidden: false, query: "")
        let b = listing([("caf\u{E9}", true), ("cafe\u{301}", true)]).visible(showHidden: false, query: "")
        #expect(a.map { Array($0.name.unicodeScalars) } == b.map { Array($0.name.unicodeScalars) })
        #expect(a.count == 2)
    }

    @Test func pathsJoinWalkUpAndShowHome() {
        #expect(DirPath.join("/a", "b") == "/a/b")
        #expect(DirPath.join("/", "b") == "/b")
        #expect(DirPath.parent("/") == nil)
        #expect(DirPath.parent("/a") == "/")
        #expect(DirPath.parent("/a/b") == "/a")
        #expect(DirPath.parents("/") == [])
        #expect(DirPath.parents("/a/b") == ["/a", "/"])
        #expect(DirPath.parents("/home/dev/x") == ["/home/dev", "/home", "/"])
        #expect(DirPath.name("/") == "/")
        #expect(DirPath.name("/a/b c") == "b c")
        #expect(DirPath.display("/home/dev/x", home: "/home/dev") == "~/x")
        #expect(DirPath.display("/home/dev", home: "/home/dev") == "~")
        #expect(DirPath.display("/home/developer", home: "/home/dev") == "/home/developer")
        #expect(DirPath.display("/etc", home: "/home/dev") == "/etc")
        #expect(DirPath.display("/home/dev/x", home: "") == "/home/dev/x")
        #expect(DirPath.isPath("/etc") && DirPath.isPath("~/x") && DirPath.isPath("~") && !DirPath.isPath("etc") && !DirPath.isPath(""))
    }

    @Test func rowsGetASymbolByKind() {
        #expect(FileGlyph.symbol(for: DirEntry(name: "src")) == "folder.fill")
        #expect(FileGlyph.symbol(for: DirEntry(name: "a.PNG", isFile: true)) == "photo")
        #expect(FileGlyph.symbol(for: DirEntry(name: "clip.mov", isFile: true)) == "film")
        #expect(FileGlyph.symbol(for: DirEntry(name: "paper.pdf", isFile: true)) == "doc.richtext")
        #expect(FileGlyph.symbol(for: DirEntry(name: "x.tar", isFile: true)) == "archivebox")
        #expect(FileGlyph.symbol(for: DirEntry(name: "main.swift", isFile: true)) == "doc.text")
        #expect(FileGlyph.symbol(for: DirEntry(name: "Makefile", isFile: true)) == "doc")
        #expect(BrowserCopy.rowLabel(DirEntry(name: "src")) == "src, folder")
        #expect(BrowserCopy.rowLabel(DirEntry(name: "latest", isSymlink: true)) == "latest, folder, link")
        #expect(BrowserCopy.rowLabel(DirEntry(name: "a.txt", isFile: true)) == "a.txt")
    }

    /// Ten thousand entries: built and filtered within a frame's worth of work several times
    /// over, and never on the main actor (`FolderModel`).
    @Test func aLargeFolderIsSortedAndFilteredQuickly() {
        let page = DirPage(path: "/big", entries: StandInFolders.many(10_000).shuffled())
        let clock = ContinuousClock()
        var listing: DirListing?
        let build = clock.measure { listing = DirListing(page) }
        var hits = 0
        let filter = clock.measure { hits = listing?.visible(showHidden: false, query: "file-99").count ?? 0 }
        #expect(listing?.items.count == 10_000)
        #expect(listing?.items.first?.entry.name == "dir-0")
        #expect(hits == 100)
        print("DIRLISTING_10000 build \(build) filter \(filter)")
        #expect(build < .seconds(2))
        #expect(filter < .milliseconds(250))
    }
}

@MainActor
struct FolderModelTests {
    private func source() -> StandInFolders {
        let s = StandInFolders()
        s.pages["/home/dev/project"] = DirPage(path: "/home/dev/project", home: "/home/dev", entries: [
            DirEntry(name: "src"), DirEntry(name: ".git"), DirEntry(name: "README.md", isFile: true),
            DirEntry(name: "my file.txt", isFile: true), DirEntry(name: "-x", isFile: true), DirEntry(name: "latest", isSymlink: true),
        ])
        s.pages[""] = s.pages["/home/dev/project"]
        s.pages["/home/dev/project/src"] = DirPage(path: "/home/dev/project/src", home: "/home/dev", entries: [DirEntry(name: "main.rs", isFile: true)])
        s.pages["/home/dev/project/empty"] = DirPage(path: "/home/dev/project/empty", home: "/home/dev")
        s.pages["~"] = DirPage(path: "/home/dev", home: "/home/dev", entries: [DirEntry(name: "project")])
        s.pages["/home/dev"] = s.pages["~"]
        s.pages["/root"] = DirPage(path: "/root", home: "/home/dev", status: .denied)
        s.pages["/new"] = DirPage(path: "/new", home: "/home/dev", status: .other("quarantined"))
        return s
    }

    @Test func aFolderListsSortedWithHiddenEntriesOut() async {
        let s = source()
        let f = FolderModel(asked: "", source: s)
        #expect(f.phase == .loading)
        await f.load()
        #expect(await settled { f.rows.count == 5 })
        #expect(f.phase == .listed)
        #expect(f.path == "/home/dev/project")
        #expect(f.home == "/home/dev")
        #expect(f.rows.map(\.name) == ["latest", "src", "-x", "my file.txt", "README.md"])
        #expect(s.asked.count == 1 && s.asked[0].path == "" && s.asked[0].prefix == "" && s.asked[0].limit == 2000)
        f.showHidden = true
        #expect(await settled { f.rows.first?.name == ".git" })
        f.query = "read"
        #expect(await settled { f.rows.map(\.name) == ["README.md"] })
        #expect(s.asked.count == 1, "a whole listing is filtered here, not on the server")
    }

    @Test func anEmptyFolderAndTheProblemsAreToldApart() async {
        let s = source()
        let empty = FolderModel(asked: "/home/dev/project/empty", source: s)
        await empty.load()
        #expect(empty.isEmpty && empty.received == 0)
        for (path, problem) in [("/root", FolderModel.Problem.denied), ("/nowhere", .gone), ("/new", .unreadable)] {
            let f = FolderModel(asked: path, source: s)
            await f.load()
            #expect(f.phase == .failed(problem), "\(path)")
            #expect(f.path == path)
            #expect(!f.hasListing)
        }
        for (failure, problem) in [(DirFailure.lost("x"), FolderModel.Problem.lost), (.unsupported, .unsupported), (.refused("no"), .refused("no"))] {
            s.failure = failure
            let f = FolderModel(asked: "/home/dev/project", source: s)
            await f.load()
            #expect(f.phase == .failed(problem))
        }
    }

    @Test func aListingStaysToReadWhenTheServerStopsListing() async {
        let s = source()
        let f = FolderModel(asked: "/home/dev/project", source: s)
        await f.load()
        #expect(await settled { f.rows.count == 5 })
        s.failure = .unsupported
        await f.load()
        #expect(f.phase == .failed(.unsupported))
        #expect(f.hasListing && f.rows.count == 5)
        s.failure = .lost("gone")
        await f.load()
        #expect(f.phase == .failed(.lost) && f.rows.count == 5)
        s.failure = nil
        await f.load()
        #expect(f.phase == .listed)
    }

    @Test func aCutListingAsksTheServerForTheFilterAfterAPause() async {
        let s = source()
        s.pages["/big"] = DirPage(path: "/big", entries: StandInFolders.many(2500))
        let f = FolderModel(asked: "/big", source: s)
        await f.load()
        #expect(await settled { f.rows.count == 2000 })
        #expect(f.truncated && f.received == 2000)
        #expect(BrowserCopy.truncated(f.received) == "Showing the first 2,000. Search to find others.")
        // Typed fast: one call, for the last text only.
        f.query = "f"
        f.query = "fi"
        f.query = "file-24"
        #expect(await settled { s.asked.count == 2 })
        #expect(s.asked[1].path == "/big" && s.asked[1].prefix == "file-24")
        // 2401…2499 are past the cut and came from the server; file-24, 241…249 were here already.
        #expect(await settled { f.rows.count == 100 })
        #expect(f.rows.contains { $0.name == "file-2499.txt" } && f.rows.contains { $0.name == "file-24.txt" })
        #expect(Set(f.rows.map(\.name)).count == f.rows.count)
        f.query = ""
        #expect(await settled { f.rows.count == 2000 })
        try? await Task.sleep(for: .milliseconds(400))
        #expect(s.asked.count == 2)
    }

    @Test func aLargeFolderNeverBlocksTheMainActor() async {
        let s = source()
        s.pages["/huge"] = DirPage(path: "/huge", entries: StandInFolders.many(10_000).shuffled())
        let f = FolderModel(asked: "/huge", source: s, limit: 10_000)
        // A heartbeat on the main actor while the folder loads and filters: its longest gap is the
        // longest the main actor was held.
        let beat = Task { @MainActor () -> Duration in
            let clock = ContinuousClock()
            var worst = Duration.zero, last = clock.now
            while !Task.isCancelled {
                await Task.yield()
                let now = clock.now
                worst = max(worst, now - last)
                last = now
            }
            return worst
        }
        await f.load()
        #expect(await settled { f.rows.count == 10_000 })
        for q in ["f", "fi", "fil", "file", "file-", "file-9"] { f.query = q }
        #expect(await settled { f.rows.count == 1000 && f.rows.allSatisfy { $0.name.hasPrefix("file-9") } })
        beat.cancel()
        let worst = await beat.value
        print("FOLDER_10000 worst main-actor gap \(worst)")
        #expect(worst < .milliseconds(12), "longest main-actor hold \(worst)")
    }

    @Test func anOvertakenLoadIsDropped() async {
        let s = source()
        let f = FolderModel(asked: "/home/dev/project", source: s)
        s.hold = true
        let first = Task { await f.load() }
        #expect(await settled { s.asked.count == 1 })
        s.pages["/home/dev/project"] = DirPage(path: "/home/dev/project", entries: [DirEntry(name: "newer")])
        let second = Task { await f.load() }
        #expect(await settled { s.asked.count == 2 })
        s.hold = false
        s.release()
        await first.value
        await second.value
        #expect(await settled { f.rows.map(\.name) == ["newer"] })
    }

    @Test func arrowKeysWalkTheRows() async {
        let f = FolderModel(asked: "/home/dev/project", source: source())
        await f.load()
        #expect(await settled { f.rows.count == 5 })
        #expect(f.selected == nil)
        f.move(1)
        #expect(f.selected?.name == "latest")
        f.move(1); f.move(1)
        #expect(f.selected?.name == "-x")
        f.move(10)
        #expect(f.selected?.name == "README.md")
        f.move(-10)
        #expect(f.selection == 0)
        f.query = "read"
        #expect(await settled { f.rows.count == 1 })
        #expect(f.selection == 0)
        #expect(BrowserKey.action(.upArrow, command: false) == .move(-1))
        #expect(BrowserKey.action(.downArrow, command: false) == .move(1))
        #expect(BrowserKey.action(.upArrow, command: true) == .parent)
        #expect(BrowserKey.action(.downArrow, command: true) == .open)
        #expect(BrowserKey.action(.return, command: false) == .activate)
        #expect(BrowserKey.action(.space, command: false) == .preview)
        #expect(BrowserKey.action(.escape, command: false) == .close)
        #expect(BrowserKey.action("a", command: false) == nil)
    }

    // MARK: The browser

    private func browser(_ s: StandInFolders, mode: BrowserModel.Mode = .browse, start: String = "",
                         facts: @escaping @MainActor () -> BrowserModel.Facts = { .init() }) -> BrowserModel {
        BrowserModel(mode: mode, machine: "studio", start: start, source: s, facts: facts)
    }

    @Test func itStartsInTheProgramsFolderAndKnowsItForRelativePaths() async {
        let s = source()
        let b = browser(s)
        await b.start()
        #expect(b.root.path == "/home/dev/project")
        #expect(b.cwd == "/home/dev/project")
        #expect(s.asked.map(\.path) == [""])
    }

    @Test func startedSomewhereElseItStillReadsTheProgramsFolder() async {
        let s = source()
        let b = browser(s, start: "/home/dev/project/src")
        await b.start()
        #expect(b.root.path == "/home/dev/project/src")
        #expect(b.cwd == "/home/dev/project")
        #expect(s.asked.contains { $0.path == "" && $0.limit == 1 })
    }

    @Test func aStartThatCantBeListedFallsBackToHome() async {
        let s = source()
        s.pages[""] = DirPage(path: "/gone/away", home: "/home/dev", status: .missing)
        let b = browser(s)
        await b.start()
        #expect(b.root.path == "/home/dev")
        #expect(b.root.phase == .listed)
        #expect(b.stack.isEmpty)
        #expect(b.cwd == "/gone/away")
    }

    @Test func foldersOpenByNameAndGoingUpGoesBackWhenItCan() async {
        let s = source()
        let b = browser(s)
        await b.start()
        b.open(DirEntry(name: "README.md", isFile: true), in: b.root)
        #expect(b.stack.isEmpty, "a file is not a folder to open")
        b.open(DirEntry(name: "src"), in: b.root)
        #expect(b.stack == ["/home/dev/project/src"])
        await b.current.load()
        #expect(b.current.path == "/home/dev/project/src")
        #expect(b.folder(for: "/home/dev/project/src") === b.current, "a folder keeps its listing while the browser is open")
        b.goUp()
        #expect(b.stack.isEmpty, "up from a folder entered from its parent is Back")
        b.goUp()
        #expect(b.stack == ["/home/dev"], "up from the first folder opens its parent")
    }

    @Test func aReconnectListsAgainOnlyWhereListingIsStillThere() async {
        let s = source()
        final class Now { var facts = BrowserModel.Facts() }
        let now = Now()
        let b = browser(s, facts: { now.facts })
        await b.start()
        s.failure = .lost("x")
        await b.refresh()
        #expect(b.root.phase == .failed(.lost))
        let before = s.asked.count
        // Back on a server without the method: nothing is sent, the listing stays.
        now.facts.canList = false
        await b.reconnected()
        #expect(s.asked.count == before)
        #expect(b.root.hasListing)
        // Back on one that has it: one more listing.
        now.facts.canList = true
        s.failure = nil
        await b.reconnected()
        #expect(s.asked.count == before + 1)
        #expect(b.root.phase == .listed)
        await b.reconnected()
        #expect(s.asked.count == before + 1, "a listed folder isn't asked for again")
    }

    @Test func showingHiddenFilesReachesEveryFolderAndIsRemembered() async {
        let s = source()
        let b = browser(s)
        var told: [Bool] = []
        b.onShowHidden = { told.append($0) }
        await b.start()
        let src = b.folder(for: "/home/dev/project/src")
        b.showHidden = true
        #expect(b.root.showHidden && src.showHidden && told == [true])
        #expect(b.folder(for: "/home/dev").showHidden, "a folder opened later starts with the choice")
    }

    @Test func theLinesSayWhatHappened() {
        #expect(BrowserCopy.problem(.denied, path: "/srv/x", home: "/home/dev", machine: "studio", mac: true)
            == "Rex on studio isn't allowed to read this folder.")
        #expect(BrowserCopy.problem(.denied, path: "/home/dev/Documents/tax", home: "/home/dev", machine: "studio", mac: true)
            == "Rex on studio isn't allowed to read this folder. Give Rex access in System Settings → Privacy & Security.")
        #expect(BrowserCopy.problem(.denied, path: "/home/dev/Documents", home: "/home/dev", machine: "studio", mac: false)
            == "Rex on studio isn't allowed to read this folder.")
        #expect(BrowserCopy.problem(.gone, path: "/x", home: "", machine: "studio", mac: false) == "This folder is gone.")
        #expect(BrowserCopy.problem(.unreadable, path: "/x", home: "", machine: "studio", mac: false) == "Couldn't read this folder.")
        #expect(BrowserCopy.problem(.lost, path: "/x", home: "", machine: "studio", mac: false) == "Couldn't reach studio.")
        #expect(BrowserCopy.problem(.unsupported, path: "/x", home: "", machine: "studio", mac: false) == "studio's Rex can't list folders.")
        #expect(BrowserCopy.elsewhere("ssh", computer: "studio") == "This pane is running ssh. These files are on studio.")
        #expect(BrowserCopy.elsewhere("tmux", computer: "Dev Box") == "This pane is running tmux. These files are on Dev Box.")
        #expect(BrowserCopy.elsewhere("ssh", computer: nil) == "This pane is running ssh. These files are on the computer.")
        #expect(BrowserCopy.elsewhere("ssh", computer: "") == "This pane is running ssh. These files are on the computer.")
        #expect(BrowserCopy.elsewhere("ssh", computer: "  ") == "This pane is running ssh. These files are on the computer.")
    }

    @Test func theCutListingsFooterGroupsThousands() {
        #expect(BrowserCopy.truncated(1312) == "Showing the first 1,312. Search to find others.")
        #expect(BrowserCopy.truncated(2000) == "Showing the first 2,000. Search to find others.")
        #expect(BrowserCopy.truncated(999) == "Showing the first 999. Search to find others.")
        #expect(BrowserCopy.truncated(0) == "Showing the first 0. Search to find others.")
        #expect(BrowserCopy.truncated(1_234_567) == "Showing the first 1,234,567. Search to find others.")
    }
}
