import SwiftUI

/// The session chip's popover, drawn from its `SessionPopover`: every row in one scroll view.
/// It reports the action of the row, the heading's button or the menu row that was tapped.
///
/// In the title menu's style (`TabMenu`): machines as quiet headings with their connection's
/// dot, their sessions as compact rows under the name with the current one filled as the
/// sidebar's selected row, then, past a divider, the places the sidebar otherwise leads to.
struct SessionPopoverView: View {
    let popover: SessionPopover
    let theme: TermTheme
    let onAction: (SessionPopover.Action) -> Void

    @ScaledMetric(relativeTo: .body) private var width = StripStyle.popoverWidth
    @ScaledMetric(relativeTo: .body) private var iconColumn: CGFloat = 24
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The rows' own height. A scroll view asks for all the height it is offered, so the
    /// popover asks for this instead, and takes less (and scrolls) where the window is shorter.
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(popover.rows) { row in
                    self.row(row)
                }
            }
            .padding(.vertical, 6)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .modifier(NoScrollEdgeEffect())
        .frame(width: min(width, StripStyle.popoverMaxWidth))
        .frame(minHeight: 0, idealHeight: contentHeight > 0 ? min(contentHeight, StripStyle.popoverMaxHeight) : nil,
               maxHeight: StripStyle.popoverMaxHeight)
        .foregroundStyle(theme.fg)
        .modifier(PopoverSurface(fill: theme.chrome.sidebar))
    }

    /// Names keep one line, two at the accessibility sizes, where one holds a few letters.
    private var lines: Int { typeSize.isAccessibilitySize ? 2 : 1 }

    @ViewBuilder
    private func row(_ row: SessionPopover.Row) -> some View {
        switch row {
        case .machine(let m): machine(m)
        case .session(let s): session(s)
        case .empty:
            Text("No sessions")
                .font(.footnote)
                .foregroundStyle(theme.chrome.tertiary)
                .padding(.leading, StripStyle.sessionInset)
                .frame(minHeight: StripStyle.headingHeight)
        case .notAdded:
            Text("Not Added")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.chrome.secondary)
                .padding(.leading, StripStyle.rowInset)
                .padding(.top, 8)
                .frame(minHeight: StripStyle.headingHeight, alignment: .bottomLeading)
                .accessibilityAddTraits(.isHeader)
        case .host(let h): host(h)
        case .footer(let f): footer(f)
        }
    }

    // MARK: Machines and sessions

    private func machine(_ m: SessionPopover.Machine) -> some View {
        HStack(spacing: 6) {
            StatusMark(status: m.status, theme: theme)
                .frame(width: 10)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.name)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(theme.chrome.secondary)
                    .lineLimit(lines)
                if m.status != .connected {
                    Text(m.status.spoken)
                        .font(.caption2)
                        .foregroundStyle(theme.chrome.tertiary)
                        .lineLimit(lines)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            if let ports = m.ports {
                Button { onAction(ports) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "globe").font(.caption.weight(.semibold))
                        Text("\(m.portCount)").font(.caption.weight(.medium)).monospacedDigit()
                    }
                    .foregroundStyle(theme.chrome.secondary)
                    .opacity(m.status.isDown ? 0.45 : 1)
                    .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(MachinePortsButton.spoken(m.portCount, machine: m.name))
            }
            if let reconnect = m.reconnect {
                headingButton(SessionPopover.title(reconnect) ?? "", symbol: "arrow.clockwise", action: reconnect)
            }
            if let add = m.newSession {
                headingButton("New Session on \(m.name)", symbol: "plus", action: add)
            }
        }
        .padding(.leading, StripStyle.rowInset)
        .padding(.trailing, 4)
        .padding(.top, 4)
        .frame(minHeight: StripStyle.rowHeight)
    }

    private func session(_ s: SessionPopover.Session) -> some View {
        let shape = RoundedRectangle(cornerRadius: StripStyle.highlightRadius, style: .continuous)
        return Button { if let open = s.open { onAction(open) } } label: {
            HStack(spacing: 8) {
                Text(s.name)
                    .font(.subheadline.weight(s.current ? .semibold : .regular))
                    .lineLimit(lines)
                if s.waiting > 0 {
                    Circle().fill(theme.chrome.blocked)
                        .frame(width: StripStyle.waitingDot, height: StripStyle.waitingDot)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 4)
            }
            .padding(.leading, StripStyle.sessionInset - StripStyle.highlightInset)
            .padding(.trailing, StripStyle.rowInset - StripStyle.highlightInset)
            .frame(minHeight: StripStyle.rowHeight)
            .background(shape.fill(s.current ? theme.chrome.rowSelected : .clear))
            .contentShape(shape)
            .opacity(s.dim ? 0.55 : 1)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, StripStyle.highlightInset)
        .disabled(s.open == nil)
        .contentShape(.contextMenuPreview, shape)
        .contextMenu {
            ForEach(Array(s.menu.enumerated()), id: \.offset) { _, action in
                menuButton(action)
            }
        }
        .accessibilityLabel(spoken(s))
        .accessibilityHint(OfflineCopy.tapHint(down: s.dim, otherComputer: s.retries) ?? "")
        .accessibilityAddTraits(s.current ? .isSelected : [])
        .accessibilityActions {
            ForEach(Array(s.menu.enumerated()), id: \.offset) { _, action in
                Button(SessionPopover.title(action) ?? "") { onAction(action) }
            }
        }
    }

    private func spoken(_ s: SessionPopover.Session) -> String {
        var parts = [s.name]
        if s.waiting > 0 { parts.append(s.waiting == 1 ? "1 agent waiting" : "\(s.waiting) agents waiting") }
        if s.dim { parts.append("offline") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private func menuButton(_ action: SessionPopover.Action) -> some View {
        let title = SessionPopover.title(action) ?? ""
        switch action {
        case .closeSession:
            Button(role: .destructive) { onAction(action) } label: { Label(title, systemImage: "xmark") }
        case .renameSession:
            Button { onAction(action) } label: { Label(title, systemImage: "pencil") }
        default:
            Button(title) { onAction(action) }
        }
    }

    private func headingButton(_ label: String, symbol: String, action: SessionPopover.Action) -> some View {
        Button { onAction(action) } label: {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.chrome.secondary)
        .accessibilityLabel(label)
    }

    // MARK: Not added

    private func host(_ h: KnownHost) -> some View {
        HStack(spacing: 8) {
            Text(h.label)
                .font(.subheadline)
                .foregroundStyle(theme.chrome.secondary)
                .lineLimit(lines)
            Spacer(minLength: 4)
            Button { onAction(.add(h)) } label: {
                Text(SessionPopover.title(.add(h)) ?? "")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(theme.accent)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.accent.opacity(0.15)))
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add \(h.label)")
        }
        .padding(.leading, StripStyle.sessionInset)
        .padding(.trailing, 12)
    }

    // MARK: Footer

    @ViewBuilder
    private func footer(_ f: SessionPopover.Footer) -> some View {
        // The popover names rows by `Row.id`, not the footer's own id.
        if SessionPopover.Row.footer(f).id == popover.firstFooterID {
            Rectangle().fill(theme.chrome.divider).frame(height: 1)
                .padding(.vertical, 6)
                .accessibilityHidden(true)
        }
        Button { onAction(f.action) } label: {
            HStack(spacing: 10) {
                Image(systemName: f.symbol)
                    .font(.body)
                    .foregroundStyle(theme.chrome.secondary)
                    .frame(width: iconColumn)
                Text(f.title)
                    .font(.subheadline)
                    .lineLimit(lines)
                Spacer(minLength: 4)
                if f.count > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "hand.raised.fill").font(.system(size: 10, weight: .semibold))
                        Text("\(f.count)").font(.caption.weight(.bold)).monospacedDigit()
                    }
                    .foregroundStyle(theme.chrome.blocked)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.chrome.blocked.opacity(0.18)))
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, StripStyle.rowInset - 4)
            .frame(minHeight: StripStyle.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(f.count > 0 ? "\(f.title), \(f.count) waiting" : f.title)
    }
}

/// The popover has no bar for its rows to pass under, so the system's soft edge would only blur
/// the first heading.
private struct NoScrollEdgeEffect: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectHidden(true, for: .all)
        } else {
            content
        }
    }
}

/// A popover's surface: the session chip's, the title menu's and a computer's ports. From iOS
/// 26 the system draws a popover as glass, arrow and all, and puts the content under the arrow:
/// a fill of ours would sit inside that glass with corners of its own and leave the arrow and a
/// rim of glass showing. So the glass is the surface there, as the system's menus and the
/// Mac's popovers are. Before, the popover is a plain shape that the sidebar's color fills,
/// arrow included.
struct PopoverSurface: ViewModifier {
    let fill: Color

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
        } else {
            content.presentationBackground(fill)
        }
    }
}

/// A machine's connection beside its name, as the sidebar's `ConnectionDot` draws it: a green
/// dot connected, the same dot grey and still while waking, a spinner while connecting, a
/// crossed antenna down.
private struct StatusMark: View {
    let status: SessionPopover.Status
    let theme: TermTheme

    var body: some View {
        switch status {
        case .connected:
            dot(theme.chrome.done)
        case .waking:
            dot(theme.chrome.tertiary)
        case .connecting, .down(_, retrying: true):
            ProgressView().controlSize(.mini)
        case .down:
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(theme.chrome.tertiary)
        }
    }

    private func dot(_ c: Color) -> some View {
        Circle().fill(c).frame(width: StripStyle.statusDot, height: StripStyle.statusDot)
    }
}

#if DEBUG
#Preview("Session popover") {
    let a = UUID(), b = UUID()
    let popover = SessionPopover(machines: [
        .init(id: a, name: "studio", platform: "darwin", status: .connected,
              sessions: [.init(id: "1", name: "pteron", tab: "w1", waiting: 1), .init(id: "2", name: "rex", tab: "w2")]),
        .init(id: b, name: "workdesk", platform: "linux", status: .down("Not answering"),
              sessions: [.init(id: "3", name: "agents", tab: "w3")]),
    ], current: Selection(serverID: a, sessionID: "1", windowID: "w1"), waiting: 1)
    SessionPopoverView(popover: popover, theme: ThemeStore.fallback) { _ in }
        .background(ThemeStore.fallback.chrome.sidebar)
}
#endif
