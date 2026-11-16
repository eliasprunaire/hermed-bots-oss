import LoopGuard
import UserNotifications

final class LoopPauseNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = LoopPauseNotifications()
    /// Mode test : texte d'autorisation distinct de `AppEnvironment.testPauseNotification`, sans `UNUserNotificationCenter`
    static let testAuthorizationGranted = "Autorisation des notifications : accordée (faux déterministe)."

    func post(cause: LoopGuard.Cause) async -> String {
        #if DEBUG
        if ProcessInfo.processInfo.environment["HV_TEST_MODE"] == "1" {
            return Self.testAuthorizationGranted
        }
        #endif
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else {
                return "Notification désactivée dans les réglages de macOS."
            }
            let content = UNMutableNotificationContent()
            content.title = "Hermed Bots : boucle en pause"
            content.body = cause.message
            content.sound = .default
            let id = UUID().uuidString
            try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            for _ in 0..<20 {
                if await center.deliveredNotifications().contains(where: { $0.request.identifier == id }) {
                    return "Notification remise par macOS."
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            return "Notification envoyée. La remise reste à confirmer."
        } catch {
            let failure = error as NSError
            #if DEBUG
            print("HV-NOTIFICATION-ERROR domain=\(failure.domain) code=\(failure.code)")
            #endif
            if failure.domain == UNErrorDomain, failure.code == UNError.Code.notificationsNotAllowed.rawValue {
                return "Notification désactivée dans les réglages de macOS."
            }
            return "La notification n'a pas pu être envoyée. Vérifiez les réglages de macOS."
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
