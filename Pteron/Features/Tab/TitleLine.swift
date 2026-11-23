import SwiftUI
import UIKit

/// Sidebar mode's title on one line, like the Mac's title bar: the tab's title, its status, then
/// the session's name in a quieter color, then the menu chevron. One line keeps the title bar
/// thin (`barHeight`). `fit` decides how the title and the session share the line; the status and
/// the chevron always keep their own width.
enum TitleLine {
    /// Between the title (or its status) and the session's name.
    static let gap: CGFloat = 7
    /// The session's name keeps at least this much, or leaves the line.
    static let sessionMin: CGFloat = 44
    /// The most of the line the session's name keeps while the title has to be cut.
    static let sessionShare: CGFloat = 0.35
    /// The title keeps at least this much (all of it, when it is shorter) before the session's
    /// name leaves the line for it.
    static let titleMin: CGFloat = 64
    /// The line's text stops growing where the strip's chips do, and the bar with it.
    static let typeLimit: DynamicTypeSize = StripStyle.chipTypeLimit

    // MARK: The bar's height

    /// The bar's glyphs (the sidebar toggle, the pane menu, Unzoom) at the bar's 17 pt: they fit
    /// this box, and don't grow with the text size.
    static let glyph: CGFloat = 22
    /// Above and below the tallest of the line and the glyphs.
    static let padding: CGFloat = 6
    /// The same in a short window (landscape iPhone), where every point is a row of text less.
    static let compactPadding: CGFloat = 4
    /// A short window's bar never passes this, whatever the text size: the line still fits.
    static let compactMax: CGFloat = 34

    /// The title bar's height: its content, the taller of the line (`lineHeight`) and the glyphs,
    /// with even padding above and below. It grows with the text size up to `typeLimit`, and in a
    /// short window stays at most `compactMax`. Whether the session's name is on the line or not
    /// changes nothing: one line, one height.
    static func barHeight(line: CGFloat, compact: Bool) -> CGFloat {
        let h = (max(line, glyph) + 2 * (compact ? compactPadding : padding)).rounded(.up)
        return compact ? min(h, compactMax) : h
    }

    /// The line's height at a text size, from the title's font (subheadline, the session's size
    /// too), capped at `typeLimit`. Read from the font's metrics, not from the drawn bar, so the
    /// bar's height never feeds back into its own layout.
    static func lineHeight(_ size: DynamicTypeSize) -> CGFloat {
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(min(size, typeLimit)))
        return UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).lineHeight.rounded(.up)
    }

    /// The title bar's height at a text size, in a short window or not.
    static func barHeight(_ size: DynamicTypeSize, compact: Bool) -> CGFloat {
        barHeight(line: lineHeight(size), compact: compact)
    }

    struct Widths: Equatable {
        var title: CGFloat
        /// Nil: the session's name has no room on the line.
        var session: CGFloat?
    }

    /// How wide the title and the session's name are, in `room` (the line less the status and the
    /// chevron), given the widths each asks for. Both fit: each gets its own. Otherwise the title
    /// comes first; the session's name keeps up to `sessionShare` of the line, and whatever the
    /// title leaves, and both truncate. Where that would cut the title below `titleMin`, the
    /// session's name leaves the line and the title takes it all.
    static func fit(room: CGFloat, title: CGFloat, session: CGFloat?) -> Widths {
        let room = max(room, 0)
        guard let session, session > 0 else { return Widths(title: min(title, room), session: nil) }
        if title + gap + session <= room { return Widths(title: title, session: session) }
        let left = room - gap
        let kept = min(session, max(sessionMin, left * sessionShare))
        let t = min(title, left - kept)
        if t < min(title, titleMin) { return Widths(title: min(title, room), session: nil) }
        return Widths(title: t, session: min(session, left - t))
    }
}

/// Lays out the title line's parts in a row, centered on the bar: each part tagged with its
/// `Role`. Parts with no width (a status that isn't there) take no spacing.
struct TitleLineLayout: Layout {
    enum Role { case title, status, session, trailing }
    struct RoleKey: LayoutValueKey { static let defaultValue = Role.trailing }

    /// Between the title, the status and the trailing parts.
    var spacing: CGFloat = 5

    private struct Plan {
        var widths: [CGFloat?]
        var total: CGFloat
    }

    private func plan(_ width: CGFloat?, _ subviews: Subviews) -> Plan {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }
        let roles = subviews.map { $0[RoleKey.self] }
        func sum(_ r: Role) -> CGFloat { zip(roles, ideal).filter { $0.0 == r }.reduce(0) { $0 + $1.1 } }
        let fixed = zip(roles, ideal).filter { ($0.0 == .status || $0.0 == .trailing) && $0.1 > 0 }
        let fixedWidth = fixed.reduce(0) { $0 + $1.1 + spacing }
        let titleIdeal = sum(.title), sessionIdeal = sum(.session)
        let w = TitleLine.fit(room: (width ?? .infinity) - fixedWidth, title: titleIdeal,
                              session: sessionIdeal > 0 ? sessionIdeal : nil)
        var widths: [CGFloat?] = []
        for (r, i) in zip(roles, ideal) {
            switch r {
            case .title: widths.append(titleIdeal > 0 ? w.title * i / titleIdeal : 0)
            case .session: widths.append(w.session.map { sessionIdeal > 0 ? $0 * i / sessionIdeal : 0 })
            case .status, .trailing: widths.append(i)
            }
        }
        let total = w.title + fixedWidth + (w.session.map { $0 + TitleLine.gap } ?? 0)
        return Plan(widths: widths, total: total)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let p = plan(proposal.width, subviews)
        let height = zip(subviews, p.widths).reduce(CGFloat(0)) { h, s in
            guard let w = s.1 else { return h }
            return max(h, s.0.sizeThatFits(ProposedViewSize(width: w, height: proposal.height)).height)
        }
        return CGSize(width: p.total, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let p = plan(bounds.width, subviews)
        var x = bounds.minX
        var first = true
        for (v, w) in zip(subviews, p.widths) {
            guard let w, w > 0 else {
                // No room or nothing to show: past the line's end, where the title bar clips it,
                // so a cut name never leaves a lone ellipsis.
                v.place(at: CGPoint(x: bounds.maxX + 10_000, y: bounds.midY), anchor: .leading,
                        proposal: ProposedViewSize(width: 0, height: 0))
                continue
            }
            if !first { x += v[RoleKey.self] == .session ? TitleLine.gap : spacing }
            first = false
            v.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading,
                    proposal: ProposedViewSize(width: w, height: bounds.height))
            x += w
        }
    }
}
