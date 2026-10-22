import SwiftUI

/// Le sélecteur de modèle de la session ouverte (`/model`, contrat `set_model`, S4) : il change le modèle de ce fil, jamais celui du profil
/// Il propose les modèles des bots actifs et celui du fil ; un nom que l'app ne connaît pas s'affiche tel que Hermes l'envoie
/// Le modèle montré ne change qu'à la confirmation de Hermes : pendant l'attente le sélecteur est grisé et le dit
/// Quand Hermes ne propose plus `set_model`, le sélecteur est grisé avec son message : le reste de la conversation marche
struct ModelPicker: View {
    let model: ConversationModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Modèle")
                picker
                if model.isModelPending {
                    ProgressView().controlSize(.small)
                    Text("Changement du modèle…").foregroundStyle(.secondary).accessibilityID(.modelWaiting)
                }
                Spacer(minLength: 0)
            }
            if case .disabled(let message) = model.modelSupport {
                Text(message).foregroundStyle(.secondary).lineLimit(3).accessibilityID(.modelDisabled)
            }
            if let error = model.modelError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(3).accessibilityID(.modelError)
            }
        }
        .font(.callout)
        // la sonde de `set_model` repart quand le bot ou l'hôte change ; une réponse déjà connue n'est pas redemandée
        .task(id: model.modelSupportTarget) { await model.checkModelSupport() }
    }

    private var picker: some View {
        Picker("Modèle", selection: selection) {
            // un fil sans modèle connu (profil sans modèle) a sa propre ligne, sinon la sélection n'aurait aucune étiquette
            if model.shownModel == nil { Text("Modèle du profil").tag("") }
            ForEach(model.modelOptions, id: \.self) { option in
                Text(option).tag(option).accessibilityIdentifier(AccessibilityID.modelOption(option))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .disabled(isDisabled)
        .accessibilityID(.modelPicker)
    }

    private var selection: Binding<String> {
        Binding(get: { model.shownModel ?? "" }, set: { model.pick(model: $0) })
    }

    private var isDisabled: Bool {
        if case .disabled = model.modelSupport { return true }
        return model.profileLockReason != nil || model.isModelPending
    }
}
