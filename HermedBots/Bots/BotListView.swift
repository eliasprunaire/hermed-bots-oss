import SwiftUI

/// La barre latérale : les bots actifs, chacun dépliable sur ses fils passés
struct BotListView: View {
    let model: BotsModel
    let profileLock: ProfileLock
    /// Le bot et le fil ouverts dans la conversation, s'ils sont dans la liste
    let selectedBot: String?
    let selectedSession: String?
    let activity: (String) -> ConversationMachine.Activity
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
                BotRow(bot: bot, isExpanded: model.expanded.contains(bot.id), isSelected: bot.id == selectedBot, activity: activity(bot.id), lockReason: profileLock.reason(bot.id)) {
                    if profileLock.state(bot.id) == .free { model.toggle(bot.id) }
                    select(bot.id)
                }
                if model.expanded.contains(bot.id) {
                    ThreadsView(botID: bot.id, tint: Palette.colors(bot)[0], state: model.threads[bot.id], selected: selectedSession) { open($0, bot.id) }
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
        case .failed(let message), .toolNotFound(let message):
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

/// Une ligne de bot : son avatar, son nom et son modèle ; un clic la déplie ; un nom ou un modèle trop long est coupé en fin de ligne, le nom entier reste dans l'infobulle
/// Pas de `Button` : un bouton fusionne ses enfants et `.name` et `.model` perdraient leur identifiant ; l'action par défaut garde la ligne utilisable au clavier d'accessibilité
struct BotRow: View {
    let bot: Bot
    let isExpanded: Bool
    let isSelected: Bool
    let activity: ConversationMachine.Activity
    let lockReason: String?
    let toggle: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 9) {
            BotAvatar(bot: bot, size: 28, activity: activity)
            VStack(alignment: .leading, spacing: 1) {
                Text(bot.name)
                    .fontWeight(isSelected ? .semibold : .regular)
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
                    // la cause d'une panne de la sonde peut tenir sur plusieurs lignes : la barre latérale en garde deux
                    .lineLimit(2)
                    .help(lockReason)
                    .accessibilityIdentifier(AccessibilityID.botLock(bot.id))
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .foregroundStyle(.tertiary)
                .opacity(isExpanded || hovered ? 1 : 0)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 10).fill(Palette.gradient(Palette.colors(bot)).opacity(0.16))
            } else if hovered {
                RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.05))
            }
        }
        .animation(.easeOut(duration: 0.2), value: isExpanded)
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
