import Foundation

public struct Profile: Equatable, Sendable {
    public let id: String
    public let displayName: String
    /// Modèle par défaut du profil, lu dans la colonne Model de `hermes profile list` ; nil quand la table n'en donne aucun
    public let model: String?

    init(id: String, displayName: String, model: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.model = model
    }
}

public struct Session: Equatable, Sendable {
    public let id: String
    public let title: String?
    /// Le modèle verrouillé sur ce fil par `set_model`, tel que Hermes l'écrit ; nil quand le fil suit le modèle du profil
    public let model: String?

    init(id: String, title: String?, model: String? = nil) {
        self.id = id
        self.title = title
        self.model = model
    }
}

/// Un message du transcript d'un fil, tel que Hermes le range (`session_messages`)
public struct Message: Equatable, Sendable {
    public enum Role: String, Sendable {
        case user
        case assistant
    }

    /// Numéro de ligne dans la base du profil, fourni par Hermes : ce n'est pas un rang dans la session (S5)
    public let id: Int
    public let role: Role
    public let text: String

    public init(id: Int, role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

/// Réponse de `list_sessions` : les fils, ou la fonction désactivée avec son message pour l'utilisateur
public enum SessionList: Equatable, Sendable {
    case sessions([Session])
    case disabled(message: String)
}

public struct Reply: Equatable, Sendable {
    public let sessionID: String
    public let text: String
    public let model: String?
}

public struct ModelLock: Equatable, Sendable {
    public let sessionID: String
    public let model: String
}

public struct ApprovalRequest: Equatable, Sendable {
    public let requestID: String
    /// Présent seulement dans Hermes 0.22.1, renvoyé tel quel à l'approbation
    public let executionGeneration: Int?
    public let command: String
    public let description: String
    public let choices: [String]
    /// L'outil qui demande : le nom de l'événement s'il en porte un, sinon l'outil en cours du tour (`tool.started` précède `approval.request`) ; nil quand ni l'un ni l'autre n'existe
    public internal(set) var tool: String?

    public init(requestID: String, executionGeneration: Int?, command: String, description: String, choices: [String], tool: String? = nil) {
        self.requestID = requestID
        self.executionGeneration = executionGeneration
        self.command = command
        self.description = description
        self.choices = choices
        self.tool = tool
    }
}

public struct ApprovalResult: Equatable, Sendable {
    public let requestID: String
    public let choice: String
    /// Faux quand le serveur n'avait aucune demande en attente pour cet identifiant
    public let resolved: Bool
}

public enum TurnState: String, Sendable {
    case running
    case waitingForApproval = "waiting_for_approval"
    case completed
    case failed
    case cancelled
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .running, .waitingForApproval: return false
        case .completed, .failed, .cancelled, .interrupted: return true
        }
    }
}

public struct Turn: Equatable, Sendable {
    public internal(set) var runID: String
    public internal(set) var text: String
    public internal(set) var state: TurnState
    public internal(set) var error: String?
    public internal(set) var approvals: [ApprovalRequest]
    /// L'outil que Hermes dit en cours (`tool.started` sans `tool.completed`) ; avec deux outils à la fois, le dernier lancé qui tourne encore
    public internal(set) var tool: String?
}

public enum HermesError: Error, Equatable, CustomStringConvertible {
    case emptyMessage
    case apiKeyMissing(String)
    case unreachable(url: String, reason: String)
    case http(contract: String, status: Int, detail: String?)
    case profileNotServed(String)
    case decoding(contract: String, detail: String)

    public var description: String {
        switch self {
        case .apiKeyMissing(let profile):
            return "Clé API introuvable sur l'hôte pour le profil \(profile)."
        case .emptyMessage:
            return "message vide : rien n'est envoyé"
        case .unreachable(let url, let reason):
            return "Hermes injoignable à \(url) : \(reason)"
        case .http(let contract, let status, let detail):
            return "\(contract) : réponse HTTP \(status)" + (detail.map { " (\($0))" } ?? "")
        case .profileNotServed(let id):
            return "profil \(id) non servi par Hermes (HTTP 404)"
        case .decoding(let contract, let detail):
            return "\(contract) : réponse illisible (\(detail))"
        }
    }
}
