import Foundation

/// Ce que le pied et Réglages disent de la version Hermes, sans bandeau tant que tout répond.
public enum CompatibilityStatus: Equatable, Sendable {
    case connecting
    case ready
    case untested
    case failed

    public static let connectingLabel = "Connexion…"
    public static let readyLabel = "Prêt"
    public static let untestedLabel = "Compatibilité · voir Réglages"
    public static let refusedLabel = "Clé refusée"
    public static let tunnelFailedLabel = "Tunnel en échec"
    public static let composerUnavailable = "Indisponible : la clé API est refusée"
    public static let composerMissingKey = "Indisponible : la clé API est introuvable"
    public static let thinkingLabel = "Le bot réfléchit…"
    public static let compactedNotice = "Contexte compacté — résumé des tours plus anciens. Le transcript reste visible ; le modèle reçoit le résumé + la queue récente."
    public static let compactedEstimateNotice = "Estimation du contexte (Hermes n'a pas envoyé l'usage) — un résumé des tours anciens est probable. Le transcript reste visible."
    public static let uniqueChatTitle = "Conversation unique"
    public static let uniqueChatBody = "Un fil par bot. Le contexte grossit sans déborder (compaction / résumé)."
    public static let waitingChatTitle = "Conversation en attente"
    public static let waitingChatBody = "Réessayez la connexion pour ouvrir le fil."

    public var footerLabel: String {
        switch self {
        case .connecting: Self.connectingLabel
        case .ready: Self.readyLabel
        case .untested: Self.untestedLabel
        case .failed: Self.refusedLabel
        }
    }

    public static func footerLabel(status: CompatibilityStatus, tunnelFailed: Bool) -> String {
        if status == .failed, tunnelFailed { return tunnelFailedLabel }
        return status.footerLabel
    }

    public static func of(map: CapabilityMap?, checking: Bool, hasError: Bool) -> CompatibilityStatus {
        // un échec déjà affiché (clé refusée, tunnel) l'emporte sur une ouverture encore en cours
        if hasError { return .failed }
        if checking { return .connecting }
        guard let map else { return .connecting }
        if map.versionNotice != nil { return .untested }
        return .ready
    }
}
