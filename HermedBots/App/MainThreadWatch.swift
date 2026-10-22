#if DEBUG
import Foundation
import Observation

/// Mesure de l'intérieur de l'app le temps que le fil principal met à répondre ; mode test seulement
/// Un fil de fond demande au fil principal de répondre toutes les 5 ms : l'attente d'une réponse est la durée d'un blocage, à 5 ms près
/// La sonde de perf ne peut pas le mesurer du dehors : `typeKey` et `click` attendent eux-mêmes le retour de l'app au repos
@Observable
@MainActor
final class MainThreadWatch {
    struct Hang: Equatable, Sendable {
        /// Secondes depuis 1970 : le runner de tests lit la même horloge
        let start: TimeInterval
        let milliseconds: Int
    }

    /// Les blocages d'au moins `threshold` ms, le plus ancien en premier ; les 100 derniers seulement
    private(set) var hangs: [Hang] = []
    /// Réponses du fil principal, publiées par centaines : un compteur publié à chaque réponse ferait travailler le fil qu'on mesure
    private(set) var samples = 0

    private let threshold: Int
    @ObservationIgnored private var count = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    init(threshold: Int = 50) {
        self.threshold = threshold
    }

    /// Ce que la sonde de perf lit par l'accessibilité : `{"samples":n,"hangs":[[début,ms],…]}`
    var report: String {
        let list = hangs.map { "[\($0.start),\($0.milliseconds)]" }.joined(separator: ",")
        return "{\"samples\":\(samples),\"hangs\":[\(list)]}"
    }

    func start() {
        guard task == nil else { return }
        task = Task.detached(priority: .high) { [weak self] in
            while !Task.isCancelled {
                guard let watch = self else { return }
                await watch.answer(to: ContinuousClock.now)
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Tourne sur le fil principal : `asked` date la demande, l'écart jusqu'ici est le temps que ce fil a mis à répondre
    private func answer(to asked: ContinuousClock.Instant) {
        let milliseconds = Int(asked.duration(to: .now) / .milliseconds(1))
        count += 1
        if milliseconds >= threshold {
            hangs.append(Hang(start: Date().timeIntervalSince1970 - Double(milliseconds) / 1000, milliseconds: milliseconds))
            if hangs.count > 100 { hangs.removeFirst() }
        }
        if count % 100 == 0 { samples = count }
    }
}
#endif
