import XCTest

/// Captures des états de la piste 1 : pied, bandeau, connexion, vides, Markdown, compaction, À propos.
/// Données fictives (`HV_SHOT_SCENE`) ; aucune image n'est écrite dans le dépôt.
@MainActor
final class Piste1Shots: XCTestCase {
    /// Même identifiants que `ShotScene.rawValue`.
    private let scenes = [
        "footer-ready", "footer-connecting", "footer-untested", "footer-failed", "footer-tunnel",
        "banner-degraded", "connection", "error", "empty-home", "empty-conversation",
        "markdown", "markdown-streaming", "compacted",
        "about-connecting", "about-ready", "about-untested", "about-failed",
    ]

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(scene: String, dark: Bool, size: String?) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(fr)"]
        app.launchEnvironment["HV_TEST_MODE"] = "1"
        app.launchEnvironment["HV_SHOT_SCENE"] = scene
        app.launchEnvironment["HV_RESUME_SCOPE"] = UUID().uuidString
        if dark { app.launchEnvironment["HV_APPEARANCE"] = "dark" }
        if let size { app.launchEnvironment["HV_WINDOW_SIZE"] = size }
        app.launch()
        return app
    }

    private func element(_ id: AccessibilityID, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id.rawValue).firstMatch
    }

    private func openSettings(about: Bool, in app: XCUIApplication) {
        let open = element(.connectionOpen, in: app)
        XCTAssertTrue(open.waitForExistence(timeout: 10), "hd.connection.open absent")
        open.click()
        XCTAssertTrue(element(.connectionHost, in: app).waitForExistence(timeout: 10), "Réglages Connexion absents")
        if about {
            let aboutTab = element(.settingsUpdates, in: app)
            XCTAssertTrue(aboutTab.waitForExistence(timeout: 10), "onglet À propos absent")
            aboutTab.click()
            XCTAssertTrue(element(.aboutCompat, in: app).waitForExistence(timeout: 10), "hd.about.compat absent")
        }
    }

    func testCaptureEachPiste1StateInStandardAndLargeLightAndDark() {
        let sizes: [(String, String?)] = [("standard", nil), ("large", "1100x760")]
        for scene in scenes {
            for (sizeName, size) in sizes {
                for dark in [false, true] {
                    let app = launch(scene: scene, dark: dark, size: size)
                    XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10), "\(scene) : fenêtre absente")
                    XCTAssertTrue(element(.statusCompat, in: app).waitForExistence(timeout: 10), "\(scene) : pied absent")
                    if scene.hasPrefix("about-") {
                        openSettings(about: true, in: app)
                    } else if scene == "connection" {
                        openSettings(about: false, in: app)
                    }
                    HVShot.capture("piste1-\(scene)-\(sizeName)-\(dark ? "dark" : "light")", app)
                    app.terminate()
                }
            }
        }
    }
}
