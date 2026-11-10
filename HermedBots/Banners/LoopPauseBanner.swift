import LoopGuard
import SwiftUI
import UserNotifications

struct LoopPauseBanner: View {
    let notice: LoopNotice?
    let close: () -> Void
    #if DEBUG
    let pauseDecisionTime: TimeInterval?
    #endif

    var body: some View {
        if let notice {
            VStack(alignment: .leading, spacing: 8) {
                switch notice {
                case .tokensDisabled:
                    tokenCaption
                case .paused(let pause):
                    pauseCard(pause)
                case .pausedAndTokensDisabled(let pause):
                    pauseCard(pause)
                    tokenCaption
                }
            }
            .column()
            .padding(.bottom, 8)
        }
    }

    private var tokenCaption: some View {
        Text(LoopNotice.tokensDisabledCaption)
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityID(.loopTokens)
    }

    private func pauseCard(_ pause: LoopNotice.Pause) -> some View {
        NoticeCard(tint: .orange, symbol: "pause.circle.fill") {
            Text(pause.title).fontWeight(.semibold).accessibilityID(.bannerLoopPause)
            Text("L'affichage et l'envoi sont suspendus. Hermes peut continuer sur le serveur. Utilisez le kill switch pour l'arrêter.")
            if let approval = pause.approval {
                Text(approval)
            }
            Button("Fermer ce fil et ouvrir une nouvelle session") { close() }
                .buttonStyle(.glass)
                .accessibilityID(.loopClose)
            #if DEBUG
            if let time = pauseDecisionTime {
                Color.clear.frame(width: 1, height: 1).accessibilityElement()
                    .accessibilityLabel(String(time)).accessibilityID(.perfLoopPause)
            }
            #endif
            if let status = pause.notification {
                Text(status).foregroundStyle(.secondary).accessibilityID(.loopNotification)
            }
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
