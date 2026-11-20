import Foundation
import RexKit

/// Whether Stop may type Ctrl-C into a port's pane. Pure, so it is tested (docs/terminal.md,
/// Ports).
///
/// Ctrl-C goes to whatever is in the pane's foreground, so Stop is for one case only: the
/// process that holds the port is itself the pane's foreground process, and it is no agent.
/// A server left in the background (`npm run dev &`), one whose pane now runs something else,
/// and one that an agent or a script started as its child all get no Stop: Rex names the
/// foreground's parents, never the port holder's, so the phone can't tell such a server from
/// one beside the foreground.
enum PortStop {
    enum Verdict: Equatable {
        case allowed
        /// The port is gone, or another process holds it now.
        case gone
        /// The server couldn't tell which process holds the port.
        case unknownProcess
        /// The pane's foreground is another process.
        case notForeground
        /// The foreground is an agent: an interrupt would stop its turn.
        case agent
    }

    /// `expected`: the process the row showed when Stop was tapped; nil to take the entry's.
    /// `agent`: the pane reports an agent, or its foreground program is one.
    static func verdict(entry: PortEntry?, expected: Int? = nil, foregroundPID: Int?, agent: Bool) -> Verdict {
        guard let entry else { return .gone }
        guard let pid = entry.pid else { return .unknownProcess }
        if let expected, expected != pid { return .gone }
        guard let foregroundPID, foregroundPID == pid else { return .notForeground }
        return agent ? .agent : .allowed
    }

    /// The foreground of a `terminal.process` reply: its id, and whether its program is an agent.
    static func foreground(_ reply: JSONObject) -> (pid: Int?, agent: Bool) {
        guard let fg = reply.obj("foreground") else { return (nil, false) }
        return (fg.int("pid"), AgentKind.fromProgram(ProcessNames.label(fg)) != nil)
    }
}
