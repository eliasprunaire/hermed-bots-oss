import XCTest
import LoopGuard

final class LoopGuardDecodingTests: XCTestCase {
    private func decode(_ json: String) -> Event? { Event.decode(Data(json.utf8)) }

    func testToolStartedKeepsToolAndPreview() {
        let event = decode(#"{"event": "tool.started", "run_id": "run_1", "timestamp": 1792357018.98, "tool": "terminal", "preview": "sleep 300", "seq": 0}"#)
        XCTAssertEqual(event, Event(kind: .toolStarted, timestamp: 1792357018.98, tool: "terminal", preview: "sleep 300"))
    }

    func testToolStartedWithoutPreviewKeepsAnEmptyPreview() {
        XCTAssertEqual(decode(#"{"event": "tool.started", "tool": "terminal"}"#), Event(kind: .toolStarted, tool: "terminal", preview: ""))
    }

    func testToolStartedWithoutToolIsOther() {
        XCTAssertEqual(decode(#"{"event": "tool.started", "preview": "ls"}"#)?.kind, .other)
    }

    func testMessageDeltaIsAnAssistantMessage() {
        XCTAssertEqual(decode(#"{"event": "message.delta", "timestamp": 5, "delta": "bonjour"}"#), Event(kind: .assistantMessage, timestamp: 5))
    }

    func testApprovalEvents() {
        XCTAssertEqual(decode(#"{"event": "approval.request", "request_id": "a"}"#)?.kind, .approvalRequested)
        XCTAssertEqual(decode(#"{"event": "approval.responded", "request_id": "a"}"#)?.kind, .approvalAnswered)
        XCTAssertEqual(decode(#"{"event": "approval.settled", "prompt_id": "a"}"#)?.kind, .approvalAnswered)
    }

    func testTerminalEventsFinishTheTurn() {
        for name in ["run.completed", "run.failed", "run.cancelled", "run.interrupted"] {
            XCTAssertEqual(decode(#"{"event": "\#(name)"}"#)?.kind, .finished, name)
        }
    }

    func testTerminalUsageCarriesTheTotalTokens() {
        let event = decode(#"{"event": "run.completed", "usage": {"input_tokens": 3, "output_tokens": 4, "total_tokens": 7}}"#)
        XCTAssertEqual(event, Event(kind: .finished, tokens: 7))
    }

    func testAnyEventCanCarryUsage() {
        XCTAssertEqual(decode(#"{"event": "hv.injected", "timestamp": 9, "usage": {"total_tokens": 600000}}"#), Event(kind: .other, timestamp: 9, tokens: 600_000))
    }

    func testUsageWithoutATotalIsNoTokenCount() {
        XCTAssertNil(decode(#"{"event": "run.completed", "usage": {"input_tokens": 3}}"#)?.tokens)
        XCTAssertNil(decode(#"{"event": "run.completed", "usage": null}"#)?.tokens)
    }

    func testUnknownEventIsOtherAndNotJSONIsNil() {
        XCTAssertEqual(decode(#"{"event": "hv.unknown_future_event", "payload": {"x": 1}}"#)?.kind, .other)
        XCTAssertNil(decode("pas du json"))
        XCTAssertNil(decode("[1, 2]"))
    }

    func testParseSSEKeepsTheDataLinesOnly() {
        let text = """
        : open

        id: 0
        data: {"event": "message.delta", "timestamp": 1}

        : keepalive
        id: 1
        data: pas du json
        data: {"event": "tool.started", "tool": "terminal", "preview": "ls", "timestamp": 2}
        """
        XCTAssertEqual(Event.parse(sse: text).map(\.kind), [.assistantMessage, .toolStarted])
    }

    func testParseSSEStopsAtTheStreamClosedMarker() {
        let text = """
        data: {"event": "run.completed"}
        : stream closed
        data: {"event": "message.delta"}
        """
        XCTAssertEqual(Event.parse(sse: text).map(\.kind), [.finished])
    }

    func testParseSSEAcceptsCRLFAndMissingSpaceAfterTheColon() {
        XCTAssertEqual(Event.parse(sse: "data:{\"event\": \"message.delta\"}\r\n\r\n").map(\.kind), [.assistantMessage])
    }

    func testHistoryList() throws {
        let stats = TurnStats.decodeList(Data(try fixture("history-5-turns.json").utf8))
        XCTAssertEqual(stats?.count, 5)
        XCTAssertEqual(stats?.first, TurnStats(toolCalls: 2, tokens: 1_800))
        XCTAssertEqual(TurnStats.decodeList(Data(#"[{"tool_calls": 2, "tokens": null}, {"tool_calls": 1}]"#.utf8)), [TurnStats(toolCalls: 2), TurnStats(toolCalls: 1)])
    }

    func testHistoryListRejectsAnythingElse() {
        XCTAssertNil(TurnStats.decodeList(Data("{}".utf8)))
        XCTAssertNil(TurnStats.decodeList(Data(#"[{"tokens": 3}]"#.utf8)))
        XCTAssertNil(TurnStats.decodeList(Data("pas du json".utf8)))
    }
}
