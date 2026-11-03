import XCTest

@MainActor
final class AboutSettingsTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private var apiURL: String? { environment["HV_API_URL"] }

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(fr)"]
        app.launchEnvironment["HV_TEST_MODE"] = "1"
        if let url = apiURL { app.launchEnvironment["HV_API_URL"] = url }
        for name in ["HV_TEST_API_KEY", "HV_TEST_API_KEYS", "HV_TEST_PROFILE_TABLE"] { app.launchEnvironment[name] = environment[name] }
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

    private func serverVersion(at url: String?) -> String? {
        guard let url, let data = try? Data(contentsOf: URL(string: url + "/health")!),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = body["version"] as? String, !version.isEmpty else { return nil }
        return version
    }

    private func settledVersion(in app: XCUIApplication, timeout: TimeInterval = 15) -> String {
        let version = element(.statusVersion, in: app)
        XCTAssertTrue(version.waitForExistence(timeout: timeout), "hd.status.version absent")
        let deadline = Date().addingTimeInterval(timeout)
        while text(of: version) == "…", Date() < deadline { usleep(50_000) }
        return text(of: version)
    }

    func testTheAboutTabShowsVersionsAndPutsTheUpdateButtonLast() throws {
        let app = launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "la fenêtre ne s'ouvre pas")
        let bot = app.descendants(matching: .any).matching(identifier: AccessibilityID.botRow("hv-bot-a")).firstMatch
        try XCTSkipUnless(bot.waitForExistence(timeout: 20), "profil hv-bot-a absent : table/clés de test ou instance orb sans ces profils")
        let shown = settledVersion(in: app)
        let open = element(.connectionOpen, in: app)
        XCTAssertTrue(open.waitForExistence(timeout: 10), "hd.connection.open absent")
        open.click()
        // La scène Réglages est une autre fenêtre : attendre un contrôle Connexion avant l'onglet À propos.
        let connectionHost = element(.connectionHost, in: app)
        XCTAssertTrue(connectionHost.waitForExistence(timeout: 10), "la fenêtre Réglages (Connexion) ne s'ouvre pas")
        // Rangée de boutons SettingsPane (connection) — aperçu demandé hors baselines.
        HVShot.capture("settings-connection", app)
        let about = element(.settingsUpdates, in: app)
        XCTAssertTrue(about.waitForExistence(timeout: 10), "l'onglet À propos est absent")
        XCTAssertEqual(about.identifier, AccessibilityID.settingsUpdates.rawValue)
        let title = about.label.isEmpty ? about.title : about.label
        XCTAssertTrue(title.contains("À propos"), "titre de l'onglet=\(title)")
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
            let shownRow = text(of: row)
            XCTAssertFalse(shownRow.isEmpty, "\(id.rawValue) vide")
            lastMaxY = max(lastMaxY, row.frame.maxY)
        }
        let hermes = element(.aboutHermes, in: app)
        XCTAssertEqual(text(of: hermes), shown)
        if let expected = serverVersion(at: apiURL) {
            XCTAssertEqual(shown, expected)
        }
        let button = element(.updatesCheck, in: app)
        XCTAssertTrue(button.waitForExistence(timeout: 5), "hd.updates.check absent")
        XCTAssertGreaterThanOrEqual(button.frame.minY, lastMaxY - 1, "le bouton n'est pas sous les versions")
        // Rangée de boutons SettingsPane (updates / À propos).
        HVShot.capture("settings-updates", app)
        HVShot.capture("about-settings", app)
    }
}
