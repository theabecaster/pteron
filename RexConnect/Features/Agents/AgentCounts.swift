import SwiftUI

/// How many agents wait for the user, work, or sit idle, as the pills that show it: most important
/// first, so the first pill is the one to keep when there is room for only one.
struct AgentCounts: Equatable {
    var waiting = 0
    var working = 0
    /// Every agent, whatever its state.
    var total = 0

    init(states: [String?]) {
        total = states.count
        for s in states {
            if s == "blocked" { waiting += 1 } else if s == "working" { working += 1 }
        }
    }

    struct Pill: Equatable, Identifiable {
        enum Kind: Equatable { case waiting, working, idle, none }
        var kind: Kind
        var count: Int
        var id: Kind { kind }

        /// The full-width form: "2 waiting".
        var words: String {
            switch kind {
            case .waiting: "\(count) waiting"
            case .working: "\(count) working"
            case .idle: "\(count) idle"
            case .none: "none"
            }
        }

        /// What VoiceOver reads, whichever form is on screen.
        var spoken: String {
            let agents = count == 1 ? "1 agent" : "\(count) agents"
            switch kind {
            case .waiting: return "\(agents) waiting"
            case .working: return "\(agents) working"
            case .idle: return "\(agents) idle"
            case .none: return "No agents"
            }
        }
    }

    /// Waiting, then working; idle (or none) only when nothing is waiting or working.
    var pills: [Pill] {
        var p: [Pill] = []
        if waiting > 0 { p.append(Pill(kind: .waiting, count: waiting)) }
        if working > 0 { p.append(Pill(kind: .working, count: working)) }
        if p.isEmpty { p.append(total == 0 ? Pill(kind: .none, count: 0) : Pill(kind: .idle, count: total)) }
        return p
    }
}

/// The agent count pills, always on one line. They take the widest form that fits: words
/// ("2 waiting"), then the status glyph and count, then only the most important pill. VoiceOver
/// reads every count in words in each form.
struct AgentCountPills: View {
    let counts: AgentCounts
    let theme: TermTheme

    var body: some View {
        let pills = counts.pills
        ViewThatFits(in: .horizontal) {
            row(pills, compact: false)
            row(pills, compact: true)
            row(Array(pills.prefix(1)), compact: true)
        }
        // Past this the smallest pill alone would outgrow a 200 pt sidebar. The title bar's
        // waiting pill stops at the same size.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pills.map(\.spoken).joined(separator: ", "))
    }

    private func row(_ pills: [AgentCounts.Pill], compact: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(pills) { StatusPill(pill: $0, compact: compact, theme: theme) }
        }
        .fixedSize()
    }
}

/// One count pill. Compact, it shows the status glyph the sidebar and title bar use, then the count.
struct StatusPill: View {
    let pill: AgentCounts.Pill
    let compact: Bool
    let theme: TermTheme
    /// The glyph follows the text's Dynamic Type size.
    @ScaledMetric(relativeTo: .caption2) private var glyph: CGFloat = 10

    var body: some View {
        let color = Self.color(pill.kind, theme)
        HStack(spacing: 3) {
            if compact { icon }
            Text(compact && pill.kind != .none ? "\(pill.count)" : pill.words)
                .monospacedDigit()
        }
        .font(.caption2.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.2)))
        .foregroundStyle(color)
        .fixedSize()
    }

    @ViewBuilder private var icon: some View {
        switch pill.kind {
        case .waiting: StatusBadge(state: "blocked", theme: theme, size: glyph)
        case .working: StatusBadge(state: "working", theme: theme, size: glyph)
        // Rows show no glyph for idle; a hollow dot is the working dot at rest.
        case .idle: Image(systemName: "circle").font(.system(size: glyph * 0.7, weight: .bold))
        case .none: EmptyView()
        }
    }

    static func color(_ kind: AgentCounts.Pill.Kind, _ theme: TermTheme) -> Color {
        switch kind {
        case .waiting: theme.chrome.blocked
        case .working: theme.chrome.working
        case .idle, .none: theme.chrome.tertiary
        }
    }
}
