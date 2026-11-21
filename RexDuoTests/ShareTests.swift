import GhosttyVt
import RexKit
import UIKit
import WebKit
import XCTest
@testable import RexDuo

/// Sharing output (docs/terminal.md, Share): the local formatter, the HTML document and its link
/// cleaning, the chunked All Output reader against a fake and against fake servers at each
/// revision, the notice's job lane, the background task, and where the sheet points.
@MainActor
final class ShareTests: XCTestCase {
    override func tearDown() async throws {
        Notice.shared.dismiss()
        try await super.tearDown()
    }

    // MARK: Formatter

    private func core(_ text: String, cols: Int = 20, rows: Int = 4) -> GhosttyCore {
        let core = GhosttyCore(cols: cols, rows: rows)
        core.feed(Array(text.utf8))
        core.sync()
        return core
    }

    func testTheViewportIsTheDrawnRowsOnly() {
        let lines = (1...12).map { "line \($0)" }
        let c = core(lines.joined(separator: "\r\n"))
        let drawn = (0..<4).map { c.rowText($0) }
        XCTAssertEqual(drawn, ["line 9", "line 10", "line 11", "line 12"])
        XCTAssertEqual(c.format(scope: .viewport, emit: .plain), drawn.joined(separator: "\n"))
        // Scrolled into history, the viewport is what the view shows there.
        _ = c.withTerminal { t in
            var behavior = GhosttyTerminalScrollViewport()
            behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA
            behavior.value.delta = -5
            ghostty_terminal_scroll_viewport(t, behavior)
        }
        let scrolled = (0..<4).map { c.rowText($0) }
        XCTAssertEqual(scrolled, ["line 4", "line 5", "line 6", "line 7"])
        XCTAssertEqual(c.format(scope: .viewport, emit: .plain), scrolled.joined(separator: "\n"))
    }

    func testTheViewportKeepsItsRowsWhereTheSelectionJoinsThem() {
        let c = core(String(repeating: "a", count: 25), cols: 20, rows: 3)
        XCTAssertEqual(c.format(scope: .viewport, emit: .plain), String(repeating: "a", count: 20) + "\n" + "aaaaa")
        XCTAssertTrue(c.selectAll())
        XCTAssertEqual(c.format(scope: .selection, emit: .plain), String(repeating: "a", count: 25))
    }

    func testTheSelectionIsWhatCopyTakes() {
        let c = core("hello world  \r\nsecond")
        XCTAssertNil(c.format(scope: .selection, emit: .plain), "no selection, nothing to share")
        XCTAssertTrue(c.selectAll())
        XCTAssertEqual(c.format(scope: .selection, emit: .plain), c.selectedText)
        XCTAssertEqual(c.selectedText, "hello world\nsecond")
    }

    func testStyledScreenHasInlineRunsAndThePalette() throws {
        let c = core("\u{1b}[31mred\u{1b}[0m \u{1b}[1mbold\u{1b}[0m")
        let html = try XCTUnwrap(c.format(scope: .viewport, emit: .html))
        XCTAssertTrue(html.hasPrefix("<style>:root{"), "the palette block comes first")
        XCTAssertTrue(html.contains("--vt-palette-1: #"))
        XCTAssertTrue(html.contains("var(--vt-palette-1)"), html)
        XCTAssertTrue(html.contains("font-weight: bold"), html)
        XCTAssertTrue(html.contains("red"))
    }

    /// `selectedText` as main made it before `format(scope:emit:)`: its own formatter, plain,
    /// UNWRAP and TRIM, every other option at its default.
    private func selectedTextAsOnMain(_ core: GhosttyCore) -> String? {
        core.withTerminal { t -> String? in
            var selection = GhosttySelection()
            guard ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS else { return nil }
            var formatter: GhosttyFormatter?
            guard ghostty_formatter_terminal_new(nil, &formatter, t) == GHOSTTY_SUCCESS, let formatter else { return nil }
            defer { ghostty_formatter_free(formatter) }
            var emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
            var yes = true
            ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit)
            ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &yes)
            ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &yes)
            guard ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &selection) == GHOSTTY_SUCCESS else { return nil }
            var bytes: UnsafeMutablePointer<UInt8>?
            var count = 0
            guard ghostty_formatter_format_alloc(formatter, nil, &bytes, &count) == GHOSTTY_SUCCESS else { return nil }
            guard let bytes else { return "" }
            defer { ghostty_free(nil, bytes, count) }
            return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
        } ?? nil
    }

    func testSelectedTextIsAsOnMainForWideTextEmojiAndSoftWraps() {
        let cases: [(String, Int)] = [
            ("日本語のテキスト 中文 한국어 カタカナ", 12),
            ("emoji 😀🎉 family 👩‍👩‍👧 flag 🇯🇵 skin 👍🏽 end", 14),
            ("ab日本語日本語日本語x", 9),  // a wide character where the row wraps
            ("word   word   word   word   word      \r\nnext   \r\n   \r\nlast  ", 10),  // soft wraps, trailing spaces
            (String(repeating: "a ", count: 30) + "   ", 8),
        ]
        for (text, cols) in cases {
            let c = core(text, cols: cols, rows: 8)
            XCTAssertTrue(c.selectAll(), text)
            XCTAssertNotNil(c.selectedText, text)
            XCTAssertEqual(c.selectedText, selectedTextAsOnMain(c), "select all: \(text)")
            for (from, to) in [((1, 0), (3, 2)), ((cols - 1, 0), (0, 1)), ((2, 1), (cols - 1, 3))] {
                let anchor = GhosttySelectionAnchor(core: c)
                c.beginSelection(col: from.0, row: from.1, word: false, anchor: anchor)
                _ = c.extendSelection(col: to.0, row: to.1, anchor: anchor, keepOnAnchor: false)
                c.endSelection(anchor: anchor)
                XCTAssertEqual(c.selectedText, selectedTextAsOnMain(c), "\(from) to \(to): \(text)")
            }
        }
    }

    func testTheSelectionIsTakenWhenShareIsTapped() async throws {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let host = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: "b"), sizing: .mirror,
                                fontSize: 12, theme: ThemeStore.fallback)
        host.share = pane()
        host.term.feed(text: "hello")
        host.term.core.sync()
        Notice.shared.dismiss()
        host.share?.shareSelection(at: nil) {}
        XCTAssertEqual(Notice.shared.message, "Nothing to share.", "no selection: said at once")
        Notice.shared.dismiss()
        host.term.selectAllText()
        host.share?.shareSelection(at: nil) {}
        // A tap that clears the selection right after changes nothing: the text is already taken.
        host.term.clearSelectedRange()
        await settle()
        XCTAssertNil(Notice.shared.message, "no later \"Nothing to share.\"")
    }

    // MARK: The HTML document

    func testTheCSPComesRightAfterTheCharset() {
        let head = ShareHTML.head(title: "t", theme: ThemeStore.fallback)
        let charset = head.range(of: "<meta charset=\"utf-8\">")!
        let csp = head.range(of: "<meta http-equiv=\"Content-Security-Policy\"")!
        XCTAssertEqual(head[charset.upperBound..<csp.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines), "")
        XCTAssertTrue(head.contains("default-src 'none'; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'"))
        XCTAssertTrue(head.hasPrefix("<!doctype html><html><head><meta charset=\"utf-8\">"))
    }

    func testTheTitleIsEscapedAndThePaletteAndFontAreForced() {
        let head = ShareHTML.head(title: "<script>alert('x')</script> & \"q\"", theme: ThemeStore.fallback)
        XCTAssertTrue(head.contains("<title>&lt;script&gt;alert(&#39;x&#39;)&lt;/script&gt; &amp; &quot;q&quot;</title>"))
        XCTAssertFalse(head.contains("<script>"))
        for i in [0, 1, 15, 16, 231, 255] {
            XCTAssertNotNil(head.range(of: #"--vt-palette-\#(i):#[0-9a-f]{6} !important;"#, options: .regularExpression), "palette \(i)")
        }
        XCTAssertTrue(head.contains("--vt-palette-1:#f47067 !important;"), "the theme's own red")
        XCTAssertTrue(head.contains("div{font-family:ui-monospace,Menlo,monospace !important;"))
        XCTAssertTrue(head.contains("body > div{background:#22272e !important;color:#adbac7 !important}"))
        XCTAssertTrue(head.contains("div[style*=\"invert(100%)\"]{background-color:#22272e}"), "inverse runs flip a background too")
    }

    func testColorsAreValidForExtendedRangeInput() {
        let wide = UIColor(displayP3Red: 1, green: 0, blue: 0, alpha: 1)
        XCTAssertNotNil(ShareHTML.css(wide).range(of: "^#[0-9a-f]{6}$", options: .regularExpression), ShareHTML.css(wide))
        let over = UIColor(red: 1.4, green: -0.3, blue: 0.5, alpha: 1)
        XCTAssertEqual(ShareHTML.css(over), "#ff0080")
        XCTAssertEqual(ShareHTML.palette(ThemeStore.fallback).count, 256)
        XCTAssertTrue(ShareHTML.palette(ThemeStore.fallback).allSatisfy { $0.range(of: "^#[0-9a-f]{6}$", options: .regularExpression) != nil })
    }

    /// Rendered by WebKit: the theme's palette beats the local formatter's own `<style>` block,
    /// the font is not Courier, a `javascript:` link has no target and no script runs.
    func testTheDocumentRendersWithTheThemeAndRunsNothing() async throws {
        let c = core("\u{1b}[31mred\u{1b}[0m \u{1b}]8;;javascript:document.title='ran'\u{1b}\\click\u{1b}]8;;\u{1b}\\ <script>document.title='ran'</script>",
                     cols: 80)
        let fragment = try XCTUnwrap(c.format(scope: .viewport, emit: .html))
        var theme = ThemeStore.fallback
        theme.ansi[1] = "#123456"
        let doc = ShareHTML.document(title: "zz", theme: theme, fragment: fragment)
        XCTAssertTrue(fragment.contains("--vt-palette-1:"), "the formatter wrote its own palette")
        XCTAssertFalse(doc.contains("javascript:"), "the link lost its target")
        XCTAssertTrue(doc.contains("&lt;script&gt;"))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let loaded = Loaded()
        web.navigationDelegate = loaded
        web.loadHTMLString(doc, baseURL: nil)
        _ = await eventually(5) { loaded.done }
        try XCTSkipUnless(loaded.done, "WebKit didn't load in this host")
        let palette = try await web.evaluateJavaScript("getComputedStyle(document.documentElement).getPropertyValue('--vt-palette-1').trim()") as? String
        XCTAssertEqual(palette, "#123456")
        let font = try await web.evaluateJavaScript("getComputedStyle(document.body.firstElementChild.nextElementSibling || document.body.firstElementChild).fontFamily") as? String
        XCTAssertFalse(font?.lowercased().contains("courier") ?? true, font ?? "")
        XCTAssertTrue(font?.contains("ui-monospace") ?? false, font ?? "")
        let hrefs = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('a')).map(a => a.hasAttribute('href')).join(',')") as? String
        XCTAssertEqual(hrefs, "false")
        let title = try await web.evaluateJavaScript("document.title") as? String
        XCTAssertEqual(title, "zz")
    }

    private final class Loaded: NSObject, WKNavigationDelegate {
        var done = false
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    }

    // MARK: Links

    private func cleaned(_ html: String) -> String {
        var s = LinkSanitizer()
        return s.feed(html) + s.finish()
    }

    func testLinksThatAreNotWebOrMailLoseTheirTarget() {
        let dropped = ["java\tscript:alert(1)", "java&#9;script:x", "\u{1}javascript:x", "JAVASCRIPT:x", " javascript:x", "data:text/html,x",
                       "vbscript:x", "file:///etc/passwd", "//evil.example", "relative/path", "&amp;#106;avascript:x",
                       "&#106;avascript:x", "&#x6A;avascript:x", "&#106avascript:x", "javascript&colon;x", "", "java\nscript:x"]
        for raw in dropped {
            XCTAssertFalse(LinkSanitizer.keeps(raw), raw)
            XCTAssertEqual(cleaned("<a href=\"\(raw)\">text</a>"), "<a>text</a>", raw)
        }
        let kept = ["http://a.example", "https://a.example/x?y=1&amp;z=2", "mailto:me@a.example", "HTTPS://A.EXAMPLE", "MailTo:x",
                    "  https://a.example", "ht\ttps://a.example", "&#104;ttps://a.example"]
        for raw in kept {
            XCTAssertTrue(LinkSanitizer.keeps(raw), raw)
            XCTAssertEqual(cleaned("<a href=\"\(raw)\">text</a>"), "<a href=\"\(raw)\">text</a>", raw)
        }
        XCTAssertEqual(cleaned("<a href='javascript:x' class=y>t</a>"), "<a class=y>t</a>")
        XCTAssertEqual(cleaned("<a HREF=javascript:x>t</a>"), "<a>t</a>")
        XCTAssertEqual(cleaned("<a/href=\"javascript:x\">t</a>"), "<a>t</a>", "a slash separates attributes, as in a browser")
        XCTAssertEqual(cleaned("<a href=\"https://a.example\"/>t</a>"), "<a href=\"https://a.example\"/>t</a>")
        XCTAssertEqual(cleaned("<div style=\"display: inline;\">x</div>"), "<div style=\"display: inline;\">x</div>")
    }

    func testALiteralScriptStaysEscaped() {
        let c = core("<script>alert(1)</script>", cols: 40)
        let html = cleaned(c.format(scope: .viewport, emit: .html) ?? "")
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
    }

    func testATagSplitAtAnyByteGivesTheSameOutput() {
        let html = "<div style=\"color: #fff;\">a&amp;b <a href=\"javascript:x\">bad</a> <a href=\"https://ok.example/&#195;&#169;\">ok</a> &#128512;</div>"
        let whole = cleaned(html)
        XCTAssertEqual(whole, "<div style=\"color: #fff;\">a&amp;b <a>bad</a> <a href=\"https://ok.example/&#195;&#169;\">ok</a> &#128512;</div>")
        let bytes = Array(html.utf8)
        for cut in 0...bytes.count {
            var s = LinkSanitizer()
            let out = s.feed(String(decoding: bytes[..<cut], as: UTF8.self)) + s.feed(String(decoding: bytes[cut...], as: UTF8.self)) + s.finish()
            XCTAssertEqual(out, whole, "cut at \(cut)")
        }
    }

    // MARK: Chunks and caps

    func testChunksFollowThroughputBetweenTheirBounds() {
        var s = ChunkSizer()
        XCTAssertEqual(s.next, 64 * 1024)
        s.measured(bytes: 65536, seconds: 65536 / 250_000)  // 2 Mbps
        XCTAssertEqual(s.next, 64 * 1024)
        s.measured(bytes: 65536, seconds: 65536 / 2_500_000)  // 20 Mbps
        XCTAssertEqual(Double(s.next), 250_000, accuracy: 1)
        s.measured(bytes: 65536, seconds: 0.0001)
        XCTAssertEqual(s.next, 256 * 1024)
        s.measured(bytes: 10, seconds: 5)
        XCTAssertEqual(s.next, 64 * 1024)
    }

    func testTheCutStartsAfterALineBreakOrAtAWholeCharacter() {
        // A start in the middle of a 4-byte emoji: the server sends a U+FFFD per byte it cut.
        let (text, dropped, replaced) = TextCap.trimStart("\u{FFFD}\u{FFFD}\u{FFFD}tail\nnext line\n")
        XCTAssertEqual(text, "next line\n")
        XCTAssertEqual(replaced, 3)
        XCTAssertEqual(dropped, 3 + 5)
        let (noBreak, d2, r2) = TextCap.trimStart("\u{FFFD}😀 no break")
        XCTAssertEqual(noBreak, "😀 no break")
        XCTAssertEqual(r2, 1)
        XCTAssertEqual(d2, 1)
        XCTAssertEqual(TextCap.marker(skipped: 12_000_000), "[Earlier output not included: 12 MB]\n")
        XCTAssertEqual(TextCap.start(total: 100, limit: 40), 60)
        XCTAssertEqual(TextCap.start(total: 10, limit: 40), 0)
    }

    func testFileNamesCarryTheTitleAndTime() {
        var c = DateComponents()
        c.year = 2026; c.month = 11; c.day = 19; c.hour = 9; c.minute = 5
        let date = Calendar.current.date(from: c)!
        XCTAssertEqual(PaneShare.fileName(title: "build / logs", date: date, ext: "txt"), "logs 2026-11-19 09.05.txt")
        XCTAssertEqual(PaneShare.fileName(title: "", date: date, ext: "html"), "Terminal 2026-11-19 09.05.html")
    }

    // MARK: Reader, against a fake

    func testReadsInAdaptiveChunksOneAtATime() async throws {
        let text = String(repeating: "0123456789abcdef\n", count: 60_000)  // ~1 MB
        let fake = FakeOutput(text)
        fake.bytesPerSecond = 2_500_000  // 20 Mbps
        let reader = OutputReader()
        reader.clock = { fake.now }
        var out = ""
        reader.write = { out += $0 }
        try await reader.read(.text, session: "s", block: "b", from: fake)
        XCTAssertEqual(out, text)
        XCTAssertEqual(fake.maxInFlight, 1)
        XCTAssertEqual(fake.requests.first?.method, OutputReader.format)
        XCTAssertEqual(fake.requests.first?.args.int("max_bytes"), 64 * 1024)
        XCTAssertEqual(fake.requests.first?.args.bool("unwrap"), true)
        XCTAssertEqual(fake.requests.first?.args.bool("trim"), true)
        let later = fake.requests.dropFirst().compactMap { $0.args.int("max_bytes") }
        XCTAssertTrue(later.allSatisfy { abs($0 - 250_000) < 2 }, "\(later)")
        XCTAssertTrue(fake.requests.dropFirst().allSatisfy { $0.method == OutputReader.blobRead && $0.args.int("id") == 7 })

        let slow = FakeOutput(text)
        slow.bytesPerSecond = 250_000  // 2 Mbps
        let r2 = OutputReader()
        r2.clock = { slow.now }
        try await r2.read(.text, session: "s", block: "b", from: slow)
        XCTAssertTrue(slow.requests.allSatisfy { $0.args.int("max_bytes") == 64 * 1024 })
    }

    func testTheReadWaitsWhileTypedInputIsOnItsWay() async throws {
        let fake = FakeOutput(String(repeating: "x", count: 2_000_000))
        fake.busy = true
        let reader = OutputReader()
        let task = Task { @MainActor in try await reader.read(.text, session: "s", block: "b", from: fake) }
        await settle()
        XCTAssertEqual(fake.requests.count, 0, "nothing goes out while a keystroke is on its way")
        // Typing during the read pauses it after the request that is out.
        fake.afterCall = { if fake.requests.count == 2 { fake.busy = true } }
        fake.setBusy(false)
        _ = await eventually { fake.requests.count == 2 }
        await settle()
        XCTAssertEqual(fake.requests.count, 2)
        fake.setBusy(false)
        try await task.value
        XCTAssertGreaterThan(fake.requests.count, 2)
    }

    func testANotFoundStartsOverOnceAndThenSucceeds() async throws {
        let text = String(repeating: "line\n", count: 40_000)
        let fake = FakeOutput(text)
        fake.failures[OutputReader.blobRead] = [RexError(code: "not_found", message: "gone")]
        let reader = OutputReader()
        var out = ""
        reader.reset = { out = "" }
        reader.write = { out += $0 }
        try await reader.read(.text, session: "s", block: "b", from: fake)
        XCTAssertEqual(out, text)
        XCTAssertEqual(fake.requests.filter { $0.method == OutputReader.format }.count, 2)
    }

    func testTwoNotFoundsEndTheRead() async {
        let fake = FakeOutput(String(repeating: "line\n", count: 40_000))
        fake.failures[OutputReader.blobRead] = [RexError(code: "not_found", message: "gone"), RexError(code: "not_found", message: "gone")]
        let reader = OutputReader()
        do {
            try await reader.read(.text, session: "s", block: "b", from: fake)
            XCTFail("the read should fail")
        } catch {
            XCTAssertEqual(error, .notFound)
        }
    }

    func testAReplyWithoutAnIdIsTheWholeOutput() async throws {
        let fake = FakeOutput("small\n")
        let reader = OutputReader()
        var out = ""
        reader.write = { out += $0 }
        try await reader.read(.html, session: "s", block: "b", from: fake)
        XCTAssertEqual(out, "small\n")
        XCTAssertEqual(fake.requests.count, 1)
        XCTAssertEqual(fake.requests[0].args.str("format"), "html")
    }

    func testARevision13ReplyWithoutEofEndsAtTheTotal() async throws {
        let text = String(repeating: "é", count: 100_000)
        let fake = FakeOutput(text)
        fake.sendsEof = false
        let reader = OutputReader()
        var out = ""
        reader.write = { out += $0 }
        try await reader.read(.text, session: "s", block: "b", from: fake)
        XCTAssertEqual(out, text)
    }

    func testStyledOutputOverItsLimitStopsBeforeReadingOn() async {
        let fake = FakeOutput(String(repeating: "x", count: 100_000))
        fake.reportedTotal = OutputReader.styledLimit + 1
        let reader = OutputReader()
        do {
            try await reader.read(.html, session: "s", block: "b", from: fake)
            XCTFail("the read should stop")
        } catch {
            XCTAssertEqual(error, .styledTooLarge)
        }
        XCTAssertEqual(fake.requests.count, 1, "decided from the first reply's total")
    }

    func testWithoutATotalTheStyledLimitCountsWhatWasRead() async {
        let fake = FakeOutput(String(repeating: "x", count: 300_000))
        fake.formatTotal = false
        fake.blobTotal = false
        let reader = OutputReader()
        reader.styledLimit = 100_000
        do {
            try await reader.read(.html, session: "s", block: "b", from: fake)
            XCTFail("the read should stop")
        } catch {
            XCTAssertEqual(error, .styledTooLarge)
        }
        XCTAssertLessThan(fake.requests.count, 5)

        // A first reply without a total, then a `blob_read` that has one: the limit applies there.
        let late = FakeOutput(String(repeating: "x", count: 300_000))
        late.formatTotal = false
        let r2 = OutputReader()
        r2.styledLimit = 100_000
        do {
            try await r2.read(.html, session: "s", block: "b", from: late)
            XCTFail("the read should stop")
        } catch {
            XCTAssertEqual(error, .styledTooLarge)
        }
        XCTAssertEqual(late.requests.count, 2)
    }

    func testLongTextKeepsTheNewestPartFromALine() async throws {
        let older = (0..<3000).map { "old \($0) 😀" }.joined(separator: "\n")
        let newer = (0..<2000).map { "new \($0) 🎉" }.joined(separator: "\n")
        let text = older + "\n" + newer + "\n"
        let fake = FakeOutput(text)
        let reader = OutputReader()
        reader.textLimit = newer.utf8.count + 30
        var out = ""
        reader.write = { out += $0 }
        try await reader.read(.text, session: "s", block: "b", from: fake)
        let marker = out.prefix { $0 != "\n" }
        XCTAssertTrue(marker.hasPrefix("[Earlier output not included: "), String(marker))
        let body = out.dropFirst(marker.count + 1)
        XCTAssertTrue(text.hasSuffix("\n" + body), "a contiguous tail from a line's start, nothing lost or repeated")
        XCTAssertTrue(body.hasSuffix("new 1999 🎉\n"))
        XCTAssertLessThanOrEqual(body.utf8.count, reader.textLimit)
        XCTAssertFalse(body.contains("\u{FFFD}"))
        let start = fake.requests[1].args.int("offset")
        XCTAssertEqual(start, text.utf8.count - reader.textLimit)
    }

    func testMethodNotFoundIsUnsupported() async {
        for method in [OutputReader.format, OutputReader.blobRead] {
            let fake = FakeOutput(String(repeating: "x", count: 100_000))
            fake.failures[method] = [RexError(code: "method_not_found", message: "no")]
            do {
                try await OutputReader().read(.text, session: "s", block: "b", from: fake)
                XCTFail("should fail")
            } catch {
                XCTAssertEqual(error, .unsupported(method))
            }
        }
    }

    func testADisconnectWithInputQueuedEndsTheReadAtOnce() async {
        let fake = FakeOutput(String(repeating: "x", count: 2_000_000))
        fake.afterCall = { if fake.requests.count == 2 { fake.busy = true } }
        let reader = OutputReader()
        var failure: OutputReadFailure?
        var ended = false
        let task = Task { @MainActor in
            do { try await reader.read(.text, session: "s", block: "b", from: fake) } catch { failure = error as? OutputReadFailure }
            ended = true
        }
        _ = await eventually { fake.requests.count == 2 }
        await settle()
        XCTAssertFalse(ended, "waiting for the typed input")
        let dropped = Date()
        fake.disconnect()
        await task.value
        XCTAssertLessThan(Date().timeIntervalSince(dropped), 0.5)
        XCTAssertEqual(failure, .connection)
        XCTAssertEqual(fake.requests.count, 2, "nothing more is asked")
    }

    func testANewConnectionEndsTheRead() async {
        let fake = FakeOutput(String(repeating: "x", count: 300_000))
        fake.afterCall = { if fake.requests.count == 2 { fake.connectionSerial += 1 } }
        do {
            try await OutputReader().read(.text, session: "s", block: "b", from: fake)
            XCTFail("should fail")
        } catch {
            XCTAssertEqual(error, .connection)
        }
        XCTAssertEqual(fake.requests.count, 2, "nothing more is asked of the new connection")
    }

    // MARK: One share, start to sheet

    private func pane(withBlock: Bool = true) -> PaneShare {
        let name = "ShareTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        let prefs = Prefs(defaults: d)
        let model = AppModel(prefs: prefs, connect: false)
        let server = ServerConnection(config: ServerConfig(name: "Desk", url: "http://127.0.0.1:9"), prefs: prefs,
                                      notifier: model.notifier, deviceID: "a1b2c3d4")
        if withBlock { server.views["s"] = SessionView(ServerEventsTests.view("s")) }
        keep.append(model)
        return PaneShare(server: server, sessionID: "s", blockID: "block:sa")
    }
    private var keep: [AnyObject] = []

    private func shared() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: FileStaging.shared, includingPropertiesForKeys: nil)) ?? []
    }

    private func run(_ share: OutputShare) async {
        share.start()
        await share.task?.value
    }

    func testAShareEndsAtTheSheetWithItsOwnFile() async throws {
        let p = pane()
        let before = shared()
        let text = String(repeating: "line of output\n", count: 30_000)
        let fake = FakeOutput(text)
        let share = OutputShare(pane: p, styled: false, anchor: .titleBar)
        share.source = fake
        var presented: (ShareItem, URL?)?
        share.present = { presented = ($0, $1) }
        await run(share)
        let (item, folder) = try XCTUnwrap(presented)
        guard case .file(let url) = item.payload else { return XCTFail("a big text goes as a file") }
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("tab "), url.lastPathComponent)
        XCTAssertEqual(folder, url.deletingLastPathComponent())
        XCTAssertFalse(Notice.shared.jobRunning, "the lane is clear")
        FileStaging.remove(folder!)
        XCTAssertEqual(Set(shared()), Set(before))
    }

    func testAShortTextGoesAsText() async throws {
        let share = OutputShare(pane: pane(), styled: false, anchor: .titleBar)
        share.source = FakeOutput(String(repeating: "short\n", count: 20_000))
        var presented: (ShareItem, URL?)?
        share.present = { presented = ($0, $1) }
        await run(share)
        let (item, folder) = try XCTUnwrap(presented)
        guard case .text(let s) = item.payload else { return XCTFail("text") }
        XCTAssertEqual(s.utf8.count, 120_000)
        XCTAssertNil(folder, "its folder is gone already")
    }

    func testAStyledShareIsADocumentWithCleanLinks() async throws {
        let fragment = "<div style=\"white-space: pre;\"><a href=\"javascript:x\">bad</a></div>" + String(repeating: "<div>row</div>\n", count: 10_000)
        let share = OutputShare(pane: pane(), styled: true, anchor: .titleBar)
        share.source = FakeOutput(fragment)
        var presented: (ShareItem, URL?)?
        share.present = { presented = ($0, $1) }
        await run(share)
        let (item, folder) = try XCTUnwrap(presented)
        guard case .file(let url) = item.payload else { return XCTFail("a file") }
        XCTAssertEqual(url.pathExtension, "html")
        let doc = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(doc.hasPrefix("<!doctype html>"))
        XCTAssertTrue(doc.hasSuffix(ShareHTML.tail))
        XCTAssertFalse(doc.contains("javascript:"))
        XCTAssertTrue(doc.contains("<a>bad</a>"))
        FileStaging.remove(folder!)
    }

    func testTwoNotFoundsDeleteTheFolderAndOfferRetry() async {
        let before = shared()
        let share = OutputShare(pane: pane(), styled: false, anchor: .titleBar)
        let fake = FakeOutput(String(repeating: "x\n", count: 100_000))
        fake.failures[OutputReader.blobRead] = [RexError(code: "not_found", message: "gone"), RexError(code: "not_found", message: "gone")]
        share.source = fake
        var presented = false
        share.present = { _, _ in presented = true }
        await run(share)
        XCTAssertFalse(presented)
        XCTAssertEqual(Notice.shared.message, "Couldn't read the output.")
        XCTAssertEqual(Notice.shared.actionTitle, "Try Again")
        XCTAssertEqual(Set(shared()), Set(before))
        XCTAssertFalse(Notice.shared.jobRunning)
    }

    func testAClosedPaneSaysSo() async {
        let share = OutputShare(pane: pane(withBlock: false), styled: false, anchor: .titleBar)
        let fake = FakeOutput(String(repeating: "x\n", count: 100_000))
        fake.failures[OutputReader.blobRead] = [RexError(code: "not_found", message: "gone"), RexError(code: "not_found", message: "gone")]
        share.source = fake
        await run(share)
        XCTAssertEqual(Notice.shared.message, Messages.paneClosed)
        XCTAssertNil(Notice.shared.actionTitle)
    }

    func testStyledOverTheLimitOffersSharePlain() async {
        let share = OutputShare(pane: pane(), styled: true, anchor: .titleBar)
        let fake = FakeOutput(String(repeating: "x", count: 100_000))
        fake.reportedTotal = OutputReader.styledLimit + 1
        share.source = fake
        await run(share)
        XCTAssertEqual(Notice.shared.message, "Too much output to share with colors.")
        XCTAssertEqual(Notice.shared.actionTitle, "Share as Plain Text")
        XCTAssertEqual(fake.requests.count, 1)
    }

    func testCancelDeletesTheFolderAndClearsTheLane() async {
        let before = shared()
        let share = OutputShare(pane: pane(), styled: false, anchor: .titleBar)
        let fake = FakeOutput(String(repeating: "x\n", count: 300_000))
        fake.afterCall = { if fake.requests.count == 2 { fake.busy = true } }
        share.source = fake
        var presented = false
        share.present = { _, _ in presented = true }
        share.start()
        _ = await eventually { fake.requests.count == 2 }
        await settle()
        XCTAssertNotNil(share.folder)
        XCTAssertEqual(Notice.shared.actionTitle, "Cancel", "a read of more than one chunk shows Cancel")
        Notice.shared.runAction()
        await share.task?.value
        XCTAssertFalse(presented)
        XCTAssertNil(share.folder)
        XCTAssertEqual(Set(shared()), Set(before))
        XCTAssertFalse(Notice.shared.jobRunning)
        XCTAssertNil(Notice.shared.message)
    }

    func testRunningOutOfBackgroundTimeStopsCleanlyAndPresentsNothing() async {
        let before = shared()
        let share = OutputShare(pane: pane(), styled: false, anchor: .titleBar)
        let fake = FakeOutput(String(repeating: "x\n", count: 300_000))
        fake.afterCall = { if fake.requests.count == 2 { fake.busy = true } }
        share.source = fake
        var presented = false
        share.present = { _, _ in presented = true }
        share.start()
        _ = await eventually { fake.requests.count == 2 }
        XCTAssertNotNil(share.background)
        share.background?.expire()
        await share.task?.value
        XCTAssertFalse(presented)
        XCTAssertEqual(Set(shared()), Set(before))
        XCTAssertFalse(Notice.shared.jobRunning)
        XCTAssertNil(Notice.shared.message, "no notice, no sheet")
        XCTAssertNil(share.background)
    }

    func testAMissingMethodMidReadHidesTheRows() async {
        let p = pane()
        let server = p.server
        let share = OutputShare(pane: p, styled: false, anchor: .titleBar)
        let fake = FakeOutput(String(repeating: "x\n", count: 100_000))
        fake.connectionSerial = server.connectionSerial
        fake.failures[OutputReader.blobRead] = [RexError(code: "method_not_found", message: "no")]
        share.source = fake
        XCTAssertTrue(server.sharesAllOutput(session: "s", block: "block:sa"))
        await run(share)
        XCTAssertEqual(Notice.shared.message, "Couldn't read the output.")
        XCTAssertNil(Notice.shared.actionTitle, "no Retry")
        XCTAssertFalse(server.sharesAllOutput(session: "s", block: "block:sa"))
    }

    // MARK: Job lane

    private func notice() -> Notice {
        let n = Notice()
        n.plainSeconds = 0.2
        n.actionSeconds = 0.2
        return n
    }

    func testAPlainNoticeOverAJobShowsItsTimeThenTheJobComesBack() async throws {
        let n = notice()
        var cancelled = false
        let begun = await n.beginJob(text: "Reading", cancel: { cancelled = true })
        let job = try XCTUnwrap(begun)
        XCTAssertNil(n.message, "a job shows from its first progress")
        n.progress(job, fraction: 0.3, text: "Reading 30%")
        XCTAssertEqual(n.message, "Reading 30%")
        XCTAssertEqual(n.actionTitle, "Cancel")
        n.show("Moved the pane.", style: .neutral)
        XCTAssertEqual(n.message, "Moved the pane.")
        n.progress(job, fraction: 0.5, text: "Reading 50%")
        XCTAssertEqual(n.message, "Moved the pane.", "progress never replaces a plain notice")
        XCTAssertNil(n.progress)
        _ = await eventually { n.message != "Moved the pane." }
        XCTAssertEqual(n.message, "Reading 50%")
        XCTAssertEqual(n.progress, 0.5)
        XCTAssertEqual(n.actionTitle, "Cancel", "Cancel is reachable again")
        n.runAction()
        XCTAssertTrue(cancelled)
        n.endJob(job)
        XCTAssertNil(n.message)
    }

    func testASecondJobWaitsForTheFirst() async throws {
        let n = notice()
        let begun = await n.beginJob(text: "one", cancel: {})
        let first = try XCTUnwrap(begun)
        var second: Notice.JobID?
        let waiter = Task { @MainActor in second = await n.beginJob(text: "two", cancel: {}) }
        await settle()
        XCTAssertNil(second)
        n.endJob(first)
        await waiter.value
        XCTAssertNotNil(second)
        n.progress(second!, fraction: 0.1)
        XCTAssertEqual(n.message, "two")
        n.endJob(second!)
        // A waiter that is cancelled never gets the lane.
        let again = await n.beginJob(text: "three", cancel: {})
        let third = try XCTUnwrap(again)
        let cancelled = Task { @MainActor in await n.beginJob(text: "four", cancel: {}) }
        await settle()
        cancelled.cancel()
        let got = await cancelled.value
        XCTAssertNil(got)
        n.endJob(third)
        XCTAssertFalse(n.jobRunning)
    }

    func testTransferProgressWaitsForAPlainNotice() async {
        let n = notice()
        var cancelled = false
        n.show("Copied.", style: .neutral)
        n.showProgress("Sending 10%", fraction: 0.1) { cancelled = true }
        XCTAssertEqual(n.message, "Copied.")
        _ = await eventually { n.message == "Sending 10%" }
        XCTAssertEqual(n.message, "Sending 10%")
        n.showProgress("Sending 20%", fraction: 0.2) { cancelled = true }
        XCTAssertEqual(n.message, "Sending 20%", "progress over progress replaces it, as before")
        n.runAction()
        XCTAssertTrue(cancelled)
        XCTAssertNil(n.message)
        n.showProgress("Sending 30%", fraction: 0.3) {}
        n.show("Sent.", style: .neutral)
        XCTAssertEqual(n.message, "Sent.", "the end of a transfer replaces its progress, as before")
        _ = await eventually { n.message == nil }
        XCTAssertNil(n.message, "and no stale progress comes back")
    }

    // MARK: Background task

    func testBackgroundTaskExpiryRunsOnceAndEnds() {
        var runs = 0
        let t = BackgroundTask(name: "test") { runs += 1 }
        t.expire()
        t.expire()
        XCTAssertEqual(runs, 1)
        XCTAssertFalse(t.running)
        let u = BackgroundTask(name: "test") { runs += 1 }
        u.end()
        u.expire()
        XCTAssertEqual(runs, 1, "an ended task has no expiry")
    }

    // MARK: Anchor

    func testTheSheetAlwaysHasASource() {
        let window = UIView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let host = UIView(frame: CGRect(x: 300, y: 50, width: 400, height: 500))
        let term = UIView(frame: host.bounds)
        window.addSubview(host)
        host.addSubview(term)
        let menu = CGRect(x: 10, y: 20, width: 30, height: 15)
        XCTAssertEqual(ShareAnchor.selection(menu).place(host: host, term: term, window: window),
                       .init(view: term, rect: menu, arrows: .any))
        XCTAssertEqual(ShareAnchor.selection(nil).place(host: host, term: term, window: window),
                       .init(view: host, rect: host.bounds, arrows: .any))
        XCTAssertEqual(ShareAnchor.titleBar.place(host: host, term: term, window: window),
                       .init(view: window, rect: CGRect(x: 656, y: 49, width: 44, height: 1), arrows: .any))
        XCTAssertEqual(ShareAnchor.bar(.leading).place(host: host, term: term, window: window),
                       .init(view: window, rect: CGRect(x: 0, y: 300, width: 1, height: 1), arrows: .left))
        XCTAssertEqual(ShareAnchor.bar(.trailing).place(host: host, term: term, window: window),
                       .init(view: window, rect: CGRect(x: 799, y: 300, width: 1, height: 1), arrows: .right))
    }

    // MARK: Edit menu

    func testShareIsLastInTheEditMenuWithASelectionOnly() throws {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let host = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: "b"), sizing: .mirror,
                                fontSize: 12, theme: ThemeStore.fallback)
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        func titles() -> [String] {
            host.editMenuInteraction(UIEditMenuInteraction(delegate: nil),
                                     menuFor: UIEditMenuConfiguration(identifier: nil, sourcePoint: .zero), suggestedActions: [])?
                .children.compactMap { ($0 as? UIAction)?.title } ?? []
        }
        host.term.feed(text: "hello")
        host.term.core.sync()
        host.term.selectAllText()
        XCTAssertEqual(titles().last, "Select All", "a pane without a server offers no Share…")
        host.share = pane()
        XCTAssertEqual(titles().suffix(2), ["Select All", "Share…"])
        host.term.clearSelectedRange()
        XCTAssertFalse(titles().contains("Share…"), "no selection, no Share…")
        XCTAssertEqual(titles().last, "Select All")
    }

    // MARK: Helpers

    private func settle(_ turns: Int = 8) async {
        for _ in 0..<turns { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
    }

    private func eventually(_ seconds: Double = 3, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }
}

/// `terminal.format` and `blob_read` over a string, as a server answers them: content up to
/// `max_bytes` cut at a whole character, a U+FFFD for each byte of a character an offset cuts
/// through, `id` while more remains, `total`, `eof`.
@MainActor
final class FakeOutput: OutputSource {
    struct Request {
        var method: String
        var args: JSONObject
    }

    let bytes: [UInt8]
    var connectionSerial = 1
    var requests: [Request] = []
    var failures: [String: [RexError]] = [:]
    var formatTotal = true
    var blobTotal = true
    var sendsEof = true
    /// A total to claim instead of the real one.
    var reportedTotal: Int?
    /// The simulated clock, advanced by each reply at `bytesPerSecond`.
    var now = 0.0
    var bytesPerSecond = 1_000_000.0
    var afterCall: (() -> Void)?
    private(set) var maxInFlight = 0
    private var inFlight = 0
    var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ text: String) { bytes = Array(text.utf8) }

    var outputConnected = true

    func setBusy(_ b: Bool) {
        busy = b
        if !b { wakeAll() }
    }

    /// The connection drops: waits for typed input end, as `InputActivity` does.
    func disconnect() {
        outputConnected = false
        wakeAll()
    }

    private func wakeAll() {
        let w = waiters
        waiters = []
        for c in w { c.resume() }
    }

    /// As `InputActivity.idle`: a cancelled wait returns, and so does one on a dropped connection.
    func inputIdle() async {
        while busy, outputConnected, !Task.isCancelled {
            await withTaskCancellationHandler {
                await withCheckedContinuation { c in
                    if Task.isCancelled { c.resume() } else { waiters.append(c) }
                }
            } onCancel: {
                Task { @MainActor in self.wakeAll() }
            }
        }
    }

    func outputCall(_ method: String, session: String, block: String, args: JSONObject) async throws -> JSONObject {
        requests.append(.init(method: method, args: args))
        inFlight += 1
        maxInFlight = max(maxInFlight, inFlight)
        defer {
            inFlight -= 1
            afterCall?()
        }
        await Task.yield()
        if var f = failures[method], !f.isEmpty {
            let e = f.removeFirst()
            failures[method] = f
            throw e
        }
        let total = reportedTotal ?? bytes.count
        let max = args.int("max_bytes") ?? 49152
        if method == OutputReader.format {
            let (text, end) = slice(from: 0, max: max)
            now += Double(end) / bytesPerSecond
            var r: JSONObject = ["content": text]
            if end < bytes.count { r["id"] = 7 }
            if formatTotal { r["total"] = total }
            if sendsEof { r["eof"] = end >= bytes.count }
            return r
        }
        let offset = args.int("offset") ?? 0
        let (text, end) = slice(from: offset, max: max)
        now += Double(end - offset) / bytesPerSecond
        var r: JSONObject = ["id": 7, "data": text]
        if blobTotal { r["total"] = total }
        if sendsEof { r["eof"] = end >= bytes.count }
        return r
    }

    private func slice(from offset: Int, max: Int) -> (String, Int) {
        var start = min(offset, bytes.count)
        var lead = ""
        while start < bytes.count, bytes[start] & 0xC0 == 0x80 {
            lead += "\u{FFFD}"
            start += 1
        }
        var end = min(bytes.count, start + max)
        while end < bytes.count, end > start, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        return (lead + String(decoding: bytes[start..<end], as: UTF8.self), end)
    }
}
