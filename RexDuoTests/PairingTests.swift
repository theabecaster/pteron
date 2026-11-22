import AVFoundation
import Foundation
import GlanceModel
import Network
import RexKit
import Testing
@testable import RexDuo

@MainActor
struct PairingTests {
    private let mac = ServerConfig(name: "Studio", url: "https://office-mac-rex.tail1234.ts.net")

    // MARK: Parsing

    @Test func readsRexCodeAsItsAddress() {
        #expect(PairingCode.address(from: "https://devbox-rex.tail1234.ts.net")?.absoluteString
                == "https://devbox-rex.tail1234.ts.net")
    }

    @Test func normalizesCaseSpacePathAndDefaultPort() {
        let want = "https://devbox-rex.tail1234.ts.net"
        for raw in ["  HTTPS://DevBox-Rex.Tail1234.ts.net/\n", "https://devbox-rex.tail1234.ts.net:443",
                    "https://devbox-rex.tail1234.ts.net/api/control?x=1#y"] {
            #expect(PairingCode.address(from: raw)?.absoluteString == want, "\(raw)")
        }
        #expect(PairingCode.address(from: "https://10.0.0.5:8443/")?.absoluteString == "https://10.0.0.5:8443")
        // A fully qualified name's trailing dot is the same host.
        #expect(PairingCode.address(from: "https://devbox-rex.tail1234.ts.net.")?.absoluteString == want)
        #expect(PairingCode.address(from: "https://[fd7a:115c:a1e0::1]:8443")?.host() == "fd7a:115c:a1e0::1")
    }

    @Test func rejectsWhatIsNotAnHTTPSAddress() {
        for raw in ["", "hello", "devbox-rex.tail1234.ts.net", "http://devbox-rex.tail1234.ts.net",
                    "rex://pair?url=x", "WIFI:S:Home;T:WPA;P:secret;;", "https://", "https://localhost",
                    "https://user:pw@devbox-rex.tail1234.ts.net", "https://a.ts.net and more",
                    "mailto:someone@example.com", "https://a.b", "https://.", "https://..", "https://studio",
                    "https://-a.example.com", "https://a-.example.com", "https://a..example.com", "https://a_b.example.com",
                    "https://example.123", "https://999.1.1.1", "https://1.2.3", "https://1.2.3.4.5"] {
            #expect(PairingCode.address(from: raw) == nil, "\(raw)")
        }
    }

    // MARK: Saved servers

    @Test func findsTheSavedServerHoweverItWasTyped() throws {
        let url = try #require(PairingCode.address(from: "https://office-mac-rex.tail1234.ts.net"))
        for saved in ["https://office-mac-rex.tail1234.ts.net", "https://Office-Mac-Rex.tail1234.ts.net/",
                      "office-mac-rex.tail1234.ts.net", "https://office-mac-rex.tail1234.ts.net:443"] {
            let list = [ServerConfig(name: "Other", url: "https://devbox-rex.tail1234.ts.net"), ServerConfig(name: "Mine", url: saved)]
            #expect(PairingCode.existing(url, in: list)?.name == "Mine", "\(saved)")
        }
        #expect(PairingCode.existing(url, in: [ServerConfig(name: "Port", url: "https://office-mac-rex.tail1234.ts.net:8443")]) == nil)
        #expect(PairingCode.existing(url, in: [ServerConfig(name: "Plain", url: "http://office-mac-rex.tail1234.ts.net")]) == nil)
        #expect(PairingCode.existing(url, in: []) == nil)
    }

    @Test func namesAServerFromItsHost() throws {
        func name(_ s: String) throws -> String { ServerConfig.name(for: try #require(URL(string: s))) }
        #expect(try name("https://devbox-rex.tail1234.ts.net") == "devbox")
        #expect(try name("https://office-mac-rex.tail1234.ts.net") == "office-mac")
        #expect(try name("https://studio.tail1234.ts.net") == "studio")
        #expect(try name("https://rex.tail1234.ts.net") == "rex")
        #expect(try name("https://-rex.tail1234.ts.net") == "-rex")
        #expect(try name("https://10.0.0.5:8443") == "10.0.0.5")
    }

    @Test func tellsAForeignTailnet() throws {
        let other = try #require(URL(string: "https://studio-rex.tail999999.ts.net"))
        let same = try #require(URL(string: "https://devbox-rex.tail1234.ts.net"))
        #expect(PairingCode.tailnet(of: same) == "tail1234.ts.net")
        #expect(PairingCode.tailnet(of: try #require(URL(string: "https://example.com"))) == nil)
        #expect(PairingCode.tailnet(of: try #require(URL(string: "https://ts.net"))) == nil)
        #expect(PairingCode.isForeignTailnet(other, servers: [mac]))
        #expect(!PairingCode.isForeignTailnet(same, servers: [mac]))
        // Nothing to compare with: no saved server, or none on a tailnet.
        #expect(!PairingCode.isForeignTailnet(other, servers: []))
        #expect(!PairingCode.isForeignTailnet(other, servers: [ServerConfig(name: "LAN", url: "https://10.0.0.5")]))
    }

    // MARK: What a failed check offers

    private func problem(_ kind: ConnectionProblem.Kind, foreign: Bool = false, tailnet: String? = nil) -> PairingProblem {
        .of(ConnectionProblem(kind: kind, detail: "NSURLErrorDomain -1"), foreignTailnet: foreign, tailnetName: tailnet)
    }

    @Test func offThePrivateNetworkOnlyTriesAgain() {
        // Saved there, the computer could never connect: no Add Anyway.
        for kind in [ConnectionProblem.Kind.offPrivateNetwork, .hostNotFound] {
            let p = problem(kind)
            #expect(p.message == "Can't reach that computer from this network. Connect this iPhone to the same network or VPN as that computer, then try again.")
            #expect(p.actions == [.tryAgain])
            #expect(p.detail == nil)
        }
    }

    /// Add Anyway only where the computer may answer later: asleep, or a failure the app can't
    /// explain. Never out of range or can't-find, which no wait fixes.
    @Test func addAnywayShowsOnlyWhereItCanWork() {
        // A check of one address never finds `tunnelDown`.
        let with = ConnectionProblem.Kind.allCases.filter { $0 != .tunnelDown && problem($0).actions.contains(.addAnyway) }
        #expect(Set(with) == [.notAnswering, .badAddress, .unknown])
        #expect(!problem(.hostNotFound, tailnet: "studio").actions.contains(.addAnyway))
        #expect(!problem(.notAnswering, foreign: true, tailnet: "studio").actions.contains(.addAnyway))
        #expect(!PairingProblem.offTailnet.offered(onTailnet: false).contains(.addAnyway))
        #expect(!PairingProblem.offTailnet.offered(onTailnet: true).contains(.addAnyway))
    }

    /// On a tailnet but not the computer's: Tailscale signed in to another account, in those words.
    @Test func aTailnetComputerNotFoundIsAnotherAccount() {
        let p = problem(.hostNotFound, tailnet: "studio")
        #expect(p.title == "Can't find studio")
        #expect(p.message == "Tailscale on this iPhone is signed in to a different account than studio. Sign in with the account you used in Rex.")
        #expect(p.actions == [.tryAgain])
        #expect(problem(.notAnswering, foreign: true, tailnet: "studio") == p)
        // On its own tailnet, a silent computer is asleep, as before.
        #expect(problem(.notAnswering, tailnet: "studio").title == "Not answering")
        let refused = problem(.notAllowed, tailnet: "studio")
        #expect(refused.message == "Rex on studio only lets in devices on its Tailscale account.")
        #expect(refused.actions == [.scanCode])
    }

    @Test func aSilentComputerOnAnotherTailnetReadsAsOffItsNetwork() {
        #expect(problem(.notAnswering).message == "That computer isn't answering. It may be asleep, or Rex isn't running there. Wake it or open Rex, then try again.")
        #expect(problem(.notAnswering, foreign: true) == problem(.offPrivateNetwork))
    }

    @Test func notAllowedLeadsToAScan() {
        let p = problem(.notAllowed, foreign: true)
        #expect(p.message == "That computer didn't let this iPhone in. It may belong to a different account.")
        #expect(p.actions == [.scanCode])
    }

    @Test func offlineCanOnlyTryAgain() {
        #expect(problem(.noInternet).actions == [.tryAgain])
    }

    @Test func onlyUnexplainedFailuresCarryDetail() {
        #expect(problem(.unknown).detail == "NSURLErrorDomain -1")
        #expect(problem(.insecure).detail == "NSURLErrorDomain -1")
        #expect(problem(.insecure).actions == [.tryAgain])
        // A check of one address never finds `tunnelDown`.
        for kind in ConnectionProblem.Kind.allCases where ![.unknown, .insecure, .badAddress, .tunnelDown].contains(kind) {
            #expect(problem(kind).detail == nil, "\(kind)")
        }
    }

    @Test func noMessageNamesAProduct() {
        for kind in ConnectionProblem.Kind.allCases {
            for foreign in [false, true] {
                let m = problem(kind, foreign: foreign).message
                #expect(!m.contains("Tailscale") && !m.contains("tailnet"), "\(kind)")
            }
        }
    }

    // MARK: The flow

    /// A model over a fixed list, with a probe that answers what the test queued. The closures hold
    /// the rig, so a check still running when a test ends finds it alive.
    @MainActor
    private final class Rig {
        var servers: [ServerConfig]
        var answers: [ConnectionProblem?] = []
        var identity: ServerIdentity?
        var probed: [URL] = []
        var existing: [ServerConfig] = []
        var added: [ServerConfig] = []
        var gate: CheckedContinuation<Void, Never>?
        var hold = false
        /// The probe waits like a slow network, and notes when its task is cancelled.
        var sleeps = false
        var sawCancel = false
        /// What `NetworkWatch` says about this iPhone. On, so the old cases read as before.
        var onTailnet = true
        private(set) var model: PairingModel!

        init(servers: [ServerConfig]) {
            self.servers = servers
            model = PairingModel(
                servers: { self.servers },
                probe: { url in
                    self.probed.append(url)
                    if self.hold { await withCheckedContinuation { self.gate = $0 } }
                    if self.sleeps {
                        try? await Task.sleep(nanoseconds: 60_000_000_000)
                        self.sawCancel = Task.isCancelled
                    }
                    if let problem = self.answers.isEmpty ? nil : self.answers.removeFirst() { return .problem(problem) }
                    return .reachable(self.identity)
                },
                onExisting: { self.existing.append($0) },
                onAdd: { self.added.append($0) },
                onTailnet: { self.onTailnet })
        }

        /// Lets the check's task run to its answer.
        func settle() async {
            for _ in 0..<50 {
                if case .checking = model.step { await Task.yield() } else { return }
            }
        }
    }

    @Test func aReachableServerIsNamedThenAdded() async throws {
        let rig = Rig(servers: [mac])
        #expect(rig.model.scanned("https://devbox-rex.tail1234.ts.net"))
        let url = try #require(URL(string: "https://devbox-rex.tail1234.ts.net"))
        #expect(rig.model.step == .checking(url))
        await rig.settle()
        #expect(rig.model.step == .found(url, nil))
        #expect(rig.model.name == "devbox")
        #expect(rig.added.isEmpty)

        rig.model.name = "  Desk  "
        rig.model.add()
        #expect(rig.added.map(\.name) == ["Desk"])
        #expect(rig.added.map(\.url) == ["https://devbox-rex.tail1234.ts.net"])
    }

    @Test func anEmptyNameFallsBackToTheHost() async {
        let rig = Rig(servers: [])
        rig.model.scanned("https://devbox-rex.tail1234.ts.net")
        await rig.settle()
        rig.model.name = "   "
        rig.model.add()
        #expect(rig.added.map(\.name) == ["devbox"])
    }

    @Test func aSavedServerKeepsItsNameAndIsNotProbed() {
        let rig = Rig(servers: [mac])
        #expect(rig.model.scanned("https://OFFICE-MAC-REX.tail1234.ts.net/"))
        #expect(rig.existing == [mac])
        #expect(rig.existing.first?.name == "Studio")
        #expect(rig.probed.isEmpty && rig.added.isEmpty)
        #expect(rig.model.step == .done)
    }

    @Test func somethingElseIsTurnedDownGentlyAndScanningGoesOn() async {
        let rig = Rig(servers: [])
        #expect(!rig.model.scanned("WIFI:S:Home;;"))
        #expect(rig.model.rejection == "That's not a Rex pairing code.")
        #expect(rig.model.step == .scanning)
        #expect(rig.probed.isEmpty)
        // A real code right after clears the message.
        #expect(rig.model.scanned("https://devbox-rex.tail1234.ts.net"))
        #expect(rig.model.rejection == nil)
    }

    @Test func aFailedCheckCanBeRetriedOrAddedAnyway() async throws {
        let rig = Rig(servers: [mac])
        rig.answers = [ConnectionProblem(kind: .notAnswering, detail: "d"), ConnectionProblem(kind: .notAnswering, detail: "d")]
        rig.model.scanned("https://studio-rex.tail1234.ts.net")
        await rig.settle()
        let url = try #require(URL(string: "https://studio-rex.tail1234.ts.net"))
        guard case .problem(url, let first) = rig.model.step else { Issue.record("\(rig.model.step)"); return }
        #expect(first.actions == [.tryAgain, .addAnyway])

        rig.model.tryAgain()
        await rig.settle()
        guard case .problem = rig.model.step else { Issue.record("\(rig.model.step)"); return }
        #expect(rig.probed.count == 2)

        rig.model.addAnyway()
        #expect(rig.added.map(\.name) == ["studio"])
        #expect(rig.model.step == .added(url, nil))
        #expect(rig.model.isFinished)
    }

    @Test func aRefusedServerCanOnlyBeCancelled() async {
        let rig = Rig(servers: [])
        rig.answers = [ConnectionProblem(kind: .notAllowed, detail: "d")]
        rig.model.scanned("https://studio-rex.tail999999.ts.net")
        await rig.settle()
        guard case .problem(_, let p) = rig.model.step else { Issue.record("\(rig.model.step)"); return }
        #expect(p.actions == [.scanCode])
        #expect(p.message == "Rex on studio only lets in devices on its Tailscale account.")
        rig.model.addAnyway()
        rig.model.tryAgain()
        rig.model.add()
        #expect(rig.added.isEmpty)
        #expect(rig.probed.count == 1)
        guard case .problem = rig.model.step else { Issue.record("\(rig.model.step)"); return }
    }

    // MARK: A code's computer on a tailnet this iPhone isn't on

    /// Unreachable at a tailnet name with no tailnet here: the one line, Get Tailscale, and the code
    /// kept. Try Again comes only once the tailnet is up, and runs one check per tap.
    @Test func offTheTailnetTheCardSaysConnectTailscaleThenTryAgain() async throws {
        let rig = Rig(servers: [])
        rig.onTailnet = false
        rig.answers = [ConnectionProblem(kind: .offPrivateNetwork, detail: "d")]
        #expect(rig.model.scanned("https://studio-rex.tail1234.ts.net"))
        await rig.settle()
        let url = try #require(URL(string: "https://studio-rex.tail1234.ts.net"))
        #expect(rig.model.step == .problem(url, .offTailnet))
        #expect(PairingProblem.offTailnet.title == nil)
        #expect(PairingProblem.offTailnet.message
            == "This computer is on a private network this iPhone isn't part of yet. Connect this iPhone with Tailscale, then try again.")
        #expect(PairingProblem.offTailnet.offered(onTailnet: false) == [.getTailscale])
        // No tailnet yet: Try Again does nothing.
        rig.model.tryAgain()
        rig.model.addAnyway()
        #expect(rig.probed.count == 1 && rig.added.isEmpty)
        // The tailnet comes up: one tap, one check, no loop.
        rig.onTailnet = true
        #expect(PairingProblem.offTailnet.offered(onTailnet: true) == [.tryAgain])
        rig.model.tryAgain()
        await rig.settle()
        #expect(rig.probed == [url, url])
        #expect(rig.model.step == .found(url, nil))
        await Task.yield()
        #expect(rig.probed.count == 2)
    }

    /// Which card a failed check gets, for each case the owner named.
    @Test func thePostScanCardForEachCase() async throws {
        let url = try #require(URL(string: "https://studio-rex.tail1234.ts.net"))
        func card(_ kind: ConnectionProblem.Kind?, onTailnet: Bool, address: String = "https://studio-rex.tail1234.ts.net",
                  guessed: Bool = false) async -> PairingModel.Step {
            let rig = Rig(servers: [])
            rig.onTailnet = onTailnet
            rig.answers = [kind.map { ConnectionProblem(kind: $0, detail: "d") }]
            if guessed {
                rig.model.start(PairingCode.Candidate(url: URL(string: address)!, guessed: true), name: "studio")
            } else {
                rig.model.scanned(address)
            }
            await rig.settle()
            return rig.model.step
        }
        // Unreachable and no tailnet here: Tailscale first.
        for kind in [ConnectionProblem.Kind.offPrivateNetwork, .hostNotFound, .notAnswering, .unknown] {
            #expect(await card(kind, onTailnet: false) == .problem(url, .offTailnet), "\(kind)")
        }
        // Unreachable while on a tailnet: today's words (asleep, or another account).
        #expect(await card(.notAnswering, onTailnet: true) == .problem(url, problem(.notAnswering, tailnet: "studio")))
        #expect(await card(.hostNotFound, onTailnet: true) == .problem(url, .otherAccount("studio")))
        // Reachable: the card.
        #expect(await card(nil, onTailnet: false) == .found(url, nil))
        // What isn't about reaching it keeps its words, off the tailnet too.
        #expect(await card(.noInternet, onTailnet: false) == .problem(url, problem(.noInternet)))
        #expect(await card(.notAllowed, onTailnet: false) == .problem(url, problem(.notAllowed, tailnet: "studio")))
        // An address that isn't a tailnet name, and a guessed one, never get the Tailscale line.
        let lan = try #require(URL(string: "https://192.168.1.20:8443"))
        #expect(await card(.offPrivateNetwork, onTailnet: false, address: lan.absoluteString) == .problem(lan, problem(.offPrivateNetwork)))
        guard case .problem(_, let g) = await card(.offPrivateNetwork, onTailnet: false, guessed: true) else {
            Issue.record("no problem"); return
        }
        #expect(g.title == "Can't find that computer")
    }

    @Test func aComputerWithNoSessionsIsOnlyAdded() {
        #expect(IdentityCopy.of(ServerIdentity(sessionCount: 0)).addTitle == "Add")
        #expect(IdentityCopy.of(ServerIdentity(sessionCount: 2, sessions: ["a", "b"])).addTitle == "Add & Open")
        // Unknown is not none.
        #expect(IdentityCopy.of(ServerIdentity()).addTitle == "Add & Open")
        #expect(IdentityCopy.of(nil).addTitle == "Add & Open")
    }

    @Test func addingTwiceSavesOnce() async {
        let rig = Rig(servers: [])
        rig.model.scanned("https://devbox-rex.tail1234.ts.net")
        await rig.settle()
        // Return on the name field, then a tap on Add.
        rig.model.add()
        rig.model.add()
        rig.model.addAnyway()
        #expect(rig.added.count == 1)
        #expect(rig.model.isFinished)
        // Nothing restarts a finished run.
        let after = rig.model.step
        rig.model.rescan()
        #expect(!rig.model.scanned("https://buildbox-rex.tail1234.ts.net"))
        #expect(rig.model.step == after)
        #expect(rig.probed.count == 1)
    }

    @Test func addingAnywayTwiceSavesOnce() async {
        let rig = Rig(servers: [])
        rig.answers = [ConnectionProblem(kind: .notAnswering, detail: "d")]
        rig.model.scanned("https://devbox-rex.tail1234.ts.net")
        await rig.settle()
        rig.model.addAnyway()
        rig.model.addAnyway()
        #expect(rig.added.count == 1)
    }

    @Test func aSavedServerSeenOnEveryFrameIsReportedOnce() {
        let rig = Rig(servers: [mac])
        let t = Date()
        #expect(rig.model.scanned("https://office-mac-rex.tail1234.ts.net", at: t))
        #expect(!rig.model.scanned("https://office-mac-rex.tail1234.ts.net", at: t + 0.03))
        // Another spelling of it, or the same one after a pause: the run is over either way.
        #expect(!rig.model.scanned("https://OFFICE-MAC-REX.tail1234.ts.net", at: t + 0.06))
        #expect(!rig.model.scanned("https://office-mac-rex.tail1234.ts.net", at: t + 10))
        #expect(rig.existing.count == 1)
    }

    @Test func aCodeReadWhileCheckingIsIgnored() async {
        let rig = Rig(servers: [])
        rig.model.scanned("https://devbox-rex.tail1234.ts.net")
        #expect(!rig.model.scanned("https://buildbox-rex.tail1234.ts.net"))
        await rig.settle()
        #expect(rig.probed.count == 1)
        #expect(!rig.model.scanned("https://buildbox-rex.tail1234.ts.net"))
    }

    @Test func cancellingACheckDoesNotStartItAgainWhileTheCodeIsStillInView() async {
        let rig = Rig(servers: [])
        rig.hold = true
        let code = "https://devbox-rex.tail1234.ts.net"
        let t = Date()
        #expect(rig.model.scanned(code, at: t))
        rig.model.rescan()
        #expect(rig.model.step == .scanning)
        // The camera is still on the code: a frame every 30 ms, for seconds.
        for i in 1...100 {
            #expect(!rig.model.scanned(code, at: t + Double(i) * 0.03))
        }
        #expect(rig.model.step == .scanning)
        // Away for a moment and back: that is the person scanning it again.
        #expect(rig.model.scanned(code, at: t + 3 + PairingModel.outOfView + 0.1))
        // Another code needs no pause.
        rig.model.rescan()
        #expect(rig.model.scanned("https://buildbox-rex.tail1234.ts.net", at: t + 5))
    }

    @Test func anAnswerToACancelledCheckIsDropped() async {
        let rig = Rig(servers: [])
        rig.hold = true
        rig.model.scanned("https://devbox-rex.tail1234.ts.net")
        for _ in 0..<50 where rig.gate == nil { await Task.yield() }
        rig.model.rescan()
        #expect(rig.model.step == .scanning)
        rig.gate?.resume()
        for _ in 0..<20 { await Task.yield() }
        #expect(rig.model.step == .scanning)
        #expect(rig.added.isEmpty)
    }

    @Test func leavingCancelsTheProbe() async {
        for leave in [{ (m: PairingModel) in m.rescan() }, { $0.cancel() }] {
            let rig = Rig(servers: [])
            rig.sleeps = true
            rig.model.scanned("https://devbox-rex.tail1234.ts.net")
            for _ in 0..<50 where rig.probed.isEmpty { await Task.yield() }
            leave(rig.model)
            for _ in 0..<200 where !rig.sawCancel { await Task.yield() }
            #expect(rig.sawCancel)
        }
    }

    @Test func theRejectionGoesWhenTheCodeLeavesTheView() {
        let rig = Rig(servers: [])
        let t = Date()
        rig.model.scanned("hello", at: t)
        #expect(rig.model.rejection != nil)
        rig.model.scanned("hello", at: t + 1)
        #expect(!rig.model.expireRejection(at: t + 2))
        #expect(rig.model.rejection != nil)
        #expect(rig.model.expireRejection(at: t + 1 + PairingModel.outOfView + 0.1))
        #expect(rig.model.rejection == nil)
        // Shown again when the same code comes back.
        #expect(!rig.model.scanned("hello", at: t + 10))
        #expect(rig.model.rejection != nil)
    }

    // MARK: The identity card

    @Test func theCardKeepsTheIdentityThroughAdding() async throws {
        let rig = Rig(servers: [])
        let id = ServerIdentity(platform: .mac, account: "alex", sessionCount: 2, sessions: ["api", "web"], hasHelper: true)
        rig.identity = id
        rig.model.scanned("https://devbox-rex.tail1234.ts.net")
        await rig.settle()
        let url = try #require(URL(string: "https://devbox-rex.tail1234.ts.net"))
        #expect(rig.model.step == .found(url, id))
        rig.model.add()
        #expect(rig.model.step == .added(url, id))
    }

    @Test func notThisOneGoesBackToTheCamera() async {
        let rig = Rig(servers: [])
        rig.identity = ServerIdentity(platform: .linux)
        rig.model.scanned("https://devbox-rex.tail1234.ts.net")
        await rig.settle()
        rig.model.rescan()
        #expect(rig.model.step == .scanning)
        #expect(rig.added.isEmpty)
    }

    @Test func theCardSummarizesAccountSystemAndSessions() {
        func copy(_ id: ServerIdentity?) -> IdentityCopy { .of(id) }
        let mac = copy(ServerIdentity(platform: .mac, account: "alex", sessionCount: 3, sessions: ["api", "web", "docs"], hasHelper: true))
        #expect(mac.symbol == "laptopcomputer")
        #expect(mac.summary == "alex · Mac · 3 sessions")
        #expect(mac.sessions == ["api", "web", "docs"])
        #expect(mac.more == 0)
        #expect(mac.owner == nil && mac.helper == nil)

        let linux = copy(ServerIdentity(platform: .linux, sessionCount: 1, sessions: ["build"], hasHelper: true))
        #expect(linux.symbol == "server.rack")
        #expect(linux.summary == "Linux · 1 session")

        let empty = copy(ServerIdentity(platform: .other, account: "sam", sessionCount: 0, hasHelper: true))
        #expect(empty.symbol == "desktopcomputer")
        #expect(empty.summary == "sam · No sessions yet")
        #expect(empty.sessions.isEmpty && empty.more == 0)
    }

    @Test func whatTheComputerDidNotSayIsLeftOutNotShownAsNone() {
        // The session and client calls failed: no "No sessions yet", no helper line.
        let partial = IdentityCopy.of(ServerIdentity(platform: .mac, account: "alex"))
        #expect(partial.summary == "alex · Mac")
        #expect(partial.helper == nil)
        #expect(partial.sessions.isEmpty && partial.more == 0)
        // Nothing at all: a bare card.
        let nothing = IdentityCopy.of(ServerIdentity())
        #expect(nothing.summary == nil && nothing.helper == nil && nothing.owner == nil)
        #expect(nothing.symbol == "desktopcomputer")
        // Only a helper it reported missing gets the line.
        #expect(IdentityCopy.of(ServerIdentity(hasHelper: false)).helper != nil)
    }

    @Test func onlyAFewSessionsAreNamed() {
        let many = IdentityCopy.of(ServerIdentity(sessionCount: 7, sessions: ["a", "b", "c", "d", "e"], hasHelper: true))
        #expect(many.sessions == ["a", "b", "c"])
        #expect(many.more == 4)
        // Unnamed sessions still count.
        let unnamed = IdentityCopy.of(ServerIdentity(sessionCount: 4, sessions: ["a"], hasHelper: true))
        #expect(unnamed.sessions == ["a"] && unnamed.more == 3)
        #expect(IdentityCopy.of(ServerIdentity(sessionCount: 2, hasHelper: true)).more == 0)
        // Names without a count (the status call failed): no "+n" to invent.
        #expect(IdentityCopy.of(ServerIdentity(sessions: ["a", "b", "c", "d"])).more == 0)
    }

    @Test func theOwnerLineShowsOnlyForSomeoneElsesComputer() {
        let mine = ServerIdentity(owner: "alex@example.com", viewer: "ALEX@example.com", hasHelper: true)
        #expect(IdentityCopy.of(mine).owner == nil)
        let theirs = ServerIdentity(owner: "sam@example.com", viewer: "alex@example.com", hasHelper: true)
        #expect(IdentityCopy.of(theirs).owner == "This computer belongs to sam@example.com.")
        #expect(IdentityCopy.of(ServerIdentity(owner: "sam@example.com", hasHelper: true)).owner == nil)
    }

    @Test func theHelperLineShowsOnlyWithoutAHelper() {
        #expect(IdentityCopy.of(ServerIdentity(hasHelper: true)).helper == nil)
        #expect(IdentityCopy.of(ServerIdentity(hasHelper: false)).helper == "Notifications need \(Brand.beaconName) on this computer.")
    }

    @Test func aComputerThatSaidNothingGetsABareCard() {
        let bare = IdentityCopy.of(nil)
        #expect(bare.summary == nil && bare.sessions.isEmpty && bare.owner == nil && bare.helper == nil)
    }

    @Test func aServerSavedWhileTheCardWasUpIsOpenedNotAddedTwice() async {
        let rig = Rig(servers: [])
        rig.model.scanned("https://devbox-rex.tail1234.ts.net")
        await rig.settle()
        // Saved elsewhere, under the person's own name, before Add & Open is tapped.
        let saved = ServerConfig(name: "Desk", url: "https://DEVBOX-rex.tail1234.ts.net/")
        rig.servers = [saved]
        rig.model.add()
        #expect(rig.added.isEmpty)
        #expect(rig.existing == [saved])
        // "Already added", not the checkmark.
        #expect(rig.model.step == .done)
        rig.model.add()
        #expect(rig.existing.count == 1)
    }

    // MARK: Computers a server already knows

    private let home = URL(string: "https://office-mac-rex.tail1234.ts.net")!

    @Test func aListedAddressIsUsedAsIs() {
        let c = PairingCode.candidate(label: "studio", endpoints: ["ssh://studio", "studio-box.tail1234.ts.net"], listedBy: home)
        #expect(c == PairingCode.Candidate(url: URL(string: "https://studio-box.tail1234.ts.net")!, guessed: false))
        let https = PairingCode.candidate(label: "studio", endpoints: ["https://Studio.example.com:8443/"], listedBy: home)
        #expect(https?.url.absoluteString == "https://studio.example.com:8443")
        #expect(https?.guessed == false)
    }

    @Test func anSSHOnlyHostFollowsTheListingServersNaming() {
        let c = PairingCode.candidate(label: "BuildBox", endpoints: ["ssh://buildbox"], listedBy: home)
        #expect(c == PairingCode.Candidate(url: URL(string: "https://buildbox-rex.tail1234.ts.net")!, guessed: true))
    }

    @Test func noAddressWhenNothingSaysWhereItIs() {
        // The listing server isn't at a Rex-style private address, or the label can't be a host name.
        for server in ["https://10.0.0.5", "https://studio.tail1234.ts.net", "https://rex.example.com"] {
            #expect(PairingCode.candidate(label: "buildbox", endpoints: ["ssh://buildbox"], listedBy: URL(string: server)!) == nil, "\(server)")
        }
        #expect(PairingCode.candidate(label: "my desk", endpoints: ["unix:///tmp/rex.sock"], listedBy: home) == nil)
        #expect(PairingCode.candidate(label: "", endpoints: [], listedBy: home) == nil)
        // A bare word is an ssh alias, not an address.
        #expect(PairingCode.candidate(label: "my desk", endpoints: ["buildbox", "buildbox.local"], listedBy: home) == nil)
    }

    @Test func theSidebarListsOnlyHostsThatAreNotSaved() {
        let hosts = [HostEntry(id: "h1", label: "buildbox", endpoints: ["ssh://buildbox"]),
                     HostEntry(id: "h2", label: "devbox", endpoints: ["ssh://devbox"]),
                     HostEntry(id: "h3", label: "Studio", endpoints: ["unix:///tmp/rex.sock"])]
        let saved = ServerConfig(name: "Mini", url: "https://buildbox-rex.tail1234.ts.net")
        let lan = ServerConfig(name: "studio", url: "https://10.0.0.5")
        let list = KnownHost.unsaved([(mac, hosts), (saved, hosts), (lan, [])])
        // buildbox is saved under another name, Studio under its own; devbox is listed twice.
        #expect(list.map(\.label) == ["devbox"])
        #expect(list.first?.candidate?.url.absoluteString == "https://devbox-rex.tail1234.ts.net")
        let unknown = KnownHost.unsaved([(lan, [HostEntry(id: "h9", label: "attic", endpoints: ["ssh://attic"])])])
        #expect(unknown.map(\.label) == ["attic"])
        #expect(unknown.first?.candidate == nil)
    }

    @Test func aPickedHostRunsTheSameCheckUnderItsListedName() async throws {
        let rig = Rig(servers: [mac])
        let url = try #require(URL(string: "https://buildbox-rex.tail1234.ts.net"))
        rig.model.start(PairingCode.Candidate(url: url, guessed: true), name: "buildbox")
        #expect(rig.model.step == .checking(url))
        await rig.settle()
        #expect(rig.model.step == .found(url, nil))
        rig.model.add()
        #expect(rig.added.map(\.name) == ["buildbox"])
    }

    @Test func aPickedHostThatIsSavedIsOpenedNotAddedAgain() throws {
        let rig = Rig(servers: [mac])
        rig.model.start(PairingCode.Candidate(url: home, guessed: true), name: "other")
        #expect(rig.existing == [mac])
        #expect(rig.probed.isEmpty)
    }

    @Test func aGuessedAddressThatDoesNotAnswerIsNeverOfferedForAdding() async {
        for kind in [ConnectionProblem.Kind.hostNotFound, .notAnswering, .offPrivateNetwork, .unknown] {
            let rig = Rig(servers: [mac])
            rig.answers = [ConnectionProblem(kind: kind, detail: "d")]
            rig.model.start(PairingCode.Candidate(url: URL(string: "https://attic-rex.tail1234.ts.net")!, guessed: true), name: "attic")
            await rig.settle()
            guard case .problem(_, let p) = rig.model.step else { Issue.record("\(rig.model.step)"); continue }
            #expect(p.message == "Pair it with a QR code from that computer.")
            #expect(p.actions == [.scanCode])
            rig.model.addAnyway()
            #expect(rig.added.isEmpty)
        }
        // A refusal says so: the computer is there.
        let rig = Rig(servers: [mac])
        rig.answers = [ConnectionProblem(kind: .notAllowed, detail: "d")]
        rig.model.start(PairingCode.Candidate(url: URL(string: "https://attic-rex.tail1234.ts.net")!, guessed: true), name: "attic")
        await rig.settle()
        guard case .problem(_, let p) = rig.model.step else { Issue.record("\(rig.model.step)"); return }
        #expect(p.title == "Not allowed in")
        // A listed address that fails keeps the usual choices.
        let listed = Rig(servers: [mac])
        listed.answers = [ConnectionProblem(kind: .notAnswering, detail: "d")]
        listed.model.start(PairingCode.Candidate(url: URL(string: "https://attic-rex.tail1234.ts.net")!, guessed: false), name: "attic")
        await listed.settle()
        guard case .problem(_, let q) = listed.model.step else { Issue.record("\(listed.model.step)"); return }
        #expect(q.actions == [.tryAgain, .addAnyway])
    }

    /// Settings → Add Computer: a typed address goes through the same check and card, under the
    /// typed name, with the usual offers when it fails.
    @Test func aTypedAddressRunsTheCheck() async throws {
        let suite = "pairing-typed-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(prefs: Prefs(defaults: defaults), connect: false)
        let typed = try #require(ServerConfig.url(from: "http://127.0.0.1:8765"))
        model.preparePairing(typed: typed, name: "  ")
        #expect(model.pairingStart == AppModel.PairingStart(candidate: .init(url: typed, guessed: false), name: ServerConfig.name(for: typed)))
        #expect(!model.showPairing, "Settings' own sheet presents it")
        model.preparePairing(typed: typed, name: " Desk ")
        #expect(model.pairingStart?.name == "Desk")
        #expect(model.prefs.servers.isEmpty, "nothing is saved before the check")

        let rig = Rig(servers: [])
        let start = try #require(model.pairingStart)
        rig.model.start(start.candidate, name: start.name)
        #expect(rig.model.step == .checking(typed))
        await rig.settle()
        #expect(rig.probed == [typed])
        #expect(rig.model.step == .found(typed, nil))
        rig.model.add()
        #expect(rig.added.map(\.name) == ["Desk"])
    }

    @Test func startPairingOpensTheFlowAtAnAddress() throws {
        let suite = "pairing-start-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(prefs: Prefs(defaults: defaults), connect: false)
        model.startPairing(prefilled: try #require(URL(string: "ssh://buildbox")))
        #expect(!model.showPairing && model.pairingStart == nil)
        model.startPairing(prefilled: try #require(URL(string: "https://BuildBox-Rex.tail1234.ts.net/x")), name: "Mini", guessed: true)
        #expect(model.showPairing)
        #expect(model.pairingStart?.candidate.url.absoluteString == "https://buildbox-rex.tail1234.ts.net")
        #expect(model.pairingStart?.candidate.guessed == true)
        #expect(model.pairingStart?.name == "Mini")
        model.startPairing(prefilled: try #require(URL(string: "https://devbox-rex.tail1234.ts.net")))
        #expect(model.pairingStart?.name == "devbox")
    }

    // MARK: The app's side

    @Test func aRefusalReadsAsNotAllowedAndARedirectAsNotRex() throws {
        let net = NetworkSnapshot(reachable: true, onPrivateNetwork: true)
        #expect(ServerProbe.failure(status: 426) == nil)
        let refused = ConnectionProblem.classify(try #require(ServerProbe.failure(status: 403)), network: net)
        #expect(refused.kind == .notAllowed)
        #expect(PairingProblem.of(refused, foreignTailnet: false).actions == [.scanCode])
        for status in [200, 302, 404, 502] {
            let p = ConnectionProblem.classify(try #require(ServerProbe.failure(status: status)), network: net)
            #expect(p.kind == .notAnswering, "\(status)")
        }
    }

    @Test func theSameAddressIsSavedOnce() throws {
        let suite = "pairing-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Prefs(defaults: defaults)
        prefs.servers = []
        let model = AppModel(prefs: prefs, connect: false)
        model.addServer(ServerConfig(name: "Desk", url: "https://devbox-rex.tail1234.ts.net"))
        model.addServer(ServerConfig(name: "Again", url: "https://DevBox-Rex.tail1234.ts.net/"))
        model.addServer(ServerConfig(name: "Mini", url: "https://buildbox-rex.tail1234.ts.net"))
        #expect(prefs.servers.map(\.name) == ["Desk", "Mini"])
    }

    @Test func thePreviewLabelFitsRexsLimitInBytes() {
        #expect(PushIdentity.previewLabel(deviceName: "Alex's iPhone") == "Alex's iPhone")
        #expect(PushIdentity.previewLabel(deviceName: "   ") == "iPhone")
        // 40 characters of four bytes each would be 160 bytes.
        let emoji = PushIdentity.previewLabel(deviceName: String(repeating: "🦖", count: 40))
        #expect(emoji == String(repeating: "🦖", count: 16))
        #expect(emoji.utf8.count == 64)
        let accents = PushIdentity.previewLabel(deviceName: String(repeating: "é", count: 100))
        #expect(accents.utf8.count == 64)
        // Never a device id: the helper reads ` #<id>` as this iPhone having the app open.
        #expect(!PushIdentity.previewLabel(deviceName: "Phone").contains("#"))
        // The full label still keeps its suffix whole.
        let full = PushIdentity.clientLabel(deviceName: String(repeating: "🦖", count: 40), deviceID: "a1b2c3d4")
        #expect(full.hasSuffix(" #a1b2c3d4") && full.utf8.count <= 64)
    }

    // MARK: Landing on the new server

    /// An app model with one server that is online with two sessions, nothing connected.
    private func landingModel() throws -> (AppModel, ServerConfig, ServerConnection) {
        let suite = "pairing-landing-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let prefs = Prefs(defaults: defaults)
        let model = AppModel(prefs: prefs, connect: false)
        let config = ServerConfig(name: "Desk", url: "https://devbox-rex.tail1234.ts.net")
        let server = ServerConnection(config: config, prefs: prefs, notifier: model.notifier, deviceID: "a1b2c3d4")
        model.servers = [server]
        return (model, config, server)
    }

    private func view(_ session: String, active: String) -> SessionView {
        let json = #"{"revision":1,"session_id":"\#(session)","active_window_id":"\#(active)","windows":[{"window_id":"w1"},{"window_id":"w2"}]}"#
        return SessionView((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? JSONObject ?? [:])
    }

    @Test func landsOnTheFirstSessionsActiveTabOnceTheServerIsIn() async throws {
        let (model, config, server) = try landingModel()
        // Still connecting when the sheet leaves; its sessions arrive a moment later.
        // A long limit: on a loaded machine a single turn of this wait can take seconds.
        let waiting = Task { await model.openWhenReady(config, timeout: 120, poll: 0.02) }
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(model.openRequest == nil)
        server.sessions = [SessionEntry(id: "s1", label: "api"), SessionEntry(id: "s2", label: "web")]
        server.views = ["s1": view("s1", active: "w2"), "s2": view("s2", active: "w1")]
        server.phase = .online
        #expect(await waiting.value)
        #expect(model.openRequest?.selection == Selection(serverID: config.id, sessionID: "s1", windowID: "w2"))
    }

    @Test func landingGivesUpAfterItsTimeout() async throws {
        let (model, config, _) = try landingModel()
        // That it returns at all is the limit at work: the server never comes up.
        #expect(await model.openWhenReady(config, timeout: 0.3, poll: 0.02) == false)
        #expect(model.openRequest == nil)
    }

    @Test func landingStopsWhenCancelledOrWhenThePersonOpensSomething() async throws {
        let (model, config, server) = try landingModel()
        let cancelled = Task { await model.openWhenReady(config, timeout: 30, poll: 0.02) }
        try await Task.sleep(nanoseconds: 60_000_000)
        cancelled.cancel()
        #expect(await cancelled.value == false)

        let overtaken = Task { await model.openWhenReady(config, timeout: 30, poll: 0.02) }
        try await Task.sleep(nanoseconds: 60_000_000)
        model.selection = Selection(serverID: UUID(), sessionID: "other", windowID: "w")
        #expect(await overtaken.value == false)
        // The server coming up afterwards doesn't pull the person away.
        server.sessions = [SessionEntry(id: "s1", label: "api")]
        server.views = ["s1": view("s1", active: "w1")]
        server.phase = .online
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(model.openRequest == nil)
    }

    @Test func aNewLandingReplacesTheOneBefore() async throws {
        let (model, config, server) = try landingModel()
        let other = ServerConfig(name: "Gone", url: "https://gone-rex.tail1234.ts.net")
        model.land(on: other)
        model.land(on: config)
        server.sessions = [SessionEntry(id: "s1", label: "api")]
        server.views = ["s1": view("s1", active: "w1")]
        server.phase = .online
        for _ in 0..<100 where model.openRequest == nil { try await Task.sleep(nanoseconds: 20_000_000) }
        #expect(model.openRequest?.selection.serverID == config.id)
    }

    // MARK: The real check

    /// Accepts connections and never answers, like a computer that is up but stuck.
    private final class SilentListener: @unchecked Sendable {
        private let queue = DispatchQueue(label: "test.silent")
        private let listener: NWListener
        private var held: [NWConnection] = []

        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [weak self] c in
                guard let self else { return }
                self.held.append(c)
                c.start(queue: self.queue)
            }
        }

        func start() async -> UInt16 {
            await withCheckedContinuation { done in
                listener.stateUpdateHandler = { [listener] state in
                    if case .ready = state {
                        listener.stateUpdateHandler = nil
                        done.resume(returning: listener.port?.rawValue ?? 0)
                    }
                }
                listener.start(queue: queue)
            }
        }

        func stop() { queue.sync { listener.cancel(); held.forEach { $0.cancel() } } }
    }

    @Test func cancellingTheRealCheckEndsItAtOnce() async throws {
        let silent = try SilentListener()
        let port = await silent.start()
        defer { silent.stop() }
        let (model, _, _) = try landingModel()
        let url = try #require(URL(string: "http://127.0.0.1:\(port)"))
        let started = Date()
        let task = Task { await model.check(url) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let cancelledAfter = Date().timeIntervalSince(started)
        task.cancel()
        guard case .problem(let p) = await task.value else { Issue.record("a cancelled check found a server"); return }
        // The probe's own limit is 6 s, and it ends as a timeout. Only a machine that held this
        // test past that limit before the cancel leaves nothing to tell apart.
        if cancelledAfter < 5 {
            #expect(!p.detail.contains("\(NSURLErrorDomain) \(NSURLErrorTimedOut)"), "ended by its limit, not by the cancel: \(p.detail)")
        }
    }

    @Test func theRealCheckReportsAComputerThatIsNotThere() async throws {
        let (model, _, _) = try landingModel()
        // Nothing listens on port 1.
        guard case .problem(let p) = await model.check(try #require(URL(string: "http://127.0.0.1:1"))) else {
            Issue.record("found a server where there is none")
            return
        }
        #expect(p.kind != .notAllowed)
    }

    @Test func cameraAccessAsksOnlyWhenUndecided() async {
        var asked = 0
        func access(_ s: AVAuthorizationStatus, grant: Bool = true) async -> CameraAccess {
            await CameraAccess.of(s) { asked += 1; return grant }
        }
        #expect(await access(.authorized) == .granted)
        #expect(await access(.denied) == .denied)
        #expect(await access(.restricted) == .restricted)
        #expect(asked == 0)
        #expect(await access(.notDetermined) == .granted)
        #expect(await access(.notDetermined, grant: false) == .denied)
        #expect(asked == 2)
    }

    // MARK: Layout

    @Test func layoutFollowsTheWindowAndTheFold() {
        // iPhone portrait, folded Duo: camera above the instructions.
        #expect(PairingLayout.decide(size: CGSize(width: 402, height: 874), division: nil) == .stacked(camera: nil))
        #expect(PairingLayout.decide(size: CGSize(width: 466, height: 678), division: nil) == .stacked(camera: nil))
        // Wide with no fold: two halves. Half of the unfolded screen is too narrow for that.
        #expect(PairingLayout.decide(size: CGSize(width: 874, height: 402), division: nil) == .sideBySide(camera: 437))
        #expect(PairingLayout.decide(size: CGSize(width: 475, height: 669), division: nil) == .stacked(camera: nil))
        // Unfolded Duo: one page each side of the crease, whichever way it runs.
        let vertical = Division(frame: CGRect(x: 470, y: 0, width: 11, height: 669), isActive: false)
        #expect(PairingLayout.decide(size: CGSize(width: 951, height: 669), division: vertical) == .sideBySide(camera: 470))
        let horizontal = Division(frame: CGRect(x: 0, y: 470, width: 669, height: 11), isActive: true)
        #expect(PairingLayout.decide(size: CGSize(width: 669, height: 951), division: horizontal) == .stacked(camera: 470))
        // A crease too near an edge to leave a page is not followed.
        let edge = Division(frame: CGRect(x: 100, y: 0, width: 0, height: 669), isActive: false)
        #expect(PairingLayout.decide(size: CGSize(width: 951, height: 669), division: edge) == .sideBySide(camera: 476))
    }

    /// The cards and the Beacon offer sit on the page past the crease, never across it.
    @Test func cardsSitOnOnePage() {
        let book = CGSize(width: 951, height: 669)
        let vertical = Division(frame: CGRect(x: 470, y: 0, width: 11, height: 669), isActive: false)
        #expect(PairingLayout.cardRect(size: book, division: vertical) == CGRect(x: 481, y: 0, width: 470, height: 669))
        let tall = CGSize(width: 669, height: 951)
        let horizontal = Division(frame: CGRect(x: 0, y: 470, width: 669, height: 11), isActive: true)
        #expect(PairingLayout.cardRect(size: tall, division: horizontal) == CGRect(x: 0, y: 481, width: 669, height: 470))
        // No fold, or one too near an edge: the whole window.
        #expect(PairingLayout.cardRect(size: book, division: nil) == CGRect(origin: .zero, size: book))
        let edge = Division(frame: CGRect(x: 100, y: 0, width: 0, height: 669), isActive: false)
        #expect(PairingLayout.cardRect(size: book, division: edge) == CGRect(origin: .zero, size: book))
    }

    /// Every place that says where the code is says it the same way: the Mac app first.
    @Test func whereTheCodeIsReadsTheSameEverywhere() {
        #expect(PairingCopy.showCode == "On your computer, in Rex: Settings → Server → Remote Address → Pair. Or run `rex server tailscale pair`.")
        #expect(PairingCopy.spoken(PairingCopy.showCode)
            == "On your computer, in Rex: Settings, Server, Remote Address, Pair. Or run rex server tailscale pair.")
        for text in [PairingSheet.instructions, EmptyStateCopy.noComputer.text, AddServerView.scanFooter, ServersPage.footer, NoServersRow.text] {
            #expect(text.contains(PairingCopy.showCode), "\(text)")
        }
        #expect(PairingCopy.getRex?.absoluteString == "https://www.superlogical.com/rex/docs/installation")
    }

    /// The tab's place with no tab: never "Pick a tab" where there is none.
    @Test func theEmptyStateSaysWhatIsThere() {
        typealias C = EmptyStateCopy.Computer
        #expect(EmptyStateCopy.decide([], tabs: false) == .noComputer)
        #expect(EmptyStateCopy.decide([C(name: "Studio", online: false, synced: false, sessions: 0)], tabs: false) == .connecting)
        // Connected, sessions not in yet: nothing is claimed.
        #expect(EmptyStateCopy.decide([C(name: "Studio", online: true, synced: false, sessions: 0)], tabs: false) == .loading)
        // Loaded and none: New Session on it.
        let none = EmptyStateCopy.decide([C(name: "Down", online: false, synced: false, sessions: 0),
                                          C(name: "Studio", online: true, synced: true, sessions: 0)], tabs: true)
        #expect(none == .noSessions(name: "Studio", index: 1))
        #expect(none.text == "No sessions on Studio yet.")
        // Any connected computer with a session: pick a tab.
        let some = EmptyStateCopy.decide([C(name: "Studio", online: true, synced: true, sessions: 0),
                                          C(name: "Box", online: true, synced: false, sessions: 2)], tabs: false)
        #expect(some == .pickTab(tabs: false))
        #expect(some.text == "Pick a tab in the sidebar.")
        #expect(EmptyStateCopy.pickTab(tabs: true).text == "Pick a session.")
    }
}
