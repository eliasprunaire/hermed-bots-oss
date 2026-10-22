import Foundation
import LoopGuard

typealias Event = LoopGuard.Event
typealias TurnStats = LoopGuard.TurnStats

func tool(_ preview: String = "ls /tmp", name: String = "terminal", at time: TimeInterval) -> Event {
    Event(kind: .toolStarted, timestamp: time, tool: name, preview: preview)
}

func message(at time: TimeInterval) -> Event { Event(kind: .assistantMessage, timestamp: time) }

func approvalRequested(at time: TimeInterval) -> Event { Event(kind: .approvalRequested, timestamp: time) }

func approvalAnswered(at time: TimeInterval) -> Event { Event(kind: .approvalAnswered, timestamp: time) }

func finished(at time: TimeInterval) -> Event { Event(kind: .finished, timestamp: time) }

/// Un événement quelconque qui porte un relevé de tokens, comme un événement injecté dans le flux
func usage(_ total: Int, at time: TimeInterval) -> Event { Event(kind: .other, timestamp: time, tokens: total) }

/// Vingt tours : p95 des appels d'outils = 9, médiane des tokens = 1 900
let twentyTurns: [TurnStats] = zip(
    [1, 2, 2, 3, 3, 3, 4, 4, 4, 5, 5, 5, 6, 6, 7, 7, 8, 8, 9, 10],
    [800, 900, 1000, 1100, 1200, 1300, 1400, 1500, 1600, 1800, 2000, 2200, 2400, 2600, 2800, 3000, 3200, 3600, 4000, 5200]
).map { TurnStats(toolCalls: $0, tokens: $1) }

func evaluate(_ events: [Event], history: [TurnStats] = [], now: TimeInterval? = nil, canStopRun: Bool = true) -> LoopGuard.Report {
    LoopGuard.evaluate(events: events, history: history, now: now ?? events.last?.timestamp ?? 0, canStopRun: canStopRun)
}

func fixture(_ name: String) throws -> String {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)")
    return try String(contentsOf: url, encoding: .utf8)
}
