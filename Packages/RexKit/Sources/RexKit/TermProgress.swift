import Foundation

/// A pane's progress bar, as a program reports it with OSC 9;4 (the terminal creator's
/// `progress_report` block event). Rex keeps no copy to read back: the newest report is all
/// there is, and it goes stale if the program stops reporting.
public struct TermProgress: Equatable, Sendable {
    public enum State: String, Sendable {
        /// A known percent.
        case set
        /// Busy, no percent.
        case indeterminate
        case pause
        case error
    }

    public var state: State
    /// 0...100, or nil when the program gave none.
    public var percent: Int?

    public init(state: State, percent: Int? = nil) {
        self.state = state
        self.percent = percent.map { min(max($0, 0), 100) }
    }

    /// One `progress_report` payload: `state` and `progress` (0...255 or null in the schema;
    /// Rex sends 0...100 and `set` with 0 for an OSC without a value).
    public enum Report: Equatable, Sendable {
        case remove
        case update(State, percent: Int?)

        /// Nil for a state this build doesn't know: newer servers may add some, and they are
        /// ignored rather than drawn wrong.
        public init?(_ payload: JSONObject) {
            guard let s = payload.str("state") else { return nil }
            if s == "remove" { self = .remove; return }
            guard let state = State(rawValue: s) else { return nil }
            self = .update(state, percent: payload.int("progress"))
        }

        /// The bar after this report. `set` without a percent is indeterminate; `pause` and
        /// `error` without one keep the percent the bar had.
        public func applied(to current: TermProgress?) -> TermProgress? {
            switch self {
            case .remove:
                return nil
            case .update(let state, let percent):
                switch state {
                case .set:
                    guard let percent else { return TermProgress(state: .indeterminate) }
                    return TermProgress(state: .set, percent: percent)
                case .indeterminate:
                    return TermProgress(state: .indeterminate)
                case .pause, .error:
                    return TermProgress(state: state, percent: percent ?? current?.percent)
                }
            }
        }
    }
}
