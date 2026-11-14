import SwiftUI

/// La barre latérale : les bots actifs seulement, un chat unique par bot
struct BotListView: View {
    let model: BotsModel
    let profileLock: ProfileLock
    /// Le bot ouvert dans la conversation, s'il est dans la liste
    let selectedBot: String?
    let activity: (String) -> ConversationMachine.Activity
    /// Un clic sur un bot ouvre son fil unique
    let select: (String) -> Void

    var body: some View {
        List {
            if let change = model.list.change {
                BotChangeNotice(change: change, apply: model.validateChange)
            }
            ForEach(model.list.shown ?? []) { bot in
                BotRow(bot: bot, isSelected: bot.id == selectedBot, activity: activity(bot.id), lockLabel: profileLock.sidebarLabel(bot.id), lockHelp: profileLock.reason(bot.id)) {
                    select(bot.id)
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
        case .failed:
            Text(BotsModel.listUnavailableMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .accessibilityID(.botsError)
                .padding()
        case .toolNotFound(let message):
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

/// Une ligne de bot : son avatar, son nom et son modèle ; un clic ouvre le fil unique ; un nom trop long est coupé avant la pastille, le nom entier reste dans l'infobulle
/// Pas de `Button` : un bouton fusionne ses enfants et `.name` et `.model` perdraient leur identifiant ; l'action par défaut garde la ligne utilisable au clavier d'accessibilité
struct BotRow: View {
    let bot: Bot
    let isSelected: Bool
    let activity: ConversationMachine.Activity
    let lockLabel: String?
    let lockHelp: String?
    let toggle: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 9) {
            BotAvatar(bot: bot, size: 28, activity: activity)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: BotLockPill.nameSpacing) {
                    Text(bot.name)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier(AccessibilityID.botName(bot.id))
                    if let lockLabel {
                        BotLockPill(label: lockLabel, help: lockHelp ?? lockLabel, accessibilityID: AccessibilityID.botLock(bot.id))
                    }
                }
                if let model = bot.model {
                    Text(model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .accessibilityIdentifier(AccessibilityID.botModel(bot.id))
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
        .padding(.leading, 6)
        .padding(.trailing, BotLockPill.sidebarTrailing)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10).fill(Palette.gradient(Palette.colors(bot)).opacity(0.16))
            } else if hovered {
                RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.05))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
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
        // sans icône ni grandes marges : la barre latérale est étroite et le titre comme le bouton doivent tenir en entier
        VStack(alignment: .leading, spacing: 6) {
            Text("La liste des bots a changé").fontWeight(.semibold).lineLimit(2).accessibilityID(.botsChange)
            if !change.added.isEmpty {
                Text("Ajouté : \(change.added.joined(separator: ", "))").lineLimit(2).truncationMode(.tail)
            }
            if !change.removed.isEmpty {
                Text("Retiré : \(change.removed.joined(separator: ", "))").lineLimit(2).truncationMode(.tail)
            }
            Button("Afficher la nouvelle liste", action: apply).accessibilityID(.botsChangeApply)
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.1), in: .rect(cornerRadius: 12))
        .padding(.vertical, 4)
    }
}
