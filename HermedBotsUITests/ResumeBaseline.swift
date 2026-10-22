import XCTest

@MainActor
final class ResumeBaseline: HD12Harness {
    override func setUpWithError() throws {
        try XCTSkipUnless(environment["HV13_BASELINE"] == "1", "La lane de référence exige trunk.")
    }

    func testTrunkCutOutcome() {
        let count = environment["HV13_SINGLE"] == "1" ? 1 : 5
        for sample in 0..<count {
            FakeServer.reset()
            let since = Date()
            launch()
            openBot()
            send("HV_SLOW go")
            usleep(1_500_000)
            request("/_hv/cut", body: ["seconds": 10])
            XCTAssertTrue(element("hd.conversation.error").waitForExistence(timeout: 20))
            XCTAssertFalse(element("hd.conversation.state").exists)
            let starts = request("/_hv/log").filter { ($0["t"] as? Double ?? 0) >= since.timeIntervalSince1970 && ($0["p"] as? String)?.hasSuffix("/v1/runs") == true && ($0["s"] as? Int) == 202 }
            XCTAssertEqual(starts.count, 1)
            print("HV-PERF13 trunk sample=\(sample) result=stream-ended-no-resume admissions=1")
            if sample == 0 { HVShot.capture("hd13-cut-trunk", app!) }
            app!.terminate()
        }
    }
}
