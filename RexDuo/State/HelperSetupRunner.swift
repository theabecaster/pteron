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
        var sessions: SetupSessions
        var theme: @MainActor () -> TermTheme
        /// The installer's text, from the app bundle. Nil when the bundle has none.
        var script: @MainActor () -> String?
        /// The session on this server the app last showed, for a server at its session limit.
        var shownSession: @MainActor (ServerConnection) -> String?
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

    // MARK: Running

    func begin() {
        guard work == nil, server != nil else { return }
        work = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        guard let server, let env else { return }
        let control = server.control
        // iOS first: with notifications off for the app, nothing runs on the computer.
        guard await env.push.enableForSetup() else { return send(.fail(.notificationsOff)) }
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

        // A tab left by an earlier run on this server is this app's own: close it first.
        await HelperSetupCenter.closeTab(env.sessions.entry(server.id), on: server)
        env.sessions.forget(server.id)

        let command = args.command(script: script)
        let theme = env.theme()
        var made: SetupSessions.Entry?
        do {
            let r = try await control.call("session.create", SetupBlock.session(command: command, theme: theme))
            if let session = r.str("session_id"), let block = (r.arr("initial_windows").first?["block_ids"] as? [String])?.first {
                made = SetupSessions.Entry(sessionID: session, blockID: block, windowID: nil, createdAt: Date())
            }
        } catch let e as RexError where e.code == "conflict" {
            // The server is at its session limit: a tab in the session the app last showed.
            if let host = env.shownSession(server),
               let r = try? await control.call("session.new_window", SetupBlock.window(in: host, command: command, theme: theme)),
               let window = r.str("window_id"), let block = (r["block_ids"] as? [Any])?.compactMap({ $0 as? String }).first {
                made = SetupSessions.Entry(sessionID: host, blockID: block, windowID: window, createdAt: Date())
            }
        } catch {}
        guard let made else { return send(.fail(.interrupted)) }
        entry = made
        env.sessions.record(made, for: server.id)
        server.dropHiddenSessions()
        tab = (made.sessionID, made.blockID)
        if state.isFinished {
            // Cancelled while the tab was being made.
            await cleanUp(closeBlockFirst: true)
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
                send(.exited(code: payload.int("exit_code") ?? -1))
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
        await cleanUp(closeBlockFirst: true)
        tab = nil
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
        await cleanUp(closeBlockFirst: true)
    }

    /// Done, Close, or before another try: the tab on the computer closes and the run lets go of
    /// everything it held.
    func finish() async {
        await cleanUp(closeBlockFirst: false)
    }

    private func cleanUp(closeBlockFirst: Bool) async {
        guard !cleaned else { return }
        cleaned = true
        work?.cancel()
        watch?.cancel()
        exitRead?.cancel()
        guard let server, let env else { return }
        env.push.setupEnded(server.id)
        code = nil
        guard let entry, server.control.state == .connected else { return }
        if closeBlockFirst {
            _ = try? await server.control.call("block.close", ["session_id": entry.sessionID, "block_id": entry.blockID])
        }
        if await HelperSetupCenter.closeTab(entry, on: server) { env.sessions.forget(server.id) }
    }
}

/// Starts installs, keeps the one on screen, and looks after the tabs they open. Owned by
/// `AppModel`.
@MainActor
@Observable
final class HelperSetupCenter {
    /// The run whose sheet is up.
    var active: HelperSetupRun?
    #if DEBUG
    /// `-simulateHelperSetup offer`: the offer page for a computer of this name.
    var simulatedOffer: String?
    #endif

    @ObservationIgnored private let push: PushRegistrar
    @ObservationIgnored private let prefs: Prefs
    @ObservationIgnored private let sessions: SetupSessions
    @ObservationIgnored private let fetcher: HelperReleaseFetcher
    @ObservationIgnored private var pending: (server: UUID, kind: SetupState.Kind)?
    /// The servers, the session on one the app shows, and whether another sheet is up. AppModel
    /// sets them.
    @ObservationIgnored var servers: () -> [ServerConnection] = { [] }
    @ObservationIgnored var shownSession: (ServerConnection) -> String? = { _ in nil }
    @ObservationIgnored var sheetIsUp: () -> Bool = { false }

    init(push: PushRegistrar, prefs: Prefs, defaults: UserDefaults = .standard, fetcher: HelperReleaseFetcher? = nil) {
        self.push = push
        self.prefs = prefs
        sessions = SetupSessions(defaults: defaults)
        var chosen = fetcher
        #if DEBUG
        // `-helperReleaseMirror <http://127.0.0.1:port>` (debug builds): read the release list from
        // a copy of the release folders on this machine. The list is still checked against the
        // built-in keys; the installer on the computer still downloads from the real address.
        if chosen == nil, let mirror = defaults.string(forKey: "helperReleaseMirror"),
           let root = URL(string: mirror), root.host == "127.0.0.1" || root.host == "localhost" {
            chosen = HelperReleaseFetcher(transport: { url in
                let path = url.absoluteString.replacingOccurrences(of: HelperRelease.base, with: "")
                let (data, response) = try await URLSession.shared.data(from: root.appendingPathComponent(path))
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= HelperRelease.maxDocument else {
                    throw ReleaseFault.unreachable
                }
                return data
            }, store: KeychainReleaseStore())
        }
        // `-autoHelperSetup install|repair` (debug builds): start that on the first server to connect.
        autoStart = defaults.string(forKey: "autoHelperSetup").flatMap { $0 == "repair" ? .repair : ($0 == "install" ? .install : nil) }
        #endif
        self.fetcher = chosen ?? HelperReleaseFetcher(store: KeychainReleaseStore())
    }

    #if DEBUG
    @ObservationIgnored private var autoStart: SetupState.Kind?
    #endif

    /// Wires a server to its installs: their events, and which sessions are the installer's.
    func attach(_ server: ServerConnection) {
        server.hiddenSessions = { [sessions, id = server.id] in sessions.hidden(id) }
        server.setupSignals = { [weak self, weak server] signal in
            guard let self, let server else { return }
            if let run = self.active, run.server === server { run.receive(signal) }
            if case .ready = signal { Task { await self.sweep(server) } }
            #if DEBUG
            if case .ready = signal, let kind = self.autoStart {
                self.autoStart = nil
                self.request(server.id, kind: kind)
            }
            #endif
        }
    }

    /// An install for this server is on screen and not over.
    func isRunning(_ id: UUID) -> Bool {
        guard let run = active, run.server?.id == id else { return false }
        return !run.state.isFinished
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
        guard pending != nil else { return }
        Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if !sheetIsUp() { present() }
        }
    }

    private func present() {
        guard let (id, kind) = pending, active == nil else { return }
        pending = nil
        guard let server = servers().first(where: { $0.id == id }) else { return }
        let run = HelperSetupRun(server: server, kind: kind, env: environment)
        active = run
        run.begin()
    }

    /// Try Again or Repair on a failed run: the old tab closes and a new run takes the sheet.
    func retry(_ run: HelperSetupRun, kind: SetupState.Kind) {
        guard let server = run.server, active === run else { return }
        Task {
            await run.finish()
            let next = HelperSetupRun(server: server, kind: kind, env: environment)
            active = next
            next.begin()
        }
    }

    /// The sheet closed: Done, Close, or Stop.
    func close(_ run: HelperSetupRun, cancelled: Bool) {
        if active === run { active = nil }
        Task { cancelled ? await run.cancel() : await run.finish() }
    }

    private var environment: HelperSetupRun.Environment {
        HelperSetupRun.Environment(push: push, fetcher: fetcher, sessions: sessions, theme: { [prefs] in prefs.theme },
                                   script: { SetupScript.bundled() }, shownSession: { [weak self] in self?.shownSession($0) })
    }

    /// Closes a tab this app recorded opening and that is left over: more than an hour old and
    /// not the run on screen. A tab the app didn't record is never touched.
    func sweep(_ server: ServerConnection) async {
        guard let entry = sessions.stale(server.id, activeBlock: active?.server === server ? active?.blockID : nil) else { return }
        if await Self.closeTab(entry, on: server) { sessions.forget(server.id) }
    }

    /// Closes a recorded tab: its session when the app made one for it, else only its window.
    /// True when the server did it or no longer has it.
    @discardableResult
    static func closeTab(_ entry: SetupSessions.Entry?, on server: ServerConnection) async -> Bool {
        guard let entry else { return true }
        do {
            if let window = entry.windowID {
                _ = try await server.control.call("session.close_window", ["session_id": entry.sessionID, "window_id": window])
            } else {
                _ = try await server.control.call("session.destroy", ["session_id": entry.sessionID])
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
