import XCTest

@MainActor
final class ResumeLanes: HD12Harness {
    override func setUpWithError() throws {
        try XCTSkipUnless(environment["HV13_PROXY"] == "1", "Le proxy HD-13 qui coupe les flux est requis.")
    }

    private var since = Date()

    override func setUp() {
        super.setUp()
        since = Date()
    }

    private func starts() -> [[String: Any]] {
        request("/_hv/log").filter {
            ($0["t"] as? Double ?? 0) >= since.timeIntervalSince1970 && ($0["m"] as? String) == "POST" && ($0["p"] as? String)?.hasSuffix("/v1/runs") == true && ($0["s"] as? Int) == 202 && ($0["probe"] as? Bool) != true
        }
    }

    private func running(_ message: String = "HV_SLOW go") {
        launch()
        openBot()
        send(message)
        let deadline = Date().addingTimeInterval(10)
        while starts().isEmpty, Date() < deadline { usleep(50_000) }
        XCTAssertEqual(starts().count, 1)
        usleep(1_200_000)
    }

    private func result(_ shot: String, timeout: TimeInterval = 30) {
        XCTAssertTrue(element("hd.conversation.state").waitForExistence(timeout: timeout))
        XCTAssertTrue(text("hd.conversation.state").contains("terminé"), text("hd.conversation.state"))
        XCTAssertEqual(starts().count, 1)
        if let body = starts().first?["body"] as? String,
           let input = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: String],
           let session = input["session_id"],
           let data = requestData("/p/hv-bot-a/api/sessions/\(session)/messages", authorized: true),
           let transcript = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let messages = transcript["data"] as? [[String: Any]] {
            XCTAssertEqual(messages.filter { $0["role"] as? String == "user" }.count, 1)
        } else { XCTFail("transcript de la session absent") }
        HVShot.capture(shot, app!)
    }

    func testCompletedDuringCut() {
        running()
        request("/_hv/cut", body: ["seconds": 10])
        request("/_hv/inject", body: ["event": "run.completed"])
        result("hd13-inject")
    }

    func testZeroSecondCut() {
        running()
        request("/_hv/cut", body: ["seconds": 0])
        result("hd13-zero")
    }

    func testTenMinuteCut() {
        running()
        request("/_hv/cut", body: ["seconds": 600])
        XCTAssertTrue(element("hd.banner.error").waitForExistence(timeout: 20))
        HVShot.capture("hd13-ten-min-banner", app!)
        result("hd13-ten-min", timeout: 630)
    }

    func testApprovalAcrossCut() { approvalAcrossCut("hd13-approval-cut") }

    func testApprovalWithDetectorCut() {
        testProfileLocks = true
        approvalAcrossCut("hd13-approval-lock-cut")
    }

    private func approvalAcrossCut(_ shot: String) {
        running("HV_APPROVAL go")
        XCTAssertTrue(element("hd.approval.sheet").waitForExistence(timeout: 10))
        request("/_hv/cut", body: ["seconds": 10])
        XCTAssertTrue(element("hd.banner.error").waitForExistence(timeout: 15))
        XCTAssertTrue(element("hd.approval.sheet").exists)
        HVShot.capture(shot, app!)
        if testProfileLocks {
            XCTAssertTrue(element("hd.banner.degraded.feature.profile_lock").waitForExistence(timeout: 10))
            XCTAssertTrue(element("hd.banner.degraded.feature.profile_lock").waitForNonExistence(timeout: 20))
            XCTAssertTrue(element("hd.approval.sheet").exists)
        }
        click("hd.approval.yes")
        result("hd13-approval-result")
        let decisions = request("/_hv/log").filter { ($0["t"] as? Double ?? 0) >= since.timeIntervalSince1970 && ($0["p"] as? String)?.hasSuffix("/approval") == true && ($0["s"] as? Int) == 200 }
        XCTAssertEqual(decisions.count, 1)
    }

    func testCutBeforeAcknowledgement() {
        request("/_hv/ack-cut", body: [:])
        running()
        result("hd13-send-cut")
    }

    func testRelaunchMidTurn() {
        running()
        let app = app!
        app.terminate()
        app.launch()
        result("hd13-relaunch")
    }

    func testOnlyIDsPersist() throws {
        running()
        let data = Data(text("hd.resume.state").utf8)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: String]])
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(Set(rows[0].keys), ["session", "run"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("HV_SLOW"))
        print("HV-STATE \(String(decoding: data, as: UTF8.self))")
        HVShot.capture("hd13-local-state", app!)
        result("hd13-local-state-result")
    }

    func testNetworkGuardCapture() {
        running()
        result("hd13-net-guard")
    }

    func testLoopGuardCountsAcrossReplay() {
        running("HV_LOOP HV_PACE_5000 go")
        XCTAssertTrue(element("hd.tool.current").waitForExistence(timeout: 10))
        request("/_hv/cut", body: ["seconds": 10])
        XCTAssertTrue(element("hd.banner.loop-pause").waitForExistence(timeout: 30))
        XCTAssertTrue(text("hd.banner.loop-pause").contains("3"))
        XCTAssertEqual(starts().count, 1)
        HVShot.capture("hd13-loop-guard", app!)
        click("hd.loop.close")
        XCTAssertTrue(element("hd.conversation.empty").waitForExistence(timeout: 10))
        app!.terminate()
        app!.launch()
        XCTAssertFalse(element("hd.banner.loop-pause").waitForExistence(timeout: 3))
        XCTAssertFalse(element("hd.conversation.busy").exists)
    }

    func testResumeBudget() {
        var times: [Double] = []
        let count = environment["HV13_SINGLE"] == "1" ? 1 : 5
        for index in 0..<count {
            FakeServer.reset()
            since = Date()
            running()
            request("/_hv/cut", body: ["seconds": 10])
            let returned = Date().addingTimeInterval(10)
            XCTAssertTrue(element("hd.conversation.state").waitForExistence(timeout: 30))
            XCTAssertTrue(text("hd.conversation.state").contains("terminé"))
            XCTAssertEqual(starts().count, 1)
            let elapsed = max(0, Date().timeIntervalSince(returned))
            times.append(elapsed)
            print("HV-PERF13 sample=\(index) seconds=\(elapsed) admissions=1 result=completed")
            app!.terminate()
        }
        let median = times.sorted()[times.count / 2]
        if count == 5 { XCTAssertLessThanOrEqual(median, 5) }
        print("HV-PERF13 median=\(median)s range=\(times.min()!)...\(times.max()!) n=\(times.count)")
    }
}
