import Foundation

/// What one input call means to predicted echo, decided from the bytes that go out. The stream
/// classifies every call in one place (`TerminalStream`), so no key path can reach the server
/// without the predictor hearing of it.
public enum EchoInputKind: Equatable, Sendable {
    /// Exactly one printable ASCII byte (0x20...0x7e).
    case char(UInt8)
    /// Exactly DEL (0x7f), the encoder's Backspace without the Kitty protocol.
    case backspace
    /// Anything else: control bytes, escape sequences, several bytes in one call (paste, swipe,
    /// dictation), reports, server actions. `newLine` marks the end of the prompt's input: Enter,
    /// Ctrl-C, Ctrl-D, Ctrl-Z, and every server action, whose effect is unknown.
    case boundary(newLine: Bool)

    public var isNewLine: Bool {
        if case .boundary(true) = self { return true }
        return false
    }
}

public enum EchoInputClassifier {
    /// A server action or a forwarded key: its effect is unknown, so it ends the prompt's input.
    public static let action = EchoInputKind.boundary(newLine: true)

    /// A typed send of `bytes`.
    public static func classify(_ bytes: [UInt8]) -> EchoInputKind {
        if bytes.count == 1 {
            let b = bytes[0]
            if b >= 0x20 && b <= 0x7e { return .char(b) }
            if b == 0x7f { return .backspace }
        }
        return boundary(bytes)
    }

    /// `bytes` as a boundary, whatever they hold: a report, keys the fence held or released,
    /// input sent once.
    public static func boundary(_ bytes: some Sequence<UInt8>) -> EchoInputKind {
        .boundary(newLine: bytes.contains { $0 == 0x0d || $0 == 0x0a || $0 == 0x03 || $0 == 0x04 || $0 == 0x1a })
    }
}

/// The terminal's (echo, canonical) state, from `terminal.input_mode`.
public struct EchoInputMode: Equatable, Sendable {
    public var echo: Bool
    public var canonical: Bool

    public init(echo: Bool, canonical: Bool) {
        self.echo = echo
        self.canonical = canonical
    }

    /// Nil when the reply or either field is missing.
    public init?(reply: JSONObject?) {
        guard let reply, let echo = reply.bool("echo"), let canonical = reply.bool("canonical") else { return nil }
        self.init(echo: echo, canonical: canonical)
    }

    /// Whether a reading proves the program reads a line that the screen will echo:
    /// - canonical off with a local shell in front: a line editor (zsh ZLE, readline, fish) turns
    ///   echo and canonical mode off while it reads a line, and draws what is typed itself;
    /// - echo and canonical on: a cooked reader that the terminal driver echoes for.
    /// Echo off with canonical on is a password reader (`sudo`, `passwd`, `read -s`) and never
    /// proves anything. Over `ssh` the reading describes the local ssh client's tty, not the
    /// remote program, so it never proves anything either.
    public static func proves(_ mode: EchoInputMode?, foreground: String?) -> Bool {
        guard let mode, let front = EchoForeground.normalize(foreground), front != "ssh",
              EchoForeground.shells.contains(front) else { return false }
        if !mode.canonical { return true }
        return mode.echo
    }
}

/// The programs a pane may predict in front of.
public enum EchoForeground {
    public static let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "nu", "ssh"]

    /// The last path component, a login shell's leading `-` removed, lowercased.
    public static func normalize(_ name: String?) -> String? {
        guard var n = name?.split(separator: "/").last.map(String.init), !n.isEmpty else { return nil }
        if n.hasPrefix("-") { n.removeFirst() }
        return n.isEmpty ? nil : n.lowercased()
    }

    public static func allows(_ name: String?) -> Bool {
        normalize(name).map(shells.contains) ?? false
    }
}

/// Why every guess was cleared.
public enum EchoClearReason: Equatable, Sendable {
    /// A write was sent and the connection broke before its answer.
    case unknown
    /// The server refused a write; its bytes were dropped.
    case refused
    /// A write never left; it goes out again later, merged with what follows (a conservative
    /// clear: its echo simply arrives unpredicted).
    case unsent
    /// The input queue was dropped.
    case dropped
    /// The catch-up fence dropped held keys.
    case fence
    /// The control connection is connected again.
    case reconnected
    /// The stream was stopped or parked.
    case stopped

    /// The input up to the clear will never be answered: the acknowledgement rule may count it
    /// as answered. Not for `.unsent`, whose bytes still go out.
    public var dropsInput: Bool { self != .unsent }
}

/// Hears every input call, classified, before it is queued (`TerminalStream.inputObserver`).
@MainActor
public protocol EchoInputObserver: AnyObject {
    func input(_ kind: EchoInputKind, seq: Int)
}

/// Hears what happens to queued input (`TerminalStream.writeObserver`).
@MainActor
public protocol EchoWriteObserver: AnyObject {
    /// An item holding input through `seq` left for the server.
    func left(through seq: Int)
    /// The server answered the item holding input through `seq`, at `time` (`EchoClock`).
    func answered(through seq: Int, at time: Double)
    /// 50 ms passed since the answer at `answer` with no newer answer: the echo of everything
    /// answered had time to arrive.
    func settled(after answer: Double)
    /// Input through `seq` was dropped or will arrive unpredicted: every guess goes.
    func cleared(_ reason: EchoClearReason, through seq: Int)
}
