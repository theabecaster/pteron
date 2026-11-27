import Foundation

/// A place this phone showed: a pane, in its tab, on a computer.
struct NavPlace: Hashable {
    var serverID: UUID
    var sessionID: String
    var windowID: String
    /// The pane shown, or nil for a tab that had none to show.
    var blockID: String?
}

/// Navigate Back and Navigate Forward, as the Rex Mac app names them (`client.navigate.back`,
/// `client.navigate.forward`): "Goes back to the pane you were in before this one, in any tab or
/// session" and "Returns to the pane that Navigate Back left". A browser's history of the panes
/// this phone showed: going somewhere new drops what lay forward.
///
/// It is the phone's own, not the server's `focus_history.reverse` (revision 19), which steps
/// through a principal's history: the phone's would hold every focus change the phone's
/// Tailscale login sent from any connection, miss the panes the phone pages without telling
/// the server, and have no step forward (docs/goto.md, Navigate Back and Forward).
struct NavHistory {
    /// The Mac's server keeps the 64 blocks focus was on last; so does this.
    static let limit = 64

    /// Where the phone is.
    private(set) var current: NavPlace?
    /// Older places, the nearest last.
    private(set) var older: [NavPlace] = []
    /// Places Navigate Back left, the nearest last.
    private(set) var newer: [NavPlace] = []

    /// The phone shows `place`. The same place again changes nothing; a new one drops what lay
    /// forward.
    mutating func visit(_ place: NavPlace) {
        guard place != current else { return }
        if let current { older.append(current) }
        if older.count > Self.limit { older.removeFirst(older.count - Self.limit) }
        newer.removeAll()
        current = place
    }

    /// The nearest older place that `open` says can still be shown, which becomes the current
    /// one; the one left goes forward. Places passed over on the way (a pane or tab that
    /// closed) are dropped. Nil, with nothing changed, when none is left.
    mutating func back(where open: (NavPlace) -> Bool) -> NavPlace? {
        guard let p = Self.nearest(&older, from: current, open) else { return nil }
        if let current { newer.append(current) }
        current = p
        return p
    }

    /// The nearest place Navigate Back left, as `back` does the other way.
    mutating func forward(where open: (NavPlace) -> Bool) -> NavPlace? {
        guard let p = Self.nearest(&newer, from: current, open) else { return nil }
        if let current { older.append(current) }
        current = p
        return p
    }

    func canGoBack(where open: (NavPlace) -> Bool) -> Bool { older.contains { $0 != current && open($0) } }
    func canGoForward(where open: (NavPlace) -> Bool) -> Bool { newer.contains { $0 != current && open($0) } }

    /// Takes the nearest place `open` allows off `list`, with the ones passed over on the way.
    /// With none, `list` stays as it was: a computer that comes back makes its places good again.
    private static func nearest(_ list: inout [NavPlace], from current: NavPlace?, _ open: (NavPlace) -> Bool) -> NavPlace? {
        guard let i = list.lastIndex(where: { $0 != current && open($0) }) else { return nil }
        let p = list[i]
        list.removeSubrange(i...)
        return p
    }
}
