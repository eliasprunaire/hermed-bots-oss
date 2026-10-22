import XCTest
import LoopGuard

final class LoopGuardTests: XCTestCase {
    private func distinctTools(_ count: Int) -> [Event] {
        (0..<count).map { tool("commande \($0)", at: Double($0)) }
    }

    // MARK: signal : le même appel répété

    func testThirdIdenticalToolCallInARowPauses() {
        XCTAssertEqual(evaluate([tool(at: 0), tool(at: 1)]).verdict, .continue)
        XCTAssertEqual(evaluate([tool(at: 0), tool(at: 1), tool(at: 2)]).verdict, .pause(.repeatedToolCall(count: 3), .stopRun))
    }

    func testADifferentCallResetsTheRepeatCount() {
        let a = { tool("a", at: $0) }
        XCTAssertEqual(evaluate([a(0), a(1), tool("b", at: 2), a(3), a(4)]).verdict, .continue)
        XCTAssertEqual(evaluate([a(0), a(1), tool("b", at: 2), a(3), a(4), a(5)]).verdict, .pause(.repeatedToolCall(count: 3), .stopRun))
    }

    func testSamePreviewOnAnotherToolIsNotARepeat() {
        let events = [tool("ls", name: "terminal", at: 0), tool("ls", name: "files", at: 1), tool("ls", name: "terminal", at: 2)]
        XCTAssertEqual(evaluate(events).verdict, .continue)
    }

    func testRepeatPausesAtTheThirdCallNotLater() {
        let events = [tool(at: 0), tool(at: 1), tool(at: 2), tool("autre", at: 3), tool("encore", at: 4)]
        XCTAssertEqual(evaluate(events).verdict, .pause(.repeatedToolCall(count: 3), .stopRun))
    }

    // MARK: signal : nombre d'appels d'outils

    func testToolCountAboveThreeTimesTheP95Pauses() {
        let limit = 27
        XCTAssertEqual(LoopGuard.Thresholds(history: twentyTurns).toolCallLimit, limit)
        XCTAssertEqual(evaluate(distinctTools(limit), history: twentyTurns).verdict, .continue)
        XCTAssertEqual(evaluate(distinctTools(limit + 1), history: twentyTurns).verdict, .pause(.toolCount(count: limit + 1, limit: limit), .stopRun))
    }

    // MARK: signal : tokens

    func testTokensAboveFiveTimesTheMedianPause() {
        let limit = 9_500
        XCTAssertEqual(LoopGuard.Thresholds(history: twentyTurns).tokenLimit, limit)
        XCTAssertEqual(evaluate([message(at: 0), usage(limit, at: 1)], history: twentyTurns).verdict, .continue)
        XCTAssertEqual(evaluate([message(at: 0), usage(limit + 1, at: 1)], history: twentyTurns).verdict, .pause(.tokens(total: limit + 1, limit: limit), .stopRun))
    }

    func testAHalfUnitMedianKeepsItsHalfUnitInTheLimit() {
        // médiane 101,5 : limite 507,5, donc 507 tokens passent et 508 pausent
        let odd = Array(repeating: TurnStats(toolCalls: 2, tokens: 101), count: 10) + Array(repeating: TurnStats(toolCalls: 2, tokens: 102), count: 10)
        XCTAssertEqual(LoopGuard.Thresholds(history: odd).tokenLimit, 507)
        XCTAssertEqual(evaluate([message(at: 0), usage(506, at: 1)], history: odd).verdict, .continue)
        XCTAssertEqual(evaluate([message(at: 0), usage(507, at: 1)], history: odd).verdict, .continue)
        XCTAssertEqual(evaluate([message(at: 0), usage(508, at: 1)], history: odd).verdict, .pause(.tokens(total: 508, limit: 507), .stopRun))
    }

    func testAMedianOfZeroAndOneIsNotTheColdStartValue() {
        // médiane 0,5 : limite 2,5, donc 3 tokens pausent
        let sparse = Array(repeating: TurnStats(toolCalls: 2, tokens: 0), count: 10) + Array(repeating: TurnStats(toolCalls: 2, tokens: 1), count: 10)
        XCTAssertEqual(LoopGuard.Thresholds(history: sparse).tokenLimit, 2)
        XCTAssertEqual(evaluate([message(at: 0), usage(2, at: 1)], history: sparse).verdict, .continue)
        XCTAssertEqual(evaluate([message(at: 0), usage(3, at: 1)], history: sparse).verdict, .pause(.tokens(total: 3, limit: 2), .stopRun))
    }

    // MARK: signal : silence

    func testSilencePastTheLimitPauses() {
        XCTAssertEqual(evaluate([message(at: 1_000)], now: 1_300).verdict, .continue)
        XCTAssertEqual(evaluate([message(at: 1_000)], now: 1_301).verdict, .pause(.silence(seconds: 301, limit: 300), .stopRun))
    }

    func testOnlyAnAssistantMessageRestartsTheSilenceClock() {
        let events = [message(at: 1_000), tool("a", at: 1_200), tool("b", at: 1_290)]
        XCTAssertEqual(evaluate(events, now: 1_301).verdict, .pause(.silence(seconds: 301, limit: 300), .stopRun))
        XCTAssertEqual(evaluate(events + [message(at: 1_295)], now: 1_301).verdict, .continue)
    }

    func testSilenceBeforeTheFirstMessageCountsFromTheFirstEvent() {
        XCTAssertEqual(evaluate([tool(at: 500)], now: 801).verdict, .pause(.silence(seconds: 301, limit: 300), .stopRun))
    }

    func testAGapInsideTheStreamPauses() {
        XCTAssertEqual(evaluate([message(at: 0), message(at: 400)], now: 400).verdict, .pause(.silence(seconds: 400, limit: 300), .stopRun))
    }

    func testWaitingForAnApprovalIsNotSilence() {
        XCTAssertEqual(evaluate([message(at: 0), approvalRequested(at: 10)], now: 10_000).verdict, .continue)
    }

    func testSilenceRestartsWhenTheApprovalIsAnswered() {
        let events = [message(at: 0), approvalRequested(at: 10), approvalAnswered(at: 5_000)]
        XCTAssertEqual(evaluate(events, now: 5_300).verdict, .continue)
        XCTAssertEqual(evaluate(events, now: 5_301).verdict, .pause(.silence(seconds: 301, limit: 300), .stopRun))
    }

    func testAFinishedTurnIsNeverSilent() {
        XCTAssertEqual(evaluate([message(at: 0), finished(at: 10)], now: 100_000).verdict, .continue)
    }

    func testEventsWithoutTimestampLeaveTheSilenceSignalOff() {
        let events = [Event(kind: .assistantMessage), Event(kind: .toolStarted, tool: "terminal", preview: "ls")]
        XCTAssertEqual(evaluate(events, now: 1_000_000).verdict, .continue)
    }

    // MARK: démarrage à froid

    func testFewerThanTwentyTurnsUseTheColdStartValues() {
        for turns in [0, 5, 19] {
            let thresholds = LoopGuard.Thresholds(history: Array(twentyTurns.prefix(turns)))
            XCTAssertEqual(thresholds.basis, .coldStart(turns: turns))
            XCTAssertEqual(thresholds.toolCallLimit, LoopGuard.Thresholds.coldStart.toolCallLimit)
            XCTAssertEqual(thresholds.tokenLimit, LoopGuard.Thresholds.coldStart.tokenLimit)
            XCTAssertEqual(thresholds.silenceSeconds, LoopGuard.Thresholds.coldStart.silenceSeconds)
        }
    }

    func testTwentyTurnsSwitchToTheHistory() {
        XCTAssertEqual(LoopGuard.Thresholds(history: twentyTurns).basis, .history(turns: 20))
    }

    func testColdStartLimitsDecideTheVerdictWithFiveTurns() {
        let five = Array(twentyTurns.prefix(5))
        XCTAssertEqual(evaluate(distinctTools(30), history: five).verdict, .continue)
        XCTAssertEqual(evaluate(distinctTools(31), history: five).verdict, .pause(.toolCount(count: 31, limit: 30), .stopRun))
        XCTAssertEqual(evaluate(distinctTools(1), history: five).thresholds.basis, .coldStart(turns: 5))
    }

    func testColdStartValuesAreTheProposals() {
        let cold = LoopGuard.Thresholds.coldStart
        XCTAssertEqual([cold.repeatedCall, cold.toolCallLimit, cold.tokenLimit, cold.silenceSeconds], [3, 30, 500_000, 300])
    }

    func testEveryValueIsMarkedUnmeasured() {
        XCTAssertFalse(LoopGuard.Thresholds.isMeasured)
        XCTAssertEqual(LoopGuard.Thresholds.coldStart.description, "basis=cold-start turns=0/20 measured=no repeat=3 tool-calls=30 tokens=500000 silence=300s")
        XCTAssertEqual(LoopGuard.Thresholds(history: twentyTurns).description, "basis=history turns=20/20 measured=no repeat=3 tool-calls=27 tokens=9500 silence=300s")
    }

    func testAHistoryWithoutToolCallsKeepsTheColdStartToolLimit() {
        let quiet = Array(repeating: TurnStats(toolCalls: 0, tokens: 1_000), count: 20)
        let thresholds = LoopGuard.Thresholds(history: quiet)
        XCTAssertEqual(thresholds.basis, .history(turns: 20))
        XCTAssertEqual(thresholds.toolCallLimit, LoopGuard.Thresholds.coldStart.toolCallLimit)
        XCTAssertEqual(thresholds.tokenLimit, 5_000)
    }

    func testAHistoryWithoutTokensKeepsTheColdStartTokenLimit() {
        let zeros = Array(repeating: TurnStats(toolCalls: 2, tokens: 0), count: 20)
        let missing = Array(repeating: TurnStats(toolCalls: 2, tokens: nil), count: 20)
        XCTAssertEqual(LoopGuard.Thresholds(history: zeros).tokenLimit, LoopGuard.Thresholds.coldStart.tokenLimit)
        XCTAssertEqual(LoopGuard.Thresholds(history: missing).tokenLimit, LoopGuard.Thresholds.coldStart.tokenLimit)
        XCTAssertEqual(LoopGuard.Thresholds(history: zeros).toolCallLimit, 6)
    }

    // MARK: source des tokens absente

    func testTokenSignalIsDisabledWhenNoEventCarriesUsage() {
        let report = evaluate([message(at: 0), tool(at: 1)], history: twentyTurns)
        XCTAssertEqual(report.tokenSignal, .disabled(reason: "no-usage-in-stream"))
        XCTAssertEqual(report.verdict, .continue)
    }

    func testOtherSignalsStayActiveWithoutTokens() {
        let report = evaluate([tool(at: 0), tool(at: 1), tool(at: 2)], history: twentyTurns)
        XCTAssertEqual(report.tokenSignal, .disabled(reason: "no-usage-in-stream"))
        XCTAssertEqual(report.verdict, .pause(.repeatedToolCall(count: 3), .stopRun))
        XCTAssertEqual(evaluate(distinctTools(28), history: twentyTurns).verdict, .pause(.toolCount(count: 28, limit: 27), .stopRun))
        XCTAssertEqual(evaluate([message(at: 0)], now: 301).verdict, .pause(.silence(seconds: 301, limit: 300), .stopRun))
    }

    func testTokenSignalIsActiveWhenAnEventCarriesUsage() {
        XCTAssertEqual(evaluate([message(at: 0), usage(10, at: 1)]).tokenSignal, .active)
    }

    // MARK: pas de pause ou d'annulation côté serveur

    func testPauseOffersTheServerStopWhenCancelRunExists() {
        XCTAssertEqual(evaluate([tool(at: 0), tool(at: 1), tool(at: 2)], canStopRun: true).verdict, .pause(.repeatedToolCall(count: 3), .stopRun))
    }

    func testPauseSuspendsDisplayAndSendWhenCancelRunIsDropped() {
        XCTAssertEqual(evaluate([tool(at: 0), tool(at: 1), tool(at: 2)], canStopRun: false).verdict, .pause(.repeatedToolCall(count: 3), .suspendDisplayAndSend))
    }

    // MARK: tours normaux, relevés sur l'instance de test

    func testANormalTurnNeverPauses() throws {
        let events = Event.parse(sse: try fixture("normal-turn.sse"))
        XCTAssertEqual(events.map(\.kind), [.assistantMessage, .other, .finished])
        for _ in 0..<100 {
            let report = evaluate(events)
            XCTAssertEqual(report.verdict, .continue)
            XCTAssertEqual(report.tokenSignal, .active)
        }
    }

    func testATurnWithOneStoppedToolNeverPauses() throws {
        let events = Event.parse(sse: try fixture("tool-turn.sse"))
        XCTAssertEqual(events.map(\.kind), [.toolStarted, .other, .finished])
        XCTAssertEqual(evaluate(events).verdict, .continue)
    }

    // MARK: sortie du probe

    func testVerdictAndCauseDescriptions() {
        XCTAssertEqual(LoopGuard.Verdict.continue.description, "continue")
        XCTAssertEqual(LoopGuard.Verdict.pause(.repeatedToolCall(count: 3), .stopRun).description, "pause cause=repeated-tool-call count=3")
        XCTAssertEqual(LoopGuard.Cause.toolCount(count: 28, limit: 27).description, "cause=tool-count count=28 limit=27")
        XCTAssertEqual(LoopGuard.Cause.tokens(total: 9_501, limit: 9_500).description, "cause=tokens total=9501 limit=9500")
        XCTAssertEqual(LoopGuard.Cause.silence(seconds: 301, limit: 300).description, "cause=silence seconds=301 limit=300")
    }

    func testRepeatedToolCallFixturePrintsThePausedLine() throws {
        let events = Event.parse(sse: try fixture("repeated-tool-call.sse"))
        XCTAssertEqual(events.count, 3)
        XCTAssertEqual(evaluate(events).verdict.description, "pause cause=repeated-tool-call count=3")
    }
}
