import GlanceModel
import Foundation
import RexKit

/// What the server tells this connection: events, the oversized ones it had to drop
/// (`event_dropped`), and the questions it asks (`client_prompt_requested`).
extension ServerConnection {
    // MARK: Events

    func receive(seq: Int, event: JSONObject) {
        if seq > 0 {
            // seq counts events on this connection from 1, with no gaps. A jump means we missed some.
            if seq > 1, lastSeq > 0, seq > lastSeq + 1 { scheduleResync() }
            lastSeq = seq
        }
        handle(event: event)
    }

    func handle(event: JSONObject) {
        let type = event.str("type") ?? ""
        let p = event.obj("payload") ?? [:]
        switch type {
        case "session_created":
            if let s = p.obj("session"), let id = s.str("session_id"), !hiddenSessions().contains(id) {
                if !sessions.contains(where: { $0.id == id }) { sessions.append(SessionEntry(id: id, label: s.str("label") ?? "")) }
                touchedSessions.insert(id)
                Task { await attach(id) }
            }
        case "session_destroyed":
            let id = p.str("session_id") ?? p.obj("session")?.str("session_id") ?? ""
            for w in views[id]?.windows ?? [] {
                for b in w.allBlocks {
                    forgetBlockAlerts(b.id)
                    paneNames.remove(b.id)
                    forgetPorts(b.id)
                }
            }
            sessions.removeAll { $0.id == id }
            views[id] = nil
        case "session_moved":
            reloadSessionList()
        case "hosts_changed":
            Task { await loadHosts() }
            // A host that came, went or was updated brings other creators.
            loadCreators()
        case "keymap_changed":
            keymap.configChanged(hash: p.str("hash"))
        case "client_joined":
            if p.obj("client")?.obj("info")?.str("name") == RelayLookup.clientName { push?.relayChanged(self) }
        case "client_left":
            if let id = p.str("client_id"), push?.isRelay(id, on: self) == true { push?.relayChanged(self) }
        case "client_prompt_requested":
            receivePrompt(p)
        case "client_prompt_ended":
            if let id = p.str("call_id") { prompts.onPromptEnded?(id, p.str("reason") ?? "") }
        case "event_dropped":
            recover(dropped: DroppedEvent(p))
        case "session_event":
            guard let sid = p.str("session_id"), let ev = p.obj("event") else { return }
            handle(sessionID: sid, event: ev)
        default:
            // A type this build doesn't know: newer servers add events. Skipped, never an error.
            break
        }
    }

    private func handle(sessionID sid: String, event ev: JSONObject) {
        let type = ev.str("type") ?? ""
        let p = ev.obj("payload") ?? [:]
        if type == "block_event", let bid = p.str("block_id") {
            setupSignals?(.block(session: sid, block: bid, name: p.str("name") ?? "", payload: p.obj("payload") ?? [:]))
        }
        // About the server, whichever session carried them.
        switch type {
        case "creator_changed":
            loadCreators()
            return
        case "event_dropped":
            recover(dropped: DroppedEvent(p, session: sid))
            return
        default:
            break
        }
        // The installer's session has no row, no badge and no toast.
        guard !hiddenSessions().contains(sid) else { return }
        switch type {
        case "session_view_changed":
            let rev = p.int("revision") ?? Int.max
            if rev > (views[sid]?.revision ?? -1) { touchedSessions.insert(sid); refreshView(sid) }
        case "session_label_changed":
            if let l = p.str("label") {
                views[sid]?.label = l
                if let i = sessions.firstIndex(where: { $0.id == sid }) { sessions[i].label = l }
            }
        case "block_created":
            // A tunnel of the open browser is detached: no view changes.
            guard !ownTunnel(p.str("block_id"), session: sid) else { return }
            // So is an fs block of a folder transfer.
            guard treeBlocks?.owns(p.str("block_id"), server: id, session: sid) != true else { return }
            touchedSessions.insert(sid)
            refreshView(sid)
            // Its metadata is read once the view holds it (`createdBlocksShown`).
            if let bid = p.str("block_id") { noteCreated(bid) }
        case "block_event":
            handleBlockEvent(sessionID: sid, p)
        case "window_created", "window_closed", "window_label_changed", "active_window_changed", "block_closed", "block_owner_changed":
            if type == "block_closed" || type == "block_owner_changed", let bid = p.str("block_id"),
               forward?.owns(bid) == true || treeBlocks?.owns(bid, server: id, session: sid) == true {
                return
            }
            // A pane that shows the block hears who has it now, and why (`TerminalHost.ownerChanged`).
            if type == "block_owner_changed", let change = BlockOwnerChange(p) { ownerChanges.send(change) }
            // Another client may be moving a tab here: its panes wait for this session's view.
            if type == "window_created", let wid = p.str("window_id") { noteArrival(wid, in: sid) }
            // A pane of a tab this iPhone is moving to another session: it goes on there.
            if type == "block_closed", let bid = p.str("block_id"), !transferring.contains(bid) {
                ownerChanges.forget(block: bid)
                typingAids.forget(block: bid)
                forgetBlockAlerts(bid)
                paneNames.remove(bid)
                forgetPorts(bid)
            }
            touchedSessions.insert(sid)
            refreshView(sid)
        default:
            break
        }
    }

    func handleBlockEvent(sessionID sid: String, _ p: JSONObject) {
        guard let bid = p.str("block_id") else { return }
        let name = p.str("name") ?? ""
        let e = p.obj("payload") ?? [:]
        var m = pendingMeta[bid] ?? meta[bid] ?? BlockMeta()
        switch name {
        case "title_changed":
            m.title = e.str("title")
        case "pwd_changed":
            m.pwd = e.str("pwd")
        case "process_changed":
            if let fg = e.obj("foreground") { m.foreground = ProcessNames.label(fg) } else { m.foreground = nil }
            m.foregroundPID = e.obj("foreground")?.int("pid")
        case "program_status_changed":
            let id = e.str("id") ?? ""
            let prev = m.statuses[id]?.state
            if let rec = e.obj("record") {
                let st = ProgramStatus(rec)
                m.statuses[id] = st
                if st.state == "blocked", prev != "blocked" { notifyBlocked(sid, bid, st, m) }
            }
        case "program_status_removed":
            for id in (e["ids"] as? [String]) ?? [] where m.statuses.removeValue(forKey: id) != nil {
                agentRecordRemoved(bid)
            }
        case "bell":
            m.bellAt = Date()
        case "child_exited":
            m.exited = true
            stageProgress(bid, nil)
        case "progress_report":
            receiveProgress(bid, e)
            return
        case "desktop_notification":
            // A toast while the app is in front (`receiveNotice`); the helper pushes these while
            // it is in the background.
            receiveNotice(sid, bid, e)
            return
        case "ports_changed":
            receivePorts(session: sid, bid, e)
            return
        default:
            return
        }
        if syncing { touchedBlocks.insert(bid) }
        // Newer than the answer of any metadata read that is out now.
        let fields = MetaFields.set(byBlockEvent: name)
        if !fields.isEmpty {
            for read in metaReads.keys { metaReads[read]?[bid, default: []].formUnion(fields) }
        }
        pendingMeta[bid] = m
        scheduleFlush(after: Self.coalesce)
    }

    // MARK: Coalescing

    func scheduleFlush(after delay: Double) {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.01) * 1_000_000_000))
            self?.flush()
        }
    }

    /// Applies the buffered block updates in one go. A status that changed less than `minStatusHold`
    /// ago stays on screen a little longer, so badges don't flicker; a new "blocked" shows at once.
    func flush() {
        flushTask = nil
        flushPorts()
        let now = Date()
        var wait: Double?
        for (bid, m) in pendingMeta {
            let old = meta[bid]?.topStatus?.state
            let new = m.topStatus?.state
            if old != new {
                let age = now.timeIntervalSince(statusShownAt[bid] ?? .distantPast)
                if new != "blocked", age < Self.minStatusHold {
                    let rest = Self.minStatusHold - age
                    wait = min(wait ?? rest, rest)
                    continue
                }
                statusShownAt[bid] = now
            }
            meta[bid] = m
            pendingMeta[bid] = nil
        }
        if let wait { scheduleFlush(after: wait) }
    }

    func notifyBlocked(_ sid: String, _ bid: String, _ st: ProgramStatus, _ m: BlockMeta) {
        let who = m.agentKind?.displayName ?? st.app ?? "A program"
        let place = label(for: sid, block: bid)
        notifier.post(AgentAlert(serverID: id, sessionID: sid, windowID: views[sid]?.windowContaining(block: bid)?.id,
                                 blockID: bid, title: WatchScreen.sentence(who, why: st.waitingFor),
                                 body: [place.isEmpty ? nil : place, st.text].compactMap { $0 }.joined(separator: " — "),
                                 date: Date()))
        notifier.waitingHaptic()
    }

    func label(for sid: String, block bid: String) -> String {
        let s = views[sid]
        let w = s?.windowContaining(block: bid)
        return [s?.label, w?.label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " › ")
    }

    // MARK: Dropped events

    /// The server sent `event_dropped` in place of an event too large to send. Reads back what
    /// that event would have changed, and no more: a full sync reads every session, and features
    /// hang work on one.
    func recover(dropped d: DroppedEvent) {
        switch d.recovery {
        case .block(let session, let bid, let name):
            // Statuses, title and foreground: a dropped event is most often a large status.
            let sid = session ?? views.first { $0.value.windowContaining(block: bid) != nil }?.key
            if let sid, !hiddenSessions().contains(sid) { readDroppedBlock(sid, bid) }
            for handler in router.handlers(forBlockEvent: name) { handler(sid, bid) }
        case .sessionView(let sid):
            touchedSessions.insert(sid)
            refreshView(sid)
        case .sessionList:
            reloadSessionList()
        case .hosts:
            Task { await loadHosts() }
            loadCreators()
        case .keymap:
            keymap.configChanged(hash: nil)
        case .creators:
            loadCreators()
        case .clients:
            // The one client the app follows is the push helper.
            push?.relayChanged(self)
        case .ignore:
            break
        case .everything:
            scheduleResync()
        }
    }

    /// One metadata read per block for a burst of dropped block events.
    func readDroppedBlock(_ sid: String, _ bid: String) {
        droppedBlocks[bid] = sid
        guard droppedBlocksTask == nil else { return }
        droppedBlocksTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.coalesce * 1_000_000_000))
            guard let self else { return }
            let blocks = self.droppedBlocks.map { (session: $0.value, block: $0.key) }
            self.droppedBlocks = [:]
            self.droppedBlocksTask = nil
            await self.loadMeta(blocks)
        }
    }

    /// Reads which sessions exist and in what order (`session.list`), for `session_moved` and for
    /// a dropped `session_created`, `session_destroyed` or `session_moved`: sessions that are gone
    /// leave, new ones are attached, and the rest take the server's order.
    ///
    /// One read at a time. An event while it is out asks for one more, and a read that an event
    /// or a full sync came after is dropped (`sessionListGeneration`), so an older list never
    /// lands after a newer one.
    func reloadSessionList() {
        sessionListGeneration += 1
        sessionListAgain = true
        guard sessionListTask == nil else { return }
        let serial = connectionSerial
        sessionListTask = Task { [weak self] in
            // A burst of events (one per session in a reorder) waits for one read.
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard let self else { return }
            defer { self.sessionListTask = nil }
            while self.sessionListAgain {
                self.sessionListAgain = false
                let generation = self.sessionListGeneration
                guard let r = try? await self.control.call("session.list"), serial == self.connectionSerial else { return }
                guard generation == self.sessionListGeneration else { continue }
                await self.applySessionList(r)
            }
        }
    }

    private func applySessionList(_ r: JSONObject) async {
        let hidden = hiddenSessions()
        let listed = r.arr("sessions").compactMap { s -> SessionEntry? in
            guard let id = s.str("session_id"), !hidden.contains(id) else { return nil }
            return SessionEntry(id: id, label: s.str("label") ?? "")
        }
        let order = listed.map(\.id)
        let known = Set(sessions.map(\.id))
        let gone = known.subtracting(order)
        var next = sessions.filter { !gone.contains($0.id) }
        let fresh = listed.filter { !known.contains($0.id) }
        next.append(contentsOf: fresh)
        next.sort { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
        if next != sessions { sessions = next }
        for id in gone where views[id] != nil { views[id] = nil }
        for s in fresh {
            touchedSessions.insert(s.id)
            await attach(s.id)
        }
    }

    // MARK: Prompts

    /// `client_prompt_requested`. A prompt nobody takes is declined before this returns, at
    /// every API revision: `not_supported` takes only this app out of the prompt, where no answer
    /// would leave the action waiting on this app until its timeout.
    func receivePrompt(_ p: JSONObject) {
        guard let request = PromptRequest(p, connectionSerial: connectionSerial) else { return }
        if request.isKnownKind, prompts.onPrompt?(request) == true { return }
        control.post("client.reply", PromptRequest.decline(callID: request.callID))
    }
}
