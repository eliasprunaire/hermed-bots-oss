import Foundation

/// Échecs classés de `start_run` HTTP 409 : jamais un code HTTP brut à l'écran
public enum StartRunConflict {
    public static let foreignSession = "Ce fil appartient à une autre surface. Hermed Bots ne peut pas y écrire. Ouvre une nouvelle session."
    public static let idempotency = "Ce message n'a pas pu partir : un autre envoi utilise déjà cette clé. Réessaie."
    public static let generic = "Le serveur a refusé cet envoi (conflit). Réessaie."

    public static func isForeignSession(_ error: Error) -> Bool {
        guard let hermes = error as? HermesError, case .http(_, 409, let detail) = hermes else { return false }
        return token(detail) == "permission_denied"
    }

    public static func message(for error: Error) -> String? {
        guard let hermes = error as? HermesError, case .http(_, 409, let detail) = hermes else { return nil }
        switch token(detail) {
        case "permission_denied": return foreignSession
        case "idempotency_key_conflict", "idempotency_replay_unavailable": return idempotency
        default: return generic
        }
    }

    private static func token(_ detail: String?) -> String {
        let text = (detail ?? "").lowercased()
        if text.contains("permission_denied") || text.contains("another surface") { return "permission_denied" }
        if text.contains("idempotency_replay_unavailable") { return "idempotency_replay_unavailable" }
        if text.contains("idempotency") { return "idempotency_key_conflict" }
        return text
    }
}
