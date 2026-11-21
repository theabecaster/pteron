import Foundation
import Observation
import RexKit
import UIKit

/// What a row of the Ports group does: open its page, in the app or in the phone's browser,
/// copy its link, show its pane, stop its program and start it again (docs/terminal.md, Ports).
/// Owned by `AppModel`; the sidebar and the palette call it.
///
/// Open in Browser, Stop for a server behind a wrapper and Restart need the computer's Beacon
/// (`port_share`, `port_owner`). What a Beacon answered is kept per server for one connection
/// and asked again on the next; a computer without one, or with an older one, shows none of
/// the three. Nothing here asks or looks on a repeating timer: a port's owner is read once
/// when its row shows, a page is asked for only on a tap, and a Restart waits on Rex's own
/// events with one deadline for each wait.
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

    /// What a row shows beside its address, or under it for a Restart to confirm.
    enum Note: Equatable {
        /// The command a Restart would type, waiting for its one tap.
        case confirm(RestartCommand)
        case restarting
        case restartFailed
        case stopping
        case stillRunning
        /// Its page is out in the phone's browser.
        case inBrowser
    }

    /// How an Open in Browser ended, for tests.
    enum Browsed: Equatable {
        case opened(URL)
        case problem(PortBrowser.Problem)
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
        /// The connected computers and their ports. Nil: the model's servers, as held now.
        var machines: (@MainActor () -> [PortAddress.Machine])?
        /// Opens a web address that isn't a computer's own in the system's browser.
        var openURL: @MainActor (URL) -> Void = { UIApplication.shared.open($0) }
        /// One action of the computer's Beacon; nil when none holds this phone there. Nil here:
        /// the model's (`PushRegistrar.ask`).
        var beacon: (@MainActor (ServerConnection, _ action: String, _ args: JSONObject, _ timeout: Int) async -> Result<JSONObject, HelperFailure>?)?
        /// The phone's own tailnet address, read when asked.
        var phoneAddress: @MainActor () -> String? = { PrivateNetwork.address() }
        var now: @MainActor () -> Date = { Date() }
        /// The pane is on screen over a current screen: its stream runs and its fence is down.
        var paneReady: @MainActor (ServerConnection, _ block: String) -> Bool = { server, bid in
            guard server.portWatch[bid] != nil, let stream = server.control.stream(block: bid) else { return false }
            return !stream.isFenced
        }
        /// Puts the row's pane on screen. Nil: `showPane`, without its notice.
        var reveal: (@MainActor (ServerConnection, PortRow) -> Bool)?
        /// Types a Restart's command, once, through the pane's own input queue and nothing
        /// else: a pane without a running stream, or behind its fence, gets nothing.
        var type: @MainActor (ServerConnection, _ text: String, _ block: String, _ limit: TimeInterval,
                              _ mayWrite: @escaping @MainActor () -> Bool) async -> TerminalStream.Delivery = { server, text, bid, limit, may in
            guard let stream = server.control.stream(block: bid), !stream.isFenced, may() else { return .unsent }
            return await withCheckedContinuation { done in
                stream.sendOnce(text: text, within: .milliseconds(Int(limit * 1000))) { done.resume(returning: $0) }
            }
        }
        /// The longest a revealed pane may take to show a current screen.
        var revealLimit: TimeInterval = 5
        /// The longest the shell may take to be in front again with the port gone.
        var shellLimit: TimeInterval = PortRestart.shellLimit
        /// The longest the port may take to come back.
        var portLimit: TimeInterval = PortRestart.portLimit
        /// Runs its closure once the pane is on screen over a current screen, if it ever is.
        var whenPaneReady: @MainActor (ServerConnection, _ block: String, @escaping @MainActor () -> Void) -> Void = { server, bid, body in
            server.whenPaneCurrent(bid, body)
        }
        /// Seconds that only go forward, for what is left of a limit.
        var uptime: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        /// The computer's Beacon said, in the status the app last read, that it can hand pages
        /// to this iPhone's browser. Nil: the model's (`PushRegistrar.sharePossible`).
        var sharePossible: (@MainActor (ServerConnection) -> Bool)?
        /// How many statuses the app has read from the computer's Beacon. Nil: the model's.
        var statusReads: (@MainActor (ServerConnection) -> Int)?
        /// How long a row says that its Restart failed.
        var failedFor: TimeInterval = 30
        /// How long a Beacon may take to hand out a page's address.
        var shareLimit: TimeInterval = 8
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

    /// What a server's Beacon has shown of itself on one connection.
    private struct BeaconMark: Equatable {
        var serial: Int
        /// Nil until it answered `port_owner`; false when it can't (none, an older one, not
        /// this phone's).
        var names: Bool?
        /// False once an answer took Open in Browser away for this computer.
        var browser = true
        /// The Beacon's status said it could hand pages out and an answer then said it can't:
        /// the count of statuses read at that moment. The item is away until another is read.
        var staleAt: Int?
        /// The phone had a tailnet address when last read.
        var phone = false
    }

    private struct OwnerMark: Equatable {
        var pid: Int
        var serial: Int
        /// Nil: asked, and the Beacon couldn't read that process.
        var owner: PortOwner?
    }

    private struct ShareMark: Equatable {
        var share: PortShare
        var until: Date
        var serial: Int
        /// The process that held the port: another one's row is not out in the browser.
        var pid: Int?
    }

    private struct RestartMark: Equatable {
        var run: PortRestart
        var command: RestartCommand
        var pid: Int
    }

    private var beacons: [UUID: BeaconMark] = [:]
    private var owners: [String: OwnerMark] = [:]
    private var shares: [String: ShareMark] = [:]
    private var restarts: [String: RestartMark] = [:]
    /// Rows whose owner is being read now.
    @ObservationIgnored private var asking: Set<String> = []

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

    /// Stop shows for this row: the server is connected, no Ctrl-C or Restart is on its way,
    /// and an interrupt typed into the pane reaches the port's process as last reported
    /// (`PortStop`): it is the pane's foreground process, or, where the Beacon named its
    /// parents, in the foreground's process group.
    func offersStop(_ server: ServerConnection, _ row: PortRow) -> Bool {
        guard server.phase == .online, server.control.state == .connected, status(server, row) != .stopping,
              restart(server, row) == nil else { return false }
        let meta = server.meta[row.blockID]
        return PortStop.verdict(entry: row.entry, foregroundPID: meta?.foregroundPID, agent: meta?.agentKind != nil,
                                owner: owner(server, row)) == .allowed
    }

    /// The command Restart would type for this row, or nil when Restart isn't offered: the
    /// Beacon named the job, its command reads whole, and Stop's rule holds (`PortStop.restart`).
    func restartCommand(_ server: ServerConnection, _ row: PortRow) -> RestartCommand? {
        guard server.phase == .online, server.control.state == .connected, status(server, row) == nil,
              restart(server, row) == nil else { return nil }
        let meta = server.meta[row.blockID]
        return PortStop.restart(entry: row.entry, foregroundPID: meta?.foregroundPID, agent: meta?.agentKind != nil, owner: owner(server, row))
    }

    /// Open in Browser shows for this row: the server is connected; its Beacon said in its
    /// status that it can hand pages to this iPhone's browser (`share_possible`); it answered
    /// `port_owner` on this connection, so it is one that knows the action; no answer has
    /// said otherwise since; the phone has a tailnet address; and the port is one a computer
    /// hands out (`PortBrowser.mayAsk`). Nothing is asked to find out, so a tap is never how
    /// someone learns that their computer can't.
    func offersBrowser(_ server: ServerConnection, _ row: PortRow) -> Bool {
        guard server.phase == .online, server.control.state == .connected, PortBrowser.mayAsk(row.entry) else { return false }
        let b = beacon(server)
        guard b.names == true, b.browser, b.phone, sharePossible(server) else { return false }
        return b.staleAt != statusReads(server)
    }

    private func sharePossible(_ server: ServerConnection) -> Bool {
        if let given = parts.sharePossible { return given(server) }
        return model?.push.sharePossible(server.id) ?? false
    }

    private func statusReads(_ server: ServerConnection) -> Int {
        if let given = parts.statusReads { return given(server) }
        return model?.push.statusReads(server.id) ?? 0
    }

    /// The address the computer handed out for this row's page, while the app takes it to
    /// exist: on this connection, for the process that held the port, until shortly before
    /// the computer would end it unused.
    func shared(_ server: ServerConnection, _ row: PortRow) -> PortShare? {
        guard let m = shares[Self.key(server, row)], m.serial == server.connectionSerial, m.pid == row.entry.pid,
              parts.now() < m.until else { return nil }
        return m.share
    }

    /// The row's Restart, asked or under way. A question asked of a process that has since
    /// gone is no question of the one that holds the port now: that row is a plain row, with
    /// its own Stop and Restart.
    private func restart(_ server: ServerConnection, _ row: PortRow) -> RestartMark? {
        guard let r = restarts[Self.key(server, row)] else { return nil }
        return r.run.step == .confirming && r.pid != row.entry.pid ? nil : r
    }

    /// What the row shows beside its address.
    func note(_ server: ServerConnection, _ row: PortRow) -> Note? {
        if let r = restart(server, row) {
            switch r.run.step {
            case .confirming: return .confirm(r.command)
            case .failed: return .restartFailed
            case .done: break
            default: return .restarting
            }
        }
        switch status(server, row) {
        case .stopping: return .stopping
        case .stillRunning: return .stillRunning
        case nil: return shared(server, row) == nil ? nil : .inBrowser
        }
    }

    /// The row's link: the address the computer handed out when its page is out in the
    /// browser, else the page as the computer names it.
    func link(_ server: ServerConnection, _ row: PortRow) -> String {
        if let share = shared(server, row) {
            let text = share.url.absoluteString
            return text.hasSuffix("/") ? String(text.dropLast()) : text
        }
        return "http://\(row.entry.name)"
    }

    // MARK: The Beacon

    private func beacon(_ server: ServerConnection) -> BeaconMark {
        if let m = beacons[server.id], m.serial == server.connectionSerial { return m }
        return BeaconMark(serial: server.connectionSerial)
    }

    private func setBeacon(_ server: ServerConnection, _ change: (inout BeaconMark) -> Void) {
        var m = beacon(server)
        change(&m)
        if beacons[server.id] != m { beacons[server.id] = m }
    }

    private func ask(_ server: ServerConnection, _ action: String, _ args: JSONObject, timeout: Int) async -> Result<JSONObject, HelperFailure>? {
        if let given = parts.beacon { return await given(server, action, args, timeout) }
        return await model?.push.ask(server.id, action: action, args: args, timeout: timeout)
    }

    /// What the Beacon said of the row's process on this connection.
    private func owner(_ server: ServerConnection, _ row: PortRow) -> PortOwner? {
        guard let m = owners[Self.key(server, row)], m.pid == row.entry.pid, m.serial == server.connectionSerial else { return nil }
        return m.owner
    }

    /// The row shows: its process's owner is read, once per process and connection. Nothing is
    /// asked of a computer whose Beacon can't answer, and nothing twice at once.
    func learnOwner(_ server: ServerConnection, _ row: PortRow) {
        guard let pid = row.entry.pid, server.phase == .online, server.control.state == .connected,
              beacon(server).names != false else { return }
        let key = Self.key(server, row)
        if let m = owners[key], m.pid == pid, m.serial == server.connectionSerial { return }
        guard asking.insert(key).inserted else { return }
        Task {
            _ = await readOwner(server, key: key, pid: pid)
            asking.remove(key)
        }
    }

    /// One `port_owner` for a process, and what it says of the Beacon. Nil when nothing came,
    /// when the Beacon can't name processes, and when it couldn't read this one.
    private func readOwner(_ server: ServerConnection, key: String, pid: Int) async -> PortOwner? {
        let serial = server.connectionSerial
        let answer = await within(parts.readLimit) { [weak self] in
            await self?.ask(server, "port_owner", ["pid": pid], timeout: 4000)
        }
        guard serial == server.connectionSerial, let answer else { return nil }
        let phone = parts.phoneAddress() != nil
        switch answer {
        case .success(let result):
            // An answer about another process is no answer about this one.
            let owner = PortOwner(result).flatMap { $0.pid == pid ? $0 : nil }
            setBeacon(server) { $0.names = true; $0.phone = phone }
            let mark = OwnerMark(pid: pid, serial: serial, owner: owner)
            if owners[key] != mark { owners[key] = mark }
            return owner
        case .failure(let f):
            if PortBeaconAnswer.ownerMissing(code: f.code, unknownAction: f.isUnknownAction) {
                setBeacon(server) { $0.names = false }
            } else if f.code == "not_available" || f.code == "bad_request" {
                // The Beacon answers; it couldn't read this process.
                setBeacon(server) { $0.names = true; $0.phone = phone }
                owners[key] = OwnerMark(pid: pid, serial: serial, owner: nil)
            }
            return nil
        }
    }

    #if DEBUG
    /// `-portsTest` (testing): what the app holds of the row's Beacon and owner, and what it
    /// makes of them, on one line.
    func testSummary(_ server: ServerConnection, _ row: PortRow) -> String {
        let b = beacon(server), meta = server.currentMeta(row.blockID)
        var parts = ["names=\(b.names.map { "\($0)" } ?? "nil") browser=\(b.browser) phone=\(b.phone) sharePossible=\(sharePossible(server))",
                     "fg=\(meta?.foregroundPID.map { "\($0)" } ?? "nil")/\(meta?.foreground ?? "-") agent=\(meta?.agentKind != nil) portPid=\(row.entry.pid.map { "\($0)" } ?? "nil")"]
        if let o = owner(server, row) {
            let leader = o.job?.leader
            parts.append("owner pid=\(o.pid) pgid=\(o.pgid) ttyFg=\(o.ttyForegroundPGID.map { "\($0)" } ?? "nil") jobMembers=\(o.jobMembers.map { "\($0)" } ?? "nil") "
                + "chain=\(o.ancestry.map { "\($0.name):\($0.pid)" }.joined(separator: ">")) "
                + "leader=\(leader?.name ?? "-") argvCount=\(leader?.argv?.count ?? -1) argvEmpty=\(leader?.argv?.filter(\.isEmpty).count ?? -1) "
                + "argv0Spaces=\(leader?.argv?.first?.contains(" ") ?? false) reaches=\(o.interruptReaches(foregroundPID: meta?.foregroundPID))")
            switch RestartCommand.make(o, isShell: ProcessNames.isShell) {
            case .success(let c): parts.append("command=[\(c.text)]")
            case .failure(let why): parts.append("noCommand=\(why)")
            }
        } else {
            parts.append("owner=none")
        }
        parts.append("offers stop=\(offersStop(server, row)) restart=\(restartCommand(server, row) != nil) browser=\(offersBrowser(server, row)) note=\(note(server, row).map { "\($0)" } ?? "nil")")
        return parts.joined(separator: " | ")
    }
    #endif

    // MARK: Open in Browser

    func openInBrowser(_ server: ServerConnection, _ row: PortRow) {
        Task { await openInBrowserNow(server, row) }
    }

    /// Asks the computer for the page's address and opens it in the phone's browser. `rest`:
    /// the path to open. `say`: where a failure's line goes (the open browser's own, when the
    /// tap was there); nil for a notice.
    @discardableResult
    func openInBrowserNow(_ server: ServerConnection, _ row: PortRow, rest: String = "/", say: (@MainActor (String) -> Void)? = nil) async -> Browsed {
        let name = row.entry.name, computer = server.config.name
        switch await requestShare(server, row) {
        case .success(let share):
            guard let url = share.page(rest) else { return browseFailed(.badAnswer, name, computer, say) }
            parts.openURL(url)
            return .opened(url)
        case .failure(let problem):
            return browseFailed(problem, name, computer, say)
        }
    }

    private func browseFailed(_ problem: PortBrowser.Problem, _ name: String, _ computer: String, _ say: (@MainActor (String) -> Void)?) -> Browsed {
        let text = PortBrowser.notice(problem, name: name, computer: computer)
        if let say { say(text) } else { parts.notify(text, nil) }
        return .problem(problem)
    }

    /// One `port_share` for the row: a new address, or the one it has with its time started
    /// over. What the answer says of the computer is kept: one that can't do this loses the
    /// item for this connection, and a failure takes the row's "In browser" away.
    private func requestShare(_ server: ServerConnection, _ row: PortRow) async -> Result<PortShare, PortBrowser.Problem> {
        let key = Self.key(server, row), serial = server.connectionSerial
        func failed(_ p: PortBrowser.Problem) -> Result<PortShare, PortBrowser.Problem> {
            if shares[key] != nil { shares[key] = nil }
            return .failure(p)
        }
        guard server.phase == .online, server.control.state == .connected else { return failed(.offline) }
        guard let phone = parts.phoneAddress() else {
            setBeacon(server) { $0.phone = false }
            return failed(.noAddress)
        }
        let args: JSONObject = ["block": row.blockID, "port": row.entry.port, "phone_ip": phone]
        let limit = parts.shareLimit
        let answer = await within(limit) { [weak self] in
            await self?.ask(server, "port_share", args, timeout: Int(limit * 1000) - 1000)
        }
        guard serial == server.connectionSerial else { return failed(.offline) }
        switch answer {
        case nil:
            return failed(.unanswered)
        case .success(let result)?:
            guard let share = PortShare(result) else { return failed(.badAnswer) }
            setBeacon(server) { $0.names = $0.names ?? true; $0.browser = true; $0.phone = true; $0.staleAt = nil }
            shares[key] = ShareMark(share: share, until: share.knownUntil(asked: parts.now()), serial: serial, pid: row.entry.pid)
            return .success(share)
        case .failure(let f)?:
            switch PortBeaconAnswer.share(code: f.code, unknownAction: f.isUnknownAction) {
            case .hide:
                setBeacon(server) { $0.browser = false }
            case .hideUntilStatus:
                // Its status said it could. The item is away until the app reads another.
                let reads = statusReads(server)
                setBeacon(server) { $0.staleAt = reads }
            case .keep:
                break
            }
            return failed(.refused(code: f.code, unknownAction: f.isUnknownAction))
        }
    }

    /// The address an in-app open loads for `link` in a pane, when the computer has already
    /// handed one out for that port; nil to load through the phone's own listener as before.
    /// Opening a page in the app never asks for a first address. One that exists is asked
    /// for again, which starts its time over and finds out that it ended: then the row's
    /// "In browser" goes and the page loads the old way.
    func existingShare(_ server: ServerConnection, block: String, _ link: LocalhostLink) async -> PortShare? {
        guard PortBrowser.mayLoad(link), let row = server.portRow("\(block):\(link.port)") else { return nil }
        // The open is a tap: the Beacon may be asked what holds the port, for the page's menu.
        learnOwner(server, row)
        guard shared(server, row) != nil, case .success(let again) = await requestShare(server, row) else { return nil }
        return again
    }

    /// The open browser's Open in Browser and its Copy Link, for a pane's port.
    func outside(_ server: ServerConnection, block: String, port: Int) -> PreviewBrowser.Outside {
        let id = "\(block):\(port)"
        return PreviewBrowser.Outside(
            offered: { [weak self, weak server] in
                guard let self, let server, let row = server.portRow(id) else { return false }
                return self.offersBrowser(server, row)
            },
            open: { [weak self, weak server] rest, say in
                guard let self, let server, let row = server.portRow(id) else { return }
                Task { await self.openInBrowserNow(server, row, rest: rest, say: say) }
            },
            link: { [weak self, weak server] rest in
                guard let self, let server, let row = server.portRow(id) else { return nil }
                return self.shared(server, row)?.page(rest)?.absoluteString
            })
    }

    // MARK: Actions

    /// Opens the port's page in the app, as the pane menu's row does. With `address`, at the
    /// path someone typed, shown as they typed it.
    func open(_ server: ServerConnection, _ row: PortRow, as address: PortAddress? = nil) {
        let pane = PanePorts(server: server, sessionID: row.sessionID, blockID: row.blockID)
        pane.view = presenter()
        pane.notify = { [parts] in parts.notify($0, nil) }
        pane.typed = { [weak self] text, browser in self?.go(text, from: browser) }
        pane.shared = { [weak self, weak server] link in
            guard let self, let server else { return nil }
            return await self.existingShare(server, block: row.blockID, link)
        }
        pane.outside = { [weak self, weak server] port in
            guard let self, let server else { return nil }
            return self.outside(server, block: row.blockID, port: port)
        }
        if let address { pane.open(row.entry, as: address) } else { pane.open(row.entry) }
    }

    // MARK: A typed address

    /// Which page a browser shows: the machine and its port.
    static func source(_ server: UUID, port: Int) -> String { "\(server.uuidString):\(port)" }

    /// The connected computers and their ports, as the app holds them now: no call is made.
    func machines() -> [PortAddress.Machine] {
        if let given = parts.machines { return given() }
        return (model?.servers ?? []).map {
            PortAddress.Machine(id: $0.id, name: $0.config.name,
                                online: $0.phase == .online && $0.control.state == .connected, rows: $0.portRows)
        }
    }

    func matches(_ address: PortAddress) -> [PortAddress.Match] {
        PortAddress.matches(address, in: machines())
    }

    /// What Go in the browser's address line did, for tests.
    enum Went: Equatable {
        case notAnAddress, elsewhere(URL), nothing, moved, opened(UUID), asked([PortAddress.Match])
    }

    /// Go in the browser's address line. One computer listens there: its page opens. Several:
    /// a list asks which. None: a notice. An address that isn't a computer's own leaves for the
    /// system's browser and is never loaded here.
    @discardableResult
    func go(_ text: String, from browser: PreviewBrowser) -> Went {
        switch PortAddress.parse(text) {
        case nil:
            browser.say("That isn't an address. Try localhost:3000.")
            return .notAnAddress
        case .elsewhere(let url):
            parts.openURL(url)
            return .elsewhere(url)
        case .local(let address):
            let found = matches(address)
            guard let first = found.first else {
                browser.say(PortAddress.nothing(address))
                return .nothing
            }
            if found.count == 1 { return show(first, address, in: browser) }
            let sheet = UIAlertController(title: address.shown, message: nil, preferredStyle: .actionSheet)
            for m in found {
                sheet.addAction(UIAlertAction(title: m.title, style: .default) { [weak self, weak browser] _ in
                    if let self, let browser { self.show(m, address, in: browser) }
                })
            }
            sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            sheet.popoverPresentationController?.sourceView = browser.navigationController?.navigationBar ?? browser.view
            browser.present(sheet, animated: true)
            return .asked(found)
        }
    }

    /// Shows the chosen computer's page: in the open browser when it is the same server, else
    /// in a new one once this one has gone.
    @discardableResult
    private func show(_ match: PortAddress.Match, _ address: PortAddress, in browser: PreviewBrowser) -> Went {
        if browser.page.source == Self.source(match.serverID, port: address.port) {
            browser.move(to: address)
            return .moved
        }
        browser.close { [weak self] in
            guard let self, let server = self.model?.server(match.serverID),
                  let row = self.row(server, id: match.row.id) else { return }
            self.open(server, row, as: address)
        }
        return .opened(match.serverID)
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
    /// tried twice. Where Rex's answer alone says the port's process is not in front and the
    /// computer's Beacon names processes, the Beacon is asked now about that process: a server
    /// behind a wrapper is stopped when the pane's foreground is its process group. `quiet`: a
    /// Restart's Stop, which says nothing itself.
    @discardableResult
    func stopNow(_ server: ServerConnection, _ row: PortRow, quiet: Bool = false) async -> Outcome {
        let key = Self.key(server, row), sid = row.sessionID, bid = row.blockID, port = row.entry.port
        let name = PortNames.program(row.entry) ?? row.entry.name
        func fail(_ outcome: Outcome, _ text: String, pane: Bool = true) -> Outcome {
            self.fail(key, outcome, text, pane ? server : nil, pane ? row : nil, quiet: quiet)
        }
        guard marks[key]?.status != .stopping else { return .busy }
        guard let pid = row.entry.pid else { return fail(.refused(.unknownProcess), "Couldn't stop \(name). Show its pane to stop it there.") }
        if let label = parts.only(), server.sessions.first(where: { $0.id == sid })?.label != label {
            return .refused(.notForeground)
        }
        guard server.phase == .online, server.control.state == .connected else {
            return fail(.offline, "Couldn't stop \(name). \(Messages.offline(server.config.name))", pane: false)
        }
        marks[key] = Mark(status: .stopping, pid: pid)
        let control = server.control
        let reply = await within(parts.readLimit) {
            try? await control.blockCall("com.superlogical.terminal.process", session: sid, block: bid)
        }
        guard let reply else {
            return fail(.unanswered, "Couldn't stop \(name): its pane didn't answer. Nothing was sent.")
        }
        let fg = PortStop.foreground(reply)
        let seen = server.currentMeta(bid)
        var verdict = PortStop.verdict(entry: server.ports.value(bid)?.entry(port), expected: pid, foregroundPID: fg.pid,
                                       agent: fg.agent || seen?.agentKind != nil)
        if verdict == .notForeground, beacon(server).names != false {
            // Read now, not taken from what the row showed: the process may be another's child since.
            let owner = await readOwner(server, key: key, pid: pid)
            verdict = PortStop.verdict(entry: server.ports.value(bid)?.entry(port), expected: pid, foregroundPID: fg.pid,
                                       agent: fg.agent || seen?.agentKind != nil || server.currentMeta(bid)?.agentKind != nil, owner: owner)
        }
        switch verdict {
        case .allowed:
            break
        case .gone:
            // It stopped by itself meanwhile: nothing to say.
            marks[key] = nil
            return .gone
        case .unknownProcess, .notForeground, .agent:
            return fail(.refused(verdict), "Couldn't stop \(name): another program is running in its pane now. Nothing was sent.")
        }
        // From here on nothing is tried twice. The last look, with nothing between it and the
        // write: the port is still that process's, no event has named another foreground since
        // the pane's processes were read, and no agent has shown up in the pane.
        let delivery = await parts.write(server, sid, bid, parts.leaveLimit) {
            server.ports.value(bid)?.entry(port)?.pid == pid && server.currentMeta(bid)?.foregroundPID == seen?.foregroundPID
                && server.currentMeta(bid)?.agentKind == nil
        }
        switch delivery {
        case .delivered, .unknown:
            watch(server, key: key, block: bid, port: port, pid: pid)
            return .sent
        case .unsent:
            return fail(.unsent, "Couldn't stop \(name): the connection dropped. Nothing was sent.")
        case .refused:
            return fail(.closed, "Couldn't stop \(name). \(Messages.paneClosed)", pane: false)
        }
    }

    // MARK: Restart

    /// Restart in the row's menu: the row shows the command and waits for one tap. Nothing is
    /// sent anywhere. Another row's unanswered question goes.
    func askRestart(_ server: ServerConnection, _ row: PortRow) {
        guard let command = restartCommand(server, row), let pid = row.entry.pid else { return }
        restarts = restarts.filter { $0.value.run.step != .confirming }
        restarts[Self.key(server, row)] = RestartMark(run: PortRestart(), command: command, pid: pid)
    }

    /// Cancel on the question, or Show Pane on a Restart that failed: the row is a row again.
    func dismissRestart(_ server: ServerConnection, _ row: PortRow) {
        let key = Self.key(server, row)
        guard let r = restarts[key], r.run.step == .confirming || r.run.isOver else { return }
        restarts[key] = nil
        server.releasePortRow(row.id)
    }

    /// The row's pane is on screen over a current screen now: a Restart types there without
    /// showing anything first.
    func paneShows(_ server: ServerConnection, _ row: PortRow) -> Bool {
        parts.paneReady(server, row.blockID)
    }

    func confirmRestart(_ server: ServerConnection, _ row: PortRow) {
        Task { await restartNow(server, row) }
    }

    private func advance(_ key: String, _ event: PortRestart.Event) -> PortRestart.Step {
        guard var r = restarts[key] else { return .failed(.changed) }
        let step = r.run.take(event)
        restarts[key] = r
        return step
    }

    /// One wait of a Restart: it ends when what it waits for happens or when its one deadline
    /// passes, whichever is first, and then never again. Used on the main actor only.
    @MainActor
    private final class Wait {
        var over = false
        var done: CheckedContinuation<Bool, Never>?
        var met: @MainActor () -> Bool = { false }
        var deadline: Task<Void, Never>?

        func end(_ value: Bool) {
            guard !over else { return }
            over = true
            deadline?.cancel()
            done?.resume(returning: value)
            done = nil
        }

        /// Looks once, and again each time something it read changes: the port lists and the
        /// panes' processes are observed state, so nothing is looked at on a clock.
        func look() {
            guard !over else { return }
            let now = withObservationTracking { met() } onChange: { [weak self] in
                Task { @MainActor in self?.look() }
            }
            if now { end(true) }
        }
    }

    /// True once `met` holds, false when it didn't within `limit`. `met` reads only what the
    /// app holds and observes (`ServerConnection.ports`, `meta`); it is looked at again when
    /// one of those changes, and one timer holds the deadline.
    private func observed(_ limit: TimeInterval, _ met: @escaping @MainActor () -> Bool) async -> Bool {
        if met() { return true }
        guard limit > 0 else { return false }
        let wait = Wait(), sleep = parts.sleep
        wait.met = met
        return await withCheckedContinuation { done in
            wait.done = done
            wait.deadline = Task { @MainActor in
                await sleep(limit)
                wait.end(false)
            }
            wait.look()
        }
    }

    /// True once `arm`'s closure was called, false when it wasn't within `limit`.
    private func signalled(_ limit: TimeInterval, _ arm: @MainActor (@escaping @MainActor () -> Void) -> Void) async -> Bool {
        let wait = Wait(), sleep = parts.sleep
        return await withCheckedContinuation { done in
            wait.done = done
            wait.deadline = Task { @MainActor in
                await sleep(limit)
                wait.end(false)
            }
            arm { wait.end(true) }
        }
    }

    /// How many times a Restart reads the pane's processes while it waits for the shell.
    static let shellReads = 3

    /// One Restart, after its one tap (`PortRestart` holds the order). The job is read again
    /// and must read as the command the row showed; the pane comes on screen and nothing is
    /// typed before it shows a current screen; one Ctrl-C goes as Stop sends it; once the port
    /// is gone and the pane's processes say the job's own shell is in front, the command and
    /// Return go once through the pane's input queue; then the row waits for the port. Any
    /// step that doesn't hold ends it with one notice and Show Pane, and nothing is typed after.
    @discardableResult
    func restartNow(_ server: ServerConnection, _ row: PortRow) async -> PortRestart.Step {
        let key = Self.key(server, row), sid = row.sessionID, bid = row.blockID, port = row.entry.port
        guard let mark = restarts[key], mark.run.step == .confirming, let pid = row.entry.pid, mark.pid == pid else {
            return restarts[key]?.run.step ?? .failed(.changed)
        }
        if let label = parts.only(), server.sessions.first(where: { $0.id == sid })?.label != label {
            restarts[key] = nil
            return .failed(.changed)
        }
        let command = mark.command
        func ended() -> PortRestart.Step { restartEnded(key, server, row) }
        _ = advance(key, .confirmed)
        guard server.phase == .online, server.control.state == .connected else {
            _ = advance(key, .paneReady(false))
            return ended()
        }
        // The job as it is now. What the row showed may be minutes old.
        let owner = await readOwner(server, key: key, pid: pid)
        let meta = server.currentMeta(bid)
        let fresh = PortStop.restart(entry: server.ports.value(bid)?.entry(port), expected: pid, foregroundPID: meta?.foregroundPID,
                                     agent: meta?.agentKind != nil, owner: owner)
        guard fresh == command, advance(key, .checked(same: true)) == .revealing else {
            _ = advance(key, .checked(same: false))
            return ended()
        }
        if !parts.paneReady(server, bid) {
            let shown = parts.reveal.map { $0(server, row) } ?? (model?.openPane(server, session: sid, window: nil, block: bid) ?? false)
            // The pane's host says when it shows and its stream when its fence is down; what is
            // typed next still looks for itself.
            let told = shown ? await signalled(parts.revealLimit) { [parts] fire in parts.whenPaneReady(server, bid, fire) } : false
            guard told, parts.paneReady(server, bid) else {
                _ = advance(key, .paneReady(false))
                return ended()
            }
        }
        guard advance(key, .paneReady(true)) == .stopping else { return ended() }
        // The row keeps its place while its port is away.
        server.holdPortRow(row)
        guard await stopNow(server, row, quiet: true) == .sent, advance(key, .stopped(true)) == .waitingForShell else {
            _ = advance(key, .stopped(false))
            return ended()
        }
        // The port goes and the pane's foreground is no longer the job's: both are events
        // from Rex, waited for and never looked up on a clock. Then the pane's processes are
        // read, and only they decide that the job's shell is in front. A read that comes while
        // the job is still ending is made again when the foreground next changes, `shellReads`
        // times at most, all within the one limit.
        let shell = command.shellPID, control = server.control, began = parts.uptime()
        var back = false, last = meta?.foregroundPID
        for _ in 0..<Self.shellReads {
            let remaining = parts.shellLimit - (parts.uptime() - began), was = last
            guard await observed(remaining, { server.ports.value(bid)?.entry(port) == nil && server.meta[bid]?.foregroundPID != was }) else { break }
            let reply = await within(parts.readLimit) {
                try? await control.blockCall("com.superlogical.terminal.process", session: sid, block: bid)
            }
            if let reply {
                let fg = PortStop.foreground(reply)
                back = fg.pid == shell && !fg.agent && server.currentMeta(bid)?.agentKind == nil
            }
            if back { break }
            last = server.meta[bid]?.foregroundPID
        }
        guard back, advance(key, .shellBack(true)) == .typing else {
            _ = advance(key, .shellBack(false))
            return ended()
        }
        // The last look, with nothing between it and the write: this Restart is still the one
        // typing, the port is still gone, no event has named another foreground since the read,
        // no agent is in the pane, and the pane still shows a current screen.
        let seen = server.currentMeta(bid)?.foregroundPID
        let delivery = await parts.type(server, command.typed, bid, parts.leaveLimit) { [weak self] in
            guard let self, self.restarts[key]?.run.mayWrite == .command else { return false }
            return server.ports.value(bid)?.entry(port) == nil && server.currentMeta(bid)?.foregroundPID == seen
                && server.currentMeta(bid)?.agentKind == nil && self.parts.paneReady(server, bid)
        }
        // One that left and got no answer may have been typed: it is never typed again.
        guard delivery == .delivered || delivery == .unknown, advance(key, .typed(true)) == .waitingForPort else {
            _ = advance(key, .typed(false))
            return ended()
        }
        let up = await observed(parts.portLimit) { server.ports.value(bid)?.entry(port) != nil }
        _ = advance(key, .portBack(up))
        return ended()
    }

    /// A Restart is over. Done: the row is a row again. Failed: one notice with Show Pane, and
    /// the row says so for `failedFor`, or until its Show Pane is tapped.
    private func restartEnded(_ key: String, _ server: ServerConnection, _ row: PortRow) -> PortRestart.Step {
        guard let step = restarts[key]?.run.step else { return .failed(.changed) }
        guard case .failed(let failure) = step else {
            restarts[key] = nil
            marks[key] = nil
            server.releasePortRow(row.id)
            return step
        }
        if marks[key]?.status == .stopping { marks[key] = nil }
        let text = PortRestartCopy.notice(failure, name: PortNames.program(row.entry) ?? row.entry.name, address: row.entry.name)
        parts.notify(text, Notice.Action(title: "Show Pane") { [weak self, weak server] in
            guard let self, let server else { return }
            self.dismissRestart(server, row)
            self.showPane(server, row)
        })
        let sleep = parts.sleep, wait = parts.failedFor
        Task { [weak self, weak server] in
            await sleep(wait)
            guard let self, self.restarts[key]?.run.step == step else { return }
            self.restarts[key] = nil
            server?.releasePortRow(row.id)
        }
        return step
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

    private func fail(_ key: String, _ outcome: Outcome, _ text: String, _ server: ServerConnection? = nil, _ row: PortRow? = nil,
                      quiet: Bool = false) -> Outcome {
        if marks[key]?.status == .stopping { marks[key] = nil }
        guard !quiet else { return outcome }
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
