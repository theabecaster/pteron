import Metal
import Synchronization
import XCTest
@testable import RexDuo

/// What the renderer does to stay cheap: rows taken over from the frame before, glyphs drawn off
/// the frame, small atlas uploads, frames drawn straight from a wake-up, and nothing at all
/// while idle. Every shortcut is checked against a frame built from scratch.
final class GhosttyPerfTests: XCTestCase {
    private func make(_ text: String, cols: Int = 40, rows: Int = 10,
                      atlas: GhosttyGlyphAtlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)) -> (GhosttyCore, GhosttyFrameBuilder) {
        let core = GhosttyCore(cols: cols, rows: rows)
        core.feed(Array(text.utf8))
        core.sync()
        let frame = GhosttyFrameBuilder(atlas: atlas)
        XCTAssertTrue(frame.update(core: core))
        return (core, frame)
    }

    private func feed(_ core: GhosttyCore, _ text: String) {
        core.feed(Array(text.utf8))
        core.sync()
    }

    /// Every instance of every row, field by field.
    private func drawn(_ frame: GhosttyFrameBuilder) -> [[UInt64]] {
        func rect(_ r: GhosttyRectInstance) -> [UInt64] {
            [UInt64(UInt16(bitPattern: r.x)) << 48 | UInt64(UInt16(bitPattern: r.y)) << 32 | UInt64(r.w) << 16 | UInt64(r.h),
             UInt64(r.color) << 32 | UInt64(r.row)]
        }
        func glyph(_ g: GhosttyGlyphInstance) -> [UInt64] {
            [UInt64(UInt16(bitPattern: g.x)) << 48 | UInt64(UInt16(bitPattern: g.y)) << 32 | UInt64(g.w) << 16 | UInt64(g.h),
             UInt64(g.u) << 48 | UInt64(g.v) << 32 | UInt64(g.color),
             UInt64(g.col) << 32 | UInt64(g.row) << 16 | UInt64(g.kind)]
        }
        return frame.rows.map { row in
            row.backgrounds.array.flatMap(rect) + [1] + row.underlines.array.flatMap(rect) + [2]
                + row.underGlyphs.array.flatMap(glyph) + [3] + row.glyphs.array.flatMap(glyph) + [4]
                + row.overlays.array.flatMap(rect)
        }
    }

    /// The frame must be exactly what a builder that reuses nothing makes of the terminal now.
    private func assertMatchesAFreshBuild(_ frame: GhosttyFrameBuilder, _ core: GhosttyCore, file: StaticString = #filePath, line: UInt = #line) {
        let fresh = GhosttyFrameBuilder(atlas: frame.atlas)
        fresh.reusesRowsOnScroll = false
        XCTAssertTrue(fresh.update(core: core), file: file, line: line)
        XCTAssertEqual(drawn(frame), drawn(fresh), file: file, line: line)
    }

    // MARK: Rows taken over from the frame before

    /// A screen as a full-screen program paints it: each row erased and written again.
    private func repaint(rows: Int, spinner: String, synchronized: Bool = true) -> String {
        var s = synchronized ? "\u{1b}[?2026h" : ""
        for row in 1...rows {
            s += "\u{1b}[\(row);1H\u{1b}[2K"
            if row == rows - 1 {
                s += "\u{1b}[38;2;215;119;87m\(spinner) Thinking\u{1b}[0m \u{1b}[2m(esc to interrupt)\u{1b}[0m"
            } else if row % 4 == 0 {
                s += "\u{1b}[32m●\u{1b}[0m \u{1b}[1mBash\u{1b}[0m(\u{1b}[38;2;140;170;255mmake test-\(row)\u{1b}[0m)"
            } else {
                s += "  the renderer holds frame \(row) \u{1b}[4munderlined\u{1b}[0m \u{1b}[41m red \u{1b}[0m"
            }
        }
        return s + (synchronized ? "\u{1b}[?2026l" : "")
    }

    func testARepaintWithTheSameTextRebuildsOnlyTheRowsThatChanged() {
        for synchronized in [true, false] {
            let (core, frame) = make("\u{1b}[?25l" + repaint(rows: 20, spinner: "⠋", synchronized: synchronized), cols: 60, rows: 20)
            // The same screen again: every row is dirty, none changed.
            feed(core, repaint(rows: 20, spinner: "⠋", synchronized: synchronized))
            XCTAssertFalse(frame.update(core: core), "what is on screen already: no new frame")
            XCTAssertEqual(frame.rowsBuilt, 0)
            XCTAssertEqual(frame.rowsReused, 20)
            assertMatchesAFreshBuild(frame, core)
            // One row differs.
            feed(core, repaint(rows: 20, spinner: "⠙", synchronized: synchronized))
            XCTAssertTrue(frame.update(core: core))
            XCTAssertEqual(frame.rowsBuilt, 1)
            XCTAssertEqual(frame.rowsReused, 19)
            assertMatchesAFreshBuild(frame, core)
            // With reuse off the dirty flags alone decide, as before.
            frame.reusesRowsOnScroll = false
            feed(core, repaint(rows: 20, spinner: "⠙", synchronized: synchronized))
            _ = frame.update(core: core)
            XCTAssertEqual(frame.rowsBuilt, 20)
            assertMatchesAFreshBuild(frame, core)
        }
    }

    func testARowWhoseStyleChangedUnderTheSameCellsIsRebuilt() {
        // A cell names its style by id. Erase the only row that uses a style and its id is free
        // for the next new style, so the same text in another color can give the same cells.
        let (core, frame) = make("\u{1b}[31mAAAA\u{1b}[0m\r\nplain", cols: 20, rows: 4)
        let red = frame.rows[0].glyphs[0].color
        let id = frame.rows[0].styles[0].id
        feed(core, "\u{1b}[1;1H\u{1b}[2K\u{1b}[34mAAAA\u{1b}[0m")
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rows[0].styles[0].id, id, "the id went to the new style: the cells alone can't tell")
        XCTAssertNotEqual(frame.rows[0].glyphs[0].color, red)
        XCTAssertEqual(frame.rowsBuilt, 1)
        assertMatchesAFreshBuild(frame, core)
        // The same with only a flag changing (underline), and with a background.
        feed(core, "\u{1b}[1;1H\u{1b}[2K\u{1b}[34;4mAAAA\u{1b}[0m")
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rows[0].underlines.count, 1)
        assertMatchesAFreshBuild(frame, core)
        feed(core, "\u{1b}[1;1H\u{1b}[2K\u{1b}[34;4;45mAAAA\u{1b}[0m")
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rows[0].backgrounds.count, 1)
        assertMatchesAFreshBuild(frame, core)
    }

    func testOutputThatScrollsBuildsOnlyTheNewRows() {
        var text = ""
        for i in 1...40 { text += "\u{1b}[3\(i % 7 + 1)m\(i)\u{1b}[0m line \u{1b}[1mbold\u{1b}[0m\r\n" }
        let (core, frame) = make(text, cols: 40, rows: 12)
        for i in 41...60 {
            feed(core, "\u{1b}[3\(i % 7 + 1)m\(i)\u{1b}[0m line \u{1b}[1mbold\u{1b}[0m\r\n")
            XCTAssertTrue(frame.update(core: core))
            XCTAssertLessThanOrEqual(frame.rowsBuilt, 2, "the line that was written and the empty one under it")
            XCTAssertGreaterThanOrEqual(frame.rowsReused, 10)
            XCTAssertEqual(frame.rows.map(\.y), Array(0..<12), "reused rows are restamped with their new place")
        }
        assertMatchesAFreshBuild(frame, core)
        // Several lines in one frame, and a scroll inside a region (rows change in place).
        feed(core, "a\r\nb\r\nc\r\n")
        XCTAssertTrue(frame.update(core: core))
        assertMatchesAFreshBuild(frame, core)
        feed(core, "\u{1b}[2;8r\u{1b}[8;1H\nregion\u{1b}[r")
        XCTAssertTrue(frame.update(core: core))
        assertMatchesAFreshBuild(frame, core)
        feed(core, "\u{1b}[12;1Hx\r\n")
        XCTAssertTrue(frame.update(core: core))
        assertMatchesAFreshBuild(frame, core)
    }

    func testRepaintCostWithAndWithoutReuse() throws {
        let metal = try XCTUnwrap(GhosttyMetal.shared)
        let cols = 60, rows = 50
        var line = ""
        for reuse in [false, true] {
            let core = GhosttyCore(cols: cols, rows: rows)
            let atlas = GhosttyGlyphAtlas(pointSize: 11, scale: 3)
            let renderer = GhosttyRenderer(core: core, atlas: atlas)
            renderer.frame.reusesRowsOnScroll = reuse
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GhosttyMetal.pixelFormat, width: cols * atlas.metrics.cellWidth,
                                                             height: rows * atlas.metrics.cellHeight, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            let texture = try XCTUnwrap(metal.device.makeTexture(descriptor: d))
            let spinner = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
            feed(core, "\u{1b}[?25l" + repaint(rows: rows, spinner: spinner[0]))
            renderer.renderOffscreen(into: texture)
            var build = 0.0, encode = 0.0, built = 0
            let frames = 200
            for i in 1...frames {
                feed(core, repaint(rows: rows, spinner: spinner[i % 10]))
                renderer.renderOffscreen(into: texture)
                build += renderer.lastBuildSeconds
                encode += renderer.lastEncodeSeconds
                built += renderer.frame.rowsBuilt
            }
            XCTAssertEqual(built, reuse ? frames : frames * rows)
            line += String(format: " %@: build %.3f ms + encode %.3f ms;", reuse ? "reuse" : "rebuild all",
                           build / Double(frames) * 1000, encode / Double(frames) * 1000)
        }
        print("PERF repaint \(cols)x\(rows), one row changes per frame:\(line)")
    }

    // MARK: Instance buffers

    private func target(_ device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: GhosttyMetal.pixelFormat, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        return try XCTUnwrap(device.makeTexture(descriptor: d))
    }

    private func pixels(_ texture: MTLTexture) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&p, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return p
    }

    func testFramesThatOnlyMoveTheCursorDrawTheSameAsAFreshRenderer() throws {
        let metal = try XCTUnwrap(GhosttyMetal.shared)
        let core = GhosttyCore(cols: 20, rows: 4)
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let m = atlas.metrics
        let renderer = GhosttyRenderer(core: core, atlas: atlas)
        let a = try target(metal.device, width: 20 * m.cellWidth, height: 4 * m.cellHeight)
        let b = try target(metal.device, width: 20 * m.cellWidth, height: 4 * m.cellHeight)
        feed(core, "\u{1b}[41mab\u{1b}[0m \u{1b}[4mcd\u{1b}[0m \u{1b}[9mef\u{1b}[0m \u{1b}[4:3mgh\u{1b}[0m\r\nsecond row")
        renderer.renderOffscreen(into: a)
        // Block, underline, bar, hidden, block on a letter, and back: the rows never change, so
        // after the first frames every buffer of the rotation is reused as it is.
        let cursors = ["\u{1b}[2 q", "\u{1b}[4 q", "\u{1b}[6 q", "\u{1b}[?25l", "\u{1b}[?25h\u{1b}[2 q\u{1b}[1;2H", "\u{1b}[2;3H", "\u{1b}[4 q\u{1b}[1;5H"]
        var seen = Set<[UInt8]>()
        for cursor in cursors {
            feed(core, cursor)
            for _ in 0..<4 {
                renderer.renderOffscreen(into: a)
                XCTAssertEqual(renderer.frame.rowsBuilt, 0, "the cursor is not part of a row")
            }
            let fresh = GhosttyRenderer(core: core, atlas: atlas)
            fresh.renderOffscreen(into: b)
            let drawn = pixels(a)
            XCTAssertTrue(drawn == pixels(b), "after \(cursor.debugDescription)")
            seen.insert(drawn)
        }
        XCTAssertEqual(seen.count, cursors.count, "each cursor gave its own picture")
        // And when a row does change, the buffers follow.
        feed(core, "\u{1b}[2 q\u{1b}[2;1H\u{1b}[42mchanged\u{1b}[0m")
        renderer.renderOffscreen(into: a)
        XCTAssertEqual(renderer.frame.rowsBuilt, 1)
        GhosttyRenderer(core: core, atlas: atlas).renderOffscreen(into: b)
        XCTAssertTrue(pixels(a) == pixels(b))
    }

    // MARK: Glyphs

    func testSlowGlyphsAreLeftOutOfTheFrameAndArrive() {
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let text = "ab 日本 😀 e\u{301} \u{2500}\u{e0b0} ok\r\nplain row"
        let core = GhosttyCore(cols: 30, rows: 4)
        feed(core, text)
        let frame = GhosttyFrameBuilder(atlas: atlas)
        frame.defersSlowGlyphs = true
        XCTAssertTrue(frame.update(core: core))
        // Our own face and the sprites are drawn in the frame. What needs a fallback font isn't.
        XCTAssertEqual(frame.rows[0].glyphs.array.map(\.col), [0, 1, 13, 14, 16, 17])
        XCTAssertEqual(frame.rowsAwaitingGlyphs, 1)
        XCTAssertEqual(frame.rows[1].glyphs.count, 8)
        XCTAssertFalse(frame.rows[1].awaitsGlyphs)
        XCTAssertFalse(frame.update(core: core), "nothing new until the glyphs are there")

        atlas.waitForHelper()
        XCTAssertTrue(frame.update(core: core), "the arrival alone makes a new frame")
        XCTAssertEqual(frame.rowsBuilt, 1, "only the row that waited")
        XCTAssertEqual(frame.rowsAwaitingGlyphs, 0)
        XCTAssertEqual(frame.rows[0].glyphs.array.map(\.col), [0, 1, 3, 5, 8, 11, 13, 14, 16, 17])
        XCTAssertEqual(frame.rows[0].glyphs.array.map(\.kind)[4], UInt16(GhosttyGlyph.color))
        XCTAssertFalse(frame.update(core: core))

        // The same bitmaps a frame that waits for every glyph gets.
        let other = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let (_, waited) = make(text, cols: 30, rows: 4, atlas: other)
        func boxes(_ f: GhosttyFrameBuilder) -> [[Int]] {
            f.rows[0].glyphs.array.map { [Int($0.x), Int($0.y), Int($0.w), Int($0.h), Int($0.col), Int($0.kind)] }
        }
        XCTAssertEqual(boxes(frame), boxes(waited))
        for (a, b) in zip(frame.rows[0].glyphs.array, waited.rows[0].glyphs.array) where a.kind == UInt16(GhosttyGlyph.mask) {
            let ga = GhosttyGlyph(u: a.u, v: a.v, w: a.w, h: a.h, kind: GhosttyGlyph.mask)
            let gb = GhosttyGlyph(u: b.u, v: b.v, w: b.w, h: b.h, kind: GhosttyGlyph.mask)
            for y in 0..<Int(a.h) {
                for x in 0..<Int(a.w) { XCTAssertEqual(atlas.maskCoverage(ga, x: x, y: y), other.maskCoverage(gb, x: x, y: y)) }
            }
        }
        // A builder that doesn't defer never sees a pending glyph, even one asked for and not drawn yet.
        feed(core, "\r\n漢字")
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rowsAwaitingGlyphs, 1)
        let sync = GhosttyFrameBuilder(atlas: atlas)
        XCTAssertTrue(sync.update(core: core))
        XCTAssertEqual(sync.rowsAwaitingGlyphs, 0)
        XCTAssertEqual(sync.rows[2].glyphs.count, 2)
        atlas.waitForHelper()
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rows[2].glyphs.count, 2)
    }

    // MARK: The glyph worker's queue

    func testRequestStackGivesTheNewestFirstAndDropsTheOldestWhenFull() {
        var stack = GhosttyRequestStack<Int>(limit: 100)
        XCTAssertNil(stack.pop())
        for i in 0..<100 { XCTAssertNil(stack.push(i), "room for \(i)") }
        XCTAssertEqual(stack.push(100), 0, "full: the oldest falls out")
        XCTAssertEqual(stack.push(101), 1)
        XCTAssertEqual(stack.count, 100)
        for expected in stride(from: 101, through: 2, by: -1) { XCTAssertEqual(stack.pop(), expected) }
        XCTAssertNil(stack.pop())
        XCTAssertTrue(stack.isEmpty)

        // Against a plain array, through growth and wrap-around.
        var small = GhosttyRequestStack<Int>(limit: 150)
        var model: [Int] = []
        var seed: UInt32 = 12345
        for value in 0..<20_000 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            if seed >> 28 < 9 {
                let evicted = small.push(value)
                model.append(value)
                XCTAssertEqual(evicted, model.count > 150 ? model.removeFirst() : nil)
            } else {
                XCTAssertEqual(small.pop(), model.popLast())
            }
            XCTAssertEqual(small.count, model.count)
        }
        while let last = model.popLast() { XCTAssertEqual(small.pop(), last) }
        XCTAssertNil(small.pop())
    }

    /// A screen of CJK text per frame, each frame other text, as when a large file goes by. The
    /// worker draws nothing meanwhile (parked), so every request is still waiting at the end.
    private func scrollCJK(_ core: GhosttyCore, _ frame: GhosttyFrameBuilder, frames: Int, perRow: Int) {
        var cp: UInt32 = 0x4e00
        for _ in 0..<frames {
            var text = String.UnicodeScalarView()
            for _ in 0..<frame.rowCount {
                text.append(contentsOf: "\r\n".unicodeScalars)
                for _ in 0..<perRow {
                    text.append(Unicode.Scalar(cp)!)
                    cp += 1
                }
            }
            feed(core, String(text))
            _ = frame.update(core: core)
        }
    }

    func testAfterABurstTheWorkerDrawsWhatIsOnScreenAndNotWhatScrolledAway() {
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let resume = GhosttyGlyphAtlas.parkHelperForTesting()
        let (core, frame) = make("", cols: 20, rows: 4, atlas: atlas)
        frame.defersSlowGlyphs = true
        scrollCJK(core, frame, frames: 30, perRow: 8)
        XCTAssertEqual(frame.rowsAwaitingGlyphs, 4)
        XCTAssertEqual(frame.rows.map(\.glyphs.count), [0, 0, 0, 0])
        resume()
        atlas.waitForHelper()
        atlas.lock()
        XCTAssertEqual(atlas.helperDrawn, 32, "the last frame's glyphs and no others")
        XCTAssertEqual(atlas.helperDropped, 29 * 32, "what scrolled away is not drawn")
        XCTAssertEqual(atlas.rasterCount, 32)
        atlas.unlock()
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rowsAwaitingGlyphs, 0)
        XCTAssertEqual(frame.rows.map(\.glyphs.count), [8, 8, 8, 8])
        assertMatchesAFreshBuild(frame, core)

        // A glyph that was left out is asked for again when it is wanted again.
        feed(core, "\u{1b}[2J\u{1b}[H\u{4e00}\u{4e01}")
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rowsAwaitingGlyphs, 1)
        atlas.waitForHelper()
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rows[0].glyphs.count, 2)
        atlas.lock()
        XCTAssertEqual(atlas.helperDrawn, 34)
        atlas.unlock()
    }

    /// A row that still waits keeps its glyphs wanted, however many frames go by in which only
    /// other rows change. (The worker can only tell "asked for before every row that waits now",
    /// so what those other rows asked for meanwhile is drawn too.)
    func testRowsThatStillWaitKeepTheirRequests() {
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let resume = GhosttyGlyphAtlas.parkHelperForTesting()
        let core = GhosttyCore(cols: 20, rows: 4)
        feed(core, "\u{4e00}\u{4e01}\r\n\u{4e02}")
        let frame = GhosttyFrameBuilder(atlas: atlas)
        frame.defersSlowGlyphs = true
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rowsAwaitingGlyphs, 2)
        for i in 0..<40 {
            feed(core, "\u{1b}[4;1H\u{1b}[2K\(i) \(Unicode.Scalar(UInt32(0x5000 + i))!)")
            XCTAssertTrue(frame.update(core: core))
        }
        XCTAssertEqual(frame.rowsAwaitingGlyphs, 3)
        resume()
        atlas.waitForHelper()
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rowsAwaitingGlyphs, 0)
        XCTAssertEqual(frame.rows[0].glyphs.count, 2, "asked for 40 frames ago and still wanted")
        XCTAssertEqual(frame.rows[1].glyphs.count, 1)
        atlas.lock()
        XCTAssertEqual(atlas.helperDrawn, 43)
        XCTAssertEqual(atlas.helperDropped, 0)
        atlas.unlock()
        assertMatchesAFreshBuild(frame, core)
    }

    /// More glyphs wanted at once than the worker holds requests for: the oldest fall out, the
    /// panes ask again, and in the end every cell has its glyph.
    func testMoreRequestsThanTheWorkerHoldsStillAllArrive() {
        // Small glyphs, so 20,000 of them fit the page without a wipe.
        let atlas = GhosttyGlyphAtlas(pointSize: 6, scale: 1)
        let resume = GhosttyGlyphAtlas.parkHelperForTesting()
        let cols = 400, rows = 100
        XCTAssertGreaterThan(cols / 2 * rows, GhosttyGlyphAtlas.requestLimit)
        let core = GhosttyCore(cols: cols, rows: rows)
        var text = String.UnicodeScalarView()
        var cp: UInt32 = 0x4e00
        for row in 0..<rows {
            if row > 0 { text.append(contentsOf: "\r\n".unicodeScalars) }
            for _ in 0..<(cols / 2) {
                text.append(Unicode.Scalar(cp)!)
                cp += 1
            }
        }
        feed(core, String(text))
        let frame = GhosttyFrameBuilder(atlas: atlas)
        frame.defersSlowGlyphs = true
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rowsAwaitingGlyphs, rows)
        atlas.lock()
        XCTAssertEqual(atlas.helperDropped, cols / 2 * rows - GhosttyGlyphAtlas.requestLimit, "the stack is bounded")
        atlas.unlock()
        resume()
        var rounds = 0
        while frame.rowsAwaitingGlyphs > 0 && rounds < 20 {
            atlas.waitForHelper()
            _ = frame.update(core: core)
            rounds += 1
        }
        XCTAssertEqual(frame.rowsAwaitingGlyphs, 0)
        XCTAssertLessThanOrEqual(rounds, 3)
        XCTAssertEqual(atlas.generation, 0, "no wipe: this is about the queue")
        XCTAssertEqual(frame.rows.reduce(0) { $0 + $1.glyphs.count }, cols / 2 * rows)
    }

    func testWarmingDrawsAsciiOffTheFrame() {
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        atlas.warm()
        atlas.waitForHelper()
        atlas.lock()
        let count = atlas.rasterCount
        XCTAssertEqual(count, 4 * 94, "printable ASCII in the four faces")
        for style in 0..<4 {
            for cp in UInt32(0x21)...UInt32(0x7e) { XCTAssertEqual(atlas.asciiGlyph(cp, style: style).kind, GhosttyGlyph.mask) }
        }
        XCTAssertEqual(atlas.rasterCount, count, "nothing left to draw in a frame")
        XCTAssertEqual(atlas.arrivals, 0, "no frame waited for these")
        atlas.unlock()
        // A frame that comes before the helper draws what it needs itself. Both ways give the same glyphs.
        let cold = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let a = cold.asciiGlyph(0x41, style: 1)
        cold.warm()
        cold.waitForHelper()
        XCTAssertEqual(cold.rasterCount, count)
        XCTAssertEqual(cold.asciiGlyph(0x41, style: 1).u, a.u)
        let b = atlas.asciiGlyph(0x41, style: 1)
        XCTAssertEqual([a.w, a.h], [b.w, b.h])
        for y in 0..<Int(a.h) {
            for x in 0..<Int(a.w) { XCTAssertEqual(cold.maskCoverage(a, x: x, y: y), atlas.maskCoverage(b, x: x, y: y)) }
        }
    }

    func testOnlyTheBoxThatChangedIsMarkedForUpload() {
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let page = atlas.maskPage
        XCTAssertGreaterThanOrEqual(page.dirtyMinY, page.dirtyMaxY, "nothing to upload yet")
        let a = atlas.asciiGlyph(0x41, style: 0)
        XCTAssertEqual([page.dirtyMinX, page.dirtyMaxX, page.dirtyMinY, page.dirtyMaxY],
                       [Int(a.u), Int(a.u) + Int(a.w), Int(a.v), Int(a.v) + Int(a.h)])
        page.clearDirty()
        let b = atlas.asciiGlyph(0x42, style: 0)
        XCTAssertEqual(page.dirtyMinX, Int(b.u))
        XCTAssertEqual(page.dirtyMaxX - page.dirtyMinX, Int(b.w), "one glyph, not the page's width")
        XCTAssertLessThan(page.usedHeight, 64, "a new texture takes the rows in use, not the page")
        page.clearDirty()
        // After a wipe only what is drawn again goes up.
        atlas.wipeForTesting()
        XCTAssertGreaterThanOrEqual(page.dirtyMinY, page.dirtyMaxY)
        let c = atlas.asciiGlyph(0x43, style: 0)
        XCTAssertEqual(page.dirtyMaxY - page.dirtyMinY, Int(c.h))
    }

    func testGlyphCosts() {
        // What a frame pays for a glyph it doesn't have yet. The first fallback glyph of a
        // process also loads the font (the test host has usually done that already).
        func time(_ body: () -> Void) -> Double {
            let start = CACurrentMediaTime()
            body()
            return (CACurrentMediaTime() - start) * 1e6
        }
        let atlas = GhosttyGlyphAtlas(pointSize: 11, scale: 3)
        let first = time { _ = atlas.glyph(0x65e5, style: 0, cells: 2) }
        let ascii = time { for cp in UInt32(0x21)...UInt32(0x7e) { _ = atlas.asciiGlyph(cp, style: 0) } } / 94
        let cjk = time { for cp in UInt32(0x4e00)..<UInt32(0x4e00 + 100) { _ = atlas.glyph(cp, style: 0, cells: 2) } } / 100
        let emoji = time { for cp in UInt32(0x1f600)..<UInt32(0x1f600 + 40) { _ = atlas.glyph(cp, style: 0, cells: 2) } } / 40
        let box = time { for cp in UInt32(0x2500)..<UInt32(0x2500 + 100) { _ = atlas.glyph(cp, style: 0, cells: 1) } } / 100
        let hit = time { for _ in 0..<100 { for cp in UInt32(0x4e00)..<UInt32(0x4e00 + 100) { _ = atlas.glyph(cp, style: 0, cells: 2) } } } / 10_000
        print(String(format: "PERF glyphs, µs each: first fallback %.0f, ASCII %.1f, CJK (fallback) %.1f, emoji %.1f, box sprite %.1f, cached %.3f",
                     first, ascii, cjk, emoji, box, hit))
        XCTAssertLessThan(ascii, 500)
    }

    // MARK: Holds

    func testARedrawLoopSchedulesOneHoldTimeoutNotOnePerFrame() async throws {
        let core = GhosttyCore(cols: 20, rows: 4)
        let wakes = Counter()
        core.onDirty = { wakes.add() }
        // 50 frames, each inside its own hold, as a redraw loop sends them.
        for i in 0..<50 { core.feed(Array("\u{1b}[?2026h\r\(i)\u{1b}[?2026l".utf8)) }
        core.sync()
        let after = wakes.count
        XCTAssertLessThanOrEqual(after, 50, "one per write: a hold beginning or ending isn't news by itself")
        try await Task.sleep(nanoseconds: UInt64((GhosttyCore.renderHoldTimeout + 0.3) * 1e9))
        XCTAssertEqual(wakes.count, after, "no hold is open: nothing to wake the renderer for")

        // A hold that stays open still gets its wake-up when the time is up.
        core.feed(Array("\u{1b}[?2026hstuck".utf8))
        core.sync()
        let held = wakes.count
        try await Task.sleep(nanoseconds: UInt64((GhosttyCore.renderHoldTimeout + 0.3) * 1e9))
        XCTAssertEqual(wakes.count, held + 1)
        let frame = GhosttyFrameBuilder(atlas: GhosttyGlyphAtlas(pointSize: 12, scale: 2))
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rows[0].glyphs.count, 7, "the hold ran out: 49 and stuck are shown")
    }

    private final class Counter: Sendable {
        private let value = Atomic<Int>(0)
        var count: Int { value.load(ordering: .relaxed) }
        func add() { value.add(1, ordering: .relaxed) }
    }

    // MARK: Pacing

    @MainActor
    func testAWakeUpDrawsAtOnceAndAnIdlePaneSchedulesNothing() async throws {
        let thread = GhosttyRenderThread.shared
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        let view = GhosttyTerminalView(frame: window.bounds, fontSize: 12, cols: 40, rows: 10)
        view.apply(theme: ThemeStore.fallback)
        window.addSubview(view)
        window.isHidden = false
        view.layoutIfNeeded()
        // A steady cursor: nothing blinks.
        view.feed(text: "idle\u{1b}[2 q")
        view.core.sync()
        try await Task.sleep(nanoseconds: 700_000_000)
        let renderer = view.renderer
        XCTAssertGreaterThan(renderer.framesDrawn, 0)

        // Idle, past the grace period: no ticks, no passes, no frames.
        let ticks = thread.ticks.load(ordering: .relaxed), passes = thread.passes.load(ordering: .relaxed)
        let frames = renderer.framesDrawn
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(thread.ticks.load(ordering: .relaxed), ticks, "display link ticked while idle")
        XCTAssertEqual(thread.passes.load(ordering: .relaxed), passes, "the render thread woke while idle")
        XCTAssertEqual(renderer.framesDrawn, frames)

        // Output after that is drawn from the wake-up, not from the next tick.
        let immediate = thread.immediateFrames.load(ordering: .relaxed)
        view.feed(text: "\r\nmore")
        view.core.sync()
        let deadline = Date().addingTimeInterval(2)
        while renderer.framesDrawn == frames && Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(renderer.framesDrawn, frames + 1)
        XCTAssertEqual(thread.immediateFrames.load(ordering: .relaxed), immediate + 1)

        // The link runs for the grace period, then stops again.
        try await Task.sleep(nanoseconds: UInt64((GhosttyRenderThread.idleGrace + 0.4) * 1e9))
        let later = thread.ticks.load(ordering: .relaxed)
        XCTAssertGreaterThan(later, ticks, "the link ran after the frame")
        XCTAssertLessThanOrEqual(later - ticks, Int(GhosttyRenderThread.idleGrace * 120) + 4, "and stopped after the grace period")
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(thread.ticks.load(ordering: .relaxed), later)
        XCTAssertEqual(renderer.framesDrawn, frames + 1)

        // A burst faster than the display: at most one frame per refresh, and the last state is shown.
        let before = renderer.framesDrawn
        let start = CACurrentMediaTime()
        for i in 0..<200 {
            view.feed(text: "\r\nburst \(i)")
            if i % 20 == 19 { try await Task.sleep(nanoseconds: 5_000_000) }
        }
        view.core.sync()
        try await Task.sleep(nanoseconds: 400_000_000)
        let elapsed = CACurrentMediaTime() - start - 0.4
        let fps = Double(window.screen.maximumFramesPerSecond)
        XCTAssertLessThanOrEqual(renderer.framesDrawn - before, Int(elapsed * fps) + 4)
        XCTAssertEqual(view.core.rowText(view.core.cursorPosition.y), "burst 199")

        view.removeFromSuperview()
        window.isHidden = true
        let gone = Date().addingTimeInterval(3)
        while thread.alive.load(ordering: .relaxed) && Date() < gone { try await Task.sleep(nanoseconds: 20_000_000) }
    }
}
