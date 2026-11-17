import Testing
import UIKit
@testable import RexDuo

/// The paper backing's coverage: the art's alpha with the seams inside the shape closed.
struct StickerPeelBackingTests {
    private func close(_ a: [UInt8], _ w: Int, _ h: Int, radius: Int = StickerPeelKit.backingSeam) -> [UInt8] {
        StickerPeelKit.closedAlpha(a, width: w, height: h, radius: radius)
    }

    /// A `w` x `h` field of clear texels with an opaque block from (4, 4) to (w - 5, h - 5).
    private func block(_ w: Int, _ h: Int) -> [UInt8] {
        var a = [UInt8](repeating: 0, count: w * h)
        for y in 4..<(h - 4) { for x in 4..<(w - 4) { a[y * w + x] = 255 } }
        return a
    }

    @Test func aSeamInsideTheShapeIsFilled() {
        let w = 24, h = 20
        var a = block(w, h)
        // Two shapes meeting edge to edge: a row of texels at 70%, and one at 40% beside it.
        for x in 4..<(w - 4) { a[10 * w + x] = 178 }
        a[10 * w + 12] = 102
        let c = close(a, w, h)
        // Filled along its length. Its last two texels at each end are within reach of the clear
        // outside, so they are outline and keep their value.
        for x in 6..<(w - 6) { #expect(c[10 * w + x] == 255, "x \(x)") }
        #expect(c[10 * w + 4] == 178 && c[10 * w + (w - 5)] == 178)
    }

    @Test func aSeamUpToTwiceTheRadiusFillsAndAWiderGapStays() {
        let w = 30, h = 30
        var narrow = block(w, h), wide = block(w, h)
        for y in 12..<16 { for x in 4..<(w - 4) { narrow[y * w + x] = 120 } }   // 4 texels
        for y in 10..<17 { for x in 4..<(w - 4) { wide[y * w + x] = 120 } }     // 7 texels: a real gap
        let n = close(narrow, w, h), g = close(wide, w, h)
        #expect((12..<16).allSatisfy { n[$0 * w + 15] == 255 })
        #expect(g[13 * w + 15] == 120)
    }

    @Test func theOutlineStaysWhereItWas() {
        let w = 24, h = 20
        var a = block(w, h)
        // An antialiased edge: a column at 50% outside the block's left side.
        for y in 4..<(h - 4) { a[y * w + 3] = 128 }
        let c = close(a, w, h)
        // Straight edges and their antialiasing are unchanged, and nothing appears outside.
        #expect(c == a)
    }

    @Test func coverageIsNeverRemoved() {
        var rng = SystemRandomNumberGenerator()
        let w = 17, h = 13
        let a = (0..<(w * h)).map { _ in UInt8.random(in: 0...255, using: &rng) }
        let c = close(a, w, h)
        #expect(zip(a, c).allSatisfy { $1 >= $0 })
        // Clear stays clear and opaque stays opaque: only the texels in between are decided.
        #expect(zip(a, c).allSatisfy { $0 != 0 || $1 == 0 })
    }

    @Test func degenerateInputComesBackAsIs() {
        #expect(close([], 0, 0) == [])
        #expect(close([7, 9], 2, 1, radius: 0) == [7, 9])
        #expect(close([1, 2, 3], 2, 2) == [1, 2, 3])   // wrong size: untouched
        // A shape touching the image edge keeps its texels.
        #expect(close([255, 255, 255, 255], 2, 2) == [255, 255, 255, 255])
    }

    // MARK: The real art

    /// `LaunchRexie`'s alpha, a byte a pixel.
    private func artAlpha() throws -> (alpha: [UInt8], width: Int, height: Int) {
        let cg = try #require(UIImage(named: "LaunchRexie")?.cgImage)
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let ok = bytes.withUnsafeMutableBytes { buf -> Bool in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        try #require(ok)
        return (stride(from: 3, to: bytes.count, by: 4).map { bytes[$0] }, w, h)
    }

    /// Texels with no clear texel within `reach`: the inside of the shape, away from its outline.
    private func interior(_ a: [UInt8], _ w: Int, _ h: Int, reach: Int) -> [Int] {
        (0..<(w * h)).filter { i in
            let x = i % w, y = i / w
            guard x >= reach, y >= reach, x < w - reach, y < h - reach else { return false }
            for dy in -reach...reach { for dx in -reach...reach where a[(y + dy) * w + x + dx] == 0 { return false } }
            return true
        }
    }

    @Test func theArtHasASeamAndTheBackingDoesNot() throws {
        let (a, w, h) = try artAlpha()
        let inside = interior(a, w, h, reach: 4)
        // The reason this exists: inside the art, where body and mouth meet, texels are see-through.
        let seam = inside.filter { a[$0] < 255 }
        #expect(!seam.isEmpty)
        #expect((seam.map { a[$0] }.min() ?? 255) < 230)

        let c = close(a, w, h)
        #expect(inside.allSatisfy { c[$0] == 255 })
    }

    @Test func closingTheArtIsQuick() throws {
        let (a, w, h) = try artAlpha()
        let clock = ContinuousClock()
        let took = clock.measure { _ = close(a, w, h) }
        print("closedAlpha \(w)x\(h): \(took)")
        // It runs once while the peel's kit is built, which must be ready before the peel starts.
        // About 15 ms unoptimized with the other tests running; a plain two-pass closing took 470.
        #expect(took < .milliseconds(120), "\(took)")
    }

    @Test func theBackingKeepsTheArtsOutline() throws {
        let (a, w, h) = try artAlpha()
        let c = close(a, w, h)
        // Nothing appears where the art is clear for a few texels around...
        for i in 0..<(w * h) where a[i] == 0 {
            let x = i % w, y = i / w
            var near = false
            for dy in -3...3 { for dx in -3...3 {
                let xx = x + dx, yy = y + dy
                if xx >= 0, yy >= 0, xx < w, yy < h, a[yy * w + xx] != 0 { near = true }
            } }
            if !near { #expect(c[i] == 0, "(\(x), \(y))") }
        }
        // ...and only the seam changes: a few hundred texels, none of them next to a clear one.
        let changed = (0..<(w * h)).filter { a[$0] != c[$0] }
        #expect(!changed.isEmpty)
        #expect(changed.count < 1000, "\(changed.count) texels changed")
        for i in changed {
            let x = i % w, y = i / w
            for dy in -2...2 { for dx in -2...2 { #expect(a[(y + dy) * w + x + dx] != 0) } }
        }
    }
}
