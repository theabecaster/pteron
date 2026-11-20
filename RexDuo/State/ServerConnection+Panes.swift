import Foundation
import Observation
import RexKit

/// The pane and order commands (Arrange, their keys, the sidebar's drag): the server calls, the
/// held order a drag shows until the server agrees, and the guard that hides a command whose
/// method a server turns out not to have.
extension ServerConnection {
    // MARK: Support

    /// Hands the keymap what this server can do, so a key bound to a command it lacks falls
    /// through. Called on every connection and when a call finds a method missing.
    func panesSupportChanged() {
        let s = capabilities.paneSupport
        if keymap.panes != s { keymap.panes = s }
    }

    /// A call answered that its method doesn't exist here: every command that uses it hides on
    /// this connection, and its key falls through. Other errors say nothing about support.
    func noteMissing(_ method: String, _ error: Error) {
        guard (error as? RexError)?.presence(targetExists: false) == .absent else { return }
        capabilities.record(method: method, host: nil, .absent, serial: connectionSerial)
        panesSupportChanged()
    }

    // MARK: View

    /// Reads a session's layout now, without the coalescing delay of `refreshView`, and applies
    /// it before returning: what the caller does next lands in the same update as the new layout.
    func reloadView(_ sid: String) async {
        guard let r = try? await control.call("session.view", ["session_id": sid]) else { return }
        apply(view: SessionView(r.obj("view") ?? r))
    }

    /// Waits until the session's view passes `test`, for at most `timeout` seconds. Watches the
    /// views as they land; nothing is asked of the server.
    func awaitView(_ sid: String, timeout: Double, _ test: @escaping @MainActor (SessionView) -> Bool) async -> Bool {
        if let v = views[sid], test(v) { return true }
        let waiter = ViewWaiter()
        return await withCheckedContinuation { c in
            waiter.done = { c.resume(returning: $0) }
            waiter.watch(self, sid, test)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                waiter.finish(false)
            }
        }
    }

    // MARK: Panes

    func swapBlocks(_ sid: String, _ a: String, _ b: String) async {
        let method = "session.swap_blocks"
        await act("swap the panes", session: sid) {
            do {
                return try await self.control.call(method, ["session_id": sid, "block_id": a, "other_block_id": b])
            } catch {
                self.noteMissing(method, error)
                throw error
            }
        }
    }

    /// Moves `block` into a new split beside `anchor`. On failure it says why and re-reads the
    /// view; true when the server moved it.
    func moveBlock(_ sid: String, _ block: String, anchor: String, direction: String) async -> Bool {
        let method = "session.move_block"
        do {
            _ = try await control.call(method, ["session_id": sid, "block_id": block, "anchor_block_id": anchor,
                                                "direction": direction, "side": "after", "ratio": 0.5])
            return true
        } catch {
            noteMissing(method, error)
            Notice.shared.show(Self.moveFailure(error))
            refreshView(sid)
            return false
        }
    }

    static func moveFailure(_ error: Error) -> String {
        if (error as? RexError)?.code == "conflict" { return "That tab can't take another pane." }
        return "Couldn't move the pane. \(short(error))"
    }

    /// Move Pane to New Tab: a tab with a placeholder shell, then, in one turn and in order, the
    /// move beside the placeholder, its close, and the new tab's place right after `source`.
    /// Returns the new tab once the view holds the pane there, or nil.
    ///
    /// The new tab has no label of its own, so its title follows its pane as the Mac's move does.
    /// A failed move is rolled back by the close (it empties the new tab, which closes it); the
    /// place call then finds no tab, which is expected. Only the move's error is shown.
    func moveToNewTab(_ sid: String, block: String, source: String) async -> String? {
        let tabs = views[sid]?.windows.map(\.id) ?? []
        let next = tabs.firstIndex(of: source).flatMap { tabs.indices.contains($0 + 1) ? tabs[$0 + 1] : nil }
        let made: JSONObject
        do {
            made = try await control.call("session.new_window", [
                "session_id": sid, "focus": false,
                "layout": ["block": ["flavor": "com.superlogical.terminal.shell"]],
            ])
        } catch {
            noteMissing("session.new_window", error)
            Notice.shared.show("Couldn't move the pane. \(Self.short(error))")
            refreshView(sid)
            return nil
        }
        guard let tab = made.str("window_id"), let placeholder = (made["block_ids"] as? [Any])?.first as? String else {
            refreshView(sid)
            return nil
        }
        var calls: [(method: String, payload: JSONObject)] = [
            ("session.move_block", ["session_id": sid, "block_id": block, "anchor_block_id": placeholder]),
            ("block.close", ["session_id": sid, "block_id": placeholder]),
        ]
        // A new tab is already last; after the last tab it stays there.
        if let next { calls.append(("session.move_window", ["session_id": sid, "window_id": tab, "before_window_id": next])) }
        let results = await control.callInOrder(calls)
        for (call, result) in zip(calls, results) {
            guard case .failure(let e) = result else { continue }
            noteMissing(call.method, e)
            #if DEBUG
            NSLog("PANES move to new tab: %@ failed: %@", call.method, Self.short(e))
            #endif
        }
        if case .failure(let e) = results[0] {
            Notice.shared.show(Self.moveFailure(e))
            refreshView(sid)
            return nil
        }
        await reloadView(sid)
        return tab
    }

    /// Balance Splits: every changed split at once. `resize_pane` isn't ordered, and each call
    /// sets one split's ratio outright, so order buys nothing. Then one re-read and at most one
    /// notice, so each pane sees one layout change and sends one resize.
    func balance(_ sid: String, _ changes: [SplitBalance.Change]) async {
        guard !changes.isEmpty else { return }
        var failure: Error?
        await withTaskGroup(of: Error?.self) { g in
            for c in changes { g.addTask { await self.resizeForBalance(sid, c) } }
            for await e in g where failure == nil { failure = e }
        }
        refreshView(sid)
        if let failure { Notice.shared.show("Couldn't balance the splits. \(Self.short(failure))") }
    }

    private func resizeForBalance(_ sid: String, _ c: SplitBalance.Change) async -> Error? {
        let method = "session.resize_pane"
        do {
            _ = try await control.call(method, ["session_id": sid, "direction": c.direction, "before_block_id": c.before,
                                                "after_block_id": c.after, "ratio": c.ratio])
            return nil
        } catch {
            noteMissing(method, error)
            return error
        }
    }

    /// Close Other Panes: closes exactly these blocks, sent in order in one turn, then one re-read
    /// and at most one notice. A block that is gone already (`not_found`) is what was asked.
    func closeBlocks(_ sid: String, _ ids: [String]) async {
        guard !ids.isEmpty else { return }
        let results = await control.callInOrder(ids.map { ("block.close", ["session_id": sid, "block_id": $0] as JSONObject) })
        var failure: Error?
        for case .failure(let e) in results where (e as? RexError)?.code != "not_found" {
            noteMissing("block.close", e)
            failure = failure ?? e
        }
        refreshView(sid)
        if let failure { Notice.shared.show("Couldn't close the panes. \(Self.short(failure))") }
    }

    // MARK: Order

    /// Moves a tab within its session (`client.tab.move.*`).
    func moveWindow(_ sid: String, _ wid: String, before: String?) async {
        let method = "session.move_window"
        var p: JSONObject = ["session_id": sid, "window_id": wid]
        if let before { p["before_window_id"] = before }
        await act("move the tab", session: sid) {
            do { return try await self.control.call(method, p) } catch {
                self.noteMissing(method, error)
                throw error
            }
        }
    }

    /// A sidebar tab drag: the new order shows at once and is held until a view at or above the
    /// revision of the newest drag's call arrives, or 2 s after that call returns.
    /// The order shows before this returns, so a caller's animation moves the rows.
    func dragTab(_ sid: String, _ wid: String, _ move: TabOrder.Move) {
        nextOrderToken += 1
        let token = nextOrderToken
        pendingOrder.tabs[sid] = PendingOrder.Hold(order: move.order, token: token)
        let serial = connectionSerial
        let method = "session.move_window"
        var p: JSONObject = ["session_id": sid, "window_id": wid]
        if let before = move.before { p["before_window_id"] = before }
        Task { [weak self] in
            guard let self else { return }
            do {
                let r = try await self.control.call(method, p)
                guard serial == self.connectionSerial, self.pendingOrder.tabs[sid]?.token == token else { return }
                self.pendingOrder.tabs[sid]?.revision = r.int("revision") ?? 0
                self.releaseTabHolds()
                self.expireHold(after: PendingOrder.timeout) {
                    if $0.tabs[sid]?.token == token { $0.tabs[sid] = nil }
                }
            } catch {
                if self.pendingOrder.tabs[sid]?.token == token { self.pendingOrder.tabs[sid] = nil }
                self.noteMissing(method, error)
                self.refreshView(sid)
                if (error as? RexError)?.code == "not_found" { return }
                Notice.shared.show("Couldn't move the tab. \(Self.short(error))")
            }
        }
    }

    /// A sidebar session drag: the order shows at once and is held until `session.list` gives
    /// it, or 2 s after the newest drag's call returns. `session.move` isn't ordered, so each
    /// drag's call waits for the one before, and works out its neighbor only when it is sent.
    func dragSession(_ sid: String, order: [String]) {
        nextOrderToken += 1
        let token = nextOrderToken
        pendingOrder.sessions = PendingOrder.Hold(order: order, token: token)
        let serial = connectionSerial
        let previous = sessionMoveTask
        sessionMoveTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            // A new connection since the drop: its lists are the truth, and the drop is dropped.
            guard serial == self.connectionSerial else { Haptic.bump(); return }
            // Its place in its own drop's order, among the sessions that are still there now.
            let live = Set(self.sessions.map(\.id))
            guard live.contains(sid), let i = order.firstIndex(of: sid) else { Haptic.bump(); return }
            var p: JSONObject = ["session_id": sid]
            if let next = order[(i + 1)...].first(where: live.contains) { p["before_session_id"] = next }
            let method = "session.move"
            do {
                _ = try await self.control.call(method, p)
                guard serial == self.connectionSerial, self.pendingOrder.sessions?.token == token else { return }
                self.pendingOrder.sessions?.returned = true
                self.releaseSessionHold()
                self.expireHold(after: PendingOrder.timeout) {
                    if $0.sessions?.token == token { $0.sessions = nil }
                }
            } catch {
                if self.pendingOrder.sessions?.token == token { self.pendingOrder.sessions = nil }
                self.noteMissing(method, error)
                let code = (error as? RexError)?.code
                if code == "not_found" || code == "session_not_found" { return }
                Notice.shared.show("Couldn't move the session. \(Self.short(error))")
            }
        }
    }

    private func expireHold(after seconds: Double, _ release: @escaping @MainActor (inout PendingOrder) -> Void) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let self else { return }
            var p = self.pendingOrder
            release(&p)
            if p != self.pendingOrder { self.pendingOrder = p }
        }
    }

    /// Lets go of tab orders the views have caught up with, or whose session is gone.
    func releaseTabHolds() {
        let done = pendingOrder.tabs.filter { sid, hold in
            guard let v = views[sid] else { return true }
            return PendingOrder.released(hold, viewRevision: v.revision)
        }
        for sid in done.keys { pendingOrder.tabs[sid] = nil }
    }

    /// Lets go of a session order the list now gives (hidden sessions are never in either).
    func releaseSessionHold() {
        guard let hold = pendingOrder.sessions, PendingOrder.released(hold, listed: sessions.map(\.id)) else { return }
        pendingOrder.sessions = nil
    }

    /// The sessions in the order the sidebar shows: a drag's held order, else the server's.
    var orderedSessions: [SessionEntry] {
        guard let hold = pendingOrder.sessions else { return sessions }
        let ids = TabOrder.applied(sessions.map(\.id), hold.order)
        let byID = Dictionary(sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byID[$0] }
    }

    /// A session's tabs in the order the sidebar shows.
    func orderedWindowIDs(_ sid: String) -> [String] {
        let ids = views[sid]?.windows.map(\.id) ?? []
        guard let hold = pendingOrder.tabs[sid] else { return ids }
        return TabOrder.applied(ids, hold.order)
    }
}

extension ServerCapabilities {
    /// What this server can do of the pane commands, from the revision and what calls found.
    var paneSupport: PaneSupport {
        PaneSupport(revision: revision, absent: Set(PaneCommand.allMethods.filter { probe(method: $0, host: nil) == false }))
    }
}

/// Watches a session's views until a test passes or time is up, then answers once.
@MainActor
private final class ViewWaiter {
    var done: ((Bool) -> Void)?

    func finish(_ ok: Bool) {
        let d = done
        done = nil
        d?(ok)
    }

    func watch(_ server: ServerConnection, _ sid: String, _ test: @escaping @MainActor (SessionView) -> Bool) {
        guard done != nil else { return }
        withObservationTracking { _ = server.views[sid] } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.done != nil else { return }
                if let v = server.views[sid], test(v) { self.finish(true) } else { self.watch(server, sid, test) }
            }
        }
    }
}
