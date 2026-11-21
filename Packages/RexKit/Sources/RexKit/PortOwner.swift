import Foundation

/// The process behind a listening port and what started it, as the computer's Beacon reports
/// them (`port_owner`): the holder first, then each parent upward. Rex names a port's process
/// and nothing above it, so this is what tells a server started through `npm run dev` from one
/// left in the background (docs/terminal.md, Ports).
public struct PortOwner: Equatable, Sendable {
    public struct Link: Equatable, Sendable {
        public var pid: Int
        public var ppid: Int
        public var pgid: Int
        public var sid: Int
        public var groupLeader: Bool
        public var sessionLeader: Bool
        public var name: String
        public var path: String
        /// The arguments the process was started with, or nil when they couldn't be read.
        public var argv: [String]?
        /// An argument wasn't text: what `argv` holds in its place is not what the process got.
        public var argvLossy: Bool
        /// The arguments were cut short.
        public var truncated: Bool
        public var cwd: String?

        public init(pid: Int, ppid: Int, pgid: Int, sid: Int = 0, groupLeader: Bool? = nil, sessionLeader: Bool? = nil, name: String,
                    path: String = "", argv: [String]? = nil, argvLossy: Bool = false, truncated: Bool = false, cwd: String? = nil) {
            self.pid = pid
            self.ppid = ppid
            self.pgid = pgid
            self.sid = sid
            self.groupLeader = groupLeader ?? (pid == pgid)
            self.sessionLeader = sessionLeader ?? (pid == sid)
            self.name = name
            self.path = path
            self.argv = argv
            self.argvLossy = argvLossy
            self.truncated = truncated
            self.cwd = cwd
        }

        /// Nil without the three ids: a link that can't be placed is no link.
        init?(_ o: JSONObject) {
            guard let pid = o.int("pid"), let ppid = o.int("ppid"), let pgid = o.int("pgid") else { return nil }
            self.pid = pid
            self.ppid = ppid
            self.pgid = pgid
            sid = o.int("sid") ?? 0
            groupLeader = o.bool("group_leader") ?? (pid == pgid)
            sessionLeader = o.bool("session_leader") ?? (pid == sid)
            name = o.str("name") ?? ""
            path = o.str("path") ?? ""
            // Every argument must be text. A list with anything else in it is unreadable, and
            // a flag that is missing counts as set: nothing is typed from a reply that is unsure.
            if let raw = o["argv"] as? [Any] {
                let words = raw.compactMap { $0 as? String }
                argv = words.count == raw.count ? words : nil
            } else {
                argv = nil
            }
            argvLossy = o.bool("argv_lossy") ?? true
            truncated = o.bool("truncated") ?? true
            cwd = o.str("cwd")
        }
    }

    /// The process that holds the port.
    public var pid: Int
    /// Its process group: an interrupt typed into a terminal goes to the terminal's foreground
    /// group, every process of it.
    public var pgid: Int
    /// The foreground group of the holder's terminal, when the computer could tell.
    public var ttyForegroundPGID: Int?
    /// The holder first, then its parents.
    public var ancestry: [Link]

    public init(pid: Int, pgid: Int, ttyForegroundPGID: Int?, ancestry: [Link]) {
        self.pid = pid
        self.pgid = pgid
        self.ttyForegroundPGID = ttyForegroundPGID
        self.ancestry = ancestry
    }

    /// A `port_owner` result. Nil when it names no holder, when its first link is not the
    /// holder, or when a link doesn't follow from the one before it: a chain with a gap proves
    /// nothing about who started what.
    public init?(_ result: JSONObject) {
        guard let pid = result.int("pid"), let pgid = result.int("pgid") else { return nil }
        let raw = result.arr("ancestry")
        let links = raw.compactMap(Link.init)
        guard links.count == raw.count, let first = links.first, first.pid == pid, first.pgid == pgid else { return nil }
        for (child, parent) in zip(links, links.dropFirst()) where child.ppid != parent.pid { return nil }
        self.pid = pid
        self.pgid = pgid
        ttyForegroundPGID = result.int("tty_foreground_pgid")
        ancestry = links
    }

    /// The links of the holder's own process group: what one interrupt reaches together.
    public var group: [Link] { ancestry.filter { $0.pgid == pgid } }

    /// Whether a Ctrl-C typed into a pane whose foreground process is `foregroundPID` (as Rex
    /// names it) reaches the port's holder.
    ///
    /// The pane's foreground must be the holder, the leader of the holder's group, or one of
    /// the holder's parents in that same group. A parent in another group doesn't count: an
    /// interrupt goes to one group, so a server its starter moved to a group of its own, or
    /// one left in the background under the shell, is not reached. Where the computer names the
    /// foreground group of the holder's terminal, that must be the holder's group as well.
    public func interruptReaches(foregroundPID: Int?) -> Bool {
        guard let fg = foregroundPID, fg > 1 else { return false }
        if let front = ttyForegroundPGID, front != pgid { return false }
        return fg == pid || fg == pgid || group.contains { $0.pid == fg }
    }

    /// The job the pane runs for this port: the leader of the holder's group, with the process
    /// that started it. Nil when the chain doesn't hold both.
    public var job: (leader: Link, parent: Link)? {
        guard let at = ancestry.firstIndex(where: { $0.pid == pgid && $0.groupLeader }), at + 1 < ancestry.count else { return nil }
        let leader = ancestry[at], parent = ancestry[at + 1]
        return leader.ppid == parent.pid ? (leader, parent) : nil
    }
}

/// The command a Restart types: the arguments the pane's job was started with, spelled so a
/// shell at its prompt reads them back as the same words (`ShellEscape`). Pure, so it is tested.
///
/// It is not what the user typed. Variables set before the command (`PORT=4000 npm run dev`),
/// an alias, and anything after a pipe are not in a process's arguments, so nothing here or on
/// screen says the two are the same: the row shows the text, and the user confirms that text.
public struct RestartCommand: Equatable, Sendable {
    /// One line, without the Return.
    public var text: String
    /// The shell that started the job, which the pane's foreground must be again before the
    /// text is typed.
    public var shellPID: Int
    /// The job's leader when the command was read: a different leader is a different job.
    public var leaderPID: Int

    public init(text: String, shellPID: Int, leaderPID: Int) {
        self.text = text
        self.shellPID = shellPID
        self.leaderPID = leaderPID
    }

    /// What goes to the pane: the line and Return.
    public var typed: String { text + "\r" }

    /// The longest line a Restart types. A longer one can't be read in a sidebar's row, and
    /// what can't be read can't be confirmed.
    public static let limit = 300

    public enum Refusal: Error, Equatable, Sendable {
        /// The chain has no job leader with the process that started it.
        case noJob
        /// The job wasn't started by a shell, or it is a part of the shell itself (a subshell,
        /// a function): its arguments are the shell's, not a command.
        case notFromShell
        /// The arguments are missing, cut short or not text.
        case unreadable
        /// An argument has no spelling on one line (empty, or with a control character), or the
        /// first word would read as something other than a program's name.
        case unquotable
        case tooLong
        /// The job runs somewhere else than its shell is: the app never types `cd`.
        case elsewhere
    }

    /// The command for the job that holds `owner`'s port, or why there is none.
    /// `isShell`: whether a program's name is a shell's.
    public static func make(_ owner: PortOwner, isShell: (String) -> Bool) -> Result<RestartCommand, Refusal> {
        guard let (leader, shell) = owner.job else { return .failure(.noJob) }
        guard isShell(programName(shell)) else { return .failure(.notFromShell) }
        guard let argv = leader.argv, !argv.isEmpty, !leader.truncated, !leader.argvLossy else { return .failure(.unreadable) }
        // A subshell or a shell function runs as a copy of the shell, with the shell's own
        // arguments (`-zsh`): typing those would start a shell, not the server.
        if argv == shell.argv || argv[0].hasPrefix("-") { return .failure(.notFromShell) }
        // The folder the command runs in is the shell's, so both must be the same and known.
        guard let here = leader.cwd, let there = shell.cwd, !here.isEmpty, folder(here) == folder(there) else { return .failure(.elsewhere) }
        // `NAME=value` as the first word sets a variable and runs nothing.
        guard !argv[0].contains("=") else { return .failure(.unquotable) }
        var words: [String] = []
        for a in argv {
            guard let w = word(a) else { return .failure(.unquotable) }
            words.append(w)
        }
        let text = words.joined(separator: " ")
        guard text.count <= limit else { return .failure(.tooLong) }
        return .success(RestartCommand(text: text, shellPID: shell.pid, leaderPID: leader.pid))
    }

    /// One argument as a shell word. `ShellEscape` keeps a leading `~/` as the home folder,
    /// which is right for a path and wrong here: the process got a literal `~`.
    static func word(_ arg: String) -> String? {
        guard arg == "~" || arg.hasPrefix("~/") else { return ShellEscape.escape(arg) }
        let rest = String(arg.dropFirst())
        guard !rest.isEmpty else { return "\\~" }
        return ShellEscape.escape(rest).map { "\\~" + $0 }
    }

    /// A process's program as a shell is named: a login shell's `-zsh` is `zsh`.
    static func programName(_ l: PortOwner.Link) -> String {
        let name = l.name.isEmpty ? (l.path as NSString).lastPathComponent : l.name
        return name.hasPrefix("-") ? String(name.dropFirst()) : name
    }

    private static func folder(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// A Restart, step by step. Pure: the app feeds it what happened and does what it says next.
///
/// The order never changes and nothing is tried twice: the pane comes on screen, one Ctrl-C
/// goes, the shell is back in front with the port gone, the command is typed once, the port
/// comes back. Anything else ends it, and from the first failure on nothing more is typed.
public struct PortRestart: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// The row shows the command and waits for the one tap.
        case confirming
        /// The pane is being put on screen; nothing is typed until it shows a current screen.
        case revealing
        /// The Ctrl-C is on its way.
        case stopping
        /// Waiting for the shell in front and the port gone.
        case waitingForShell
        /// The command is on its way.
        case typing
        /// Typed; waiting for the port.
        case waitingForPort
        case done
        case failed(Failure)
    }

    public enum Failure: Equatable, Sendable {
        /// The job is not the one the row showed any more, or its command reads differently now.
        case changed
        /// The pane didn't come on screen with a current screen in time.
        case paneNotReady
        /// Stop's own rule said no, or the interrupt didn't leave.
        case notStopped
        /// The program kept running, or something else took the foreground.
        case stillRunning
        /// The command didn't leave the phone: nothing was typed.
        case notTyped
        /// Typed, and no port within the limit.
        case noPort
    }

    public enum Event: Equatable, Sendable {
        case confirmed
        /// The fresh read of the job: whether it is still the one confirmed.
        case checked(same: Bool)
        case paneReady(Bool)
        case stopped(Bool)
        case shellBack(Bool)
        case typed(Bool)
        case portBack(Bool)
    }

    public private(set) var step: Step

    public init(step: Step = .confirming) {
        self.step = step
    }

    /// How long the shell has to come back in front with the port gone.
    public static let shellLimit: TimeInterval = 10
    /// How long the port has to come back.
    public static let portLimit: TimeInterval = 30

    /// Whether the app may write to the pane in this step, and what.
    public enum Write: Equatable, Sendable { case interrupt, command }
    public var mayWrite: Write? {
        switch step {
        case .stopping: .interrupt
        case .typing: .command
        default: nil
        }
    }

    /// The row keeps its place while its port is away.
    public var holdsRow: Bool {
        switch step {
        case .stopping, .waitingForShell, .typing, .waitingForPort, .failed: true
        case .confirming, .revealing, .done: false
        }
    }

    public var isOver: Bool {
        switch step {
        case .done, .failed: true
        default: false
        }
    }

    /// Takes what happened. An event that doesn't belong to the step changes nothing, so a late
    /// answer can't move a Restart that has ended or moved on.
    @discardableResult
    public mutating func take(_ event: Event) -> Step {
        switch (step, event) {
        case (.confirming, .confirmed): step = .revealing
        case (.revealing, .checked(let same)): if !same { step = .failed(.changed) }
        case (.revealing, .paneReady(let ok)): step = ok ? .stopping : .failed(.paneNotReady)
        case (.stopping, .stopped(let ok)): step = ok ? .waitingForShell : .failed(.notStopped)
        case (.waitingForShell, .shellBack(let ok)): step = ok ? .typing : .failed(.stillRunning)
        case (.typing, .typed(let ok)): step = ok ? .waitingForPort : .failed(.notTyped)
        case (.waitingForPort, .portBack(let ok)): step = ok ? .done : .failed(.noPort)
        default: break
        }
        return step
    }
}

/// A port of the computer that its Beacon lets this phone's browsers reach (`port_share`).
public struct PortShare: Equatable, Sendable {
    /// The address to open, by the computer's name where it has one.
    public var url: URL
    /// How long the computer keeps it after its last use.
    public var idle: TimeInterval

    public init(url: URL, idle: TimeInterval) {
        self.url = url
        self.idle = idle
    }

    /// A `port_share` result. Nil unless `url` is a plain web address with a host and a port:
    /// the app opens nothing else from a reply.
    public init?(_ result: JSONObject) {
        guard let text = result.str("url"), let c = URLComponents(string: text), c.scheme?.lowercased() == "http",
              let host = c.host, !host.isEmpty, c.port != nil, c.user == nil, c.password == nil,
              c.path.isEmpty || c.path == "/", c.query == nil, c.fragment == nil, let url = c.url else { return nil }
        self.url = url
        idle = TimeInterval(max(0, result.int("idle_seconds") ?? 0))
    }

    /// The shared address of a page: the path, query and fragment of `rest` under the share.
    public func page(_ rest: String) -> URL? {
        var base = url.absoluteString
        if base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + (rest.hasPrefix("/") ? rest : "/" + rest))
    }

    /// Until when the app takes the share to exist, asked at `asked`: the computer keeps it at
    /// least `idle` from then, and the app stops counting on it a minute sooner.
    public func knownUntil(asked: Date) -> Date {
        asked.addingTimeInterval(max(0, idle - 60))
    }
}

/// What a Beacon's answer to `port_share` or `port_owner` means for the app.
public enum PortBeaconAnswer: Equatable, Sendable {
    /// What the app does with a refusal.
    public enum Share: Equatable, Sendable {
        /// This computer can't do it at all, for this connection: the item goes away.
        case hide
        /// It can, not for this port or not now: the item stays.
        case keep
    }

    /// How a `port_share` error code is taken. Unknown codes keep the item: one failure of an
    /// unknown kind says nothing about the next.
    public static func share(code: String, unknownAction: Bool) -> Share {
        if unknownAction { return .hide }
        switch code {
        case "not_supported", "not_available", "not_registered", "not_your_phone": return .hide
        default: return .keep
        }
    }

    /// Whether a `port_owner` error means the Beacon can't be asked at all on this connection.
    /// `not_available` is about one process (it ended, or it is another user's) and
    /// `bad_request` about one question.
    public static func ownerMissing(code: String, unknownAction: Bool) -> Bool {
        if unknownAction { return true }
        return ["not_supported", "not_registered", "refused"].contains(code)
    }
}

/// The phone's own address on the tailnet, which a share is held to. Pure: the app reads the
/// interfaces and this picks (`PrivateNetwork.address`).
public enum TailnetAddress {
    public enum Candidate: Equatable, Sendable {
        case v4(interface: String, UInt32)
        case v6([UInt8])
    }

    /// 100.64.0.0/10, the range Tailscale assigns from. It is also the carrier-grade NAT range
    /// a cellular network can give the phone itself, so it counts only on a tunnel (`utun*`).
    public static func isTailnet(interface name: String, ipv4 a: UInt32) -> Bool {
        name.hasPrefix("utun") && a & 0xFFC0_0000 == 0x6440_0000
    }

    /// fd7a:115c:a1e0::/48, Tailscale's own.
    public static func isTailnet(ipv6 b: [UInt8]) -> Bool {
        b.count == 16 && Array(b.prefix(6)) == [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]
    }

    /// The address to give: the IPv4 one when there is one (every tailnet device has it), else
    /// the IPv6 one, else nil. The first of each kind, in the order given.
    public static func pick(_ all: [Candidate]) -> String? {
        var six: String?
        for c in all {
            switch c {
            case .v4(let name, let a):
                if isTailnet(interface: name, ipv4: a) { return text(ipv4: a) }
            case .v6(let b):
                if six == nil, isTailnet(ipv6: b) { six = text(ipv6: b) }
            }
        }
        return six
    }

    public static func text(ipv4 a: UInt32) -> String {
        "\(a >> 24 & 0xFF).\(a >> 16 & 0xFF).\(a >> 8 & 0xFF).\(a & 0xFF)"
    }

    /// All eight groups in hex, no `::`: every reader takes it, and it is only sent, never shown.
    public static func text(ipv6 b: [UInt8]) -> String {
        stride(from: 0, to: 16, by: 2).map { String(UInt16(b[$0]) << 8 | UInt16(b[$0 + 1]), radix: 16) }.joined(separator: ":")
    }
}
