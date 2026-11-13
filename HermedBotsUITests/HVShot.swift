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
        hideCaret(in: window)
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

    /// Masque le caret du compositeur avant la capture : retire le focus s'il est encore sur le champ.
    /// Ne jamais envoyer Escape : une feuille d'approbation se fermerait.
    /// Le masquage visuel tient aussi au `tint(.clear)` du champ en mode test, y compris derrière une feuille.
    static func hideCaret(in root: XCUIElement) {
        let input = root.descendants(matching: .any).matching(identifier: AccessibilityID.composerInput.rawValue).firstMatch
        guard input.exists, input.hasKeyboardFocus else { return }
        let status = root.descendants(matching: .any).matching(identifier: AccessibilityID.statusVersion.rawValue).firstMatch
        if status.exists, status.isHittable {
            status.click()
        }
    }
}
