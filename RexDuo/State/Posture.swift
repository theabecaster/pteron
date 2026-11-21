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
/// reserved regions for layout, the hinge only for effects). The hinge is read in one place, to
/// tell when the phone stands as a tent (`TentDetector`), and never for layout.
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

/// Whether the sidebar shows, and what commands and gestures do to it. One state for every
/// arrangement: inline it sits beside the tab, narrow it is a drawer over the tab.
struct SidebarState: Equatable {
    /// Starts open, so a launch shows the last tab with the sidebar beside or over it.
    var open = true
    /// What the sidebar lists: machines, sessions and tabs, or every agent (the Mac's activity mode).
    var mode = SidebarMode.sessions

    enum Presentation: Equatable { case hidden, inline, drawer }

    func presentation(_ arrangement: Arrangement) -> Presentation {
        open ? (arrangement.inline ? .inline : .drawer) : .hidden
    }

    /// The toggle button, the Toggle Sidebar shortcut (`client.sidebar.toggle`) and the menu command.
    mutating func toggle() { open.toggle() }

    /// The left-edge swipe.
    mutating func reveal() { open = true }

    /// A tab was picked to be shown: a drawer closes so the tab shows; an inline sidebar stays.
    mutating func tabShown(inline: Bool) { if !inline { open = false } }

    /// `client.sidebar.activity.toggle` (⌘.): shows the sidebar in Agents mode, or goes back to
    /// Sessions when Agents mode is already showing.
    mutating func toggleAgents() {
        if open && mode == .agents {
            mode = .sessions
        } else {
            open = true
            mode = .agents
        }
    }

    /// The root's way to change the sidebar: in tab mode nothing does. No sidebar is on screen
    /// there, so a tab that is shown, a fold into book mode or a key leaves it as it was, and it
    /// is back exactly so when the sidebar is.
    mutating func write(in navigation: NavigationStyle, _ change: (inout SidebarState) -> Void) {
        guard navigation == .sidebar else { return }
        change(&self)
    }

    /// Runs an app command that is the sidebar's. False for any other command.
    mutating func perform(_ command: RexCommand) -> Bool {
        switch command {
        case .toggleSidebar: toggle()
        case .toggleAgents: toggleAgents()
        default: return false
        }
        return true
    }
}

enum SidebarMode: String, CaseIterable, Identifiable {
    case sessions, agents
    var id: String { rawValue }
    var title: String { self == .sessions ? "Sessions" : "Agents" }
    var symbol: String { self == .sessions ? "list.bullet.indent" : "sparkles" }
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

    /// How far a hidden sidebar moves left, from its place at the safe area's leading edge. It
    /// goes past the window's edge, not only the safe area's: a leading inset (the vertical bar
    /// on the left, an app on the left of Split View, the Dynamic Island in landscape) is screen
    /// the app draws under, so moving by the width alone left that much of the sidebar showing.
    /// The 24 pt more keep the drawer's shadow off screen too.
    static func hiddenOffset(width: CGFloat, leadingInset: CGFloat) -> CGFloat {
        -(width + leadingInset + 24)
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
    /// The crease book mode lays a tab's splits out against, in the root's coordinates: an active
    /// vertical fold that has held still (`CreaseSettle`). Nil otherwise.
    @Entry var bookCrease: CGRect? = nil
    /// The edge of the system's vertical bar (iPhone Duo: the outer screen, and the inner screen in
    /// landscape). Nil where bars are horizontal. Toolbar items go there instead of the title bar.
    @Entry var verticalBarEdge: HorizontalEdge? = nil
    /// That bar's column, in screen coordinates: the window's safe-area inset on its edge, as
    /// tall as the window (`KeyBarPlacement.column`). The key bar beside the keyboard ends short
    /// of it. Nil without a vertical bar.
    @Entry var verticalBarColumn: CGRect? = nil
}

#if DEBUG
/// `-simulateDuo <posture>` (testing): lays the root out as that window, with its size classes, the
/// system's insets and a fake fold, so one big simulator screen shows every layout. Each posture is
/// described once, in `postures`. A comma-separated list cycles through the postures every
/// `-simulateDuoEvery` seconds (default 10), to check what a fold or an unfold keeps.
struct DuoSimulation: Equatable {
    var name: String
    /// The whole window, insets included.
    var size: CGSize
    var horizontal: UserInterfaceSizeClass
    var vertical: UserInterfaceSizeClass
    /// The fold, in the window's coordinates.
    var division: Division?
    /// The system's insets there: the vertical bar (84 pt, on the outer screen and the inner
    /// screen in landscape), the status bar, the Dynamic Island and the home indicator. The root
    /// gets them twice, as on a device: as the room it is laid out in (`rootSize`), and as the
    /// safe area of the sidebar and the tab, which draw under them (`insets(keyboard:)`).
    var safeArea: EdgeInsets
    /// Whether the window covers its whole screen there, for `TentDetector`: every posture but
    /// a half of the inner screen beside another app.
    var fillsScreen = true

    /// The Duo's vertical bar, as the simulator reports it on the outer screen.
    private static let bar: CGFloat = 84

    /// Every posture. The insets of the outer screen and of the iPhone in landscape come from the
    /// iOS 27.2 simulators (docs/debug-args.md says which); the others are rough.
    static let postures: [DuoSimulation] = [
        .init(name: "unfolded", size: CGSize(width: 951, height: 669), horizontal: .regular, vertical: .regular,
              division: Division(frame: CGRect(x: 475.5, y: 0, width: 0, height: 669), isActive: false),
              safeArea: EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: bar)),
        .init(name: "book", size: CGSize(width: 951, height: 669), horizontal: .regular, vertical: .regular,
              division: Division(frame: CGRect(x: 455.5, y: 0, width: 40, height: 669), isActive: true),
              safeArea: EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: bar)),
        .init(name: "unfoldedPortrait", size: CGSize(width: 669, height: 951), horizontal: .regular, vertical: .regular,
              division: Division(frame: CGRect(x: 0, y: 475.5, width: 669, height: 0), isActive: false),
              safeArea: EdgeInsets(top: 44, leading: 0, bottom: 20, trailing: 0)),
        .init(name: "tabletop", size: CGSize(width: 669, height: 951), horizontal: .regular, vertical: .regular,
              division: Division(frame: CGRect(x: 0, y: 455.5, width: 669, height: 40), isActive: true),
              safeArea: EdgeInsets(top: 44, leading: 0, bottom: 20, trailing: 0)),
        .init(name: "folded", size: CGSize(width: 466, height: 678), horizontal: .compact, vertical: .regular,
              safeArea: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: bar)),
        .init(name: "foldedLandscape", size: CGSize(width: 678, height: 466), horizontal: .compact, vertical: .compact,
              safeArea: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: bar)),
        // The outer screen on its side the other way: the bar is on the left.
        .init(name: "foldedLandscapeBarLeft", size: CGSize(width: 678, height: 466), horizontal: .compact, vertical: .compact,
              safeArea: EdgeInsets(top: 0, leading: bar, bottom: 34, trailing: 0)),
        // Unfolded, with the app on the right half of the inner screen beside another app.
        .init(name: "halfWindow", size: CGSize(width: 475, height: 669), horizontal: .compact, vertical: .regular,
              safeArea: EdgeInsets(top: 0, leading: 0, bottom: 20, trailing: bar), fillsScreen: false),
        // The same on the left half: the bar is on the outer edge, the left.
        .init(name: "halfWindowBarLeft", size: CGSize(width: 475, height: 669), horizontal: .compact, vertical: .regular,
              safeArea: EdgeInsets(top: 0, leading: bar, bottom: 20, trailing: 0), fillsScreen: false),
        .init(name: "iPhone", size: CGSize(width: 402, height: 874), horizontal: .compact, vertical: .regular,
              safeArea: EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0)),
        // iOS insets both sides alike, whichever holds the Dynamic Island, so this is also the
        // island on the left.
        .init(name: "iPhoneLandscape", size: CGSize(width: 874, height: 402), horizontal: .compact, vertical: .compact,
              safeArea: EdgeInsets(top: 0, leading: 62, bottom: 20, trailing: 62)),
        .init(name: "proMaxLandscape", size: CGSize(width: 956, height: 440), horizontal: .regular, vertical: .compact,
              safeArea: EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62)),
    ]

    static func named(_ raw: String) -> DuoSimulation? {
        let name = raw.trimmingCharacters(in: .whitespaces)
        return postures.first { $0.name == name }
    }

    /// The safe area the sidebar and the tab get, with the simulated keyboard `keyboard` pt
    /// tall. The keyboard covers the home indicator, so the bottom inset goes while it is up.
    func insets(keyboard: CGFloat = 0) -> EdgeInsets {
        var e = safeArea
        if keyboard > 0 { e.bottom = 0 }
        return e
    }

    /// The window inside its insets: the size the root is laid out in, which picks the
    /// arrangement.
    var rootSize: CGSize {
        CGSize(width: size.width - safeArea.leading - safeArea.trailing,
               height: size.height - safeArea.top - safeArea.bottom)
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
