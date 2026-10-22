import XCTest

// compilé dans le paquet de tests lui-même, sans l'app comme hôte : le fil principal est celui du runner de tests
#if DEBUG
/// Le chien de garde est l'instrument de la sonde de perf de HD-09 : ces tests prouvent qu'il voit un blocage plus long que le budget de 250 ms et qu'il ne voit rien au repos
@MainActor
final class MainThreadWatchTests: XCTestCase {
    /// Le fil principal ne répond plus pendant `seconds` : une fonction synchrone, parce que `Thread.sleep` est refusé dans un contexte asynchrone
    private func blockMainThread(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    func testABlockLongerThanTheBudgetIsRecordedWithItsLengthItsStartAndTheReport() async throws {
        let watch = MainThreadWatch(threshold: 50)
        watch.start()
        defer { watch.stop() }
        try await Task.sleep(for: .milliseconds(100))

        let before = Date().timeIntervalSince1970
        blockMainThread(for: 0.4)
        let after = Date().timeIntervalSince1970
        try await Task.sleep(for: .milliseconds(100))

        let hang = try XCTUnwrap(watch.hangs.max { $0.milliseconds < $1.milliseconds }, "le blocage de 400 ms n'est pas vu")
        XCTAssertTrue((350...450).contains(hang.milliseconds), "durée lue : \(hang.milliseconds) ms pour un blocage de 400 ms")
        XCTAssertGreaterThanOrEqual(hang.start, before - 0.05, "le blocage commence avec le sommeil du fil principal")
        XCTAssertLessThanOrEqual(hang.start + Double(hang.milliseconds) / 1000, after + 0.1, "le blocage finit avec lui")

        // ce que la sonde lit par l'accessibilité
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(watch.report.utf8)) as? [String: Any])
        let listed = try XCTUnwrap(report["hangs"] as? [[Double]])
        XCTAssertEqual(listed.map { Int($0[1]) }, watch.hangs.map(\.milliseconds))
        XCTAssertEqual(listed.map { $0[0] }, watch.hangs.map(\.start))
        XCTAssertEqual(report["samples"] as? Int, watch.samples)
    }

    func testAnIdleMainThreadRecordsNoHangAndTheWatchKeepsSampling() async throws {
        let watch = MainThreadWatch(threshold: 200)
        watch.start()
        defer { watch.stop() }
        try await Task.sleep(for: .seconds(2))
        XCTAssertGreaterThanOrEqual(watch.samples, 100, "un chien de garde mort ferait passer n'importe quel envoi : il doit échantillonner")
        XCTAssertTrue(watch.hangs.isEmpty, "au repos : \(watch.hangs)")
    }

    func testAStoppedWatchSamplesNoMore() async throws {
        let watch = MainThreadWatch(threshold: 200)
        watch.start()
        try await Task.sleep(for: .seconds(1))
        watch.stop()
        try await Task.sleep(for: .milliseconds(100))
        let stopped = watch.samples
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(watch.samples, stopped)
    }
}
#endif
