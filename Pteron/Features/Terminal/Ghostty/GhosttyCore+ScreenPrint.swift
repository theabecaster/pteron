import Foundation
import GhosttyVt

/// What a key typed at a screen depends on: the active area's text and styles, the cursor, and
/// the terminal modes and keyboard modes that shape the bytes a key becomes. Two equal prints are
/// the same screen to type at (docs/terminal.md, The catch-up fence).
///
/// It is the terminal's own VT rendering of the active area with the cursor, the modes and the
/// keyboard modes, kept as a hash: a few kilobytes formatted twice per fence that holds keys,
/// never per byte.
struct GhosttyScreenPrint: Equatable, Sendable {
    let cols: Int
    let rows: Int
    let length: Int
    let digest: Int

    /// The print of the terminal as it is. The caller holds `termLock`.
    static func of(_ t: GhosttyTerminal) -> GhosttyScreenPrint? {
        var c: UInt16 = 0, r: UInt16 = 0
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLS, &c)
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ROWS, &r)
        guard c > 0, r > 0 else { return nil }
        func point(_ x: UInt16, _ y: UInt16) -> GhosttyPoint {
            var p = GhosttyPoint()
            p.tag = GHOSTTY_POINT_TAG_ACTIVE
            p.value.coordinate = GhosttyPointCoordinate(x: x, y: UInt32(y))
            return p
        }
        var start = GhosttyGridRef(), end = GhosttyGridRef()
        guard ghostty_terminal_grid_ref(t, point(0, 0), &start) == GHOSTTY_SUCCESS,
              ghostty_terminal_grid_ref(t, point(c - 1, r - 1), &end) == GHOSTTY_SUCCESS else { return nil }
        var selection = GhosttySelection(start: start, end: end, rectangle: false)
        // The formatter borrows the terminal, and a restore replaces it: it lives for this call.
        var formatter: GhosttyFormatter?
        guard ghostty_formatter_terminal_new(nil, &formatter, t) == GHOSTTY_SUCCESS, let formatter else { return nil }
        defer { ghostty_formatter_free(formatter) }
        var format = GHOSTTY_FORMATTER_FORMAT_VT
        var trim = false
        var extras = GhosttyFormatterExtras(GHOSTTY_FORMATTER_EXTRA_MODES | GHOSTTY_FORMATTER_EXTRA_KEYBOARD
            | GHOSTTY_FORMATTER_EXTRA_KITTY_KEYBOARD | GHOSTTY_FORMATTER_EXTRA_CURSOR | GHOSTTY_FORMATTER_EXTRA_STYLE)
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &format)
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &trim)
        ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EXTRAS, &extras)
        guard ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &selection) == GHOSTTY_SUCCESS else { return nil }
        var bytes: UnsafeMutablePointer<UInt8>?
        var count = 0
        guard ghostty_formatter_format_alloc(formatter, nil, &bytes, &count) == GHOSTTY_SUCCESS else { return nil }
        var hasher = Hasher()
        if let bytes {
            hasher.combine(bytes: UnsafeRawBufferPointer(start: bytes, count: count))
            ghostty_free(nil, bytes, count)
        }
        // Which screen is a mode the formatter may leave out: said here.
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        hasher.combine(screen.rawValue)
        return GhosttyScreenPrint(cols: Int(c), rows: Int(r), length: count, digest: hasher.finalize())
    }
}

extension GhosttyCore {
    /// The print of the terminal as parsed so far. For tests and the fence's question.
    var screenPrint: GhosttyScreenPrint? { withTerminal { GhosttyScreenPrint.of($0) } ?? nil }
}
