import HermesAdapter
import SwiftUI

/// La zone de conversation d'un bot : son en-tête, les lignes du fil, l'état du dernier tour et le champ de saisie
/// Toute la zone prend la couleur du bot : un halo derrière l'en-tête, les bulles de l'utilisateur, le bouton Envoyer
struct ConversationView: View {
    let model: ConversationModel
    let killSwitch: KillSwitch
    let bot: Bot
    @Environment(\.motion) private var motion

    private var colors: [Color] { Palette.colors(bot) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let reason = model.profileLockReason {
                NoticeCard(tint: .orange, symbol: "lock.fill") {
                    Text(reason).accessibilityID(.profileLock)
                        .accessibilityIdentifier(model.profileLock?.state(model.botID ?? "") == .unknown ? AccessibilityID.degradedFeature("profile_lock") : AccessibilityID.profileLock.rawValue)
                }
                .column()
                .padding(.bottom, 8)
            }
            LoopPauseBanner(model: model)
            if model.isOpening {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Connexion à Hermes… préparation de la clé du profil")
                        .accessibilityID(.conversationOpening)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 4)
            }
            if let error = model.openError {
                NoticeCard(tint: .red, symbol: "exclamationmark.triangle.fill") {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(error).accessibilityID(.conversationError)
                        Spacer(minLength: 0)
                        Button("Réessayer") { model.retryOpen() }
                            .buttonStyle(.glass)
                            .accessibilityID(.bannerErrorRetry)
                    }
                }
                .column()
                .padding(.bottom, 8)
            }
            if model.compaction.isCompacted, !model.conversation.entries.isEmpty {
                NoticeCard(tint: .blue, symbol: "rectangle.compress.vertical") {
                    Text(CompatibilityStatus.compactedNotice).accessibilityID(.conversationCompacted)
                }
                .column()
                .padding(.bottom, 8)
            }
            transcript
            // sous le fil et non en `safeAreaInset` : posé au-dessus de la ScrollView, le champ et Envoyer n'étaient plus atteignables pour XCUITest
            ComposerView(model: model, bot: bot)
        }
        .background(alignment: .top) {
            Palette.gradient(colors)
                .opacity(0.22)
                .frame(height: 240)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.45), value: bot.id)
                .accessibilityHidden(true)
        }
        // le groupe garde ses enfants adressables : chaque ligne porte son propre identifiant
        .accessibilityElement(children: .contain)
        .accessibilityID(.conversationView)
        // la feuille suit la demande du fil à l'écran : l'utilisateur ne la ferme pas, une décision ou la fin du tour la ferme
        .sheet(isPresented: Binding(get: { model.approval != nil }, set: { _ in })) {
            VStack(spacing: 0) {
                ApprovalSheet(model: model)
                Divider()
                StopAllButton(model: killSwitch, inApproval: true).padding(20)
            }
            .frame(width: 560)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.newSession() } label: { Label("Nouvelle session", systemImage: "square.and.pencil") }
                    .labelStyle(.titleAndIcon)
                    .accessibilityID(.sessionNew)
                    .disabled(model.stopInProgress || model.profileLockReason != nil)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            BotAvatar(bot: bot, size: 40, activity: model.activity(of: bot.id))
            VStack(alignment: .leading, spacing: 3) {
                Text(bot.name)
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 8) {
                    ModelPicker(model: model)
                    Text("fil unique")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary.opacity(0.5), in: .capsule)
                }
            }
            Spacer(minLength: 0)
        }
        .column()
        .padding(.vertical, 12)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // l'état du tour reste hors de la pile paresseuse : après un message très haut, une pile paresseuse ne le créait pas
                VStack(alignment: .leading, spacing: 18) {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        ForEach(model.conversation.entries) { entry in
                            MessageRow(entry: entry, bot: bot, isStreaming: model.conversation.phase == .running && entry.id == model.conversation.entries.last?.id)
                                .id(entry.id)
                                .transition(motion ? .opacity.combined(with: .offset(y: 6)) : .identity)
                        }
                    }
                    .animation(motion ? .easeOut(duration: 0.24) : nil, value: model.conversation.entries.count)
                    footer.id("footer")
                }
                .column()
                .padding(.vertical, 12)
            }
            // la lecture suit la fin du fil à mesure que la réponse arrive
            .onChange(of: model.conversation.entries.last?.text) { proxy.scrollTo("footer", anchor: .bottom) }
            .onChange(of: model.conversation.entries.count) { proxy.scrollTo("footer", anchor: .bottom) }
        }
        .overlay { placeholder }
    }

    @ViewBuilder private var placeholder: some View {
        if model.isLoading || model.isOpening {
            ProgressView().controlSize(.small)
        } else if model.conversation.entries.isEmpty, !model.isBusy {
            VStack(spacing: 14) {
                BotAvatar(bot: bot, size: 64)
                    .background { Aurora(colors: colors + [colors[0].opacity(0.4)]).clipShape(.circle).frame(width: 130, height: 130).blur(radius: 28).opacity(0.55) }
                Text(model.openError == nil ? CompatibilityStatus.uniqueChatTitle : CompatibilityStatus.waitingChatTitle)
                    .font(.system(.title2, design: .rounded, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(model.openError == nil ? CompatibilityStatus.uniqueChatBody : CompatibilityStatus.waitingChatBody)
                    .foregroundStyle(.secondary)
                    .accessibilityID(.conversationEmpty)
            }
            .padding(24)
        }
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.isBusy {
                HStack(spacing: 10) {
                    // la ligne de réponse porte déjà l'avatar : la ligne d'activité s'aligne sur son texte
                    if model.conversation.entries.last?.role == .assistant {
                        Color.clear.frame(width: 26, height: 1)
                    } else {
                        BotAvatar(bot: bot, size: 26, activity: model.isWaitingForUser ? .waiting : .working)
                    }
                    if model.isWaitingForUser {
                        Label("Le bot attend votre réponse…", systemImage: "hand.raised.fill")
                            .foregroundStyle(.orange)
                            .accessibilityID(.conversationBusy)
                    } else {
                        TypingDots(tint: colors[0])
                        Text(CompatibilityStatus.thinkingLabel).foregroundStyle(.secondary).accessibilityID(.conversationBusy)
                    }
                }
                if let tool = model.currentTool {
                    CurrentToolRow(tool: tool).padding(.leading, 36)
                }
            }
            if let end = model.conversation.end {
                TurnEndRow(end: end, detail: model.conversation.endDetail).padding(.leading, 36)
            }
            if let failure = model.conversation.failure {
                NoticeCard(tint: .red, symbol: "exclamationmark.triangle.fill") {
                    Text(failure).lineLimit(6).accessibilityID(.conversationError)
                }
            }
        }
        .font(.callout)
    }
}

extension View {
    /// La colonne de lecture : 760 points au plus, centrée, avec ses marges ; l'en-tête, le fil et le champ de saisie s'y alignent
    func column() -> some View {
        frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
    }
}

/// Une ligne du fil : le numéro de Hermes fait l'identifiant, une ligne pas encore numérotée porte sa clé locale
/// L'utilisateur parle dans une bulle teintée de la couleur du bot, à droite ; le bot répond à plat, derrière son avatar
private struct MessageRow: View {
    let entry: ConversationEntry
    let bot: Bot
    /// La ligne grandit encore : un texte sélectionnable ne rend plus à l'accessibilité les mots qui arrivent
    let isStreaming: Bool

    /// Au-delà de ce nombre de caractères, la bulle perd dégradé, liseré et interligne : leur mise en page d'un texte de 100 000 caractères dépassait le délai des tests
    static let plainThreshold = 10_000

    private var isLong: Bool { entry.text.count > Self.plainThreshold }

    var body: some View {
        if entry.role == .user {
            HStack {
                Spacer(minLength: 80)
                if isLong {
                    text
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Palette.colors(bot)[0].opacity(0.18), in: .rect(cornerRadius: 20))
                        .accessibilityIdentifier(identifier)
                } else {
                    text
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .background(Palette.gradient(Palette.colors(bot)).opacity(0.22), in: .rect(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Palette.gradient(Palette.colors(bot)).opacity(0.3)))
                        .accessibilityIdentifier(identifier)
                }
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                BotAvatar(bot: bot, size: 26)
                text
                    .padding(.top, 4)
                    .accessibilityIdentifier(identifier)
                Spacer(minLength: 40)
            }
        }
    }

    @ViewBuilder private var text: some View {
        if entry.role == .assistant {
            MessageMarkdownView(source: entry.text, selectable: !isStreaming, streaming: isStreaming)
        } else if isStreaming {
            Text(entry.text).lineSpacing(isLong ? 0 : 3)
        } else {
            Text(entry.text).lineSpacing(isLong ? 0 : 3).textSelection(.enabled)
        }
    }

    private var identifier: String {
        entry.serverIndex.map(AccessibilityID.conversationMessage) ?? AccessibilityID.conversationMessagePending(entry.id)
    }
}

/// L'état terminal du tour : un texte traduit par état, qui nomme l'état que Hermes a annoncé
private struct TurnEndRow: View {
    let end: TurnEnd
    let detail: String?

    var body: some View {
        Label {
            if let detail, !detail.isEmpty {
                Text("\(label) : \(detail)").lineLimit(4)
            } else {
                Text(label)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.12), in: .rect(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.map { "\(label) : \($0)" } ?? label)
        .accessibilityID(.conversationState)
    }

    private var label: String {
        switch end {
        case .completed: String(localized: "Tour terminé")
        case .failed: String(localized: "Tour échoué")
        case .cancelled: String(localized: "Tour annulé")
        case .interrupted: String(localized: "Tour interrompu")
        }
    }

    private var symbol: String {
        switch end {
        case .completed: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .cancelled: "stop.circle.fill"
        case .interrupted: "bolt.slash.fill"
        }
    }

    private var color: Color {
        switch end {
        case .completed: .green
        case .failed: .red
        case .cancelled, .interrupted: .orange
        }
    }
}
