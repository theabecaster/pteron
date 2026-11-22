import Foundation

/// What the pane knows on the main thread when a key is typed, that the grid cannot say: whether
/// this is a place where a typed character may be guessed at all.
public struct EchoHostConditions: Equatable, Sendable {
    /// The catch-up fence is up: the screen may be behind the program.
    public var fenced = false
    /// The keyboard is composing (IME marked text).
    public var composing = false
    /// A selection is up.
    public var selecting = false
    /// Find is open.
    public var finding = false
    /// The view is scrolled into the history.
    public var scrolledBack = false
    /// An agent runs in the pane (`BlockMeta.agentKind`).
    public var agent = false
    /// The program in front, as the server names it; nil when unknown.
    public var foreground: String?

    public init(fenced: Bool = false, composing: Bool = false, selecting: Bool = false, finding: Bool = false,
                scrolledBack: Bool = false, agent: Bool = false, foreground: String? = nil) {
        self.fenced = fenced
        self.composing = composing
        self.selecting = selecting
        self.finding = finding
        self.scrolledBack = scrolledBack
        self.agent = agent
        self.foreground = foreground
    }

    /// A shell is in front (or `ssh`, whose remote shell must then mark its prompt), no agent,
    /// and nothing of the pane's own is in the way. An unknown foreground allows nothing.
    public var allowsGuesses: Bool {
        guard !fenced, !composing, !selecting, !finding, !scrolledBack, !agent else { return false }
        guard let front = EchoForeground.normalize(foreground) else { return false }
        return EchoForeground.shells.contains(front)
    }
}

/// The pane's main-thread gate for predicted echo: a key typed where no guess may be made
/// reaches the predictor as a boundary, so it ends the epoch like any other input that is not a
/// plain key. Boundaries pass as they are.
public enum EchoHostGate {
    public static func admit(_ kind: EchoInputKind, _ conditions: EchoHostConditions) -> EchoInputKind {
        switch kind {
        case .boundary: return kind
        case .char, .backspace: return conditions.allowsGuesses ? kind : .boundary(newLine: false)
        }
    }
}
