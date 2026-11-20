import Foundation

/// An answer from the wrist: Enter or Interrupt for one waiting agent (docs/glance.md, Actions
/// from the wrist). The watch sends it to the phone's app, which checks that the agent still
/// waits for the same thing (`ActionGuard`) and then types it, once.
public struct WatchAction: Codable, Equatable, Sendable {
    public static let version = 1

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case enter, interrupt

        /// What is typed into the pane: Return, or Control-C.
        public var text: String {
            switch self {
            case .enter: "\r"
            case .interrupt: "\u{03}"
            }
        }
    }

    /// The wait an action answers, as the snapshot on the watch names it.
    public struct Target: Codable, Equatable, Sendable, Hashable {
        /// The server's id in the app (`GlanceSnapshot.Machine.id`).
        public var server: String
        public var session: String
        public var block: String
        /// The id of the status record that reports the wait. Never empty.
        public var record: String
        /// `ActionGuard.fingerprint` of the wait, as the phone wrote it.
        public var fp: String

        public init(server: String, session: String, block: String, record: String, fp: String) {
            self.server = server
            self.session = session
            self.block = block
            self.record = record
            self.fp = fp
        }

        /// The wait of a snapshot's agent. Nil when the snapshot can't name it well enough to
        /// act on: no record id, or no fingerprint (a snapshot from an older phone app).
        public init?(server: String, agent: GlanceSnapshot.Agent) {
            guard !agent.record.isEmpty, let fp = agent.fp, !fp.isEmpty else { return nil }
            self.init(server: server, session: agent.session, block: agent.block, record: agent.record, fp: fp)
        }
    }

    public var v: Int
    /// Names this one tap, so the phone never acts twice on a message that reaches it twice.
    public var id: String
    public var kind: Kind
    public var target: Target

    public init(id: String, kind: Kind, target: Target) {
        v = Self.version
        self.id = id
        self.kind = kind
        self.target = target
    }
}

/// What the phone answers.
public enum WatchActionResult: String, Codable, Sendable, CaseIterable {
    /// Typed, once, and the computer took it.
    case sent
    /// Not typed: the agent no longer waits, or waits for something else.
    case changed
    /// Not typed: the phone couldn't reach the computer.
    case unreachable
    /// It left the phone and no answer came back: nobody knows whether it was typed.
    case unconfirmed
}

/// How an action ended, as the watch says it. `noPhone` is the watch's own: the message never
/// reached the phone's app.
public enum WatchActionOutcome: Equatable, Sendable, CaseIterable {
    case sent, changed, unreachable, unconfirmed, noPhone

    /// How long the watch waits for the phone's answer. The phone answers within 20 s at the
    /// worst. A message with no answer and no failure by then may have arrived: `unconfirmed`.
    public static var replyLimit: TimeInterval { 30 }

    public init(_ result: WatchActionResult) {
        switch result {
        case .sent: self = .sent
        case .changed: self = .changed
        case .unreachable: self = .unreachable
        case .unconfirmed: self = .unconfirmed
        }
    }

    /// From the phone's reply. Nil: the message failed or timed out. A reply this watch app
    /// can't read came from the phone, which may have typed: not confirmed.
    ///
    /// `arrived`, for a message that failed: true when it reached the phone and only the reply
    /// was lost. The phone may have typed then, so that is not confirmed either.
    public init(reply: [String: Any]?, arrived: Bool = false) {
        guard let reply else { self = arrived ? .unconfirmed : .noPhone; return }
        self = WatchActionWire.result(in: reply).map(Self.init) ?? .unconfirmed
    }

    /// The phone was reached and nothing more can come of asking again for the same wait:
    /// it was typed, may have been typed, or the wait is over.
    public var settled: Bool {
        switch self {
        case .sent, .changed, .unconfirmed: true
        case .unreachable, .noPhone: false
        }
    }
}

/// An action and its answer as they travel between the watch and the phone: property lists, the
/// action as JSON bytes under one key, the answer as one word.
public enum WatchActionWire {
    public static let actionKey = "a"
    public static let resultKey = "r"

    public static func message(_ action: WatchAction) -> [String: Any] {
        guard let data = try? JSONEncoder().encode(action) else { return [:] }
        return [actionKey: data]
    }

    public static func actionData(in message: [String: Any]) -> Data? {
        message[actionKey] as? Data
    }

    /// Nil for bytes that are no action, an action of a later version, or a kind this app
    /// doesn't know: nothing is typed for what it can't read in full.
    public static func action(from data: Data) -> WatchAction? {
        guard let action = try? JSONDecoder().decode(WatchAction.self, from: data), action.v == WatchAction.version else { return nil }
        return action
    }

    public static func reply(_ result: WatchActionResult) -> [String: Any] {
        [resultKey: result.rawValue]
    }

    public static func result(in reply: [String: Any]) -> WatchActionResult? {
        (reply[resultKey] as? String).flatMap(WatchActionResult.init(rawValue:))
    }
}

/// Decides, on the phone, whether an action from the watch may be typed: only while the pane
/// still shows the wait the watch showed. Pure.
public enum ActionGuard {
    /// A pane's top status record, read from the server just before typing.
    public struct Current: Equatable, Sendable {
        public var record: String
        public var state: String
        /// What it waits for (`permission`, `question`, …).
        public var kind: String?
        public var message: String?

        public init(record: String, state: String, kind: String?, message: String?) {
            self.record = record
            self.state = state
            self.kind = kind
            self.message = message
        }

        public var fingerprint: String {
            ActionGuard.fingerprint(state: state, kind: kind, message: message)
        }
    }

    /// The state of an agent that waits for the person.
    public static let waiting = "blocked"

    /// True only when the agent still waits, its top record is the one the watch saw (an id
    /// that isn't empty), and its state, kind and message are the same. `current` nil: the pane
    /// has no status any more.
    public static func allows(_ action: WatchAction, current: Current?) -> Bool {
        guard let current, current.state == waiting else { return false }
        guard !action.target.record.isEmpty, current.record == action.target.record else { return false }
        return !action.target.fp.isEmpty && current.fingerprint == action.target.fp
    }

    /// A short name for what an agent waits for: its state, kind and whole message. The same
    /// wait gives the same name on every launch and device (FNV-1a, 64 bits, as hex); it tells
    /// waits apart and is no secret. A missing kind or message differs from an empty one.
    public static func fingerprint(state: String, kind: String?, message: String?) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func add(_ bytes: some Sequence<UInt8>) {
            for b in bytes {
                hash ^= UInt64(b)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        for part in [state, kind, message] {
            // A mark for present or missing, the text, and an end that no text holds.
            add([part == nil ? 0 : 1])
            add((part ?? "").utf8)
            add([0xff])
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}

/// What the watch holds for one agent's actions: nothing, an action on its way, or how the last
/// one ended. Pure; `WatchActions` keeps one per agent.
public struct WatchActionState: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case idle
        case sending(WatchAction.Kind)
        case done(WatchAction.Kind, WatchActionOutcome)
    }

    public private(set) var phase: Phase = .idle
    /// The wait the action on its way, or the last one, answered.
    public private(set) var target: WatchAction.Target?
    private var sending: String?

    public init() {}

    /// Whether an action may start for this wait: never while one is on its way, and never
    /// again for a wait the phone has answered for (`WatchActionOutcome.settled`). After the
    /// phone or the computer couldn't be reached, the person may tap again.
    public func canAct(on target: WatchAction.Target) -> Bool {
        switch phase {
        case .idle: true
        case .sending: false
        case .done(_, let outcome): !outcome.settled || target != self.target
        }
    }

    /// Starts an action, after the person confirmed it. Nil when none may start.
    public mutating func begin(_ kind: WatchAction.Kind, on target: WatchAction.Target, id: String) -> WatchAction? {
        guard canAct(on: target) else { return nil }
        phase = .sending(kind)
        self.target = target
        sending = id
        return WatchAction(id: id, kind: kind, target: target)
    }

    /// The action with this id ended. An answer for another action changes nothing.
    public mutating func finish(id: String, _ outcome: WatchActionOutcome) {
        guard sending == id, case .sending(let kind) = phase else { return }
        sending = nil
        phase = .done(kind, outcome)
    }

    /// The quiet line under the agent. `current`: the wait the screen shows now, nil when the
    /// agent no longer waits. An answer for an earlier wait says nothing about a new one.
    public func line(for current: WatchAction.Target?) -> String? {
        switch phase {
        case .idle: return nil
        case .sending: return WatchText.sending
        case .done(let kind, let outcome):
            guard current == nil || current == target else { return nil }
            return WatchText.outcome(outcome, kind)
        }
    }
}
