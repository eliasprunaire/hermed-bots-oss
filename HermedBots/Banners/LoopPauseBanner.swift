import LoopGuard
import SwiftUI

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
            Text("L'affichage et l'envoi sont suspendus. Hermes peut continuer sur le serveur. Utilisez « Tout arrêter » pour l'arrêter.")
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
