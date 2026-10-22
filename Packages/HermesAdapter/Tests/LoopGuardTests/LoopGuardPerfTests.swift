import XCTest
import LoopGuard

final class LoopGuardPerfTests: XCTestCase {
    // Budget proposé par le plan : au plus 1 ms par événement au 95e centile de cinq passes sur 10 000 événements
    func testEvaluateStaysUnderOneMillisecondPerEvent() {
        var events: [Event] = []
        for index in 0..<10_000 {
            let time = Double(index) * 0.01
            events.append(index % 10 == 9 ? tool("commande \(index)", at: time) : message(at: time))
        }
        // l'historique donne un plafond d'appels qui laisse passer les 1 000 appels du flux
        let history = Array(repeating: TurnStats(toolCalls: 1_000, tokens: 1_000), count: 20)

        var perEvent: [Double] = []
        for _ in 0..<5 {
            let start = Date()
            let report = LoopGuard.evaluate(events: events, history: history, now: 100, canStopRun: true)
            perEvent.append(Date().timeIntervalSince(start) / Double(events.count))
            XCTAssertEqual(report.verdict, .continue)
        }
        perEvent.sort()
        let p95 = perEvent[Int((0.95 * Double(perEvent.count)).rounded(.up)) - 1]
        print("LoopGuardPerfTests: p95 \(String(format: "%.4f", p95 * 1000)) ms par événement sur 5 passes de 10 000 événements")
        XCTAssertLessThan(p95, 0.001)
    }
}
