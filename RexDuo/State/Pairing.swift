import Foundation
import GlanceModel
import Observation
import RexKit

/// A scanned pairing code. Rex's code (`rex server tailscale pair`) holds only the server's https
/// address, no credential, so reading one is parsing a URL.
enum PairingCode {
    /// The server address in a scanned code, normalized to `https://host[:port]`. Nil for anything
    /// that isn't an https address: other text, other schemes, addresses with a login in them.
    static func address(from payload: String) -> URL? {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: \.isWhitespace), let c = URLComponents(string: text),
              c.scheme?.lowercased() == "https", c.user == nil, c.password == nil,
              let host = c.host.flatMap(validHost) else { return nil }
        var out = URLComponents()
        out.scheme = "https"
        out.host = host
        if let p = c.port, p != 443 { out.port = p }
        return out.url
    }

    /// The host in lower case without a trailing dot, when it is a full name (`studio.tail1234.ts.net`)
    /// or an IP address. Nil for a single label, an empty or malformed label, or a last label that
    /// can't be a top-level domain.
    static func validHost(_ raw: String) -> String? {
        var host = raw.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        // An IPv6 literal; URLComponents has already checked its form.
        if host.contains(":") {
            let inner = host.hasPrefix("[") && host.hasSuffix("]") ? host.dropFirst().dropLast() : Substring(host)
            return !inner.isEmpty && inner.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." } ? host : nil
        }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, host.utf8.count <= 253 else { return nil }
        if labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
            return labels.count == 4 && labels.allSatisfy { Int($0).map { $0 <= 255 } == true } ? host : nil
        }
        let ok = labels.allSatisfy { l in
            (1...63).contains(l.utf8.count) && l.first != "-" && l.last != "-"
                && l.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        guard ok, let tld = labels.last, tld.count >= 2, tld.contains(where: \.isLetter) else { return nil }
        return host
    }

    /// The saved server at the same host and port, however its address was typed.
    static func existing(_ url: URL, in servers: [ServerConfig]) -> ServerConfig? {
        guard let key = key(url) else { return nil }
        return servers.first { ServerConfig.url(from: $0.url).flatMap(Self.key) == key }
    }

    private static func key(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        let port = url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443)
        return "\(host):\(port)"
    }

    /// Where a computer on a server's host list can be reached, when that can be told.
    struct Candidate: Equatable {
        var url: URL
        /// Worked out from the listing server's own address, not stated by the host list. It may
        /// not exist, so a failed check says to pair with a code instead of offering to add it.
        var guessed: Bool
    }

    /// The address of a host a server lists (`hosts.list`). An endpoint that is an https address
    /// or a private-network name is taken as is. Otherwise, when the listing server's own address
    /// has Rex's form, `<computer>-rex.<network>`, the host is assumed to follow it under its
    /// label. Nil when neither applies: an ssh-only host listed by a server at some other address.
    static func candidate(label: String, endpoints: [String], listedBy server: URL) -> Candidate? {
        for endpoint in endpoints {
            if let url = address(from: endpoint) { return Candidate(url: url, guessed: false) }
            if !endpoint.contains("://"), !endpoint.contains("/"), let url = address(from: "https://" + endpoint), tailnet(of: url) != nil {
                return Candidate(url: url, guessed: false)
            }
        }
        guard let network = tailnet(of: server), server.host()?.split(separator: ".").first?.hasSuffix("-rex") == true,
              let url = address(from: "https://\(label.lowercased())-rex.\(network)") else { return nil }
        return Candidate(url: url, guessed: true)
    }

    /// The tailnet a host belongs to (`tail1234.ts.net` for `studio.tail1234.ts.net`), or nil when
    /// the host isn't a tailnet name.
    static func tailnet(of url: URL) -> String? {
        guard let labels = url.host()?.lowercased().split(separator: "."), labels.count >= 4,
              labels.suffix(2) == ["ts", "net"] else { return nil }
        return labels.suffix(3).joined(separator: ".")
    }

    /// The code's tailnet is none of the saved servers' tailnets: a hint that the computer is on a
    /// private network this iPhone isn't part of. False when either side has no tailnet to compare.
    static func isForeignTailnet(_ url: URL, servers: [ServerConfig]) -> Bool {
        guard let mine = tailnet(of: url) else { return false }
        let known = Set(servers.compactMap { ServerConfig.url(from: $0.url).flatMap(tailnet) })
        return !known.isEmpty && !known.contains(mine)
    }
}

/// Why a scanned server wasn't added straight away, and what the person can do about it. Worded
/// like the offline screen: the app says what it can see.
struct PairingProblem: Equatable {
    enum Action: Equatable { case tryAgain, addAnyway }

    var symbol: String
    var title: String
    var message: String
    /// A short technical line, shown collapsed. Only for a failure the app can't explain.
    var detail: String?
    /// Besides Cancel, which is always there.
    var actions: [Action]

    static func of(_ problem: ConnectionProblem, foreignTailnet: Bool) -> PairingProblem {
        let offNetwork = PairingProblem(
            symbol: "antenna.radiowaves.left.and.right.slash", title: "Out of range",
            message: "This iPhone can't reach that computer's private network. Connect it to the same network or VPN as that computer, then try again.",
            actions: [.tryAgain, .addAnyway])
        switch problem.kind {
        case .noInternet:
            return PairingProblem(symbol: "wifi.slash", title: "No connection",
                                  message: "This iPhone is offline right now. Connect it to a network, then try again.",
                                  actions: [.tryAgain])
        case .offPrivateNetwork, .hostNotFound:
            return offNetwork
        case .notAnswering:
            if foreignTailnet { return offNetwork }
            return PairingProblem(symbol: "moon.zzz", title: "Not answering",
                                  message: "That computer isn't answering. It may be asleep, or Rex isn't open there.",
                                  actions: [.tryAgain, .addAnyway])
        case .notAllowed:
            return PairingProblem(symbol: "lock", title: "Not allowed in",
                                  message: "That computer didn't let this iPhone in. It may belong to a different account.",
                                  actions: [])
        case .updateServer:
            return PairingProblem(symbol: "arrow.down.circle", title: "Update Rex on that computer",
                                  message: "Rex there is too old for this version of \(Brand.appName). Update Rex on that computer, then try again.",
                                  actions: [.tryAgain])
        case .updateApp:
            return PairingProblem(symbol: "arrow.down.circle", title: "Update \(Brand.appName)",
                                  message: "That computer runs a newer Rex than this version of \(Brand.appName) works with. Update \(Brand.appName), then try again.",
                                  actions: [.tryAgain])
        case .insecure:
            return PairingProblem(symbol: "lock.trianglebadge.exclamationmark", title: "Can't verify that computer",
                                  message: "The secure connection to that computer failed, so \(Brand.appName) stopped there.",
                                  detail: problem.detail, actions: [.tryAgain])
        case .badAddress, .unknown:
            return PairingProblem(symbol: "antenna.radiowaves.left.and.right.slash", title: "Can't connect",
                                  message: "Something stopped this iPhone from reaching that computer.",
                                  detail: problem.detail, actions: [.tryAgain, .addAnyway])
        }
    }
}

/// What checking a scanned address found.
enum PairingCheck: Equatable {
    /// Rex answered. The identity is nil when it answered but wouldn't say who it is.
    case reachable(ServerIdentity?)
    case problem(ConnectionProblem)
}

/// What the identity card says about a computer, under its name and address.
struct IdentityCopy: Equatable {
    /// How many session names the card shows before "+n".
    static let maxSessions = 3

    var symbol: String
    /// "alex · Mac · 3 sessions". Nil when the computer said nothing about itself.
    var summary: String?
    /// The first few session names.
    var sessions: [String]
    /// Sessions beyond the ones named.
    var more: Int
    /// Only when the computer's owner isn't the login this iPhone connects as.
    var owner: String?
    /// Only when no helper is running on the computer.
    var helper: String?

    /// Only what the computer said. A count or a helper it didn't report is left out, never
    /// shown as "none".
    static func of(_ id: ServerIdentity?) -> IdentityCopy {
        guard let id else { return IdentityCopy(symbol: "desktopcomputer", sessions: [], more: 0) }
        var parts: [String] = []
        if let account = id.account { parts.append(account) }
        switch id.platform {
        case .mac: parts.append("Mac")
        case .linux: parts.append("Linux")
        case .other, nil: break
        }
        switch id.sessionCount {
        case nil: break
        case 0: parts.append("No sessions yet")
        case 1: parts.append("1 session")
        case let n?: parts.append("\(n) sessions")
        }
        let shown = Array(id.sessions.prefix(maxSessions))
        return IdentityCopy(
            symbol: id.platform == .mac ? "laptopcomputer" : id.platform == .linux ? "server.rack" : "desktopcomputer",
            summary: parts.isEmpty ? nil : parts.joined(separator: " · "),
            sessions: shown,
            more: shown.isEmpty ? 0 : max(0, (id.sessionCount ?? 0) - shown.count),
            owner: id.belongsToSomeoneElse ? id.owner.map { "This computer belongs to \($0)." } : nil,
            helper: id.hasHelper == false ? "Notifications need \(Brand.beaconName) on this computer." : nil)
    }
}

extension PairingProblem {
    /// An address that was only worked out didn't answer: it may not exist, so it is not offered
    /// for adding. A refusal or no network at all keeps its own message.
    static func guessed(_ problem: ConnectionProblem, foreignTailnet: Bool) -> PairingProblem {
        switch problem.kind {
        case .noInternet, .notAllowed:
            return of(problem, foreignTailnet: foreignTailnet)
        default:
            return PairingProblem(symbol: "qrcode.viewfinder", title: "Can't find that computer",
                                  message: "Pair it with a QR code from that computer.", actions: [])
        }
    }
}

/// One run of "Pair via QR Code": a scanned code is parsed, matched against the saved servers,
/// checked for an answer, then named and added. It reaches the app only through the closures it
/// is given, so tests run it without a camera or a network.
@MainActor
@Observable
final class PairingModel {
    enum Step: Equatable {
        case scanning
        case checking(URL)
        /// The server answered: its identity card, with a name to confirm.
        case found(URL, ServerIdentity?)
        case problem(URL, PairingProblem)
        /// The server was added; its card stays up while the sheet leaves. Ends the run.
        case added(URL, ServerIdentity?)
        /// The server was already saved. Ends the run.
        case done
    }

    /// Nothing more happens in this run.
    var isFinished: Bool {
        switch step {
        case .added, .done: return true
        default: return false
        }
    }

    static let notACode = "That's not a Rex pairing code."
    /// A code not seen for this long has left the camera's view.
    static let outOfView: TimeInterval = 1.5

    private(set) var step: Step = .scanning
    /// Shown over the camera while the code in view isn't a pairing code.
    private(set) var rejection: String?
    /// The new server's name, editable while it is `found`.
    var name = ""

    @ObservationIgnored private let servers: () -> [ServerConfig]
    @ObservationIgnored private let probe: (URL) async -> PairingCheck
    @ObservationIgnored private let onExisting: (ServerConfig) -> Void
    @ObservationIgnored private let onAdd: (ServerConfig) -> Void
    /// Counts checks, so an answer to one the person has left is dropped.
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var check: Task<Void, Never>?
    /// The address being checked was worked out, not read from a code or a host list.
    @ObservationIgnored private var guessed = false
    /// The code the camera last reported and when. The camera reports a code on every frame it is
    /// in view, so a code is handled once per stay in view: cancelling a check with the code still
    /// in front of the camera doesn't start the check again.
    @ObservationIgnored private var lastPayload: String?
    @ObservationIgnored private var lastSeen = Date.distantPast
    @ObservationIgnored private var rejectionWatch: Task<Void, Never>?

    init(servers: @escaping () -> [ServerConfig], probe: @escaping (URL) async -> PairingCheck,
         onExisting: @escaping (ServerConfig) -> Void, onAdd: @escaping (ServerConfig) -> Void) {
        self.servers = servers
        self.probe = probe
        self.onExisting = onExisting
        self.onAdd = onAdd
    }

    /// The camera sees a code. True when it was taken (the caller plays the haptic): not for a code
    /// that isn't a pairing code, one already handled while it stayed in view, or any code while
    /// not scanning.
    @discardableResult
    func scanned(_ payload: String, at now: Date = Date()) -> Bool {
        let fresh = payload != lastPayload || now.timeIntervalSince(lastSeen) > Self.outOfView
        lastPayload = payload
        lastSeen = now
        guard step == .scanning, fresh else { return false }
        guard let url = PairingCode.address(from: payload) else {
            rejection = Self.notACode
            watchRejection()
            return false
        }
        clearRejection()
        take(url, guessed: false)
        return true
    }

    /// A computer picked from a server's host list: the same run as a scanned code, from its
    /// address. `name` is what the list calls it.
    func start(_ candidate: PairingCode.Candidate, name: String) {
        guard step == .scanning else { return }
        take(candidate.url, guessed: candidate.guessed)
        if case .checking = step { self.name = name }
    }

    private func take(_ url: URL, guessed: Bool) {
        // A server that is already saved keeps the name its owner gave it.
        if let saved = PairingCode.existing(url, in: servers()) {
            step = .done
            onExisting(saved)
            return
        }
        self.guessed = guessed
        name = ServerConfig.name(for: url)
        check(url)
    }

    /// Drops the "not a pairing code" message once that code has left the view. True when it did.
    @discardableResult
    func expireRejection(at now: Date = Date()) -> Bool {
        guard rejection != nil, now.timeIntervalSince(lastSeen) > Self.outOfView else { return false }
        clearRejection()
        return true
    }

    func tryAgain() {
        guard case .problem(let url, let problem) = step, problem.actions.contains(.tryAgain) else { return }
        check(url)
    }

    /// Saves the server though it didn't answer; it shows as offline until it does. Only for a
    /// problem that offers it.
    func addAnyway() {
        guard case .problem(let url, let problem) = step, problem.actions.contains(.addAnyway) else { return }
        add(url, nil)
    }

    func add() {
        guard case .found(let url, let identity) = step else { return }
        add(url, identity)
    }

    /// Back to the camera, dropping any check still running.
    func rescan() {
        guard !isFinished else { return }
        stopCheck()
        clearRejection()
        step = .scanning
    }

    /// The sheet is gone: stop whatever is still running.
    func cancel() {
        stopCheck()
        clearRejection()
    }

    private func check(_ url: URL) {
        stopCheck()
        let mine = attempt
        step = .checking(url)
        check = Task { [weak self, probe] in
            let result = await probe(url)
            guard let self, mine == self.attempt, !Task.isCancelled else { return }
            switch result {
            case .problem(let problem):
                let foreign = PairingCode.isForeignTailnet(url, servers: self.servers())
                self.step = .problem(url, self.guessed ? .guessed(problem, foreignTailnet: foreign)
                                                        : .of(problem, foreignTailnet: foreign))
            case .reachable(let identity):
                self.step = .found(url, identity)
            }
        }
    }

    private func stopCheck() {
        attempt += 1
        check?.cancel()
        check = nil
    }

    private func add(_ url: URL, _ identity: ServerIdentity?) {
        stopCheck()
        // Saved in the meantime (another window, a second device syncing): open it, add nothing.
        if let saved = PairingCode.existing(url, in: servers()) {
            step = .done
            onExisting(saved)
            return
        }
        step = .added(url, identity)
        let typed = name.trimmingCharacters(in: .whitespaces)
        onAdd(ServerConfig(name: typed.isEmpty ? ServerConfig.name(for: url) : typed, url: url.absoluteString))
    }

    private func clearRejection() {
        rejectionWatch?.cancel()
        rejectionWatch = nil
        rejection = nil
    }

    /// The camera reports nothing when no code is in view, so a timer notices the code is gone.
    private func watchRejection() {
        guard rejectionWatch == nil else { return }
        rejectionWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let self, !Task.isCancelled else { return }
                if self.expireRejection() { return }
            }
        }
    }
}
