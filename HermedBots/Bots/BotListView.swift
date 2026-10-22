import SwiftUI

/// La barre latérale : les bots actifs, chacun dépliable sur ses fils passés
struct BotListView: View {
    let model: BotsModel
    let profileLock: ProfileLock
    /// Le fil ouvert dans la conversation, s'il est dans la liste
    let selectedSession: String?
    /// Un clic sur un bot le choisit pour la conversation, en plus de le déplier
    let select: (String) -> Void
    /// Un clic sur un fil passé l'ouvre : le fil, puis son bot
    let open: (String, String) -> Void

    var body: some View {
        List {
            if let change = model.list.change {
                BotChangeNotice(change: change, apply: model.validateChange)
            }
            ForEach(model.list.shown ?? []) { bot in
                BotRow(bot: bot, isExpanded: model.expanded.contains(bot.id), lockReason: profileLock.state(bot.id).reason) {
                    if profileLock.state(bot.id) == .free { model.toggle(bot.id) }
                    select(bot.id)
                }
                if model.expanded.contains(bot.id) {
                    ThreadsView(botID: bot.id, state: model.threads[bot.id], selected: selectedSession) { open($0, bot.id) }
                }
            }
        }
        // l'identifiant se pose avant l'overlay : sinon les textes de l'overlay le portent aussi
        .accessibilityID(.botsList)
        .overlay { placeholder }
    }

    @ViewBuilder private var placeholder: some View {
        switch model.phase {
        case .loading where model.list.shown == nil:
            ProgressView().controlSize(.small)
        case .failed(let message):
            VStack(spacing: 8) {
                Text("La liste des bots n'a pas pu être lue : \(message)").multilineTextAlignment(.center).accessibilityID(.botsError)
                Button("Réessayer") { Task { await model.refresh() } }.accessibilityID(.botsRetry)
            }
            .padding()
        default:
            if model.list.shown?.isEmpty ?? true {
                VStack(spacing: 4) {
                    Text("Aucun bot").accessibilityID(.botsEmpty)
                    if model.phase == .ready { Text("Hermes ne liste aucun profil actif.") }
                }
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
    }
}

/// Une ligne de bot : un clic la déplie ; un nom ou un modèle trop long est coupé en fin de ligne, le nom entier reste dans l'infobulle
/// Pas de `Button` : un bouton fusionne ses enfants et `.name` et `.model` perdraient leur identifiant ; l'action par défaut garde la ligne utilisable au clavier d'accessibilité
struct BotRow: View {
    let bot: Bot
    let isExpanded: Bool
    let lockReason: String?
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(.secondary)
                .frame(width: 12)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(bot.name)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier(AccessibilityID.botName(bot.id))
                if let model = bot.model {
                    Text(model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier(AccessibilityID.botModel(bot.id))
                }
            }
            if let lockReason {
                Text(lockReason)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier(AccessibilityID.botLock(bot.id))
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .help(bot.name)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.botRow(bot.id))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, toggle)
    }
}

/// Le changement de liste trouvé en route : rien ne change à l'écran avant le clic
struct BotChangeNotice: View {
    let change: BotList.Change
    let apply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("La liste des bots a changé").fontWeight(.semibold).accessibilityID(.botsChange)
            if !change.added.isEmpty {
                Text("Ajouté : \(change.added.joined(separator: ", "))").lineLimit(2).truncationMode(.tail)
            }
            if !change.removed.isEmpty {
                Text("Retiré : \(change.removed.joined(separator: ", "))").lineLimit(2).truncationMode(.tail)
            }
            Button("Afficher la nouvelle liste", action: apply).accessibilityID(.botsChangeApply)
        }
        .font(.callout)
        .padding(.vertical, 4)
    }
}
