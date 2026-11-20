import GlanceModel
import GlanceUI
import SwiftUI
import WidgetKit

/// The Home Screen sizes. Each lays out a `GlanceDigest`; none decides anything.
struct GlanceHomeView: View {
    enum Size { case small, medium, large }

    let digest: GlanceDigest
    let size: Size
    let style: GlanceStyle

    var body: some View {
        Group {
            switch digest.kind {
            case .placeholder: way(in: GlanceDigest.openText, hint: nil)
            case .unpaired: way(in: GlanceDigest.unpairedText, hint: "Tap to pair")
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

    private func way(in text: String, hint: String?) -> some View {
        VStack(spacing: 8) {
            Image(GlanceStyle.markOpen, bundle: style.symbols)
                .font(.system(size: size == .small ? 40 : 46, weight: .medium))
                .foregroundStyle(style.fullColor ? style.colors.accent : .primary)
                .widgetAccentable()
            Text(text)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(style.fg)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
            if let hint {
                Text(hint).font(GlanceType.place).foregroundStyle(style.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Parts

    private func headline(stacked: Bool = false) -> some View {
        GlanceHeadline(headline: digest.headline, stacked: stacked)
            .font(GlanceType.headline(small: size == .small))
            // "Last seen" is quiet: the secondary color and no bold, never a warning.
            .fontWeight(digest.urgency == .offline ? .regular : nil)
            .foregroundStyle(digest.urgency == .offline ? style.secondary : style.fg)
            .lineLimit(1)
            .minimumScaleFactor(0.65)
            .widgetAccentable()
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

    /// The counts under each other, the most urgent first, for a narrow column. The waiting
    /// count is left out where the headline already says it.
    private func countList(_ c: GlanceSnapshot.Counts, lines: Int) -> some View {
        var parts: [(String, GlanceDigest.Urgency)] = []
        if c.waiting > 0, digest.urgency != .waiting { parts.append(("\(c.waiting) waiting", .waiting)) }
        if c.error > 0, digest.urgency != .error { parts.append((c.error == 1 ? "1 error" : "\(c.error) errors", .error)) }
        if c.working > 0, digest.urgency != .working { parts.append(("\(c.working) working", .working)) }
        if c.done > 0 { parts.append(("\(c.done) done", .done)) }
        if c.idle > 0 { parts.append(("\(c.idle) idle", .quiet)) }
        return VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(parts.prefix(lines).enumerated()), id: \.offset) { _, part in
                Text(part.0).font(GlanceType.state).foregroundStyle(style.state(part.1)).lineLimit(1)
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

    /// One tile per machine with its counts: what fills the room no waiting agent takes.
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

    // MARK: Small

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            headline(stacked: true)
            Spacer(minLength: 4)
            if let first = digest.rows.first {
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
                .opacity(first.stale || digest.dimmed ? style.dim : 1)
            } else {
                countList(digest.counts, lines: 3)
            }
            Spacer(minLength: 4)
            // The age when there is one to tell; else where the agent is.
            if digest.age != .current {
                ageLine
            } else if let first = digest.rows.first, !first.agent.place.isEmpty {
                Text(first.agent.place).font(GlanceType.place).foregroundStyle(style.secondary).lineLimit(1).privacySensitive()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Medium

    private var medium: some View {
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

    private var large: some View {
        let (rows, extra) = digest.shown(6)
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
            }
            ForEach(rows) { row($0, ring: 26) }
            if rows.count < 5 { machineTiles(6 - rows.count - 1) }
            Spacer(minLength: 0)
            if extra > 0 { more(extra) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
