import XCTest
@testable import HermesAdapter

final class PerfTests: XCTestCase {
    // Budget proposé par le plan : 200 ms pour décoder 10 000 événements sur le runner Linux
    func testDecodingATenThousandEventStreamStaysUnderTheBudget() throws {
        var text = ""
        for index in 0..<10_000 {
            let json = index % 10 == 9
                ? #"{"event":"tool.completed","run_id":"run_1","timestamp":1792343644.41,"tool":"terminal","duration":0.065,"error":false,"preview":"ok","seq":\#(index)}"#
                : #"{"event":"message.delta","run_id":"run_1","timestamp":1792343644.46,"delta":"mot ","seq":\#(index)}"#
            text += "id: \(index)\ndata: \(json)\n\n"
        }
        text += #"data: {"event":"run.completed","run_id":"run_1","output":"fin"}"# + "\n\n: stream closed\n\n"
        let stream = Data(text.utf8)

        let start = Date()
        var parser = SSEParser()
        var reader = TurnReader(runID: "run_1")
        for frame in parser.feed(stream) { _ = reader.apply(frame) }
        let elapsed = Date().timeIntervalSince(start)

        print("PerfTests: 10 001 événements décodés en \(Int(elapsed * 1000)) ms")
        XCTAssertEqual(reader.turn.state, .completed)
        XCTAssertEqual(reader.turn.text.count, 9_000 * 4)
        XCTAssertLessThan(elapsed, 0.2)
    }
}
