import Foundation

// Décodage tolérant : un champ inconnu est ignoré, un champ attendu mais absent ou d'un autre type prend sa valeur
// par défaut. Seul un identifiant que le client ne peut pas deviner (session, run) fait échouer le décodage

struct JSONObject {
    let raw: [String: Any]

    init(_ raw: [String: Any]) { self.raw = raw }

    init?(_ data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        raw = object
    }

    func string(_ key: String) -> String? { raw[key] as? String }
    func int(_ key: String) -> Int? { raw[key] as? Int }
    func object(_ key: String) -> JSONObject? { (raw[key] as? [String: Any]).map(JSONObject.init) }
    func strings(_ key: String) -> [String]? { (raw[key] as? [Any])?.compactMap { $0 as? String } }
}

private func nonEmpty(_ value: String?) -> String? { value.flatMap { $0.isEmpty ? nil : $0 } }

private func root(_ data: Data, _ contract: Contract) throws -> JSONObject {
    guard let object = JSONObject(data) else {
        throw HermesError.decoding(contract: contract.rawValue, detail: "le corps n'est pas un objet JSON")
    }
    return object
}

extension Profile {
    /// `display_name` n'apparaît dans aucune réponse observée de Hermes : l'id du profil le remplace
    static func decode(_ data: Data, requestedID: String) throws -> Profile {
        let entry = ((try root(data, .profileServed)).raw["data"] as? [Any])?.first as? [String: Any]
        let name = nonEmpty(entry.flatMap(JSONObject.init)?.string("display_name"))
        return Profile(id: requestedID, displayName: name ?? requestedID)
    }
}

extension Session {
    static func decode(_ data: Data) throws -> Session {
        guard let session = try root(data, .newSession).object("session"), let id = nonEmpty(session.string("id")) else {
            throw HermesError.decoding(contract: Contract.newSession.rawValue, detail: "session.id absent")
        }
        return Session(id: id, title: session.string("title"), model: nonEmpty(session.string("model")))
    }
}

/// Une page de `list_sessions` : `entries` compte les entrées du serveur, `offset` de la page suivante se calcule dessus
struct SessionPage: Equatable {
    let sessions: [Session]
    let entries: Int
    let hasMore: Bool
}

extension Session {
    /// Une entrée sans identifiant est ignorée : aucun fil n'est inventé. Un titre vide vaut pas de titre
    /// Un `has_more` absent ou qui n'est pas un booléen vaut « pas de page suivante »
    static func decodePage(_ data: Data) throws -> SessionPage {
        let body = try root(data, .listSessions)
        guard let entries = body.raw["data"] as? [Any] else {
            throw HermesError.decoding(contract: Contract.listSessions.rawValue, detail: "data n'est pas une liste")
        }
        let sessions: [Session] = entries.compactMap { entry in
            guard let entry = (entry as? [String: Any]).map(JSONObject.init), let id = nonEmpty(entry.string("id")) else { return nil }
            return Session(id: id, title: nonEmpty(entry.string("title")), model: nonEmpty(entry.string("model")))
        }
        return SessionPage(sessions: sessions, entries: entries.count, hasMore: body.raw["has_more"] as? Bool ?? false)
    }
}

extension Message {
    /// Seuls les rôles `user` et `assistant` portant un texte sont des messages à montrer : une ligne `tool`, `session_meta` (0.22.1) ou sans contenu est ignorée
    /// Une entrée sans identifiant entier est ignorée aussi : aucun numéro n'est inventé
    static func decodeList(_ data: Data) throws -> [Message] {
        guard let entries = try root(data, .sessionMessages).raw["data"] as? [Any] else {
            throw HermesError.decoding(contract: Contract.sessionMessages.rawValue, detail: "data n'est pas une liste")
        }
        return entries.compactMap { entry in
            guard let entry = (entry as? [String: Any]).map(JSONObject.init), let id = entry.int("id"),
                  let role = entry.string("role").flatMap(Role.init(rawValue:)), let text = nonEmpty(entry.string("content")) else { return nil }
            return Message(id: id, role: role, text: text)
        }
    }
}

extension Reply {
    static func decode(_ data: Data, session: String) throws -> Reply {
        let body = try root(data, .sendMessage)
        let model = nonEmpty(body.object("runtime")?.string("model")) ?? nonEmpty(body.object("usage")?.object("runtime")?.string("model"))
        return Reply(
            sessionID: nonEmpty(body.string("session_id")) ?? session,
            text: body.object("message")?.string("content") ?? "",
            model: model
        )
    }
}

extension ModelLock {
    static func decode(_ data: Data, session: String, model: String) throws -> ModelLock {
        let body = try root(data, .setModel)
        return ModelLock(
            sessionID: nonEmpty(body.string("session_id")) ?? session,
            model: nonEmpty(body.object("runtime")?.string("model")) ?? model
        )
    }
}

extension ApprovalResult {
    /// 0.22.2 répond `resolved: 1`, 0.22.1 répond `status: "resolved"`
    static func decode(_ data: Data, request: ApprovalRequest, choice: String) throws -> ApprovalResult {
        let body = try root(data, .approve)
        let resolved: Bool
        if let count = body.int("resolved") {
            resolved = count > 0
        } else if let status = body.string("status") {
            resolved = status == "resolved"
        } else {
            resolved = true
        }
        return ApprovalResult(requestID: request.requestID, choice: body.string("choice") ?? choice, resolved: resolved)
    }
}

enum TurnEvent: Equatable {
    case text(String)
    case approvalRequest(ApprovalRequest)
    case approvalAnswered
    case toolStarted(String)
    case toolFinished(String)
    case finished(TurnState, output: String?, error: String?)
    case other(String)

    /// nil pour une donnée qui n'est pas un objet JSON, `.other` pour un type d'événement inconnu
    static func decode(_ json: Data) -> TurnEvent? {
        guard let event = JSONObject(json) else { return nil }
        let name = event.string("event") ?? ""
        switch name {
        case "message.delta":
            return event.string("delta").map(TurnEvent.text) ?? .other(name)
        case "approval.request":
            // 0.22.2 nomme l'identifiant `request_id`, 0.22.1 `prompt_id`
            guard let id = nonEmpty(event.string("request_id")) ?? nonEmpty(event.string("prompt_id")) else { return .other(name) }
            return .approvalRequest(ApprovalRequest(
                requestID: id,
                executionGeneration: event.int("execution_generation"),
                command: event.string("command") ?? "",
                description: event.string("description") ?? "",
                choices: event.strings("choices") ?? [],
                tool: nonEmpty(event.string("tool"))
            ))
        case "approval.responded", "approval.settled":
            return .approvalAnswered
        case "tool.started":
            return nonEmpty(event.string("tool")).map(TurnEvent.toolStarted) ?? .other(name)
        case "tool.completed":
            return nonEmpty(event.string("tool")).map(TurnEvent.toolFinished) ?? .other(name)
        case "run.completed":
            // un `status` terminal connu l'emporte sur le nom de l'événement
            let status = event.string("status").flatMap(TurnState.init(rawValue:))
            return .finished(status.flatMap { $0.isTerminal ? $0 : nil } ?? .completed, output: event.string("output"), error: event.string("error"))
        case "run.failed":
            return .finished(.failed, output: event.string("output"), error: event.string("error"))
        case "run.cancelled":
            return .finished(.cancelled, output: event.string("output"), error: event.string("error"))
        case "run.interrupted":
            return .finished(.interrupted, output: event.string("output"), error: event.string("error"))
        default:
            return .other(name)
        }
    }
}

enum SSEFrame: Equatable {
    case comment(String)
    case data(Data)
}

/// Découpe un flux `text/event-stream` reçu par morceaux en trames
struct SSEParser {
    private var pending = Data()
    private var dataLines: [Data] = []

    mutating func feed(_ chunk: Data) -> [SSEFrame] {
        var buffer = pending
        buffer.append(chunk)
        var frames: [SSEFrame] = []
        var consumed = 0
        buffer.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            while consumed < bytes.count, let hit = memchr(base + consumed, 0x0A, bytes.count - consumed) {
                let end = base.distance(to: UnsafeRawPointer(hit))
                var line = UnsafeRawBufferPointer(start: base + consumed, count: end - consumed)
                if line.last == 0x0D { line = UnsafeRawBufferPointer(rebasing: line.dropLast()) }
                handle(line, into: &frames)
                consumed = end + 1
            }
        }
        pending = Data(buffer.suffix(from: buffer.startIndex + consumed))
        return frames
    }

    private mutating func handle(_ line: UnsafeRawBufferPointer, into frames: inout [SSEFrame]) {
        if line.isEmpty {
            if !dataLines.isEmpty {
                frames.append(.data(dataLines.count == 1 ? dataLines[0] : Data(dataLines.joined(separator: [0x0A]))))
                dataLines = []
            }
        } else if line[0] == 0x3A {  // ':' commence un commentaire
            let text = String(decoding: UnsafeRawBufferPointer(rebasing: line.dropFirst()), as: UTF8.self)
            frames.append(.comment(text.trimmingCharacters(in: .whitespaces)))
        } else if line.starts(with: "data:".utf8) {
            var value = UnsafeRawBufferPointer(rebasing: line.dropFirst(5))
            if value.first == 0x20 { value = UnsafeRawBufferPointer(rebasing: value.dropFirst()) }
            dataLines.append(Data(value))
        }
        // `id:`, `event:` et `retry:` ne servent pas : le numéro de séquence est aussi dans les données
    }
}

/// Assemble un tour à partir des trames du flux `run_events`
struct TurnReader {
    private(set) var turn: Turn
    /// Compte les événements qui ont changé le tour : le lecteur sait ainsi quand rendre la main sans comparer le texte entier
    private(set) var changes = 0
    private let stopAtApproval: Bool
    private var terminalOutput: String?
    /// Les outils lancés qui n'ont pas fini, dans l'ordre de lancement : `tool.completed` ne porte pas d'identifiant d'appel en 0.22.2, il se rapporte au nom
    private var running: [String] = []

    init(runID: String, stopAtApproval: Bool = false) {
        turn = Turn(runID: runID, text: "", state: .running, error: nil, approvals: [], tool: nil)
        self.stopAtApproval = stopAtApproval
    }

    /// Renvoie vrai quand la lecture doit s'arrêter : marqueur de fin de flux, ou demande d'approbation si elle est demandée
    mutating func apply(_ frame: SSEFrame) -> Bool {
        switch frame {
        case .comment(let text):
            return text == "stream closed"
        case .data(let data):
            guard let event = TurnEvent.decode(data) else { return false }
            return apply(event)
        }
    }

    private mutating func apply(_ event: TurnEvent) -> Bool {
        switch event {
        case .text(let delta):
            turn.text += delta
            changes += 1
        case .approvalRequest(var request):
            request.tool = request.tool ?? turn.tool
            turn.approvals.append(request)
            turn.state = .waitingForApproval
            changes += 1
            return stopAtApproval
        case .approvalAnswered:
            if turn.state == .waitingForApproval {
                turn.state = .running
                changes += 1
            }
        case .toolStarted(let name):
            running.append(name)
            turn.tool = name
            changes += 1
        case .toolFinished(let name):
            // une fin sans début ne change rien
            if let index = running.lastIndex(of: name) {
                running.remove(at: index)
                turn.tool = running.last
                changes += 1
            }
        case .finished(let state, let output, let error):
            changes += 1
            running = []
            turn.tool = nil
            // Hermes envoie un seul événement terminal par tour : le faux serveur en ajoute après celui de la fixture, le dernier gagne
            turn.state = state
            turn.error = error
            if let output { terminalOutput = output }
            if turn.text.isEmpty, let terminalOutput { turn.text = terminalOutput }
        case .other:
            break
        }
        return false
    }
}

public enum ProfileTable {
    /// Lit la table de `hermes profile list` : les profils au Gateway `stopped` sont décommissionnés et exclus (décision S6)
    /// Un texte non vide sans l'en-tête `Profile ... Gateway` n'est pas la table (message d'erreur, bannière) : erreur, jamais un bot
    /// Une ligne qui n'a pas la forme d'une ligne de profil (avertissement après la table) est ignorée
    /// Une table sans ligne, ou un texte vide, est une liste vide
    public static func parse(_ text: String) throws -> [Profile] {
        var tail: Int?  // nombre de colonnes après Gateway
        var sawOtherText = false
        var profiles: [Profile] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if line.allSatisfy({ $0 == "─" || $0 == " " }) { continue }
            let cells = line.components(separatedBy: "  ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard let first = cells.first else { continue }
            if first == "Profile", let gateway = cells.firstIndex(of: "Gateway") {
                tail = cells.count - gateway - 1
                continue
            }
            guard let tail else {
                sawOtherText = true
                continue
            }
            if let row = row(line, tail: tail), row.state == "running" { profiles.append(row.profile) }
        }
        if tail == nil, sawOtherText {
            throw HermesError.decoding(contract: "list_profiles", detail: "l'en-tête Profile ... Gateway est absent")
        }
        return profiles
    }

    /// Une ligne de profil : `[◆] libellé modèle état` puis `tail` colonnes d'un mot (alias, distribution), comme `_profile_list` de Hermes
    /// Le libellé est `nom affiché (identifiant)`, ou l'identifiant seul quand il n'y a pas de nom affiché (`format_profile_label`)
    /// Hermes remplit la colonne Model à 28 caractères (modèle coupé à 26) et met un espace avant l'état
    /// Le modèle commence donc 29 caractères avant l'état, et le libellé finit juste avant lui, quelle que soit la largeur du libellé
    /// L'état se repère depuis la fin de la ligne : un nom affiché peut contenir `running`, `stopped` ou des espaces
    /// Le modèle se sépare du libellé avant la lecture de l'identifiant : un modèle peut contenir des espaces et des `(mot)`
    /// Une ligne dont la colonne Model est plus large que Hermes ne l'écrit se lit seulement sans parenthèse : le libellé est alors l'identifiant seul
    /// Limite : un alias ou une distribution à espaces se lit de travers
    private static func row(_ line: Substring, tail: Int) -> (profile: Profile, state: Substring)? {
        let words = line.split(separator: " ")
        guard words.count >= tail + 3, case let state = words[words.count - 1 - tail], state == "running" || state == "stopped" else { return nil }
        let scalars = line.unicodeScalars  // Hermes compte en points de code (Python), pas en caractères
        let label: String, model: String
        if let start = scalars.index(state.startIndex, offsetBy: -29, limitedBy: scalars.startIndex), start > scalars.startIndex,
           scalars[start] != " ", scalars[scalars.index(before: start)] == " " {
            (label, model) = (unmarked(String(scalars[..<start])), String(scalars[start..<state.startIndex]).trimmingCharacters(in: .whitespaces))
        } else if let match = unmarked(String(line[..<state.startIndex])).wholeMatch(of: #/([^\s()]+)\s+([^()]*\S)/#) {
            (label, model) = (String(match.1), String(match.2))
        } else {
            return nil
        }
        let id: String, name: String
        if let match = label.wholeMatch(of: #/(.*) \(([a-z0-9][a-z0-9_-]{0,63})\)/#) {
            (name, id) = (String(match.1), String(match.2))
        } else if !label.isEmpty, !label.contains(where: \.isWhitespace) {
            (id, name) = (label, label)
        } else {
            return nil
        }
        return (Profile(id: id, displayName: name, model: model == "—" ? nil : model), state)
    }

    /// Le texte sans espaces de bord ni marqueur `◆` du profil par défaut
    private static func unmarked(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        return text.first == "◆" ? String(text.dropFirst()).trimmingCharacters(in: .whitespaces) : text
    }
}
