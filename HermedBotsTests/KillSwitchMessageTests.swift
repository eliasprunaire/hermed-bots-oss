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
            confirmed: { _, _, _ in }
        )
        XCTAssertEqual(model.message, "")
    }

    func testAMissingEndpointAtRestHasNoCaption() {
        let model = KillSwitch(
            endpoint: { nil },
            connection: { "test" },
            runs: { self.runs },
            profiles: { [] },
            confirmed: { _, _, _ in }
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
            confirmed: { _, _, _ in },
            cancel: { _, _, _ in "cancelled" }
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
            confirmed: { _, _, _ in },
            cancel: { _, _, _ in throw URLError(.cannotConnectToHost) }
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
            confirmed: { _, _, _ in confirmed += 1 },
            cancel: { _, run, _ in
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
            confirmed: { _, _, _ in },
            canCancel: { _, _, _ in false }
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
            confirmed: { _, _, _ in },
            cancel: { _, _, _ in throw URLError(.cannotConnectToHost) },
            canCancel: { _, _, _ in true }
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
            confirmed: { _, _, _ in },
            cancel: { _, run, _ in
                if run == runA { throw URLError(.cannotConnectToHost) }
                cancelled.append(run.id)
                return "cancelled"
            },
            canCancel: { _, _, _ in true }
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
            confirmed: { _, _, _ in },
            cancel: { _, _, _ in throw URLError(.cannotConnectToHost) },
            canCancel: { _, _, _ in true }
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
            confirmed: { _, _, _ in confirmed += 1 },
            cancel: { _, _, allow in
                inCancel = true
                while allow() {
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw URLError(.cancelled)
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
        XCTAssertEqual(model.message, "")
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
            confirmed: { _, _, _ in },
            pending: {
                waiting = true
                return ["t1"]
            },
            cancel: { _, _, _ in "cancelled" }
        )
        let stopping = Task { await model.stopAll() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !waiting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(waiting)
        host = "B"
        await stopping.value
        XCTAssertEqual(model.message, "")
        host = "A"
        XCTAssertEqual(model.message, hint)
    }

    func testLeavingWithAKnownRunAndAPendingStartKeepsTheFailedStop() async {
        var host = "A"
        var waiting = false
        let runA = KillSwitch.Run(profile: "pA", id: "rA")
        let model = KillSwitch(
            endpoint: { self.endpoint },
            connection: { host },
            runs: { [runA] },
            profiles: { ["pA"] },
            confirmed: { _, _, _ in },
            pending: {
                waiting = true
                return ["t1"]
            },
            cancel: { _, _, _ in "cancelled" }
        )
        let stopping = Task { await model.stopAll() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !waiting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(waiting)
        host = "B"
        await stopping.value
        XCTAssertEqual(model.message, "")
        host = "A"
        XCTAssertEqual(model.message, hint)
    }

    func testLeavingBeforeTheSendDoesNotSendTheStopToTheNewConnection() async {
        var host = "A"
        var waiting = false
        var cancelled: [String] = []
        let runA = KillSwitch.Run(profile: "pA", id: "rA")
        let model = KillSwitch(
            endpoint: { self.endpoint },
            connection: { host },
            runs: { [runA] },
            profiles: { ["pA"] },
            confirmed: { _, _, _ in },
            pending: {
                waiting = true
                return ["t1"]
            },
            cancel: { _, run, _ in
                cancelled.append(run.id)
                return "cancelled"
            }
        )
        let stopping = Task { await model.stopAll() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !waiting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(waiting)
        host = "B"
        await stopping.value
        XCTAssertEqual(cancelled, [])
        XCTAssertEqual(model.message, "")
        host = "A"
        XCTAssertEqual(model.message, hint)
    }

    func testAStopDoesNotSendAfterSwitchingConnection() async {
        var host = "A"
        let shared = KillSwitch.Run(profile: "p", id: "r0")
        var sent: [String] = []
        let model = KillSwitch(
            endpoint: { self.endpoint },
            connection: { host },
            runs: { [shared] },
            profiles: { ["p"] },
            confirmed: { _, _, _ in },
            cancel: { _, _, allow in
                while true {
                    guard allow() else { throw URLError(.cancelled) }
                    sent.append(host)
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
        )
        let stopping = Task { await model.stopAll() }
        let deadline = ContinuousClock.now + .seconds(2)
        while sent.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(sent, ["A"])
        host = "B"
        await stopping.value
        XCTAssertFalse(sent.contains("B"))
        XCTAssertEqual(model.message, "")
        host = "A"
        XCTAssertEqual(model.message, hint)
    }

    func testAConfirmationKeepsTheConnectionThatStartedTheStop() async {
        var host = "A"
        let run = KillSwitch.Run(profile: "p", id: "r0")
        var confirmedOn: [String] = []
        var inCancel = false
        let model = KillSwitch(
            endpoint: { self.endpoint },
            connection: { host },
            runs: { [run] },
            profiles: { ["p"] },
            confirmed: { _, _, origin in confirmedOn.append(origin) },
            cancel: { _, _, allow in
                inCancel = true
                while allow() {
                    try await Task.sleep(for: .milliseconds(10))
                }
                throw URLError(.cancelled)
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
        XCTAssertEqual(confirmedOn, [])
        XCTAssertEqual(model.message, "")
        host = "A"
        XCTAssertEqual(model.message, hint)
    }

    func testASecondClickAfterALateStartOnALeftConnectionKeepsTheFailedStop() async {
        var host = "A"
        var starting = true
        var cancelled = 0
        let model = KillSwitch(
            endpoint: { self.endpoint },
            connection: { host },
            runs: { [] },
            profiles: { ["pA"] },
            confirmed: { _, _, _ in },
            pending: { host == "A" && starting ? ["t1"] : [] },
            cancel: { _, _, _ in
                cancelled += 1
                return "cancelled"
            }
        )
        let first = Task { await model.stopAll() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !model.isStopping, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.isStopping)
        host = "B"
        starting = false
        await first.value
        host = "A"
        XCTAssertEqual(model.message, hint)
        await model.stopAll()
        XCTAssertEqual(cancelled, 0)
        XCTAssertEqual(model.message, hint)
    }

    func testCancellingAnotherTurnDoesNotClearALateStart() async {
        var host = "A"
        var starting = true
        var runsA: [KillSwitch.Run] = []
        var cancelled: [String] = []
        let other = KillSwitch.Run(profile: "pA", id: "other")
        let model = KillSwitch(
            endpoint: { self.endpoint },
            connection: { host },
            runs: { host == "A" ? runsA : [] },
            profiles: { ["pA"] },
            confirmed: { _, _, _ in },
            pending: { host == "A" && starting ? ["t1"] : [] },
            cancel: { _, run, _ in
                cancelled.append(run.id)
                return "cancelled"
            }
        )
        let first = Task { await model.stopAll() }
        let deadline = ContinuousClock.now + .seconds(2)
        while !model.isStopping, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.isStopping)
        host = "B"
        starting = false
        await first.value
        host = "A"
        XCTAssertEqual(model.message, hint)
        runsA = [other]
        await model.stopAll()
        XCTAssertEqual(cancelled, ["other"])
        XCTAssertEqual(model.message, hint)
    }

    func testCancellingTheTurnOfALateStartClearsItsMarker() async {
        var starting = true
        var runsA: [KillSwitch.Run] = []
        var cancelled: [String] = []
        let model = KillSwitch(
            endpoint: { self.endpoint },
            connection: { "A" },
            runs: { runsA },
            profiles: { ["pA"] },
            confirmed: { _, _, _ in },
            pending: { starting ? ["t1"] : [] },
            startWait: .milliseconds(50),
            cancel: { _, run, _ in
                cancelled.append(run.id)
                return "cancelled"
            }
        )
        await model.stopAll()
        XCTAssertEqual(cancelled, [])
        XCTAssertEqual(model.message, hint)
        starting = false
        runsA = [KillSwitch.Run(profile: "pA", id: "late", turn: "t1")]
        await model.stopAll()
        XCTAssertEqual(cancelled, ["late"])
        XCTAssertEqual(model.message, "")
    }

    func testAnEmptyClickDoesNotClearAFailedStop() async {
        var targets = runs
        let model = KillSwitch(
            endpoint: { self.endpoint },
            connection: { "test" },
            runs: { targets },
            profiles: { [] },
            confirmed: { _, _, _ in },
            cancel: { _, _, _ in throw URLError(.cannotConnectToHost) }
        )
        await model.stopAll()
        XCTAssertEqual(model.message, hint)
        targets = []
        await model.stopAll()
        XCTAssertEqual(model.message, hint)
    }

    func testASuccessfulStopOnTheSameConnectionClearsTheFailedStop() async {
        var failing = true
        let model = KillSwitch(
            endpoint: { self.endpoint },
            connection: { "test" },
            runs: { self.runs },
            profiles: { [] },
            confirmed: { _, _, _ in },
            cancel: { _, _, _ in
                if failing { throw URLError(.cannotConnectToHost) }
                return "cancelled"
            }
        )
        await model.stopAll()
        XCTAssertEqual(model.message, hint)
        failing = false
        await model.stopAll()
        XCTAssertEqual(model.message, "")
    }
}
