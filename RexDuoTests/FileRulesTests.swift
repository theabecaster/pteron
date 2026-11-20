import XCTest
import RexKit
@testable import RexDuo

/// Sending files to a pane: names, where the menu says they go, and what Paste does.
final class FileRulesTests: XCTestCase {
    // MARK: Names

    func testANameIsOneComponentWithoutControlCharacters() {
        XCTAssertEqual(UploadName.sanitize("dir/sub/leaf.txt"), "leaf.txt")
        XCTAssertEqual(UploadName.sanitize("tab\there\u{7}.txt"), "tabhere.txt")
        XCTAssertEqual(UploadName.sanitize("evil\u{202E}txt.exe"), "eviltxt.exe", "no bidi override")
        XCTAssertEqual(UploadName.sanitize("  spaced name.png \n"), "spaced name.png")
        XCTAssertEqual(UploadName.sanitize("it's \"q\".txt"), "it's \"q\".txt", "the server quotes for the shell")
        XCTAssertEqual(UploadName.sanitize("-rf.txt"), "-rf.txt", "it is typed inside an absolute path")
    }

    func testJoinersStayAndInvisibleSpacesGo() {
        // Emoji sequences and Persian need the zero-width joiner and non-joiner.
        XCTAssertEqual(UploadName.sanitize("\u{1F469}\u{200D}\u{1F4BB}.png"), "\u{1F469}\u{200D}\u{1F4BB}.png")
        XCTAssertEqual(UploadName.sanitize("\u{0645}\u{06CC}\u{200C}\u{062E}.txt"), "\u{0645}\u{06CC}\u{200C}\u{062E}.txt")
        XCTAssertEqual(UploadName.sanitize("a\u{200B}b.txt"), "ab.txt")
        XCTAssertEqual(UploadName.sanitize("a\u{2066}b\u{2069}.txt"), "ab.txt")
        XCTAssertEqual(UploadName.sanitize("a\u{202A}b.txt"), "ab.txt")
    }

    func testAnEmptyOrDotNameFallsBack() {
        XCTAssertEqual(UploadName.sanitize(""), "File")
        XCTAssertEqual(UploadName.sanitize("/"), "File")
        XCTAssertEqual(UploadName.sanitize(".."), "File")
        XCTAssertEqual(UploadName.sanitize("\u{1}\u{2}"), "File")
    }

    func testNamesAreNFC() {
        let decomposed = "cafe\u{301}.png"
        XCTAssertEqual(UploadName.sanitize(decomposed).unicodeScalars.count, "café.png".unicodeScalars.count)
        XCTAssertEqual(UploadName.sanitize(decomposed), "caf\u{e9}.png")
    }

    func testALongNameIsCutKeepingItsExtension() {
        let long = String(repeating: "y", count: 300) + ".txt"
        let cut = UploadName.sanitize(long)
        XCTAssertEqual(cut.utf8.count, UploadName.maxBytes)
        XCTAssertTrue(cut.hasSuffix("y.txt"))
        // Never inside a character.
        let wide = String(repeating: "日", count: 100) + ".png"
        let w = UploadName.sanitize(wide)
        XCTAssertLessThanOrEqual(w.utf8.count, UploadName.maxBytes)
        XCTAssertTrue(w.hasSuffix("日.png"))
        // An "extension" that is most of the name isn't kept whole.
        let noExt = "a." + String(repeating: "z", count: 300)
        XCTAssertEqual(UploadName.sanitize(noExt).utf8.count, UploadName.maxBytes)
    }

    func testReadableNamesForPhotosAndPastedImages() {
        let d = Date(timeIntervalSince1970: 1_794_936_660)  // 2026-11-17 17:31 UTC
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(UploadName.stamped("Photo", at: d, ext: "jpg", timeZone: utc), "Photo 2026-11-17 17.31.jpg")
        XCTAssertEqual(UploadName.stamped("Pasted Image", at: d, ext: "png", timeZone: utc), "Pasted Image 2026-11-17 17.31.png")
        XCTAssertEqual(UploadName.withExtension("IMG_0001.HEIC", "jpg"), "IMG_0001.jpg")
        XCTAssertEqual(UploadName.withExtension("noext", "jpg"), "noext.jpg")
    }

    // MARK: Destination

    func testTheMenuNamesTheAgentElseTheMachine() {
        XCTAssertEqual(SendTarget.menuTitle(SendTarget.name(agent: .claude, machine: "studio")), "Send to Claude")
        XCTAssertEqual(SendTarget.menuTitle(SendTarget.name(agent: nil, machine: "studio")), "Send to studio")
        XCTAssertEqual(SendTarget.name(agent: nil, machine: "  "), "this computer")
        XCTAssertEqual(SendTarget.name(agent: nil, machine: nil), "this computer")
    }

    func testProgressAndDoneNameTheFilesAndWhereTheyGo() {
        XCTAssertEqual(SendTarget.progress(["a.png"], to: "Claude", fraction: 0.456), "Sending a.png to Claude · 45%")
        XCTAssertEqual(SendTarget.progress(["a", "b", "c"], to: "studio", fraction: 1.2), "Sending 3 files to studio · 100%")
        XCTAssertEqual(SendTarget.done(["a", "b"], to: "Codex"), "Sent 2 files to Codex")
        XCTAssertTrue(SendTarget.tooLarge("a.mov").hasPrefix("a.mov is too big. Rex takes files up to "))
    }

    // MARK: Clipboard

    func testTextAlwaysPastesAsText() {
        typealias C = ClipboardChoice
        // hasText, hasImage, hasFiles, canSend
        XCTAssertEqual(C.paste(hasText: true, hasImage: true, hasFiles: false, canSend: true), .text,
                       "an image copied from Safari also carries its address: text wins")
        XCTAssertEqual(C.paste(hasText: true, hasImage: false, hasFiles: false, canSend: false), .text)
        XCTAssertEqual(C.paste(hasText: false, hasImage: true, hasFiles: false, canSend: true), .image)
        XCTAssertEqual(C.paste(hasText: false, hasImage: true, hasFiles: true, canSend: true), .files)
        XCTAssertEqual(C.paste(hasText: true, hasImage: false, hasFiles: true, canSend: true), .text,
                       "copied files with a text form still paste as text; Paste File sends them")
        XCTAssertEqual(C.paste(hasText: false, hasImage: true, hasFiles: false, canSend: false), .nothing,
                       "a server that can't take files leaves Paste text-only")
        XCTAssertEqual(C.paste(hasText: false, hasImage: false, hasFiles: false, canSend: true), .nothing)
        XCTAssertTrue(C.offersPasteImage(hasImage: true, canSend: true))
        XCTAssertFalse(C.offersPasteImage(hasImage: true, canSend: false))
    }

    /// Paste Image beside Paste in the edit menu (and in both attach menus): only with an image or
    /// copied files and a host that takes uploads, and even beside text. Paste itself never changes.
    func testPasteImageShowsOnlyWithAnImageAndUploads() {
        typealias C = ClipboardChoice
        XCTAssertEqual(C.pasteFileTitle(hasImage: true, hasFiles: false, canSend: true), "Paste Image")
        XCTAssertEqual(C.pasteFileTitle(hasImage: true, hasFiles: true, canSend: true), "Paste File")
        XCTAssertEqual(C.pasteFileTitle(hasImage: false, hasFiles: true, canSend: true), "Paste File")
        XCTAssertNil(C.pasteFileTitle(hasImage: false, hasFiles: false, canSend: true), "text alone: no row")
        XCTAssertNil(C.pasteFileTitle(hasImage: true, hasFiles: false, canSend: false), "no uploads: no row")
        XCTAssertNil(C.pasteFileTitle(hasImage: true, hasFiles: true, canSend: false))
        // Beside text the row shows and Paste still pastes the text.
        XCTAssertNotNil(C.pasteFileTitle(hasImage: true, hasFiles: false, canSend: true))
        XCTAssertEqual(C.paste(hasText: true, hasImage: true, hasFiles: false, canSend: true), .text)
    }
}

/// Drops: only files from another app, and only where the server takes them.
final class DropRuleTests: XCTestCase {
    func testTextAndAddressesAreNotFiles() {
        XCTAssertNil(FileItemType.pick([.plainText], fileBacked: false), "a text drag isn't sent as a .txt")
        XCTAssertNil(FileItemType.pick([.url, .plainText], fileBacked: false), "nor a link")
        XCTAssertNil(FileItemType.pick([.plainText, .utf8PlainText], fileBacked: true))
        XCTAssertEqual(FileItemType.pick([.url, .png], fileBacked: false), .png)
        XCTAssertEqual(FileItemType.pick([.quickTimeMovie], fileBacked: false), .quickTimeMovie)
        XCTAssertEqual(FileItemType.pick([.fileURL, .plainText, .pdf], fileBacked: true), .pdf)
        XCTAssertNil(FileItemType.pick([.pdf], fileBacked: false), "data that isn't a file, an image or a movie")
        XCTAssertFalse(DropRule.types.contains(.plainText))
        XCTAssertFalse(DropRule.types.contains { $0.conforms(to: .text) || $0 == .url })
    }

    func testOnlyAnotherAppsFilesAreTaken() {
        XCTAssertTrue(DropRule.accepts(fromThisApp: false, canSend: true, hasFiles: true))
        XCTAssertFalse(DropRule.accepts(fromThisApp: true, canSend: true, hasFiles: true), "a selection drag stays a selection")
        XCTAssertFalse(DropRule.accepts(fromThisApp: false, canSend: false, hasFiles: true))
        XCTAssertFalse(DropRule.accepts(fromThisApp: false, canSend: true, hasFiles: false))
    }
}

/// Open: whether selected text names a file, and which.
final class PathGuessTests: XCTestCase {
    private func g(_ s: String) -> String? { PathGuess.path(in: s) }

    func testPathsAsTerminalsShowThem() {
        XCTAssertEqual(g("/tmp/zz-files/dl one.bin"), "/tmp/zz-files/dl one.bin")
        XCTAssertEqual(g("  ~/notes/todo.md \n"), "~/notes/todo.md")
        XCTAssertEqual(g("./build/out.log"), "./build/out.log")
        XCTAssertEqual(g("../a.txt"), "../a.txt")
        XCTAssertEqual(g("src/main.swift"), "src/main.swift")
        XCTAssertEqual(g("README.md"), "README.md")
    }

    func testShellEscapesAndQuotesAreUndone() {
        // The server types an uploaded file's path this way.
        XCTAssertEqual(g(#"/home/u/.local/state/rex/uploads/1/2/3/probe\ three.bin"#),
                       "/home/u/.local/state/rex/uploads/1/2/3/probe three.bin")
        XCTAssertEqual(g(#"/tmp/it\'s\ \"q\".txt"#), #"/tmp/it's "q".txt"#)
        XCTAssertEqual(g("'/tmp/a b.txt'"), "/tmp/a b.txt")
        XCTAssertEqual(g(#""docs/x.md""#), "docs/x.md")
    }

    func testLineNumbersAndSentencePunctuationAreDropped() {
        XCTAssertEqual(g("Sources/App.swift:12:5"), "Sources/App.swift")
        XCTAssertEqual(g("Sources/App.swift:12"), "Sources/App.swift")
        XCTAssertEqual(g("/tmp/x.txt,"), "/tmp/x.txt")
        XCTAssertEqual(g("/tmp/x.txt."), "/tmp/x.txt")
        XCTAssertNil(g("see /tmp/x.txt"), "a sentence isn't a path")
    }

    func testAWrappedPathIsJoined() {
        XCTAssertEqual(g("/home/user/.local/state/rex/upl\noads/x/y.png"), "/home/user/.local/state/rex/uploads/x/y.png")
        XCTAssertNil(g("two words\nover rows"))
    }

    func testOnlyASmallSelectionIsReadAsAPath() {
        XCTAssertTrue(PathGuess.isSmall(rows: 1, cols: 80, startCol: 0, endCol: 40, clipped: false))
        XCTAssertTrue(PathGuess.isSmall(rows: 3, cols: 120, startCol: 10, endCol: 5, clipped: false))
        XCTAssertFalse(PathGuess.isSmall(rows: 5, cols: 40, startCol: 0, endCol: 0, clipped: false), "too many rows")
        XCTAssertFalse(PathGuess.isSmall(rows: 4, cols: 400, startCol: 0, endCol: 399, clipped: false), "over 1 KB")
        XCTAssertFalse(PathGuess.isSmall(rows: 1, cols: 80, startCol: 0, endCol: 10, clipped: true), "runs out of view")
    }

    func testWhatIsNotAPath() {
        XCTAssertNil(g(""))
        XCTAssertNil(g("hello world"))
        XCTAssertNil(g("https://example.com/a.png"))
        XCTAssertNil(g("someone@example.com"))
        XCTAssertNil(g("-rf"))
        XCTAssertNil(g("3.14"))
        XCTAssertNil(g(String(repeating: "a/", count: 600)))
    }

    func testFailuresInPlainWords() {
        XCTAssertEqual(PathGuess.message(.notFound, path: "/tmp/x.txt", machine: "studio"), "There's no x.txt on studio.")
        XCTAssertEqual(PathGuess.message(.folder, path: "/tmp/zz", machine: "studio"), "zz is a folder.")
        XCTAssertTrue(PathGuess.message(.tooBig(200_000_000), path: "big.mov", machine: "m").hasPrefix("big.mov is too big to open here ("))
    }
}
