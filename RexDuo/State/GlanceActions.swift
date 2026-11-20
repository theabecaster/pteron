import Foundation
import GlanceModel
import RexKit

/// How `GlanceActions` reaches one pane: it reads the pane's status and types into it.
@MainActor
protocol ActionChannel: AnyObject {
    /// The label of the pane's session. Nil when it couldn't be read.
    func label(session: String) async -> String?
    /// The pane's status records, by id, read from the server now. Nil when it couldn't be read.
    func statuses(session: String, block: String) async -> [String: ProgramStatus]?
    /// Types `text`, once. `limit`: how long it may wait to leave before it is dropped.
    /// `mayWrite` is asked as the last thing before the text is handed over: false types
    /// nothing and answers `.unsent`.
    func write(_ text: String, session: String, block: String, within limit: TimeInterval,
               mayWrite: @escaping @MainActor () -> Bool) async -> TerminalStream.Delivery
    /// The job is over.
    func close()
}

/// Answers an action from the watch: Enter or Interrupt for one waiting agent (docs/glance.md,
/// Actions from the wrist). Owned by `AppModel`; `GlanceBridge` hands it each message.
///
/// For each action, in order:
/// 1. it reads the pane's status from the server, now;
/// 2. `ActionGuard` passes it only while the agent still waits, on the same status record, for
///    the same thing the watch showed;
/// 3. it types once. A write that left is never sent again, whatever came of it, and an action
///    that reaches the phone twice is answered from memory.
///
/// One wait is answered once, whoever asks: the watch and a notification's action both come
/// here, and for `answeredFor` after a write left for a wait, another action for that same
/// wait types nothing. The agent's status needs a moment to change after a key, and until
/// then a second Enter would pass the guard and land on whatever the agent asks next.
///
/// It starts no server and opens no pane. With the app in front it uses the server's live
/// connection, and the pane's own input queue when the pane is on screen. Otherwise (the system
/// woke the app for the message) it uses one short connection that attaches to the pane's
/// session alone, which Rex asks for before it answers for a pane.
@MainActor
final class GlanceActions {
    struct Parts {
        var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max($0, 0) * 1_000_000_000)) }
        /// The longest the status read may take.
        var readLimit: TimeInterval = 5
        /// The longest the write may wait to leave, behind what was typed on the phone.
        var leaveLimit: TimeInterval = 3
        /// The longest to wait for the write's answer, from when it was asked for.
        var answerLimit: TimeInterval = 8
        var now: @Sendable () -> Date = { Date() }
        /// How long a wait counts as answered after a write for it left.
        var answeredFor: TimeInterval = 15
    }

    /// How an action ended, for a caller that must tell these apart (a notification, which
    /// is removed, put back or left alone). The watch gets a `WatchActionResult` (`handle`).
    enum Answer: Equatable, Sendable {
        /// This call did the work, or waited for the one that did and nothing was typed.
        case fresh(WatchActionResult)
        /// The same tap again (`WatchAction.id`): the answer it had, from memory.
        case repeated(WatchActionResult)
        /// Another action answered this same wait a moment ago: nothing was typed for this one.
        case answered
    }

    /// The way to the action's pane. Nil: the server is not one of the app's. Set by `AppModel`.
    var channel: @MainActor (WatchAction) -> ActionChannel? = { _ in nil }
    /// False where the app must type nothing (a launch that shows made-up state).
    var enabled: @MainActor () -> Bool = { false }
    /// A test launch's session label (`-autoOpen <label>`): only that session's panes are typed into.
    var only: @MainActor () -> String? = { nil }

    private let parts: Parts
    /// The actions taken, by id, with their answer once there is one. The newest `memory`.
    private var answers: [String: WatchActionResult?] = [:]
    private var order: [String] = []
    static let memory = 64
    /// The waits a write left for, and when (`waitKey`). Kept for `answeredFor`.
    private var answered: [String: Date] = [:]
    /// The waits an action is under way for, with the later actions that wait for its answer.
    private var running: [String: [CheckedContinuation<WatchActionResult, Never>]] = [:]

    init(parts: Parts = Parts()) {
        self.parts = parts
    }

    /// A message from the watch, as bytes. Bytes that are no action this app reads type nothing.
    func answer(_ data: Data) async -> WatchActionResult {
        guard let action = WatchActionWire.action(from: data) else { return .changed }
        return await handle(action)
    }

    /// What the watch is told. A wait another action just answered no longer waits for this
    /// one: `changed`, the watch's word for that.
    func handle(_ action: WatchAction, mayWrite: @escaping @MainActor () -> Bool = { true }) async -> WatchActionResult {
        switch await take(action, mayWrite: mayWrite) {
        case .fresh(let result), .repeated(let result): result
        case .answered: .changed
        }
    }

    /// `mayWrite` is asked right before the write, and again by the connection as the last
    /// thing before the text is handed over: false types nothing. It is how a caller whose
    /// time has run out (a notification's action in the background) stops a run that is
    /// still reading.
    func take(_ action: WatchAction, mayWrite: @escaping @MainActor () -> Bool = { true }) async -> Answer {
        // The same tap again: never typed twice. One still on its way may have typed.
        if let known = answers[action.id] { return .repeated(known ?? .unconfirmed) }
        remember(action.id)
        let key = Self.waitKey(action.target)
        let now = parts.now()
        answered = answered.filter { now.timeIntervalSince($0.value) < parts.answeredFor && now >= $0.value }
        // Another action answered this wait a moment ago.
        if answered[key] != nil {
            answers[action.id] = .some(.changed)
            return .answered
        }
        // Another action for this wait is under way: its answer decides, and this one never
        // types. If that one typed, this wait is answered; if not, this one failed as it did.
        if running[key] != nil {
            let first = await withCheckedContinuation { running[key, default: []].append($0) }
            let typed = Self.left(first)
            answers[action.id] = .some(typed ? .changed : first)
            return typed ? .answered : .fresh(first)
        }
        running[key] = []
        let result = await run(action, mayWrite: mayWrite)
        answers[action.id] = .some(result)
        if Self.left(result) { answered[key] = parts.now() }
        for waiting in running.removeValue(forKey: key) ?? [] { waiting.resume(returning: result) }
        #if DEBUG
        // To check on a simulator what the phone did: `eventMessage CONTAINS "GLANCE_ACTION"`.
        NSLog("GLANCE_ACTION %@ %@", action.kind.rawValue, result.rawValue)
        #endif
        return .fresh(result)
    }

    /// True when a write left the phone for this answer: the computer took it, or nobody
    /// knows whether it did.
    static func left(_ result: WatchActionResult) -> Bool {
        result == .sent || result == .unconfirmed
    }

    /// Names a wait whoever asks about it: the server, the pane, the record and the fingerprint.
    static func waitKey(_ target: WatchAction.Target) -> String {
        [target.server, target.block, target.record, target.fp].joined(separator: "\u{0}")
    }

    private func remember(_ id: String) {
        answers[id] = .some(nil)
        order.append(id)
        if order.count > Self.memory { answers[order.removeFirst()] = nil }
    }

    private func run(_ action: WatchAction, mayWrite: @escaping @MainActor () -> Bool) async -> WatchActionResult {
        guard enabled() else { return .changed }
        guard let channel = channel(action) else { return .changed }
        defer { channel.close() }
        let target = action.target
        let limit = parts.readLimit
        if let label = only() {
            let found = await within(limit) { await channel.label(session: target.session) }
            guard let found else { return .unreachable }
            guard found == label else { return .changed }
        }
        let read = await within(limit) { await channel.statuses(session: target.session, block: target.block) }
        guard let statuses = read else { return .unreachable }
        guard ActionGuard.allows(action, current: Self.current(statuses)) else { return .changed }
        guard mayWrite() else { return .unreachable }
        // From here on nothing is tried twice.
        let leave = parts.leaveLimit
        let delivery = await within(parts.answerLimit) {
            await channel.write(action.kind.text, session: target.session, block: target.block, within: leave, mayWrite: mayWrite)
        }
        switch delivery {
        case .delivered: return .sent
        case .unsent: return .unreachable
        case .refused: return .changed
        case .unknown, nil: return .unconfirmed
        }
    }

    /// The pane's top status record, as the snapshot's writer picks it (`GlanceSource.topRecord`).
    static func current(_ statuses: [String: ProgramStatus]) -> ActionGuard.Current? {
        var meta = BlockMeta()
        meta.statuses = statuses
        return GlanceSource.current(meta)
    }

    /// Which of the work and the limit ended first. Used on the main actor only.
    @MainActor
    private final class Race {
        var over = false
    }

    /// `work`'s value, or nil when it took longer than `limit`. `work` goes on by itself then;
    /// what it gives is dropped.
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

/// The server's live connection, with the app in front. A pane that is on screen has a running
/// stream, and the text goes through that stream's queue, behind what was typed on the phone.
/// A pane that isn't has no stream and nothing queued: one call on the same connection.
@MainActor
final class LiveActionChannel: ActionChannel {
    private let server: ServerConnection

    init(_ server: ServerConnection) {
        self.server = server
    }

    func label(session: String) async -> String? {
        server.sessions.first { $0.id == session }?.label ?? ""
    }

    func statuses(session: String, block: String) async -> [String: ProgramStatus]? {
        await ActionCalls.statuses(server.control, session: session, block: block)
    }

    func write(_ text: String, session: String, block: String, within limit: TimeInterval,
               mayWrite: @escaping @MainActor () -> Bool) async -> TerminalStream.Delivery {
        guard let stream = server.control.stream(block: block) else {
            return await ActionCalls.write(server.control, text, session: session, block: block, mayWrite: mayWrite)
        }
        guard mayWrite() else { return .unsent }
        return await withCheckedContinuation { done in
            stream.sendOnce(text: text, within: .milliseconds(Int(limit * 1000))) { done.resume(returning: $0) }
        }
    }

    func close() {}
}

/// One short control connection, made for one action while the app is not in front: hello, one
/// `session.attach` for the pane's session (Rex answers for a pane only on a connection attached
/// to its session), the status read, at most one write, a clean close. It is no server of the
/// app's: it asks for no session list, no events of the whole server and no data stream, so no
/// pane is opened, claimed or resized, and its label carries no device id, so no Beacon takes it
/// for this iPhone having the app open. One attempt: a connection that fails is not made again.
@MainActor
final class OneShotActionChannel: ActionChannel {
    private let control: RexControl
    private var connecting: Task<Bool, Never>?
    /// The attach of each session asked for, made once. False: the server refused it.
    private var attaching: [String: Task<Bool?, Never>] = [:]

    init(address: String, client: ClientInfo) {
        control = RexControl(address: address, client: client)
    }

    /// Connects at the first call. False when it couldn't.
    private func connected() async -> Bool {
        if connecting == nil {
            connecting = Task { [control] in
                do {
                    try await control.connect()
                    return true
                } catch {
                    // `RexControl` would go on retrying: this job gets one attempt.
                    control.disconnect()
                    return false
                }
            }
        }
        return await connecting?.value ?? false
    }

    func label(session: String) async -> String? {
        guard await connected(), let r = try? await control.call("session.list") else { return nil }
        return r.arr("sessions").first { $0.str("session_id") == session }?.str("label") ?? ""
    }

    /// Attaches to the session, once. True: attached. False: the server refused (the session is
    /// gone). Nil: the connection failed.
    private func attached(_ session: String) async -> Bool? {
        guard await connected() else { return nil }
        if attaching[session] == nil {
            attaching[session] = Task { [control] in
                do {
                    try await control.call("session.attach", ["session_id": session])
                    return true
                } catch {
                    return TerminalStream.Delivery(failure: error) == .refused ? false : nil
                }
            }
        }
        return await attaching[session]?.value ?? nil
    }

    func statuses(session: String, block: String) async -> [String: ProgramStatus]? {
        // A session that is gone has no status: the guard then refuses.
        guard let attached = await attached(session) else { return nil }
        guard attached else { return [:] }
        return await ActionCalls.statuses(control, session: session, block: block)
    }

    func write(_ text: String, session: String, block: String, within limit: TimeInterval,
               mayWrite: @escaping @MainActor () -> Bool) async -> TerminalStream.Delivery {
        guard await attached(session) == true else { return .unsent }
        return await ActionCalls.write(control, text, session: session, block: block, mayWrite: mayWrite)
    }

    func close() {
        // Ends whatever still waits on it, and never retries.
        control.invalidate()
    }
}

/// The two block calls an action makes.
@MainActor
enum ActionCalls {
    static func statuses(_ control: RexControl, session: String, block: String) async -> [String: ProgramStatus]? {
        let r: JSONObject
        do {
            r = try await control.blockCall("com.superlogical.terminal.program_status", session: session, block: block)
        } catch {
            // The server answered that it can't (the pane is gone): it has no status. Anything
            // else is a connection that failed.
            return TerminalStream.Delivery(failure: error) == .refused ? [:] : nil
        }
        var out: [String: ProgramStatus] = [:]
        for rec in r.arr("records") { out[rec.str("id") ?? ""] = ProgramStatus(rec) }
        return out
    }

    /// One `terminal.write`. Whatever it throws, it is not called again. `mayWrite` is asked
    /// with nothing between its answer and the call: false, and nothing is sent.
    static func write(_ control: RexControl, _ text: String, session: String, block: String,
                      mayWrite: @MainActor () -> Bool = { true }) async -> TerminalStream.Delivery {
        guard mayWrite() else { return .unsent }
        do {
            try await control.blockCall("com.superlogical.terminal.write", session: session, block: block, args: ["data": text])
            return .delivered
        } catch {
            return TerminalStream.Delivery(failure: error)
        }
    }
}
