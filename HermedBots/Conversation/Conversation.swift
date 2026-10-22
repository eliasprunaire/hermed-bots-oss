import Foundation

/// Comment un tour finit, tel que Hermes l'annonce (S1) ; `rawValue` est le nom de l'état chez Hermes
enum TurnEnd: String, Equatable, Sendable, CaseIterable {
    case completed
    case failed
    case cancelled
    case interrupted
}

struct ConversationEntry: Equatable, Identifiable, Sendable {
    enum Role: Equatable, Sendable {
        case user
        case assistant
    }

    /// Clé de liste propre à l'app : elle ne change pas quand Hermes numérote la ligne
    let id: Int
    let role: Role
    var text: String
    /// Numéro que Hermes donne au message (ligne de sa base, pas un rang) ; nil tant que le transcript n'a pas été relu
    var serverIndex: Int?
}

/// Ce que l'écran montre d'un fil : les lignes, le tour en cours et la fin du dernier tour
/// Logique pure : le réseau et la vue sont ailleurs
struct Conversation: Equatable {
    enum Phase: Equatable {
        case idle
        case running
    }

    private(set) var entries: [ConversationEntry] = []
    private(set) var phase = Phase.idle
    /// L'état terminal du dernier tour, tel que Hermes l'a donné ; nil avant le premier tour et pendant un tour
    private(set) var end: TurnEnd?
    /// L'erreur que Hermes donne avec cette fin (`run.failed`), si elle en donne une
    private(set) var endDetail: String?
    /// Une lecture qui a échoué (flux coupé, Hermes injoignable) : ce n'est pas un état terminal de Hermes
    private(set) var failure: String?
    private var nextKey = 0

    /// Le texte à envoyer : le brouillon sans blancs de bord, ou nil quand il est vide
    static func message(from draft: String) -> String? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Envoyer exige un message non vide et aucun tour en cours
    func canSend(_ draft: String) -> Bool { phase == .idle && Self.message(from: draft) != nil }

    /// Ajoute le message de l'utilisateur et ouvre le tour ; rend le texte à envoyer, ou nil quand l'envoi est refusé
    /// Le refus du tour déjà en cours est ce qui fait qu'un double clic ne part qu'une fois
    mutating func begin(_ draft: String) -> String? {
        guard canSend(draft), let text = Self.message(from: draft) else { return nil }
        entries.append(entry(.user, text))
        phase = .running
        end = nil
        endDetail = nil
        failure = nil
        return text
    }

    /// `reply` est le texte cumulé de la réponse : la ligne de réponse naît au premier texte et grandit sur place
    mutating func receive(reply: String) {
        guard phase == .running, !reply.isEmpty else { return }
        if let last = entries.indices.last, entries[last].role == .assistant, entries[last].serverIndex == nil {
            entries[last].text = reply
        } else {
            entries.append(entry(.assistant, reply))
        }
    }

    mutating func finish(_ end: TurnEnd, detail: String? = nil) {
        self.end = end
        endDetail = detail
        phase = .idle
    }

    /// Une lecture qui échoue ne touche pas à la fin du dernier tour : `begin` l'a déjà effacée pour un tour en cours
    mutating func fail(_ message: String) {
        failure = message
        phase = .idle
    }

    /// Ouvre un fil : le transcript de Hermes remplace les lignes ; la fin du dernier tour reste, le transcript ne la porte pas
    mutating func open(_ lines: [(serverIndex: Int, role: ConversationEntry.Role, text: String)]) {
        phase = .idle
        failure = nil
        entries = lines.map { entry($0.role, $0.text, serverIndex: $0.serverIndex) }
    }

    mutating func resume() {
        phase = .running
        end = nil
        failure = nil
    }

    /// Relit le transcript après un tour : les lignes prennent le numéro de Hermes, l'état du tour reste
    /// Les lignes locales gardent leur clé quand le transcript a la même forme ; sinon le transcript de Hermes l'emporte
    mutating func sync(_ lines: [(serverIndex: Int, role: ConversationEntry.Role, text: String)]) {
        let same = lines.count == entries.count && zip(lines, entries).allSatisfy { $0.role == $1.role && $0.text == $1.text }
        if same {
            for index in entries.indices { entries[index].serverIndex = lines[index].serverIndex }
        } else {
            entries = lines.map { entry($0.role, $0.text, serverIndex: $0.serverIndex) }
        }
    }

    private mutating func entry(_ role: ConversationEntry.Role, _ text: String, serverIndex: Int? = nil) -> ConversationEntry {
        defer { nextKey += 1 }
        return ConversationEntry(id: nextKey, role: role, text: text, serverIndex: serverIndex)
    }
}
