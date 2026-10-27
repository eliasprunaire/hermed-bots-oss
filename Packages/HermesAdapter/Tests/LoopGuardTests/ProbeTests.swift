import XCTest
import Foundation

// Lance le binaire `hd-probe` construit par `swift test` : le comportement sur stdin et les codes de sortie ne se jugent pas en bibliothèque
final class ProbeTests: XCTestCase {
    private struct Outcome {
        let reason: Process.TerminationReason
        let status: Int32
        let output: String
        let errors: String
        let timedOut: Bool
    }

    override func setUp() {
        // écrire dans le stdin d'un probe déjà mort ne doit pas tuer le test
        signal(SIGPIPE, SIG_IGN)
    }

    private func probeURL() throws -> URL {
        #if os(macOS)
        let bundle = try XCTUnwrap(Bundle.allBundles.first { $0.bundleURL.pathExtension == "xctest" })
        let products = bundle.bundleURL.deletingLastPathComponent()
        #else
        let products = Bundle.main.bundleURL
        #endif
        let url = products.appendingPathComponent("hd-probe")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: url.path), "hd-probe absent de \(products.path)")
        return url
    }

    /// `closeStdin` à faux garde stdin ouvert jusqu'à la sortie du probe ; au-delà de `deadline` secondes le probe est tué
    private func probe(_ arguments: [String], stdin text: String = "", closeStdin: Bool = true, deadline: TimeInterval = 10) throws -> Outcome {
        let process = Process()
        process.executableURL = try probeURL()
        process.arguments = arguments
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        try? input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        if closeStdin { try? input.fileHandleForWriting.close() }
        let limit = Date().addingTimeInterval(deadline)
        while process.isRunning, Date() < limit { Thread.sleep(forTimeInterval: 0.05) }
        let timedOut = process.isRunning
        if timedOut { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
        try? input.fileHandleForWriting.close()
        return Outcome(
            reason: process.terminationReason,
            status: process.terminationStatus,
            output: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            errors: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            timedOut: timedOut
        )
    }

    private func line(_ event: String, at time: TimeInterval) -> String {
        "data: {\"event\": \"\(event)\", \"timestamp\": \(String(format: "%.3f", time))}\n"
    }

    // MARK: silence sur un flux ouvert

    func testAnOpenSilentStreamPausesWithoutWaitingForTheEnd() throws {
        let start = Date().timeIntervalSince1970
        let stream = ": open\n" + line("message.delta", at: start - 299.5) + ": keepalive\n"
        let outcome = try probe(["loop-guard", "--events", "-"], stdin: stream, closeStdin: false)
        XCTAssertFalse(outcome.timedOut, "le probe attend la fin d'un flux ouvert et silencieux")
        XCTAssertEqual(outcome.reason, .exit)
        XCTAssertEqual(outcome.status, 0)
        XCTAssertTrue(outcome.output.contains("pause cause=silence seconds=30"), outcome.output)
        XCTAssertLessThan(Date().timeIntervalSince1970 - start, 8)
    }

    func testAnOpenStreamThatIsNotSilentYetKeepsWaiting() throws {
        let stream = line("message.delta", at: Date().timeIntervalSince1970)
        let outcome = try probe(["loop-guard", "--events", "-"], stdin: stream, closeStdin: false, deadline: 2)
        XCTAssertTrue(outcome.timedOut)
    }

    func testTheClockIsReadAgainAtTheEndOfTheStream() throws {
        let stream = line("message.delta", at: Date().timeIntervalSince1970 - 301)
        let outcome = try probe(["loop-guard", "--events", "-"], stdin: stream)
        XCTAssertEqual(outcome.status, 0)
        XCTAssertTrue(outcome.output.contains("pause cause=silence seconds=30"), outcome.output)
    }

    func testAFixedClockReplaysDeterministically() throws {
        let stream = line("message.delta", at: 1_000)
        let late = try probe(["loop-guard", "--events", "-", "--now", "1301"], stdin: stream)
        XCTAssertTrue(late.output.contains("pause cause=silence seconds=301 limit=300"), late.output)
        let early = try probe(["loop-guard", "--events", "-", "--now", "1300"], stdin: stream)
        XCTAssertTrue(early.output.contains("\ncontinue\n"), early.output)
    }

    func testAPauseStopsTheReadOfAnOpenStream() throws {
        let stream = (0..<3).map { line("tool.started", at: Double($0)).replacingOccurrences(of: "}", with: ", \"tool\": \"terminal\", \"preview\": \"ls\"}") }.joined()
        let outcome = try probe(["loop-guard", "--events", "-", "--now", "10"], stdin: stream, closeStdin: false)
        XCTAssertFalse(outcome.timedOut)
        XCTAssertTrue(outcome.output.contains("pause cause=repeated-tool-call count=3"), outcome.output)
    }

    // MARK: nombres hors bornes : un diagnostic, jamais un signal de plantage

    func testNowOutsideTheBoundsIsAUsageError() throws {
        for value in ["inf", "-inf", "nan", "1e100", "1e400"] {
            let outcome = try probe(["loop-guard", "--events", "-", "--now", value])
            XCTAssertEqual(outcome.reason, .exit, value)
            XCTAssertEqual(outcome.status, 2, value)
            XCTAssertTrue(outcome.errors.contains("--now"), outcome.errors)
        }
    }

    func testAHugeTimestampInTheStreamDoesNotCrashTheProbe() throws {
        let stream = line("message.delta", at: 0) + "data: {\"event\": \"message.delta\", \"timestamp\": 1e100}\n"
        let outcome = try probe(["loop-guard", "--events", "-", "--now", "100"], stdin: stream)
        XCTAssertEqual(outcome.reason, .exit)
        XCTAssertEqual(outcome.status, 0)
        XCTAssertTrue(outcome.output.contains("\ncontinue\n"), outcome.output)
    }

    func testANonLocalUrlExitsWithTheForbiddenTargetCode() throws {
        let outcome = try probe(["list-profiles", "--url", "http://example-host.invalid:18642"])
        XCTAssertEqual(outcome.reason, .exit)
        XCTAssertEqual(outcome.status, 22)
        XCTAssertTrue(outcome.errors.contains("cible refusée"), outcome.errors)
        XCTAssertTrue(outcome.errors.contains("example-host.invalid"), outcome.errors)
        XCTAssertFalse(outcome.errors.contains("127.0.0.1"), outcome.errors)
    }

    func testAHistoryWithHugeCountsIsRejectedWithAMessage() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hd-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = Array(repeating: #"{"tool_calls": 9223372036854775807, "tokens": 9223372036854775807}"#, count: 20)
        let file = directory.appendingPathComponent("history.json")
        try "[\(entries.joined(separator: ","))]".write(to: file, atomically: true, encoding: .utf8)
        let outcome = try probe(["loop-guard", "--events", "-", "--history", file.path])
        XCTAssertEqual(outcome.reason, .exit)
        XCTAssertEqual(outcome.status, 1)
        XCTAssertTrue(outcome.errors.contains("--history"), outcome.errors)
    }
}
