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
                    ForEach(chip.menu, id: \.self) { action in
                        Button(action.title) { onAction(action) }
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
                HStack(spacing: StripStyle.iconSpacing) {
                    ForEach(Array(chip.icons.enumerated()), id: \.offset) { _, icon in
                        ZStack {
                            TabRowLabel.tile(icon.agent).fill(TabRowLabel.tint(icon.agent, theme).opacity(0.9))
                            Image(systemName: icon.agent?.symbol ?? "terminal")
                                .font(.system(size: StripStyle.iconGlyph, weight: .bold))
                                .foregroundStyle(theme.bg)
                        }
                        .frame(width: StripStyle.iconSize, height: StripStyle.iconSize)
                    }
                }
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
            TabChipView(chip: TabChip(id: "2", title: "~/code/pteron/RexDuo/Features", active: false, position: 2, count: 4,
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
