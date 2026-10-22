import Foundation

// Garde de boucle : fonction pure sur les événements d'un tour et l'historique du profil
// Elle rend « continuer » ou « pause » avec une cause, et ne coupe jamais rien : l'app décide de la suite

public enum LoopGuard {
    public static let historyTurns = 20

    /// Bornes des nombres venus de l'extérieur : au-delà, la valeur n'est ni un horodatage ni un compte plausible
    /// Un horodatage ou une heure d'évaluation hors de ±10^15 s (ou non fini) est ignoré : le silence ne le juge pas
    /// Un compte de l'historique hors de 0...10^12 est rejeté à la lecture
    public static let maxEpochSeconds: TimeInterval = 1e15
    public static let maxCount = 1_000_000_000_000

    private static func plausible(_ seconds: TimeInterval?) -> TimeInterval? {
        seconds.flatMap { abs($0) <= maxEpochSeconds ? $0 : nil }
    }

    public struct Event: Equatable, Sendable {
        public enum Kind: Equatable, Sendable {
            case toolStarted, assistantMessage, approvalRequested, approvalAnswered, finished, other
        }

        public var kind: Kind
        public var timestamp: TimeInterval?
        public var tool: String?
        public var preview: String?
        public var tokens: Int?

        public init(kind: Kind, timestamp: TimeInterval? = nil, tool: String? = nil, preview: String? = nil, tokens: Int? = nil) {
            self.kind = kind
            self.timestamp = timestamp
            self.tool = tool
            self.preview = preview
            self.tokens = tokens
        }

        /// nil pour une donnée qui n'est pas un objet JSON, `.other` pour un événement inconnu
        /// L'identité d'un appel d'outil est (`tool`, `preview`) : le flux `run_events` ne donne pas les arguments (S1)
        /// Tout événement qui porte `usage.total_tokens` fournit un relevé de tokens (S10)
        public static func decode(_ json: Data) -> Event? {
            guard let object = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
            var event = Event(
                kind: .other,
                timestamp: plausible(number(object["timestamp"])),
                tokens: (object["usage"] as? [String: Any])?["total_tokens"] as? Int
            )
            switch object["event"] as? String ?? "" {
            case "tool.started":
                if let tool = object["tool"] as? String {
                    event.kind = .toolStarted
                    event.tool = tool
                    event.preview = object["preview"] as? String ?? ""
                }
            case "message.delta":
                event.kind = .assistantMessage
            case "approval.request":
                event.kind = .approvalRequested
            case "approval.responded", "approval.settled":
                event.kind = .approvalAnswered
            case "run.completed", "run.failed", "run.cancelled", "run.interrupted":
                event.kind = .finished
            default:
                break
            }
            return event
        }

        /// Lit un flux `text/event-stream` : une ligne `data:` par événement, arrêt au marqueur `: stream closed`
        public static func parse(sse text: String) -> [Event] {
            var events: [Event] = []
            for line in text.split(whereSeparator: \.isNewline) {
                if line.hasPrefix(":") {
                    if line.dropFirst().trimmingCharacters(in: .whitespaces) == "stream closed" { break }
                    continue
                }
                guard line.hasPrefix("data:") else { continue }
                var payload = line.dropFirst(5)
                if payload.first == " " { payload = payload.dropFirst() }
                if let event = decode(Data(payload.utf8)) { events.append(event) }
            }
            return events
        }

        private static func number(_ value: Any?) -> Double? {
            if let double = value as? Double { return double }
            return (value as? Int).map(Double.init)
        }
    }

    public struct TurnStats: Equatable, Sendable {
        public var toolCalls: Int
        public var tokens: Int?

        public init(toolCalls: Int, tokens: Int? = nil) {
            self.toolCalls = toolCalls
            self.tokens = tokens
        }

        /// Liste JSON d'objets `{"tool_calls": n, "tokens": n|null}`, un par tour ; nil si la forme est autre
        /// ou si un compte sort de 0...`maxCount`
        public static func decodeList(_ json: Data) -> [TurnStats]? {
            guard let list = (try? JSONSerialization.jsonObject(with: json)) as? [[String: Any]] else { return nil }
            var stats: [TurnStats] = []
            for entry in list {
                guard let calls = entry["tool_calls"] as? Int, (0...maxCount).contains(calls) else { return nil }
                var tokens: Int?
                if let raw = entry["tokens"], !(raw is NSNull) {
                    guard let count = raw as? Int, (0...maxCount).contains(count) else { return nil }
                    tokens = count
                }
                stats.append(TurnStats(toolCalls: calls, tokens: tokens))
            }
            return stats
        }
    }

    public struct Thresholds: Equatable, Sendable, CustomStringConvertible {
        public enum Basis: Equatable, Sendable {
            case coldStart(turns: Int)
            case history(turns: Int)
        }

        public static let isMeasured = false

        public static let coldStart = Thresholds(basis: .coldStart(turns: 0), repeatedCall: 3, toolCallLimit: 30, tokenLimit: 500_000, silenceSeconds: 300)

        public let basis: Basis
        public let repeatedCall: Int
        public let toolCallLimit: Int
        public let tokenLimit: Int
        public let silenceSeconds: Int

        /// Sous 20 tours d'historique, les valeurs de démarrage à froid s'appliquent
        /// Ensuite : appels d'outils au-delà de 3 fois le 95e centile, tokens au-delà de 5 fois la médiane
        /// Une base à zéro, négative ou dont le produit dépasse `Int` ne donne aucune limite utile : la valeur de démarrage à froid reste
        public init(history: [TurnStats]) {
            let cold = Thresholds.coldStart
            guard history.count >= LoopGuard.historyTurns else {
                self.init(basis: .coldStart(turns: history.count), repeatedCall: cold.repeatedCall, toolCallLimit: cold.toolCallLimit,
                          tokenLimit: cold.tokenLimit, silenceSeconds: cold.silenceSeconds)
                return
            }
            let calls = history.map(\.toolCalls).sorted()
            let p95 = calls[Int((0.95 * Double(calls.count)).rounded(.up)) - 1]
            let tokens = history.compactMap(\.tokens).sorted()
            let lower = tokens.isEmpty ? 0 : tokens[(tokens.count - 1) / 2]
            let upper = tokens.isEmpty ? 0 : tokens[tokens.count / 2]
            self.init(basis: .history(turns: history.count), repeatedCall: cold.repeatedCall,
                      toolCallLimit: Thresholds.times(3, p95) ?? cold.toolCallLimit,
                      tokenLimit: Thresholds.fiveTimesMedian(lower, upper) ?? cold.tokenLimit,
                      silenceSeconds: cold.silenceSeconds)
        }

        /// nil si la base n'est pas positive ou si le produit dépasse `Int`
        private static func times(_ factor: Int, _ base: Int) -> Int? {
            guard base > 0 else { return nil }
            let (product, overflow) = factor.multipliedReportingOverflow(by: base)
            return overflow ? nil : product
        }

        /// Partie entière de 5 × (lower + upper) / 2, sans somme qui déborde : la demi-unité d'une médiane paire compte
        /// Un total est un entier, donc `total > 507,5` équivaut à `total > 507`
        /// nil si une valeur est négative, si les deux sont nulles ou si le résultat dépasse `Int`
        private static func fiveTimesMedian(_ lower: Int, _ upper: Int) -> Int? {
            guard lower >= 0, upper > 0 else { return nil }
            // lower = 2a + r, upper = 2b + s : 5 × (a + b) + partie entière de 5 × (r + s) / 2
            let (whole, overflow) = (lower / 2 + upper / 2).multipliedReportingOverflow(by: 5)
            let (limit, overflowAdd) = whole.addingReportingOverflow(5 * (lower % 2 + upper % 2) / 2)
            return overflow || overflowAdd ? nil : limit
        }

        private init(basis: Basis, repeatedCall: Int, toolCallLimit: Int, tokenLimit: Int, silenceSeconds: Int) {
            self.basis = basis
            self.repeatedCall = repeatedCall
            self.toolCallLimit = toolCallLimit
            self.tokenLimit = tokenLimit
            self.silenceSeconds = silenceSeconds
        }

        public var description: String {
            let (name, turns): (String, Int)
            switch basis {
            case .coldStart(let count): (name, turns) = ("cold-start", count)
            case .history(let count): (name, turns) = ("history", count)
            }
            return "basis=\(name) turns=\(turns)/\(LoopGuard.historyTurns) measured=\(Thresholds.isMeasured ? "yes" : "no") "
                + "repeat=\(repeatedCall) tool-calls=\(toolCallLimit) tokens=\(tokenLimit) silence=\(silenceSeconds)s"
        }
    }

    public enum Cause: Equatable, Sendable, CustomStringConvertible {
        case repeatedToolCall(count: Int)
        case toolCount(count: Int, limit: Int)
        case tokens(total: Int, limit: Int)
        case silence(seconds: Int, limit: Int)

        public var description: String {
            switch self {
            case .repeatedToolCall(let count): return "cause=repeated-tool-call count=\(count)"
            case .toolCount(let count, let limit): return "cause=tool-count count=\(count) limit=\(limit)"
            case .tokens(let total, let limit): return "cause=tokens total=\(total) limit=\(limit)"
            case .silence(let seconds, let limit): return "cause=silence seconds=\(seconds) limit=\(limit)"
            }
        }
    }

    /// Ce que l'app peut faire du verdict ; le garde n'en exécute aucun
    public enum Remedy: Equatable, Sendable {
        /// `cancel_run` existe : l'app propose l'arrêt du tour, l'utilisateur confirme
        case stopRun
        /// Ni pause ni annulation côté serveur : l'app suspend l'affichage et l'envoi, notifie et propose le kill switch
        case suspendDisplayAndSend
    }

    public enum Verdict: Equatable, Sendable, CustomStringConvertible {
        case `continue`
        case pause(Cause, Remedy)

        public var description: String {
            switch self {
            case .continue: return "continue"
            case .pause(let cause, _): return "pause \(cause)"
            }
        }
    }

    /// Désactivé tant qu'aucun événement du flux ne porte de relevé de tokens (S10) ; les autres signaux restent actifs
    public enum TokenSignal: Equatable, Sendable {
        case active
        case disabled(reason: String)
    }

    public struct Report: Equatable, Sendable {
        public let thresholds: Thresholds
        public let tokenSignal: TokenSignal
        public let verdict: Verdict
    }

    /// Une passe sur les événements du tour, arrêtée à la première cause
    /// `now` est l'heure de l'évaluation (secondes depuis 1970) : le garde ne lit pas l'horloge
    /// Une heure ou un horodatage hors bornes (voir `maxEpochSeconds`) est ignoré ; les autres signaux restent actifs
    /// Le silence se compte depuis le dernier message de l'assistant, ou le premier événement ; il s'arrête pendant une approbation
    /// et il est ignoré une fois le tour terminé
    public static func evaluate(events: [Event], history: [TurnStats], now: TimeInterval, canStopRun: Bool) -> Report {
        let thresholds = Thresholds(history: history)
        let remedy: Remedy = canStopRun ? .stopRun : .suspendDisplayAndSend
        let silenceLimit = Double(thresholds.silenceSeconds)
        var cause: Cause?
        var toolCalls = 0
        var streak = 0
        var lastCall: (tool: String?, preview: String?)?
        var clock: TimeInterval?
        var waitingForApproval = false
        var finished = false

        scan: for event in events {
            let stamp = plausible(event.timestamp)
            if let time = stamp {
                if let start = clock {
                    if !waitingForApproval, !finished, time - start > silenceLimit {
                        cause = .silence(seconds: Int((time - start).rounded(.up)), limit: thresholds.silenceSeconds)
                        break scan
                    }
                } else {
                    clock = time
                }
            }
            if let total = event.tokens, total > thresholds.tokenLimit {
                cause = .tokens(total: total, limit: thresholds.tokenLimit)
                break scan
            }
            switch event.kind {
            case .toolStarted:
                toolCalls += 1
                streak = lastCall.map { $0.tool == event.tool && $0.preview == event.preview } == true ? streak + 1 : 1
                lastCall = (event.tool, event.preview)
                if streak >= thresholds.repeatedCall {
                    cause = .repeatedToolCall(count: streak)
                    break scan
                }
                if toolCalls > thresholds.toolCallLimit {
                    cause = .toolCount(count: toolCalls, limit: thresholds.toolCallLimit)
                    break scan
                }
            case .assistantMessage:
                clock = stamp ?? clock
            case .approvalRequested:
                waitingForApproval = true
            case .approvalAnswered:
                waitingForApproval = false
                clock = stamp ?? clock
            case .finished:
                finished = true
            case .other:
                break
            }
        }

        if cause == nil, !waitingForApproval, !finished, let start = clock, let end = plausible(now), end - start > silenceLimit {
            cause = .silence(seconds: Int((end - start).rounded(.up)), limit: thresholds.silenceSeconds)
        }
        let tokenSignal: TokenSignal = events.contains { $0.tokens != nil } ? .active : .disabled(reason: "no-usage-in-stream")
        return Report(thresholds: thresholds, tokenSignal: tokenSignal, verdict: cause.map { .pause($0, remedy) } ?? .continue)
    }
}
