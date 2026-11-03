import ClaudistCore
import AppKit
import UserNotifications

/// macOS notifications for tasks that need the user. One notification per task: a newer
/// request replaces the older one, and answering removes it.
@MainActor
enum Notifications {
    private static var router: Router?

    /// Asks for permission and routes clicks to the task. Needs a bundle (not a bare `swift run`).
    static func setUp(store: AppStore) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let router = Router(store: store)
        self.router = router
        let center = UNUserNotificationCenter.current()
        center.delegate = router
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    static func post(taskId: ID, title: String, subtitle: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.userInfo = ["taskId": taskId]
        content.threadIdentifier = taskId
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier(taskId), content: content, trigger: nil))
    }

    static func clear(taskId: ID) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier(taskId)])
    }

    private static func identifier(_ taskId: ID) -> String { "needs-you-\(taskId)" }

    private final class Router: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
        weak var store: AppStore?

        init(store: AppStore) { self.store = store }

        /// Show banners even while Claudist is the active app.
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .list, .sound])
        }

        /// A click opens the task.
        func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                    withCompletionHandler completionHandler: @escaping () -> Void) {
            let taskId = response.notification.request.content.userInfo["taskId"] as? String
            DispatchQueue.main.async { [weak self] in
                if let taskId, let store = self?.store {
                    store.selectedTaskId = taskId
                    NSApp.activate(ignoringOtherApps: true)
                }
                completionHandler()
            }
        }
    }
}
