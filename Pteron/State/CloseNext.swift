import Foundation

/// What to show when the tab on screen closes: its last pane closed, Close Tab, the session
/// ended, or another client closed it. Rex keeps a session whose last tab closed (it has no
/// windows and stays listed until someone kills it), so without this the phone would sit on
/// the empty state with work open elsewhere.
///
/// The rule, newest place first, as a desktop's windows and Safari's tabs go back to where you were:
/// 1. The pane moved: a pane of the closed tab is now in another tab of the session (Move Pane
///    to Tab took the last one). Follow it.
/// 2. The session still has tabs: the one viewed most recently, else the closed tab's neighbour,
///    the next one first, as Rex itself picks the active tab after a close.
/// 3. The session is empty or gone: the session viewed most recently on the same machine, then
///    on another machine that is online, each at the tab viewed last there.
/// 4. None viewed: the first session with tabs on the same machine, then on another online
///    machine, in sidebar order. Not in a test launch, which must not open a session it didn't.
/// 5. Nothing: nil, and the empty state shows.
///
/// Only the tab on screen counts: a tab or session that closes off screen changes nothing.
struct CloseNext {
    struct Session: Equatable {
        var id: String
        /// Tab ids, in the session's order.
        var windows: [String]
        var active: String?
    }

    struct Machine: Equatable {
        var id: UUID
        var online: Bool
        /// In sidebar order.
        var sessions: [Session]
    }

    /// The tab that closed.
    var closed: Selection
    /// Its session's tabs before the close, in order, for the neighbour.
    var order: [String]
    /// The tab that holds a pane of the closed tab now, if one does.
    var movedTo: String?
    var machines: [Machine]
    /// Tabs viewed, newest first (`TabHistory`).
    var recent: [Selection]
    /// Whether a session never viewed may be picked (rule 4).
    var anySession: Bool

    func next() -> Selection? {
        guard let here = machines.first(where: { $0.id == closed.serverID }) else {
            return recentSession(on: others) ?? firstSession(on: others)
        }
        let session = here.sessions.first { $0.id == closed.sessionID }
        if let session, !session.windows.isEmpty {
            return Selection(serverID: here.id, sessionID: session.id, windowID: tab(in: session))
        }
        return recentSession(on: [here]) ?? recentSession(on: others) ?? firstSession(on: [here]) ?? firstSession(on: others)
    }

    private var others: [Machine] { machines.filter { $0.id != closed.serverID && $0.online } }

    /// The tab to show in the closed tab's own session, which still has tabs.
    private func tab(in session: Session) -> String {
        let live = Set(session.windows)
        if let moved = movedTo, live.contains(moved) { return moved }
        if let r = recent.first(where: { $0.serverID == closed.serverID && $0.sessionID == session.id
            && $0.windowID != closed.windowID && live.contains($0.windowID) }) {
            return r.windowID
        }
        if let i = order.firstIndex(of: closed.windowID) {
            if let after = order[(i + 1)...].first(where: live.contains) { return after }
            if let before = order[..<i].last(where: live.contains) { return before }
        }
        return session.windows[0]
    }

    /// The newest viewed session with tabs on these machines, other than the closed one.
    private func recentSession(on list: [Machine]) -> Selection? {
        for r in recent where r.sessionID != closed.sessionID || r.serverID != closed.serverID {
            guard let m = list.first(where: { $0.id == r.serverID }),
                  let s = m.sessions.first(where: { $0.id == r.sessionID }), !s.windows.isEmpty else { continue }
            return Selection(serverID: m.id, sessionID: s.id, windowID: lastTab(in: s, on: m.id))
        }
        return nil
    }

    private func firstSession(on list: [Machine]) -> Selection? {
        guard anySession else { return nil }
        for m in list {
            for s in m.sessions where !s.windows.isEmpty && (s.id != closed.sessionID || m.id != closed.serverID) {
                return Selection(serverID: m.id, sessionID: s.id, windowID: lastTab(in: s, on: m.id))
            }
        }
        return nil
    }

    /// The tab viewed last in a session, else the one it shows (its active tab).
    private func lastTab(in s: Session, on server: UUID) -> String {
        let live = Set(s.windows)
        if let r = recent.first(where: { $0.serverID == server && $0.sessionID == s.id && live.contains($0.windowID) }) {
            return r.windowID
        }
        if let a = s.active, live.contains(a) { return a }
        return s.windows[0]
    }
}

/// The tabs viewed, newest first, each once: what `CloseNext` goes back to.
enum TabHistory {
    static let limit = 32

    static func visiting(_ sel: Selection, _ list: [Selection]) -> [Selection] {
        Array(([sel] + list.filter { $0 != sel }).prefix(limit))
    }

    /// A tab moved from one session to another: its entry names the new session, in its place.
    static func moved(_ old: Selection, to new: Selection, in list: [Selection]) -> [Selection] {
        var out: [Selection] = []
        for s in list {
            let t = s == old ? new : s
            if !out.contains(t) { out.append(t) }
        }
        return out
    }
}
