import AppKit
import ClaudeMonitorCore
import UserNotifications

/// Posts macOS notifications and reports clicks. Needs the .app bundle
/// (UNUserNotificationCenter refuses to work for an unbundled binary).
final class Notifier: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let sessionIdKey = "session_id"

    private let log: AppLog
    private let onOpen: @MainActor (String) -> Void
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    init(log: AppLog, onOpen: @escaping @MainActor (String) -> Void) {
        self.log = log
        self.onOpen = onOpen
        super.init()
    }

    /// Call once the app has finished launching: an authorization request made
    /// earlier (from App.init) is refused with "not allowed" and never prompts.
    func start() {
        guard let center else {
            log.log("notifications unavailable: not running from the .app bundle")
            return
        }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { [log] granted, error in
            if let error { log.log("notification authorization failed: \(error)") }
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                log.log("notifications: granted=\(granted) status=\(settings.authorizationStatus.rawValue)")
            }
        }
    }

    func post(_ session: Session) {
        guard let center else { return }
        let text = NotificationPolicy.content(for: session)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.body = text.body
        content.sound = .default
        content.threadIdentifier = session.id
        content.userInfo = [Self.sessionIdKey: session.id]
        // One per session+state: a newer one replaces an older one instead of stacking.
        let request = UNNotificationRequest(identifier: "\(session.id).\(session.state.rawValue)",
                                            content: content, trigger: nil)
        let label = "\(session.id) \(session.state.rawValue)"
        center.add(request) { [log] error in
            log.log(error.map { "notification failed (\(label)): \($0)" } ?? "notified: \(label)")
        }
    }

    /// Removes delivered notifications for a session once it has been dealt with.
    func clear(sessionId: String) {
        center?.removeDeliveredNotifications(
            withIdentifiers: NotificationPolicy.notifyingStates.map { "\(sessionId).\($0.rawValue)" })
    }

    // Menu-bar apps count as "foreground": show banners anyway.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo[Self.sessionIdKey] as? String
        log.log("notification clicked: \(id ?? "no session id") action=\(response.actionIdentifier)")
        let onOpen = onOpen
        if let id { Task { @MainActor in onOpen(id) } }
        completionHandler()
    }
}
