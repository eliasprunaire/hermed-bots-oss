import SwiftUI

/// Le champ de saisie et le bouton Envoyer
/// Envoyer est grisé pour un brouillon vide ou fait de blancs, et pendant un tour ; ⏎ passe par la même garde que le bouton
struct ComposerView: View {
    @Bindable var model: ConversationModel

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message", text: $model.draft, axis: .vertical)
                .lineLimit(1...6)
                .textFieldStyle(.roundedBorder)
                .onSubmit(model.send)
                .accessibilityID(.composerInput)
            Button("Envoyer", action: model.send)
                .disabled(!model.canSend)
                .accessibilityID(.composerSend)
        }
        .padding(10)
    }
}
