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
        XCTAssertEqual(SendTarget.menuTitle(SendTarget.name(agent: .claude, machine: "workdesk")), "Send to Claude")
        XCTAssertEqual(SendTarget.menuTitle(SendTarget.name(agent: nil, machine: "workdesk")), "Send to workdesk")
        XCTAssertEqual(SendTarget.name(agent: nil, machine: "  "), "this computer")
        XCTAssertEqual(SendTarget.name(agent: nil, machine: nil), "this computer")
    }

    func testProgressAndDoneNameTheFilesAndWhereTheyGo() {
        XCTAssertEqual(SendTarget.progress(["a.png"], to: "Claude", fraction: 0.456), "Sending a.png to Claude · 45%")
        XCTAssertEqual(SendTarget.progress(["a", "b", "c"], to: "workdesk", fraction: 1.2), "Sending 3 files to workdesk · 100%")
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
        XCTAssertEqual(C.paste(hasText: false, hasImage: true, hasFiles: false, canSend: false), .nothing,
                       "a server that can't take files leaves Paste text-only")
        XCTAssertEqual(C.paste(hasText: false, hasImage: false, hasFiles: false, canSend: true), .nothing)
        XCTAssertTrue(C.offersPasteImage(hasImage: true, canSend: true))
        XCTAssertFalse(C.offersPasteImage(hasImage: true, canSend: false))
    }
}

/// Drops: only files from another app, and only where the server takes them.
final class DropRuleTests: XCTestCase {
    func testOnlyAnotherAppsFilesAreTaken() {
        XCTAssertTrue(DropRule.accepts(fromThisApp: false, canSend: true, hasFiles: true))
        XCTAssertFalse(DropRule.accepts(fromThisApp: true, canSend: true, hasFiles: true), "a selection drag stays a selection")
        XCTAssertFalse(DropRule.accepts(fromThisApp: false, canSend: false, hasFiles: true))
        XCTAssertFalse(DropRule.accepts(fromThisApp: false, canSend: true, hasFiles: false))
    }
}
