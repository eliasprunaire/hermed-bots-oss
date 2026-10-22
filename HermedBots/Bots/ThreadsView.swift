import HermesAdapter
import SwiftUI

/// Les fils passés d'un bot, sous sa ligne ; un clic rouvre le fil avec son transcript (HD-09)
struct ThreadsView: View {
    let botID: String
    let state: BotsModel.Threads?
    let selected: String?
    let open: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch state {
            case .none, .loading:
                ProgressView().controlSize(.small)
            case .loaded(let sessions) where sessions.isEmpty:
                Text("Aucun fil passé").foregroundStyle(.secondary).accessibilityIdentifier(AccessibilityID.threadsEmpty(botID))
            case .loaded(let sessions):
                ForEach(sessions, id: \.id) { session in
                    // un fil sans titre prend son identifiant
                    // pas de `Button` ni de trait bouton : la ligne reste un texte adressable par son identifiant, l'action par défaut la rend utilisable au clavier d'accessibilité
                    Text(session.title ?? session.id)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                        .background(session.id == selected ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 4))
                        .contentShape(Rectangle())
                        .onTapGesture { open(session.id) }
                        .help(session.title ?? session.id)
                        .accessibilityIdentifier(AccessibilityID.threadRow(session.id))
                        .accessibilityAction(.default) { open(session.id) }
                }
            case .disabled(let message):
                // la barre latérale coupe un texte à une ligne tant qu'aucune limite n'est donnée : un message passe à la ligne
                Text(message).foregroundStyle(.secondary).lineLimit(6).multilineTextAlignment(.leading).accessibilityIdentifier(AccessibilityID.threadsDisabled(botID))
            case .failed(let message):
                Text(message).foregroundStyle(.red).lineLimit(6).multilineTextAlignment(.leading).accessibilityIdentifier(AccessibilityID.threadsError(botID))
            }
        }
        .font(.callout)
        .padding(.leading, 20)
        // le groupe reste un élément à part : ses lignes gardent leur identifiant et ne prennent pas celui du groupe
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.botThreads(botID))
    }
}
