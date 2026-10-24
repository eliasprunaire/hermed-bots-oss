import XCTest

@MainActor
final class KillSwitchMessageTests: XCTestCase {
    private let hint = "Le tunnel est coupé, mais le service distant tourne peut-être encore."
    private let endpoint = KillSwitchAPI(baseURL: URL(string: "http://hermes.invalid")!, apiKey: nil)
    private let runs = (0..<3).map { KillSwitch.Run(profile: "p\($0)", id: "r\($0)") }

    func testRestHasNoCaption() {
        let model = KillSwitch(
            endpoint: { self.endpoint },
            connection: { "test" },
            runs: { self.runs },
            profiles: { ["p0"] },
            confirmed: { _, _ in }
        )
        XCTAssertEqual(model.message, "")
    }

    func testAMissingEndpointAtRestHasNoCaption() {
        let model = KillSwitch(
            endpoint: { nil },
            connection: { "test" },
            runs: { self.runs },
            profiles: { [] },
            confirmed: { _, _ in }
        )
        XCTAssertTrue(model.isDisabled)
        XCTAssertEqual(model.message, "")
    }

    func testASuccessfulStopHasNoCaption() async {
        var targets = runs
        let model = KillSwitch(
            endpoint: { self.endpoint },
            connection: { "test" },
            runs: { targets },
            profiles: { ["p0"] },
            confirmed: { _, _ in },
            cancel: { _, _ in "cancelled" }
        )
        await model.stopAll()
        XCTAssertEqual(model.message, "")
        XCTAssertFalse(model.isDisabled)
        targets = []
        await model.stopAll()
        XCTAssertEqual(model.message, "")
    }

    func testAFailedStopShowsThePartialHint() async {
        let model = KillSwitch(
            endpoint: { self.endpoint },
            connection: { "test" },
            runs: { self.runs },
            profiles: { [] },
            confirmed: { _, _ in },
            cancel: { _, _ in throw URLError(.cannotConnectToHost) }
        )
        await model.stopAll()
        XCTAssertEqual(model.message, hint)
    }

    func testAPartialStopShowsThePartialHint() async {
        var confirmed = 0
        let model = KillSwitch(
            endpoint: { self.endpoint },
            connection: { "test" },
            runs: { self.runs },
            profiles: { [] },
            confirmed: { _, _ in confirmed += 1 },
            cancel: { _, run in
                if run == self.runs[0] { throw URLError(.cannotConnectToHost) }
                return "cancelled"
            }
        )
        await model.stopAll()
        XCTAssertEqual(confirmed, 2)
        XCTAssertEqual(model.message, hint)
    }

    func testSupportCheckAtRestDoesNotShowACaption() async {
        let model = KillSwitch(
            endpoint: { self.endpoint },
            connection: { "test" },
            runs: { self.runs },
            profiles: { ["p0"] },
            confirmed: { _, _ in },
            canCancel: { _, _ in false }
        )
        await model.checkSupport()
        XCTAssertTrue(model.isDisabled)
        XCTAssertEqual(model.message, "")
    }

    func testSupportCheckDoesNotClearAFailedStop() async {
        let model = KillSwitch(
            endpoint: { self.endpoint },
            connection: { "test" },
            runs: { self.runs },
            profiles: { ["p0"] },
            confirmed: { _, _ in },
            cancel: { _, _ in throw URLError(.cannotConnectToHost) },
            canCancel: { _, _ in true }
        )
        await model.stopAll()
        XCTAssertEqual(model.message, hint)
        await model.checkSupport()
        XCTAssertEqual(model.message, hint)
    }

    func testALaterConnectionCanStopAfterAFailedOne() async {
        var host = "A"
        let runA = KillSwitch.Run(profile: "pA", id: "rA")
        let runB = KillSwitch.Run(profile: "pB", id: "rB")
        var cancelled: [String] = []
        let model = KillSwitch(
            endpoint: { self.endpoint },
            connection: { host },
            runs: { host == "A" ? [runA] : [runB] },
            profiles: { [host == "A" ? "pA" : "pB"] },
            confirmed: { _, _ in },
            cancel: { _, run in
                if run == runA { throw URLError(.cannotConnectToHost) }
                cancelled.append(run.id)
                return "cancelled"
            },
            canCancel: { _, _ in true }
        )
        await model.stopAll()
        XCTAssertEqual(model.message, hint)
        host = "B"
        XCTAssertFalse(model.isDisabled)
        await model.stopAll()
        XCTAssertEqual(cancelled, ["rB"])
        XCTAssertEqual(model.message, "")
        host = "A"
        XCTAssertEqual(model.message, hint)
    }

    func testAFailedStopSurvivesASupportCheckOnAnotherConnection() async {
        var host = "A"
        let model = KillSwitch(
            endpoint: { self.endpoint },
            connection: { host },
            runs: { self.runs },
            profiles: { ["p0"] },
            confirmed: { _, _ in },
            cancel: { _, _ in throw URLError(.cannotConnectToHost) },
            canCancel: { _, _ in true }
        )
        await model.stopAll()
        XCTAssertEqual(model.message, hint)
        host = "B"
        await model.checkSupport()
        XCTAssertEqual(model.message, "")
        host = "A"
        XCTAssertEqual(model.message, hint)
    }

    func testLeavingDuringCancelKeepsTheFailedStop() async {
        var host = "A"
        let runA = KillSwitch.Run(profile: "pA", id: "rA")
        var inCancel = false
        var confirmed = 0
        let model = KillSwitch(
            endpoint: { self.endpoint },
            connection: { host },
            runs: { [runA] },
            profiles: { ["pA"] },
            confirmed: { _, _ in confirmed += 1 },
            cancel: { _, _ in
                inCancel = true
                while host == "A" {
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw URLError(.cannotConnectToHost)
            }
        )
        let stopping = Task { await model.stopAll() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !inCancel, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(inCancel)
        host = "B"
        await stopping.value
        XCTAssertEqual(confirmed, 0)
        host = "A"
        XCTAssertEqual(model.message, hint)
    }

    func testLeavingWhileStopAllIsWaitingKeepsTheFailedStop() async {
        var host = "A"
        var waiting = false
        let model = KillSwitch(
            endpoint: { self.endpoint },
            connection: { host },
            runs: { [] },
            profiles: { ["pA"] },
            confirmed: { _, _ in },
            pending: {
                waiting = true
                return true
            },
            cancel: { _, _ in "cancelled" }
        )
        let stopping = Task { await model.stopAll() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !waiting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(waiting)
        host = "B"
        await stopping.value
        host = "A"
        XCTAssertEqual(model.message, hint)
    }
}
