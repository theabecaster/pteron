import SwiftUI
import RexKit

/// The agent board: who needs you, read from a desk a meter away. One line sums up the most
/// urgent state, then a tile per agent that isn't idle, laid out for their number and the window
/// (`BoardLayout`). It never scrolls. With nobody at work it is a clock.
///
/// Colors are the terminal theme's chrome colors, like the sidebar. A state is always said in
/// words and shown by a glyph too, never by color alone.
struct AgentBoardView: View {
    let machines: [BoardMachine]
    let theme: TermTheme
    let onOpen: (BoardAgent) -> Void
    let onMore: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// The text size setting, as a factor: tiles grow to 1.25, the header and the clock to 1.5.
    @ScaledMetric(relativeTo: .body) private var unit: CGFloat = 100
    @State private var throttle = BoardOrderThrottle()
    /// The tiles' order on screen, which changes at most once a second.
    @State private var order: [String] = []
    @State private var retryAt: Date?

    private var tileScale: CGFloat { min(max(unit / 100, 1), 1.25) }
    private var headScale: CGFloat { min(max(unit / 100, 1), 1.5) }

    var body: some View {
        let board = AgentBoard.make(machines)
        let wanted = board.tiles.map(\.id)
        GeometryReader { geo in
            let layout = BoardLayout.decide(count: board.tiles.count, size: geo.size, hasFooter: board.idleCount > 0,
                                            typeScale: tileScale, headScale: headScale)
            ZStack(alignment: .topLeading) {
                if layout.style == .quiet {
                    quiet(board, geo.size)
                } else {
                    busy(board, layout, geo.size)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background { BoardBackdrop(theme: theme, glow: reduceTransparency ? nil : board.glow.map(color)) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onChange(of: wanted, initial: true) { _, ids in reorder(ids) }
        .task(id: retryAt) {
            guard let at = retryAt else { return }
            // A little past the deadline, so an early wake has still passed it.
            let wait = at.timeIntervalSinceNow + 0.05
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            // The throttle holds the newest order asked for: this task may have started before it.
            if !Task.isCancelled { reorder(nil) }
        }
    }

    /// A new order from the board, or nil when the held reorder is due.
    private func reorder(_ ids: [String]?) {
        let now = Date()
        let r = ids.map { throttle.order(desired: $0, now: now) } ?? throttle.retry(now: now)
        if r.ids != order { order = r.ids }
        if r.retryAt != retryAt { retryAt = r.retryAt }
    }

    /// The tiles in the order on screen: the held order first, anything it doesn't know after.
    private func ordered(_ tiles: [AgentBoard.Tile]) -> [AgentBoard.Tile] {
        let byID = Dictionary(tiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let held = order.compactMap { byID[$0] }
        let known = Set(order)
        return held + tiles.filter { !known.contains($0.id) }
    }

    private func color(_ u: AgentBoard.Urgency) -> Color {
        switch u {
        case .waiting: theme.chrome.blocked
        case .error: theme.chrome.error
        case .working: theme.chrome.working
        case .done: theme.chrome.done
        default: theme.fg
        }
    }

    // MARK: Tiles

    @ViewBuilder
    private func busy(_ board: AgentBoard, _ layout: BoardLayout, _ size: CGSize) -> some View {
        let small = size.width < 340 || size.height < 480
        let area = BoardLayout.area(size, hasFooter: board.idleCount > 0, typeScale: tileScale, headScale: headScale)
        let frames = layout.frames(in: area)
        let tiles = Array(ordered(board.tiles).prefix(layout.shown))

        VStack(alignment: .leading, spacing: 2) {
            Text(board.headline)
                .font(.system(size: (small ? 32 : 40) * headScale, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(board.urgency == .waiting || board.urgency == .error ? color(board.urgency) : theme.fg)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(board.subline)
                .font(.system(size: 15 * headScale, weight: .medium))
                .foregroundStyle(theme.chrome.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(width: area.width, height: layout.headerHeight, alignment: .topLeading)
        .offset(x: BoardLayout.pad, y: BoardLayout.pad)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(board.subline.isEmpty ? board.headline : "\(board.headline). \(board.subline)")
        .accessibilityAddTraits(.isHeader)
        .accessibilitySortPriority(3)

        ZStack(alignment: .topLeading) {
            ForEach(Array(tiles.enumerated()), id: \.element.id) { i, tile in
                if i < frames.count {
                    let f = frames[i]
                    BoardTile(tile: tile, layout: layout, size: f.size, scale: tileScale, theme: theme,
                              still: reduceMotion) { onOpen(tile.agent) }
                        .frame(width: f.width, height: f.height)
                        .offset(x: f.minX, y: f.minY)
                        .transition(.opacity)
                }
            }
            if layout.more > 0, let f = frames.last {
                MoreTile(count: layout.more, scale: tileScale, theme: theme, action: onMore)
                    .frame(width: f.width, height: f.height)
                    .offset(x: f.minX, y: f.minY)
                    .transition(.opacity)
            }
        }
        // A reorder is a spring; a tile that comes or goes fades.
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.5, bounce: 0.15), value: tiles.map(\.id))
        .accessibilitySortPriority(2)

        if board.idleCount > 0 {
            Text("+\(board.idleCount) idle")
                .font(.system(size: 14 * tileScale, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(theme.chrome.secondary)
                .lineLimit(1)
                .frame(width: area.width, height: layout.footerHeight, alignment: .bottomLeading)
                .offset(x: BoardLayout.pad, y: size.height - BoardLayout.pad - layout.footerHeight)
                .accessibilityLabel("\(board.idleCount) idle")
                .accessibilitySortPriority(1)
        }
    }

    // MARK: Quiet

    /// Nobody at work: a desk clock, with what there is to say under it.
    private func quiet(_ board: AgentBoard, _ size: CGSize) -> some View {
        let small = size.width < 340 || size.height < 420
        return VStack(spacing: 6) {
            TimelineView(.everyMinute) { context in
                Text(context.date, style: .time)
                    .font(.system(size: (small ? 72 : 96) * min(headScale, 1.2), weight: .thin))
                    .monospacedDigit()
                    .foregroundStyle(theme.fg)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
            }
            .accessibilitySortPriority(1)
            Text(board.headline)
                .font(.system(size: (small ? 24 : 28) * headScale, weight: .semibold))
                .foregroundStyle(board.urgency == .quiet || board.urgency == .done ? theme.fg : theme.chrome.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
                .accessibilitySortPriority(3)
            if !board.subline.isEmpty {
                Text(board.subline)
                    .font(.system(size: 15 * headScale, weight: .medium))
                    .foregroundStyle(theme.chrome.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilitySortPriority(2)
            }
            if board.idleCount > 0 {
                Text("+\(board.idleCount) idle")
                    .font(.system(size: 15 * headScale, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(theme.chrome.tertiary)
                    .padding(.top, 4)
                    .accessibilityLabel("\(board.idleCount) idle")
            }
        }
        .padding(.horizontal, 24)
        .frame(width: size.width, height: size.height)
    }
}

/// The board's ground: the chrome's canvas color, and at its edges a soft glow in the color of
/// the most urgent state. No glow with Reduce Transparency, or when nobody waits, fails or works.
private struct BoardBackdrop: View {
    let theme: TermTheme
    let glow: Color?

    var body: some View {
        ZStack {
            theme.chrome.canvas
            if let glow {
                Rectangle()
                    .strokeBorder(glow, lineWidth: 14)
                    .blur(radius: 28)
                    .opacity(theme.isDark ? 0.6 : 0.32)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: glow)
        .compositingGroup()
        .clipped()
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

// MARK: - Tile

/// One agent: its glyph in a ring that shows its state, its name, the state in words, its last
/// message and where it runs. A tap opens its pane.
private struct BoardTile: View {
    let tile: AgentBoard.Tile
    let layout: BoardLayout
    let size: CGSize
    let scale: CGFloat
    let theme: TermTheme
    /// Reduce Motion: rings hold still.
    let still: Bool
    let action: () -> Void

    private var agent: BoardAgent { tile.agent }

    private var stateColor: Color {
        switch agent.state {
        case "blocked": theme.chrome.blocked
        case "error": theme.chrome.error
        case "working": theme.chrome.working
        case "done": theme.chrome.done
        default: theme.chrome.tertiary
        }
    }

    private var place: String {
        [tile.machineName ?? "", agent.place].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        Button(action: action) {
            content
                .frame(width: size.width, height: size.height)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(theme.chrome.sidebar))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(border, lineWidth: borderWidth))
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(BoardTileStyle())
        // Last known, not current: dimmed like a down machine's rows in the sidebar.
        .opacity(tile.stale ? 0.45 : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([agent.name, agent.stateText.lowercased(), agent.place, tile.machineName ?? ""]
            + (tile.stale ? ["last known"] : [])).filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityValue(agent.message ?? "")
        .accessibilityHint("Opens the pane.")
    }

    private var border: Color {
        switch agent.state {
        case "blocked": theme.chrome.blocked.opacity(0.55)
        case "error": theme.chrome.error.opacity(0.5)
        default: theme.chrome.divider
        }
    }

    private var borderWidth: CGFloat { agent.state == "blocked" || agent.state == "error" ? 1.5 : 1 }

    @ViewBuilder private var content: some View {
        switch layout.style {
        case .hero: hero
        case .regular: regular
        default: compact
        }
    }

    private func ring(_ d: CGFloat) -> some View {
        BoardRing(state: agent.state, progress: agent.progress, symbol: agent.kind?.symbol ?? "cpu",
                  tint: TabRowLabel.tint(agent.kind, theme), color: stateColor, ground: theme.chrome.sidebar,
                  diameter: d, still: still || tile.stale)
    }

    private func name(_ pt: CGFloat) -> some View {
        Text(agent.name)
            .font(.system(size: pt * scale, weight: .semibold))
            .foregroundStyle(theme.fg)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
    }

    /// The state in words, and for a waiting agent how long it has waited.
    /// Only such a tile keeps a clock, which ticks every 20 s.
    @ViewBuilder
    private func state(_ pt: CGFloat) -> some View {
        if let since = agent.waitingSince, !tile.stale {
            TimelineView(.periodic(from: .now, by: 20)) { context in
                stateText(pt, waited: AgentBoard.elapsed(context.date.timeIntervalSince(since)))
            }
        } else {
            stateText(pt, waited: nil)
        }
    }

    private func stateText(_ pt: CGFloat, waited: String?) -> some View {
        Group {
            // The time goes before the words shrink.
            ViewThatFits(in: .horizontal) {
                if let waited { Text("\(agent.stateText) · \(waited)") }
                Text(agent.stateText)
                Text(agent.stateText).minimumScaleFactor(0.7)
            }
            .font(.system(size: pt * scale, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(stateColor)
            .lineLimit(1)
        }
    }

    @ViewBuilder
    private func message(_ pt: CGFloat, lines: Int) -> some View {
        if lines > 0, let m = agent.message, !m.isEmpty {
            Text(m)
                .font(.system(size: pt * scale))
                .foregroundStyle(theme.fg.opacity(0.8))
                .lineLimit(lines)
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder
    private func placeLine(_ pt: CGFloat) -> some View {
        if !place.isEmpty {
            Text(place)
                .font(.system(size: pt * scale))
                .foregroundStyle(theme.chrome.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// One agent: everything large, side by side in a wide window, stacked in a tall one.
    @ViewBuilder private var hero: some View {
        let wide = size.width > size.height * 1.25
        let d: CGFloat = min(120, size.height * 0.42, size.width * 0.34)
        if wide {
            HStack(alignment: .center, spacing: 28) {
                ring(d)
                VStack(alignment: .leading, spacing: 6) {
                    name(34)
                    state(24)
                    message(20, lines: 3).padding(.top, 4)
                    placeLine(15).padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(28)
        } else {
            VStack(alignment: .center, spacing: 8) {
                Spacer(minLength: 0)
                ring(d).padding(.bottom, 14)
                name(34)
                state(24)
                if let m = agent.message, !m.isEmpty {
                    Text(m)
                        .font(.system(size: 20 * scale))
                        .foregroundStyle(theme.fg.opacity(0.8))
                        .lineLimit(4)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                }
                Spacer(minLength: 0)
                placeLine(15)
            }
            .padding(24)
        }
    }

    /// Up to four agents: a tile with room for two lines of message.
    @ViewBuilder private var regular: some View {
        let wide = size.width >= size.height * 1.3
        if wide {
            HStack(alignment: .top, spacing: 16) {
                ring(56)
                VStack(alignment: .leading, spacing: 3) {
                    name(22)
                    state(17)
                    message(15, lines: 2).padding(.top, 3)
                    Spacer(minLength: 0)
                    placeLine(13)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        } else {
            VStack(alignment: .leading, spacing: 3) {
                ring(56).padding(.bottom, 9)
                name(22)
                state(17)
                message(15, lines: size.height >= 240 ? 3 : 2).padding(.top, 3)
                Spacer(minLength: 0)
                placeLine(13)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    /// Five and up: the ring beside the name and state, then what fits of the rest.
    private var compact: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ring(36)
                VStack(alignment: .leading, spacing: 1) {
                    name(17)
                    state(13)
                }
            }
            message(13, lines: layout.messageLines)
            if layout.showsPlace {
                Spacer(minLength: 0)
                placeLine(11)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: layout.messageLines == 0 ? .leading : .topLeading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// A pressed tile dims a little.
private struct BoardTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The agents that don't fit: how many, and a tap lists them all in the sidebar.
private struct MoreTile: View {
    let count: Int
    let scale: CGFloat
    let theme: TermTheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("+\(count)")
                    .font(.system(size: 28 * scale, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(theme.fg)
                Text("more")
                    .font(.system(size: 15 * scale, weight: .medium))
                    .foregroundStyle(theme.chrome.secondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(theme.chrome.tertiary, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(BoardTileStyle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(count == 1 ? "1 more agent" : "\(count) more agents")
        .accessibilityHint("Lists every agent in the sidebar.")
    }
}

// MARK: - Ring

/// The agent's glyph in a ring that shows its state, with a small badge that says it without
/// color: working, an arc that turns slowly (or fills to its progress); waiting, a solid ring
/// that breathes, and a raised hand; done, a full ring and a check; error, a full ring and an x.
/// `still` (Reduce Motion, a stale tile) stops the turning and the breathing.
struct BoardRing: View {
    let state: String?
    let progress: Int?
    let symbol: String
    let tint: Color
    let color: Color
    /// The color behind the ring, for the badge's rim.
    let ground: Color
    let diameter: CGFloat
    let still: Bool

    @State private var turning = false
    @State private var breathing = false

    private var line: CGFloat { max(3, diameter * 0.075) }

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.22), lineWidth: line)
            arc
            Image(systemName: symbol)
                .font(.system(size: diameter * 0.38, weight: .bold))
                .foregroundStyle(tint)
        }
        .padding(line / 2)
        .frame(width: diameter, height: diameter)
        .overlay(alignment: .bottomTrailing) { badge }
        .accessibilityHidden(true)
    }

    @ViewBuilder private var arc: some View {
        let style = StrokeStyle(lineWidth: line, lineCap: .round)
        switch state {
        case "working":
            if let p = progress {
                Circle().trim(from: 0, to: CGFloat(min(max(p, 2), 100)) / 100)
                    .stroke(color, style: style)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: p)
            } else {
                Circle().trim(from: 0, to: 0.28)
                    .stroke(color, style: style)
                    .rotationEffect(.degrees(turning && !still ? 270 : -90))
                    .animation(still ? nil : .linear(duration: 6).repeatForever(autoreverses: false), value: turning)
                    .onAppear { turning = true }
            }
        case "blocked":
            Circle().stroke(color, lineWidth: line)
                .opacity(breathing && !still ? 0.4 : 1)
                .animation(still ? nil : .easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: breathing)
                .onAppear { breathing = true }
        case "done", "error":
            Circle().stroke(color, lineWidth: line)
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var badge: some View {
        let glyph: String? = switch state {
        case "blocked": "hand.raised.fill"
        case "done": "checkmark"
        case "error": "xmark"
        default: nil
        }
        if let glyph {
            let d = max(15, diameter * 0.36)
            Image(systemName: glyph)
                .font(.system(size: d * 0.52, weight: .heavy))
                .foregroundStyle(ground)
                .frame(width: d, height: d)
                .background(Circle().fill(color))
                .overlay(Circle().strokeBorder(ground, lineWidth: max(1.5, d * 0.1)))
                .offset(x: d * 0.18, y: d * 0.18)
        }
    }
}
