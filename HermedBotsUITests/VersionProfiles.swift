import XCTest

@MainActor
final class VersionProfiles: HD12Harness {
    private let a = "hv-bot-a"
    private let b = "hv-bot-b"

    private func configureVersion(_ version: String, rejectKey: Bool = false) {
        request("/_hv/config", body: ["mode": "normal", "version": version, "reject_key": rejectKey, "profiles": [a, b]])
    }

    private func start(keys: [String: String]) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(fr)"]
        app.launchEnvironment["HV_TEST_MODE"] = "1"
        app.launchEnvironment["HV_API_URL"] = environment["HV_API_URL"]
        app.launchEnvironment["HV_TEST_API_KEYS"] = String(decoding: try JSONEncoder().encode(keys), as: UTF8.self)
        app.launch()
        self.app = app
        return app
    }

    private func keys() throws -> [String: String] {
        try JSONDecoder().decode([String: String].self, from: Data(XCTUnwrap(environment["HV_TEST_API_KEYS"]).utf8))
    }

    private func waitForVersion(_ expected: String) {
        let predicate = NSPredicate { [self] _, _ in text(AccessibilityID.statusVersion.rawValue) == expected }
        expectation(for: predicate, evaluatedWith: nil)
        waitForExpectations(timeout: 15)
    }

    func testVersionFollowsSelectionAndReloadsOnReturn() throws {
        let started = Date().timeIntervalSince1970
        configureVersion("profile-a")
        let app = try start(keys: keys())
        click(AccessibilityID.botRow(a))
        waitForVersion("profile-a")
        HVShot.capture("issue58-version-a", app)
        configureVersion("profile-b")
        click(AccessibilityID.botRow(b))
        waitForVersion("profile-b")
        HVShot.capture("issue58-version-b", app)
        configureVersion("profile-a-return")
        click(AccessibilityID.botRow(a))
        waitForVersion("profile-a-return")
        HVShot.capture("issue58-version-return", app)
        let paths = request("/_hv/log").filter { ($0["t"] as? Double ?? 0) >= started }.compactMap { $0["p"] as? String }.filter { $0.hasSuffix("/health") }
        XCTAssertTrue(paths.contains("/p/\(a)/health"))
        XCTAssertTrue(paths.contains("/p/\(b)/health"))
        XCTAssertFalse(paths.contains("/health"))
        print("HV-VERSION selection=A,B,A versions=profile-a,profile-b,profile-a-return routes=profils")
    }

    func testLateRequestCannotReplaceTheNewSelection() throws {
        configureVersion("profile-a")
        let app = try start(keys: keys())
        click(AccessibilityID.botRow(a))
        waitForVersion("profile-a")
        let started = Date().timeIntervalSince1970
        request("/_hv/config", body: ["mode": "slow", "profiles": [a, b]])
        click(AccessibilityID.botRow(b))
        let sent = NSPredicate { [self] _, _ in
            request("/_hv/log").contains { $0["p"] as? String == "/p/\(b)/health" && ($0["t"] as? Double ?? 0) >= started }
        }
        expectation(for: sent, evaluatedWith: nil)
        waitForExpectations(timeout: 10)
        configureVersion("profile-a-return")
        click(AccessibilityID.botRow(a))
        waitForVersion("profile-a-return")
        sleep(9)
        XCTAssertEqual(text(AccessibilityID.statusVersion.rawValue), "profile-a-return")
        XCTAssertFalse(element(AccessibilityID.bannerError.rawValue).exists)
        HVShot.capture("issue58-version-late-response", app)
    }

    func testMissingKeyIsClearAndAnotherProfileRecovers() throws {
        let started = Date().timeIntervalSince1970
        configureVersion("profile-a")
        var keys = try keys()
        keys[b] = nil
        let app = try start(keys: keys)
        click(AccessibilityID.botRow(a))
        waitForVersion("profile-a")
        click(AccessibilityID.botRow(b))
        let banner = element(AccessibilityID.bannerError.rawValue)
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertTrue(text(banner.identifier).contains("Clé API absente"))
        waitForVersion("inconnue")
        HVShot.capture("issue58-version-missing-key", app)
        XCTAssertFalse(request("/_hv/log").contains { $0["p"] as? String == "/p/\(b)/health" && ($0["t"] as? Double ?? 0) >= started })
        click(AccessibilityID.botRow(a))
        waitForVersion("profile-a")
        XCTAssertFalse(banner.exists)
    }

    func test401IsClearAndSwitchingProfileRecovers() throws {
        let started = Date().timeIntervalSince1970
        configureVersion("profile-a")
        let app = try start(keys: keys())
        click(AccessibilityID.botRow(a))
        waitForVersion("profile-a")
        configureVersion("profile-b", rejectKey: true)
        click(AccessibilityID.botRow(b))
        let banner = element(AccessibilityID.bannerError.rawValue)
        XCTAssertTrue(banner.waitForExistence(timeout: 15))
        XCTAssertTrue(text(banner.identifier).contains("clé API est refusée"))
        waitForVersion("inconnue")
        XCTAssertTrue(request("/_hv/log").contains { $0["p"] as? String == "/p/\(b)/health" && $0["s"] as? Int == 401 && ($0["t"] as? Double ?? 0) >= started })
        HVShot.capture("issue58-version-401", app)
        configureVersion("profile-a")
        click(AccessibilityID.botRow(a))
        waitForVersion("profile-a")
        XCTAssertFalse(banner.exists)
    }
}
