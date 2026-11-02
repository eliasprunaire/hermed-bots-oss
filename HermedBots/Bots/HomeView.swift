import SwiftUI

/// L'accueil, quand aucun bot n'est ouvert : l'aurore, puis chaque bot en carte ; sans bot, ce qui manque pour en voir
struct HomeView: View {
    let bots: BotsModel
    let profileLock: ProfileLock
    let activity: (String) -> ConversationMachine.Activity
    /// Aucune adresse d'API : l'app attend une connexion
    let needsConnection: Bool
    let open: (String) -> Void
    let configure: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                AuroraOrb(colors: Palette.brand + [Color(rgb: 0xE100FF)], size: 104)
                    .padding(.top, 32)
                VStack(spacing: 8) {
                    Text("Avec quel bot voulez-vous parler ?")
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .multilineTextAlignment(.center)
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                content
            }
            .frame(maxWidth: 900)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
    }

    private var subtitle: LocalizedStringKey {
        if let shown = bots.list.shown, !shown.isEmpty { return "Choisissez un bot pour ouvrir sa conversation." }
        if needsConnection { return "Reliez l'app à votre instance Hermes pour voir vos bots." }
        return "Vos bots apparaissent ici dès que Hermes les liste."
    }

    @ViewBuilder private var content: some View {
        if let shown = bots.list.shown, !shown.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14)], spacing: 14) {
                ForEach(shown) { bot in
                    BotCard(bot: bot, activity: activity(bot.id), lockReason: profileLock.state(bot.id).reason) { open(bot.id) }
                }
            }
        } else if needsConnection {
            Button(action: configure) {
                Label("Configurer la connexion", systemImage: "point.3.connected.trianglepath.dotted")
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .accessibilityID(.homeConfigure)
        } else if bots.phase == .loading || bots.phase == .waiting {
            ProgressView().controlSize(.regular)
        }
    }
}

/// La carte d'un bot à l'accueil : un clic l'ouvre ; elle prend sa couleur au survol et s'enfonce sous le clic
private struct BotCard: View {
    let bot: Bot
    let activity: ConversationMachine.Activity
    let lockReason: String?
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        let colors = Palette.colors(bot)
        Button(action: action) {
            HStack(spacing: 12) {
                BotAvatar(bot: bot, size: 44, activity: activity)
                VStack(alignment: .leading, spacing: 3) {
                    Text(bot.name)
                        .font(.headline)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let lockReason {
                        Text(lockReason).font(.caption).foregroundStyle(.orange).lineLimit(2)
                    } else {
                        Group { if let model = bot.model { Text(verbatim: model) } else { Text("Modèle du profil") } }
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(colors[0])
                    .opacity(hovered ? 1 : 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 18)
                    .fill(.background.secondary)
                    .overlay(RoundedRectangle(cornerRadius: 18).fill(Palette.gradient(colors).opacity(hovered ? 0.14 : 0.05)))
            }
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Palette.gradient(colors).opacity(hovered ? 0.7 : 0.18), lineWidth: 1))
            .contentShape(.rect(cornerRadius: 18))
        }
        .buttonStyle(PressStyle())
        .shadow(color: colors[0].opacity(hovered ? 0.3 : 0), radius: 14, y: 6)
        .animation(.easeOut(duration: 0.16), value: hovered)
        .onHover { hovered = $0 }
        .help(bot.name)
        .accessibilityLabel(bot.name)
        .accessibilityIdentifier(AccessibilityID.homeBot(bot.id))
    }
}
