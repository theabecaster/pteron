import Metal
import XCTest
@testable import RexConnect

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
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first { window.windowScene = scene }
        var view: GhosttyTerminalView? = GhosttyTerminalView(frame: window.bounds, fontSize: 12, cols: 40, rows: 10)
        let grid = GridSpy()
        view!.engineDelegate = grid
        view!.apply(theme: ThemeStore.fallback)
        window.addSubview(view!)
        window.isHidden = false
        view!.layoutIfNeeded()
        XCTAssertTrue(view!.parsesOffMainThread)
        XCTAssertFalse(view!.fontChangeResetsModes)
        XCTAssertGreaterThan(view!.cellSize.width, 0)

        view!.setGrid(cols: 30, rows: 8, force: false)
        XCTAssertEqual(grid.last?.0, 30)
        XCTAssertEqual(grid.last?.1, 8)
        view!.setGrid(cols: 30, rows: 8, force: false)
        XCTAssertEqual(grid.count, 2, "once on setting the delegate, once for the change; an unchanged grid isn't reported again")
        view!.feed(text: "hello \u{1b}[2 q")
        view!.feed(byteArray: Array("world".utf8)[...])
        view!.core.sync()
        XCTAssertEqual(view!.core.rowText(0), "hello world")
        XCTAssertEqual(view!.core.gridSize.cols, 30)

        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(thread.alive.load(ordering: .relaxed))
        let renderer = view!.renderer
        XCTAssertGreaterThan(renderer.framesDrawn, 0, "the pane drew")

        // Idle: a steady cursor and no output must schedule no frames at all.
        let ticks = thread.ticks.load(ordering: .relaxed), frames = renderer.framesDrawn
        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertEqual(thread.ticks.load(ordering: .relaxed), ticks, "display link ticked while idle")
        XCTAssertEqual(renderer.framesDrawn, frames)

        // Output wakes it.
        view!.feed(text: "\r\nmore")
        view!.core.sync()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertGreaterThan(renderer.framesDrawn, frames)

        // A font change keeps the grid and changes the cell.
        let cell = view!.cellSize
        view!.setFont(size: 16)
        XCTAssertGreaterThan(view!.cellSize.width, cell.width)
        XCTAssertEqual(view!.core.gridSize.cols, 30)

        // Teardown: the thread goes away with the last pane.
        view!.removeFromSuperview()
        view = nil
        window.isHidden = true
        let deadline = Date().addingTimeInterval(3)
        while thread.alive.load(ordering: .relaxed) && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(thread.alive.load(ordering: .relaxed), "render thread still running")
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
