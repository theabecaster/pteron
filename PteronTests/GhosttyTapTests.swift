import XCTest
@testable import Pteron

private let esc = "\u{1b}"
private let bel = "\u{07}"

private func core(_ text: String, cols: Int = 40, rows: Int = 10) -> GhosttyCore {
    let core = GhosttyCore(cols: cols, rows: rows)
    core.feed(Array(text.utf8))
    core.sync()
    return core
}

/// OSC 8 hyperlinks and web addresses under a tapped cell.
@MainActor
final class GhosttyLinkLookupTests: XCTestCase {
    private func link(_ url: String, _ text: String, params: String = "") -> String {
        "\(esc)]8;\(params);\(url)\(esc)\\\(text)\(esc)]8;;\(esc)\\"
    }

    func testAHyperlinkIsOnItsCellsOnly() {
        let c = core("ab \(link("https://example.com/a", "link")) cd")
        for col in 3...6 {
            XCTAssertEqual(c.link(atViewportCol: col, row: 0), GhosttyTappedLink(url: "https://example.com/a", explicit: true), "col \(col)")
        }
        for col in [0, 1, 2, 7, 8, 9, 20] { XCTAssertNil(c.link(atViewportCol: col, row: 0), "col \(col)") }
        XCTAssertNil(c.link(atViewportCol: 3, row: 1))
        // Outside the grid is no cell.
        XCTAssertNil(c.link(atViewportCol: 400, row: 0))
        XCTAssertNil(c.link(atViewportCol: 0, row: 400))
        XCTAssertNil(c.link(atViewportCol: -1, row: -1))
    }

    func testParametersAreNotPartOfTheAddressAndAnySchemeIsKept() {
        let c = core(link("file://host/tmp/a%20b.txt", "file", params: "id=7:x=y") + " " + link("mailto:a@b.c", "mail"))
        XCTAssertEqual(c.link(atViewportCol: 1, row: 0)?.url, "file://host/tmp/a%20b.txt")
        XCTAssertEqual(c.link(atViewportCol: 6, row: 0)?.url, "mailto:a@b.c")
    }

    func testAHyperlinkThatWrapsIsOnEveryRowOfIt() {
        // 10 columns: "0123456" then a 14-character link that fills the row and wraps twice.
        let c = core("0123456" + link("https://example.com/wrapped", "ABCDEFGHIJKLMN"), cols: 10, rows: 6)
        XCTAssertEqual(c.rowText(0), "0123456ABC")
        XCTAssertEqual(c.rowText(1), "DEFGHIJKLM")
        XCTAssertEqual(c.rowText(2), "N")
        let want = GhosttyTappedLink(url: "https://example.com/wrapped", explicit: true)
        XCTAssertNil(c.link(atViewportCol: 6, row: 0))
        XCTAssertEqual(c.link(atViewportCol: 7, row: 0), want)
        XCTAssertEqual(c.link(atViewportCol: 9, row: 0), want)
        XCTAssertEqual(c.link(atViewportCol: 0, row: 1), want)
        XCTAssertEqual(c.link(atViewportCol: 9, row: 1), want)
        XCTAssertEqual(c.link(atViewportCol: 0, row: 2), want)
        XCTAssertNil(c.link(atViewportCol: 1, row: 2))
    }

    func testBothHalvesOfAWideCharacterCarryTheHyperlink() {
        let c = core("a" + link("https://example.jp/", "日本") + "b")
        for col in 1...4 { XCTAssertEqual(c.link(atViewportCol: col, row: 0)?.url, "https://example.jp/", "col \(col)") }
        XCTAssertNil(c.link(atViewportCol: 0, row: 0))
        XCTAssertNil(c.link(atViewportCol: 5, row: 0))
    }

    func testAHyperlinkInScrollbackIsFoundWhereItIsDrawn() {
        // The link scrolls to the top row of a 4-row screen, then off it.
        let c = core(link("https://example.com/old", "old") + "\r\n1\r\n2\r\n3", cols: 20, rows: 4)
        XCTAssertEqual(c.link(atViewportCol: 0, row: 0)?.url, "https://example.com/old")
        c.feed(Array("\r\n4".utf8))
        c.sync()
        XCTAssertNil(c.link(atViewportCol: 0, row: 0), "row 0 now shows \"1\"")
    }

    func testAWebAddressInTextIsFound() {
        let text = "see https://example.com/path?q=1&r=2#frag, ok"
        let c = core(text, cols: 60)
        let start = 4, end = start + "https://example.com/path?q=1&r=2#frag".count
        for col in start..<end {
            XCTAssertEqual(c.link(atViewportCol: col, row: 0), GhosttyTappedLink(url: "https://example.com/path?q=1&r=2#frag", explicit: false), "col \(col)")
        }
        // The words around it, the comma after it and blank cells are not the address.
        for col in [0, 1, 2, 3, end, end + 1, end + 2, 55] { XCTAssertNil(c.link(atViewportCol: col, row: 0), "col \(col)") }
    }

    func testAWebAddressThatSoftWrapsIsOneAddress() {
        let url = "https://example.com/a/very/long/path/that/wraps/over/rows?x=1"
        let c = core("go " + url + " now\r\nhttps://example.com/next", cols: 20, rows: 8)
        XCTAssertEqual(c.rowText(0), "go https://example.c")
        // Every cell of the address, on each of its rows.
        let cells = Array(("go " + url).indices).count
        for i in 3..<cells {
            XCTAssertEqual(c.link(atViewportCol: i % 20, row: i / 20)?.url, url, "cell \(i)")
        }
        XCTAssertNil(c.link(atViewportCol: 1, row: 0))
        // A line break ends it: the next line's address is its own.
        let nextRow = (cells + 4 - 1) / 20 + 1
        XCTAssertEqual(c.link(atViewportCol: 3, row: nextRow)?.url, "https://example.com/next")
    }

    func testAnOSC8HyperlinkWinsOverTheTextUnderIt() {
        let c = core(link("https://real.example/", "https://shown.example/"))
        XCTAssertEqual(c.link(atViewportCol: 10, row: 0), GhosttyTappedLink(url: "https://real.example/", explicit: true))
    }

    func testAddressesInText() {
        func find(_ line: String, _ needle: Character) -> String? {
            let scalars = Array(line.unicodeScalars)
            guard let at = line.unicodeScalars.firstIndex(where: { Character($0) == needle }) else { return nil }
            return GhosttyLinkText.url(in: scalars, at: line.unicodeScalars.distance(from: line.unicodeScalars.startIndex, to: at))
        }
        XCTAssertEqual(find("(https://en.wikipedia.org/wiki/A_(b)) x", "w"), "https://en.wikipedia.org/wiki/A_(b)")
        XCTAssertEqual(find("[docs](https://example.com/z).", "z"), "https://example.com/z")
        XCTAssertEqual(find("HTTP://EXAMPLE.COM/Q yes", "Q"), "HTTP://EXAMPLE.COM/Q")
        XCTAssertEqual(find("\"https://example.com/q\"", "q"), "https://example.com/q")
        XCTAssertEqual(find("│ https://example.com/q │", "q"), "https://example.com/q")
        XCTAssertEqual(find("<https://example.com/q>", "q"), "https://example.com/q")
        XCTAssertEqual(find("a https://one.example/1 https://two.example/2", "2"), "https://two.example/2")
        XCTAssertEqual(find("http://localhost:3000/z?", "z"), "http://localhost:3000/z")
        // Not addresses: no scheme, another scheme, a scheme inside a word, nothing after it.
        XCTAssertNil(find("example.com/q", "q"))
        XCTAssertNil(find("ftp://example.com/q", "q"))
        XCTAssertNil(find("xhttps://example.com/q", "q"))
        XCTAssertNil(find("https:// q", "q"))
        XCTAssertNil(find("https://", "h"))
        XCTAssertNil(GhosttyLinkText.url(in: [], at: 0))
        XCTAssertNil(GhosttyLinkText.url(in: Array("https://a.b".unicodeScalars), at: 99))
    }
}

/// OSC 133: a tap on the prompt's input moves the shell's cursor.
@MainActor
final class GhosttyPromptClickTests: XCTestCase {
    /// A prompt "$ " with `input` typed after it. `options` go on the `OSC 133 ; A`.
    private func prompt(_ input: String, options: String = ";cl=line") -> String {
        "\(esc)]133;A\(options)\(bel)$ \(esc)]133;B\(bel)\(input)"
    }

    func testTheClickModeTheShellAnnounces() {
        func mode(_ s: String) -> GhosttyPromptClickMode? { GhosttyPromptClickMode.announced(by: Array(s.utf8)) }
        XCTAssertEqual(mode("A;cl=line"), .cursorKeys)
        XCTAssertEqual(mode("A;cl=m"), .cursorKeys)
        XCTAssertEqual(mode("A;cl=v"), .cursorKeys)
        XCTAssertEqual(mode("A;cl=w"), .cursorKeys)
        XCTAssertEqual(mode("N;aid=7;cl=line"), .cursorKeys)
        XCTAssertEqual(mode("A;redraw=last;cl=line;aid=123"), .cursorKeys)
        XCTAssertEqual(mode("A;click_events=1"), .clickEvents(relative: false))
        XCTAssertEqual(mode("A;click_events=2"), .clickEvents(relative: true))
        XCTAssertEqual(mode("A;cl=line;click_events=1"), .clickEvents(relative: false), "click events win")
        XCTAssertEqual(mode("A;click_events=0;cl=v"), .cursorKeys, "falls back to cl")
        // Nothing announced: the mode stays as it was.
        XCTAssertNil(mode("A"))
        XCTAssertNil(mode("A;aid=1"))
        XCTAssertNil(mode("A;cl=bogus"))
        XCTAssertNil(mode("A;click_events=3"))
        XCTAssertNil(mode("B;cl=line"))
        XCTAssertNil(mode("P;k=i;cl=line"))
        XCTAssertNil(mode("AA;cl=line"))
        XCTAssertNil(mode(""))
    }

    func testNothingMovesUnlessTheShellAskedForClicks() {
        XCTAssertEqual(core(prompt("echo hello", options: "")).promptClick(viewportCol: 4, row: 0), .none)
        XCTAssertEqual(core("$ echo hello").promptClick(viewportCol: 4, row: 0), .none)
        XCTAssertEqual(core(prompt("echo hello")).promptClick(viewportCol: 4, row: 0), .keys(left: 8, right: 0))
    }

    func testLeftFromTheEndOfTheLine() {
        // "$ echo hello": input in columns 2 to 11, cursor on column 12.
        let c = core(prompt("echo hello"))
        XCTAssertEqual(c.cursorPosition.x, 12)
        XCTAssertEqual(c.promptClick(viewportCol: 11, row: 0), .keys(left: 1, right: 0))
        XCTAssertEqual(c.promptClick(viewportCol: 7, row: 0), .keys(left: 5, right: 0))
        XCTAssertEqual(c.promptClick(viewportCol: 2, row: 0), .keys(left: 10, right: 0))
        // On the prompt text: the start of the input.
        XCTAssertEqual(c.promptClick(viewportCol: 0, row: 0), .keys(left: 10, right: 0))
        // On the cursor, or past the end of the text: nowhere to go.
        XCTAssertEqual(c.promptClick(viewportCol: 12, row: 0), .none)
        XCTAssertEqual(c.promptClick(viewportCol: 30, row: 0), .none)
    }

    func testRightFromTheMiddleOfTheLine() {
        // The cursor moved back to the "h" of hello (column 7).
        let c = core(prompt("echo hello") + "\(esc)[5D")
        XCTAssertEqual(c.cursorPosition.x, 7)
        XCTAssertEqual(c.promptClick(viewportCol: 8, row: 0), .keys(left: 0, right: 1))
        XCTAssertEqual(c.promptClick(viewportCol: 11, row: 0), .keys(left: 0, right: 4))
        // Past the end of the text: after the last character.
        XCTAssertEqual(c.promptClick(viewportCol: 12, row: 0), .keys(left: 0, right: 5))
        XCTAssertEqual(c.promptClick(viewportCol: 39, row: 0), .keys(left: 0, right: 5))
        XCTAssertEqual(c.promptClick(viewportCol: 3, row: 0), .keys(left: 4, right: 0))
        XCTAssertEqual(c.promptClick(viewportCol: 7, row: 0), .none)
    }

    func testAWideCharacterIsOneStep() {
        // "$ 日本語abc": 日 2-3, 本 4-5, 語 6-7, a 8, b 9, c 10, cursor 11.
        let c = core(prompt("日本語abc"))
        XCTAssertEqual(c.cursorPosition.x, 11)
        XCTAssertEqual(c.promptClick(viewportCol: 8, row: 0), .keys(left: 3, right: 0))
        XCTAssertEqual(c.promptClick(viewportCol: 6, row: 0), .keys(left: 4, right: 0))
        XCTAssertEqual(c.promptClick(viewportCol: 7, row: 0), .keys(left: 4, right: 0), "the right half is the same character")
        XCTAssertEqual(c.promptClick(viewportCol: 4, row: 0), .keys(left: 5, right: 0))
        XCTAssertEqual(c.promptClick(viewportCol: 2, row: 0), .keys(left: 6, right: 0))
        // And to the right, from the start of the input.
        let back = core(prompt("日本語abc") + "\(esc)[1;3H")
        XCTAssertEqual(back.cursorPosition.x, 2)
        XCTAssertEqual(back.promptClick(viewportCol: 5, row: 0), .keys(left: 0, right: 1))
        XCTAssertEqual(back.promptClick(viewportCol: 8, row: 0), .keys(left: 0, right: 3))
        XCTAssertEqual(back.promptClick(viewportCol: 30, row: 0), .keys(left: 0, right: 6))
    }

    func testInputThatSoftWrapsIsOneLine() {
        // 20 columns: "$ " and 30 characters. Row 0 holds 18 of them, row 1 the other 12.
        let input = "abcdefghijklmnopqrstuvwxyz0123"
        let c = core(prompt(input), cols: 20, rows: 6)
        XCTAssertEqual(c.rowText(0), "$ abcdefghijklmnopqr")
        XCTAssertEqual(c.rowText(1), "stuvwxyz0123")
        XCTAssertEqual(c.cursorPosition.x, 12)
        XCTAssertEqual(c.cursorPosition.y, 1)
        XCTAssertEqual(c.promptClick(viewportCol: 4, row: 1), .keys(left: 8, right: 0))
        XCTAssertEqual(c.promptClick(viewportCol: 19, row: 0), .keys(left: 13, right: 0))
        XCTAssertEqual(c.promptClick(viewportCol: 5, row: 0), .keys(left: 27, right: 0))
        XCTAssertEqual(c.promptClick(viewportCol: 0, row: 0), .keys(left: 30, right: 0))
        // From the first row down onto the second.
        let up = core(prompt(input) + "\(esc)[1;6H", cols: 20, rows: 6)
        XCTAssertEqual(up.cursorPosition.x, 5)
        XCTAssertEqual(up.cursorPosition.y, 0)
        XCTAssertEqual(up.promptClick(viewportCol: 19, row: 0), .keys(left: 0, right: 14))
        XCTAssertEqual(up.promptClick(viewportCol: 0, row: 1), .keys(left: 0, right: 15))
        XCTAssertEqual(up.promptClick(viewportCol: 3, row: 1), .keys(left: 0, right: 18))
        XCTAssertEqual(up.promptClick(viewportCol: 15, row: 1), .keys(left: 0, right: 27), "past the end: after the last character")
    }

    func testTheMoveItself() {
        // The walk on rows made by hand: a hard line break ends it, a cursor waiting to wrap
        // stands after its cell.
        func row(_ s: String, wrap: Bool = false, continuation: Bool = false, kind: GhosttyPromptRow.Kind = .none) -> GhosttyPromptRow {
            GhosttyPromptRow(input: s.map { $0 == "i" }, wrap: wrap, wrapContinuation: continuation, kind: kind)
        }
        func keys(_ rows: [GhosttyPromptRow], cursor: (Int, Int), pending: Bool = false, click: (Int, Int)) -> [Int] {
            let m = GhosttyPromptMove.keys(cursor: (cursor.0, cursor.1), pendingWrap: pending, click: (click.0, click.1)) {
                $0 >= 0 && $0 < rows.count ? rows[$0] : nil
            }
            return [m.left, m.right]
        }
        let twoLines = [row("ppiiii", kind: .prompt), row("ppiiii", kind: .continuation)]
        XCTAssertEqual(keys(twoLines, cursor: (3, 0), click: (4, 1)), [0, 3], "stops at the end of the first line")
        XCTAssertEqual(keys(twoLines, cursor: (3, 1), click: (4, 0)), [1, 0], "stops at the start of the second line")
        let wrapped = [row("ppiiii", wrap: true, kind: .prompt), row("iiii..", continuation: true, kind: .continuation)]
        XCTAssertEqual(keys(wrapped, cursor: (3, 0), click: (2, 1)), [0, 5])
        XCTAssertEqual(keys(wrapped, cursor: (2, 1), click: (3, 0)), [5, 0])
        // Waiting to wrap after the last cell of row 0: logically at the start of row 1.
        XCTAssertEqual(keys(wrapped, cursor: (5, 0), pending: true, click: (5, 0)), [1, 0])
        XCTAssertEqual(keys(wrapped, cursor: (5, 0), pending: true, click: (2, 0)), [4, 0])
        XCTAssertEqual(keys(wrapped, cursor: (5, 0), pending: true, click: (2, 1)), [0, 2])
        XCTAssertEqual(keys(wrapped, cursor: (5, 0), click: (2, 1)), [0, 3])
        // A row that isn't this prompt's continuation is not walked into.
        let output = [row("ppiiii", wrap: true, kind: .prompt), row("iiii..")]
        XCTAssertEqual(keys(output, cursor: (3, 0), click: (2, 1)), [0, 2])
        XCTAssertEqual(keys(wrapped, cursor: (3, 0), click: (3, 0)), [0, 0])
        XCTAssertEqual(keys([], cursor: (3, 0), click: (1, 0)), [0, 0])
    }

    func testNotWhileACommandRunsNorOnOtherScreensNorAboveThePrompt() {
        // The command started (OSC 133 C) and writes output.
        let running = core(prompt("sleep 9") + "\(esc)]133;C\(bel)\r\nworking")
        XCTAssertEqual(running.promptClick(viewportCol: 3, row: 0), .none)
        XCTAssertEqual(running.promptClick(viewportCol: 3, row: 1), .none)
        // The alternate screen is never a prompt.
        let alternate = core(prompt("vim") + "\(esc)[?1049h")
        XCTAssertEqual(alternate.promptClick(viewportCol: 3, row: 0), .none)
        // Back on the primary screen it is one again.
        alternate.feed(Array("\(esc)[?1049l".utf8))
        alternate.sync()
        XCTAssertEqual(alternate.promptClick(viewportCol: 3, row: 0), .keys(left: 2, right: 0))
        // A program that tracks the mouse gets the click itself.
        XCTAssertEqual(core(prompt("abc") + "\(esc)[?1000h").promptClick(viewportCol: 3, row: 0), .none)
        // Output above the prompt.
        let below = core("output\r\nmore\r\n" + prompt("echo hi"))
        XCTAssertEqual(below.promptClick(viewportCol: 3, row: 0), .none)
        XCTAssertEqual(below.promptClick(viewportCol: 3, row: 1), .none)
        XCTAssertEqual(below.promptClick(viewportCol: 3, row: 2), .keys(left: 6, right: 0))
    }

    func testNotWhileTextIsSelected() {
        let c = core(prompt("echo hello"))
        let anchor = GhosttySelectionAnchor(core: c)
        XCTAssertTrue(c.beginSelection(col: 3, row: 0, word: true, anchor: anchor))
        XCTAssertEqual(c.promptClick(viewportCol: 4, row: 0), .none)
        _ = c.clearSelection()
        XCTAssertEqual(c.promptClick(viewportCol: 4, row: 0), .keys(left: 8, right: 0))
    }

    func testAPromptInScrollbackIsNotClicked() {
        // 30 lines of output push the first prompt into history; scrolled up, it is drawn again.
        let c = core(prompt("old") + "\(esc)]133;C\(bel)\r\n" + (1...30).map { "\($0)\r\n" }.joined() + "\(esc)]133;D\(bel)" + prompt("new"), rows: 6)
        XCTAssertEqual(c.promptClick(viewportCol: 2, row: 5), .keys(left: 3, right: 0))
        XCTAssertEqual(c.promptClick(viewportCol: 2, row: 4), .none)
    }

    func testClickEventsSendAPressToTheShell() {
        let absolute = core("one\r\ntwo\r\n" + prompt("echo hi", options: ";click_events=1"))
        XCTAssertEqual(absolute.promptClick(viewportCol: 4, row: 2), .press(column: 5, row: 3))
        XCTAssertEqual(absolute.promptClick(viewportCol: 30, row: 4), .press(column: 31, row: 5), "below the prompt: the shell decides")
        XCTAssertEqual(absolute.promptClick(viewportCol: 4, row: 1), .none, "above the prompt")
        let relative = core("one\r\ntwo\r\n" + prompt("echo hi", options: ";click_events=2"))
        XCTAssertEqual(relative.promptClick(viewportCol: 4, row: 2), .press(column: 5, row: 1))
        XCTAssertEqual(relative.promptClick(viewportCol: 0, row: 3), .press(column: 1, row: 2))
        XCTAssertEqual(GhosttyPromptClick.pressBytes(column: 5, row: 3), Array("\(esc)[<0;5;3M".utf8))
    }

    func testTheModeIsReadFromTheStreamHoweverItIsCut() {
        let bytes = Array(prompt("echo hello", options: ";aid=42;cl=line").utf8)
        for cut in 1..<bytes.count {
            let c = GhosttyCore(cols: 40, rows: 10)
            c.feed(Array(bytes[..<cut]))
            c.sync()
            c.feed(Array(bytes[cut...]))
            c.sync()
            XCTAssertEqual(c.promptClick(viewportCol: 4, row: 0), .keys(left: 8, right: 0), "cut at \(cut)")
            XCTAssertEqual(c.rowText(0), "$ echo hello", "cut at \(cut)")
        }
        // The string terminator form, and other strings around it.
        let st = core("\(esc)]0;title\(bel)\(esc)]133;A;cl=line\(esc)\\$ \(esc)]133;B\(esc)\\ab\(esc)]8;;https://x.y\(esc)\\c\(esc)]8;;\(esc)\\")
        XCTAssertEqual(st.promptClick(viewportCol: 2, row: 0), .keys(left: 3, right: 0))
    }

    func testTheModeFollowsTheShell() {
        let c = core(prompt("one"))
        XCTAssertEqual(c.promptClick(viewportCol: 2, row: 0), .keys(left: 3, right: 0))
        // A new prompt without options keeps the mode, as in Ghostty.
        c.feed(Array(("\r\n" + prompt("two", options: "")).utf8))
        c.sync()
        XCTAssertEqual(c.promptClick(viewportCol: 2, row: 1), .keys(left: 3, right: 0))
        // The shell switches to click events.
        c.feed(Array(("\r\n" + prompt("three", options: ";click_events=1")).utf8))
        c.sync()
        XCTAssertEqual(c.promptClick(viewportCol: 2, row: 2), .press(column: 3, row: 3))
        // A full reset forgets it, from the stream or from the host.
        c.feed(Array(("\(esc)c" + prompt("four", options: "")).utf8))
        c.sync()
        XCTAssertEqual(c.promptClick(viewportCol: 2, row: 0), .none)
        c.feed(Array(("\r\n" + prompt("five")).utf8))
        c.sync()
        XCTAssertEqual(c.promptClick(viewportCol: 2, row: 1), .keys(left: 4, right: 0))
        c.reset()
        c.feed(Array(prompt("six", options: "").utf8))
        c.sync()
        XCTAssertEqual(c.promptClick(viewportCol: 2, row: 0), .none)
        // A cancelled string and one that is too long to be ours set nothing.
        let cancelled = core("\(esc)]133;A;cl=line\u{18}" + prompt("abc", options: ""))
        XCTAssertEqual(cancelled.promptClick(viewportCol: 2, row: 0), .none)
        let long = core(prompt("abc", options: ";aid=" + String(repeating: "x", count: 400) + ";cl=line"))
        XCTAssertEqual(long.promptClick(viewportCol: 2, row: 0), .none)
    }

    func testWatchingTheStreamChangesNothingOnScreen() {
        // Every kind of string in the way, fed whole and a byte at a time: the same screen.
        // (OSC 133 A starts a fresh line, so the text goes on in the next row.)
        let text = "a\(esc)]0;t\(bel)b\(esc)]133;A;cl=line\(bel)c\(esc)]52;c;aGk=\(esc)\\d\(esc)_apc\(esc)\\e\(esc)Pdcs\(esc)\\f\(esc)[1mg\(esc)]unterminated"
        let whole = core(text)
        let c = GhosttyCore(cols: 40, rows: 10)
        for byte in Array(text.utf8) {
            c.feed([byte])
            c.sync()
        }
        for each in [whole, c] {
            XCTAssertEqual(each.rowText(0), "ab")
            XCTAssertEqual(each.rowText(1), "cdefg")
            XCTAssertEqual(each.cursorPosition.x, 5)
            XCTAssertEqual(each.promptClick(viewportCol: 0, row: 1), .none, "no input cells: nothing to move over")
        }
    }
}

/// Which of the things a tap can do it does.
@MainActor
final class GhosttyTapRoutingTests: XCTestCase {
    private final class Sink: TerminalEngineDelegate {
        var sent: [[UInt8]] = []
        func engineGridChanged(cols: Int, rows: Int) {}
        func engineSend(_ bytes: [UInt8]) { sent.append(bytes) }
    }

    func testDecisionTable() {
        let explicit = GhosttyTappedLink(url: "https://osc8.example/", explicit: true)
        let plain = GhosttyTappedLink(url: "https://text.example/", explicit: false)
        let move = GhosttyPromptClick.keys(left: 3, right: 0)
        func act(focused: Bool = true, shift: Bool = false, selection: Bool = false, link: GhosttyTappedLink? = nil,
                 tracking: Bool = false, near: Bool = false, prompt: GhosttyPromptClick = .none) -> GhosttyTapAction {
            GhosttyTapRouting.action(focusedAtTouch: focused, shift: shift, hasSelection: selection,
                                     probe: GhosttyTapProbe(link: link, mouseTracking: tracking, nearCursor: near, prompt: prompt))
        }
        // A pane without the keyboard: the tap only focuses, whatever is under it.
        XCTAssertEqual(act(focused: false), .focusOnly)
        XCTAssertEqual(act(focused: false, link: explicit, tracking: true, prompt: move), .focusOnly)
        XCTAssertEqual(act(focused: false, selection: true), .focusOnly)
        // Shift keeps the tap from the program and does nothing else.
        XCTAssertEqual(act(shift: true, link: explicit, tracking: true, prompt: move), .nothing)
        // A selection is dismissed before anything else.
        XCTAssertEqual(act(selection: true, link: explicit), .dismissSelection)
        XCTAssertEqual(act(selection: true, tracking: true), .dismissSelection)
        XCTAssertEqual(act(selection: true, prompt: move), .dismissSelection)
        // An OSC 8 hyperlink opens, also under mouse tracking and next to the cursor.
        XCTAssertEqual(act(link: explicit), .open("https://osc8.example/"))
        XCTAssertEqual(act(link: explicit, tracking: true), .open("https://osc8.example/"))
        XCTAssertEqual(act(link: explicit, near: true, prompt: move), .open("https://osc8.example/"))
        // An address in the text opens under mouse tracking too (the phone's Cmd-click); a program
        // that tracks the mouse gets every other tap as a click.
        XCTAssertEqual(act(link: plain, tracking: true), .open("https://text.example/"))
        XCTAssertEqual(act(tracking: true), .mouseClick)
        XCTAssertEqual(act(tracking: true, near: true, prompt: move), .mouseClick)
        // An address in the text opens otherwise.
        XCTAssertEqual(act(link: plain), .open("https://text.example/"))
        XCTAssertEqual(act(link: plain, near: true, prompt: move), .open("https://text.example/"))
        // Next to the cursor nothing moves; elsewhere on the prompt the cursor does.
        XCTAssertEqual(act(near: true, prompt: move), .nothing)
        XCTAssertEqual(act(prompt: move), .prompt(move))
        XCTAssertEqual(act(prompt: .press(column: 2, row: 3)), .prompt(.press(column: 2, row: 3)))
        XCTAssertEqual(act(), .nothing)
    }

    func testTheProbeReadsTheTerminal() {
        let link = "\(esc)]8;;https://osc8.example/\(esc)\\L\(esc)]8;;\(esc)\\"
        let c = core("\(link) https://text.example/ x\r\n\(esc)]133;A;cl=line\(bel)$ \(esc)]133;B\(bel)echo hello world")
        XCTAssertEqual(c.tapProbe(viewportCol: 0, row: 0), GhosttyTapProbe(link: GhosttyTappedLink(url: "https://osc8.example/", explicit: true)))
        XCTAssertEqual(c.tapProbe(viewportCol: 5, row: 0), GhosttyTapProbe(link: GhosttyTappedLink(url: "https://text.example/", explicit: false)))
        // The cursor is on column 18 of row 1.
        XCTAssertEqual(c.tapProbe(viewportCol: 4, row: 1), GhosttyTapProbe(prompt: .keys(left: 14, right: 0)))
        XCTAssertEqual(c.tapProbe(viewportCol: 15, row: 1), GhosttyTapProbe(nearCursor: true))
        XCTAssertEqual(c.tapProbe(viewportCol: 14, row: 1), GhosttyTapProbe(prompt: .keys(left: 4, right: 0)))
        XCTAssertEqual(c.tapProbe(viewportCol: 18, row: 2), GhosttyTapProbe(nearCursor: true))
        XCTAssertEqual(c.tapProbe(viewportCol: 30, row: 5), GhosttyTapProbe())
        // Mouse tracking: both kinds of link are still looked up, the prompt and the cursor aren't.
        c.feed(Array("\(esc)[?1000h".utf8))
        c.sync()
        XCTAssertEqual(c.tapProbe(viewportCol: 0, row: 0), GhosttyTapProbe(link: GhosttyTappedLink(url: "https://osc8.example/", explicit: true), mouseTracking: true))
        XCTAssertEqual(c.tapProbe(viewportCol: 5, row: 0), GhosttyTapProbe(link: GhosttyTappedLink(url: "https://text.example/", explicit: false), mouseTracking: true))
        XCTAssertEqual(c.tapProbe(viewportCol: 4, row: 1), GhosttyTapProbe(mouseTracking: true))
    }

    // MARK: Through the view

    private func make(_ text: String, cols: Int = 40, rows: Int = 10) -> (GhosttyTerminalView, Sink) {
        let view = GhosttyTerminalView(frame: .zero, fontSize: 12, cols: cols, rows: rows)
        let cell = view.cellSize
        view.frame = CGRect(x: 0, y: 0, width: CGFloat(cols) * cell.width, height: CGFloat(rows) * cell.height)
        view.layoutIfNeeded()
        let sink = Sink()
        view.engineDelegate = sink
        view.feed(text: text)
        frame(view)
        return (view, sink)
    }

    private func frame(_ view: GhosttyTerminalView) {
        view.core.sync()
        _ = view.renderer.frame.update(core: view.core)
        view.scroller.apply(view.core.scroll.snapshot)
    }

    private var now: CFTimeInterval = 100

    /// A tap in the middle of a cell, as the host's tap passes it on, `after` seconds after the
    /// one before.
    private func tap(_ view: GhosttyTerminalView, col: Int, row: Int, focused: Bool = true, shift: Bool = false,
                     after: CFTimeInterval = 2) -> Bool {
        let rect = view.viewportRect(row: row, columns: col..<(col + 1))
        now += after
        let at = now
        view.taps.clock = { at }
        return view.tapOpensLinkOrMovesCursor(at: CGPoint(x: rect.midX, y: rect.midY), focused: focused, shift: shift)
    }

    func testTheNextTapOfADoubleTapIsLeftToTheSelection() {
        let (view, sink) = make("see https://text.example/z ok\r\n\r\n\(esc)]133;A;cl=line\(bel)$ \(esc)]133;B\(bel)echo hello world and more")
        var opened: [URL] = []
        view.taps.open = { url, _ in opened.append(url) }
        // The shell hasn't moved its cursor yet: a second tap must not send the keys again.
        XCTAssertTrue(tap(view, col: 4, row: 2))
        XCTAssertFalse(tap(view, col: 4, row: 2, after: 0.2))
        XCTAssertFalse(tap(view, col: 5, row: 2, after: 0.2), "a third tap, a cell away")
        XCTAssertEqual(sink.sent.count, 1)
        // Later, or somewhere else, it is a tap of its own.
        XCTAssertTrue(tap(view, col: 4, row: 2, after: 0.6))
        XCTAssertTrue(tap(view, col: 16, row: 2, after: 0.1), "far enough away")
        XCTAssertEqual(sink.sent.count, 3)
        // A link opens once for a double tap.
        XCTAssertTrue(tap(view, col: 8, row: 0))
        XCTAssertFalse(tap(view, col: 8, row: 0, after: 0.2))
        XCTAssertEqual(opened.count, 1)
        // A tap that used nothing up starts no such window.
        XCTAssertFalse(tap(view, col: 1, row: 0))
        XCTAssertTrue(tap(view, col: 8, row: 2, after: 0.1))
    }


    func testATapOnALinkOpensItOnlyOnAFocusedPane() {
        let (view, sink) = make("\(esc)]8;;https://osc8.example/a?b=c\(esc)\\link\(esc)]8;;\(esc)\\ and https://text.example/z ok")
        var opened: [URL] = []
        view.taps.open = { url, _ in opened.append(url) }
        XCTAssertFalse(tap(view, col: 1, row: 0, focused: false), "the first tap on a pane only focuses it")
        XCTAssertFalse(tap(view, col: 1, row: 0, shift: true))
        XCTAssertEqual(opened, [])
        XCTAssertTrue(tap(view, col: 1, row: 0))
        XCTAssertTrue(tap(view, col: 12, row: 0))
        XCTAssertFalse(tap(view, col: 5, row: 0), "the word between them")
        XCTAssertFalse(tap(view, col: 20, row: 4), "an empty cell")
        XCTAssertEqual(opened.map(\.absoluteString), ["https://osc8.example/a?b=c", "https://text.example/z"])
        XCTAssertEqual(sink.sent, [], "opening a link sends nothing to the program")
    }

    func testAMouseTrackingProgramKeepsItsClicksExceptOnALink() {
        let (view, sink) = make("\(esc)[?1000h\(esc)[?1006h\(esc)]8;;https://osc8.example/\(esc)\\link\(esc)]8;;\(esc)\\ https://text.example/ menu")
        var opened: [URL] = []
        view.taps.open = { url, _ in opened.append(url) }
        XCTAssertTrue(tap(view, col: 8, row: 0), "an address in the text opens, as a Cmd-click does on a Mac")
        XCTAssertTrue(tap(view, col: 1, row: 0))
        XCTAssertFalse(tap(view, col: 28, row: 0), "the word after it is the program's to click")
        XCTAssertEqual(opened.map(\.absoluteString), ["https://text.example/", "https://osc8.example/"])
        XCTAssertEqual(sink.sent, [])
    }

    func testWithoutTheKeyboardOnlyALinkIsUsed() {
        let (view, sink) = make("see https://text.example/z ok\r\n\r\n\(esc)]133;A;cl=line\(bel)$ \(esc)]133;B\(bel)echo hello world")
        var opened: [URL] = []
        view.taps.open = { url, _ in opened.append(url) }
        func tapLink(col: Int, row: Int) -> Bool {
            let rect = view.viewportRect(row: row, columns: col..<(col + 1))
            now += 2
            let at = now
            view.taps.clock = { at }
            return view.tapOpensLink(at: CGPoint(x: rect.midX, y: rect.midY))
        }
        XCTAssertTrue(tapLink(col: 8, row: 0))
        XCTAssertEqual(opened.map(\.absoluteString), ["https://text.example/z"])
        XCTAssertFalse(tapLink(col: 1, row: 0), "a plain word")
        XCTAssertFalse(tapLink(col: 4, row: 2), "the prompt's cursor never moves from this tap")
        XCTAssertEqual(sink.sent, [])
    }

    func testATapOnThePromptSendsArrowKeysInTheCursorKeyMode() {
        let line = "\(esc)]133;A;cl=line\(bel)$ \(esc)]133;B\(bel)echo hello world"
        let (view, sink) = make(line)
        XCTAssertFalse(tap(view, col: 4, row: 0, focused: false))
        XCTAssertEqual(sink.sent, [])
        // The cursor is on column 18: 14 steps left to column 4, in one write.
        XCTAssertTrue(tap(view, col: 4, row: 0))
        XCTAssertEqual(sink.sent, [Array(String(repeating: "\(esc)[D", count: 14).utf8)])
        // Within 3 columns of the cursor nothing is sent (the host shows its Paste menu there).
        XCTAssertFalse(tap(view, col: 16, row: 0))
        XCTAssertEqual(sink.sent.count, 1)
        // Application cursor keys (DECCKM).
        view.feed(text: "\(esc)[?1h\(esc)[10D")
        frame(view)
        sink.sent = []
        XCTAssertTrue(tap(view, col: 2, row: 0))
        XCTAssertEqual(sink.sent, [Array(String(repeating: "\(esc)OD", count: 6).utf8)])
        sink.sent = []
        XCTAssertTrue(tap(view, col: 30, row: 0))
        // From column 8: the 9 characters after the cursor's, and one more to stand after the last.
        XCTAssertEqual(sink.sent, [Array(String(repeating: "\(esc)OC", count: 10).utf8)])
        // While a selection is up the tap is the host's (it clears the selection).
        sink.sent = []
        view.beginSelection(at: view.viewportRect(row: 0, columns: 3..<4).origin, word: true)
        XCTAssertTrue(view.hasActiveSelection)
        XCTAssertFalse(tap(view, col: 30, row: 0))
        XCTAssertEqual(sink.sent, [])
    }

    func testAShellThatAskedForClickEventsGetsAPress() {
        let (view, sink) = make("\(esc)]133;A;click_events=1\(bel)> \(esc)]133;B\(bel)echo hello world")
        XCTAssertTrue(tap(view, col: 5, row: 0))
        XCTAssertEqual(sink.sent, [Array("\(esc)[<0;6;1M".utf8)])
    }

    func testATapOnThePromptReturnsAScrolledUpViewToTheBottom() {
        let (view, sink) = make((1...40).map { "\($0)\r\n" }.joined() + "\(esc)]133;A;cl=line\(bel)$ \(esc)]133;B\(bel)echo hello world")
        XCTAssertTrue(tap(view, col: 4, row: 9))
        XCTAssertEqual(sink.sent.count, 1)
        // Scrolled up, the prompt's row shows history: nothing to click there.
        view.scrollLines(-5)
        frame(view)
        sink.sent = []
        XCTAssertFalse(tap(view, col: 4, row: 9))
        XCTAssertEqual(sink.sent, [])
    }
}
