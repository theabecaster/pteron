import Foundation
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

/// The guide's steps and what each control does. It exists only while the guide is on screen.
///
/// Nothing in it asks for a permission: the camera is asked for by the scanner that `pair` opens,
/// and notifications by the Beacon offer after a computer is added. Nothing in it waits on the
/// network or gates a step: every screen can be skipped or left.
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
        /// Settings → Add Server, over the guide.
        var enterAddress: @MainActor () -> Void = {}
        /// The Tailscale app's App Store page, in the app.
        var getTailscale: @MainActor () -> Void = {}
        /// The guide goes (Not Now).
        var close: @MainActor () -> Void = {}
    }

    private(set) var step: Step
    /// The card on screen while the tour shows. Optional for `scrollPosition(id:)`.
    var card: Card? = .sessions
    var computer: Computer = .mac
    /// Opened from Setup Guide: the checklist is all there is, with nothing to go back to.
    let reopened: Bool
    @ObservationIgnored private let effects: Effects

    init(start: OnboardingStart, effects: Effects) {
        reopened = start == .checklist
        step = start == .checklist ? .connect : .welcome
        self.effects = effects
        #if DEBUG
        // `-guideStep agents|tour|connect` (testing): the first run opened at that step.
        if !reopened {
            switch UserDefaults.standard.string(forKey: "guideStep") {
            case "tour": step = .tour
            case "agents": step = .tour; card = .agents
            case "connect": step = .connect
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
            card = Card.allCases.last
            step = .tour
        }
    }

    func pair() { effects.pair() }
    func enterAddress() { effects.enterAddress() }
    func getTailscale() { effects.getTailscale() }
    func close() { effects.close() }
}
