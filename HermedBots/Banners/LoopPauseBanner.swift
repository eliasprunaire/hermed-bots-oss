import LoopGuard
import HermesAdapter
import SwiftUI
import UserNotifications

struct LoopPauseBanner: View {
    let model: ConversationModel

    var body: some View {
        if model.pauseCause != nil || model.tokenSignal != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let cause = model.pauseCause {
                    Text("Boucle en pause : \(cause.message)").accessibilityID(.bannerLoopPause)
                    Text("L'affichage et l'envoi sont suspendus. Hermes peut continuer sur le serveur. Utilisez le kill switch pour l'arrêter.")
                    if let approval = model.pausedApproval {
                        Text("Approbation en attente sur Hermes : \(approval.request.tool ?? "inconnu"). La lecture suspendue empêche de répondre ici.")
                    }
                    Button("Fermer ce fil et ouvrir une nouvelle session") { model.closePausedThread() }
                        .accessibilityID(.loopClose)
                    #if DEBUG
                    if let time = model.pauseDecisionTime {
                        Color.clear.frame(width: 1, height: 1).accessibilityElement()
                            .accessibilityLabel(String(time)).accessibilityID(.perfLoopPause)
                    }
                    #endif
                    if let status = model.notificationStatus { Text(status).accessibilityID(.loopNotification) }
                }
                if let thresholds = model.loopThresholds {
                    switch thresholds.basis {
                    case .coldStart(let turns): Text("Garde non calibré : \(turns)/20 tours observés pour ce bot.")
                    case .history(let turns): Text("Garde fondé sur \(turns) tours observés pour ce bot. Seuils non mesurés.")
                    }
                }
                if case .disabled? = model.tokenSignal {
                    Text("Signal des tokens désactivé : Hermes ne fournit aucun relevé dans le flux.")
                        .foregroundStyle(.secondary)
                        .accessibilityID(.loopTokens)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(model.pauseCause == nil ? Color.clear : .orange.opacity(0.12))
        }
    }
}

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
