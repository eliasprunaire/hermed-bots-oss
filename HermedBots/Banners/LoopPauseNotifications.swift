import Foundation
import LoopGuard
import UserNotifications

extension LoopGuard.Cause {
    var message: String {
        switch self {
        case .repeatedToolCall(let count): "Appel d'outil répété \(count) fois."
        case .toolCount(let count, let limit): "\(count) appels d'outils dépassent la limite de \(limit)."
        case .tokens(let total, let limit): "\(total) tokens dépassent la limite de \(limit)."
        case .silence(let seconds, let limit): "Silence de \(seconds) secondes au-delà de \(limit)."
        }
    }
}

final class LoopPauseNotifications: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = LoopPauseNotifications()

    func post(cause: LoopGuard.Cause) async -> String {
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
