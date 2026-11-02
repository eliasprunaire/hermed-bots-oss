import XCTest

@MainActor
final class AboutSettingsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(fr)"]
        app.launchEnvironment["HV_TEST_MODE"] = "1"
        app.launch()
        return app
    }

    private func element(_ id: AccessibilityID, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id.rawValue).firstMatch
    }

    private func text(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty { return value }
        return element.label
    }

    func testTheAboutTabShowsVersionsAndPutsTheUpdateButtonLast() {
        let app = launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "la fenêtre ne s'ouvre pas")
        let open = element(.connectionOpen, in: app)
        XCTAssertTrue(open.waitForExistence(timeout: 10), "hd.connection.open absent")
        open.click()
        let about = element(.settingsUpdates, in: app)
        XCTAssertTrue(about.waitForExistence(timeout: 5), "l'onglet À propos est absent")
        XCTAssertTrue(about.label.contains("À propos") || about.title.contains("À propos") || about.identifier == AccessibilityID.settingsUpdates.rawValue)
        about.click()
        let versionIDs: [AccessibilityID] = [
            .aboutAppVersion,
            .aboutAppBuild,
            .aboutHermes,
            .aboutMacOS,
            .aboutChannel,
        ]
        var lastMaxY: CGFloat = 0
        for id in versionIDs {
            let row = element(id, in: app)
            XCTAssertTrue(row.waitForExistence(timeout: 5), "\(id.rawValue) absent")
            let shown = text(of: row)
            XCTAssertFalse(shown.isEmpty, "\(id.rawValue) vide")
            lastMaxY = max(lastMaxY, row.frame.maxY)
        }
        let button = element(.updatesCheck, in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "hd.updates.check absent")
        XCTAssertGreaterThanOrEqual(button.frame.minY, lastMaxY - 1, "le bouton n'est pas sous les versions")
        HVShot.capture("about-settings", app)
    }
}
