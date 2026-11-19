import Metal
import XCTest
@testable import RexDuo

/// Find's tints in the renderer: drawn with matches, nothing allocated or changed without.
final class FindRenderTests: XCTestCase {
    private func target(_ device: MTLDevice, width: Int, height: Int) throws -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        return try XCTUnwrap(device.makeTexture(descriptor: d))
    }

    private func bytes(_ texture: MTLTexture) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: texture.width * texture.height * 4)
        texture.getBytes(&out, bytesPerRow: texture.width * 4, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        return out
    }

    private func pixel(_ texture: MTLTexture, _ x: Int, _ y: Int) -> [UInt8] {
        var p = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&p, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return p // b, g, r, a
    }

    private func wait(_ find: GhosttyFind, _ predicate: (FindResult) -> Bool) {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            GhosttyFind.queue.sync {}
            if predicate(find.published.withLock { $0 }) { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    private let text = "one error\r\ntwo error\r\n"

    func testMatchesAreTintedTheCurrentOneOpaqueAndClosedFindDrawsAsWithout() throws {
        let metal = try XCTUnwrap(GhosttyMetal.shared)
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let m = atlas.metrics
        let width = 12 * m.cellWidth, height = 3 * m.cellHeight

        // Reference: the same text in a pane that never searched.
        let plain = GhosttyCore(cols: 12, rows: 3)
        plain.feed(Array(text.utf8))
        plain.sync()
        let reference = try target(metal.device, width: width, height: height)
        XCTAssertTrue(GhosttyRenderer(core: plain, atlas: atlas).renderOffscreen(into: reference))

        let core = GhosttyCore(cols: 12, rows: 3)
        core.feed(Array(text.utf8))
        core.sync()
        let renderer = GhosttyRenderer(core: core, atlas: atlas)
        let colors = GhosttyFindHighlights.Colors.fallback
        renderer.setFindColors(colors)
        let find = core.makeFind()
        find.open()
        find.setNeedle(Array("error".utf8))
        wait(find) { $0.total == 2 }
        XCTAssertFalse(renderer.hasHighlightBuffers, "no buffer before the first frame with a match")
        find.step(1)
        wait(find) { $0.selected != nil }
        let found = try target(metal.device, width: width, height: height)
        XCTAssertTrue(renderer.renderOffscreen(into: found))
        XCTAssertTrue(renderer.hasHighlightBuffers)
        // The newest match ("error" on row 1, column 4) is the current one: its fill is opaque
        // bright yellow at a corner no glyph reaches.
        let current = pixel(found, 4 * m.cellWidth + 1, m.cellHeight + 1)
        let c = colors.current
        XCTAssertEqual(current, [UInt8((c >> 16) & 0xff), UInt8((c >> 8) & 0xff), UInt8(c & 0xff), 0xff])
        // The other match is tinted: not the background, not the opaque fill.
        let other = pixel(found, 4 * m.cellWidth + 1, 1)
        XCTAssertNotEqual(other, pixel(reference, 4 * m.cellWidth + 1, 1))
        XCTAssertNotEqual(other, current)
        // Outside the matches nothing changed.
        XCTAssertEqual(pixel(found, 1, 1), pixel(reference, 1, 1))

        find.close()
        wait(find) { !$0.open }
        let closed = try target(metal.device, width: width, height: height)
        XCTAssertTrue(renderer.renderOffscreen(into: closed))
        XCTAssertEqual(bytes(closed), bytes(reference), "closed find draws byte for byte as a pane without find")
        XCTAssertFalse(renderer.hasHighlightBuffers, "freed at the first frame after closing")
    }

    func testThreeFramesInFlightKeepTheirOwnTints() throws {
        let metal = try XCTUnwrap(GhosttyMetal.shared)
        let atlas = GhosttyGlyphAtlas(pointSize: 12, scale: 2)
        let m = atlas.metrics
        let core = GhosttyCore(cols: 12, rows: 3)
        core.feed(Array("aa bb cc\r\n".utf8))
        core.sync()
        let renderer = GhosttyRenderer(core: core, atlas: atlas)
        let find = core.makeFind()
        find.open()
        var pending: [(MTLCommandBuffer, MTLTexture, Int)] = []
        for (needle, col) in [("aa", 0), ("bb", 3), ("cc", 6)] {
            find.setNeedle(Array(needle.utf8))
            find.step(1)
            wait(find) { $0.needle == Array(needle.utf8) && $0.selected != nil }
            let t = try target(metal.device, width: 12 * m.cellWidth, height: 3 * m.cellHeight)
            let commands = try XCTUnwrap(renderer.encodeOffscreen(into: t))
            pending.append((commands, t, col))
            renderer.offscreenCommitted()
        }
        // The GPU runs all three only now: each must show its own match.
        for (commands, _, _) in pending { commands.commit() }
        for (commands, t, col) in pending {
            commands.waitUntilCompleted()
            let c = GhosttyFindHighlights.Colors.fallback.current
            XCTAssertEqual(pixel(t, col * m.cellWidth + 1, 1), [UInt8((c >> 16) & 0xff), UInt8((c >> 8) & 0xff), UInt8(c & 0xff), 0xff],
                           "frame for column \(col)")
        }
    }

    func testDuringAHeldFrameOutputRefreshesQuietlyAndUserActionsBreakThrough() throws {
        let core = GhosttyCore(cols: 20, rows: 4)
        core.feed(Array("error\r\n".utf8))
        core.sync()
        let find = core.makeFind()
        find.open()
        find.setNeedle(Array("error".utf8))
        wait(find) { $0.total == 1 }
        _ = core.findDirty.exchange(false, ordering: .relaxed)
        // A program holds its frame (mode 2026) and writes more.
        core.feed(Array("\u{1b}[?2026herror again\r\n".utf8))
        core.sync()
        wait(find) { $0.total == 2 }
        XCTAssertFalse(core.findDirty.load(ordering: .relaxed), "an output refresh waits for the program's frame")
        find.step(1)
        wait(find) { $0.selected != nil }
        XCTAssertTrue(core.findDirty.load(ordering: .relaxed), "a step shows at once")
    }
}
