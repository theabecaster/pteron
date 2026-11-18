import UIKit
import UserNotifications

/// APNs token callbacks and push taps. SwiftUI creates it before the app's first view, so it sets
/// the notification delegate early enough to receive the tap that cold-launched the app; that tap
/// waits here until the app hands over its model.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    /// The helper's push categories (docs/notifications.md). No actions: a tap opens the pane.
    static let categories = ["AGENT_BLOCKED", "AGENT_DONE", "NOTICE"]

    private weak var model: AppModel?
    private var notifications: NotificationDelegate?
    private var pendingRoute: PushRoute?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let n = NotificationDelegate { [weak self] route in
            Task { @MainActor in self?.open(route) }
        }
        notifications = n
        let center = UNUserNotificationCenter.current()
        center.delegate = n
        center.setNotificationCategories(Set(Self.categories.map {
            UNNotificationCategory(identifier: $0, actions: [], intentIdentifiers: [], options: [])
        }))
        return true
    }

    /// The app is on screen: start push registration and open a pane a push asked for.
    func attach(_ model: AppModel) {
        guard self.model !== model else { return }
        self.model = model
        model.push.start()
        if let r = pendingRoute {
            pendingRoute = nil
            open(r)
        }
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

/// While the app is in front it shows no system notifications (agents that need the user get a
/// toast instead), except the one "Send Test Notification" asks for, which is there to be seen; a
/// tapped push opens its pane. It holds only a Sendable closure, so iOS may call it on any queue.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let onOpen: @Sendable (PushRoute) -> Void

    init(onOpen: @escaping @Sendable (PushRoute) -> Void) {
        self.onOpen = onOpen
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let test = PushTest.isTest(threadID: notification.request.content.threadIdentifier)
        completionHandler(test ? [.banner, .list, .sound] : [])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let route = PushRoute(userInfo: response.notification.request.content.userInfo) {
            onOpen(route)
        }
        completionHandler()
    }
}
