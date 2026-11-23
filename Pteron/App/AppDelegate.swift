import GlanceModel
import UIKit
import UserNotifications

/// APNs token callbacks, push taps and the actions of a question's push. SwiftUI creates it
/// before the app's first view, so it sets the notification delegate early enough to receive
/// the tap that cold-launched the app; that tap waits here until the app hands over its model,
/// and an action waits for it in `NotificationActions`, for a limited time.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The helper's push categories without actions (docs/notifications.md): a tap opens the
    /// pane. A question from a Beacon that names no wait is one of them.
    static let categories = [PushAction.plain, "AGENT_DONE", "NOTICE"]

    /// Every category the app registers: the ones above, and a question that names its wait,
    /// with Enter and Interrupt in the watch's words. Both ask for the unlocked phone, since
    /// they type into a terminal. iOS shows them when the notification is expanded.
    static var notificationCategories: Set<UNNotificationCategory> {
        let actions = WatchAction.Kind.allCases.map { kind in
            UNNotificationAction(identifier: PushAction.identifier(kind), title: WatchText.title(kind),
                                 options: kind == .interrupt ? [.authenticationRequired, .destructive] : [.authenticationRequired])
        }
        var all = Set(categories.map { UNNotificationCategory(identifier: $0, actions: [], intentIdentifiers: [], options: []) })
        all.insert(UNNotificationCategory(identifier: PushAction.category, actions: actions, intentIdentifiers: [], options: []))
        return all
    }

    private weak var model: AppModel?
    private var notifications: NotificationDelegate?
    private var pendingRoute: PushRoute?
    private let actions = NotificationActions()

    /// The model `PteronApp.init` made, handed over through this one slot. It exists because
    /// SwiftUI builds the `App` value before this delegate exists, so `init` has no delegate
    /// to give the model to, and it is left here for `didFinishLaunching` to take. It is how a
    /// launch with no scene (the system started the app in the background for an action,
    /// after the app was swiped away) still has a model to answer with: no view ever appears
    /// to hand one over. The slot is weak, so it keeps no model alive (the app's `@State`
    /// owns it), and it is set once, by `launching(with:)` in the app's `init`. Nothing else
    /// reads or writes it: it is a hand-over, not a way to reach the model.
    private static weak var launchModel: AppModel?

    /// Called once, by the app's `init`.
    static func launching(with model: AppModel) {
        launchModel = model
    }

    /// Whether an action on a notification has a model to answer with.
    var answersActions: Bool { actions.isAttached }

    /// Gives the model of this launch to the actions. It starts nothing: no server, no push
    /// registration. Those wait for the app to be on screen (`attach`).
    func takeLaunchModel() {
        if let model = Self.launchModel { attachActions(model) }
    }

    private func attachActions(_ model: AppModel) {
        actions.attach(NotificationActions.Model(
            servers: { [weak model] in
                (model?.servers ?? []).map { PushAction.Server(id: $0.id.uuidString, url: $0.config.url, hostName: $0.hostName) }
            },
            handle: { [weak model] action, mayWrite in
                // No model any more: nothing was typed.
                guard let model else { return .fresh(.unreachable) }
                return await model.actions.take(action, mayWrite: mayWrite)
            }))
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let n = NotificationDelegate(onOpen: { [weak self] route in
            Task { @MainActor in self?.open(route) }
        }, onAction: { [weak self] response, done in
            Task { @MainActor in
                guard let self else { return done() }
                await self.actions.handle(response) { done() }
            }
        })
        notifications = n
        let center = UNUserNotificationCenter.current()
        center.delegate = n
        center.setNotificationCategories(Self.notificationCategories)
        takeLaunchModel()
        return true
    }

    /// The app is on screen: start push registration, open a pane a push asked for, and let a
    /// link that arrived first run.
    func attach(_ model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
        attachActions(model)
        model.push.start()
        if let r = pendingRoute {
            pendingRoute = nil
            open(r)
        }
        model.releaseLinks()
    }

    private func open(_ route: PushRoute) {
        guard let model else { pendingRoute = route; return }
        Task { await model.open(route) }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        model?.push.tokenReceived(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        model?.push.tokenFailed(error)
    }
}

/// What the app shows of a notification that arrives while it is in front.
enum PushPresentation {
    /// Nothing: agents that need the person get a toast instead. Two exceptions. The one
    /// "Send Test Notification" asks for is there to be seen. And a notification the app made
    /// itself, which is only ever the one that takes the place of a question whose action
    /// typed nothing (`NotificationActions`), goes into the list without a banner or a sound,
    /// or it would be lost.
    static func options(test: Bool, local: Bool) -> UNNotificationPresentationOptions {
        if test { return [.banner, .list, .sound] }
        return local ? [.list] : []
    }
}

/// iOS's word that a response was handled. iOS lets it be called from any thread, and each
/// one is called exactly once, by the one task it is handed to.
struct ResponseHandled: @unchecked Sendable {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func callAsFunction() {
        handler()
    }
}

/// While the app is in front it shows no system notifications (`PushPresentation`); a tapped
/// push opens its pane, and a tapped action is handed on with iOS's completion handler, which
/// is called once the action has ended. It holds only Sendable closures, so iOS may call it on
/// any queue.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let onOpen: @Sendable (PushRoute) -> Void
    private let onAction: @Sendable (PushActionResponse, ResponseHandled) -> Void

    init(onOpen: @escaping @Sendable (PushRoute) -> Void,
         onAction: @escaping @Sendable (PushActionResponse, ResponseHandled) -> Void) {
        self.onOpen = onOpen
        self.onAction = onAction
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let test = PushTest.isTest(threadID: notification.request.content.threadIdentifier)
        let local = !(notification.request.trigger is UNPushNotificationTrigger)
        completionHandler(PushPresentation.options(test: test, local: local))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if PushAction.kind(response.actionIdentifier) != nil {
            // Handled only once the action has ended: until then iOS keeps the app running.
            onAction(PushActionResponse(response), ResponseHandled(completionHandler))
            return
        }
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let route = PushRoute(userInfo: response.notification.request.content.userInfo) {
            onOpen(route)
        }
        completionHandler()
    }
}
