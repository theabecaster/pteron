import CoreGraphics
import CoreText
import Foundation
import UIKit

/// Pixel metrics of one cell. Everything is whole pixels at the layer's scale, so glyphs and
/// lines land on pixel boundaries.
struct GhosttyCellMetrics: Equatable {
    var cellWidth: Int
    var cellHeight: Int
    /// From the top of the cell down to the baseline.
    var baseline: Int
    var underlineTop: Int
    var underlineThickness: Int
    var strikeTop: Int
    var strikeThickness: Int
    /// The light line width of box drawing.
    var boxThickness: Int
    var scale: CGFloat

    var cellSizePoints: CGSize {
        CGSize(width: CGFloat(cellWidth) / scale, height: CGFloat(cellHeight) / scale)
    }
}

/// Where a rasterized glyph sits in an atlas and how to place it in its cell.
struct GhosttyGlyph {
    static let empty: UInt8 = 0
    static let mask: UInt8 = 1
    static let color: UInt8 = 2
    static let unknown: UInt8 = 0xff

    var u: UInt16 = 0
    var v: UInt16 = 0
    var w: UInt16 = 0
    var h: UInt16 = 0
    /// Offset of the bitmap's top-left from the cell's top-left.
    var ox: Int16 = 0
    var oy: Int16 = 0
    var kind: UInt8 = GhosttyGlyph.empty
}

/// A growable bitmap with shelf packing. CPU side only; the renderer mirrors it into a texture.
final class GhosttyAtlasPage {
    let width: Int
    private(set) var height: Int
    let maxHeight: Int
    let bytesPerPixel: Int
    private(set) var pixels: UnsafeMutablePointer<UInt8>
    private var shelfX = 1
    private var shelfY = 1
    private var shelfHeight = 0
    /// Rows changed since the renderer last uploaded. Empty when `dirtyMinY >= dirtyMaxY`.
    private(set) var dirtyMinY = Int.max
    private(set) var dirtyMaxY = 0
    /// Bumped when the bitmap is reallocated: the texture must be recreated.
    private(set) var sizeGeneration = 0

    init(width: Int, height: Int, maxHeight: Int, bytesPerPixel: Int) {
        self.width = width
        self.height = height
        self.maxHeight = maxHeight
        self.bytesPerPixel = bytesPerPixel
        pixels = .allocate(capacity: width * height * bytesPerPixel)
        pixels.initialize(repeating: 0, count: width * height * bytesPerPixel)
    }

    deinit { pixels.deallocate() }

    var bytesPerRow: Int { width * bytesPerPixel }

    /// Reserves `w` × `h` pixels with a one pixel gutter. Grows the page if needed. Nil when full.
    func allocate(_ w: Int, _ h: Int) -> (x: Int, y: Int)? {
        guard w + 2 <= width else { return nil }
        if shelfX + w + 1 > width {
            shelfY += shelfHeight + 1
            shelfX = 1
            shelfHeight = 0
        }
        while shelfY + h + 1 > height {
            guard height < maxHeight else { return nil }
            grow()
        }
        let pos = (shelfX, shelfY)
        shelfX += w + 1
        shelfHeight = max(shelfHeight, h)
        return pos
    }

    private func grow() {
        let newHeight = min(maxHeight, height * 2)
        let fresh = UnsafeMutablePointer<UInt8>.allocate(capacity: width * newHeight * bytesPerPixel)
        fresh.initialize(repeating: 0, count: width * newHeight * bytesPerPixel)
        fresh.update(from: pixels, count: width * height * bytesPerPixel)
        pixels.deallocate()
        pixels = fresh
        height = newHeight
        sizeGeneration += 1
        dirtyMinY = 0
        dirtyMaxY = shelfY + shelfHeight + 1
    }

    /// Copies `h` rows of `w` pixels from `src` (with `srcBytesPerRow`) to (x, y).
    func write(x: Int, y: Int, w: Int, h: Int, from src: UnsafePointer<UInt8>, srcBytesPerRow: Int) {
        for row in 0..<h {
            (pixels + ((y + row) * width + x) * bytesPerPixel)
                .update(from: src + row * srcBytesPerRow, count: w * bytesPerPixel)
        }
        dirtyMinY = min(dirtyMinY, y)
        dirtyMaxY = max(dirtyMaxY, y + h)
    }

    func clearDirty() {
        dirtyMinY = Int.max
        dirtyMaxY = 0
    }

    func reset() {
        pixels.update(repeating: 0, count: width * height * bytesPerPixel)
        shelfX = 1
        shelfY = 1
        shelfHeight = 0
        dirtyMinY = 0
        dirtyMaxY = height
    }
}

/// Fonts, cell metrics and the glyph cache for one font size at one scale.
///
/// `metrics` is fixed at init and safe to read anywhere. Everything else (lookups, rasterizing,
/// the atlas pages) belongs to one thread at a time: the render thread in the app.
final class GhosttyGlyphAtlas {
    static let regular = 0
    static let bold = 1
    static let italic = 2
    static let boldItalic = 3

    let pointSize: CGFloat
    let metrics: GhosttyCellMetrics
    /// Regular, bold, italic, bold italic at pixel size.
    let fonts: [CTFont]

    let maskPage = GhosttyAtlasPage(width: 2048, height: 512, maxHeight: 4096, bytesPerPixel: 1)
    let colorPage = GhosttyAtlasPage(width: 1024, height: 256, maxHeight: 2048, bytesPerPixel: 4)
    /// Bumped when the pages are wiped because they filled up. Every cached glyph position is
    /// then stale, so rows built before must be rebuilt.
    private(set) var generation = 0
    /// Glyphs rasterized so far (for tests and tuning).
    private(set) var rasterCount = 0

    /// Opaque storage for the renderer's textures, so panes sharing an atlas share them too.
    var rendererResources: AnyObject?

    private let ascii: UnsafeMutablePointer<GhosttyGlyph>
    private var glyphs: [UInt64: GhosttyGlyph] = [:]
    private var clusters: [ClusterKey: GhosttyGlyph] = [:]

    private struct ClusterKey: Hashable {
        var codepoints: [UInt32]
        var style: UInt8
        var cells: UInt8
    }

    // Scratch bitmaps, reused for every glyph.
    private var maskScratch: Scratch?
    private var colorScratch: Scratch?

    private final class Scratch {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let data: UnsafeMutablePointer<UInt8>
        let context: CGContext

        init?(width: Int, height: Int, color: Bool) {
            self.width = width
            self.height = height
            bytesPerRow = width * (color ? 4 : 1)
            data = .allocate(capacity: bytesPerRow * height)
            data.initialize(repeating: 0, count: bytesPerRow * height)
            let space = color ? CGColorSpaceCreateDeviceRGB() : CGColorSpaceCreateDeviceGray()
            // BGRA premultiplied, the layout of MTLPixelFormat.bgra8Unorm.
            let info = color
                ? CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
                : CGImageAlphaInfo.none.rawValue
            guard let ctx = CGContext(data: data, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: bytesPerRow, space: space, bitmapInfo: info) else {
                data.deallocate()
                return nil
            }
            ctx.setAllowsAntialiasing(true)
            ctx.setShouldAntialias(true)
            // Grayscale antialiasing at whole-pixel origins: crisp, and the same on every background.
            ctx.setAllowsFontSmoothing(false)
            ctx.setShouldSmoothFonts(false)
            ctx.setAllowsFontSubpixelPositioning(false)
            ctx.setShouldSubpixelPositionFonts(false)
            ctx.setAllowsFontSubpixelQuantization(false)
            ctx.setShouldSubpixelQuantizeFonts(false)
            if color { ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1) } else { ctx.setFillColor(gray: 1, alpha: 1) }
            context = ctx
        }

        deinit { data.deallocate() }

        func clear() { data.update(repeating: 0, count: bytesPerRow * height) }
    }

    // MARK: Shared instances

    private static let sharedLock = NSLock()
    private static var shared: [String: Weak] = [:]
    private final class Weak {
        weak var atlas: GhosttyGlyphAtlas?
        init(_ a: GhosttyGlyphAtlas) { atlas = a }
    }

    /// One atlas per font size and scale, shared by every pane that uses them.
    static func shared(pointSize: CGFloat, scale: CGFloat) -> GhosttyGlyphAtlas {
        let key = "\(Int((pointSize * 100).rounded()))@\(Int((scale * 100).rounded()))"
        sharedLock.lock()
        defer { sharedLock.unlock() }
        if let a = shared[key]?.atlas { return a }
        let a = GhosttyGlyphAtlas(pointSize: pointSize, scale: scale)
        shared = shared.filter { $0.value.atlas != nil }
        shared[key] = Weak(a)
        return a
    }

    init(pointSize: CGFloat, scale: CGFloat) {
        self.pointSize = pointSize
        let px = max(1, pointSize * scale)
        func font(_ name: String, _ fallbackTraits: CTFontSymbolicTraits) -> CTFont {
            if UIFont(name: name, size: 12) != nil { return CTFontCreateWithName(name as CFString, px, nil) }
            let base = CTFontCreateUIFontForLanguage(.userFixedPitch, px, nil) ?? CTFontCreateWithName("Menlo" as CFString, px, nil)
            if fallbackTraits.isEmpty { return base }
            return CTFontCreateCopyWithSymbolicTraits(base, px, nil, fallbackTraits, fallbackTraits) ?? base
        }
        // The same faces RexFont.all loads.
        fonts = [
            font("MesloLGS-NF-Regular", []),
            font("MesloLGS-NF-Bold", .traitBold),
            font("MesloLGS-NF-Italic", .traitItalic),
            font("MesloLGS-NF-Bold-Italic", [.traitBold, .traitItalic]),
        ]
        metrics = Self.measure(fonts[0], scale: scale)
        ascii = .allocate(capacity: 4 * 128)
        ascii.initialize(repeating: GhosttyGlyph(kind: GhosttyGlyph.unknown), count: 4 * 128)
    }

    deinit { ascii.deallocate() }

    /// Cell metrics the way Ghostty's `font/Metrics.zig` derives them: round the advance and the
    /// line height to whole pixels, then centre the face in the rounded cell.
    private static func measure(_ font: CTFont, scale: CGFloat) -> GhosttyCellMetrics {
        var chars: [UniChar] = Array("M".utf16)
        var glyph: [CGGlyph] = [0]
        CTFontGetGlyphsForCharacters(font, &chars, &glyph, 1)
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyph, &advance, 1)
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font), leading = CTFontGetLeading(font)
        let faceHeight = ascent + descent + leading
        let cellWidth = max(1, Int(advance.width.rounded()))
        let cellHeight = max(1, Int(faceHeight.rounded()))
        // Baseline from the bottom: half the line gap plus the descent, shifted to keep the face centred.
        let fromBottom = (leading / 2 + descent + (CGFloat(cellHeight) - faceHeight) / 2).rounded()
        let baseline = cellHeight - Int(fromBottom)
        let thickness = max(1, Int(CTFontGetUnderlineThickness(font).rounded(.up)))
        // CoreText's underline position is the line's centre, negative below the baseline.
        let underlineTop = min(cellHeight - thickness,
                               Int((CGFloat(baseline) - CTFontGetUnderlinePosition(font) - CGFloat(thickness) / 2).rounded()))
        let strikeTop = Int((CGFloat(baseline) - CTFontGetXHeight(font) / 2 - CGFloat(thickness) / 2).rounded())
        return GhosttyCellMetrics(cellWidth: cellWidth, cellHeight: cellHeight, baseline: baseline,
                                  underlineTop: max(0, underlineTop), underlineThickness: thickness,
                                  strikeTop: max(0, strikeTop), strikeThickness: thickness,
                                  boxThickness: thickness, scale: scale)
    }

    // MARK: Lookup

    /// Printable ASCII in one of the four faces. One array read once the glyph is cached.
    @inline(__always)
    func asciiGlyph(_ cp: UInt32, style: Int) -> GhosttyGlyph {
        let slot = ascii + (style &* 128 &+ Int(cp))
        if slot.pointee.kind != GhosttyGlyph.unknown { return slot.pointee }
        return rasterAscii(cp, style: style)
    }

    private func rasterAscii(_ cp: UInt32, style: Int) -> GhosttyGlyph {
        // If the pages were wiped while rasterizing, the table was cleared and this glyph is still valid.
        let g = rasterize(cp, style: style, cells: 1)
        ascii[style * 128 + Int(cp)] = g
        return g
    }

    /// Any single codepoint. `cells` is how many cells the glyph may cover (1 or 2).
    func glyph(_ cp: UInt32, style: Int, cells: Int) -> GhosttyGlyph {
        let sprite = GhosttySprites.isSprite(cp) || cp >= GhosttySprites.curlyUnderline
        let key = UInt64(cp) | UInt64(sprite ? 0 : style) << 24 | UInt64(cells) << 28
        if let g = glyphs[key] { return g }
        let g = sprite ? rasterizeSprite(cp, cells: cells) : rasterize(cp, style: style, cells: cells)
        glyphs[key] = g
        return g
    }

    /// A grapheme cluster: base codepoint plus combining marks, joiners, variation selectors.
    func glyph(cluster: UnsafeBufferPointer<UInt32>, style: Int, cells: Int) -> GhosttyGlyph {
        let key = ClusterKey(codepoints: Array(cluster), style: UInt8(style), cells: UInt8(cells))
        if let g = clusters[key] { return g }
        var scalars = String.UnicodeScalarView()
        for cp in cluster { if let s = Unicode.Scalar(cp) { scalars.append(s) } }
        let g = rasterizeLine(String(scalars), style: style, cells: cells)
        clusters[key] = g
        return g
    }

    // MARK: Rasterizing

    private func rasterize(_ cp: UInt32, style: Int, cells: Int) -> GhosttyGlyph {
        guard let scalar = Unicode.Scalar(cp) else { return GhosttyGlyph() }
        let font = fonts[style]
        var chars = Array(String(scalar).utf16)
        var out = [CGGlyph](repeating: 0, count: chars.count)
        if CTFontGetGlyphsForCharacters(font, &chars, &out, chars.count), out[0] != 0 {
            return rasterizeGlyph(out[0], font: font, cells: cells, fit: Self.isPrivateUse(cp))
        }
        // Not in MesloLGS NF: let CoreText pick a fallback font (CJK, symbols, emoji).
        return rasterizeLine(String(scalar), style: style, cells: cells)
    }

    @inline(__always)
    static func isPrivateUse(_ cp: UInt32) -> Bool {
        (cp >= 0xe000 && cp <= 0xf8ff) || cp >= 0xf0000
    }

    /// A glyph of one of our own faces, drawn at its natural position on the baseline. With
    /// `fit` (icons), a glyph wider than its cells is scaled down to fit them.
    private func rasterizeGlyph(_ glyph: CGGlyph, font: CTFont, cells: Int, fit: Bool) -> GhosttyGlyph {
        var g = glyph
        var rect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &rect, 1)
        guard rect.width > 0, rect.height > 0 else { return GhosttyGlyph() }
        var scale: CGFloat = 1
        let limit = CGFloat(cells * metrics.cellWidth)
        if fit, rect.maxX > limit + 0.5 {
            scale = min(1, limit / max(rect.maxX, rect.width))
        }
        let bounds = rect.applying(CGAffineTransform(scaleX: scale, y: scale))
        return draw(bounds: bounds, color: false) { ctx in
            ctx.scaleBy(x: scale, y: scale)
            var position = CGPoint.zero
            CTFontDrawGlyphs(font, &g, &position, 1, ctx)
        }
    }

    /// Text CoreText lays out for us, with font fallback. Scaled down if it is larger than its
    /// cells; colour glyphs (emoji) are centred in them.
    private func rasterizeLine(_ text: String, style: Int, cells: Int) -> GhosttyGlyph {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): fonts[style],
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        var isColor = false
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            if let f = attrs[kCTFontAttributeName as String] {
                // swiftlint:disable:next force_cast
                if CTFontGetSymbolicTraits(f as! CTFont).contains(.traitColorGlyphs) { isColor = true }
            }
        }
        guard let scratch = scratch(color: isColor, width: 16, height: 16) else { return GhosttyGlyph() }
        scratch.context.textMatrix = .identity
        scratch.context.textPosition = .zero
        let image = CTLineGetImageBounds(line, scratch.context)
        guard image.width > 0, image.height > 0, image.width.isFinite, image.height.isFinite else { return GhosttyGlyph() }
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let limitW = CGFloat(cells * metrics.cellWidth), limitH = CGFloat(metrics.cellHeight)
        var scale: CGFloat = 1
        let widest = max(advance, image.maxX)
        if widest > limitW + 0.5 { scale = min(scale, limitW / widest) }
        if image.height > limitH { scale = min(scale, limitH / image.height) }
        var dx: CGFloat = 0, dy: CGFloat = 0
        if isColor {
            // Centre the picture in its cells. `dy` is relative to the baseline, y up.
            dx = ((limitW - image.width * scale) / 2 - image.minX * scale).rounded()
            let bottom = (limitH - image.height * scale) / 2
            dy = (bottom - CGFloat(metrics.cellHeight - metrics.baseline) - image.minY * scale).rounded()
        } else if advance * scale < limitW - 0.5 {
            dx = ((limitW - advance * scale) / 2).rounded()
        }
        let bounds = image.applying(CGAffineTransform(scaleX: scale, y: scale)).offsetBy(dx: dx, dy: dy)
        return draw(bounds: bounds, color: isColor) { ctx in
            ctx.translateBy(x: dx, y: dy)
            ctx.scaleBy(x: scale, y: scale)
            ctx.textPosition = .zero
            CTLineDraw(line, ctx)
        }
    }

    private func scratch(color: Bool, width: Int, height: Int) -> Scratch? {
        let current = color ? colorScratch : maskScratch
        if let s = current, s.width >= width, s.height >= height { return s }
        let w = max(width, 4 * metrics.cellWidth + 8, current?.width ?? 0)
        let h = max(height, 2 * metrics.cellHeight + 8, current?.height ?? 0)
        let s = Scratch(width: w, height: h, color: color)
        if color { colorScratch = s } else { maskScratch = s }
        return s
    }

    /// Draws into the scratch bitmap and copies the result to an atlas page.
    /// `bounds` is the ink box relative to the pen origin on the baseline, y up, in pixels.
    /// `body` draws with the same origin.
    private func draw(bounds: CGRect, color: Bool, _ body: (CGContext) -> Void) -> GhosttyGlyph {
        let x0 = Int(bounds.minX.rounded(.down)) - 1, x1 = Int(bounds.maxX.rounded(.up)) + 1
        let y0 = Int(bounds.minY.rounded(.down)) - 1, y1 = Int(bounds.maxY.rounded(.up)) + 1
        let w = x1 - x0, h = y1 - y0
        guard w > 0, h > 0, w < 1024, h < 1024, let s = scratch(color: color, width: w, height: h) else { return GhosttyGlyph() }
        s.clear()
        let ctx = s.context
        ctx.saveGState()
        // The text matrix isn't part of the graphics state, and CTLineDraw leaves it changed.
        ctx.textMatrix = .identity
        // The bitmap's memory starts at its top row; our box occupies the bottom-left w × h.
        ctx.translateBy(x: CGFloat(-x0), y: CGFloat(-y0))
        body(ctx)
        ctx.restoreGState()
        let top = s.data + (s.height - h) * s.bytesPerRow
        var g = GhosttyGlyph()
        g.kind = color ? GhosttyGlyph.color : GhosttyGlyph.mask
        g.w = UInt16(w)
        g.h = UInt16(h)
        g.ox = Int16(clamping: x0)
        g.oy = Int16(clamping: metrics.baseline - y1)
        return store(&g, pixels: top, bytesPerRow: s.bytesPerRow)
    }

    private func rasterizeSprite(_ cp: UInt32, cells: Int) -> GhosttyGlyph {
        let decoration = cp >= GhosttySprites.curlyUnderline
        let w = metrics.cellWidth * (decoration ? 1 : max(1, cells))
        let h = decoration ? min(metrics.cellHeight, max(3, metrics.underlineThickness * 3)) : metrics.cellHeight
        let canvas = GhosttySprites.draw(cp, width: w, height: h, thickness: metrics.boxThickness)
        var g = GhosttyGlyph()
        g.kind = GhosttyGlyph.mask
        g.w = UInt16(w)
        g.h = UInt16(h)
        return canvas.pixels.withUnsafeBufferPointer { store(&g, pixels: $0.baseAddress!, bytesPerRow: w) }
    }

    private func store(_ g: inout GhosttyGlyph, pixels: UnsafePointer<UInt8>, bytesPerRow: Int) -> GhosttyGlyph {
        let page = g.kind == GhosttyGlyph.color ? colorPage : maskPage
        var slot = page.allocate(Int(g.w), Int(g.h))
        if slot == nil {
            wipe()
            slot = page.allocate(Int(g.w), Int(g.h))
        }
        guard let slot else { return GhosttyGlyph() }
        page.write(x: slot.x, y: slot.y, w: Int(g.w), h: Int(g.h), from: pixels, srcBytesPerRow: bytesPerRow)
        g.u = UInt16(slot.x)
        g.v = UInt16(slot.y)
        rasterCount += 1
        return g
    }

    /// The pages are full: forget everything and start over.
    private func wipe() {
        maskPage.reset()
        colorPage.reset()
        glyphs.removeAll(keepingCapacity: true)
        clusters.removeAll(keepingCapacity: true)
        ascii.update(repeating: GhosttyGlyph(kind: GhosttyGlyph.unknown), count: 4 * 128)
        generation += 1
    }

    /// Test hook: behaves as if the pages had filled up.
    func wipeForTesting() { wipe() }

    /// The mask coverage at a glyph's pixel (x, y). For tests.
    func maskCoverage(_ g: GhosttyGlyph, x: Int, y: Int) -> UInt8 {
        guard g.kind == GhosttyGlyph.mask, x >= 0, y >= 0, x < Int(g.w), y < Int(g.h) else { return 0 }
        return maskPage.pixels[(Int(g.v) + y) * maskPage.width + Int(g.u) + x]
    }
}
