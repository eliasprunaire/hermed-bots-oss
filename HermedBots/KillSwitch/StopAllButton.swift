import SwiftUI

/// Le kill switch : un bouton rouge ; son infobulle porte ce que Hermes a confirmé ou ce qui reste à faire à la main
/// Dans la barre d'outils il reste visible quand la barre latérale est masquée ; dans la feuille d'approbation il porte aussi son statut écrit
struct StopAllButton: View {
    let model: KillSwitch
    var inApproval = false

    var body: some View {
        if inApproval {
            VStack(alignment: .leading, spacing: 6) {
                button.frame(maxWidth: .infinity).controlSize(.large)
                StopAllStatus(model: model, inApproval: true)
            }
        } else {
            button
        }
    }

    private var button: some View {
        Button(role: .destructive) { Task { await model.stopAll() } } label: {
            Label("Tout arrêter", systemImage: "stop.circle.fill")
                .fontWeight(.semibold)
                .frame(maxWidth: inApproval ? .infinity : nil)
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(.glass)
        .tint(.red)
        .help(model.message)
        .accessibilityID(inApproval ? .approvalStopAll : .stopAll)
        .disabled(model.isDisabled)
    }
}

/// Ce que Hermes a confirmé de l'arrêt, ou ce qui reste à faire à la main ; rien au repos
struct StopAllStatus: View {
    let model: KillSwitch
    var inApproval = false

    var body: some View {
        if !model.message.isEmpty {
            Text(model.message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityID(inApproval ? .approvalStopStatus : .stopAllStatus)
        }
    }
}
