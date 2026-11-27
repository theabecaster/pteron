import Foundation
import RexKit

/// Moving a tab, with its programs running, to another session of the same computer
/// (`session.transfer_window`, revision 22; docs/sidebar.md, Move to Session).
extension ServerConnection {
    /// Whether this computer moves tabs between sessions now.
    var movesTabs: Bool { phase == .online && capabilities.paneSupport.has(.transferTab) }

    /// The sessions a tab of `sid` can move to: the computer's other sessions, in sidebar order.
    /// None where the computer can't move tabs. Reads the session list, not the views, so a
    /// menu that shows them redraws for a session that comes, goes or is renamed, not for a tab.
    func moveDestinations(from sid: String) -> [SessionEntry] {
        guard movesTabs else { return [] }
        let hidden = hiddenSessions()
        return orderedSessions.filter { $0.id != sid && !hidden.contains($0.id) }
    }

    /// A session's name as menus say it: "session" for one without.
    func sessionName(_ sid: String) -> String {
        let label = views[sid]?.label ?? sessions.first { $0.id == sid }?.label ?? ""
        return label.isEmpty ? "session" : label
    }

    /// Moves tab `wid` of `sid` to session `dest`, before its tab `before` (nil: last). `focus`
    /// makes it the destination's active tab. The tab stays where it is until the server has
    /// moved it, then changes sessions in one step (`TabTransfer`); a failure says why in one
    /// notice and leaves it where it was. False when it didn't move.
    @discardableResult
    func transferTab(_ sid: String, _ wid: String, to dest: String, before: String?, focus: Bool) async -> Bool {
        guard sid != dest, let v = views[sid], let w = v.window(wid), movesTabs else { return false }
        let blocks = w.allBlocks.map(\.id)
        nextOrderToken += 1
        let token = nextOrderToken
        transfers[wid] = TabTransfer(window: w, from: sid, to: dest, index: v.windows.firstIndex { $0.id == wid } ?? v.windows.count,
                                     before: before, focus: focus, token: token)
        transferring.formUnion(blocks)
        tabMoving?(self, .began(blocks: blocks))
        let serial = connectionSerial
        let method = "session.transfer_window"
        var p: JSONObject = ["session_id": sid, "window_id": wid, "to_session_id": dest, "focus": focus]
        if let before { p["before_window_id"] = before }
        let result: JSONObject
        do {
            do {
                result = try await control.call(method, p)
            } catch let e as RexError where e.code == "not_found" && before != nil && views[dest]?.window(before) == nil
                && views[sid]?.window(wid) != nil {
                // The tab it was to go before closed meanwhile: it goes last instead.
                p["before_window_id"] = nil
                transfers[wid]?.before = nil
                result = try await control.call(method, p)
            }
        } catch {
            guard transfers[wid]?.token == token else { return false }
            endTransfer(wid, blocks: blocks)
            noteMissing(method, error)
            tabMoving?(self, .failed(blocks: blocks))
            refreshView(sid)
            refreshView(dest)
            Notice.shared.show(TransferCopy.failure(error, to: sessionName(dest), computer: config.name))
            return false
        }
        guard serial == connectionSerial, transfers[wid]?.token == token else {
            // A new connection meanwhile: its views say where the tab is, and a move they show
            // reaches the panes from there (`noteTabMoves`).
            tabMoving?(self, .failed(blocks: blocks))
            return true
        }
        transfers[wid]?.fromRevision = result.int("revision") ?? 0
        transfers[wid]?.toRevision = result.int("to_revision") ?? 0
        // Both sessions change in one step; the server's own views follow.
        views = TabTransfer.reconcile(views, Array(transfers.values))
        refreshView(sid)
        refreshView(dest)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(TabTransfer.timeout * 1_000_000_000))
            guard let self, self.transfers[wid]?.token == token else { return }
            self.endTransfer(wid, blocks: blocks)
        }
        return true
    }

    /// Lets go of the holds whose sessions' views have caught up.
    func releaseTransfers() {
        for (wid, h) in transfers where h.released(by: views) {
            endTransfer(wid, blocks: h.window.allBlocks.map(\.id))
        }
    }

    /// A new connection: no hold outlives the views it brings.
    func dropTransfers() {
        for (wid, h) in transfers { endTransfer(wid, blocks: h.window.allBlocks.map(\.id)) }
    }

    private func endTransfer(_ wid: String, blocks: [String]) {
        transfers[wid] = nil
        transferring.subtract(blocks)
    }

    /// Finds the tabs this change of views moved to another session, and follows each: what
    /// this connection keeps by pane and session, then the app (`tabMoved`). Remembers the tabs
    /// that left every view, for a move whose destination's view comes later.
    func noteTabMoves(from old: [String: SessionView]) {
        let now = Date()
        if !departedTabs.isEmpty {
            departedTabs = departedTabs.filter { now.timeIntervalSince($0.value.at) < TabMoves.memory }
        }
        let moves = TabMoves.find(old: old, new: views, departed: departedTabs.mapValues(\.session))
        for (wid, sid) in TabMoves.departures(old: old, new: views) { departedTabs[wid] = (sid, now) }
        guard !moves.isEmpty else { return }
        for m in moves {
            departedTabs[m.window] = nil
            arrivals[m.window] = nil
            for b in m.blocks {
                // A pane on screen keeps its ports followed, through its new session.
                if portWatch[b] != nil { portWatch[b] = PortWatch(session: m.to) }
                // Another client's move closed the panes here first (`block_closed`): their ports
                // are read again.
                fillPorts(session: m.to, block: b)
            }
            #if DEBUG
            NSLog("TAB_MOVED %@ %@ -> %@", String(m.window.suffix(4)), String(m.from.suffix(4)), String(m.to.suffix(4)))
            #endif
            tabMoved?(self, m)
        }
        refreshPortRows()
    }

    // MARK: Another client's move of the tab on screen

    /// `next` as the app shows it: with this iPhone's moves (`TabTransfer`) and the tab on screen
    /// kept while it may be moving (`LeavingTab`). The views of the sessions in `server` are the
    /// server's own.
    func held(_ next: [String: SessionView], server: Set<String>) -> [String: SessionView] {
        var out = transfers.isEmpty ? next : TabTransfer.reconcile(next, Array(transfers.values))
        if leaving == nil { beginLeaving(old: views, new: out) }
        guard let h = leaving else { return out }
        switch h.apply(&out, server: server) {
        case .held:
            break
        case .moved:
            // Followed from this change of views (`noteTabMoves`): the panes open through the
            // new session there.
            leaving = nil
        case .over:
            leaving = nil
            if arrivals[h.window.id] == nil { tabMoving?(self, .failed(blocks: h.window.allBlocks.map(\.id))) }
        }
        return out
    }

    /// Holds the tab on screen when this change takes it out of every view, where the server
    /// moves tabs. Its panes wait for the move as this iPhone's own move's do.
    private func beginLeaving(old: [String: SessionView], new: [String: SessionView]) {
        guard capabilities.paneSupport.has(.transferTab), let shown = shownTab?(), transfers[shown.window] == nil,
              var h = LeavingTab.begins(shown: shown, old: old, new: new) else { return }
        nextOrderToken += 1
        h.token = nextOrderToken
        leaving = h
        tabMoving?(self, .began(blocks: h.window.allBlocks.map(\.id)))
        waitForLeaving(h.token, LeavingTab.wait)
    }

    private func waitForLeaving(_ token: Int, _ seconds: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0.01) * 1_000_000_000))
            self?.leavingWaitOver(token)
        }
    }

    /// The wait is over and no view showed the tab elsewhere: unless a `window_created` named it
    /// in another session and its view may still come, it closes, and the app moves off it as
    /// for any closed tab (`CloseNext`) in this same turn.
    private func leavingWaitOver(_ token: Int) {
        guard let h = leaving, h.token == token else { return }
        if let a = arrivals[h.window.id], a.until > Date() {
            return waitForLeaving(token, a.until.timeIntervalSinceNow)
        }
        leaving = nil
        arrivals[h.window.id] = nil
        var next = views
        h.release(&next)
        views = next
        tabMoving?(self, .failed(blocks: h.window.allBlocks.map(\.id)))
    }

    /// A `window_created` in session `sid`: when a view of another session holds that tab, another
    /// client is moving it here (`session.transfer_window`, which keeps the tab's ID). Its panes
    /// wait for the destination's view, `LeavingTab.arrivalWait` at most.
    func noteArrival(_ wid: String, in sid: String) {
        guard capabilities.paneSupport.has(.transferTab), transfers[wid] == nil, arrivals[wid] == nil,
              views[sid]?.window(wid) == nil,
              let w = views.first(where: { $0.key != sid && $0.value.window(wid) != nil })?.value.window(wid) else { return }
        nextOrderToken += 1
        let token = nextOrderToken
        let blocks = w.allBlocks.map(\.id)
        arrivals[wid] = TabArrival(to: sid, blocks: blocks, until: Date().addingTimeInterval(LeavingTab.arrivalWait), token: token)
        tabMoving?(self, .began(blocks: blocks))
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(LeavingTab.arrivalWait * 1_000_000_000))
            guard let self, self.arrivals[wid]?.token == token else { return }
            self.arrivals[wid] = nil
            // The tab on screen ends with its own hold, which waits for this one.
            if self.leaving?.window.id != wid { self.tabMoving?(self, .failed(blocks: blocks)) }
        }
    }

    /// A new connection: its views say where each tab is, and a move they show reaches the
    /// panes from there (`noteTabMoves`). The kept tab stays in the views until they come.
    func dropArrivals() {
        if let h = leaving {
            leaving = nil
            tabMoving?(self, .failed(blocks: h.window.allBlocks.map(\.id)))
        }
        for a in arrivals.values { tabMoving?(self, .failed(blocks: a.blocks)) }
        arrivals = [:]
    }

    /// The session that holds a pane now, which differs from the one a stale place names once
    /// its tab moved.
    func session(holding block: String) -> String? {
        views.first { $0.value.windowContaining(block: block) != nil }?.key
    }

    /// The session that holds a tab now.
    func session(holdingWindow wid: String) -> String? {
        views.first { $0.value.window(wid) != nil }?.key
    }
}
