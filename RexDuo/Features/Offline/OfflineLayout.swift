import CoreGraphics

/// Where the offline screen puts its parts, from the size of its safe area and the fold. Pure, so it
/// is tested.
///
/// - Across a crease with room on both sides (unfolded Duo): two pages. The illustration takes the
///   leading or top page, the card with the message and buttons the other, each centered in its page.
/// - A crease with room for the card on one side only (sidebar beside it, keyboard up): the whole card
///   on the page that holds it.
/// - No crease in the region (folded, half window, other iPhones): one card, centered.
///
/// Nothing is placed on the crease: each page stops `gutter` points short of it.
struct OfflineLayout: Equatable {
    enum Kind: Equatable {
        case single
        /// Two pages side by side (vertical crease) or stacked (horizontal crease).
        case sideBySide, stacked
    }

    var kind: Kind
    /// The region the card is centered in, in the screen's safe-area coordinates.
    var card: CGRect
    /// The region the illustration is centered in, for two pages.
    var art: CGRect?

    var isPaged: Bool { art != nil }

    /// Space kept clear on each side of the crease.
    static let gutter: CGFloat = 12
    /// The smallest page that holds the card (the folded card is 360 pt wide plus margins).
    static let cardWidth: CGFloat = 320
    static let cardHeight: CGFloat = 300
    /// The smallest page worth giving the illustration.
    static let artWidth: CGFloat = 240
    static let artHeight: CGFloat = 180

    /// `size`: the screen's safe area. `origin`: its top-leading corner in the root's coordinates,
    /// the ones `division` is in.
    static func decide(size: CGSize, origin: CGPoint, division: Division?) -> OfflineLayout {
        let all = CGRect(origin: .zero, size: size)
        let single = OfflineLayout(kind: .single, card: all, art: nil)
        guard let d = division else { return single }
        if d.isVertical {
            let lo = d.frame.minX - origin.x, hi = d.frame.maxX - origin.x
            guard lo > 0, hi < size.width else { return single }
            let first = CGRect(x: 0, y: 0, width: max(lo - gutter, 0), height: size.height)
            let second = CGRect(x: hi + gutter, y: 0, width: max(size.width - hi - gutter, 0), height: size.height)
            return paged(first, second, fitsArt: first.width >= artWidth, fits: { $0.width >= cardWidth },
                         kind: .sideBySide, fallback: single)
        }
        let lo = d.frame.minY - origin.y, hi = d.frame.maxY - origin.y
        guard lo > 0, hi < size.height else { return single }
        let first = CGRect(x: 0, y: 0, width: size.width, height: max(lo - gutter, 0))
        let second = CGRect(x: 0, y: hi + gutter, width: size.width, height: max(size.height - hi - gutter, 0))
        return paged(first, second, fitsArt: first.height >= artHeight, fits: { $0.height >= cardHeight },
                     kind: .stacked, fallback: single)
    }

    private static func paged(_ first: CGRect, _ second: CGRect, fitsArt: Bool, fits: (CGRect) -> Bool,
                              kind: Kind, fallback: OfflineLayout) -> OfflineLayout {
        if fitsArt, fits(second) { return OfflineLayout(kind: kind, card: second, art: first) }
        // Room for the card on one page only: the whole card there, the larger page if both hold it.
        let pages = [second, first].filter(fits)
        if let best = pages.max(by: { $0.width * $0.height < $1.width * $1.height }) {
            return OfflineLayout(kind: .single, card: best, art: nil)
        }
        return fallback
    }
}
