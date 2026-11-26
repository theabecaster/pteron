import Metal
import XCTest
@testable import Pteron

final class GhosttyRenderTests: XCTestCase {
    private let red = GhosttyRowBuilder.pack(0xf4, 0x70, 0x67)
    private let foreground = GhosttyRowBuilder.pack(0xad, 0xba, 0xc7)
    private let background = GhosttyRowBuilder.pack(0x22, 0x27, 0x2e)

    /// A core with the fallback theme, an atlas of its own and a frame built from `text`.
    private func build(_ text: String, cols: Int = 20, rows: Int = 4) -> (GhosttyCore, GhosttyFrameBuilder) {
        let core = GhosttyCore(cols: cols, rows: rows)
        core.feed(Array(text.utf8))
        core.sync()
        let frame = GhosttyFrameBuilder(atlas: GhosttyGlyphAtlas(pointSize: 12, scale: 2))
        XCTAssertTrue(frame.update(core: core))
        return (core, frame)
    }

    // MARK: Row builder

    func testPlainTextMakesOneGlyphPerCharacterAndNoBackground() {
        let (_, frame) = build("aa c")
        let row = frame.rows[0]
        XCTAssertEqual(frame.rows.count, 4)
        XCTAssertEqual(row.glyphs.count, 3)
        XCTAssertEqual(row.backgrounds.count, 0)
        XCTAssertEqual(row.glyphs.array.map(\.col), [0, 1, 3])
        XCTAssertTrue(row.glyphs.array.allSatisfy { $0.color == foreground && $0.kind == 1 && $0.row == 0 })
        let m = frame.atlas.metrics
        XCTAssertEqual(Int(row.glyphs[1].x) - Int(row.glyphs[0].x), m.cellWidth, "glyphs sit on whole-pixel cell steps")
    }

    func testAdjacentCellsWithOneBackgroundMerge() {
        let (_, frame) = build("\u{1b}[41mABC\u{1b}[0m \u{1b}[41mD\u{1b}[44mE\u{1b}[0m")
        let m = frame.atlas.metrics
        let bg = frame.rows[0].backgrounds.array
        XCTAssertEqual(bg.count, 3)
        XCTAssertEqual(bg[0].color, red)
        XCTAssertEqual(Int(bg[0].x), 0)
        XCTAssertEqual(Int(bg[0].w), 3 * m.cellWidth)
        XCTAssertEqual(Int(bg[0].h), m.cellHeight)
        XCTAssertEqual(Int(bg[1].x), 4 * m.cellWidth)
        XCTAssertEqual(Int(bg[1].w), m.cellWidth)
        XCTAssertNotEqual(bg[2].color, red)
    }

    func testInverseSwapsColorsWithDefaultsStandingIn() {
        let (_, frame) = build("\u{1b}[7mX\u{1b}[0m\u{1b}[31;7mY\u{1b}[0m")
        let row = frame.rows[0]
        let bg = row.backgrounds.array
        XCTAssertEqual(bg.map(\.color), [foreground, red])
        XCTAssertEqual(row.glyphs.array.map(\.color), [background, background])
    }

    func testBoldItalicFaintInvisible() {
        let (_, frame) = build("a\u{1b}[1ma\u{1b}[0;3ma\u{1b}[0;2ma\u{1b}[0;8ma\u{1b}[0m")
        let glyphs = frame.rows[0].glyphs.array
        XCTAssertEqual(glyphs.count, 4, "the invisible cell draws nothing")
        // Regular, bold and italic come from different faces, so different atlas slots.
        XCTAssertEqual(Set(glyphs.prefix(3).map { UInt32($0.u) << 16 | UInt32($0.v) }).count, 3)
        XCTAssertEqual(glyphs[3].color >> 24, 128, "faint halves the alpha")
        XCTAssertEqual(glyphs[3].color & 0xff_ffff, foreground & 0xff_ffff)
        XCTAssertEqual(glyphs[3].u, glyphs[0].u)
    }

    func testWideCharactersAndGraphemes() {
        let (_, frame) = build("日a e\u{301}")
        let row = frame.rows[0]
        let m = frame.atlas.metrics
        let glyphs = row.glyphs.array
        XCTAssertEqual(glyphs.map(\.col), [0, 2, 4], "the spacer tail draws nothing; the combining mark joins its base")
        XCTAssertEqual(row.wideColumns, [0])
        XCTAssertGreaterThan(Int(glyphs[0].w), m.cellWidth)
        XCTAssertLessThanOrEqual(Int(glyphs[0].w), 2 * m.cellWidth + 2)
        // "é" as a cluster is taller than a plain "e".
        let plain = frame.atlas.asciiGlyph(0x65, style: 0)
        XCTAssertGreaterThan(glyphs[2].h, plain.h)
    }

    func testEmojiUsesTheColorAtlas() {
        let (_, frame) = build("😀")
        let glyphs = frame.rows[0].glyphs.array
        XCTAssertEqual(glyphs.count, 1)
        XCTAssertEqual(glyphs[0].kind, UInt16(GhosttyGlyph.color))
    }

    func testUnderlineRunsMergeAndStrikethroughGoesOnTop() {
        let (_, frame) = build("\u{1b}[4mabc\u{1b}[0m \u{1b}[9mx\u{1b}[0m \u{1b}[4:3my\u{1b}[0m")
        let row = frame.rows[0]
        let m = frame.atlas.metrics
        XCTAssertEqual(row.underlines.count, 1)
        XCTAssertEqual(Int(row.underlines[0].w), 3 * m.cellWidth)
        XCTAssertEqual(Int(row.underlines[0].y), m.underlineTop)
        XCTAssertEqual(row.overlays.count, 1)
        XCTAssertEqual(Int(row.overlays[0].x), 4 * m.cellWidth)
        // The curly underline is an atlas sprite drawn before its letter.
        XCTAssertEqual(row.glyphs.count, 5)
        XCTAssertEqual(row.underGlyphs.count, 1)
        XCTAssertEqual(Int(row.underGlyphs[0].x), 6 * m.cellWidth)
    }

    func testExplicitAndPaletteColors() {
        let (_, frame) = build("\u{1b}[38;2;1;2;3mA\u{1b}[38;5;1mB\u{1b}[48;2;9;8;7m \u{1b}[0m")
        let row = frame.rows[0]
        XCTAssertEqual(row.glyphs.array.map(\.color), [GhosttyRowBuilder.pack(1, 2, 3), red])
        XCTAssertEqual(row.backgrounds.array.map(\.color), [GhosttyRowBuilder.pack(9, 8, 7)])
    }

    func testCursorFollowsTheTerminal() {
        let (core, frame) = build("ab")
        XCTAssertTrue(frame.cursor.visible)
        XCTAssertEqual(frame.cursor.x, 2)
        XCTAssertEqual(frame.cursor.y, 0)
        XCTAssertEqual(frame.cursor.color, GhosttyRowBuilder.pack(0x53, 0x9b, 0xf5), "the theme's cursor color")
        core.feed(Array("\u{1b}[?25l".utf8))
        core.sync()
        XCTAssertTrue(frame.update(core: core))
        XCTAssertFalse(frame.cursor.visible)
    }

    func testOnlyDirtyRowsAreRebuilt() {
        let (core, frame) = build("one\r\ntwo\r\nthree", rows: 6)
        XCTAssertEqual(frame.rowsBuilt, 6)
        XCTAssertFalse(frame.update(core: core), "nothing changed")
        XCTAssertEqual(frame.rowsBuilt, 0)
        core.feed(Array("!".utf8))
        core.sync()
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rowsBuilt, 1)
        XCTAssertEqual(frame.rows[2].glyphs.count, 6)
        // A theme change rebuilds everything with the new colors.
        var colors = GhosttyThemeColors.fallback
        colors.foreground = 0x010203
        core.setColors(colors)
        core.sync()
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rowsBuilt, 6)
        XCTAssertEqual(frame.rows[0].glyphs[0].color, GhosttyRowBuilder.pack(1, 2, 3))
    }

    func testSynchronizedOutputHoldsTheLastFinishedFrame() {
        let (core, frame) = build("old")
        // The hold begins in the same write as the new text: the frame must stay on "old".
        core.feed(Array("\u{1b}[?2026h\r\u{1b}[Knewer".utf8))
        core.sync()
        _ = frame.update(core: core)
        XCTAssertEqual(frame.rows[0].glyphs.count, 3)
        XCTAssertEqual(core.rowText(0), "newer", "the terminal itself has moved on")
        core.feed(Array("\u{1b}[?2026l".utf8))
        core.sync()
        XCTAssertTrue(frame.update(core: core))
        XCTAssertEqual(frame.rows[0].glyphs.count, 5)
    }

    func testAHoldThatIsNeverReleasedTimesOut() {
        let (core, frame) = build("old")
        core.feed(Array("\u{1b}[?2026h\r\u{1b}[Knewer".utf8))
        core.sync()
        _ = frame.update(core: core)
        XCTAssertEqual(frame.rows[0].glyphs.count, 3)
        XCTAssertTrue(frame.update(core: core, now: CACurrentMediaTime() + GhosttyCore.renderHoldTimeout + 0.1))
        XCTAssertEqual(frame.rows[0].glyphs.count, 5)
    }

    // MARK: Atlas and sprites

    func testAtlasCachesAndRecoversFromAWipe() {
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let m = atlas.metrics
        XCTAssertGreaterThan(m.cellWidth, 0)
        XCTAssertGreaterThan(m.baseline, 0)
        XCTAssertLessThan(m.baseline, m.cellHeight)
        XCTAssertEqual(m.cellSizePoints.width * 2, CGFloat(m.cellWidth))
        let a = atlas.asciiGlyph(0x41, style: 0)
        XCTAssertEqual(a.kind, GhosttyGlyph.mask)
        XCTAssertGreaterThan(a.w, 0)
        let count = atlas.rasterCount
        let again = atlas.asciiGlyph(0x41, style: 0)
        XCTAssertEqual(atlas.rasterCount, count, "cached")
        XCTAssertEqual(again.u, a.u)
        XCTAssertEqual(atlas.asciiGlyph(0x20, style: 0).kind, GhosttyGlyph.empty)
        var ink = 0
        for y in 0..<Int(a.h) { for x in 0..<Int(a.w) where atlas.maskCoverage(a, x: x, y: y) > 128 { ink += 1 } }
        XCTAssertGreaterThan(ink, 20, "the glyph has ink")
        // Many glyphs make the page grow rather than fail.
        for cp in UInt32(0x4e00)..<UInt32(0x4e00 + 2500) { _ = atlas.glyph(cp, style: 0, cells: 2) }
        XCTAssertGreaterThan(atlas.maskPage.height, 512)
        XCTAssertEqual(atlas.generation, 0)
        atlas.wipeForTesting()
        XCTAssertEqual(atlas.generation, 1)
        XCTAssertEqual(atlas.asciiGlyph(0x41, style: 0).kind, GhosttyGlyph.mask)
    }

    func testBoxAndBlockSpritesFillTheCellEdgeToEdge() {
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let m = atlas.metrics
        let full = atlas.glyph(0x2588, style: 0, cells: 1)
        XCTAssertEqual(Int(full.w), m.cellWidth)
        XCTAssertEqual(Int(full.h), m.cellHeight)
        XCTAssertEqual(full.ox, 0)
        XCTAssertEqual(full.oy, 0)
        for (x, y) in [(0, 0), (m.cellWidth - 1, 0), (0, m.cellHeight - 1), (m.cellWidth - 1, m.cellHeight - 1)] {
            XCTAssertEqual(atlas.maskCoverage(full, x: x, y: y), 255)
        }
        // ─ reaches both side edges; │ reaches top and bottom; ┼ reaches all four.
        let mid = (m.cellHeight - m.boxThickness) / 2, centre = (m.cellWidth - m.boxThickness) / 2
        let h = atlas.glyph(0x2500, style: 0, cells: 1)
        XCTAssertEqual(atlas.maskCoverage(h, x: 0, y: mid), 255)
        XCTAssertEqual(atlas.maskCoverage(h, x: m.cellWidth - 1, y: mid), 255)
        XCTAssertEqual(atlas.maskCoverage(h, x: 0, y: 0), 0)
        let v = atlas.glyph(0x2502, style: 0, cells: 1)
        XCTAssertEqual(atlas.maskCoverage(v, x: centre, y: 0), 255)
        XCTAssertEqual(atlas.maskCoverage(v, x: centre, y: m.cellHeight - 1), 255)
        let cross = atlas.glyph(0x253c, style: 0, cells: 1)
        XCTAssertEqual(atlas.maskCoverage(cross, x: 0, y: mid), 255)
        XCTAssertEqual(atlas.maskCoverage(cross, x: centre, y: m.cellHeight - 1), 255)
        // ▄ is exactly the lower half.
        let lower = atlas.glyph(0x2584, style: 0, cells: 1)
        XCTAssertEqual(atlas.maskCoverage(lower, x: 0, y: m.cellHeight - 1), 255)
        XCTAssertEqual(atlas.maskCoverage(lower, x: 0, y: 0), 0)
        // Sprites are the same in every face.
        XCTAssertEqual(atlas.glyph(0x2500, style: 1, cells: 1).u, h.u)
        XCTAssertTrue(GhosttySprites.isSprite(0x28ff))
        XCTAssertTrue(GhosttySprites.isSprite(0xe0b0))
        XCTAssertFalse(GhosttySprites.isSprite(0x41))
    }

    // MARK: Renderer

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

    func testRendererDrawsBackgroundsGlyphsAndCursor() throws {
        let metal = try XCTUnwrap(GhosttyMetal.shared, "Metal and the shaders must be available")
        let core = GhosttyCore(cols: 10, rows: 3)
        core.feed(Array("\u{1b}[41m \u{1b}[0m\u{2588}\r\n\u{1b}[2 q".utf8))
        core.sync()
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let m = atlas.metrics
        let renderer = GhosttyRenderer(core: core, atlas: atlas)
        let texture = try target(metal.device, width: 10 * m.cellWidth, height: 3 * m.cellHeight)
        XCTAssertTrue(renderer.renderOffscreen(into: texture))
        let cx = m.cellWidth / 2, cy = m.cellHeight / 2
        XCTAssertEqual(pixel(texture, cx, cy), [0x67, 0x70, 0xf4, 0xff], "red background cell")
        XCTAssertEqual(pixel(texture, m.cellWidth + cx, cy), [0xc7, 0xba, 0xad, 0xff], "full block in the foreground color")
        XCTAssertEqual(pixel(texture, 3 * m.cellWidth + cx, cy), [0x2e, 0x27, 0x22, 0xff], "default background")
        XCTAssertEqual(pixel(texture, cx, m.cellHeight + cy), [0xf5, 0x9b, 0x53, 0xff], "steady block cursor on row 1")
        // The block's last column and the next cell's first: no gap, no bleed.
        XCTAssertEqual(pixel(texture, 2 * m.cellWidth - 1, cy), [0xc7, 0xba, 0xad, 0xff])
        XCTAssertEqual(pixel(texture, 2 * m.cellWidth, cy), [0x2e, 0x27, 0x22, 0xff])
    }

    private func bytes(_ texture: MTLTexture) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&out, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return out
    }

    /// What a pane with an atlas of its own draws for `core`.
    private func reference(_ core: GhosttyCore, device: MTLDevice, width: Int, height: Int) throws -> [UInt8] {
        let texture = try target(device, width: width, height: height)
        XCTAssertTrue(GhosttyRenderer(core: core, atlas: GhosttyGlyphAtlas(pointSize: 12, scale: 2)).renderOffscreen(into: texture))
        return bytes(texture)
    }

    /// Two panes share an atlas. The page fills up and is wiped while one pane's frame is with
    /// the GPU and not drawn yet: that frame must still show its own glyphs, not the ones the
    /// other pane put in their place.
    func testAWipeLeavesFramesAlreadyHandedOverIntact() throws {
        let metal = try XCTUnwrap(GhosttyMetal.shared)
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let m = atlas.metrics
        let width = 12 * m.cellWidth, height = 2 * m.cellHeight
        let first = GhosttyCore(cols: 12, rows: 2), second = GhosttyCore(cols: 12, rows: 2)
        first.feed(Array("ABCDEFGH\u{1b}[?25l".utf8))
        second.feed(Array("stuvwxyz\u{1b}[?25l".utf8))
        first.sync()
        second.sync()
        let wanted = try reference(first, device: metal.device, width: width, height: height)
        let wantedSecond = try reference(second, device: metal.device, width: width, height: height)
        XCTAssertFalse(wanted == wantedSecond)

        let one = GhosttyRenderer(core: first, atlas: atlas), two = GhosttyRenderer(core: second, atlas: atlas)
        let textureOne = try target(metal.device, width: width, height: height)
        let textureTwo = try target(metal.device, width: width, height: height)
        // The first pane's frame is encoded, its glyphs are uploaded; the GPU has not run it.
        let waiting = try XCTUnwrap(one.encodeOffscreen(into: textureOne))
        // The pages are wiped, and the second pane's build puts its glyphs where the first's were.
        atlas.lock()
        atlas.wipeForTesting()
        atlas.unlock()
        XCTAssertTrue(two.renderOffscreen(into: textureTwo))
        XCTAssertTrue(bytes(textureTwo) == wantedSecond)
        // Now the GPU gets to the first pane's frame.
        waiting.commit()
        one.offscreenCommitted()
        waiting.waitUntilCompleted()
        XCTAssertTrue(bytes(textureOne) == wanted, "a frame handed over before the wipe draws the glyphs it was built with")
        // And its next frame is built from the new pages.
        XCTAssertTrue(one.renderOffscreen(into: textureOne))
        XCTAssertTrue(bytes(textureOne) == wanted)
        XCTAssertEqual(one.frame.rowsBuilt, 2, "rows built before the wipe are built again")
    }

    /// A frame that was encoded and never committed must not use up a buffer set: the sets after
    /// it may still be read by the GPU.
    func testOnlyACommittedFrameUsesUpItsBuffers() throws {
        let metal = try XCTUnwrap(GhosttyMetal.shared)
        let core = GhosttyCore(cols: 12, rows: 2)
        core.feed(Array("first\u{1b}[?25l".utf8))
        core.sync()
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let m = atlas.metrics
        let width = 12 * m.cellWidth, height = 2 * m.cellHeight
        let renderer = GhosttyRenderer(core: core, atlas: atlas)
        let texture = try target(metal.device, width: width, height: height)
        XCTAssertEqual(renderer.nextBufferIndex, 0)
        XCTAssertTrue(renderer.renderOffscreen(into: texture))
        XCTAssertEqual(renderer.nextBufferIndex, 1)
        // Encoded twice and thrown away, as when a frame can't be handed over.
        XCTAssertNotNil(renderer.encodeOffscreen(into: texture))
        XCTAssertEqual(renderer.nextBufferIndex, 1)
        core.feed(Array("\rsecond".utf8))
        core.sync()
        XCTAssertNotNil(renderer.encodeOffscreen(into: texture))
        XCTAssertEqual(renderer.nextBufferIndex, 1)
        // The retry fills the same set again, with what is on screen now.
        let commands = try XCTUnwrap(renderer.encodeOffscreen(into: texture))
        commands.commit()
        renderer.offscreenCommitted()
        commands.waitUntilCompleted()
        XCTAssertEqual(renderer.nextBufferIndex, 2)
        XCTAssertTrue(bytes(texture) == (try reference(core, device: metal.device, width: width, height: height)))
        XCTAssertTrue(renderer.renderOffscreen(into: texture))
        XCTAssertEqual(renderer.nextBufferIndex, 0)
    }

    /// Pixel positions are 16 bits wide. Far to the right of a very wide grid they are clamped,
    /// part by part and as sums.
    func testACursorFarToTheRightOfAVeryWideGridIsDrawnClamped() throws {
        let metal = try XCTUnwrap(GhosttyMetal.shared)
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let cols = Int(Int16.max) / atlas.metrics.cellWidth + 200
        let core = GhosttyCore(cols: cols, rows: 2)
        core.feed(Array("\u{1b}[4mleft\u{1b}[0m\u{1b}[1;\(cols)H\u{1b}[41;4;9mX\u{1b}[0m\u{1b}[1;\(cols)H".utf8))
        core.sync()
        XCTAssertEqual(core.cursorPosition.x, cols - 1)
        let texture = try target(metal.device, width: 64, height: 64)
        // Every cursor shape: the hollow block of an unfocused pane adds a width to the position.
        for (focused, style) in [(false, "2"), (true, "2"), (true, "4"), (true, "6")] {
            let renderer = GhosttyRenderer(core: core, atlas: atlas)
            renderer.setFocused(focused)
            core.feed(Array("\u{1b}[\(style) q".utf8))
            core.sync()
            XCTAssertTrue(renderer.renderOffscreen(into: texture))
            XCTAssertEqual(renderer.frame.cursor.x, cols - 1)
        }
        XCTAssertEqual(pixel(texture, 2, 2)[3], 0xff)
    }

    /// Row rebuild plus encode for a frame where every row is dirty, which is what scrolling output is.
    private func measureFullDirty(cols: Int, rows: Int) throws {
        let metal = try XCTUnwrap(GhosttyMetal.shared)
        let core = GhosttyCore(cols: cols, rows: rows)
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 3)
        let m = atlas.metrics
        let renderer = GhosttyRenderer(core: core, atlas: atlas)
        // The worst case: no row is taken over from the frame before.
        renderer.frame.reusesRowsOnScroll = false
        let texture = try target(metal.device, width: cols * m.cellWidth, height: rows * m.cellHeight)
        func line(_ i: Int) -> String {
            var s = "\u{1b}[3\(i % 8)m\(i)\u{1b}[0m \u{1b}[1mdrwxr-xr-x\u{1b}[0m user \u{1b}[44m staff \u{1b}[0m "
            s += String(repeating: "file-\(i).swift ", count: cols / 12)
            return String(s.prefix(cols + 40)) + "\r\n"
        }
        core.feed(Array((0..<rows * 2).map(line).joined().utf8))
        core.sync()
        renderer.renderOffscreen(into: texture)
        var build = 0.0, encode = 0.0, glyphs = 0
        let frames = 200
        for i in 0..<frames {
            core.feed(Array(line(1000 + i).utf8))
            core.sync()
            renderer.renderOffscreen(into: texture)
            XCTAssertEqual(renderer.frame.rowsBuilt, rows)
            build += renderer.lastBuildSeconds
            encode += renderer.lastEncodeSeconds
            glyphs += renderer.frame.rows.reduce(0) { $0 + $1.glyphs.count }
        }
        print(String(format: "PERF full-dirty %dx%d: rebuild %.3f ms + encode %.3f ms = %.3f ms per frame (%d glyphs)",
                     cols, rows, build / Double(frames) * 1000, encode / Double(frames) * 1000,
                     (build + encode) / Double(frames) * 1000, glyphs / frames))
        XCTAssertLessThan((build + encode) / Double(frames), 0.008, "must fit a 120 Hz frame")
    }

    func testFullDirtyFrameCost80x24() throws { try measureFullDirty(cols: 80, rows: 24) }
    func testFullDirtyFrameCost60x60() throws { try measureFullDirty(cols: 60, rows: 60) }

    // MARK: View and render thread

    @MainActor
    func testViewDrawsThenIdlesThenStopsTheThread() async throws {
        let thread = GhosttyRenderThread.shared
        let panes = await PaneBaseline.afterQuiet()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        var view: GhosttyTerminalView? = GhosttyTerminalView(frame: window.bounds, fontSize: 12, cols: 40, rows: 10)
        let grid = GridSpy()
        view!.engineDelegate = grid
        view!.apply(theme: ThemeStore.fallback)
        window.addSubview(view!)
        window.isHidden = false
        view!.layoutIfNeeded()
        XCTAssertGreaterThan(view!.cellSize.width, 0)

        view!.setGrid(cols: 30, rows: 8, force: false)
        XCTAssertEqual(grid.last?.0, 30)
        XCTAssertEqual(grid.last?.1, 8)
        view!.setGrid(cols: 30, rows: 8, force: false)
        XCTAssertEqual(grid.count, 2, "once on setting the delegate, once for the change; an unchanged grid isn't reported again")
        view!.feed(text: "hello \u{1b}[2 q")
        Array("world".utf8).withUnsafeBufferPointer { view!.feed(buffer: $0) }
        view!.core.sync()
        XCTAssertEqual(view!.core.rowText(0), "hello world")
        XCTAssertEqual(view!.core.gridSize.cols, 30)

        let renderer = view!.renderer
        let drew = try await eventually(10) { renderer.framesDrawn > 0 }
        XCTAssertTrue(drew, "the pane drew")
        XCTAssertTrue(thread.alive.load(ordering: .relaxed))
        // Past the grace period that follows a frame.
        try await Task.sleep(nanoseconds: 600_000_000)

        // Idle: a steady cursor and no output must schedule no frames at all.
        let ticks = thread.ticks.load(ordering: .relaxed), frames = renderer.framesDrawn
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(thread.ticks.load(ordering: .relaxed), ticks, "display link ticked while idle")
        XCTAssertEqual(renderer.framesDrawn, frames)

        // Output wakes it.
        view!.feed(text: "\r\nmore")
        view!.core.sync()
        let woke = try await eventually(10) { renderer.framesDrawn > frames }
        XCTAssertTrue(woke, "output drew no frame")

        // A font change keeps the grid and changes the cell.
        let cell = view!.cellSize
        view!.setFont(size: 16)
        XCTAssertGreaterThan(view!.cellSize.width, cell.width)
        XCTAssertEqual(view!.core.gridSize.cols, 30)

        // Teardown: the thread goes away with the last pane.
        view!.removeFromSuperview()
        view = nil
        window.isHidden = true
        let cleared = await panes.cleared()
        XCTAssertTrue(cleared, "the pane is still registered")
        // The thread is one for the process: it stops when no pane of any test is left.
        if thread.paneCount == 0 {
            let stopped = try await eventually(30) { !thread.alive.load(ordering: .relaxed) }
            XCTAssertTrue(stopped, "render thread still running")
        }
    }

    @MainActor
    private func makeWindow(_ size: CGSize = CGSize(width: 320, height: 240)) -> UIWindow {
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        window.isHidden = false
        return window
    }

    /// Waits until `condition` holds, for at most `seconds`.
    @MainActor
    private func eventually(_ seconds: TimeInterval = 3, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        return condition()
    }

    /// A pane's view is let go while it still has megabytes to parse, a restore queued, a hold
    /// that is never released and a selection drag: the render thread's pane, the terminal and
    /// the core all go, with nothing left that ticks.
    @MainActor
    func testAViewDroppedInTheMiddleOfWorkLetsEverythingGo() async throws {
        let thread = GhosttyRenderThread.shared
        let panes = await PaneBaseline.afterQuiet()
        let terminals = GhosttyCore.liveTerminals.load(ordering: .relaxed)
        let snapshot = try ghosttyFixture("ghostty-history")
        weak var core: GhosttyCore?
        weak var renderer: GhosttyRenderer?
        weak var gone: GhosttyTerminalView?
        do {
            let window = makeWindow()
            let view = GhosttyTerminalView(frame: window.bounds, fontSize: 12, cols: 40, rows: 10)
            view.apply(theme: ThemeStore.fallback)
            window.addSubview(view)
            view.layoutIfNeeded()
            core = view.core
            renderer = view.renderer
            gone = view
            let drew = try await eventually { view.renderer.framesDrawn > 0 }
            XCTAssertTrue(drew)
            XCTAssertEqual(thread.paneCount, panes.before + 1)
            view.feed(text: String(repeating: "a line of output that scrolls\r\n", count: 100_000))
            XCTAssertTrue(view.restoreSnapshot(snapshot, failed: {}))
            view.feed(text: "more\u{1b}[?2026hheld and never released")
            view.beginSelection(at: CGPoint(x: 20, y: 8), word: true)
            view.extendSelection(to: CGPoint(x: 120, y: 40), autoscroll: false)
            view.removeFromSuperview()
            window.isHidden = true
        }
        let freed = try await eventually(30) {
            gone == nil && core == nil && renderer == nil && panes.left == 0
                && GhosttyCore.liveTerminals.load(ordering: .relaxed) <= terminals
        }
        XCTAssertNil(gone, "something holds the view")
        XCTAssertNil(renderer, "something holds the renderer")
        XCTAssertNil(core, "something holds the core")
        XCTAssertEqual(panes.left, 0)
        XCTAssertTrue(freed)
        // The thread is one for the process: it stops, and nothing wakes it, when no pane of
        // any test is left.
        guard thread.paneCount == 0 else { return }
        let stopped = try await eventually(30) { !thread.alive.load(ordering: .relaxed) }
        XCTAssertTrue(stopped, "render thread still running")
        // Nothing left that wakes: the hold's timer finds no core.
        let passes = thread.passes.load(ordering: .relaxed)
        try await Task.sleep(nanoseconds: UInt64((GhosttyCore.renderHoldTimeout + 0.2) * 1e9))
        XCTAssertEqual(thread.passes.load(ordering: .relaxed), passes)
    }

    /// A layer without area never shows a drawable, so none comes back to its pool and the
    /// fourth request for one would block the thread every pane draws on.
    @MainActor
    func testAPaneWithoutAreaAsksForNoDrawable() async throws {
        let window = makeWindow()
        var view: GhosttyTerminalView? = GhosttyTerminalView(frame: window.bounds, fontSize: 12, cols: 40, rows: 10)
        let renderer = view!.renderer
        view!.apply(theme: ThemeStore.fallback)
        window.addSubview(view!)
        view!.layoutIfNeeded()
        view!.feed(text: "shown\u{1b}[2 q")
        let drew = try await eventually { renderer.framesDrawn > 0 }
        XCTAssertTrue(drew)
        try await Task.sleep(nanoseconds: 200_000_000)

        view!.frame = .zero
        view!.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        let frames = renderer.framesDrawn
        let start = CACurrentMediaTime()
        for i in 0..<12 {
            view!.feed(text: "\r\nwritten while there is nothing to draw on \(i)")
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        view!.core.sync()
        XCTAssertEqual(renderer.framesDrawn, frames, "no frame for a layer without area")
        XCTAssertEqual(renderer.drawableMisses, 0)
        XCTAssertLessThan(CACurrentMediaTime() - start, 0.9)

        // With area again, it draws what was written meanwhile.
        view!.frame = window.bounds
        view!.layoutIfNeeded()
        let again = try await eventually { renderer.framesDrawn > frames }
        XCTAssertTrue(again)
        XCTAssertEqual(renderer.drawableMisses, 0)
        view!.removeFromSuperview()
        view = nil
        window.isHidden = true
    }

    /// A pane whose layer shows nothing (here: an ancestor is hidden, which the view can't see)
    /// runs out of drawables. Once a request for one came back late, the pane is left alone
    /// for a while and the other panes draw at their pace.
    @MainActor
    func testAPaneWhoseLayerGivesNoDrawableLeavesTheOthersDrawing() async throws {
        let window = makeWindow(CGSize(width: 320, height: 480))
        let holder = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        holder.isHidden = true
        window.addSubview(holder)
        var covered: GhosttyTerminalView? = GhosttyTerminalView(frame: holder.bounds, fontSize: 12, cols: 40, rows: 10)
        var shown: GhosttyTerminalView? = GhosttyTerminalView(frame: CGRect(x: 0, y: 240, width: 320, height: 240), fontSize: 12, cols: 40, rows: 10)
        let stuck = covered!.renderer, free = shown!.renderer
        for view in [covered!, shown!] { view.apply(theme: ThemeStore.fallback) }
        holder.addSubview(covered!)
        window.addSubview(shown!)
        covered!.layoutIfNeeded()
        shown!.layoutIfNeeded()
        // Output for the covered pane until its layer has no drawable left.
        var i = 0
        let deadline = Date().addingTimeInterval(4)
        // Polled often, so the wait below starts close to the miss its backoff counts from.
        var feeds = 0
        while stuck.drawableMisses == 0 && Date() < deadline {
            if feeds % 4 == 0 {
                covered!.feed(text: "\r\ncovered \(i)")
                i += 1
            }
            feeds += 1
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        if stuck.drawableMisses > 0 {
            // It has more to draw, and is not asked to for the time being. The window ends
            // inside that time on any machine, so a slow one doesn't run it into the retry,
            // which waits on the layer again and holds every pane's drawing meanwhile.
            covered!.feed(text: "\r\nmore")
            let before = free.framesDrawn, stuckFrames = stuck.framesDrawn, misses = stuck.drawableMisses
            let start = CACurrentMediaTime()
            let window = GhosttyRenderer.drawableBackoffStart - 0.05
            var last = start, longest = 0.0, n = 0
            while CACurrentMediaTime() - start < window {
                shown!.feed(text: "\r\nshown \(n)")
                covered!.feed(text: "\r\nstill covered \(n)")
                n += 1
                try await Task.sleep(nanoseconds: 10_000_000)
                let now = CACurrentMediaTime()
                longest = max(longest, now - last)
                last = now
            }
            // A main thread held up shows as a long turn between two of its feeds; a wait on the
            // dry layer would hold it for as long as the layer takes to give up (about 1 s).
            XCTAssertLessThan(longest, GhosttyRenderer.drawableBackoffStart, "the main thread was not held up either")
            XCTAssertGreaterThanOrEqual(free.framesDrawn - before, 5, "the visible pane kept drawing")
            XCTAssertEqual(stuck.drawableMisses, misses, "no drawable asked for during the wait")
            XCTAssertLessThanOrEqual(stuck.framesDrawn - stuckFrames, 1)
        }
        // (A simulator or device whose layer never runs dry has nothing to show here.)
        covered!.removeFromSuperview()
        shown!.removeFromSuperview()
        covered = nil
        shown = nil
        window.isHidden = true
    }

    /// The page of a shared atlas is wiped: every pane that uses it draws again, also one with
    /// nothing new of its own, because its rows name places that hold other glyphs now.
    @MainActor
    func testAWipeMakesEveryPaneOfTheAtlasDrawAgain() async throws {
        let window = makeWindow(CGSize(width: 320, height: 480))
        var one: GhosttyTerminalView? = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: 12, cols: 40, rows: 10)
        var two: GhosttyTerminalView? = GhosttyTerminalView(frame: CGRect(x: 0, y: 240, width: 320, height: 240), fontSize: 12, cols: 40, rows: 10)
        XCTAssertTrue(one!.atlas === two!.atlas, "same font and scale: one atlas")
        let atlas = one!.atlas
        let first = one!.renderer, second = two!.renderer
        for view in [one!, two!] {
            view.apply(theme: ThemeStore.fallback)
            window.addSubview(view)
            view.layoutIfNeeded()
            view.feed(text: "idle pane\u{1b}[2 q")
        }
        let drew = try await eventually { first.framesDrawn > 0 && second.framesDrawn > 0 }
        XCTAssertTrue(drew)
        try await Task.sleep(nanoseconds: 500_000_000)
        let a = first.framesDrawn, b = second.framesDrawn
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(first.framesDrawn, a, "idle")
        XCTAssertEqual(second.framesDrawn, b, "idle")

        atlas.lock()
        atlas.wipeForTesting()
        atlas.unlock()
        let both = try await eventually { first.framesDrawn > a && second.framesDrawn > b }
        XCTAssertTrue(both, "\(first.framesDrawn - a) and \(second.framesDrawn - b) frames after the wipe")
        for view in [one!, two!] { view.removeFromSuperview() }
        one = nil
        two = nil
        window.isHidden = true
    }
}

@MainActor
private final class GridSpy: TerminalEngineDelegate {
    var last: (Int, Int)?
    var count = 0
    func engineGridChanged(cols: Int, rows: Int) {
        last = (cols, rows)
        count += 1
    }
    func engineSend(_ bytes: [UInt8]) {}
}
