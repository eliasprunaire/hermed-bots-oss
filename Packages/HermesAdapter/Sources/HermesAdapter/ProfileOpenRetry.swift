import Foundation

/// Tentatives d'ouverture d'un profil : immédiat, 400 ms, 1,2 s, puis seulement l'erreur.
public enum ProfileOpenRetry: Sendable {
    public static let delays: [Duration] = [.zero, .milliseconds(400), .milliseconds(1_200)]

    public static var attemptCount: Int { delays.count }

    public static func delay(beforeAttempt index: Int) -> Duration {
        guard delays.indices.contains(index) else { return delays.last ?? .zero }
        return delays[index]
    }

    /// Exécute `work` jusqu'à trois fois. `work` rend `true` pour s'arrêter (succès).
    public static func run(_ work: () async throws -> Bool) async throws -> Bool {
        for attempt in 0..<attemptCount {
            let wait = delay(beforeAttempt: attempt)
            if wait != .zero { try await Task.sleep(for: wait) }
            if try await work() { return true }
        }
        return false
    }
}
