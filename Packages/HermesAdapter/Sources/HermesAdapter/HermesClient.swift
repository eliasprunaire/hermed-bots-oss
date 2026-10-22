import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// L'unique couche qui appelle Hermes : l'interface n'écrit jamais une route ni ne lit un JSON de Hermes
public struct HermesClient: @unchecked Sendable {
    public let baseURL: URL
    private let apiKey: String?
    private let apiKeyForProfile: (@Sendable (String) throws -> String?)?
    private let timeout: TimeInterval
    private let configuration: URLSessionConfiguration

    /// `timeout` est le délai sans octet reçu, pas la durée totale : un tour long reste ouvert tant que Hermes envoie ses `: keepalive`
    public init(baseURL: URL, apiKey: String? = nil, timeout: TimeInterval = 120, configuration: URLSessionConfiguration = .ephemeral, apiKeyForProfile: (@Sendable (String) throws -> String?)? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.apiKeyForProfile = apiKeyForProfile
        self.timeout = timeout
        self.configuration = configuration
    }

    // MARK: les six actions

    /// Ouvre un profil : vérifie qu'il est servi et lit son nom
    public func openProfile(_ id: String) async throws -> Profile {
        let body = try await call(.profileServed, ["profile": id])
        return try Profile.decode(body, requestedID: id)
    }

    /// Hermes plafonne `limit` à 200 (observé : limit=500 rend limit=200, défaut 50) : les pages suivantes se lisent par `offset` tant que `has_more` est vrai
    static let sessionPageSize = 200
    // ponytail: 50 pages (10 000 fils) au plus, pour qu'un serveur qui répond toujours `has_more` ne boucle pas ; relever la borne si un profil la dépasse
    static let maxSessionPages = 50

    /// Liste les fils d'un bot, les plus récents d'abord, toutes pages réunies ; la première page est classée comme la sonde de `capabilities`
    /// Une route absente ou une réponse de forme changée rend `.disabled`, jamais une erreur ; clé refusée, profil non servi et panne restent des erreurs, une page en échec comprise
    public func listSessions(profile: String) async throws -> SessionList {
        var sessions: [Session] = []
        var offset = 0
        for _ in 0..<Self.maxSessionPages {
            var query = [URLQueryItem(name: "limit", value: String(Self.sessionPageSize))]
            if offset > 0 { query.append(URLQueryItem(name: "offset", value: String(offset))) }
            let (status, body) = try await send(makeRequest(.listSessions, ["profile": profile], body: nil, query: query))
            switch try classify(.listSessions, status: status, body: body, profile: profile) {
            case .disabled(let message): return .disabled(message: message)
            case .available:
                let page = try Session.decodePage(body)
                sessions += page.sessions
                offset += page.entries
                // une page vide avec `has_more` ferait redemander le même offset sans fin
                if !page.hasMore || page.entries == 0 { return .sessions(sessions) }
            }
        }
        return .sessions(sessions)
    }

    /// Lit le transcript d'un fil : une seule page, la plus récente (Hermes en rend 500 au plus)
    // ponytail: pas de page suivante ; un fil de plus de 500 messages montre ses 500 derniers, lire `offset` si un profil le dépasse
    public func messages(profile: String, session: String) async throws -> [Message] {
        try Message.decodeList(await call(.sessionMessages, ["profile": profile, "session": session]))
    }

    public func newSession(profile: String) async throws -> Session {
        try Session.decode(await call(.newSession, ["profile": profile], body: [:]))
    }

    public func setModel(profile: String, session: String, model: String) async throws -> ModelLock {
        let body = try await call(.setModel, ["profile": profile, "session": session], body: ["model": model])
        return try ModelLock.decode(body, session: session, model: model)
    }

    /// Envoie un message par le chat de session (il lit le verrou de modèle, S4) et rend la réponse entière
    public func send(profile: String, session: String, text: String) async throws -> Reply {
        guard !text.isEmpty else { throw HermesError.emptyMessage }
        let body = try await call(.sendMessage, ["profile": profile, "session": session], body: ["input": text])
        return try Reply.decode(body, session: session)
    }

    /// Lit les événements d'un tour jusqu'à son état final
    /// Avec `stopAtApproval`, rend la main dès qu'une demande d'approbation arrive, car le tour attend alors la réponse
    /// `onUpdate` reçoit le tour après chaque événement qui le change (texte, approbation, état), pas après un événement inconnu ; la lecture attend son retour
    public func readTurn(profile: String, run: String, stopAtApproval: Bool = false, onEvent: (@Sendable (Data) async -> Bool)? = nil, onUpdate: (@Sendable (Turn) async -> Void)? = nil) async throws -> Turn {
        let variables = ["profile": profile, "run": run]
        let request = try makeRequest(.runEvents, variables, body: nil)
        var reader = TurnReader(runID: run, stopAtApproval: stopAtApproval)
        var parser = SSEParser()
        var status = 0
        var errorBody = Data()
        do {
            reading: for try await part in open(request) {
                switch part {
                case .head(let code):
                    status = code
                case .body(let chunk):
                    guard (200..<300).contains(status) else { errorBody.append(chunk); continue }
                    for frame in parser.feed(chunk) {
                        if case .data(let data) = frame, let onEvent, !(await onEvent(data)) { break reading }
                        let before = reader.changes
                        let stop = reader.apply(frame)
                        if reader.changes != before { await onUpdate?(reader.turn) }
                        if stop { break reading }
                    }
                }
            }
        } catch let error as URLError {
            // le flux est coupé après l'événement terminal, sans le marqueur de fin : le tour est fini
            if !reader.turn.state.isTerminal { throw unreachable(error) }
        }
        guard (200..<300).contains(status) else { throw httpError(.runEvents, status, errorBody, variables) }
        return reader.turn
    }

    public func approve(profile: String, run: String, request: ApprovalRequest, choice: String) async throws -> ApprovalResult {
        var payload: [String: Any] = ["request_id": request.requestID, "choice": choice]
        if let generation = request.executionGeneration { payload["execution_generation"] = generation }
        let body = try await call(.approve, ["profile": profile, "run": run], body: payload)
        return try ApprovalResult.decode(body, request: request, choice: choice)
    }

    // MARK: tour à événements

    /// Démarre un tour à événements (`start_run`) et rend l'identifiant du run, à lire avec `readTurn`
    /// Avec `session`, le tour continue ce fil (S5) ; sans, Hermes ouvre un fil dont l'identifiant est celui du run (S1)
    /// Avec `model`, le run part avec ce modèle : `POST /v1/runs` ignore le verrou de modèle de la session (S4, observé sur 0.22.2)
    public func startRun(profile: String, input: String, session: String? = nil, model: String? = nil) async throws -> String {
        guard !input.isEmpty else { throw HermesError.emptyMessage }
        var payload: [String: Any] = ["input": input]
        if let session { payload["session_id"] = session }
        if let model { payload["model"] = model }
        let body = try await call(.startRun, ["profile": profile], body: payload)
        guard let id = JSONObject(body)?.string("run_id"), !id.isEmpty else {
            throw HermesError.decoding(contract: Contract.startRun.rawValue, detail: "run_id absent")
        }
        return id
    }

    // MARK: transport

    private enum Part {
        case head(Int)
        case body(Data)
    }

    private final class Collector: NSObject, URLSessionDataDelegate {
        private let continuation: AsyncThrowingStream<Part, Error>.Continuation

        init(_ continuation: AsyncThrowingStream<Part, Error>.Continuation) { self.continuation = continuation }

        // pas de sous-classe de RedirectGuard : sous Linux, une sous-classe qui ajoute des méthodes de délégué ne les voit pas appelées
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(RedirectGuard.target(of: task, redirectedTo: request))
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            continuation.yield(.head((response as? HTTPURLResponse)?.statusCode ?? 0))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            continuation.yield(.body(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
        }
    }

    // un URLSession par requête avec un délégué qui pousse les octets à mesure : `bytes(for:)` n'existe pas sur Linux
    private func open(_ request: URLRequest) -> AsyncThrowingStream<Part, Error> {
        let configuration = self.configuration
        return AsyncThrowingStream { continuation in
            let session = URLSession(configuration: configuration, delegate: Collector(continuation), delegateQueue: nil)
            continuation.onTermination = { _ in session.invalidateAndCancel() }
            session.dataTask(with: request).resume()
        }
    }

    func makeRequest(_ contract: Contract, _ variables: [String: String], body: [String: Any]?, query: [URLQueryItem] = []) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw HermesError.unreachable(url: baseURL.absoluteString, reason: "URL de base invalide")
        }
        components.percentEncodedPath = contract.resolve(variables)
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            throw HermesError.unreachable(url: baseURL.absoluteString, reason: "URL invalide pour \(contract.rawValue)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = contract.method
        request.timeoutInterval = timeout
        let key: String?
        if let profile = variables["profile"], let apiKeyForProfile { key = try apiKeyForProfile(profile) }
        else { key = apiKey }
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        if contract == .runEvents { request.setValue("text/event-stream", forHTTPHeaderField: "Accept") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// Une seule requête, aucun nouvel essai : un renvoi automatique d'un POST doublerait le message
    private func call(_ contract: Contract, _ variables: [String: String], body: [String: Any]? = nil) async throws -> Data {
        let (status, data) = try await send(makeRequest(contract, variables, body: body))
        guard (200..<300).contains(status) else { throw httpError(contract, status, data, variables) }
        return data
    }

    /// Rend le statut et le corps sans juger le statut : seule une panne de transport lève une erreur
    func send(_ request: URLRequest) async throws -> (status: Int, data: Data) {
        var status = 0
        var data = Data()
        do {
            for try await part in open(request) {
                switch part {
                case .head(let code): status = code
                case .body(let chunk): data.append(chunk)
                }
            }
        } catch let error as URLError {
            throw unreachable(error)
        }
        return (status, data)
    }

    private func unreachable(_ error: URLError) -> HermesError {
        .unreachable(url: baseURL.absoluteString, reason: error.code == .timedOut ? "délai dépassé" : error.localizedDescription)
    }

    func httpError(_ contract: Contract, _ status: Int, _ body: Data, _ variables: [String: String]) -> HermesError {
        if contract == .profileServed, status == 404, let profile = variables["profile"] { return .profileNotServed(profile) }
        var detail: String?
        if let object = JSONObject(body) {
            detail = object.string("error") ?? object.object("error")?.string("message")
        }
        return .http(contract: contract.rawValue, status: status, detail: detail)
    }
}
