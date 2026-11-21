import SwiftUI
import RexKit

/// The sidebar's three levels share one grid, so a session's name sits under its machine's name and
/// its tabs one step further in. Indentation, type and spacing carry the hierarchy, with no lines:
/// machines are the largest and heaviest rows, sessions a full-contrast middle level, tabs lighter.
enum SidebarMetrics {
    /// Padding inside a row, both sides.
    static let pad: CGFloat = 8
    /// The machine glyph's column and the space after it.
    static let glyph: CGFloat = 20
    static let gap: CGFloat = 7
    /// A session's name starts under its machine's name.
    static var sessionLeading: CGFloat { pad + glyph + gap }
    /// Where a tab row starts. `TabRowLabel` adds its own 8 pt before the tile.
    static var tabLeading: CGFloat { sessionLeading + 5 }
    /// Names stay on one line, except at accessibility sizes, where two keep them readable.
    static func lines(_ size: DynamicTypeSize) -> Int { size.isAccessibilitySize ? 2 : 1 }
}

/// The disclosure chevron: points to the trailing side while folded, down while open (HIG).
struct Chevron: View {
    let open: Bool
    let theme: TermTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(theme.chrome.tertiary)
            .rotationEffect(.degrees(open ? 90 : 0))
            // A springy quarter turn; with Reduce Motion it just turns.
            .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.35, bounce: 0.3), value: open)
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .frame(width: 22)
            .accessibilityHidden(true)
    }
}

/// The machine's operating system, from `server.version`.
enum MachineGlyph {
    static func symbol(platform: String?) -> String {
        let p = platform?.lowercased() ?? ""
        if p.hasPrefix("darwin") || p.hasPrefix("macos") { return "apple.logo" }
        if p.hasPrefix("linux") || p.hasPrefix("freebsd") { return "server.rack" }
        if p.hasPrefix("windows") { return "pc" }
        return "desktopcomputer"
    }
}

/// Connected: a green dot. Waking up (back from the background, reconnecting): the same dot, grey
/// and still; the title bar's Glide is the one that moves. Connecting or trying again: a spinner.
/// Offline: a crossed antenna.
struct ConnectionDot: View {
    let server: ServerConnection
    let theme: TermTheme

    var body: some View {
        switch server.phase {
        case .online:
            Circle().fill(server.waking ? theme.chrome.tertiary : theme.chrome.done).frame(width: 7, height: 7)
                .accessibilityHidden(true)
        case .connecting, .idle:
            ProgressView().controlSize(.mini)
                .accessibilityLabel("Connecting")
        case .offline:
            if server.retrying {
                ProgressView().controlSize(.mini)
                    .accessibilityLabel("Connecting")
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.caption2)
                    .foregroundStyle(theme.chrome.tertiary)
                    .accessibilityLabel("Offline")
            }
        }
    }
}

/// What a folded group holds: its count ("3 tabs") and its waiting and working pills. Reads the
/// group's block statuses in its own body, so a status change re-renders only this summary.
/// It takes the widest form that fits and never wraps: words, then digits and glyphs, then the pills
/// alone, then the most urgent pill.
struct GroupSummary: View {
    let server: ServerConnection
    let windows: [WindowInfo]
    let count: Int
    /// "tab" or "session".
    let noun: String
    let theme: TermTheme

    var body: some View {
        let counts = AgentCounts(states: windows.flatMap(\.allBlocks).map { server.meta[$0.id]?.topStatus?.state })
        let pills = counts.activePills
        let words = "\(count) \(noun)\(count == 1 ? "" : "s")"
        ViewThatFits(in: .horizontal) {
            row(Text(words), pills, compact: false)
            row(Text(words), pills, compact: true)
            row(Text("\(count)"), pills, compact: true)
            row(nil, pills, compact: true)
            row(nil, Array(pills.prefix(1)), compact: true)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pills.map(\.spoken).joined(separator: ", "))
    }

    private func row(_ text: Text?, _ pills: [AgentCounts.Pill], compact: Bool) -> some View {
        HStack(spacing: 5) {
            if let text {
                text.font(.caption.weight(.medium)).monospacedDigit().foregroundStyle(theme.chrome.tertiary)
            }
            ForEach(pills) { StatusPill(pill: $0, compact: compact, theme: theme) }
        }
        .lineLimit(1)
        .fixedSize()
    }
}

/// A machine: the sidebar's top level. Tap to fold or open everything on it.
struct MachineHeader: View {
    let server: ServerConnection
    /// Every tab on the machine, for the folded summary. Passed in, so the header doesn't read
    /// `server.views` and re-render with every layout change.
    let windows: [WindowInfo]
    var sessionCount = 0
    let collapsed: Bool
    /// False in Agents mode, where a machine never folds.
    var foldable = true
    let theme: TermTheme
    let toggle: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        if foldable {
            Button(action: toggle) { content }
                .buttonStyle(.plain)
                .focusable(interactions: .activate)
                .onKeyPress(.return) { toggle(); return .handled }
                .accessibilityAddTraits(.isHeader)
                .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        } else {
            content
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private var content: some View {
        HStack(spacing: SidebarMetrics.gap) {
            Image(systemName: MachineGlyph.symbol(platform: server.platform))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(theme.chrome.secondary)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .frame(width: SidebarMetrics.glyph)
                .accessibilityHidden(true)
            NameAndSummary {
                // Down: a quiet line under the name, never a takeover while another server is up.
                VStack(alignment: .leading, spacing: 1) {
                    Text(server.config.name)
                        .font(.headline)
                        .lineLimit(SidebarMetrics.lines(typeSize))
                        .accessibilityLabel(spokenName)
                    if let p = server.phase.problem {
                        Text(OfflineCopy.short(p.kind))
                            .font(.caption2)
                            .foregroundStyle(theme.chrome.tertiary)
                            .lineLimit(1)
                    }
                }
                if collapsed {
                    GroupSummary(server: server, windows: windows, count: sessionCount,
                                 noun: "session", theme: theme)
                        .transition(SidebarMotion.handoff)
                }
            }
            ConnectionDot(server: server, theme: theme)
            if foldable { Chevron(open: !collapsed, theme: theme) }
        }
        .padding(.horizontal, SidebarMetrics.pad)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var spokenName: String {
        "\(server.config.name), machine, \(sessionCount) session\(sessionCount == 1 ? "" : "s")"
    }
}

/// A session: the middle level, under its machine's name. Tap to fold its tabs; `+` adds a tab.
struct SessionHeader: View {
    let server: ServerConnection
    let session: SessionEntry
    /// The session's tabs, passed in by the row (see `MachineHeader.windows`).
    let windows: [WindowInfo]
    let collapsed: Bool
    let theme: TermTheme
    let toggle: () -> Void
    let newTab: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let name = session.label.isEmpty ? "session" : session.label
        // One fold button across the row, chevron included; `+` sits over it, so VoiceOver finds
        // two elements: the session and New Tab.
        Button(action: toggle) {
            HStack(spacing: 0) {
                NameAndSummary {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(SidebarMetrics.lines(typeSize))
                        .accessibilityLabel("\(name), session, \(windows.count) tab\(windows.count == 1 ? "" : "s")")
                    if collapsed {
                        GroupSummary(server: server, windows: windows, count: windows.count, noun: "tab", theme: theme)
                            .transition(SidebarMotion.handoff)
                    }
                }
                // Room for `+`. Folded, the name gets it; New Tab stays in the swipe and the menu.
                Color.clear.frame(width: collapsed ? 0 : 36, height: 1)
                Chevron(open: !collapsed, theme: theme)
            }
            .padding(.leading, SidebarMetrics.sessionLeading)
            .padding(.trailing, SidebarMetrics.pad)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(interactions: .activate)
        .onKeyPress(.return) { toggle(); return .handled }
        .accessibilityValue(collapsed ? "Collapsed" : "Expanded")
        .overlay(alignment: .trailing) {
            if !collapsed {
                Button(action: newTab) {
                    Image(systemName: "plus")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(theme.chrome.tertiary)
                        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("New Tab in \(name)")
                .padding(.trailing, SidebarMetrics.pad + 22)
                .transition(SidebarMotion.handoff)
            }
        }
    }
}

/// A header's name, then its summary at the trailing edge. The name keeps its whole width, or at
/// least `share` of the row, before the summary gives up room: the summary then takes its smaller
/// forms (`GroupSummary` is a `ViewThatFits`), and only past that does the name truncate. Sessions
/// are what people look for, so their names win over counts.
struct NameAndSummary: Layout {
    var spacing: CGFloat = 6
    var share: CGFloat = 0.55

    /// The last split, so placing doesn't measure the summary's forms again.
    struct Cache {
        var width: CGFloat = -1
        var split: (CGFloat, CGSize) = (0, .zero)
    }

    func makeCache(subviews: Subviews) -> Cache { Cache() }

    func updateCache(_ cache: inout Cache, subviews: Subviews) { cache = Cache() }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        guard let width = proposal.width else {
            let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
            let ideal = sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(subviews.count - 1, 0))
            return CGSize(width: ideal, height: sizes.map(\.height).max() ?? 0)
        }
        let (nameWidth, summary) = split(width, subviews, &cache)
        // A name that wraps (accessibility sizes) makes the row taller.
        let nameHeight = subviews.first?.sizeThatFits(ProposedViewSize(width: nameWidth, height: nil)).height ?? 0
        return CGSize(width: width, height: max(nameHeight, summary.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        guard let name = subviews.first else { return }
        let (nameWidth, summary) = split(bounds.width, subviews, &cache)
        if subviews.count > 1 {
            subviews[1].place(at: CGPoint(x: bounds.maxX - summary.width, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(summary))
        }
        name.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                   proposal: ProposedViewSize(width: nameWidth, height: bounds.height))
    }

    /// The name's width and the summary's size in a row this wide.
    private func split(_ width: CGFloat, _ subviews: Subviews, _ cache: inout Cache) -> (CGFloat, CGSize) {
        guard subviews.count > 1, let name = subviews.first else { return (width, .zero) }
        if cache.width == width { return cache.split }
        let nameIdeal = name.sizeThatFits(.unspecified).width
        let room = max(0, width - min(nameIdeal, width * share) - spacing)
        // Even its smallest form never clips: past that the name gives way.
        let summary = subviews[1].sizeThatFits(ProposedViewSize(width: room, height: nil))
        cache = Cache(width: width, split: (max(0, width - summary.width - spacing), summary))
        return cache.split
    }
}

struct StatusBadge: View {
    var state: String?
    var theme: TermTheme
    /// The glyph's point size; the working dot is 0.7 of it.
    var size: CGFloat = 10

    init(status: ProgramStatus?, theme: TermTheme, size: CGFloat = 10) {
        self.init(state: status?.state, theme: theme, size: size)
    }

    init(state: String?, theme: TermTheme, size: CGFloat = 10) {
        self.state = state
        self.theme = theme
        self.size = size
    }

    var body: some View {
        switch state {
        case "working":
            PulsingDot(color: theme.chrome.working, size: size * 0.7)
                .accessibilityLabel("working")
        case "blocked":
            Image(systemName: "hand.raised.fill").font(.system(size: size)).foregroundStyle(theme.chrome.blocked)
                .accessibilityLabel("waiting for you")
        case "done":
            Image(systemName: "checkmark").font(.system(size: size, weight: .bold)).foregroundStyle(theme.chrome.done)
                .accessibilityLabel("done")
        case "error":
            Image(systemName: "exclamationmark").font(.system(size: size, weight: .bold)).foregroundStyle(theme.chrome.error)
                .accessibilityLabel("error")
        default:
            EmptyView()
        }
    }
}

/// What a tab's status glyph shows. Agent status (OSC 7501) that needs or holds attention ranks
/// above a program's progress bar (OSC 9;4), so a tab whose agent works keeps its working dot
/// even while another pane builds; a bar ranks above done and idle.
enum TabBadge: Equatable {
    /// `StatusBadge` for this OSC 7501 state, or nothing.
    case status(String?)
    case ring(TermProgress)

    /// `status` is the tab's top agent status; `progress` the bars of its panes without an
    /// OSC 7501 record. Of several bars: an error first, else the lowest percent, else
    /// indeterminate.
    static func of(status: String?, progress: [TermProgress]) -> TabBadge {
        switch status {
        case "blocked", "error", "working": return .status(status)
        default: break
        }
        guard let ring = lowest(progress) else { return .status(status) }
        return .ring(ring)
    }

    static func lowest(_ bars: [TermProgress]) -> TermProgress? {
        func key(_ p: TermProgress) -> (Int, Int) {
            (p.state == .error ? 0 : p.percent == nil ? 2 : 1, p.percent ?? 0)
        }
        return bars.min { key($0) < key($1) }
    }
}

/// A tab's status glyph, observing only that tab's blocks. With `showsProgress` (sidebar tab rows
/// and overview cards) a program's progress bar shows as a ring where no agent status outranks
/// it; without, it is exactly `StatusBadge` of the tab's status, as the title bar wants it. Its own
/// view, so a progress report re-renders this leaf and not the row around it.
struct WindowStatusBadge: View {
    let server: ServerConnection
    let window: WindowInfo
    let theme: TermTheme
    var showsProgress = false

    var body: some View {
        #if DEBUG
        let _ = RenderCount.bump(.statusLeaves)
        #endif
        let status = server.windowStatus(window)
        if showsProgress {
            switch TabBadge.of(status: status?.state, progress: bars(status?.state)) {
            case .status(let state): StatusBadge(state: state, theme: theme)
            case .ring(let p): ProgressRing(progress: p, theme: theme)
            }
        } else {
            StatusBadge(status: status, theme: theme)
        }
    }

    /// The bars of the panes that report no agent status. Read only when no agent status
    /// outranks them, so a working agent's tab doesn't observe its panes' bars at all.
    private func bars(_ state: String?) -> [TermProgress] {
        if state == "blocked" || state == "error" || state == "working" { return [] }
        return window.allBlocks.compactMap { b in
            guard server.meta[b.id]?.statuses.isEmpty ?? true else { return nil }
            return server.progress.value(b.id)
        }
    }
}

/// A program's progress bar (OSC 9;4) in the status glyph's place: an arc over a faint track,
/// paler while paused, red on error. Busy with no percent is the working dot.
struct ProgressRing: View {
    let progress: TermProgress
    let theme: TermTheme
    var size: CGFloat = 10
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if progress.state == .indeterminate {
            PulsingDot(color: theme.chrome.working, size: size * 0.7)
                .accessibilityLabel("working")
        } else {
            let color = progress.state == .error ? theme.chrome.error : theme.chrome.working
            let fill = CGFloat(progress.percent ?? 100) / 100
            ZStack {
                Circle().stroke(color.opacity(0.22), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: fill)
                    .stroke(progress.state == .pause ? color.opacity(0.45) : color,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .padding(0.75)
            .frame(width: size, height: size)
            .animation(reduceMotion ? nil : .linear(duration: 0.2), value: fill)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.spoken(progress))
        }
    }

    nonisolated static func spoken(_ p: TermProgress) -> String {
        let state: String
        switch p.state {
        case .pause: state = "paused"
        case .error: state = "error"
        case .set, .indeterminate: state = "working"
        }
        return p.percent.map { "\(state), \($0) percent" } ?? state
    }
}

/// The "working" dot. A symbol effect, not a SwiftUI repeat-forever animation, so many rows stay cheap.
/// With Reduce Motion on it holds still.
struct PulsingDot: View {
    var color: Color
    var size: CGFloat = 7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: size))
            .foregroundStyle(color)
            .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
    }
}

/// One tab row's contents. It reads block metadata in its own body, so a status change in one tab
/// re-renders only that row, not the whole sidebar.
struct TabRowLabel: View {
    let server: ServerConnection
    let window: WindowInfo
    var textSize: Double = 14
    /// The title's color; nil is the theme's text color.
    var textColor: Color?
    var minHeight: CGFloat = 44
    let theme: TermTheme
    /// Scales the text size with Dynamic Type.
    @ScaledMetric(relativeTo: .subheadline) private var scale: CGFloat = 1
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        #if DEBUG
        let _ = RenderCount.bump(.tabRowLabels)
        #endif
        let agent = server.windowAgent(window)
        HStack(spacing: 9) {
            ZStack {
                Self.tile(agent).fill(Self.tint(agent, theme).opacity(0.9))
                Image(systemName: agent?.symbol ?? "terminal")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(theme.bg)
            }
            .frame(width: 18, height: 18)
            // One line, so the row's height stays put and the badges keep their room; two at
            // accessibility sizes, where one would hold a few letters.
            Text(WindowTitle.of(window, server: server))
                .font(.system(size: textSize * scale))
                .foregroundStyle(textColor ?? theme.fg)
                .lineLimit(SidebarMetrics.lines(typeSize))
            Spacer(minLength: 4)
            Group {
                if window.allBlocks.count > 1 {
                    Text("\(window.allBlocks.count)")
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.chrome.tertiary)
                        .accessibilityLabel("\(window.allBlocks.count) panes")
                }
                WindowStatusBadge(server: server, window: window, theme: theme, showsProgress: true)
            }
            .fixedSize()
            .layoutPriority(1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// The tile behind the glyph: a circle for an agent, a rounded square for a shell, so the
    /// two read apart at a glance. One shape type (half of the 18 pt tile is a circle), so rows
    /// need no type erasure.
    static func tile(_ a: AgentKind?) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: a == nil ? 5 : 9)
    }

    static func tint(_ a: AgentKind?, _ theme: TermTheme) -> Color {
        switch a {
        case .claude: return Color(hex: "#d97757")
        case .codex: return theme.fg
        case .gemini: return theme.ansiColor(4)
        case .some: return theme.ansiColor(5)
        case nil: return theme.chrome.secondary
        }
    }
}

enum WindowTitle {
    @MainActor
    static func of(_ w: WindowInfo, server: ServerConnection) -> String {
        let generic = w.label.isEmpty || w.label.hasPrefix("Window ")
        if !generic { return w.label }
        if let f = w.focusedBlockID ?? w.orderedBlockIDs.first, let t = server.meta[f]?.title, !t.isEmpty { return condense(t) }
        return w.block(w.focusedBlockID ?? "")?.label ?? "shell"
    }

    /// Shell titles like "user@host:~/code/project" become "project": the part that tells tabs apart.
    static func condense(_ t: String) -> String {
        let s = t.trimmingCharacters(in: .whitespaces)
        guard let at = s.firstIndex(of: "@"), let colon = s[at...].firstIndex(of: ":"),
              !s[..<at].contains(" ") else { return s }
        let path = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if path.isEmpty { return s }
        if path == "~" || path == "/" { return path }
        return path.split(separator: "/").last.map(String.init) ?? path
    }
}
