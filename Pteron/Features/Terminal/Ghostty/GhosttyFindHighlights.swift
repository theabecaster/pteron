import Foundation

/// Find's tints, from a search result to rect instances on the viewport's rows. Pure, so it is
/// tested without a renderer.
///
/// Every match is tinted with the theme's yellow at 30%; the current match gets an opaque bright
/// yellow, and its text is drawn black or white (`FindContrast`), on at most `maxSpans` rows.
/// A current match that runs over more rows than that is tinted like the others past them.
enum GhosttyFindHighlights {
    /// Rows of the current match whose text is recolored (`GhosttyUniforms.matchSpans`).
    static let maxSpans = 4
    /// The tint every match gets.
    static let matchAlpha: UInt8 = 77  // 30%

    /// Colors, packed as the rect instances take them (`GhosttyRowBuilder.pack`).
    struct Colors: Equatable, Sendable {
        /// Every match: translucent.
        var match: UInt32
        /// The current match: opaque.
        var current: UInt32
        /// The current match's text, 0xRRGGBB.
        var currentText: UInt32

        /// From the theme's ANSI yellow (3) and bright yellow (11).
        static func theme(yellow: UInt32, brightYellow: UInt32) -> Colors {
            func rgba(_ c: UInt32, _ a: UInt8) -> UInt32 {
                GhosttyRowBuilder.pack(UInt8((c >> 16) & 0xff), UInt8((c >> 8) & 0xff), UInt8(c & 0xff), a)
            }
            return Colors(match: rgba(yellow, matchAlpha), current: rgba(brightYellow, 255),
                          currentText: FindContrast.text(on: brightYellow))
        }

        static let fallback = theme(yellow: 0xc69026, brightYellow: 0xdaaa3f)
    }

    /// One row's part of a match, in viewport rows and columns (both ends included).
    struct RowRange: Equatable {
        var row: Int
        var first: Int
        var last: Int
    }

    /// The viewport row ranges a match covers: rows outside `0..<rows` are dropped. `viewTop` is
    /// the first screen row the viewport shows.
    static func ranges(_ span: FindSpan, viewTop: Int, rows: Int, cols: Int) -> [RowRange] {
        let top = span.startRow - viewTop, bottom = span.endRow - viewTop
        guard bottom >= 0, top < rows, cols > 0 else { return [] }
        var out: [RowRange] = []
        for r in max(0, top)...min(rows - 1, bottom) {
            let first = r == top ? span.startCol : 0
            let last = r == bottom ? span.endCol : cols - 1
            guard last >= first else { continue }
            out.append(RowRange(row: r, first: min(first, cols - 1), last: min(last, cols - 1)))
        }
        return out
    }

    /// What the renderer draws for `result`: the tints, in drawing order (others first, then the
    /// current match), and the current match's recolored rows.
    /// - Parameters:
    ///   - viewTop: the first screen row the viewport shows.
    ///   - rows: viewport rows drawn (the overscan row included).
    ///   - wideAt: whether the cell at (viewport row, column) is a wide character's head; a match
    ///     that ends on one covers its tail too.
    static func build(_ result: FindResult, viewTop: Int, rows: Int, cols: Int, cellWidth: Int, cellHeight: Int,
                      colors: Colors, wideAt: (Int, Int) -> Bool) -> (rects: [GhosttyRectInstance], spans: [RowRange]) {
        guard result.open, !result.needle.isEmpty else { return ([], []) }
        var rects: [GhosttyRectInstance] = []
        func add(_ r: RowRange, _ color: UInt32) {
            var last = r.last
            if last + 1 < cols, wideAt(r.row, last) { last += 1 }
            rects.append(GhosttyRectInstance(x: Int16(clamping: r.first * cellWidth), y: 0,
                                             w: UInt16(clamping: (last - r.first + 1) * cellWidth),
                                             h: UInt16(clamping: cellHeight), color: color, row: UInt16(clamping: r.row)))
        }
        for m in result.matches where m != result.selected {
            for r in ranges(m, viewTop: viewTop, rows: rows, cols: cols) { add(r, colors.match) }
        }
        var spans: [RowRange] = []
        if let s = result.selected {
            let all = ranges(s, viewTop: viewTop, rows: rows, cols: cols)
            // The first rows of the match as it is on screen, not as it was searched.
            let firstRow = s.startRow - viewTop
            for r in all {
                if r.row - firstRow < maxSpans {
                    add(r, colors.current)
                    var span = r
                    if span.last + 1 < cols, wideAt(r.row, r.last) { span.last += 1 }
                    spans.append(span)
                } else {
                    add(r, colors.match)
                }
            }
        }
        return (rects, spans)
    }
}

/// Black or white text on a color, whichever contrasts more (WCAG 2 relative luminance). For any
/// background the better one reaches about 4.58:1 at least.
enum FindContrast {
    static func luminance(_ rgb: UInt32) -> Double {
        func channel(_ v: UInt32) -> Double {
            let c = Double(v & 0xff) / 255
            return c <= 0.039_28 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb >> 16) + 0.7152 * channel(rgb >> 8) + 0.0722 * channel(rgb)
    }

    static func ratio(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// 0x000000 or 0xffffff.
    static func text(on background: UInt32) -> UInt32 {
        ratio(0x000000, background) >= ratio(0xffffff, background) ? 0x000000 : 0xffffff
    }
}
