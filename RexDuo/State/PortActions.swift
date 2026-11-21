import Foundation
import RexKit
import UIKit

/// What a row of the Ports group does: open its page, copy its link, show its pane, stop its
/// program (docs/terminal.md, Ports). Owned by `AppModel`; the sidebar and the palette call it.
///
/// Stop types one Ctrl-C into the pane, once, and only under `PortStop`'s rule, checked against
/// the server right before the write. It never names a process to the computer and never sends
/// a second interrupt by itself: a program that keeps its port after `stillAfter` is marked
/// "Still running", and Stop is there to tap again.
@MainActor
@Observable
final class PortActions {
    enum Status: Equatable {
        /// Ctrl-C left; the port hasn't gone yet.
        case stopping
        /// The port is still there `stillAfter` after a Ctrl-C.
        case stillRunning
    }

    /// How a Stop ended, for tests.
    enum Outcome: Equatable {
        case sent, busy, offline, unanswered, gone, refused(PortStop.Verdict), unsent, closed
    }

    struct Parts {
        var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max($0, 0) * 1_000_000_000)) }
        /// The longest the pane's process read may take.
        var readLimit: TimeInterval = 5
        /// The longest the Ctrl-C may wait to leave, behind what was typed on the phone.
        var leaveLimit: TimeInterval = 3
        /// How long after a Ctrl-C a port that is still there counts as still running.
        var stillAfter: TimeInterval = 5
        var copy: @MainActor (String) -> Void = { UIPasteboard.general.string = $0 }
        /// Says why something the person tapped didn't happen, with Show Pane where it helps.
        var notify: @MainActor (String, Notice.Action?) -> Void = { Notice.shared.show($0, style: .neutral, action: $1) }
        /// A test launch's session label (`-autoOpen <label>`): only that session's panes are typed into.
        var only: @MainActor () -> String? = { UserDefaults.standard.string(forKey: "autoOpen") }
        /// Types the Ctrl-C, once: through the pane's own input queue when it is on screen, else
        /// as one call. `mayWrite` is asked as the last thing before the text is handed over.
        var write: @MainActor (ServerConnection, _ session: String, _ block: String, _ limit: TimeInterval,
                               _ mayWrite: @escaping @MainActor () -> Bool) async -> TerminalStream.Delivery = { server, sid, bid, limit, may in
            await LiveActionChannel(server).write("\u{3}", session: sid, block: bid, within: limit, mayWrite: may)
        }
    }

    private struct Mark: Equatable {
        var status: Status
        /// The process the Ctrl-C was for: a mark never shows on another one's row.
        var pid: Int
    }

    @ObservationIgnored private weak var model: AppModel?
    /// The view pages are presented over. Tests put their own here.
    @ObservationIgnored var presenter: @MainActor () -> UIView? = { GoToCenter.keyWindow()?.rootViewController?.view }
    @ObservationIgnored var parts: Parts
    private var marks: [String: Mark] = [:]

    init(model: AppModel?, parts: Parts = Parts()) {
        self.model = model
        self.parts = parts
    }

    private static func key(_ server: ServerConnection, _ row: PortRow) -> String { "\(server.id.uuidString):\(row.id)" }

    /// The row as the server lists it now, by its id.
    func row(_ server: ServerConnection, id: String) -> PortRow? {
        server.portRow(id)
    }

    // MARK: Reading

    /// What the row says after a Stop, for the process the Stop was for.
    func status(_ server: ServerConnection, _ row: PortRow) -> Status? {
        guard let m = marks[Self.key(server, row)], m.pid == row.entry.pid else { return nil }
        return m.status
    }

    /// Stop shows for this row: the server is connected, no Ctrl-C is on its way, and the
    /// port's process is the pane's foreground process as last reported (`PortStop`).
    func offersStop(_ server: ServerConnection, _ row: PortRow) -> Bool {
        guard server.phase == .online, server.control.state == .connected, status(server, row) != .stopping else { return false }
        let meta = server.meta[row.blockID]
        return PortStop.verdict(entry: row.entry, foregroundPID: meta?.foregroundPID, agent: meta?.agentKind != nil) == .allowed
    }

    /// The row's link: the page as the phone opens it.
    func link(_ server: ServerConnection, _ row: PortRow) -> String {
        "http://\(row.entry.name)"
    }

    // MARK: Actions

    /// Opens the port's page in the app, as the pane menu's row does.
    func open(_ server: ServerConnection, _ row: PortRow) {
        let pane = PanePorts(server: server, sessionID: row.sessionID, blockID: row.blockID)
        pane.view = presenter()
        pane.notify = { [parts] in parts.notify($0, nil) }
        pane.open(row.entry)
    }

    func copyLink(_ server: ServerConnection, _ row: PortRow) {
        parts.copy(link(server, row))
    }

    /// Puts the row's pane on screen: its tab, with the pane shown when only one fits.
    @discardableResult
    func showPane(_ server: ServerConnection, _ row: PortRow) -> Bool {
        guard let model, model.openPane(server, session: row.sessionID, window: nil, block: row.blockID) else {
            parts.notify(Messages.paneClosed, nil)
            return false
        }
        return true
    }

    func stop(_ server: ServerConnection, _ row: PortRow) {
        Task { await stopNow(server, row) }
    }

    /// One Stop: the pane's processes are read now, `PortStop` decides, and one Ctrl-C goes
    /// through the pane's own input queue when it is on screen, else as one call. Nothing is
    /// tried twice.
    @discardableResult
    func stopNow(_ server: ServerConnection, _ row: PortRow) async -> Outcome {
        let key = Self.key(server, row), sid = row.sessionID, bid = row.blockID, port = row.entry.port
        let name = PortNames.program(row.entry) ?? row.entry.name
        guard marks[key]?.status != .stopping else { return .busy }
        guard let pid = row.entry.pid else { return fail(key, .refused(.unknownProcess), "Couldn't stop \(name). Show its pane to stop it there.", server, row) }
        if let label = parts.only(), server.sessions.first(where: { $0.id == sid })?.label != label {
            return .refused(.notForeground)
        }
        guard server.phase == .online, server.control.state == .connected else {
            return fail(key, .offline, "Couldn't stop \(name). \(Messages.offline(server.config.name))")
        }
        marks[key] = Mark(status: .stopping, pid: pid)
        let control = server.control
        let reply = await within(parts.readLimit) {
            try? await control.blockCall("com.superlogical.terminal.process", session: sid, block: bid)
        }
        guard let reply else {
            return fail(key, .unanswered, "Couldn't stop \(name): its pane didn't answer. Nothing was sent.", server, row)
        }
        let fg = PortStop.foreground(reply)
        let seen = server.currentMeta(bid)
        let verdict = PortStop.verdict(entry: server.ports.value(bid)?.entry(port), expected: pid, foregroundPID: fg.pid,
                                       agent: fg.agent || seen?.agentKind != nil)
        switch verdict {
        case .allowed:
            break
        case .gone:
            // It stopped by itself meanwhile: nothing to say.
            marks[key] = nil
            return .gone
        case .unknownProcess, .notForeground, .agent:
            return fail(key, .refused(verdict), "Couldn't stop \(name): another program is running in its pane now. Nothing was sent.", server, row)
        }
        // From here on nothing is tried twice. The last look, with nothing between it and the
        // write: the port is still that process's, and no event has named another foreground.
        let delivery = await parts.write(server, sid, bid, parts.leaveLimit) {
            server.ports.value(bid)?.entry(port)?.pid == pid && server.currentMeta(bid)?.foregroundPID == seen?.foregroundPID
        }
        switch delivery {
        case .delivered, .unknown:
            watch(server, key: key, block: bid, port: port, pid: pid)
            return .sent
        case .unsent:
            return fail(key, .unsent, "Couldn't stop \(name): the connection dropped. Nothing was sent.", server, row)
        case .refused:
            return fail(key, .closed, "Couldn't stop \(name). \(Messages.paneClosed)")
        }
    }

    /// One look, `stillAfter` after the Ctrl-C: a port that is still that process's is marked
    /// still running. A port that went takes its mark with it.
    private func watch(_ server: ServerConnection, key: String, block: String, port: Int, pid: Int) {
        let sleep = parts.sleep, wait = parts.stillAfter
        Task { [weak self, weak server] in
            await sleep(wait)
            guard let self, self.marks[key] == Mark(status: .stopping, pid: pid) else { return }
            let there = server?.ports.value(block)?.entry(port)?.pid == pid
            self.marks[key] = there ? Mark(status: .stillRunning, pid: pid) : nil
        }
    }

    private func fail(_ key: String, _ outcome: Outcome, _ text: String, _ server: ServerConnection? = nil, _ row: PortRow? = nil) -> Outcome {
        if marks[key]?.status == .stopping { marks[key] = nil }
        var action: Notice.Action?
        if let server, let row {
            action = Notice.Action(title: "Show Pane") { [weak self, weak server] in
                if let self, let server { self.showPane(server, row) }
            }
        }
        parts.notify(text, action)
        return outcome
    }

    /// Which of the work and the limit ended first. Used on the main actor only.
    @MainActor
    private final class Race {
        var over = false
    }

    /// `work`'s value, or nil when it took longer than `limit`; what it gives later is dropped.
    private func within<T>(_ limit: TimeInterval, _ work: @escaping @MainActor () async -> T?) async -> T? {
        let race = Race()
        let sleep = parts.sleep
        return await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
            Task { @MainActor in
                let value = await work()
                guard !race.over else { return }
                race.over = true
                done.resume(returning: value)
            }
            Task { @MainActor in
                await sleep(limit)
                guard !race.over else { return }
                race.over = true
                done.resume(returning: nil)
            }
        }
    }
}
