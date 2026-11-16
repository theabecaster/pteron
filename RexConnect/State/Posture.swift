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

/// How the root lays out the sidebar and the tab. Picked from size classes and the fold, never from
/// orientation or the hinge (Apple: use reserved regions for layout, the hinge only for effects).
enum Arrangement: Equatable {
    /// Compact width or compact height: a navigation stack, sidebar then tab, one pane at a time.
    /// Folded Duo, every other iPhone, landscape iPhones.
    case stack
    /// Two pages split at a vertical crease: the sidebar (or a pane) on the first page, the tab (or
    /// the other pane) on the second. `first` is the first page's width, `gap` the crease between them.
    case pages(first: CGFloat, gap: CGFloat)
    /// One column the full width, sidebar as an overlay. Unfolded portrait, flat.
    case overlay
    /// Partly folded with a horizontal crease: the terminal above it, the controls and keyboard below.
    /// `top` is the top region's height, `gap` the crease.
    case tabletop(top: CGFloat, gap: CGFloat)

    var isStack: Bool { self == .stack }

    /// Narrowest page worth drawing; below this the split falls back to the center.
    static let minPage: CGFloat = 200

    static func decide(size: CGSize, horizontal: UserInterfaceSizeClass?, vertical: UserInterfaceSizeClass?,
                       division: Division?) -> Arrangement {
        guard horizontal == .regular, vertical != .compact, size.width > 0, size.height > 0 else { return .stack }
        if let d = division, d.isVertical {
            return pages(width: size.width, from: d.frame.minX, to: d.frame.maxX)
        }
        if let d = division {
            guard d.isActive else { return .overlay }
            // The height shrinks while the keyboard is up, so only the top region is checked.
            let top = d.frame.minY
            guard top >= minPage else { return .overlay }
            return .tabletop(top: top, gap: d.frame.height)
        }
        // No fold reported (before iOS 27.1, or none found): this app runs only on iPhones, where
        // regular width and height means the Duo's inner screen. Assume its crease at the center.
        return size.width > size.height ? pages(width: size.width, from: size.width / 2, to: size.width / 2) : .overlay
    }

    private static func pages(width: CGFloat, from: CGFloat, to: CGFloat) -> Arrangement {
        guard from >= minPage, width - to >= minPage else {
            return .pages(first: (width / 2).rounded(), gap: 0)
        }
        return .pages(first: from, gap: max(to - from, 0))
    }
}

/// The fold, for views that adapt to it (an even column count in grids). Nil without one.
extension EnvironmentValues {
    @Entry var division: Division? = nil
}

#if DEBUG
/// `-simulateDuo unfolded|book|unfoldedPortrait|tabletop|folded|halfWindow|iPhone|iPhoneLandscape|
/// proMaxLandscape` (testing): lays the root out in that window size, with its size classes and a fake
/// fold, so one big simulator screen shows every layout.
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

    static var sequence: [DuoSimulation] {
        (UserDefaults.standard.string(forKey: "simulateDuo") ?? "").split(separator: ",").compactMap { named(String($0)) }
    }

    static var interval: Double {
        let v = UserDefaults.standard.double(forKey: "simulateDuoEvery")
        return v > 0 ? v : 10
    }
}
#endif
