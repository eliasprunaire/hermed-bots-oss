import XCTest
@testable import HermesAdapter

final class ContextCompactionTests: XCTestCase {
    func testHermesThresholdsAreFiftyThenEightyFivePercent() {
        XCTAssertEqual(ContextCompaction.compressorRatio, 0.50, accuracy: 0.001)
        XCTAssertEqual(ContextCompaction.gatewayRatio, 0.85, accuracy: 0.001)
        XCTAssertEqual(ContextCompaction.defaultWindowTokens, 128_000)
    }

    func testAShortTranscriptIsNotCompacted() {
        let compaction = ContextCompaction(usedTokens: 1_000)
        XCTAssertFalse(compaction.isCompacted)
        XCTAssertFalse(compaction.isGatewayCompressed)
        XCTAssertEqual(compaction.percent, 0)
    }

    func testCrossingTheCompressorThresholdMarksCompaction() {
        let window = 1_000
        let justBelow = ContextCompaction(usedTokens: 499, windowTokens: window)
        XCTAssertFalse(justBelow.isCompacted)
        let atThreshold = ContextCompaction(usedTokens: 500, windowTokens: window)
        XCTAssertTrue(atThreshold.isCompacted)
        XCTAssertFalse(atThreshold.isGatewayCompressed)
        XCTAssertEqual(atThreshold.percent, 50)
        let gateway = ContextCompaction(usedTokens: 850, windowTokens: window)
        XCTAssertTrue(gateway.isGatewayCompressed)
        XCTAssertEqual(gateway.percent, 85)
    }

    func testTranscriptEstimateFeedsThePercent() {
        let text = String(repeating: "abcd", count: 16_000)
        let compaction = ContextCompaction.of(transcript: text, windowTokens: 32_000)
        XCTAssertEqual(ContextCompaction.estimateTokens(text), 16_000)
        XCTAssertTrue(compaction.isCompacted)
        XCTAssertEqual(compaction.percent, 50)
        XCTAssertEqual(compaction.source, .estimate)
    }

    func testServerUsageIsDistinctFromTheTranscriptEstimate() {
        let estimated = ContextCompaction.of(transcript: "court")
        XCTAssertEqual(estimated.source, .estimate)
        let server = ContextCompaction.server(usedTokens: 70_000)
        XCTAssertEqual(server.source, .server)
        XCTAssertTrue(server.isCompacted)
        XCTAssertGreaterThan(server.percent, estimated.percent)
    }
}
