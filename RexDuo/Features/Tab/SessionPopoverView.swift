import SwiftUI

/// The session chip's popover, drawn from its `SessionPopover`: every row in one scroll view.
/// It reports the action of the row, the heading's button or the menu row that was tapped.
struct SessionPopoverView: View {
    let popover: SessionPopover
    let theme: TermTheme
    let onAction: (SessionPopover.Action) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(popover.rows) { row in
                    self.row(row)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(width: 300)
        .frame(maxHeight: 480)
        .foregroundStyle(theme.fg)
        .presentationBackground(theme.chrome.sidebar)
    }

    @ViewBuilder
    private func row(_ row: SessionPopover.Row) -> some View {
        switch row {
        case .machine(let m):
            HStack(spacing: 8) {
                Image(systemName: MachineGlyph.symbol(platform: m.platform))
                    .foregroundStyle(theme.chrome.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.name).font(.headline).lineLimit(1)
                    if m.status != .connected {
                        Text(m.status.spoken).font(.caption2).foregroundStyle(theme.chrome.tertiary).lineLimit(1)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                if let reconnect = m.reconnect {
                    button(SessionPopover.title(reconnect) ?? "", symbol: "arrow.clockwise", action: reconnect)
                }
                if let add = m.newSession {
                    button("New Session on \(m.name)", symbol: "plus", action: add)
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 4)
            .frame(minHeight: 44)
        case .session(let s):
            Button { if let open = s.open { onAction(open) } } label: {
                HStack(spacing: 8) {
                    Text(s.name).lineLimit(1)
                    if s.waiting > 0 {
                        Circle().fill(theme.chrome.blocked).frame(width: 6, height: 6)
                            .accessibilityLabel(s.waiting == 1 ? "1 agent waiting" : "\(s.waiting) agents waiting")
                    }
                    Spacer(minLength: 4)
                    if s.current {
                        Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.accent)
                    }
                }
                .padding(.leading, 40)
                .padding(.trailing, 16)
                .frame(minHeight: 44)
                .background(s.current ? theme.chrome.rowSelected : .clear)
                .contentShape(Rectangle())
                .opacity(s.dim ? 0.55 : 1)
            }
            .buttonStyle(.plain)
            .disabled(s.open == nil)
            .accessibilityAddTraits(s.current ? .isSelected : [])
            .contextMenu {
                ForEach(Array(s.menu.enumerated()), id: \.offset) { _, action in
                    Button(SessionPopover.title(action) ?? "") { onAction(action) }
                }
            }
        case .empty:
            Text("No sessions")
                .font(.subheadline)
                .foregroundStyle(theme.chrome.tertiary)
                .padding(.leading, 40)
                .frame(minHeight: 36)
        case .notAdded:
            Text("Not added")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.chrome.tertiary)
                .padding(.horizontal, 16)
                .frame(minHeight: 32, alignment: .bottomLeading)
                .accessibilityAddTraits(.isHeader)
        case .host(let h):
            HStack(spacing: 8) {
                Image(systemName: "desktopcomputer").foregroundStyle(theme.chrome.tertiary).accessibilityHidden(true)
                Text(h.label).foregroundStyle(theme.chrome.secondary).lineLimit(1)
                Spacer(minLength: 4)
                Button(SessionPopover.title(.add(h)) ?? "") { onAction(.add(h)) }
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Add \(h.label)")
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
        case .footer(let f):
            if f.id == popover.firstFooterID {
                Divider().overlay(theme.chrome.divider).padding(.vertical, 6)
            }
            Button { onAction(f.action) } label: {
                HStack(spacing: 12) {
                    Image(systemName: f.symbol).frame(width: 22)
                    Text(f.title)
                    Spacer()
                    if f.count > 0 {
                        Text("\(f.count)").font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(theme.chrome.blocked)
                    }
                }
                .padding(.horizontal, 16)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func button(_ label: String, symbol: String, action: SessionPopover.Action) -> some View {
        Button { onAction(action) } label: {
            Image(systemName: symbol)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.chrome.secondary)
        .accessibilityLabel(label)
    }
}
