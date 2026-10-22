import XCTest
import LoopGuard

// Les nombres venus de l'extérieur (flux SSE, historique, horloge) ne font jamais planter le garde
final class BoundsTests: XCTestCase {
    private func history(toolCalls: Int, tokens: Int?) -> [TurnStats] {
        Array(repeating: TurnStats(toolCalls: toolCalls, tokens: tokens), count: 20)
    }

    // MARK: horodatages et horloge

    func testATimestampBeyondTheBoundIsIgnoredNotTrusted() {
        let events = [message(at: 0), message(at: 1e100), message(at: 2e15), message(at: -2e15)]
        XCTAssertEqual(evaluate(events, now: 100).verdict, .continue)
        XCTAssertEqual(evaluate(events, now: 301).verdict, .pause(.silence(seconds: 301, limit: 300), .stopRun))
    }

    func testNonFiniteTimestampsAreIgnored() {
        let events = [message(at: 0), message(at: .infinity), message(at: .nan), message(at: -.infinity)]
        XCTAssertEqual(evaluate(events, now: 100).verdict, .continue)
        XCTAssertEqual(evaluate(events, now: 301).verdict, .pause(.silence(seconds: 301, limit: 300), .stopRun))
    }

    func testANonFiniteOrHugeNowLeavesOnlyTheSilenceSignalOff() {
        for now in [TimeInterval.infinity, -.infinity, .nan, 1e100] {
            XCTAssertEqual(evaluate([message(at: 0)], now: now).verdict, .continue)
            XCTAssertEqual(evaluate([tool(at: 0), tool(at: 1), tool(at: 2)], now: now).verdict, .pause(.repeatedToolCall(count: 3), .stopRun))
        }
    }

    func testTheBoundIsInclusive() {
        XCTAssertEqual(evaluate([message(at: 0)], now: 1e15).verdict, .pause(.silence(seconds: 1_000_000_000_000_000, limit: 300), .stopRun))
        XCTAssertEqual(evaluate([message(at: -1e15)], now: 1e15).verdict, .pause(.silence(seconds: 2_000_000_000_000_000, limit: 300), .stopRun))
    }

    func testDecodeDropsATimestampBeyondTheBound() throws {
        func decode(_ number: String) -> Event? { Event.decode(Data(#"{"event": "message.delta", "timestamp": \#(number)}"#.utf8)) }
        for text in ["1e100", "-1e100", "2e15"] {
            let event = try XCTUnwrap(decode(text), text)
            XCTAssertEqual(event.kind, .assistantMessage, text)
            XCTAssertNil(event.timestamp, text)
        }
        XCTAssertEqual(try XCTUnwrap(decode("1500.5")).timestamp, 1500.5)
        XCTAssertEqual(try XCTUnwrap(decode("1e15")).timestamp, 1e15)
        // JSONSerialization lit ce nombre comme un infini ou le refuse : ni plantage ni horodatage
        XCTAssertNil(decode("1e15000")?.timestamp)
    }

    // MARK: historique

    func testHugeToolCountsKeepTheColdStartLimitWithoutTrapping() {
        let thresholds = LoopGuard.Thresholds(history: history(toolCalls: .max, tokens: 1_000))
        XCTAssertEqual(thresholds.basis, .history(turns: 20))
        XCTAssertEqual(thresholds.toolCallLimit, LoopGuard.Thresholds.coldStart.toolCallLimit)
        XCTAssertEqual(thresholds.tokenLimit, 5_000)
    }

    func testHugeTokenCountsKeepTheColdStartLimitWithoutTrapping() {
        // la médiane de deux Int.max dépasse Int en somme : la moyenne se calcule sans dépassement
        let thresholds = LoopGuard.Thresholds(history: history(toolCalls: 2, tokens: .max))
        XCTAssertEqual(thresholds.tokenLimit, LoopGuard.Thresholds.coldStart.tokenLimit)
        XCTAssertEqual(thresholds.toolCallLimit, 6)
    }

    func testTheLimitsFollowTheHistoryUpToTheLastValueThatFits() {
        XCTAssertEqual(LoopGuard.Thresholds(history: history(toolCalls: Int.max / 3, tokens: nil)).toolCallLimit, 3 * (Int.max / 3))
        XCTAssertEqual(LoopGuard.Thresholds(history: history(toolCalls: Int.max / 3 + 1, tokens: nil)).toolCallLimit, LoopGuard.Thresholds.coldStart.toolCallLimit)
        XCTAssertEqual(LoopGuard.Thresholds(history: history(toolCalls: 1, tokens: Int.max / 5)).tokenLimit, 5 * (Int.max / 5))
        XCTAssertEqual(LoopGuard.Thresholds(history: history(toolCalls: 1, tokens: Int.max / 5 + 1)).tokenLimit, LoopGuard.Thresholds.coldStart.tokenLimit)
    }

    func testAHalfUnitMedianStaysExactUpToTheLastLimitThatFits() {
        let m = Int.max / 5
        func limit(_ lower: Int, _ upper: Int) -> Int {
            let mixed = Array(repeating: TurnStats(toolCalls: 1, tokens: lower), count: 10) + Array(repeating: TurnStats(toolCalls: 1, tokens: upper), count: 10)
            return LoopGuard.Thresholds(history: mixed).tokenLimit
        }
        // 5 × (m + 0,5) = Int.max - 0,5 : la limite entière vaut Int.max - 2 + 2
        XCTAssertEqual(limit(m, m + 1), Int.max)
        XCTAssertEqual(limit(m + 1, m + 2), LoopGuard.Thresholds.coldStart.tokenLimit)
        XCTAssertEqual(limit(.max - 1, .max), LoopGuard.Thresholds.coldStart.tokenLimit)
    }

    func testNegativeHistoryValuesKeepTheColdStartLimits() {
        let thresholds = LoopGuard.Thresholds(history: history(toolCalls: .min, tokens: .min))
        XCTAssertEqual(thresholds.toolCallLimit, LoopGuard.Thresholds.coldStart.toolCallLimit)
        XCTAssertEqual(thresholds.tokenLimit, LoopGuard.Thresholds.coldStart.tokenLimit)
    }

    func testEvaluateWithAnExtremeHistoryStillJudgesTheTurn() {
        let extreme = history(toolCalls: .max, tokens: .max)
        XCTAssertEqual(evaluate([tool(at: 0), tool(at: 1), tool(at: 2)], history: extreme).verdict, .pause(.repeatedToolCall(count: 3), .stopRun))
        XCTAssertEqual(evaluate([message(at: 0)], history: extreme).verdict, .continue)
    }

    // MARK: lecture de l'historique

    func testHistoryListRejectsCountsOutsideTheBounds() {
        let limit = 1_000_000_000_000
        func list(_ entry: String) -> [TurnStats]? { TurnStats.decodeList(Data("[\(entry)]".utf8)) }
        XCTAssertEqual(list(#"{"tool_calls": \#(limit), "tokens": \#(limit)}"#), [TurnStats(toolCalls: limit, tokens: limit)])
        XCTAssertNil(list(#"{"tool_calls": \#(limit + 1)}"#))
        XCTAssertNil(list(#"{"tool_calls": 9223372036854775807}"#))
        XCTAssertNil(list(#"{"tool_calls": -1}"#))
        XCTAssertNil(list(#"{"tool_calls": 1, "tokens": \#(limit + 1)}"#))
        XCTAssertNil(list(#"{"tool_calls": 1, "tokens": 9223372036854775807}"#))
        XCTAssertNil(list(#"{"tool_calls": 1, "tokens": -1}"#))
        XCTAssertNil(list(#"{"tool_calls": 1, "tokens": 1e100}"#))
        XCTAssertNil(list(#"{"tool_calls": 1, "tokens": "beaucoup"}"#))
        XCTAssertNil(list(#"{"tool_calls": 1e100}"#))
    }
}
