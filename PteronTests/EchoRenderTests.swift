import Metal
import RexKit
import Synchronization
import XCTest
@testable import Pteron

/// A pane at a shell prompt marked with OSC 133, with a predictor a test drives by hand: what
/// the host will tell the core (keys, answers, settles) and what the server writes. Time is the
/// test's.
final class EchoPane {
    let core: GhosttyCore
    let clock = EchoTestClock()
    private(set) var seq = 0
    let cols: Int
    let rows: Int

    /// `before` is output ahead of the prompt (history to scroll into).
    init(cols: Int = 20, rows: Int = 4, level: EchoLevel? = .slow, before: String = "") {
        self.cols = cols
        self.rows = rows
        core = GhosttyCore(cols: cols, rows: rows)
        let clock = clock
        core.echo.clock = { clock.now }
        core.feed(Array((before + Self.prompt).utf8))
        if let level { core.setEchoLevel(level, ack: (lastSeq: 0, answeredThrough: 0, settled: true)) }
        core.sync()
    }

    static let prompt = "\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}"

    /// The user types one printable character.
    func type(_ c: Character) {
        seq += 1
        core.echoTyped(.char(c.asciiValue ?? 0x3f), seq: seq, at: clock.now)
        core.sync()
    }

    func backspace() {
        seq += 1
        core.echoTyped(.backspace, seq: seq, at: clock.now)
        core.sync()
    }

    /// Enter: the end of the prompt's input.
    func enter() {
        seq += 1
        core.echoTyped(.boundary(newLine: true), seq: seq, at: clock.now)
        core.sync()
    }

    /// The server answered everything typed so far, and 50 ms passed.
    func answer() {
        let at = clock.now
        core.echoAnswered(through: seq, at: at)
        clock.advance(EchoPredictor.settle)
        core.echoSettled(after: at)
        core.sync()
    }

    /// The server writes `text`, as one message.
    func server(_ text: String) {
        core.feed(Array(text.utf8))
        core.sync()
    }

    /// Types `first`, has it answered and echoed (so its epoch is confirmed), and leaves the
    /// pane ready for guesses that draw.
    func confirmed(_ first: Character, echoedAs echo: String? = nil) {
        type(first)
        answer()
        server(echo ?? String(first))
    }
}

/// Predicted echo in the frame builder and the renderer: what a guess is drawn with, that a
/// guess and the row it sits on come from the same moment, that a wrong guess goes in the frame
/// that shows the server's text, and that nothing is built or copied without a change.
final class EchoRenderTests: XCTestCase {
    private let foreground = GhosttyRowBuilder.pack(0xad, 0xba, 0xc7)
    private let background = GhosttyRowBuilder.pack(0x22, 0x27, 0x2e)

    private func builder() -> GhosttyFrameBuilder { GhosttyFrameBuilder(atlas: GhosttyGlyphAtlas(pointSize: 12, scale: 2)) }

    private func target(_ device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        return try XCTUnwrap(device.makeTexture(descriptor: d))
    }

    private func pixel(_ texture: MTLTexture, _ x: Int, _ y: Int) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&p, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return p // b, g, r, a
    }

    private func bytes(_ texture: MTLTexture) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&out, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return out
    }

    /// The columns of the row glyphs of `row`.
    private func columns(_ frame: GhosttyFrameBuilder, row: Int) -> [Int] {
        let g = frame.rows[row].glyphs
        return (0..<g.count).map { Int(g[$0].col) }
    }

    // MARK: What a guess is drawn with

    func testAGuessIsAGlyphAndAnUnderlineOfItsOwnAndTheRowsAreNotBuiltAgain() {
        let pane = EchoPane()
        pane.confirmed("l")
        let frame = builder()
        XCTAssertTrue(frame.update(core: pane.core))
        XCTAssertEqual(frame.echoVersion, 0)
        let rowsVersion = frame.rowsVersion
        pane.type("s")
        XCTAssertTrue(frame.update(core: pane.core), "an overlay-only publish is a change, though no row was built")
        XCTAssertEqual(frame.rowsBuilt, 0)
        XCTAssertEqual(frame.rowsVersion, rowsVersion, "the rows' buffers keep their version")
        XCTAssertEqual(frame.echoVersion, 1)
        XCTAssertEqual(columns(frame, row: 0), [0, 2], "the row holds the server's text only")
        XCTAssertEqual(frame.echoGlyphs.map { Int($0.col) }, [3])
        XCTAssertEqual(frame.echoGlyphs.first?.color, foreground, "the theme's foreground")
        XCTAssertTrue(frame.echoMasks.isEmpty, "no rect under a guess over a blank cell")
        let m = frame.builder.atlas.metrics
        XCTAssertEqual(frame.echoLines.count, 1)
        let line = frame.echoLines[0]
        XCTAssertEqual(Int(line.x), 3 * m.cellWidth)
        XCTAssertEqual(Int(line.w), m.cellWidth)
        XCTAssertEqual(Int(line.y), m.underlineTop)
        XCTAssertEqual(Int(line.h), max(1, m.underlineThickness))
        XCTAssertEqual(line.color, (foreground & 0x00ff_ffff) | 128 << 24, "the glyph's colour at half alpha")
        XCTAssertEqual(frame.cursor.x, 4, "the cursor is drawn where the guess puts it")
        // Nothing changed: nothing is built, and the frame says so.
        XCTAssertFalse(frame.update(core: pane.core))
        XCTAssertEqual(frame.echoVersion, 1)
        XCTAssertEqual(frame.echoBuilds, 1)
    }

    func testUnmarkedGuessesHaveNoUnderlineAndIncreaseContrastMakesItOpaque() {
        let on = EchoPane(level: .on)
        on.confirmed("l")
        on.type("s")
        let plain = builder()
        _ = plain.update(core: on.core)
        XCTAssertEqual(plain.echoGlyphs.count, 1)
        XCTAssertTrue(plain.echoLines.isEmpty, "between 60 and 80 ms a guess is unmarked")

        let pane = EchoPane()
        pane.confirmed("l")
        pane.type("s")
        let frame = builder()
        _ = frame.update(core: pane.core)
        XCTAssertEqual(frame.echoLines.first.map { $0.color >> 24 }, 128)
        frame.echoUnderlineAlpha = 255
        XCTAssertTrue(frame.update(core: pane.core), "the look changed")
        XCTAssertEqual(frame.echoLines.first.map { $0.color >> 24 }, 255)
        XCTAssertEqual(frame.echoVersion, 2)
    }

    func testAGuessTakesTheColourOfTheTypedCellToItsLeft() {
        let pane = EchoPane()
        // The shell highlights what is typed: the first key comes back in red.
        pane.confirmed("l", echoedAs: "\u{1b}[31ml\u{1b}[39m")
        pane.type("s")
        let frame = builder()
        _ = frame.update(core: pane.core)
        XCTAssertEqual(frame.echoGlyphs.first?.color, frame.builder.paletteColor(1))
        XCTAssertEqual(frame.echoLines.first.map { $0.color & 0x00ff_ffff }, frame.builder.paletteColor(1) & 0x00ff_ffff)
    }

    func testAGuessedSpaceIsAnUnderlineOnly() {
        let pane = EchoPane()
        pane.confirmed("l")
        pane.type(" ")
        pane.type("a")
        let frame = builder()
        _ = frame.update(core: pane.core)
        XCTAssertEqual(frame.echoGlyphs.map { Int($0.col) }, [4])
        XCTAssertEqual(frame.echoLines.map { Int($0.x) / frame.builder.atlas.metrics.cellWidth }, [3, 4], "the trail is continuous")
    }

    // MARK: A guess and its row are of one moment

    func testConfirmationRemovesTheGuessInTheFrameThatDrawsTheRealGlyph() {
        let pane = EchoPane()
        pane.confirmed("l")
        pane.type("s")
        let frame = builder()
        _ = frame.update(core: pane.core)
        pane.answer()
        pane.server("s")
        XCTAssertTrue(frame.update(core: pane.core))
        XCTAssertEqual(columns(frame, row: 0), [0, 2, 3], "the server's glyph")
        XCTAssertTrue(frame.echoGlyphs.isEmpty && frame.echoLines.isEmpty && frame.echoMasks.isEmpty, "and no guess over it")
        XCTAssertEqual(frame.cursor.x, 4)
        XCTAssertEqual(pane.core.echoCounters?.confirmed, 2)
    }

    /// A wrong guess: no frame shows the guess together with the server's text, and none shows
    /// neither. The frame before has the guess on a blank cell; the frame after has the server's
    /// character and no guess. Also with the server's text split across two messages, and with
    /// a frame built between them.
    func testAWrongGuessGoesInTheFrameThatShowsTheServersText() {
        for split in [false, true] {
            let pane = EchoPane()
            pane.confirmed("l")
            pane.type("s")
            let frame = builder()
            _ = frame.update(core: pane.core)
            XCTAssertEqual(frame.echoGlyphs.map { Int($0.col) }, [3])
            XCTAssertEqual(columns(frame, row: 0), [0, 2])
            // The shell wrote something else there (an abbreviation expanded).
            pane.server(split ? "x" : "xy")
            XCTAssertTrue(frame.update(core: pane.core))
            XCTAssertTrue(frame.echoGlyphs.isEmpty && frame.echoLines.isEmpty && frame.echoMasks.isEmpty, "split=\(split): the guess is gone")
            XCTAssertTrue(columns(frame, row: 0).contains(3), "split=\(split): and the server's character is there")
            if split {
                pane.server("y")
                _ = frame.update(core: pane.core)
                XCTAssertTrue(frame.echoGlyphs.isEmpty)
                XCTAssertEqual(columns(frame, row: 0), [0, 2, 3, 4])
            }
            XCTAssertEqual(pane.core.echoCounters?.mismatched, 1)
            XCTAssertEqual(pane.core.echoCounters?.vanished, 0)
            // No guess until the next Enter.
            pane.type("z")
            XCTAssertNil(pane.core.publishedEcho)
            _ = frame.update(core: pane.core)
            XCTAssertTrue(frame.echoGlyphs.isEmpty)
        }
    }

    func testSynchronizedOutputHoldsTheGuessWithItsRows() {
        let pane = EchoPane()
        pane.confirmed("l")
        pane.type("s")
        let frame = builder()
        _ = frame.update(core: pane.core)
        // The echo arrives inside a hold (mode 2026): the rows stay, and so does the guess.
        pane.server("\u{1b}[?2026hs")
        XCTAssertNil(pane.core.publishedEcho, "the grid itself shows the character now")
        _ = frame.update(core: pane.core)
        XCTAssertEqual(columns(frame, row: 0), [0, 2], "the held frame")
        XCTAssertEqual(frame.echoGlyphs.map { Int($0.col) }, [3], "keeps the guess it was drawn with")
        pane.server("\u{1b}[?2026l")
        XCTAssertTrue(frame.update(core: pane.core))
        XCTAssertEqual(columns(frame, row: 0), [0, 2, 3], "the release shows the real glyph")
        XCTAssertTrue(frame.echoGlyphs.isEmpty, "only")
    }

    /// A hold keeps the rows of the moment it began. The guesses kept with them are of that
    /// moment too, not the last drawn frame's: a guess confirmed since is not drawn a second
    /// time over the character that confirmed it.
    func testAHoldTakesTheGuessesOfTheMomentItBeginsNotTheLastFramesGuesses() {
        let pane = EchoPane()
        pane.confirmed("l")
        pane.type("s")
        let frame = builder()
        _ = frame.update(core: pane.core)
        XCTAssertEqual(frame.echoGlyphs.map { Int($0.col) }, [3], "the last drawn frame shows the guess")
        // The echo arrives and no frame is drawn; then the program begins a hold.
        pane.server("s")
        pane.server("\u{1b}[?2026h!")
        _ = frame.update(core: pane.core)
        XCTAssertEqual(columns(frame, row: 0), [0, 2, 3], "the held rows show the echoed character")
        XCTAssertTrue(frame.echoGlyphs.isEmpty, "and no guess is drawn over it")
        pane.server("\u{1b}[?2026l")
    }

    /// While a pane's stream catches up its screen may be behind the program: the held frame
    /// carries no guess, whatever the frame before it showed.
    func testTheCatchUpHoldDrawsNoGuess() {
        let pane = EchoPane()
        pane.confirmed("l")
        pane.type("s")
        let frame = builder()
        _ = frame.update(core: pane.core)
        XCTAssertEqual(frame.echoGlyphs.map { Int($0.col) }, [3])
        pane.core.setCatchUpHold(true)
        _ = frame.update(core: pane.core)
        XCTAssertTrue(frame.echoGlyphs.isEmpty, "held: no guess over a screen that may be behind")
        XCTAssertEqual(columns(frame, row: 0), [0, 2])
        pane.core.setCatchUpHold(false)
    }

    /// A pane that leaves the screen takes no guess with it into the frame it shows when it
    /// comes back and is held.
    func testAPaneThatLeftTheScreenComesBackHeldWithoutItsGuess() {
        let pane = EchoPane()
        pane.confirmed("l")
        pane.type("s")
        let frame = builder()
        _ = frame.update(core: pane.core)
        XCTAssertNotNil(pane.core.frameEcho)
        pane.core.dropFrameEcho()
        XCTAssertNil(pane.core.frameEcho)
    }

    func testAScrolledViewportDrawsNoGuess() {
        let pane = EchoPane(before: (1...12).map { "\($0)\r\n" }.joined())
        pane.confirmed("l")
        pane.type("s")
        let frame = builder()
        _ = frame.update(core: pane.core)
        XCTAssertEqual(frame.echoGlyphs.count, 1)
        pane.core.scrollViewport(.lines(-2))
        XCTAssertTrue(frame.update(core: pane.core))
        XCTAssertTrue(frame.echoGlyphs.isEmpty && frame.echoLines.isEmpty, "guesses are rows of the active area, which is not on screen")
        XCTAssertNotNil(pane.core.publishedEcho, "the guess itself is still pending")
        pane.core.scrollViewport(.lines(2))
        XCTAssertTrue(frame.update(core: pane.core))
        XCTAssertEqual(frame.echoGlyphs.count, 1, "back at the bottom it shows again")
    }

    func testACharacterUnderAPendingBackspaceIsMaskedInItsOwnBackground() {
        let pane = EchoPane()
        pane.confirmed("l")
        pane.type("a")
        pane.backspace()
        XCTAssertNil(pane.core.publishedEcho, "typed and taken back: the line looks as the server has it")
        // The echo of `a` arrives before the Backspace's.
        pane.answer()
        pane.server("a")
        let frame = builder()
        _ = frame.update(core: pane.core)
        XCTAssertEqual(columns(frame, row: 0), [0, 2, 3], "the server shows the deleted character")
        XCTAssertEqual(frame.echoMasks.count, 1, "and a mask hides it")
        XCTAssertEqual(frame.echoMasks.first.map { Int($0.x) }, 3 * frame.builder.atlas.metrics.cellWidth)
        XCTAssertEqual(frame.echoMasks.first?.color, background)
        XCTAssertTrue(frame.echoGlyphs.isEmpty && frame.echoLines.isEmpty)
        XCTAssertEqual(frame.cursor.x, 3)
        // The Backspace's echo: nothing left to hide.
        pane.server("\u{08} \u{08}")
        _ = frame.update(core: pane.core)
        XCTAssertTrue(frame.echoMasks.isEmpty)
        XCTAssertEqual(columns(frame, row: 0), [0, 2])
        XCTAssertEqual(pane.core.echoCounters?.mismatched, 0)
    }

    func testResizeResetRestoreAndThemeTakeTheGuessBeforeTheNextFrame() {
        let changes: [(String, (GhosttyCore) -> Void)] = [
            ("resize", { $0.resize(cols: 30, rows: 5, cellWidthPx: 8, cellHeightPx: 16) }),
            ("reset", { $0.reset() }),
            ("theme", { var c = GhosttyThemeColors.fallback; c.foreground = 0x010203; $0.setColors(c) }),
        ]
        for (name, change) in changes {
            let pane = EchoPane()
            pane.confirmed("l")
            pane.type("s")
            let frame = builder()
            _ = frame.update(core: pane.core)
            XCTAssertEqual(frame.echoGlyphs.count, 1, name)
            XCTAssertTrue(pane.core.echoUnsettled, name)
            change(pane.core)
            pane.core.sync()
            XCTAssertNil(pane.core.publishedEcho, name)
            XCTAssertFalse(pane.core.echoUnsettled, name)
            _ = frame.update(core: pane.core)
            XCTAssertTrue(frame.echoGlyphs.isEmpty && frame.echoLines.isEmpty && frame.echoMasks.isEmpty, "\(name): no guess over the new grid")
        }
    }

    func testAnOverlayPastTheFrameIsClipped() {
        let core = GhosttyCore(cols: 10, rows: 3)
        core.feed(Array("$ ".utf8))
        core.sync()
        // No predictor publishes this: an overlay for a grid that is no longer the frame's.
        core.lockTerminal()
        core.echoPublished = EchoOverlay(cells: [
            .init(col: 5, row: 1, scalar: 0x61, underlined: true),
            .init(col: 10, row: 1, scalar: 0x62, underlined: true),
            .init(col: 3, row: 3, scalar: 0x63, mask: .default, underlined: true),
            .init(col: -1, row: 0, scalar: 0x64, underlined: true),
        ], cursor: .init(col: 12, row: 1), unsettled: true)
        core.termLock.unlock()
        let frame = builder()
        _ = frame.update(core: core)
        XCTAssertEqual(frame.echoGlyphs.map { [Int($0.col), Int($0.row)] }, [[5, 1]], "only the cell inside")
        XCTAssertEqual(frame.echoLines.count, 1)
        XCTAssertTrue(frame.echoMasks.isEmpty)
        XCTAssertEqual(frame.cursor.x, 2, "a predicted cursor outside the frame is not drawn")
        XCTAssertEqual(frame.cursor.y, 0)
    }

    // MARK: On screen

    func testTheUnderlineIsDrawnAndGoesWithTheGuess() throws {
        let metal = try XCTUnwrap(GhosttyMetal.shared)
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let m = atlas.metrics
        let pane = EchoPane()
        pane.confirmed("l")
        let renderer = GhosttyRenderer(core: pane.core, atlas: atlas)
        let texture = try target(metal.device, width: pane.cols * m.cellWidth, height: pane.rows * m.cellHeight)
        // A steady bar cursor, so the cell under the cursor keeps the background.
        pane.server("\u{1b}[6 q")
        XCTAssertTrue(renderer.renderOffscreen(into: texture, now: 100))
        let x = 3 * m.cellWidth + m.cellWidth / 2, y = m.underlineTop
        let bg: [UInt8] = [0x2e, 0x27, 0x22, 0xff]
        XCTAssertEqual(pixel(texture, x, y), bg, "no guess yet")
        pane.type("s")
        XCTAssertTrue(renderer.renderOffscreen(into: texture, now: 100))
        let half = pixel(texture, x, y)
        XCTAssertNotEqual(half, bg, "the underline of the guess")
        XCTAssertNotEqual(half, [0xc7, 0xba, 0xad, 0xff], "at half alpha")
        renderer.setIncreaseContrast(true)
        XCTAssertTrue(renderer.renderOffscreen(into: texture, now: 100))
        XCTAssertEqual(pixel(texture, x, y), [0xc7, 0xba, 0xad, 0xff], "Increase Contrast: the glyph's colour, opaque")
        // The server wrote another character there: the guess and its underline go in that frame.
        pane.server("x")
        XCTAssertTrue(renderer.renderOffscreen(into: texture, now: 100))
        XCTAssertEqual(pixel(texture, x, y), bg)
    }

    // MARK: Nothing is built or copied without a change

    func testTheEchoBuffersAreFilledOnlyWhenTheGuessesChanged() throws {
        let metal = try XCTUnwrap(GhosttyMetal.shared)
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let m = atlas.metrics
        let pane = EchoPane()
        pane.confirmed("l")
        pane.server("\u{1b}[6 q")
        let renderer = GhosttyRenderer(core: pane.core, atlas: atlas)
        let texture = try target(metal.device, width: pane.cols * m.cellWidth, height: pane.rows * m.cellHeight)
        XCTAssertTrue(renderer.renderOffscreen(into: texture, now: 100))
        XCTAssertEqual(renderer.echoFills, 0)
        XCTAssertFalse(renderer.hasEchoBuffers, "no buffer before the first guess")
        pane.type("s")
        XCTAssertTrue(renderer.renderOffscreen(into: texture, now: 100))
        XCTAssertEqual(renderer.echoFills, 1)
        XCTAssertTrue(renderer.hasEchoBuffers)
        // The same guesses, frame after frame: each buffer set is filled once at most (there are
        // three), and then never again.
        for _ in 0..<6 { XCTAssertTrue(renderer.renderOffscreen(into: texture, now: 100)) }
        let settled = renderer.echoFills
        XCTAssertLessThanOrEqual(settled, 3)
        let before = bytes(texture)
        for _ in 0..<9 { XCTAssertTrue(renderer.renderOffscreen(into: texture, now: 100)) }
        XCTAssertEqual(renderer.echoFills, settled, "no refill on frames whose guesses did not change")
        XCTAssertEqual(bytes(texture), before, "and the frames are the same")
        XCTAssertEqual(renderer.frame.echoBuilds, 1, "the instances were built once")
        // One more key: the sets are filled again, once each.
        pane.type("x")
        for _ in 0..<9 { XCTAssertTrue(renderer.renderOffscreen(into: texture, now: 100)) }
        XCTAssertGreaterThan(renderer.echoFills, settled)
        XCTAssertLessThanOrEqual(renderer.echoFills, settled + 3)
        XCTAssertEqual(renderer.frame.echoBuilds, 2)
    }

    /// With predictions off the render path does nothing for predicted echo: nothing is built,
    /// no buffer is made or filled, and the frames are those of a pane that never heard of it.
    func testWithoutGuessesNothingIsBuiltOrCopied() throws {
        let metal = try XCTUnwrap(GhosttyMetal.shared)
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let m = atlas.metrics
        let text = "$ ls -la\r\n\u{1b}[31mred\u{1b}[0m \u{1b}[4munder\u{1b}[0m\r\n$ "
        func frames(level: EchoLevel?, typing: Bool) throws -> ([UInt8], GhosttyRenderer, EchoPane) {
            let pane = EchoPane(level: level)
            let renderer = GhosttyRenderer(core: pane.core, atlas: atlas)
            let texture = try target(metal.device, width: pane.cols * m.cellWidth, height: pane.rows * m.cellHeight)
            pane.server(text)
            for step in 0..<6 {
                if typing {
                    pane.type("a")
                    pane.answer()
                }
                pane.server("a")
                if step == 3 {
                    // A theme and a size change: every row is built again.
                    var c = GhosttyThemeColors.fallback
                    c.foreground = 0xadbac7
                    pane.core.setColors(c)
                    pane.core.sync()
                }
                XCTAssertTrue(renderer.renderOffscreen(into: texture, now: 100))
            }
            return (bytes(texture), renderer, pane)
        }
        let (reference, _, _) = try frames(level: nil, typing: false)
        for (level, typing) in [(EchoLevel?.none, false), (nil, true), (.off, true)] {
            let (image, renderer, pane) = try frames(level: level, typing: typing)
            XCTAssertEqual(pane.core.echo.created.load(ordering: .relaxed), 0, "no predictor")
            XCTAssertEqual(pane.core.echo.publishes.load(ordering: .relaxed), 0, "nothing published")
            XCTAssertEqual(renderer.frame.echoBuilds, 0, "no instance built")
            XCTAssertEqual(renderer.frame.echoVersion, 0)
            XCTAssertEqual(renderer.echoFills, 0, "no buffer filled")
            XCTAssertFalse(renderer.hasEchoBuffers, "no buffer made")
            XCTAssertEqual(image, reference, "the same frame as a pane without predicted echo")
        }
    }
}
