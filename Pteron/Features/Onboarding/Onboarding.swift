import Foundation
import GlanceModel
import Observation

/// Where the setup guide starts.
enum OnboardingStart: Equatable {
    /// A first run: the welcome, the tour, then the checklist.
    case welcome
    /// Setup Guide, from the empty state or Settings: the checklist alone.
    case checklist
}

/// Whether a launch opens on the setup guide. Pure, so it is tested.
///
/// Only an install that has never had a server and never left the guide sees it. An update that
/// finds servers sets `Prefs.onboardingDone` before the first frame, so an existing user never
/// does. A test launch (its own servers, a session to open, a demo) never does either.
enum FirstRun {
    /// Launch arguments of test runs (docs/debug-args.md).
    static let testArguments = ["servers", "autoOpen", "boardDemo", "simulateOffline"]

    /// `servers`: the servers the model built, which `-servers` replaces for a run.
    static func start(done: Bool, servers: Int, defaults: UserDefaults = .standard) -> OnboardingStart? {
        guard !done, servers == 0 else { return nil }
        guard !testArguments.contains(where: { defaults.object(forKey: $0) != nil }) else { return nil }
        return .welcome
    }
}

/// The checklist's words (`ConnectPage`). Tailscale is explained where a screen first names it.
enum ChecklistCopy {
    static let steps = 4

    static let header = "\(Brand.appName) reaches your computer through Tailscale, a free private network for your own devices."
    /// The header for someone who came from "I Have a Pairing Code" off the tailnet.
    static let tailscaleFirst = "First connect this \(DeviceWord.current) with Tailscale, a free private network for your own devices. The camera opens once it's on."

    static let rex = "Rex on your computer"
    static let rexDetail = "\(Brand.appName) shows your Rex sessions. Rex is a terminal app for Mac and Linux."
    static let tailscale = "Connect this \(DeviceWord.current) with Tailscale"
    static let rexTailscale = "Turn on Tailscale in Rex"
    /// Markdown: commands in code type. Flags from `rex server tailscale on --help`.
    static let linuxSignIn = "If it asks you to sign in, run `rex server tailscale login` and open the link on any device. Tailscale stays on until Rex restarts; start the server with `--tailscale` to keep it on."
    static let rexJoins = "Rex joins Tailscale by itself; the computer's Tailscale app isn't needed."
    static let sameAccount = "Sign in with the same account as on this \(DeviceWord.current)."
    static let pairCode = "Show the pairing code"
    static let noPair = "No Pair option? Update Rex."

    /// What VoiceOver says for a step's title. `done` is nil for a step the app can't check,
    /// which is never called done or not done.
    static func spoken(step: Int, title: String, done: Bool?) -> String {
        let head = "Step \(step) of \(steps), \(title)"
        guard let done else { return head }
        return head + (done ? ", done" : ", not done")
    }
}

/// The guide's steps and what each control does. It exists only while the guide is on screen.
///
/// Nothing in it asks for a permission: the camera is asked for by the scanner that `pair` opens,
/// and notifications by the Beacon offer after a computer is added. Nothing in it waits on the
/// network or gates a step: every screen can be skipped or left. The one thing it does on its own:
/// a pairing code tapped off the tailnet opens the scanner once the tailnet comes up
/// (`scanWhenConnected`), which `NetworkWatch` reports.
@MainActor
@Observable
final class OnboardingModel {
    enum Step: Equatable {
        case welcome, tour, connect
    }

    /// The tour's cards: what the app is, and why to have it.
    enum Card: Int, CaseIterable, Identifiable, Hashable {
        case sessions, agents
        var id: Int { rawValue }
    }

    /// Which steps the checklist shows for the computer: Rex's Mac app, or Rex's command line.
    enum Computer: String, CaseIterable, Identifiable {
        case mac, linux
        var id: String { rawValue }
        var title: String { self == .mac ? "Mac" : "Linux" }
    }

    /// What the guide makes happen outside itself.
    struct Effects {
        /// "Pair via QR Code", over the guide.
        var pair: @MainActor () -> Void = {}
        /// Settings → Add Computer, over the guide.
        var enterAddress: @MainActor () -> Void = {}
        /// The Tailscale app's App Store page, in the app. It calls its argument once the page is
        /// gone.
        var getTailscale: @MainActor (_ closed: @escaping @MainActor () -> Void) -> Void = { _ in }
        /// The guide goes (Not Now).
        var close: @MainActor () -> Void = {}
        /// Whether this iPhone is on a tailnet now (`NetworkWatch`). Unknown reads as no.
        var onTailnet: @MainActor () -> Bool = { false }
    }

    private(set) var step: Step
    /// The card on screen while the tour shows. Optional for `scrollPosition(id:)`.
    var card: Card? = .sessions
    var computer: Computer = .mac
    /// Opened from Setup Guide: the checklist is all there is, with nothing to go back to.
    let reopened: Bool
    /// "I Have a Pairing Code" was tapped while this iPhone wasn't on a tailnet: the checklist
    /// shows its Tailscale step as the one to do, and the scanner opens by itself, once, when the
    /// tailnet comes up while the checklist is still in front. Any other way off the checklist
    /// drops it.
    private(set) var scanWhenConnected = false
    /// The App Store page is over the guide.
    private(set) var storeShown = false
    @ObservationIgnored private let effects: Effects

    init(start: OnboardingStart, effects: Effects) {
        reopened = start == .checklist
        step = start == .checklist ? .connect : .welcome
        self.effects = effects
        #if DEBUG
        // `-guideStep agents|tour|connect|pairingCode` (testing): the first run opened at that
        // step; `pairingCode` is "I Have a Pairing Code" tapped on the welcome.
        if !reopened {
            switch UserDefaults.standard.string(forKey: "guideStep") {
            case "tour": step = .tour
            case "agents": step = .tour; card = .agents
            case "connect": step = .connect
            case "pairingCode": havePairingCode()
            default: break
            }
        }
        if UserDefaults.standard.string(forKey: "guideComputer") == "linux" { computer = .linux }
        #endif
    }

    /// Back goes to the previous card or step; the welcome and a reopened checklist have none.
    var canGoBack: Bool { step == .tour || (step == .connect && !reopened) }
    /// Skip goes to the checklist from the welcome and the tour.
    var canSkip: Bool { step != .connect }
    /// The checklist's way out says what it does: a first run is put off, a reopened guide closed.
    var closeTitle: String { reopened ? "Close" : "Not Now" }

    func getStarted() {
        card = .sessions
        step = .tour
    }

    func skip() { step = .connect }

    /// Continue: the next card, then the checklist.
    func next() {
        guard step == .tour else { return }
        if let c = card, let n = Card(rawValue: c.rawValue + 1) {
            card = n
        } else {
            step = .connect
        }
    }

    func back() {
        switch step {
        case .welcome:
            break
        case .tour:
            if let c = card, let p = Card(rawValue: c.rawValue - 1) {
                card = p
            } else {
                step = .welcome
            }
        case .connect:
            guard !reopened else { return }
            scanWhenConnected = false
            card = Card.allCases.last
            step = .tour
        }
    }

    /// "I Have a Pairing Code": the scanner when this iPhone is on a tailnet, where a code's
    /// address can answer. Otherwise the checklist at its Tailscale step, so the scan doesn't end
    /// at a computer this iPhone can't reach.
    func havePairingCode() {
        if effects.onTailnet() {
            effects.pair()
        } else {
            scanWhenConnected = true
            step = .connect
        }
    }

    /// What the checklist sees changed: the tailnet, or something over it (a sheet, the App Store
    /// page, the app in the background). Opens the scanner once, for a pairing code that waited
    /// on the tailnet, when the tailnet is up and nothing covers the checklist.
    func checklistChanged(onTailnet: Bool, covered: Bool) {
        guard scanWhenConnected, step == .connect, onTailnet, !covered, !storeShown else { return }
        scanWhenConnected = false
        effects.pair()
    }

    /// Scan Code.
    func pair() {
        scanWhenConnected = false
        effects.pair()
    }

    func enterAddress() {
        scanWhenConnected = false
        effects.enterAddress()
    }

    func getTailscale() {
        storeShown = true
        effects.getTailscale { [weak self] in self?.storeShown = false }
    }

    func close() {
        scanWhenConnected = false
        effects.close()
    }
}
