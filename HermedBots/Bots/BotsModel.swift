import HermesAdapter
import Observation
import SwiftUI

/// Les bots de la barre latérale et leurs fils passés
/// La liste vient de `list_profiles` (décision S6), les fils de `list_sessions` ; ni l'un ni l'autre ne sont lus sans qu'on les montre
///
/// Un état par connexion (l'hôte de Hermes choisi dans l'app) : la barre latérale ne montre que les bots, les fils et les déplis de l'hôte courant
/// Une réponse est rangée chez l'hôte qui l'a demandée : une liste lue sur A et arrivée après le passage sur B reste chez A, qui la retrouve au retour
@Observable
@MainActor
final class BotsModel {
    enum Phase: Equatable {
        /// pas d'adresse d'API : rien n'est lu
        case waiting
        case loading
        case ready
        case failed(String)
    }

    enum Threads: Equatable {
        case loading
        case loaded([Session])
        /// `list_sessions` est désactivée dans la carte des capacités : le message dit pourquoi, le reste de l'app marche
        case disabled(String)
        case failed(String)
    }

    /// Ce que la barre latérale montre pour un hôte
    private struct Host {
        var list = BotList()
        var phase = Phase.waiting
        var threads: [String: Threads] = [:]
        /// Le numéro de la lecture rangée de la liste des fils de chaque bot, pris à son départ : la conversation le compare à la confirmation d'un choix
        var reads: [String: Int] = [:]
        var issued: [String: Int] = [:]
        var expanded: Set<String> = []
    }

    private var hosts: [String: Host] = [:]
    /// Le numéro de la dernière lecture de la liste des fils partie, un seul compteur pour tous les bots et tous les hôtes
    /// Chaque lecture prend son numéro au départ : une lecture partie avant la confirmation d'un choix a un numéro inférieur ou égal à celui que la confirmation retient
    private(set) var startedReads = 0

    var list: BotList { shown.list }
    var phase: Phase { shown.phase }
    var threads: [String: Threads] { shown.threads }
    var expanded: Set<String> { shown.expanded }

    private let readProfiles: @MainActor () async throws -> [Profile]
    private let client: @MainActor () -> HermesClient?
    private let connection: @MainActor () -> String
    private let interval: Duration

    /// `interval` sépare deux relevés de la liste ; un changement trouvé en route attend la validation de l'utilisateur
    /// `connection` nomme l'hôte de Hermes, comme pour `ConversationModel` ; sans lui, l'adresse du client le nomme
    init(interval: Duration = .seconds(30), readProfiles: @escaping @MainActor () async throws -> [Profile], client: @escaping @MainActor () -> HermesClient?, connection: (@MainActor () -> String)? = nil) {
        self.interval = interval
        self.readProfiles = readProfiles
        self.client = client
        self.connection = connection ?? { client()?.baseURL.absoluteString ?? "" }
    }

    /// L'état de l'hôte courant ; un hôte jamais lu ne montre rien
    private var shown: Host { hosts[connection()] ?? Host() }

    /// Relit la liste tout de suite puis à chaque intervalle, jusqu'à l'annulation de la tâche
    func run() async {
        let host = connection()
        if hosts[host, default: Host()].list.shown == nil { hosts[host, default: Host()].phase = .loading }
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: interval)
        }
    }

    func refresh() async {
        let host = connection()
        do {
            let profiles = try await readProfiles()
            hosts[host, default: Host()].list.receive(profiles.map { Bot(id: $0.id, name: $0.displayName, model: $0.model) })
            hosts[host, default: Host()].phase = .ready
        } catch {
            if Task.isCancelled { return }
            // une liste déjà affichée reste : la panne passagère d'une relecture ne la remplace pas
            if hosts[host, default: Host()].list.shown == nil { hosts[host, default: Host()].phase = .failed(Self.message(error)) }
        }
    }

    /// Ce que la liste des fils dit d'un fil de ce bot : le modèle qu'elle écrit pour lui (nil quand le fil y manque ou qu'il suit le modèle du profil), et le numéro pris au départ par la lecture qui le donne
    /// nil quand la liste n'est pas lue
    func listedThread(_ bot: String, _ session: String) -> (model: String?, read: Int)? {
        guard case .loaded(let sessions)? = threads[bot] else { return nil }
        return (sessions.first { $0.id == session }?.model, shown.reads[bot] ?? 0)
    }

    func validateChange() { hosts[connection(), default: Host()].list.validate() }

    /// Déplie ou replie un bot ; chaque dépli relit ses fils
    func toggle(_ id: String) {
        let host = connection()
        if hosts[host, default: Host()].expanded.remove(id) != nil { return }
        hosts[host, default: Host()].expanded.insert(id)
        Task { await loadThreads(id, on: host) }
    }

    /// Relit les fils d'un bot déplié ; un bot replié les lira au dépli
    func reload(_ id: String) {
        let host = connection()
        guard hosts[host]?.expanded.contains(id) == true else { return }
        Task { await loadThreads(id, on: host) }
    }

    func loadThreads(_ id: String) async { await loadThreads(id, on: connection()) }

    private func loadThreads(_ id: String, on host: String) async {
        // l'hôte a pu changer depuis le dépli : rien ne part chez le nouvel hôte pour un bot de l'ancien
        guard host == connection(), let client = client() else {
            hosts[host, default: Host()].threads[id] = .failed(String(localized: "Hermes n'est pas joignable."))
            return
        }
        // les fils déjà lus restent affichés pendant la relecture
        if hosts[host, default: Host()].threads[id] == nil { hosts[host, default: Host()].threads[id] = .loading }
        startedReads += 1
        let read = startedReads
        hosts[host, default: Host()].issued[id] = read
        let result: Threads
        do {
            switch try await client.listSessions(profile: id) {
            case .sessions(let sessions): result = .loaded(sessions)
            case .disabled(let message): result = .disabled(message)
            }
        } catch {
            result = .failed(Self.message(error))
        }
        guard read == hosts[host, default: Host()].issued[id] else { return }
        hosts[host, default: Host()].threads[id] = result
        if case .loaded = result { hosts[host, default: Host()].reads[id] = read }
    }

    private static func message(_ error: Error) -> String {
        switch error {
        case let failure as SSHFailure: failure.message
        case let failure as RemoteCommandFailure:
            String(localized: "La commande « hermes profile list » a échoué (code \(String(failure.status))) : \(failure.detail)")
        default: "\(error)"
        }
    }
}
