import Foundation
import GhosttyVt
import QuartzCore

/// A filled rectangle. Layout matches `RectInstance` in GhosttyShaders.metal (16 bytes).
struct GhosttyRectInstance {
    /// Pixels from the grid's left edge.
    var x: Int16
    /// Pixels from the top of the row.
    var y: Int16
    var w: UInt16
    var h: UInt16
    /// Bytes r, g, b, a. Not premultiplied.
    var color: UInt32
    var row: UInt16
    var pad: UInt16 = 0
}

/// A textured quad from an atlas. Layout matches `GlyphInstance` in GhosttyShaders.metal (24 bytes).
struct GhosttyGlyphInstance {
    var x: Int16
    var y: Int16
    var w: UInt16
    var h: UInt16
    var u: UInt16
    var v: UInt16
    var color: UInt32
    var col: UInt16
    var row: UInt16
    /// `GhosttyGlyph.mask` or `GhosttyGlyph.color`.
    var kind: UInt16
    var pad: UInt16 = 0
}

/// A plain growable buffer. Appending is one store; no retain/release or bounds traps on the hot path.
final class GhosttyInstanceList<T> {
    private(set) var base: UnsafeMutablePointer<T>
    private(set) var count = 0
    private var capacity: Int

    init(capacity: Int = 16) {
        self.capacity = capacity
        base = .allocate(capacity: capacity)
    }

    deinit { base.deallocate() }

    @inline(__always) func removeAll() { count = 0 }

    @inline(__always) func append(_ value: T) {
        if count == capacity { grow() }
        (base + count).initialize(to: value)
        count &+= 1
    }

    private func grow() {
        let bigger = UnsafeMutablePointer<T>.allocate(capacity: capacity * 2)
        bigger.moveInitialize(from: base, count: count)
        base.deallocate()
        base = bigger
        capacity *= 2
    }

    subscript(i: Int) -> T {
        get { base[i] }
        set { base[i] = newValue }
    }

    var array: [T] { Array(UnsafeBufferPointer(start: base, count: count)) }
}

/// Everything needed to draw one row, in draw order: backgrounds, underlines, glyphs, then
/// lines that go over text.
final class GhosttyRow {
    var id: (UInt64, UInt64) = (0, 0)
    /// Viewport row the instances are stamped with.
    var y = -1
    let backgrounds = GhosttyInstanceList<GhosttyRectInstance>()
    let underlines = GhosttyInstanceList<GhosttyRectInstance>()
    /// Sprites that go under the text (curly underlines).
    let underGlyphs = GhosttyInstanceList<GhosttyGlyphInstance>(capacity: 4)
    let glyphs = GhosttyInstanceList<GhosttyGlyphInstance>(capacity: 96)
    let overlays = GhosttyInstanceList<GhosttyRectInstance>()
    /// Columns that start a wide character (the cursor needs to know).
    var wideColumns: [UInt16] = []

    // What the instances were built from, kept so a scroll step can tell that a row it has
    // already built is still right (`GhosttyRowBuilder.matches`).
    private(set) var source: UnsafeMutablePointer<GhosttyCell>?
    private(set) var sourceCount = 0
    private var sourceCapacity = 0
    var selectionStart = -1
    var selectionEnd = -1
    /// The row has cells whose text lives outside the cell (grapheme clusters), which the raw
    /// cells can't vouch for.
    var hasClusters = false

    deinit { source?.deallocate() }

    func remember(_ cells: UnsafePointer<GhosttyCell>, count: Int) {
        if count > sourceCapacity {
            source?.deallocate()
            source = .allocate(capacity: count)
            sourceCapacity = count
        }
        source?.update(from: cells, count: count)
        sourceCount = count
    }

    func removeAll() {
        backgrounds.removeAll()
        underlines.removeAll()
        underGlyphs.removeAll()
        glyphs.removeAll()
        overlays.removeAll()
        if !wideColumns.isEmpty { wideColumns.removeAll(keepingCapacity: true) }
        sourceCount = 0
        selectionStart = -1
        selectionEnd = -1
        hasClusters = false
    }

    /// Moves a built row to another viewport row without rebuilding it.
    func restamp(_ newY: Int) {
        guard newY != y else { return }
        y = newY
        let r = UInt16(clamping: newY)
        // `while`, not `for in`: an unoptimized build allocates for every range iterator, and
        // this runs for every row of every scroll step.
        var i = 0
        var rects = backgrounds.base
        while i < backgrounds.count { rects[i].row = r; i += 1 }
        i = 0
        rects = underlines.base
        while i < underlines.count { rects[i].row = r; i += 1 }
        i = 0
        rects = overlays.base
        while i < overlays.count { rects[i].row = r; i += 1 }
        i = 0
        var quads = underGlyphs.base
        while i < underGlyphs.count { quads[i].row = r; i += 1 }
        i = 0
        quads = glyphs.base
        while i < glyphs.count { quads[i].row = r; i += 1 }
    }
}

/// Turns render-state rows into instances. Rendering policy follows Ghostty's own renderer
/// (`src/renderer/generic.zig`, `rebuildRow`):
/// - inverse swaps the cell's foreground and background, with the defaults standing in;
/// - faint halves the foreground alpha; bold only picks the bold face (no brightening);
/// - invisible cells keep their background and draw nothing else;
/// - underlines go under the text, strikethrough and overline over it.
/// Selected cells get the theme's selection color laid over their background.
final class GhosttyRowBuilder {
    static let flagBold: UInt16 = 1 << 0
    static let flagItalic: UInt16 = 1 << 1
    static let flagFaint: UInt16 = 1 << 2
    static let flagInverse: UInt16 = 1 << 4
    static let flagInvisible: UInt16 = 1 << 5
    static let flagStrikethrough: UInt16 = 1 << 6
    static let flagOverline: UInt16 = 1 << 7

    var atlas: GhosttyGlyphAtlas
    /// r, g, b, a bytes, laid over selected cells.
    var selectionColor: UInt32 = GhosttyRowBuilder.pack(0x3d, 0x4e, 0x63, 140)
    /// Foreground alpha of faint text. Ghostty's default `faint-opacity` is 0.5.
    var faintAlpha: UInt32 = 128

    // Colors of the current frame, packed r, g, b, a.
    private(set) var foreground: UInt32 = 0xffff_ffff
    private(set) var background: UInt32 = 0xff00_0000
    private let palette = UnsafeMutablePointer<UInt32>.allocate(capacity: 256)
    private let paletteRaw = UnsafeMutableRawPointer.allocate(byteCount: 768, alignment: 1)

    // Scratch for C calls: outputs of one ghostty_cell_get_multi.
    private let keys = UnsafeMutablePointer<GhosttyCellData>.allocate(capacity: 5)
    private let values = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 5)
    private let outCodepoint = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
    private let outTag = UnsafeMutablePointer<GhosttyCellContentTag>.allocate(capacity: 1)
    private let outWide = UnsafeMutablePointer<GhosttyCellWide>.allocate(capacity: 1)
    private let outStyled = UnsafeMutablePointer<Bool>.allocate(capacity: 1)
    private let outStyleId = UnsafeMutablePointer<UInt16>.allocate(capacity: 1)
    private let cluster = UnsafeMutablePointer<UInt32>.allocate(capacity: 32)

    init(atlas: GhosttyGlyphAtlas) {
        self.atlas = atlas
        palette.initialize(repeating: 0, count: 256)
        paletteRaw.initializeMemory(as: UInt8.self, repeating: 0, count: 768)
        keys[0] = GHOSTTY_CELL_DATA_CODEPOINT
        keys[1] = GHOSTTY_CELL_DATA_CONTENT_TAG
        keys[2] = GHOSTTY_CELL_DATA_WIDE
        keys[3] = GHOSTTY_CELL_DATA_HAS_STYLING
        keys[4] = GHOSTTY_CELL_DATA_STYLE_ID
        outCodepoint.initialize(to: 0)
        outTag.initialize(to: GHOSTTY_CELL_CONTENT_CODEPOINT)
        outWide.initialize(to: GHOSTTY_CELL_WIDE_NARROW)
        outStyled.initialize(to: false)
        outStyleId.initialize(to: 0)
        cluster.initialize(repeating: 0, count: 32)
        values[0] = UnsafeMutableRawPointer(outCodepoint)
        values[1] = UnsafeMutableRawPointer(outTag)
        values[2] = UnsafeMutableRawPointer(outWide)
        values[3] = UnsafeMutableRawPointer(outStyled)
        values[4] = UnsafeMutableRawPointer(outStyleId)
    }

    deinit {
        palette.deallocate()
        paletteRaw.deallocate()
        keys.deallocate()
        values.deallocate()
        outCodepoint.deallocate()
        outTag.deallocate()
        outWide.deallocate()
        outStyled.deallocate()
        outStyleId.deallocate()
        cluster.deallocate()
    }

    @inline(__always)
    static func pack(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) -> UInt32 {
        UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | UInt32(a) << 24
    }

    @inline(__always)
    static func pack(_ c: GhosttyColorRgb) -> UInt32 { pack(c.r, c.g, c.b) }

    @inline(__always)
    private static func withAlpha(_ c: UInt32, _ a: UInt32) -> UInt32 { (c & 0x00ff_ffff) | a << 24 }

    /// Reads the frame's colors. Returns true if any differ from the last frame, in which case
    /// every row must be rebuilt.
    func loadColors(_ state: GhosttyRenderState) -> Bool {
        var colors = GhosttyRenderStateColors()
        colors.size = MemoryLayout<GhosttyRenderStateColors>.size
        guard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLORS, &colors) == GHOSTTY_SUCCESS else { return false }
        let fg = Self.pack(colors.foreground), bg = Self.pack(colors.background)
        var changed = fg != foreground || bg != background
        foreground = fg
        background = bg
        withUnsafeBytes(of: &colors.palette) { raw in
            guard raw.count >= 768, memcmp(raw.baseAddress, paletteRaw, 768) != 0 else { return }
            changed = true
            paletteRaw.copyMemory(from: raw.baseAddress!, byteCount: 768)
            let p = raw.bindMemory(to: UInt8.self)
            for i in 0..<256 { palette[i] = Self.pack(p[i * 3], p[i * 3 + 1], p[i * 3 + 2]) }
        }
        return changed
    }

    @inline(__always)
    private func resolve(_ c: GhosttyStyleColor) -> UInt32? {
        switch UInt32(c.tag) {
        case GHOSTTY_STYLE_COLOR_PALETTE.rawValue: return palette[Int(c.value.palette)]
        case GHOSTTY_STYLE_COLOR_RGB.rawValue: return Self.pack(c.value.rgb)
        default: return nil
        }
    }

    /// The iterator's current row's selected columns, both included, or (-1, -1).
    @inline(__always)
    private func selection(_ iterator: GhosttyRenderStateRowIterator, cells raws: UnsafePointer<GhosttyCell>, count: Int) -> (Int, Int) {
        var selection = GhosttyRenderStateRowSelection()
        selection.size = MemoryLayout<GhosttyRenderStateRowSelection>.size
        guard ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS else {
            return (-1, -1)
        }
        var end = Int(selection.end_x)
        // A selection that ends on a wide character covers both of its cells. (The render
        // state already widens a start on the right half.)
        if end >= 0, end + 1 < count {
            var endWide = GHOSTTY_CELL_WIDE_NARROW
            ghostty_cell_get(raws[end], GHOSTTY_CELL_DATA_WIDE, &endWide)
            if endWide == GHOSTTY_CELL_WIDE_WIDE { end += 1 }
        }
        return (Int(selection.start_x), end)
    }

    /// True if `row`, built earlier, is exactly what building the iterator's current row would
    /// give now. The caller has already matched the row id.
    ///
    /// Upstream marks every row dirty after the viewport scrolls ("the dirty flag is
    /// conservative"), so the flag can't tell a scrolled row from a changed one. This can: a
    /// row's instances are a function of its cells, the styles those cells name, its selection,
    /// the colors and the atlas. Colors and atlas changes rebuild everything before we get here.
    /// A style id is fixed while a cell of the same row still uses it, so equal cells mean equal
    /// styles. Grapheme clusters live outside the cells, so rows that have any are rebuilt.
    func matches(_ row: GhosttyRow, iterator: GhosttyRenderStateRowIterator) -> Bool {
        guard !row.hasClusters, let source = row.source else { return false }
        var view = GhosttyCellsView()
        guard ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW, &view) == GHOSTTY_SUCCESS,
              let raws = view.ptr, view.len == row.sourceCount,
              memcmp(raws, source, view.len * MemoryLayout<GhosttyCell>.stride) == 0 else { return false }
        return selection(iterator, cells: raws, count: view.len) == (row.selectionStart, row.selectionEnd)
    }

    /// Builds `row` from the iterator's current row. `cells` is the shared cells handle.
    func build(_ row: GhosttyRow, y: Int, iterator: GhosttyRenderStateRowIterator, cells: GhosttyRenderStateRowCells) {
        row.removeAll()
        row.y = y
        let rowIndex = UInt16(clamping: y)
        var view = GhosttyCellsView()
        guard ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW, &view) == GHOSTTY_SUCCESS,
              let raws = view.ptr, view.len > 0 else { return }
        let count = view.len
        row.remember(raws, count: count)

        let (selStart, selEnd) = selection(iterator, cells: raws, count: count)
        row.selectionStart = selStart
        row.selectionEnd = selEnd

        let m = atlas.metrics
        let cellW = m.cellWidth, cellH = m.cellHeight
        var cellsLoaded = false
        var cells = Optional(cells)

        // Decoded fields of the last distinct raw cell. Runs of equal cells decode once.
        var lastRaw: GhosttyCell = 0
        var haveRaw = false
        var cp: UInt32 = 0
        var tag = GHOSTTY_CELL_CONTENT_CODEPOINT
        var wide = GHOSTTY_CELL_WIDE_NARROW
        var styled = false
        var styleId: UInt16 = 0
        var cellBackground: UInt32? = nil
        var lastGlyph = GhosttyGlyph()
        var haveGlyph = false

        // The last style fetched. A row lives in one page, so a style id names one style.
        var cachedStyleId: Int = -1
        var styleFg: UInt32? = nil
        var styleBg: UInt32? = nil
        var styleUnderlineColor: UInt32? = nil
        var styleFlags: UInt16 = 0

        // Open runs, merged across adjacent cells.
        var bgStart = 0
        var bgColor: UInt32 = 0
        var ulStart = 0
        var ulStyle = 0
        var ulColor: UInt32 = 0
        var previousWasIcon = false

        @inline(__always) func flushBackground(_ end: Int) {
            if bgColor != 0 && end > bgStart {
                row.backgrounds.append(GhosttyRectInstance(
                    x: Int16(clamping: bgStart * cellW), y: 0,
                    w: UInt16(clamping: (end - bgStart) * cellW), h: UInt16(clamping: cellH),
                    color: bgColor, row: rowIndex))
            }
        }

        func flushUnderline(_ end: Int) {
            guard ulStyle != 0, end > ulStart else { return }
            let x0 = ulStart * cellW, width = (end - ulStart) * cellW
            let t = m.underlineThickness
            let top = m.underlineTop
            switch ulStyle {
            case 2: // double
                let first = max(0, min(top - t, cellH - 3 * t))
                for y in [first, first + 2 * t] {
                    row.underlines.append(GhosttyRectInstance(x: Int16(clamping: x0), y: Int16(clamping: y), w: UInt16(clamping: width),
                                                              h: UInt16(clamping: t), color: ulColor, row: rowIndex))
                }
            case 3: // curly: one sprite per cell, a full wave period each
                let sprite = atlas.glyph(GhosttySprites.curlyUnderline, style: 0, cells: 1)
                guard sprite.kind == GhosttyGlyph.mask else { break }
                let y = max(0, min(top + t / 2 - Int(sprite.h) / 2, cellH - Int(sprite.h)))
                for col in ulStart..<end {
                    row.underGlyphs.append(GhosttyGlyphInstance(
                        x: Int16(clamping: col * cellW), y: Int16(clamping: y), w: sprite.w, h: sprite.h, u: sprite.u, v: sprite.v,
                        color: ulColor, col: 0xffff, row: rowIndex, kind: UInt16(GhosttyGlyph.mask)))
                }
            case 4, 5: // dotted, dashed
                let on = ulStyle == 4 ? max(1, t) : max(2, cellW / 2)
                let period = ulStyle == 4 ? 2 * on : cellW
                var x = x0
                while x < x0 + width {
                    row.underlines.append(GhosttyRectInstance(x: Int16(clamping: x), y: Int16(clamping: top), w: UInt16(clamping: min(on, x0 + width - x)),
                                                              h: UInt16(clamping: t), color: ulColor, row: rowIndex))
                    x += period
                }
            default:
                row.underlines.append(GhosttyRectInstance(x: Int16(clamping: x0), y: Int16(clamping: top), w: UInt16(clamping: width),
                                                          h: UInt16(clamping: t), color: ulColor, row: rowIndex))
            }
        }

        var x = 0
        while x < count {
            let raw = raws[x]
            let sameAsLast = haveRaw && raw == lastRaw
            if !sameAsLast {
                ghostty_cell_get_multi(raw, 5, keys, values, nil)
                cp = outCodepoint.pointee
                tag = outTag.pointee
                wide = outWide.pointee
                styled = outStyled.pointee
                styleId = outStyleId.pointee
                cellBackground = nil
                if tag == GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE {
                    var index: GhosttyColorPaletteIndex = 0
                    ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_PALETTE, &index)
                    cellBackground = palette[Int(index)]
                } else if tag == GHOSTTY_CELL_CONTENT_BG_COLOR_RGB {
                    var rgb = GhosttyColorRgb()
                    ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_RGB, &rgb)
                    cellBackground = Self.pack(rgb)
                }
                lastRaw = raw
                haveRaw = true
                haveGlyph = false
            }

            var flags: UInt16 = 0
            var fgStyle = foreground
            var bgStyle: UInt32? = cellBackground
            var underlineColor: UInt32? = nil
            if styled {
                if cachedStyleId != Int(styleId) {
                    if !cellsLoaded {
                        cellsLoaded = ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells) == GHOSTTY_SUCCESS
                    }
                    var style = GhosttyStyle()
                    if cellsLoaded, ghostty_render_state_row_cells_select(cells, UInt16(x)) == GHOSTTY_SUCCESS,
                       ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) == GHOSTTY_SUCCESS {
                        styleFg = resolve(style.fg_color)
                        styleBg = resolve(style.bg_color)
                        styleUnderlineColor = resolve(style.underline_color)
                        styleFlags = style.flags
                        cachedStyleId = Int(styleId)
                    } else {
                        styleFg = nil
                        styleBg = nil
                        styleUnderlineColor = nil
                        styleFlags = 0
                        cachedStyleId = -1
                    }
                }
                flags = styleFlags
                if let c = styleFg { fgStyle = c }
                if cellBackground == nil { bgStyle = styleBg }
                underlineColor = styleUnderlineColor
            }

            let inverse = flags & Self.flagInverse != 0
            let bg: UInt32 = inverse ? fgStyle : (bgStyle ?? 0)
            var fg: UInt32 = inverse ? (bgStyle ?? background) : fgStyle
            if flags & Self.flagFaint != 0 { fg = Self.withAlpha(fg, faintAlpha) }

            if bg != bgColor {
                flushBackground(x)
                bgStart = x
                bgColor = bg
            }

            let invisible = flags & Self.flagInvisible != 0
            let underline = invisible ? 0 : Int((flags >> 8) & 7)
            let wantedUnderlineColor = underline == 0 ? 0 : (underlineColor.map { Self.withAlpha($0, fg >> 24) } ?? fg)
            if underline != ulStyle || wantedUnderlineColor != ulColor {
                flushUnderline(x)
                ulStart = x
                ulStyle = underline
                ulColor = wantedUnderlineColor
            }

            let isTail = wide == GHOSTTY_CELL_WIDE_SPACER_TAIL
            let isWide = wide == GHOSTTY_CELL_WIDE_WIDE
            if isWide { row.wideColumns.append(UInt16(x)) }
            var isIcon = false

            if !invisible && !isTail && wide != GHOSTTY_CELL_WIDE_SPACER_HEAD {
                if cp > 0x20 {
                    let face = Int(flags & 3)
                    var glyph: GhosttyGlyph
                    if tag == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME {
                        // Extra codepoints live outside the cell, so equal cells can differ here.
                        row.hasClusters = true
                        glyph = GhosttyGlyph()
                        if !cellsLoaded {
                            cellsLoaded = ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells) == GHOSTTY_SUCCESS
                        }
                        var buffer = GhosttyCodepointBuffer(ptr: cluster, cap: 32, len: 0)
                        if cellsLoaded, ghostty_render_state_row_cells_select(cells, UInt16(x)) == GHOSTTY_SUCCESS {
                            let r = ghostty_render_state_row_cells_get(cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &buffer)
                            if r == GHOSTTY_SUCCESS || r == GHOSTTY_OUT_OF_SPACE {
                                let n = min(buffer.len, 32)
                                glyph = n > 1
                                    ? atlas.glyph(cluster: UnsafeBufferPointer(start: cluster, count: n), style: face, cells: isWide ? 2 : 1)
                                    : atlas.glyph(cp, style: face, cells: isWide ? 2 : 1)
                            }
                        }
                    } else if cp < 0x80 {
                        glyph = atlas.asciiGlyph(cp, style: face)
                    } else if sameAsLast && haveGlyph {
                        glyph = lastGlyph
                    } else {
                        var span = isWide ? 2 : 1
                        if cp == 0x10eeee {
                            // Kitty image placeholder. We don't draw images.
                            x += 1
                            previousWasIcon = false
                            continue
                        }
                        if GhosttyGlyphAtlas.isPrivateUse(cp) && !GhosttySprites.isSprite(cp) {
                            // Like Ghostty's constraint width: an icon may spill into a blank cell after it.
                            isIcon = true
                            if !isWide && !previousWasIcon && x + 1 < count {
                                var next: UInt32 = 0
                                ghostty_cell_get(raws[x + 1], GHOSTTY_CELL_DATA_CODEPOINT, &next)
                                if next == 0 || next == 0x20 { span = 2 }
                            }
                        }
                        glyph = atlas.glyph(cp, style: face, cells: span)
                        if !isIcon {
                            lastGlyph = glyph
                            haveGlyph = true
                        }
                    }
                    if glyph.kind != GhosttyGlyph.empty {
                        row.glyphs.append(GhosttyGlyphInstance(
                            x: Int16(clamping: x * cellW + Int(glyph.ox)), y: glyph.oy, w: glyph.w, h: glyph.h, u: glyph.u, v: glyph.v,
                            color: fg, col: UInt16(x), row: rowIndex, kind: UInt16(glyph.kind)))
                    }
                }
                if flags & (Self.flagStrikethrough | Self.flagOverline) != 0 {
                    let width = UInt16(clamping: cellW * (isWide ? 2 : 1))
                    if flags & Self.flagStrikethrough != 0 {
                        row.overlays.append(GhosttyRectInstance(x: Int16(clamping: x * cellW), y: Int16(clamping: m.strikeTop), w: width,
                                                                h: UInt16(clamping: m.strikeThickness), color: fg, row: rowIndex))
                    }
                    if flags & Self.flagOverline != 0 {
                        row.overlays.append(GhosttyRectInstance(x: Int16(clamping: x * cellW), y: 0, w: width,
                                                                h: UInt16(clamping: m.underlineThickness), color: fg, row: rowIndex))
                    }
                }
            }
            previousWasIcon = isIcon
            x += 1
        }
        flushBackground(count)
        flushUnderline(count)

        if selStart >= 0 && selEnd >= selStart {
            let end = min(count, selEnd + 1)
            row.backgrounds.append(GhosttyRectInstance(
                x: Int16(clamping: selStart * cellW), y: 0, w: UInt16(clamping: (end - selStart) * cellW),
                h: UInt16(clamping: cellH), color: selectionColor, row: rowIndex))
        }
    }
}

/// The cursor as the renderer draws it.
struct GhosttyCursorState: Equatable {
    var visible = false
    var x = 0
    var y = 0
    var wide = false
    /// `GHOSTTY_CURSOR_STYLE_*` raw value.
    var style: UInt32 = 1
    var blinking = false
    /// r, g, b, a bytes.
    var color: UInt32 = 0xffff_ffff
}

/// Keeps built rows for one pane and rebuilds only what the render state says changed.
/// CPU only, so tests can drive it without Metal.
final class GhosttyFrameBuilder {
    let builder: GhosttyRowBuilder
    private(set) var rows: [GhosttyRow] = []
    private(set) var cols = 0
    private(set) var rowCount = 0
    private(set) var cursor = GhosttyCursorState()
    /// Rows rebuilt by the last `update` (for tests and tuning).
    private(set) var rowsBuilt = 0
    private(set) var rowsReused = 0
    /// Pixels the grid is drawn shifted up: the sub-row scroll offset plus the rubber band.
    private(set) var scrollOffset = 0
    /// Rows captured below the viewport by the last update (0 or 1).
    private(set) var overscanBelow = 0
    /// Off only to measure what row reuse saves on a scroll step.
    var reusesRowsOnScroll = true

    private var spare: [GhosttyRow] = []
    /// The previous frame's rows while a full frame is rebuilt. Kept to avoid allocating.
    private var previous: [GhosttyRow?] = []
    private var seenStateGeneration = -1
    private var seenAtlasGeneration = -1
    private var seenAtlas: ObjectIdentifier?
    private var needsFull = true

    init(atlas: GhosttyGlyphAtlas) {
        builder = GhosttyRowBuilder(atlas: atlas)
    }

    var atlas: GhosttyGlyphAtlas {
        get { builder.atlas }
        set { builder.atlas = newValue }
    }

    var background: UInt32 { builder.background }
    var foreground: UInt32 { builder.foreground }

    /// Forces every row to be rebuilt on the next update (theme or font changed).
    func invalidate() { needsFull = true }

    /// Updates the render state from the terminal and rebuilds dirty rows.
    /// Returns true if anything that is drawn changed.
    func update(core: GhosttyCore, now: CFTimeInterval = CACurrentMediaTime()) -> Bool {
        guard let state = core.lockFrame(now: now) else { return false }
        defer { core.unlockFrame() }
        guard let iterator = core.rowIterator, let cells = core.rowCells else { return false }
        rowsBuilt = 0
        rowsReused = 0

        var full = needsFull
        needsFull = false
        if core.stateGeneration != seenStateGeneration {
            seenStateGeneration = core.stateGeneration
            full = true
        }
        if seenAtlas != ObjectIdentifier(atlas) || seenAtlasGeneration != atlas.generation { full = true }
        if builder.loadColors(state) { full = true }

        var dirty = GHOSTTY_RENDER_STATE_DIRTY_FALSE
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_DIRTY, &dirty)
        var c: UInt16 = 0, r: UInt16 = 0
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLS, &c)
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROWS, &r)
        if Int(c) != cols || Int(r) != rowCount { full = true }
        cols = Int(c)
        rowCount = Int(r)

        var changed = full || dirty != GHOSTTY_RENDER_STATE_DIRTY_FALSE
        if changed {
            // Row identity: on a full redraw, a row whose id we already built and whose dirty flag
            // is clear can be reused as is. Not when we forced the rebuild ourselves.
            let reuse = !full && dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL
            // A scroll step marks every row dirty. Then a row with a known id is reused if its
            // cells still match what it was built from.
            let scrolled = reusesRowsOnScroll && core.scroll.movedViewport
            var attempts = 0
            repeat {
                attempts += 1
                seenAtlas = ObjectIdentifier(atlas)
                seenAtlasGeneration = atlas.generation
                rebuild(state, iterator: iterator, cells: cells, everything: full || dirty == GHOSTTY_RENDER_STATE_DIRTY_FULL,
                        reuse: reuse && attempts == 1, verifyDirty: scrolled)
                // The atlas filled up and was wiped while we built: earlier rows point at stale slots.
                full = true
            } while seenAtlasGeneration != atlas.generation && attempts < 3
            ghostty_render_state_clean(state)
        }

        // Upstream: don't shift the grid toward a side where nothing was captured.
        var captured = GhosttyRenderStateOverscan()
        ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_OVERSCAN, &captured)
        overscanBelow = Int(captured.below)
        if captured.below == 0 { core.scroll.clearRenderFraction() }
        let offset = core.scroll.renderFraction + core.scroll.renderBounce
        if offset != scrollOffset {
            scrollOffset = offset
            changed = true
        }

        var info = GhosttyRenderStateCursor()
        info.size = MemoryLayout<GhosttyRenderStateCursor>.size
        var next = GhosttyCursorState()
        if ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &info) == GHOSTTY_SUCCESS,
           info.visible, info.viewport_has_value {
            next.visible = true
            next.y = Int(info.viewport_y)
            next.x = Int(info.viewport_x)
            next.wide = info.wide_tail
            if info.wide_tail {
                next.x = max(0, next.x - 1)
            } else if next.y < rows.count, rows[next.y].wideColumns.contains(UInt16(next.x)) {
                next.wide = true
            }
            next.style = UInt32(info.visual_style.rawValue)
            next.blinking = info.blinking
            // An explicit cursor color (the theme's default or OSC 12), else the foreground.
            var color = GhosttyColorRgb()
            next.color = ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_COLOR_CURSOR, &color) == GHOSTTY_SUCCESS
                ? GhosttyRowBuilder.pack(color) : builder.foreground
        }
        if next != cursor {
            cursor = next
            changed = true
        }
        return changed
    }

    private func rebuild(_ state: GhosttyRenderState, iterator: GhosttyRenderStateRowIterator, cells: GhosttyRenderStateRowCells,
                         everything: Bool, reuse: Bool, verifyDirty: Bool) {
        var iterator = Optional(iterator)
        guard ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator) == GHOSTTY_SUCCESS,
              let iterator else { return }
        if everything {
            previous.removeAll(keepingCapacity: true)
            var i = 0
            while i < rows.count {
                previous.append(rows[i])
                i += 1
            }
            rows.removeAll(keepingCapacity: true)
        }
        // Rows come top to bottom (viewport rows, then the overscan row below), so the index is
        // the viewport row.
        var y = 0
        // Where the last reused row sat. After a scroll the next one sits right after it.
        var hint = 0
        while ghostty_render_state_row_iterator_next(iterator) {
            var rowDirty = true
            ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY, &rowDirty)
            if everything {
                var id = GhosttyRenderStateRowId()
                ghostty_render_state_row_get(iterator, GHOSTTY_RENDER_STATE_ROW_DATA_ID, &id)
                let key = (id.bits.0, id.bits.1)
                var row: GhosttyRow?
                if reuse, !rowDirty || verifyDirty, key != (0, 0) {
                    let n = previous.count
                    var k = 0
                    while k < n {
                        let i = hint + k < n ? hint + k : hint + k - n
                        if let candidate = previous[i], candidate.id == key {
                            if !rowDirty || builder.matches(candidate, iterator: iterator) {
                                row = candidate
                                previous[i] = nil
                                hint = i + 1 < n ? i + 1 : 0
                            }
                            break
                        }
                        k += 1
                    }
                }
                if let row {
                    row.restamp(y)
                    rowsReused += 1
                    rows.append(row)
                } else {
                    let fresh = spare.popLast() ?? GhosttyRow()
                    builder.build(fresh, y: y, iterator: iterator, cells: cells)
                    fresh.id = key
                    rowsBuilt += 1
                    rows.append(fresh)
                }
            } else if rowDirty, y < rows.count {
                builder.build(rows[y], y: y, iterator: iterator, cells: cells)
                rowsBuilt += 1
            }
            y += 1
        }
        if everything {
            var i = 0
            while i < previous.count {
                if let row = previous[i], spare.count < 256 { spare.append(row) }
                i += 1
            }
            previous.removeAll(keepingCapacity: true)
        }
    }
}
