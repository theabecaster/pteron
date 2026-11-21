import Foundation
import RexKit

/// Whether Stop may type Ctrl-C into a port's pane. Pure, so it is tested (docs/terminal.md,
/// Ports).
///
/// Ctrl-C goes to whatever is in the pane's foreground, so Stop is for a server the interrupt
/// reaches, in a pane with no agent. From Rex alone that is one case: the process that holds
/// the port is itself the pane's foreground process. Rex names the foreground's parents, never
/// the port holder's, so a server started through a wrapper (`npm run dev`, where `npm` is in
/// front and its child holds the port) can't be told from one beside the foreground. Where the
/// computer's Beacon names the holder's parents and process group (`PortOwner`), the wrapped
/// server gets its Stop too: the pane's foreground is the holder's group. A server left in the
/// background (`npm run dev &`), one whose pane now runs something else and one an agent
/// started get no Stop either way.
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

    /// The same with what the computer's Beacon says of the port's process. `owner` only adds
    /// a yes for a server behind a wrapper, and only when it is about the very process Rex
    /// names for the port, when the pane's foreground is that process's group
    /// (`PortOwner.interruptReaches`) and when no process of that group is an agent.
    static func verdict(entry: PortEntry?, expected: Int? = nil, foregroundPID: Int?, agent: Bool, owner: PortOwner?) -> Verdict {
        let plain = verdict(entry: entry, expected: expected, foregroundPID: foregroundPID, agent: agent)
        guard plain == .notForeground, let owner, owner.pid == entry?.pid, owner.interruptReaches(foregroundPID: foregroundPID) else { return plain }
        return agent || agentInGroup(owner) ? .agent : .allowed
    }

    /// An agent is one of the processes an interrupt for this port would reach.
    static func agentInGroup(_ owner: PortOwner) -> Bool {
        owner.group.contains { link in
            AgentKind.fromProgram(link.name) != nil || link.argv?.first.flatMap { AgentKind.fromProgram(($0 as NSString).lastPathComponent) } != nil
        }
    }

    /// The command a Restart would type for this port, or nil when there is none to offer: the
    /// rule Stop has, and a job whose command can be read whole and typed on one line in the
    /// folder its shell is in (`RestartCommand`).
    static func restart(entry: PortEntry?, expected: Int? = nil, foregroundPID: Int?, agent: Bool, owner: PortOwner?) -> RestartCommand? {
        guard let owner, owner.pid == entry?.pid, !agent, !agentInGroup(owner), owner.interruptReaches(foregroundPID: foregroundPID),
              verdict(entry: entry, expected: expected, foregroundPID: foregroundPID, agent: agent, owner: owner) == .allowed else { return nil }
        return try? RestartCommand.make(owner, isShell: ProcessNames.isShell).get()
    }

    /// The foreground of a `terminal.process` reply: its id, and whether its program is an agent.
    static func foreground(_ reply: JSONObject) -> (pid: Int?, agent: Bool) {
        guard let fg = reply.obj("foreground") else { return (nil, false) }
        return (fg.int("pid"), AgentKind.fromProgram(ProcessNames.label(fg)) != nil)
    }
}
