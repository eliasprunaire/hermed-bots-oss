import SwiftUI

/// La zone de conversation d'un bot : les lignes du fil, l'état du dernier tour et le champ de saisie
struct ConversationView: View {
    let model: ConversationModel
    let killSwitch: KillSwitch

    var body: some View {
        VStack(spacing: 0) {
            if let reason = model.profileLockReason {
                Text(reason).foregroundStyle(.orange).padding(10).accessibilityID(.profileLock)
                    .accessibilityIdentifier(model.profileLock?.state(model.botID ?? "") == .unknown ? AccessibilityID.degradedFeature("profile_lock") : AccessibilityID.profileLock.rawValue)
            }
            LoopPauseBanner(model: model)
            ModelPicker(model: model)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            transcript
            Divider()
            ComposerView(model: model)
        }
        // le groupe garde ses enfants adressables : chaque ligne porte son propre identifiant
        .accessibilityElement(children: .contain)
        .accessibilityID(.conversationView)
        // la feuille suit la demande du fil à l'écran : l'utilisateur ne la ferme pas, une décision ou la fin du tour la ferme
        .sheet(isPresented: Binding(get: { model.approval != nil }, set: { _ in })) { VStack { ApprovalSheet(model: model); StopAllButton(model: killSwitch, inApproval: true).padding() } }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.newSession() } label: { Label("Nouvelle session", systemImage: "square.and.pencil") }
                    .labelStyle(.titleAndIcon)
                    .accessibilityID(.sessionNew)
                    .disabled(model.stopInProgress || model.profileLockReason != nil)
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.conversation.entries) { entry in
                        MessageRow(entry: entry, isStreaming: model.conversation.phase == .running && entry.id == model.conversation.entries.last?.id).id(entry.id)
                    }
                    footer.id("footer")
                }
                .padding(12)
            }
            // la lecture suit la fin du fil à mesure que la réponse arrive
            .onChange(of: model.conversation.entries.last?.text) { proxy.scrollTo("footer", anchor: .bottom) }
            .onChange(of: model.conversation.entries.count) { proxy.scrollTo("footer", anchor: .bottom) }
        }
        .overlay { placeholder }
    }

    @ViewBuilder private var placeholder: some View {
        if model.isLoading {
            ProgressView().controlSize(.small)
        } else if model.conversation.entries.isEmpty, !model.isBusy {
            Text("Nouvelle session : écrivez le premier message.")
                .foregroundStyle(.secondary)
                .accessibilityID(.conversationEmpty)
        }
    }

    @ViewBuilder private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.isBusy {
                if model.isWaitingForUser {
                    Label("Le bot attend votre réponse…", systemImage: "hourglass").foregroundStyle(.secondary).accessibilityID(.conversationBusy)
                } else {
                    Label("Le bot répond…", systemImage: "ellipsis.bubble").foregroundStyle(.secondary).accessibilityID(.conversationBusy)
                }
                if let tool = model.currentTool {
                    CurrentToolRow(tool: tool)
                }
            }
            if let end = model.conversation.end {
                TurnEndRow(end: end, detail: model.conversation.endDetail)
            }
            if let failure = model.conversation.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(6)
                    .accessibilityID(.conversationError)
            }
        }
        .font(.callout)
    }
}

/// Une ligne du fil : le numéro de Hermes fait l'identifiant, une ligne pas encore numérotée porte sa clé locale
private struct MessageRow: View {
    let entry: ConversationEntry
    /// La ligne grandit encore : un texte sélectionnable ne rend plus à l'accessibilité les mots qui arrivent
    let isStreaming: Bool

    var body: some View {
        HStack {
            if entry.role == .user { Spacer(minLength: 60) }
            bubble
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(entry.role == .user ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.14), in: .rect(cornerRadius: 10))
                .accessibilityIdentifier(identifier)
            if entry.role == .assistant { Spacer(minLength: 60) }
        }
        .frame(maxWidth: .infinity, alignment: entry.role == .user ? .trailing : .leading)
    }

    @ViewBuilder private var bubble: some View {
        if isStreaming {
            Text(entry.text)
        } else {
            Text(entry.text).textSelection(.enabled)
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
