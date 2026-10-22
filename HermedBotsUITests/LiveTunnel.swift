import XCTest

@MainActor
final class LiveTunnel: XCTestCase {
    func testRealTestProfilesThroughTheVMTunnel() async throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["HV_TEST_API_KEYS"],
              let table = environment["HV_TEST_PROFILE_TABLE"] else {
            throw XCTSkip("La lane hv-vm-ui.py est requise")
        }
        let keys = try JSONDecoder().decode([String: String].self, from: Data(raw.utf8))
        XCTAssertEqual(Set(keys.keys), ["hv-bot-a", "hv-bot-b"])
        let base = try XCTUnwrap(environment["HV_API_URL"])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        for profile in ["hv-bot-a", "hv-bot-b"] {
            var request = URLRequest(url: try XCTUnwrap(URL(string: base + "/p/\(profile)/v1/models")))
            request.setValue("Bearer \(try XCTUnwrap(keys[profile]))", forHTTPHeaderField: "Authorization")
            let (_, response) = try await session.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            print("HV-TUNNEL UI GET /p/\(profile)/v1/models HTTP 200")
        }
        let (data, _) = try await session.data(from: try XCTUnwrap(URL(string: base + "/p/hv-bot-a/health")))
        let expectedVersion = try XCTUnwrap((JSONSerialization.jsonObject(with: data) as? [String: Any])?["version"] as? String)
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(fr)"]
        app.launchEnvironment["HV_TEST_MODE"] = "1"
        app.launchEnvironment["HV_API_URL"] = base
        app.launchEnvironment["HV_TEST_API_KEYS"] = raw
        app.launchEnvironment["HV_TEST_PROFILE_TABLE"] = table
        app.launch()
        defer { app.terminate() }
        for profile in ["hv-bot-a", "hv-bot-b"] {
            let row = app.descendants(matching: .any).matching(identifier: AccessibilityID.botRow(profile)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 20))
            let deadline = Date().addingTimeInterval(20)
            while !row.isHittable, Date() < deadline { usleep(50_000) }
            XCTAssertTrue(row.isHittable, "la fenêtre de la VM doit être prête avant le clic")
            row.click()
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: AccessibilityID.composerInput.rawValue).firstMatch.waitForExistence(timeout: 10))
            let version = app.descendants(matching: .any).matching(identifier: AccessibilityID.statusVersion.rawValue).firstMatch
            let ready = NSPredicate { _, _ in
                let text = (version.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? version.label
                return text == expectedVersion
            }
            await fulfillment(of: [expectation(for: ready, evaluatedWith: nil)], timeout: 20)
            XCTAssertFalse(app.descendants(matching: .any).matching(identifier: AccessibilityID.bannerError.rawValue).firstMatch.exists)
            HVShot.capture("issue56-\(profile)", app)
            print("HV-VERSION live profile=\(profile) version=\(expectedVersion) erreur=absente")
        }
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier MATCHES %@", #"hd\.bots\.row\.[^.]+"#))
        XCTAssertEqual(Set(rows.allElementsBoundByIndex.map(\.identifier)), [AccessibilityID.botRow("hv-bot-a"), AccessibilityID.botRow("hv-bot-b")])
    }
}
