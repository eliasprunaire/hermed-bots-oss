import HermesAdapter
import SwiftUI

/// Le champ de saisie et le bouton Envoyer, dans une capsule de verre qui flotte au-dessus du fil
/// Envoyer est grisé pour un brouillon vide ou fait de blancs, et pendant un tour ; ⏎ passe par la même garde que le bouton
struct ComposerView: View {
    @Bindable var model: ConversationModel
    let bot: Bot
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(model.openError == nil ? "Écrire à \(bot.name)…" : model.composerUnavailableText, text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...8)
                .focused($focused)
                .disabled(model.isOpening || model.openError != nil)
                .padding(.vertical, 7)
                .onSubmit(model.send)
                .accessibilityID(.composerInput)
            Button(action: model.send) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(model.canSend ? AnyShapeStyle(Palette.gradient(Palette.colors(bot))) : AnyShapeStyle(.quaternary), in: .circle)
            }
            .buttonStyle(PressStyle())
            .disabled(!model.canSend)
            .help("Envoyer")
            .accessibilityLabel("Envoyer")
            .accessibilityID(.composerSend)
        }
        .padding(.leading, 16)
        .padding(.trailing, 7)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .column()
        .padding(.top, 6)
        .padding(.bottom, 14)
        .onAppear { focused = true }
    }
}
