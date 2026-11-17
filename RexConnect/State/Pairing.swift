import Foundation
import Observation

/// A scanned pairing code. Rex's code (`rex server tailscale pair`) holds only the server's https
/// address, no credential, so reading one is parsing a URL.
enum PairingCode {
    /// The server address in a scanned code, normalized to `https://host[:port]`. Nil for anything
    /// that isn't an https address: other text, other schemes, addresses with a login in them.
    static func address(from payload: String) -> URL? {
        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: \.isWhitespace), let c = URLComponents(string: text),
              c.scheme?.lowercased() == "https", c.user == nil, c.password == nil,
              let host = c.host?.lowercased(), !host.isEmpty, host.contains(".") || host.contains(":") else { return nil }
        var out = URLComponents()
        out.scheme = "https"
        out.host = host
        if let p = c.port, p != 443 { out.port = p }
        return out.url
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
        case .insecure:
            return PairingProblem(symbol: "lock.trianglebadge.exclamationmark", title: "Can't verify that computer",
                                  message: "The secure connection to that computer failed, so Rex DUO stopped there.",
                                  detail: problem.detail, actions: [.tryAgain])
        case .badAddress, .unknown:
            return PairingProblem(symbol: "antenna.radiowaves.left.and.right.slash", title: "Can't connect",
                                  message: "Something stopped this iPhone from reaching that computer.",
                                  detail: problem.detail, actions: [.tryAgain, .addAnyway])
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
        /// The server answered: confirm its name and add it.
        case found(URL)
        case problem(URL, PairingProblem)
    }

    static let notACode = "That's not a Rex pairing code."

    private(set) var step: Step = .scanning
    /// Shown over the camera while the code in view isn't a pairing code.
    private(set) var rejection: String?
    /// The new server's name, editable while it is `found`.
    var name = ""

    @ObservationIgnored private let servers: () -> [ServerConfig]
    /// Nil when the server answered.
    @ObservationIgnored private let probe: (URL) async -> ConnectionProblem?
    @ObservationIgnored private let onExisting: (ServerConfig) -> Void
    @ObservationIgnored private let onAdd: (ServerConfig) -> Void
    /// Counts checks, so an answer to one the person has left is dropped.
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var lastRejected: String?

    init(servers: @escaping () -> [ServerConfig], probe: @escaping (URL) async -> ConnectionProblem?,
         onExisting: @escaping (ServerConfig) -> Void, onAdd: @escaping (ServerConfig) -> Void) {
        self.servers = servers
        self.probe = probe
        self.onExisting = onExisting
        self.onAdd = onAdd
    }

    /// The camera read a code. True when it was taken (the caller plays the haptic); a code that
    /// isn't a pairing code, or any code while not scanning, is not.
    @discardableResult
    func scanned(_ payload: String) -> Bool {
        guard step == .scanning else { return false }
        guard let url = PairingCode.address(from: payload) else {
            if payload != lastRejected {
                lastRejected = payload
                rejection = Self.notACode
            }
            return false
        }
        rejection = nil
        lastRejected = nil
        // A server that is already saved keeps the name its owner gave it.
        if let saved = PairingCode.existing(url, in: servers()) {
            onExisting(saved)
            return true
        }
        name = ServerConfig.name(for: url)
        check(url)
        return true
    }

    func tryAgain() {
        guard case .problem(let url, _) = step else { return }
        check(url)
    }

    /// Saves the server though it didn't answer; it shows as offline until it does.
    func addAnyway() {
        guard case .problem(let url, _) = step else { return }
        add(url)
    }

    func add() {
        guard case .found(let url) = step else { return }
        add(url)
    }

    /// Back to the camera, dropping any check still running.
    func rescan() {
        attempt += 1
        rejection = nil
        lastRejected = nil
        step = .scanning
    }

    private func check(_ url: URL) {
        attempt += 1
        let mine = attempt
        step = .checking(url)
        Task {
            let problem = await probe(url)
            guard mine == attempt else { return }
            if let problem {
                let foreign = PairingCode.isForeignTailnet(url, servers: servers())
                step = .problem(url, .of(problem, foreignTailnet: foreign))
            } else {
                step = .found(url)
            }
        }
    }

    private func add(_ url: URL) {
        attempt += 1
        let typed = name.trimmingCharacters(in: .whitespaces)
        onAdd(ServerConfig(name: typed.isEmpty ? ServerConfig.name(for: url) : typed, url: url.absoluteString))
    }
}
