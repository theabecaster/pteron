import CoreGraphics
import Foundation

/// Cell-exact procedural glyphs, drawn the way Ghostty's `src/font/sprite/draw` does, so boxes,
/// bars and Powerline separators meet their neighbours with no gaps. Font glyphs don't: their
/// outlines rarely match a pixel-rounded cell.
///
/// Covered: box drawing U+2500–257F, block elements U+2580–259F, braille U+2800–28FF and the
/// Powerline separators U+E0B0–E0B7 plus the filled corner triangles U+E0B8, E0BA, E0BC, E0BE.
enum GhosttySprites {
    /// Decorations kept in the atlas next to real glyphs. Values sit above the Unicode range.
    static let curlyUnderline: UInt32 = 0x11_0000

    @inline(__always)
    static func isSprite(_ cp: UInt32) -> Bool {
        if cp < 0x2500 { return false }
        if cp <= 0x259f { return true }
        if cp >= 0x2800 && cp <= 0x28ff { return true }
        if cp >= 0xe0b0 && cp <= 0xe0be {
            return cp <= 0xe0b7 || cp == 0xe0b8 || cp == 0xe0ba || cp == 0xe0bc || cp == 0xe0be
        }
        return false
    }

    /// A coverage bitmap, row 0 at the top.
    struct Canvas {
        let width: Int
        let height: Int
        var pixels: [UInt8]

        init(width: Int, height: Int) {
            self.width = width
            self.height = height
            pixels = [UInt8](repeating: 0, count: width * height)
        }

        /// Fills [x0, x1) × [y0, y1), clipped to the canvas.
        mutating func box(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ value: UInt8 = 255) {
            let ax = max(0, x0), bx = min(width, x1), ay = max(0, y0), by = min(height, y1)
            guard ax < bx, ay < by else { return }
            for y in ay..<by {
                for x in ax..<bx { pixels[y * width + x] = value }
            }
        }

        /// Antialiased drawing for the few shapes that aren't axis-aligned. Coordinates are y-down.
        mutating func draw(_ body: (CGContext) -> Void) {
            let w = width, h = height
            pixels.withUnsafeMutableBytes { raw in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w, space: CGColorSpaceCreateDeviceGray(),
                                          bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return }
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: 1, y: -1)
                ctx.setFillColor(gray: 1, alpha: 1)
                ctx.setStrokeColor(gray: 1, alpha: 1)
                ctx.setShouldAntialias(true)
                body(ctx)
            }
        }
    }

    /// Draws `cp` for a cell of `width` × `height` pixels. `thickness` is the light line width.
    static func draw(_ cp: UInt32, width: Int, height: Int, thickness: Int) -> Canvas {
        var c = Canvas(width: width, height: height)
        let t = max(1, thickness)
        switch cp {
        case 0x2500...0x257f: box(cp, &c, t)
        case 0x2580...0x259f: block(cp, &c)
        case 0x2800...0x28ff: braille(cp, &c)
        case 0xe0b0...0xe0be: powerline(cp, &c, t)
        case curlyUnderline: curly(&c, t)
        default: break
        }
        return c
    }

    // MARK: Box drawing

    /// Line style from the centre to each edge, two bits each: up, right, down, left.
    /// 0 none, 1 light, 2 heavy, 3 double. Generated from Ghostty's `box.zig`.
    private static let lines: [UInt8] = [
        0x44, 0x88, 0x11, 0x22, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x14, 0x18, 0x24, 0x28,
        0x50, 0x90, 0x60, 0xa0, 0x05, 0x09, 0x06, 0x0a, 0x41, 0x81, 0x42, 0x82, 0x15, 0x19, 0x16, 0x25,
        0x26, 0x1a, 0x29, 0x2a, 0x51, 0x91, 0x52, 0x61, 0x62, 0x92, 0xa1, 0xa2, 0x54, 0x94, 0x58, 0x98,
        0x64, 0xa4, 0x68, 0xa8, 0x45, 0x85, 0x49, 0x89, 0x46, 0x86, 0x4a, 0x8a, 0x55, 0x95, 0x59, 0x99,
        0x56, 0x65, 0x66, 0x96, 0x5a, 0xa5, 0x69, 0x9a, 0xa9, 0xa6, 0x6a, 0xaa, 0x00, 0x00, 0x00, 0x00,
        0xcc, 0x33, 0x1c, 0x34, 0x3c, 0xd0, 0x70, 0xf0, 0x0d, 0x07, 0x0f, 0xc1, 0x43, 0xc3, 0x1d, 0x37,
        0x3f, 0xd1, 0x73, 0xf3, 0xdc, 0x74, 0xfc, 0xcd, 0x47, 0xcf, 0xdd, 0x77, 0xff, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x40, 0x01, 0x04, 0x10, 0x80, 0x02, 0x08, 0x20, 0x48, 0x21, 0x84, 0x12,
    ]

    private static func box(_ cp: UInt32, _ c: inout Canvas, _ t: Int) {
        let packed = lines[Int(cp - 0x2500)]
        if packed != 0 {
            linesChar(&c, t, up: Int(packed & 3), right: Int((packed >> 2) & 3),
                      down: Int((packed >> 4) & 3), left: Int((packed >> 6) & 3))
            return
        }
        let heavy = cp & 1 == 1
        switch cp {
        case 0x2504, 0x2505: dash(&c, t, count: 3, heavy: heavy, horizontal: true)
        case 0x2506, 0x2507: dash(&c, t, count: 3, heavy: heavy, horizontal: false)
        case 0x2508, 0x2509: dash(&c, t, count: 4, heavy: heavy, horizontal: true)
        case 0x250a, 0x250b: dash(&c, t, count: 4, heavy: heavy, horizontal: false)
        case 0x254c, 0x254d: dash(&c, t, count: 2, heavy: heavy, horizontal: true)
        case 0x254e, 0x254f: dash(&c, t, count: 2, heavy: heavy, horizontal: false)
        case 0x256d...0x2570: arc(cp, &c, t)
        case 0x2571: diagonal(&c, t, rising: true)
        case 0x2572: diagonal(&c, t, rising: false)
        case 0x2573:
            diagonal(&c, t, rising: true)
            diagonal(&c, t, rising: false)
        default: break
        }
    }

    /// Port of Ghostty's `linesChar`: each arm runs from its edge to a join computed so that
    /// light, heavy and double strokes meet cleanly.
    private static func linesChar(_ c: inout Canvas, _ t: Int, up: Int, right: Int, down: Int, left: Int) {
        let w = c.width, h = c.height
        let light = t, heavy = t * 2
        let hLightTop = max(0, h - light) / 2, hLightBottom = hLightTop + light
        let hHeavyTop = max(0, h - heavy) / 2, hHeavyBottom = hHeavyTop + heavy
        let hDoubleTop = max(0, hLightTop - light), hDoubleBottom = hLightBottom + light
        let vLightLeft = max(0, w - light) / 2, vLightRight = vLightLeft + light
        let vHeavyLeft = max(0, w - heavy) / 2, vHeavyRight = vHeavyLeft + heavy
        let vDoubleLeft = max(0, vLightLeft - light), vDoubleRight = vLightRight + light

        let upBottom: Int
        if left == 2 || right == 2 { upBottom = hHeavyBottom }
        else if left != right || down == up { upBottom = (left == 3 || right == 3) ? hDoubleBottom : hLightBottom }
        else if left == 0 && right == 0 { upBottom = hLightBottom }
        else { upBottom = hLightTop }

        let downTop: Int
        if left == 2 || right == 2 { downTop = hHeavyTop }
        else if left != right || up == down { downTop = (left == 3 || right == 3) ? hDoubleTop : hLightTop }
        else if left == 0 && right == 0 { downTop = hLightTop }
        else { downTop = hLightBottom }

        let leftRight: Int
        if up == 2 || down == 2 { leftRight = vHeavyRight }
        else if up != down || left == right { leftRight = (up == 3 || down == 3) ? vDoubleRight : vLightRight }
        else if up == 0 && down == 0 { leftRight = vLightRight }
        else { leftRight = vLightLeft }

        let rightLeft: Int
        if up == 2 || down == 2 { rightLeft = vHeavyLeft }
        else if up != down || right == left { rightLeft = (up == 3 || down == 3) ? vDoubleLeft : vLightLeft }
        else if up == 0 && down == 0 { rightLeft = vLightLeft }
        else { rightLeft = vLightRight }

        switch up {
        case 1: c.box(vLightLeft, 0, vLightRight, upBottom)
        case 2: c.box(vHeavyLeft, 0, vHeavyRight, upBottom)
        case 3:
            c.box(vDoubleLeft, 0, vLightLeft, left == 3 ? hLightTop : upBottom)
            c.box(vLightRight, 0, vDoubleRight, right == 3 ? hLightTop : upBottom)
        default: break
        }
        switch right {
        case 1: c.box(rightLeft, hLightTop, w, hLightBottom)
        case 2: c.box(rightLeft, hHeavyTop, w, hHeavyBottom)
        case 3:
            c.box(up == 3 ? vLightRight : rightLeft, hDoubleTop, w, hLightTop)
            c.box(down == 3 ? vLightRight : rightLeft, hLightBottom, w, hDoubleBottom)
        default: break
        }
        switch down {
        case 1: c.box(vLightLeft, downTop, vLightRight, h)
        case 2: c.box(vHeavyLeft, downTop, vHeavyRight, h)
        case 3:
            c.box(vDoubleLeft, left == 3 ? hLightBottom : downTop, vLightLeft, h)
            c.box(vLightRight, right == 3 ? hLightBottom : downTop, vDoubleRight, h)
        default: break
        }
        switch left {
        case 1: c.box(0, hLightTop, leftRight, hLightBottom)
        case 2: c.box(0, hHeavyTop, leftRight, hHeavyBottom)
        case 3:
            c.box(0, hDoubleTop, up == 3 ? vLightLeft : leftRight, hLightTop)
            c.box(0, hLightBottom, down == 3 ? vLightLeft : leftRight, hDoubleBottom)
        default: break
        }
    }

    /// Dashes with half a gap at each end, so a run of dashed cells has even spacing.
    private static func dash(_ c: inout Canvas, _ t: Int, count: Int, heavy: Bool, horizontal: Bool) {
        let thick = heavy ? t * 2 : t
        let length = horizontal ? c.width : c.height
        let across = horizontal ? c.height : c.width
        let start = max(0, across - thick) / 2
        guard length >= count * 2 else {
            if horizontal { c.box(0, start, length, start + thick) } else { c.box(start, 0, start + thick, length) }
            return
        }
        let gap = min(max(4, t), length / (2 * count))
        let total = length - gap * count
        let dashLength = total / count
        var extra = total % count
        var p = gap / 2
        for _ in 0..<count {
            var q = p + dashLength
            if extra > 0 {
                extra -= 1
                q += 1
            }
            if horizontal { c.box(p, start, q, start + thick) } else { c.box(start, p, start + thick, q) }
            p = q + gap
        }
    }

    /// Rounded corners ╭ ╮ ╯ ╰. Same curve as Ghostty: a straight run, then a tight cubic.
    private static func arc(_ cp: UInt32, _ c: inout Canvas, _ t: Int) {
        let w = CGFloat(c.width), h = CGFloat(c.height), thick = CGFloat(t)
        let cx = CGFloat(max(0, c.width - t) / 2) + thick / 2
        let cy = CGFloat(max(0, c.height - t) / 2) + thick / 2
        let r = min(w, h) / 2
        let s: CGFloat = 0.25
        // ╭ joins down and right, ╮ down and left, ╯ up and left, ╰ up and right.
        let goesDown = cp == 0x256d || cp == 0x256e
        let goesRight = cp == 0x256d || cp == 0x2570
        let vy: CGFloat = goesDown ? 1 : -1
        let hx: CGFloat = goesRight ? 1 : -1
        c.draw { ctx in
            ctx.setLineWidth(thick)
            ctx.setLineCap(.butt)
            ctx.move(to: CGPoint(x: cx, y: goesDown ? h : 0))
            ctx.addLine(to: CGPoint(x: cx, y: cy + vy * r))
            ctx.addCurve(to: CGPoint(x: cx + hx * r, y: cy),
                         control1: CGPoint(x: cx, y: cy + vy * s * r),
                         control2: CGPoint(x: cx + hx * s * r, y: cy))
            ctx.addLine(to: CGPoint(x: goesRight ? w : 0, y: cy))
            ctx.strokePath()
        }
    }

    private static func diagonal(_ c: inout Canvas, _ t: Int, rising: Bool) {
        let w = CGFloat(c.width), h = CGFloat(c.height)
        let sx = min(1, w / h) * 0.5, sy = min(1, h / w) * 0.5
        c.draw { ctx in
            ctx.setLineWidth(CGFloat(t))
            if rising {
                ctx.move(to: CGPoint(x: w + sx, y: -sy))
                ctx.addLine(to: CGPoint(x: -sx, y: h + sy))
            } else {
                ctx.move(to: CGPoint(x: -sx, y: -sy))
                ctx.addLine(to: CGPoint(x: w + sx, y: h + sy))
            }
            ctx.strokePath()
        }
    }

    // MARK: Block elements

    private static func block(_ cp: UInt32, _ c: inout Canvas) {
        let w = c.width, h = c.height
        func eighthsH(_ n: Int) -> Int { Int((Double(h) * Double(n) / 8).rounded()) }
        func eighthsW(_ n: Int) -> Int { Int((Double(w) * Double(n) / 8).rounded()) }
        let halfW = eighthsW(4), halfH = eighthsH(4)
        switch cp {
        case 0x2580: c.box(0, 0, w, halfH)
        case 0x2581...0x2587: c.box(0, h - eighthsH(Int(cp - 0x2580)), w, h)
        case 0x2588: c.box(0, 0, w, h)
        case 0x2589...0x258f: c.box(0, 0, eighthsW(Int(0x2590 - cp)), h)
        case 0x2590: c.box(w - halfW, 0, w, h)
        case 0x2591: c.box(0, 0, w, h, 0x40)
        case 0x2592: c.box(0, 0, w, h, 0x80)
        case 0x2593: c.box(0, 0, w, h, 0xc0)
        case 0x2594: c.box(0, 0, w, eighthsH(1))
        case 0x2595: c.box(w - eighthsW(1), 0, w, h)
        default:
            // Quadrants: bit 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right.
            let quads: [UInt32: Int] = [0x2596: 4, 0x2597: 8, 0x2598: 1, 0x2599: 13, 0x259a: 9,
                                        0x259b: 7, 0x259c: 11, 0x259d: 2, 0x259e: 6, 0x259f: 14]
            guard let q = quads[cp] else { return }
            if q & 1 != 0 { c.box(0, 0, halfW, halfH) }
            if q & 2 != 0 { c.box(halfW, 0, w, halfH) }
            if q & 4 != 0 { c.box(0, halfH, halfW, h) }
            if q & 8 != 0 { c.box(halfW, halfH, w, h) }
        }
    }

    // MARK: Braille

    /// Port of Ghostty's braille layout: square dots, with spare pixels spread over the margins
    /// and gaps so the pattern stays centred.
    private static func braille(_ cp: UInt32, _ c: inout Canvas) {
        let width = c.width, height = c.height
        var w = min(width / 4, height / 8)
        var xSpacing = width / 4, ySpacing = height / 8
        var xMargin = xSpacing / 2, yMargin = ySpacing / 2
        var xLeft = width - 2 * xMargin - xSpacing - 2 * w
        var yLeft = height - 2 * yMargin - 3 * ySpacing - 4 * w
        if xLeft >= 2 && yLeft >= 4 && w == 0 { w += 1; xLeft -= 2; yLeft -= 4 }
        if xLeft >= 2 && xMargin == 0 { xMargin = 1; xLeft -= 2 }
        if yLeft >= 2 && yMargin == 0 { yMargin = 1; yLeft -= 2 }
        if xLeft >= 1 { xSpacing += 1; xLeft -= 1 }
        if yLeft >= 3 { ySpacing += 1; yLeft -= 3 }
        if xLeft >= 2 { xMargin += 1; xLeft -= 2 }
        if yLeft >= 2 { yMargin += 1; yLeft -= 2 }
        if xLeft >= 2 && yLeft >= 4 { w += 1; xLeft -= 2; yLeft -= 4 }
        let xs = [xMargin, xMargin + w + xSpacing]
        let ys = (0..<4).map { yMargin + $0 * (w + ySpacing) }
        let bits = Int(cp & 0xff)
        // Unicode dot numbering: bits 0-2 left column rows 0-2, 3-5 right column, 6 and 7 the bottom row.
        let dots: [(Int, Int)] = [(0, 0), (0, 1), (0, 2), (1, 0), (1, 1), (1, 2), (0, 3), (1, 3)]
        for (i, d) in dots.enumerated() where bits & (1 << i) != 0 {
            c.box(xs[d.0], ys[d.1], xs[d.0] + w, ys[d.1] + w)
        }
    }

    // MARK: Powerline

    private static func powerline(_ cp: UInt32, _ c: inout Canvas, _ t: Int) {
        let w = CGFloat(c.width), h = CGFloat(c.height)
        c.draw { ctx in
            ctx.setLineWidth(CGFloat(t))
            switch cp {
            case 0xe0b0: // right-pointing solid triangle
                ctx.move(to: .zero)
                ctx.addLine(to: CGPoint(x: w, y: h / 2))
                ctx.addLine(to: CGPoint(x: 0, y: h))
                ctx.fillPath()
            case 0xe0b1:
                ctx.move(to: .zero)
                ctx.addLine(to: CGPoint(x: w, y: h / 2))
                ctx.addLine(to: CGPoint(x: 0, y: h))
                ctx.strokePath()
            case 0xe0b2:
                ctx.move(to: CGPoint(x: w, y: 0))
                ctx.addLine(to: CGPoint(x: 0, y: h / 2))
                ctx.addLine(to: CGPoint(x: w, y: h))
                ctx.fillPath()
            case 0xe0b3:
                ctx.move(to: CGPoint(x: w, y: 0))
                ctx.addLine(to: CGPoint(x: 0, y: h / 2))
                ctx.addLine(to: CGPoint(x: w, y: h))
                ctx.strokePath()
            case 0xe0b4, 0xe0b5: // right half ellipse
                ctx.move(to: .zero)
                ctx.addCurve(to: CGPoint(x: 0, y: h), control1: CGPoint(x: w * 1.33, y: 0), control2: CGPoint(x: w * 1.33, y: h))
                if cp == 0xe0b4 { ctx.fillPath() } else { ctx.strokePath() }
            case 0xe0b6, 0xe0b7: // left half ellipse
                ctx.move(to: CGPoint(x: w, y: 0))
                ctx.addCurve(to: CGPoint(x: w, y: h), control1: CGPoint(x: -w * 0.33, y: 0), control2: CGPoint(x: -w * 0.33, y: h))
                if cp == 0xe0b6 { ctx.fillPath() } else { ctx.strokePath() }
            case 0xe0b8: // lower-left triangle
                ctx.move(to: .zero)
                ctx.addLine(to: CGPoint(x: w, y: h))
                ctx.addLine(to: CGPoint(x: 0, y: h))
                ctx.fillPath()
            case 0xe0ba: // lower-right triangle
                ctx.move(to: CGPoint(x: w, y: 0))
                ctx.addLine(to: CGPoint(x: w, y: h))
                ctx.addLine(to: CGPoint(x: 0, y: h))
                ctx.fillPath()
            case 0xe0bc: // upper-left triangle
                ctx.move(to: .zero)
                ctx.addLine(to: CGPoint(x: w, y: 0))
                ctx.addLine(to: CGPoint(x: 0, y: h))
                ctx.fillPath()
            case 0xe0be: // upper-right triangle
                ctx.move(to: .zero)
                ctx.addLine(to: CGPoint(x: w, y: 0))
                ctx.addLine(to: CGPoint(x: w, y: h))
                ctx.fillPath()
            default: break
            }
        }
    }

    // MARK: Decorations

    /// One period of a curly underline, sized to the canvas (cell width × a few line widths).
    private static func curly(_ c: inout Canvas, _ t: Int) {
        let w = CGFloat(c.width), h = CGFloat(c.height), thick = CGFloat(t)
        let amplitude = max(0.5, (h - thick) / 2)
        let mid = h / 2
        c.draw { ctx in
            ctx.setLineWidth(thick)
            ctx.setLineCap(.butt)
            ctx.move(to: CGPoint(x: -1, y: mid))
            var x: CGFloat = -1
            while x <= w + 1 {
                ctx.addLine(to: CGPoint(x: x, y: mid - sin(x / w * 2 * .pi) * amplitude))
                x += 0.5
            }
            ctx.strokePath()
        }
    }
}
