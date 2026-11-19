import CoreGraphics

/// How the agent board lays its tiles out for a number of agents and a window size. The board
/// never scrolls: what doesn't fit is counted in a "+K more" tile. Pure, so it is tested.
///
/// - No agent: the quiet board (a clock).
/// - 1: one hero tile.
/// - 2: side by side in a wide window, stacked in a tall one.
/// - 3: three full rows in a tall window.
/// - Otherwise two columns; with an odd count the first, most urgent tile takes a full row.
/// - More than 8, or more than the window's height holds: one tile fewer, and "+K more".
/// - Under 300 pt of width (a narrow Split View): one column.
struct BoardLayout: Equatable {
    enum Style: Equatable { case quiet, hero, regular, compact }

    var style: Style
    var rows: Int
    var cols: Int
    /// Agent tiles shown.
    var shown: Int
    /// Agents behind the "+K more" tile, which takes the last cell. 0: no such tile.
    var more: Int
    var messageLines: Int
    var showsPlace: Bool
    var headerHeight: CGFloat
    var footerHeight: CGFloat
    /// The size of one cell (a tile on a full row is wider).
    var cell: CGSize

    static let pad: CGFloat = 16
    static let gap: CGFloat = 10
    static let most = 8
    /// The shortest tile that still reads: a ring, a name and a state.
    static let minCell: CGFloat = 60

    /// Tiles and the "+K more" tile together.
    var cells: Int { shown + (more > 0 ? 1 : 0) }
    /// With an odd number of cells in two columns, the first one takes its whole row.
    var leadsWide: Bool { cols == 2 && cells % 2 == 1 && cells > 1 }

    static let footer: CGFloat = 22

    /// The header's height: the headline and the line under it, which grow with the text size
    /// (`headScale`, 1 at the standard size, up to 1.5).
    static func header(_ size: CGSize, headScale: CGFloat = 1) -> CGFloat {
        ((size.height < 480 ? 68 : 84) * headScale).rounded()
    }

    /// The footer's height: the "+N idle" line, which grows with the tiles' text.
    static func footer(typeScale: CGFloat) -> CGFloat { (footer * typeScale).rounded() }

    /// The room for tiles: the board inside its padding, under the header and above the footer.
    static func area(_ size: CGSize, hasFooter: Bool, typeScale: CGFloat = 1, headScale: CGFloat = 1) -> CGRect {
        let top = pad + header(size, headScale: headScale)
        let bottom = pad + (hasFooter ? footer(typeScale: typeScale) : 0)
        return CGRect(x: pad, y: top, width: max(0, size.width - 2 * pad), height: max(0, size.height - top - bottom))
    }

    /// - count: agents that aren't idle.
    /// - size: the board inside the safe area.
    /// - typeScale: 1 at the standard text size; larger text makes tiles taller, so fewer fit.
    /// - headScale: the same for the header, which grows further and takes its room from the tiles.
    static func decide(count: Int, size: CGSize, hasFooter: Bool, typeScale: CGFloat = 1, headScale: CGFloat = 1) -> BoardLayout {
        let head = header(size, headScale: headScale), foot: CGFloat = hasFooter ? footer(typeScale: typeScale) : 0
        guard count > 0 else {
            return BoardLayout(style: .quiet, rows: 0, cols: 0, shown: 0, more: 0, messageLines: 0, showsPlace: false,
                               headerHeight: head, footerHeight: foot, cell: .zero)
        }
        let area = area(size, hasFooter: hasFooter, typeScale: typeScale, headScale: headScale)
        let narrow = area.width < 300
        let cols: Int
        switch count {
        case 1: cols = 1
        case 2: cols = !narrow && area.width / max(area.height, 1) >= 1.2 ? 2 : 1
        // Three read best as three full rows, where the window is tall enough for them.
        case 3: cols = narrow || (area.height - 2 * gap) / 3 >= 150 * typeScale ? 1 : 2
        default: cols = narrow ? 1 : 2
        }
        let fit = max(1, Int((area.height + gap) / (minCell * typeScale + gap)))
        // A leading full-row tile uses a row for one cell.
        func rows(_ cells: Int) -> Int { cols == 2 ? (cells + 1) / 2 : cells }
        var cells = min(count, most)
        while cells > 1, rows(cells) > fit { cells -= 1 }
        let more = count > cells ? count - (cells - 1) : 0
        let shown = more > 0 ? cells - 1 : cells
        let r = rows(cells)
        let cell = CGSize(width: (area.width - gap * CGFloat(cols - 1)) / CGFloat(cols),
                          height: (area.height - gap * CGFloat(r - 1)) / CGFloat(r))
        let style: Style
        if count == 1 {
            style = .hero
        } else if cells <= 4, cell.height >= 150 * typeScale, cell.width >= 160 {
            style = .regular
        } else {
            style = .compact
        }
        var lines = 2, place = true
        if style == .compact {
            let h = cell.height / typeScale
            if h >= 150 { lines = 3 } else if h >= 112 { lines = 2 } else if h >= 92 { lines = 1 } else if h >= 76 { lines = 1; place = false } else { lines = 0; place = false }
        }
        return BoardLayout(style: style, rows: r, cols: cols, shown: shown, more: more, messageLines: lines, showsPlace: place,
                           headerHeight: head, footerHeight: foot, cell: cell)
    }

    /// Each cell's frame inside `area`, in order.
    func frames(in area: CGRect) -> [CGRect] {
        guard cells > 0, cols > 0 else { return [] }
        var out: [CGRect] = []
        var row = 0, col = 0
        for i in 0..<cells {
            let y = area.minY + CGFloat(row) * (cell.height + Self.gap)
            if i == 0, leadsWide {
                out.append(CGRect(x: area.minX, y: y, width: area.width, height: cell.height))
                row += 1
                continue
            }
            out.append(CGRect(x: area.minX + CGFloat(col) * (cell.width + Self.gap), y: y, width: cell.width, height: cell.height))
            col += 1
            if col == cols { col = 0; row += 1 }
        }
        return out
    }
}
