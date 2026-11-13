import XCTest

/// Capture de la fenêtre pour la passe de vérification : joint l'image au xcresult et annonce `HV-SHOT <nom>`
/// Le runner XCUITest est sandboxé et ne peut pas écrire dans `$HV_SHOTS` : `hv-run.sh` exporte les pièces jointes
/// vers `shots/<nom>.png` et échoue si une capture annoncée manque
@MainActor
enum HVShot {
    /// Dossier de la passe donné par `hv-run.sh` (`$HV_EVIDENCE/shots`), nil hors passe de vérification ; `LaunchTests` s'en sert pour situer `run.log`
    static var directory: URL? {
        ProcessInfo.processInfo.environment["HV_SHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    @discardableResult
    static func capture(_ name: String, _ app: XCUIApplication) -> XCUIScreenshot {
        capture(name, app.windows.firstMatch)
    }

    @discardableResult
    static func capture(_ name: String, _ window: XCUIElement) -> XCUIScreenshot {
        let screenshot = window.screenshot()
        print("HV-SHOT \(name)")
        XCTContext.runActivity(named: "capture \(name)") { activity in
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = name
            attachment.lifetime = .keepAlways
            activity.add(attachment)
        }
        return screenshot
    }
}
