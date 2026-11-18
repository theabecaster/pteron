import Foundation
import Observation
import RexKit
import os

/// One install (or repair) of Rex DUO Helper on one server, from the tap on Install to Connected
/// or an error. It opens a tab on the computer that runs the installer from the app bundle,
/// follows the installer's progress records and exit code, types the run's setup code into the
/// installer's terminal when the installer asks for it, then asks the helper for the proof that
/// this install started it and waits for that helper to register. `SetupState` decides what the
/// sheet shows and when the proof is asked for; this type makes the calls.
///
/// The run survives a dropped connection: the installer keeps going on the computer, and after
/// the reconnect its latest record and exit code are read back.
@MainActor
@Observable
final class HelperSetupRun: Identifiable {
    /// What a run needs from the rest of the app, so the type holds no global.
    struct Environment {
        var push: PushRegistrar
        var fetcher: HelperReleaseFetcher
        /// Closes the tabs this app made, and keeps the list of them.
        var tabs: SetupSessionCloser
        var theme: @MainActor () -> TermTheme
        /// The installer's text, from the app bundle. Nil when the bundle has none.
        var script: @MainActor () -> String?
        /// The session on this server the app last showed, for a server at its session limit.
        var shownSession: @MainActor (ServerConnection) -> String?
        /// The run reached an end: connected, failed or stopped.
        var finished: @MainActor (HelperSetupRun) -> Void = { _ in }
    }

    nonisolated let id = UUID()
    let name: String
    /// The computer account Rex runs as, for the password card.
    let account: String?
    /// Nil only for a run that shows a state without a server (`-simulateHelperSetup`).
    @ObservationIgnored let server: ServerConnection?
    private(set) var state: SetupState
    /// The installer's tab, once it exists: what "Show details" shows.
    private(set) var tab: (session: String, block: String)?
    /// A password is on its way to the computer.
    private(set) var sendingPassword = false
    #if DEBUG
    /// `-simulateHelperSetup`: text shown in place of the installer's terminal.
    var simulatedDetails: String?
    #endif

    @ObservationIgnored private let env: Environment?
    @ObservationIgnored private var entry: SetupSessions.Entry?
    /// The run's setup code, from its making until it is typed into the installer's terminal.
    /// After that only `PushRegistrar` holds it, to check the helper's proof.
    @ObservationIgnored private var code: String?
    /// The installer's request for the code was taken up. It is answered once.
    @ObservationIgnored private var codeAnswered = false
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var watch: Task<Void, Never>?
    @ObservationIgnored private var exitRead: Task<Void, Never>?
    @ObservationIgnored private var connectingSince: Date?
    @ObservationIgnored private var cleaned = false
    /// The installer's output was on screen. A failed run's tab closes with the sheet then.
    @ObservationIgnored private var detailsShown = false

    /// How long the helper has to connect and register once the installer finished.
    static let connectTimeout: TimeInterval = 60
    /// Also the pause between two requests for the setup proof.
    static let pollInterval: TimeInterval = 2
    /// How often the terminal is looked at before the code is typed or the run gives up: the
    /// installer asks a moment before it starts reading.
    static let codeChecks = 3
    private static let log = Logger(subsystem: "dev.abrahamgonzalez.rexduo", category: "helper-setup")

    init(server: ServerConnection, kind: SetupState.Kind, env: Environment) {
        self.server = server
        self.env = env
        name = server.config.name
        account = server.identity?.account
        state = SetupState(kind: kind, computer: server.platform?.lowercased().hasPrefix("linux") == true ? .linux : .mac)
    }

    #if DEBUG
    /// A run that only shows `state`.
    init(name: String, account: String?, state: SetupState) {
        server = nil
        env = nil
        self.name = name
        self.account = account
        self.state = state
    }
    #endif

    var blockID: String? { entry?.blockID }

    /// The sentence under "Connected". While iOS has notifications turned off for the app it
    /// also says where to turn them on.
    var connectedMessage: String {
        SetupState.connectedMessage(name: name, notificationsAllowed: env?.push.permission != .denied)
    }

    // MARK: Running

    func begin() {
        guard work == nil, server != nil else { return }
        work = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        guard let server, let env else { return }
        let control = server.control
        // An install is the person asking for notifications from this computer: the master
        // switch and this computer go on, and iOS asks if it never did. Whatever iOS answers,
        // the helper is installed.
        await env.push.prepareForSetup(server.id)
        guard await waitOnline(server) else { return send(.fail(.interrupted)) }

        let version: JSONObject, creators: JSONObject
        do {
            version = try await control.call("server.version")
            creators = try await control.call("block_creator.list")
        } catch {
            return send(.fail(.interrupted))
        }
        guard SetupBlock.supported(version: version, creators: creators) else { return send(.fail(.manual)) }
        guard let script = env.script() else { return send(.fail(.release)) }

        let release: VerifiedRelease
        switch await env.fetcher.verified() {
        case .success(let r): release = r
        case .failure: return send(.fail(.release))
        }
        send(.release(version: release.version.description))
        guard let args = SetupArgs(release: release, linger: state.computer == .linux ? .ask : .skip) else {
            return send(.fail(.release))
        }
        guard !state.isFinished else { return }
        // The setup code is in nothing sent here. It is typed into the terminal when the
        // installer asks (`answerCodeRequest`).
        code = SetupCode.make()

        // A tab an earlier run on this server left in the app's list is this app's own: close it first.
        for old in env.tabs.tabs(on: server.id) { await env.tabs.handle(.retry, old, on: server.id) }

        guard let made = await HelperSetupCenter.openTab(args.command(script: script), on: server, theme: env.theme(),
                                                         shownSession: env.shownSession(server)) else {
            return send(.fail(.interrupted))
        }
        entry = made
        env.tabs.made(made, on: server.id)
        server.dropHiddenSessions()
        tab = (made.sessionID, made.blockID)
        if state.isFinished {
            // Cancelled while the tab was being made.
            await cleanUp(stopped: true)
            return
        }
        _ = try? await control.call("session.attach", ["session_id": made.sessionID])
        send(.started)
        // Reports that arrived before the block's id was known.
        await catchUp()
        startWatch()
    }

    private func waitOnline(_ server: ServerConnection, timeout: TimeInterval = 20) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while server.control.state != .connected {
            guard Date() < end, !Task.isCancelled, !state.isFinished else { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return true
    }

    // MARK: What the server says

    func receive(_ signal: ServerConnection.SetupSignal) {
        switch signal {
        case .block(_, let block, let name, let payload):
            guard block == entry?.blockID else { return }
            switch name {
            case "program_status_changed":
                var raw = payload.obj("record") ?? [:]
                if raw["id"] == nil { raw["id"] = payload.str("id") }
                guard let record = SetupRecord(raw) else { return }
                send(.record(record))
                answerCodeRequest(record)
                // The exit code is what counts. If the event for it doesn't come, it is read.
                if record.state == "done" || record.state == "error" { readExitSoon() }
            case "child_exited":
                let code = payload.int("exit_code") ?? -1
                send(.exited(code: code))
                tabEnded(.exited(code: code))
            default:
                break
            }
        case .disconnected:
            if state.hasTab, !state.isFinished { send(.connectionLost) }
        case .ready:
            if state.connectionLost { Task { await self.catchUp() } }
        }
    }

    // MARK: The setup code

    /// The installer asks for the setup code: type it, once.
    private func answerCodeRequest(_ record: SetupRecord) {
        guard SetupCode.isRequest(record, answered: codeAnswered), state.phase == .running,
              server?.control.state == .connected else { return }
        codeAnswered = true
        Task { await self.typeCode() }
    }

    /// Types the code into the installer's terminal, only while the terminal has echo off and the
    /// program in front is the installer's shell (`SetupCode.allows`). Otherwise, or when the
    /// write fails, nothing more is typed, the tab closes and the run ends.
    private func typeCode() async {
        guard let server, let env, let entry, let code else { return }
        let control = server.control
        var allowed = false
        for check in 0..<Self.codeChecks where !allowed {
            if check > 0 { try? await Task.sleep(nanoseconds: 300_000_000) }
            let mode = try? await control.blockCall("com.superlogical.terminal.input_mode", session: entry.sessionID, block: entry.blockID)
            let process = try? await control.blockCall("com.superlogical.terminal.process", session: entry.sessionID, block: entry.blockID)
            allowed = SetupCode.allows(inputMode: mode, process: process)
        }
        guard state.phase == .running else { return }
        guard allowed else { return await refuseCode() }
        // From here on this server's helper has to show the proof for this code.
        env.push.beginSetup(server.id, code: code)
        self.code = nil
        do {
            // One write, straight to the block, as for the password.
            _ = try await control.blockCall("com.superlogical.terminal.write", session: entry.sessionID, block: entry.blockID,
                                            args: ["data": SetupCode.input(code)])
        } catch {
            await refuseCode()
        }
    }

    private func refuseCode() async {
        send(.codeRefused)
        await cleanUp(stopped: true)
        tab = nil
    }

    /// Something happened that may close the run's tab (`SetupSessionCloser.closes`): its
    /// script ended well, or the person is done with a run that failed. The tab then closes at
    /// once, whether or not the sheet is open, and the sheet offers no details any more.
    private func tabEnded(_ reason: SetupSessionCloser.Reason) {
        guard let server, let env, let entry, tab != nil, SetupSessionCloser.closes(reason) else { return }
        tab = nil
        state.handle(.tabClosed)
        Task { await env.tabs.handle(reason, entry, on: server.id) }
    }

    /// The sheet shows the installer's output.
    func showedDetails() { detailsShown = true }

    /// The sheet went away without Done, Close or Stop. A run that failed keeps its tab for
    /// "Show Details" in the computer's row, unless its details were already shown.
    func sheetDismissed() {
        guard state.error != nil else { return }
        tabEnded(.dismissed(detailsShown: detailsShown))
    }

    private func readExitSoon() {
        guard exitRead == nil else { return }
        exitRead = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.exitRead = nil
            if self.state.phase == .running { await self.catchUp() }
        }
    }

    /// Reads the installer's latest record and how it exited, after a reconnect or a missed event.
    private func catchUp() async {
        guard let server, let entry, !state.isFinished || state.phase == .connected else { return }
        let control = server.control
        _ = try? await control.call("session.attach", ["session_id": entry.sessionID])
        do {
            let status = try await control.blockCall("com.superlogical.terminal.program_status", session: entry.sessionID, block: entry.blockID)
            let process = try await control.blockCall("com.superlogical.terminal.process", session: entry.sessionID, block: entry.blockID)
            let record = SetupRecord.find(in: status.arr("records"))
            let exitCode = process.obj("last_exit")?.int("exit_code")
            send(.caughtUp(record: record, exitCode: exitCode, gone: false))
            if let exitCode { tabEnded(.exited(code: exitCode)) }
            // A request for the code that came while nobody listened, if the installer still waits.
            if let record, exitCode == nil { answerCodeRequest(record) }
        } catch let e as RexError where e.code.contains("not_found") {
            send(.caughtUp(record: nil, exitCode: nil, gone: true))
        } catch {
            // Still no connection: the next sync tries again.
        }
    }

    /// While the run lasts: asks the helper for the setup proof when the state says so, tells the
    /// state what it answered and when it registered, and ends the wait for it after
    /// `connectTimeout`.
    private func startWatch() {
        guard watch == nil else { return }
        watch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, await self.watchOnce() else { return }
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    /// False when there is nothing left to watch.
    private func watchOnce() async -> Bool {
        guard let server, let env else { return false }
        let waitingForAllow = state.phase == .connected && state.human == .allowNotifications
        guard !state.isFinished || waitingForAllow else { return false }
        if state.phase == .connecting, connectingSince == nil { connectingSince = Date() }
        guard server.control.state == .connected else { return true }

        if state.wantsProof {
            // One request per round, so two requests are `pollInterval` apart, and the state
            // stops asking after `SetupProof.requests`.
            switch await env.push.proveSetup(server) {
            case .notAsked: break
            case .missing: send(.proof(.missing))
            case .wrong: send(.proof(.wrong))
            case .proven: send(.proof(.valid))
            case .registered:
                send(.proof(.valid))
                send(.helperRegistered)
            }
            if state.error == .identityChanged { env.push.setupUnproven(server) }
        } else if state.awaitsRegistration {
            if await env.push.syncAfterSetup(server) { send(.helperRegistered) }
        }
        if state.helperRegistered {
            // The helper's own word on the Mac's notification question, for the "click Allow" card.
            env.push.refreshVersion(server)
            if let version = env.push.versions[server.id] { send(.notices(version.notices)) }
        }
        if state.phase == .connecting, let since = connectingSince, Date().timeIntervalSince(since) > Self.connectTimeout {
            send(.connectTimeout)
        }
        return true
    }

    private func send(_ event: SetupState.Event) {
        let before = state.phase
        state.handle(event)
        guard state.phase != before, let server else { return }
        if state.isFinished { env?.finished(self) }
        // Step changes and the outcome, by server id. Never a name, an address or a value.
        switch state.phase {
        case .failed(let error):
            Self.log.notice("setup \(server.id.uuidString, privacy: .public): failed, \(String(describing: error), privacy: .public)")
        default:
            Self.log.notice("setup \(server.id.uuidString, privacy: .public): \(String(describing: self.state.phase), privacy: .public)")
        }
    }

    // MARK: What the person does

    /// Done on the "click Allow" card.
    func humanDone() { send(.humanDone) }

    /// Continue on the password card. The password goes to the terminal only while the terminal
    /// has echo off and the program in front is one that asks for it; it is written once and kept
    /// nowhere. Otherwise nothing is written and the card says to type it on the computer.
    func sendPassword(_ password: String) async {
        guard let server, let entry, !password.isEmpty, !sendingPassword else { return }
        sendingPassword = true
        defer { sendingPassword = false }
        let control = server.control
        let mode = try? await control.blockCall("com.superlogical.terminal.input_mode", session: entry.sessionID, block: entry.blockID)
        let process = try? await control.blockCall("com.superlogical.terminal.process", session: entry.sessionID, block: entry.blockID)
        guard PasswordGuard.allows(inputMode: mode, process: process) else { return send(.passwordRefused) }
        do {
            // One write, straight to the block: no pane of the app's shows this terminal for
            // typing, so there is no input queue to keep in order with.
            _ = try await control.blockCall("com.superlogical.terminal.write", session: entry.sessionID, block: entry.blockID,
                                            args: ["data": password + "\r"])
            send(.passwordSent)
        } catch {
            send(.passwordRefused)
        }
    }

    /// "Type it on <Name> instead".
    func typeOnComputer() { send(.passwordOnComputer) }

    /// "Not now": the installer goes on without the setting. The question on the computer is
    /// ended with Ctrl-C, and only when the program in front is the one asking.
    func skipPassword() async {
        send(.passwordSkipped)
        guard let server, let entry else { return }
        let control = server.control
        let process = try? await control.blockCall("com.superlogical.terminal.process", session: entry.sessionID, block: entry.blockID)
        guard PasswordGuard.frontIsPrompt(process) else { return }
        _ = try? await control.blockCall("com.superlogical.terminal.write", session: entry.sessionID, block: entry.blockID,
                                         args: ["data": "\u{03}"])
    }

    /// Stop in the sheet: the installer is ended where it is. It replaces files only by renaming,
    /// so the computer keeps what it had or has the new helper whole.
    func cancel() async {
        send(.cancel)
        await cleanUp(stopped: true)
    }

    /// Done, Close, or before another try: the tab on the computer closes and the run lets go of
    /// everything it held.
    func finish() async {
        await cleanUp(stopped: false)
    }

    private func cleanUp(stopped: Bool) async {
        guard !cleaned else { return }
        cleaned = true
        work?.cancel()
        watch?.cancel()
        exitRead?.cancel()
        guard let server, let env else { return }
        env.push.setupEnded(server.id)
        code = nil
        guard let entry, tab != nil else { return }
        tab = nil
        state.handle(.tabClosed)
        // A close the server can't take now is tried again on its next connection.
        await env.tabs.handle(stopped ? .cancel : .done, entry, on: server.id)
    }
}

/// Starts installs, keeps the one on screen, and looks after the tabs they open. Owned by
/// `AppModel`.
@MainActor
@Observable
final class HelperSetupCenter {
    /// The run whose sheet is up.
    var active: HelperSetupRun? {
        didSet {
            // The sheet went away by something other than its own buttons, which put the run
            // away themselves before this.
            if let old = oldValue, old !== active, parked[old.server?.id ?? UUID()] !== old { old.sheetDismissed() }
        }
    }
    /// Runs that go on with their sheet closed, by server. A row in Settings shows where each
    /// stands, and `show` brings its sheet back.
    private(set) var parked: [UUID: HelperSetupRun] = [:]
    /// How the last install on a server ended, when it failed, for that computer's row once the
    /// sheet is closed. Kept while the app runs; the next install or a turned-off switch clears it.
    private(set) var failures: [UUID: SetupError] = [:]
    /// The install that waits for Settings or pairing to close before its sheet opens.
    private(set) var pending: (server: UUID, kind: SetupState.Kind)?
    #if DEBUG
    /// `-simulateHelperSetup offer`: the offer page for a computer of this name.
    var simulatedOffer: String?
    #endif

    @ObservationIgnored private let push: PushRegistrar
    @ObservationIgnored private let prefs: Prefs
    @ObservationIgnored private let sessions: SetupSessions
    @ObservationIgnored private let fetcher: HelperReleaseFetcher
    /// Closes the tabs the installs made. Made on first use, since it calls back into `servers`.
    @ObservationIgnored private lazy var tabs = SetupSessionCloser(sessions: sessions, server: SetupTabServer(
        read: { [weak self] id, session in
            guard let server = self?.servers().first(where: { $0.id == id }) else { return .noAnswer }
            return await HelperSetupCenter.readTab(session, on: server)
        },
        close: { [weak self] id, what, entry in
            guard let server = self?.servers().first(where: { $0.id == id }), server.control.state == .connected else { return false }
            return await HelperSetupCenter.closeTab(what, entry, on: server)
        }))
    /// The servers, the session on one the app shows, and whether another sheet is up. AppModel
    /// sets them.
    @ObservationIgnored var servers: () -> [ServerConnection] = { [] }
    @ObservationIgnored var shownSession: (ServerConnection) -> String? = { _ in nil }
    @ObservationIgnored var sheetIsUp: () -> Bool = { false }

    init(push: PushRegistrar, prefs: Prefs, defaults: UserDefaults = .standard, fetcher: HelperReleaseFetcher? = nil) {
        self.push = push
        self.prefs = prefs
        sessions = SetupSessions(defaults: defaults)
        #if DEBUG
        // `-autoHelperSetup install|repair` (debug builds): start that on the first server to connect.
        autoStart = defaults.string(forKey: "autoHelperSetup").flatMap { $0 == "repair" ? .repair : ($0 == "install" ? .install : nil) }
        #endif
        self.fetcher = fetcher ?? .standard(defaults: defaults)
    }

    #if DEBUG
    @ObservationIgnored private var autoStart: SetupState.Kind?
    #endif
    /// The block of the removal script's tab on each server where one runs.
    @ObservationIgnored private var removing: [UUID: String] = [:]
    /// The server whose unseen install is about to get its sheet back.
    @ObservationIgnored private var showing: UUID?
    /// The server whose install's sheet opens at the installer's output the next time it shows.
    @ObservationIgnored private var detailsWanted: UUID?

    /// Wires a server to its installs: their events, and which sessions are the installer's.
    func attach(_ server: ServerConnection) {
        server.hiddenSessions = { [sessions, id = server.id] in sessions.hidden(id) }
        server.setupSignals = { [weak self, weak server] signal in
            guard let self, let server else { return }
            self.run(for: server.id)?.receive(signal)
            // Tabs the app left on this computer are closed: a failed install's when the app was
            // killed with it open, and one whose close the server did not take.
            if case .ready = signal {
                let inUse = self.blocksInUse(on: server.id)
                Task { await self.tabs.connected(server.id, inUse: inUse) }
            }
            #if DEBUG
            if case .ready = signal, let kind = self.autoStart {
                self.autoStart = nil
                self.request(server.id, kind: kind)
            }
            #endif
        }
    }

    /// The blocks of the tabs on a server that this app session still works with: its install's,
    /// while it runs or while its failed run keeps the tab for "Show Details", and a running
    /// removal's.
    private func blocksInUse(on id: UUID) -> Set<String> {
        var blocks: Set<String> = []
        if let block = run(for: id)?.blockID { blocks.insert(block) }
        if let block = removing[id] { blocks.insert(block) }
        return blocks
    }

    /// The server's install: the one whose sheet is up, or one that goes on without its sheet.
    func run(for id: UUID) -> HelperSetupRun? {
        if let run = active, run.server?.id == id { return run }
        return parked[id]
    }

    /// An install for this server is under way, or about to open its sheet.
    func isRunning(_ id: UUID) -> Bool {
        if pending?.server == id { return true }
        guard let run = run(for: id) else { return false }
        return !run.state.isFinished
    }

    /// Closes the sheet and lets the install go on. Its row in Settings follows it from here.
    func hide(_ run: HelperSetupRun) {
        guard active === run, let id = run.server?.id else { return }
        active = nil
        if run.state.isFinished { ended(run) } else { parked[id] = run }
    }

    /// Brings back the sheet of an install that goes on without it, or that failed while its
    /// sheet was closed. While Settings or pairing is up it waits for that sheet to close, as a
    /// new install does. `details` opens the sheet at the installer's output.
    func show(_ id: UUID, details: Bool = false) {
        guard parked[id] != nil else { return }
        showing = id
        detailsWanted = details ? id : nil
        if !sheetIsUp() { present() }
    }

    /// True once, for the sheet of a run that `show` asked to open at the installer's output.
    func takeDetailsRequest(for run: HelperSetupRun) -> Bool {
        guard let id = detailsWanted, run.server?.id == id else { return false }
        detailsWanted = nil
        return true
    }

    /// The person will install the helper on this computer by hand: its row says so.
    func noteManual(_ id: UUID) {
        guard !isRunning(id) else { return }
        failures[id] = .manual
    }

    /// Stops the server's install, wherever it stands, and forgets how an earlier one ended.
    func cancel(_ id: UUID) {
        if pending?.server == id { pending = nil }
        failures[id] = nil
        guard let run = run(for: id) else { return }
        if active === run { active = nil }
        parked[id] = nil
        Task { await run.cancel() }
    }

    /// A run reached its end. One whose sheet is closed is put away here, since nobody will tap
    /// Done or Close for it; how it ended stays for the row. A failed one keeps its tab, so
    /// "Show Details" in the row can bring its sheet and the installer's output back; the next
    /// install, Close in that sheet, or the computer's switch going off puts it away.
    private func ended(_ run: HelperSetupRun) {
        guard let id = run.server?.id else { return }
        failures[id] = run.state.error
        guard active !== run else { return }
        if run.state.error != nil, run.tab != nil {
            parked[id] = run
            return
        }
        parked[id] = nil
        Task { await run.finish() }
    }

    /// Whether to offer installing the helper on a connected server.
    /// `repairing`: the question is asked for a helper that is there but not working.
    func offer(for server: ServerConnection, repairing: Bool = false) -> HelperOffer {
        let has = !repairing && (push.helpers[server.id].map { $0 != .missing } ?? false)
        return HelperOffer.decide(platform: server.platform, hasHelper: has,
                           owner: server.identity?.owner, viewer: server.identity?.viewer, running: isRunning(server.id))
    }

    /// Opens the install sheet for a server. While Settings or pairing is up it waits for that
    /// sheet to close (`presentPending`), so one sheet follows the other.
    func request(_ server: UUID, kind: SetupState.Kind) {
        guard !isRunning(server) else { return }
        pending = (server, kind)
        if !sheetIsUp() { present() }
    }

    /// Called when Settings or pairing has closed. Pairing opened from Settings closes both at
    /// once, so the install sheet waits a moment for the last of them to be off screen.
    func presentPending() {
        guard pending != nil || showing != nil else { return }
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !sheetIsUp() { present() }
        }
    }

    private func present() {
        if let id = showing {
            showing = nil
            if active == nil, let run = parked.removeValue(forKey: id) { active = run }
            return
        }
        guard let (id, kind) = pending, active == nil else { return }
        pending = nil
        guard let server = servers().first(where: { $0.id == id }) else { return }
        // One install per computer: the new one takes the place of one that went on unseen.
        if let old = parked.removeValue(forKey: id) { Task { await old.cancel() } }
        failures[id] = nil
        let run = HelperSetupRun(server: server, kind: kind, env: environment)
        active = run
        run.begin()
    }

    /// Try Again or Repair on a failed run: the old tab closes and a new run takes the sheet.
    func retry(_ run: HelperSetupRun, kind: SetupState.Kind) {
        guard let server = run.server, active === run else { return }
        Task {
            await run.finish()
            failures[server.id] = nil
            let next = HelperSetupRun(server: server, kind: kind, env: environment)
            active = next
            next.begin()
        }
    }

    /// The sheet closed: Done, Close, or Stop.
    func close(_ run: HelperSetupRun, cancelled: Bool) {
        if active === run { active = nil }
        if cancelled, let id = run.server?.id { failures[id] = nil }
        Task { cancelled ? await run.cancel() : await run.finish() }
    }

    private var environment: HelperSetupRun.Environment {
        HelperSetupRun.Environment(push: push, fetcher: fetcher, tabs: tabs, theme: { [prefs] in prefs.theme },
                                   script: { SetupScript.bundled() }, shownSession: { [weak self] in self?.shownSession($0) },
                                   finished: { [weak self] in self?.ended($0) })
    }

    // MARK: Removing the helper

    /// How long the remove script gets. It waits up to 30 s by itself for a helper update that
    /// is under way.
    static let removeTimeout: TimeInterval = 90

    /// Runs the installer script in its remove mode on a server, in a tab of its own, as an
    /// install runs it, and closes the tab. The script's exit code; nil when it could not run
    /// there or did not finish in time.
    func remove(on server: ServerConnection) async -> Int? {
        let control = server.control
        guard control.state == .connected, !isRunning(server.id),
              let version = try? await control.call("server.version"),
              let creators = try? await control.call("block_creator.list"),
              SetupBlock.supported(version: version, creators: creators),
              let script = SetupScript.bundled() else { return nil }
        // A tab an earlier run on this server left in the app's list is this app's own: close it first.
        for old in tabs.tabs(on: server.id) { await tabs.handle(.retry, old, on: server.id) }
        guard let entry = await Self.openTab(SetupArgs.removeCommand(script: script), on: server, theme: prefs.theme,
                                             shownSession: shownSession(server)) else { return nil }
        tabs.made(entry, on: server.id)
        // A reconnect while the script runs leaves its tab alone.
        removing[server.id] = entry.blockID
        defer { removing[server.id] = nil }
        server.dropHiddenSessions()
        let code = await Self.exitCode(of: entry, on: server, within: Self.removeTimeout)
        // A script that ended well closes its tab at once. One that failed keeps it until the
        // next try on this computer.
        if let code { await tabs.handle(.exited(code: code), entry, on: server.id) }
        return code
    }

    /// Follows a script's tab until its program exits: its progress records go to the log, and
    /// its exit code is the answer. Nil when the tab is gone or the time is up.
    private static func exitCode(of entry: SetupSessions.Entry, on server: ServerConnection, within limit: TimeInterval) async -> Int? {
        let control = server.control
        let end = Date().addingTimeInterval(limit)
        var step = ""
        while Date() < end, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            // A dropped connection leaves the script running; it is read again after the reconnect.
            guard control.state == .connected else { continue }
            do {
                let status = try await control.blockCall("com.superlogical.terminal.program_status", session: entry.sessionID, block: entry.blockID)
                if let token = SetupRecord.find(in: status.arr("records"))?.token, token != step {
                    step = token
                    // The step by server id. Never a name, an address or a value.
                    log.notice("remove \(server.id.uuidString, privacy: .public): \(token, privacy: .public)")
                }
                let process = try await control.blockCall("com.superlogical.terminal.process", session: entry.sessionID, block: entry.blockID)
                if let code = process.obj("last_exit")?.int("exit_code") { return code }
            } catch let e as RexError where e.code.contains("not_found") {
                return nil
            } catch {
                // No answer this time: the next round asks again.
            }
        }
        return nil
    }

    private static let log = Logger(subsystem: "dev.abrahamgonzalez.rexduo", category: "helper-setup")

    /// Opens the tab a script runs in: a session of its own, or, on a server at its session
    /// limit, a tab in the session the app last showed. Nil when the server made neither.
    static func openTab(_ command: [String], on server: ServerConnection, theme: TermTheme, shownSession: String?) async -> SetupSessions.Entry? {
        let control = server.control
        do {
            let r = try await control.call("session.create", SetupBlock.session(command: command, theme: theme))
            if let session = r.str("session_id"), let block = (r.arr("initial_windows").first?["block_ids"] as? [String])?.first {
                return SetupSessions.Entry(sessionID: session, blockID: block, windowID: nil, createdAt: Date())
            }
        } catch let e as RexError where e.code == "conflict" {
            if let host = shownSession,
               let r = try? await control.call("session.new_window", SetupBlock.window(in: host, command: command, theme: theme)),
               let window = r.str("window_id"), let block = (r["block_ids"] as? [Any])?.compactMap({ $0 as? String }).first {
                return SetupSessions.Entry(sessionID: host, blockID: block, windowID: window, createdAt: Date())
            }
        } catch {}
        return nil
    }

    /// What the server says a session holds now (`session.view`), before anything of a recorded
    /// tab is closed.
    static func readTab(_ session: String, on server: ServerConnection) async -> SetupTabServer.Read {
        guard server.control.state == .connected else { return .noAnswer }
        do {
            let r = try await server.control.call("session.view", ["session_id": session])
            let view = SessionView(r.obj("view") ?? r)
            return view.sessionID == session ? .view(view) : .unreadable
        } catch let e as RexError where e.code != "client" {
            // The server's own answer: it has no such session, or will not show it.
            return .unreadable
        } catch {
            return .noAnswer
        }
    }

    /// Closes what `SetupTabClose` decided on for a recorded tab. True when the server did it or
    /// no longer has it.
    static func closeTab(_ what: SetupTabClose, _ entry: SetupSessions.Entry, on server: ServerConnection) async -> Bool {
        do {
            switch what {
            case .session:
                _ = try await server.control.call("session.destroy", ["session_id": entry.sessionID])
            case .window(let window):
                _ = try await server.control.call("session.close_window", ["session_id": entry.sessionID, "window_id": window])
            case .block:
                _ = try await server.control.call("block.close", ["session_id": entry.sessionID, "block_id": entry.blockID])
            case .nothing:
                break
            }
            return true
        } catch let e as RexError {
            return e.code.contains("not_found")
        } catch {
            return false
        }
    }
}

/// The installer's text: `Relay/setup.sh`, copied into the app when it is built.
enum SetupScript {
    /// Linux passes one argument of at most 128 KiB; half of that leaves room to spare.
    static let maxBytes = 64 << 10

    static func bundled(_ bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "setup", withExtension: "sh"), let data = try? Data(contentsOf: url),
              !data.isEmpty, data.count < maxBytes else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
