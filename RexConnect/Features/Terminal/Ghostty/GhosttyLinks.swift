import Foundation
import GhosttyVt

// Links under a tap.
//
// - An OSC 8 hyperlink is the terminal's own data: `ghostty_grid_ref_hyperlink_uri` on the cell.
// - A web address written as plain text is found in the logical line the cell is on. The rows of
//   that line come from the library's wrap flags (`GHOSTTY_ROW_DATA_WRAP`,
//   `GHOSTTY_ROW_DATA_WRAP_CONTINUATION`), so an address that soft-wraps is one address.
//
// Both reads happen in one hold of the terminal lock, on at most the rows of one logical line
// that are in view.

/// A link found under a tap.
struct GhosttyTappedLink: Equatable {
    var url: String
    /// True for an OSC 8 hyperlink, false for an address found in the text.
    var explicit: Bool
}

enum GhosttyLinkText {
    private static let schemes: [[Unicode.Scalar]] = [Array("https://".unicodeScalars), Array("http://".unicodeScalars)]

    /// The web address (http or https) that covers position `index` of `line`, or nil.
    ///
    /// An address runs to the first space, control character, quote, angle bracket or
    /// box-drawing character. Punctuation that ends a sentence is left off its end, and so is a
    /// closing bracket that has no opening one inside the address.
    static func url(in line: [Unicode.Scalar], at index: Int) -> String? {
        guard index >= 0, index < line.count else { return nil }
        var i = 0
        while i < line.count {
            guard let scheme = schemes.first(where: { starts(line, at: i, with: $0) }),
                  i == 0 || !isSchemeCharacter(line[i - 1]) else {
                i += 1
                continue
            }
            var end = i + scheme.count
            while end < line.count, !endsAddress(line[end]) { end += 1 }
            let trimmed = trim(line, from: i, to: end)
            if trimmed > i + scheme.count, index >= i, index < trimmed {
                var out = String.UnicodeScalarView()
                out.append(contentsOf: line[i..<trimmed])
                return String(out)
            }
            if index < end { return nil }
            i = end
        }
        return nil
    }

    private static func starts(_ line: [Unicode.Scalar], at i: Int, with prefix: [Unicode.Scalar]) -> Bool {
        guard i + prefix.count <= line.count else { return false }
        for (k, want) in prefix.enumerated() {
            let have = line[i + k].value
            // ASCII letters compare without case.
            let lower = have >= 0x41 && have <= 0x5a ? have + 0x20 : have
            if lower != want.value { return false }
        }
        return true
    }

    private static func isSchemeCharacter(_ s: Unicode.Scalar) -> Bool {
        s.properties.isAlphabetic || (s.value >= 0x30 && s.value <= 0x39) || s == "+" || s == "-" || s == "."
    }

    private static func endsAddress(_ s: Unicode.Scalar) -> Bool {
        if s.value <= 0x20 || s.value == 0x7f { return true }
        if s.properties.isWhitespace { return true }
        // Frames drawn around text (boxes, block elements).
        if s.value >= 0x2500 && s.value <= 0x259f { return true }
        return "\"'`<>".unicodeScalars.contains(s)
    }

    private static func trim(_ line: [Unicode.Scalar], from start: Int, to end: Int) -> Int {
        var end = end
        while end > start {
            let last = line[end - 1]
            if ".,;:!?".unicodeScalars.contains(last) {
                end -= 1
                continue
            }
            let open: Unicode.Scalar
            switch last {
            case ")": open = "("
            case "]": open = "["
            case "}": open = "{"
            default: return end
            }
            let inside = line[start..<end]
            if inside.filter({ $0 == last }).count > inside.filter({ $0 == open }).count {
                end -= 1
            } else {
                return end
            }
        }
        return end
    }
}

extension GhosttyCore {
    /// Longer than any address a program means to be opened.
    static let hyperlinkMaxBytes = 16 * 1024
    /// Cells of one logical line read to find a plain address.
    static let linkLineMaxCells = 8192

    /// The link on viewport cell (`col`, `row`): its OSC 8 hyperlink, else a web address in the
    /// text there. Takes the terminal lock once.
    func link(atViewportCol col: Int, row: Int) -> GhosttyTappedLink? {
        withTerminal { t in Self.hyperlink(t, col: col, row: row) ?? Self.plainLink(t, col: col, row: row) } ?? nil
    }

    private static func viewportRef(_ t: GhosttyTerminal, x: Int, y: Int) -> GhosttyGridRef? {
        guard x >= 0, y >= 0 else { return nil }
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: x), y: UInt32(clamping: y))
        var ref = GhosttyGridRef()
        return ghostty_terminal_grid_ref(t, point, &ref) == GHOSTTY_SUCCESS ? ref : nil
    }

    private static func wide(_ ref: inout GhosttyGridRef) -> GhosttyCellWide {
        var cell: GhosttyCell = 0
        var wide = GHOSTTY_CELL_WIDE_NARROW
        if ghostty_grid_ref_cell(&ref, &cell) == GHOSTTY_SUCCESS { ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide) }
        return wide
    }

    /// The OSC 8 hyperlink of a viewport cell. Call with the terminal lock held.
    static func hyperlink(_ t: GhosttyTerminal, col: Int, row: Int) -> GhosttyTappedLink? {
        guard var ref = viewportRef(t, x: col, y: row) else { return nil }
        if let uri = uri(&ref) { return GhosttyTappedLink(url: uri, explicit: true) }
        // The right half of a wide character is the character on its left.
        if wide(&ref) == GHOSTTY_CELL_WIDE_SPACER_TAIL, var left = viewportRef(t, x: col - 1, y: row), let uri = uri(&left) {
            return GhosttyTappedLink(url: uri, explicit: true)
        }
        return nil
    }

    private static func uri(_ ref: inout GhosttyGridRef) -> String? {
        // Upstream: ask for the size first; a cell with no hyperlink answers success with 0.
        var length = 0
        guard ghostty_grid_ref_hyperlink_uri(&ref, nil, 0, &length) == GHOSTTY_OUT_OF_SPACE,
              length > 0, length <= hyperlinkMaxBytes else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        var written = 0
        guard ghostty_grid_ref_hyperlink_uri(&ref, &bytes, bytes.count, &written) == GHOSTTY_SUCCESS, written > 0 else { return nil }
        return String(validating: bytes.prefix(written), as: UTF8.self)
    }

    /// A web address in the text of the logical line a viewport cell is on. Call with the
    /// terminal lock held.
    static func plainLink(_ t: GhosttyTerminal, col: Int, row: Int) -> GhosttyTappedLink? {
        var c: UInt16 = 0, r: UInt16 = 0
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLS, &c)
        ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ROWS, &r)
        let cols = Int(c), rows = Int(r)
        guard col >= 0, col < cols, row >= 0, row < rows, var tapped = viewportRef(t, x: col, y: row) else { return nil }
        var col = col
        if wide(&tapped) == GHOSTTY_CELL_WIDE_SPACER_TAIL, col > 0 { col -= 1 }
        // Nothing to find on a blank cell: don't read the line.
        guard let cell = viewportRef(t, x: col, y: row), scalar(cell) != " " else { return nil }

        func flags(_ y: Int) -> (wrap: Bool, continuation: Bool) {
            var wrap = false, continuation = false
            guard var ref = viewportRef(t, x: 0, y: y) else { return (false, false) }
            var raw: GhosttyVt.GhosttyRow = 0
            if ghostty_grid_ref_row(&ref, &raw) == GHOSTTY_SUCCESS {
                ghostty_row_get(raw, GHOSTTY_ROW_DATA_WRAP, &wrap)
                ghostty_row_get(raw, GHOSTTY_ROW_DATA_WRAP_CONTINUATION, &continuation)
            }
            return (wrap, continuation)
        }

        // The rows of the logical line that are in view, within the budget.
        let budget = max(1, linkLineMaxCells / max(1, cols))
        var first = row, last = row
        while first > 0, row - first < budget, flags(first).continuation { first -= 1 }
        while last < rows - 1, last - first < budget, flags(last).wrap { last += 1 }

        var line: [Unicode.Scalar] = []
        line.reserveCapacity((last - first + 1) * cols)
        var index = -1
        for y in first...last {
            for x in 0..<cols {
                guard var ref = viewportRef(t, x: x, y: y) else { break }
                let w = wide(&ref)
                // Fillers are not text: the right half of a wide character, and the gap left when
                // one didn't fit at the end of a row.
                if w == GHOSTTY_CELL_WIDE_SPACER_TAIL || w == GHOSTTY_CELL_WIDE_SPACER_HEAD { continue }
                if y == row, x == col { index = line.count }
                line.append(scalar(ref))
            }
        }
        guard index >= 0, let url = GhosttyLinkText.url(in: line, at: index) else { return nil }
        return GhosttyTappedLink(url: url, explicit: false)
    }

    /// The first codepoint of a cell, or a space for an empty one.
    private static func scalar(_ ref: GhosttyGridRef) -> Unicode.Scalar {
        var ref = ref
        var buffer: (UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0)
        var written = 0
        let result = withUnsafeMutablePointer(to: &buffer) {
            $0.withMemoryRebound(to: UInt32.self, capacity: 4) { ghostty_grid_ref_graphemes(&ref, $0, 4, &written) }
        }
        guard result == GHOSTTY_SUCCESS, written > 0, let s = Unicode.Scalar(buffer.0), s.value != 0 else { return " " }
        return s
    }
}
