import SwiftUI

/// The fold of an unfolded iPhone Duo, from `reservedRegions(kind: .division)`, in the root view's
/// coordinates. `frame` includes Apple's tap margins. Flat, the region is inactive and has zero width
/// (or height); partly folded, it is active and wider.
struct Division: Equatable {
    var frame: CGRect
    var isActive: Bool

    /// A vertical crease splits the screen into a left and a right page (inner screen, landscape).
    var isVertical: Bool { frame.height > frame.width }
}

/// How the root lays out the sidebar and the tab. One model everywhere, like the Mac app: the tab
/// fills the window, and the sidebar sits beside it (wide) or slides over it as a drawer (narrow).
/// Picked from the window's width and the fold, never from orientation or the hinge (Apple: use
/// reserved regions for layout, the hinge only for effects).
struct Arrangement: Equatable {
    /// Wide enough for a sidebar beside a usable tab: the sidebar is inline, resizable and
    /// collapsible. Narrower (folded Duo, iPhone portrait, half the inner screen), it is a drawer.
    var inline: Bool
    /// A vertical crease's leading edge (unfolded Duo, landscape): a snap point for the sidebar's edge.
    var crease: CGFloat?
    /// Partly folded with a horizontal crease: the tab keeps its title bar and panes above it and the
    /// keyboard below.
    var tabletop: Tabletop?

    struct Tabletop: Equatable {
        /// Height above the crease.
        var top: CGFloat
        /// The crease's height.
        var gap: CGFloat
    }

    /// Narrowest window that fits the inline sidebar beside a tab.
    static let minInlineWidth: CGFloat = 600
    /// Shortest region worth drawing above a horizontal crease.
    static let minRegion: CGFloat = 200

    static func decide(size: CGSize, division: Division?) -> Arrangement {
        var a = Arrangement(inline: size.width >= minInlineWidth)
        guard let d = division else { return a }
        if d.isVertical {
            if d.frame.minX > 0, d.frame.minX < size.width { a.crease = d.frame.minX }
        } else if d.isActive, d.frame.minY >= minRegion {
            // The height shrinks while the keyboard is up, so only the top region is checked.
            a.tabletop = Tabletop(top: d.frame.minY, gap: d.frame.height)
        }
        return a
    }
}

/// The sidebar's width: limits, snap points and what a drag does. Pure, so it is tested.
enum SidebarWidth {
    /// The Mac app's default.
    static let standard: CGFloat = 260
    static let min: CGFloat = 200
    /// Let go narrower than this and the sidebar collapses (inline) or closes (drawer).
    static let collapse: CGFloat = 140
    /// A drag within this distance of a snap point rests on it.
    static let snapDistance: CGFloat = 14

    /// Inline, at most half the window; as a drawer, up to 85% of it.
    static func max(container: CGFloat, inline: Bool) -> CGFloat {
        Swift.max(min, (container * (inline ? 0.5 : 0.85)).rounded())
    }

    /// A stored width, fitted into this window.
    static func clamp(_ w: CGFloat, container: CGFloat, inline: Bool) -> CGFloat {
        Swift.min(Swift.max(w, min), max(container: container, inline: inline))
    }

    /// The default width, and inline the crease, where the sidebar fills the left page.
    static func snaps(container: CGFloat, inline: Bool, crease: CGFloat?) -> [CGFloat] {
        let hi = max(container: container, inline: inline)
        var s: [CGFloat] = [Swift.min(standard, hi)]
        if inline, let c = crease, c >= min, c <= hi, abs(c - s[0]) > snapDistance { s.append(c) }
        return s
    }

    /// The width shown while a drag is at `raw`: it rests on a snap point when near one, and stretches
    /// with resistance past either limit. `snapped` is the snap point it rests on.
    static func live(_ raw: CGFloat, container: CGFloat, inline: Bool, crease: CGFloat?) -> (width: CGFloat, snapped: CGFloat?) {
        let hi = max(container: container, inline: inline)
        if raw < min { return (min - rubber(min - raw), nil) }
        if raw > hi { return (hi + rubber(raw - hi), nil) }
        if let p = snaps(container: container, inline: inline, crease: crease).first(where: { abs($0 - raw) <= snapDistance }) {
            return (p, p)
        }
        return (raw, nil)
    }

    /// Where a drag that ended at `raw` leaves the sidebar. Nil collapses (or closes) it.
    static func release(_ raw: CGFloat, container: CGFloat, inline: Bool, crease: CGFloat?) -> CGFloat? {
        guard raw >= collapse else { return nil }
        let w = live(raw, container: container, inline: inline, crease: crease)
        return w.snapped ?? clamp(w.width, container: container, inline: inline)
    }

    /// One remembered width per posture: inline or drawer, at this window width.
    static func key(container: CGFloat, inline: Bool) -> String {
        "\(inline ? "inline" : "drawer")-\(Int(container.rounded()))"
    }

    private static func rubber(_ d: CGFloat) -> CGFloat { 24 * (1 - 1 / (d / 60 + 1)) }
}

/// The fold, for views that adapt to it (an even column count in grids). Nil without one.
extension EnvironmentValues {
    @Entry var division: Division? = nil
    /// Where the root's coordinates (the ones `division` is in) start, in global coordinates. A view
    /// subtracts it from its own global frame to place itself against the fold.
    @Entry var rootOrigin: CGPoint = .zero
    /// The edge of the system's vertical bar (iPhone Duo: the outer screen, and the inner screen in
    /// landscape). Nil where bars are horizontal. Toolbar items go there instead of the title bar.
    @Entry var verticalBarEdge: HorizontalEdge? = nil
}

#if DEBUG
/// `-simulateDuo unfolded|book|unfoldedPortrait|tabletop|folded|foldedLandscape|halfWindow|iPhone|
/// iPhoneLandscape|proMaxLandscape` (testing): lays the root out in that window size, with its size
/// classes and a fake fold, so one big simulator screen shows every layout.
/// A comma-separated list cycles through the postures every `-simulateDuoEvery` seconds (default 10),
/// to check what a fold or an unfold keeps.
struct DuoSimulation: Equatable {
    var name: String
    var size: CGSize
    var horizontal: UserInterfaceSizeClass
    var vertical: UserInterfaceSizeClass
    var division: Division?

    static func named(_ raw: String) -> DuoSimulation? {
        switch raw.trimmingCharacters(in: .whitespaces) {
        case "unfolded":
            return .init(name: "unfolded", size: CGSize(width: 951, height: 669), horizontal: .regular, vertical: .regular,
                         division: Division(frame: CGRect(x: 475.5, y: 0, width: 0, height: 669), isActive: false))
        case "book":
            return .init(name: "book", size: CGSize(width: 951, height: 669), horizontal: .regular, vertical: .regular,
                         division: Division(frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), isActive: true))
        case "unfoldedPortrait":
            return .init(name: "unfoldedPortrait", size: CGSize(width: 669, height: 951), horizontal: .regular, vertical: .regular,
                         division: Division(frame: CGRect(x: 0, y: 475.5, width: 669, height: 0), isActive: false))
        case "tabletop":
            return .init(name: "tabletop", size: CGSize(width: 669, height: 951), horizontal: .regular, vertical: .regular,
                         division: Division(frame: CGRect(x: 0, y: 455.5, width: 669, height: 40), isActive: true))
        case "folded":
            return .init(name: "folded", size: CGSize(width: 466, height: 678), horizontal: .compact, vertical: .regular,
                         division: nil)
        case "foldedLandscape":
            return .init(name: "foldedLandscape", size: CGSize(width: 678, height: 466), horizontal: .compact, vertical: .compact,
                         division: nil)
        case "halfWindow":
            // Unfolded, with the app on one half of the inner screen beside another app.
            return .init(name: "halfWindow", size: CGSize(width: 475, height: 669), horizontal: .compact, vertical: .regular,
                         division: nil)
        case "iPhone":
            return .init(name: "iPhone", size: CGSize(width: 402, height: 874), horizontal: .compact, vertical: .regular,
                         division: nil)
        case "iPhoneLandscape":
            return .init(name: "iPhoneLandscape", size: CGSize(width: 874, height: 402), horizontal: .compact, vertical: .compact,
                         division: nil)
        case "proMaxLandscape":
            return .init(name: "proMaxLandscape", size: CGSize(width: 956, height: 440), horizontal: .regular, vertical: .compact,
                         division: nil)
        default:
            return nil
        }
    }

    /// The system's insets in that posture, roughly: the vertical bar (about 84 pt, on the outer screen
    /// and the inner screen in landscape), the status bar and the home indicator. Without them the
    /// simulation hides layouts that only fit the full window.
    var safeArea: EdgeInsets {
        switch name {
        case "unfolded", "book", "folded", "foldedLandscape", "halfWindow":
            return EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: 84)
        case "unfoldedPortrait", "tabletop":
            return EdgeInsets(top: 44, leading: 0, bottom: 20, trailing: 0)
        case "iPhone":
            return EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)
        default:
            return EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62)
        }
    }

    /// The fold as `reservedRegions` reports it: in the coordinates of the root, which sits inside the
    /// safe area.
    var rootDivision: Division? {
        division.map { Division(frame: $0.frame.offsetBy(dx: -safeArea.leading, dy: -safeArea.top), isActive: $0.isActive) }
    }

    static var sequence: [DuoSimulation] {
        (UserDefaults.standard.string(forKey: "simulateDuo") ?? "").split(separator: ",").compactMap { named(String($0)) }
    }

    static var interval: Double {
        let v = UserDefaults.standard.double(forKey: "simulateDuoEvery")
        return v > 0 ? v : 10
    }
}
#endif
