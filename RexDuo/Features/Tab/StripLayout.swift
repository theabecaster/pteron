import CoreGraphics

/// What the tab strip shows in a bar of a given width, and where each part sits. The strip takes
/// the title bar's place and its height, so everything is decided along one axis.
///
/// Left to right: the session chip, the session's tab chips (they scroll), the pane dots, the
/// waiting pill, Unzoom, New Tab, a slot for a floating windows control, the pane menu. In a narrow bar the strip is compact: New Tab
/// and Unzoom are left to the Pane Actions menu, the dots are a count ("2/5"), and the session
/// chip is a glyph. Pure, so the frames are tested.
struct StripLayout: Equatable {
    struct Input: Equatable {
        /// The bar's width, its own paddings included.
        var width: CGFloat
        /// The bar's height: the title bar's, 44 pt or 34 pt in a short window.
        var height: CGFloat = 44
        /// The bar's leading edge in the root's coordinates: its global `minX` less
        /// `rootOrigin.x`. `crease` is in the same coordinates.
        var originX: CGFloat = 0
        /// The settled crease of book mode (`bookCrease`), in the root's coordinates. Nil flat.
        var crease: CGRect?
        /// The system's vertical bar holds the pane menu and Unzoom.
        var bar = false
        /// A session is on screen: its chips and New Tab show. Without one, the session chip alone.
        var hasSession = true
        /// A pane is on screen: the dots, Unzoom and the pane menu have something to act on.
        var hasPane = true
        /// The tab is zoomed on the phone.
        var zoomed = false
        /// How many panes the dots page through. Under two, no dots.
        var panes = 0
        /// How many agents the waiting pill counts. None, no pill.
        var waiting = 0
        /// A tab with floating windows shows a control for them beside the pane menu: its slot
        /// is kept, in both forms and beside a vertical bar too. Off, nothing is kept.
        var hasFloatsControl = false
        /// The session chip's own width with its name, as the strip's row measures it while
        /// it places the parts (`StripRow`). The chip takes it, between a hit target and
        /// `sessionMax`. Nil takes the most a name may have: what the strip's views are built
        /// from, since the name's width changes no part's form, only where the chips start.
        var sessionIdeal: CGFloat?
    }

    /// The strip's parts, in the order they sit.
    enum Part: Hashable, CaseIterable {
        case session, chips, dots, waiting, unzoom, newTab, floats, paneMenu

        /// Parts a finger taps. The dots only show a place, and are stepped by VoiceOver.
        var tappable: Bool { self != .dots }
    }

    /// How the session chip shows its session.
    enum SessionForm: Equatable {
        /// The session's name and a chevron.
        case name
        /// A glyph, with the waiting dot on it.
        case glyph
    }

    /// How the pane dots show which pane is on screen.
    enum DotsForm: Equatable {
        /// One dot per pane, the shown one a short bar.
        case dots(Int)
        /// "2/5".
        case count
    }

    // MARK: Fixed choices

    /// The narrowest a tappable part is.
    static let hit: CGFloat = 44
    /// Between the session chip and the chips, between two chips, and after the chips.
    static let gap: CGFloat = 6
    /// The most the session chip takes with its name: about 96 pt of name, and the chevron. A
    /// shorter name's chip is as wide as its name needs (`Input.sessionIdeal`).
    static let sessionMax: CGFloat = 120
    /// The narrowest tab chip.
    static let chipMin: CGFloat = hit
    /// The narrowest active chip that carries its close button: the button, and as much again
    /// for the chip's own label, so a tap meant for one never lands on the other.
    static let closeChipMin: CGFloat = hit + gap + hit
    /// The longest title of a chip that isn't the active one. The active chip shows all of its
    /// title that the chips' room holds.
    static let inactiveTitleMax: CGFloat = 120
    /// The room the chips need for the strip to keep every part: the active chip with its close
    /// button and one more chip beside it. With less, the strip is compact; with less in a
    /// compact strip, the active chip has no close button (Close Tab stays in the pane menu).
    static let chipsRoom: CGFloat = closeChipMin + gap + chipMin
    /// More panes than this show as a count, as in the title bar.
    static let maxDots = 6
    /// How far the strip's end keeps from the crease, as the panes do.
    static let creaseClearance: CGFloat = 3
    /// The least room the strip draws in. A crease can leave less: then nothing is drawn, so no
    /// glyph and no hairline ever lies on the fold.
    static let runMin: CGFloat = 16

    // MARK: Result

    /// New Tab and Unzoom are left to the pane menu, the dots are a count and the session chip
    /// is a glyph.
    var compact: Bool
    var session: SessionForm
    /// Nil with fewer than two panes to page through.
    var dots: DotsForm?
    /// The active chip carries its close button.
    var showsClose: Bool
    /// Where the bar's content starts: its leading padding, or past a crease that leaves no
    /// room before it (`run`).
    var start: CGFloat
    /// Where the bar's content ends: its trailing padding, or short of the crease.
    var end: CGFloat
    /// Each part on screen, in the bar's own coordinates, as tall as the bar.
    private(set) var frames: [Part: CGRect] = [:]

    /// The parts on screen, left to right.
    var parts: [Part] { Part.allCases.filter { frames[$0] != nil } }

    func frame(_ part: Part) -> CGRect? { frames[part] }
    func shows(_ part: Part) -> Bool { frames[part] != nil }

    /// The chips' room: the scrolling area's width.
    var chipsWidth: CGFloat { frames[.chips]?.width ?? 0 }

    /// The narrowest and widest the active chip is. It never outgrows the chips' room, so its
    /// close button is never scrolled out of reach while the chip is in view.
    var activeChip: ClosedRange<CGFloat> { activeChip(room: chipsWidth) }

    /// The narrowest and widest any other chip is. Its title is cut at `inactiveTitleMax`.
    var chip: ClosedRange<CGFloat> { chip(room: chipsWidth) }

    /// The same for chips whose row is `room` wide: the row's width as it was placed, which
    /// is more than `chipsWidth` where the session's name is short.
    func activeChip(room: CGFloat) -> ClosedRange<CGFloat> {
        let low = showsClose ? Self.closeChipMin : Self.chipMin
        return low...max(low, room)
    }

    func chip(room: CGFloat) -> ClosedRange<CGFloat> { Self.chipMin...max(Self.chipMin, room) }

    init(_ i: Input) {
        let (lead, end) = Self.run(i)
        // Decided for the bar as it is with every part showing, so a pill or the dots coming
        // and going never changes what else is there.
        let compact = end - lead - Self.fullParts(bar: i.bar, floats: i.hasFloatsControl) < Self.chipsRoom
        self.compact = compact
        start = lead
        self.end = end
        session = compact ? .glyph : .name

        var widths: [Part: CGFloat] = [:]
        widths[.session] = compact ? Self.hit : min(max(i.sessionIdeal ?? Self.sessionMax, Self.hit), Self.sessionMax)
        var dots: DotsForm?
        if i.hasPane, i.panes > 1 {
            let form: DotsForm = compact || i.panes > Self.maxDots ? .count : .dots(i.panes)
            dots = form
            widths[.dots] = Self.dotsWidth(form, panes: i.panes)
        }
        self.dots = dots
        if i.waiting > 0 { widths[.waiting] = Self.waitingWidth(i.waiting) }
        // Unzoom and the pane menu are in the vertical bar where there is one.
        if i.hasPane, i.zoomed, !i.bar, !compact { widths[.unzoom] = Self.hit }
        if i.hasSession, !compact { widths[.newTab] = Self.hit }
        if i.hasFloatsControl { widths[.floats] = Self.hit }
        if i.hasPane, !i.bar { widths[.paneMenu] = Self.hit }

        var frames: [Part: CGRect] = [:]
        func place(_ part: Part, _ x: CGFloat, _ w: CGFloat) {
            frames[part] = CGRect(x: x, y: 0, width: w, height: i.height)
        }
        // A crease can leave the strip next to nothing: then it has no parts at all.
        guard end - lead >= Self.runMin else {
            showsClose = false
            return
        }
        // Never past the strip's end: a crease that leaves the chip less than its width cuts it.
        let sessionWidth = min(widths[.session] ?? Self.hit, end - lead)
        place(.session, lead, sessionWidth)
        // The trailing parts sit against the end, right to left, while each has room and a gap
        // left beside the session chip. The first that doesn't ends them: a bar that narrow is
        // cut by a crease, and the pane menu comes first.
        var x = end
        for part in [Part.paneMenu, .floats, .newTab, .unzoom, .waiting, .dots] {
            guard let w = widths[part] else { continue }
            guard x - w >= lead + sessionWidth + Self.gap else { break }
            x -= w
            place(part, x, w)
        }
        let trailing = x < end
        let chipsMinX = lead + sessionWidth + Self.gap
        let chipsMaxX = trailing ? x - Self.gap : end
        if i.hasSession, chipsMaxX - chipsMinX >= Self.chipMin {
            place(.chips, chipsMinX, chipsMaxX - chipsMinX)
        }
        self.frames = frames
        showsClose = (frames[.chips]?.width ?? 0) >= Self.chipsRoom
    }

    // MARK: Widths

    /// The bar's padding before the session chip: as the title bar's.
    static func leading(bar: Bool) -> CGFloat { bar ? 12 : 4 }
    static let trailing: CGFloat = 4

    /// The crease with its clearance on both sides, in the bar's coordinates. Nil when it lies
    /// outside the bar.
    static func creaseSpan(_ i: Input) -> ClosedRange<CGFloat>? {
        guard let crease = i.crease else { return nil }
        let from = crease.minX - creaseClearance - i.originX, to = crease.maxX + creaseClearance - i.originX
        return to > 0 && from < i.width ? from...to : nil
    }

    /// Where the strip starts and ends in the bar: inside the bar's paddings and on one side of
    /// the crease. That is the left page while it holds the session chip as a hit target, and
    /// the pane menu as another where the strip has one, as in book mode on the Duo. A bar with
    /// less than that before the crease has its strip past the crease. With that room on
    /// neither side the strip keeps the wider side, and the session chip is cut to it.
    static func run(_ i: Input) -> (start: CGFloat, end: CGFloat) {
        let lead = leading(bar: i.bar), end = i.width - trailing
        guard let crease = creaseSpan(i) else { return (lead, end) }
        let before = crease.lowerBound - lead, after = end - max(lead, crease.upperBound)
        let needed = hit + (i.bar || !i.hasPane ? 0 : hit)
        if before >= needed || before >= after { return (lead, max(lead, min(end, crease.lowerBound))) }
        return (max(lead, crease.upperBound), end)
    }

    /// What the parts other than the chips take in a bar that shows them all in their full
    /// forms, the two gaps around the chips included. The floats slot counts only for a tab that
    /// has it, so a tab with floating windows goes compact 44 pt sooner.
    static func fullParts(bar: Bool, floats: Bool = false) -> CGFloat {
        let always = sessionMax + gap * 2 + dotsWidth(.dots(maxDots), panes: maxDots) + waitingWidth(1) + hit
        // Unzoom and the pane menu.
        return always + (bar ? 0 : hit * 2) + (floats ? hit : 0)
    }

    /// The dots' width: 8 pt each side, a 9 pt bar for the shown pane and 4 pt dots 3 pt apart;
    /// as a count, 7 pt a character.
    static func dotsWidth(_ form: DotsForm, panes: Int) -> CGFloat {
        switch form {
        case .dots(let n): 16 + 9 + CGFloat(max(n - 1, 0)) * 7
        case .count: 16 + CGFloat(String(panes).count * 2 + 1) * 7
        }
    }

    /// The waiting pill's width: its hit target, and wider from two digits on.
    static func waitingWidth(_ count: Int) -> CGFloat {
        max(hit, 33 + CGFloat(String(count).count) * 8)
    }
}
