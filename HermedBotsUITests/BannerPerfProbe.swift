import XCTest

@MainActor
final class BannerPerfProbe: HD12Harness {
    private func waitForVisible(_ id: String) -> Bool {
        let item = element(id)
        let deadline = Date().addingTimeInterval(15)
        while !item.exists, Date() < deadline { usleep(10_000) }
        return item.exists
    }

    func testFiveLaunchesAndFivePauses() throws {
        var degraded: [Int] = []
        var pauses: [Int] = []
        for _ in 0..<5 {
            configure(mode: "drop-route")
            let start = Date().timeIntervalSince1970
            let launched = launch()
            XCTAssertTrue(waitForVisible("hd.banner.degraded.feature.set_model"))
            let visible = Date().timeIntervalSince1970
            let dropped = try XCTUnwrap(request("/_hv/log").first {
                ($0["p"] as? String)?.hasSuffix("/hd-probe-capabilities/model") == true && ($0["t"] as? Double ?? 0) >= start
            }?["t"] as? Double)
            degraded.append(Int((visible - dropped) * 1000))
            launched.terminate()
        }
        for _ in 0..<5 {
            configure()
            FakeServer.reset()
            let launched = launch()
            openBot()
            send("HV_LOOP go")
            XCTAssertTrue(waitForVisible("hd.banner.loop-pause"))
            let visible = Date().timeIntervalSince1970
            let decided = try XCTUnwrap(Double(text("hd.perf.loop-pause")))
            pauses.append(Int((visible - decided) * 1000))
            launched.terminate()
        }
        let routeMedian = degraded.sorted()[2]
        let pauseMedian = pauses.sorted()[2]
        print("HV-PERF12 route_to_banner_ms=\(degraded) median_ms=\(routeMedian) pause_to_banner_ms=\(pauses) median_ms=\(pauseMedian) budget_ms=1000")
        XCTAssertLessThanOrEqual(routeMedian, 1000)
        XCTAssertLessThanOrEqual(pauseMedian, 1000)
    }
}
