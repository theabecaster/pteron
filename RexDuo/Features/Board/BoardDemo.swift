#if DEBUG
import Foundation
import RexKit

/// `-boardDemo <scenario>` (testing): the agent board at launch, filled with made-up agents, for
/// screenshots of every state without a server. The app uses no server in such a run, so nothing
/// real is opened; a tile's tap does nothing. Scenarios: `none`, `0`, `idle`, `1`, `3`, `6`,
/// `12`, `machines`, `offline`, `stale`, `states`, `long`, `churn`, `kinds`.
enum BoardDemo {
    static var scenario: String? {
        UserDefaults.standard.string(forKey: "boardDemo").flatMap { $0.isEmpty ? nil : $0 }
    }

    private static let studio = UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!
    private static let laptop = UUID(uuidString: "00000000-0000-0000-0000-0000000000a2")!
    private static let mini = UUID(uuidString: "00000000-0000-0000-0000-0000000000a3")!

    private static func agent(_ n: Int, _ kind: AgentKind?, _ state: String, _ message: String?, _ place: String,
                              waiting: String? = nil, progress: Int? = nil, since: TimeInterval? = nil,
                              on server: UUID = studio, name: String? = nil, now: Date) -> BoardAgent {
        var status = ProgramStatus([:])
        status.state = state
        status.waitingFor = waiting
        status.progress = progress
        return BoardAgent(server: server, sessionID: "session:\(n)", windowID: "window:\(n)", blockID: "block:\(n)",
                          kind: kind, name: name ?? kind?.displayName ?? "Program", state: state,
                          stateText: AgentRowLabel.stateText(status), progress: progress, message: message, place: place,
                          waitingSince: state == "blocked" ? now.addingTimeInterval(-(since ?? 0)) : nil)
    }

    /// `step` advances the `churn` scenario.
    static func machines(_ name: String, now: Date, step: Int = 0) -> [BoardMachine]? {
        func one(_ agents: [BoardAgent], link: BoardMachine.Link = .live) -> [BoardMachine] {
            [BoardMachine(id: studio, name: "Studio", link: link, agents: agents)]
        }
        let ask = agent(1, .claude, "blocked", "Run `npm test` in api?", "api › tests", waiting: "permission", since: 12 * 60, now: now)
        let build = agent(2, .codex, "working", "Rewriting the sync queue", "web › build", progress: 62, now: now)
        let done = agent(3, .gemini, "done", "Wrote the release notes", "docs › notes", now: now)
        let failed = agent(4, .claude, "error", "The build failed: 3 type errors", "ios › fix", now: now)
        let question = agent(5, .aider, "blocked", "Which branch should this go on?", "infra › deploy", waiting: "question", since: 3 * 60, now: now)
        let crawl = agent(6, .claude, "working", "Reading 48 files", "api › review", now: now)
        func idle(_ n: Int) -> BoardAgent { agent(n, .claude, "idle", nil, "scratch › tab \(n)", now: now) }

        switch name {
        case "none":
            return []
        case "0":
            return one([])
        case "idle":
            return one((20..<24).map(idle))
        case "1":
            return one([ask])
        case "3":
            return one([build, ask, done])
        case "6":
            return one([build, done, ask, failed, question, crawl, idle(20), idle(21)])
        case "12":
            let extra = (7..<13).map { agent($0, $0 % 2 == 0 ? .codex : .claude, $0 % 3 == 0 ? "done" : "working",
                                             "Step \($0) of the migration", "data › shard \($0)", now: now) }
            return one([build, done, ask, failed, question, crawl] + extra)
        case "machines":
            var a = ask, b = build
            a.server = studio
            b.server = studio
            let c = agent(7, .gemini, "working", "Profiling the renderer", "ios › perf", on: laptop, now: now)
            let d = agent(8, .claude, "done", "Merged the fix", "api › hotfix", on: laptop, now: now)
            let e = agent(9, .codex, "blocked", "Enter the sudo password", "ops › upgrade", waiting: "auth", since: 40, on: laptop, now: now)
            return [BoardMachine(id: studio, name: "Studio", link: .live, agents: [a, b]),
                    BoardMachine(id: laptop, name: "Laptop", link: .live, agents: [c, d, e]),
                    BoardMachine(id: mini, name: "Mini", link: .never, agents: [])]
        case "offline":
            return one([ask, build, done], link: .stale)
        case "stale":
            // The connected machine is quiet; the one that is down last had an agent waiting.
            let a = agent(11, .claude, "blocked", "Run `npm test` in api?", "api › tests", waiting: "permission", since: 300, on: laptop, now: now)
            let d = agent(12, .codex, "done", "Wrote the release notes", "docs › notes", on: laptop, now: now)
            return [BoardMachine(id: studio, name: "Studio", link: .live, agents: [idle(20), idle(21)]),
                    BoardMachine(id: laptop, name: "Laptop", link: .stale, agents: [a, d])]
        case "states":
            let password = agent(10, .codex, "blocked", "sudo needs your password", "ops › upgrade", waiting: "auth", since: 95 * 60, now: now)
            return one([ask, question, password, failed, build, crawl, done, idle(20), idle(21)])
        case "long":
            let a = agent(1, nil, "blocked", "Allow the agent to run a very long command that goes on and on, with many flags and a path that never seems to end?",
                          "a-session-with-a-rather-long-name › a tab title that is long as well", waiting: "permission", since: 3 * 3600,
                          name: "An agent with a very long program name", now: now)
            let b = agent(2, .opencode, "working", "Refactoring the whole notification pipeline, the gateway client and every test that touches them, one file at a time",
                          "monorepo-platform-services › refactor/notifications-pipeline", progress: 7, now: now)
            let c = agent(3, .cursor, "error", "error: could not compile `rexduo-beacon` (bin \"beacon\") due to 14 previous errors; 3 warnings emitted",
                          "beacon › cargo build --release --target aarch64", now: now)
            return one([a, b, c])
        case "kinds":
            // One agent of each kind, for their marks.
            let kinds: [AgentKind] = [.claude, .codex, .gemini, .opencode, .amp, .aider, .cursor]
            let states = ["blocked", "working", "done", "working", "blocked", "error", "working"]
            return one(kinds.enumerated().map { i, k in
                agent(40 + i, k, states[i], "\(k.displayName) at work", "marks › tab \(i + 1)",
                      waiting: states[i] == "blocked" ? "question" : nil, since: Double(i + 1) * 60, now: now)
            } + [agent(47, nil, "working", "A shell", "marks › tab 8", now: now)])
        case "churn":
            // Six agents whose states rotate, faster than the board may reorder.
            let states = ["working", "blocked", "done", "error", "working", "done"]
            let kinds: [AgentKind] = [.claude, .codex, .gemini, .aider, .claude, .codex]
            return one((0..<6).map { i in
                let s = states[(i + step) % states.count]
                return agent(30 + i, kinds[i], s, "Agent \(i + 1), step \(step)", "churn › tab \(i + 1)",
                             waiting: s == "blocked" ? "question" : nil, since: Double(i) * 60, now: now)
            })
        default:
            return nil
        }
    }
}
#endif
