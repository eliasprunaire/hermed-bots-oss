import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum CapabilityState: Equatable, Sendable {
    case available
    /// `message` est écrit pour l'utilisateur : il dit quelle fonction manque et pourquoi
    case disabled(message: String)
}

/// Ce que Hermes sait faire, un état par contrat, et la version lue pour information
public struct CapabilityMap: Equatable, Sendable {
    /// Lue sur `GET /health` (S8) ; nil quand Hermes n'en donne aucune
    public let version: String?
    let states: [Contract: CapabilityState]

    // ponytail: les versions des deux fixtures ; une version de plus se déclare ici après le test quotidien
    static let knownVersions: Set<String> = ["0.22.1", "0.22.2"]

    public var isVersionKnown: Bool { version.map(Self.knownVersions.contains) ?? false }

    /// Mode dégradé : version inconnue ou au moins une fonction désactivée. Il ne refuse jamais la connexion
    public var isDegraded: Bool { !isVersionKnown || states.values.contains { $0 != .available } }

    public subscript(_ contract: Contract) -> CapabilityState { states[contract] ?? .available }

    /// Un état par contrat, dans l'ordre de `Contract` ; `version` n'est pas une fonction, la carte ne la juge pas
    public var entries: [(contract: Contract, state: CapabilityState)] {
        Contract.features.map { ($0, self[$0]) }
    }
}

extension Contract {
    static let features = allCases.filter { $0 != .version }

    /// Ce que l'utilisateur perd quand le contrat est désactivé
    var feature: String {
        switch self {
        case .version: return "la lecture de la version"
        case .profileServed: return "l'ouverture d'un bot"
        case .listSessions: return "la liste des fils passés"
        case .sessionMessages: return "la lecture d'un fil passé"
        case .newSession: return "la nouvelle session"
        case .sendMessage: return "l'envoi d'un message"
        case .startRun: return "le démarrage d'un tour"
        case .runEvents: return "le suivi d'un tour"
        case .setModel: return "le changement de modèle"
        case .approve: return "la réponse à une approbation"
        }
    }
}

extension HermesClient {
    /// Sonde Hermes sans rien créer ni démarrer : la version, puis une requête inoffensive par contrat
    /// Un contrat dont la route répond 404 ou change de forme tombe seul, les autres restent disponibles
    /// Lève une erreur si la clé manque ou est refusée, si l’API ne répond pas ou si le profil n’est pas servi
    public func capabilities(profile: String) async throws -> CapabilityMap {
        let version = try await readVersion(profile: profile)
        var states: [Contract: CapabilityState] = [:]
        // ponytail: une requête après l'autre, un TaskGroup si la latence du tunnel pèse
        for contract in Contract.features {
            states[contract] = try await capability(contract, profile: profile)
        }
        return CapabilityMap(version: version, states: states)
    }

    /// Sonde un seul contrat par sa requête inoffensive, sans rien créer ni démarrer : un écran qui n'a besoin que d'une fonction ne sonde pas les autres
    /// Mêmes erreurs que `capabilities` : clé refusée, profil non servi et panne lèvent, jamais « désactivé »
    public func capability(_ contract: Contract, profile: String) async throws -> CapabilityState {
        let (status, body) = try await send(probeRequest(contract, profile: profile))
        return try classify(contract, status: status, body: body, profile: profile)
    }

    /// Lit la version du profil avec sa clé ; nil quand Hermes ne donne aucune version
    /// Lève `unreachable` quand l'API répond 5xx ou ne répond pas
    public func readVersion(profile: String) async throws -> String? {
        let variables = ["profile": profile]
        let request = try makeRequest(.version, variables, body: nil)
        let (status, body) = try await send(request)
        if status == 401 || status == 403 { throw httpError(.version, status, body, variables) }
        if status >= 500 { throw HermesError.unreachable(url: baseURL.absoluteString, reason: "réponse HTTP \(status)") }
        guard (200..<300).contains(status), let version = JSONObject(body)?.string("version"), !version.isEmpty else { return nil }
        return version
    }

    /// Un identifiant impossible ou un corps vide : Hermes refuse la requête sans rien créer ni démarrer
    private func probeRequest(_ contract: Contract, profile: String) throws -> URLRequest {
        let inert = "hd-probe-capabilities"
        let body: [String: Any]?
        switch contract {
        case .startRun, .sendMessage: body = ["input": ""]
        case .setModel: body = ["model": ""]
        case .newSession, .approve: body = [:]
        case .version, .profileServed, .listSessions, .sessionMessages, .runEvents: body = nil
        }
        var request = try makeRequest(contract, ["profile": profile, "session": inert, "run": inert], body: body)
        request.setValue("1", forHTTPHeaderField: "X-Hermed-Capability-Probe")
        // un corps JSON invalide : Hermes répond 400 et n'ouvre aucune session, alors que `{}` en ouvrirait une (S8)
        if contract == .newSession { request.httpBody = Data("{".utf8) }
        return request
    }

    /// Un contrat est disponible quand Hermes répond à sa requête inoffensive par la réponse observée en S8, et par aucune autre
    func classify(_ contract: Contract, status: Int, body: Data, profile: String) throws -> CapabilityState {
        switch status {
        case 401, 403, 500...:
            throw httpError(contract, status, body, ["profile": profile])
        case 404 where JSONObject(body)?.string("error") == "Unknown or unconfigured profile":
            throw HermesError.profileNotServed(profile)
        default:
            break
        }
        if isExpectedReply(contract, status: status, body: body, profile: profile) { return .available }
        return status == 404 ? disabled(contract, "Hermes ne propose plus cette route") : changedShape(contract, status)
    }

    /// Réponse de Hermes à la requête inoffensive : un 404 ne prouve la route que par le code de la ressource manquante (S8)
    private func isExpectedReply(_ contract: Contract, status: Int, body: Data, profile: String) -> Bool {
        let object = JSONObject(body)
        switch contract {
        case .version: return true
        case .profileServed: return status == 200 && object?.raw["data"] is [Any] && (try? Profile.decode(body, requestedID: profile)) != nil
        case .listSessions: return status == 200 && object?.raw["data"] is [Any]
        case .newSession, .startRun: return status == 400 && (object?.object("error")?.string("message") ?? object?.string("error")) != nil
        case .sendMessage, .setModel, .sessionMessages: return status == 404 && object?.object("error")?.string("code") == "session_not_found"
        case .runEvents, .approve: return status == 404 && object?.object("error")?.string("code") == "run_not_found"
        }
    }

    private func changedShape(_ contract: Contract, _ status: Int) -> CapabilityState {
        disabled(contract, "la réponse de Hermes a changé de forme (HTTP \(status))")
    }

    private func disabled(_ contract: Contract, _ reason: String) -> CapabilityState {
        .disabled(message: "Fonction désactivée (\(contract.feature)) : \(reason).")
    }
}
