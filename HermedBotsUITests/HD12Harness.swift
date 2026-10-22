import XCTest

@MainActor
class HD12Harness: XCTestCase {
    var app: XCUIApplication?
    var testProfileLocks = false
    let environment = ProcessInfo.processInfo.environment

    override func setUp() {
        continueAfterFailure = false
        FakeServer.reset()
    }

    override func tearDown() async throws {
        await MainActor.run {
            app?.terminate()
            configure()
        }
    }

    func configure(mode: String = "normal", drop: String = "set_model", rejectKey: Bool = false, omitTokens: Bool = false, version: String? = nil) {
        var body: [String: Any] = ["mode": mode, "drop": drop, "reject_key": rejectKey, "omit_tokens": omitTokens]
        if let version { body["version"] = version }
        request("/_hv/config", body: body)
    }

    @discardableResult
    func request(_ path: String, body: [String: Any]? = nil) -> [[String: Any]] {
        guard let data = requestData(path, body: body) else { return [] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
    }

    func requestData(_ path: String, body: [String: Any]? = nil, authorized: Bool = false) -> Data? {
        guard let base = environment["HV_API_URL"], let url = URL(string: base + path) else { XCTFail("HV_API_URL absent"); return nil }
        var request = URLRequest(url: url)
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        if authorized, let key = FakeServer.apiKey(for: path) { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Data?
        URLSession.shared.dataTask(with: request) { data, _, error in
            result = data
            if let error { XCTFail("contrôle fake : \(error)") }
            done.signal()
        }.resume()
        XCTAssertEqual(done.wait(timeout: .now() + 15), .success)
        return result
    }

    @discardableResult
    func launch(wrongKey: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(fr)"]
        app.launchEnvironment["HV_TEST_MODE"] = "1"
        app.launchEnvironment["HV_PROFILE_LOCKS"] = testProfileLocks ? "1" : "0"
        app.launchEnvironment["HV_RESUME_SCOPE"] = UUID().uuidString
        for key in ["HV_API_URL", "HV_TEST_API_KEY", "HV_TEST_API_KEYS"] { app.launchEnvironment[key] = environment[key] }
        if wrongKey {
            app.launchEnvironment["HV_TEST_API_KEY"] = "intentionally-invalid-test-key"
            if let raw = environment["HV_TEST_API_KEYS"], let keys = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)),
               let data = try? JSONEncoder().encode(keys.mapValues { _ in "intentionally-invalid-test-key" }) {
                app.launchEnvironment["HV_TEST_API_KEYS"] = String(decoding: data, as: UTF8.self)
            }
        }
        app.launch()
        self.app = app
        return app
    }

    func element(_ id: String) -> XCUIElement {
        app!.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", id)).firstMatch
    }

    func text(_ id: String) -> String {
        let item = element(id)
        if let value = item.value as? String, !value.isEmpty { return value }
        return item.label
    }

    func click(_ id: String) {
        let item = element(id)
        XCTAssertTrue(item.waitForExistence(timeout: 20))
        let deadline = Date().addingTimeInterval(10)
        while !item.isHittable, Date() < deadline { usleep(50_000) }
        XCTAssertTrue(item.isHittable, "élément inaccessible : \(id)")
        item.click()
    }

    func openBot() {
        click("hd.bots.row.hv-bot-a")
        XCTAssertTrue(element("hd.composer.input").waitForExistence(timeout: 10))
    }

    func send(_ message: String = "Bonjour hv") {
        click("hd.composer.input")
        element("hd.composer.input").typeText(message)
        click("hd.composer.send")
    }

    func completed() {
        XCTAssertTrue(element("hd.conversation.state").waitForExistence(timeout: 30))
        XCTAssertTrue(text("hd.conversation.state").contains("terminé"))
    }
}
