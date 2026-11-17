import SwiftUI

/// Computers that a connected server lists in `hosts.list` but that aren't saved here
/// (`KnownHost.unsaved`), each with an Add button. Add opens the pairing identity card for that
/// host's address, as if its code had been scanned. `hosts.list` mostly gives ssh:// endpoints, so
/// the address is often worked out from the listing server's (`guessed`): a failed check then says
/// to pair with a code. With no address at all, Add opens the scanner.
///
/// Its own view, so the host lists are read here and not on every change to the sessions list.
struct NotAddedSection: View {
    @Environment(AppModel.self) private var model
    let theme: TermTheme
    let gap: CGFloat

    var body: some View {
        let hosts = KnownHost.unsaved(model.servers.map { ($0.config, $0.hosts) })
        if !hosts.isEmpty {
            Text("Not added")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(theme.chrome.tertiary)
                .padding(.horizontal, SidebarMetrics.pad)
                .padding(.top, gap)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .bottomLeading)
                .accessibilityAddTraits(.isHeader)
                .modifier(SidebarStackRow(theme: theme))
            ForEach(hosts) { h in
                NotAddedRow(host: h, theme: theme) { Self.add(h, model: model) }
                    .modifier(SidebarStackRow(theme: theme))
            }
        }
    }

    static func add(_ host: KnownHost, model: AppModel) {
        if let c = host.candidate {
            model.startPairing(prefilled: c.url, name: host.label, guessed: c.guessed)
        } else {
            model.showPairing = true
        }
    }
}

/// One machine that isn't added yet: quiet, with a one-tap Add.
struct NotAddedRow: View {
    let host: KnownHost
    let theme: TermTheme
    let add: () -> Void

    var body: some View {
        HStack(spacing: SidebarMetrics.gap) {
            Image(systemName: "desktopcomputer")
                .font(.subheadline)
                .foregroundStyle(theme.chrome.tertiary)
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                .frame(width: SidebarMetrics.glyph)
                .accessibilityHidden(true)
            Text(host.label)
                .font(.subheadline)
                .foregroundStyle(theme.chrome.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button(action: add) {
                Text("Add")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Capsule().fill(theme.accent.opacity(0.16)))
                    .foregroundStyle(theme.accent)
                    .frame(minHeight: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Add \(host.label)")
        }
        .padding(.horizontal, SidebarMetrics.pad)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
    }
}
