import SwiftUI

/// One tab chip of the strip, drawn from its `TabChip`. It reports a tap, and an action from
/// its close button or its menu; the strip gives it its width.
struct TabChipView: View {
    let chip: TabChip
    let theme: TermTheme
    let onTap: () -> Void
    let onAction: (TabChip.Action) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onTap) { label }
                .buttonStyle(.plain)
                .accessibilityLabel(chip.spoken)
                .accessibilityAddTraits(chip.active ? .isSelected : [])
            if chip.showsClose {
                Button { onAction(.close) } label: {
                    Image(systemName: TabChip.Action.close.symbol)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(theme.chrome.secondary)
                        .frame(width: StripLayout.hit)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(TabChip.Action.close.title)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(chip.active ? theme.chrome.rowSelected : .clear).padding(.vertical, 4))
        .contextMenu {
            ForEach(chip.menu, id: \.self) { action in
                Button(role: action.destructive ? .destructive : nil) { onAction(action) } label: {
                    Label(action.title, systemImage: action.symbol)
                }
            }
        }
    }

    private var label: some View {
        HStack(spacing: 5) {
            ForEach(Array(chip.icons.enumerated()), id: \.offset) { _, icon in
                ZStack {
                    TabRowLabel.tile(icon.agent).fill(TabRowLabel.tint(icon.agent, theme).opacity(0.9))
                    Image(systemName: icon.agent?.symbol ?? "terminal")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(theme.bg)
                }
                .frame(width: 14, height: 14)
            }
            title
            switch chip.badge {
            case .status(let state): StatusBadge(state: state, theme: theme)
            case .ring(let progress): ProgressRing(progress: progress, theme: theme)
            }
            if chip.waking { WakingMark() }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: StripLayout.chipMin, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    /// The active chip's title takes what the chip has; any other is cut at `inactiveTitleMax`.
    @ViewBuilder
    private var title: some View {
        let text = Text(chip.title)
            .font(.subheadline.weight(chip.active ? .semibold : .regular))
            .lineLimit(1)
            .truncationMode(chip.title.contains("/") ? .middle : .tail)
        if chip.active {
            text
        } else {
            text.frame(maxWidth: StripLayout.inactiveTitleMax).fixedSize()
        }
    }
}
