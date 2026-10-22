import XCTest

@MainActor
final class HD12Baseline: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    private func element(_ id: String, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", id)).firstMatch
    }

    private func injectRepeatedCalls() throws {
        let base = try XCTUnwrap(environment["HV_API_URL"])
        for _ in 0..<3 {
            var request = URLRequest(url: try XCTUnwrap(URL(string: base + "/_hv/inject")))
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["event": "tool.started", "tool": "terminal", "preview": "repeat"])
            let done = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
            XCTAssertEqual(done.wait(timeout: .now() + 5), .success)
        }
    }

    func testTrunkHasNoFeatureOrPauseBanner() throws {
        continueAfterFailure = false
        FakeServer.reset()
        try injectRepeatedCalls()
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(fr)"]
        app.launchEnvironment["HV_TEST_MODE"] = "1"
        for key in ["HV_API_URL", "HV_TEST_API_KEY"] { app.launchEnvironment[key] = environment[key] }
        app.launch()
        defer { app.terminate() }
        let bot = element("hd.bots.row.hv-bot-a", app: app)
        XCTAssertTrue(bot.waitForExistence(timeout: 20))
        let deadline = Date().addingTimeInterval(10)
        while !bot.isHittable, Date() < deadline { usleep(50_000) }
        bot.click()
        XCTAssertTrue(element("hd.model.disabled", app: app).waitForExistence(timeout: 10))
        let input = element("hd.composer.input", app: app)
        input.click()
        input.typeText("baseline calls")
        element("hd.composer.send", app: app).click()
        XCTAssertTrue(element("hd.conversation.state", app: app).waitForExistence(timeout: 20))
        XCTAssertFalse(element("hd.banner.degraded", app: app).exists)
        XCTAssertFalse(element("hd.banner.loop-pause", app: app).exists)
        print("HV-BASELINE set_model=disabled degraded_banner=missing pause_banner=missing repeated_calls=3")
        HVShot.capture("hd12-trunk-no-banners", app)
    }
}
