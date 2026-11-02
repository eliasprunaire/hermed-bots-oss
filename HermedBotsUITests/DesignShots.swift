import AppKit
import XCTest

/// Le rendu de l'interface hors de la taille et de l'apparence de la suite ordinaire : apparence sombre, puis fenêtre réduite à sa taille minimale
/// Lane à part (`docs/spike/design-instruments/run-design.sh`) : une fenêtre redimensionnée garde sa taille au lancement suivant et fausserait les captures de la suite ordinaire
@MainActor
final class DesignShots: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    override func setUpWithError() throws {
        try XCTSkipUnless(environment["HV_DESIGN_LANE"] == "1", "lane de rendu : docs/spike/design-instruments/run-design.sh")
        continueAfterFailure = false
        FakeServer.reset()
    }

    private func launch(dark: Bool = false, size: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(fr)"]
        app.launchEnvironment["HV_TEST_MODE"] = "1"
        app.launchEnvironment["HV_RESUME_SCOPE"] = UUID().uuidString
        if dark { app.launchEnvironment["HV_APPEARANCE"] = "dark" }
        if let size { app.launchEnvironment["HV_WINDOW_SIZE"] = size }
        for name in ["HV_API_URL", "HV_TEST_API_KEY", "HV_TEST_API_KEYS"] {
            if let value = environment[name] { app.launchEnvironment[name] = value }
        }
        app.launch()
        return app
    }

    /// La luminance moyenne, de 0 à 1, d'un carré de 40 points pris dans la fenêtre au point normalisé donné
    private func luminance(_ screenshot: XCUIScreenshot, at point: CGPoint) throws -> Double {
        let image = try XCTUnwrap(NSBitmapImageRep(data: screenshot.pngRepresentation), "capture illisible")
        let scale = Double(image.pixelsWide) / Double(screenshot.image.size.width)
        let side = Int(40 * scale)
        let x0 = Int(point.x * Double(image.pixelsWide)) - side / 2, y0 = Int(point.y * Double(image.pixelsHigh)) - side / 2
        var total = 0.0
        for x in x0..<(x0 + side) {
            for y in y0..<(y0 + side) {
                let color = try XCTUnwrap(image.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                total += 0.2126 * color.redComponent + 0.7152 * color.greenComponent + 0.0722 * color.blueComponent
            }
        }
        return total / Double(side * side)
    }

    private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@", id)).firstMatch
    }

    /// Ouvre `hv-bot-a` et attend la fin d'un tour, pour capturer un fil rempli
    private func converse(_ app: XCUIApplication) {
        let bot = element(AccessibilityID.botRow("hv-bot-a"), in: app)
        XCTAssertTrue(bot.waitForExistence(timeout: 20))
        bot.click()
        let input = element(AccessibilityID.composerInput.rawValue, in: app)
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.click()
        input.typeText("Bonjour hv\n")
        XCTAssertTrue(element(AccessibilityID.conversationState.rawValue, in: app).waitForExistence(timeout: 20), "le tour ne finit pas")
    }

    func testTheDarkAppearanceKeepsTheHomeAndTheConversationReadable() throws {
        let app = launch(dark: true)
        XCTAssertTrue(element(AccessibilityID.homeBot("hv-bot-a"), in: app).waitForExistence(timeout: 20), "l'accueil ne montre pas les bots")
        let home = HVShot.capture("design-dark-home", app)
        // le bas de la zone de détail, sous les cartes : un fond sombre et non le blanc de l'apparence claire
        let background = try luminance(home, at: CGPoint(x: 0.6, y: 0.97))
        print("HV-DESIGN luminance accueil sombre=\(background)")
        XCTAssertLessThan(background, 0.3, "l'accueil n'est pas en apparence sombre")
        converse(app)
        let conversation = HVShot.capture("design-dark-conversation", app)
        let thread = try luminance(conversation, at: CGPoint(x: 0.6, y: 0.7))
        print("HV-DESIGN luminance fil sombre=\(thread)")
        XCTAssertLessThan(thread, 0.3, "le fil n'est pas en apparence sombre")
    }

    func testTheMinimumWindowKeepsTheSidebarAndTheComposerUsable() {
        let app = launch(size: "760x520")
        XCTAssertTrue(element(AccessibilityID.homeBot("hv-bot-a"), in: app).waitForExistence(timeout: 20), "l'accueil ne montre pas les bots")
        let frame = app.windows.firstMatch.frame
        print("HV-DESIGN fenêtre \(Int(frame.width))x\(Int(frame.height))")
        XCTAssertEqual(frame.width, 760, accuracy: 2, "la fenêtre n'a pas la largeur demandée")
        HVShot.capture("design-compact-home", app)
        converse(app)
        XCTAssertTrue(element(AccessibilityID.composerSend.rawValue, in: app).isHittable, "Envoyer sort de la fenêtre")
        XCTAssertTrue(element(AccessibilityID.composerInput.rawValue, in: app).isHittable, "le champ sort de la fenêtre")
        let row = element(AccessibilityID.botRow("hv-bot-a"), in: app)
        let list = element(AccessibilityID.botsList.rawValue, in: app)
        print("HV-DESIGN compact ligne=\(row.isHittable) liste=\(list.isHittable) cadre-liste=\(list.frame)")
        HVShot.capture("design-compact-conversation", app)
        // la ligne et non la liste : XCUITest juge le conteneur `hd.bots.list` non atteignable même quand ses lignes le sont (relevé du 2026-11-01)
        XCTAssertTrue(row.isHittable, "la ligne du bot ouvert n'est plus cliquable dans la barre latérale")
    }
}
