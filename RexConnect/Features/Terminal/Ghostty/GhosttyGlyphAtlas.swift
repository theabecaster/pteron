import CoreGraphics
import CoreText
import Foundation
import QuartzCore
import Synchronization
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
    /// Being drawn on the atlas's glyph worker. Nothing to show yet: leave it out and build the
    /// row again once `GhosttyGlyphAtlas.arrivals` has moved.
    static let pending: UInt8 = 0xfe
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
    /// The box of pixels changed since the renderer last uploaded. Empty when
    /// `dirtyMinY >= dirtyMaxY`.
    private(set) var dirtyMinX = Int.max
    private(set) var dirtyMaxX = 0
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

    /// Rows that hold glyphs, from the top. Nothing below them is ever sampled.
    var usedHeight: Int { min(height, shelfY + shelfHeight + 1) }

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
        // The renderer makes a new texture and fills it with the rows in use (`markUsedDirty`).
        sizeGeneration += 1
    }

    /// Copies `h` rows of `w` pixels from `src` (with `srcBytesPerRow`) to (x, y).
    func write(x: Int, y: Int, w: Int, h: Int, from src: UnsafePointer<UInt8>, srcBytesPerRow: Int) {
        for row in 0..<h {
            (pixels + ((y + row) * width + x) * bytesPerPixel)
                .update(from: src + row * srcBytesPerRow, count: w * bytesPerPixel)
        }
        dirtyMinX = min(dirtyMinX, x)
        dirtyMaxX = max(dirtyMaxX, x + w)
        dirtyMinY = min(dirtyMinY, y)
        dirtyMaxY = max(dirtyMaxY, y + h)
    }

    func clearDirty() {
        dirtyMinX = Int.max
        dirtyMaxX = 0
        dirtyMinY = Int.max
        dirtyMaxY = 0
    }

    /// Everything in use must be uploaded again (a new texture).
    func markUsedDirty() {
        dirtyMinX = 0
        dirtyMaxX = width
        dirtyMinY = 0
        dirtyMaxY = usedHeight
    }

    /// Forgets every glyph. Nothing is marked dirty: a glyph's box is uploaded when it is
    /// written, and pixels outside the boxes handed out are never read.
    func reset() {
        pixels.update(repeating: 0, count: width * height * bytesPerPixel)
        shelfX = 1
        shelfY = 1
        shelfHeight = 0
        clearDirty()
    }
}

/// Draws glyphs with CoreText into scratch bitmaps of its own.
///
/// It shares only the fonts and the metrics, which never change, so each thread that draws has
/// one: the atlas keeps one for glyphs drawn inside a frame and one for its glyph worker.
final class GhosttyGlyphRasterizer {
    /// A drawn glyph. `pixels` points into a scratch bitmap and is good until the next draw.
    struct Bitmap {
        /// Size, offset and kind. The atlas fills in the position.
        var glyph = GhosttyGlyph()
        var pixels: UnsafePointer<UInt8>?
        var bytesPerRow = 0
    }

    let fonts: [CTFont]
    let metrics: GhosttyCellMetrics
    // Scratch bitmaps, reused for every glyph.
    private var maskScratch: Scratch?
    private var colorScratch: Scratch?
    /// One per face. Building it per glyph showed in the cost of a fallback glyph.
    private let lineAttributes: [[NSAttributedString.Key: Any]]

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

    init(fonts: [CTFont], metrics: GhosttyCellMetrics) {
        self.fonts = fonts
        self.metrics = metrics
        lineAttributes = fonts.map { font in
            [NSAttributedString.Key(kCTFontAttributeName as String): font,
             NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true]
        }
    }

    /// The glyph for `cp` in one of our own faces, or nil if the face doesn't have it. Cheap:
    /// a table lookup.
    func ownGlyph(_ cp: UInt32, style: Int) -> CGGlyph? {
        guard let scalar = Unicode.Scalar(cp) else { return nil }
        var chars = Array(String(scalar).utf16)
        var out = [CGGlyph](repeating: 0, count: chars.count)
        return CTFontGetGlyphsForCharacters(fonts[style], &chars, &out, chars.count) && out[0] != 0 ? out[0] : nil
    }

    /// A glyph of one of our own faces, drawn at its natural position on the baseline. With
    /// `fit` (icons), a glyph wider than its cells is scaled down to fit them.
    func draw(_ glyph: CGGlyph, style: Int, cells: Int, fit: Bool) -> Bitmap {
        let font = fonts[style]
        var g = glyph
        var rect = CGRect.zero
        CTFontGetBoundingRectsForGlyphs(font, .horizontal, &g, &rect, 1)
        guard rect.width > 0, rect.height > 0 else { return Bitmap() }
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

    /// Text CoreText lays out for us, with font fallback (CJK, symbols, emoji, clusters). Scaled
    /// down if it is larger than its cells; colour glyphs (emoji) are centred in them.
    ///
    /// This is the slow path: CoreText looks for a font that has the text, and the first use of
    /// a fallback font in the process loads it (hundreds of milliseconds were measured).
    func draw(text: String, style: Int, cells: Int) -> Bitmap {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: lineAttributes[style]))
        var isColor = false
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            if let f = attrs[kCTFontAttributeName as String] {
                // swiftlint:disable:next force_cast
                if CTFontGetSymbolicTraits(f as! CTFont).contains(.traitColorGlyphs) { isColor = true }
            }
        }
        guard let scratch = scratch(color: isColor, width: 16, height: 16) else { return Bitmap() }
        scratch.context.textMatrix = .identity
        scratch.context.textPosition = .zero
        let image = CTLineGetImageBounds(line, scratch.context)
        guard image.width > 0, image.height > 0, image.width.isFinite, image.height.isFinite else { return Bitmap() }
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

    /// Draws into the scratch bitmap.
    /// `bounds` is the ink box relative to the pen origin on the baseline, y up, in pixels.
    /// `body` draws with the same origin.
    private func draw(bounds: CGRect, color: Bool, _ body: (CGContext) -> Void) -> Bitmap {
        let x0 = Int(bounds.minX.rounded(.down)) - 1, x1 = Int(bounds.maxX.rounded(.up)) + 1
        let y0 = Int(bounds.minY.rounded(.down)) - 1, y1 = Int(bounds.maxY.rounded(.up)) + 1
        let w = x1 - x0, h = y1 - y0
        guard w > 0, h > 0, w < 1024, h < 1024, let s = scratch(color: color, width: w, height: h) else { return Bitmap() }
        s.clear()
        let ctx = s.context
        ctx.saveGState()
        // The text matrix isn't part of the graphics state, and CTLineDraw leaves it changed.
        ctx.textMatrix = .identity
        // The bitmap's memory starts at its top row; our box occupies the bottom-left w × h.
        ctx.translateBy(x: CGFloat(-x0), y: CGFloat(-y0))
        body(ctx)
        ctx.restoreGState()
        var g = GhosttyGlyph()
        g.kind = color ? GhosttyGlyph.color : GhosttyGlyph.mask
        g.w = UInt16(w)
        g.h = UInt16(h)
        g.ox = Int16(clamping: x0)
        g.oy = Int16(clamping: metrics.baseline - y1)
        return Bitmap(glyph: g, pixels: UnsafePointer(s.data + (s.height - h) * s.bytesPerRow), bytesPerRow: s.bytesPerRow)
    }
}

/// The thread that draws slow glyphs, for every atlas. It is made once and then parks: asking a
/// dispatch queue instead meant a new thread for nearly every batch, and making one stalled the
/// frame that asked for 0.5 to 2 ms (measured). Parked, it wakes for nothing.
private final class GhosttyGlyphWorker: @unchecked Sendable {
    static let shared = GhosttyGlyphWorker()

    // Guarded by `condition`.
    private let condition = NSCondition()
    private var jobs: [@Sendable () -> Void] = []
    private var started = false

    /// Runs `job` on the worker thread, after the jobs before it. Any thread.
    func run(_ job: @escaping @Sendable () -> Void) {
        condition.lock()
        jobs.append(job)
        if !started {
            started = true
            let thread = Thread { [self] in work() }
            thread.name = "rex.ghostty.glyphs"
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        condition.signal()
        condition.unlock()
    }

    private func work() {
        while true {
            condition.lock()
            while jobs.isEmpty { condition.wait() }
            let job = jobs.removeFirst()
            condition.unlock()
            job()
        }
    }
}

/// Fonts, cell metrics and the glyph cache for one font size at one scale.
///
/// Threads:
/// - `metrics`, `fonts` and `pointSize` are fixed at init and safe to read anywhere.
/// - Everything else (the lookups, the pages, `generation`, `arrivals`, `rendererResources`) is
///   guarded by the atlas lock. The render thread takes it once per frame for the row build
///   (`GhosttyFrameBuilder.update`) and once for the texture upload, not per glyph. Lookups
///   therefore don't lock: call them with the lock held. (A test that owns an atlas it made
///   with `init` and builds without deferring may skip the lock: nothing else touches it.)
/// - The glyph worker thread draws the slow glyphs with a rasterizer of its own and takes the
///   lock only to copy a finished bitmap into a page, so a frame never waits for CoreText.
///
/// `@unchecked Sendable`: for the reasons above.
final class GhosttyGlyphAtlas: @unchecked Sendable {
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
    /// Bumped when the glyph worker has put a glyph in that a lookup answered `pending` for.
    private(set) var arrivals = 0
    /// While true, a lookup answers `GhosttyGlyph.pending` for a glyph that needs the slow path
    /// (font fallback, clusters) and has the glyph worker draw it. Glyphs of our own faces and
    /// sprites are always drawn at once: they cost tens of microseconds. Whoever takes the lock
    /// sets it for the lookups it makes.
    var defersSlowGlyphs = false

    /// Opaque storage for the renderer's textures, so panes sharing an atlas share them too.
    var rendererResources: AnyObject?

    private let guardLock = GhosttyLock()
    /// What each face has a glyph for. Made on first use (a fraction of a millisecond per face).
    private var coverage: [CFCharacterSet]?
    private let ascii: UnsafeMutablePointer<GhosttyGlyph>
    private var glyphs: [UInt64: GhosttyGlyph] = [:]
    private var clusters: [ClusterKey: GhosttyGlyph] = [:]
    /// Draws inside a frame. Used with the lock held.
    private let rasterizer: GhosttyGlyphRasterizer

    private struct ClusterKey: Hashable {
        var codepoints: [UInt32]
        var style: UInt8
        var cells: UInt8
    }

    // MARK: Glyph worker

    private enum Request {
        case ascii(cp: UInt32, style: Int)
        case codepoint(key: UInt64, cp: UInt32, style: Int, cells: Int)
        case cluster(ClusterKey)
        /// Draw and throw away: makes CoreText load its fallback fonts.
        case prime(String)
    }

    /// Glyph worker thread only.
    private let helperRasterizer: GhosttyGlyphRasterizer
    /// Guarded by the lock.
    private var requests: [Request] = []
    private var helperBusy = false
    /// CoreText's fallback fonts are loaded once per process.
    private static let primed = Atomic<Bool>(false)

    // MARK: Shared instances

    private static let shared = Mutex<[String: Weak]>([:])
    private struct Weak {
        weak var atlas: GhosttyGlyphAtlas?
    }

    /// One atlas per font size and scale, shared by every pane that uses them. A new one is
    /// warmed in the background (`warm`).
    static func shared(pointSize: CGFloat, scale: CGFloat) -> GhosttyGlyphAtlas {
        let key = "\(Int((pointSize * 100).rounded()))@\(Int((scale * 100).rounded()))"
        return shared.withLock { shared in
            if let a = shared[key]?.atlas { return a }
            let a = GhosttyGlyphAtlas(pointSize: pointSize, scale: scale)
            a.warm()
            shared = shared.filter { $0.value.atlas != nil }
            shared[key] = Weak(atlas: a)
            return a
        }
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
        rasterizer = GhosttyGlyphRasterizer(fonts: fonts, metrics: metrics)
        helperRasterizer = GhosttyGlyphRasterizer(fonts: fonts, metrics: metrics)
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

    // MARK: Lock

    /// Takes the atlas: for a frame's row build, or to read the pages.
    func lock() { guardLock.lock() }

    /// The worker is started here, not by the lookup that asks for a glyph: it couldn't store
    /// anything before the lock is free anyway, and waking it in the middle of a row build
    /// stalled the build.
    func unlock() {
        let start = !requests.isEmpty && !helperBusy
        if start { helperBusy = true }
        guardLock.unlock()
        if start { GhosttyGlyphWorker.shared.run { self.drain() } }
    }

    // MARK: Lookup (with the lock held)

    /// Printable ASCII in one of the four faces. One array read once the glyph is cached.
    @inline(__always)
    func asciiGlyph(_ cp: UInt32, style: Int) -> GhosttyGlyph {
        let slot = ascii + (style &* 128 &+ Int(cp))
        if slot.pointee.kind != GhosttyGlyph.unknown { return slot.pointee }
        return rasterAscii(cp, style: style)
    }

    private func rasterAscii(_ cp: UInt32, style: Int) -> GhosttyGlyph {
        // If the pages were wiped while rasterizing, the table was cleared and this glyph is still valid.
        let g = store(drawNow(cp, style: style, cells: 1))
        ascii[style * 128 + Int(cp)] = g
        return g
    }

    /// Any single codepoint. `cells` is how many cells the glyph may cover (1 or 2).
    func glyph(_ cp: UInt32, style: Int, cells: Int) -> GhosttyGlyph {
        let sprite = GhosttySprites.isSprite(cp) || cp >= GhosttySprites.curlyUnderline
        let key = UInt64(cp) | UInt64(sprite ? 0 : style) << 24 | UInt64(cells) << 28
        if let g = glyphs[key], g.kind != GhosttyGlyph.pending || defersSlowGlyphs { return g }
        let g: GhosttyGlyph
        if sprite {
            g = rasterizeSprite(cp, cells: cells)
        } else if defersSlowGlyphs, Unicode.Scalar(cp) != nil, !covers(cp, style: style) {
            // Not in MesloLGS NF: CoreText has to find a fallback font. Not inside a frame.
            g = GhosttyGlyph(kind: GhosttyGlyph.pending)
            request(.codepoint(key: key, cp: cp, style: style, cells: cells))
        } else if let own = rasterizer.ownGlyph(cp, style: style) {
            g = store(rasterizer.draw(own, style: style, cells: cells, fit: Self.isPrivateUse(cp)))
        } else if defersSlowGlyphs, Unicode.Scalar(cp) != nil {
            g = GhosttyGlyph(kind: GhosttyGlyph.pending)
            request(.codepoint(key: key, cp: cp, style: style, cells: cells))
        } else {
            g = store(drawNow(cp, style: style, cells: cells))
        }
        glyphs[key] = g
        return g
    }

    /// A grapheme cluster: base codepoint plus combining marks, joiners, variation selectors.
    func glyph(cluster: UnsafeBufferPointer<UInt32>, style: Int, cells: Int) -> GhosttyGlyph {
        let key = ClusterKey(codepoints: Array(cluster), style: UInt8(style), cells: UInt8(cells))
        if let g = clusters[key], g.kind != GhosttyGlyph.pending || defersSlowGlyphs { return g }
        let g: GhosttyGlyph
        if defersSlowGlyphs {
            g = GhosttyGlyph(kind: GhosttyGlyph.pending)
            request(.cluster(key))
        } else {
            g = store(rasterizer.draw(text: Self.text(key.codepoints), style: style, cells: cells))
        }
        clusters[key] = g
        return g
    }

    /// False if the face surely has no glyph for `cp`. A set lookup: asking CoreText for the
    /// glyph of every character a face lacks took milliseconds on a screen of CJK text.
    private func covers(_ cp: UInt32, style: Int) -> Bool {
        if coverage == nil { coverage = fonts.map { CTFontCopyCharacterSet($0) } }
        guard let set = coverage?[style] else { return true }
        return CFCharacterSetIsLongCharacterMember(set, cp)
    }

    private static func text(_ codepoints: [UInt32]) -> String {
        var scalars = String.UnicodeScalarView()
        for cp in codepoints { if let s = Unicode.Scalar(cp) { scalars.append(s) } }
        return String(scalars)
    }

    @inline(__always)
    static func isPrivateUse(_ cp: UInt32) -> Bool {
        (cp >= 0xe000 && cp <= 0xf8ff) || cp >= 0xf0000
    }

    // MARK: Rasterizing

    /// One codepoint, drawn on this thread whatever it takes. With the lock held.
    private func drawNow(_ cp: UInt32, style: Int, cells: Int) -> GhosttyGlyphRasterizer.Bitmap {
        Self.draw(cp, style: style, cells: cells, with: rasterizer)
    }

    private static func draw(_ cp: UInt32, style: Int, cells: Int, with r: GhosttyGlyphRasterizer) -> GhosttyGlyphRasterizer.Bitmap {
        guard let scalar = Unicode.Scalar(cp) else { return GhosttyGlyphRasterizer.Bitmap() }
        if let own = r.ownGlyph(cp, style: style) {
            return r.draw(own, style: style, cells: cells, fit: isPrivateUse(cp))
        }
        // Not in MesloLGS NF: let CoreText pick a fallback font (CJK, symbols, emoji).
        return r.draw(text: String(scalar), style: style, cells: cells)
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
        return canvas.pixels.withUnsafeBufferPointer {
            store(GhosttyGlyphRasterizer.Bitmap(glyph: g, pixels: $0.baseAddress, bytesPerRow: w))
        }
    }

    /// Copies a drawn glyph into its page. With the lock held.
    private func store(_ bitmap: GhosttyGlyphRasterizer.Bitmap) -> GhosttyGlyph {
        var g = bitmap.glyph
        guard g.kind != GhosttyGlyph.empty, let pixels = bitmap.pixels else { return GhosttyGlyph() }
        let page = g.kind == GhosttyGlyph.color ? colorPage : maskPage
        var slot = page.allocate(Int(g.w), Int(g.h))
        if slot == nil {
            wipe()
            slot = page.allocate(Int(g.w), Int(g.h))
        }
        guard let slot else { return GhosttyGlyph() }
        page.write(x: slot.x, y: slot.y, w: Int(g.w), h: Int(g.h), from: pixels, srcBytesPerRow: bitmap.bytesPerRow)
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

    // MARK: Glyph worker

    /// Draws printable ASCII in the four faces on the glyph worker and makes CoreText load its
    /// fallback fonts, so the first frames find their glyphs. Any thread. A frame that comes
    /// first draws what it needs itself.
    func warm() {
        lock()
        for style in 0..<4 {
            for cp in UInt32(0x21)...UInt32(0x7e) { requests.append(.ascii(cp: cp, style: style)) }
        }
        if !Self.primed.exchange(true, ordering: .relaxed) {
            // A symbol, a CJK character and an emoji: the fonts a terminal falls back to most.
            for text in ["\u{25cf}", "\u{65e5}", "\u{1f600}"] { requests.append(.prime(text)) }
        }
        unlock()
    }

    /// With the lock held. The worker starts when the lock is released.
    private func request(_ r: Request) {
        requests.append(r)
    }

    /// Blocks until the glyph worker has drawn everything asked of it so far. For tests.
    func waitForHelper() {
        let done = DispatchSemaphore(value: 0)
        GhosttyGlyphWorker.shared.run { done.signal() }
        done.wait()
    }

    /// Glyph worker thread. Draws without the lock, then takes it to store the result.
    private func drain() {
        var unannounced = false
        var announced = CACurrentMediaTime()
        while true {
            lock()
            guard !requests.isEmpty else {
                helperBusy = false
                unlock()
                break
            }
            let r = requests.removeFirst()
            var wanted = true
            if case .ascii(let cp, let style) = r {
                wanted = ascii[style * 128 + Int(cp)].kind == GhosttyGlyph.unknown
                // The first glyph of each face is drawn the way a frame draws: with the frame's
                // rasterizer, under the lock. The first draw of a face into a bitmap context
                // sets things up (milliseconds were measured), and a frame shouldn't be the one.
                if wanted, cp == 0x21 {
                    _ = rasterAscii(cp, style: style)
                    _ = covers(cp, style: style)
                    // The first insertion into a dictionary makes its storage type at run time:
                    // 0.5 to 2 ms were measured for the first cluster of a frame.
                    glyphs.reserveCapacity(256)
                    clusters.reserveCapacity(64)
                    wanted = false
                }
            }
            unlock()
            guard wanted else { continue }

            let bitmap: GhosttyGlyphRasterizer.Bitmap
            switch r {
            case .ascii(let cp, let style): bitmap = Self.draw(cp, style: style, cells: 1, with: helperRasterizer)
            case .codepoint(_, let cp, let style, let cells): bitmap = Self.draw(cp, style: style, cells: cells, with: helperRasterizer)
            case .cluster(let key):
                bitmap = helperRasterizer.draw(text: Self.text(key.codepoints), style: Int(key.style), cells: Int(key.cells))
            case .prime(let text): bitmap = helperRasterizer.draw(text: text, style: 0, cells: 2)
            }

            lock()
            let before = generation
            switch r {
            case .ascii(let cp, let style):
                // A frame may have drawn it meanwhile.
                if ascii[style * 128 + Int(cp)].kind == GhosttyGlyph.unknown {
                    let g = store(bitmap)
                    ascii[style * 128 + Int(cp)] = g
                }
            case .codepoint(let key, _, _, _):
                glyphs[key] = store(bitmap)
                arrivals += 1
                unannounced = true
            case .cluster(let key):
                clusters[key] = store(bitmap)
                arrivals += 1
                unannounced = true
            case .prime:
                break
            }
            // Storing wiped full pages: every pane's rows point at stale slots.
            if generation != before { unannounced = true }
            unlock()

            // Tell the panes now and then, so glyphs show while a long batch is still drawing.
            let now = CACurrentMediaTime()
            if unannounced, now - announced > 0.008 {
                unannounced = false
                announced = now
                GhosttyRenderThread.shared.glyphsReady()
            }
        }
        if unannounced { GhosttyRenderThread.shared.glyphsReady() }
    }
}
