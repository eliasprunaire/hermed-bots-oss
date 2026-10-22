import Foundation
import HermesAdapter
import LoopGuard
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Pilote HermesAdapter depuis un terminal : une commande par action, une ligne `clé: valeur` par résultat
// Codes de sortie : 0 réussi, 1 échec, 2 usage, 22 cible interdite (même code que hv-guard.sh target)

let usage = """
usage : hd-probe <commande> --url <URL> [options]

commandes :
  list-profiles [--profile-cmd "<préfixe>"]   profils actifs (hermes profile list ; sans préfixe, route de test /_hv/profile-list du faux serveur)
  open-profile                                 vérifie que --profile est servi
  list-sessions [--session <S>]                fils passés de --profile, toutes pages réunies (nombre, premier, dernier) ; avec --session, le modèle que la liste donne à ce fil
  new-session                                  crée une session
  set-model --model <M> [--session <S>]        verrouille le modèle de la session
  send --text <T> [--session <S>]              envoie un message et affiche la réponse
  read-turn (--run <R> | --input <T> [--session <S>] [--model <M>]) [--stop-at-approval]
                                               avec --input, démarre un tour ; avec --session, il continue ce fil ; avec --model, le run part avec ce modèle (`POST /v1/runs` ignore le verrou de la session, S4)
  messages --session <S>                       transcript du fil : une ligne `message: <id> <rôle> <texte>` par message
  approve (--run <R> | --input <T>) [--request-id <I>] [--generation <N>] [--choice <C>]
  capabilities                                 lit la version puis sonde chaque contrat sans rien créer (une ligne par contrat)
  loop-guard --events <fichier|-> [--history <fichier>] [--now <epoch>] [--cancel-run available|dropped]
                                               juge un tour avec le garde de boucle, hors ligne : sans --url, flux SSE lu dans un fichier ou sur stdin
                                               sur stdin, l'heure est relue à chaque ligne et toutes les 0,25 s ; --now fige l'heure (rejeu)

options communes : --profile <P> (hv-bot-a), --timeout <secondes> (120)
environnement : HV_TEST_API_KEY (clé Bearer, jamais affichée)
"""

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("hd-probe : \(message)\n".utf8))
    exit(code)
}

func usageError(_ message: String) -> Never {
    FileHandle.standardError.write(Data("hd-probe : \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

let valueOptions: Set<String> = [
    "url", "profile", "profile-cmd", "session", "model", "text", "run", "input", "request-id", "generation", "choice", "timeout",
    "events", "history", "now", "cancel-run",
]
let flagOptions: Set<String> = ["stop-at-approval"]

func parse(_ input: [String]) -> (command: String, values: [String: String], flags: Set<String>) {
    var arguments = input
    guard !arguments.isEmpty, !arguments[0].hasPrefix("-") else { usageError("commande absente") }
    let command = arguments.removeFirst()
    var values: [String: String] = [:]
    var flags: Set<String> = []
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        guard argument.hasPrefix("--") else { usageError("argument inattendu : \(argument)") }
        let name = String(argument.dropFirst(2))
        if flagOptions.contains(name) {
            flags.insert(name)
        } else if valueOptions.contains(name) {
            guard !arguments.isEmpty else { usageError("--\(name) demande une valeur") }
            values[name] = arguments.removeFirst()
        } else {
            usageError("option inconnue : \(argument)")
        }
    }
    return (command, values, flags)
}

let (command, values, flags) = parse(Array(CommandLine.arguments.dropFirst()))

// Garde de boucle : une pause est un résultat, pas un échec, donc le code de sortie reste 0
// Sur stdin, la lecture s'arrête à la première pause, au dernier événement du tour, au marqueur de fin de flux ou à la fin de stdin
// Sans --now, l'heure est relue à chaque évaluation et un flux ouvert et silencieux est jugé toutes les 0,25 s
// ponytail: tick fixe de 0,25 s au lieu de l'échéance exacte, la pause arrive au plus 0,25 s après la limite
final class StdinLines {
    private let lock = NSLock()
    private var pending: [String] = []
    private var ended = false
    let wake = DispatchSemaphore(value: 0)

    init() {
        // read(2) et non readLine() : un fil bloqué dans readLine() tient le verrou de stdin, et exit() l'attend sous Linux
        Thread.detachNewThread {
            var buffer = Data()
            var bytes = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = read(STDIN_FILENO, &bytes, bytes.count)
                if count < 0, errno == EINTR { continue }
                if count <= 0 { break }
                buffer.append(contentsOf: bytes[0..<count])
                while let newline = buffer.firstIndex(of: 10) {
                    self.push(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self), ended: false)
                    buffer.removeSubrange(buffer.startIndex...newline)
                }
            }
            self.push(buffer.isEmpty ? nil : String(decoding: buffer, as: UTF8.self), ended: true)
        }
    }

    private func push(_ line: String?, ended: Bool) {
        lock.lock()
        if let line { pending.append(line) }
        if ended { self.ended = true }
        lock.unlock()
        wake.signal()
    }

    func drain() -> (lines: [String], ended: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let lines = pending
        pending = []
        return (lines, ended)
    }
}

func loopGuard() -> Never {
    guard let source = values["events"] else { usageError("--events est obligatoire pour loop-guard (un fichier SSE, ou - pour stdin)") }
    var history: [LoopGuard.TurnStats] = []
    if let path = values["history"] {
        guard let data = FileManager.default.contents(atPath: path), let stats = LoopGuard.TurnStats.decodeList(data) else {
            fail("--history : fichier illisible ou forme inattendue (attendu : une liste de {\"tool_calls\": n, \"tokens\": n} avec des entiers de 0 à 10^12)")
        }
        history = stats
    }
    var fixedNow: TimeInterval?
    if let text = values["now"] {
        guard let epoch = TimeInterval(text), abs(epoch) <= LoopGuard.maxEpochSeconds else {
            usageError("--now attend un nombre de secondes depuis 1970, fini et d'au plus 10^15 en valeur absolue")
        }
        fixedNow = epoch
    }
    let canStopRun: Bool
    switch values["cancel-run"] ?? "available" {
    case "available": canStopRun = true
    case "dropped": canStopRun = false
    default: usageError("--cancel-run attend available ou dropped")
    }
    func judge(_ events: [LoopGuard.Event]) -> LoopGuard.Report {
        LoopGuard.evaluate(events: events, history: history, now: fixedNow ?? Date().timeIntervalSince1970, canStopRun: canStopRun)
    }

    var report: LoopGuard.Report
    if source == "-" {
        var events: [LoopGuard.Event] = []
        let input = StdinLines()
        while true {
            _ = input.wake.wait(timeout: fixedNow == nil ? .now() + 0.25 : .distantFuture)
            let (lines, ended) = input.drain()
            var done = false
            for line in lines {
                if line.hasPrefix(":") {
                    done = line.contains("stream closed")
                } else {
                    events += LoopGuard.Event.parse(sse: line)
                    done = events.last?.kind == .finished
                }
                if done { break }
            }
            report = judge(events)
            if done || ended { break }
            if case .pause = report.verdict { break }
        }
    } else {
        guard let text = try? String(contentsOfFile: source, encoding: .utf8) else { fail("--events : fichier illisible : \(source)") }
        report = judge(LoopGuard.Event.parse(sse: text))
    }

    print("thresholds: \(report.thresholds)")
    switch report.tokenSignal {
    case .active: print("tokens: active")
    case .disabled(let reason): print("tokens: disabled reason=\(reason)")
    }
    print(report.verdict)
    if case .pause(_, let remedy) = report.verdict {
        switch remedy {
        case .stopRun: print("remedy: stop-run (cancel_run disponible, l'utilisateur confirme, le garde n'annule rien)")
        case .suspendDisplayAndSend: print("remedy: suspend-display-and-send notify=yes kill-switch=offered (cancel_run absent)")
        }
    }
    exit(0)
}
if command == "loop-guard" { loopGuard() }

guard let urlText = values["url"], let baseURL = URL(string: urlText), let host = baseURL.host?.lowercased() else {
    usageError("--url est obligatoire (http://127.0.0.1:18642)")
}
// seules les cibles locales sont permises : conteneur OrbStack ou faux serveur, jamais perso-hermes
guard ["127.0.0.1", "localhost", "::1"].contains(host) else {
    fail("cible refusée : \(host) n'est pas une adresse locale", code: 22)
}

let profile = values["profile"] ?? "hv-bot-a"
var timeout: TimeInterval = 120
if let text = values["timeout"] {
    guard let seconds = TimeInterval(text), seconds > 0 else { usageError("--timeout attend un nombre de secondes") }
    timeout = seconds
}
let environmentKey = ProcessInfo.processInfo.environment["HV_TEST_API_KEY"]
let client = HermesClient(baseURL: baseURL, apiKey: environmentKey?.isEmpty == false ? environmentKey : nil, timeout: timeout)

func require(_ name: String) -> String {
    guard let value = values[name] else { usageError("--\(name) est obligatoire pour \(command)") }
    return value
}

func session() async throws -> String {
    if let given = values["session"] { return given }
    return try await client.newSession(profile: profile).id
}

func run() async throws -> String {
    if let given = values["run"] { return given }
    guard let input = values["input"] else { usageError("--run ou --input est obligatoire pour \(command)") }
    return try await client.startRun(profile: profile, input: input, session: values["session"], model: values["model"])
}

func describe(_ request: ApprovalRequest) -> String {
    let generation = request.executionGeneration.map(String.init) ?? "-"
    // l'outil qui demande : le nom de l'événement, sinon l'outil en cours du tour (HD-11) ; la commande est coupée à 80 caractères pour la lecture
    return "approval: \(request.requestID) generation=\(generation) tool=\(request.tool ?? "-") command=\(request.command.prefix(80)) choices=\(request.choices.joined(separator: ","))"
}

// la même garde de redirection que HermesClient : un 3xx vers une autre origine n'est pas suivi
let fetchSession = URLSession(configuration: .ephemeral, delegate: RedirectGuard(), delegateQueue: nil)

func fetch(_ url: URL) async throws -> (status: Int, body: Data) {
    try await withCheckedThrowingContinuation { continuation in
        fetchSession.dataTask(with: url) { data, response, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: ((response as? HTTPURLResponse)?.statusCode ?? 0, data ?? Data()))
            }
        }.resume()
    }
}

func profileTable() async throws -> String {
    guard let prefix = values["profile-cmd"] else {
        let status: Int
        let body: Data
        do {
            (status, body) = try await fetch(baseURL.appendingPathComponent("_hv/profile-list"))
        } catch let error as URLError {
            throw HermesError.unreachable(url: baseURL.absoluteString, reason: error.localizedDescription)
        }
        guard status == 200 else {
            throw HermesError.http(contract: "list_profiles", status: status, detail: "aucune route HTTP ne liste les profils (S6) : donner --profile-cmd")
        }
        return String(decoding: body, as: UTF8.self)
    }
    // pas de shell : le préfixe est découpé sur les espaces, la commande lue est toujours `hermes profile list`
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = prefix.split(separator: " ").map(String.init) + ["hermes", "profile", "list"]
    let output = Pipe()
    let errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    let table = output.fileHandleForReading.readDataToEndOfFile()
    let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        let detail = String(decoding: diagnostics.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        fail("le canal --profile-cmd a échoué (code \(process.terminationStatus))" + (detail.isEmpty ? "" : " : \(detail)"))
    }
    return String(decoding: table, as: UTF8.self)
}

do {
    switch command {
    case "list-profiles":
        for entry in try ProfileTable.parse(try await profileTable()) { print(entry.id) }
    case "open-profile":
        let opened = try await client.openProfile(profile)
        print("profile: \(opened.id)")
        print("display_name: \(opened.displayName)")
    case "list-sessions":
        switch try await client.listSessions(profile: profile) {
        case .sessions(let sessions):
            print("sessions: \(sessions.count)")
            print("first: \(sessions.first?.id ?? "-")")
            print("last: \(sessions.last?.id ?? "-")")
            print("distinct: \(Set(sessions.map(\.id)).count)")
            if let id = values["session"] { print("session-model: \(sessions.first { $0.id == id }.map { $0.model ?? "-" } ?? "absent")") }
        case .disabled(let message):
            print("disabled: \(message)")
        }
    case "new-session":
        print("session: \(try await client.newSession(profile: profile).id)")
    case "set-model":
        let id = try await session()
        let lock = try await client.setModel(profile: profile, session: id, model: require("model"))
        print("session: \(lock.sessionID)")
        print("model: \(lock.model)")
    case "send":
        let text = require("text")
        // le refus d'un message vide passe avant la création de la session : aucune requête ne part
        if text.isEmpty { throw HermesError.emptyMessage }
        let id = try await session()
        let reply = try await client.send(profile: profile, session: id, text: text)
        print("session: \(reply.sessionID)")
        print("model: \(reply.model ?? "-")")
        print("reply: \(reply.text)")
    case "messages":
        for message in try await client.messages(profile: profile, session: require("session")) { print("message: \(message.id) \(message.role) \(message.text)") }
    case "read-turn":
        let id = try await run()
        let turn = try await client.readTurn(profile: profile, run: id, stopAtApproval: flags.contains("stop-at-approval"))
        print("run: \(turn.runID)")
        print("state: \(turn.state.rawValue)")
        for request in turn.approvals { print(describe(request)) }
        if let error = turn.error { print("error: \(error)") }
        print("text: \(turn.text)")
        if turn.state == .running { fail("le flux s'est terminé avant l'état final du tour") }
    case "approve":
        let id = try await run()
        print("run: \(id)")
        let request: ApprovalRequest
        if let requestID = values["request-id"] {
            request = ApprovalRequest(requestID: requestID, executionGeneration: values["generation"].flatMap { Int($0) }, command: "", description: "", choices: [])
        } else {
            let turn = try await client.readTurn(profile: profile, run: id, stopAtApproval: true)
            guard let pending = turn.approvals.last else { fail("aucune demande d'approbation dans le run \(id) (état \(turn.state.rawValue))") }
            request = pending
            print(describe(pending))
        }
        // refuser est le choix par défaut : approuver demande un --choice explicite
        let result = try await client.approve(profile: profile, run: id, request: request, choice: values["choice"] ?? "deny")
        print("approved: request=\(result.requestID) choice=\(result.choice) resolved=\(result.resolved)")
        if !result.resolved { fail("le serveur n'avait aucune demande en attente pour \(result.requestID)") }
    case "capabilities":
        let map = try await client.capabilities(profile: profile)
        print("version: \(map.version ?? "absente") (\(map.isVersionKnown ? "connue" : "inconnue"))")
        var reasons: [String] = []
        if !map.isVersionKnown { reasons.append("version inconnue") }
        if map.entries.contains(where: { $0.state != .available }) { reasons.append("fonction désactivée") }
        print("degraded: " + (reasons.isEmpty ? "no" : "yes (\(reasons.joined(separator: ", ")))"))
        for entry in map.entries {
            switch entry.state {
            case .available: print("\(entry.contract.rawValue) available")
            case .disabled(let message): print("\(entry.contract.rawValue) disabled: \(message)")
            }
        }
    default:
        usageError("commande inconnue : \(command)")
    }
} catch let error as HermesError {
    fail("\(error)")
} catch {
    fail("\(error.localizedDescription)")
}
