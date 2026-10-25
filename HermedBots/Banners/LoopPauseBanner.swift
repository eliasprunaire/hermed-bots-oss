import LoopGuard
import HermesAdapter
import SwiftUI

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
