import SwiftUI

/// Machines that a connected server lists in `hosts.list` but that aren't saved here, and how the
/// sidebar's Add button starts adding one. The one place that knows both.
///
/// When the pairing identity card lands, `KnownHost.unsaved` replaces `list`, and `add` calls
/// `model.startPairing(prefilled:name:guessed: true)` with `PairingCode.candidate`'s address:
/// `hosts.list` gives only ssh:// endpoints, so the address is a guess.
enum NotAddedHosts {
    struct Host: Identifiable, Equatable {
        /// The label, lowercased: one row per machine, whichever servers list it.
        var id: String
        var label: String
        var endpoints: [String]
    }

    struct Saved {
        var name: String
        var url: String
        /// The server's own tailnet name, once connected (`rex.tail1234.ts.net`).
        var hostName: String?
    }

    /// Every listed host, once, minus those saved here. A host matches a saved server by name, or by
    /// the first label of the server's address or tailnet name (without Rex's `-rex` ending).
    static func list(listed: [[HostEntry]], saved: [Saved]) -> [Host] {
        var taken = Set<String>()
        for s in saved {
            taken.insert(s.name.lowercased())
            if let u = ServerConfig.url(from: s.url) { taken.insert(ServerConfig.name(for: u).lowercased()) }
            if let h = s.hostName, let u = ServerConfig.url(from: h) { taken.insert(ServerConfig.name(for: u).lowercased()) }
        }
        var out: [Host] = []
        for h in listed.joined() {
            let key = h.label.lowercased()
            guard !key.isEmpty, !taken.contains(key) else { continue }
            taken.insert(key)
            out.append(Host(id: key, label: h.label, endpoints: h.endpoints))
        }
        return out
    }

    @MainActor
    static func list(_ model: AppModel) -> [Host] {
        list(listed: model.servers.map(\.hosts),
             saved: model.servers.map { Saved(name: $0.config.name, url: $0.config.url, hostName: $0.hostName) })
    }

    /// Starts adding the machine: Settings → Add Server for now.
    @MainActor
    static func add(_ host: Host, model: AppModel) {
        model.openSettings(at: .addServer)
    }
}

/// One machine that isn't added yet: quiet, with a one-tap Add.
struct NotAddedRow: View {
    let host: NotAddedHosts.Host
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
