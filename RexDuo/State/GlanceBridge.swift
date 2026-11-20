import Foundation
import GlanceModel
import WatchConnectivity

/// What the bridge needs of the session with the watch. `WCSessionLink` is the real one; tests
/// have their own.
@MainActor
protocol WatchLink: AnyObject {
    /// Called on the main actor when the session's state changes.
    var onEvent: (@MainActor (WatchLinkEvent) -> Void)? { get set }
    /// False where the device has no session at all.
    var isSupported: Bool { get }
    func activate()
    var isActivated: Bool { get }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    var isComplicationEnabled: Bool { get }
    var transfersLeft: Int { get }
    func update(context: [String: Any]) throws
    func transferComplication(_ info: [String: Any])
}

enum WatchLinkEvent: Equatable, Sendable {
    /// Activation ended, and the session's properties now hold real values.
    case activated
    /// The person is switching watches: nothing can be sent.
    case inactive
    /// The switch is done: the session wants to be activated for the other watch.
    case deactivated
    /// Something about the watch changed: paired, the watch app installed, a complication added.
    case watchChanged
}

/// Sends the snapshot to the watch (docs/glance.md, The watch). Owned by `AppModel`, which
/// hands it to the snapshot's writer: the bridge gets each snapshot as it is written, with the
/// bytes that went to the file, and `WatchDelivery` decides which of them go on, and when.
///
/// It only sends. Nothing comes back from the watch, so the watch can never wake the phone or
/// ask it for anything, and the bridge knows nothing of `AppModel` or the servers.
///
/// The session is made and activated at the first snapshot, never at launch: a launch that
/// writes nothing (a test, a launch that doesn't reach the screen) never touches it.
@MainActor
final class GlanceBridge {
    struct Parts {
        var now: @MainActor () -> Date = { Date() }
        var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max($0, 0) * 1_000_000_000)) }
    }

    private let makeLink: @MainActor () -> WatchLink?
    private let parts: Parts
    private var link: WatchLink?
    private var started = false
    private var delivery = WatchDelivery()
    /// The newest snapshot written, and its bytes.
    private var latest: (snapshot: GlanceSnapshot, data: Data)?
    /// Whether the watch app was installed when last looked.
    private var installed = false
    private var timer: Task<Void, Never>?

    /// `link` is asked once, at the first snapshot.
    init(parts: Parts = Parts(), link: @escaping @MainActor () -> WatchLink?) {
        self.parts = parts
        makeLink = link
    }

    /// The writer wrote this snapshot. `leaving`: the app is on its way to the background.
    func wrote(_ snapshot: GlanceSnapshot, data: Data, leaving: Bool) {
        latest = (snapshot, data)
        start()
        offer(leaving ? .leaving : .wrote)
    }

    #if DEBUG
    /// `-glanceDemo <scenario>`: these bytes go as they are once the session can deliver, so
    /// a paired watch simulator shows the scenario.
    func wroteDemo(_ data: Data) {
        demo = data
        start()
        sendDemo()
    }

    private var demo: Data?

    private func sendDemo() {
        guard let demo, let link, ready(link) else { return }
        try? link.update(context: WatchPayload.dictionary(demo))
        NSLog("GLANCE_WATCH demo bytes=%d", demo.count)
    }
    #endif

    private func start() {
        guard !started else { return }
        started = true
        guard let link = makeLink(), link.isSupported else { return }
        self.link = link
        link.onEvent = { [weak self] in self?.handle($0) }
        // Its properties hold real values only after activation, so nothing is asked first.
        link.activate()
    }

    private func handle(_ event: WatchLinkEvent) {
        guard let link else { return }
        #if DEBUG
        NSLog("GLANCE_WATCH %@ activated=%d paired=%d installed=%d", String(describing: event), link.isActivated ? 1 : 0,
              link.isPaired ? 1 : 0, link.isWatchAppInstalled ? 1 : 0)
        #endif
        switch event {
        case .activated:
            installed = link.isWatchAppInstalled
            offer(.opened)
        case .watchChanged:
            let now = link.isWatchAppInstalled
            defer { installed = now }
            // The watch app was just installed: it gets the state at once, not at the next change.
            if now, !installed { offer(.opened) }
        case .inactive:
            timer?.cancel()
            timer = nil
        case .deactivated:
            // Another watch: nothing was sent to it yet.
            delivery.reset()
            installed = false
            link.activate()
        }
    }

    private func ready(_ link: WatchLink) -> Bool {
        link.isActivated && link.isPaired && link.isWatchAppInstalled
    }

    private func offer(_ reason: WatchDelivery.Reason) {
        #if DEBUG
        if reason == .opened { sendDemo() }
        #endif
        guard let link, let latest else { return }
        let state = ready(link)
            ? WatchDelivery.Link(ready: true, complicationEnabled: link.isComplicationEnabled, transfersLeft: link.transfersLeft)
            : WatchDelivery.Link(ready: false)
        let step = delivery.offer(latest.snapshot, reason: reason, link: state, now: parts.now())
        if step.context {
            let payload = WatchPayload.dictionary(latest.data)
            do {
                try link.update(context: payload)
                if step.complication { link.transferComplication(payload) }
                #if DEBUG
                // To check on a simulator that the phone sent: `eventMessage CONTAINS "GLANCE_WATCH"`.
                NSLog("GLANCE_WATCH seq=%d complication=%d", latest.snapshot.seq ?? 0, step.complication ? 1 : 0)
                #endif
            } catch {
                delivery.failed()
            }
        }
        schedule(ready: state.ready)
    }

    /// Wakes for a change the gap holds. Nothing is scheduled while the session can't deliver:
    /// its next event offers the newest snapshot.
    private func schedule(ready: Bool) {
        timer?.cancel()
        timer = nil
        guard ready, let at = delivery.wake(latest?.snapshot, now: parts.now()) else { return }
        let wait = at.timeIntervalSince(parts.now())
        let sleep = parts.sleep
        timer = Task { [weak self] in
            await sleep(wait)
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            self.offer(.wrote)
        }
    }
}

/// The system's session with the watch. Its callbacks arrive on a queue of the system's; each
/// is handed to the main actor, where the bridge lives.
@MainActor
final class WCSessionLink: NSObject, WatchLink {
    var onEvent: (@MainActor (WatchLinkEvent) -> Void)?
    private let session: WCSession?

    override init() {
        session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
    }

    var isSupported: Bool { session != nil }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    var isActivated: Bool { session?.activationState == .activated }
    var isPaired: Bool { session?.isPaired ?? false }
    var isWatchAppInstalled: Bool { session?.isWatchAppInstalled ?? false }
    var isComplicationEnabled: Bool { session?.isComplicationEnabled ?? false }
    var transfersLeft: Int { session?.remainingComplicationUserInfoTransfers ?? 0 }

    func update(context: [String: Any]) throws {
        try session?.updateApplicationContext(context)
    }

    func transferComplication(_ info: [String: Any]) {
        session?.transferCurrentComplicationUserInfo(info)
    }

    private nonisolated func send(_ event: WatchLinkEvent) {
        Task { @MainActor in self.onEvent?(event) }
    }
}

extension WCSessionLink: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if activationState == .activated { send(.activated) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) { send(.inactive) }
    nonisolated func sessionDidDeactivate(_ session: WCSession) { send(.deactivated) }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) { send(.watchChanged) }
}
