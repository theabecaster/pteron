import Foundation
import GhosttyVt
import RexKit

/// The predictor's view of a libghostty terminal: the active area, as parsed so far.
///
/// Made and used on the feed queue with the terminal lock held, for one predictor call: the
/// scalar facts are read once when it is made (a few `ghostty_terminal_get`s), cells only when
/// the predictor asks, at most a row's worth per call. A call checks, judges and draws from
/// the same cells of one row, so the row asked for last is kept: each cell is read from the
/// terminal once per call.
struct GhosttyEchoGrid: EchoGrid {
    private let t: GhosttyTerminal
    private final class Row {
        var y = -1
        var cells: [EchoCell?] = []
        var reads = 0
    }
    private let kept = Row()
    /// Cells read from the terminal so far (the probe's count).
    var cellReads: Int { kept.reads }
    let cols: Int
    let rows: Int
    let cursorX: Int
    let cursorY: Int
    let pendingWrap: Bool
    let screenAllows: Bool
    let scrollbackRows: Int
    let marks: EchoPromptMarks
    let cursorAtPrompt: Bool

    /// A value no typed byte can equal: a wide character, a cluster, or a cell that couldn't
    /// be read.
    static let foreign: UInt32 = 0xFFFF_FFFF

    init(_ t: GhosttyTerminal, marks: EchoPromptMarks) {
        self.t = t
        self.marks = marks
        var c: UInt16 = 0, r: UInt16 = 0, x: UInt16 = 0, y: UInt16 = 0
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLS, &c)
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ROWS, &r)
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
        cols = Int(c)
        rows = Int(r)
        cursorX = Int(x)
        cursorY = Int(y)
        var wrap = false
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP, &wrap)
        pendingWrap = wrap
        var scrollback = 0
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &scrollback)
        scrollbackRows = scrollback
        var atPrompt = false
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_AT_PROMPT, &atPrompt)
        cursorAtPrompt = atPrompt
        screenAllows = Self.screenAllows(t)
    }

    /// Primary screen, cursor visible, insert mode off, wraparound on, no Kitty keyboard flags.
    private static func screenAllows(_ t: GhosttyTerminal) -> Bool {
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        guard screen == GHOSTTY_TERMINAL_SCREEN_PRIMARY else { return false }
        var visible = false
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &visible)
        guard visible else { return false }
        var kitty: UInt8 = 0
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &kitty)
        guard kitty == 0 else { return false }
        func mode(_ n: UInt16, ansi: Bool) -> Bool {
            var m = GhosttyTerminalModeConfig(mode: ghostty_mode_new(n, ansi), value: false)
            return ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_MODE, &m) == GHOSTTY_SUCCESS && m.value
        }
        return !mode(4, ansi: true) && mode(7, ansi: false)
    }

    func cell(_ x: Int, _ y: Int) -> EchoCell {
        guard x >= 0, x < cols, y >= 0, y < rows else { return .blank }
        if kept.y != y {
            kept.y = y
            kept.cells = [EchoCell?](repeating: nil, count: cols)
        }
        if let have = kept.cells[x] { return have }
        let read = readCell(x, y)
        kept.reads += 1
        kept.cells[x] = read
        return read
    }

    private func readCell(_ x: Int, _ y: Int) -> EchoCell {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_ACTIVE
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(x), y: UInt32(y))
        var ref = GhosttyGridRef()
        var raw: GhosttyCell = 0
        guard ghostty_terminal_grid_ref(t, point, &ref) == GHOSTTY_SUCCESS,
              ghostty_grid_ref_cell(&ref, &raw) == GHOSTTY_SUCCESS else { return EchoCell(scalar: Self.foreign) }
        var out = EchoCell()
        var tag = GHOSTTY_CELL_CONTENT_CODEPOINT
        ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CONTENT_TAG, &tag)
        var wide = GHOSTTY_CELL_WIDE_NARROW
        ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
        switch tag {
        case GHOSTTY_CELL_CONTENT_CODEPOINT:
            var cp: UInt32 = 0
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CODEPOINT, &cp)
            out.scalar = wide == GHOSTTY_CELL_WIDE_NARROW ? cp : Self.foreign
        case GHOSTTY_CELL_CONTENT_BG_COLOR_PALETTE:
            var index: GhosttyColorPaletteIndex = 0
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_PALETTE, &index)
            out.bg = .palette(UInt8(index))
        case GHOSTTY_CELL_CONTENT_BG_COLOR_RGB:
            var rgb = GhosttyColorRgb()
            ghostty_cell_get(raw, GHOSTTY_CELL_DATA_COLOR_RGB, &rgb)
            out.bg = .rgb(UInt32(rgb.r) << 16 | UInt32(rgb.g) << 8 | UInt32(rgb.b))
        default:
            out.scalar = Self.foreign
        }
        var styled = false
        ghostty_cell_get(raw, GHOSTTY_CELL_DATA_HAS_STYLING, &styled)
        if styled {
            var style = GhosttyStyle()
            if ghostty_grid_ref_style(&ref, &style) == GHOSTTY_SUCCESS {
                out.fg = Self.color(style.fg_color)
                if case .default = out.bg { out.bg = Self.color(style.bg_color) }
                out.bold = style.flags & Self.bold != 0
            }
        }
        return out
    }

    /// `GHOSTTY_STYLE_FLAG_BOLD`, a cast macro Swift doesn't import.
    private static let bold: UInt16 = 1 << 0

    private static func color(_ c: GhosttyStyleColor) -> EchoColor {
        switch UInt32(c.tag) {
        case GHOSTTY_STYLE_COLOR_PALETTE.rawValue: return .palette(c.value.palette)
        case GHOSTTY_STYLE_COLOR_RGB.rawValue:
            let v = c.value.rgb
            return .rgb(UInt32(v.r) << 16 | UInt32(v.g) << 8 | UInt32(v.b))
        default: return .default
        }
    }
}
