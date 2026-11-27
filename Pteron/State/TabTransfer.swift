import Foundation
import RexKit

/// A tab this iPhone is moving to another session of its computer (`session.transfer_window`),
/// held until the server's views of both sessions show the move (docs/sidebar.md, Move to
/// Session). Pure, so it is tested.
///
/// The tab is in exactly one of the two sessions at every moment the app draws:
/// - **Before the answer** it stays where it was, also when a view of the session it leaves
///   comes in without it; it changes sessions, in one step, when a view of the destination shows
///   it. The tab on screen never looks closed on the way.
/// - **From the answer on** it is in the destination, at its place there, in views older than
///   the revisions the answer gave, and in neither of the two sessions' older views twice.
struct TabTransfer {
    /// The tab as the session it leaves had it when the move began.
    var window: WindowInfo
    var from: String
    var to: String
    /// Its place in the session it leaves, to keep it there before the answer.
    var index: Int
    /// The destination's tab it goes before; nil: last.
    var before: String?
    /// It becomes the destination's active tab.
    var focus: Bool
    /// The revisions of the two sessions after the move, from the answer; nil before it.
    var fromRevision: Int?
    var toRevision: Int?
    /// The move this hold is for: an expiry for an earlier move of the same tab does nothing.
    var token: Int

    var answered: Bool { fromRevision != nil }

    /// How long a hold waits, from the answer, for the server's views to agree.
    static let timeout = 2.0

    /// `views` with every hold applied.
    static func reconcile(_ views: [String: SessionView], _ holds: [TabTransfer]) -> [String: SessionView] {
        var out = views
        for h in holds { h.apply(&out) }
        return out
    }

    func apply(_ views: inout [String: SessionView]) {
        let id = window.id
        guard var a = views[from] else {
            // The session it leaves is gone: the destination still gets it once answered.
            if answered, var b = views[to], b.window(id) == nil, b.revision < (toRevision ?? 0) {
                insert(into: &b)
                views[to] = b
            }
            return
        }
        let inA = a.window(id) != nil
        let inB = views[to]?.window(id) != nil
        if let fromRevision, let toRevision {
            if inA, a.revision < fromRevision {
                remove(from: &a)
                views[from] = a
            }
            if !inB, var b = views[to], b.revision < toRevision {
                insert(into: &b)
                views[to] = b
            }
        } else if inB, inA {
            // The server moved it, and the destination's view came first.
            remove(from: &a)
            views[from] = a
        } else if !inB, !inA {
            // The view of the session it leaves came first: it stays until the destination has it.
            var w = a.windows
            w.insert(window, at: min(index, w.count))
            a.windows = w
            views[from] = a
        }
    }

    private func remove(from v: inout SessionView) {
        v.windows.removeAll { $0.id == window.id }
        // The server picks the session's next active tab; its view says which.
        if v.activeWindowID == window.id { v.activeWindowID = nil }
    }

    private func insert(into v: inout SessionView) {
        let at = before.flatMap { b in v.windows.firstIndex { $0.id == b } } ?? v.windows.count
        v.windows.insert(window, at: at)
        // A session with no active tab always makes it active, as the server does.
        if focus || v.activeWindowID == nil || v.window(v.activeWindowID) == nil { v.activeWindowID = window.id }
    }

    /// The server's views of both sessions have caught up with the answer.
    func released(by views: [String: SessionView]) -> Bool {
        guard let fromRevision, let toRevision else { return false }
        let a = views[from].map { $0.revision >= fromRevision } ?? true
        let b = views[to].map { $0.revision >= toRevision } ?? true
        return a && b
    }
}

/// Tabs that changed sessions on a computer: by this iPhone's move or by another client's (the
/// Rex app, `rex window move --to`). A tab keeps its ID, so a tab that leaves one session's view
/// and shows up in another's has moved. Pure, so it is tested.
enum TabMoves {
    struct Move: Equatable {
        var window: String
        var from: String
        var to: String
        /// The tab's panes, which keep their IDs.
        var blocks: [String]
    }

    /// This iPhone's move of a tab, for the panes' streams: the server ends the streams opened
    /// through the session the tab leaves.
    enum Moving: Equatable {
        case began(blocks: [String])
        case failed(blocks: [String])
    }

    /// How long a tab that left every view is remembered, for its view in the new session to come.
    static let memory: TimeInterval = 10

    /// The tabs that are in a session of `new` and were in another one: in `old`, or among those
    /// that left lately (`departed`). Cheap when no session gained a tab, as on most changes.
    static func find(old: [String: SessionView], new: [String: SessionView], departed: [String: String]) -> [Move] {
        var arrived: [(String, WindowInfo)] = []
        for (sid, v) in new {
            let before = old[sid]
            if let before, sameTabs(before, v) { continue }
            let had = Set(before?.windows.map(\.id) ?? [])
            for w in v.windows where !had.contains(w.id) { arrived.append((sid, w)) }
        }
        guard !arrived.isEmpty, !(old.isEmpty && departed.isEmpty) else { return [] }
        var home: [String: String] = [:]
        for (sid, v) in old { for w in v.windows { home[w.id] = sid } }
        return arrived.compactMap { sid, w in
            guard let from = home[w.id] ?? departed[w.id], from != sid else { return nil }
            return Move(window: w.id, from: from, to: sid, blocks: w.allBlocks.map(\.id))
        }
    }

    /// The tabs that were in `old` and are in no view of `new`, with the session each left.
    static func departures(old: [String: SessionView], new: [String: SessionView]) -> [String: String] {
        var gone: [String: String] = [:]
        for (sid, v) in old {
            let now = new[sid]
            if let now, sameTabs(v, now) { continue }
            let kept = Set(now?.windows.map(\.id) ?? [])
            for w in v.windows where !kept.contains(w.id) { gone[w.id] = sid }
        }
        guard !gone.isEmpty else { return [:] }
        for v in new.values { for w in v.windows { gone[w.id] = nil } }
        return gone
    }

    private static func sameTabs(_ a: SessionView, _ b: SessionView) -> Bool {
        a.windows.count == b.windows.count && zip(a.windows, b.windows).allSatisfy { $0.id == $1.id }
    }
}

/// The tab on screen, gone from its session's view and in no other view yet (docs/sidebar.md,
/// Move to Session). Another client's move (the Rex app, `rex window move --to`) sends the
/// session the tab leaves first, so its view can land before the destination's. Where the server
/// moves tabs, the tab stays in its session's view for a short wait (`wait`), longer once a
/// `window_created` names it in another session (`arrivalWait`): nothing new shows, the old
/// frame stays, and the view that shows it elsewhere moves it in one step. When the wait ends
/// with no such view, the tab closes as before (`CloseNext`). Pure, so it is tested.
struct LeavingTab {
    /// The tab as its session had it.
    var window: WindowInfo
    var session: String
    /// Its place there, to keep it there.
    var index: Int
    /// The hold this is: an expiry for an earlier hold does nothing.
    var token = 0

    /// How long the tab on screen waits for another session's view to show it.
    static let wait: TimeInterval = 0.4
    /// How long a move a `window_created` announced waits for the destination's view.
    static let arrivalWait: TimeInterval = 2

    enum Outcome: Equatable {
        /// Kept in its session.
        case held
        /// A view of another session shows it: it moved, in this same change.
        case moved
        /// The server's view of its session shows it again, or that view is gone: no hold.
        case over
    }

    /// The hold a change of views from `old` to `new` begins for the tab on screen (`shown`): the
    /// tab left its session's view, is in no other, and no pane of it went to another tab of its
    /// session (Move Pane to Tab, which `CloseNext` follows at once). Nil: no hold.
    static func begins(shown: (session: String, window: String), old: [String: SessionView],
                       new: [String: SessionView]) -> LeavingTab? {
        guard let was = old[shown.session], let w = was.window(shown.window),
              let now = new[shown.session], now.window(shown.window) == nil,
              !w.allBlocks.contains(where: { now.windowContaining(block: $0.id) != nil }),
              !new.values.contains(where: { $0.window(shown.window) != nil }) else { return nil }
        return LeavingTab(window: w, session: shown.session, index: was.windows.firstIndex { $0.id == w.id } ?? was.windows.count)
    }

    /// Applies the hold to `views`, in which the views of the sessions in `server` are the
    /// server's own (the others may hold the kept tab).
    func apply(_ views: inout [String: SessionView], server: Set<String>) -> Outcome {
        let id = window.id
        if views.contains(where: { $0.key != session && $0.value.window(id) != nil }) {
            release(&views)
            return .moved
        }
        guard var v = views[session] else { return .over }
        if v.window(id) != nil { return server.contains(session) ? .over : .held }
        v.windows.insert(window, at: min(index, v.windows.count))
        views[session] = v
        return .held
    }

    /// Takes the kept tab out of its session's view.
    func release(_ views: inout [String: SessionView]) {
        views[session]?.windows.removeAll { $0.id == window.id }
    }
}

/// A tab a `window_created` names in a session while a view of another session still holds it:
/// another client is moving it there. Its panes wait for the move (`TerminalStream.expectMove`)
/// until the destination's view shows it, or `LeavingTab.arrivalWait` at most.
struct TabArrival {
    var to: String
    var blocks: [String]
    var until: Date
    var token: Int
}

/// What a failed move says, in the notice style of the app's other failures.
enum TransferCopy {
    static func failure(_ error: Error, to session: String, computer: String) -> String {
        switch (error as? RexError)?.code {
        // The destination has its most tabs, or a pane of the tab is starting or moving.
        case "conflict": "Couldn't move the tab. “\(session)” is full, or a pane in the tab is still starting."
        case "session_not_found": "Couldn't move the tab. That session closed."
        case "not_found": "Couldn't move the tab. That tab closed."
        default: Messages.couldNot("move the tab", error, computer: computer)
        }
    }
}
