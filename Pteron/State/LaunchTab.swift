import Foundation

/// The tab a launch opens, in every posture and in both navigation styles. Decided from what was
/// saved (`Prefs.lastSelection`, the newest of `TabHistory`) and what the servers have synced:
/// no call of its own, and nothing shown that is then swapped for another tab.
///
/// 1. The tab viewed last, while it is still there.
/// 2. Else the top tab of its session, in the sidebar's order.
/// 3. Else the top tab of the first session with tabs on that machine.
/// 4. Else, or with nothing saved, as before: the first session with tabs on any machine, at the
///    tab it shows.
///
/// Until the machine viewed last has synced, the launch waits for it, so a machine that answers
/// sooner doesn't put its own tab on screen first. A machine that is down, or not added any more,
/// goes to rule 4.
struct LaunchTab {
    struct Machine: Equatable {
        var id: UUID
        var state: State
        /// In sidebar order, with their tabs in order (`CloseNext.Session`).
        var sessions: [CloseNext.Session]
    }

    enum State: Equatable {
        /// Connecting or syncing: its sessions aren't known yet.
        case waiting
        /// Its sessions and tabs are in.
        case synced
        /// Its offline screen is up.
        case down
    }

    enum Pick: Equatable {
        /// The machine viewed last hasn't synced yet: show nothing new.
        case wait
        case show(Selection)
        /// Nothing to show yet: the empty state stays.
        case none
    }

    /// Whether a launch picks a tab by itself, by the rules above. Not with `-autoOpen`, which
    /// names the one session a test launch opens, and not in a test launch given servers with
    /// `-servers` but no `-autoOpen`: those are real computers, and their tab viewed last or top
    /// tab is a real session, which a test must never open, take or resize. Both are launch
    /// arguments (`arguments`, the argument domain); users never pass them.
    static func picksOnItsOwn(autoOpen: String?, arguments: [String: Any]) -> Bool {
        autoOpen == nil && arguments["autoOpen"] == nil && arguments["servers"] == nil
    }

    /// The tab viewed last.
    var last: Selection?
    /// In the app's order.
    var machines: [Machine]

    func pick() -> Pick {
        if let last, let here = machines.first(where: { $0.id == last.serverID }) {
            switch here.state {
            case .waiting: return .wait
            case .down: break
            case .synced: if let sel = restore(last, on: here) { return .show(sel) }
            }
        }
        return anyTab().map(Pick.show) ?? .none
    }

    /// Rules 1 to 3, on the machine viewed last.
    private func restore(_ last: Selection, on m: Machine) -> Selection? {
        if let s = m.sessions.first(where: { $0.id == last.sessionID }), let top = s.windows.first {
            let tab = s.windows.contains(last.windowID) ? last.windowID : top
            return Selection(serverID: m.id, sessionID: s.id, windowID: tab)
        }
        guard let s = m.sessions.first(where: { !$0.windows.isEmpty }) else { return nil }
        return Selection(serverID: m.id, sessionID: s.id, windowID: s.windows[0])
    }

    /// Rule 4: what a launch showed before there was a saved tab.
    private func anyTab() -> Selection? {
        for m in machines {
            for s in m.sessions where !s.windows.isEmpty {
                let tab = s.active.flatMap { s.windows.contains($0) ? $0 : nil } ?? s.windows[0]
                return Selection(serverID: m.id, sessionID: s.id, windowID: tab)
            }
        }
        return nil
    }
}
