import SwiftUI

/// The session chip at the strip's start, drawn from its `SessionChip`: the session's name, or
/// a glyph in a narrow strip, and a dot while agents wait there. A tap opens the sessions.
struct SessionChipView: View {
    let chip: SessionChip
    let theme: TermTheme
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                switch chip.form {
                case .name:
                    Text(chip.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(theme.chrome.tertiary)
                case .glyph:
                    Image(systemName: "rectangle.stack")
                }
                if chip.waiting > 0 {
                    Circle().fill(theme.chrome.blocked).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(chip.spoken)
        .accessibilityHint(SessionChip.hint)
    }
}
