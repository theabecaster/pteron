import SwiftUI
import UserNotifications

struct SessionEntry: Identifiable, Equatable {
    var id: String
    var label: String
}

struct HostEntry: Identifiable, Equatable {
    var id: String
    var label: String
    var endpoints: [String]
}

/// Everything known about one Rex server: its sessions, their layouts, and live block metadata.
@MainActor
@Observable
final class ServerConnection: Identifiable {
    enum Phase: Equatable { case idle, connecting, online, offline(String) }

    let config: ServerConfig
    var id: UUID { config.id }
    let control: RexControl

    var phase: Phase = .idle
    var sessions: [SessionEntry] = []
    var views: [String: SessionView] = [:]
    var meta: [String: BlockMeta] = [:]
    var hosts: [HostEntry] = []
    var hostName: String?
    var lastError: String?

    private var refreshScheduled: Set<String> = []
    private var started = false

    init(config: ServerConfig) {
        self.config = config
        let url = URL(string: config.url.trimmingCharacters(in: .whitespacesAndNewlines)) ?? URL(string: "https://invalid.local")!
        control = RexControl(baseURL: url)
        control.onEvent = { [weak self] seq, ev in self?.handle(event: ev) }
        control.onStateChange = { [weak self] st in
            guard let self else { return }
            switch st {
            case .connecting: if self.phase != .online { self.phase = .connecting }
            case .connected: self.phase = .online
            case .failed(let m): self.phase = .offline(m)
            case .idle: self.phase = .idle
            }
        }
        control.onReconnected = { [weak self] _ in
            Task { await self?.bootstrap() }
        }
    }

    func start() {
        guard !started else { control.kick(); return }
        started = true
        Task {
            do {
                phase = .connecting
                try await control.connect()
                await bootstrap()
            } catch {
                phase = .offline(error.localizedDescription)
                lastError = error.localizedDescription
                // RexControl only auto-retries after a successful first connect; retry here.
                started = false
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                if case .offline = phase { start() }
            }
        }
    }

    func stop() {
        control.disconnect()
        started = false
        phase = .idle
    }

    func bootstrap() async {
        do {
            let r = try await control.call("session.bootstrap", ["event_scope": "all", "attach_session_ids": [String]()])
            if let st = r.obj("server_status"), let ts = st.obj("tailscale") {
                hostName = ts.str("dns_name")
            }
            let list = r.obj("attach_all")?.arr("sessions") ?? []
            sessions = list.map { SessionEntry(id: $0.str("session_id") ?? "", label: $0.str("label") ?? "") }
            await withTaskGroup(of: Void.self) { g in
                for s in sessions { g.addTask { await self.attach(s.id) } }
            }
            await loadHosts()
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func loadHosts() async {
        if let r = try? await control.call("hosts.list") {
            hosts = r.arr("hosts").map { HostEntry(id: $0.str("id") ?? "", label: $0.str("label") ?? "host",
                                                   endpoints: ($0["endpoints"] as? [String]) ?? []) }
        }
    }

    func attach(_ sessionID: String) async {
        do {
            let r = try await control.call("session.attach", ["session_id": sessionID])
            if let v = r.obj("view") { apply(view: SessionView(v)) }
            await loadMeta(sessionID)
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func apply(view: SessionView) {
        if let old = views[view.sessionID], old.revision > view.revision { return }
        views[view.sessionID] = view
        if let i = sessions.firstIndex(where: { $0.id == view.sessionID }) {
            sessions[i].label = view.label
        } else {
            sessions.append(SessionEntry(id: view.sessionID, label: view.label))
        }
    }

    func refreshView(_ sessionID: String) {
        guard !refreshScheduled.contains(sessionID) else { return }
        refreshScheduled.insert(sessionID)
        Task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            refreshScheduled.remove(sessionID)
            if let r = try? await control.call("session.view", ["session_id": sessionID]) {
                let v = r.obj("view") ?? r
                apply(view: SessionView(v))
            }
        }
    }

    private func loadMeta(_ sessionID: String) async {
        guard let v = views[sessionID] else { return }
        let blocks = v.windows.flatMap(\.allBlocks).filter(\.isTerminal)
        await withTaskGroup(of: (String, BlockMeta).self) { g in
            for b in blocks {
                g.addTask { @MainActor in
                    var m = BlockMeta()
                    async let st = try? self.control.blockCall("com.superlogical.terminal.program_status", session: sessionID, block: b.id)
                    async let ti = try? self.control.blockCall("com.superlogical.terminal.title", session: sessionID, block: b.id)
                    async let pr = try? self.control.blockCall("com.superlogical.terminal.process", session: sessionID, block: b.id)
                    if let st = await st {
                        for rec in st.arr("records") { m.statuses[rec.str("id") ?? ""] = ProgramStatus(rec) }
                    }
                    m.title = await ti?.str("title")
                    if let fg = await pr?.obj("foreground") { m.foreground = Self.processLabel(fg) }
                    return (b.id, m)
                }
            }
            for await (id, m) in g {
                var cur = meta[id] ?? BlockMeta()
                cur.title = m.title ?? cur.title
                cur.foreground = m.foreground ?? cur.foreground
                if !m.statuses.isEmpty { cur.statuses = m.statuses }
                meta[id] = cur
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

    private func handle(event: JSONObject) {
        let type = event.str("type") ?? ""
        let p = event.obj("payload") ?? [:]
        switch type {
        case "session_created":
            if let s = p.obj("session"), let id = s.str("session_id") {
                if !sessions.contains(where: { $0.id == id }) { sessions.append(SessionEntry(id: id, label: s.str("label") ?? "")) }
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
            if rev > (views[sid]?.revision ?? -1) { refreshView(sid) }
        case "session_label_changed":
            if let l = p.str("label") {
                views[sid]?.label = l
                if let i = sessions.firstIndex(where: { $0.id == sid }) { sessions[i].label = l }
            }
        case "block_created":
            refreshView(sid)
            Task { try? await Task.sleep(nanoseconds: 300_000_000); await loadMeta(sid) }
        case "block_event":
            handleBlockEvent(sessionID: sid, p)
        case "window_created", "window_closed", "window_label_changed", "active_window_changed", "block_closed", "block_owner_changed":
            refreshView(sid)
        default:
            break
        }
    }

    private func handleBlockEvent(sessionID sid: String, _ p: JSONObject) {
        guard let bid = p.str("block_id") else { return }
        let name = p.str("name") ?? ""
        let e = p.obj("payload") ?? [:]
        var m = meta[bid] ?? BlockMeta()
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
        default:
            return
        }
        meta[bid] = m
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

    @discardableResult
    func createSession(label: String?) async -> String? {
        var p: JSONObject = ["initial_windows": [["layout": ["block": ["flavor": "com.superlogical.terminal.shell"]]]]]
        if let label, !label.isEmpty { p["label"] = label }
        guard let r = try? await control.call("session.create", p), let id = r.str("session_id") else { return nil }
        if !sessions.contains(where: { $0.id == id }) { sessions.append(SessionEntry(id: id, label: label ?? "")) }
        await attach(id)
        return id
    }

    func newWindow(_ sid: String, label: String? = nil) async {
        var p: JSONObject = ["session_id": sid, "layout": ["block": ["flavor": "com.superlogical.terminal.shell"]], "focus": true]
        if let label, !label.isEmpty { p["window_label"] = label }
        _ = try? await control.call("session.new_window", p)
        refreshView(sid)
    }

    func split(_ sid: String, anchor: String, vertical: Bool) async {
        _ = try? await control.call("session.new_split", [
            "session_id": sid, "anchor_id": anchor, "direction": vertical ? "vertical" : "horizontal",
            "side": "after", "ratio": 0.5, "focus": true,
            "layout": ["block": ["flavor": "com.superlogical.terminal.shell"]],
        ])
        refreshView(sid)
    }

    func closeBlock(_ sid: String, _ bid: String) async {
        _ = try? await control.call("block.close", ["session_id": sid, "block_id": bid])
        refreshView(sid)
    }

    func closeWindow(_ sid: String, _ wid: String) async {
        _ = try? await control.call("session.close_window", ["session_id": sid, "window_id": wid])
        refreshView(sid)
    }

    func destroySession(_ sid: String) async {
        _ = try? await control.call("session.destroy", ["session_id": sid])
        sessions.removeAll { $0.id == sid }
        views[sid] = nil
    }

    func renameSession(_ sid: String, _ label: String) async {
        _ = try? await control.call("session.set_label", ["session_id": sid, "label": label])
        refreshView(sid)
    }

    func renameWindow(_ sid: String, _ wid: String, _ label: String) async {
        _ = try? await control.call("session.set_window_label", ["session_id": sid, "window_id": wid, "label": label])
        refreshView(sid)
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
        _ = try? await control.call("session.zoom_block", p)
        refreshView(sid)
    }

    func resizePane(_ sid: String, direction: String, before: String, after: String, ratio: Double) async {
        _ = try? await control.call("session.resize_pane", [
            "session_id": sid, "direction": direction, "before_block_id": before, "after_block_id": after,
            "ratio": min(max(ratio, 0.05), 0.95),
        ])
    }

    func clear(_ sid: String, _ bid: String) async {
        _ = try? await control.blockCall("com.superlogical.terminal.clear", session: sid, block: bid)
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
