import AVFoundation
import Foundation
import RexKit
import Testing
@testable import RexConnect

@MainActor
struct PairingTests {
    private let mac = ServerConfig(name: "Studio", url: "https://macbook-pro-rex.tail8657d0.ts.net")

    // MARK: Parsing

    @Test func readsRexCodeAsItsAddress() {
        #expect(PairingCode.address(from: "https://workdesk-rex.tail8657d0.ts.net")?.absoluteString
                == "https://workdesk-rex.tail8657d0.ts.net")
    }

    @Test func normalizesCaseSpacePathAndDefaultPort() {
        let want = "https://workdesk-rex.tail8657d0.ts.net"
        for raw in ["  HTTPS://WorkDesk-Rex.Tail8657d0.ts.net/\n", "https://workdesk-rex.tail8657d0.ts.net:443",
                    "https://workdesk-rex.tail8657d0.ts.net/api/control?x=1#y"] {
            #expect(PairingCode.address(from: raw)?.absoluteString == want, "\(raw)")
        }
        #expect(PairingCode.address(from: "https://10.0.0.5:8443/")?.absoluteString == "https://10.0.0.5:8443")
        // A fully qualified name's trailing dot is the same host.
        #expect(PairingCode.address(from: "https://workdesk-rex.tail8657d0.ts.net.")?.absoluteString == want)
        #expect(PairingCode.address(from: "https://[fd7a:115c:a1e0::1]:8443")?.host() == "fd7a:115c:a1e0::1")
    }

    @Test func rejectsWhatIsNotAnHTTPSAddress() {
        for raw in ["", "hello", "workdesk-rex.tail8657d0.ts.net", "http://workdesk-rex.tail8657d0.ts.net",
                    "rex://pair?url=x", "WIFI:S:Home;T:WPA;P:secret;;", "https://", "https://localhost",
                    "https://user:pw@workdesk-rex.tail8657d0.ts.net", "https://a.ts.net and more",
                    "mailto:someone@example.com", "https://a.b", "https://.", "https://..", "https://studio",
                    "https://-a.example.com", "https://a-.example.com", "https://a..example.com", "https://a_b.example.com",
                    "https://example.123", "https://999.1.1.1", "https://1.2.3", "https://1.2.3.4.5"] {
            #expect(PairingCode.address(from: raw) == nil, "\(raw)")
        }
    }

    // MARK: Saved servers

    @Test func findsTheSavedServerHoweverItWasTyped() throws {
        let url = try #require(PairingCode.address(from: "https://macbook-pro-rex.tail8657d0.ts.net"))
        for saved in ["https://macbook-pro-rex.tail8657d0.ts.net", "https://MacBook-Pro-Rex.tail8657d0.ts.net/",
                      "macbook-pro-rex.tail8657d0.ts.net", "https://macbook-pro-rex.tail8657d0.ts.net:443"] {
            let list = [ServerConfig(name: "Other", url: "https://workdesk-rex.tail8657d0.ts.net"), ServerConfig(name: "Mine", url: saved)]
            #expect(PairingCode.existing(url, in: list)?.name == "Mine", "\(saved)")
        }
        #expect(PairingCode.existing(url, in: [ServerConfig(name: "Port", url: "https://macbook-pro-rex.tail8657d0.ts.net:8443")]) == nil)
        #expect(PairingCode.existing(url, in: [ServerConfig(name: "Plain", url: "http://macbook-pro-rex.tail8657d0.ts.net")]) == nil)
        #expect(PairingCode.existing(url, in: []) == nil)
    }

    @Test func namesAServerFromItsHost() throws {
        func name(_ s: String) throws -> String { ServerConfig.name(for: try #require(URL(string: s))) }
        #expect(try name("https://workdesk-rex.tail8657d0.ts.net") == "workdesk")
        #expect(try name("https://macbook-pro-rex.tail8657d0.ts.net") == "macbook-pro")
        #expect(try name("https://studio.tail1234.ts.net") == "studio")
        #expect(try name("https://rex.tail1234.ts.net") == "rex")
        #expect(try name("https://-rex.tail1234.ts.net") == "-rex")
        #expect(try name("https://10.0.0.5:8443") == "10.0.0.5")
    }

    @Test func tellsAForeignTailnet() throws {
        let other = try #require(URL(string: "https://studio-rex.tail999999.ts.net"))
        let same = try #require(URL(string: "https://workdesk-rex.tail8657d0.ts.net"))
        #expect(PairingCode.tailnet(of: same) == "tail8657d0.ts.net")
        #expect(PairingCode.tailnet(of: try #require(URL(string: "https://example.com"))) == nil)
        #expect(PairingCode.tailnet(of: try #require(URL(string: "https://ts.net"))) == nil)
        #expect(PairingCode.isForeignTailnet(other, servers: [mac]))
        #expect(!PairingCode.isForeignTailnet(same, servers: [mac]))
        // Nothing to compare with: no saved server, or none on a tailnet.
        #expect(!PairingCode.isForeignTailnet(other, servers: []))
        #expect(!PairingCode.isForeignTailnet(other, servers: [ServerConfig(name: "LAN", url: "https://10.0.0.5")]))
    }

    // MARK: What a failed check offers

    private func problem(_ kind: ConnectionProblem.Kind, foreign: Bool = false) -> PairingProblem {
        .of(ConnectionProblem(kind: kind, detail: "NSURLErrorDomain -1"), foreignTailnet: foreign)
    }

    @Test func offThePrivateNetworkOffersAllThree() {
        for kind in [ConnectionProblem.Kind.offPrivateNetwork, .hostNotFound] {
            let p = problem(kind)
            #expect(p.message.hasPrefix("This iPhone can't reach that computer's private network."))
            #expect(p.actions == [.tryAgain, .addAnyway])
            #expect(p.detail == nil)
        }
    }

    @Test func aSilentComputerOnAnotherTailnetReadsAsOffItsNetwork() {
        #expect(problem(.notAnswering).message.hasPrefix("That computer isn't answering."))
        #expect(problem(.notAnswering, foreign: true) == problem(.offPrivateNetwork))
    }

    @Test func notAllowedOnlyCancels() {
        let p = problem(.notAllowed, foreign: true)
        #expect(p.message == "That computer didn't let this iPhone in. It may belong to a different account.")
        #expect(p.actions.isEmpty)
    }

    @Test func offlineCanOnlyTryAgain() {
        #expect(problem(.noInternet).actions == [.tryAgain])
    }

    @Test func onlyUnexplainedFailuresCarryDetail() {
        #expect(problem(.unknown).detail == "NSURLErrorDomain -1")
        #expect(problem(.insecure).detail == "NSURLErrorDomain -1")
        #expect(problem(.insecure).actions == [.tryAgain])
        for kind in ConnectionProblem.Kind.allCases where ![.unknown, .insecure, .badAddress].contains(kind) {
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
        var probed: [URL] = []
        var existing: [ServerConfig] = []
        var added: [ServerConfig] = []
        var gate: CheckedContinuation<Void, Never>?
        var hold = false
        /// The probe waits like a slow network, and notes when its task is cancelled.
        var sleeps = false
        var sawCancel = false
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
                    return self.answers.isEmpty ? nil : self.answers.removeFirst()
                },
                onExisting: { self.existing.append($0) },
                onAdd: { self.added.append($0) })
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
        #expect(rig.model.scanned("https://workdesk-rex.tail8657d0.ts.net"))
        let url = try #require(URL(string: "https://workdesk-rex.tail8657d0.ts.net"))
        #expect(rig.model.step == .checking(url))
        await rig.settle()
        #expect(rig.model.step == .found(url))
        #expect(rig.model.name == "workdesk")
        #expect(rig.added.isEmpty)

        rig.model.name = "  Desk  "
        rig.model.add()
        #expect(rig.added.map(\.name) == ["Desk"])
        #expect(rig.added.map(\.url) == ["https://workdesk-rex.tail8657d0.ts.net"])
    }

    @Test func anEmptyNameFallsBackToTheHost() async {
        let rig = Rig(servers: [])
        rig.model.scanned("https://workdesk-rex.tail8657d0.ts.net")
        await rig.settle()
        rig.model.name = "   "
        rig.model.add()
        #expect(rig.added.map(\.name) == ["workdesk"])
    }

    @Test func aSavedServerKeepsItsNameAndIsNotProbed() {
        let rig = Rig(servers: [mac])
        #expect(rig.model.scanned("https://MACBOOK-PRO-REX.tail8657d0.ts.net/"))
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
        #expect(rig.model.scanned("https://workdesk-rex.tail8657d0.ts.net"))
        #expect(rig.model.rejection == nil)
    }

    @Test func aFailedCheckCanBeRetriedOrAddedAnyway() async throws {
        let rig = Rig(servers: [mac])
        rig.answers = [ConnectionProblem(kind: .offPrivateNetwork, detail: "d"), ConnectionProblem(kind: .notAnswering, detail: "d")]
        rig.model.scanned("https://studio-rex.tail999999.ts.net")
        await rig.settle()
        let url = try #require(URL(string: "https://studio-rex.tail999999.ts.net"))
        guard case .problem(url, let first) = rig.model.step else { Issue.record("\(rig.model.step)"); return }
        #expect(first.actions == [.tryAgain, .addAnyway])

        rig.model.tryAgain()
        await rig.settle()
        guard case .problem = rig.model.step else { Issue.record("\(rig.model.step)"); return }
        #expect(rig.probed.count == 2)

        rig.model.addAnyway()
        #expect(rig.added.map(\.name) == ["studio"])
        #expect(rig.model.step == .done)
    }

    @Test func aRefusedServerCanOnlyBeCancelled() async {
        let rig = Rig(servers: [])
        rig.answers = [ConnectionProblem(kind: .notAllowed, detail: "d")]
        rig.model.scanned("https://studio-rex.tail999999.ts.net")
        await rig.settle()
        guard case .problem(_, let p) = rig.model.step else { Issue.record("\(rig.model.step)"); return }
        #expect(p.actions.isEmpty)
        rig.model.addAnyway()
        rig.model.tryAgain()
        rig.model.add()
        #expect(rig.added.isEmpty)
        #expect(rig.probed.count == 1)
        guard case .problem = rig.model.step else { Issue.record("\(rig.model.step)"); return }
    }

    @Test func addingTwiceSavesOnce() async {
        let rig = Rig(servers: [])
        rig.model.scanned("https://workdesk-rex.tail8657d0.ts.net")
        await rig.settle()
        // Return on the name field, then a tap on Add.
        rig.model.add()
        rig.model.add()
        rig.model.addAnyway()
        #expect(rig.added.count == 1)
        #expect(rig.model.step == .done)
        // Nothing restarts a finished run.
        rig.model.rescan()
        #expect(!rig.model.scanned("https://macdesk-rex.tail8657d0.ts.net"))
        #expect(rig.model.step == .done)
        #expect(rig.probed.count == 1)
    }

    @Test func addingAnywayTwiceSavesOnce() async {
        let rig = Rig(servers: [])
        rig.answers = [ConnectionProblem(kind: .notAnswering, detail: "d")]
        rig.model.scanned("https://workdesk-rex.tail8657d0.ts.net")
        await rig.settle()
        rig.model.addAnyway()
        rig.model.addAnyway()
        #expect(rig.added.count == 1)
    }

    @Test func aSavedServerSeenOnEveryFrameIsReportedOnce() {
        let rig = Rig(servers: [mac])
        let t = Date()
        #expect(rig.model.scanned("https://macbook-pro-rex.tail8657d0.ts.net", at: t))
        #expect(!rig.model.scanned("https://macbook-pro-rex.tail8657d0.ts.net", at: t + 0.03))
        // Another spelling of it, or the same one after a pause: the run is over either way.
        #expect(!rig.model.scanned("https://MACBOOK-PRO-REX.tail8657d0.ts.net", at: t + 0.06))
        #expect(!rig.model.scanned("https://macbook-pro-rex.tail8657d0.ts.net", at: t + 10))
        #expect(rig.existing.count == 1)
    }

    @Test func aCodeReadWhileCheckingIsIgnored() async {
        let rig = Rig(servers: [])
        rig.model.scanned("https://workdesk-rex.tail8657d0.ts.net")
        #expect(!rig.model.scanned("https://macdesk-rex.tail8657d0.ts.net"))
        await rig.settle()
        #expect(rig.probed.count == 1)
        #expect(!rig.model.scanned("https://macdesk-rex.tail8657d0.ts.net"))
    }

    @Test func cancellingACheckDoesNotStartItAgainWhileTheCodeIsStillInView() async {
        let rig = Rig(servers: [])
        rig.hold = true
        let code = "https://workdesk-rex.tail8657d0.ts.net"
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
        #expect(rig.model.scanned("https://macdesk-rex.tail8657d0.ts.net", at: t + 5))
    }

    @Test func anAnswerToACancelledCheckIsDropped() async {
        let rig = Rig(servers: [])
        rig.hold = true
        rig.model.scanned("https://workdesk-rex.tail8657d0.ts.net")
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
            rig.model.scanned("https://workdesk-rex.tail8657d0.ts.net")
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

    // MARK: The app's side

    @Test func aRefusalReadsAsNotAllowedAndARedirectAsNotRex() throws {
        let net = NetworkSnapshot(reachable: true, onPrivateNetwork: true)
        #expect(ServerProbe.failure(status: 426) == nil)
        let refused = ConnectionProblem.classify(try #require(ServerProbe.failure(status: 403)), network: net)
        #expect(refused.kind == .notAllowed)
        #expect(PairingProblem.of(refused, foreignTailnet: false).actions.isEmpty)
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
        model.addServer(ServerConfig(name: "Desk", url: "https://workdesk-rex.tail8657d0.ts.net"))
        model.addServer(ServerConfig(name: "Again", url: "https://WorkDesk-Rex.tail8657d0.ts.net/"))
        model.addServer(ServerConfig(name: "Mini", url: "https://macdesk-rex.tail8657d0.ts.net"))
        #expect(prefs.servers.map(\.name) == ["Desk", "Mini"])
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
}
