import Foundation
import GlanceModel
import Testing
@testable import RexDuo

/// The first-run guide: who sees it, its steps and ways out, what it may make happen, the
/// Tailscale tick's detection, and what ends it.
@MainActor
@Suite struct OnboardingTests {
    private func defaults() throws -> UserDefaults {
        let suite = "onboarding-\(UUID().uuidString)"
        let d = try #require(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
        return d
    }

    private func savedServers(_ d: UserDefaults) throws {
        let list = [ServerConfig(name: "desk", url: "https://desk-rex.tail1234.ts.net")]
        d.set(try JSONEncoder().encode(list), forKey: "servers")
    }

    // MARK: Who sees it (hazards 1 and 7)

    @Test func onlyAFreshInstallStartsOnTheWelcome() throws {
        let d = try defaults()
        #expect(FirstRun.start(done: false, servers: 0, defaults: d) == .welcome)
        #expect(FirstRun.start(done: true, servers: 0, defaults: d) == nil)
        #expect(FirstRun.start(done: false, servers: 1, defaults: d) == nil)
    }

    @Test func aTestLaunchNeverShowsIt() throws {
        for key in FirstRun.testArguments {
            let d = try defaults()
            d.set("zz-test", forKey: key)
            #expect(FirstRun.start(done: false, servers: 0, defaults: d) == nil, "\(key)")
        }
    }

    @Test func anUpdateWithServersIsDoneBeforeTheFirstFrame() throws {
        let d = try defaults()
        try savedServers(d)
        let prefs = Prefs(defaults: d)
        #expect(prefs.onboardingDone)
        // Saved, so removing every server later doesn't bring the guide back.
        #expect(d.bool(forKey: "onboardingDone"))
        prefs.servers = []
        #expect(Prefs(defaults: d).onboardingDone)
    }

    @Test func aFreshInstallIsNotDoneUntilAServerIsAdded() throws {
        let d = try defaults()
        let prefs = Prefs(defaults: d)
        #expect(!prefs.onboardingDone)
        prefs.servers.append(ServerConfig(name: "desk", url: "https://desk-rex.tail1234.ts.net"))
        #expect(prefs.onboardingDone)
        #expect(Prefs(defaults: d).onboardingDone)
    }

    @Test func theTestHostNeverShowsIt() throws {
        let model = AppModel(prefs: Prefs(defaults: try defaults()), connect: false)
        #expect(model.guide == nil)
    }

    // MARK: What ends it (hazards 2 and 8)

    @Test func notNowEndsTheFirstRunForGood() throws {
        let d = try defaults()
        let model = AppModel(prefs: Prefs(defaults: d), connect: false)
        model.guide = .welcome
        model.closeGuide()
        #expect(model.guide == nil)
        #expect(model.prefs.onboardingDone)
        #expect(FirstRun.start(done: Prefs(defaults: d).onboardingDone, servers: 0, defaults: try defaults()) == nil)
    }

    @Test func setupGuideReopensTheChecklistOverSettings() throws {
        let model = AppModel(prefs: Prefs(defaults: try defaults()), connect: false)
        model.showSettings = true
        model.openGuide()
        #expect(!model.showSettings)
        #expect(model.guide == .checklist)
    }

    @Test func addingAComputerEndsTheGuide() throws {
        let model = AppModel(prefs: Prefs(defaults: try defaults()), connect: false)
        model.guide = .welcome
        #expect(model.addServer(ServerConfig(name: "desk", url: "https://desk-rex.tail1234.ts.net")))
        #expect(model.guide == nil)
        #expect(model.prefs.onboardingDone)
    }

    @Test func thePairLinkGoesStraightToPairingAndTheServerEndsTheFirstRun() throws {
        let model = AppModel(prefs: Prefs(defaults: try defaults()), connect: false)
        model.guide = .welcome
        model.releaseLinks()
        model.openLink(DeepLink.pair.url)
        #expect(model.showPairing)
        // The guide steps aside for this run; the first run isn't over until a computer is added.
        #expect(model.guide == nil)
        #expect(!model.prefs.onboardingDone)
        model.addServer(ServerConfig(name: "desk", url: "https://desk-rex.tail1234.ts.net"))
        #expect(model.prefs.onboardingDone)
    }

    // MARK: Steps and ways out (hazard 2, rule: no dead ends)

    /// Counts what the guide asked for outside itself.
    private final class Spy {
        var pair = 0, enterAddress = 0, getTailscale = 0, close = 0
        var total: Int { pair + enterAddress + getTailscale + close }
    }

    private func flow(_ start: OnboardingStart = .welcome) -> (OnboardingModel, Spy) {
        let spy = Spy()
        let flow = OnboardingModel(start: start, effects: .init(
            pair: { spy.pair += 1 }, enterAddress: { spy.enterAddress += 1 },
            getTailscale: { spy.getTailscale += 1 }, close: { spy.close += 1 }))
        return (flow, spy)
    }

    @Test func theFirstRunGoesForwardAndBackThroughEveryStep() {
        let (f, _) = flow()
        #expect(f.step == .welcome && !f.canGoBack && f.canSkip)
        f.getStarted()
        #expect(f.step == .tour && f.card == .sessions && f.canGoBack && f.canSkip)
        f.next()
        #expect(f.step == .tour && f.card == .agents)
        f.next()
        #expect(f.step == .connect && f.canGoBack && !f.canSkip)
        #expect(f.closeTitle == "Not Now")
        // Back from the checklist lands on the last card, then the first, then the welcome.
        f.back()
        #expect(f.step == .tour && f.card == .agents)
        f.back()
        #expect(f.step == .tour && f.card == .sessions)
        f.back()
        #expect(f.step == .welcome)
    }

    @Test func skipGoesToTheChecklistFromEveryScreenBeforeIt() {
        let (welcome, _) = flow()
        welcome.skip()
        #expect(welcome.step == .connect)
        for card in OnboardingModel.Card.allCases {
            let (f, _) = flow()
            f.getStarted()
            f.card = card
            f.skip()
            #expect(f.step == .connect)
        }
    }

    @Test func aReopenedGuideIsTheChecklistWithAClose() {
        let (f, spy) = flow(.checklist)
        #expect(f.step == .connect && f.reopened && !f.canGoBack && !f.canSkip)
        #expect(f.closeTitle == "Close")
        f.back()
        #expect(f.step == .connect)
        f.close()
        #expect(spy.close == 1)
    }

    // MARK: Permissions (hazard 3)

    /// Walking the guide asks for nothing outside it: no camera, no notifications, no App Store.
    /// Each effect runs only from its own control, and the only one that leads to a permission
    /// question is Scan Code (the scanner asks for the camera when it opens).
    @Test func noEffectRunsBeforeItsOwnTap() {
        let (f, spy) = flow()
        f.getStarted(); f.next(); f.back(); f.next(); f.next(); f.back(); f.skip()
        f.computer = .linux
        #expect(spy.total == 0)
        f.getTailscale()
        #expect(spy.getTailscale == 1 && spy.total == 1)
        f.enterAddress()
        #expect(spy.enterAddress == 1 && spy.total == 2)
        f.pair()
        #expect(spy.pair == 1 && spy.total == 3)
        f.close()
        #expect(spy.close == 1 && spy.total == 4)
    }

    @Test func theGuideNeverTurnsNotificationsOn() throws {
        let model = AppModel(prefs: Prefs(defaults: try defaults()), connect: false)
        model.guide = .welcome
        model.openGuide()
        model.closeGuide()
        #expect(!model.prefs.pushEnabled)
        #expect(!model.showPairing)
    }

    // MARK: The Tailscale tick (hazard 4)

    @Test func tailscaleIPv4CountsOnlyOnATunnel() {
        let tailnet: UInt32 = 0x646D_0631     // 100.109.6.49
        let cgnat: UInt32 = 0x6440_1A02       // 100.64.26.2, a carrier's NAT
        // Cellular CGNAT on the phone's own interface: not Tailscale.
        #expect(!PrivateNetwork.isTailnet(interface: "pdp_ip0", ipv4: cgnat))
        #expect(!PrivateNetwork.isTailnet(interface: "en0", ipv4: tailnet))
        // Tailscale's tunnel.
        #expect(PrivateNetwork.isTailnet(interface: "utun4", ipv4: tailnet))
        // Another tunnel's private address is no tailnet.
        #expect(!PrivateNetwork.isTailnet(interface: "utun2", ipv4: 0x0A00_0001))
        // IPv6: Tailscale's own range, on any interface.
        #expect(PrivateNetwork.isTailnet(ipv6: [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0] + Array(repeating: 1, count: 10)))
    }

    @Test func tailnetAddresses() {
        #expect(TailscaleApp.isTailnetAddress("https://desk-rex.tail1234.ts.net"))
        #expect(TailscaleApp.isTailnetAddress("desk-rex.tail1234.ts.net"))
        #expect(TailscaleApp.isTailnetAddress("https://DESK.TAIL1234.TS.NET:443"))
        #expect(!TailscaleApp.isTailnetAddress("http://192.168.1.20:8765"))
        #expect(!TailscaleApp.isTailnetAddress("https://desk.ts.net.example.com"))
        #expect(!TailscaleApp.isTailnetAddress(""))
    }
}
