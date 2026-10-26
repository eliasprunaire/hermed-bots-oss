import XCTest

@MainActor
final class ProfileKeys: HD12Harness {
    private let profiles = ["default", "cyber", "gaming", "ia", "perso", "recherches", "sport", "tiny", "wikilibriste"]

    func testAllNineProfilesWithDistinctKeys() throws {
        guard environment["HV_TEST_API_KEYS"] != nil else { throw XCTSkip("Lane HD17 avec clés distinctes requise") }
        for profile in profiles {
            let app = launch()
            let row = element(AccessibilityID.botName(profile))
            XCTAssertTrue(row.waitForExistence(timeout: 20))
            let deadline = Date().addingTimeInterval(10)
            while !row.isHittable, Date() < deadline {
                element(AccessibilityID.botsList.rawValue).scroll(byDeltaX: 0, deltaY: -300)
            }
            click(AccessibilityID.botName(profile))
            send()
            let state = element(AccessibilityID.conversationState.rawValue)
            let finished = NSPredicate { _, _ in
                state.exists && self.text(AccessibilityID.conversationState.rawValue).contains("terminé")
            }
            expectation(for: finished, evaluatedWith: nil)
            waitForExpectations(timeout: 30)
            XCTAssertFalse(element(AccessibilityID.bannerError.rawValue).exists)
            HVShot.capture("hd17-profile-\(profile)", app)
            app.terminate()
        }
        let entries = request("/_hv/log")
        let starts = entries.filter { $0["m"] as? String == "POST" && ($0["p"] as? String)?.hasSuffix("/v1/runs") == true }
        print("HD17 starts: " + starts.map { "\($0["p"] ?? "")=\($0["s"] ?? "")" }.joined(separator: ", "))
        for profile in profiles {
            let path = "/p/\(profile)/v1/runs"
            XCTAssertTrue(entries.contains { $0["p"] as? String == path && $0["s"] as? Int == 202 }, "Aucun run accepté pour \(profile)")
        }
        print("HD17 UI: neuf conversations terminées avec clés distinctes")
    }

    func testCrossedKeyShowsTheAuthenticationError() throws {
        guard let raw = environment["HV_TEST_API_KEYS"], var keys = try? JSONDecoder().decode([String: String].self, from: Data(raw.utf8)) else {
            throw XCTSkip("Lane HD17 avec clés distinctes requise")
        }
        keys["cyber"] = keys["ia"]
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(fr)"]
        app.launchEnvironment["HV_TEST_MODE"] = "1"
        app.launchEnvironment["HV_API_URL"] = environment["HV_API_URL"]
        app.launchEnvironment["HV_TEST_API_KEYS"] = String(decoding: try JSONEncoder().encode(keys), as: UTF8.self)
        app.launch()
        self.app = app
        click(AccessibilityID.botRow("cyber"))
        XCTAssertTrue(element(AccessibilityID.bannerError.rawValue).waitForExistence(timeout: 20))
        XCTAssertTrue(text(AccessibilityID.bannerError.rawValue).contains("clé API"))
        let entries = request("/_hv/log")
        XCTAssertTrue(entries.contains { ($0["p"] as? String)?.hasPrefix("/p/cyber/") == true && $0["s"] as? Int == 401 })
        HVShot.capture("hd17-crossed-key", app)
    }

    func testConnectionOffersASecureFieldForEachProfile() {
        let app = launch()
        XCTAssertTrue(element(AccessibilityID.botRow("cyber")).waitForExistence(timeout: 20))
        click(AccessibilityID.connectionOpen.rawValue)
        XCTAssertTrue(element(AccessibilityID.connectionAPIProfile.rawValue).waitForExistence(timeout: 10))
        XCTAssertTrue(app.secureTextFields[AccessibilityID.connectionAPIKey.rawValue].exists)
        XCTAssertFalse(element(AccessibilityID.connectionAPISave.rawValue).isEnabled)
        let settings = app.windows.containing(.any, identifier: AccessibilityID.connectionConnect.rawValue).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertEqual(settings.frame.width, 1024, accuracy: 1)
        XCTAssertEqual(settings.frame.height, 680, accuracy: 1)
        for id in [
            AccessibilityID.connectionCheck.rawValue,
            AccessibilityID.connectionClose.rawValue,
            AccessibilityID.connectionConnect.rawValue,
        ] {
            let button = element(id)
            XCTAssertTrue(button.isHittable, "élément inaccessible : \(id)")
            XCTAssertTrue(settings.frame.contains(button.frame), "\(id) hors de la fenêtre")
        }
        HVShot.capture("hd17-key-settings", settings)
    }
}
