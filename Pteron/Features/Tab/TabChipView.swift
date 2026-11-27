import GlanceUI
import SwiftUI
import RexKit

/// One tab chip of the strip, drawn from its `TabChip`. It reports a tap, and an action from
/// its close button or its menu; the strip gives it its width.
///
/// As the Mac app's horizontal tabs: the active tab is a quiet filled capsule with its title at
/// the title bar's weight and its close button; every other tab is its icons and a quieter title,
/// with no fill until it is pressed. Sizes and colors are in `StripStyle`.
struct TabChipView: View {
    let chip: TabChip
    let theme: TermTheme
    let onTap: () -> Void
    let onAction: (TabChip.Action) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) { label }
                .buttonStyle(ChipPressStyle(theme: theme, selected: chip.active))
                .accessibilityLabel(chip.spoken)
                .accessibilityAddTraits(chip.active ? .isSelected : [])
                .accessibilityActions {
                    ForEach(chip.spokenActions) { a in
                        Button(a.title) { onAction(a.action) }
                    }
                }
            if chip.showsClose { close }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if chip.active { ChipCapsule().fill(StripStyle.selectedFill(theme)) }
        }
        .contentShape(.contextMenuPreview, ChipCapsule())
        .contextMenu {
            ForEach(chip.menu, id: \.self) { action in
                if action == .close {
                    // Before Close Tab, as in the sidebar's tab menu.
                    MoveToSessionMenu(choices: chip.moves) { onAction(.moveToSession($0)) }
                }
                Button(role: action.destructive ? .destructive : nil) { onAction(action) } label: {
                    Label(action.title, systemImage: action.symbol)
                }
            }
        }
        .dynamicTypeSize(...StripStyle.chipTypeLimit)
        .modifier(ScrollEdgeFade())
    }

    /// Icons, title, status: the sidebar row's order, in one line.
    private var label: some View {
        HStack(spacing: StripStyle.chipSpacing) {
            if !chip.icons.isEmpty {
                PaneStack(icons: chip.icons, scope: chip.stackScope, theme: theme)
                    .opacity(chip.active ? 1 : StripStyle.inactiveIconOpacity)
                    .fixedSize()
            }
            title
                .layoutPriority(1)
            Group {
                switch chip.badge {
                case .status(let state): StatusBadge(state: state, theme: theme)
                case .ring(let progress): ProgressRing(progress: progress, theme: theme)
                }
                if chip.waking { WakingMark() }
            }
            .fixedSize()
            .layoutPriority(2)
        }
        .padding(.leading, StripStyle.chipPadding)
        // The close button brings its own room.
        .padding(.trailing, chip.showsClose ? 0 : StripStyle.chipPadding)
        .frame(minWidth: StripLayout.chipMin, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    /// The active chip's title takes what the chip has; any other is cut at `inactiveTitleMax`.
    private var title: some View {
        CappedWidth(max: chip.active ? .infinity : StripLayout.inactiveTitleMax) {
            Text(chip.title)
                .font(StripStyle.titleFont(active: chip.active))
                .foregroundStyle(StripStyle.titleColor(active: chip.active, theme))
                .lineLimit(1)
                // A path keeps both ends; a name keeps its start, as the title bar's.
                .truncationMode(chip.title.contains("/") ? .middle : .tail)
        }
    }

    /// The × at the chip's end: a small glyph in a full-height hit target.
    private var close: some View {
        Button { onAction(.close) } label: {
            Image(systemName: TabChip.Action.close.symbol)
                .font(.system(size: StripStyle.closeGlyph, weight: .semibold))
                .foregroundStyle(theme.chrome.secondary)
                .frame(width: StripLayout.hit)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(TabChip.Action.close.title)
    }
}

/// A chip's pane icons as a deck: the active pane's in front at full size, each other one
/// behind it smaller and dimmer, a step further right and up (`StripStyle.stackStep`), with a
/// thin cutout around the icon over it so the chip's own fill shows between the two.
///
/// A new front pane on the same chip moves the icons: the new front comes forward and the old
/// one goes back in a short spring. Anything else shows the new order at once: a tab switch,
/// the first draw, a relayout (`TabChip.stackMoves`). Reduce Motion crossfades instead. The
/// motion is a transaction on the front pane's id changing, so nothing runs while it rests.
struct PaneStack: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    #if DEBUG
    @Environment(\.paneStackProbe) private var probe
    #endif
    let icons: [TabChip.Icon]
    /// The chip's tab and role: when either changes, the stack doesn't move.
    let scope: TabChip.StackScope
    let theme: TermTheme

    var body: some View {
        let front = icons.first?.id
        ZStack(alignment: .topLeading) {
            if reduceMotion {
                // A new deck for each front pane, so the change is a fade and nothing moves.
                deck.id(front).transition(.opacity)
            } else {
                deck
            }
        }
        .frame(width: StripStyle.stackWidth(icons.count), height: StripStyle.iconSize, alignment: .topLeading)
        #if DEBUG
        // Innermost, so it sees the transaction the two below leave.
        .transaction(value: front) { [probe] in probe?.record($0.animation) }
        #endif
        // Applied after the motion below: a new scope takes it away again.
        .transaction(value: scope) { $0.animation = nil }
        .animation(reduceMotion ? StripStyle.stackFade : StripStyle.stackMotion, value: front)
    }

    /// The icons, the front one drawn last. Each one's cutout clears what the icons behind it
    /// drew there; the group keeps the clearing to the stack.
    private var deck: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(icons.enumerated()), id: \.element.id) { slot, icon in
                PaneIcon(agent: icon.agent, theme: theme, opacity: StripStyle.stackOpacities[slot])
                    .scaleEffect(StripStyle.stackScales[slot], anchor: .topTrailing)
                    .offset(x: StripStyle.stackStep * CGFloat(slot), y: -StripStyle.stackRise * CGFloat(slot))
                    .zIndex(Double(icons.count - slot))
            }
        }
        .compositingGroup()
    }
}

/// One pane's icon in the stack: the sidebar's tile in small, with its cutout.
private struct PaneIcon: View {
    let agent: AgentKind?
    let theme: TermTheme
    let opacity: Double

    var body: some View {
        ZStack {
            TabRowLabel.tile(agent)
                .fill(.black)
                .padding(-StripStyle.stackRing)
                .blendMode(.destinationOut)
            ZStack {
                TabRowLabel.tile(agent).fill(TabRowLabel.tint(agent, theme).opacity(0.9))
                AgentGlyph.image(agent: agent)
                    .font(.system(size: StripStyle.iconGlyph, weight: .bold))
                    .foregroundStyle(theme.bg)
            }
            .compositingGroup()
            .opacity(opacity)
        }
        .frame(width: StripStyle.iconSize, height: StripStyle.iconSize)
    }
}

#if DEBUG
/// Tests: whether each change of a `PaneStack`'s front pane carried an animation.
@MainActor
final class PaneStackProbe {
    private(set) var moves: [Bool] = []

    func record(_ animation: Animation?) { moves.append(animation != nil) }
}

extension EnvironmentValues {
    @Entry var paneStackProbe: PaneStackProbe? = nil
}
#endif

/// Lays its content out at most `max` wide, so a title truncates there and its chip is only as
/// wide as the text. A frame's `maxWidth` alone lets a title laid out with no width proposed (in
/// the strip's scroll view) spill past the cap instead of truncating.
struct CappedWidth: Layout {
    var max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let s = subviews.first else { return .zero }
        return s.sizeThatFits(capped(proposal))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }

    private func capped(_ p: ProposedViewSize) -> ProposedViewSize {
        let w = p.width.map { Swift.min($0, max) } ?? (max.isFinite ? max : nil)
        return ProposedViewSize(width: w, height: p.height)
    }
}

#if DEBUG
#Preview("Tab chips") {
    let theme = ThemeStore.fallback
    let strip = StripLayout(.init(width: 402))
    ScrollView(.horizontal) {
        HStack(spacing: StripLayout.gap) {
            TabChipView(chip: TabChip(id: "1", title: "claude", active: true, position: 1, count: 4,
                                      panes: [.claude, nil], status: "working", strip: strip),
                        theme: theme, onTap: {}, onAction: { _ in })
            TabChipView(chip: TabChip(id: "2", title: "~/code/pteron/Pteron/Features", active: false, position: 2, count: 4,
                                      panes: [nil], status: "blocked"),
                        theme: theme, onTap: {}, onAction: { _ in })
            TabChipView(chip: TabChip(id: "3", title: "build", active: false, position: 3, count: 4,
                                      panes: [nil, nil, .codex], status: nil,
                                      progress: [TermProgress(state: .set, percent: 40)]),
                        theme: theme, onTap: {}, onAction: { _ in })
        }
    }
    .frame(height: 44)
    .background(theme.chrome.canvas)
}
#endif
