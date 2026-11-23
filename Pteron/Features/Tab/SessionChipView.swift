import SwiftUI

/// The session chip at the strip's start, drawn from its `SessionChip`: the session's name, or
/// a glyph in a narrow strip, and a dot while agents wait there. A tap opens the sessions.
///
/// It reads as the Mac's title: the name at the title's weight with a small chevron that says it
/// opens, the machine under it where the bar is tall enough and more than one is set up, and a
/// hairline at its end that sets it apart from the session's tabs.
struct SessionChipView: View {
    let chip: SessionChip
    let theme: TermTheme
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            content
                .padding(.horizontal, chip.form == .name ? 6 : 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: chip.form == .name ? .leading : .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(ChipPressStyle(theme: theme))
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(theme.chrome.divider)
                .frame(width: 1, height: StripStyle.separatorHeight)
                .accessibilityHidden(true)
        }
        .dynamicTypeSize(...StripStyle.chipTypeLimit)
        .accessibilityLabel(chip.spoken)
        .accessibilityHint(SessionChip.hint)
    }

    @ViewBuilder
    private var content: some View {
        switch chip.form {
        case .name:
            if let machine = chip.machine {
                // Two lines where the bar holds them, as the title bar's subtitle; one in a short bar.
                ViewThatFits(in: .vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        nameLine
                        Text(machine)
                            .font(.caption2)
                            .foregroundStyle(theme.chrome.tertiary)
                            .lineLimit(1)
                    }
                    // Room above and below, so a short (34 pt) bar takes the one line.
                    .padding(.vertical, 4)
                    nameLine
                }
            } else {
                nameLine
            }
        case .glyph:
            Image(systemName: "rectangle.stack")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(theme.chrome.secondary)
                .overlay(alignment: .topTrailing) {
                    if chip.waiting > 0 { dot.offset(x: 4, y: -3) }
                }
        }
    }

    private var nameLine: some View {
        HStack(spacing: 4) {
            Text(chip.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .layoutPriority(1)
            // The dot keeps its room while no agent waits: the strip sizes the chip to its
            // content, and a dot that came and went would move the tabs beside it.
            dot.opacity(chip.waiting > 0 ? 1 : 0)
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(theme.chrome.tertiary)
        }
    }

    private var dot: some View {
        Circle().fill(theme.chrome.blocked).frame(width: StripStyle.waitingDot, height: StripStyle.waitingDot)
    }
}

#if DEBUG
#Preview("Session chip") {
    let theme = ThemeStore.fallback
    HStack(spacing: StripLayout.gap) {
        SessionChipView(chip: SessionChip(name: "pteron", machine: "studio", waiting: 2), theme: theme) {}
            .frame(width: StripLayout.sessionMax)
        SessionChipView(chip: SessionChip(name: "work", machine: nil, waiting: 0), theme: theme) {}
            .frame(width: StripLayout.sessionMax)
        SessionChipView(chip: SessionChip(name: "work", machine: nil, waiting: 1, form: .glyph), theme: theme) {}
            .frame(width: StripLayout.hit)
    }
    .frame(height: 44)
    .background(theme.chrome.canvas)
}
#endif
