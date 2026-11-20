import Foundation
import GlanceModel
import UserNotifications

/// Enter and Interrupt on a question's notification: the names iOS knows them by, and how the
/// payload of the push becomes the wait an action answers (docs/notifications.md, Answering
/// from a notification). Pure.
enum PushAction {
    /// The category of a question whose push names its wait (`record`, `fp`). Only this one
    /// has the actions: a push from a Beacon that names no wait is `plain` and shows none.
    static let category = "AGENT_BLOCKED_ACT"
    /// A question without actions: from an earlier Beacon, or one whose action typed nothing.
    static let plain = "AGENT_BLOCKED"

    static func identifier(_ kind: WatchAction.Kind) -> String {
        switch kind {
        case .enter: "ENTER"
        case .interrupt: "INTERRUPT"
        }
    }

    /// Nil for anything that is no action of ours: the tap on the notification itself, its
    /// dismissal, an action of a later version.
    static func kind(_ identifier: String) -> WatchAction.Kind? {
        WatchAction.Kind.allCases.first { self.identifier($0) == identifier }
    }

    /// One of the app's servers, as far as a push is matched against it.
    struct Server: Equatable, Sendable {
        /// `ServerConnection.id`, as `WatchAction.Target.server` holds it.
        var id: String
        var url: String
        var hostName: String?
    }

    /// The wait a push names, on the server it came from. Nil when the payload names no wait
    /// (no session, pane, record or fingerprint), when its server is not one of the app's,
    /// and when its address fits more than one of them: an action never guesses where to type.
    static func target(_ info: [String: String], servers: [Server]) -> WatchAction.Target? {
        func text(_ key: String) -> String? { info[key].flatMap { $0.isEmpty ? nil : $0 } }
        guard let address = text("server"), let session = text("session_id"), let block = text("block_id"),
              let record = text("record"), let fp = text("fp") else { return nil }
        let route = PushRoute(server: address, sessionID: session)
        let from = servers.filter { route.matches(serverURL: $0.url, hostName: $0.hostName) }
        guard from.count == 1 else { return nil }
        return WatchAction.Target(server: from[0].id, session: session, block: block, record: record, fp: fp)
    }

    /// Names one tap on one delivered notification, so a tap that reaches the app twice types
    /// once (`GlanceActions` answers a known id from memory). The request's identifier alone
    /// would not do: it is the push's collapse id, which a pane's next question from the same
    /// status record has again, and that question's tap must be typed. The time the
    /// notification was delivered tells the two apart.
    static func actionID(request: String, delivered: Date, kind: WatchAction.Kind) -> String {
        "\(request)|\(Int64((delivered.timeIntervalSince1970 * 1000).rounded()))|\(kind.rawValue)"
    }

    /// The payload's own fields: every string at its top level. `aps` is the system's part
    /// and is left out.
    static func fields(_ userInfo: [AnyHashable: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (key, value) in userInfo {
            if let key = key as? String, let value = value as? String { out[key] = value }
        }
        return out
    }

    /// What becomes of the notification once the action has ended.
    enum Outcome: Equatable, Sendable {
        /// Typed: the notification is done with.
        case remove
        /// Not typed: the notification comes back, saying this.
        case replace(String)
        /// The same tap again: the first one decides what the notification becomes.
        case leave
    }

    /// Nil: no answer at all (no app model in time, a payload that names no wait, a server
    /// that is not the app's or not one alone, the system's time ran out).
    static func outcome(_ answer: GlanceActions.Answer?) -> Outcome {
        switch answer {
        case .repeated: .leave
        // The wait was answered a moment ago, from the watch or another notification, so
        // nothing was typed. It is never removed for that: an agent can ask the very same
        // question again within the hold, and that alert must not be lost.
        case .answered: .replace(NotificationCopy.actionAnswered)
        case .fresh(.sent): .remove
        case .fresh(.changed): .replace(NotificationCopy.actionChanged)
        // Not confirmed: it may have been typed, and only the pane can say.
        case .fresh(.unreachable), .fresh(.unconfirmed), nil: .replace(NotificationCopy.actionFailed)
        }
    }
}

/// What iOS hands over when a notification's action is tapped, as far as the app reads it.
struct PushActionResponse: Equatable, Sendable {
    /// The action's identifier.
    var action: String
    /// The notification's request identifier, which removes or replaces it.
    var request: String
    /// When the notification was delivered.
    var delivered: Date
    var title: String
    var subtitle: String
    var thread: String
    /// `PushAction.fields` of the payload.
    var info: [String: String]

    init(action: String, request: String, delivered: Date, title: String = "", subtitle: String = "", thread: String = "",
         info: [String: String]) {
        self.action = action
        self.request = request
        self.delivered = delivered
        self.title = title
        self.subtitle = subtitle
        self.thread = thread
        self.info = info
    }

    init(_ response: UNNotificationResponse) {
        let request = response.notification.request
        self.init(action: response.actionIdentifier, request: request.identifier, delivered: response.notification.date,
                  title: request.content.title, subtitle: request.content.subtitle, thread: request.content.threadIdentifier,
                  info: PushAction.fields(request.content.userInfo))
    }
}

/// Answers Enter or Interrupt tapped on a question's notification. It builds the same
/// `WatchAction` the watch sends and hands it to `GlanceActions`, so the same guard decides:
/// the status is read, and one write goes out only while the pane still shows that wait.
///
/// - Typed: the delivered notification is removed.
/// - Not typed, for any reason, one of them that another action answered the same wait a
///   moment ago: the notification is put back under the same identifier, so it is never
///   lost: passive, without a sound and without actions, with the payload's fields, so a tap
///   opens the pane. Its text says why.
/// - The same tap delivered again: nothing, the first one decides.
///
/// It asks, plays and shows nothing else. Every wait has a limit: the app's model after a
/// launch in the background (`modelLimit`), the action itself (`GlanceActions`), and the
/// write to Notification Center (`centerLimit`). When the system's time for the background
/// runs out first, the action ends inside that moment: the notification is put back and iOS
/// is told before the background task ends, and nothing is typed from then on.
@MainActor
final class NotificationActions {
    /// What it needs of Notification Center, so tests can stand in for it.
    @MainActor
    struct Center {
        var remove: @MainActor ([String]) -> Void
        /// Puts the notification back, and returns once Notification Center has it.
        var replace: @MainActor (Replacement) async -> Void
        /// The same, handed over and not waited for: for the moment the system's time ends.
        var post: @MainActor (Replacement) -> Void

        static let live = Center(
            remove: { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: $0) },
            replace: { replacement in
                let request = UNNotificationRequest(identifier: replacement.identifier, content: replacement.content, trigger: nil)
                try? await UNUserNotificationCenter.current().add(request)
            },
            post: { replacement in
                let request = UNNotificationRequest(identifier: replacement.identifier, content: replacement.content, trigger: nil)
                UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
            })
    }

    /// The notification that takes the place of one whose action typed nothing.
    struct Replacement: Equatable, Sendable {
        var identifier: String
        var title: String
        var subtitle: String
        var body: String
        var thread: String
        var info: [String: String]

        /// Quiet, and without actions: it only says what happened and opens the pane.
        var content: UNNotificationContent {
            let c = UNMutableNotificationContent()
            c.title = title
            c.subtitle = subtitle
            c.body = body
            c.threadIdentifier = thread
            c.categoryIdentifier = PushAction.plain
            c.userInfo = info
            c.interruptionLevel = .passive
            c.sound = nil
            return c
        }
    }

    /// What it needs of the app: its servers, and the one place that types for an action.
    /// `handle`'s second argument is asked right before the write: false types nothing.
    @MainActor
    struct Model {
        var servers: @MainActor () -> [PushAction.Server]
        var handle: @MainActor (WatchAction, @escaping @MainActor () -> Bool) async -> GlanceActions.Answer
    }

    /// One action's end: what became of the notification is decided once, and iOS is told once.
    @MainActor
    private final class Job {
        private var settled = false
        private var handled: (@MainActor () -> Void)?

        init(_ handled: @escaping @MainActor () -> Void) {
            self.handled = handled
        }

        /// True for the one caller that may decide what the notification becomes.
        func settle() -> Bool {
            guard !settled else { return false }
            settled = true
            return true
        }

        func tell() {
            let h = handled
            handled = nil
            h?()
        }
    }

    /// The system's time for one action: whether it ran out, and what waits to hear of it.
    @MainActor
    private final class Expiry {
        private(set) var expired = false
        private var heard: (@MainActor () -> Void)?

        func expire() {
            expired = true
            let h = heard
            heard = nil
            h?()
        }

        /// `hear` runs once, when the time runs out, or now if it has.
        func onExpire(_ hear: @escaping @MainActor () -> Void) {
            if expired { hear() } else { heard = hear }
        }
    }

    struct Parts {
        var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64(max($0, 0) * 1_000_000_000)) }
        /// The longest to wait for the app's model, after the system launched the app in the
        /// background for the action.
        var modelLimit: TimeInterval = 5
        /// The longest to wait for Notification Center to take the replacement.
        var centerLimit: TimeInterval = 2
    }

    private let center: Center
    private let parts: Parts
    /// Takes the system's time for a job in the background, and gives back how to end it.
    /// Its argument runs if that time runs out first.
    private let background: @MainActor (@escaping @MainActor () -> Void) -> @MainActor () -> Void
    private var model: Model?
    private var waiting: [CheckedContinuation<Model?, Never>] = []

    init(center: Center = .live, parts: Parts = Parts(),
         background: @escaping @MainActor (@escaping @MainActor () -> Void) -> @MainActor () -> Void = { expired in
             let task = BackgroundTask(name: "notification_action", expired: expired)
             return { task.end() }
         }) {
        self.center = center
        self.parts = parts
        self.background = background
    }

    /// Whether the app's model is there.
    var isAttached: Bool { model != nil }

    /// The app's model is there. Actions that waited for it go on.
    func attach(_ model: Model) {
        self.model = model
        let waiting = waiting
        self.waiting = []
        for w in waiting { w.resume(returning: model) }
    }

    /// One tapped action, from the tap to what the notification becomes. `handled` tells iOS
    /// the response was handled: it is called once, when all of it has ended, or in the
    /// moment the system's time for the background runs out, whichever is first.
    func handle(_ response: PushActionResponse, handled: @escaping @MainActor () -> Void = {}) async {
        guard let kind = PushAction.kind(response.action) else { return handled() }
        func replacement(_ words: String) -> Replacement {
            Replacement(identifier: response.request, title: response.title, subtitle: response.subtitle,
                        body: words, thread: response.thread, info: response.info)
        }
        let job = Job(handled)
        let expiry = Expiry()
        // The app may be in the background, or launched there for this. When that time runs
        // out the task ends as soon as this closure returns, so everything left is done in
        // it: the notification is put back, not waited for, and iOS is told.
        let end = background { [center] in
            if job.settle() { center.post(replacement(NotificationCopy.actionFailed)) }
            job.tell()
            expiry.expire()
        }
        defer {
            end()
            job.tell()
        }
        let answer = await run(kind, response, until: expiry)
        guard job.settle() else { return }
        switch PushAction.outcome(answer) {
        case .leave:
            break
        case .remove:
            center.remove([response.request])
        case .replace(let words):
            let replacement = replacement(words)
            let replace = center.replace
            _ = await within(parts.centerLimit) {
                await replace(replacement)
                return true
            }
        }
    }

    /// The action's answer, or nil when there is none or the system's time ran out first.
    /// A run the time ran out on goes on to its own limits by itself and types nothing: the
    /// write asks `expiry` first.
    private func run(_ kind: WatchAction.Kind, _ response: PushActionResponse, until expiry: Expiry) async -> GlanceActions.Answer? {
        let race = Race()
        return await withCheckedContinuation { (done: CheckedContinuation<GlanceActions.Answer?, Never>) in
            expiry.onExpire {
                guard !race.over else { return }
                race.over = true
                done.resume(returning: nil)
            }
            Task { @MainActor [weak self] in
                let result = await self?.answer(kind, response, expiry)
                guard !race.over else { return }
                race.over = true
                done.resume(returning: result)
            }
        }
    }

    private func answer(_ kind: WatchAction.Kind, _ response: PushActionResponse, _ expiry: Expiry) async -> GlanceActions.Answer? {
        guard let model = await attached() else { return nil }
        guard let target = PushAction.target(response.info, servers: model.servers()) else { return nil }
        let id = PushAction.actionID(request: response.request, delivered: response.delivered, kind: kind)
        return await model.handle(WatchAction(id: id, kind: kind, target: target)) { !expiry.expired }
    }

    /// The app's model, waited for `modelLimit` at most. Nil when it never came.
    private func attached() async -> Model? {
        if let model { return model }
        return await within(parts.modelLimit) { [weak self] in
            await withCheckedContinuation { (c: CheckedContinuation<Model?, Never>) in
                guard let self else { return c.resume(returning: nil) }
                if let model = self.model { return c.resume(returning: model) }
                self.waiting.append(c)
            }
        }
    }

    /// Which of the work and the limit ended first. Used on the main actor only.
    @MainActor
    private final class Race {
        var over = false
    }

    /// `work`'s value, or nil when it took longer than `limit`. `work` goes on by itself then;
    /// what it gives is dropped.
    private func within<T>(_ limit: TimeInterval, _ work: @escaping @MainActor () async -> T?) async -> T? {
        let race = Race()
        let sleep = parts.sleep
        return await withCheckedContinuation { (done: CheckedContinuation<T?, Never>) in
            Task { @MainActor in
                let value = await work()
                guard !race.over else { return }
                race.over = true
                done.resume(returning: value)
            }
            Task { @MainActor in
                await sleep(limit)
                guard !race.over else { return }
                race.over = true
                done.resume(returning: nil)
            }
        }
    }
}
