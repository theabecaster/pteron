import Foundation

/// An address of a dev server as someone types it: `localhost:3000`, `127.0.0.1:3000/admin`,
/// `:3000`, `[::1]:3000`, `0.0.0.0:3000`, with or without `http://` or `https://`. Pure: it
/// reads only the port lists the app already holds, so it costs nothing to ask on every
/// keystroke (docs/terminal.md, Ports).
struct PortAddress: Equatable {
    /// `http` unless `https://` was typed.
    var scheme: String
    /// The address as typed, which the browser then shows: `127.0.0.1:3000`. `:3000` reads
    /// `localhost:3000`.
    var shown: String
    var port: Int
    /// Path, query and fragment as typed, `/` when there is none.
    var rest: String

    enum Typed: Equatable {
        /// An address on a computer's own loopback.
        case local(PortAddress)
        /// A web address somewhere else: not for the app's browser.
        case elsewhere(URL)
    }

    /// One connected computer and what listens on it.
    struct Machine {
        var id: UUID
        var name: String
        var online: Bool
        var rows: [PortRow]
    }

    struct Match: Equatable, Identifiable {
        var serverID: UUID
        var machine: String
        var row: PortRow
        var id: String { "\(serverID.uuidString):\(row.id)" }

        /// The picker's row: the machine, then what runs there ("Desk · Next.js · anchor").
        var title: String { "\(machine) · \(PortNames.title(row.entry))" }
    }

    /// What the text names. Nil when it is no address: a word, a bare number (`3000` is too
    /// many things), a local name without a port.
    static func parse(_ text: String) -> Typed? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" "), t.count <= 2048 else { return nil }
        if t.hasPrefix(":") { t = "localhost" + t }
        let lower = t.lowercased()
        let hasScheme = lower.hasPrefix("http://") || lower.hasPrefix("https://")
        guard hasScheme || !lower.contains("://") else { return nil }
        guard let url = URL(string: hasScheme ? t : "http://" + t),
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = c.host?.lowercased(), !host.isEmpty else { return nil }
        if let link = LocalhostLink(url) {
            // A local name needs its port: `localhost` alone says nothing.
            guard c.port != nil else { return nil }
            return .local(PortAddress(scheme: link.scheme, shown: link.shown, port: link.port, rest: link.rest.isEmpty ? "/" : link.rest))
        }
        // Somewhere else: a name with a dot, or an IP address.
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard bare.contains(".") || bare.contains(":"), bare.first != ".", bare.last != "." else { return nil }
        return .elsewhere(url)
    }

    /// Every connected computer where a pane listens on that port, in the sidebar's order.
    /// A computer that is offline has none.
    static func matches(_ a: PortAddress, in machines: [Machine]) -> [Match] {
        var out: [Match] = []
        for m in machines where m.online {
            // One row a machine: the first pane that holds the port.
            if let row = m.rows.first(where: { $0.entry.port == a.port }) {
                out.append(Match(serverID: m.id, machine: m.name, row: row))
            }
        }
        return out
    }

    /// `localhost:3000/admin?x=1`, as the browser's address line shows it for editing.
    var text: String { shown + (rest == "/" ? "" : rest) }

    static func nothing(_ a: PortAddress) -> String {
        "Nothing is running on \(a.shown) on your computers."
    }
}
