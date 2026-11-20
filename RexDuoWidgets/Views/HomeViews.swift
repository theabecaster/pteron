import GlanceModel
import GlanceUI
import SwiftUI
import WidgetKit

/// The Home Screen sizes. Each lays out a `GlanceDigest`; none decides anything.
///
/// Every state is drawn in the app's own language: the theme's canvas with a faint wash of
/// the most urgent state (`GlanceCanvas`), the headline in its state's color, Glide where
/// nothing needs a look, and the agents as the sidebar's tiles (circles for agents, rounded
/// squares for shells) with the board's state badges.
struct GlanceHomeView: View {
    enum Size { case small, medium, large }

    let digest: GlanceDigest
    let size: Size
    let style: GlanceStyle

    var body: some View {
        Group {
            switch digest.kind {
            case .placeholder: welcome(GlanceDigest.openText, hint: size == .small ? nil : "to see your agents here")
            case .unpaired: welcome(GlanceDigest.pairText, hint: size == .small ? nil : "Tap to scan its pairing code")
            case .agents:
                switch size {
                case .small: small
                case .medium: medium
                case .large: large
                }
            }
        }
        .dynamicTypeSize(...GlanceType.largestText)
    }

    // MARK: No snapshot, no servers

    private func welcome(_ text: String, hint: String?) -> some View {
        VStack(spacing: size == .large ? 14 : 8) {
            glide(size == .large ? 64 : 52)
            VStack(spacing: 2) {
                Text(text)
                    .font(.system(size: size == .large ? 20 : 15, weight: .semibold))
                    .foregroundStyle(style.fg)
                    .widgetAccentable()
                if let hint {
                    Text(hint).font(GlanceType.place).foregroundStyle(style.secondary)
                }
            }
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Parts

    private var mark: Image { Image(GlanceStyle.markOpen, bundle: style.symbols) }

    /// Glide in the icon's gradient over its halo; the system's accent when tinted.
    private func glide(_ size: CGFloat, halo: Bool = true) -> some View {
        GlanceGlideMark(mark, size: size, fullColor: style.fullColor, halo: halo && !digest.dimmed, accent: Accented())
            .opacity(digest.dimmed ? style.dim : 1)
    }

    private func headline(stacked: Bool = false) -> some View {
        GlanceHeadline(headline: digest.headline, stacked: stacked)
            .font(GlanceType.headline(small: size == .small))
            // "Last seen" is quiet: the secondary color and no bold, never a warning.
            .fontWeight(digest.urgency == .offline ? .regular : nil)
            .foregroundStyle(style.headline(digest))
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .widgetAccentable()
            .glanceCount()
            .opacity(digest.dimmed ? style.dim : 1)
    }

    private var ageLine: some View {
        GlanceAgeLine(age: digest.age)
            .font(GlanceType.place)
            .foregroundStyle(style.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    private func ring(_ agent: GlanceSnapshot.Agent, _ d: CGFloat) -> some View {
        GlanceRing(state: "blocked", symbol: agent.symbol, tint: style.tint(kind: agent.kind), color: style.state(.waiting),
                   ground: style.ground, diameter: d, strokes: Accented()) {
            $0.widgetAccentedRenderingMode(.accentedDesaturated)
        }
    }

    /// One machine's counts, each state a word in its color: "2 waiting · 3 working".
    private func counts(_ c: GlanceSnapshot.Counts, lines: Int) -> some View {
        var parts: [Text] = []
        func add(_ n: Int, _ word: String, _ u: GlanceDigest.Urgency) {
            if n > 0 { parts.append(Text("\(n) \(word)").foregroundStyle(style.state(u))) }
        }
        add(c.waiting, "waiting", .waiting)
        add(c.error, c.error == 1 ? "error" : "errors", .error)
        add(c.working, "working", .working)
        add(c.done, "done", .done)
        add(c.idle, "idle", .quiet)
        let dot = Text(" · ").foregroundStyle(style.tertiary)
        let all = parts.isEmpty ? Text("No agents").foregroundStyle(style.secondary)
            : parts.dropFirst().reduce(parts[0]) { Text("\($0)\(dot)\($1)") }
        return all.font(GlanceType.state).lineLimit(lines).minimumScaleFactor(0.8)
    }

    /// The counts under each other, the most urgent first, for a narrow column. The headline's
    /// own count is left out: it already says it.
    private func countList(_ c: GlanceSnapshot.Counts, lines: Int) -> some View {
        var parts: [(String, GlanceDigest.Urgency)] = []
        if c.waiting > 0, digest.urgency != .waiting { parts.append(("\(c.waiting) waiting", .waiting)) }
        if c.error > 0, digest.urgency != .error { parts.append((c.error == 1 ? "1 error" : "\(c.error) errors", .error)) }
        if c.working > 0, digest.urgency != .working { parts.append(("\(c.working) working", .working)) }
        if c.done > 0, digest.urgency != .done { parts.append(("\(c.done) done", .done)) }
        if c.idle > 0 { parts.append(("\(c.idle) idle", .quiet)) }
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(parts.prefix(lines).enumerated()), id: \.offset) { _, part in
                Text(part.0).font(GlanceType.state).foregroundStyle(style.state(part.1)).lineLimit(1).glanceCount()
            }
        }
        .opacity(digest.dimmed ? style.dim : 1)
    }

    /// A waiting agent: its ring, its name over its place, and how long it has waited.
    private func row(_ r: GlanceDigest.Row, ring d: CGFloat) -> some View {
        Link(destination: r.link.url) {
            HStack(spacing: 8) {
                ring(r.agent, d)
                // The name and the time share the first line; the place has the second to itself.
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(r.agent.name)
                            .font(GlanceType.name)
                            .foregroundStyle(style.fg)
                            .privacySensitive()
                        Spacer(minLength: 0)
                        waited(r, width: 70, edge: .trailing)
                    }
                    Text([r.machineName, r.agent.place.isEmpty ? nil : r.agent.place].compactMap { $0 }.joined(separator: " · "))
                        .font(GlanceType.place)
                        .foregroundStyle(style.secondary)
                        .privacySensitive()
                }
                .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: 40, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(style.tile))
        }
        .opacity(r.stale || digest.dimmed ? style.dim : 1)
        .accessibilityElement(children: .combine)
    }

    /// `width`: the frame the time gets (see `GlanceWaited`), with the time at its `edge`.
    @ViewBuilder private func waited(_ r: GlanceDigest.Row, width: CGFloat, edge: Alignment) -> some View {
        // A down machine's wait is last known: it shows no running clock.
        if !r.stale {
            GlanceWaited(since: r.agent.since)
                .font(GlanceType.state)
                .foregroundStyle(style.state(.waiting))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(edge == .trailing ? .trailing : .leading)
                .frame(width: width, alignment: edge)
        }
    }

    private func more(_ n: Int) -> some View {
        Text("+\(n) more").font(GlanceType.place).foregroundStyle(style.secondary)
    }

    /// One tile per machine with its counts: what an older app's file, which lists no tiles,
    /// shows where the strip would be.
    private func machineTiles(_ limit: Int) -> some View {
        ForEach(digest.machines.prefix(limit)) { m in
            VStack(alignment: .leading, spacing: 2) {
                if digest.machines.count > 1 {
                    // A machine's name is private too (StandBy shows this size on a locked phone).
                    Text(m.name).font(GlanceType.name).foregroundStyle(style.fg).lineLimit(1).privacySensitive()
                }
                counts(m.counts, lines: 2)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(style.tile))
            .opacity(m.live && !digest.dimmed ? 1 : style.dim)
        }
    }

    /// A machine's card where nobody waits: a dot that says whether it is connected, its name
    /// and its counts.
    private func machineCards(_ limit: Int) -> some View {
        ForEach(digest.machines.prefix(limit)) { m in
            HStack(spacing: 8) {
                LiveDot(live: m.live, style: style)
                // The name keeps its room; long counts shrink, then truncate.
                Text(m.name).font(GlanceType.name).foregroundStyle(style.fg).lineLimit(1).privacySensitive()
                    .layoutPriority(1)
                Spacer(minLength: 6)
                counts(m.counts, lines: 1).minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(style.tile))
            .opacity(m.live && !digest.dimmed ? 1 : style.dim)
            .accessibilityElement(children: .combine)
        }
    }

    /// The agents as tiles, in rows of `perRow`, the most urgent first, with "+N" in the last
    /// place when there are more than fit. A waiting agent's tile opens its pane.
    private func strip(after rows: Int, limit: Int, perRow: Int, tile d: CGFloat, gap: CGFloat) -> some View {
        let (tiles, more) = digest.strip(after: rows, limit: limit)
        let cells: [StripCell] = tiles.map { .tile($0) } + (more > 0 ? [.more(more)] : [])
        let lines = stride(from: 0, to: cells.count, by: perRow).map { Array(cells[$0..<min($0 + perRow, cells.count)]) }
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: gap) {
                    ForEach(line) { cell in
                        switch cell {
                        case .tile(let t):
                            let drawn = GlanceTileView(tile: t, style: style, diameter: d, dimmed: digest.dimmed)
                                .glanceSwap("\(t.id)|\(t.state)")
                            if let link = t.link { Link(destination: link.url) { drawn } } else { drawn }
                        case .more(let n):
                            Text("+\(n)")
                                .font(GlanceType.state)
                                .foregroundStyle(style.secondary)
                                .minimumScaleFactor(0.7)
                                .lineLimit(1)
                                .glanceCount()
                                .frame(width: d, height: d)
                                .background(Circle().fill(style.tile))
                                .accessibilityLabel("\(n) more agents")
                        }
                    }
                }
            }
        }
    }

    // MARK: Small

    @ViewBuilder private var small: some View {
        if let first = digest.rows.first {
            smallWaiting(first)
        } else if let line = digest.calmLine {
            calm { calmLine(line) }
        } else if digest.urgency == .offline {
            calm {
                GlanceHeadline(headline: digest.headline, stacked: true)
                    .font(.system(size: 15))
                    .foregroundStyle(style.secondary)
                    .multilineTextAlignment(.center)
            }
        } else {
            smallBusy
        }
    }

    /// Glide over one line, where nothing needs a look.
    private func calm(@ViewBuilder _ line: () -> some View) -> some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            glide(52)
            line()
                .lineLimit(2)
                .minimumScaleFactor(0.75)
            if digest.age != .current { ageLine }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// "All quiet · 4 idle": the state's words in its color, the rest secondary.
    private func calmLine(_ line: String) -> some View {
        let parts = line.components(separatedBy: " · ")
        let head = Text(parts[0]).foregroundStyle(digest.kind == .agents ? style.headline(digest) : style.fg)
        let rest = parts.dropFirst().map { Text(" · \($0)").foregroundStyle(style.secondary) }
        return rest.reduce(head) { Text("\($0)\($1)") }
            .font(.system(size: 15, weight: .semibold).monospacedDigit())
            .multilineTextAlignment(.center)
            .glanceCount()
            .opacity(digest.dimmed ? style.dim : 1)
    }

    /// Working or failing, nobody waiting: the headline over Glide in the state's ring, and the
    /// other counts beside it.
    private var smallBusy: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline(stacked: true)
            Spacer(minLength: 6)
            HStack(spacing: 12) {
                GlanceGlideRing(urgency: digest.urgency, style: style, mark: mark, diameter: 52)
                    .opacity(digest.dimmed ? style.dim : 1)
                countList(digest.counts, lines: 3)
            }
            Spacer(minLength: 6)
            ageLine
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func smallWaiting(_ first: GlanceDigest.Row) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            headline(stacked: true)
            Spacer(minLength: 4)
            HStack(spacing: 8) {
                ring(first.agent, 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text(first.agent.name)
                        .font(GlanceType.name)
                        .foregroundStyle(style.fg)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .privacySensitive()
                    waited(first, width: 80, edge: .leading)
                }
            }
            .glanceSwap(first.id)
            .opacity(first.stale || digest.dimmed ? style.dim : 1)
            Spacer(minLength: 4)
            // The age when there is one to tell; else where the agent is.
            if digest.age != .current {
                ageLine
            } else if !first.agent.place.isEmpty {
                Text(first.agent.place).font(GlanceType.place).foregroundStyle(style.secondary).lineLimit(1).privacySensitive()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Medium

    @ViewBuilder private var medium: some View {
        if digest.noAgents {
            mediumEmpty
        } else if !digest.listsAgents {
            mediumWithoutTiles
        } else {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    headline(stacked: true)
                    if let line = digest.machineLine {
                        Text(line).font(GlanceType.place).foregroundStyle(style.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 2)
                    countList(digest.counts, lines: 3)
                    ageLine
                }
                .frame(width: 112, alignment: .leading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 8) {
                    if let first = digest.rows.first {
                        row(first, ring: 26).glanceSwap(first.id)
                        strip(after: 1, limit: 8, perRow: 4, tile: 32, gap: 12)
                        Spacer(minLength: 0)
                    } else {
                        Spacer(minLength: 0)
                        strip(after: 0, limit: 8, perRow: 4, tile: 36, gap: 12)
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
        }
    }

    /// Connected, and no agent runs: Glide, the words, and the machines it watches.
    private var mediumEmpty: some View {
        HStack(spacing: 18) {
            glide(52)
            VStack(alignment: .leading, spacing: 6) {
                Text(GlanceDigest.noAgentsText)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(style.fg)
                    .widgetAccentable()
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(digest.machines.prefix(3)) { m in
                        HStack(spacing: 6) {
                            LiveDot(live: m.live, style: style)
                            Text(m.name).font(GlanceType.place).foregroundStyle(style.secondary).privacySensitive()
                        }
                    }
                }
                ageLine
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.leading, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }

    /// A file from an older app: its waiting agents, or each machine's counts.
    private var mediumWithoutTiles: some View {
        let (rows, extra) = digest.shown(3)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                headline(stacked: true)
                if let line = digest.machineLine {
                    Text(line).font(GlanceType.place).foregroundStyle(style.secondary).lineLimit(2)
                }
                Spacer(minLength: 2)
                if extra > 0 { more(extra) } else if !rows.isEmpty { countList(digest.counts, lines: 3) }
                ageLine
            }
            .frame(width: 112, alignment: .leading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            VStack(spacing: 5) {
                if rows.isEmpty {
                    machineTiles(2)
                } else {
                    ForEach(rows) { row($0, ring: 26) }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: Large

    @ViewBuilder private var large: some View {
        if digest.rows.isEmpty {
            largeCalm
        } else {
            largeWaiting
        }
    }

    private var largeWaiting: some View {
        let tiles = digest.listsAgents
        let (rows, extra) = digest.shown(tiles ? 4 : 6)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                headline()
                Spacer(minLength: 4)
                if digest.age != .current {
                    ageLine
                } else if let line = digest.machineLine {
                    Text(line).font(GlanceType.place).foregroundStyle(style.secondary).lineLimit(1)
                }
            }
            if let first = rows.first, !first.stale, let msg = first.agent.msg, !msg.isEmpty {
                // What the longest-waiting agent asks. Private: redacted while the phone is locked.
                HStack(spacing: 8) {
                    Capsule().fill(style.state(.waiting)).frame(width: 3).widgetAccentable()
                    Text(msg)
                        .font(.system(size: 12))
                        .foregroundStyle(style.fg.opacity(0.85))
                        .lineLimit(2)
                        .privacySensitive()
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(digest.dimmed ? style.dim : 1)
                .glanceSwap(first.id)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                if i == 0 { row(r, ring: 26).glanceSwap(r.id) } else { row(r, ring: 26) }
            }
            if tiles {
                // The rest of the team under the rows, and what each machine runs at the foot
                // where there is room.
                strip(after: rows.count, limit: rows.count >= 3 ? 7 : 14, perRow: 7, tile: 32, gap: 12)
                    .padding(.top, 6)
                Spacer(minLength: 6)
                if rows.count <= 2 {
                    VStack(spacing: 6) { machineCards(rows.count == 1 ? 2 : 1) }
                }
            } else {
                if rows.count < 5 { machineTiles(6 - rows.count - 1) }
                Spacer(minLength: 0)
                if extra > 0 { more(extra) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Nobody waits: a Glide hero with the headline in the middle of the room, the agents'
    /// strip under it, and one card per machine at the foot.
    private var largeCalm: some View {
        let tiles = digest.listsAgents && !digest.tiles.isEmpty
        let twoLines = digest.strip(after: 0, limit: 14).tiles.count + (digest.strip(after: 0, limit: 14).more > 0 ? 1 : 0) > 7
        let cards = !tiles ? 4 : twoLines ? 2 : 3
        return VStack(spacing: 0) {
            Spacer(minLength: 0)
            if digest.urgency == .working || digest.urgency == .error {
                GlanceGlideRing(urgency: digest.urgency, style: style, mark: mark, diameter: 64)
                    .opacity(digest.dimmed ? style.dim : 1)
            } else {
                glide(60)
            }
            VStack(spacing: 2) {
                if digest.noAgents {
                    Text(GlanceDigest.noAgentsText)
                        .font(GlanceType.headline(small: false))
                        .foregroundStyle(style.fg)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .widgetAccentable()
                } else {
                    headline()
                }
                if digest.age != .current {
                    ageLine
                } else if let line = digest.machineLine {
                    Text(line).font(GlanceType.place).foregroundStyle(style.secondary).lineLimit(1)
                }
            }
            .padding(.top, 8)
            Spacer(minLength: 12)
            if tiles {
                strip(after: 0, limit: 14, perRow: 7, tile: 32, gap: 12)
                Spacer(minLength: 12)
            }
            VStack(spacing: 6) { machineCards(cards) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A place in an agent strip: a tile, or "+N" for the agents that don't fit.
private enum StripCell: Identifiable {
    case tile(GlanceDigest.Tile)
    case more(Int)

    var id: String {
        switch self {
        case .tile(let t): t.id
        case .more: "more"
        }
    }
}

/// An agent's tile: the sidebar's tile (a circle for an agent, a rounded square for another
/// program) in the agent's tint with its glyph, and the state's badge at its corner: the
/// board's raised hand, x or check, and the sidebar's dot for working. Idle has no badge and
/// is dimmed, as is anything last known.
struct GlanceTileView: View {
    let tile: GlanceDigest.Tile
    let style: GlanceStyle
    let diameter: CGFloat
    var dimmed = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: tile.kind == nil ? diameter * 5 / 18 : diameter / 2, style: .continuous)
        ZStack {
            shape.fill(style.fullColor ? style.tint(kind: tile.kind).opacity(0.9) : Color.primary.opacity(0.22))
            Image(systemName: tile.symbol)
                .font(.system(size: diameter * 0.42, weight: .bold))
                .foregroundStyle(style.fullColor ? style.colors.bg : .primary)
        }
        .frame(width: diameter, height: diameter)
        .overlay(alignment: .bottomTrailing) { badge }
        .opacity(tile.state == .quiet || tile.stale || dimmed ? style.dim : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(tile.kind?.capitalized ?? "Program"), \(Self.word(tile.state))")
    }

    private var stateWord: String? {
        switch tile.state {
        case .waiting: "blocked"
        case .error: "error"
        case .done: "done"
        default: nil
        }
    }

    @ViewBuilder private var badge: some View {
        let d = max(13, diameter * 0.42)
        if let name = GlanceRingBadge.symbol(stateWord) {
            Image(systemName: name)
                .font(.system(size: d * 0.5, weight: .heavy))
                .foregroundStyle(style.ground)
                .frame(width: d, height: d)
                .background(Circle().fill(style.state(tile.state)).widgetAccentable())
                .overlay(Circle().strokeBorder(style.ground, lineWidth: max(1.5, d * 0.12)))
                .offset(x: d * 0.25, y: d * 0.25)
        } else if tile.state == .working {
            let dot = d * 0.72
            Circle()
                .fill(style.state(.working))
                .widgetAccentable()
                .frame(width: dot, height: dot)
                .overlay(Circle().strokeBorder(style.ground, lineWidth: max(1.5, dot * 0.16)))
                .offset(x: dot * 0.25, y: dot * 0.25)
        }
    }

    static func word(_ u: GlanceDigest.Urgency) -> String {
        switch u {
        case .waiting: "waiting"
        case .error: "error"
        case .working: "working"
        case .done: "done"
        case .quiet, .offline: "idle"
        }
    }
}

/// Glide inside a still ring in the state's color: the board's arc for working, a full ring
/// with the x for an error.
struct GlanceGlideRing: View {
    let urgency: GlanceDigest.Urgency
    let style: GlanceStyle
    let mark: Image
    let diameter: CGFloat

    private var line: CGFloat { max(3, diameter * 0.075) }

    var body: some View {
        let color = style.state(urgency)
        ZStack {
            Group {
                Circle().stroke(color.opacity(0.22), lineWidth: line)
                if urgency == .working {
                    Circle().trim(from: 0, to: 0.28)
                        .stroke(color, style: StrokeStyle(lineWidth: line, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    Circle().stroke(color, lineWidth: line)
                }
            }
            .widgetAccentable()
            GlanceGlideMark(mark, size: diameter * 0.46, fullColor: style.fullColor, halo: false, accent: Accented())
        }
        .padding(line / 2)
        .frame(width: diameter, height: diameter)
        .overlay(alignment: .bottomTrailing) {
            if urgency == .error, let name = GlanceRingBadge.symbol("error") {
                let d = max(15, diameter * 0.36)
                Image(systemName: name)
                    .font(.system(size: d * 0.52, weight: .heavy))
                    .foregroundStyle(style.ground)
                    .frame(width: d, height: d)
                    .background(Circle().fill(color).widgetAccentable())
                    .overlay(Circle().strokeBorder(style.ground, lineWidth: max(1.5, d * 0.1)))
                    .offset(x: d * 0.18, y: d * 0.18)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Whether a machine was connected at the write: a dot in the done color, or a hollow one.
struct LiveDot: View {
    let live: Bool
    let style: GlanceStyle

    var body: some View {
        Circle()
            .fill(live ? style.state(.done) : .clear)
            .overlay(Circle().strokeBorder(live ? .clear : style.secondary, lineWidth: 1.2))
            .frame(width: 7, height: 7)
            .widgetAccentable()
            .accessibilityLabel(live ? "connected" : "not connected")
    }
}

/// The widget's ground: the app's canvas, a faint wash of the most urgent state (or the
/// theme's accent) at the top, and the edge. All still, and only in full color: tinted and
/// clear widgets lose their background to the system's glass.
struct GlanceCanvas: View {
    let digest: GlanceDigest
    let style: GlanceStyle

    var body: some View {
        style.colors.canvas
            .overlay {
                if style.fullColor {
                    LinearGradient(colors: [style.wash(digest), style.wash(digest).opacity(0)], startPoint: .top,
                                   endPoint: UnitPoint(x: 0.5, y: 0.6))
                }
            }
            .overlay { GlanceEdge(digest: digest, style: style) }
    }
}

/// The edge that says the most urgent state at a glance: the board's glow, scaled down. Only
/// in full color, and only while someone waits, fails or works.
struct GlanceEdge: View {
    let digest: GlanceDigest
    let style: GlanceStyle

    var body: some View {
        if style.fullColor, let glow = digest.glow {
            ContainerRelativeShape().strokeBorder(style.colors.state(glow).opacity(0.7), lineWidth: 1.5)
        }
    }
}
