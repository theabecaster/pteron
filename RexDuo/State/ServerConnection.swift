import SwiftUI
import UserNotifications

struct SessionEntry: Identifiable, Equatable {
    var id: String
    var label: String
}

/// One block's metadata, observed on its own.
@MainActor
@Observable
final class BlockMetaBox {
    var value: BlockMeta?
}

/// `server.meta[blockID]` reads and writes a block's metadata through its own observable box.
@MainActor
struct MetaTable {
    let server: ServerConnection

    subscript(id: String) -> BlockMeta? {
        get { server.metaBox(id).value }
        nonmutating set {
            let box = server.metaBox(id)
            if box.value != newValue { box.value = newValue }
        }
    }
}

struct HostEntry: Identifiable, Equatable {
    var id: String
    var label: String
    var endpoints: [String]
}

/// Everything known about one Rex server: its sessions, their layouts, and live block metadata.
///
/// Sync rules, kept simple:
/// - The server is the truth. A full resync (sessions, views, meta) replaces local state on first
///   connect, on every reconnect, on return to the foreground and when an event `seq` gap shows we
///   missed something. Every action ends by re-reading the server's view of the session.
/// - The UI stays calm: per-block events are coalesced into one update per ~150 ms, a status is held
///   on screen for at least a second (a new "blocked" shows at once), and connection drops only show
///   once they last more than a second.
@MainActor
@Observable
final class ServerConnection: Identifiable {
    enum Phase: Equatable { case idle, connecting, online, offline(String) }

    let config: ServerConfig
    nonisolated var id: UUID { config.id }
    let control: RexControl
    /// What each hardware key does: Rex's defaults under the user's init.lua (`client.keymap`).
    @ObservationIgnored let keymap: KeymapStore

    /// Connection state for the UI. A drop from online shows only after it lasts `phaseGrace`.
    var phase: Phase = .idle
    var sessions: [SessionEntry] = []
    var views: [String: SessionView] = [:]
    /// Live per-block metadata. Each block has its own observable box, so a status change in one pane
    /// only re-renders the views that read that pane (not every view that touches the server).
    var meta: MetaTable { MetaTable(server: self) }
    var hosts: [HostEntry] = []
    var hostName: String?
    var lastError: String?

    @ObservationIgnored fileprivate var metaBoxes: [String: BlockMetaBox] = [:]
    @ObservationIgnored private var rawPhase: Phase = .idle
    @ObservationIgnored private var phaseTask: Task<Void, Never>?
    @ObservationIgnored private var refreshScheduled: Set<String> = []
    @ObservationIgnored private var started = false
    // Resync bookkeeping.
    @ObservationIgnored private var lastSeq = 0
    @ObservationIgnored private var resyncTask: Task<Void, Never>?
    @ObservationIgnored private var syncing = false
    @ObservationIgnored private var syncAgain = false
    @ObservationIgnored private var touchedBlocks: Set<String> = []
    @ObservationIgnored private var touchedSessions: Set<String> = []
    // Coalescing and status hold.
    @ObservationIgnored private var pendingMeta: [String: BlockMeta] = [:]
    @ObservationIgnored private var statusShownAt: [String: Date] = [:]
    @ObservationIgnored private var flushTask: Task<Void, Never>?

    static let phaseGrace: Double = 1.0
    static let coalesce: Double = 0.15
    static let minStatusHold: Double = 1.0

    fileprivate func metaBox(_ id: String) -> BlockMetaBox {
        if let b = metaBoxes[id] { return b }
        let b = BlockMetaBox()
        metaBoxes[id] = b
        return b
    }

    init(config: ServerConfig) {
        self.config = config
        let url = URL(string: config.url.trimmingCharacters(in: .whitespacesAndNewlines)) ?? URL(string: "https://invalid.local")!
        control = RexControl(baseURL: url)
        keymap = KeymapStore(control: control)
        control.onEvent = { [weak self] seq, ev in self?.receive(seq: seq, event: ev) }
        control.onStateChange = { [weak self] st in
            guard let self else { return }
            switch st {
            case .connecting: self.setPhase(.connecting)
            case .connected: self.setPhase(.online)
            case .failed(let m): self.setPhase(.offline(m))
            case .idle: self.setPhase(.idle)
            }
        }
        control.onReconnected = { [weak self] _ in
            // Events that happened while disconnected are lost: start over from the server's state.
            self?.scheduleResync(after: 0)
        }
    }

    // MARK: Connection

    private func setPhase(_ p: Phase) {
        rawPhase = p
        phaseTask?.cancel()
        phaseTask = nil
        // Coming online, going idle, or still on the first connect: show it now.
        if p == .online || p == .idle || phase != .online {
            if phase != p { phase = p }
            return
        }
        // A drop from online: wait out short blips.
        phaseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.phaseGrace * 1_000_000_000))
            guard !Task.isCancelled, let self, self.rawPhase != .online else { return }
            self.phase = self.rawPhase
        }
    }

    func start() {
        guard !started else { control.kick(); return }
        started = true
        Task {
            do {
                setPhase(.connecting)
                try await control.connect()
                lastSeq = 0
                await bootstrap()
            } catch {
                setPhase(.offline(error.localizedDescription))
                lastError = error.localizedDescription
                // RexControl only auto-retries after a successful first connect; retry here.
                started = false
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if case .offline = rawPhase { start() }
            }
        }
    }

    func stop() {
        control.disconnect()
        started = false
        setPhase(.idle)
    }

    /// Back in the foreground: reconnect if needed (which resyncs), or resync the live connection.
    func resume() {
        start()
        if rawPhase == .online { scheduleResync(after: 0) }
    }

    /// Pull to refresh: reload everything when online, otherwise reconnect.
    func refresh() async {
        if rawPhase == .online {
            await bootstrap()
        } else {
            stop()
            start()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    // MARK: Full sync

    func scheduleResync(after delay: Double = 0.25) {
        resyncTask?.cancel()
        resyncTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            await self.bootstrap()
        }
    }

    /// Reads the whole server state and replaces the local copy with it.
    func bootstrap() async {
        if syncing { syncAgain = true; return }
        syncing = true
        touchedBlocks = []
        touchedSessions = []
        defer {
            syncing = false
            if syncAgain { syncAgain = false; scheduleResync(after: 0.1) }
        }
        do {
            let r = try await control.call("session.bootstrap", ["event_scope": "all", "attach_session_ids": [String]()])
            if let st = r.obj("server_status"), let ts = st.obj("tailscale") {
                hostName = ts.str("dns_name")
            }
            let list = (r.obj("attach_all")?.arr("sessions") ?? []).map {
                SessionEntry(id: $0.str("session_id") ?? "", label: $0.str("label") ?? "")
            }
            var fresh: [String: SessionView] = [:]
            await withTaskGroup(of: SessionView?.self) { g in
                for s in list { g.addTask { await self.fetchView(s.id) } }
                for await v in g { if let v { fresh[v.sessionID] = v } }
            }
            // Replace, don't merge. Sessions changed by events during the sync get one more read.
            sessions = list.map { e in SessionEntry(id: e.id, label: fresh[e.id]?.label ?? e.label) }
            views = fresh
            for sid in touchedSessions { refreshView(sid) }
            let blocks = fresh.values.flatMap { v in
                v.windows.flatMap(\.allBlocks).filter(\.isTerminal).map { (v.sessionID, $0.id) }
            }
            await loadMeta(blocks)
            await loadHosts()
            await keymap.load()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func fetchView(_ sessionID: String) async -> SessionView? {
        guard let r = try? await control.call("session.attach", ["session_id": sessionID]), let v = r.obj("view") else { return nil }
        return SessionView(v)
    }

    func loadHosts() async {
        if let r = try? await control.call("hosts.list") {
            hosts = r.arr("hosts").map { HostEntry(id: $0.str("id") ?? "", label: $0.str("label") ?? "host",
                                                   endpoints: ($0["endpoints"] as? [String]) ?? []) }
        }
    }

    /// Attaches one new session (for `session_created`).
    func attach(_ sessionID: String) async {
        guard let v = await fetchView(sessionID) else { return }
        apply(view: v)
        await loadMeta(v.windows.flatMap(\.allBlocks).filter(\.isTerminal).map { (sessionID, $0.id) })
    }

    private func apply(view: SessionView) {
        if let old = views[view.sessionID], old.revision > view.revision { return }
        views[view.sessionID] = view
        if let i = sessions.firstIndex(where: { $0.id == view.sessionID }) {
            if sessions[i].label != view.label { sessions[i].label = view.label }
        } else {
            sessions.append(SessionEntry(id: view.sessionID, label: view.label))
        }
    }

    /// Re-reads a session's layout from the server. Bursts of calls collapse into one read.
    func refreshView(_ sessionID: String) {
        guard !refreshScheduled.contains(sessionID) else { return }
        refreshScheduled.insert(sessionID)
        Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            refreshScheduled.remove(sessionID)
            if let r = try? await control.call("session.view", ["session_id": sessionID]) {
                let v = r.obj("view") ?? r
                apply(view: SessionView(v))
            }
        }
    }

    /// Reads status, title and process for the blocks and replaces what we had for them.
    private func loadMeta(_ blocks: [(session: String, block: String)]) async {
        await withTaskGroup(of: (String, BlockMeta?, String??, String??).self) { g in
            for (sid, bid) in blocks {
                g.addTask { @MainActor in
                    async let st = try? self.control.blockCall("com.superlogical.terminal.program_status", session: sid, block: bid)
                    async let ti = try? self.control.blockCall("com.superlogical.terminal.title", session: sid, block: bid)
                    async let pr = try? self.control.blockCall("com.superlogical.terminal.process", session: sid, block: bid)
                    var statuses: BlockMeta?
                    if let st = await st {
                        var m = BlockMeta()
                        for rec in st.arr("records") { m.statuses[rec.str("id") ?? ""] = ProgramStatus(rec) }
                        statuses = m
                    }
                    // Outer nil: the call failed, keep what we had. Inner nil: the server has none.
                    let title: String?? = await ti.map { $0.str("title") }
                    let fg: String?? = await pr.map { $0.obj("foreground").map(Self.processLabel) }
                    return (bid, statuses, title, fg)
                }
            }
            for await (bid, statuses, title, fg) in g where !touchedBlocks.contains(bid) {
                var cur = pendingMeta[bid] ?? meta[bid] ?? BlockMeta()
                if let statuses { cur.statuses = statuses.statuses }
                if let title { cur.title = title }
                if let fg { cur.foreground = fg }
                pendingMeta[bid] = nil
                statusShownAt[bid] = Date()
                meta[bid] = cur
            }
        }
    }

    nonisolated static func processLabel(_ fg: JSONObject) -> String {
        if let s = fg.str("script"), !s.isEmpty { return (s as NSString).lastPathComponent }
        if let a = fg.str("invoked_path") ?? fg.str("argv0"), !a.isEmpty {
            return (a.trimmingCharacters(in: CharacterSet(charactersIn: "-")) as NSString).lastPathComponent
        }
        return fg.str("name") ?? ""
    }

    // MARK: Events

    private func receive(seq: Int, event: JSONObject) {
        if seq > 0 {
            // seq counts events on this connection from 1, with no gaps. A jump means we missed some.
            if seq > 1, lastSeq > 0, seq > lastSeq + 1 { scheduleResync() }
            lastSeq = seq
        }
        handle(event: event)
    }

    private func handle(event: JSONObject) {
        let type = event.str("type") ?? ""
        let p = event.obj("payload") ?? [:]
        switch type {
        case "session_created":
            if let s = p.obj("session"), let id = s.str("session_id") {
                if !sessions.contains(where: { $0.id == id }) { sessions.append(SessionEntry(id: id, label: s.str("label") ?? "")) }
                touchedSessions.insert(id)
                Task { await attach(id) }
            }
        case "session_destroyed":
            let id = p.str("session_id") ?? p.obj("session")?.str("session_id") ?? ""
            sessions.removeAll { $0.id == id }
            views[id] = nil
        case "session_moved":
            Task {
                if let r = try? await control.call("session.list") {
                    let order = r.arr("sessions").compactMap { $0.str("session_id") }
                    sessions.sort { (order.firstIndex(of: $0.id) ?? 0) < (order.firstIndex(of: $1.id) ?? 0) }
                }
            }
        case "hosts_changed":
            Task { await loadHosts() }
        case "keymap_changed":
            keymap.configChanged(hash: p.str("hash"))
        case "session_event":
            guard let sid = p.str("session_id"), let ev = p.obj("event") else { return }
            handle(sessionID: sid, event: ev)
        default:
            break
        }
    }

    private func handle(sessionID sid: String, event ev: JSONObject) {
        let type = ev.str("type") ?? ""
        let p = ev.obj("payload") ?? [:]
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
            touchedSessions.insert(sid)
            refreshView(sid)
            if let bid = p.str("block_id") {
                Task { try? await Task.sleep(nanoseconds: 300_000_000); await loadMeta([(sid, bid)]) }
            }
        case "block_event":
            handleBlockEvent(sessionID: sid, p)
        case "window_created", "window_closed", "window_label_changed", "active_window_changed", "block_closed", "block_owner_changed":
            touchedSessions.insert(sid)
            refreshView(sid)
        default:
            break
        }
    }

    private func handleBlockEvent(sessionID sid: String, _ p: JSONObject) {
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
            if let fg = e.obj("foreground") { m.foreground = Self.processLabel(fg) } else { m.foreground = nil }
        case "program_status_changed":
            let id = e.str("id") ?? ""
            let prev = m.statuses[id]?.state
            if let rec = e.obj("record") {
                let st = ProgramStatus(rec)
                m.statuses[id] = st
                if st.state == "blocked", prev != "blocked" { notifyBlocked(sid, bid, st, m) }
            }
        case "program_status_removed":
            for id in (e["ids"] as? [String]) ?? [] { m.statuses[id] = nil }
        case "bell":
            m.bellAt = Date()
        case "child_exited":
            m.exited = true
        case "desktop_notification":
            postLocal(title: e.str("title").flatMap { $0.isEmpty ? nil : $0 } ?? label(for: sid, block: bid),
                      body: e.str("body") ?? "")
            return
        default:
            return
        }
        if syncing { touchedBlocks.insert(bid) }
        pendingMeta[bid] = m
        scheduleFlush(after: Self.coalesce)
    }

    // MARK: Coalescing

    private func scheduleFlush(after delay: Double) {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(delay, 0.01) * 1_000_000_000))
            self?.flush()
        }
    }

    /// Applies the buffered block updates in one go. A status that changed less than `minStatusHold`
    /// ago stays on screen a little longer, so badges don't flicker; a new "blocked" shows at once.
    private func flush() {
        flushTask = nil
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

    private func notifyBlocked(_ sid: String, _ bid: String, _ st: ProgramStatus, _ m: BlockMeta) {
        guard Prefs.shared.notifyOnBlocked else { return }
        let who = m.agentKind?.displayName ?? st.app ?? "A program"
        let why: String
        switch st.waitingFor {
        case "permission": why = "needs permission"
        case "question": why = "has a question"
        case "auth": why = "needs a password"
        default: why = "is waiting for you"
        }
        postLocal(title: "\(who) \(why)", body: [label(for: sid, block: bid), st.text].compactMap { $0 }.joined(separator: " — "))
        if Prefs.shared.haptics { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    }

    private func postLocal(title: String, body: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func label(for sid: String, block bid: String) -> String {
        let s = views[sid]
        let w = s?.windowContaining(block: bid)
        return [s?.label, w?.label].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " › ")
    }

    // MARK: Actions
    //
    // Each action asks the server, then re-reads the server's view of the session. Nothing guesses a
    // layout locally. A failure shows a short notice and the view is re-read, so the screen matches
    // the server either way.

    @discardableResult
    private func act(_ what: String, session sid: String?, _ body: () async throws -> JSONObject) async -> JSONObject? {
        do {
            let r = try await body()
            if let sid { refreshView(sid) }
            return r
        } catch {
            Notice.shared.show("Couldn't \(what). \(Self.short(error))")
            if let sid { refreshView(sid) }
            return nil
        }
    }

    private static func short(_ error: Error) -> String {
        let s = (error as? RexError).map { $0.message } ?? error.localizedDescription
        return s.count > 80 ? String(s.prefix(80)) : s
    }

    @discardableResult
    func createSession(label: String?) async -> String? {
        var p: JSONObject = ["initial_windows": [["layout": ["block": ["flavor": "com.superlogical.terminal.shell"]]]]]
        if let label, !label.isEmpty { p["label"] = label }
        guard let r = await act("create the session", session: nil, { try await self.control.call("session.create", p) }),
              let id = r.str("session_id") else { return nil }
        if !sessions.contains(where: { $0.id == id }) { sessions.append(SessionEntry(id: id, label: label ?? "")) }
        await attach(id)
        return id
    }

    func newWindow(_ sid: String, label: String? = nil) async {
        var p: JSONObject = ["session_id": sid, "layout": ["block": ["flavor": "com.superlogical.terminal.shell"]], "focus": true]
        if let label, !label.isEmpty { p["window_label"] = label }
        await act("open a tab", session: sid) { try await self.control.call("session.new_window", p) }
    }

    func split(_ sid: String, anchor: String, vertical: Bool) async {
        await act("split the pane", session: sid) {
            try await self.control.call("session.new_split", [
                "session_id": sid, "anchor_id": anchor, "direction": vertical ? "vertical" : "horizontal",
                "side": "after", "ratio": 0.5, "focus": true,
                "layout": ["block": ["flavor": "com.superlogical.terminal.shell"]],
            ])
        }
    }

    func closeBlock(_ sid: String, _ bid: String) async {
        await act("close the pane", session: sid) { try await self.control.call("block.close", ["session_id": sid, "block_id": bid]) }
    }

    func closeWindow(_ sid: String, _ wid: String) async {
        await act("close the tab", session: sid) { try await self.control.call("session.close_window", ["session_id": sid, "window_id": wid]) }
    }

    func destroySession(_ sid: String) async {
        // Only drop it locally once the server agrees.
        guard await act("close the session", session: nil, { try await self.control.call("session.destroy", ["session_id": sid]) }) != nil else { return }
        sessions.removeAll { $0.id == sid }
        views[sid] = nil
    }

    func renameSession(_ sid: String, _ label: String) async {
        await act("rename the session", session: sid) { try await self.control.call("session.set_label", ["session_id": sid, "label": label]) }
    }

    func renameWindow(_ sid: String, _ wid: String, _ label: String) async {
        await act("rename the tab", session: sid) {
            try await self.control.call("session.set_window_label", ["session_id": sid, "window_id": wid, "label": label])
        }
    }

    func focus(_ sid: String, block: String) async {
        _ = try? await control.call("session.focus_block", ["session_id": sid, "block_id": block])
    }

    func focusWindow(_ sid: String, _ wid: String) async {
        _ = try? await control.call("session.focus_window", ["session_id": sid, "window_id": wid])
    }

    func zoom(_ sid: String, block: String, on: Bool?) async {
        var p: JSONObject = ["session_id": sid, "block_id": block]
        if let on { p["zoom"] = on }
        await act("zoom the pane", session: sid) { try await self.control.call("session.zoom_block", p) }
    }

    func resizePane(_ sid: String, direction: String, before: String, after: String, ratio: Double) async {
        await act("resize the pane", session: sid) {
            try await self.control.call("session.resize_pane", [
                "session_id": sid, "direction": direction, "before_block_id": before, "after_block_id": after,
                "ratio": min(max(ratio, 0.05), 0.95),
            ])
        }
    }

    /// Types text into a pane (quick replies). Escape sequences work: "\u{1b}" is Esc, "\r" is Enter.
    func write(_ sid: String, _ bid: String, _ text: String) async {
        await act("send to the pane", session: nil) {
            try await self.control.blockCall("com.superlogical.terminal.write", session: sid, block: bid, args: ["data": text])
        }
    }

    /// Sends a composed message: the text, then Enter as a separate write so agents don't treat the
    /// Enter as part of a paste. Multi-line text goes in as a bracketed paste.
    func submit(_ sid: String, _ bid: String, _ text: String) async {
        if !text.isEmpty {
            let body = text.contains("\n") ? "\u{1b}[200~" + text + "\u{1b}[201~" : text
            await write(sid, bid, body)
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        await write(sid, bid, "\r")
    }

    /// The last lines of a pane as plain text (tab overview cards).
    func preview(_ sid: String, _ bid: String, lines: Int = 16) async -> String? {
        let window = 6000
        guard let r = try? await control.blockCall("com.superlogical.terminal.format", session: sid, block: bid,
                                                   args: ["format": "text", "trim": true, "max_bytes": window]) else { return nil }
        var text = r.str("content") ?? ""
        if let id = r.int("id"), let total = r.int("total"), total > window,
           let tail = try? await control.blockCall("com.superlogical.terminal.blob_read", session: sid, block: bid,
                                                   args: ["id": id, "offset": total - window, "max_bytes": window]) {
            text = tail.str("data") ?? text
        }
        let rows = text.split(separator: "\n", omittingEmptySubsequences: false)
        var trimmed = rows[...]
        while let last = trimmed.last, last.trimmingCharacters(in: .whitespaces).isEmpty { trimmed = trimmed.dropLast() }
        return trimmed.suffix(lines).joined(separator: "\n")
    }

    func clear(_ sid: String, _ bid: String) async {
        await act("clear the pane", session: nil) {
            try await self.control.blockCall("com.superlogical.terminal.clear", session: sid, block: bid)
        }
    }

    // MARK: Derived

    struct AgentRow: Identifiable {
        var id: String { blockID }
        var sessionID: String
        var windowID: String
        var blockID: String
        var kind: AgentKind?
        var status: ProgramStatus?
        var title: String
        var place: String
    }

    var agents: [AgentRow] {
        var rows: [AgentRow] = []
        for s in sessions {
            guard let v = views[s.id] else { continue }
            for w in v.windows {
                for b in w.allBlocks where b.isTerminal {
                    let m = meta[b.id] ?? BlockMeta()
                    guard m.agentKind != nil || m.topStatus != nil else { continue }
                    rows.append(AgentRow(sessionID: s.id, windowID: w.id, blockID: b.id, kind: m.agentKind,
                                         status: m.topStatus, title: m.title ?? b.label,
                                         place: [v.label, w.label].filter { !$0.isEmpty }.joined(separator: " › ")))
                }
            }
        }
        let rank = ["blocked": 0, "error": 1, "working": 2, "done": 3, "idle": 4]
        return rows.sorted { (rank[$0.status?.state ?? "idle"] ?? 5) < (rank[$1.status?.state ?? "idle"] ?? 5) }
    }

    func windowStatus(_ w: WindowInfo) -> ProgramStatus? {
        let rank = ["blocked": 5, "error": 4, "working": 3, "done": 2, "idle": 1]
        return w.allBlocks.compactMap { meta[$0.id]?.topStatus }.max { (rank[$0.state] ?? 0) < (rank[$1.state] ?? 0) }
    }

    func windowAgent(_ w: WindowInfo) -> AgentKind? {
        w.allBlocks.lazy.compactMap { self.meta[$0.id]?.agentKind }.first
    }
}
