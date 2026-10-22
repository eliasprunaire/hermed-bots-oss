import SwiftUI

/// La feuille d'approbation : l'outil qui demande et ses paramètres, avant toute réponse, puis Approuver ou Refuser
/// Elle suit la demande du fil à l'écran et ne se ferme que par une décision que Hermes prend ou par la fin du tour : Échap ne la ferme pas
/// Les paramètres défilent et ne sont jamais coupés en silence : ce que la feuille ne montre pas, ou écrit autrement, est dit dessous
/// Quand la liaison est coupée, la décision reste et repart au retour ; quand Hermes ne propose plus `approve`, la demande reste affichée et la réponse est grisée
struct ApprovalSheet: View {
    let model: ConversationModel

    var body: some View {
        if let approval = model.approval {
            content(approval)
        }
    }

    private func content(_ approval: ConversationMachine.Approval) -> some View {
        let request = approval.request
        let params = ApprovalParams(request.command)
        return VStack(alignment: .leading, spacing: 12) {
            Label("Le bot demande l'autorisation d'utiliser un outil", systemImage: "exclamationmark.shield.fill")
                .font(.headline)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Outil")
                    .foregroundStyle(.secondary)
                Text(request.tool ?? String(localized: "inconnu"))
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .accessibilityID(.approvalTool)
            }
            if !request.description.isEmpty {
                Text(request.description)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            self.params(params)
            Divider()
            status(approval)
            if let reason = model.profileLockReason {
                Text(reason).foregroundStyle(.orange).accessibilityID(.profileLock)
            }
            if case .disabled(let message) = model.approveSupport {
                disabled(message)
            }
            buttons(approval)
        }
        .padding(20)
        .frame(width: 560)
        // le groupe garde ses enfants adressables : l'outil, les paramètres et les boutons portent chacun leur identifiant
        .accessibilityElement(children: .contain)
        .accessibilityID(.approvalSheet)
        .interactiveDismissDisabled()
    }

    private func params(_ params: ApprovalParams) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Paramètres")
                .foregroundStyle(.secondary)
            ScrollView {
                Text(params.shown.isEmpty ? String(localized: "Aucun paramètre.") : params.shown)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .accessibilityID(.approvalParams)
            }
            .frame(minHeight: 100, maxHeight: 260)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
            if params.isChanged {
                cut(params)
            }
        }
    }

    /// Ce que la feuille ne montre pas tel quel : une coupure, des caractères écrits en clair
    private func cut(_ params: ApprovalParams) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if params.hidden > 0 {
                Label("\(number(params.hidden)) caractères non affichés sur \(number(params.total)) : refusez si vous ne pouvez pas juger la commande.", systemImage: "scissors")
            }
            if params.escaped > 0 {
                Label("\(number(params.escaped)) caractères de contrôle sont écrits sous la forme \\u{…}.", systemImage: "eye.slash")
            }
        }
        .font(.callout)
        .foregroundStyle(.orange)
        .accessibilityElement(children: .combine)
        .accessibilityID(.approvalCut)
    }

    /// Les nombres suivent la langue du texte qui les entoure, pas la région du Mac : « 200 000 » dans un texte français
    private func number(_ value: Int) -> String {
        value.formatted(.number.locale(Locale(identifier: Bundle.main.preferredLocalizations.first ?? "fr")))
    }

    @ViewBuilder private func status(_ approval: ConversationMachine.Approval) -> some View {
        Group {
            if approval.decision == nil {
                Label("Le bot attend votre réponse.", systemImage: "hourglass")
            } else if approval.isQueued {
                Label("Hermes n'est pas joignable. Votre réponse part dès le retour de la liaison.", systemImage: "wifi.slash")
                    .foregroundStyle(.orange)
            } else {
                Label("Réponse envoyée à Hermes…", systemImage: "paperplane")
            }
        }
        .accessibilityID(.approvalStatus)
        if let error = approval.error {
            Label("Hermes a refusé la réponse : \(error)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .lineLimit(4)
        }
    }

    /// La demande reste affichée et la réponse grisée : le bot reste bloqué tant qu'elle n'a pas de réponse, il ne se débloque que par le kill switch
    @ViewBuilder private func disabled(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .accessibilityID(.approvalDisabled)
        Label("Le bot reste bloqué tant que cette demande n'a pas de réponse. Pour l'arrêter : kill switch (arrêt du processus Hermes de ce profil sur la VM).", systemImage: "power")
            .foregroundStyle(.secondary)
            .lineLimit(4)
            .accessibilityID(.approvalKillSwitch)
    }

    private func buttons(_ approval: ConversationMachine.Approval) -> some View {
        let isDisabled: Bool = {
            if case .disabled = model.approveSupport { return true }
            return model.stopInProgress || model.profileLockReason != nil || approval.decision != nil
        }()
        return HStack {
            Spacer()
            // Échap refuse : refuser est le choix sans effet ; Approuver n'a pas de raccourci
            Button("Refuser") { model.answer(.no) }
                .keyboardShortcut(.cancelAction)
                .accessibilityID(.approvalNo)
            Button("Approuver") { model.answer(.yes) }
                .accessibilityID(.approvalYes)
        }
        .disabled(isDisabled)
    }
}
