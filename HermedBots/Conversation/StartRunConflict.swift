import Foundation
import HermesAdapter

/// Échecs classés de `start_run` HTTP 409 : jamais un code HTTP brut à l'écran
enum StartRunConflict {
    static let foreignSession = String(localized: "Ce fil appartient à une autre surface. Hermed Bots ne peut pas y écrire. Ouvre une nouvelle session.")
    static let idempotency = String(localized: "Ce message n'a pas pu partir : un autre envoi utilise déjà cette clé. Réessaie.")
    static let generic = String(localized: "Le serveur a refusé cet envoi (conflit). Réessaie.")

    static func isForeignSession(_ error: Error) -> Bool {
        guard case HermesError.http(_, 409, let detail) = error as? HermesError else { return false }
        return token(detail) == "permission_denied"
    }

    static func message(for error: Error) -> String? {
        guard case HermesError.http(_, 409, let detail) = error as? HermesError else { return nil }
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
